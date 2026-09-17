// VirtualAudioDevicePlugin.cpp
//
// Core Audio AudioServerPlugIn (HAL Plugin) implementing a single virtual
// OUTPUT device with a runtime-configurable channel count (gChannelCount,
// 1-128, default kDefaultChannelCount). Written from scratch against
// <CoreAudio/AudioServerPlugIn.h> / AudioHardwareBase.h (no BlackHole/
// existing plugin code reused), following the plugin-host COM-style calling
// convention Apple's HAL requires (a "class" is a struct whose first member
// is an AudioServerPlugInDriverInterface* vtable, dispatched exactly like a
// COM object; there is no C++ vtable / RTTI involved).
//
// DAWs (Ableton Live etc.) select this device as an OUTPUT and write mixed
// audio into it (kAudioServerPlugInIOOperationWriteMix). On every IO cycle
// this plugin computes an abs-peak per channel from the HAL-mixed buffer and
// publishes it into the POSIX shared-memory meter struct (Shared/MeterShm.h)
// for the visualizer app to read. No control features (mute/volume) beyond
// nominal sample rate — those remain follow-up work (README roadmap).

#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreFoundation/CoreFoundation.h>
#include <dispatch/dispatch.h>
#include <mach/mach_time.h>
#include <pthread.h>
#include <algorithm>
#include <atomic>
#include <fcntl.h>
#include <sys/mman.h>
#include <unistd.h>
#include <cmath>
#include <cstring>
#include <cstdio>

#include "../../Shared/MeterShm.h"

namespace {

constexpr UInt32 kDefaultChannelCount = 128;
static_assert(kDefaultChannelCount <= VAI_MAX_CHANNELS, "kDefaultChannelCount exceeds shared-memory capacity");

// Supported nominal sample rates (variable sample rate support).
constexpr Float64 kSupportedSampleRates[] = {44100.0, 48000.0, 88200.0, 96000.0};
constexpr int kSupportedSampleRateCount = sizeof(kSupportedSampleRates) / sizeof(kSupportedSampleRates[0]);
constexpr Float64 kDefaultSampleRate = 48000.0;

constexpr UInt32 kZeroTimeStampPeriod = 16384; // frames

const AudioObjectID kPlugInObjectID = kAudioObjectPlugInObject;
const AudioObjectID kDeviceObjectID = 2;
const AudioObjectID kStreamObjectID = 3;

CFStringRef kDeviceUID = CFSTR("com.daitomanabe.virtualaudiointerface.device");
CFStringRef kModelUID = CFSTR("com.daitomanabe.virtualaudiointerface.model");
CFStringRef kDeviceName = CFSTR("Virtual Audio Interface (128ch)");
CFStringRef kManufacturer = CFSTR("daitomanabe");
CFStringRef kPlugInBundleName = CFSTR("VirtualAudioInterfaceDriver");
CFStringRef kEmptyString = CFSTR("");

bool SampleRateSupported(Float64 rate) {
    for (int i = 0; i < kSupportedSampleRateCount; ++i) {
        if (std::fabs(kSupportedSampleRates[i] - rate) < 0.5) return true;
    }
    return false;
}

// ---- shared memory meter publisher ------------------------------------

struct MeterPublisher {
    VAIMeterShm *shm = nullptr;
    int fd = -1;

    // Driver-side ballistics state (previous IO cycle's values), kept out of
    // shm since only this struct ever reads or writes it. Indexed by
    // channel; IO thread only, fixed size, no malloc.
    float peakState[VAI_MAX_CHANNELS] = {};
    float meanSqState[VAI_MAX_CHANNELS] = {};

    void open(UInt32 initialChannelCount, Float64 initialSampleRate, UInt32 zeroTimeStampPeriod) {
        fd = shm_open(VAI_SHM_NAME, O_CREAT | O_RDWR, 0666);
        if (fd < 0) return;
        ftruncate(fd, sizeof(VAIMeterShm));
        void *p = mmap(nullptr, sizeof(VAIMeterShm), PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
        if (p == MAP_FAILED) { shm = nullptr; return; }
        shm = reinterpret_cast<VAIMeterShm *>(p);
        memset(shm, 0, sizeof(*shm));
        shm->magic = VAI_SHM_MAGIC;
        shm->channelCount = initialChannelCount;
        shm->sampleRate = initialSampleRate;
        shm->zeroTimeStampPeriod = zeroTimeStampPeriod;
        shm->updateCounter = 0;
        resetState();
    }

    // Channel count just changed: the old ballistics state no longer
    // corresponds to the new channel mapping, so drop it. Not synchronized
    // with publish() below (both only ever run near-serially around a
    // config change, and worst case is one meter frame briefly resetting —
    // same tolerance the rest of this struct already assumes for shm reads).
    void resetState() {
        memset(peakState, 0, sizeof(peakState));
        memset(meanSqState, 0, sizeof(meanSqState));
    }

    // interleaved: Float32[frames * channels], HAL-mixed output (WriteMix).
    // IO thread only: no malloc, no locks, no logging.
    void publish(const Float32 *interleaved, UInt32 frames, UInt32 channels, Float64 sampleRate) {
        if (!shm) return;
        float decay = vai_peak_decay_factor(frames, sampleRate);
        float alpha = vai_rms_alpha(frames, sampleRate);
        for (UInt32 ch = 0; ch < channels && ch < VAI_MAX_CHANNELS; ++ch) {
            float peak = 0.f;
            double sumSq = 0.0;
            bool clipped = false;
            for (UInt32 f = 0; f < frames; ++f) {
                float v = interleaved[f * channels + ch];
                float av = std::fabs(v);
                if (av > peak) peak = av;
                sumSq += static_cast<double>(v) * static_cast<double>(v);
                if (av >= 1.0f) clipped = true;
            }
            float meanSq = frames > 0 ? static_cast<float>(sumSq / frames) : 0.f;

            float newPeak = std::max(peak, peakState[ch] * decay);
            peakState[ch] = newPeak;
            float newMeanSq = meanSqState[ch] + alpha * (meanSq - meanSqState[ch]);
            meanSqState[ch] = newMeanSq;

            shm->peakLevel[ch] = newPeak;
            shm->rmsLevel[ch] = std::sqrt(std::max(newMeanSq, 0.f));
            if (clipped) shm->clipCount[ch]++;
        }
        shm->updateCounter++;
    }
};

MeterPublisher gMeter;

// ---- plugin-wide state ---------------------------------------------------
// Protects sample rate + channel count + zero-timestamp anchoring state, all
// touched from both the HAL's IO thread and property get/set calls.
pthread_mutex_t gStateMutex = PTHREAD_MUTEX_INITIALIZER;

// atomic: publish() now reads this lock-free from the IO thread (ballistics
// decay/alpha depend on sample rate), same rationale as gChannelCount below.
// All existing gStateMutex-guarded call sites are unchanged: std::atomic<T>
// converts to/from T implicitly, so this is a drop-in type swap.
std::atomic<Float64> gSampleRate{kDefaultSampleRate};
std::atomic<UInt32> gChannelCount{kDefaultChannelCount}; // atomic: read lock-free on the IO thread
UInt64 gZeroTimeSeed = 1;
bool gDeviceIsRunning = false;

// Zero-timestamp anchoring (set on StartIO).
UInt64 gAnchorHostTime = 0;
Float64 gTicksPerPeriod = 0; // mach host ticks per kZeroTimeStampPeriod frames

void RecomputeTicksPerPeriod() {
    mach_timebase_info_data_t tb = {1, 1};
    mach_timebase_info(&tb);
    double periodSeconds = static_cast<double>(kZeroTimeStampPeriod) / gSampleRate;
    double periodNanos = periodSeconds * 1e9;
    gTicksPerPeriod = periodNanos * (static_cast<double>(tb.denom) / static_cast<double>(tb.numer));
}

// ---- device configuration change protocol ---------------------------------
// inChangeAction just means "apply whatever is staged in gPending*" — the
// actual new rate/channel count travel out-of-band (mutex-protected globals)
// instead of being packed into the UInt64 action code.
constexpr UInt64 kApplyPendingConfigAction = 1;

Float64 gPendingSampleRate = kDefaultSampleRate;
UInt32 gPendingChannelCount = kDefaultChannelCount;
UInt64 gPendingConfigCounter = 0; // shm->configCounter this pending change corresponds to (0 = host-initiated, not from app)

// Client count: bumped from AddDeviceClient/RemoveDeviceClient, which the
// HAL can call from more than one thread, so an atomic counter is simpler
// and just as correct here as taking gStateMutex would be.
std::atomic<UInt32> gClientCount{0};

// Only ever touched from the config-poll dispatch source below (its
// callbacks never overlap), so it needs no lock of its own.
UInt64 gLastSeenConfigCounter = 0;
dispatch_source_t gConfigPollTimer = nullptr;

// =========================================================================
// AudioServerPlugInDriverInterface implementation
// =========================================================================

HRESULT Plugin_QueryInterface(void *, REFIID inUUID, LPVOID *outInterface);
ULONG Plugin_AddRef(void *inDriver);
ULONG Plugin_Release(void *inDriver);

OSStatus Plugin_Initialize(AudioServerPlugInDriverRef inDriver, AudioServerPlugInHostRef inHost);
OSStatus Plugin_CreateDevice(AudioServerPlugInDriverRef, CFDictionaryRef, const AudioServerPlugInClientInfo *, AudioObjectID *);
OSStatus Plugin_DestroyDevice(AudioServerPlugInDriverRef, AudioObjectID);
OSStatus Plugin_AddDeviceClient(AudioServerPlugInDriverRef, AudioObjectID, const AudioServerPlugInClientInfo *);
OSStatus Plugin_RemoveDeviceClient(AudioServerPlugInDriverRef, AudioObjectID, const AudioServerPlugInClientInfo *);
OSStatus Plugin_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef, AudioObjectID, UInt64, void *);
OSStatus Plugin_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef, AudioObjectID, UInt64, void *);

