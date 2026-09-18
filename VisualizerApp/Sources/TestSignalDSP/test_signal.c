#include "include/test_signal.h"
#include <math.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

// RMS of the Kellet filter below fed with uniform white noise in [-1, 1)
// (measured over 200 s); scales pink noise to unit RMS.
#define PINK_UNIT_RMS (1.0f / 1.7631f)
#define FADE_SECONDS 0.010
#define TWO_PI 6.283185307179586

struct TSGState {
    // main thread -> render thread
    _Atomic int32_t reqChannel;
    _Atomic int32_t reqSignal;
    _Atomic float reqGain;   // linear
    _Atomic float reqFreq;   // Hz

    // render thread only
    double sampleRate;
    double phase;
    float fadeStep;          // envelope change per sample (0 -> 1 in FADE_SECONDS)
    float gainCoef;          // one-pole smoothing of level changes
    float env;               // 0..1 fade envelope
    float gain;              // smoothed linear gain
    int32_t channel;         // what is sounding now; changes only while env == 0
    int32_t signal;
    uint32_t rng;
    float b[7];              // pink filter state
};

TSGState *tsgCreate(double sampleRate) {
    TSGState *s = calloc(1, sizeof *s);
    if (!s) return NULL;
    s->sampleRate = sampleRate > 0 ? sampleRate : 48000;
    s->fadeStep = (float)(1.0 / (FADE_SECONDS * s->sampleRate));
    s->gainCoef = (float)(1.0 - exp(-1.0 / (FADE_SECONDS * s->sampleRate)));
    s->channel = TSG_CHANNEL_NONE;
    s->signal = TSG_PINK;
    s->rng = 0x9E3779B9u;
    atomic_init(&s->reqChannel, TSG_CHANNEL_NONE);
    atomic_init(&s->reqSignal, TSG_PINK);
    atomic_init(&s->reqGain, 0.1f);
    atomic_init(&s->reqFreq, 1000.0f);
    return s;
}

void tsgDestroy(TSGState *s) { free(s); }

void tsgSetChannel(TSGState *s, int32_t channel) { atomic_store_explicit(&s->reqChannel, channel, memory_order_relaxed); }
void tsgSetSignal(TSGState *s, int32_t signal) { atomic_store_explicit(&s->reqSignal, signal, memory_order_relaxed); }
void tsgSetLevel(TSGState *s, float dBFS) { atomic_store_explicit(&s->reqGain, powf(10.0f, dBFS / 20.0f), memory_order_relaxed); }
void tsgSetFrequency(TSGState *s, float hz) { atomic_store_explicit(&s->reqFreq, hz, memory_order_relaxed); }

// Paul Kellet's refined pink noise filter (+-0.05 dB above 9.2 Hz at 44.1 kHz).
static inline float pink(TSGState *s) {
    s->rng = s->rng * 1664525u + 1013904223u;
    float w = (float)(int32_t)s->rng * (1.0f / 2147483648.0f);
    float *b = s->b;
    b[0] = 0.99886f * b[0] + w * 0.0555179f;
    b[1] = 0.99332f * b[1] + w * 0.0750759f;
    b[2] = 0.96900f * b[2] + w * 0.1538520f;
    b[3] = 0.86650f * b[3] + w * 0.3104856f;
    b[4] = 0.55000f * b[4] + w * 0.5329522f;
    b[5] = -0.7616f * b[5] - w * 0.0168980f;
    float p = b[0] + b[1] + b[2] + b[3] + b[4] + b[5] + b[6] + w * 0.5362f;
    b[6] = w * 0.115926f;
    return p * PINK_UNIT_RMS;
}

static OSStatus render(void *refCon, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *time,
                       UInt32 bus, UInt32 frames, AudioBufferList *io) {
    (void)flags; (void)time; (void)bus;
    TSGState *s = refCon;
    if (!io) return noErr;
    const UInt32 nb = io->mNumberBuffers;
    for (UInt32 i = 0; i < nb; i++) memset(io->mBuffers[i].mData, 0, io->mBuffers[i].mDataByteSize);
    if (nb == 0) return noErr;
    const UInt32 capacity = io->mBuffers[0].mDataByteSize / sizeof(float);
    if (frames > capacity) frames = capacity;

    const int32_t reqChannel = atomic_load_explicit(&s->reqChannel, memory_order_relaxed);
    const int32_t reqSignal = atomic_load_explicit(&s->reqSignal, memory_order_relaxed);
    const float target = atomic_load_explicit(&s->reqGain, memory_order_relaxed);
    const double inc = TWO_PI * atomic_load_explicit(&s->reqFreq, memory_order_relaxed) / s->sampleRate;

    for (UInt32 f = 0; f < frames; f++) {
        if (s->channel != reqChannel || s->signal != reqSignal) {
            s->env -= s->fadeStep;
            if (s->env <= 0) { s->env = 0; s->channel = reqChannel; s->signal = reqSignal; }
        } else if (s->env < 1) {
            s->env = fminf(1, s->env + s->fadeStep);
        }
        if (s->env == 0) s->gain = target; // silent anyway: jump instead of ramping
        else s->gain += (target - s->gain) * s->gainCoef;

        float x;
        if (s->signal == TSG_SINE) {
            x = (float)sin(s->phase);
            s->phase += inc;
            if (s->phase >= TWO_PI) s->phase -= TWO_PI;
        } else {
            x = pink(s);
        }
        x = fmaxf(-1, fminf(1, x * s->gain * s->env));

        if (s->channel == TSG_CHANNEL_ALL) {
            for (UInt32 i = 0; i < nb; i++) ((float *)io->mBuffers[i].mData)[f] = x;
        } else if (s->channel >= 1 && (UInt32)s->channel <= nb) {
            ((float *)io->mBuffers[s->channel - 1].mData)[f] = x;
        }
    }
    return noErr;
}

AURenderCallbackStruct tsgRenderCallback(TSGState *s) {
    AURenderCallbackStruct cb = { render, s };
    return cb;
}
