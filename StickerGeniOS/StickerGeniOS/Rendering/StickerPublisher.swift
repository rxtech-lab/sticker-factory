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
        var system: RenderedStickerExport

        var all: [RenderedStickerExport] {
            [png, gif, mp4, system].compactMap { $0 }
        }
    }

    init(exporter: StickerExporter = .init(), api: StickerAPIClientProtocol) {
        self.exporter = exporter
        self.api = api
    }

    func export(
        revision: StickerRevision,
        assets: [String: UIImage],
        verifiedAssetIDs: Set<String>,
        size: SystemStickerSize = .default
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
            size: size
        ).all
    }

    func publish(
        stickerID: String,
        revision: StickerRevision,
        assets: [String: UIImage],
        verifiedAssetIDs: Set<String>,
        size: SystemStickerSize = .default
    ) async throws -> (jobID: String, localExports: [RenderedStickerExport]) {
        guard revision.canPublishExports else { throw StickerPublishError.animationRequired }
        let rendered = try await renderExports(
            revision: revision,
            assets: assets,
            verifiedAssetIDs: verifiedAssetIDs,
            size: size
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
        let systemAssetID = try await upload(rendered.system, stickerID: stickerID, kind: .system)

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
                mp4Background: document.kind == .animated ? StickerMP4BackgroundV1(document.mp4Background) : nil
            ),
            idempotencyKey: UUID().uuidString
        )
        return (response.job.id, rendered.all)
    }

    /// The files a published revision already has on the server, back on disk to be shared.
    ///
    /// A sheet opened on a revision that was published in an earlier session holds no local
    /// renders, and re-rendering them would spend an MP4 encode reproducing bytes the server is
    /// already keeping. Files land under the same temporary directory the exporter writes to,
    /// named for the asset, so sharing one revision twice in a session downloads once.
    func publishedExports(for revision: StickerRevision) async throws -> [URL] {
        var assetIDs: [String] = []
        for assetID in [revision.pngAssetId, revision.gifAssetId, revision.mp4AssetId, revision.systemAssetId] {
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

    private func renderExports(
        revision: StickerRevision,
        assets: [String: UIImage],
        verifiedAssetIDs: Set<String>,
        size: SystemStickerSize
    ) async throws -> RenderedExportSet {
        let document = try validatedDocument(
            revision: revision,
            assets: assets,
            verifiedAssetIDs: verifiedAssetIDs
        )

        let png: RenderedStickerExport?
        let gif: RenderedStickerExport?
        let mp4: RenderedStickerExport?

        if document.kind == .static {
            png = try exporter.exportStaticPNG(document: document, assets: assets)
            gif = nil
            mp4 = nil
        } else {
            png = nil
            gif = try exporter.exportGIF(document: document, assets: assets)
            mp4 = try await exporter.exportMP4(document: document, assets: assets)
        }

        let system = try exporter.exportSystemSticker(document: document, assets: assets, size: size)
        guard system.metadata.byteCount < 500_000 else {
            throw StickerExportError.systemStickerTooLarge(smallestByteCount: system.metadata.byteCount)
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
        let requiredAssetIDs = Set(document.layers.flatMap { layer -> [String] in
            guard case .image(let image) = layer else { return [] }
            return [image.assetId, image.maskAssetId].compactMap { $0 }
        })
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
    var errorDescription: String? {
        switch self {
        case .revisionNotAccepted: "Accept this revision before publishing exports."
        case .animationRequired: "Add motion before publishing this animated sticker. You can still export the current image locally."
        case .missingVerifiedAssets: "All image and mask assets must finish verified download before export. Try again when the preview is ready."
        case .publishedExportsUnavailable: "This version has no published files to share yet."
        case .exportDownloadFailed: "Couldn't fetch the published files. Check your connection and try again."
        }
    }
}
