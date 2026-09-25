import SwiftUI

/// Test signal controls on every tab. One selected Core Audio output receives the generated signal;
/// stepping moves the app-wide channel selection along.
struct TestSignalBar: View {
    let speakers: [Speaker]
    @Binding var selectedChannel: Int?
    @ObservedObject var engine: TestSignalEngine
    let longStatusPreview: Bool

    private static let maxStatusNameCharacters = 8
    private static let statusWidth: CGFloat = 120

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            controls
            status
                .font(Theme.Fonts.body)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: Self.statusWidth, alignment: .leading)
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

    /// Noise modes use negative tags; positive tags select a sine frequency.
    private var signal: Binding<Double> {
        Binding(get: {
                    switch engine.signal {
                    case .pink: return 0
                    case .pinkPulse: return -1
                    case .sine: return engine.frequency
                    }
                },
                set: { value in
                    if value > 0 { engine.frequency = value }
                    engine.signal = value > 0 ? .sine : (value < 0 ? .pinkPulse : .pink)
                })
    }

    private static func hz(_ f: Double) -> String { f < 1000 ? "\(Int(f)) Hz" : "\(Int(f / 1000)) kHz" }

    /// Show one bounded speaker name; keep the complete list in the status tooltip.
    private static func shortStatusName(_ names: [String]) -> String {
        guard let first = names.first else { return "no speaker" }
        let extra = names.count > 1 ? " +\(names.count - 1)" : ""
        let budget = max(1, maxStatusNameCharacters - extra.count)
        let name = first.count > budget ? String(first.prefix(budget - 1)) + "…" : first
        return name + extra
    }

    private func channelStatus(_ channel: Int, names: [String], external: Bool, deviceName: String) -> some View {
        let fullNames = names.isEmpty ? "no speaker" : names.joined(separator: ", ")
        let route = external ? "Generated signal sent to \(deviceName); virtual meters do not measure this output"
                             : "Signal sent to the virtual device and visible in Meters"
        return Text("\(external ? "Send" : "Ch") \(channel) · \(Self.shortStatusName(names))")
            .fontWeight(.semibold)
            .help("\(fullNames)\n\(route)")
    }

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
                Text("Pink noise pulse · 4 Hz").tag(-1.0)
                Divider()
                ForEach(TestSignalEngine.frequencies, id: \.self) { Text("Sine \(Self.hz($0))").tag($0) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Text(engine.signal == .pink ? "Pink noise" :
                 engine.signal == .pinkPulse ? "Pink pulse" : "Sine \(Self.hz(engine.frequency))")
        }
        .frame(width: 96)
        .help(engine.signal == .pinkPulse ? "Pink noise pulse: 4 Hz, 50% duty" : "Signal")
        Slider(value: $engine.levelDB, in: -60...0, step: 1)
            .frame(width: 72)
            .help("Level. Sine: peak. Pink noise: RMS during the ON interval.")
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
            Stepper(value: $engine.dwell, in: 0.5...5, step: 0.25) {
                Text("\(String(format: "%g", engine.dwell)) s").font(Theme.Fonts.number)
            }
            .help("Time on each channel while stepping")
        }
    }

    @ViewBuilder
    private var status: some View {
        if longStatusPreview {
            // Docshot fixture: exercise the long-name layout without starting an output device.
            channelStatus(18, names: ["SP-C-long-speaker-name-ch18-with-many-extra-characters"],
                          external: true, deviceName: "Test output fixture")
        } else if let failure = engine.failure {
            Text(failure).foregroundStyle(Color(nsColor: Theme.error)).help(failure)
        } else if let device = engine.device {
            if !engine.playing {
                Text(" ").hidden() // reserve the same width before and during playback
            } else if engine.target == .all {
                Text("All \(device.channels) channels").fontWeight(.semibold)
            } else if let channel = engine.currentChannel {
                let names = speakers.filter { $0.channel == channel }.map(\.name)
                let external = engine.selectedDeviceUID != DriverController.deviceUID
                channelStatus(channel, names: names, external: external, deviceName: device.name)
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
