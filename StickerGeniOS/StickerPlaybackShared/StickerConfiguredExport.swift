import AnimatedView
import UIKit

@MainActor
enum StickerConfiguredExport {
    static func render(document: AnimatedDocument, settings: StickerControlSettings, assets: StickerRenderAssets,
                       image: Bool, size: SystemStickerSize = .default) async throws -> RenderedStickerExport {
        try Task.checkCancellation()
        var output = document
        var renderAssets = assets
        if !settings.animate {
            let renderer = AnimatedIconRenderer(document: document, assets: assets.dictionary)
            guard let frame = renderer.cgImage(at: settings.stillTime(in: document), dimension: 1024) else {
                throw StickerExportError.renderFailed
            }
            let id = "ffffffff-ffff-4fff-8fff-ffffffffffff"
            output = AnimatedDocument(kind: .static, layers: [.image(.init(base: .init(id: "still", name: "Still frame", anchor: .init(scale: .init(x: 1 / Double(AnimatedIconFrame.layerFit), y: 1 / Double(AnimatedIconFrame.layerFit)))), assetId: id))])
            renderAssets = .init(images: [id: UIImage(cgImage: frame)])
        }
        let exporter = StickerExporter()
        if !image { return try await exporter.exportSystemSticker(document: output, assets: renderAssets, size: size) }
        if output.kind == .static { return try exporter.exportStaticPNG(document: output, assets: renderAssets) }
        return try await exporter.exportAPNG(document: output, assets: renderAssets)
    }
}

nonisolated struct StickerPlaybackBundle: Codable, Sendable {
    struct Asset: Codable, Sendable {
        var id: String
        var mimeType: String
        var byteSize: Int
        var sha256: String
        var width: Int
        var height: Int
    }
    var stickerId: String
    var revisionId: String
    var version: Int
    var document: AnimatedDocument
    var assets: [Asset]
}
