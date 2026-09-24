import Foundation
import SwiftUI

@MainActor
final class DebugLog: ObservableObject {
    static let shared = DebugLog()
    @Published private(set) var entries: [String] = []
    @Published private(set) var revision = 0
    private let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    func add(_ message: String) {
        entries.append("\(formatter.string(from: Date()))  \(message)")
        if entries.count > 500 { entries.removeFirst(entries.count - 500) }
        revision += 1
    }

    func clear() { entries.removeAll(); revision += 1 }
    var text: String { entries.joined(separator: "\n") }
}

struct DebugLogView: View {
    @ObservedObject var log: DebugLog

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Scene loading, test signal routing, device changes, and output errors")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Copy Log") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(log.text, forType: .string) }
                    .disabled(log.entries.isEmpty)
                Button("Clear") { log.clear() }.disabled(log.entries.isEmpty)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    Text(log.text.isEmpty ? "No events yet." : log.text)
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .id(log.revision)
                }
                .onChange(of: log.revision) { proxy.scrollTo($0, anchor: .bottom) }
            }
        }
        .padding()
    }
}
