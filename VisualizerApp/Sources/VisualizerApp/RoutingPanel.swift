import SwiftUI

struct RoutingIssue: Identifiable {
    enum Severity: Int { case error, warning, info }
    let id: String
    let severity: Severity
    let text: String
    let channel: Int?

    /// Re-evaluated on every level update (30 Hz); O(channels + speakers).
    static func check(speakers: [Speaker], parserWarnings: [String], levels: [Float], deviceChannels: Int) -> [RoutingIssue] {
        var out: [RoutingIssue] = []
        func dbText(_ ch: Int) -> String { String(format: "%.1f dBFS", channelDb(levels, ch)) }
        func sounding(_ ch: Int) -> Bool { channelDb(levels, ch) > LevelThreshold.signal }
        let byChannel = Dictionary(grouping: speakers, by: \.channel)

        for ch in levels.indices.map({ $0 + 1 }) where sounding(ch) && byChannel[ch] == nil {
            out.append(.init(id: "unassigned-\(ch)", severity: .error,
                             text: "Ch \(ch): signal (\(dbText(ch))) but no speaker assigned", channel: ch))
        }
        for (ch, list) in byChannel.sorted(by: { $0.key < $1.key }) {
            let names = list.map(\.displayName).joined(separator: ", ")
            if ch > deviceChannels {
                out.append(.init(id: "range-\(ch)", severity: .error,
                                 text: "Ch \(ch) (\(names)): beyond the device's \(deviceChannels) active channels", channel: ch))
            }
            if list.count > 1 {
                out.append(.init(id: "shared-\(ch)", severity: .info,
                                 text: "Ch \(ch): shared by \(list.count) speakers (\(names))", channel: ch))
            }
            guard sounding(ch) else { continue }
            for s in list where s.mute {
                out.append(.init(id: "mute-\(s.id)", severity: .warning,
                                 text: "Ch \(ch) (\(s.displayName)): muted but carries signal (\(dbText(ch)))", channel: ch))
            }
            for s in list where !s.active {
                out.append(.init(id: "disabled-\(s.id)", severity: .warning,
                                 text: "Ch \(ch) (\(s.displayName)): disabled (Enabled 0 on it or a parent) but carries signal (\(dbText(ch)))", channel: ch))
            }
        }
        for (i, w) in parserWarnings.enumerated() {
            out.append(.init(id: "parser-\(i)", severity: .warning, text: "Parser: \(w)", channel: nil))
        }
        return out.sorted { ($0.severity.rawValue, $0.channel ?? 0) < ($1.severity.rawValue, $1.channel ?? 0) }
    }
}

extension Speaker {
    var displayName: String { name.isEmpty ? "ID \(objectID)" : name }
}

/// Scene info, live routing warnings and the speaker table (selection shared with the 3D view).
/// Only the leaf views that show levels observe `audio`, so a 1000-row table is not
/// re-diffed at 30 Hz.
struct RoutingPanel: View {
    @ObservedObject var sceneModel: SSDSceneModel
    let audio: AudioLevelsModel
    let levelOverride: [Float]?
    @Binding var selectedChannel: Int?
    let applyGain: Bool              // level bars and "sounding" use input + SSD Gain, like the 3D view
    @State private var soundingOnly = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            sceneInfo
            LiveIssues(sceneModel: sceneModel, audio: audio, levelOverride: levelOverride, selectedChannel: $selectedChannel)
            Divider()
            HStack {
                Text("Speakers").font(Theme.Fonts.heading)
                Spacer()
                Toggle("Sounding only", isOn: $soundingOnly)
            }
            if soundingOnly {
                SoundingSpeakerTable(sceneModel: sceneModel, audio: audio, levelOverride: levelOverride,
                                     selectedChannel: $selectedChannel, applyGain: applyGain)
            } else {
                SpeakerTable(rows: sceneModel.speakers, all: sceneModel.speakers, audio: audio,
                             levelOverride: levelOverride, selectedChannel: $selectedChannel, applyGain: applyGain)
            }
        }
        .padding(10)
    }

    @ViewBuilder
    private var sceneInfo: some View {
        if let error = sceneModel.loadError {
            Text("Load error: \(error)").foregroundStyle(Color(nsColor: Theme.error)).textSelection(.enabled)
        }
        let channels = Set(sceneModel.speakers.map(\.channel))
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 3) {
            infoRow("File", sceneModel.path.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Not loaded (Open… or drop a file)")
            infoRow("Scene name", sceneModel.sceneName.isEmpty ? "—" : sceneModel.sceneName)
            infoRow("Speakers", "\(sceneModel.speakers.count) on \(channels.count) channels")
            infoRow("Channels used", channels.isEmpty ? "—" : "\(channels.min()!)–\(channels.max()!)")
            if let v = sceneModel.reviewVolume {
                infoRow("Review volume", String(format: "W %.2f × D %.2f × H %.2f m (context only)", v.x, v.y, v.z))
            }
        }
        .font(.callout)
    }

    private func infoRow(_ title: String, _ value: String) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
        }
    }
}

