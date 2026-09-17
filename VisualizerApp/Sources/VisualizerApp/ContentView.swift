import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var audioLevels = AudioLevelsModel()
    @StateObject private var sceneModel = SSDSceneModel()

    var body: some View {
        TabView {
            LevelMeterGridView(model: audioLevels)
                .tabItem { Text("Level Meters") }
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
            .tabItem { Text("3D Speaker View") }
        }
        .frame(minWidth: 800, minHeight: 600)
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
