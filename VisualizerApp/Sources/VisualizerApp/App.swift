import SwiftUI
import AppKit

@main
enum Main {
    @MainActor static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        if args.contains("--status") {
            let s = DriverController.probe()
            print("installed=\(s.installed) helperPIDs=\(s.helperPIDs) devicePresent=\(s.devicePresent) outdated=\(s.outdated) on=\(s.isOn) off=\(s.isOff)")
            exit(0)
        }
        if let i = args.firstIndex(of: "--test-signal") {
            TestSignalEngine.runCLI(Array(args[(i + 1)...])) // plays without a window, then exits
        }
        if let i = args.firstIndex(of: "--docshot") {
            func value(_ flag: String) -> String? { args.firstIndex(of: flag).flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : "" } }
            let appearance = value("--appearance")
            let size = value("--size").map { $0.split(separator: "x").compactMap { Int($0) } }
            guard i + 1 < args.count, !args[i + 1].hasPrefix("--"),
                  appearance == nil || appearance == "light" || appearance == "dark",
                  size == nil || size!.count == 2 else {
                print("usage: VisualizerApp --docshot <outdir> [scene.sscene] [--appearance light|dark] [--size WxH]")
                exit(2)
            }
            DocShot.run(outDir: args[i + 1], scenePath: scenePathArgument, appearance: appearance,
                        size: size.map { NSSize(width: $0[0], height: $0[1]) } ?? NSSize(width: 1400, height: 900))
        } else {
            let app = NSApplication.shared
            app.delegate = AppDelegate.shared
            app.setActivationPolicy(.regular)
            app.run()
        }
    }

    /// `open VirtualAudioVisualizer.app --args scene.sscene`. Matched by extension
    /// because AppKit/Xcode may inject `-NS... YES` style arguments.
    static var scenePathArgument: String? {
        CommandLine.arguments.dropFirst().first { $0.hasSuffix(".sscene") }
    }
}

/// Plain AppKit window instead of a SwiftUI WindowGroup: when launched without activation
/// (e.g. `open` from a terminal that keeps focus) WindowGroup never creates its window.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static let shared = AppDelegate()
    private let audioLevels = AudioLevelsModel()
    private let driver = DriverController()
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = Self.makeMainMenu()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "Virtual Audio Interface"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: ContentView(audioLevels: audioLevels, driver: driver,
                                                                 scenePath: Main.scenePathArgument))
        if !window.setFrameUsingName("MainWindow") { window.center() }
        window.setFrameAutosaveName("MainWindow")
        window.makeKeyAndOrderFront(nil) // launch flow only; no activate()
        self.window = window
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    private static func makeMainMenu() -> NSMenu {
        func item(_ title: String, _ action: Selector?, _ key: String = "") -> NSMenuItem {
            NSMenuItem(title: title, action: action, keyEquivalent: key)
        }
        func menu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
            let m = NSMenu(title: title)
            items.forEach(m.addItem)
            let top = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            top.submenu = m
            return top
        }
        let main = NSMenu()
        main.addItem(menu("Virtual Audio Interface", [
            item("Hide Virtual Audio Interface", #selector(NSApplication.hide(_:)), "h"),
            .separator(),
            item("Quit Virtual Audio Interface", #selector(NSApplication.terminate(_:)), "q"),
        ]))
        main.addItem(menu("Edit", [
            item("Undo", Selector(("undo:")), "z"),
            item("Redo", Selector(("redo:")), "Z"),
            .separator(),
            item("Cut", #selector(NSText.cut(_:)), "x"),
            item("Copy", #selector(NSText.copy(_:)), "c"),
            item("Paste", #selector(NSText.paste(_:)), "v"),
            item("Select All", #selector(NSText.selectAll(_:)), "a"),
        ]))
        main.addItem(menu("Window", [
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
            item("Close", #selector(NSWindow.performClose(_:)), "w"),
        ]))
        return main
    }
}

/// `VisualizerApp --docshot <outdir> [scene.sscene] [--appearance light|dark] [--size WxH]`: self-captures
/// each tab to PNG and exits. The window is 1400x900 pt unless `--size` says otherwise (content minimum 1000x640).
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

    static func run(outDir: String, scenePath: String?, appearance: String?, size: NSSize) {
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
        if let appearance {
            NSApplication.shared.appearance = NSAppearance(named: appearance == "light" ? .aqua : .darkAqua)
        }
        let audio = AudioLevelsModel()
        let driver = DriverController()
        let path = scenePath.map { URL(fileURLWithPath: $0).path }
        let shots: [(name: String, tab: MainTab, camera: CameraPreset, labels: LabelMode)] = [
            ("monitor-top", .monitor, .top, .numberAndName),
            ("monitor-front", .monitor, .front, .number),
            ("monitor-side", .monitor, .side, .number),
            ("monitor-perspective", .monitor, .perspective, .number),
            ("meters", .meters, .top, .number),
            ("meters-layout", .meters, .top, .number),
            ("settings", .settings, .top, .number),
        ]
        // LevelMeterGridView reads its All/Layout mode from UserDefaults on init;
        // force it per shot and restore whatever the user had before exiting, so
        // running docshot never changes the real app's persisted preference.
        let savedMeterMode = UserDefaults.standard.string(forKey: LevelMeterGridView.modeKey)
        func setMeterMode(_ mode: MeterMode) {
            UserDefaults.standard.set(mode.rawValue, forKey: LevelMeterGridView.modeKey)
        }
        func restoreMeterMode() {
            if let savedMeterMode {
                UserDefaults.standard.set(savedMeterMode, forKey: LevelMeterGridView.modeKey)
            } else {
                UserDefaults.standard.removeObject(forKey: LevelMeterGridView.modeKey)
            }
        }
        func root(_ i: Int) -> AnyView {
            let s = shots[i]
            // .id(i) recreates ContentView so the initial tab/camera state applies.
            return AnyView(ContentView(audioLevels: audio, driver: driver, scenePath: path, tab: s.tab, camera: s.camera,
                                       labelMode: s.labels, docshot: true).id(i))
        }

        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: 80, y: 80), size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "Virtual Audio Interface"
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: root(0))
        window.contentView = host
        window.orderFrontRegardless()
        log("docshot: window \(window.windowNumber), scene \(path ?? "(last opened)"), appearance \(appearance ?? "system")")

        Task { @MainActor in
            for (i, shot) in shots.enumerated() {
                if shot.name == "meters" { setMeterMode(.all) }
                if shot.name == "meters-layout" { setMeterMode(.layout) }
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
            restoreMeterMode()
            log("docshot: done")
            exit(0)
        }
        NSApplication.shared.run()
    }
}
