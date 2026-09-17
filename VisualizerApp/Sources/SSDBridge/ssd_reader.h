// SSD (Spatial Scene Definition) v0.1 reader written for this repository (MIT License, see LICENSE).
// Covers what the Monitor tab reads (SCENE, OBJECT world poses, SPEAKER, REVIEW_VOLUME) plus the
// format's mandatory checks. Header-only C++17, standard library only, internal to SSDBridge.
#pragma once
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <fstream>
#include <locale>
#include <map>
#include <set>
#include <sstream>
#include <stdexcept>
#include <string>
#include <string_view>
#include <vector>

namespace ssdreader {

struct Error : std::runtime_error {
    using std::runtime_error::runtime_error;
};

[[noreturn]] inline void fail(int line, const std::string &message) {
    throw Error("line " + std::to_string(line) + ": " + message);
}

struct Row {
    int line = 0;
    std::vector<std::string> cells; // tab-separated, untrimmed, positional
};

// Affine transform, column vectors: p_parent = r * p_local + t.
struct Pose {
    double r[3][3] = {{1, 0, 0}, {0, 1, 0}, {0, 0, 1}};
    double t[3] = {0, 0, 0};
};

inline Pose operator*(const Pose &a, const Pose &b) {
    Pose m;
    for (int i = 0; i < 3; ++i) {
        for (int j = 0; j < 3; ++j)
            m.r[i][j] = a.r[i][0] * b.r[0][j] + a.r[i][1] * b.r[1][j] + a.r[i][2] * b.r[2][j];
        m.t[i] = a.r[i][0] * b.t[0] + a.r[i][1] * b.t[1] + a.r[i][2] * b.t[2] + a.t[i];
    }
    return m;
}

// Right-handed rotations in degrees about the fixed parent axes:
// R = Ry(Roll) * Rx(Pitch) * Rz(Yaw), M_local = T(X,Y,Z) * R.
inline Pose localPose(double x, double y, double z, double yaw, double pitch, double roll) {
    const double toRad = std::acos(-1.0) / 180.0;
    auto axis = [&](int a, double degrees) { // rotation about axis a (0 = X, 1 = Y, 2 = Z)
        Pose p;
        const double c = std::cos(degrees * toRad), s = std::sin(degrees * toRad);
        const int u = (a + 1) % 3, v = (a + 2) % 3; // (u, v, a) is right-handed
        p.r[u][u] = c, p.r[u][v] = -s;
        p.r[v][u] = s, p.r[v][v] = c;
        return p;
    };
    Pose m = axis(1, roll) * axis(0, pitch) * axis(2, yaw);
    m.t[0] = x, m.t[1] = y, m.t[2] = z;
    return m;
}

// Decimal or scientific notation with a period, e.g. 1, -0.5, .5, 2.5e-1. Rejects surrounding
// whitespace, leading '+', hex, NaN/Inf, empty cells, placeholders like TBD and overflow.
inline double number(const Row &row, size_t col, const char *field) {
    if (col >= row.cells.size()) fail(row.line, std::string(field) + " is missing");
    const std::string &s = row.cells[col];
    size_t i = 0;
    auto digits = [&] {
        size_t n = 0;
        for (; i < s.size() && s[i] >= '0' && s[i] <= '9'; ++i) ++n;
        return n;
    };
    if (i < s.size() && s[i] == '-') ++i;
    size_t mantissa = digits();
    if (i < s.size() && s[i] == '.') ++i, mantissa += digits();
    bool ok = mantissa > 0;
    if (ok && i < s.size() && (s[i] == 'e' || s[i] == 'E')) {
        ++i;
        if (i < s.size() && (s[i] == '+' || s[i] == '-')) ++i;
        ok = digits() > 0;
    }
    double value = 0;
    if (ok && i == s.size()) {
        std::istringstream in(s);
        in.imbue(std::locale::classic()); // never the host locale's decimal comma
        in >> value;
        ok = !in.fail() && std::isfinite(value);
    } else {
        ok = false;
    }
    if (!ok) fail(row.line, std::string(field) + " must be a finite decimal number, got '" + s + "'");
    return value;
}

// Any number above with an integral value (1, 007, 1.0 and 1e0 all mean 1).
inline int32_t integer(const Row &row, size_t col, const char *field, int32_t minimum) {
    const double value = number(row, col, field);
    if (value != std::floor(value) || value < minimum || value > INT32_MAX)
        fail(row.line, std::string(field) + " must be an integer in " + std::to_string(minimum) +
                           "..2147483647, got '" + row.cells[col] + "'");
    return static_cast<int32_t>(value);
}

inline bool flag(const Row &row, size_t col, const char *field) {
    const std::string &s = row.cells[col];
    if (s != "0" && s != "1") fail(row.line, std::string(field) + " must be 0 or 1, got '" + s + "'");
    return s == "1";
}

struct Object {
    std::string type, name, parent;
    bool enabled = true;
    int line = 0;
    Pose local, world; // world = M_parent_world * local
    bool active = true; // Enabled here and on every ancestor
    int depth = -1;     // parent links to a root; -1 unresolved, -2 while resolving
};

struct Speaker {
    std::string id;
    int32_t channel = 0;
    double gainDb = 0, delayMs = 0;
    bool mute = false;
};

struct Scene {
    std::map<std::string, std::string> properties;    // [SCENE] key -> value
    std::map<std::string, Object> objects;            // [OBJECT] by ID, world poses resolved
    std::vector<Speaker> speakers;                    // [SPEAKER] in file order
    std::map<std::string, std::vector<Row>> sections; // raw data rows of every section, unknown ones too
    std::vector<std::string> warnings;
};

// Well-formed UTF-8: no overlong forms, surrogates or code points above U+10FFFF.
inline bool validUtf8(std::string_view s) {
    for (size_t i = 0; i < s.size(); ++i) {
        const unsigned char lead = s[i];
        if (lead < 0x80) continue;
        const int extra = lead >= 0xC2 && lead <= 0xDF ? 1 : lead >= 0xE0 && lead <= 0xEF ? 2
                        : lead >= 0xF0 && lead <= 0xF4 ? 3 : 0;
        if (extra == 0 || i + extra >= s.size()) return false;
        uint32_t cp = lead & (0x3F >> extra);
        for (int k = 0; k < extra; ++k) {
            const unsigned char next = s[++i];
            if ((next & 0xC0) != 0x80) return false;
            cp = cp << 6 | (next & 0x3F);
        }
        if ((extra == 2 && (cp < 0x800 || (cp >= 0xD800 && cp <= 0xDFFF))) ||
            (extra == 3 && (cp < 0x10000 || cp > 0x10FFFF)))
            return false;
    }
    return true;
}

constexpr int kMaxParentDepth = 512;

inline void resolve(std::map<std::string, Object> &objects, const std::string &id, Object &o, int level) {
    if (o.depth >= 0) return;
    if (o.depth == -2) fail(o.line, "OBJECT " + id + " is part of a Parent cycle");
    if (level > kMaxParentDepth) fail(o.line, "Parent chain deeper than 512 at OBJECT " + id);
    if (o.parent == "none") {
        o.world = o.local, o.active = o.enabled, o.depth = 0;
        return;
    }
    auto parent = objects.find(o.parent);
    if (parent == objects.end()) fail(o.line, "OBJECT " + id + " has unknown Parent '" + o.parent + "'");
    o.depth = -2;
    resolve(objects, parent->first, parent->second, level + 1);
    const Object &p = parent->second;
    if (p.depth + 1 > kMaxParentDepth) fail(o.line, "Parent chain deeper than 512 at OBJECT " + id);
    o.world = p.world * o.local, o.active = o.enabled && p.active, o.depth = p.depth + 1;
}

inline Scene parse(std::string_view text) {
    // Minimum positional fields; trailing extension fields are allowed. Other known sections are
    // only checked for field count, unknown sections are kept with a warning.
    static const std::map<std::string_view, size_t> knownSections = {
        {"SCENE", 2},      {"OBJECT", 11},    {"SPEAKER", 5},    {"SCREEN", 3},
        {"SURFACE", 3},    {"LED", 5},        {"DISPLAY", 4},    {"PROJECTOR", 5},
        {"PIXELMAP", 8},   {"CAMERA", 5},     {"MICROPHONE", 3}, {"SENSOR", 2},
        {"TRACKER", 3},    {"LIGHT", 4},      {"ROBOT", 3},      {"EVIDENCE", 6},
        {"BOX", 4},        {"FOV", 5},        {"DEVICE", 3},     {"VISUAL_REQUIREMENT", 4},
        {"INVENTORY", 6},  {"SHARED_INVENTORY", 4},
        {"REVIEW_VOLUME", 1}, {"UNRESOLVED", 1}, // free-form context: never blocks loading
    };
    Scene scene;
    if (text.substr(0, 3) == "\xEF\xBB\xBF") text.remove_prefix(3);
    std::string section;
    int lineNumber = 0;
    for (size_t pos = 0; pos < text.size();) {
        size_t end = std::min(text.find('\n', pos), text.size());
        std::string_view line = text.substr(pos, end - pos);
        pos = end + 1;
        ++lineNumber;
        if (!line.empty() && line.back() == '\r') line.remove_suffix(1);
        if (!validUtf8(line)) fail(lineNumber, "not valid UTF-8");
        size_t first = line.find_first_not_of(" \t");
        if (first == std::string_view::npos || line[first] == '#') continue;
        if (line[first] == '[') {
            std::string_view header = line.substr(first, line.find_last_not_of(" \t") + 1 - first);
            std::string_view name = header.substr(1, header.size() - 2);
            if (header.size() < 3 || header.back() != ']' || name.find_first_of("[]") != std::string_view::npos)
                fail(lineNumber, "malformed section header '" + std::string(line) + "'");
            section = name;
            if (!knownSections.count(name) && !scene.sections.count(section))
                scene.warnings.push_back("Preserved unknown section [" + section + "]");
            scene.sections[section];
            continue;
        }
        if (section.empty()) fail(lineNumber, "data row before any [SECTION] header");
        Row row{lineNumber, {}};
        for (size_t start = 0;;) {
            size_t tab = std::min(line.find('\t', start), line.size());
            row.cells.emplace_back(line.substr(start, tab - start));
            if (tab == line.size()) break;
            start = tab + 1;
        }
        auto known = knownSections.find(section);
        if (known != knownSections.end() && row.cells.size() < known->second)
            fail(lineNumber, "[" + section + "] needs " + std::to_string(known->second) +
                                 " tab-separated fields, got " + std::to_string(row.cells.size()));
        scene.sections[section].push_back(std::move(row));
    }

    static const std::pair<const char *, const char *> required[] = {
        {"Version", "0.1"}, {"Unit", "meter"}, {"CoordinateSystem", "SSD_RH_ZUP"}, {"AngleUnit", "degree"}};
    for (const Row &r : scene.sections["SCENE"]) {
        if (!scene.properties.emplace(r.cells[0], r.cells[1]).second)
            fail(r.line, "duplicate [SCENE] key " + r.cells[0]);
        for (auto [key, value] : required)
            if (r.cells[0] == key && r.cells[1] != value)
                fail(r.line, std::string(key) + " must be " + value + ", got '" + r.cells[1] + "'");
    }
    for (auto [key, value] : required)
        if (!scene.properties.count(key)) throw Error(std::string("[SCENE] is missing required key ") + key);

    for (const Row &r : scene.sections["OBJECT"]) {
        const auto &c = r.cells;
        if (c[0].empty() || c[0] == "none") fail(r.line, "OBJECT ID must not be empty or 'none'");
        if (c[1].empty()) fail(r.line, "OBJECT " + c[0] + " has an empty Type");
        Object o;
        o.type = c[1], o.name = c[2], o.parent = c[3], o.line = r.line;
        o.local = localPose(number(r, 4, "X"), number(r, 5, "Y"), number(r, 6, "Z"), number(r, 7, "Yaw"),
                            number(r, 8, "Pitch"), number(r, 9, "Roll"));
        o.enabled = flag(r, 10, "Enabled");
        if (!scene.objects.emplace(c[0], std::move(o)).second) fail(r.line, "duplicate OBJECT ID " + c[0]);
    }
    for (auto &[id, object] : scene.objects) resolve(scene.objects, id, object, 0); // row order is irrelevant

    std::set<std::string> speakerIds;
    for (const Row &r : scene.sections["SPEAKER"]) {
        const std::string &id = r.cells[0];
        auto object = scene.objects.find(id);
        if (object == scene.objects.end() || object->second.type != "speaker")
            fail(r.line, "SPEAKER " + id + " must reference an OBJECT of Type speaker");
        if (!speakerIds.insert(id).second) fail(r.line, "duplicate SPEAKER row for " + id);
        Speaker s{id, integer(r, 1, "Channel", 1), number(r, 2, "Gain"), number(r, 3, "Delay"), flag(r, 4, "Mute")};
        if (s.delayMs < 0) fail(r.line, "Delay must be >= 0, got '" + r.cells[3] + "'");
        scene.speakers.push_back(std::move(s));
    }
    return scene;
}

inline Scene load(const std::string &path) {
    std::ifstream in(path, std::ios::binary);
    if (!in) throw Error("cannot open " + path);
    std::ostringstream text;
    text << in.rdbuf();
    return parse(text.str());
}

} // namespace ssdreader
