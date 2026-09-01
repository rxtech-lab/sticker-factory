import AnimatedView
import CryptoKit
import Foundation
import UniformTypeIdentifiers
import UIKit

@MainActor
final class StickerPublisher {
    private let exporter: StickerExporter
    private let api: StickerAPIClientProtocol

    private struct RenderedExportSet {
        var png: RenderedStickerExport?
        var apng: RenderedStickerExport?
        /// Rendered only when the share sheet asked for one, and never uploaded — see
        /// `StickerSharingFormat`.
        var gif: RenderedStickerExport?
        var mp4: RenderedStickerExport?
        var system: RenderedStickerExport?

        var all: [RenderedStickerExport] {
            [png, apng, gif, mp4, system].compactMap { $0 }
        }

        /// The files the person who pressed Export actually asked for.
        ///
        /// A publish still uploads everything — the library and the Messages extension are entitled
        /// to the whole set — so this filters what reaches the share sheet, not what is rendered.
        /// The static PNG stands in for a video that does not exist rather than handing back
        /// nothing.
        ///
        /// The animated sticker goes out in one container, not both: the APNG is always published
        /// but only shared when it is the one asked for, so choosing GIF hands over a GIF rather
        /// than two files that differ in a way nothing in the share sheet explains.
        func files(for selection: StickerExportSelection, sharing: StickerSharingFormat) -> [RenderedStickerExport] {
            var files: [RenderedStickerExport] = []
            if selection.includesSticker {
                let animated = sharing == .gif ? gif ?? apng : apng
                files.append(contentsOf: [png, animated, system].compactMap { $0 })
            }
            if selection.includesVideo, let mp4 { files.append(mp4) }
            return files.isEmpty ? all : files
        }
    }

    init(exporter: StickerExporter = .init(), api: StickerAPIClientProtocol) {
        self.exporter = exporter
        self.api = api
    }

    /// - Parameter selection: nothing that is not asked for is rendered here. A local export answers
    ///   to no server contract, so choosing Video skips the sticker ladder outright and choosing
    ///   Sticker skips the MP4 encode, which is the slowest thing this class does.
    /// - Parameter progress: the timeline this run reports into, when one is on screen.
    func export(
        revision: StickerRevision,
        assets: [String: UIImage],
        verifiedAssetIDs: Set<String>,
        selection: StickerExportSelection = .default,
        sharing: StickerSharingFormat = .default,
        progress: StickerExportProgress? = nil
    ) async throws -> [RenderedStickerExport] {
        if !revision.canPublishExports {
            progress?.begin(.prepare)
            let document = try validatedDocument(
                revision: revision,
                assets: assets,
                verifiedAssetIDs: verifiedAssetIDs
            )
            progress?.begin(.renderImage)
            return [try exporter.exportStaticPNG(document: document, assets: assets)]
        }
        return try await renderExports(
            revision: revision,
            assets: assets,
            verifiedAssetIDs: verifiedAssetIDs,
            rendering: selection,
            sharing: sharing,
            progress: progress
        ).files(for: selection, sharing: sharing)
    }

    /// - Parameter selection: what comes back to be shared, and — for the MP4 alone — whether it is
    ///   rendered at all. The sticker set always is: the library and the Messages extension are
    ///   entitled to it however this export was asked for, and the server refuses a publish without
    ///   it. The video is not; it is the slowest thing this class does, nothing on the platform
    ///   reads it, and `publishedExports` can render one later for a share that wants it.
    /// - Returns: the job to watch, the files to share, and what the sticker rendition had to give
    ///   up to fit Apple's ceiling. The compromise is reported separately because it describes a
    ///   file that was published whether or not the person asked to share it.
    func publish(
        stickerID: String,
        revision: StickerRevision,
        assets: [String: UIImage],
        verifiedAssetIDs: Set<String>,
        selection: StickerExportSelection = .default,
        sharing: StickerSharingFormat = .default,
        progress: StickerExportProgress? = nil
    ) async throws -> (jobID: String, localExports: [RenderedStickerExport], compromise: SystemStickerCompromise?) {
        guard revision.canPublishExports else { throw StickerPublishError.animationRequired }
        let rendered = try await renderExports(
            revision: revision,
            assets: assets,
            verifiedAssetIDs: verifiedAssetIDs,
            rendering: selection.includesVideo ? .both : .sticker,
            sharing: sharing,
            progress: progress
        )
        let document = revision.document

        progress?.begin(.upload)
        // The last point a Cancel press can still leave the server untouched: past the register
        // call below the export exists whether or not this app is still watching it.
        try Task.checkCancellation()
        var pngAssetID: String?
        var apngAssetID: String?
        var mp4AssetID: String?
        if let png = rendered.png {
            progress?.report(String(localized: "Sending the image"), for: .upload)
            pngAssetID = try await upload(png, stickerID: stickerID, kind: .master)
        }
        if let apng = rendered.apng {
            progress?.report(String(localized: "Sending the animation"), for: .upload)
            apngAssetID = try await upload(apng, stickerID: stickerID, kind: .apng)
        }
        if let mp4 = rendered.mp4 {
            progress?.report(String(localized: "Sending the video"), for: .upload)
            mp4AssetID = try await upload(mp4, stickerID: stickerID, kind: .mp4)
        }
        guard let system = rendered.system else { throw StickerPublishError.systemRenditionUnavailable }
        progress?.report(String(localized: "Sending the sticker"), for: .upload)
        let systemAssetID = try await upload(system, stickerID: stickerID, kind: .system)

        // The rest of the publish happens on the server; `StickerExportProgress` keeps this step
        // running until the job it returns reaches a terminal state.
        progress?.begin(.publish)
        let response = try await api.registerExport(
            stickerID: stickerID,
            request: .init(
                revisionId: revision.id,
                pngAssetId: pngAssetID,
                apngAssetId: apngAssetID,
                mp4AssetId: mp4AssetID,
                systemAssetId: systemAssetID,
                // The publish request only speaks the two fills the server accepts. A document
                // carrying a radial gradient or an image here has no equivalent, so the field is
                // omitted and the server keeps whatever the revision already stored.
                mp4Background: document.kind == .animated ? StickerMP4BackgroundV1(document.mp4Background) : nil,
                // An animated sticker whose motion could not be squeezed under 500 KB ships a still.
                // Saying so is what separates the bottom of the ladder from a client that uploaded
                // the wrong file, which the server would otherwise have to treat as the same thing.
                systemRenditionKind: system.isStillFallback ? .still : nil
            ),
            idempotencyKey: UUID().uuidString
        )
        return (response.job.id, rendered.files(for: selection, sharing: sharing), system.compromise)
    }

