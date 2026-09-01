import AnimatedView
import Foundation
import Observation
import OSLog
import UIKit

// There is no preferred sticker size any more. A publish renders every size the sticker can be
// sent at, and which one arrives is chosen in WinkySticker at send time — where the conversation
// it is going into is actually known. `StickerFactoryPreferredStickerSize` is deliberately not
// migrated: the value it held is no longer a question anyone is asked.
private let preferredExportSelectionKey = "StickerFactoryPreferredExportSelection"
private let preferredSharingFormatKey = "StickerFactoryPreferredSharingFormat"

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
    /// The timeline of the run in progress, or of the last one. Kept here rather than on the sheet
    /// that draws it so a publish that outlives its progress sheet keeps reporting somewhere.
    private(set) var progress: StickerExportProgress?
    /// The run in flight, so Cancel has something to stop. Held here for the same reason the
    /// timeline is: the sheet that starts a run is not the only thing that can outlive it.
    private var exportTask: Task<Void, Never>?

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

    /// Which container an animated sticker is shared in. Remembered across stickers for the same
    /// reason the other two are: someone who shares to WhatsApp does it every time, not once.
    ///
    /// This never changes what a publish uploads — that is always the APNG — only which file the
    /// share sheet hands over. See `StickerSharingFormat`.
    var sharingFormat: StickerSharingFormat = StickerSharingFormat(
        rawValue: UserDefaults.standard.string(forKey: preferredSharingFormatKey) ?? ""
    ) ?? .default {
        didSet {
            guard oldValue != sharingFormat else { return }
            UserDefaults.standard.set(sharingFormat.rawValue, forKey: preferredSharingFormatKey)
        }
    }

    private var seededRevisionID: String?

    static let log = Logger(subsystem: "app.rxlab.sticker-factory", category: "publish")

    /// Moves this sheet onto a revision: restores its saved MP4 background, and decides what the
    /// previous one's run leaves behind.
    ///
    /// Without the background restore the picker silently resets to the default and the user loses
    /// their choice on publish. The rest is about telling two very different arrivals apart — an
    /// edit the user made, and the publish this sheet just performed.
    func seed(from revision: StickerRevision) {
        guard seededRevisionID != revision.id else { return }
        // A publish does not edit the revision it exported — it *inserts* one, whose parent is the
        // revision that was published, and makes it active. So the sheet is re-seeded by its own
        // success, arriving here with a revision id it has never seen. Treating that as a different
        // sticker to ship is what left the timeline spinning on "Publishing to your library" with
        // nothing on screen that could ever end it, and threw away the files just rendered for it.
        let isPublishResult = revision.parentRevisionId != nil && revision.parentRevisionId == seededRevisionID
        Self.log.debug(
            """
            seed revision=\(revision.id, privacy: .public) \
            from=\(self.seededRevisionID ?? "-", privacy: .public) \
            parent=\(revision.parentRevisionId ?? "-", privacy: .public) \
            publishResult=\(isPublishResult) job=\(self.publishJobID ?? "-", privacy: .public)
            """
        )
        // A different revision is a different sticker to ship. Files rendered for the previous one
        // — and the publish job watching it — would otherwise stay on screen as this one's result,
        // handing the user a Share button for the version they just edited away.
        if seededRevisionID != nil, !isPublishResult { invalidateExports() }
        seededRevisionID = revision.id
        // The published revision landing *is* the server's word that the publish finished, and it
        // is the one signal that cannot be missed: it is what put this sheet on this revision.
        if isPublishResult { settlePublish(with: revision) }
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

    /// Ends a publish timeline from the revision the publish produced, rather than from the job.
    ///
    /// The job state is the usual route — see `StickerExportProgress.apply(publishJob:)` — but it is
    /// not a route that can be relied on alone: a publish rotates the active revision, so the sheet
    /// is rebuilt around a revision the job it was watching is no longer reachable from, and a
    /// terminal event that arrives after that has nowhere to land. A revision carrying published
    /// exports says the same thing the job would have, and says it from the state the screen is
    /// already reading.
    func settlePublish(with revision: StickerRevision) {
        guard let progress, progress.isWaitingOnServer else { return }
        guard revision.hasPublishedExports else {
            Self.log.debug("settle skipped revision=\(revision.id, privacy: .public) reason=no-published-exports")
            return
        }
        Self.log.debug("settle revision=\(revision.id, privacy: .public) job=\(self.publishJobID ?? "-", privacy: .public)")
        progress.succeed()
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

    /// Opens the timeline for the run the button just asked for.
    ///
    /// Separate from `exportOrPublish` so the sheet can put the timeline on screen in the same frame
    /// as the tap: the first step is document validation, which on a sticker whose assets are still
    /// arriving is not instant, and a button that simply stops responding is what this replaces.
    @discardableResult
    func beginProgress(for revision: StickerRevision) -> StickerExportProgress {
        let progress = StickerExportProgress.planned(for: revision, selection: selection, sharing: sharingFormat)
        self.progress = progress
        return progress
    }

    /// Runs the export as a cancellable task, with the timeline open before the first step.
    ///
    /// - Parameter onFinish: run once the work stops, however it stopped — the caller's cue to
    ///   play a haptic for an outcome only it knows how to weigh.
    func startExportOrPublish(
        store: StickerStore,
        stickerID: String,
        revision: StickerRevision,
        assets: [String: UIImage],
        verifiedAssetIDs: Set<String>,
        onFinish: @escaping @MainActor () -> Void = {}
    ) {
        exportTask?.cancel()
        beginProgress(for: revision)
        exportTask = Task { [weak self] in
            await self?.exportOrPublish(
                store: store,
                stickerID: stickerID,
                revision: revision,
                assets: assets,
                verifiedAssetIDs: verifiedAssetIDs
            )
            self?.exportTask = nil
            onFinish()
        }
    }

    /// Stops the run in flight.
    ///
    /// Only the local half can be stopped — see `StickerExportProgress.isCancellable`. Nothing is
    /// left behind: the renditions are temporary files nobody has been handed yet, and an upload
    /// that never gets registered is an orphan the server collects on its own.
    func cancelExport() {
        exportTask?.cancel()
    }

    func exportOrPublish(
        store: StickerStore,
        stickerID: String,
        revision: StickerRevision,
        assets: [String: UIImage],
        verifiedAssetIDs: Set<String>
    ) async {
        isPublishing = true
        // A run started anywhere else — a test, or a retry that skipped the sheet — opens its own
        // timeline rather than reporting into the finished one still on screen.
        let progress: StickerExportProgress
        if let existing = self.progress, existing.isRunning {
            progress = existing
        } else {
            progress = beginProgress(for: revision)
        }
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
                    selection: selection,
                    sharing: sharingFormat,
                    progress: progress
                )
                exports = result.localExports
                compromise = result.compromise
                publishJobID = result.jobID
                Self.log.debug(
                    "publish registered job=\(result.jobID, privacy: .public) revision=\(revision.id, privacy: .public)"
                )
                store.observeExternalJob(jobID: result.jobID, stickerID: stickerID)
            } else {
                exports = try await publisher.export(
                    revision: exportRevision,
                    assets: assets,
                    verifiedAssetIDs: verifiedAssetIDs,
                    selection: selection,
                    sharing: sharingFormat,
                    progress: progress
                )
            }
            publishedURLs = exports.map(\.url)
            // The sticker always exports; when the 500 KB ceiling cost it size or motion, say so
            // here rather than failing the export the way this used to. A publish reports its own
            // compromise because the sticker rendition ships whether or not it was asked to share.
            qualityNote = (compromise ?? exports.compactMap(\.compromise).first)?.message
            progress.note = qualityNote
            errorMessage = nil
            // A local export is over. A publish is not: the timeline's last step stays running
            // until the job the server handed back reports how it ended — see `apply(publishJob:)`.
            if publishJobID == nil { progress.succeed() }
        } catch {
            // A cancelled run is not a failed one, and it has nothing to say in a banner. The check
            // covers both shapes cancellation arrives in: `CancellationError` from the render
            // loops, and `URLError.cancelled` from an upload that was already in flight.
            if Task.isCancelled || error is CancellationError {
                progress.cancel()
            } else {
                errorMessage = error.localizedDescription
                progress.fail(error.localizedDescription)
            }
        }
    }
}
