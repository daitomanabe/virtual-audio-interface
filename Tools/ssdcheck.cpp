// Headless check of the SSDBridge C ABI used by the Monitor tab. Run: make -C Tools check
#include "../VisualizerApp/Sources/SSDBridge/include/ssd_bridge.h"
#include <cassert>
#include <cmath>
#include <cstdio>
#include <cstring>

static SSDBSpeakerInfo sp[SSDB_MAX_SPEAKERS];
static SSDBSceneInfo info;
static char warnings[4096], err[256];

static int load(const char *path) {
    int n = ssdb_load_scene(path, &info, sp, SSDB_MAX_SPEAKERS, warnings, sizeof warnings, err, sizeof err);
    if (n < 0) std::printf("load error (%s): %s\n", path, err);
    return n;
}
static const SSDBSpeakerInfo &byName(int n, const char *name) {
    for (int i = 0; i < n; ++i)
        if (std::strcmp(sp[i].name, name) == 0) return sp[i];
    std::printf("missing speaker %s\n", name);
    assert(false);
    return sp[0];
}
static bool near(double a, double b) { return std::fabs(a - b) < 1e-6; }

int main() {
    int n = load("../Examples/dome-24.sscene");
    assert(n == 24);
    assert(std::strcmp(info.name, "dome-24") == 0);
    assert(info.hasReviewVolume && near(info.reviewWidth, 12) && near(info.reviewHeight, 6));
    assert(warnings[0] == '\0');

    const auto &l1 = byName(n, "L1"); // ch1 = front (+Y), raw SSD axes
    assert(l1.channel == 1 && near(l1.x, 0) && near(l1.y, 4) && near(l1.z, 1.2) && !l1.mute && l1.active);
    const auto &sub = byName(n, "SUB1");
    assert(sub.channel == 21 && near(sub.gainDb, -6) && near(sub.delayMs, 4));

    // Truss at (5,0,3.5) yaw 90: child local (2,0,-0.4) -> world (5,2,3.1).
    const auto &tr1 = byName(n, "TR1");
    assert(tr1.channel == 23 && tr1.mute && tr1.active);
    assert(near(tr1.x, 5) && near(tr1.y, 2) && near(tr1.z, 3.1));
    const auto &tr2 = byName(n, "TR2"); // local (-2,0,-0.4), Enabled=0
    assert(tr2.channel == 24 && !tr2.mute && !tr2.active);
    assert(near(tr2.x, 5) && near(tr2.y, -2) && near(tr2.z, 3.1));

    // ring-8: SSD -> SceneKit axis conversion.
    n = load("../Examples/ring-8.sscene");
    assert(n == 8);
    SSDBVec3 p = ssdb_to_scenekit(sp[0].x, sp[0].y, sp[0].z); // SSD (3,0,1) -> (3,1,0)
    assert(near(p.x, 3) && near(p.y, 1) && near(p.z, 0));
    p = ssdb_to_scenekit(sp[2].x, sp[2].y, sp[2].z); // SSD (0,3,1) front -> (0,1,-3)
    assert(near(p.x, 0) && near(p.y, 1) && near(p.z, -3));

    n = load("../Examples/routing-errors.sscene");
    assert(n == 7);
    assert(std::strstr(warnings, "[SPEAKERS]"));
    assert(byName(n, "Left (ch 130)").channel == 130);
    assert(!byName(n, "On disabled truss").active); // disabled via parent

    assert(ssdb_load_scene("../Examples/missing.sscene", &info, sp, SSDB_MAX_SPEAKERS, warnings,
                           sizeof warnings, err, sizeof err) == -1 && err[0]);
    std::puts("ssdcheck OK");
    return 0;
}
