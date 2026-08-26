import AnimatedView
import Foundation
import Observation
import UIKit

/// Export/publish state for one sticker.
///
/// Owned by the chat screen rather than the export sheet so that dismissing the sheet mid-publish
/// does not discard the rendered files or the job being observed.
@MainActor
@Observable
final class StickerExportModel {
    var isPublishing = false
    var publishedURLs: [URL] = []
    var publishJobID: String?
    var background: ExportBackgroundChoice = .midnight
    var errorMessage: String?

    private var seededRevisionID: String?

    /// Restores the saved MP4 background when a different revision comes into view. Without this
    /// the picker silently resets to the default and the user loses their choice on publish.
    func seed(from revision: StickerRevision) {
        guard seededRevisionID != revision.id else { return }
        // A different revision is a different sticker to ship. Files rendered for the previous one
        // — and the publish job watching it — would otherwise stay on screen as this one's result,
        // handing the user a Share button for the version they just edited away.
        if seededRevisionID != nil { invalidateExports() }
        seededRevisionID = revision.id
        // The document stores a full `AnimatedBackground`, but the publish request — and this
        // picker — only speak the two shapes the server accepts. Anything else leaves the picker on
        // its default rather than silently mapping a radial gradient onto a linear one.
        if let stored = StickerMP4BackgroundV1(revision.document.mp4Background),
           let choice = ExportBackgroundChoice.choice(for: stored) {
            background = choice
        }
    }

    func invalidateExports() {
        publishedURLs = []
        publishJobID = nil
    }

    func exportOrPublish(
        store: StickerStore,
        stickerID: String,
        revision: StickerRevision,
        assets: [String: UIImage],
        verifiedAssetIDs: Set<String>
    ) async {
        isPublishing = true
        defer { isPublishing = false }
        do {
            var exportRevision = revision
            exportRevision.document.mp4Background = background.background.animatedBackground
            let publisher = StickerPublisher(api: store.api)
            publishJobID = nil

            if exportRevision.canPublishExports {
                let result = try await publisher.publish(
                    stickerID: stickerID,
                    revision: exportRevision,
                    assets: assets,
                    verifiedAssetIDs: verifiedAssetIDs
                )
                publishedURLs = result.localExports.map(\.url)
                publishJobID = result.jobID
                store.observeExternalJob(jobID: result.jobID, stickerID: stickerID)
            } else {
                let exports = try await publisher.export(
                    revision: exportRevision,
                    assets: assets,
                    verifiedAssetIDs: verifiedAssetIDs
                )
                publishedURLs = exports.map(\.url)
            }
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }
}
