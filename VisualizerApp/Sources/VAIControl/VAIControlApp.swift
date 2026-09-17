import SwiftUI

@main
enum Main {
    static func main() {
        if CommandLine.arguments.contains("--status") {
            let s = DriverController.probe()
            print("installed=\(s.installed) helperPIDs=\(s.helperPIDs) devicePresent=\(s.devicePresent) on=\(s.isOn) off=\(s.isOff)")
            exit(0)
        }
        VAIControlApp.main()
    }
}

struct VAIControlApp: App {
    init() { NSApplication.shared.setActivationPolicy(.regular) }

    var body: some Scene {
        WindowGroup("VAI Control") { ControlView() }
            .windowResizability(.contentSize)
    }
}

struct ControlView: View {
    @StateObject private var driver = DriverController()

    var body: some View {
        let s = driver.snapshot
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Circle().fill(s.isOn ? .green : s.isOff ? .gray : .orange).frame(width: 14, height: 14)
                Text(s.isOn ? "ON" : s.isOff ? "OFF" : "不整合").font(.title2.bold())
                Spacer()
                if driver.busy { ProgressView().controlSize(.small) }
            }
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                GridRow { Text("ドライバ配置"); Text(s.installed ? "あり" : "なし") }
                GridRow { Text("ドライバプロセス"); Text(s.helperPIDs.isEmpty ? "なし" : "PID " + s.helperPIDs.map(String.init).joined(separator: ", ")) }
                GridRow { Text("CoreAudio デバイス"); Text(s.devicePresent ? "登録あり" : "なし") }
            }
            .font(.system(.body, design: .monospaced))
            HStack {
                Button("ON") { driver.turnOn() }
                    .disabled(driver.busy || s.isOn || driver.bundledDriver == nil)
                Button("OFF") { driver.turnOff() }
                    .disabled(driver.busy || s.isOff)
            }
            .controlSize(.large)
            Text("ON/OFF は管理者パスワードが必要です。coreaudiod を再起動するため、他のオーディオデバイスも一瞬途切れます。")
                .font(.caption).foregroundStyle(.secondary)
            if !driver.message.isEmpty {
                Text(driver.message).font(.caption).textSelection(.enabled)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}
