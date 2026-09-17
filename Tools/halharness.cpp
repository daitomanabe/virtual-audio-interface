// Drives the HAL plugin in-process the way coreaudiod does, to catch crashes without installing it.
// Build+run: make -C Tools harness   (ASan/UBSan, private shm name so a live driver is untouched)
#include <CoreAudio/AudioServerPlugIn.h>
#include <dispatch/dispatch.h>
#include <atomic>
#include <cassert>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <fcntl.h>
#include <sys/mman.h>
#include <thread>
#include <vector>
#include "../Shared/MeterShm.h"

extern "C" void *VirtualAudioDevicePlugin_Factory(CFAllocatorRef, CFUUIDRef);

static AudioServerPlugInDriverRef gDrv;
static std::atomic<int> gPropsChanged{0}, gConfigRequests{0};
static dispatch_queue_t gHALQueue;

static OSStatus HostPropertiesChanged(AudioServerPlugInHostRef, AudioObjectID, UInt32 n, const AudioObjectPropertyAddress *a) {
    for (UInt32 i = 0; i < n; ++i) (void)a[i].mSelector;
    gPropsChanged++;
    return 0;
}
static OSStatus HostCopyFromStorage(AudioServerPlugInHostRef, CFStringRef, CFPropertyListRef *out) { *out = nullptr; return kAudioHardwareUnknownPropertyError; }
static OSStatus HostWriteToStorage(AudioServerPlugInHostRef, CFStringRef, CFPropertyListRef) { return 0; }
static OSStatus HostDeleteFromStorage(AudioServerPlugInHostRef, CFStringRef) { return 0; }
static OSStatus HostRequestConfig(AudioServerPlugInHostRef, AudioObjectID dev, UInt64 action, void *info) {
    gConfigRequests++;
    // Real HAL: stops IO, performs the change on its own thread, restarts IO.
    dispatch_async(gHALQueue, ^{ (*gDrv)->PerformDeviceConfigurationChange(gDrv, dev, action, info); });
    return 0;
}
static AudioServerPlugInHostInterface gHost = {HostPropertiesChanged, HostCopyFromStorage, HostWriteToStorage,
                                               HostDeleteFromStorage, HostRequestConfig};

static const AudioObjectPropertySelector kSelectors[] = {
    kAudioObjectPropertyBaseClass, kAudioObjectPropertyClass, kAudioObjectPropertyOwner, kAudioObjectPropertyName,
    kAudioObjectPropertyModelName, kAudioObjectPropertyManufacturer, kAudioObjectPropertyElementName,
    kAudioObjectPropertyOwnedObjects, kAudioObjectPropertyControlList, kAudioObjectPropertyIdentify,
    kAudioObjectPropertyCustomPropertyInfoList, kAudioPlugInPropertyDeviceList, kAudioPlugInPropertyTranslateUIDToDevice,
    kAudioPlugInPropertyResourceBundle, kAudioPlugInPropertyBoxList, kAudioDevicePropertyConfigurationApplication,
    kAudioDevicePropertyDeviceUID, kAudioDevicePropertyModelUID, kAudioDevicePropertyTransportType,
    kAudioDevicePropertyRelatedDevices, kAudioDevicePropertyClockDomain, kAudioDevicePropertyDeviceIsAlive,
    kAudioDevicePropertyDeviceIsRunning, kAudioDevicePropertyDeviceCanBeDefaultDevice,
    kAudioDevicePropertyDeviceCanBeDefaultSystemDevice, kAudioDevicePropertyLatency, kAudioDevicePropertyStreams,
    kAudioDevicePropertySafetyOffset, kAudioDevicePropertyNominalSampleRate,
    kAudioDevicePropertyAvailableNominalSampleRates, kAudioDevicePropertyIsHidden,
    kAudioDevicePropertyPreferredChannelsForStereo, kAudioDevicePropertyPreferredChannelLayout,
    kAudioDevicePropertyZeroTimeStampPeriod, kAudioDevicePropertyIcon, kAudioDevicePropertyClockAlgorithm,
    kAudioDevicePropertyClockIsStable, kAudioStreamPropertyIsActive, kAudioStreamPropertyDirection,
    kAudioStreamPropertyTerminalType, kAudioStreamPropertyStartingChannel, kAudioStreamPropertyLatency,
    kAudioStreamPropertyVirtualFormat, kAudioStreamPropertyAvailableVirtualFormats,
    kAudioStreamPropertyPhysicalFormat, kAudioStreamPropertyAvailablePhysicalFormats,
};
static const bool IsCFType(AudioObjectPropertySelector s) {
    return s == kAudioObjectPropertyName || s == kAudioObjectPropertyModelName || s == kAudioObjectPropertyManufacturer ||
           s == kAudioObjectPropertyElementName || s == kAudioPlugInPropertyResourceBundle ||
           s == kAudioDevicePropertyDeviceUID || s == kAudioDevicePropertyModelUID ||
           s == kAudioDevicePropertyConfigurationApplication || s == kAudioDevicePropertyIcon;
}

