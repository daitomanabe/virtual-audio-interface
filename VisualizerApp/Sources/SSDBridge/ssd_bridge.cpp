#include "include/ssd_bridge.h"
#include "ssd_reader.h"
#include <algorithm>
#include <cstring>

namespace {
void copyText(char *dst, size_t capacity, const std::string &src) {
    if (!dst || capacity == 0) return;
    size_t n = std::min(src.size(), capacity - 1);
    while (n > 0 && n < src.size() && (static_cast<unsigned char>(src[n]) & 0xC0) == 0x80) --n; // don't split a UTF-8 sequence
    std::memcpy(dst, src.data(), n);
    dst[n] = '\0';
}
} // namespace

extern "C" SSDBVec3 ssdb_to_scenekit(double x, double y, double z) {
    return {x, z, -y}; // +Z-up -> +Y-up, a right-handed rotation about X
}

extern "C" int32_t ssdb_load_scene(const char *path, SSDBSceneInfo *outInfo,
                                   SSDBSpeakerInfo *outSpeakers, int32_t maxSpeakers,
                                   char *outWarnings, int32_t warningsCapacity,
                                   char *outErrorMessage, int32_t errorMessageCapacity) {
    try {
        ssdreader::Scene scene = ssdreader::load(path);
        std::vector<std::string> warnings = scene.warnings;

        *outInfo = SSDBSceneInfo{};
        auto name = scene.properties.find("Name");
        if (name != scene.properties.end()) copyText(outInfo->name, sizeof outInfo->name, name->second);
        const auto &volume = scene.sections["REVIEW_VOLUME"]; // context only: bad values warn, not fail
        if (!volume.empty()) {
            try {
                outInfo->reviewWidth = ssdreader::number(volume[0], 0, "Width");
                outInfo->reviewDepth = ssdreader::number(volume[0], 1, "Depth");
                outInfo->reviewHeight = ssdreader::number(volume[0], 2, "Height");
                outInfo->hasReviewVolume = true;
            } catch (const std::exception &e) {
                warnings.push_back(std::string("REVIEW_VOLUME ignored: ") + e.what());
            }
        }

        int32_t count = 0;
        for (const auto &speaker : scene.speakers) {
            if (count >= maxSpeakers) {
                warnings.push_back("Only the first " + std::to_string(maxSpeakers) + " of " +
                                   std::to_string(scene.speakers.size()) + " SPEAKER rows are shown");
                break;
            }
            const ssdreader::Object &object = scene.objects.at(speaker.id);
            SSDBSpeakerInfo &out = outSpeakers[count++];
            out = SSDBSpeakerInfo{};
            copyText(out.objectId, sizeof out.objectId, speaker.id);
            copyText(out.name, sizeof out.name, object.name);
            out.channel = speaker.channel;
            out.gainDb = speaker.gainDb;
            out.delayMs = speaker.delayMs;
            out.mute = speaker.mute;
            out.active = object.active;
            out.x = object.world.t[0];
            out.y = object.world.t[1];
            out.z = object.world.t[2];
        }

        std::string joined;
        for (const auto &w : warnings) joined += (joined.empty() ? "" : "\n") + w;
        copyText(outWarnings, warningsCapacity > 0 ? size_t(warningsCapacity) : 0, joined);
        return count;
    } catch (const std::exception &e) {
        copyText(outErrorMessage, errorMessageCapacity > 0 ? size_t(errorMessageCapacity) : 0, e.what());
        return -1;
    }
}

