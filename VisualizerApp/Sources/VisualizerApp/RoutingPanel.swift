import SwiftUI

struct RoutingIssue: Identifiable {
    enum Severity: Int, CaseIterable { case error, warning, info }
    let id: String
    let severity: Severity
    let text: String                 // without the channel, which the list shows in its own column
    let channel: Int?

    /// Re-evaluated on every level update (30 Hz); O(channels + speakers).
    static func check(speakers: [Speaker], parserWarnings: [String], levels: [Float], deviceChannels: Int) -> [RoutingIssue] {
        var out: [RoutingIssue] = []
        func dbText(_ ch: Int) -> String { String(format: "%.1f dBFS", channelDb(levels, ch)) }
        func sounding(_ ch: Int) -> Bool { channelDb(levels, ch) > LevelThreshold.signal }
        let byChannel = Dictionary(grouping: speakers, by: \.channel)

        // Without a layout every channel would be "unassigned"; the meters skip that case too.
        for ch in levels.indices.map({ $0 + 1 }) where !speakers.isEmpty && sounding(ch) && byChannel[ch] == nil {
            out.append(.init(id: "unassigned-\(ch)", severity: .error,
                             text: "Signal at \(dbText(ch)), no speaker assigned", channel: ch))
        }
        for (ch, list) in byChannel.sorted(by: { $0.key < $1.key }) {
            let names = list.map(\.displayName).joined(separator: ", ")
            if ch > deviceChannels {
                out.append(.init(id: "range-\(ch)", severity: .error,
                                 text: "\(names): beyond the device's \(deviceChannels) active channels", channel: ch))
            }
            if list.count > 1 {
                out.append(.init(id: "shared-\(ch)", severity: .info,
                                 text: "Shared by \(list.count) speakers: \(names)", channel: ch))
            }
            guard sounding(ch) else { continue }
            for s in list where s.mute {
                out.append(.init(id: "mute-\(s.id)", severity: .warning,
                                 text: "\(s.displayName) is muted but receives \(dbText(ch))", channel: ch))
            }
            for s in list where !s.active {
                out.append(.init(id: "disabled-\(s.id)", severity: .warning,
                                 text: "\(s.displayName) is disabled (Enabled 0 on it or a parent) but receives \(dbText(ch))",
                                 channel: ch))
            }
        }
        for (i, w) in parserWarnings.enumerated() {
            out.append(.init(id: "parser-\(i)", severity: .warning, text: "Parser: \(w)", channel: nil))
        }
        return out.sorted { ($0.severity.rawValue, $0.channel ?? 0) < ($1.severity.rawValue, $1.channel ?? 0) }
    }
}

extension RoutingIssue.Severity {
    var color: Color { Color(nsColor: self == .error ? Theme.error : self == .warning ? Theme.warning : Theme.info) }
    var icon: String {
        switch self {
        case .error: return "xmark.octagon.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .info: return "info.circle.fill"
        }
    }
}

extension Speaker {
    var displayName: String { name.isEmpty ? "ID \(objectID)" : name }
}

