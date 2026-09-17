import SwiftUI

@main
struct VirtualAudioVisualizerApp: App {
    init() { NSApplication.shared.setActivationPolicy(.regular) }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
