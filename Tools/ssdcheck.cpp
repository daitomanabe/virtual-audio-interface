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
static bool near(double a, double b, double eps = 1e-6) { return std::fabs(a - b) < eps; }

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

static SSDBObjectInfo objects[SSDB_MAX_OBJECTS];

static int loadObjects(const char *path) {
    int n = ssdb_load_objects(path, objects, SSDB_MAX_OBJECTS, warnings, sizeof warnings, err, sizeof err);
    if (n < 0) std::printf("load error (%s): %s\n", path, err);
    return n;
}
static int objectIndex(int n, const char *id) {
    for (int i = 0; i < n; ++i)
        if (std::strcmp(objects[i].objectId, id) == 0) return i;
    std::printf("missing object %s\n", id);
    assert(false);
    return -1;
}
// m * p, with (point) or without (direction) the translation column.
static SSDBVec3 apply(const SSDBMatrix &m, SSDBVec3 p, bool point = true) {
    double v[3] = {p.x, p.y, p.z}, o[3];
    for (int r = 0; r < 3; ++r)
        o[r] = m.m[r * 4] * v[0] + m.m[r * 4 + 1] * v[1] + m.m[r * 4 + 2] * v[2] + (point ? m.m[r * 4 + 3] : 0);
    return {o[0], o[1], o[2]};
}
static bool is(SSDBVec3 v, double x, double y, double z, double eps = 1e-6) {
    if (near(v.x, x, eps) && near(v.y, y, eps) && near(v.z, z, eps)) return true;
    std::printf("got (%g, %g, %g), expected (%g, %g, %g)\n", v.x, v.y, v.z, x, y, z);
    return false;
}
static SSDBVec3 sk(SSDBVec3 p) { return ssdb_to_scenekit(p.x, p.y, p.z); }

