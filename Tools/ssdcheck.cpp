// Headless check of the SSDBridge C ABI used by the Monitor tab and of its SSD reader.
// Run: make -C Tools check
#include "../VisualizerApp/Sources/SSDBridge/include/ssd_bridge.h"
#include "../VisualizerApp/Sources/SSDBridge/ssd_reader.h"
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

static const std::string kHead = "[SCENE]\nVersion\t0.1\nUnit\tmeter\nCoordinateSystem\tSSD_RH_ZUP\nAngleUnit\tdegree\n";

// Where the object's world rotation sends a local axis (0 = X, 1 = Y, 2 = Z).
static bool maps(const ssdreader::Object &o, int axis, double x, double y, double z) {
    return near(o.world.r[0][axis], x) && near(o.world.r[1][axis], y) && near(o.world.r[2][axis], z);
}

// parse() must fail and name the offending line.
static void expectError(const std::string &text, const char *line) {
    try {
        ssdreader::parse(text);
    } catch (const ssdreader::Error &e) {
        if (std::strstr(e.what(), line)) return;
        std::printf("wrong error: %s (expected %s)\n", e.what(), line);
        assert(false);
    }
    std::printf("no error for:\n%s\n", text.c_str());
    assert(false);
}

static void readerChecks() {
    // Rotation convention: Yaw about +Z, Pitch about +X, right-handed, degrees.
    auto scene = ssdreader::parse(kHead + "[OBJECT]\n"
                                          "yaw\tspeaker\ty\tnone\t0\t0\t0\t90\t0\t0\t1\n"
                                          "pitch\tspeaker\tp\tnone\t0\t0\t0\t0\t90\t0\t1\n"
                                          "all\tspeaker\ta\tnone\t0\t0\t0\t90\t90\t90\t1\n");
    assert(maps(scene.objects.at("yaw"), 0, 0, 1, 0));    // Yaw 90: local +X -> world +Y
    assert(maps(scene.objects.at("pitch"), 2, 0, -1, 0)); // Pitch 90: local +Z -> world -Y
    // Order R = Ry(Roll) * Rx(Pitch) * Rz(Yaw): +X -> +Y -> +Z -> +X and +Y -> -X -> -X -> +Z.
    assert(maps(scene.objects.at("all"), 0, 1, 0, 0) && maps(scene.objects.at("all"), 1, 0, 0, 1));

    // Parent/child: M_world = M_parent * T * R, independent of row order.
    scene = ssdreader::parse(kHead + "[OBJECT]\n"
                                     "child\tspeaker\tc\trig\t1\t0\t0\t0\t90\t0\t1\n"
                                     "rig\ttruss\tr\tnone\t1\t2\t3\t90\t0\t0\t0\n");
    const auto &child = scene.objects.at("child");
    assert(near(child.world.t[0], 1) && near(child.world.t[1], 3) && near(child.world.t[2], 3));
    assert(maps(child, 2, 1, 0, 0)); // own Pitch 90 sends +Z to -Y, the rig's Yaw 90 turns -Y into +X
    assert(child.enabled && !child.active); // rig is disabled

    const std::string speaker = "1\tspeaker\ta\tnone\t0\t0\t0\t0\t0\t0\t1\n";
    expectError(kHead + "[OBJECT]\n" + speaker + "2\tspeaker\tb\t99\t0\t0\t0\t0\t0\t0\t1\n", "line 8:"); // no parent 99
    expectError(kHead + "[OBJECT]\n3\ttruss\ta\t4\t0\t0\t0\t0\t0\t0\t1\n4\ttruss\tb\t3\t0\t0\t0\t0\t0\t0\t1\n",
                "line 7:"); // parent cycle
    expectError(kHead + "[OBJECT]\n1\tspeaker\ta\tnone\t+1.0\t0\t0\t0\t0\t0\t1\n", "line 7:"); // leading '+'
    expectError(kHead + "[OBJECT]\n1\ttruss\ta\tnone\t0\t0\t0\t0\t0\t0\t1\n[SPEAKER]\n1\t1\t0\t0\t0\n",
                "line 9:"); // SPEAKER on a non-speaker OBJECT
    expectError("[SCENE]\nVersion\t0.2\n", "line 2:");
}

int main() {
    readerChecks();

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
