import SwiftUI

@main
struct VirtualAudioVisualizerApp: App {
    private let audioLevels = AudioLevelsModel()   // one poller shared by every window

    init() { NSApplication.shared.setActivationPolicy(.regular) }

    var body: some Scene {
        WindowGroup {
            // `open VirtualAudioVisualizer.app --args scene.sscene`. Matched by extension
            // because AppKit/Xcode may inject `-NS... YES` style arguments.
            ContentView(audioLevels: audioLevels,
                        scenePath: CommandLine.arguments.dropFirst().first { $0.hasSuffix(".sscene") })
        }
    }
}
