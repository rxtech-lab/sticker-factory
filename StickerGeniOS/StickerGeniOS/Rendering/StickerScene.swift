import AnimatedView
import os
import SwiftUI
import UIKit

/// Plays a sticker document.
///
/// A thin wrapper over `AnimatedIconView` from the `AnimatedView` package. The app used to carry
/// its own renderer here — a second implementation of the same contract, complete with its own
/// interpolator and shape library — and the two had already begun to drift. One engine draws every
/// sticker now: the chat bubble, the full-screen player, the editor, and every exported frame.
///
/// The wrapper survives only because a dozen call sites pass `[String: UIImage]` and expect a
/// `repeats` flag, and because that dictionary is what `StickerAssetStore` already holds.
struct StickerPlayer: View {
    let document: AnimatedDocument
    var assets: [String: UIImage] = [:]
    /// Decoded clips for video layers. Empty draws each such layer's poster instead.
    var videos: [String: KeyedVideoFrames] = [:]
    var repeats = false

    var body: some View {
        AnimatedIconView(
            document: document,
            assets: AnimatedAssetDictionary(images: assets, videos: videos),
            repeats: repeats
        )
    }
}

/// Everything the exporter draws from: the bitmaps and, for video layers, the keyed clips.
///
/// The exporter used to take the image dictionary alone. Video layers are the first content that
/// is not a bitmap, and threading a second dictionary through every render call was the
/// alternative to this one value.
nonisolated struct StickerRenderAssets: Sendable {
    var images: [String: UIImage]
    var videos: [String: KeyedVideoFrames]

    init(images: [String: UIImage] = [:], videos: [String: KeyedVideoFrames] = [:]) {
        self.images = images
        self.videos = videos
    }

    @MainActor
    var dictionary: AnimatedAssetDictionary {
        AnimatedAssetDictionary(images: images, videos: videos)
    }
}

/// Loads and caches the bitmaps a document's layers reference.
///
/// Conforms to `AnimatedAssetProvider`, which is the seam the renderer uses to turn an `assetId`
/// into pixels — so the store can be handed straight to `AnimatedIconView`, the editor, or the
/// exporter without anyone copying its dictionary first.
@MainActor
@Observable
final class StickerAssetStore: AnimatedAssetProvider {
    /// Why a bitmap never arrived. Loading degrades to a placeholder by design, which is right for
    /// the renderer and leaves anyone debugging a permanently-empty slot with nothing to read.
    ///
    /// `xcrun simctl spawn booted log stream --predicate 'category == "assets"'`
    nonisolated static let log = Logger(subsystem: "app.rxlab.sticker-factory", category: "assets")

    private(set) var images: [String: UIImage] = [:]
    /// Keyed clips for video layers, by asset id. Decoded once per clip as the document loads.
    private(set) var videos: [String: KeyedVideoFrames] = [:]
    private(set) var verifiedAssetIDs: Set<String> = []
    private var loading: Set<String> = []

    /// Frames are decoded at this edge. The clip is generated at 480p and the largest rendition is
    /// 618px with the layer occupying part of it, so nothing larger would ever be drawn — and a
    /// few seconds at 24 fps is already tens of megabytes at this size.
    static let videoDecodeEdge = 384

    /// The images and clips together, for the exporter and the publisher's pre-flight.
    var renderAssets: StickerRenderAssets { .init(images: images, videos: videos) }

    // MARK: - AnimatedAssetProvider

    func image(for assetId: String) -> PlatformImage? { images[assetId] }

    func videoFrames(for assetId: String) -> KeyedVideoFrames? { videos[assetId] }

    /// SVG layers currently only ever carry inline markup, which needs no resolution. This exists
    /// so a document that later references uploaded artwork degrades to drawing nothing rather than
    /// failing to compile.
    func svgMarkup(for assetId: String) -> String? { nil }

    // MARK: - Loading

    /// Fetches every bitmap a document needs, including image-layer masks, capture atlases, and an
    /// image background.
    func preload(document: AnimatedDocument, api: StickerAPIClientProtocol) async {
        var ids = Set(document.layers.flatMap(\.referencedImageAssetIDs))
        if case .image(let assetId, _) = document.background { ids.insert(assetId) }
        for id in ids { await load(assetID: id, api: api) }
        // After the bitmaps, so a video layer's poster is on screen while its clip decodes.
        for layer in document.layers {
            if case .video(let video) = layer {
                await loadVideo(assetID: video.assetId, keyColor: video.keyColor, api: api)
            }
        }
    }

    /// Downloads a video layer's clip, checks its digest, and keys it into frames.
    ///
    /// The key colour comes from the layer rather than the asset because it is baked into the
    /// clip's pixels: the same asset is never keyed two ways, and the layer is what knows which.
    func loadVideo(assetID: String, keyColor: AnimatedVideoKeyColor, api: StickerAPIClientProtocol) async {
        guard videos[assetID] == nil, !loading.contains(assetID) else { return }
        loading.insert(assetID)
        defer { loading.remove(assetID) }
        do {
            let download = try await VerifiedAssetDownload.fetch(
                assetID: assetID,
                into: Self.videoDirectory,
                api: api
            )
            let clip = try await VideoFrameDecoder.decode(
                url: download.url,
                keyColor: keyColor,
                maxEdge: Self.videoDecodeEdge
            )
            if download.isVerified { verifiedAssetIDs.insert(assetID) }
            videos[assetID] = clip
        } catch {
            Self.log.error("video: load failed id=\(assetID, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
        }
    }

    nonisolated static var videoDirectory: URL {
        URL.cachesDirectory.appending(path: "sticker-videos", directoryHint: .isDirectory)
    }

    func load(assetID: String, api: StickerAPIClientProtocol) async {
        guard images[assetID] == nil, !loading.contains(assetID) else { return }
        loading.insert(assetID)
        defer { loading.remove(assetID) }
        do {
            let result = try await StickerImageCache.load(assetID: assetID, api: api)
            if result.isVerified { verifiedAssetIDs.insert(assetID) }
            images[assetID] = result.image
        } catch {
            // The renderer keeps its deterministic placeholder and can retry when the layer becomes
            // visible again or connectivity returns.
            Self.log.error("asset: load failed id=\(assetID, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
        }
    }
}
