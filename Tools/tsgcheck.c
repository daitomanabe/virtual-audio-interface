// Self-check for the app's test signal renderer (VisualizerApp/Sources/TestSignalDSP):
// channel isolation, sine peak / pink RMS calibration, fades, all-channels, clamping.
#include "test_signal.h"
#include <assert.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>

enum { CH = 8, FRAMES = 512, SR = 48000 };

static float buf[CH][FRAMES];
static AudioBufferList *abl;

static void render(TSGState *s) {
    AURenderCallbackStruct cb = tsgRenderCallback(s);
    AudioUnitRenderActionFlags flags = 0;
    AudioTimeStamp ts = {0};
    for (int i = 0; i < CH; i++) abl->mBuffers[i] = (AudioBuffer){1, sizeof buf[i], buf[i]};
    assert(cb.inputProc(cb.inputProcRefCon, &flags, &ts, 0, FRAMES, abl) == noErr);
}

// Renders `blocks` buffers; returns peak and RMS per channel over them.
static void measure(TSGState *s, int blocks, float peak[CH], float rms[CH]) {
    double sq[CH] = {0};
    for (int c = 0; c < CH; c++) peak[c] = 0;
    for (int b = 0; b < blocks; b++) {
        render(s);
        for (int c = 0; c < CH; c++)
            for (int f = 0; f < FRAMES; f++) {
                peak[c] = fmaxf(peak[c], fabsf(buf[c][f]));
                sq[c] += (double)buf[c][f] * buf[c][f];
            }
    }
    for (int c = 0; c < CH; c++) rms[c] = (float)sqrt(sq[c] / ((double)blocks * FRAMES));
}

int main(void) {
    abl = malloc(sizeof(AudioBufferList) + CH * sizeof(AudioBuffer));
    abl->mNumberBuffers = CH;
    float peak[CH], rms[CH];

    TSGState *s = tsgCreate(SR);
    measure(s, 4, peak, rms);
    for (int c = 0; c < CH; c++) assert(peak[c] == 0); // starts silent

    // Sine, -20 dBFS on channel 5: peak 0.1 there, nothing elsewhere, fades in.
    tsgSetSignal(s, TSG_SINE);
    tsgSetLevel(s, -20);
    tsgSetChannel(s, 5);
    render(s);
    float first = 0;
    for (int f = 0; f < 48; f++) first = fmaxf(first, fabsf(buf[4][f])); // first 1 ms
    assert(first < 0.012f);
    measure(s, 100, peak, rms);
    printf("sine -20 dBFS ch5: peak %.4f rms %.4f\n", peak[4], rms[4]);
    assert(fabsf(peak[4] - 0.1f) < 0.001f && fabsf(rms[4] - 0.0707f) < 0.001f);
    for (int c = 0; c < CH; c++) if (c != 4) assert(peak[c] == 0);

    // Switch to pink on channel 2: channel 5 is silent after the 10 ms fade-out.
    tsgSetSignal(s, TSG_PINK);
    tsgSetChannel(s, 2);
    render(s);
    int lastNonZero = -1;
    for (int f = 0; f < FRAMES; f++) if (buf[4][f] != 0) lastNonZero = f;
    assert(lastNonZero >= 0 && lastNonZero < SR / 100);
    measure(s, 1000, peak, rms); // ~10.7 s
    printf("pink -20 dBFS ch2: peak %.4f rms %.4f\n", peak[1], rms[1]);
    assert(fabsf(20 * log10f(rms[1]) + 20) < 0.5f);
    for (int c = 0; c < CH; c++) if (c != 1) assert(peak[c] == 0);

    // All channels at once get the same signal.
    tsgSetChannel(s, TSG_CHANNEL_ALL);
    measure(s, 10, peak, rms);
    for (int c = 1; c < CH; c++) for (int f = 0; f < FRAMES; f++) assert(buf[c][f] == buf[0][f]);
    assert(rms[0] > 0.05f);

    // 0 dBFS pink clips; output stays within +-1.
    tsgSetLevel(s, 0);
    measure(s, 100, peak, rms);
    assert(peak[0] <= 1.0f);

    // Out-of-range channel and NONE are silent.
    tsgSetChannel(s, CH + 1);
    render(s); // fade-out
    measure(s, 10, peak, rms);
    for (int c = 0; c < CH; c++) assert(peak[c] == 0);

    tsgDestroy(s);
    free(abl);
    printf("tsgcheck: OK\n");
    return 0;
}
