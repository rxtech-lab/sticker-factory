import SwiftUI

/// The sticker's name over the live phase, in a Liquid Glass capsule.
///
/// Takes the navigation bar's `.principal` slot rather than using `navigationTitle` plus
/// `navigationSubtitle`, so the two lines share one glass surface and the chip hugs them instead of
/// spanning the bar. The bar's own background is left stock: a chip is a floating label, and glass
/// on top of an always-visible glass bar reads as a smear rather than as two surfaces.
struct ChatTitleChip: View {
    let title: String
    /// `nil` when nothing is running — the chip then shows the title alone and shrinks to fit.
    let status: String?

    var body: some View {
        VStack(spacing: 2) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppColors.ink)
                .lineLimit(1)
            if let status {
                Text(status)
                    .font(.caption2)
                    .foregroundStyle(AppColors.muted)
                    .lineLimit(1)
                    // Keyed on the text so a phase change cross-fades rather than snapping, which
                    // matters when a turn walks through three of them in a few seconds.
                    .id(status)
                    .transition(.opacity)
            }
        }
        .posterChip()
        .animation(.easeInOut(duration: 0.2), value: status)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(status.map { "\(title), \($0)" } ?? title)
        .accessibilityIdentifier("chat-title-chip")
    }
}
