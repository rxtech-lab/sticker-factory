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
    var settings: StickerControlSettings?
    var playbackOrigin: Date?
    @State private var defaultOrigin = Date()

    var body: some View {
        if let settings {
            StickerConfiguredPreview(document: document, settings: settings,
                assets: .init(images: assets, videos: videos), repeats: repeats, origin: playbackOrigin ?? defaultOrigin)
        } else {
            AnimatedIconView(document: document, assets: AnimatedAssetDictionary(images: assets, videos: videos), repeats: repeats)
        }
    }
}

/// Everything the exporter draws from: the bitmaps and, for video layers, the keyed clips.
///
/// The exporter used to take the image dictionary alone. Video layers are the first content that
/// is not a bitmap, and threading a second dictionary through every render call was the
/// alternative to this one value.
/// Downloads and keys a video asset once, then shares those decoded frames between every screen
/// that opens the sticker.
///
/// `VerifiedAssetDownload` already keeps the MP4 on disk, but decoding and chroma keying it is the
/// expensive part. A `StickerAssetStore` is owned by a screen, so keeping the only copy there made
/// reopening a sticker repeat all of that CPU work. The cache is cost-bounded because decoded
/// frames are uncompressed and a short clip can occupy tens of megabytes.
actor StickerVideoFrameLoader {
    static let shared = StickerVideoFrameLoader()

    struct Result: Sendable {
        var frames: KeyedVideoFrames
        var isVerified: Bool
    }

    typealias Load = @Sendable (
        _ assetID: String,
        _ keyColor: AnimatedVideoKeyColor,
        _ maxEdge: Int,
        _ api: any StickerAPIClientProtocol
    ) async throws -> Result

    private final class CachedFrames: NSObject, @unchecked Sendable {
        let result: Result
        init(_ result: Result) { self.result = result }
    }

    private let cache: NSCache<NSString, CachedFrames>
    private let loadFrames: Load
    private var inFlight: [String: Task<Result, Error>] = [:]

    init(
        totalCostLimit: Int = 96 * 1024 * 1024,
        loadFrames: @escaping Load = StickerVideoFrameLoader.load
    ) {
        let cache = NSCache<NSString, CachedFrames>()
        cache.totalCostLimit = totalCostLimit
        self.cache = cache
        self.loadFrames = loadFrames
    }

    /// Returns a decoded clip, coalescing simultaneous requests for the same representation.
    func frames(
        assetID: String,
        keyColor: AnimatedVideoKeyColor,
        maxEdge: Int,
        api: any StickerAPIClientProtocol
    ) async throws -> Result {
        let key = "\(assetID)@\(keyColor.rawValue)@\(maxEdge)"
        if let cached = cache.object(forKey: key as NSString) { return cached.result }
        if let running = inFlight[key] { return try await running.value }

        let loadFrames = self.loadFrames
        let task = Task {
            try await loadFrames(assetID, keyColor, maxEdge, api)
        }
        inFlight[key] = task
        do {
            let result = try await task.value
            inFlight[key] = nil
            cache.setObject(
                CachedFrames(result),
                forKey: key as NSString,
                cost: result.frames.byteCost
            )
            return result
        } catch {
            inFlight[key] = nil
            throw error
        }
    }

    func removeAll() {
        inFlight.values.forEach { $0.cancel() }
        inFlight.removeAll()
        cache.removeAllObjects()
    }

    nonisolated static var directory: URL {
        URL.cachesDirectory.appending(path: "sticker-videos", directoryHint: .isDirectory)
    }

    private static func load(
        assetID: String,
        keyColor: AnimatedVideoKeyColor,
        maxEdge: Int,
        api: any StickerAPIClientProtocol
    ) async throws -> Result {
        let download = try await VerifiedAssetDownload.fetch(
            assetID: assetID,
            into: directory,
            api: api
        )
        let frames = try await VideoFrameDecoder.decode(
            url: download.url,
            keyColor: keyColor,
            maxEdge: maxEdge
        )
        return Result(frames: frames, isVerified: download.isVerified)
    }
}

private extension KeyedVideoFrames {
    /// The decoded bitmap allocation, used as `NSCache` cost rather than treating every clip as
    /// equal. `bytesPerRow` includes Core Graphics' actual row padding.
    nonisolated var byteCost: Int {
        frames.reduce(into: 0) { cost, frame in
            cost += frame.bytesPerRow * frame.height
        }
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
    private let videoFrameLoader: StickerVideoFrameLoader

    /// Frames are decoded at this edge. The clip is generated at 480p and the largest rendition is
    /// 618px with the layer occupying part of it, so nothing larger would ever be drawn — and a
    /// few seconds at 24 fps is already tens of megabytes at this size.
    static let videoDecodeEdge = 384

    init(videoFrameLoader: StickerVideoFrameLoader = .shared) {
        self.videoFrameLoader = videoFrameLoader
    }

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
        let document = (try? document.resolvingConfiguration()) ?? document
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
            let result = try await videoFrameLoader.frames(
                assetID: assetID,
                keyColor: keyColor,
                maxEdge: Self.videoDecodeEdge,
                api: api
            )
            if result.isVerified { verifiedAssetIDs.insert(assetID) }
            videos[assetID] = result.frames
        } catch {
            Self.log.error("video: load failed id=\(assetID, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
        }
    }

    nonisolated static var videoDirectory: URL {
        StickerVideoFrameLoader.directory
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
