import AnimatedView
import SwiftUI
import TipKit
import UIKit

/// The candidate decision, presented from the banner that sits above the composer.
///
/// The banner only announces that a decision is waiting; every button lives here, so the
/// transcript keeps its full width and the composer stays the thing under the reader's thumb.
struct CandidateReadySheet: View {
    /// Which decision is currently in flight, so only the tapped button spins.
    enum Decision {
        case accept
        case reject
    }

    let revision: StickerRevision
    let assets: [String: UIImage]
    let isBusy: Bool
    /// Both decisions report whether they landed. On success the sheet stays put and lets the
    /// candidate disappearing take it away; on failure it leaves so the chat can present its
    /// error alert.
    let onAccept: () async -> Bool
    let onCompare: () -> Void
    let onReject: () async -> Bool

    @Environment(\.dismiss) private var dismiss
    /// The decision the user just tapped. Kept here rather than read off `isBusy` so the spinner
    /// lands on the button they actually pressed.
    @State private var pending: Decision?

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
                colors: [AppColors.accentSoft.opacity(0.5), .clear],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
        )
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        // Swiping the sheet away mid-decision would leave the spinner behind with nothing to
        // report back to.
        .interactiveDismissDisabled(pending != nil)
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
                .foregroundStyle(AppColors.accent)
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

    /// Whether every button should be inert: one decision at a time, and none at all while the
    /// screen behind is already deciding.
    var isLocked: Bool { isBusy || pending != nil }

    var actions: some View {
        VStack(spacing: 12) {
            Button {
                decide(.accept, run: onAccept)
            } label: {
                decisionLabel(
                    "Continue with this sticker",
                    systemImage: "checkmark.circle",
                    spinning: pending == .accept,
                    spinnerTint: .white
                )
            }
            .buttonStyle(.borderedProminent)
            .tint(AppColors.accent)
            .controlSize(.large)
            .disabled(isLocked)
            .accessibilityIdentifier("accept-candidate-next")

            Button {
                dismiss()
                onCompare()
            } label: {
                Label("Compare with previous", systemImage: "rectangle.on.rectangle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(AppColors.accent)
            .controlSize(.large)
            .disabled(isLocked)
            .accessibilityIdentifier("compare-candidate")

            Button(role: .destructive) {
                decide(.reject, run: onReject)
            } label: {
                decisionLabel(
                    "Reject",
                    systemImage: "xmark.circle",
                    spinning: pending == .reject,
                    spinnerTint: .red
                )
            }
            .buttonStyle(.bordered)
            // The destructive role alone does not colorize a bordered button against the
            // app's purple accent, and rejecting must not read like another neutral choice.
            .tint(.red)
            .controlSize(.large)
            .disabled(isLocked)
            .accessibilityIdentifier("reject-candidate-next")
        }
        // The spinner slides in beside the title rather than popping the row wider in one frame.
        .animation(.easeInOut(duration: 0.2), value: pending)
    }

    /// The spinner sits inside the label so the button keeps its own disabled dimming, and the
    /// title stays centred on the button rather than shifting when the spinner appears.
    func decisionLabel(
        _ title: String,
        systemImage: String,
        spinning: Bool,
        spinnerTint: Color
    ) -> some View {
        Label(title, systemImage: systemImage)
            .frame(maxWidth: .infinity)
            .overlay(alignment: .trailing) {
                if spinning {
                    ProgressView()
                        .controlSize(.small)
                        .tint(spinnerTint)
                        .transition(.opacity.combined(with: .scale))
                }
            }
    }

    func decide(_ decision: Decision, run: @escaping () async -> Bool) {
        guard pending == nil else { return }
        pending = decision
        Task {
            let landed = await run()
            pending = nil
            // A failed decision leaves the candidate in place, so the sheet has to step aside for
            // the chat's error alert.
            if !landed { dismiss() }
        }
    }
}

/// The always-visible half of the decision: a compact banner that rides directly above the
/// composer and opens `CandidateReadySheet`.
struct CandidateReadyBanner: View {
    let isBusy: Bool
    let onTap: () -> Void
    private let reviewTip = ReviewCandidateTip()

    var body: some View {
        Button {
            reviewTip.invalidate(reason: .actionPerformed)
            onTap()
        } label: {
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
        .tint(AppColors.accent)
        .controlSize(.large)
        .popoverTip(reviewTip, arrowEdge: .bottom)
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
        onAccept: {
            try? await Task.sleep(for: .seconds(2))
            return true
        },
        onCompare: {},
        onReject: {
            try? await Task.sleep(for: .seconds(2))
            return true
        }
    )
}
