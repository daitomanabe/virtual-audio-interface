import SwiftUI

/// "All channels" (fixed 1...128 grid) vs "Layout" (grouped by the loaded
/// SSD scene's speaker height layers). Persisted across launches.
enum MeterMode: String, CaseIterable, Identifiable {
    case all, layout
    var id: Self { self }
    var label: String { self == .all ? "All channels" : "Layout" }
}

/// One drawn section of the meter grid: a header (nil for the flat "All
/// channels" grid) plus the channels it contains, laid out in a flow like
/// the original 128-channel grid. `showBadges` gates the Mute/disabled
/// badge — only Layout's SSD-backed groups show it, so "All channels"
/// keeps its existing appearance.
private struct MeterSection: Identifiable {
    let id: String
    let header: String?
    let channels: [Int]
    let showBadges: Bool
}

/// 128ch dBFS level meter grid, drawn as a single Canvas per section. 128
/// individual SwiftUI views + GeometryReader (the previous implementation)
/// each re-layout every frame at 60Hz; one Canvas.draw call per section is
/// far cheaper.
struct LevelMeterGridView: View {
    @ObservedObject var model: AudioLevelsModel
    var speakers: [Speaker]
    var levelOverride: [Float]?      // --docshot synthetic levels
    var selectedChannel: Binding<Int?>

    @State private var mode: MeterMode

    static let modeKey = "meterGridMode"     // shared with DocShot for the layout screenshot

    init(model: AudioLevelsModel,
         speakers: [Speaker] = [],
         levelOverride: [Float]? = nil,
         selectedChannel: Binding<Int?> = .constant(nil)) {
        self._model = ObservedObject(wrappedValue: model)
        self.speakers = speakers
        self.levelOverride = levelOverride
        self.selectedChannel = selectedChannel
        let saved = UserDefaults.standard.string(forKey: Self.modeKey).flatMap(MeterMode.init(rawValue:)) ?? .all
        _mode = State(initialValue: saved)
    }

    private static let minMeterWidth: CGFloat = 36
    private static let rowHeight: CGFloat = 116
    private static let ledSize: CGFloat = 6
    private static let topAreaHeight: CGFloat = 16   // clip LED + "NO SPK"
    private static let bottomAreaHeight: CGFloat = 32 // channel number + peak dB + speaker label
    private static let dbMin: Float = -60
    private static let dbMax: Float = 0
    private static let gridlines: [Float] = [0, -6, -12, -24, -48]
    /// ponytail: fixed adjacent-gap threshold for grouping speakers into height
    /// layers. Good enough for typical dome/ring layouts; promote to a UI
    /// slider if real scenes need a different value.
    private static let layerGapMeters: Double = 0.5

    // MARK: - Derived from `speakers` (scene-wide, cheap even recomputed at 60Hz)

    private var assigned: Set<Int>? { speakers.isEmpty ? nil : Set(speakers.map(\.channel)) }
    private var labels: [Int: String] {
        Dictionary(grouping: speakers, by: \.channel).mapValues { $0.map(\.name).joined(separator: ",") }
    }
    private var mutedChannels: Set<Int> { Set(speakers.filter(\.mute).map(\.channel)) }
    private var disabledChannels: Set<Int> { Set(speakers.filter { !$0.active }.map(\.channel)) }
    /// Channels where no speaker can sound (every speaker on it is muted or disabled).
    private var silentChannels: Set<Int> {
        Set(Dictionary(grouping: speakers, by: \.channel).filter { $0.value.allSatisfy { $0.mute || !$0.active } }.keys)
    }

    /// The selection shown in the mode picker: forced to `.all` (and disabled)
    /// when no scene is loaded, regardless of the persisted preference.
    private var modeBinding: Binding<MeterMode> {
        Binding(
            get: { speakers.isEmpty ? .all : mode },
            set: { newValue in
                mode = newValue
                UserDefaults.standard.set(newValue.rawValue, forKey: Self.modeKey)
            })
    }

