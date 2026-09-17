// VirtualAudioDevicePlugin.cpp
//
// Minimal Core Audio AudioServerPlugIn (HAL Plugin) implementing a single
// virtual input device with kChannelCount input channels. Written from
// scratch against <CoreAudio/AudioServerPlugIn.h> (no BlackHole/existing
// plugin code reused), following the plugin-host COM-style calling
// convention Apple's HAL requires (a "class" is a struct whose first member
// is an AudioServerPlugInDriverInterface* vtable, dispatched exactly like a
// COM object; there is no C++ vtable / RTTI involved).
//
// Scope for this milestone: registers as a system device, reports
// kChannelCount input channels, accepts IOProc start/stop and
// DoIOOperation calls, and on every IO cycle computes an abs-peak per
// channel and publishes it into the POSIX shared-memory meter struct
// (Shared/MeterShm.h) for the visualizer app to read. No output channels,
// no clock drift compensation, no control features (mute/volume) — those
// are listed as follow-up work in the README.
//
// ponytail: kChannelCount defaults to 16 for the first bring-up/build
// verification pass; the README documents the 16 -> 128 change (one
// constant + IOBufferFrameSize math) as the next step, not implemented
// here to keep this milestone buildable/testable quickly.

#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreFoundation/CoreFoundation.h>
#include <mach/mach_time.h>
#include <pthread.h>
#include <fcntl.h>
#include <sys/mman.h>
#include <unistd.h>
#include <cmath>
#include <cstring>
#include <cstdio>

#include "../../Shared/MeterShm.h"

namespace {

constexpr UInt32 kChannelCount = 16; // see file header re: 16 -> 128
constexpr Float64 kSampleRate = 48000.0;
constexpr UInt32 kRingFrames = 4096;

const AudioObjectID kPlugInObjectID = kAudioObjectPlugInObject;
const AudioObjectID kDeviceObjectID = 2;
const AudioObjectID kStreamObjectID = 3;

CFStringRef kDeviceUID = CFSTR("com.daitomanabe.virtualaudiointerface.device");
CFStringRef kDeviceName = CFSTR("Virtual Audio Interface (128ch)");
CFStringRef kManufacturer = CFSTR("daitomanabe");

// ---- shared memory meter publisher ------------------------------------

struct MeterPublisher {
    VAIMeterShm *shm = nullptr;
    int fd = -1;

