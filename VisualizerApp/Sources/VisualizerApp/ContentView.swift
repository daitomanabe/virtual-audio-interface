import SwiftUI
import UniformTypeIdentifiers

enum MainTab: Hashable { case monitor, meters, settings }

struct ContentView: View {
    /// Not observed here: only the views that show levels/driver state subscribe,
    /// so the whole window does not re-render at 30 Hz / 1 Hz.
    let audioLevels: AudioLevelsModel
    let driver: DriverController
    let scenePath: String?           // CLI argument; nil -> last opened file
    let docshot: Bool

    @StateObject private var sceneModel = SSDSceneModel()
    @State private var tab: MainTab
    @State private var camera: CameraPreset
    @State private var labelMode: LabelMode
    @State private var showLines: Bool
    @State private var showObjects = true
    @State private var applyGain = true
    @State private var selectedChannel: Int?
    @AppStorage(LevelMeterGridView.modeKey) private var meterMode = MeterMode.all

    private static let lastPathKey = "lastScenePath"

    init(audioLevels: AudioLevelsModel, driver: DriverController, scenePath: String?, tab: MainTab = .monitor,
         camera: CameraPreset = .top, labelMode: LabelMode = .number, docshot: Bool = false) {
        self.audioLevels = audioLevels
        self.driver = driver
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
            fileBar
            Divider()
            controlBar
            Divider()
            TabView(selection: $tab) {
                HSplitView {
                    SpeakerSceneView(sceneModel: sceneModel, audio: audioLevels, levelOverride: levelOverride,
                                     selectedChannel: $selectedChannel, camera: camera,
                                     showLines: showLines, labelMode: labelMode,
                                     showObjects: showObjects, applyGain: applyGain)
                        .overlay(alignment: .topLeading) { SceneLoadStatus(sceneModel: sceneModel) }
                        .frame(minWidth: 360, maxWidth: .infinity)
                    RoutingPanel(sceneModel: sceneModel, audio: audioLevels, levelOverride: levelOverride,
                                 selectedChannel: $selectedChannel, applyGain: applyGain)
                        .frame(minWidth: 520, idealWidth: 660, maxWidth: 900)
                }
                .tabItem { Text("Monitor") }.tag(MainTab.monitor)
                LevelMeterGridView(
                    model: audioLevels,
                    speakers: sceneModel.speakers,
                    levelOverride: levelOverride,
                    selectedChannel: $selectedChannel)
                    .tabItem { Text("Meters") }.tag(MainTab.meters)
                SettingsView(model: audioLevels, driver: driver)
                    .tabItem { Text("Settings") }.tag(MainTab.settings)
            }
        }
        .frame(minWidth: 1000, minHeight: 640)
        .tint(Color(nsColor: Theme.accent))
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

    // MARK: row 1: file and driver (the same on every tab)

    private var fileBar: some View {
        HStack(spacing: Theme.Space.s) {
            Button("Open…") { openPanel() }
                .keyboardShortcut("o")
                .help("Open a .sscene layout (⌘O), or drop one on the window")
            Button("Reload") { sceneModel.reload() }
                .keyboardShortcut("r")
                .help("Read the file again and re-frame the view (⌘R). Saving the file reloads it automatically.")
                .disabled(sceneModel.path == nil)
            sceneStatus
                .padding(.leading, Theme.Space.xs)
            Spacer(minLength: Theme.Space.m)
            DeviceFormat(audio: audioLevels)
            DriverMenu(driver: driver)
        }
        .padding(.horizontal, Theme.Space.m)
        .padding(.vertical, Theme.Space.s)
    }