static void objectChecks() {
    int n = loadObjects("../Examples/venue-demo.sscene");
    assert(n == 20 && warnings[0] == '\0');
    assert(std::strcmp(objects[0].objectId, "1") == 0 && std::strcmp(objects[0].type, "speaker") == 0); // file order

    // Upright screen (0, 90, 0): +Z front normal -> world -Y, local Y (up) -> +Z.
    const SSDBObjectInfo &scr = objects[objectIndex(n, "scr")];
    assert(std::strcmp(scr.type, "screen") == 0 && scr.hasRect && near(scr.width, 8) && near(scr.height, 4.5));
    assert(scr.parent == -1 && scr.active && !scr.hasBox && !scr.hasFov && scr.target == -1);
    assert(is(apply(scr.world, {0, 0, 1}, false), 0, -1, 0) && is(apply(scr.world, {0, 1, 0}, false), 0, 0, 1));
    assert(is(apply(scr.world, {4, 2.25, 0}), 4, 6, 5.45)); // UV (1, 1): top right as seen from the audience

    // LED on a rig with Yaw 90: parent index, world pose through the parent, pixel counts.
    const int rig = objectIndex(n, "rigL");
    const SSDBObjectInfo &ledL = objects[objectIndex(n, "ledL")];
    assert(ledL.parent == rig && ledL.hasRect && ledL.pixelWidth == 384 && ledL.pixelHeight == 192);
    assert(is(apply(ledL.world, {0, 0, 0}), -6, 1, 2.2));
    assert(is(apply(ledL.world, {0, 0, 1}, false), 1, 0, 0) && is(apply(ledL.world, {1, 0, 0}, false), 0, 1, 0));
    const SSDBObjectInfo &ledR = objects[objectIndex(n, "ledR")];
    assert(ledR.parent == -1 && is(apply(ledR.world, {0, 0, 1}, false), -1, 0, 0) &&
           is(apply(ledR.world, {0, 1, 0}, false), 0, 0, 1));

    // Projector: target, FOV, and its frustum corner lands on the screen's UV (1, 1) corner.
    const SSDBObjectInfo &pj = objects[objectIndex(n, "pj")];
    assert(pj.target == objectIndex(n, "scr") && pj.hasFov && near(pj.fovDistance, 11) && !pj.hasCamera);
    const double toRad = std::acos(-1.0) / 180;
    const double hx = 11 * std::tan(pj.fovHorizontal / 2 * toRad), hy = 11 * std::tan(pj.fovVertical / 2 * toRad);
    assert(is(apply(pj.world, {hx, hy, -11}), 4, 6, 5.45, 1e-2)); // the app's convention: view along local -Z

    const SSDBObjectInfo &camTop = objects[objectIndex(n, "camTop")];
    assert(camTop.hasCamera && near(camTop.cameraFovH, 70) && camTop.hasFov && near(camTop.fovDistance, 5.49));
    assert(is(apply(camTop.world, {0, 0, -1}, false), 0, 0, -1)); // zero pose looks down
    const SSDBObjectInfo &camStage = objects[objectIndex(n, "camStage")];
    const double c15 = std::cos(15 * toRad), s15 = std::sin(15 * toRad);
    assert(is(apply(camStage.world, {0, 0, -1}, false), 0, -c15, -s15) &&
           is(apply(camStage.world, {0, 1, 0}, false), 0, -s15, c15)); // up leans forward with the tilt
    assert(!objects[objectIndex(n, "camSpare")].active);
    const SSDBObjectInfo &stage = objects[objectIndex(n, "stage")];
    assert(stage.hasBox && near(stage.sizeX, 12) && near(stage.sizeY, 2.5) && near(stage.sizeZ, 0.8) && !stage.hasRect);
    const SSDBObjectInfo &mic = objects[objectIndex(n, "mic")];
    assert(std::strcmp(mic.type, "microphone") == 0 && !mic.hasRect && !mic.hasBox && !mic.hasFov && !mic.hasCamera);

    // SSD -> SceneKit pose: B * M * B^-1. The upright screen's normal (SSD local +Z, i.e. SceneKit
    // local B(0,0,1)) must point to SceneKit +Z (= SSD -Y, towards the audience), its up to +Y.
    SSDBMatrix k = ssdb_matrix_to_scenekit(scr.world);
    assert(is(apply(k, sk({0, 0, 1}), false), 0, 0, 1) && is(apply(k, sk({0, 1, 0}), false), 0, 1, 0));
    assert(is(apply(k, {0, 0, 0}), 0, 3.2, -6));
    // In general node(B p) == B (M p): check points of parented / yaw+pitch+roll poses.
    for (const SSDBObjectInfo *o : {&ledL, &ledR, &camStage, &pj}) {
        k = ssdb_matrix_to_scenekit(o->world);
        for (SSDBVec3 p : {SSDBVec3{0, 0, 0}, SSDBVec3{1, 2, 3}, SSDBVec3{-3, 1.5, -0.5}}) {
            SSDBVec3 want = sk(apply(o->world, p));
            assert(is(apply(k, sk(p)), want.x, want.y, want.z));
        }
    }

    // Bad geometry rows are skipped with a warning; the scene itself still loads.
    const char *tmp = "ssdcheck_objects.sscene";
    std::FILE *f = std::fopen(tmp, "w");
    std::fputs((kHead + "[OBJECT]\n"
                        "s\tscreen\tS\tnone\t0\t0\t0\t0\t0\t0\t1\n"
                        "c\tcamera\tC\tnone\t0\t0\t0\t0\t0\t0\t1\n"
                        "p\tprojector\tP\tnone\t0\t0\t0\t0\t0\t0\t1\n"
                        "[SCREEN]\ns\t0\t2\n"                             // Width 0
                        "[CAMERA]\ns\t60\t40\t1\t1\nc\t180\t40\t1\t1\n"   // wrong Type, FovH 180
                        "[PROJECTOR]\np\to\tc\t1\t1\n"                    // target is a camera
                        "[BOX]\nmissing\t1\t1\t1\n")                      // no such OBJECT
                   .c_str(), f);
    std::fclose(f);
    n = loadObjects(tmp);
    std::remove(tmp);
    assert(n == 3);
    for (int i = 0; i < n; ++i)
        assert(!objects[i].hasRect && !objects[i].hasCamera && !objects[i].hasBox && objects[i].target == -1);
    for (const char *w : {"[SCREEN] row ignored: line 11: Width must be > 0", "[CAMERA] row ignored: line 13: OBJECT s has Type",
                          "[CAMERA] row ignored: line 14: FovH", "[PROJECTOR] row ignored: line 16: TargetID 'c'",
                          "[BOX] row ignored: line 18: no OBJECT"}) {
        if (!std::strstr(warnings, w)) std::printf("missing warning '%s' in:\n%s\n", w, warnings);
        assert(std::strstr(warnings, w));
    }
    assert(ssdb_load_objects("../Examples/missing.sscene", objects, SSDB_MAX_OBJECTS, warnings, sizeof warnings,
                             err, sizeof err) == -1 && err[0]);
}

int main() {
    readerChecks();
    objectChecks();

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

    // FIL-v1: a real-room export with sections this app does not read ([DEVICE], [EVIDENCE], [LIGHT], ...).
    n = load("../Examples/FIL-v1.sscene");
    assert(n == 16 && warnings[0] == '\0');
    assert(byName(n, "Front C").channel == 1 && byName(n, "Extra rear-right").channel == 16);
    n = loadObjects("../Examples/FIL-v1.sscene");
    assert(n == 35 && warnings[0] == '\0');  // 1 room + 16 speakers + 16 lights + projector + wall image
    const SSDBObjectInfo &wall = objects[objectIndex(n, "projection-wall-01")];
    assert(wall.hasRect && near(wall.width, 3.9) && is(apply(wall.world, {0, 0, 1}, false), -1, 0, 0)); // faces -X
    // The surveyed projector pose does not aim at that wall: along this app's assumed optical axis
    // (local -Z) it faces world -X. Kept as surveyed, see the file's header comment.
    assert(is(apply(objects[objectIndex(n, "projector-01")].world, {0, 0, -1}, false), -1, 0, 0));

    assert(ssdb_load_scene("../Examples/missing.sscene", &info, sp, SSDB_MAX_SPEAKERS, warnings,
                           sizeof warnings, err, sizeof err) == -1 && err[0]);
    std::puts("ssdcheck OK");
    return 0;
}
