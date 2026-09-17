import SwiftUI

/// 128ch level meter grid. Plain bars, no per-channel config UI (out of scope
/// for this milestone per the "動く最小実装" brief).
struct LevelMeterGridView: View {
    @ObservedObject var model: AudioLevelsModel
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 16)

    var body: some View {
        // Driver reports 0 until the shm segment is readable; fall back to
        // showing the full grid so the meters still work standalone.
        let active = model.status.available ? Int(model.status.channelCount) : AudioLevelsModel.channelCount
        ScrollView {
            LazyVGrid(columns: columns, spacing: 4) {
                ForEach(0..<AudioLevelsModel.channelCount, id: \.self) { ch in
                    let isActive = ch < active
                    VStack(spacing: 2) {
                        GeometryReader { geo in
                            ZStack(alignment: .bottom) {
                                Rectangle().fill(Color.gray.opacity(0.2))
                                if isActive {
                                    Rectangle()
                                        .fill(barColor(for: model.levels[ch]))
                                        .frame(height: geo.size.height * CGFloat(min(model.levels[ch], 1)))
                                }
                            }
                        }
                        .frame(height: 80)
                        .opacity(isActive ? 1 : 0.25)
                        Text("\(ch + 1)")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(8)
        }
    }

    private func barColor(for level: Float) -> Color {
        if level > 0.9 { return .red }
        if level > 0.7 { return .yellow }
        return .green
    }
}
