import SwiftUI

/// "All channels" (fixed 1...128 grid) vs "Layout" (grouped by the loaded
/// SSD scene's speaker height layers). Persisted across launches.
enum MeterMode: String, CaseIterable, Identifiable {
    case all, layout
    var id: Self { self }
    var label: String { self == .all ? "All channels" : "Layout" }
}

/// 128 ch dBFS meters, drawn in a single Canvas: 128 SwiftUI views + GeometryReader (an earlier
/// implementation) each re-layout every frame at 60 Hz, one Canvas.draw is far cheaper.
/// "All channels" is a grid of every channel. "Layout" groups the scene's channels by speaker height
/// and flows the groups across the width. Both stretch the meters to the available height.
struct LevelMeterGridView: View {
    @ObservedObject var model: AudioLevelsModel
    var speakers: [Speaker]
    var levelOverride: [Float]?      // --docshot synthetic levels
    var selectedChannel: Binding<Int?>

    /// Set by the picker in the top bar (ContentView) and by DocShot.
    @AppStorage(LevelMeterGridView.modeKey) private var mode = MeterMode.all

    static let modeKey = "meterGridMode"

    private static let minMeterWidth: CGFloat = 36
    private static let maxMeterWidth: CGFloat = 88     // Layout: a few meters get wider, up to this
    private static let maxBarWidth: CGFloat = 40
    private static let minRowHeight: CGFloat = 108    // all 128 channels fit a 1000x640 window
    private static let headerHeight: CGFloat = 22
    private static let groupGap: CGFloat = 24
    private static let lineGap: CGFloat = 12
    private static let pad: CGFloat = Theme.Space.s
    private static let ledSize: CGFloat = 6
    private static let topAreaHeight: CGFloat = 20     // clip LED + NO SPK / MUTE / OFF
    private static let bottomAreaHeight: CGFloat = 38  // channel number + peak dB + speaker label
    private static let dbMin: Float = -60
    private static let dbMax: Float = 0
    private static let gridlines: [Float] = [0, -6, -12, -24, -48]
    private static let headerFont = NSFont.systemFont(ofSize: 11, weight: .semibold)
    /// ponytail: fixed adjacent-gap threshold for grouping speakers into height
    /// layers. Good enough for typical dome/ring layouts; promote to a UI
    /// slider if real scenes need a different value.
    private static let layerGapMeters: Double = 0.5

    private struct Group {
        let header: String?
        let detail: String
        let channels: [Int]
        var isError = false
    }

    /// Where everything goes for the current size; recomputed per frame (cheap arithmetic).
    private struct Plan {
        var meters: [(channel: Int, rect: CGRect)] = []
        var headers: [(group: Group, at: CGPoint)] = []
        var height: CGFloat = 0
    }

    // MARK: - Derived from `speakers` (scene-wide, cheap even recomputed at 60Hz)

