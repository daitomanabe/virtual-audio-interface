// Headless check of the two C bridges the app relies on. Run: make -C Tools check
#include "../VisualizerApp/Sources/SSDBridge/include/ssd_bridge.h"
#include "../VisualizerApp/Sources/AudioBridge/include/audio_bridge.h"
#include <cassert>
#include <cmath>
#include <cstdio>

int main(int argc, char **argv) {
    SSDBSpeaker sp[SSDB_MAX_SPEAKERS];
    char err[256] = {};
    int n = ssdb_load_speakers(argc > 1 ? argv[1] : "../Examples/ring-8.sscene", sp, SSDB_MAX_SPEAKERS, err, sizeof err);
    if (n < 0) { std::printf("load error: %s\n", err); return 1; }
    assert(n == 8);
    assert(sp[0].channel == 1);
    // SSD (3,0,1) z-up -> SceneKit (3,1,0) y-up
    assert(std::fabs(sp[0].x - 3) < 1e-6 && std::fabs(sp[0].y - 1) < 1e-6 && std::fabs(sp[0].z) < 1e-6);
    // SSD (0,3,1) -> SceneKit (0,1,-3)
    assert(std::fabs(sp[2].x) < 1e-6 && std::fabs(sp[2].y - 1) < 1e-6 && std::fabs(sp[2].z + 3) < 1e-6);

    float lv[VAI_MAX_CHANNELS] = {};
    uint32_t got = abrReadLevels(lv, VAI_MAX_CHANNELS);
    std::printf("speakers=%d shm_channels=%u ch1=%.2f ch128=%.2f\n", n, got, lv[0], lv[127]);
    if (got) assert(got >= 1 && got <= 128);

    float peak[VAI_MAX_CHANNELS] = {}, rms[VAI_MAX_CHANNELS] = {};
    uint32_t clip[VAI_MAX_CHANNELS] = {};
    uint32_t gotMeters = abrReadMeters(peak, rms, clip, VAI_MAX_CHANNELS);
    if (gotMeters) assert(gotMeters == got);

    // Ballistics formulas from Shared/MeterShm.h (vai_peak_decay_factor /
    // vai_rms_alpha), checked standalone against the spec: 48kHz/512-frame
    // buffers, peak should fall by -20dB +/-0.5dB after ~1.5s of silence,
    // and the RMS EMA should reach ~63% of a step after one 300ms tau.
    {
        const double sr = 48000.0;
        const uint32_t frames = 512;
        float decay = vai_peak_decay_factor(frames, sr);
        uint32_t iterations = static_cast<uint32_t>(std::lround(1.5 * sr / frames)); // ~1.5s
        float peakState = 1.0f; // 0 dBFS
        for (uint32_t i = 0; i < iterations; ++i) peakState *= decay;
        float peakDB = 20.0f * std::log10(peakState);
        std::printf("decay check: %u iterations (%.3fs), peakDB=%.2f\n", iterations,
                     iterations * frames / sr, peakDB);
        assert(std::fabs(peakDB - (-20.0f)) < 0.5f);

        float alpha = vai_rms_alpha(frames, sr);
        uint32_t tauIterations = static_cast<uint32_t>(std::lround(0.3 * sr / frames)); // ~300ms
        float meanSq = 0.0f;
        for (uint32_t i = 0; i < tauIterations; ++i) meanSq += alpha * (1.0f - meanSq);
        std::printf("rms alpha check: %u iterations (%.3fs), meanSq=%.3f (expect ~0.63)\n", tauIterations,
                     tauIterations * frames / sr, meanSq);
        assert(std::fabs(meanSq - 0.632f) < 0.05f);
    }

    VAIStatus status = {};
    if (abrReadStatus(&status)) {
        std::printf("status: sr=%.0f iobuf=%u running=%u clients=%u\n",
                     status.sampleRate, status.ioBufferFrameSize, status.isRunning, status.clientCount);
        uint64_t beforeConfig = status.configCounter;
        bool wrote = abrWriteConfig(64, 48000.0);
        assert(wrote);
        VAIStatus after = {};
        abrReadStatus(&after);
        assert(after.configCounter == beforeConfig + 1);
    }
    std::puts("OK");
    return 0;
}
