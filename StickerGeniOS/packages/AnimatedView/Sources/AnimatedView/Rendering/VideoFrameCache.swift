import Foundation

/// Wrap-once storage for the frames of a video layer's clip.
///
/// The frames themselves live in `KeyedVideoFrames`, held by the asset provider. What this saves is
/// the `PlatformImage` allocation per frame on the render hot path, for the same reason
/// `FrameAtlasCache` exists: `AnimatedIconView` re-evaluates its body every tick, and the exporter
/// drives it once per exported frame.
@MainActor
public final class VideoFrameCache {
    public static let shared = VideoFrameCache()

    /// A clip is at most a few seconds at 24 fps, so this keeps a couple of clips fully resident.
    private let capacity: Int
    private var storage: [Key: PlatformImage] = [:]
    private var order: [Key] = []

    public init(capacity: Int = 256) {
        self.capacity = capacity
    }

    private struct Key: Hashable {
        let assetId: String
        let index: Int
    }

    /// The frame at `index`, or `nil` when the clip has not decoded yet.
    public func frame(
        for layer: AnimatedVideoLayer,
        index: Int,
        assets: any AnimatedAssetProvider
    ) -> PlatformImage? {
        guard let clip = assets.videoFrames(for: layer.assetId), let cgImage = clip.frame(at: index) else { return nil }
        // Keyed by the clamped index rather than the requested one, so the tail of a clip that
        // decoded short does not fill the cache with copies of its last frame.
        let key = Key(assetId: layer.assetId, index: min(max(index, 0), clip.frameCount - 1))
        if let cached = storage[key] {
            touch(key)
            return cached
        }
        guard let wrapped = PlatformImage(animatedCGImage: cgImage) else { return nil }
        storage[key] = wrapped
        order.append(key)
        evictIfNeeded()
        return wrapped
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