/// Device channel count + warnings; re-renders with every level update.
private struct LiveIssues: View {
    @ObservedObject var sceneModel: SSDSceneModel
    @ObservedObject var audio: AudioLevelsModel
    let levelOverride: [Float]?
    @Binding var selectedChannel: Int?

    var body: some View {
        let deviceChannels = audio.status.available ? Int(audio.status.channelCount) : AudioLevelsModel.channelCount
        let issues = RoutingIssue.check(speakers: sceneModel.speakers, parserWarnings: sceneModel.warnings,
                                        levels: levelOverride ?? audio.levels, deviceChannels: deviceChannels)
        VStack(alignment: .leading, spacing: 4) {
            Text(audio.status.available ? "Device: \(deviceChannels) channels active" : "Device: driver not connected (checking against \(deviceChannels) channels)")
                .font(.callout).foregroundStyle(.secondary)
            Divider()
            HStack {
                Text("Warnings").font(Theme.Fonts.heading)
                Text("\(issues.count)")
                    .font(.caption.bold().monospacedDigit())
                    .padding(.horizontal, 7).padding(.vertical, 1)
                    .background(Capsule().fill(issues.first.map { color($0.severity) } ?? .green))
                    .foregroundStyle(.white)
            }
            if issues.isEmpty {
                Text("No issues").foregroundStyle(.secondary).font(.callout)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(issues) { issue in
                            Button { if let ch = issue.channel { selectedChannel = ch } } label: {
                                HStack(alignment: .firstTextBaseline, spacing: 6) {
                                    Image(systemName: icon(issue.severity)).foregroundStyle(color(issue.severity))
                                    Text(issue.text).lineLimit(1).truncationMode(.middle)
                                    Spacer(minLength: 0)
                                }
                                .frame(height: 16)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .font(.callout)
                            .help(issue.text)
                        }
                    }
                }
                .frame(height: CGFloat(min(issues.count, 8)) * 19)
            }
        }
    }

    private func color(_ s: RoutingIssue.Severity) -> Color {
        Color(nsColor: s == .error ? Theme.error : s == .warning ? Theme.warning : Theme.info)
    }

    private func icon(_ s: RoutingIssue.Severity) -> String {
        switch s {
        case .error: return "xmark.octagon.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .info: return "info.circle.fill"
        }
    }
}

/// The "Sounding only" variant: the row set itself depends on levels, so this one observes.
/// With Apply SSD gain, "sounding" means input + Gain above the threshold and not muted.
private struct SoundingSpeakerTable: View {
    @ObservedObject var sceneModel: SSDSceneModel
    @ObservedObject var audio: AudioLevelsModel
    let levelOverride: [Float]?
    @Binding var selectedChannel: Int?
    let applyGain: Bool

