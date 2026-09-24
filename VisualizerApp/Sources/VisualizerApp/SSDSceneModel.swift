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

/// One OBJECT row (speakers included) with the geometry rows the Monitor tab draws.
struct SceneObject: Identifiable {
    let id: Int                          // OBJECT row index in the file
    let objectID: String
    let type: String
    let name: String
    let parent: Int?                     // index into SSDSceneModel.objects
    let active: Bool                     // Enabled, including disabled ancestors
    let rotation: simd_double3x3         // SSD world pose: p_world = rotation * p_local + position
    let position: SIMD3<Double>
    let sceneKitTransform: simd_float4x4 // the same pose for a SceneKit node (B·M·B⁻¹, via the bridge)
    let rect: SIMD2<Double>?             // SCREEN / SURFACE / LED width, height (m); local X right, Y up, +Z front
    let pixels: SIMD2<Int>?              // LED pixel width, height
    let box: SIMD3<Double>?              // BOX size x, y, z (m), centered
    let fov: SIMD3<Double>?              // FOV horizontal°, vertical°, distance (m)
    let cameraFov: SIMD2<Double>?        // CAMERA FovH°, FovV°
    let target: Int?                     // PROJECTOR TargetID, index into SSDSceneModel.objects

    func world(_ local: SIMD3<Double>) -> SIMD3<Double> { rotation * local + position }
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
    /// Every OBJECT in file order, speakers included.
    @Published private(set) var objects: [SceneObject] = []
    @Published private(set) var sceneName = ""
    @Published private(set) var warnings: [String] = []
    /// REVIEW_VOLUME width/depth/height: context only, never drawn or used for placement.
    @Published private(set) var reviewVolume: SIMD3<Double>?
    @Published private(set) var loadError: String?
    @Published private(set) var path: String?
    /// Bumped whenever the shown scene changes (load, reload, file change), so views rebuild their nodes.
    @Published private(set) var generation = 0
    /// Bumped when views should re-frame the camera: Open / Reload, or the first good read of a file.
    /// Reloads caused by saving the file keep the user's view.
    @Published private(set) var framing = 0
    /// Last successful read; `reloaded` is false for the first read of a file.
    @Published private(set) var loadedAt: Date?
    @Published private(set) var reloaded = false

    /// File the shown scene was read from. A failed read of that same file (e.g. a half-saved
    /// edit) keeps showing it; a failed read of another file clears it.
    private var shownPath: String?
    private var watcher: FileWatcher?

    /// True while an error is shown on top of the last valid version of the same file.
    var showsLastValidScene: Bool { loadError != nil && shownPath != nil && shownPath == path }

    func load(path: String) { read(path, reframe: true) }

    func reload() {
        if let path { read(path, reframe: true) }
    }

