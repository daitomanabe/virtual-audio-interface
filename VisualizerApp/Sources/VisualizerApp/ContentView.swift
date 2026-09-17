import SwiftUI
import UniformTypeIdentifiers
import SceneKit

struct ContentView: View {
    @StateObject private var audioLevels = AudioLevelsModel()
    @StateObject private var sceneModel = SSDSceneModel()
    @State private var tab = 0

    var body: some View {
        TabView(selection: $tab) {
            LevelMeterGridView(model: audioLevels)
                .tabItem { Text("Level Meters") }.tag(0)
            VStack {
                HStack {
                    Button("Open .sscene…") { openScenePanel() }
                    if let error = sceneModel.loadError {
                        Text(error).foregroundStyle(.red).font(.caption)
                    } else {
                        Text("\(sceneModel.speakers.count) speakers").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(8)
                SpeakerSceneView(sceneModel: sceneModel, levels: audioLevels)
            }
            .tabItem { Text("3D Speaker View") }.tag(1)
        }
        .frame(minWidth: 800, minHeight: 600)
        .onAppear {
            if CommandLine.arguments.count > 1 { sceneModel.load(path: CommandLine.arguments[1]) }
            if let dir = ProcessInfo.processInfo.environment["VAI_SNAPSHOT"] { runSnapshot(dir: dir) }
        }
    }

    // Debug hook: VAI_SNAPSHOT=<dir> writes meters.png / scene.png then quits.
    private func runSnapshot(dir: String) {
        func png(_ image: NSImage, _ name: String) {
            guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                  let data = rep.representation(using: .png, properties: [:]) else { return }
            try? data.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name))
        }
        func findSCNView(_ v: NSView) -> SCNView? {
            if let s = v as? SCNView { return s }
            for c in v.subviews { if let s = findSCNView(c) { return s } }
            return nil
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            guard let content = NSApp.windows.first?.contentView,
                  let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) else {
                FileHandle.standardError.write("snapshot: no window (\(NSApp.windows.count))\n".data(using: .utf8)!)
                NSApp.terminate(nil); return
            }
            content.cacheDisplay(in: content.bounds, to: rep)
            let img = NSImage(size: content.bounds.size); img.addRepresentation(rep); png(img, "meters.png")
            tab = 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                if let scn = findSCNView(content) { png(scn.snapshot(), "scene.png") }
                NSApp.terminate(nil)
            }
        }
    }

    private func openScenePanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "sscene") ?? .data]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            sceneModel.load(path: url.path)
        }
    }
}
