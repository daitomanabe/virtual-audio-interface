// Shared memory layout for passing per-channel peak levels from the HAL plugin
// process (coreaudiod) to the visualizer app. Single-writer/multi-reader,
// no lock: a meter can tolerate an occasional torn read of one frame.
//
// ponytail: no ring buffer / no raw audio transport here — the app only needs
// peak levels for metering + SSD channel highlighting, not the waveform.
// If a future feature needs the actual audio (e.g. recording from the app),
// add a lock-free ring buffer alongside this struct instead of replacing it.
#pragma once
#include <stdint.h>

#define VAI_SHM_NAME "/vai_meter_v1"
#define VAI_MAX_CHANNELS 128
#define VAI_SHM_MAGIC 0x56414931u // 'VAI1'

typedef struct {
    uint32_t magic;
    uint32_t channelCount;      // channels actually active (<= VAI_MAX_CHANNELS)
    uint64_t updateCounter;     // incremented every IOProc cycle
    float peakLevel[VAI_MAX_CHANNELS];  // 0..1ish (abs sample peak since last read)
} VAIMeterShm;
