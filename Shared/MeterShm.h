// Shared memory layout for passing per-channel meter levels and host-decided
// device state from the HAL plugin process (coreaudiod) to the visualizer
// app, and for the app to request channel count / sample rate changes back.
// Single-writer-per-half, no lock: status half is written only by the
// driver, config half only by the app; a meter/settings UI can tolerate an
// occasional torn read of one frame.
//
// ponytail: no ring buffer / no raw audio transport here — the app only needs
// levels for metering + SSD channel highlighting, not the waveform. If a
// future feature needs the actual audio (e.g. recording from the app), add a
// lock-free ring buffer alongside this struct instead of replacing it.
#pragma once
#include <stdint.h>
#include <math.h>

#ifndef VAI_SHM_NAME
#define VAI_SHM_NAME "/vai_meter_v3"
#endif
#define VAI_MAX_CHANNELS 128
#define VAI_SHM_MAGIC 0x56414933u // 'VAI3'

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

    // Ballistics-smoothed peak per channel: on every IO buffer the driver
    // does peak = max(bufferPeak, peak * vai_peak_decay_factor(...)), tuned
    // for -20dB/1.5s decay. Without this a raw per-buffer overwrite would
    // lose transients between UI polls (IO cycles are ~ms, UI polls at
    // 30-60Hz). Linear 0..1(+) amplitude, driver-only writer.
    float    peakLevel[VAI_MAX_CHANNELS];
    // Running RMS: sqrt of an exponential moving average of mean-square
    // power, 300ms time constant (vai_rms_alpha). Linear amplitude.
    float    rmsLevel[VAI_MAX_CHANNELS];
    // Cumulative count of IO buffers on that channel containing at least one
    // |sample| >= 1.0. Never reset by the driver; the app records a baseline
    // snapshot and treats any increase since then as "clipped".
    uint32_t clipCount[VAI_MAX_CHANNELS];

    // ---- config: app -> driver (app writes, driver reads) ----
    uint32_t requestedChannelCount; // 1..128, 0 = no change requested
    double   requestedSampleRate;   // 0 = no change requested
    uint64_t configCounter;         // incremented by the app on every settings change
} VAIMeterShm;

// ---- ballistics formulas (shared so the driver and the Tools/ self-check
// compute the exact same numbers) --------------------------------------

// Per-IO-buffer peak decay multiplier: applying this once per buffer of
// `frames` samples at `sampleRate` produces a steady -20dB/1.5s falloff
// regardless of buffer size.
static inline float vai_peak_decay_factor(uint32_t frames, double sampleRate) {
    if (sampleRate <= 0.0 || frames == 0) return 0.0f;
    double seconds = (double)frames / sampleRate;
    return (float)pow(10.0, (-20.0 / 20.0) * (seconds / 1.5));
}

// EMA weight for the running mean-square power estimate (300ms time
// constant): meanSq += alpha * (bufferMeanSq - meanSq).
static inline float vai_rms_alpha(uint32_t frames, double sampleRate) {
    if (sampleRate <= 0.0 || frames == 0) return 1.0f;
    double seconds = (double)frames / sampleRate;
    return (float)(1.0 - exp(-seconds / 0.3));
}
