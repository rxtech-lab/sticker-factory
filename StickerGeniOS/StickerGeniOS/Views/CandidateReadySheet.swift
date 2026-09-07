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
    var videos: [String: KeyedVideoFrames] = [:]
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
        GeometryReader { proxy in
            // Keep the actions at the bottom when everything fits. On a shorter medium detent
            // (or with larger text), let the content grow and scroll from its natural top instead
            // of centring an oversized stack and clipping the eyebrow above the sheet.
            ScrollView {
                VStack(spacing: 16) {
                    header
                    preview
                    Spacer(minLength: 16)
                    actions
                }
                .padding(.top, 24)
                .padding(.horizontal, 24)
                .padding(.bottom, 8)
                .frame(minHeight: proxy.size.height)
            }
            .scrollIndicators(.hidden)
            .scrollBounceBehavior(.basedOnSize)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { PosterPaper() }
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
        VStack(spacing: 8) {
            PosterEyebrow(text: String(localized: "Fresh off the press"), fill: AppColors.lime)
            Text("Candidate ready")
                .font(.posterDisplay(26, weight: .heavy))
                .foregroundStyle(AppColors.ink)
            Text("Keep it and it becomes the sticker you build on.")
                .font(.system(size: 14, design: .rounded))
                .foregroundStyle(AppColors.muted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }

    var preview: some View {
        StickerPlayer(document: revision.document, assets: assets, videos: videos, repeats: true)
            .padding(16)
            .frame(maxWidth: .infinity)
            .frame(height: 160)
            .posterSurface(cornerRadius: Poster.cardRadius, fill: AppColors.paper)
            .padding(.trailing, Poster.mediumShadow.width)
            .padding(.bottom, Poster.mediumShadow.height)
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
                    spinnerTint: AppColors.card
                )
            }
            .buttonStyle(.poster)
            .disabled(isLocked)
            .accessibilityIdentifier("accept-candidate-next")

            Button {
                dismiss()
                onCompare()
            } label: {
                Label("Compare with previous", systemImage: "rectangle.on.rectangle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.posterSecondary)
            .disabled(isLocked)
            .accessibilityIdentifier("compare-candidate")

            Button(role: .destructive) {
                decide(.reject, run: onReject)
            } label: {
                decisionLabel(
                    "Reject",
                    systemImage: nil,
                    spinning: pending == .reject,
                    spinnerTint: AppColors.card
                )
            }
            // Coral, not another cream button: turning the sticker down must not read as the
            // third neutral choice in a row.
            .buttonStyle(.posterDanger)
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
        systemImage: String?,
        spinning: Bool,
        spinnerTint: Color
    ) -> some View {
        Group {
            if let systemImage {
                Label {
                    Text(title)
                } icon: {
                    Image(systemName: systemImage)
                }
            } else {
                Text(title)
            }
        }
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
                    ProgressView().controlSize(.small).tint(AppColors.ink)
                } else {
                    Text("Review")
                }
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.posterLime)
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
