import SwiftUI
import AppKit

/// Design tokens. Colors are named by meaning and defined once as NSColor so SceneKit, the meter
/// Canvas and SwiftUI share them (SwiftUI: `Color(nsColor: Theme.x)`). The 3D view and the meters
/// always sit on the dark `canvas`, so what is drawn there looks the same in light and dark mode.
enum Theme {
    // MARK: color

    /// Interactive tint and the selected channel (3D ring, meter frame).
    static let accent = NSColor(srgbRed: 0.25, green: 0.63, blue: 1.00, alpha: 1)
    static let selection = accent

    /// Level zones, shared by the meters, the 3D speakers and the table bars (see LevelStyle).
    static let levelOff = NSColor(srgbRed: 0.30, green: 0.31, blue: 0.34, alpha: 1)
    static let levelGreen = NSColor(srgbRed: 0.22, green: 0.82, blue: 0.38, alpha: 1)
    static let levelYellow = NSColor(srgbRed: 1.00, green: 0.80, blue: 0.12, alpha: 1)
    static let levelRed = NSColor(srgbRed: 1.00, green: 0.25, blue: 0.20, alpha: 1)

    /// Routing checks and status: wrong / needs a look / for information.
    static let error = NSColor.systemRed
    static let warning = NSColor.systemOrange
    static let info = NSColor.systemBlue
    /// Speakers that cannot sound (Mute, Enabled 0): never lit.
    static let inactive = NSColor(white: 0.52, alpha: 1)

    /// Dark surface under the 3D view and the meters, in both appearances.
    static let canvas = NSColor(srgbRed: 0.07, green: 0.075, blue: 0.085, alpha: 1)
    static let canvasTrack = NSColor(white: 1, alpha: 0.07)      // meter background
    static let canvasLine = NSColor(white: 1, alpha: 0.13)       // floor grid, meter outlines and dB lines
    static let canvasText = NSColor(white: 0.92, alpha: 1)        // speaker labels
    static let canvasTextDim = NSColor(white: 0.60, alpha: 1)     // object and listener labels

    /// The scene's other SSD objects, muted so the speakers stay in front visually.
    static let objectSurface = NSColor(srgbRed: 0.45, green: 0.62, blue: 0.85, alpha: 1)  // screen / surface
    static let objectLED = NSColor(srgbRed: 0.62, green: 0.52, blue: 0.86, alpha: 1)
    static let objectDevice = NSColor(srgbRed: 0.80, green: 0.70, blue: 0.46, alpha: 1)   // camera / projector / FOV
    static let objectBox = NSColor(white: 0.72, alpha: 0.45)
    static let objectMarker = NSColor(white: 0.6, alpha: 1)

    /// Axis gizmo, softened so it does not read as level colors.
    static let axisX = NSColor(srgbRed: 0.93, green: 0.42, blue: 0.40, alpha: 1)
    static let axisY = NSColor(srgbRed: 0.45, green: 0.80, blue: 0.50, alpha: 1)
    static let axisZ = NSColor(srgbRed: 0.45, green: 0.62, blue: 1.00, alpha: 1)

    // MARK: type

    enum Fonts {
        static let heading = Font.headline
        static let body = Font.callout
        static let caption = Font.caption
        static let number = Font.callout.monospacedDigit()
        static let smallNumber = Font.caption.monospacedDigit()
        static let meterChannel = Font.system(size: 10, weight: .semibold, design: .monospaced)
        static let meterValue = Font.system(size: 9, design: .monospaced)
        static let meterBadge = Font.system(size: 8, weight: .bold)
    }

    /// 3D text: one face; heights in meters for a 12 m floor grid (SpeakerSceneView scales them with the scene).
    static let sceneFont = NSFont.systemFont(ofSize: 12, weight: .semibold)
    static let sceneLabel: CGFloat = 0.3
    static let sceneLabelSmall: CGFloat = 0.21

    // MARK: spacing, shape

    enum Space {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
    }
    static let radius: CGFloat = 6
}