    /// The files a published revision already has on the server, back on disk to be shared.
    ///
    /// A sheet opened on a revision that was published in an earlier session holds no local
    /// renders, and re-rendering them would spend an MP4 encode reproducing bytes the server is
    /// already keeping. Files land under the same temporary directory the exporter writes to,
    /// named for the asset, so sharing one revision twice in a session downloads once.
    ///
    /// - Parameter assets: the images the document draws, for the one file that may not exist yet.
    ///   A publish only uploads a video when the export asked for one, so someone who published a
    ///   sticker and later wants the video is not stuck with what they chose at publish time — the
    ///   document is unchanged, and the same encode that would have run then runs now.
    func publishedExports(
        for revision: StickerRevision,
        assets: [String: UIImage] = [:],
        verifiedAssetIDs: Set<String> = [],
        selection: StickerExportSelection = .default
    ) async throws -> [URL] {
        var wanted: [String?] = []
        if selection.includesSticker { wanted += [revision.pngAssetId, revision.sharingAssetId, revision.systemAssetId] }
        if selection.includesVideo { wanted.append(revision.mp4AssetId) }

        // Asked for a video the server does not hold. An animated sticker can still produce one; a
        // static sticker never could, so it hands back what it does have rather than an empty
        // share sheet.
        var rendered: [URL] = []
        if selection.includesVideo, !revision.hasPublishedVideo, revision.document.kind == .animated {
            let document = try validatedDocument(
                revision: revision,
                assets: assets,
                verifiedAssetIDs: verifiedAssetIDs
            )
            rendered.append(try await exporter.exportMP4(document: document, assets: assets).url)
        }
        if rendered.isEmpty, wanted.compactMap({ $0 }).isEmpty {
            wanted = [revision.pngAssetId, revision.sharingAssetId, revision.mp4AssetId, revision.systemAssetId]
        }

        var assetIDs: [String] = []
        for assetID in wanted {
            // A static sticker can register the same file as both its master and its system
            // sticker; sharing it twice would put two identical items in the share sheet.
            guard let assetID, !assetIDs.contains(assetID) else { continue }
            assetIDs.append(assetID)
        }
        guard !assetIDs.isEmpty || !rendered.isEmpty else { throw StickerPublishError.publishedExportsUnavailable }

        var urls: [URL] = []
        for assetID in assetIDs {
            urls.append(try await downloadExport(assetID: assetID))
        }
        return urls + rendered
    }

