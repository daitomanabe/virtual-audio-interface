import SwiftUI

/// App-configurable settings (channel count / sample rate, written to the
/// driver via shm) plus the host-decided values the driver publishes
/// read-only. See README "Settings and host-decided values".
struct SettingsView: View {
    @ObservedObject var model: AudioLevelsModel
    @ObservedObject var driver: DriverController

    static let supportedSampleRates: [Double] = [44100, 48000, 88200, 96000]

    @State private var requestedChannelCount: Int = 128
    @State private var requestedSampleRate: Double = 48000

    var body: some View {
        Form {
            Section("Driver") {
                let s = driver.snapshot
                LabeledContent("Installed", value: !s.installed ? "No"
                                : s.outdated ? "Yes, differs from the app's driver (Driver menu → Update)" : "Yes, matches the app")
                LabeledContent("Helper process", value: s.helperPIDs.isEmpty ? "Not running"
                                : "PID " + s.helperPIDs.map(String.init).joined(separator: ", "))
                LabeledContent("Core Audio device", value: s.devicePresent ? "Present" : "Not present")
                if !driver.message.isEmpty {
                    LabeledContent("Last message", value: driver.message)
                }
                Text("Turning the driver on or off asks for an administrator password and restarts coreaudiod, so every audio device drops out for a moment.")
                    .font(Theme.Fonts.caption).foregroundStyle(.secondary)
            }

            Section("Device settings (app → driver)") {
                Stepper(value: $requestedChannelCount, in: 1...128) {
                    HStack {
                        Text("Channels")
                        Spacer()
                        TextField("", value: $requestedChannelCount, format: .number)
                            .frame(width: 60)
                            .multilineTextAlignment(.trailing)
                    }
                }
                Picker("Sample rate", selection: $requestedSampleRate) {
                    ForEach(Self.supportedSampleRates, id: \.self) { rate in
                        Text(verbatim: "\(Int(rate)) Hz").tag(rate)   // 48000 Hz, like the values below
                    }
                }
                Button("Apply") {
                    model.requestConfig(channelCount: requestedChannelCount, sampleRate: requestedSampleRate)
                }
            }

            Section("Host-decided values (read-only)") {
                if !model.status.available {
                    Text("Driver not connected (shared memory not found)").foregroundStyle(.secondary)
                } else {
                    let s = model.status
                    LabeledContent("Sample rate", value: "\(Int(s.sampleRate)) Hz")
                    LabeledContent("IO buffer", value: bufferSizeLabel(s))
                    LabeledContent("Running", value: s.isRunning ? "Yes" : "No")
                    LabeledContent("Clients", value: "\(s.clientCount)")
                    LabeledContent("Zero timestamp period", value: "\(s.zeroTimeStampPeriod) frames")
                    LabeledContent("Host-requested rate", value: s.hostRequestedSampleRate > 0 ? "\(Int(s.hostRequestedSampleRate)) Hz" : "Not requested")
                    LabeledContent("Settings applied", value: s.configAppliedCounter == s.configCounter ? "Yes" : "Pending…")
                }
            }

            Text(Self.versionString)
                .font(Theme.Fonts.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .monospacedDigit()
        .onAppear {
            requestedChannelCount = model.status.available ? Int(model.status.channelCount) : 128
            requestedSampleRate = model.status.available && model.status.sampleRate > 0 ? model.status.sampleRate : 48000
        }
    }

    private static var versionString: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "Version \(short) (\(build))"
    }

    private func bufferSizeLabel(_ s: DriverStatus) -> String {
        guard s.ioBufferFrameSize > 0, s.sampleRate > 0 else { return "\(s.ioBufferFrameSize) frames" }
        let ms = Double(s.ioBufferFrameSize) / s.sampleRate * 1000
        return "\(s.ioBufferFrameSize) frames (\(String(format: "%.1f", ms)) ms)"
    }
}
