// C ABI wrapper around this repository's SSD v0.1 reader (../ssd_reader.h) so
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
// (x, y, z) -> (x, z, -y). A rotation, not a mirror.
// The only place this mapping lives: the app converts every point through it.
SSDBVec3 ssdb_to_scenekit(double x, double y, double z);

typedef struct {
    char objectId[SSDB_TEXT_LEN];  // OBJECT ID (truncated, NUL-terminated)
    char name[SSDB_TEXT_LEN];      // OBJECT Name (truncated, NUL-terminated)
    int32_t channel;               // SPEAKER Channel (1-based per SSD spec)
    double gainDb;                 // SPEAKER Gain (dB)
    double delayMs;                // SPEAKER Delay (ms)
    bool mute;                     // SPEAKER Mute
    bool active;                   // own Enabled && all ancestors enabled
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

// ---- Every OBJECT, with the geometry sections the Monitor tab draws ----

#define SSDB_MAX_OBJECTS 4096

// Row-major 3x4 affine pose: p_world = m[r*4+0..2] . p_local + m[r*4+3] for row r = 0..2.
typedef struct {
    double m[12];
} SSDBMatrix;

// Pose in SSD axes -> SceneKit node transform: B * M * B^-1, where B is the ssdb_to_scenekit
// rotation. Converts the rotation together with the position (the SSD Euler angles are never
// reused in SceneKit). Geometry built in SSD-local coordinates and mapped through
// ssdb_to_scenekit lands where M would put it: node(B p) = B (M p).
SSDBMatrix ssdb_matrix_to_scenekit(SSDBMatrix ssd);

typedef struct {
    char objectId[SSDB_TEXT_LEN];
    char type[SSDB_TEXT_LEN];      // OBJECT Type as written (e.g. "screen", "camera", "truss")
    char name[SSDB_TEXT_LEN];
    int32_t parent;                // index of the parent in the output array, -1 for none
    bool active;                   // own Enabled && all ancestors enabled
    SSDBMatrix world;              // world pose in SSD axes, parents applied
    // Rectangles: local X right, Y up, +Z front normal, centered on the origin.
    bool hasRect;                  // [SCREEN] / [SURFACE] / [LED] row
    double width, height;          // meters
    int32_t pixelWidth, pixelHeight; // [LED] only, 0 otherwise
    bool hasBox;                   // [BOX] row (any OBJECT type), centered on the origin
    double sizeX, sizeY, sizeZ;    // meters, local axes
    bool hasFov;                   // [FOV] row (any OBJECT type)
    double fovHorizontal, fovVertical, fovDistance; // degrees, degrees, meters
    bool hasCamera;                // [CAMERA] row
    double cameraFovH, cameraFovV; // degrees
    int32_t target;                // [PROJECTOR] TargetID -> index in the output array, -1 if none
} SSDBObjectInfo;

// Loads the scene like ssdb_load_scene and writes up to maxObjects OBJECT rows in file order,
// speakers included. Parse/validation errors of the file fail like ssdb_load_scene (-1, message).
// A geometry row with bad values or references (e.g. Width 0, PROJECTOR target that is not a
// screen/surface/led) is skipped and reported in outWarnings (newline-separated; these warnings
// only, not ssdb_load_scene's) so the speakers stay usable. Returns the number written.
int32_t ssdb_load_objects(const char *path, SSDBObjectInfo *outObjects, int32_t maxObjects,
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
