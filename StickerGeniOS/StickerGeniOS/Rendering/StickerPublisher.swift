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
        var gif: RenderedStickerExport?
        var mp4: RenderedStickerExport?
        var system: RenderedStickerExport?

        var all: [RenderedStickerExport] {
            [png, gif, mp4, system].compactMap { $0 }
        }

        /// The files the person who pressed Export actually asked for.
        ///
        /// A publish still uploads everything — the library and the Messages extension are entitled
        /// to the whole set — so this filters what reaches the share sheet, not what is rendered.
        /// The static PNG stands in for a video that does not exist rather than handing back
        /// nothing.
        func files(for selection: StickerExportSelection) -> [RenderedStickerExport] {
            var files: [RenderedStickerExport] = []
            if selection.includesSticker { files.append(contentsOf: [png, gif, system].compactMap { $0 }) }
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
    func export(
        revision: StickerRevision,
        assets: [String: UIImage],
        verifiedAssetIDs: Set<String>,
        size: SystemStickerSize = .default,
        selection: StickerExportSelection = .default
    ) async throws -> [RenderedStickerExport] {
        if !revision.canPublishExports {
            let document = try validatedDocument(
                revision: revision,
                assets: assets,
                verifiedAssetIDs: verifiedAssetIDs
            )
            return [try exporter.exportStaticPNG(document: document, assets: assets)]
        }
        return try await renderExports(
            revision: revision,
            assets: assets,
            verifiedAssetIDs: verifiedAssetIDs,
            size: size,
            rendering: selection
        ).files(for: selection)
    }

    /// - Parameter selection: what comes back to be shared. Publishing renders and uploads the full
    ///   set no matter what — the server rejects an animated sticker missing any of its renditions —
    ///   so this narrows the share sheet rather than the work.
    /// - Returns: the job to watch, the files to share, and what the sticker rendition had to give
    ///   up to fit Apple's ceiling. The compromise is reported separately because it describes a
    ///   file that was published whether or not the person asked to share it.
    func publish(
        stickerID: String,
        revision: StickerRevision,
        assets: [String: UIImage],
        verifiedAssetIDs: Set<String>,
        size: SystemStickerSize = .default,
        selection: StickerExportSelection = .default
    ) async throws -> (jobID: String, localExports: [RenderedStickerExport], compromise: SystemStickerCompromise?) {
        guard revision.canPublishExports else { throw StickerPublishError.animationRequired }
        let rendered = try await renderExports(
            revision: revision,
            assets: assets,
            verifiedAssetIDs: verifiedAssetIDs,
            size: size,
            rendering: .both
        )
        let document = revision.document

        var pngAssetID: String?
        var gifAssetID: String?
        var mp4AssetID: String?
        if let png = rendered.png {
            pngAssetID = try await upload(png, stickerID: stickerID, kind: .master)
        }
        if let gif = rendered.gif {
            gifAssetID = try await upload(gif, stickerID: stickerID, kind: .gif)
        }
        if let mp4 = rendered.mp4 {
            mp4AssetID = try await upload(mp4, stickerID: stickerID, kind: .mp4)
        }
        guard let system = rendered.system else { throw StickerPublishError.systemRenditionUnavailable }
        let systemAssetID = try await upload(system, stickerID: stickerID, kind: .system)

        let response = try await api.registerExport(
            stickerID: stickerID,
            request: .init(
                revisionId: revision.id,
                pngAssetId: pngAssetID,
                gifAssetId: gifAssetID,
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
        return (response.job.id, rendered.files(for: selection), system.compromise)
    }

    /// The files a published revision already has on the server, back on disk to be shared.
    ///
    /// A sheet opened on a revision that was published in an earlier session holds no local
    /// renders, and re-rendering them would spend an MP4 encode reproducing bytes the server is
    /// already keeping. Files land under the same temporary directory the exporter writes to,
    /// named for the asset, so sharing one revision twice in a session downloads once.
    func publishedExports(
        for revision: StickerRevision,
        selection: StickerExportSelection = .default
    ) async throws -> [URL] {
        var wanted: [String?] = []
        if selection.includesSticker { wanted += [revision.pngAssetId, revision.gifAssetId, revision.systemAssetId] }
        if selection.includesVideo { wanted.append(revision.mp4AssetId) }
        // A static sticker asked for as a video has none; hand back what it does have rather than an
        // empty share sheet.
        if wanted.compactMap({ $0 }).isEmpty {
            wanted = [revision.pngAssetId, revision.gifAssetId, revision.mp4AssetId, revision.systemAssetId]
        }

        var assetIDs: [String] = []
        for assetID in wanted {
            // A static sticker can register the same file as both its master and its system
            // sticker; sharing it twice would put two identical items in the share sheet.
            guard let assetID, !assetIDs.contains(assetID) else { continue }
            assetIDs.append(assetID)
        }
        guard !assetIDs.isEmpty else { throw StickerPublishError.publishedExportsUnavailable }

        var urls: [URL] = []
        for assetID in assetIDs {
            urls.append(try await downloadExport(assetID: assetID))
        }
        return urls
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
        size: SystemStickerSize,
        rendering: StickerExportSelection
    ) async throws -> RenderedExportSet {
        let document = try validatedDocument(
            revision: revision,
            assets: assets,
            verifiedAssetIDs: verifiedAssetIDs
        )

        var png: RenderedStickerExport?
        var gif: RenderedStickerExport?
        var mp4: RenderedStickerExport?
        var system: RenderedStickerExport?

        if document.kind == .static {
            png = try exporter.exportStaticPNG(document: document, assets: assets)
        } else if rendering.includesVideo {
            mp4 = try await exporter.exportMP4(document: document, assets: assets)
        }
        if document.kind == .animated, rendering.includesSticker {
            gif = try exporter.exportGIF(document: document, assets: assets)
        }
        if rendering.includesSticker || document.kind == .static {
            system = try exporter.exportSystemSticker(document: document, assets: assets, size: size)
        }
        return .init(png: png, gif: gif, mp4: mp4, system: system)
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
    var errorDescription: String? {
        switch self {
        case .systemRenditionUnavailable: String(localized: "The sticker rendition could not be rendered.")
        case .revisionNotAccepted: String(localized: "Accept this revision before publishing exports.")
        case .animationRequired: String(localized: "Add motion before publishing this animated sticker. You can still export the current image locally.")
        case .missingVerifiedAssets: String(localized: "All image and mask assets must finish verified download before export. Try again when the preview is ready.")
        case .publishedExportsUnavailable: String(localized: "This version has no published files to share yet.")
        case .exportDownloadFailed: String(localized: "Couldn't fetch the published files. Check your connection and try again.")
        }
    }
}
