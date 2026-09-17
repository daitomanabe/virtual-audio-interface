import AppKit

/// Linear peak (0...1) -> dBFS, floored at -120.
func dbFS(_ linear: Float) -> Float { 20 * log10(max(linear, 1e-6)) }

/// dBFS of a 1-based channel; -120 for channels the level array does not cover (e.g. ch 130).
func channelDb(_ levels: [Float], _ channel: Int) -> Float {
    channel >= 1 && channel <= levels.count ? dbFS(levels[channel - 1]) : -120
}

enum LevelThreshold {
    static let signal: Float = -60  // "signal present"
    static let line: Float = -40    // sounding lines in the 3D view
}

/// 0 at -60 dBFS (and below), 1 at 0 dBFS. Drives glow and scale.
func levelAmount(_ db: Float) -> CGFloat {
    CGFloat(min(max((db - LevelThreshold.signal) / -LevelThreshold.signal, 0), 1))
}

/// <= -60: dark grey, then green brightening, green -> yellow up to -12, yellow, red above -3.
func levelColor(_ db: Float) -> NSColor {
    switch db {
    case ...LevelThreshold.signal:
        return NSColor(srgbRed: 0.30, green: 0.30, blue: 0.32, alpha: 1)
    case ...(-24):
        return NSColor(srgbRed: 0.10, green: 0.40 + 0.60 * CGFloat((db + 60) / 36), blue: 0.15, alpha: 1)
    case ...(-12):
        return NSColor(srgbRed: 0.10 + 0.90 * CGFloat((db + 24) / 12), green: 1, blue: 0.15, alpha: 1)
    case ...(-3):
        return NSColor(srgbRed: 1, green: 0.85, blue: 0.10, alpha: 1)
    default:
        return NSColor(srgbRed: 1, green: 0.18, blue: 0.12, alpha: 1)
    }
}
