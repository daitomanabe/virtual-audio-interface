import SwiftUI

/// 128ch dBFS level meter grid, drawn as a single Canvas. 128 individual
/// SwiftUI views + GeometryReader (the previous implementation) each
/// re-layout every frame at 60Hz; one Canvas.draw call is far cheaper.
struct LevelMeterGridView: View {
    @ObservedObject var model: AudioLevelsModel
    var labels: [Int: String]
    var assigned: Set<Int>?
    var selectedChannel: Binding<Int?>

    init(model: AudioLevelsModel,
         labels: [Int: String] = [:],
         assigned: Set<Int>? = nil,
         selectedChannel: Binding<Int?> = .constant(nil)) {
        self._model = ObservedObject(wrappedValue: model)
        self.labels = labels
        self.assigned = assigned
        self.selectedChannel = selectedChannel
    }

    private static let minMeterWidth: CGFloat = 36
    private static let rowHeight: CGFloat = 108
    private static let ledSize: CGFloat = 6
    private static let topAreaHeight: CGFloat = 16   // clip LED + "未割当"
    private static let bottomAreaHeight: CGFloat = 24 // channel number + peak dB
    private static let dbMin: Float = -60
    private static let dbMax: Float = 0
    private static let gridlines: [Float] = [0, -6, -12, -24, -48]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("Reset Clips") { model.resetClips() }
                Spacer()
                Text("\(model.status.available ? Int(model.status.channelCount) : AudioLevelsModel.channelCount) ch")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(8)

