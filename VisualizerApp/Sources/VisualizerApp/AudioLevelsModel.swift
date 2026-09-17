import Foundation
import AudioBridge

/// Polls the HAL plugin's shared-memory meter struct at ~30Hz.
/// ponytail: polling instead of a push/notify mechanism (e.g. Mach port
/// signal) — simplest thing that works for a meter; revisit only if 30Hz
/// polling shows up as real CPU cost.
@MainActor
final class AudioLevelsModel: ObservableObject {
    static let channelCount = 128
    @Published var levels: [Float] = Array(repeating: 0, count: channelCount)

    private var timer: Timer?

    init() {
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    deinit {
        timer?.invalidate()
        abrClose()
    }

    // ponytail: fixed decay constant, tune if 30Hz feels too slow/fast to
    // read; per-channel-configurable decay would be premature here.
    private let decay: Float = 0.85

    private func tick() {
        var buffer = [Float](repeating: 0, count: Self.channelCount)
        let n = buffer.withUnsafeMutableBufferPointer { ptr -> UInt32 in
            abrReadLevels(ptr.baseAddress, UInt32(Self.channelCount))
        }
        if n > 0 {
            // Shared memory is overwritten every IO cycle (~ms), so a raw
            // 30Hz poll misses transients between polls. Peak-hold + decay
            // so a brief spike stays visible.
            for i in 0..<Self.channelCount {
                levels[i] = max(buffer[i], levels[i] * decay)
            }
        }
    }
}
