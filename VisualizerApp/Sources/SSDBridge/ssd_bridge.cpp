#include "include/ssd_bridge.h"
#include "ssd/Scene.h"
#include <cstring>

namespace {
void copyText(char *dst, size_t capacity, const std::string &src) {
    if (!dst || capacity == 0) return;
    std::strncpy(dst, src.c_str(), capacity - 1);
    dst[capacity - 1] = '\0';
}
} // namespace

extern "C" SSDBVec3 ssdb_to_scenekit(double x, double y, double z) {
    ssd::Vec3 p = ssd::toOpenFrameworks({x, y, z}); // same +Z-up -> +Y-up right-handed rotation
    return {p.x, p.y, p.z};
}

extern "C" int32_t ssdb_load_scene(const char *path, SSDBSceneInfo *outInfo,
                                   SSDBSpeakerInfo *outSpeakers, int32_t maxSpeakers,
                                   char *outWarnings, int32_t warningsCapacity,
                                   char *outErrorMessage, int32_t errorMessageCapacity) {
    try {
        ssd::Scene scene = ssd::load(path);
        std::vector<std::string> warnings = scene.warnings;

        *outInfo = SSDBSceneInfo{};
        copyText(outInfo->name, sizeof outInfo->name, scene.property("Name"));
        const auto &volume = scene.rows("REVIEW_VOLUME"); // not validated by Scene.h
        if (!volume.empty()) {
            try {
                outInfo->reviewWidth = ssd::number(volume[0], 0);
                outInfo->reviewDepth = ssd::number(volume[0], 1);
                outInfo->reviewHeight = ssd::number(volume[0], 2);
                outInfo->hasReviewVolume = true;
            } catch (const std::exception &e) {
                warnings.push_back(std::string("REVIEW_VOLUME ignored: ") + e.what());
            }
        }

        int32_t count = 0;
        const auto &rows = scene.rows("SPEAKER");
        for (const auto &row : rows) {
            if (count >= maxSpeakers) {
                warnings.push_back("Only the first " + std::to_string(maxSpeakers) + " of " +
                                   std::to_string(rows.size()) + " SPEAKER rows are shown");
                break;
            }
            const std::string &id = row[0];
            ssd::Vec3 p = scene.world(id).point({0, 0, 0});
            SSDBSpeakerInfo &out = outSpeakers[count++];
            out = SSDBSpeakerInfo{};
            copyText(out.objectId, sizeof out.objectId, id);
            copyText(out.name, sizeof out.name, scene.objects.at(id).name);
            out.channel = static_cast<int32_t>(ssd::number(row, 1)); // validated 1..INT32_MAX
            out.gainDb = ssd::number(row, 2);
            out.delayMs = ssd::number(row, 3);
            out.mute = ssd::flag(row, 4);
            out.active = scene.active(id);
            out.x = p.x;
            out.y = p.y;
            out.z = p.z;
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