    var body: some View {
        let levels = levelOverride ?? audio.levels
        SpeakerTable(rows: sceneModel.speakers.filter {
                         $0.db(levels, applyGain: applyGain) > LevelThreshold.signal && !(applyGain && $0.mute)
                     },
                     all: sceneModel.speakers, audio: audio, levelOverride: levelOverride,
                     selectedChannel: $selectedChannel, applyGain: applyGain)
    }
}

private struct SpeakerTable: View {
    let rows: [Speaker]
    let all: [Speaker]
    let audio: AudioLevelsModel
    let levelOverride: [Float]?
    @Binding var selectedChannel: Int?
    let applyGain: Bool

    var body: some View {
        // Table selection is per row; the app-wide selection is a channel (all its speakers).
        let selection = Binding<Set<Int>>(
            get: { Set(all.filter { $0.channel == selectedChannel }.map(\.id)) },
            set: { ids in
                let picked = all.first { ids.contains($0.id) && $0.channel != selectedChannel }
                    ?? all.first { ids.contains($0.id) }
                selectedChannel = picked?.channel
            })
        Table(rows, selection: selection) {
            // Levels sit next to Name so they stay visible when the panel is narrow. The bar is drawn
            // in the column that drives the 3D view (Post-gain with Apply SSD gain, else Level).
            TableColumn("Ch") { Text("\($0.channel)").monospacedDigit() }.width(28)
            TableColumn("Name") { Text($0.name) }.width(min: 36, ideal: 56)
            TableColumn("Level (dBFS)") {
                LevelCell(audio: audio, levelOverride: levelOverride, speaker: $0, postGain: false, showsBar: !applyGain)
            }.width(96)
            TableColumn("Post-gain") {
                LevelCell(audio: audio, levelOverride: levelOverride, speaker: $0, postGain: true, showsBar: applyGain)
            }.width(96)
            TableColumn("ID") { Text($0.objectID) }.width(min: 20, ideal: 28)
            TableColumn("x, y, z (m)") { s in
                Text(String(format: "%.2f, %.2f, %.2f", s.position.x, s.position.y, s.position.z)).monospacedDigit()
            }.width(min: 90, ideal: 116)
            TableColumn("Gain") { Text(String(format: "%.1f", $0.gainDb)).monospacedDigit() }.width(40)
            TableColumn("Delay") { Text(String(format: "%.1f", $0.delayMs)).monospacedDigit() }.width(40)
            TableColumn("Mute") { Text($0.mute ? "M" : "").bold().foregroundStyle(Color(nsColor: Theme.inactive)) }.width(36)
            TableColumn("En") { Text($0.active ? "1" : "0").foregroundStyle(Color(nsColor: $0.active ? .secondaryLabelColor : Theme.inactive)) }.width(20)
        }
    }
}

/// Channel level (dBFS) or, with `postGain`, channel level + SPEAKER Gain ("muted" for muted speakers).
private struct LevelCell: View {
    @ObservedObject var audio: AudioLevelsModel
    let levelOverride: [Float]?
    let speaker: Speaker
    let postGain: Bool
    let showsBar: Bool

    var body: some View {
        let levels = levelOverride ?? audio.levels
        let db = speaker.db(levels, applyGain: postGain)
        HStack(spacing: 5) {
            if postGain && speaker.mute {
                Text("muted").font(.caption).foregroundStyle(.secondary)
            } else {
                ZStack(alignment: .leading) {
                    Rectangle().fill(Color.secondary.opacity(0.2))
                    Rectangle().fill(Color(nsColor: levelColor(db))).frame(width: 44 * levelAmount(db))
                }
                .frame(width: 44, height: 7)
                .opacity(showsBar ? 1 : 0)
                Text(channelDb(levels, speaker.channel) <= -120 ? "-inf" : String(format: "%.1f", db))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(db > LevelThreshold.signal ? Color.primary : Color.secondary)
            }
        }
    }
}