Boolean Plugin_HasProperty(AudioServerPlugInDriverRef, AudioObjectID, pid_t, const AudioObjectPropertyAddress *);
OSStatus Plugin_IsPropertySettable(AudioServerPlugInDriverRef, AudioObjectID, pid_t, const AudioObjectPropertyAddress *, Boolean *);
OSStatus Plugin_GetPropertyDataSize(AudioServerPlugInDriverRef, AudioObjectID, pid_t, const AudioObjectPropertyAddress *, UInt32, const void *, UInt32 *);
OSStatus Plugin_GetPropertyData(AudioServerPlugInDriverRef, AudioObjectID, pid_t, const AudioObjectPropertyAddress *, UInt32, const void *, UInt32, UInt32 *, void *);
OSStatus Plugin_SetPropertyData(AudioServerPlugInDriverRef, AudioObjectID, pid_t, const AudioObjectPropertyAddress *, UInt32, const void *, UInt32, const void *);

OSStatus Plugin_StartIO(AudioServerPlugInDriverRef, AudioObjectID, UInt32);
OSStatus Plugin_StopIO(AudioServerPlugInDriverRef, AudioObjectID, UInt32);
OSStatus Plugin_GetZeroTimeStamp(AudioServerPlugInDriverRef, AudioObjectID, UInt32, Float64 *, UInt64 *, UInt64 *);
OSStatus Plugin_WillDoIOOperation(AudioServerPlugInDriverRef, AudioObjectID, UInt32, UInt32, Boolean *, Boolean *);
OSStatus Plugin_BeginIOOperation(AudioServerPlugInDriverRef, AudioObjectID, UInt32, UInt32, UInt32, const AudioServerPlugInIOCycleInfo *);
OSStatus Plugin_DoIOOperation(AudioServerPlugInDriverRef, AudioObjectID, AudioObjectID, UInt32, UInt32, UInt32, const AudioServerPlugInIOCycleInfo *, void *, void *);
OSStatus Plugin_EndIOOperation(AudioServerPlugInDriverRef, AudioObjectID, UInt32, UInt32, UInt32, const AudioServerPlugInIOCycleInfo *);

AudioServerPlugInDriverInterface gDriverInterface = {
    nullptr,
    Plugin_QueryInterface, Plugin_AddRef, Plugin_Release,
    Plugin_Initialize, Plugin_CreateDevice, Plugin_DestroyDevice,
    Plugin_AddDeviceClient, Plugin_RemoveDeviceClient,
    Plugin_PerformDeviceConfigurationChange, Plugin_AbortDeviceConfigurationChange,
    Plugin_HasProperty, Plugin_IsPropertySettable, Plugin_GetPropertyDataSize,
    Plugin_GetPropertyData, Plugin_SetPropertyData,
    Plugin_StartIO, Plugin_StopIO, Plugin_GetZeroTimeStamp,
    Plugin_WillDoIOOperation, Plugin_BeginIOOperation, Plugin_DoIOOperation, Plugin_EndIOOperation,
};

AudioServerPlugInDriverInterface *gDriverInterfacePtr = &gDriverInterface;
AudioServerPlugInDriverRef gDriverRef = &gDriverInterfacePtr;
AudioServerPlugInHostRef gPlugInHost = nullptr;

// ---- IUnknown ------------------------------------------------------------

HRESULT Plugin_QueryInterface(void *, REFIID inUUID, LPVOID *outInterface) {
    if (!outInterface) return kAudioHardwareIllegalOperationError;
    CFUUIDRef requested = CFUUIDCreateFromUUIDBytes(nullptr, inUUID);
    bool match = CFEqual(requested, IUnknownUUID) || CFEqual(requested, kAudioServerPlugInDriverInterfaceUUID);
    CFRelease(requested);
    if (!match) return E_NOINTERFACE;
    *outInterface = gDriverRef;
    return S_OK;
}
ULONG Plugin_AddRef(void *) { return 1; }
ULONG Plugin_Release(void *) { return 1; }

