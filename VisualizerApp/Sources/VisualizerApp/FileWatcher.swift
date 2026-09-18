import Foundation

/// Calls `onChange` on the main thread `debounce` seconds after the last write to `path`.
/// Editors that save atomically replace the file (rename or delete, then a new file under
/// the same name); the watch then re-opens the path, retrying until it exists again, and
/// reports that as a change too. Watching stops when the watcher is released.
/// Foundation only, so Tools/watchcheck.swift can test it outside the app.
@MainActor
final class FileWatcher {
    let path: String
    private let debounce: TimeInterval
    private let onChange: () -> Void
    private var source: DispatchSourceFileSystemObject?
    private var token = 0                 // bumped per scheduled step; stale steps do nothing

    init(path: String, debounce: TimeInterval = 0.2, onChange: @escaping () -> Void) {
        self.path = path
        self.debounce = debounce
        self.onChange = onChange
        if !open() { later(0.5) { $0.reopen() } }
    }

    deinit { source?.cancel() }

    private func open() -> Bool {
        let fd = Darwin.open(path, O_EVTONLY)
        guard fd >= 0 else { return false }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .extend, .rename, .delete], queue: .main)
        source.setEventHandler { [weak self] in self?.handle() }
        source.setCancelHandler { close(fd) }
        source.resume()
        self.source = source
        return true
    }

    private func handle() {
        guard let source else { return }
        if source.data.isDisjoint(with: [.rename, .delete]) {
            later(debounce) { $0.onChange() }
        } else {
            // The watched inode is gone or moved; the path may already name the new file.
            source.cancel()
            self.source = nil
            later(0.1) { $0.reopen() }
        }
    }

    private func reopen() {
        if open() {
            later(debounce) { $0.onChange() }
        } else {
            later(0.5) { $0.reopen() }    // ponytail: polls a missing file every 0.5 s until it is back
        }
    }

    /// Runs `action` after `delay` unless another step is scheduled first (debounce).
    private func later(_ delay: TimeInterval, _ action: @escaping (FileWatcher) -> Void) {
        token += 1
        let current = token
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.token == current else { return }
            action(self)
        }
    }
}
