// Test signal renderer for the app's own AUHAL output (TestSignalEngine.swift).
//
// Threading: the tsgSet* functions are called from the main thread and only do
// relaxed C11 atomic stores. The render callback runs on the HAL IO thread and
// only does atomic loads plus arithmetic on fields it alone owns: no allocation,
// locks, Objective-C/Swift runtime calls or logging.
#pragma once
#include <AudioToolbox/AudioToolbox.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct TSGState TSGState;

static const int32_t TSG_PINK = 0;
static const int32_t TSG_SINE = 1;
static const int32_t TSG_CHANNEL_NONE = -1;
static const int32_t TSG_CHANNEL_ALL = 0;

// Starts silent (TSG_CHANNEL_NONE), pink, -20 dBFS, 1 kHz.
TSGState *tsgCreate(double sampleRate);
// Only after the AudioUnit rendering with it has been disposed.
void tsgDestroy(TSGState *s);

// 1-based device channel, TSG_CHANNEL_ALL or TSG_CHANNEL_NONE. Changing the channel
// or the signal fades out, switches, and fades back in (10 ms each way).
void tsgSetChannel(TSGState *s, int32_t channel);
void tsgSetSignal(TSGState *s, int32_t signal);
// Sine: peak level. Pink noise: RMS level. Output is clamped to +-1.
void tsgSetLevel(TSGState *s, float dBFS);
void tsgSetFrequency(TSGState *s, float hz);

// Render callback for kAudioUnitProperty_SetRenderCallback. Expects Float32
// non-interleaved buffers, one per device channel.
AURenderCallbackStruct tsgRenderCallback(TSGState *s);

#ifdef __cplusplus
}
#endif
