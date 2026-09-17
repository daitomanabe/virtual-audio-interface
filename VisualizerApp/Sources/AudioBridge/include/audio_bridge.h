// Thin C wrapper for reading/writing the HAL plugin's shared-memory meter
// struct (Shared/MeterShm.h) from Swift via mmap. The app reads the driver's
// status half and writes the config half (channel count / sample rate
// requests) — same segment, opened PROT_READ|PROT_WRITE so both halves are
// reachable from one mapping.
#pragma once
#include <stdint.h>
#include <stdbool.h>
#include "MeterShm.h"

#ifdef __cplusplus
extern "C" {
#endif

// Opens (or re-opens) the POSIX shared memory segment. Returns true on success.
// Safe to call repeatedly (e.g. on a timer) if the HAL plugin hasn't started yet.
bool abrOpen(void);
void abrClose(void);

// Copies channel count and up to maxOut peak levels into outLevels.
// Returns the number of channels copied, or 0 if the segment isn't open/available.
uint32_t abrReadLevels(float *outLevels, uint32_t maxOut);

// Status snapshot of driver-decided values (see VAIMeterShm). All zero if
// the segment isn't open yet.
typedef struct {
    uint32_t channelCount;
    double   sampleRate;
    uint32_t ioBufferFrameSize;
    uint32_t isRunning;
    uint32_t clientCount;
    uint32_t zeroTimeStampPeriod;
    double   hostRequestedSampleRate;
    uint64_t updateCounter;
    uint64_t configAppliedCounter;
    uint64_t configCounter;
} VAIStatus;

// Returns true if the segment is open and outStatus was filled.
bool abrReadStatus(VAIStatus *outStatus);

// Requests the driver switch to the given channel count / sample rate
// (0 = leave unchanged) and bumps configCounter so the driver's poller
// picks it up. Returns true if the segment is open and the write happened.
bool abrWriteConfig(uint32_t channelCount, double sampleRate);

#ifdef __cplusplus
}
#endif
