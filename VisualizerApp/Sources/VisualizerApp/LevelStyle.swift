import AppKit

/// Linear peak (0...1) -> dBFS, floored at -120.
func dbFS(_ linear: Float) -> Float { 20 * log10(max(linear, 1e-6)) }

/// dBFS of a 1-based channel; -120 for channels the level array does not cover (e.g. ch 130).
func channelDb(_ levels: [Float], _ channel: Int) -> Float {
    channel >= 1 && channel <= levels.count ? dbFS(levels[channel - 1]) : -120
}

extension Speaker {
    /// Channel level in dBFS, plus the SPEAKER Gain when `applyGain` (the level expected at the
    /// speaker). Mute is not applied here; callers show muted speakers their own way.
    func db(_ levels: [Float], applyGain: Bool) -> Float {
        channelDb(levels, channel) + (applyGain ? Float(gainDb) : 0)
    }
}

enum LevelThreshold {
    static let signal: Float = -60  // "signal present"
    static let line: Float = -40    // sounding lines in the 3D view
    static let yellow: Float = -12  // meter zones
    static let red: Float = -3
}

/// 0 at -60 dBFS (and below), 1 at 0 dBFS. Drives glow and scale.
func levelAmount(_ db: Float) -> CGFloat {
    CGFloat(min(max((db - LevelThreshold.signal) / -LevelThreshold.signal, 0), 1))
}

/// 3D speakers and table bars: off below -60, fading into green up to -24, green -> yellow up to
/// the yellow zone, yellow, red in the red zone. Same hues as the meters' `levelZoneColor`.
func levelColor(_ db: Float) -> NSColor {
    switch db {
    case ...LevelThreshold.signal: return Theme.levelOff
    case ...(-24): return mix(Theme.levelOff, Theme.levelGreen, CGFloat((db + 60) / 36))
    case ...LevelThreshold.yellow: return mix(Theme.levelGreen, Theme.levelYellow, CGFloat((db + 24) / 12))
    case ...LevelThreshold.red: return Theme.levelYellow
    default: return Theme.levelRed
    }
}

/// Meters: flat green / yellow / red zones.
func levelZoneColor(_ db: Float) -> NSColor {
    db > LevelThreshold.red ? Theme.levelRed : db > LevelThreshold.yellow ? Theme.levelYellow : Theme.levelGreen
}

private func mix(_ a: NSColor, _ b: NSColor, _ t: CGFloat) -> NSColor {
    NSColor(srgbRed: a.redComponent + (b.redComponent - a.redComponent) * t,
            green: a.greenComponent + (b.greenComponent - a.greenComponent) * t,
            blue: a.blueComponent + (b.blueComponent - a.blueComponent) * t, alpha: 1)
}
