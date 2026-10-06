import SwiftUI

/// One stat drawn like an RPG status window: a monospaced label and a framed, segmented gauge.
struct PetStatRow: View {
    let title: LocalizedStringKey
    let value: Int
    /// The gauge's ceiling: 100 for happiness and energy, the class's own for HP.
    var maximum: Int = 100
    let symbol: String
    let color: Color

    private static let segments = 20
    /// How long a change stays marked after it lands — long enough to notice on a later glance.
    private static let highlightDuration: Duration = .seconds(60)

    /// The net change still on show, or nil once it has faded. Changes that land while one is
    /// still showing add up, so two quick actions read as their total.
    @State private var delta: Int?
    /// Bumped by every change, restarting the fade-out timer.
    @State private var changeCount = 0

    private var deltaTint: Color { (delta ?? 0) > 0 ? AppColors.mint : AppColors.coral }

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Label(title, systemImage: symbol)
                    .labelStyle(PetStatLabelStyle(color: color))
                Spacer()
                if let delta {
                    PetStatDeltaChip(delta: delta, tint: deltaTint)
                        .transition(.scale(scale: 0.5, anchor: .trailing).combined(with: .opacity))
                }
                Text(verbatim: "\(value)/\(maximum)")
                    .monospacedDigit()
                    .contentTransition(.numericText(value: Double(value)))
            }
            .font(.system(size: 14, weight: .bold, design: .monospaced))
            .foregroundStyle(AppColors.ink)
            gauge
        }
        // A wash behind the whole row, drawn past its edges so marking it never shifts the layout.
        .background {
            if delta != nil {
                RoundedRectangle(cornerRadius: 8)
                    .fill(deltaTint.opacity(0.22))
                    .padding(-6)
                    .transition(.opacity)
            }
        }
        .onChange(of: value) { old, new in
            guard new != old else { return }
            withAnimation(.snappy(duration: 0.3)) { delta = (delta ?? 0) + (new - old) }
            if delta == 0 { withAnimation(.easeOut(duration: 0.3)) { delta = nil } }
            changeCount += 1
        }
        .task(id: changeCount) {
            guard delta != nil else { return }
            try? await Task.sleep(for: Self.highlightDuration)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.5)) { delta = nil }
        }
        .accessibilityElement(children: .combine)
    }

    private var gauge: some View {
        let ceiling = max(maximum, 1)
        let filled = Int((Double(min(max(value, 0), ceiling)) / Double(ceiling) * Double(Self.segments)).rounded())
        return HStack(spacing: 2) {
            ForEach(0..<Self.segments, id: \.self) { index in
                Rectangle()
                    .fill(index < filled ? color : AppColors.ink.opacity(0.08))
                    // A lighter top edge gives each block the bevel of a pixel-art gauge.
                    .overlay(alignment: .top) {
                        if index < filled { Rectangle().fill(.white.opacity(0.35)).frame(height: 3) }
                    }
            }
        }
        .frame(height: 12)
        .padding(3)
        .background(AppColors.card)
        .overlay { Rectangle().strokeBorder(AppColors.ink, lineWidth: 2.5) }
        .accessibilityHidden(true)
    }
}

/// How much a stat just moved: a filled, outlined chip with an arrow, mint for a gain, coral for a loss.
private struct PetStatDeltaChip: View {
    let delta: Int
    let tint: Color

    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: delta > 0 ? "arrow.up" : "arrow.down")
            Text(verbatim: delta > 0 ? "+\(delta)" : "\(delta)")
                .monospacedDigit()
                .contentTransition(.numericText(value: Double(delta)))
        }
        .font(.system(size: 12, weight: .heavy, design: .monospaced))
        .foregroundStyle(AppColors.ink)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(tint, in: .capsule)
        .overlay { Capsule().strokeBorder(AppColors.ink, lineWidth: 2) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(delta > 0 ? Text("Up \(delta)") : Text("Down \(-delta)"))
    }
}

/// Puts the stat's icon in its colour, so each row reads at a glance like a game HUD.
struct PetStatLabelStyle: LabelStyle {
    let color: Color

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon.foregroundStyle(color)
            configuration.title
        }
    }
}