    void open() {
        fd = shm_open(VAI_SHM_NAME, O_CREAT | O_RDWR, 0666);
        if (fd < 0) return;
        ftruncate(fd, sizeof(VAIMeterShm));
        void *p = mmap(nullptr, sizeof(VAIMeterShm), PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
        if (p == MAP_FAILED) { shm = nullptr; return; }
        shm = reinterpret_cast<VAIMeterShm *>(p);
        shm->magic = VAI_SHM_MAGIC;
        shm->channelCount = kChannelCount;
        shm->updateCounter = 0;
        memset(shm->peakLevel, 0, sizeof(shm->peakLevel));
    }

    void publish(const Float32 *interleaved, UInt32 frames, UInt32 channels) {
        if (!shm) return;
        for (UInt32 ch = 0; ch < channels && ch < VAI_MAX_CHANNELS; ++ch) {
            float peak = 0.f;
            for (UInt32 f = 0; f < frames; ++f) {
                float v = std::fabs(interleaved[f * channels + ch]);
                if (v > peak) peak = v;
            }
            shm->peakLevel[ch] = peak;
        }
        shm->updateCounter++;
    }
};

MeterPublisher gMeter;

// ---- ring buffer that IOProc reads live audio into ---------------------
// ponytail: fixed-size float ring, single producer (DoIOOperation writes
// the input buffer straight through). No consumer besides the meter today;
// add a real reader if the app ever needs to record/monitor the audio
// itself, not just its level.
float gRing[kRingFrames * kChannelCount];

// ---- plugin-wide state ---------------------------------------------------

pthread_mutex_t gStateMutex = PTHREAD_MUTEX_INITIALIZER;
UInt64 gIOProcID = 0; // opaque token we hand back to the HAL
bool gDeviceIsRunning = false;

// =========================================================================
// AudioServerPlugInDriverInterface implementation
// =========================================================================

HRESULT Plugin_QueryInterface(void *inDriver, REFIID inUUID, LPVOID *outInterface);
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

HRESULT Plugin_QueryInterface(void *inDriver, REFIID inUUID, LPVOID *outInterface) {
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

OSStatus Plugin_Initialize(AudioServerPlugInDriverRef, AudioServerPlugInHostRef inHost) {
    gPlugInHost = inHost;
    gMeter.open();
    return kAudioHardwareNoError;
}

OSStatus Plugin_CreateDevice(AudioServerPlugInDriverRef, CFDictionaryRef, const AudioServerPlugInClientInfo *, AudioObjectID *outDeviceObjectID) {
    if (outDeviceObjectID) *outDeviceObjectID = kDeviceObjectID;
    return kAudioHardwareNoError; // dynamic device creation unsupported; we expose one static device
}
OSStatus Plugin_DestroyDevice(AudioServerPlugInDriverRef, AudioObjectID) { return kAudioHardwareNoError; }
OSStatus Plugin_AddDeviceClient(AudioServerPlugInDriverRef, AudioObjectID, const AudioServerPlugInClientInfo *) { return kAudioHardwareNoError; }
OSStatus Plugin_RemoveDeviceClient(AudioServerPlugInDriverRef, AudioObjectID, const AudioServerPlugInClientInfo *) { return kAudioHardwareNoError; }
OSStatus Plugin_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef, AudioObjectID, UInt64, void *) { return kAudioHardwareNoError; }
OSStatus Plugin_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef, AudioObjectID, UInt64, void *) { return kAudioHardwareNoError; }

// ---- property helpers ------------------------------------------------

CFStringRef CopyCFString(CFStringRef s) { return static_cast<CFStringRef>(CFRetain(s)); }

Boolean Plugin_HasProperty(AudioServerPlugInDriverRef, AudioObjectID inObjectID, pid_t, const AudioObjectPropertyAddress *inAddress) {
    if (!inAddress) return false;
    switch (inAddress->mSelector) {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
        case kAudioObjectPropertyOwner:
        case kAudioObjectPropertyName:
        case kAudioObjectPropertyManufacturer:
        case kAudioObjectPropertyOwnedObjects:
        case kAudioDevicePropertyDeviceUID:
        case kAudioDevicePropertyStreams:
        case kAudioDevicePropertyNominalSampleRate:
        case kAudioDevicePropertyAvailableNominalSampleRates:
        case kAudioDevicePropertyDeviceIsAlive:
        case kAudioDevicePropertyIsHidden:
        case kAudioDevicePropertySafetyOffset:
        case kAudioDevicePropertyLatency:
        case kAudioStreamPropertyDirection:
        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat:
            return true;
        default:
            return inObjectID == kPlugInObjectID && inAddress->mSelector == kAudioObjectPropertyOwnedObjects;
    }
}

OSStatus Plugin_IsPropertySettable(AudioServerPlugInDriverRef, AudioObjectID, pid_t, const AudioObjectPropertyAddress *, Boolean *outIsSettable) {
    if (outIsSettable) *outIsSettable = false; // read-only for this milestone
    return kAudioHardwareNoError;
}

AudioStreamBasicDescription StreamFormat() {
    AudioStreamBasicDescription fmt = {};
    fmt.mSampleRate = kSampleRate;
    fmt.mFormatID = kAudioFormatLinearPCM;
    fmt.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
    fmt.mBytesPerPacket = sizeof(Float32) * kChannelCount;
    fmt.mFramesPerPacket = 1;
    fmt.mBytesPerFrame = sizeof(Float32) * kChannelCount;
    fmt.mChannelsPerFrame = kChannelCount;
    fmt.mBitsPerChannel = 32;
    return fmt;
}

OSStatus Plugin_GetPropertyDataSize(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientPID, const AudioObjectPropertyAddress *inAddress, UInt32 inQualifierDataSize, const void *inQualifierData, UInt32 *outDataSize) {
    if (!outDataSize) return kAudioHardwareIllegalOperationError;
    switch (inAddress->mSelector) {
        case kAudioObjectPropertyOwnedObjects:
            *outDataSize = (inObjectID == kPlugInObjectID) ? sizeof(AudioObjectID) : (inObjectID == kDeviceObjectID ? sizeof(AudioObjectID) : 0);
            return kAudioHardwareNoError;
        case kAudioDevicePropertyStreams:
            *outDataSize = sizeof(AudioObjectID);
            return kAudioHardwareNoError;
        case kAudioDevicePropertyAvailableNominalSampleRates:
            *outDataSize = sizeof(AudioValueRange);
            return kAudioHardwareNoError;
        case kAudioObjectPropertyName:
        case kAudioObjectPropertyManufacturer:
        case kAudioDevicePropertyDeviceUID:
            *outDataSize = sizeof(CFStringRef);
            return kAudioHardwareNoError;
        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat:
            *outDataSize = sizeof(AudioStreamBasicDescription);
            return kAudioHardwareNoError;
        case kAudioDevicePropertyNominalSampleRate:
            *outDataSize = sizeof(Float64);
            return kAudioHardwareNoError;
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
        case kAudioObjectPropertyOwner:
        case kAudioDevicePropertyDeviceIsAlive:
        case kAudioDevicePropertyIsHidden:
        case kAudioDevicePropertySafetyOffset:
        case kAudioDevicePropertyLatency:
        case kAudioStreamPropertyDirection:
            *outDataSize = sizeof(UInt32);
            return kAudioHardwareNoError;
        default:
            *outDataSize = 0;
            return kAudioHardwareUnknownPropertyError;
    }
}

OSStatus Plugin_GetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientPID, const AudioObjectPropertyAddress *inAddress, UInt32 inQualifierDataSize, const void *inQualifierData, UInt32 inDataSize, UInt32 *outDataSize, void *outData) {
    switch (inAddress->mSelector) {
        case kAudioObjectPropertyBaseClass:
            *static_cast<AudioClassID *>(outData) = (inObjectID == kDeviceObjectID) ? kAudioDeviceClassID : kAudioObjectClassID;
            *outDataSize = sizeof(AudioClassID);
            return kAudioHardwareNoError;
        case kAudioObjectPropertyClass:
            *static_cast<AudioClassID *>(outData) =
                (inObjectID == kPlugInObjectID) ? kAudioPlugInClassID :
                (inObjectID == kDeviceObjectID) ? kAudioDeviceClassID : kAudioStreamClassID;
            *outDataSize = sizeof(AudioClassID);
            return kAudioHardwareNoError;
        case kAudioObjectPropertyOwner:
            *static_cast<AudioObjectID *>(outData) = (inObjectID == kDeviceObjectID) ? kPlugInObjectID : kDeviceObjectID;
            *outDataSize = sizeof(AudioObjectID);
            return kAudioHardwareNoError;
        case kAudioObjectPropertyName:
            *static_cast<CFStringRef *>(outData) = CopyCFString(kDeviceName);
            *outDataSize = sizeof(CFStringRef);
            return kAudioHardwareNoError;
        case kAudioObjectPropertyManufacturer:
            *static_cast<CFStringRef *>(outData) = CopyCFString(kManufacturer);
            *outDataSize = sizeof(CFStringRef);
            return kAudioHardwareNoError;
        case kAudioObjectPropertyOwnedObjects:
            if (inObjectID == kPlugInObjectID) {
                *static_cast<AudioObjectID *>(outData) = kDeviceObjectID;
            } else {
                *static_cast<AudioObjectID *>(outData) = kStreamObjectID;
            }
            *outDataSize = sizeof(AudioObjectID);
            return kAudioHardwareNoError;
        case kAudioDevicePropertyDeviceUID:
            *static_cast<CFStringRef *>(outData) = CopyCFString(kDeviceUID);
            *outDataSize = sizeof(CFStringRef);
            return kAudioHardwareNoError;
        case kAudioDevicePropertyStreams:
            *static_cast<AudioObjectID *>(outData) = kStreamObjectID;
            *outDataSize = sizeof(AudioObjectID);
            return kAudioHardwareNoError;
        case kAudioDevicePropertyNominalSampleRate:
            *static_cast<Float64 *>(outData) = kSampleRate;
            *outDataSize = sizeof(Float64);
            return kAudioHardwareNoError;
        case kAudioDevicePropertyAvailableNominalSampleRates:
            static_cast<AudioValueRange *>(outData)->mMinimum = kSampleRate;
            static_cast<AudioValueRange *>(outData)->mMaximum = kSampleRate;
            *outDataSize = sizeof(AudioValueRange);
            return kAudioHardwareNoError;
        case kAudioDevicePropertyDeviceIsAlive:
            *static_cast<UInt32 *>(outData) = 1;
            *outDataSize = sizeof(UInt32);
            return kAudioHardwareNoError;
        case kAudioDevicePropertyIsHidden:
            *static_cast<UInt32 *>(outData) = 0;
            *outDataSize = sizeof(UInt32);
            return kAudioHardwareNoError;
        case kAudioDevicePropertySafetyOffset:
        case kAudioDevicePropertyLatency:
            *static_cast<UInt32 *>(outData) = 0;
            *outDataSize = sizeof(UInt32);
            return kAudioHardwareNoError;
        case kAudioStreamPropertyDirection:
            *static_cast<UInt32 *>(outData) = 1; // input
            *outDataSize = sizeof(UInt32);
            return kAudioHardwareNoError;
        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat:
            *static_cast<AudioStreamBasicDescription *>(outData) = StreamFormat();
            *outDataSize = sizeof(AudioStreamBasicDescription);
            return kAudioHardwareNoError;
        default:
            return kAudioHardwareUnknownPropertyError;
    }
}