extern "C" SSDBMatrix ssdb_matrix_to_scenekit(SSDBMatrix in) {
    double b[3][3]; // columns: the SSD axes mapped by ssdb_to_scenekit. A rotation, so B^-1 = B^T.
    for (int j = 0; j < 3; ++j) {
        SSDBVec3 c = ssdb_to_scenekit(j == 0, j == 1, j == 2);
        b[0][j] = c.x, b[1][j] = c.y, b[2][j] = c.z;
    }
    SSDBMatrix out{};
    for (int i = 0; i < 3; ++i) {
        for (int j = 0; j < 3; ++j) {
            double s = 0; // (B R B^T)_ij
            for (int k = 0; k < 3; ++k)
                for (int l = 0; l < 3; ++l) s += b[i][k] * in.m[k * 4 + l] * b[j][l];
            out.m[i * 4 + j] = s;
        }
        for (int k = 0; k < 3; ++k) out.m[i * 4 + 3] += b[i][k] * in.m[k * 4 + 3]; // B t
    }
    return out;
}

extern "C" int32_t ssdb_load_objects(const char *path, SSDBObjectInfo *outObjects, int32_t maxObjects,
                                     char *outWarnings, int32_t warningsCapacity,
                                     char *outErrorMessage, int32_t errorMessageCapacity) {
    using ssdreader::Row;
    try {
        ssdreader::Scene scene = ssdreader::load(path);
        std::vector<std::string> warnings;

        std::map<std::string, int32_t> index; // OBJECT ID -> output slot, file order
        const auto &rows = scene.sections["OBJECT"];
        for (const Row &r : rows) {
            if (int32_t(index.size()) >= maxObjects) {
                warnings.push_back("Only the first " + std::to_string(maxObjects) + " of " +
                                   std::to_string(rows.size()) + " OBJECT rows are shown");
                break;
            }
            index.emplace(r.cells[0], int32_t(index.size()));
        }
        for (const auto &[id, i] : index) {
            const ssdreader::Object &o = scene.objects.at(id);
            SSDBObjectInfo &out = outObjects[i];
            out = SSDBObjectInfo{};
            copyText(out.objectId, sizeof out.objectId, id);
            copyText(out.type, sizeof out.type, o.type);
            copyText(out.name, sizeof out.name, o.name);
            auto parent = index.find(o.parent);
            out.parent = parent == index.end() ? -1 : parent->second;
            out.active = o.active;
            for (int r = 0; r < 3; ++r) {
                for (int c = 0; c < 3; ++c) out.world.m[r * 4 + c] = o.world.r[r][c];
                out.world.m[r * 4 + 3] = o.world.t[r];
            }
            out.target = -1;
        }

        // Geometry rows: a bad row is skipped with a warning, the rest of the scene still loads.
        // Each apply() validates everything before setting its has* flag.
        auto positive = [](const Row &r, size_t col, const char *field) {
            const double v = ssdreader::number(r, col, field);
            if (v <= 0) ssdreader::fail(r.line, std::string(field) + " must be > 0, got '" + r.cells[col] + "'");
            return v;
        };
        auto angle = [](const Row &r, size_t col, const char *field) {
            const double v = ssdreader::number(r, col, field);
            if (v <= 0 || v >= 180)
                ssdreader::fail(r.line, std::string(field) + " must be in (0, 180) degrees, got '" + r.cells[col] + "'");
            return v;
        };
        auto requireType = [](const Row &r, const ssdreader::Object &o, const std::string &type) {
            if (o.type != type)
                ssdreader::fail(r.line, "OBJECT " + r.cells[0] + " has Type '" + o.type + "', expected '" + type + "'");
        };
        auto each = [&](const std::string &section, auto &&apply) {
            std::set<std::string> seen;
            for (const Row &r : scene.sections[section]) {
                try {
                    auto object = scene.objects.find(r.cells[0]);
                    if (object == scene.objects.end()) ssdreader::fail(r.line, "no OBJECT with ID '" + r.cells[0] + "'");
                    if (!seen.insert(r.cells[0]).second) ssdreader::fail(r.line, "duplicate row for " + r.cells[0]);
                    SSDBObjectInfo scratch{}; // objects cut off by maxObjects are still validated
                    auto slot = index.find(r.cells[0]);
                    apply(r, object->second, slot == index.end() ? scratch : outObjects[slot->second]);
                } catch (const ssdreader::Error &e) {
                    warnings.push_back("[" + section + "] row ignored: " + e.what());
                }
            }
        };
        static const std::pair<const char *, const char *> rects[] = {
            {"SCREEN", "screen"}, {"SURFACE", "surface"}, {"LED", "led"}};
        for (const auto &rect : rects) {
            each(rect.first, [&](const Row &r, const ssdreader::Object &o, SSDBObjectInfo &out) {
                requireType(r, o, rect.second);
                const double w = positive(r, 1, "Width"), h = positive(r, 2, "Height");
                if (rect.second == std::string("led")) {
                    out.pixelWidth = ssdreader::integer(r, 3, "PixelWidth", 1);
                    out.pixelHeight = ssdreader::integer(r, 4, "PixelHeight", 1);
                }
                out.width = w, out.height = h, out.hasRect = true;
            });
        }
        each("BOX", [&](const Row &r, const ssdreader::Object &, SSDBObjectInfo &out) {
            const double x = positive(r, 1, "SizeX"), y = positive(r, 2, "SizeY"), z = positive(r, 3, "SizeZ");
            out.sizeX = x, out.sizeY = y, out.sizeZ = z, out.hasBox = true;
        });
        each("FOV", [&](const Row &r, const ssdreader::Object &, SSDBObjectInfo &out) {
            const double h = angle(r, 1, "Horizontal"), v = angle(r, 2, "Vertical"), d = positive(r, 3, "Distance");
            out.fovHorizontal = h, out.fovVertical = v, out.fovDistance = d, out.hasFov = true;
        });
        each("CAMERA", [&](const Row &r, const ssdreader::Object &o, SSDBObjectInfo &out) {
            requireType(r, o, "camera");
            const double h = angle(r, 1, "FovH"), v = angle(r, 2, "FovV");
            out.cameraFovH = h, out.cameraFovV = v, out.hasCamera = true;
        });
        each("PROJECTOR", [&](const Row &r, const ssdreader::Object &o, SSDBObjectInfo &out) {
            requireType(r, o, "projector");
            auto target = scene.objects.find(r.cells[2]);
            if (target == scene.objects.end() ||
                (target->second.type != "screen" && target->second.type != "surface" && target->second.type != "led"))
                ssdreader::fail(r.line, "TargetID '" + r.cells[2] + "' is not a screen/surface/led OBJECT");
            auto slot = index.find(r.cells[2]);
            out.target = slot == index.end() ? -1 : slot->second;
        });

        std::string joined;
        for (const auto &w : warnings) joined += (joined.empty() ? "" : "\n") + w;
        copyText(outWarnings, warningsCapacity > 0 ? size_t(warningsCapacity) : 0, joined);
        return int32_t(index.size());
    } catch (const std::exception &e) {
        copyText(outErrorMessage, errorMessageCapacity > 0 ? size_t(errorMessageCapacity) : 0, e.what());
        return -1;
    }
}

extern "C" int32_t ssdb_load_speakers(const char *path, SSDBSpeaker *outSpeakers, int32_t maxSpeakers,
                                       char *outErrorMessage, int32_t errorMessageCapacity) {
    std::vector<SSDBSpeakerInfo> info(maxSpeakers > 0 ? size_t(maxSpeakers) : 0);
    SSDBSceneInfo sceneInfo;
    int32_t n = ssdb_load_scene(path, &sceneInfo, info.data(), maxSpeakers, nullptr, 0,
                                outErrorMessage, errorMessageCapacity);
    for (int32_t i = 0; i < n; ++i) {
        SSDBVec3 p = ssdb_to_scenekit(info[i].x, info[i].y, info[i].z);
        outSpeakers[i] = {info[i].channel, p.x, p.y, p.z, info[i].gainDb, info[i].mute};
    }
    return n;
}