            GeometryReader { geo in
                let columns = max(1, Int(geo.size.width / Self.minMeterWidth))
                let meterWidth = geo.size.width / CGFloat(columns)
                let rows = Int(ceil(Double(AudioLevelsModel.channelCount) / Double(columns)))
                let canvasHeight = CGFloat(rows) * Self.rowHeight

                ScrollView(.vertical) {
                    Canvas { context, size in
                        draw(context: context, size: size, columns: columns, meterWidth: meterWidth)
                    }
                    .frame(width: geo.size.width, height: canvasHeight)
                    .gesture(SpatialTapGesture().onEnded { value in
                        if let ch = channel(at: value.location, columns: columns, meterWidth: meterWidth) {
                            selectedChannel.wrappedValue = ch
                        }
                    })
                }
            }
        }
    }

    private func channel(at point: CGPoint, columns: Int, meterWidth: CGFloat) -> Int? {
        guard meterWidth > 0 else { return nil }
        let col = Int(point.x / meterWidth)
        let row = Int(point.y / Self.rowHeight)
        guard col >= 0, col < columns, row >= 0 else { return nil }
        let ch = row * columns + col + 1
        return (1...AudioLevelsModel.channelCount).contains(ch) ? ch : nil
    }

    private func draw(context: GraphicsContext, size: CGSize, columns: Int, meterWidth: CGFloat) {
        let activeCount = model.status.available ? Int(model.status.channelCount) : AudioLevelsModel.channelCount
        for ch in 1...AudioLevelsModel.channelCount {
            let index = ch - 1
            let row = index / columns
            let col = index % columns
            let rect = CGRect(x: CGFloat(col) * meterWidth, y: CGFloat(row) * Self.rowHeight,
                               width: meterWidth, height: Self.rowHeight)
            drawMeter(context: context, rect: rect, channel: ch, isActive: ch <= activeCount)
        }
    }

    private func drawMeter(context: GraphicsContext, rect: CGRect, channel ch: Int, isActive: Bool) {
        var layer = context
        let meterRect = rect.insetBy(dx: 2, dy: 2)
        let index = ch - 1
        let peakDB = index < model.peakDB.count ? model.peakDB[index] : AudioLevelsModel.dbFloor
        let rmsDB = index < model.rmsDB.count ? model.rmsDB[index] : AudioLevelsModel.dbFloor
        let holdDB = index < model.holdDB.count ? model.holdDB[index] : AudioLevelsModel.dbFloor
        let isClipped = model.clipped.contains(ch)
        let isSelected = selectedChannel.wrappedValue == ch
        let hasSignal = peakDB > AudioLevelsModel.signalThresholdDB
        let isUnassigned = isActive && hasSignal && assigned != nil && !(assigned?.contains(ch) ?? true)

        layer.opacity = isActive ? 1.0 : 0.3

        // Clip LED (top, latched).
        let ledRect = CGRect(x: meterRect.midX - Self.ledSize / 2, y: meterRect.minY,
                              width: Self.ledSize, height: Self.ledSize)
        layer.fill(Path(ellipseIn: ledRect), with: .color(isClipped ? .red : Color.gray.opacity(0.35)))

        // "未割当" marker.
        if isUnassigned {
            layer.draw(Text("未割当").font(.system(size: 7)).foregroundColor(.orange),
                       at: CGPoint(x: meterRect.midX, y: meterRect.minY + Self.ledSize + 6), anchor: .top)
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

        layer.fill(Path(barRect), with: .color(Color.gray.opacity(0.15)))

        // dB gridlines.
        for db in Self.gridlines {
            let gy = y(forDB: db)
            var p = Path()
            p.move(to: CGPoint(x: barRect.minX, y: gy))
            p.addLine(to: CGPoint(x: barRect.maxX, y: gy))
            layer.stroke(p, with: .color(Color.secondary.opacity(0.3)), lineWidth: 0.5)
        }

        let barColor = color(forDB: rmsDB)
        // RMS: wide bar.
        let rmsRect = CGRect(x: barRect.minX + barRect.width * 0.15, y: y(forDB: rmsDB),
                              width: barRect.width * 0.7, height: barRect.maxY - y(forDB: rmsDB))
        layer.fill(Path(rmsRect), with: .color(barColor.opacity(0.85)))

        // Peak: thin, brighter bar on top of RMS.
        let peakColor = color(forDB: peakDB)
        let peakRect = CGRect(x: barRect.minX + barRect.width * 0.35, y: y(forDB: peakDB),
                               width: barRect.width * 0.3, height: barRect.maxY - y(forDB: peakDB))
        layer.fill(Path(peakRect), with: .color(peakColor.opacity(0.95)))

        // Hold: thin horizontal line.
        if holdDB > Self.dbMin {
            let hy = y(forDB: holdDB)
            var p = Path()
            p.move(to: CGPoint(x: barRect.minX, y: hy))
            p.addLine(to: CGPoint(x: barRect.maxX, y: hy))
            layer.stroke(p, with: .color(.white), lineWidth: 1.5)
        }

        layer.stroke(Path(barRect), with: .color(Color.secondary.opacity(0.4)), lineWidth: 0.5)

        // Channel number + peak dB.
        let labelY = barRect.maxY + 2
        layer.draw(Text("\(ch)").font(.system(size: 9, design: .monospaced)).foregroundColor(.secondary),
                   at: CGPoint(x: meterRect.midX, y: labelY), anchor: .top)
        let dbText = peakDB <= AudioLevelsModel.dbFloor ? "-\u{221E}" : String(format: "%.0f", peakDB)
        layer.draw(Text(dbText).font(.system(size: 8, design: .monospaced)).foregroundColor(.secondary),
                   at: CGPoint(x: meterRect.midX, y: labelY + 10), anchor: .top)
        if let label = labels[ch] {
            let truncated = label.count > 8 ? label.prefix(7) + "\u{2026}" : Substring(label)
            layer.draw(Text(String(truncated)).font(.system(size: 7)).foregroundColor(.secondary),
                       at: CGPoint(x: meterRect.midX, y: labelY + 20), anchor: .top)
        }

        // Selection / unassigned borders drawn last so they sit on top.
        if isUnassigned {
            layer.stroke(Path(meterRect), with: .color(.orange), lineWidth: 1.5)
        }
        if isSelected {
            layer.stroke(Path(meterRect.insetBy(dx: -1, dy: -1)), with: .color(.accentColor), lineWidth: 2)
        }
    }

    private func color(forDB db: Float) -> Color {
        if db > -3 { return .red }
        if db > -12 { return .yellow }
        return .green
    }
}