    private var assigned: Set<Int>? { speakers.isEmpty ? nil : Set(speakers.map(\.channel)) }
    private var labels: [Int: String] {
        Dictionary(grouping: speakers, by: \.channel).mapValues { $0.map(\.name).joined(separator: ",") }
    }
    /// Channels no speaker can sound on (every speaker on it is muted or disabled): "MUTE" when one
    /// of them is muted, else "OFF".
    private var silentBadges: [Int: String] {
        Dictionary(grouping: speakers, by: \.channel)
            .filter { $0.value.allSatisfy(\.silent) }
            .mapValues { $0.contains(where: \.mute) ? "MUTE" : "OFF" }
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

    private var groups: [Group] {
        guard mode == .layout else {
            return [Group(header: nil, detail: "", channels: Array(1...AudioLevelsModel.channelCount))]
        }
        var result = Self.zLayers(speakers).map { layer -> Group in
            let count = layer.speakers.count
            return Group(header: "z \u{2248} \(String(format: "%.1f", layer.z)) m",
                         detail: " \u{b7} \(count) speaker\(count == 1 ? "" : "s")",
                         channels: Set(layer.speakers.map(\.channel)).sorted())
        }
        let unassigned = unassignedWithSignal
        if !unassigned.isEmpty {
            result.append(Group(header: "Unassigned with signal", detail: "", channels: unassigned, isError: true))
        }
        return result
    }

    var body: some View {
        GeometryReader { geo in
            if mode == .layout && speakers.isEmpty {
                emptyLayout.frame(width: geo.size.width, height: geo.size.height)
            } else {
                let plan = plan(for: geo.size)
                ScrollView(.vertical) {
                    Canvas { context, _ in draw(context: context, plan: plan) }
                        .frame(width: geo.size.width, height: plan.height)
                        .gesture(SpatialTapGesture().onEnded { value in
                            if let hit = plan.meters.first(where: { $0.rect.contains(value.location) }) {
                                selectedChannel.wrappedValue = hit.channel
                            }
                        })
                }
                .overlay(alignment: .bottomLeading) { signalNotice }
            }
        }
        .background(Color(nsColor: Theme.canvas))
        .environment(\.colorScheme, .dark)     // meters stay on the dark canvas in light mode too
    }

    private var emptyLayout: some View {
        VStack(spacing: Theme.Space.s) {
            Image(systemName: "square.3.layers.3d.down.right").font(.system(size: 28)).foregroundStyle(.secondary)
            Text("No speaker layout loaded").font(Theme.Fonts.heading)
            Text("Layout groups the meters by speaker height. Open a .sscene file, or switch to All channels.")
                .font(Theme.Fonts.body).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding()
    }

    /// Says why every meter is empty: no driver, or no signal on any channel.
    @ViewBuilder
    private var signalNotice: some View {
        let silence = !(1...AudioLevelsModel.channelCount).contains { levels(for: $0).peak > AudioLevelsModel.signalThresholdDB }
        if levelOverride == nil && !model.status.available {
            notice("Driver not connected: no levels", systemImage: "exclamationmark.triangle.fill", color: Theme.warning)
        } else if silence {
            notice("No signal on any channel", systemImage: "speaker.slash", color: Theme.canvasTextDim)
        }
    }

    private func notice(_ text: String, systemImage: String, color: NSColor) -> some View {
        Label(text, systemImage: systemImage)
            .font(Theme.Fonts.body)
            .foregroundStyle(Color(nsColor: color))
            .padding(.horizontal, Theme.Space.s).padding(.vertical, Theme.Space.xs)
            .background(Color(nsColor: Theme.canvas).opacity(0.9), in: RoundedRectangle(cornerRadius: Theme.radius))
            .padding(Theme.Space.s)
            .allowsHitTesting(false)
    }

    // MARK: - layout

    private func plan(for size: CGSize) -> Plan {
        let groups = self.groups
        let width = size.width - 2 * Self.pad
        var plan = Plan()
        if groups.count == 1, groups[0].header == nil {
            // All channels: a plain grid, rows stretched to the height.
            let channels = groups[0].channels
            let cols = max(1, Int(width / Self.minMeterWidth))
            let w = width / CGFloat(cols)
            let rows = (channels.count + cols - 1) / cols
            let h = max(Self.minRowHeight, (size.height - 2 * Self.pad) / CGFloat(rows))
            for (i, ch) in channels.enumerated() {
                plan.meters.append((ch, CGRect(x: Self.pad + CGFloat(i % cols) * w, y: Self.pad + CGFloat(i / cols) * h,
                                               width: w, height: h)))
            }
            plan.height = 2 * Self.pad + CGFloat(rows) * h
            return plan
        }

        // Layout: one block per group (header + meters), blocks flow left to right and wrap;
        // a group wider than a line wraps its own meters. Meters get the widest width (up to
        // maxMeterWidth) that needs no more lines than the narrowest one.
        let headerWidths = groups.map {
            min((($0.header ?? "") + $0.detail as NSString).size(withAttributes: [.font: Self.headerFont]).width + 4, width)
        }
        func flow(_ w: CGFloat) -> [[(group: Int, x: CGFloat, cols: Int, rows: Int)]] {
            let perLine = max(1, Int(width / w))
            var lines: [[(group: Int, x: CGFloat, cols: Int, rows: Int)]] = [[]]
            var x: CGFloat = 0
            for (i, g) in groups.enumerated() {
                let cols = min(g.channels.count, perLine)
                let rows = (g.channels.count + cols - 1) / cols
                let blockWidth = max(CGFloat(cols) * w, headerWidths[i])
                if !lines[lines.count - 1].isEmpty && x + blockWidth > width {
                    lines.append([])
                    x = 0
                }
                lines[lines.count - 1].append((i, x, cols, rows))
                x += blockWidth + Self.groupGap
            }
            return lines
        }
        let fewest = flow(Self.minMeterWidth).count
        var w = Self.maxMeterWidth
        while w > Self.minMeterWidth && flow(w).count > fewest { w -= 2 }
        w = max(w, Self.minMeterWidth)
        let lines = flow(w)
        let meterRows = lines.reduce(0) { $0 + ($1.map(\.rows).max() ?? 0) }
        let fixed = 2 * Self.pad + CGFloat(lines.count) * Self.headerHeight + CGFloat(lines.count - 1) * Self.lineGap
        let h = max(Self.minRowHeight, (size.height - fixed) / CGFloat(max(meterRows, 1)))
        var y = Self.pad
        for line in lines {
            for block in line {
                let g = groups[block.group]
                plan.headers.append((g, CGPoint(x: Self.pad + block.x, y: y)))
                for (i, ch) in g.channels.enumerated() {
                    plan.meters.append((ch, CGRect(x: Self.pad + block.x + CGFloat(i % block.cols) * w,
                                                   y: y + Self.headerHeight + CGFloat(i / block.cols) * h,
                                                   width: w, height: h)))
                }
            }
            y += Self.headerHeight + CGFloat(line.map(\.rows).max() ?? 0) * h + Self.lineGap
        }
        plan.height = y - Self.lineGap + Self.pad
        return plan
    }

    // MARK: - drawing

    private func draw(context: GraphicsContext, plan: Plan) {
        for (group, at) in plan.headers {
            let title = Text(group.header ?? "").foregroundColor(Color(nsColor: group.isError ? Theme.error : Theme.canvasText))
                + Text(group.detail).foregroundColor(Color(nsColor: Theme.canvasTextDim))
            context.draw(title.font(.system(size: Self.headerFont.pointSize, weight: .semibold)), at: CGPoint(x: at.x + 2, y: at.y + 4), anchor: .topLeading)
        }
        let activeCount = model.status.available ? Int(model.status.channelCount) : AudioLevelsModel.channelCount
        let badges = silentBadges, labels = labels, assigned = assigned
        for (ch, rect) in plan.meters {
            drawMeter(context: context, rect: rect, channel: ch, isActive: ch <= activeCount,
                      badge: badges[ch], label: labels[ch], assigned: assigned)
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

    /// One meter. `badge` marks a channel no speaker can sound on (MUTE / OFF): drawn gray like the
    /// 3D view, with a warning frame while signal still arrives. Signal on a channel without a
    /// speaker gets an error frame and NO SPK.
    private func drawMeter(context: GraphicsContext, rect: CGRect, channel ch: Int, isActive: Bool,
                           badge: String?, label: String?, assigned: Set<Int>?) {
        var layer = context
        let cell = rect.insetBy(dx: 2, dy: 2)
        let lv = levels(for: ch)
        let hasSignal = lv.peak > AudioLevelsModel.signalThresholdDB
        let isUnassigned = isActive && hasSignal && assigned.map { !$0.contains(ch) } == true
        let warn = badge != nil && hasSignal
        layer.opacity = (isActive ? 1.0 : 0.3) * (badge != nil && !warn ? 0.55 : 1.0)

        // Top band: latched clip LED, then the channel's state.
        let ledRect = CGRect(x: cell.midX - Self.ledSize / 2, y: cell.minY, width: Self.ledSize, height: Self.ledSize)
        layer.fill(Path(ellipseIn: ledRect), with: .color(Color(nsColor: lv.clipped ? Theme.levelRed : Theme.canvasLine)))
        if let state = isUnassigned ? "NO SPK" : badge {
            let color = isUnassigned ? Theme.error : warn ? Theme.warning : Theme.inactive
            layer.draw(Text(state).font(Theme.Fonts.meterBadge).foregroundColor(Color(nsColor: color)),
                       at: CGPoint(x: cell.midX, y: cell.minY + Self.ledSize + 2), anchor: .top)
        }

        // Bar area between the top and bottom label bands, at most maxBarWidth wide.
        let barWidth = min(cell.width, Self.maxBarWidth)
        let barRect = CGRect(x: cell.midX - barWidth / 2, y: cell.minY + Self.topAreaHeight,
                             width: barWidth, height: cell.height - Self.topAreaHeight - Self.bottomAreaHeight)
        guard barRect.height > 0 else { return }

        func y(forDB db: Float) -> CGFloat {
            let clamped = min(max(db, Self.dbMin), Self.dbMax)
            let t = CGFloat((clamped - Self.dbMin) / (Self.dbMax - Self.dbMin))
            return barRect.maxY - t * barRect.height
        }

        layer.fill(Path(barRect), with: .color(Color(nsColor: Theme.canvasTrack)))
        for db in Self.gridlines {
            let gy = y(forDB: db)
            var p = Path()
            p.move(to: CGPoint(x: barRect.minX, y: gy))
            p.addLine(to: CGPoint(x: barRect.maxX, y: gy))
            layer.stroke(p, with: .color(Color(nsColor: Theme.canvasLine)), lineWidth: 0.5)
        }

        // RMS: wide bar; peak: thin, brighter bar on top. Gray when no speaker can sound.
        func color(_ db: Float) -> Color { Color(nsColor: badge != nil ? Theme.inactive : levelZoneColor(db)) }
        layer.fill(Path(CGRect(x: barRect.minX + barRect.width * 0.15, y: y(forDB: lv.rms),
                               width: barRect.width * 0.7, height: barRect.maxY - y(forDB: lv.rms))),
                   with: .color(color(lv.rms).opacity(0.85)))
        layer.fill(Path(CGRect(x: barRect.minX + barRect.width * 0.35, y: y(forDB: lv.peak),
                               width: barRect.width * 0.3, height: barRect.maxY - y(forDB: lv.peak))),
                   with: .color(color(lv.peak)))

        // Hold: thin horizontal line.
        if lv.hold > Self.dbMin {
            let hy = y(forDB: lv.hold)
            var p = Path()
            p.move(to: CGPoint(x: barRect.minX, y: hy))
            p.addLine(to: CGPoint(x: barRect.maxX, y: hy))
            layer.stroke(p, with: .color(Color(nsColor: Theme.canvasText)), lineWidth: 1.5)
        }
        layer.stroke(Path(barRect), with: .color(Color(nsColor: Theme.canvasLine)), lineWidth: 0.5)

        // Channel number, peak dB, speaker name.
        let labelY = barRect.maxY + 3
        layer.draw(Text("\(ch)").font(Theme.Fonts.meterChannel).foregroundColor(Color(nsColor: Theme.canvasText)),
                   at: CGPoint(x: cell.midX, y: labelY), anchor: .top)
        let dbText = lv.peak <= AudioLevelsModel.dbFloor ? "-\u{221E}" : String(format: "%.0f", lv.peak)
        layer.draw(Text(dbText).font(Theme.Fonts.meterValue).foregroundColor(Color(nsColor: Theme.canvasTextDim)),
                   at: CGPoint(x: cell.midX, y: labelY + 12), anchor: .top)
        if let label {
            let maxChars = max(3, Int(cell.width / 6))
            let shown = label.count > maxChars ? label.prefix(maxChars - 1) + "\u{2026}" : Substring(label)
            layer.draw(Text(String(shown)).font(Theme.Fonts.meterValue).foregroundColor(Color(nsColor: Theme.canvasTextDim)),
                       at: CGPoint(x: cell.midX, y: labelY + 23), anchor: .top)
        }

        // Frames last so they sit on top: problem first, selection outermost.
        if isUnassigned || warn {
            layer.stroke(Path(cell), with: .color(Color(nsColor: isUnassigned ? Theme.error : Theme.warning)), lineWidth: 1.5)
        }
        if selectedChannel.wrappedValue == ch {
            context.stroke(Path(cell.insetBy(dx: -1.5, dy: -1.5)), with: .color(Color(nsColor: Theme.selection)), lineWidth: 2)
        }
    }
}
