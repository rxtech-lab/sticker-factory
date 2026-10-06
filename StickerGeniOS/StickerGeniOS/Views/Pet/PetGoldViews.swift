import SwiftUI

/// How much gold the pet has, as a coin and a number. Sits beside the pet and atop its actions.
struct PetGoldBadge: View {
    let gold: Int

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "dollarsign.circle.fill").foregroundStyle(.yellow)
            Text(verbatim: "\(gold)")
                .monospacedDigit()
                .contentTransition(.numericText(value: Double(gold)))
        }
        .font(.system(size: 15, weight: .heavy, design: .monospaced))
        .foregroundStyle(AppColors.ink)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.yellow.opacity(0.18), in: .capsule)
        .overlay { Capsule().strokeBorder(AppColors.ink, lineWidth: 2) }
        .animation(.snappy(duration: 0.45), value: gold)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(gold) gold"))
        .accessibilityIdentifier("pet-gold")
    }
}

/// What an action costs or earns in gold, as a small signed chip.
struct PetGoldChip: View {
    let change: Int

    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: "dollarsign.circle.fill").foregroundStyle(.yellow)
            Text(verbatim: change > 0 ? "+\(change)" : "\(change)")
        }
        .font(.system(size: 12, weight: .bold, design: .monospaced))
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Color.yellow.opacity(0.18), in: .capsule)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(change > 0 ? Text("Earns \(change) gold") : Text("Costs \(-change) gold"))
    }
}

/// How one change moves each stat, as small signed chips. Unchanged stats are left out. The diary
/// shows every number; the actions sheet shows only gold.
struct PetEffectsRow: View {
    let effects: PetActionEffects

    var body: some View {
        HStack(spacing: 6) {
            chip(effects.happiness, symbol: "heart.fill", color: .pink, name: "Happiness")
            chip(effects.hp, symbol: "cross.vial.fill", color: .red, name: "HP")
            chip(effects.energy, symbol: "bolt.fill", color: .orange, name: "Energy")
            if effects.gold != 0 { PetGoldChip(change: effects.gold) }
        }
        .font(.system(size: 12, weight: .bold, design: .monospaced))
    }

    @ViewBuilder
    private func chip(_ value: Int, symbol: String, color: Color, name: LocalizedStringKey) -> some View {
        if value != 0 {
            HStack(spacing: 2) {
                Image(systemName: symbol).foregroundStyle(color)
                Text(value > 0 ? "+\(value)" : "\(value)")
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.12), in: .capsule)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(name) + Text(verbatim: " \(value > 0 ? "+" : "")\(value)"))
        }
    }
}