/// Scene summary, live routing warnings and the speaker table (selection shared with the 3D view).
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
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            if sceneModel.loadedAt != nil { sceneInfo }
            LiveIssues(sceneModel: sceneModel, audio: audio, levelOverride: levelOverride, selectedChannel: $selectedChannel)
            Divider()
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                Text("Speakers").font(Theme.Fonts.heading)
                Text("\(sceneModel.speakers.count)").font(Theme.Fonts.number).foregroundStyle(.secondary)
                Spacer()
                Toggle("Sounding only", isOn: $soundingOnly)
                    .controlSize(.small)
                    .help("Only speakers above \(Int(LevelThreshold.signal)) dBFS that can sound")
            }
            if sceneModel.speakers.isEmpty {
                placeholder(sceneModel.path == nil ? "No layout loaded"
                            : sceneModel.loadedAt == nil ? "The layout could not be loaded" : "The layout has no speakers")
            } else if soundingOnly {
                SoundingSpeakerTable(sceneModel: sceneModel, audio: audio, levelOverride: levelOverride,
                                     selectedChannel: $selectedChannel, applyGain: applyGain)
            } else {
                SpeakerTable(rows: sceneModel.speakers, all: sceneModel.speakers, audio: audio,
                             levelOverride: levelOverride, selectedChannel: $selectedChannel, applyGain: applyGain)
            }
        }
        .padding(Theme.Space.m)
    }

    private var sceneInfo: some View {
        let channels = Set(sceneModel.speakers.map(\.channel))
        return Grid(alignment: .leading, horizontalSpacing: Theme.Space.m, verticalSpacing: Theme.Space.xs) {
            infoRow("Scene", sceneModel.sceneName.isEmpty ? "—" : sceneModel.sceneName)
            infoRow("Speakers", "\(sceneModel.speakers.count) on \(channels.count) channels"
                    + (channels.isEmpty ? "" : " (\(channels.min()!)–\(channels.max()!))"))
            if let v = sceneModel.reviewVolume {
                infoRow("Review volume", String(format: "%.2f × %.2f × %.2f m (W × D × H, context only)", v.x, v.y, v.z))
            }
        }
        .font(Theme.Fonts.body)
        .monospacedDigit()
    }

    private func infoRow(_ title: String, _ value: String) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
        }
    }
}

private func placeholder(_ text: String) -> some View {
    Text(text)
        .font(Theme.Fonts.body)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
}

/// Warnings with a count per severity; re-renders with every level update.
private struct LiveIssues: View {
    @ObservedObject var sceneModel: SSDSceneModel
    @ObservedObject var audio: AudioLevelsModel
    let levelOverride: [Float]?
    @Binding var selectedChannel: Int?

    private static let rowHeight: CGFloat = 20

    var body: some View {
        let deviceChannels = audio.status.available ? Int(audio.status.channelCount) : AudioLevelsModel.channelCount
        let issues = RoutingIssue.check(speakers: sceneModel.speakers, parserWarnings: sceneModel.warnings,
                                        levels: levelOverride ?? audio.levels, deviceChannels: deviceChannels)
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            HStack(spacing: Theme.Space.s) {
                Text("Warnings").font(Theme.Fonts.heading)
                ForEach(RoutingIssue.Severity.allCases, id: \.self) { severity in
                    let count = issues.filter { $0.severity == severity }.count
                    if count > 0 {
                        Label("\(count)", systemImage: severity.icon)
                            .font(Theme.Fonts.smallNumber.bold())
                            .foregroundStyle(severity.color)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(severity.color.opacity(0.15), in: Capsule())
                    }
                }
            }
            if !audio.status.available && levelOverride == nil {
                Text("Driver not connected: checking against \(deviceChannels) channels")
                    .font(Theme.Fonts.caption).foregroundStyle(Color(nsColor: Theme.warning))
            }
            if issues.isEmpty {
                Label("No routing problems", systemImage: "checkmark.circle.fill")
                    .font(Theme.Fonts.body)
                    .foregroundStyle(.secondary)
                    .frame(height: Self.rowHeight)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(issues) { row($0) }
                    }
                }
                .frame(height: CGFloat(min(issues.count, 6)) * Self.rowHeight)
            }
        }
    }

    private func row(_ issue: RoutingIssue) -> some View {
        Button { if let ch = issue.channel { selectedChannel = ch } } label: {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                Image(systemName: issue.severity.icon).foregroundStyle(issue.severity.color)
                Text(issue.channel.map { "Ch \($0)" } ?? "File")
                    .font(Theme.Fonts.number)
                    .foregroundStyle(.secondary)
                    .frame(width: 52, alignment: .leading)
                Text(issue.text).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .font(Theme.Fonts.body)
            .padding(.horizontal, Theme.Space.xs)
            .frame(height: Self.rowHeight)
            .background(issue.channel != nil && issue.channel == selectedChannel ? Color(nsColor: Theme.selection).opacity(0.18) : .clear,
                        in: RoundedRectangle(cornerRadius: 4))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(issue.channel.map { "Ch \($0): \(issue.text)" } ?? issue.text)
    }
}