    private func read(_ path: String, reframe: Bool) {
        self.path = path
        DebugLog.shared.add("Loading \(URL(fileURLWithPath: path).lastPathComponent)\(reframe ? "" : " (file changed)" )")
        if watcher?.path != path {
            watcher = FileWatcher(path: path) { [weak self] in self?.read(path, reframe: false) }
        }

        var info = SSDBSceneInfo()
        var speakerBuffer = [SSDBSpeakerInfo](repeating: SSDBSpeakerInfo(), count: Int(SSDB_MAX_SPEAKERS))
        var objectBuffer = [SSDBObjectInfo](repeating: SSDBObjectInfo(), count: Int(SSDB_MAX_OBJECTS))
        var warningText = [CChar](repeating: 0, count: 8192)
        var objectWarningText = [CChar](repeating: 0, count: 8192)
        var errorText = [CChar](repeating: 0, count: 512)
        let count = ssdb_load_scene(path, &info, &speakerBuffer, SSDB_MAX_SPEAKERS,
                                    &warningText, Int32(warningText.count), &errorText, Int32(errorText.count))
        // A second parse of the same path: if the file changed in between, its change event reloads again.
        let objectCount = count < 0 ? -1 : ssdb_load_objects(path, &objectBuffer, SSDB_MAX_OBJECTS,
                                                              &objectWarningText, Int32(objectWarningText.count),
                                                              &errorText, Int32(errorText.count))
        guard count >= 0, objectCount >= 0 else {
            loadError = String(cString: errorText)
            DebugLog.shared.add("Scene load failed: \(loadError ?? "unknown error")")
            if shownPath != path {
                speakers = []; objects = []; warnings = []; sceneName = ""; reviewVolume = nil; loadedAt = nil
                shownPath = nil
                generation += 1
            }
            return
        }
        loadError = nil
        sceneName = text(info.name)
        warnings = (String(cString: warningText) + "\n" + String(cString: objectWarningText))
            .split(separator: "\n").map(String.init)
        reviewVolume = info.hasReviewVolume ? SIMD3(info.reviewWidth, info.reviewDepth, info.reviewHeight) : nil
        speakers = speakerBuffer.prefix(Int(count)).enumerated().map { i, s in
            Speaker(id: i, objectID: text(s.objectId), name: text(s.name), channel: Int(s.channel),
                    gainDb: s.gainDb, delayMs: s.delayMs, mute: s.mute, active: s.active,
                    position: SIMD3(s.x, s.y, s.z))
        }
        .sorted { ($0.channel, $0.id) < ($1.channel, $1.id) }
        objects = objectBuffer.prefix(Int(objectCount)).enumerated().map { i, o in sceneObject(i, o) }

        reloaded = shownPath == path
        if reframe || !reloaded { framing += 1 }
        shownPath = path
        loadedAt = Date()
        generation += 1
        DebugLog.shared.add("Scene loaded: \(objects.count) objects, \(speakers.count) mapped speaker rows, \(Set(speakers.filter { $0.active && !$0.mute }.map(\.channel)).count) playable channels, \(warnings.count) warnings")
        if speakers.isEmpty {
            DebugLog.shared.add("No [SPEAKER] channel mapping. Step: SSD speakers has no channels; speaker OBJECT rows alone do not define routing.")
        }
        for warning in warnings { DebugLog.shared.add("SSD warning: \(warning)") }
    }
}

private func sceneObject(_ index: Int, _ o: SSDBObjectInfo) -> SceneObject {
    let w = doubles(o.world.m)
    let k = doubles(ssdb_matrix_to_scenekit(o.world).m)
    func column(_ c: Int, _ last: Float) -> SIMD4<Float> { SIMD4(Float(k[c]), Float(k[4 + c]), Float(k[8 + c]), last) }
    return SceneObject(
        id: index, objectID: text(o.objectId), type: text(o.type), name: text(o.name),
        parent: o.parent >= 0 ? Int(o.parent) : nil, active: o.active,
        rotation: simd_double3x3(rows: [SIMD3(w[0], w[1], w[2]), SIMD3(w[4], w[5], w[6]), SIMD3(w[8], w[9], w[10])]),
        position: SIMD3(w[3], w[7], w[11]),
        sceneKitTransform: simd_float4x4(columns: (column(0, 0), column(1, 0), column(2, 0), column(3, 1))),
        rect: o.hasRect ? SIMD2(o.width, o.height) : nil,
        pixels: o.pixelWidth > 0 && o.pixelHeight > 0 ? SIMD2(Int(o.pixelWidth), Int(o.pixelHeight)) : nil,
        box: o.hasBox ? SIMD3(o.sizeX, o.sizeY, o.sizeZ) : nil,
        fov: o.hasFov ? SIMD3(o.fovHorizontal, o.fovVertical, o.fovDistance) : nil,
        cameraFov: o.hasCamera ? SIMD2(o.cameraFovH, o.cameraFovV) : nil,
        target: o.target >= 0 ? Int(o.target) : nil)
}

/// Fixed-size C double array (imported as a tuple) -> [Double].
private func doubles<T>(_ tuple: T) -> [Double] {
    withUnsafeBytes(of: tuple) { Array($0.bindMemory(to: Double.self)) }
}

/// Fixed-size C char array (imported as a tuple) -> String.
private func text<T>(_ tuple: T) -> String {
    withUnsafeBytes(of: tuple) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
}
