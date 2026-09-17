import SwiftUI

/// App-configurable settings (channel count / sample rate, written to the
/// driver via shm) plus the host-decided values the driver publishes
/// read-only. See README "設定可能パラメータ / ホスト決定パラメータ".
struct SettingsView: View {
    @ObservedObject var model: AudioLevelsModel

    static let supportedSampleRates: [Double] = [44100, 48000, 88200, 96000]

    @State private var requestedChannelCount: Int = 128
    @State private var requestedSampleRate: Double = 48000

    var body: some View {
        Form {
            Section("設定 (アプリ → ドライバ)") {
                Stepper(value: $requestedChannelCount, in: 1...128) {
                    HStack {
                        Text("チャンネル数")
                        Spacer()
                        TextField("", value: $requestedChannelCount, format: .number)
                            .frame(width: 60)
                            .multilineTextAlignment(.trailing)
                    }
                }
                Picker("サンプルレート", selection: $requestedSampleRate) {
                    ForEach(Self.supportedSampleRates, id: \.self) { rate in
                        Text("\(Int(rate)) Hz").tag(rate)
                    }
                }
                Button("Apply") {
                    model.requestConfig(channelCount: requestedChannelCount, sampleRate: requestedSampleRate)
                }
            }

            Section("ホスト決定値 (読み取り専用)") {
                if !model.status.available {
                    Text("ドライバ未接続 (共有メモリが見つかりません)").foregroundStyle(.secondary)
                } else {
                    let s = model.status
                    LabeledContent("実効サンプルレート", value: "\(Int(s.sampleRate)) Hz")
                    LabeledContent("IOバッファフレーム数", value: bufferSizeLabel(s))
                    LabeledContent("Running", value: s.isRunning ? "Yes" : "No")
                    LabeledContent("接続クライアント数", value: "\(s.clientCount)")
                    LabeledContent("ZeroTimeStampPeriod", value: "\(s.zeroTimeStampPeriod) frames")
                    LabeledContent("ホスト要求レート", value: s.hostRequestedSampleRate > 0 ? "\(Int(s.hostRequestedSampleRate)) Hz" : "(未要求)")
                    LabeledContent("設定適用状況", value: s.configAppliedCounter == s.configCounter ? "適用済み" : "適用待ち…")
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            requestedChannelCount = model.status.available ? Int(model.status.channelCount) : 128
            requestedSampleRate = model.status.available && model.status.sampleRate > 0 ? model.status.sampleRate : 48000
        }
    }

    private func bufferSizeLabel(_ s: DriverStatus) -> String {
        guard s.ioBufferFrameSize > 0, s.sampleRate > 0 else { return "\(s.ioBufferFrameSize) frames" }
        let ms = Double(s.ioBufferFrameSize) / s.sampleRate * 1000
        return "\(s.ioBufferFrameSize) frames (\(String(format: "%.1f", ms)) ms)"
    }
}
