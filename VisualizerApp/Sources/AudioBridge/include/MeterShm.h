// Shared memory layout for passing per-channel peak levels and host-decided
// device state from the HAL plugin process (coreaudiod) to the visualizer
// app, and for the app to request channel count / sample rate changes back.
// Single-writer-per-half, no lock: status half is written only by the
// driver, config half only by the app; a meter/settings UI can tolerate an
// occasional torn read of one frame.
//
// ponytail: no ring buffer / no raw audio transport here — the app only needs
// peak levels for metering + SSD channel highlighting, not the waveform.
// If a future feature needs the actual audio (e.g. recording from the app),
// add a lock-free ring buffer alongside this struct instead of replacing it.
#pragma once
#include <stdint.h>

#define VAI_SHM_NAME "/vai_meter_v2"
#define VAI_MAX_CHANNELS 128
#define VAI_SHM_MAGIC 0x56414932u // 'VAI2'

typedef struct {
    uint32_t magic;

    // ---- status: driver -> app (driver writes, app reads) ----
    uint32_t channelCount;        // channels the device currently exposes
    double   sampleRate;          // currently effective nominal rate
    uint32_t ioBufferFrameSize;   // most recent DoIOOperation inIOBufferFrameSize (host-decided)
    uint32_t isRunning;           // 1 between StartIO and StopIO
    uint32_t clientCount;         // incremented/decremented in AddDeviceClient/RemoveDeviceClient
    uint32_t zeroTimeStampPeriod;
    double   hostRequestedSampleRate; // last rate the DAW/host requested via SetPropertyData (0 = none yet)
    uint64_t updateCounter;       // incremented every IO cycle
    uint64_t configAppliedCounter; // configCounter value the driver last applied
    float    peakLevel[VAI_MAX_CHANNELS];

    // ---- config: app -> driver (app writes, driver reads) ----
    uint32_t requestedChannelCount; // 1..128, 0 = no change requested
    double   requestedSampleRate;   // 0 = no change requested
    uint64_t configCounter;         // incremented by the app on every settings change
} VAIMeterShm;
