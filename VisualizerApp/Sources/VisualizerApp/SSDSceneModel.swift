import Foundation
import SceneKit
import SSDBridge

struct Speaker: Identifiable {
    let id: Int                    // SPEAKER row index in the file (channels may repeat)
    let objectID: String
    let name: String
    let channel: Int               // 1-based
    let gainDb: Double
    let delayMs: Double
    let mute: Bool
    let active: Bool               // Enabled, including disabled ancestors
    let position: SIMD3<Double>    // SSD world, meters: x right, y front, z up
}

/// SSD point/direction -> SceneKit. Always go through the bridge's single mapping.
func scenekit(_ p: SIMD3<Double>) -> SCNVector3 {
    let v = ssdb_to_scenekit(p.x, p.y, p.z)
    return SCNVector3(v.x, v.y, v.z)
}

@MainActor
final class SSDSceneModel: ObservableObject {
    /// Sorted by channel, then file order.
    @Published private(set) var speakers: [Speaker] = []
    @Published private(set) var sceneName = ""
    @Published private(set) var warnings: [String] = []
    /// REVIEW_VOLUME width/depth/height: context only, never drawn or used for placement.
    @Published private(set) var reviewVolume: SIMD3<Double>?
    @Published private(set) var loadError: String?
    @Published private(set) var path: String?
    /// Bumped on every load(), including reloads, so views rebuild their nodes.
    @Published private(set) var generation = 0

    func load(path: String) {
        var info = SSDBSceneInfo()
        var buffer = [SSDBSpeakerInfo](repeating: SSDBSpeakerInfo(), count: Int(SSDB_MAX_SPEAKERS))
        var warningText = [CChar](repeating: 0, count: 8192)
        var errorText = [CChar](repeating: 0, count: 512)
        let count = ssdb_load_scene(path, &info, &buffer, SSDB_MAX_SPEAKERS,
                                    &warningText, Int32(warningText.count), &errorText, Int32(errorText.count))
        self.path = path
        generation += 1
        guard count >= 0 else {
            loadError = String(cString: errorText)
            speakers = []; warnings = []; sceneName = ""; reviewVolume = nil
            return
        }
        loadError = nil
        sceneName = text(info.name)
        warnings = String(cString: warningText).split(separator: "\n").map(String.init)
        reviewVolume = info.hasReviewVolume ? SIMD3(info.reviewWidth, info.reviewDepth, info.reviewHeight) : nil
        speakers = buffer.prefix(Int(count)).enumerated().map { i, s in
            Speaker(id: i, objectID: text(s.objectId), name: text(s.name), channel: Int(s.channel),
                    gainDb: s.gainDb, delayMs: s.delayMs, mute: s.mute, active: s.active,
                    position: SIMD3(s.x, s.y, s.z))
        }
        .sorted { ($0.channel, $0.id) < ($1.channel, $1.id) }
    }

    func reload() {
        if let path { load(path: path) }
    }
}

/// Fixed-size C char array (imported as a tuple) -> String.
private func text<T>(_ tuple: T) -> String {
    withUnsafeBytes(of: tuple) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
}