OSStatus Plugin_SetPropertyData(AudioServerPlugInDriverRef, AudioObjectID, pid_t, const AudioObjectPropertyAddress *, UInt32, const void *, UInt32, const void *) {
    return kAudioHardwareUnsupportedOperationError; // milestone is read-only
}

// ---- IO ------------------------------------------------------------------

OSStatus Plugin_StartIO(AudioServerPlugInDriverRef, AudioObjectID, UInt32) {
    pthread_mutex_lock(&gStateMutex);
    gDeviceIsRunning = true;
    pthread_mutex_unlock(&gStateMutex);
    return kAudioHardwareNoError;
}
OSStatus Plugin_StopIO(AudioServerPlugInDriverRef, AudioObjectID, UInt32) {
    pthread_mutex_lock(&gStateMutex);
    gDeviceIsRunning = false;
    pthread_mutex_unlock(&gStateMutex);
    return kAudioHardwareNoError;
}

OSStatus Plugin_GetZeroTimeStamp(AudioServerPlugInDriverRef, AudioObjectID, UInt32, Float64 *outSampleTime, UInt64 *outHostTime, UInt64 *outSeed) {
    static UInt64 seed = 1;
    if (outSampleTime) *outSampleTime = 0;
    if (outHostTime) *outHostTime = mach_absolute_time();
    if (outSeed) *outSeed = seed;
    return kAudioHardwareNoError;
}

