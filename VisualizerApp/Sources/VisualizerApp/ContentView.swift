import SwiftUI
import UniformTypeIdentifiers

enum MainTab: Hashable { case monitor, meters, settings }

struct ContentView: View {
    /// Not observed here: only the views that show levels subscribe, so the
    /// whole window does not re-render at 30 Hz.
    let audioLevels: AudioLevelsModel
    let scenePath: String?           // CLI argument; nil -> last opened file
    let docshot: Bool

    @StateObject private var sceneModel = SSDSceneModel()
    @State private var tab: MainTab
    @State private var camera: CameraPreset
    @State private var labelMode: LabelMode
    @State private var showLines: Bool
    @State private var selectedChannel: Int?

    private static let lastPathKey = "lastScenePath"

    init(audioLevels: AudioLevelsModel, scenePath: String?, tab: MainTab = .monitor,
         camera: CameraPreset = .top, labelMode: LabelMode = .number, docshot: Bool = false) {
        self.audioLevels = audioLevels
        self.scenePath = scenePath
        self.docshot = docshot
        _tab = State(initialValue: tab)
        _camera = State(initialValue: camera)
        _labelMode = State(initialValue: labelMode)
        _showLines = State(initialValue: docshot)
        _selectedChannel = State(initialValue: docshot ? 1 : nil)
    }

    var body: some View {
        let levelOverride = docshot ? DocShot.syntheticLevels(for: sceneModel.speakers) : nil
        VStack(spacing: 0) {
            topBar
            TabView(selection: $tab) {
                HSplitView {
                    SpeakerSceneView(sceneModel: sceneModel, audio: audioLevels, levelOverride: levelOverride,
                                     selectedChannel: $selectedChannel, camera: camera,
                                     showLines: showLines, labelMode: labelMode)
                        .frame(minWidth: 360, maxWidth: .infinity)
                    RoutingPanel(sceneModel: sceneModel, audio: audioLevels, levelOverride: levelOverride,
                                 selectedChannel: $selectedChannel)
                        .frame(minWidth: 520, idealWidth: 660, maxWidth: 900)
                }
                .tabItem { Text("Monitor") }.tag(MainTab.monitor)
                LevelMeterGridView(model: audioLevels)
                    .tabItem { Text("Meters") }.tag(MainTab.meters)
                SettingsView(model: audioLevels)
                    .tabItem { Text("Settings") }.tag(MainTab.settings)
            }
        }
        .frame(minWidth: 1000, minHeight: 640)
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let path = url?.path else { return }
                DispatchQueue.main.async { open(path) }
            }
            return true
        }
        .onAppear {
            // onAppear can fire again (window hide/show); only the first one loads.
            guard sceneModel.path == nil,
                  let path = scenePath ?? UserDefaults.standard.string(forKey: Self.lastPathKey) else { return }
            open(path)
        }
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            Button("Open…") { openPanel() }
                .keyboardShortcut("o")
                .help("Open .sscene (⌘O) — or drop a file on the window")
            Button("Reload") { sceneModel.reload() }
                .keyboardShortcut("r")
                .help("Reload the current file (⌘R)")
                .disabled(sceneModel.path == nil)
            Spacer()
            if tab == .monitor { sceneControls }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var sceneControls: some View {
        Picker("Camera", selection: $camera) {
            ForEach(CameraPreset.allCases) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        Toggle("発音ライン (> \(Int(LevelThreshold.line)) dBFS)", isOn: $showLines)
        Picker("Labels", selection: $labelMode) {
            ForEach(LabelMode.allCases) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }

    private func open(_ path: String) {
        sceneModel.load(path: path)
        if sceneModel.loadError == nil && !docshot {
            UserDefaults.standard.set(path, forKey: Self.lastPathKey)
        }
    }

    /// Only ever called from a click / ⌘O.
    private func openPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "sscene") ?? .data]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            open(url.path)
        }
    }
}