static void QueryAllProperties() {
    CFStringRef uid = CFSTR("com.daitomanabe.virtualaudiointerface.device");
    for (AudioObjectID obj : {(AudioObjectID)kAudioObjectPlugInObject, (AudioObjectID)2, (AudioObjectID)3, (AudioObjectID)99})
        for (AudioObjectPropertyScope scope : {(AudioObjectPropertyScope)kAudioObjectPropertyScopeGlobal, (AudioObjectPropertyScope)kAudioObjectPropertyScopeInput, (AudioObjectPropertyScope)kAudioObjectPropertyScopeOutput})
            for (AudioObjectPropertySelector sel : kSelectors) {
                AudioObjectPropertyAddress addr = {sel, scope, kAudioObjectPropertyElementMain};
                if (!(*gDrv)->HasProperty(gDrv, obj, 0, &addr)) continue;
                const void *q = sel == kAudioPlugInPropertyTranslateUIDToDevice ? &uid : nullptr;
                UInt32 qsize = q ? sizeof(CFStringRef) : 0;
                UInt32 size = 0;
                if ((*gDrv)->GetPropertyDataSize(gDrv, obj, 0, &addr, qsize, q, &size) != 0) continue;
                std::vector<UInt8> buf(size + 1);
                UInt32 got = 0;
                OSStatus st = (*gDrv)->GetPropertyData(gDrv, obj, 0, &addr, qsize, q, size, &got, buf.data());
                if (st == 0) {
                    assert(got <= size);
                    if (IsCFType(sel) && got == sizeof(CFTypeRef)) {
                        CFTypeRef ref; memcpy(&ref, buf.data(), sizeof ref);
                        if (ref) CFRelease(ref);
                    }
                }
                if (size >= 1) { // undersized buffer must be rejected, not overrun
                    std::vector<UInt8> small(size - 1 + 1);
                    (*gDrv)->GetPropertyData(gDrv, obj, 0, &addr, qsize, q, size - 1, &got, small.data());
                }
            }
}

int main() {
    gHALQueue = dispatch_queue_create("hal", DISPATCH_QUEUE_SERIAL);
    gDrv = (AudioServerPlugInDriverRef)VirtualAudioDevicePlugin_Factory(nullptr, kAudioServerPlugInTypeUUID);
    assert(gDrv);
    AudioServerPlugInHostRef host = &gHost;
    assert((*gDrv)->Initialize(gDrv, host) == 0);
    QueryAllProperties();
    std::puts("properties OK");

    int fd = shm_open(VAI_SHM_NAME, O_RDWR, 0);
    assert(fd >= 0);
    auto *shm = (VAIMeterShm *)mmap(nullptr, sizeof(VAIMeterShm), PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);

    const AudioObjectID dev = 2, stream = 3;
    AudioServerPlugInClientInfo client = {1, 1234, true, CFSTR("com.example.daw")};
    assert((*gDrv)->AddDeviceClient(gDrv, dev, &client) == 0);
    assert((*gDrv)->StartIO(gDrv, dev, client.mClientID) == 0);

    std::atomic<bool> stop{false};
    std::thread reconfig([&] {
        const double rates[] = {44100, 48000, 96000, 48000};
        for (int i = 0; !stop; ++i) {
            if (i % 2 == 0) {
                AudioObjectPropertyAddress a = {kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
                Float64 r = rates[i % 4];
                (*gDrv)->SetPropertyData(gDrv, dev, 1234, &a, 0, nullptr, sizeof r, &r);
            } else {
                shm->requestedChannelCount = 1 + (i * 37) % 128;
                shm->requestedSampleRate = 0;
                shm->configCounter++;
            }
            QueryAllProperties();
            std::this_thread::sleep_for(std::chrono::milliseconds(50));
        }
    });

    std::vector<Float32> buffer(4096 * 128);
    const UInt32 ops[] = {kAudioServerPlugInIOOperationThread, kAudioServerPlugInIOOperationCycle,
                          kAudioServerPlugInIOOperationProcessOutput, kAudioServerPlugInIOOperationMixOutput,
                          kAudioServerPlugInIOOperationProcessMix, kAudioServerPlugInIOOperationConvertMix,
                          kAudioServerPlugInIOOperationWriteMix};
    Float64 lastSampleTime = -1;
    for (int cycle = 0; cycle < 3000; ++cycle) {
        UInt32 frames = (cycle % 3 == 0) ? 4096 : 512;
        for (UInt32 f = 0; f < frames * 128; ++f) buffer[f] = (cycle % 50 == 0) ? 1.2f : 0.25f;
        Float64 st; UInt64 ht, seed;
        (*gDrv)->GetZeroTimeStamp(gDrv, dev, client.mClientID, &st, &ht, &seed);
        (void)lastSampleTime;
        lastSampleTime = st;
        AudioServerPlugInIOCycleInfo info = {};
        info.mNominalIOBufferFrameSize = frames;
        for (UInt32 op : ops) {
            Boolean will = false, inPlace = false;
            (*gDrv)->WillDoIOOperation(gDrv, dev, client.mClientID, op, &will, &inPlace);
            if (!will) continue;
            (*gDrv)->BeginIOOperation(gDrv, dev, client.mClientID, op, frames, &info);
            (*gDrv)->DoIOOperation(gDrv, dev, stream, client.mClientID, op, frames, &info, buffer.data(), nullptr);
            (*gDrv)->EndIOOperation(gDrv, dev, client.mClientID, op, frames, &info);
        }
        std::this_thread::sleep_for(std::chrono::microseconds(500));
    }
    stop = true;
    reconfig.join();
    assert((*gDrv)->StopIO(gDrv, dev, client.mClientID) == 0);
    (*gDrv)->RemoveDeviceClient(gDrv, dev, &client);
    dispatch_sync(gHALQueue, ^{});

    std::printf("io OK: updateCounter=%llu ioBuf=%u ch=%u sr=%.0f clip1=%u propsChanged=%d configRequests=%d\n",
                shm->updateCounter, shm->ioBufferFrameSize, shm->channelCount, shm->sampleRate, shm->clipCount[0],
                gPropsChanged.load(), gConfigRequests.load());
    assert(shm->updateCounter > 0);
    assert(shm->ioBufferFrameSize == 512 || shm->ioBufferFrameSize == 4096);
    shm_unlink(VAI_SHM_NAME);
    std::puts("OK");
}
