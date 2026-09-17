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
    if (got) assert(got == 128);
    std::puts("OK");
    return 0;
}