    /// Speakers grouped into height layers, highest first: sort by z, start a
    /// new layer whenever the gap to the previous speaker exceeds `layerGapMeters`.
    private static func zLayers(_ speakers: [Speaker]) -> [(z: Double, speakers: [Speaker])] {
        let sorted = speakers.sorted { $0.position.z > $1.position.z }
        var groups: [[Speaker]] = []
        for s in sorted {
            if let lastZ = groups.last?.last?.position.z, lastZ - s.position.z <= layerGapMeters {
                groups[groups.count - 1].append(s)
            } else {
                groups.append([s])
            }
        }
        return groups.map { g in
            (z: g.reduce(0) { $0 + $1.position.z } / Double(g.count), speakers: g)
        }
    }

    private var unassignedWithSignal: [Int] {
        guard !speakers.isEmpty else { return [] }
        let assignedChannels = Set(speakers.map(\.channel))
        return (1...AudioLevelsModel.channelCount).filter {
            !assignedChannels.contains($0) && levels(for: $0).peak > AudioLevelsModel.signalThresholdDB
        }
    }

    private var sections: [MeterSection] {
        guard mode == .layout, !speakers.isEmpty else {
            return [MeterSection(id: "all", header: nil, channels: Array(1...AudioLevelsModel.channelCount), showBadges: false)]
        }
        var result = Self.zLayers(speakers).enumerated().map { i, layer -> MeterSection in
            let channels = Set(layer.speakers.map(\.channel)).sorted()
            let count = layer.speakers.count
            let header = "z \u{2248} \(String(format: "%.1f", layer.z)) m \u{b7} \(count) speaker\(count == 1 ? "" : "s")"
            return MeterSection(id: "layer-\(i)", header: header, channels: channels, showBadges: true)
        }
        let unassigned = unassignedWithSignal
        if !unassigned.isEmpty {
            result.append(MeterSection(id: "unassigned", header: "Unassigned with signal", channels: unassigned, showBadges: false))
        }
        return result
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("Reset Clips") { model.resetClips() }
                Spacer()
                Picker("Mode", selection: modeBinding) {
                    ForEach(MeterMode.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .disabled(speakers.isEmpty)
                .help(speakers.isEmpty ? "Load a .sscene to enable Layout mode" : "")
                Spacer()
                Text("\(model.status.available ? Int(model.status.channelCount) : AudioLevelsModel.channelCount) ch")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(8)

            GeometryReader { geo in
                let columns = max(1, Int(geo.size.width / Self.minMeterWidth))
                let meterWidth = geo.size.width / CGFloat(columns)
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(sections) { section in
                            sectionView(section, columns: columns, meterWidth: meterWidth, width: geo.size.width)
                        }
                    }
                    .padding(.vertical, sections.first?.header != nil ? 8 : 0)
                }
            }
            .background(Color(nsColor: Theme.canvas))
            .environment(\.colorScheme, .dark)     // meters stay on the dark canvas in light mode too
        }
    }

    @ViewBuilder
    private func sectionView(_ section: MeterSection, columns: Int, meterWidth: CGFloat, width: CGFloat) -> some View {
        let rows = max(1, Int(ceil(Double(section.channels.count) / Double(columns))))
        let height = CGFloat(rows) * Self.rowHeight
        VStack(alignment: .leading, spacing: 2) {
            if let header = section.header {
                Text(header).font(Theme.Fonts.caption.bold()).foregroundStyle(.secondary).padding(.horizontal, Theme.Space.s)
            }
            Canvas { context, size in
                draw(context: context, size: size, section: section, columns: columns, meterWidth: meterWidth)
            }
            .frame(width: width, height: height)
            .gesture(SpatialTapGesture().onEnded { value in
                if let ch = channel(at: value.location, section: section, columns: columns, meterWidth: meterWidth) {
                    selectedChannel.wrappedValue = ch
                }
            })
        }
    }

    private func channel(at point: CGPoint, section: MeterSection, columns: Int, meterWidth: CGFloat) -> Int? {
        guard meterWidth > 0 else { return nil }
        let col = Int(point.x / meterWidth)
        let row = Int(point.y / Self.rowHeight)
        guard col >= 0, col < columns, row >= 0 else { return nil }
        let index = row * columns + col
        guard index >= 0, index < section.channels.count else { return nil }
        return section.channels[index]
    }

    private func draw(context: GraphicsContext, size: CGSize, section: MeterSection, columns: Int, meterWidth: CGFloat) {
        let activeCount = model.status.available ? Int(model.status.channelCount) : AudioLevelsModel.channelCount
        for (index, ch) in section.channels.enumerated() {
            let row = index / columns
            let col = index % columns
            let rect = CGRect(x: CGFloat(col) * meterWidth, y: CGFloat(row) * Self.rowHeight,
                               width: meterWidth, height: Self.rowHeight)
            drawMeter(context: context, rect: rect, channel: ch, isActive: ch <= activeCount,
                      muted: section.showBadges && mutedChannels.contains(ch),
                      disabled: section.showBadges && disabledChannels.contains(ch),
                      dimmed: section.showBadges && silentChannels.contains(ch))
        }
    }

    /// Peak/RMS/hold dBFS + clip state for one channel, from either the live
    /// model or (in --docshot) the synthetic override — same values a static
    /// screenshot needs, no ballistics required.
    private func levels(for ch: Int) -> (peak: Float, rms: Float, hold: Float, clipped: Bool) {
        let index = ch - 1
        if let override = levelOverride {
            let db = index >= 0 && index < override.count ? dbFS(override[index]) : AudioLevelsModel.dbFloor
            return (db, db, db, false)
        }
        let peak = index >= 0 && index < model.peakDB.count ? model.peakDB[index] : AudioLevelsModel.dbFloor
        let rms = index >= 0 && index < model.rmsDB.count ? model.rmsDB[index] : AudioLevelsModel.dbFloor
        let hold = index >= 0 && index < model.holdDB.count ? model.holdDB[index] : AudioLevelsModel.dbFloor
        return (peak, rms, hold, model.clipped.contains(ch))
    }

    private func drawMeter(context: GraphicsContext, rect: CGRect, channel ch: Int, isActive: Bool,
                            muted: Bool = false, disabled: Bool = false, dimmed: Bool = false) {
        var layer = context
        let meterRect = rect.insetBy(dx: 2, dy: 2)
        let lv = levels(for: ch)
        let peakDB = lv.peak, rmsDB = lv.rms, holdDB = lv.hold
        let isClipped = lv.clipped
        let isSelected = selectedChannel.wrappedValue == ch
        let hasSignal = peakDB > AudioLevelsModel.signalThresholdDB
        let isUnassigned = isActive && hasSignal && assigned != nil && !(assigned?.contains(ch) ?? true)

        layer.opacity = (isActive ? 1.0 : 0.3) * (dimmed ? 0.5 : 1.0)

        // Clip LED (top, latched).
        let ledRect = CGRect(x: meterRect.midX - Self.ledSize / 2, y: meterRect.minY,
                              width: Self.ledSize, height: Self.ledSize)
        layer.fill(Path(ellipseIn: ledRect), with: .color(isClipped ? Color(nsColor: Theme.levelRed) : Color(nsColor: Theme.canvasLine)))

        // "NO SPK" marker: signal on a channel without a speaker.
        if isUnassigned {
            layer.draw(Text("NO SPK").font(Theme.Fonts.meterBadge).foregroundColor(Color(nsColor: Theme.error)),
                       at: CGPoint(x: meterRect.midX, y: meterRect.minY + Self.ledSize + 6), anchor: .top)
        }

        // Mute / disabled badge (Layout mode's SSD groups only).
        if muted || disabled {
            let badge = [muted ? "M" : nil, disabled ? "off" : nil].compactMap { $0 }.joined(separator: ",")
            layer.draw(Text(badge).font(Theme.Fonts.meterBadge).foregroundColor(Color(nsColor: Theme.inactive)),
                       at: CGPoint(x: meterRect.maxX - 1, y: meterRect.minY), anchor: .topTrailing)
        }

        // Bar area between the top and bottom label bands.
        let barRect = CGRect(x: meterRect.minX, y: meterRect.minY + Self.topAreaHeight,
                              width: meterRect.width,
                              height: meterRect.height - Self.topAreaHeight - Self.bottomAreaHeight)
        guard barRect.height > 0 else { return }

        func y(forDB db: Float) -> CGFloat {
            let clamped = min(max(db, Self.dbMin), Self.dbMax)
            let t = CGFloat((clamped - Self.dbMin) / (Self.dbMax - Self.dbMin))
            return barRect.maxY - t * barRect.height
        }

        layer.fill(Path(barRect), with: .color(Color(nsColor: Theme.canvasTrack)))

        // dB gridlines.
        for db in Self.gridlines {
            let gy = y(forDB: db)
            var p = Path()
            p.move(to: CGPoint(x: barRect.minX, y: gy))
            p.addLine(to: CGPoint(x: barRect.maxX, y: gy))
            layer.stroke(p, with: .color(Color(nsColor: Theme.canvasLine)), lineWidth: 0.5)
        }

        let barColor = Color(nsColor: levelZoneColor(rmsDB))
        // RMS: wide bar.
        let rmsRect = CGRect(x: barRect.minX + barRect.width * 0.15, y: y(forDB: rmsDB),
                              width: barRect.width * 0.7, height: barRect.maxY - y(forDB: rmsDB))
        layer.fill(Path(rmsRect), with: .color(barColor.opacity(0.85)))

        // Peak: thin, brighter bar on top of RMS.
        let peakColor = Color(nsColor: levelZoneColor(peakDB))
        let peakRect = CGRect(x: barRect.minX + barRect.width * 0.35, y: y(forDB: peakDB),
                               width: barRect.width * 0.3, height: barRect.maxY - y(forDB: peakDB))
        layer.fill(Path(peakRect), with: .color(peakColor.opacity(0.95)))

        // Hold: thin horizontal line.
        if holdDB > Self.dbMin {
            let hy = y(forDB: holdDB)
            var p = Path()
            p.move(to: CGPoint(x: barRect.minX, y: hy))
            p.addLine(to: CGPoint(x: barRect.maxX, y: hy))
            layer.stroke(p, with: .color(Color(nsColor: Theme.canvasText)), lineWidth: 1.5)
        }

        layer.stroke(Path(barRect), with: .color(Color(nsColor: Theme.canvasLine)), lineWidth: 0.5)

        // Channel number + peak dB.
        let labelY = barRect.maxY + 2
        layer.draw(Text("\(ch)").font(Theme.Fonts.meterChannel).foregroundColor(Color(nsColor: Theme.canvasText)),
                   at: CGPoint(x: meterRect.midX, y: labelY), anchor: .top)
        let dbText = peakDB <= AudioLevelsModel.dbFloor ? "-\u{221E}" : String(format: "%.0f", peakDB)
        layer.draw(Text(dbText).font(Theme.Fonts.meterValue).foregroundColor(Color(nsColor: Theme.canvasTextDim)),
                   at: CGPoint(x: meterRect.midX, y: labelY + 10), anchor: .top)
        if let label = labels[ch] {
            let truncated = label.count > 8 ? label.prefix(7) + "\u{2026}" : Substring(label)
            layer.draw(Text(String(truncated)).font(Theme.Fonts.meterValue).foregroundColor(Color(nsColor: Theme.canvasTextDim)),
                       at: CGPoint(x: meterRect.midX, y: labelY + 20), anchor: .top)
        }

        // Selection / unassigned borders drawn last so they sit on top.
        if isUnassigned {
            layer.stroke(Path(meterRect), with: .color(Color(nsColor: Theme.error)), lineWidth: 1.5)
        }
        if isSelected {
            layer.stroke(Path(meterRect.insetBy(dx: -1, dy: -1)), with: .color(Color(nsColor: Theme.selection)), lineWidth: 2)
        }
    }

}
