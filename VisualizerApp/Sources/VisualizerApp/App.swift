import SwiftUI
import AppKit

@main
enum Main {
    @MainActor static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        if args.contains("--status") {
            let s = DriverController.probe()
            print("installed=\(s.installed) helperPIDs=\(s.helperPIDs) devicePresent=\(s.devicePresent) on=\(s.isOn) off=\(s.isOff)")
            exit(0)
        }
        if let i = args.firstIndex(of: "--docshot") {
            guard i + 1 < args.count else {
                print("usage: VisualizerApp --docshot <outdir> [scene.sscene]")
                exit(2)
            }
            DocShot.run(outDir: args[i + 1], scenePath: args.count > i + 2 ? args[i + 2] : nil)
        } else {
            VirtualAudioVisualizerApp.main()
        }
    }

    /// `open VirtualAudioVisualizer.app --args scene.sscene`. Matched by extension
    /// because AppKit/Xcode may inject `-NS... YES` style arguments.
    static var scenePathArgument: String? {
        CommandLine.arguments.dropFirst().first { $0.hasSuffix(".sscene") }
    }
}

struct VirtualAudioVisualizerApp: App {
    private let audioLevels = AudioLevelsModel()   // one poller shared by every window
    private let driver = DriverController()        // one driver-state owner shared by every window

    init() { NSApplication.shared.setActivationPolicy(.regular) }

    var body: some Scene {
        WindowGroup {
            ContentView(audioLevels: audioLevels, driver: driver, scenePath: Main.scenePathArgument)
        }
    }
}

/// `VisualizerApp --docshot <outdir> [scene.sscene]`: self-captures each tab to PNG and exits.
/// A background launch never gets a WindowGroup window, so this hosts ContentView in a
/// plain NSWindow; orderFrontRegardless is allowed in this mode only.
@MainActor
enum DocShot {
    /// Test levels so the Monitor tab has something to show: ch1 -3, ch3 -20, ch9 -50,
    /// ch30 (unassigned) -10, and -10 on every muted / disabled speaker's channel.
    static func syntheticLevels(for speakers: [Speaker]) -> [Float] {
        var levels = [Float](repeating: 0, count: AudioLevelsModel.channelCount)
        func set(_ ch: Int, _ db: Float) {
            if ch >= 1 && ch <= levels.count { levels[ch - 1] = pow(10, db / 20) }
        }
        for s in speakers where s.mute || !s.active { set(s.channel, -10) }
        set(1, -3); set(3, -20); set(9, -50); set(30, -10)
        return levels
    }

    static func run(outDir: String, scenePath: String?) {
        let dir = URL(fileURLWithPath: outDir, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let logURL = dir.appendingPathComponent("docshot.log")
        try? Data().write(to: logURL)
        func log(_ message: String) {
            print(message)
            if let handle = try? FileHandle(forWritingTo: logURL) {
                handle.seekToEndOfFile()
                handle.write(Data("\(Date()) \(message)\n".utf8))
                try? handle.close()
            }
        }

        NSApplication.shared.setActivationPolicy(.regular)
        let audio = AudioLevelsModel()
        let driver = DriverController()
        let path = scenePath.map { URL(fileURLWithPath: $0).path }
        let shots: [(name: String, tab: MainTab, camera: CameraPreset, labels: LabelMode)] = [
            ("monitor-top", .monitor, .top, .numberAndName),
            ("monitor-front", .monitor, .front, .number),
            ("monitor-side", .monitor, .side, .number),
            ("monitor-perspective", .monitor, .perspective, .number),
            ("meters", .meters, .top, .number),
            ("settings", .settings, .top, .number),
        ]
        func root(_ i: Int) -> AnyView {
            let s = shots[i]
            // .id(i) recreates ContentView so the initial tab/camera state applies.
            return AnyView(ContentView(audioLevels: audio, driver: driver, scenePath: path, tab: s.tab, camera: s.camera,
                                       labelMode: s.labels, docshot: true).id(i))
        }

        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 1400, height: 900),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "Virtual Audio Visualizer (docshot)"
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: root(0))
        window.contentView = host
        window.orderFrontRegardless()
        log("docshot: window \(window.windowNumber), scene \(path ?? "(last opened)")")

        Task { @MainActor in
            for (i, shot) in shots.enumerated() {
                if i > 0 { host.rootView = root(i) }
                try? await Task.sleep(nanoseconds: i == 0 ? 4_000_000_000 : 2_500_000_000)
                guard let image = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(window.windowNumber),
                                                          [.boundsIgnoreFraming, .bestResolution]),
                      let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
                    log("docshot: capture failed for \(shot.name)")
                    continue
                }
                do {
                    try png.write(to: dir.appendingPathComponent("\(shot.name).png"))
                    log("docshot: wrote \(shot.name).png (\(image.width)x\(image.height))")
                } catch {
                    log("docshot: write failed for \(shot.name): \(error)")
                }
            }
            log("docshot: done")
            exit(0)
        }
        NSApplication.shared.run()
    }
}
