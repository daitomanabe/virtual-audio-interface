import SwiftUI

/// Test signal controls on every tab. One selected Core Audio output receives the generated signal;
/// stepping moves the app-wide channel selection along.
struct TestSignalBar: View {
    let speakers: [Speaker]
    @Binding var selectedChannel: Int?
    @ObservedObject var engine: TestSignalEngine

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            controls
            status
                .font(Theme.Fonts.body)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(minWidth: 40, alignment: .leading)
        }
        .background(WindowCloseHook { engine.stop(fade: false) })
        .onAppear {
            engine.selectedChannel = selectedChannel
            engine.speakerChannels = speakerChannels
            DebugLog.shared.add("SSD step list: \(speakerChannels.isEmpty ? "empty" : speakerChannels.map(String.init).joined(separator: ", "))")
        }
        .onChange(of: selectedChannel) { engine.selectedChannel = $0 }
        .onChange(of: speakerChannels) {
            engine.speakerChannels = $0
            DebugLog.shared.add("SSD step list: \($0.isEmpty ? "empty" : $0.map(String.init).joined(separator: ", "))")
        }
        .onChange(of: engine.currentChannel) { if let channel = $0 { selectedChannel = channel } }
    }

    /// Enabled, unmuted speakers; a channel shared by several speakers is played once.
    private var speakerChannels: [Int] {
        Set(speakers.filter { !$0.silent }.map(\.channel)).sorted()
    }

    /// Pink noise, or sine at one of the frequencies, in one menu (0 = pink noise).
    private var signal: Binding<Double> {
        Binding(get: { engine.signal == .pink ? 0 : engine.frequency },
                set: { value in
                    if value > 0 { engine.frequency = value }
                    engine.signal = value > 0 ? .sine : .pink
                })
    }

    private static func hz(_ f: Double) -> String { f < 1000 ? "\(Int(f)) Hz" : "\(Int(f / 1000)) kHz" }

    @ViewBuilder
    private var controls: some View {
        Toggle(isOn: Binding(get: { engine.playing }, set: { $0 ? engine.start() : engine.stop() })) {
            Label("Test signal", systemImage: engine.playing ? "stop.fill" : "play.fill")
        }
        .toggleStyle(.button)
        .fixedSize()
        .disabled(engine.device == nil && !engine.playing)
        .help("Generate a test signal on the selected output device")
        Menu {
            Picker("Output device", selection: $engine.selectedDeviceUID) {
                if engine.availableDevices.isEmpty { Text("No output devices").disabled(true) }
                ForEach(engine.availableDevices, id: \.uid) { output in
                    Text("\(output.name) (\(output.channels) ch)").tag(output.uid)
                }
                if engine.device == nil, !engine.selectedDeviceUID.isEmpty {
                    Text("Selected device unavailable").tag(engine.selectedDeviceUID)
                }
            }
            .pickerStyle(.inline)
        } label: {
            Text(engine.device?.name ?? "Output unavailable")
                .lineLimit(1).truncationMode(.middle)
        }
        .frame(width: 155)
        .help(engine.device.map { "Test output: \($0.name) [\($0.uid)], \($0.channels) ch @ \(Int($0.sampleRate)) Hz" }
              ?? "Selected test output is unavailable; choose another device")
        Menu {
            Picker("Signal", selection: signal) {
                Text("Pink noise").tag(0.0)
                Divider()
                ForEach(TestSignalEngine.frequencies, id: \.self) { Text("Sine \(Self.hz($0))").tag($0) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Text(engine.signal == .pink ? "Pink noise" : "Sine \(Self.hz(engine.frequency))")
        }
        .frame(width: 96)
        .help("Signal")
        Slider(value: $engine.levelDB, in: -60...0, step: 1)
            .frame(width: 72)
            .help("Level. Sine: peak. Pink noise: RMS.")
        Text("\(Int(engine.levelDB)) dBFS")
            .font(Theme.Fonts.number)
            .frame(width: 54, alignment: .leading)
        Menu {
            Picker("Target", selection: $engine.target) {
                ForEach(TestSignalEngine.Target.allCases) { target in
                    Text(target.rawValue).tag(target)
                        .disabled(target == .all && engine.selectedDeviceUID != DriverController.deviceUID)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Text(engine.target.short)
        }
        .frame(width: 136) // fixed, so the controls after it do not move when the target changes
        .help("Where the signal goes: \(engine.target.rawValue)")
        if engine.target.steps {
            Stepper(value: $engine.dwell, in: 0.25...5, step: 0.25) {
                Text("\(String(format: "%g", engine.dwell)) s").font(Theme.Fonts.number)
            }
            .help("Time on each channel while stepping")
        }
    }

    @ViewBuilder
    private var status: some View {
        if let failure = engine.failure {
            Text(failure).foregroundStyle(Color(nsColor: Theme.error)).help(failure)
        } else if let device = engine.device {
            if !engine.playing {
                EmptyView()
            } else if engine.target == .all {
                Text("All \(device.channels) channels").fontWeight(.semibold)
            } else if let channel = engine.currentChannel {
                let names = speakers.filter { $0.channel == channel }.map(\.name).joined(separator: ", ")
                let external = engine.selectedDeviceUID != DriverController.deviceUID
                Text("\(external ? "Sending ch" : "Ch") \(channel) · \(names.isEmpty ? "no speaker" : names)")
                    .fontWeight(.semibold)
                    .help(external ? "Generated signal sent to \(device.name); virtual meters do not measure this output"
                                   : "Signal sent to the virtual device and visible in Meters")
            } else if engine.target == .selected, let selected = selectedChannel {
                Text("Ch \(selected) is beyond the device's \(device.channels) channels")
                    .foregroundStyle(Color(nsColor: Theme.warning))
            } else {
                Text(engine.target == .speakers ? "No speakers to step through" : "Select a channel")
                    .foregroundStyle(.secondary)
            }
        } else {
            Text("Output unavailable")
                .foregroundStyle(Color(nsColor: Theme.warning))
                .help("Choose an available output device. The virtual output requires its driver to be on.")
        }
    }
}

private extension TestSignalEngine.Target {
    /// Menu button title; the menu itself lists the full names.
    var short: String {
        switch self {
        case .selected: return "Selected channel"
        case .speakers: return "Step: SSD speakers"
        case .channels: return "Step: all channels"
        case .all: return "All at once"
        }
    }
}

/// Calls `action` synchronously when the window hosting this view closes.
private struct WindowCloseHook: NSViewRepresentable {
    let action: () -> Void

    func makeNSView(context: Context) -> HookView { HookView() }
    func updateNSView(_ view: HookView, context: Context) { view.action = action }

    final class HookView: NSView {
        var action: () -> Void = {}
        private var observer: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = window.map {
                NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: $0,
                                                       queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.action() }
                }
            }
        }
    }
}
