#include "include/ssd_bridge.h"
#include "ssd/Scene.h"
#include <cstring>

extern "C" int32_t ssdb_load_speakers(const char *path, SSDBSpeaker *outSpeakers, int32_t maxSpeakers,
                                       char *outErrorMessage, int32_t errorMessageCapacity) {
    try {
        ssd::Scene scene = ssd::load(path);
        int32_t count = 0;
        for (const auto &row : scene.rows("SPEAKER")) {
            if (count >= maxSpeakers) break;
            const std::string &objectId = row[0];
            ssd::Vec3 worldPos = scene.world(objectId).point({0, 0, 0});
            // SSD -> SceneKit axis conversion (right-handed, +Y up):
            // ssd (x, y, z), z-up  =>  scenekit (x, z, -y), y-up
            SSDBSpeaker &out = outSpeakers[count];
            out.channel = static_cast<int32_t>(ssd::number(row, 1));
            out.x = worldPos.x;
            out.y = worldPos.z;
            out.z = -worldPos.y;
            out.gain = ssd::number(row, 2);
            out.mute = ssd::flag(row, 4);
            ++count;
        }
        return count;
    } catch (const std::exception &e) {
        if (outErrorMessage && errorMessageCapacity > 0) {
            std::strncpy(outErrorMessage, e.what(), errorMessageCapacity - 1);
            outErrorMessage[errorMessageCapacity - 1] = '\0';
        }
        return -1;
    }
}
