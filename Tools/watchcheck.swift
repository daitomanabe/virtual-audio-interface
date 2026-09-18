// Checks the app's FileWatcher (VisualizerApp/Sources/VisualizerApp/FileWatcher.swift) against
// the ways editors save: in-place writes, bursts, atomic replace, delete + recreate, rename away.
// Run: make -C Tools check
import Foundation

@main
enum WatchCheck {
    @MainActor static func main() {
        let files = FileManager.default
        let dir = files.temporaryDirectory.appendingPathComponent("watchcheck-\(getpid())")
        try! files.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: dir) }
        let url = dir.appendingPathComponent("scene.sscene")
        func write(_ text: String, atomic: Bool = false) { try! Data(text.utf8).write(to: url, options: atomic ? .atomic : []) }
        func wait(_ seconds: Double) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
        var count = 0
        func expect(_ n: Int, _ what: String) {
            guard count == n else {
                print("watchcheck FAILED: \(what): \(count) callbacks, expected \(n)")
                exit(1)
            }
        }

        write("v1")
        let watcher = FileWatcher(path: url.path) { count += 1 }
        wait(0.4); expect(0, "no change")
        write("v2"); wait(0.4); expect(1, "in-place write")
        for i in 0..<5 { write("burst \(i)"); wait(0.03) }
        wait(0.4); expect(2, "burst of writes (debounced to one)")
        write("atomic", atomic: true); wait(0.6); expect(3, "atomic save (temp file renamed over)")
        write("after atomic"); wait(0.4); expect(4, "in-place write after an atomic save (new file watched)")
        try! files.removeItem(at: url); wait(0.8); expect(4, "deleted (nothing to read)")
        write("recreated"); wait(1.0); expect(5, "file recreated")
        try! files.moveItem(at: url, to: dir.appendingPathComponent("scene.sscene~")) // vim-style backup
        write("new file"); wait(0.8); expect(6, "renamed away + new file")
        withExtendedLifetime(watcher) {}
        print("watchcheck OK")
    }
}
