// Thin C wrapper for reading the HAL plugin's shared-memory meter struct
// (Shared/MeterShm.h) from Swift via mmap. No writing from this side.
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

#ifdef __cplusplus
}
#endif
