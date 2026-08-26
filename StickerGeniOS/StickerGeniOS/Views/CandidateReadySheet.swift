import SwiftUI
import UIKit

/// The candidate decision, presented from the banner that sits above the composer.
///
/// The banner only announces that a decision is waiting; every button lives here, so the
/// transcript keeps its full width and the composer stays the thing under the reader's thumb.
struct CandidateReadySheet: View {
    let revision: StickerRevision
    let assets: [String: UIImage]
    let isBusy: Bool
    let onAccept: () -> Void
    let onCompare: () -> Void
    let onReject: () -> Void

    @Environment(\.dismiss) private var dismiss

    // No `NavigationStack` and no close button: a bar for a lone ✕ costs the medium detent
    // roughly the height of the sticker preview, and the drag indicator already says
    // "swipe me away".
    var body: some View {
        // A plain VStack with a Spacer, not a scroll view with a pinned inset: the content is
        // short enough to never scroll, and the spacer drops the buttons to the bottom without
        // painting a bar behind them that would cut the gradient in half.
        VStack(spacing: 16) {
            header
            preview
            Spacer(minLength: 16)
            actions
        }
        .padding(.top, 24)
        .padding(.horizontal, 24)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            LinearGradient(
                colors: [Color.purple.opacity(0.12), .clear],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
        )
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .accessibilityIdentifier("candidate-sheet")
    }
}

private extension CandidateReadySheet {
    /// Deliberately no big glyph: the sticker below *is* the icon, and at the medium
    /// detent every point spent on chrome is a point taken from the thing being judged.
    var header: some View {
        VStack(spacing: 6) {
            Image(systemName: "sparkles")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.purple)
            Text("Candidate ready")
                .font(.title2.bold())
            Text("Keep it and it becomes the sticker you build on.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }

    var preview: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.background)
            StickerPlayer(document: revision.document, assets: assets, repeats: true)
                .padding(16)
        }
        .frame(height: 160)
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08))
        )
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .accessibilityLabel(
            revision.document.kind == .animated ? "Candidate animated sticker" : "Candidate sticker"
        )
    }

    var actions: some View {
        VStack(spacing: 12) {
            Button {
                dismiss()
                onAccept()
            } label: {
                HStack(spacing: 8) {
                    if isBusy { ProgressView().tint(.white) }
                    Label("Continue with this sticker", systemImage: "checkmark.circle")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.purple)
            .controlSize(.large)
            .disabled(isBusy)
            .accessibilityIdentifier("accept-candidate-next")

            Button {
                dismiss()
                onCompare()
            } label: {
                Label("Compare with previous", systemImage: "rectangle.on.rectangle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(.purple)
            .controlSize(.large)
            .disabled(isBusy)
            .accessibilityIdentifier("compare-candidate")

            Button(role: .destructive) {
                dismiss()
                onReject()
            } label: {
                Label("Reject", systemImage: "xmark.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            // The destructive role alone does not colorize a bordered button against the
            // app's purple accent, and rejecting must not read like another neutral choice.
            .tint(.red)
            .controlSize(.large)
            .disabled(isBusy)
            .accessibilityIdentifier("reject-candidate-next")
        }
    }
}

/// The always-visible half of the decision: a compact banner that rides directly above the
/// composer and opens `CandidateReadySheet`.
struct CandidateReadyBanner: View {
    let isBusy: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                Label("Candidate ready", systemImage: "sparkles")
                Spacer(minLength: 8)
                if isBusy {
                    ProgressView().controlSize(.small)
                } else {
                    Text("Review").fontWeight(.semibold)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.glassProminent)
        .tint(.purple)
        .controlSize(.large)
        .accessibilityIdentifier("candidate-banner")
    }
}

#Preview("Banner") {
    ZStack(alignment: .bottom) {
        Color.gray.opacity(0.15).ignoresSafeArea()
        CandidateReadyBanner(isBusy: false) {}
            .padding(16)
    }
}

#Preview("Sheet") {
    CandidateReadySheet(
        revision: PreviewFixtures.candidate,
        assets: [:],
        isBusy: false,
        onAccept: {},
        onCompare: {},
        onReject: {}
    )
}