    private func downloadExport(assetID: String) async throws -> URL {
        let download = try await api.assetDownload(assetID: assetID)
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appending(path: "StickerFactoryExports", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileExtension = UTType(mimeType: download.asset.mimeType)?.preferredFilenameExtension ?? "dat"
        let url = directory.appending(path: assetID).appendingPathExtension(fileExtension)
        if fileManager.fileExists(atPath: url.path(percentEncoded: false)) { return url }

        let (data, response) = try await URLSession.shared.data(from: download.url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw StickerPublishError.exportDownloadFailed
        }
        // The same digest check the image cache makes: a file that does not match what the server
        // recorded is not the sticker that was published, and it is not what should be shared.
        if let expected = download.asset.sha256 {
            let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard actual.caseInsensitiveCompare(expected) == .orderedSame else {
                throw StickerPublishError.exportDownloadFailed
            }
        }
        try data.write(to: url, options: .atomic)
        return url
    }

    /// - Parameter rendering: which renditions are produced. `.both` is what a publish passes,
    ///   because the server accepts an animated sticker only with its complete set.
    private func renderExports(
        revision: StickerRevision,
        assets: [String: UIImage],
        verifiedAssetIDs: Set<String>,
        rendering: StickerExportSelection,
        sharing: StickerSharingFormat,
        progress: StickerExportProgress? = nil
    ) async throws -> RenderedExportSet {
        progress?.begin(.prepare)
        let document = try validatedDocument(
            revision: revision,
            assets: assets,
            verifiedAssetIDs: verifiedAssetIDs
        )

        var png: RenderedStickerExport?
        var apng: RenderedStickerExport?
        var gif: RenderedStickerExport?
        var mp4: RenderedStickerExport?
        var system: RenderedStickerExport?

        if document.kind == .static {
            progress?.begin(.renderImage)
            png = try exporter.exportStaticPNG(document: document, assets: assets)
        } else if rendering.includesVideo {
            progress?.begin(.renderVideo)
            mp4 = try await exporter.exportMP4(document: document, assets: assets) {
                progress?.report($0, for: .renderVideo)
            }
        }
        if document.kind == .animated, rendering.includesSticker {
            progress?.begin(.renderAPNG)
            apng = try await exporter.exportAPNG(document: document, assets: assets) {
                progress?.report($0, for: .renderAPNG)
            }
            // The APNG above is what gets published either way; this is the share sheet's copy, and
            // it is rendered only when someone asked for it because it is a second full encode of
            // the same cycle.
            if sharing == .gif {
                progress?.begin(.renderGIF)
                gif = try await exporter.exportGIF(document: document, assets: assets) {
                    progress?.report($0, for: .renderGIF)
                }
            }
        }
        if rendering.includesSticker || document.kind == .static {
            progress?.begin(.renderSticker)
            system = try await exporter.exportSystemSticker(document: document, assets: assets) {
                progress?.report($0, for: .renderSticker)
            }
        }
        return .init(png: png, apng: apng, gif: gif, mp4: mp4, system: system)
    }

    private func validatedDocument(
        revision: StickerRevision,
        assets: [String: UIImage],
        verifiedAssetIDs: Set<String>
    ) throws -> AnimatedDocument {
        guard revision.state == .accepted else { throw StickerPublishError.revisionNotAccepted }
        let document = try revision.document.validated()
        let requiredAssetIDs = Set(document.layers.flatMap(\.referencedImageAssetIDs))
        let missing = requiredAssetIDs.filter { assets[$0]?.cgImage == nil || !verifiedAssetIDs.contains($0) }
        guard missing.isEmpty else { throw StickerPublishError.missingVerifiedAssets(missing.sorted()) }
        return document
    }

    private func upload(_ export: RenderedStickerExport, stickerID: String, kind: AssetKind) async throws -> String {
        let data = try Data(contentsOf: export.url)
        let mimeType: String = switch export.metadata.format {
        case .png, .apng: "image/png"
        case .gif: "image/gif"
        case .mp4: "video/mp4"
        }
        return try await api.upload(
            data: data,
            stickerID: stickerID,
            kind: kind,
            filename: export.url.lastPathComponent,
            mimeType: mimeType,
            sequence: nil,
            idempotencyKey: UUID().uuidString
        )
    }
}

nonisolated enum StickerPublishError: Error, LocalizedError {
    case revisionNotAccepted
    case animationRequired
    case missingVerifiedAssets([String])
    case publishedExportsUnavailable
    case exportDownloadFailed
    case systemRenditionUnavailable
    /// An imported sticker came back without the revision the import said it made — so there is
    /// nothing to publish, and nothing the user can do about it but try again.
    case importedRevisionUnavailable
    /// A sticker added to the pack never finished publishing. Carries the server's reason when it
    /// gave one; nil covers the export that simply never landed, which reads the same to the user.
    case packPublishFailed(String?)
    var errorDescription: String? {
        switch self {
        case .importedRevisionUnavailable: String(localized: "Couldn't prepare the new sticker. Try again.")
        case .packPublishFailed(let message):
            message ?? String(localized: "The sticker didn't finish publishing. Open it from your library and export it again.")
        case .systemRenditionUnavailable: String(localized: "The sticker rendition could not be rendered.")
        case .revisionNotAccepted: String(localized: "Accept this revision before publishing exports.")
        case .animationRequired: String(localized: "Add motion before publishing this animated sticker. You can still export the current image locally.")
        case .missingVerifiedAssets: String(localized: "All image and mask assets must finish verified download before export. Try again when the preview is ready.")
        case .publishedExportsUnavailable: String(localized: "This version has no published files to share yet.")
        case .exportDownloadFailed: String(localized: "Couldn't fetch the published files. Check your connection and try again.")
        }
    }
}
