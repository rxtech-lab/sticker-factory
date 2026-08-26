import AnimatedView
import Foundation
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
        verifiedAssetIDs: Set<String>
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
            verifiedAssetIDs: verifiedAssetIDs
        ).all
    }

    func publish(
        stickerID: String,
        revision: StickerRevision,
        assets: [String: UIImage],
        verifiedAssetIDs: Set<String>
    ) async throws -> (jobID: String, localExports: [RenderedStickerExport]) {
        guard revision.canPublishExports else { throw StickerPublishError.animationRequired }
        let rendered = try await renderExports(
            revision: revision,
            assets: assets,
            verifiedAssetIDs: verifiedAssetIDs
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

    private func renderExports(
        revision: StickerRevision,
        assets: [String: UIImage],
        verifiedAssetIDs: Set<String>
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

        let system = try exporter.exportSystemSticker(document: document, assets: assets)
        guard system.metadata.byteCount < 500_000 else { throw StickerExportError.systemStickerTooLarge }
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
    var errorDescription: String? {
        switch self {
        case .revisionNotAccepted: "Accept this revision before publishing exports."
        case .animationRequired: "Add motion before publishing this animated sticker. You can still export the current image locally."
        case .missingVerifiedAssets: "All image and mask assets must finish verified download before export. Try again when the preview is ready."
        }
    }
}
