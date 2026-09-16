import AnimatedView
import UIKit

@MainActor
enum StickerConfiguredExport {
    static func render(document: AnimatedDocument, settings: StickerControlSettings, assets: StickerRenderAssets,
                       image: Bool, size: SystemStickerSize = .default) async throws -> RenderedStickerExport {
        try Task.checkCancellation()
        if settings.mode == .multiple {
            let timeline = try StickerPlaybackTimeline(document: document, settings: settings)
            guard timeline.segments.allSatisfy({ assets.containsArtwork(for: $0.document) }) else { throw StickerExportError.renderFailed }
            let output = timeline.segments[0].document
            let exporter = StickerExporter(timeline: timeline)
            if image { return try await exporter.exportAPNG(document: output, assets: assets) }
            return try await systemSequence(document: document, settings: settings) { timeline in
                try await StickerExporter(timeline: timeline).exportSystemSticker(
                    document: output, assets: assets, size: size, allowsStillFallback: false)
            }
        }
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

    /// Retry only a size failure. Cancellation, corrupt assets, and encoder failures never send a different animation.
    static func systemSequence(document: AnimatedDocument, settings: StickerControlSettings,
                               render: (StickerPlaybackTimeline) async throws -> RenderedStickerExport) async throws -> RenderedStickerExport {
        let timeline = try StickerPlaybackTimeline(document: document, settings: settings)
        do { return try await render(timeline) }
        catch StickerSequenceExportError.animationDoesNotFit {
            try Task.checkCancellation()
            guard settings.entries.count > 1 else { throw StickerSequenceExportError.animationDoesNotFit }
            var first = settings
            first.entries = Array(settings.entries.prefix(1))
            var result = try await render(StickerPlaybackTimeline(document: document, settings: first))
            result.firstAnimationOnly = true
            return result
        }
    }

    static func share(document: AnimatedDocument, settings: StickerControlSettings, assets: StickerRenderAssets,
                      format: StickerExportFormat, background: StickerMP4BackgroundV1 = .solid("#FFFFFF"),
                      note: ((String) -> Void)? = nil) async throws -> RenderedStickerExport {
        let documents = try settings.playbackDocuments(document)
        guard documents.allSatisfy({ assets.containsArtwork(for: $0) }) else { throw StickerExportError.renderFailed }
        let timeline = settings.mode == .multiple ? try StickerPlaybackTimeline(document: document, settings: settings) : nil
        var output = documents[0]
        output.mp4Background = background.animatedBackground
        let exporter = StickerExporter(timeline: timeline, stillTime: settings.mode == .single && !settings.animate ? settings.stillTime(in: output) : nil)
        switch format {
        case .mp4: return try await exporter.exportMP4(document: output, assets: assets, note: note)
        case .gif: return try await exporter.exportGIF(document: output, assets: assets, note: note)
        case .webp: return try await exporter.exportWebP(document: output, assets: assets, note: note)
        default: throw StickerExportError.invalidDocument
        }
    }
}

nonisolated enum StickerSequenceExportError: Error, LocalizedError {
    case animationDoesNotFit, fileTooLarge
    var errorDescription: String? {
        switch self {
        case .animationDoesNotFit: String(localized: "The first animation cannot fit as an animated sticker. Increase its speed or use Send Image.")
        case .fileTooLarge: String(localized: "This animation is too large to export. Remove an animation or increase its speed and try again.")
        }
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
