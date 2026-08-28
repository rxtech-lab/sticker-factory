import PhotosUI
import SwiftUI
import UIKit
import os

/// A photo waiting for the user to choose a subject in it.
///
/// `replacing` is the reference this lift will stand in for. It is always set now: a lift is only
/// ever reached by tapping a photo that is already attached, so it refines an existing reference
/// rather than adding a second one.
nonisolated struct PendingLift: Identifiable {
    let id = UUID()
    var capture: LivePhotoCapture
    var replacing: UUID?
}

extension View {
    /// Presents the subject-lift sheet and files its result into `references`.
    ///
    /// Shared by both composers so "what a lift does to the attachment list" is decided once.
    /// Replacing in place rather than appending matters because the sheet is always opened from a
    /// photo that is already attached: appending would leave the user with the original *and* the
    /// cut-out, and the original is the one they were trying to replace.
    func subjectLiftSheet(
        pending: Binding<PendingLift?>,
        references: Binding<[PendingMediaAttachment]>,
        basename: String
    ) -> some View {
        sheet(item: pending) { lift in
            SubjectLiftSheet(
                capture: lift.capture,
                basename: "\(basename)-\(references.wrappedValue.count + 1)"
            ) { attachment in
                if let replacing = lift.replacing,
                   let index = references.wrappedValue.firstIndex(where: { $0.id == replacing }) {
                    var replacement = attachment
                    // Carried across so a second tap can still reach the paired video. Without it
                    // the first lift would quietly downgrade the photo to a still for good.
                    replacement.source = references.wrappedValue[index].source
                    references.wrappedValue[index] = replacement
                } else {
                    references.wrappedValue.append(attachment)
                }
                Haptics.selection()
            }
        }
    }
}

/// Re-opens an attached photo as something the lift sheet can work on.
@MainActor
enum SubjectLiftPresenter {
    /// Prefers the original picked item, and falls back to the bytes already in hand.
    ///
    /// The fallback is a genuine degrade rather than a failure path: it yields a still, which the
    /// pipeline turns into a one-frame atlas that behaves like any other capture. Reaching it means
    /// the user gets a cut-out without motion, which is still the thing they asked for.
    static func lift(from reference: PendingMediaAttachment) async -> PendingLift? {
        if let source = reference.source,
           let capture = try? await LivePhotoImporter.capture(from: source) {
            return PendingLift(capture: capture, replacing: reference.id)
        }
        SubjectLiftLog.logger.info("present: no original item available, lifting from normalized bytes")
        guard let image = UIImage(data: reference.data)?.cgImage else { return nil }
        return PendingLift(
            capture: LivePhotoCapture(still: image, videoURL: nil, stillTimeSeconds: nil),
            replacing: reference.id
        )
    }
}
