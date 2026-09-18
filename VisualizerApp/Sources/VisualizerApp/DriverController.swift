import AppKit
import CoreAudio

/// Installs/uninstalls the HAL driver and verifies the result from the outside:
/// bundle on disk, the coreaudiod helper process, and the CoreAudio device.
@MainActor
final class DriverController: ObservableObject {
    nonisolated static let halPath = "/Library/Audio/Plug-Ins/HAL/VirtualAudioInterfaceDriver.driver"
    nonisolated static let deviceUID = "com.daitomanabe.virtualaudiointerface.device"
    nonisolated static let helperTitle = "Core Audio Driver (VirtualAudioInterfaceDriver.driver)"

    struct Snapshot: Equatable {
        var installed = false
        var helperPIDs: [Int32] = []
        var devicePresent = false
        var outdated = false   // installed driver was built from different source than the bundled one
        var isOn: Bool { installed && !helperPIDs.isEmpty && devicePresent }
        var isOff: Bool { !installed && helperPIDs.isEmpty && !devicePresent }
    }

    @Published private(set) var snapshot = Snapshot()
    @Published private(set) var busy = false
    @Published private(set) var message = ""

    let bundledDriver = Bundle.main.url(forResource: "VirtualAudioInterfaceDriver", withExtension: "driver")
    private var timer: Timer?

    init() {
        refresh()
        timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in if self?.busy == false { self?.refresh() } }
        }
        RunLoop.main.add(timer!, forMode: .common) // keep running during menu tracking and live resize
    }

    private var probing = false

    /// The CoreAudio lookup in probe() blocks while coreaudiod is busy (it can take minutes to come back
    /// after a restart on a machine with many drivers), so never run it on the main thread.
    func refresh() {
        guard !probing else { return }
        probing = true
        Task { [weak self] in
            let s = await Self.probeInBackground()
            self?.snapshot = s
            self?.probing = false
        }
    }

    nonisolated static func probeInBackground() async -> Snapshot {
        await Task.detached(priority: .utility) { probe() }.value
    }

    nonisolated static func probe() -> Snapshot {
        let installed = FileManager.default.fileExists(atPath: halPath)
        let bundled = Bundle.main.url(forResource: "VirtualAudioInterfaceDriver", withExtension: "driver")
        func sourceHash(_ bundlePath: String) -> String? {
            (NSDictionary(contentsOfFile: bundlePath + "/Contents/Info.plist")?["VAIDriverSourceHash"]) as? String
        }
        // A driver installed before source hashes existed has none, so it counts as outdated.
        let outdated = installed && bundled.map { sourceHash(halPath) != sourceHash($0.path) } ?? false
        return Snapshot(installed: installed, helperPIDs: helperPIDs(), devicePresent: devicePresent(), outdated: outdated)
    }

    func turnOn() {
        guard let src = bundledDriver else {
            message = "No driver bundled with this app. Launch the .app built by build_app.sh."
            return
        }
        let dst = Self.shq(Self.halPath)
        run(label: "ON", script: "/bin/rm -rf \(dst) && /bin/cp -R \(Self.shq(src.path)) \(dst) && /usr/bin/xattr -cr \(dst) && /usr/sbin/chown -R root:wheel \(dst) && { /usr/bin/killall coreaudiod; true; }",
            done: { $0.isOn && !$0.outdated })
    }

    func turnOff() {
        run(label: "OFF", script: "/bin/rm -rf \(Self.shq(Self.halPath)); /usr/bin/killall coreaudiod; true",
            done: { $0.isOff })
    }

    private func run(label: String, script: String, done: @escaping (Snapshot) -> Bool) {
        busy = true
        message = "\(label): restarting coreaudiod…"
        if let error = Self.runPrivileged(script) {
            busy = false
            refresh()
            message = "\(label): \(error)"
            return
        }
        Task {
            var s = await Self.waitFor(seconds: 15, done)
            // OFF must leave no driver process behind: SIGKILL stragglers by exact PID.
            if label == "OFF", !s.helperPIDs.isEmpty {
                let pids = s.helperPIDs.map(String.init).joined(separator: " ")
                message = "OFF: helper process still running (PID \(pids)), force-quitting it"
                if let error = Self.runPrivileged("/bin/kill -9 \(pids); true") {
                    message = "OFF: force quit failed: \(error)"
                }
                s = await Self.waitFor(seconds: 5, done)
            }
            snapshot = s
            busy = false
            if done(s) {
                message = label == "ON" ? "ON: driver process and Core Audio device are up"
                                        : "OFF: driver process has quit and the device is gone"
            } else {
                message = "\(label): unexpected state (installed=\(s.installed), PID=\(s.helperPIDs), device=\(s.devicePresent))"
            }
        }
    }

    private static func waitFor(seconds: Double, _ done: (Snapshot) -> Bool) async -> Snapshot {
        let deadline = Date().addingTimeInterval(seconds)
        var s = await probeInBackground()
        while !done(s), Date() < deadline {
            try? await Task.sleep(nanoseconds: 500_000_000)
            s = await probeInBackground()
        }
        return s
    }

    // MARK: - system probes

    nonisolated static func helperPIDs() -> [Int32] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-axo", "pid=,command="]
        let pipe = Pipe()
        p.standardOutput = pipe
        guard (try? p.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            guard let sp = t.firstIndex(of: " ") else { return nil }
            let cmd = t[sp...].trimmingCharacters(in: .whitespaces)
            guard cmd == helperTitle || cmd.hasPrefix(halPath + "/") else { return nil }
            return Int32(t[..<sp])
        }
    }

    nonisolated static func devicePresent() -> Bool {
        var uid = deviceUID as CFString
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        let status = withUnsafeMutablePointer(to: &uid) { uidPtr in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr,
                                       UInt32(MemoryLayout<CFString>.size), uidPtr, &size, &device)
        }
        return status == noErr && device != kAudioObjectUnknown
    }

    // MARK: - privileged shell

    /// Runs `script` as root via the standard macOS admin password dialog. Returns an error string or nil.
    static func runPrivileged(_ script: String) -> String? {
        let escaped = script.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        var err: NSDictionary?
        NSAppleScript(source: "do shell script \"\(escaped)\" with administrator privileges")?.executeAndReturnError(&err)
        guard let err else { return nil }
        if (err[NSAppleScript.errorNumber] as? Int) == -128 { return "Cancelled" }
        return err[NSAppleScript.errorMessage] as? String ?? "Unknown error"
    }

    static func shq(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}
