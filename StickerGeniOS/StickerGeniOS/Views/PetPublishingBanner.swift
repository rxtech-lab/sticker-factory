import SwiftUI

/// The pet builds and publishes its new look in the background; nothing here is for the owner to
/// decide, so the banner only says it is on its way.
struct PetPublishingBanner: View {
    var body: some View {
        HStack(spacing: 10) {
            ProgressView()
                .tint(AppColors.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text("Publishing…")
                    .font(.posterDisplay(14, weight: .bold))
                    .foregroundStyle(AppColors.ink)
                Text("Your pet is publishing its new look in the background.")
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(AppColors.muted)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .posterSurface(cornerRadius: Poster.tileRadius, offset: Poster.smallShadow)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("chat-pet-publishing-banner")
    }
}