/// The "Sounding only" variant: the row set itself depends on levels, so this one observes.
/// With Apply SSD gain, "sounding" means input + Gain above the threshold on a speaker that can sound.
private struct SoundingSpeakerTable: View {
    @ObservedObject var sceneModel: SSDSceneModel
    @ObservedObject var audio: AudioLevelsModel
    let levelOverride: [Float]?
    @Binding var selectedChannel: Int?
    let applyGain: Bool

    var body: some View {
        let levels = levelOverride ?? audio.levels
        let rows = sceneModel.speakers.filter {
            $0.db(levels, applyGain: applyGain) > LevelThreshold.signal && !(applyGain && $0.silent)
        }
        SpeakerTable(rows: rows, all: sceneModel.speakers, audio: audio, levelOverride: levelOverride,
                     selectedChannel: $selectedChannel, applyGain: applyGain)
            .overlay { if rows.isEmpty { placeholder("No speaker is sounding") } }
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
        let table = Table(rows, selection: selection) {
            // Levels sit next to Name so they stay visible when the panel is narrow. The bar is drawn
            // in the column that drives the 3D view (Post-gain with Apply SSD gain, else Level).
            TableColumn("Ch") { number("\($0.channel)", dim: $0.silent) }.width(28)
            TableColumn("Name") { Text($0.name).foregroundStyle($0.silent ? .secondary : .primary) }
                .width(min: 40, ideal: 56)
            TableColumn("Level dBFS") {
                LevelCell(audio: audio, levelOverride: levelOverride, speaker: $0, postGain: false, showsBar: !applyGain)
            }.width(84)
            TableColumn("Post-gain") {
                LevelCell(audio: audio, levelOverride: levelOverride, speaker: $0, postGain: true, showsBar: applyGain)
            }.width(84)
            TableColumn("Gain dB") { number(String(format: "%.1f", $0.gainDb), dim: $0.gainDb == 0) }.width(52)
            TableColumn("Delay ms") { number(String(format: "%.1f", $0.delayMs), dim: $0.delayMs == 0) }.width(56)
            TableColumn("ID") { Text($0.objectID).foregroundStyle(.secondary) }.width(min: 24, ideal: 30)
            TableColumn("x, y, z m") { s in
                number(String(format: "%.2f, %.2f, %.2f", s.position.x, s.position.y, s.position.z), dim: false)
            }.width(min: 96, ideal: 110)
        }
        if #available(macOS 14.0, *) {
            table.alternatingRowBackgrounds(.disabled)   // no striped empty rows below a short list
        } else {
            table
        }
    }

    /// Right-aligned digits so decimal points line up.
    private func number(_ text: String, dim: Bool) -> some View {
        Text(text)
            .monospacedDigit()
            .lineLimit(1)
            .foregroundStyle(dim ? .secondary : .primary)
            .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

/// Channel level (dBFS) or, with `postGain`, channel level + SPEAKER Gain ("Muted" / "Off" for
/// speakers that cannot sound): the value, then its bar.
private struct LevelCell: View {
    @ObservedObject var audio: AudioLevelsModel
    let levelOverride: [Float]?
    let speaker: Speaker
    let postGain: Bool
    let showsBar: Bool

    var body: some View {
        let levels = levelOverride ?? audio.levels
        let db = speaker.db(levels, applyGain: postGain)
        HStack(spacing: Theme.Space.xs + 2) {
            if postGain && speaker.silent {
                Text(speaker.mute ? "Muted" : "Off").font(Theme.Fonts.caption).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            } else {
                Text(channelDb(levels, speaker.channel) <= -120 ? "-\u{221E}" : String(format: "%.1f", db))
                    .font(Theme.Fonts.smallNumber)
                    .foregroundStyle(db > LevelThreshold.signal ? Color.primary : Color.secondary)
                    .frame(width: 36, alignment: .trailing)
                ZStack(alignment: .leading) {
                    Rectangle().fill(Color.secondary.opacity(0.2))
                    Rectangle().fill(Color(nsColor: levelColor(db))).frame(width: 36 * levelAmount(db))
                }
                .frame(width: 36, height: 7)
                .opacity(showsBar ? 1 : 0)
            }
        }
    }
}
