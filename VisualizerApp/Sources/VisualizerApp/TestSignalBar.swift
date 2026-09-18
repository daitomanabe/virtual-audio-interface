import SwiftUI

/// One-row test signal strip under the top bar, on every tab. Plays into the virtual device so the
/// Monitor and Meters tabs can be checked without a DAW; stepping moves the app-wide selection along.
struct TestSignalBar: View {
    let speakers: [Speaker]
    @Binding var selectedChannel: Int?
    @StateObject private var engine = TestSignalEngine()

    var body: some View {
        HStack(spacing: 12) {
            controls
                .disabled(engine.device == nil && !engine.playing)
            Spacer(minLength: 8)
            status
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(.bar)
        .background(WindowCloseHook { engine.stop(fade: false) })
        .onAppear {
            engine.selectedChannel = selectedChannel
            engine.speakerChannels = speakerChannels
        }
        .onChange(of: selectedChannel) { engine.selectedChannel = $0 }
        .onChange(of: speakerChannels) { engine.speakerChannels = $0 }
        .onChange(of: engine.currentChannel) { if let channel = $0 { selectedChannel = channel } }
    }

    /// Enabled, unmuted speakers; a channel shared by several speakers is played once.
    private var speakerChannels: [Int] {
        Set(speakers.filter { $0.active && !$0.mute }.map(\.channel)).sorted()
    }

    @ViewBuilder
    private var controls: some View {
        Toggle(isOn: Binding(get: { engine.playing }, set: { $0 ? engine.start() : engine.stop() })) {
            Label("Test Signal", systemImage: engine.playing ? "stop.fill" : "play.fill")
        }
        .toggleStyle(.button)
        .help("Play a test signal into the virtual device (mixed with any DAW output)")
        Picker("Signal", selection: $engine.signal) {
            ForEach(TestSignalEngine.Signal.allCases) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        Picker("Frequency", selection: $engine.frequency) {
            ForEach(TestSignalEngine.frequencies, id: \.self) {
                Text($0 < 1000 ? "\(Int($0)) Hz" : "\(Int($0 / 1000)) kHz").tag($0)
            }
        }
        .labelsHidden()
        .fixedSize()
        .disabled(engine.signal != .sine)
        .help("Sine frequency")
        HStack(spacing: 4) {
            Slider(value: $engine.levelDB, in: -60...0, step: 1)
                .frame(width: 110)
            Text("\(Int(engine.levelDB)) dBFS")
                .monospacedDigit()
                .frame(width: 58, alignment: .trailing)
        }
        .help("Level. Sine: peak. Pink noise: RMS.")
        Picker("Target", selection: $engine.target) {
            ForEach(TestSignalEngine.Target.allCases) { Text($0.rawValue).tag($0) }
        }
        .labelsHidden()
        .frame(width: 200) // fixed, so the controls after it do not move when the target changes
        Stepper(value: $engine.dwell, in: 0.25...5, step: 0.25) {
            Text("Dwell \(String(format: "%g", engine.dwell)) s")
                .monospacedDigit()
                .foregroundStyle(engine.target.steps ? .primary : .secondary)
                .frame(width: 70, alignment: .leading)
        }
        .disabled(!engine.target.steps)
        .help("Time on each channel while stepping")
    }

    @ViewBuilder
    private var status: some View {
        if let failure = engine.failure {
            Text(failure).foregroundStyle(.red)
        } else if let device = engine.device {
            if !engine.playing {
                Text("\(device.channels) ch · \(Int(device.sampleRate)) Hz").foregroundStyle(.secondary)
            } else if engine.target == .all {
                Text("All \(device.channels) channels").fontWeight(.semibold)
            } else if let channel = engine.currentChannel {
                let names = speakers.filter { $0.channel == channel }.map(\.name).joined(separator: ", ")
                Text("Ch \(channel) · \(names.isEmpty ? "no speaker" : names)").fontWeight(.semibold)
            } else if engine.target == .selected, let selected = selectedChannel {
                Text("Ch \(selected) is outside the device's \(device.channels) channels").foregroundStyle(.orange)
            } else {
                Text(engine.target == .speakers ? "No speakers to step through" : "Select a channel or speaker")
                    .foregroundStyle(.secondary)
            }
        } else {
            Text(engine.playing ? "Waiting for the virtual device…" : "Virtual device not found. Turn the driver ON.")
                .foregroundStyle(.orange)
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