// ---- lifecycle -----------------------------------------------------------

// Forward decl; defined after PerformDeviceConfigurationChange needs it too
// (poll timer calls back into RequestDeviceConfigurationChange).
void StartConfigPollTimer();

OSStatus Plugin_Initialize(AudioServerPlugInDriverRef, AudioServerPlugInHostRef inHost) {
    gPlugInHost = inHost;
    RecomputeTicksPerPeriod();
    // keep returning success even if shm open failed (existing behavior)
    gMeter.open(gChannelCount, gSampleRate, kZeroTimeStampPeriod);
    StartConfigPollTimer();
    return kAudioHardwareNoError;
}

OSStatus Plugin_CreateDevice(AudioServerPlugInDriverRef, CFDictionaryRef, const AudioServerPlugInClientInfo *, AudioObjectID *outDeviceObjectID) {
    if (outDeviceObjectID) *outDeviceObjectID = kDeviceObjectID;
    return kAudioHardwareNoError; // dynamic device creation unsupported; we expose one static device
}
OSStatus Plugin_DestroyDevice(AudioServerPlugInDriverRef, AudioObjectID) { return kAudioHardwareNoError; }
OSStatus Plugin_AddDeviceClient(AudioServerPlugInDriverRef, AudioObjectID, const AudioServerPlugInClientInfo *) {
    UInt32 n = ++gClientCount;
    if (gMeter.shm) gMeter.shm->clientCount = n;
    return kAudioHardwareNoError;
}
OSStatus Plugin_RemoveDeviceClient(AudioServerPlugInDriverRef, AudioObjectID, const AudioServerPlugInClientInfo *) {
    UInt32 n = (gClientCount > 0) ? UInt32(--gClientCount) : 0;
    if (gMeter.shm) gMeter.shm->clientCount = n;
    return kAudioHardwareNoError;
}

// inChangeAction is always kApplyPendingConfigAction: the actual new
// rate/channel count are staged in gPendingSampleRate/gPendingChannelCount
// by whoever called RequestDeviceConfigurationChange (SetPropertyData for a
// host-driven rate change, or the config-poll timer for an app-driven
// channel/rate change via shared memory).
OSStatus Plugin_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef, AudioObjectID inDeviceObjectID, UInt64 inChangeAction, void *) {
    if (inDeviceObjectID != kDeviceObjectID) return kAudioHardwareBadObjectError;
    if (inChangeAction != kApplyPendingConfigAction) return kAudioHardwareIllegalOperationError;

    pthread_mutex_lock(&gStateMutex);
    Float64 newRate = gPendingSampleRate;
    UInt32 newChannels = gPendingChannelCount;
    bool rateOk = SampleRateSupported(newRate);
    bool channelsOk = (newChannels >= 1 && newChannels <= VAI_MAX_CHANNELS);
    bool channelsChanged = channelsOk && newChannels != gChannelCount;
    if (rateOk) gSampleRate = newRate;
    if (channelsOk) gChannelCount = newChannels;
    RecomputeTicksPerPeriod();
    gZeroTimeSeed++;
    UInt64 appliedConfigCounter = gPendingConfigCounter;
    pthread_mutex_unlock(&gStateMutex);

    // Old per-channel ballistics state no longer maps to the new channel
    // layout — drop it so a channel doesn't inherit a stale peak/rms.
    if (channelsChanged) gMeter.resetState();

    if (gMeter.shm) {
        gMeter.shm->channelCount = gChannelCount;
        gMeter.shm->sampleRate = gSampleRate;
        if (appliedConfigCounter != 0) gMeter.shm->configAppliedCounter = appliedConfigCounter;
    }

    // Let the HAL know the stream format / device properties it cached may
    // have changed so DAWs pick up the new channel count / sample rate.
    if (gPlugInHost && gPlugInHost->PropertiesChanged) {
        AudioObjectPropertyAddress streamAddrs[] = {
            {kAudioStreamPropertyVirtualFormat, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain},
            {kAudioStreamPropertyPhysicalFormat, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain},
        };
        gPlugInHost->PropertiesChanged(gPlugInHost, kStreamObjectID, 2, streamAddrs);

        AudioObjectPropertyAddress deviceAddrs[] = {
            {kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain},
            {kAudioDevicePropertyPreferredChannelLayout, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain},
        };
        gPlugInHost->PropertiesChanged(gPlugInHost, kDeviceObjectID, 2, deviceAddrs);
    }
    return kAudioHardwareNoError;
}
OSStatus Plugin_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef, AudioObjectID, UInt64, void *) { return kAudioHardwareNoError; }

// ---- app-driven config polling --------------------------------------------
// The app (VisualizerApp Settings tab) requests channel-count/sample-rate
// changes by writing requestedChannelCount/requestedSampleRate into shm and
// bumping configCounter. We can't act on that from the IO thread, so a timer
// on a background queue polls every 200ms and routes validated requests
// through the same RequestDeviceConfigurationChange/PerformDeviceConfigurationChange
// path the HAL uses for its own property-set-driven changes.
void PollConfigRequests() {
    if (!gMeter.shm) return;
    UInt64 counter = gMeter.shm->configCounter;
    if (counter == gLastSeenConfigCounter) return;
    gLastSeenConfigCounter = counter;
    std::atomic_thread_fence(std::memory_order_acquire); // pair with app's release fence before configCounter++

    UInt32 reqChannels = gMeter.shm->requestedChannelCount;
    Float64 reqRate = gMeter.shm->requestedSampleRate;

    pthread_mutex_lock(&gStateMutex);
    Float64 newRate = gSampleRate;
    UInt32 newChannels = gChannelCount;
    bool needApply = false;
    if (reqChannels >= 1 && reqChannels <= VAI_MAX_CHANNELS && reqChannels != gChannelCount) {
        newChannels = reqChannels;
        needApply = true;
    }
    if (reqRate > 0 && SampleRateSupported(reqRate) && std::fabs(reqRate - gSampleRate) >= 0.5) {
        newRate = reqRate;
        needApply = true;
    }
    if (needApply) {
        gPendingChannelCount = newChannels;
        gPendingSampleRate = newRate;
        gPendingConfigCounter = counter;
    }
    pthread_mutex_unlock(&gStateMutex);

    if (needApply && gPlugInHost && gPlugInHost->RequestDeviceConfigurationChange) {
        gPlugInHost->RequestDeviceConfigurationChange(gPlugInHost, kDeviceObjectID, kApplyPendingConfigAction, nullptr);
    } else {
        // Nothing actually changed (e.g. request matched current state) —
        // still mark it seen so the app's "applied" indicator doesn't spin.
        gMeter.shm->configAppliedCounter = counter;
    }
}

void StartConfigPollTimer() {
    gConfigPollTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                               dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0));
    if (!gConfigPollTimer) return;
    dispatch_source_set_timer(gConfigPollTimer, dispatch_time(DISPATCH_TIME_NOW, 0),
                               200ull * NSEC_PER_MSEC, 20ull * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(gConfigPollTimer, ^{ PollConfigRequests(); });
    dispatch_resume(gConfigPollTimer);
}