OSStatus Plugin_WillDoIOOperation(AudioServerPlugInDriverRef, AudioObjectID, UInt32, UInt32 inOperationID, Boolean *outWillDo, Boolean *outWillDoInPlace) {
    bool willDo = (inOperationID == kAudioServerPlugInIOOperationReadInput);
    if (outWillDo) *outWillDo = willDo;
    if (outWillDoInPlace) *outWillDoInPlace = true;
    return kAudioHardwareNoError;
}
OSStatus Plugin_BeginIOOperation(AudioServerPlugInDriverRef, AudioObjectID, UInt32, UInt32, UInt32, const AudioServerPlugInIOCycleInfo *) { return kAudioHardwareNoError; }
OSStatus Plugin_EndIOOperation(AudioServerPlugInDriverRef, AudioObjectID, UInt32, UInt32, UInt32, const AudioServerPlugInIOCycleInfo *) { return kAudioHardwareNoError; }

OSStatus Plugin_DoIOOperation(AudioServerPlugInDriverRef, AudioObjectID, AudioObjectID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, UInt32, const AudioServerPlugInIOCycleInfo *, void *ioMainBuffer, void *) {
    if (inOperationID != kAudioServerPlugInIOOperationReadInput) return kAudioHardwareNoError;
    if (!ioMainBuffer) return kAudioHardwareNoError;
    const Float32 *samples = static_cast<const Float32 *>(ioMainBuffer);
    UInt32 frames = inIOBufferFrameSize;
    if (frames > kRingFrames) frames = kRingFrames;
    memcpy(gRing, samples, sizeof(Float32) * frames * kChannelCount);
    gMeter.publish(gRing, frames, kChannelCount);
    return kAudioHardwareNoError;
}

} // namespace

// ---- CFPlugIn factory entry point ---------------------------------------

extern "C" void *VirtualAudioDevicePlugin_Factory(CFAllocatorRef, CFUUIDRef inRequestedTypeUUID) {
    if (!CFEqual(inRequestedTypeUUID, kAudioServerPlugInTypeUUID)) return nullptr;
    return gDriverRef;
}
