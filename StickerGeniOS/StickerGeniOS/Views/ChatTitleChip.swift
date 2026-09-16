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
    var progressCount: String?

    var body: some View {
        VStack(spacing: 2) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppColors.ink)
                .lineLimit(1)
            if let status {
                HStack(spacing: 4) {
                    Text(status)
                        .lineLimit(1)
                    if let progressCount {
                        Text(progressCount)
                            .monospacedDigit()
                            .fixedSize()
                    }
                }
                .font(.caption2)
                .foregroundStyle(AppColors.muted)
                // Only phase changes cross-fade; counts update in place.
                .id(status)
                .transition(.opacity)
            }
        }
        .posterChip()
        .animation(.easeInOut(duration: 0.2), value: status)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(status.map {
            "\(title), \($0)" + (progressCount.map { ", \($0)" } ?? "")
        } ?? title)
        .accessibilityIdentifier("chat-title-chip")
    }
}
