import CoreGraphics
import Foundation

/// Slice-once storage for the tiles of a sequence layer's frame atlas.
///
/// A sequence layer's asset is one image holding a `rows` x `columns` grid of frames. `AnimatedIconView`
/// re-evaluates its body every frame under `TimelineView`, and the exporter drives the same view once
/// per exported frame, so the tile lookup happens on the hot path — hence a cache, for the same
/// reason `SVGCache` exists.
///
/// The slicing itself is nearly free: `CGImage.cropping(to:)` returns a view onto the shared backing
/// store rather than copying pixels. What this actually saves is the repeated `PlatformImage`
/// allocation and the provider round-trip, which is enough to matter at 30fps across a dozen layers.
///
/// Note the deliberate absence of a time parameter on `AnimatedAssetProvider`. Resolving *which*
/// tile is showing belongs to the renderer, not to the asset store: `AnimatedAssetDictionary` is
/// documented as the exporter's provider precisely because the exporter holds every asset before it
/// starts, and giving it a notion of time it has no use for would spread the sequence layer's
/// concerns across every provider in the app, the previews, and the tests.
@MainActor
public final class FrameAtlasCache {
    public static let shared = FrameAtlasCache()

    /// A document may hold twelve layers, and a sequence carries up to 64 tiles. This is sized to
    /// keep a few full sequences resident while a gallery scrolls past, not to hold everything.
    private let capacity: Int
    private var storage: [Key: PlatformImage] = [:]
    private var order: [Key] = []

    public init(capacity: Int = 256) {
        self.capacity = capacity
    }

    /// The grid is part of the key: the same asset re-sliced under a different layout is a different
    /// tile, and a document being edited can change `columns`/`rows` without the asset changing.
    private struct Key: Hashable {
        let assetId: String
        let columns: Int
        let rows: Int
        let index: Int
    }

    /// The tile at `index`, or `nil` when the atlas has not loaded or the index falls outside it.
    public func tile(
        for layer: AnimatedSequenceLayer,
        index: Int,
        assets: any AnimatedAssetProvider
    ) -> PlatformImage? {
        guard layer.columns > 0, layer.rows > 0, index >= 0, index < layer.columns * layer.rows else { return nil }
        let key = Key(assetId: layer.assetId, columns: layer.columns, rows: layer.rows, index: index)
        if let cached = storage[key] {
            touch(key)
            return cached
        }
        guard let sheet = assets.image(for: layer.assetId), let cropped = crop(sheet, key: key) else { return nil }
        storage[key] = cropped
        order.append(key)
        evictIfNeeded()
        return cropped
    }

    private func crop(_ sheet: PlatformImage, key: Key) -> PlatformImage? {
        guard let cgImage = sheet.animatedCGImage else { return nil }
        // Integer arithmetic on the *pixel* dimensions, so a sheet whose side is not exactly
        // divisible by the grid loses at most a sub-pixel sliver at the far edge instead of
        // accumulating a rounding drift that would shift later tiles off their frames.
        let tileWidth = cgImage.width / key.columns
        let tileHeight = cgImage.height / key.rows
        guard tileWidth > 0, tileHeight > 0 else { return nil }
        let rect = CGRect(
            x: (key.index % key.columns) * tileWidth,
            y: (key.index / key.columns) * tileHeight,
            width: tileWidth,
            height: tileHeight
        )
        guard let tile = cgImage.cropping(to: rect) else { return nil }
        return PlatformImage(animatedCGImage: tile)
    }

    private func touch(_ key: Key) {
        guard let index = order.firstIndex(of: key) else { return }
        order.remove(at: index)
        order.append(key)
    }

    private func evictIfNeeded() {
        while order.count > capacity, let oldest = order.first {
            order.removeFirst()
            storage[oldest] = nil
        }
    }

    public func removeAll() {
        storage.removeAll()
        order.removeAll()
    }
}

extension PlatformImage {
    /// The backing `CGImage`, on whichever platform this is building for.
    ///
    /// `UIImage` has one directly; `NSImage` is a list of representations and has to be asked. Kept
    /// next to the cache rather than in `PlatformImage.swift` because the atlas is the only thing in
    /// the package that needs pixel-level access to an asset.
    var animatedCGImage: CGImage? {
        #if canImport(UIKit)
        return cgImage
        #else
        var rect = CGRect(origin: .zero, size: size)
        return cgImage(forProposedRect: &rect, context: nil, hints: nil)
        #endif
    }

    convenience init?(animatedCGImage image: CGImage) {
        #if canImport(UIKit)
        self.init(cgImage: image)
        #else
        self.init(cgImage: image, size: CGSize(width: image.width, height: image.height))
        #endif
    }
}
