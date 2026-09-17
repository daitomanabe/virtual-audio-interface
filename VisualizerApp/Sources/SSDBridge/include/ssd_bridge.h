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

// Several speakers may share one channel, so this is not tied to the 128ch device.
#define SSDB_MAX_SPEAKERS 1024
#define SSDB_TEXT_LEN 64

typedef struct {
    double x, y, z;
} SSDBVec3;

// SSD (right-handed, +Z up, X right / Y front) -> SceneKit (right-handed, +Y up):
// (x, y, z) -> (x, z, -y). A rotation, not a mirror (ssd::toOpenFrameworks).
// The only place this mapping lives: the app converts every point through it.
SSDBVec3 ssdb_to_scenekit(double x, double y, double z);

typedef struct {
    char objectId[SSDB_TEXT_LEN];  // OBJECT ID (truncated, NUL-terminated)
    char name[SSDB_TEXT_LEN];      // OBJECT Name (truncated, NUL-terminated)
    int32_t channel;               // SPEAKER Channel (1-based per SSD spec)
    double gainDb;                 // SPEAKER Gain (dB)
    double delayMs;                // SPEAKER Delay (ms)
    bool mute;                     // SPEAKER Mute
    bool active;                   // scene.active(id): own Enabled && all ancestors enabled
    double x, y, z;                // world position in raw SSD axes (meters), parents applied
} SSDBSpeakerInfo;

typedef struct {
    char name[128];                // [SCENE] Name ("" if absent)
    bool hasReviewVolume;          // [REVIEW_VOLUME] first row parsed (context only, no position)
    double reviewWidth, reviewDepth, reviewHeight;
} SSDBSceneInfo;

// Loads and validates the scene. Fills outInfo, up to maxSpeakers SPEAKER rows
// (file order) and outWarnings (newline-separated parser/bridge warnings).
// Returns the number of speakers written, or -1 on parse/validation error
// (outErrorMessage is filled). Buffers may be truncated, never overflowed.
int32_t ssdb_load_scene(const char *path, SSDBSceneInfo *outInfo,
                        SSDBSpeakerInfo *outSpeakers, int32_t maxSpeakers,
                        char *outWarnings, int32_t warningsCapacity,
                        char *outErrorMessage, int32_t errorMessageCapacity);

// Legacy API kept for Tools/selfcheck.cpp: position already SceneKit-converted.
typedef struct {
    int32_t channel;
    double x, y, z;
    double gain;
    bool mute;
} SSDBSpeaker;

int32_t ssdb_load_speakers(const char *path, SSDBSpeaker *outSpeakers, int32_t maxSpeakers,
                            char *outErrorMessage, int32_t errorMessageCapacity);

#ifdef __cplusplus
}
#endif
