import SwiftUI

struct StickerBackground<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    AppColors.accentSoft.opacity(0.42),
                    AppColors.secondaryAccentSoft.opacity(0.22),
                    Color.clear,
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
            content
        }
        // Every screen is wrapped in this shell, so setting the behavior here gives the
        // whole app one rule: dragging a vertical scroll view puts the keyboard away.
        // Horizontal strips (attachment chips, thumbnails) opt back out with `.never`.
        .scrollDismissesKeyboard(.immediately)
    }
}

struct GlassCard<Content: View>: View {
    var padding: CGFloat = 16
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .glassEffect(.regular, in: .rect(cornerRadius: 24))
    }
}

extension View {
    /// A Liquid Glass capsule chip: padded content over glass, sized to hug what is inside it.
    ///
    /// The padding is baked in ahead of the glass on purpose — the capsule is meant to fit the text,
    /// so any framing belongs *after* this, not before. Bare `.regular` with no tint and no
    /// `.interactive()`, which is what keeps a chip reading as a floating label rather than as a
    /// control the user is meant to press.
    func glassChip() -> some View {
        self
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .glassEffect(.regular, in: .capsule)
    }
}

struct EmptyStateView: View {
    let symbol: String
    let title: String
    let message: String

    var body: some View {
        ContentUnavailableView(title, systemImage: symbol, description: Text(message))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Something that went the way it had to rather than the way that was asked for. Deliberately not
/// an `ErrorBanner`: the work succeeded, and colouring it red would say it did not.
struct NoticeBanner: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "info.circle.fill")
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(.regular, in: .rect(cornerRadius: 16))
            .accessibilityIdentifier("notice-banner")
    }
}

struct ErrorBanner: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.callout)
            .foregroundStyle(.red)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(.regular.tint(.red.opacity(0.12)), in: .rect(cornerRadius: 16))
            .accessibilityIdentifier("error-banner")
    }
}
