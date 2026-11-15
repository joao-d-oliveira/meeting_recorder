import SwiftUI

struct LevelMeterView: View {
    /// Shown to the left of the bar; nil for a bare bar (e.g. inside an input row).
    var label: String? = nil
    let levelDB: Double

    // Map -60 dB...0 dB onto 0...1.
    private var fraction: CGFloat {
        CGFloat(max(0, min(1, (levelDB + 60) / 60)))
    }

    private var barColor: Color {
        if fraction > 0.85 { return .red }
        if fraction > 0.6 { return .yellow }
        return .green
    }

    var body: some View {
        HStack(spacing: 8) {
            if let label {
                Text(label)
                    .font(.caption)
                    .frame(width: 56, alignment: .leading)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.gray.opacity(0.2))
                    RoundedRectangle(cornerRadius: 3)
                        .fill(barColor)
                        .frame(width: geo.size.width * fraction)
                }
            }
            .frame(height: 8)
        }
        .animation(.linear(duration: 0.1), value: fraction)
    }
}
