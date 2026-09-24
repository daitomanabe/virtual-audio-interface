import Foundation

/// Local working layouts. Scene data here is deliberately outside the public source repository.
enum LayoutLibrary {
    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VirtualAudioInterface/Scenes", isDirectory: true)
    }

    static func scenes() -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil,
                                                       options: [.skipsHiddenFiles])) ?? [])
            .filter { $0.pathExtension.lowercased() == "sscene" }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }
}