// ---- property helpers ------------------------------------------------

CFStringRef CopyCFString(CFStringRef s) { return static_cast<CFStringRef>(CFRetain(s)); }

bool IsPlugInObject(AudioObjectID objectID) { return objectID == kPlugInObjectID; }
bool IsDeviceObject(AudioObjectID objectID) { return objectID == kDeviceObjectID; }
bool IsStreamObject(AudioObjectID objectID) { return objectID == kStreamObjectID; }

// Callers hold gStateMutex already (see GetPropertyData virtual/physical
// format case below).
AudioStreamBasicDescription StreamFormat() {
    AudioStreamBasicDescription fmt = {};
    fmt.mSampleRate = gSampleRate;
    fmt.mFormatID = kAudioFormatLinearPCM;
    fmt.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
    fmt.mBytesPerPacket = sizeof(Float32) * gChannelCount;
    fmt.mFramesPerPacket = 1;
    fmt.mBytesPerFrame = sizeof(Float32) * gChannelCount;
    fmt.mChannelsPerFrame = gChannelCount;
    fmt.mBitsPerChannel = 32;
    return fmt;
}

// sizeof(AudioChannelLayout) already includes one AudioChannelDescription
// (mNumberChannelDescriptions == 1 case); for N descriptions the size is
// base struct minus the one built-in description plus N descriptions.
UInt32 ChannelLayoutSize(UInt32 numberChannelDescriptions) {
    return static_cast<UInt32>(sizeof(AudioChannelLayout) - sizeof(AudioChannelDescription) +
                                numberChannelDescriptions * sizeof(AudioChannelDescription));
}

// Caller must hold gStateMutex (reads gChannelCount).
void FillChannelLayout(AudioChannelLayout *layout) {
    layout->mChannelLayoutTag = kAudioChannelLayoutTag_DiscreteInOrder | gChannelCount;
    layout->mChannelBitmap = 0;
    layout->mNumberChannelDescriptions = 0;
}

Boolean Plugin_HasProperty(AudioServerPlugInDriverRef, AudioObjectID inObjectID, pid_t, const AudioObjectPropertyAddress *inAddress) {
    if (!inAddress) return false;

    if (IsPlugInObject(inObjectID)) {
        switch (inAddress->mSelector) {
            case kAudioObjectPropertyBaseClass:
            case kAudioObjectPropertyClass:
            case kAudioObjectPropertyOwner:
            case kAudioObjectPropertyName:
            case kAudioObjectPropertyManufacturer:
            case kAudioObjectPropertyOwnedObjects:
            case kAudioPlugInPropertyDeviceList:
            case kAudioPlugInPropertyTranslateUIDToDevice:
            case kAudioPlugInPropertyResourceBundle:
                return true;
            default:
                return false;
        }
    }
    if (IsDeviceObject(inObjectID)) {
        switch (inAddress->mSelector) {
            case kAudioObjectPropertyBaseClass:
            case kAudioObjectPropertyClass:
            case kAudioObjectPropertyOwner:
            case kAudioObjectPropertyName:
            case kAudioObjectPropertyManufacturer:
            case kAudioObjectPropertyOwnedObjects:
            case kAudioObjectPropertyElementName:
            case kAudioDevicePropertyDeviceUID:
            case kAudioDevicePropertyModelUID:
            case kAudioDevicePropertyTransportType:
            case kAudioDevicePropertyRelatedDevices:
            case kAudioDevicePropertyClockDomain:
            case kAudioDevicePropertyDeviceIsAlive:
            case kAudioDevicePropertyDeviceIsRunning:
            case kAudioDevicePropertyDeviceCanBeDefaultDevice:
            case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
            case kAudioDevicePropertyIsHidden:
            case kAudioDevicePropertyZeroTimeStampPeriod:
            case kAudioDevicePropertyStreams:
            case kAudioObjectPropertyControlList:
            case kAudioDevicePropertyNominalSampleRate:
            case kAudioDevicePropertyAvailableNominalSampleRates:
            case kAudioDevicePropertySafetyOffset:
            case kAudioDevicePropertyLatency:
            case kAudioDevicePropertyPreferredChannelsForStereo:
            case kAudioDevicePropertyPreferredChannelLayout:
                return true;
            default:
                return false;
        }
    }
    if (IsStreamObject(inObjectID)) {
        switch (inAddress->mSelector) {
            case kAudioObjectPropertyBaseClass:
            case kAudioObjectPropertyClass:
            case kAudioObjectPropertyOwner:
            case kAudioObjectPropertyName:
            case kAudioStreamPropertyDirection:
            case kAudioStreamPropertyTerminalType:
            case kAudioStreamPropertyStartingChannel:
            case kAudioStreamPropertyLatency:
            case kAudioStreamPropertyIsActive:
            case kAudioStreamPropertyVirtualFormat:
            case kAudioStreamPropertyPhysicalFormat:
            case kAudioStreamPropertyAvailableVirtualFormats:
            case kAudioStreamPropertyAvailablePhysicalFormats:
                return true;
            default:
                return false;
        }
    }
    return false;
}

OSStatus Plugin_IsPropertySettable(AudioServerPlugInDriverRef, AudioObjectID inObjectID, pid_t, const AudioObjectPropertyAddress *inAddress, Boolean *outIsSettable) {
    if (!outIsSettable || !inAddress) return kAudioHardwareIllegalOperationError;
    bool settable = false;
    if (IsDeviceObject(inObjectID) && inAddress->mSelector == kAudioDevicePropertyNominalSampleRate) settable = true;
    if (IsStreamObject(inObjectID) &&
        (inAddress->mSelector == kAudioStreamPropertyVirtualFormat || inAddress->mSelector == kAudioStreamPropertyPhysicalFormat)) settable = true;
    *outIsSettable = settable;
    return kAudioHardwareNoError;
}

