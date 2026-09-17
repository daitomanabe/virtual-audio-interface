// C ABI wrapper around ssd::Scene (Scene.h, spatial-audio-kit-and-ssd-v4) so
// Swift can load an .sscene file and read SPEAKER channel -> world position
// without a Swift/C++ interop dependency. Plain C types only, arrays are
// fixed-size and caller-allocated to keep memory ownership simple.
#pragma once
#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

#define SSDB_MAX_SPEAKERS 128

typedef struct {
    int32_t channel;   // SPEAKER Channel field (1-based per SSD spec)
    double x, y, z;     // world-space position, already axis-converted for SceneKit (+Y up, right-handed)
    double gain;
    bool mute;
} SSDBSpeaker;

// Loads and validates the scene, converts every SPEAKER's world transform
// origin from SSD's right-handed +Z-up meters into SceneKit's right-handed
// +Y-up: (x, y, z)_ssd -> (x, z, -y)_scenekit (same mapping the reference
// header documents for the openFrameworks port; SceneKit uses the same
// right-handed +Y-up convention, so no extra flip is needed).
// Returns the number of speakers written into outSpeakers (<= SSDB_MAX_SPEAKERS),
// or -1 on parse/validation error (outErrorMessage is filled if non-null).
int32_t ssdb_load_speakers(const char *path, SSDBSpeaker *outSpeakers, int32_t maxSpeakers,
                            char *outErrorMessage, int32_t errorMessageCapacity);

#ifdef __cplusplus
}
#endif
