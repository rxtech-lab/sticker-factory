import SwiftUI
import UIKit
import os

/// Touch and hold a subject in the photo, then confirm it in the callout that appears.
///
/// Deliberately close to bare: the photo, a hint, and one button that shows up where the subject is.
/// Every knob this screen used to carry — motion on/off, smoothness, cut-out quality — was a
/// question the user had no basis to answer, asked before they had even chosen a subject. The
/// defaults are now simply used, and motion comes along whenever the photo has it.
///
/// The sheet is an *enhancement* on a photo that is already attached, which is what makes "no
/// subject found" survivable: cancelling leaves the original reference exactly where it was.
struct SubjectLiftSheet: View {
    let capture: LivePhotoCapture
    var basename: String = "capture"
    let onUse: (PendingMediaAttachment) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selection: LiftedSubject?
    @State private var detection: SubjectDetection = .detecting
    @State private var isPressing = false
    @State private var isWorking = false
    @State private var errorMessage: String?

    private var hint: String {
        switch detection {
        case .detecting:
            return String(localized: "Looking for subjects…")
        case .failed:
            return String(localized: "Could not read this photo. Close to keep it as it is.")
        case .found(0):
            return String(localized: "No subject found here. Close to keep the whole photo.")
        case .found:
            return selection == nil
                ? String(localized: "Touch and hold the subject")
                : String(localized: "Touch and hold another subject to switch")
        }
    }

    private var hintSymbol: String {
        switch detection {
        case .detecting: "hourglass"
        case .failed, .found(0): "exclamationmark.circle"
        case .found: "hand.tap"
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                stage
                if isWorking { workingOverlay }
            }
            .navigationTitle("Lift subject")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) { footer }
        }
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled(isWorking)
    }

    private var stage: some View {
        SubjectLiftView(
            image: capture.still,
            selection: $selection,
            detection: $detection,
            isPressing: $isPressing
        )
        .overlay { callout }
        .accessibilityIdentifier("subject-lift-stage")
        .accessibilityLabel("Photo. Touch and hold a subject to lift it out.")
        .padding(.horizontal, 8)
    }

    /// The confirmation, placed over the subject the user just held — the same shape of answer
    /// Photos gives, and the reason nothing else on this screen needs to be a button.
    ///
    /// It waits for the finger to lift (`isPressing`) so it never opens underneath the thumb that
    /// summoned it, and it is clamped inside the stage so a subject near an edge still gets a
    /// callout the user can actually reach.
    private var callout: some View {
        GeometryReader { proxy in
            if let selection, !isPressing, !isWorking {
                Button {
                    Haptics.tap(.medium)
                    Task { await use() }
                } label: {
                    Label(
                        capture.hasMotion ? "Use Live Subject" : "Use Subject",
                        systemImage: capture.hasMotion ? "livephoto" : "sparkles"
                    )
                    .font(.callout.weight(.semibold))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.black)
                .background(.white, in: .capsule)
                .shadow(color: .black.opacity(0.35), radius: 12, y: 4)
                .position(
                    x: min(max(selection.bounds.midX, 92), max(92, proxy.size.width - 92)),
                    y: min(max(selection.bounds.minY - 30, 26), max(26, proxy.size.height - 26))
                )
                .transition(.scale(scale: 0.86).combined(with: .opacity))
                .accessibilityIdentifier("subject-lift-use")
            }
        }
        .animation(.snappy(duration: 0.22), value: isPressing)
        .animation(.snappy(duration: 0.22), value: selection?.bounds)
    }

    private var footer: some View {
        VStack(spacing: 8) {
            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }
            Label(hint, systemImage: hintSymbol)
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.75))
                .multilineTextAlignment(.center)
            Text("Only the subject you lift is uploaded. The rest of the photo stays on your device.")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.45))
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity)
        .animation(.snappy, value: hint)
    }

    private var workingOverlay: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()
            VStack(spacing: 10) {
                ProgressView().controlSize(.large).tint(.white)
                Text(capture.hasMotion ? "Lifting the subject from every frame…" : "Lifting the subject…")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.8))
            }
        }
        .transition(.opacity)
    }

    private func use() async {
        isWorking = true
        defer { isWorking = false }
        do {
            let attachment = try await SubjectLiftPipeline.attachment(
                from: capture,
                anchor: selection.map(\.anchor),
                // Motion is not a question any more. If the photo has it, it is the entire reason
                // this feature exists; if it does not, the pipeline produces a one-frame atlas that
                // is structurally identical and nothing downstream can tell the difference.
                includeMotion: capture.hasMotion,
                settings: .default,
                basename: basename
            )
            Haptics.success()
            onUse(attachment)
            dismiss()
        } catch {
            // The banner gets one sentence; the log gets the type, the domain, and anything the
            // error wrapped, which is what actually identifies where a lift broke.
            SubjectLiftLog.logger.error("sheet: lift failed — \(String(describing: error), privacy: .public)")
            errorMessage = error.localizedDescription
            Haptics.failure()
        }
    }
}