OSStatus Plugin_GetPropertyDataSize(AudioServerPlugInDriverRef, AudioObjectID inObjectID, pid_t, const AudioObjectPropertyAddress *inAddress, UInt32, const void *, UInt32 *outDataSize) {
    if (!outDataSize || !inAddress) return kAudioHardwareIllegalOperationError;

    if (IsPlugInObject(inObjectID)) {
        switch (inAddress->mSelector) {
            case kAudioObjectPropertyBaseClass:
            case kAudioObjectPropertyClass:
                *outDataSize = sizeof(AudioClassID); return kAudioHardwareNoError;
            case kAudioObjectPropertyOwner:
                *outDataSize = sizeof(AudioObjectID); return kAudioHardwareNoError;
            case kAudioObjectPropertyName:
            case kAudioObjectPropertyManufacturer:
            case kAudioPlugInPropertyResourceBundle:
                *outDataSize = sizeof(CFStringRef); return kAudioHardwareNoError;
            case kAudioObjectPropertyOwnedObjects:
            case kAudioPlugInPropertyDeviceList:
                *outDataSize = sizeof(AudioObjectID); return kAudioHardwareNoError;
            case kAudioPlugInPropertyTranslateUIDToDevice:
                *outDataSize = sizeof(AudioObjectID); return kAudioHardwareNoError;
            default:
                *outDataSize = 0; return kAudioHardwareUnknownPropertyError;
        }
    }
    if (IsDeviceObject(inObjectID)) {
        switch (inAddress->mSelector) {
            case kAudioObjectPropertyBaseClass:
            case kAudioObjectPropertyClass:
                *outDataSize = sizeof(AudioClassID); return kAudioHardwareNoError;
            case kAudioObjectPropertyOwner:
            case kAudioDevicePropertyClockDomain:
            case kAudioDevicePropertyTransportType:
            case kAudioDevicePropertyDeviceIsAlive:
            case kAudioDevicePropertyDeviceIsRunning:
            case kAudioDevicePropertyDeviceCanBeDefaultDevice:
            case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
            case kAudioDevicePropertyIsHidden:
            case kAudioDevicePropertySafetyOffset:
            case kAudioDevicePropertyLatency:
                *outDataSize = sizeof(UInt32); return kAudioHardwareNoError;
            case kAudioObjectPropertyName:
            case kAudioObjectPropertyManufacturer:
            case kAudioObjectPropertyElementName:
            case kAudioDevicePropertyDeviceUID:
            case kAudioDevicePropertyModelUID:
                *outDataSize = sizeof(CFStringRef); return kAudioHardwareNoError;
            case kAudioObjectPropertyOwnedObjects:
                // Input scope has no streams; caller (HAL) passes scope via
                // qualifier normally but our single stream is output-only —
                // report the stream as owned regardless of scope filter here.
                *outDataSize = sizeof(AudioObjectID); return kAudioHardwareNoError;
            case kAudioDevicePropertyRelatedDevices:
                *outDataSize = sizeof(AudioObjectID); return kAudioHardwareNoError;
            case kAudioDevicePropertyStreams:
                *outDataSize = (inAddress->mScope == kAudioObjectPropertyScopeInput) ? 0 : sizeof(AudioObjectID);
                return kAudioHardwareNoError;
            case kAudioObjectPropertyControlList:
                *outDataSize = 0; return kAudioHardwareNoError;
            case kAudioDevicePropertyZeroTimeStampPeriod:
                *outDataSize = sizeof(UInt32); return kAudioHardwareNoError;
            case kAudioDevicePropertyNominalSampleRate:
                *outDataSize = sizeof(Float64); return kAudioHardwareNoError;
            case kAudioDevicePropertyAvailableNominalSampleRates:
                *outDataSize = sizeof(AudioValueRange) * kSupportedSampleRateCount; return kAudioHardwareNoError;
            case kAudioDevicePropertyPreferredChannelsForStereo:
                *outDataSize = sizeof(UInt32) * 2; return kAudioHardwareNoError;
            case kAudioDevicePropertyPreferredChannelLayout:
                *outDataSize = ChannelLayoutSize(0); return kAudioHardwareNoError;
            default:
                *outDataSize = 0; return kAudioHardwareUnknownPropertyError;
        }
    }
    if (IsStreamObject(inObjectID)) {
        switch (inAddress->mSelector) {
            case kAudioObjectPropertyBaseClass:
            case kAudioObjectPropertyClass:
                *outDataSize = sizeof(AudioClassID); return kAudioHardwareNoError;
            case kAudioObjectPropertyOwner:
                *outDataSize = sizeof(AudioObjectID); return kAudioHardwareNoError;
            case kAudioObjectPropertyName:
                *outDataSize = sizeof(CFStringRef); return kAudioHardwareNoError;
            case kAudioStreamPropertyDirection:
            case kAudioStreamPropertyTerminalType:
            case kAudioStreamPropertyStartingChannel:
            case kAudioStreamPropertyLatency:
            case kAudioStreamPropertyIsActive:
                *outDataSize = sizeof(UInt32); return kAudioHardwareNoError;
            case kAudioStreamPropertyVirtualFormat:
            case kAudioStreamPropertyPhysicalFormat:
                *outDataSize = sizeof(AudioStreamBasicDescription); return kAudioHardwareNoError;
            case kAudioStreamPropertyAvailableVirtualFormats:
            case kAudioStreamPropertyAvailablePhysicalFormats:
                *outDataSize = sizeof(AudioStreamRangedDescription) * kSupportedSampleRateCount; return kAudioHardwareNoError;
            default:
                *outDataSize = 0; return kAudioHardwareUnknownPropertyError;
        }
    }
    *outDataSize = 0;
    return kAudioHardwareBadObjectError;
}

