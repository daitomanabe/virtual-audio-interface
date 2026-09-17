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
