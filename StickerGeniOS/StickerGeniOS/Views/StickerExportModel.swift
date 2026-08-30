import AnimatedView
import Foundation
import Observation
import UIKit

private let preferredStickerSizeKey = "StickerFactoryPreferredStickerSize"
private let preferredExportSelectionKey = "StickerFactoryPreferredExportSelection"

/// Export/publish state for one sticker.
///
/// Owned by the chat screen rather than the export sheet so that dismissing the sheet mid-publish
/// does not discard the rendered files or the job being observed.
@MainActor
@Observable
final class StickerExportModel {
    var isPublishing = false
    var isPreparingShare = false
    var publishedURLs: [URL] = []
    var publishJobID: String?
    var background: ExportBackgroundChoice = .midnight
    var errorMessage: String?
    /// What the ladder gave up to fit Apple's ceiling, when it gave up anything. Not an error: the
    /// export succeeded, and this says what it cost.
    var qualityNote: String?

    /// Not part of the document: the canvas is normalized and every export is square, so the
    /// rendition's pixel size is the only thing that decides how big the sticker arrives. It is
    /// remembered across stickers rather than per sticker — someone who wants small stickers wants
    /// them everywhere — and defaults to the largest rung, which is what the ladder did before.
    var stickerSize: SystemStickerSize = SystemStickerSize(
        rawValue: UserDefaults.standard.string(forKey: preferredStickerSizeKey) ?? ""
    ) ?? .default {
        didSet {
            guard oldValue != stickerSize else { return }
            UserDefaults.standard.set(stickerSize.rawValue, forKey: preferredStickerSizeKey)
        }
    }

    /// Which files the share sheet hands over. Remembered across stickers for the same reason the
    /// size is: someone who wants video wants it every time, not once.
    var selection: StickerExportSelection = StickerExportSelection(
        rawValue: UserDefaults.standard.string(forKey: preferredExportSelectionKey) ?? ""
    ) ?? .default {
        didSet {
            guard oldValue != selection else { return }
            UserDefaults.standard.set(selection.rawValue, forKey: preferredExportSelectionKey)
        }
    }

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

    /// Drops the files staged for sharing without disowning the publish that produced them.
    ///
    /// Changing which formats to share does not invalidate a publish — the sticker set is published
    /// whatever was asked for, and the video can be rendered on demand — so this deliberately keeps
    /// `publishJobID`, which is what the sheet reads to know the sticker landed.
    func clearShareFiles() {
        publishedURLs = []
    }

    func invalidateExports() {
        publishedURLs = []
        publishJobID = nil
        qualityNote = nil
    }

    /// Puts the published files on disk so a revision published in an earlier session — one this
    /// run never rendered anything for — can still be shared.
    ///
    /// - Parameter assets: passed through for the video, which a sticker-only publish never
    ///   uploaded and which is rendered here instead of downloaded.
    /// - Returns: whether `publishedURLs` now holds files to share.
    func prepareShareFiles(
        store: StickerStore,
        revision: StickerRevision,
        assets: [String: UIImage],
        verifiedAssetIDs: Set<String>
    ) async -> Bool {
        guard publishedURLs.isEmpty else { return true }
        isPreparingShare = true
        defer { isPreparingShare = false }
        do {
            let urls = try await StickerPublisher(api: store.api).publishedExports(
                for: revision,
                assets: assets,
                verifiedAssetIDs: verifiedAssetIDs,
                selection: selection
            )
            // An edit landed while the download was in flight: these files are the version the user
            // just moved off, and `seed` has already cleared this sheet's state for the new one.
            guard seededRevisionID == revision.id else { return false }
            publishedURLs = urls
            errorMessage = nil
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
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

            let exports: [RenderedStickerExport]
            var compromise: SystemStickerCompromise?
            if exportRevision.canPublishExports {
                let result = try await publisher.publish(
                    stickerID: stickerID,
                    revision: exportRevision,
                    assets: assets,
                    verifiedAssetIDs: verifiedAssetIDs,
                    size: stickerSize,
                    selection: selection
                )
                exports = result.localExports
                compromise = result.compromise
                publishJobID = result.jobID
                store.observeExternalJob(jobID: result.jobID, stickerID: stickerID)
            } else {
                exports = try await publisher.export(
                    revision: exportRevision,
                    assets: assets,
                    verifiedAssetIDs: verifiedAssetIDs,
                    size: stickerSize,
                    selection: selection
                )
            }
            publishedURLs = exports.map(\.url)
            // The sticker always exports; when the 500 KB ceiling cost it size or motion, say so
            // here rather than failing the export the way this used to. A publish reports its own
            // compromise because the sticker rendition ships whether or not it was asked to share.
            qualityNote = (compromise ?? exports.compactMap(\.compromise).first)?.message
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }
}