OSStatus Plugin_GetPropertyData(AudioServerPlugInDriverRef, AudioObjectID inObjectID, pid_t, const AudioObjectPropertyAddress *inAddress, UInt32 inQualifierDataSize, const void *inQualifierData, UInt32 inDataSize, UInt32 *outDataSize, void *outData) {
    if (!inAddress || !outData || !outDataSize) return kAudioHardwareIllegalOperationError;

    if (IsPlugInObject(inObjectID)) {
        switch (inAddress->mSelector) {
            case kAudioObjectPropertyBaseClass:
                if (inDataSize < sizeof(AudioClassID)) return kAudioHardwareBadPropertySizeError;
                *static_cast<AudioClassID *>(outData) = kAudioObjectClassID;
                *outDataSize = sizeof(AudioClassID);
                return kAudioHardwareNoError;
            case kAudioObjectPropertyClass:
                if (inDataSize < sizeof(AudioClassID)) return kAudioHardwareBadPropertySizeError;
                *static_cast<AudioClassID *>(outData) = kAudioPlugInClassID;
                *outDataSize = sizeof(AudioClassID);
                return kAudioHardwareNoError;
            case kAudioObjectPropertyOwner:
                if (inDataSize < sizeof(AudioObjectID)) return kAudioHardwareBadPropertySizeError;
                *static_cast<AudioObjectID *>(outData) = kAudioObjectUnknown;
                *outDataSize = sizeof(AudioObjectID);
                return kAudioHardwareNoError;
            case kAudioObjectPropertyName:
                if (inDataSize < sizeof(CFStringRef)) return kAudioHardwareBadPropertySizeError;
                *static_cast<CFStringRef *>(outData) = CopyCFString(kPlugInBundleName);
                *outDataSize = sizeof(CFStringRef);
                return kAudioHardwareNoError;
            case kAudioObjectPropertyManufacturer:
                if (inDataSize < sizeof(CFStringRef)) return kAudioHardwareBadPropertySizeError;
                *static_cast<CFStringRef *>(outData) = CopyCFString(kManufacturer);
                *outDataSize = sizeof(CFStringRef);
                return kAudioHardwareNoError;
            case kAudioObjectPropertyOwnedObjects:
            case kAudioPlugInPropertyDeviceList:
                if (inDataSize < sizeof(AudioObjectID)) return kAudioHardwareBadPropertySizeError;
                *static_cast<AudioObjectID *>(outData) = kDeviceObjectID;
                *outDataSize = sizeof(AudioObjectID);
                return kAudioHardwareNoError;
            case kAudioPlugInPropertyTranslateUIDToDevice: {
                if (inDataSize < sizeof(AudioObjectID)) return kAudioHardwareBadPropertySizeError;
                // The qualifier points at a CFStringRef; it is not the CFStringRef itself.
                if (inQualifierDataSize < sizeof(CFStringRef) || !inQualifierData) return kAudioHardwareBadPropertySizeError;
                CFStringRef uid = *static_cast<const CFStringRef *>(inQualifierData);
                AudioObjectID result = kAudioObjectUnknown;
                if (uid && CFEqual(uid, kDeviceUID)) result = kDeviceObjectID;
                *static_cast<AudioObjectID *>(outData) = result;
                *outDataSize = sizeof(AudioObjectID);
                return kAudioHardwareNoError;
            }
            case kAudioPlugInPropertyResourceBundle:
                if (inDataSize < sizeof(CFStringRef)) return kAudioHardwareBadPropertySizeError;
                *static_cast<CFStringRef *>(outData) = CopyCFString(kEmptyString);
                *outDataSize = sizeof(CFStringRef);
                return kAudioHardwareNoError;
            default:
                return kAudioHardwareUnknownPropertyError;
        }
    }

    if (IsDeviceObject(inObjectID)) {
        switch (inAddress->mSelector) {
            case kAudioObjectPropertyBaseClass:
                if (inDataSize < sizeof(AudioClassID)) return kAudioHardwareBadPropertySizeError;
                *static_cast<AudioClassID *>(outData) = kAudioObjectClassID;
                *outDataSize = sizeof(AudioClassID);
                return kAudioHardwareNoError;
            case kAudioObjectPropertyClass:
                if (inDataSize < sizeof(AudioClassID)) return kAudioHardwareBadPropertySizeError;
                *static_cast<AudioClassID *>(outData) = kAudioDeviceClassID;
                *outDataSize = sizeof(AudioClassID);
                return kAudioHardwareNoError;
            case kAudioObjectPropertyOwner:
                if (inDataSize < sizeof(AudioObjectID)) return kAudioHardwareBadPropertySizeError;
                *static_cast<AudioObjectID *>(outData) = kPlugInObjectID;
                *outDataSize = sizeof(AudioObjectID);
                return kAudioHardwareNoError;
            case kAudioObjectPropertyName:
                if (inDataSize < sizeof(CFStringRef)) return kAudioHardwareBadPropertySizeError;
                *static_cast<CFStringRef *>(outData) = CopyCFString(kDeviceName);
                *outDataSize = sizeof(CFStringRef);
                return kAudioHardwareNoError;
            case kAudioObjectPropertyManufacturer:
                if (inDataSize < sizeof(CFStringRef)) return kAudioHardwareBadPropertySizeError;
                *static_cast<CFStringRef *>(outData) = CopyCFString(kManufacturer);
                *outDataSize = sizeof(CFStringRef);
                return kAudioHardwareNoError;
            case kAudioObjectPropertyElementName:
                if (inDataSize < sizeof(CFStringRef)) return kAudioHardwareBadPropertySizeError;
                *static_cast<CFStringRef *>(outData) = CopyCFString(kEmptyString);
                *outDataSize = sizeof(CFStringRef);
                return kAudioHardwareNoError;
            case kAudioObjectPropertyOwnedObjects:
                if (inDataSize < sizeof(AudioObjectID)) return kAudioHardwareBadPropertySizeError;
                *static_cast<AudioObjectID *>(outData) = kStreamObjectID;
                *outDataSize = sizeof(AudioObjectID);
                return kAudioHardwareNoError;
            case kAudioDevicePropertyDeviceUID:
                if (inDataSize < sizeof(CFStringRef)) return kAudioHardwareBadPropertySizeError;
                *static_cast<CFStringRef *>(outData) = CopyCFString(kDeviceUID);
                *outDataSize = sizeof(CFStringRef);
                return kAudioHardwareNoError;
            case kAudioDevicePropertyModelUID:
                if (inDataSize < sizeof(CFStringRef)) return kAudioHardwareBadPropertySizeError;
                *static_cast<CFStringRef *>(outData) = CopyCFString(kModelUID);
                *outDataSize = sizeof(CFStringRef);
                return kAudioHardwareNoError;
            case kAudioDevicePropertyTransportType:
                if (inDataSize < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
                *static_cast<UInt32 *>(outData) = kAudioDeviceTransportTypeVirtual;
                *outDataSize = sizeof(UInt32);
                return kAudioHardwareNoError;
            case kAudioDevicePropertyRelatedDevices:
                if (inDataSize < sizeof(AudioObjectID)) return kAudioHardwareBadPropertySizeError;
                *static_cast<AudioObjectID *>(outData) = kDeviceObjectID;
                *outDataSize = sizeof(AudioObjectID);
                return kAudioHardwareNoError;
            case kAudioDevicePropertyClockDomain:
                if (inDataSize < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
                *static_cast<UInt32 *>(outData) = 0;
                *outDataSize = sizeof(UInt32);
                return kAudioHardwareNoError;
            case kAudioDevicePropertyDeviceIsAlive:
                if (inDataSize < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
                *static_cast<UInt32 *>(outData) = 1;
                *outDataSize = sizeof(UInt32);
                return kAudioHardwareNoError;
            case kAudioDevicePropertyDeviceIsRunning:
                if (inDataSize < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
                pthread_mutex_lock(&gStateMutex);
                *static_cast<UInt32 *>(outData) = gDeviceIsRunning ? 1 : 0;
                pthread_mutex_unlock(&gStateMutex);
                *outDataSize = sizeof(UInt32);
                return kAudioHardwareNoError;
            case kAudioDevicePropertyDeviceCanBeDefaultDevice:
            case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
                if (inDataSize < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
                *static_cast<UInt32 *>(outData) = 1;
                *outDataSize = sizeof(UInt32);
                return kAudioHardwareNoError;
            case kAudioDevicePropertyIsHidden:
                if (inDataSize < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
                *static_cast<UInt32 *>(outData) = 0;
                *outDataSize = sizeof(UInt32);
                return kAudioHardwareNoError;
            case kAudioDevicePropertyStreams:
                if (inAddress->mScope == kAudioObjectPropertyScopeInput) {
                    *outDataSize = 0;
                    return kAudioHardwareNoError;
                }
                if (inDataSize < sizeof(AudioObjectID)) return kAudioHardwareBadPropertySizeError;
                *static_cast<AudioObjectID *>(outData) = kStreamObjectID;
                *outDataSize = sizeof(AudioObjectID);
                return kAudioHardwareNoError;
            case kAudioObjectPropertyControlList:
                *outDataSize = 0;
                return kAudioHardwareNoError;
            case kAudioDevicePropertyZeroTimeStampPeriod:
                if (inDataSize < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
                *static_cast<UInt32 *>(outData) = kZeroTimeStampPeriod;
                *outDataSize = sizeof(UInt32);
                return kAudioHardwareNoError;
            case kAudioDevicePropertyNominalSampleRate:
                if (inDataSize < sizeof(Float64)) return kAudioHardwareBadPropertySizeError;
                pthread_mutex_lock(&gStateMutex);
                *static_cast<Float64 *>(outData) = gSampleRate;
                pthread_mutex_unlock(&gStateMutex);
                *outDataSize = sizeof(Float64);
                return kAudioHardwareNoError;
            case kAudioDevicePropertyAvailableNominalSampleRates: {
                UInt32 want = static_cast<UInt32>(kSupportedSampleRateCount) * sizeof(AudioValueRange);
                UInt32 n = inDataSize / sizeof(AudioValueRange);
                if (n < 1) return kAudioHardwareBadPropertySizeError;
                if (n > static_cast<UInt32>(kSupportedSampleRateCount)) n = kSupportedSampleRateCount;
                AudioValueRange *ranges = static_cast<AudioValueRange *>(outData);
                for (UInt32 i = 0; i < n; ++i) {
                    ranges[i].mMinimum = kSupportedSampleRates[i];
                    ranges[i].mMaximum = kSupportedSampleRates[i];
                }
                *outDataSize = n * sizeof(AudioValueRange);
                (void)want;
                return kAudioHardwareNoError;
            }
            case kAudioDevicePropertySafetyOffset:
            case kAudioDevicePropertyLatency:
                if (inDataSize < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
                *static_cast<UInt32 *>(outData) = 0;
                *outDataSize = sizeof(UInt32);
                return kAudioHardwareNoError;
            case kAudioDevicePropertyPreferredChannelsForStereo:
                if (inDataSize < sizeof(UInt32) * 2) return kAudioHardwareBadPropertySizeError;
                static_cast<UInt32 *>(outData)[0] = 1;
                static_cast<UInt32 *>(outData)[1] = 2;
                *outDataSize = sizeof(UInt32) * 2;
                return kAudioHardwareNoError;
            case kAudioDevicePropertyPreferredChannelLayout: {
                UInt32 needed = ChannelLayoutSize(0);
                if (inDataSize < needed) return kAudioHardwareBadPropertySizeError;
                pthread_mutex_lock(&gStateMutex);
                FillChannelLayout(static_cast<AudioChannelLayout *>(outData));
                pthread_mutex_unlock(&gStateMutex);
                *outDataSize = needed;
                return kAudioHardwareNoError;
            }
            default:
                return kAudioHardwareUnknownPropertyError;
        }
    }

    if (IsStreamObject(inObjectID)) {
        switch (inAddress->mSelector) {
            case kAudioObjectPropertyBaseClass:
                if (inDataSize < sizeof(AudioClassID)) return kAudioHardwareBadPropertySizeError;
                *static_cast<AudioClassID *>(outData) = kAudioObjectClassID;
                *outDataSize = sizeof(AudioClassID);
                return kAudioHardwareNoError;
            case kAudioObjectPropertyClass:
                if (inDataSize < sizeof(AudioClassID)) return kAudioHardwareBadPropertySizeError;
                *static_cast<AudioClassID *>(outData) = kAudioStreamClassID;
                *outDataSize = sizeof(AudioClassID);
                return kAudioHardwareNoError;
            case kAudioObjectPropertyOwner:
                if (inDataSize < sizeof(AudioObjectID)) return kAudioHardwareBadPropertySizeError;
                *static_cast<AudioObjectID *>(outData) = kDeviceObjectID;
                *outDataSize = sizeof(AudioObjectID);
                return kAudioHardwareNoError;
            case kAudioObjectPropertyName:
                if (inDataSize < sizeof(CFStringRef)) return kAudioHardwareBadPropertySizeError;
                *static_cast<CFStringRef *>(outData) = CopyCFString(kDeviceName);
                *outDataSize = sizeof(CFStringRef);
                return kAudioHardwareNoError;
            case kAudioStreamPropertyDirection:
                if (inDataSize < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
                *static_cast<UInt32 *>(outData) = 0; // 0 = output
                *outDataSize = sizeof(UInt32);
                return kAudioHardwareNoError;
            case kAudioStreamPropertyTerminalType:
                if (inDataSize < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
                *static_cast<UInt32 *>(outData) = kAudioStreamTerminalTypeSpeaker;
                *outDataSize = sizeof(UInt32);
                return kAudioHardwareNoError;
            case kAudioStreamPropertyStartingChannel:
                if (inDataSize < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
                *static_cast<UInt32 *>(outData) = 1;
                *outDataSize = sizeof(UInt32);
                return kAudioHardwareNoError;
            case kAudioStreamPropertyLatency:
                if (inDataSize < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
                *static_cast<UInt32 *>(outData) = 0;
                *outDataSize = sizeof(UInt32);
                return kAudioHardwareNoError;
            case kAudioStreamPropertyIsActive:
                if (inDataSize < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
                *static_cast<UInt32 *>(outData) = 1;
                *outDataSize = sizeof(UInt32);
                return kAudioHardwareNoError;
            case kAudioStreamPropertyVirtualFormat:
            case kAudioStreamPropertyPhysicalFormat:
                if (inDataSize < sizeof(AudioStreamBasicDescription)) return kAudioHardwareBadPropertySizeError;
                pthread_mutex_lock(&gStateMutex);
                *static_cast<AudioStreamBasicDescription *>(outData) = StreamFormat();
                pthread_mutex_unlock(&gStateMutex);
                *outDataSize = sizeof(AudioStreamBasicDescription);
                return kAudioHardwareNoError;
            case kAudioStreamPropertyAvailableVirtualFormats:
            case kAudioStreamPropertyAvailablePhysicalFormats: {
                UInt32 n = inDataSize / sizeof(AudioStreamRangedDescription);
                if (n < 1) return kAudioHardwareBadPropertySizeError;
                if (n > static_cast<UInt32>(kSupportedSampleRateCount)) n = kSupportedSampleRateCount;
                AudioStreamRangedDescription *descs = static_cast<AudioStreamRangedDescription *>(outData);
                pthread_mutex_lock(&gStateMutex);
                UInt32 channels = gChannelCount;
                pthread_mutex_unlock(&gStateMutex);
                for (UInt32 i = 0; i < n; ++i) {
                    AudioStreamBasicDescription fmt = {};
                    fmt.mSampleRate = kSupportedSampleRates[i];
                    fmt.mFormatID = kAudioFormatLinearPCM;
                    fmt.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
                    fmt.mBytesPerPacket = sizeof(Float32) * channels;
                    fmt.mFramesPerPacket = 1;
                    fmt.mBytesPerFrame = sizeof(Float32) * channels;
                    fmt.mChannelsPerFrame = channels;
                    fmt.mBitsPerChannel = 32;
                    descs[i].mFormat = fmt;
                    descs[i].mSampleRateRange.mMinimum = kSupportedSampleRates[i];
                    descs[i].mSampleRateRange.mMaximum = kSupportedSampleRates[i];
                }
                *outDataSize = n * sizeof(AudioStreamRangedDescription);
                return kAudioHardwareNoError;
            }
            default:
                return kAudioHardwareUnknownPropertyError;
        }
    }
    return kAudioHardwareBadObjectError;
}

OSStatus Plugin_SetPropertyData(AudioServerPlugInDriverRef, AudioObjectID inObjectID, pid_t, const AudioObjectPropertyAddress *inAddress, UInt32, const void *, UInt32 inDataSize, const void *inData) {
    if (!inAddress) return kAudioHardwareIllegalOperationError;

    Float64 requestedRate = 0;
    if (IsDeviceObject(inObjectID) && inAddress->mSelector == kAudioDevicePropertyNominalSampleRate) {
        if (inDataSize < sizeof(Float64) || !inData) return kAudioHardwareBadPropertySizeError;
        requestedRate = *static_cast<const Float64 *>(inData);
    } else if (IsStreamObject(inObjectID) &&
               (inAddress->mSelector == kAudioStreamPropertyVirtualFormat || inAddress->mSelector == kAudioStreamPropertyPhysicalFormat)) {
        if (inDataSize < sizeof(AudioStreamBasicDescription) || !inData) return kAudioHardwareBadPropertySizeError;
        requestedRate = static_cast<const AudioStreamBasicDescription *>(inData)->mSampleRate;
    } else {
        return kAudioHardwareUnknownPropertyError;
    }

    if (!SampleRateSupported(requestedRate)) return kAudioHardwareIllegalOperationError;

    // Visible in the app's Settings tab as "最後に DAW から要求されたレート",
    // regardless of whether it changes anything below.
    if (gMeter.shm) gMeter.shm->hostRequestedSampleRate = requestedRate;

    pthread_mutex_lock(&gStateMutex);
    bool alreadyCurrent = std::fabs(gSampleRate - requestedRate) < 0.5;
    if (!alreadyCurrent) {
        gPendingSampleRate = requestedRate;
        gPendingChannelCount = gChannelCount; // no channel change requested here
        gPendingConfigCounter = 0;            // host-initiated, not from the app's shm config
    }
    pthread_mutex_unlock(&gStateMutex);
    if (alreadyCurrent) return kAudioHardwareNoError;

    if (gPlugInHost && gPlugInHost->RequestDeviceConfigurationChange) {
        gPlugInHost->RequestDeviceConfigurationChange(gPlugInHost, kDeviceObjectID, kApplyPendingConfigAction, nullptr);
    }
    return kAudioHardwareNoError;
}

// ---- IO ------------------------------------------------------------------

OSStatus Plugin_StartIO(AudioServerPlugInDriverRef, AudioObjectID, UInt32) {
    pthread_mutex_lock(&gStateMutex);
    gDeviceIsRunning = true;
    gAnchorHostTime = mach_absolute_time();
    RecomputeTicksPerPeriod();
    pthread_mutex_unlock(&gStateMutex);
    if (gMeter.shm) gMeter.shm->isRunning = 1;
    return kAudioHardwareNoError;
}
OSStatus Plugin_StopIO(AudioServerPlugInDriverRef, AudioObjectID, UInt32) {
    pthread_mutex_lock(&gStateMutex);
    gDeviceIsRunning = false;
    pthread_mutex_unlock(&gStateMutex);
    if (gMeter.shm) gMeter.shm->isRunning = 0;
    return kAudioHardwareNoError;
}

OSStatus Plugin_GetZeroTimeStamp(AudioServerPlugInDriverRef, AudioObjectID, UInt32, Float64 *outSampleTime, UInt64 *outHostTime, UInt64 *outSeed) {
    pthread_mutex_lock(&gStateMutex);
    UInt64 anchor = gAnchorHostTime;
    Float64 ticksPerPeriod = gTicksPerPeriod;
    UInt64 seed = gZeroTimeSeed;
    pthread_mutex_unlock(&gStateMutex);

    if (anchor == 0 || ticksPerPeriod <= 0) {
        // IO not started yet; anchor to now so callers get a monotonic value.
        anchor = mach_absolute_time();
    }

    UInt64 now = mach_absolute_time();
    UInt64 elapsedTicks = (now > anchor) ? (now - anchor) : 0;
    UInt64 periodsElapsed = ticksPerPeriod > 0 ? static_cast<UInt64>(elapsedTicks / ticksPerPeriod) : 0;

    Float64 sampleTime = static_cast<Float64>(periodsElapsed) * kZeroTimeStampPeriod;
    UInt64 hostTime = anchor + static_cast<UInt64>(periodsElapsed * ticksPerPeriod);

    if (outSampleTime) *outSampleTime = sampleTime;
    if (outHostTime) *outHostTime = hostTime;
    if (outSeed) *outSeed = seed;
    return kAudioHardwareNoError;
}

OSStatus Plugin_WillDoIOOperation(AudioServerPlugInDriverRef, AudioObjectID, UInt32, UInt32 inOperationID, Boolean *outWillDo, Boolean *outWillDoInPlace) {
    bool willDo = (inOperationID == kAudioServerPlugInIOOperationWriteMix);
    if (outWillDo) *outWillDo = willDo;
    if (outWillDoInPlace) *outWillDoInPlace = true;
    return kAudioHardwareNoError;
}
OSStatus Plugin_BeginIOOperation(AudioServerPlugInDriverRef, AudioObjectID, UInt32, UInt32, UInt32, const AudioServerPlugInIOCycleInfo *) { return kAudioHardwareNoError; }
OSStatus Plugin_EndIOOperation(AudioServerPlugInDriverRef, AudioObjectID, UInt32, UInt32, UInt32, const AudioServerPlugInIOCycleInfo *) { return kAudioHardwareNoError; }

OSStatus Plugin_DoIOOperation(AudioServerPlugInDriverRef, AudioObjectID, AudioObjectID, UInt32 /*inClientID*/, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo *, void *ioMainBuffer, void *) {
    if (gMeter.shm) gMeter.shm->ioBufferFrameSize = inIOBufferFrameSize; // host-decided, record regardless of operation
    if (inOperationID != kAudioServerPlugInIOOperationWriteMix) return kAudioHardwareNoError;
    if (!ioMainBuffer) return kAudioHardwareNoError;
    UInt32 channels = gChannelCount.load(std::memory_order_relaxed);
    const Float32 *samples = static_cast<const Float32 *>(ioMainBuffer);
    gMeter.publish(samples, inIOBufferFrameSize, channels, gSampleRate);
    return kAudioHardwareNoError;
}

} // namespace

// ---- CFPlugIn factory entry point ---------------------------------------

extern "C" void *VirtualAudioDevicePlugin_Factory(CFAllocatorRef, CFUUIDRef inRequestedTypeUUID) {
    if (!CFEqual(inRequestedTypeUUID, kAudioServerPlugInTypeUUID)) return nullptr;
    return gDriverRef;
}