    private static let time: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    /// File name plus when it was read, or the load error (the 3D view keeps the full message on screen).
    @ViewBuilder
    private var sceneStatus: some View {
        if let path = sceneModel.path {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                Text(URL(fileURLWithPath: path).lastPathComponent)
                    .font(Theme.Fonts.heading)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(path)
                if let error = sceneModel.loadError {
                    Label(sceneModel.showsLastValidScene ? "Parse error, showing the last valid version" : "Could not load",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(Theme.Fonts.body)
                        .foregroundStyle(Color(nsColor: Theme.error))
                        .lineLimit(1)
                        .help(error)
                } else if let date = sceneModel.loadedAt {
                    Text("\(sceneModel.reloaded ? "Reloaded" : "Loaded") \(Self.time.string(from: date))")
                        .font(Theme.Fonts.number)
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
            }
        } else {
            Text("No layout. Open a .sscene file or drop one on the window.")
                .font(Theme.Fonts.body)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    // MARK: row 2: the tab's own controls, then the test signal

    private var controlBar: some View {
        HStack(spacing: Theme.Space.s) {
            switch tab {
            case .monitor: monitorControls
            case .meters: meterControls
            case .settings: EmptyView()
            }
            Spacer(minLength: Theme.Space.m)
            TestSignalBar(speakers: sceneModel.speakers, selectedChannel: $selectedChannel)
                .layoutPriority(1)   // its full width before the spacer; only the status text truncates
        }
        .controlSize(.small)
        .padding(.horizontal, Theme.Space.m)
        .padding(.vertical, Theme.Space.xs + 2)
        .frame(minHeight: 32)
    }

    @ViewBuilder
    private var monitorControls: some View {
        Picker("Camera", selection: $camera) {
            ForEach(CameraPreset.allCases) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .help("Top: plan view with the front (+Y) up. Front / Side: elevations. Perspective: drag to orbit.")
        Menu("View") {
            Toggle("Sounding lines (above \(Int(LevelThreshold.line)) dBFS)", isOn: $showLines)
            Toggle("Scene objects", isOn: $showObjects)
            Toggle("Apply SSD gain", isOn: $applyGain)
            Divider()
            Picker("Labels", selection: $labelMode) {
                ForEach(LabelMode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.inline)
        }
        .fixedSize()
        .help("Sounding lines, scene objects (screens, LED walls, projectors, cameras…), SSD gain, labels")
    }

    @ViewBuilder
    private var meterControls: some View {
        Picker("Meters", selection: $meterMode) {
            ForEach(MeterMode.allCases) { Text($0.label).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .help("All channels in order, or grouped by the speakers' height in the loaded layout")
        Button("Reset Clips") { audioLevels.resetClips() }
            .help("Clear the latched clip indicators")
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

/// "128 ch · 48 kHz" as the driver reports it. Observes the 60 Hz model, so it stays a leaf.
private struct DeviceFormat: View {
    @ObservedObject var audio: AudioLevelsModel

    var body: some View {
        let s = audio.status
        if s.available {
            Text("\(s.channelCount) ch · \(String(format: "%g", s.sampleRate / 1000)) kHz")
                .font(Theme.Fonts.number)
                .foregroundStyle(.secondary)
                .fixedSize()
        }
    }
}

/// Driver state dot + menu with ON / Update / OFF and the details. Only this subscribes to
/// DriverController's 1 Hz status updates, so the rest of ContentView doesn't re-render with it.
/// Enable/disable conditions mirror the former standalone VAIControl app.
private struct DriverMenu: View {
    @ObservedObject var driver: DriverController

    var body: some View {
        let s = driver.snapshot
        let (title, color) = s.isOn && s.outdated ? ("Driver outdated", Theme.warning)
            : s.isOn ? ("Driver ON", Theme.levelGreen)
            : s.isOff ? ("Driver OFF", Theme.inactive)
            : ("Driver inconsistent", Theme.warning)
        HStack(spacing: Theme.Space.xs + 2) {
            if driver.busy {
                ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 12, height: 12)
            } else {
                Circle().fill(Color(nsColor: color)).frame(width: 8, height: 8)
            }
            Menu(title) {
                Button(s.outdated ? "Update Driver" : "Turn Driver On") { driver.turnOn() }
                    .disabled(driver.busy || (s.isOn && !s.outdated) || driver.bundledDriver == nil)
                Button("Turn Driver Off") { driver.turnOff() }
                    .disabled(driver.busy || s.isOff)
                Divider()
                Text(!s.installed ? "Not installed" : s.outdated ? "Installed, differs from the app's driver" : "Installed")
                Text(s.helperPIDs.isEmpty ? "Helper process not running"
                     : "Helper process PID " + s.helperPIDs.map(String.init).joined(separator: ", "))
                Text(s.devicePresent ? "Core Audio device present" : "No Core Audio device")
                if !driver.message.isEmpty {
                    Divider()
                    Text(driver.message)
                }
                Divider()
                Text("On, Update and Off ask for an administrator password")
                Text("and restart coreaudiod (all audio drops out briefly).")
            }
            .fixedSize()
        }
        .help(driver.message.isEmpty ? title : driver.message)
    }
}
