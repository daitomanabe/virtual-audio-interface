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

/// Polls the HAL plugin's shared-memory meter struct at ~60Hz.
/// ponytail: polling instead of a push/notify mechanism (e.g. Mach port
/// signal) — simplest thing that works for a meter; revisit only if 60Hz
/// polling shows up as real CPU cost.
@MainActor
final class AudioLevelsModel: ObservableObject {
    static let channelCount = 128
    /// Driver-side ballistics peak, linear 0...1(+). The driver already
    /// applies peak-hold decay (see Shared/MeterShm.h vai_peak_decay_factor),
    /// so this is used as-is — no second decay layer on top.
    @Published var levels: [Float] = Array(repeating: 0, count: channelCount)
    @Published var status = DriverStatus()

    /// dBFS views of the same data, floor at -120dB.
    @Published var peakDB: [Float] = Array(repeating: AudioLevelsModel.dbFloor, count: channelCount)
    @Published var rmsDB: [Float] = Array(repeating: AudioLevelsModel.dbFloor, count: channelCount)
    /// Peak-hold: holds the loudest recent peakDB for holdTime, then falls at
    /// holdFallRatePerSec. Computed here (app-side) since it's a UI/display
    /// concern, not something other consumers of `levels` need.
    @Published var holdDB: [Float] = Array(repeating: AudioLevelsModel.dbFloor, count: channelCount)
    /// 1-based channel numbers that clipped (|sample| >= 1.0) since the last
    /// resetClips(). Latched until reset.
    @Published var clipped: Set<Int> = []

    static let dbFloor: Float = -120
    static let signalThresholdDB: Float = -60
    private static let holdTime: Float = 1.5
    private static let holdFallRatePerSec: Float = 20

    private var timer: Timer?
    private var holdTimer: [Float] = Array(repeating: 0, count: channelCount)
    private var clipBaseline: [UInt32] = Array(repeating: 0, count: channelCount)
    private var lastClipCounts: [UInt32] = Array(repeating: 0, count: channelCount)
    private var clipBaselineSet = false
    private var lastUpdateCounter: UInt64 = 0
    private var lastUpdateTime = Date.distantPast
    /// shm keeps its last values when IO stops or the driver is removed; treat a stalled counter as silence.
    private static let staleAfter: TimeInterval = 0.25

    init() {
        timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(timer!, forMode: .common) // keep running during menu tracking and live resize
    }

    deinit {
        timer?.invalidate()
        abrClose()
    }

    private static func linearToDB(_ v: Float) -> Float {
        guard v > 0 else { return dbFloor }
        return max(20 * log10f(v), dbFloor)
    }

    private func tick() {
        var peakBuf = [Float](repeating: 0, count: Self.channelCount)
        var rmsBuf = [Float](repeating: 0, count: Self.channelCount)
        var clipBuf = [UInt32](repeating: 0, count: Self.channelCount)
        let n: UInt32 = peakBuf.withUnsafeMutableBufferPointer { peakPtr in
            rmsBuf.withUnsafeMutableBufferPointer { rmsPtr in
                clipBuf.withUnsafeMutableBufferPointer { clipPtr in
                    abrReadMeters(peakPtr.baseAddress, rmsPtr.baseAddress, clipPtr.baseAddress, UInt32(Self.channelCount))
                }
            }
        }
        var counter = VAIStatus()
        if abrReadStatus(&counter), counter.updateCounter != lastUpdateCounter {
            lastUpdateCounter = counter.updateCounter
            lastUpdateTime = Date()
        }
        if Date().timeIntervalSince(lastUpdateTime) > Self.staleAfter {
            for i in 0..<Int(n) { peakBuf[i] = 0; rmsBuf[i] = 0 }
        }
        if n > 0 {
            if !clipBaselineSet {
                // Clips counted before this app launched are not this session's news.
                clipBaseline = clipBuf
                clipBaselineSet = true
            }
            levels = peakBuf
            var newPeakDB = peakDB
            var newRmsDB = rmsDB
            var newHoldDB = holdDB
            let dt = Float(1.0 / 60.0)
            for i in 0..<Int(n) {
                let db = Self.linearToDB(peakBuf[i])
                newPeakDB[i] = db
                newRmsDB[i] = Self.linearToDB(rmsBuf[i])

                if db >= newHoldDB[i] {
                    newHoldDB[i] = db
                    holdTimer[i] = 0
                } else {
                    holdTimer[i] += dt
                    if holdTimer[i] > Self.holdTime {
                        newHoldDB[i] = max(db, newHoldDB[i] - Self.holdFallRatePerSec * dt)
                    }
                }
            }
            peakDB = newPeakDB
            rmsDB = newRmsDB
            holdDB = newHoldDB

            var newClipped = clipped
            for i in 0..<Int(n) where clipBuf[i] != clipBaseline[i] {
                newClipped.insert(i + 1)
            }
            if newClipped != clipped { clipped = newClipped }
            lastClipCounts = clipBuf
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

    /// Snapshots the current cumulative clip counts as the new baseline and
    /// clears the latched `clipped` set. The driver never resets clipCount
    /// itself (single-writer discipline), so "reset" is purely app-side.
    func resetClips() {
        clipBaseline = lastClipCounts
        clipped = []
    }
}
