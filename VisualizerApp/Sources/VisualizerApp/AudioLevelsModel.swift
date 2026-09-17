import Foundation
import AudioBridge

/// Snapshot of the driver-decided (read-only) status half of the shm struct.
/// Mirrors VAIStatus (AudioBridge/include/audio_bridge.h).
struct DriverStatus {
    var channelCount: UInt32 = 0
    var sampleRate: Double = 0
    var ioBufferFrameSize: UInt32 = 0
    var isRunning: Bool = false
    var clientCount: UInt32 = 0
    var zeroTimeStampPeriod: UInt32 = 0
    var hostRequestedSampleRate: Double = 0
    var updateCounter: UInt64 = 0
    var configAppliedCounter: UInt64 = 0
    var configCounter: UInt64 = 0
    var available: Bool = false
}

/// Polls the HAL plugin's shared-memory meter struct at ~30Hz.
/// ponytail: polling instead of a push/notify mechanism (e.g. Mach port
/// signal) — simplest thing that works for a meter; revisit only if 30Hz
/// polling shows up as real CPU cost.
@MainActor
final class AudioLevelsModel: ObservableObject {
    static let channelCount = 128
    @Published var levels: [Float] = Array(repeating: 0, count: channelCount)
    @Published var status = DriverStatus()

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

        var raw = VAIStatus()
        if abrReadStatus(&raw) {
            status = DriverStatus(
                channelCount: raw.channelCount,
                sampleRate: raw.sampleRate,
                ioBufferFrameSize: raw.ioBufferFrameSize,
                isRunning: raw.isRunning != 0,
                clientCount: raw.clientCount,
                zeroTimeStampPeriod: raw.zeroTimeStampPeriod,
                hostRequestedSampleRate: raw.hostRequestedSampleRate,
                updateCounter: raw.updateCounter,
                configAppliedCounter: raw.configAppliedCounter,
                configCounter: raw.configCounter,
                available: true
            )
        } else {
            status.available = false
        }
    }

    /// Requests the driver switch channel count / sample rate (0 = leave
    /// that one unchanged). Applied asynchronously by the driver's config
    /// poll timer (~200ms) — see status.configAppliedCounter vs configCounter.
    func requestConfig(channelCount: Int?, sampleRate: Double?) {
        _ = abrWriteConfig(UInt32(channelCount ?? 0), sampleRate ?? 0)
    }
}
