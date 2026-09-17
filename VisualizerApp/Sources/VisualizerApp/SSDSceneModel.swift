import Foundation
import SSDBridge

struct Speaker: Identifiable {
    let id: Int32          // channel number, used as SwiftUI identity
    let channel: Int32
    let x, y, z: Double    // already in SceneKit space (right-handed, +Y up)
    let gain: Double
    let mute: Bool
}

@MainActor
final class SSDSceneModel: ObservableObject {
    @Published var speakers: [Speaker] = []
    @Published var loadError: String?
    /// Bumped on every load() call, including reloads of a .sscene with the
    /// same speaker count, so observers can detect "loaded again" separately
    /// from "speaker count changed".
    @Published var generation: Int = 0

    func load(path: String) {
        generation += 1
        var buffer = [SSDBSpeaker](repeating: SSDBSpeaker(), count: Int(SSDB_MAX_SPEAKERS))
        var errorMessage = [CChar](repeating: 0, count: 256)
        let count = path.withCString { cPath in
            buffer.withUnsafeMutableBufferPointer { bufPtr in
                errorMessage.withUnsafeMutableBufferPointer { errPtr in
                    ssdb_load_speakers(cPath, bufPtr.baseAddress, Int32(SSDB_MAX_SPEAKERS),
                                       errPtr.baseAddress, Int32(errPtr.count))
                }
            }
        }
        if count < 0 {
            loadError = String(cString: errorMessage)
            speakers = []
            return
        }
        loadError = nil
        speakers = (0..<Int(count)).map { i in
            let s = buffer[i]
            return Speaker(id: s.channel, channel: s.channel, x: s.x, y: s.y, z: s.z,
                            gain: s.gain, mute: s.mute)
        }
    }
}

extension SSDBSpeaker {
    init() { self.init(channel: 0, x: 0, y: 0, z: 0, gain: 0, mute: false) }
}
