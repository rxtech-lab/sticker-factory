import CryptoKit
import ImageIO
import UIKit

/// How large an animated sticker's frames are decoded, per surface.
///
/// This is the only knob that decides whether a screenful of moving stickers fits in memory. Frames
/// are held as uncompressed bitmaps, so a 618 px frame — the size the Messages rendition is written
/// at — costs 1.5 MB, and a two-second animation of them costs ninety. The source file is under
/// 500 KB precisely because APNG only stores what changed between frames; playback cannot borrow
/// that, so it borrows resolution instead.
nonisolated enum StickerAnimationDetail: Sendable {
    /// Grid tiles: eight or more on screen at once, each a couple of hundred points wide.
    case thumbnail
    /// One sticker filling a sheet.
    case preview

    /// Longest edge, in pixels, a frame is decoded at.
    var maxPixelSize: Int {
        switch self {
        case .thumbnail: 192
        case .preview: 384
        }
    }
}

/// An animated sticker's frames, decoded and ready to play.
nonisolated struct StickerAnimation: Sendable {
    /// Asset plus decode size — the key this was cached under, and what tells one animation from
    /// another when the player is handed a new one.
    let id: String
    let frames: [UIImage]
    /// Seconds to hold each frame. Same count as `frames`.
    let delays: [Double]
    /// Roughly what `frames` occupy, for the cache's cost accounting.
    let byteCost: Int

    var duration: Double { delays.reduce(0, +) }
}

/// The artwork behind one asset: the still every surface can draw, and the motion if it has any.
nonisolated struct StickerArtwork: Sendable {
    let still: UIImage
    /// `nil` for a single-frame asset — including an animated sticker whose Messages rendition had
    /// to give up its motion to fit Apple's 500 KB ceiling. See `SystemStickerCompromise`.
    let animation: StickerAnimation?
}

nonisolated enum StickerArtworkError: Error {
    case download(Int)
    case checksumMismatch
    case undecodable
}

/// Turns GIF/APNG/WebP bytes into frames.
///
/// APNG is what a publish uploads, so this cannot lean on Kingfisher: its animation support is GIF
/// only, and for APNG data it hands back frame zero — blank for any sticker that fades or slides in,
/// which is why every still surface goes through `StickerPosterFrame` instead. WebP is here because
/// a messenger export previews the file it is about to hand over, and WhatsApp's is an animated
/// WebP.
nonisolated enum StickerAnimationDecoder {
    /// What one animation's frames may occupy. Longer animations are not refused, they are played
    /// at a lower frame rate: `stride` below drops frames until the rest fit.
    static let byteBudget = 24 * 1024 * 1024

    /// A frame held for no time at all would spin the player's catch-up loop forever, and containers
    /// do write zero delays — both GIF and APNG treat it as "as fast as possible".
    static let minimumDelay = 0.01

    /// Returns `nil` for single-frame data, which is not an error: the caller draws the still.
    ///
    /// - Parameter byteBudget: what the frames may occupy. A parameter only so a test can watch the
    ///   subsampling without decoding the hundreds of megabytes it takes to reach 24 MB.
    static func decode(
        _ data: Data,
        id: String,
        maxPixelSize: Int,
        byteBudget: Int = byteBudget
    ) -> StickerAnimation? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let count = CGImageSourceGetCount(source)
        guard count > 1 else { return nil }

        let delays = (0 ..< count).map { delay(source: source, index: $0) }

        // The first frame sizes the rest: every frame of an animated container has the canvas'
        // dimensions once ImageIO has composited it, so one decode answers what a frame costs.
        guard let first = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let size = scaledSize(width: first.width, height: first.height, maxPixelSize: maxPixelSize)
        let frameCost = size.width * size.height * 4
        let affordable = max(1, byteBudget / max(1, frameCost))
        let stride = max(1, Int((Double(count) / Double(affordable)).rounded(.up)))

        var frames: [UIImage] = []
        var keptDelays: [Double] = []
        var index = 0
        while index < count {
            let next = min(index + stride, count)
            defer { index = next }
            let frame = index == 0 ? first : CGImageSourceCreateImageAtIndex(source, index, nil)
            guard let frame, let scaled = downscale(frame, to: size) else { continue }
            frames.append(UIImage(cgImage: scaled))
            // A dropped frame's time is spent on the frame that replaced it, so a subsampled
            // animation still runs at the length it was authored at.
            keptDelays.append(max(minimumDelay, delays[index ..< next].reduce(0, +)))
        }
        guard frames.count > 1 else { return nil }
        return StickerAnimation(
            id: id,
            frames: frames,
            delays: keptDelays,
            byteCost: frames.count * frameCost
        )
    }

    /// The delay this container states for one frame, in seconds.
    ///
    /// GIF, APNG and WebP each keep it in their own property dictionary, and only the one matching
    /// the container is present — so a format with no branch here falls through to `minimumDelay`
    /// and plays at 100 FPS rather than at its own speed. The unclamped value is preferred where
    /// both exist: the clamped one is floored at 0.1 s for the benefit of 1990s browsers, and
    /// applying that floor to a 30 FPS sticker plays it at a third of its speed.
    private static func delay(source: CGImageSource, index: Int) -> Double {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil)
            as? [CFString: Any] else { return minimumDelay }

        if let gif = properties[kCGImagePropertyGIFDictionary] as? [CFString: Any] {
            let unclamped = gif[kCGImagePropertyGIFUnclampedDelayTime] as? Double
            let clamped = gif[kCGImagePropertyGIFDelayTime] as? Double
            if let delay = [unclamped, clamped].compactMap({ $0 }).first(where: { $0 > 0 }) {
                return delay
            }
        }
        if let png = properties[kCGImagePropertyPNGDictionary] as? [CFString: Any] {
            let unclamped = png[kCGImagePropertyAPNGUnclampedDelayTime] as? Double
            let clamped = png[kCGImagePropertyAPNGDelayTime] as? Double
            if let delay = [unclamped, clamped].compactMap({ $0 }).first(where: { $0 > 0 }) {
                return delay
            }
        }
        if let webp = properties[kCGImagePropertyWebPDictionary] as? [CFString: Any] {
            let unclamped = webp[kCGImagePropertyWebPUnclampedDelayTime] as? Double
            let clamped = webp[kCGImagePropertyWebPDelayTime] as? Double
            if let delay = [unclamped, clamped].compactMap({ $0 }).first(where: { $0 > 0 }) {
                return delay
            }
        }
        return minimumDelay
    }

    private static func scaledSize(
        width: Int,
        height: Int,
        maxPixelSize: Int
    ) -> (width: Int, height: Int) {
        let longest = max(width, height)
        guard longest > maxPixelSize, longest > 0 else { return (max(1, width), max(1, height)) }
        let scale = Double(maxPixelSize) / Double(longest)
        return (
            max(1, Int((Double(width) * scale).rounded())),
            max(1, Int((Double(height) * scale).rounded()))
        )
    }

    /// Redraws a composited frame at the playback size, keeping its alpha.
    private static func downscale(_ image: CGImage, to size: (width: Int, height: Int)) -> CGImage? {
        guard image.width != size.width || image.height != size.height else { return image }
        guard let context = CGContext(
            data: nil,
            width: size.width,
            height: size.height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return image }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: size.width, height: size.height))
        return context.makeImage()
    }
}

/// The decoded animation, boxed for `NSCache`.
nonisolated private final class CachedStickerArtwork: NSObject, @unchecked Sendable {
    let artwork: StickerArtwork
    init(_ artwork: StickerArtwork) { self.artwork = artwork }
}

/// Downloads an animated asset's bytes once, decodes them once, and hands the result to every tile
/// that asks for it.
///
/// Separate from `StickerImageCache` because the two need different things from the same file.
/// Kingfisher's pipeline is built to hand back a `UIImage`, and the frames of an APNG do not survive
/// that trip; this keeps the container bytes, which is the only form the frames exist in.
actor StickerArtworkLoader {
    static let shared = StickerArtworkLoader()

    /// Bounded by cost so a long scroll through a library of animated stickers evicts rather than
    /// growing without limit. A player holds its own animation strongly, so eviction never pulls
    /// frames out from under something on screen.
    private let cache: NSCache<NSString, CachedStickerArtwork> = {
        let cache = NSCache<NSString, CachedStickerArtwork>()
        cache.totalCostLimit = 64 * 1024 * 1024
        return cache
    }()

    /// One download and decode per key, however many tiles ask for it at once.
    private var inFlight: [String: Task<StickerArtwork?, Never>] = [:]

    func artwork(
        assetID: String,
        expectedSHA256: String?,
        detail: StickerAnimationDetail,
        api: StickerAPIClientProtocol
    ) async -> StickerArtwork? {
        let key = "\(assetID)@\(detail.maxPixelSize)"
        if let hit = cache.object(forKey: key as NSString) { return hit.artwork }
        if let running = inFlight[key] { return await running.value }

        // Detached: decoding a couple of hundred frames is synchronous CPU work, and running it on
        // the actor would stall every other tile's cache lookup behind it.
        let task = Task.detached(priority: .userInitiated) { () -> StickerArtwork? in
            guard let data = try? await StickerAssetData.load(
                assetID: assetID,
                expectedSHA256: expectedSHA256,
                api: api
            ) else { return nil }
            let animation = StickerAnimationDecoder.decode(
                data,
                id: key,
                maxPixelSize: detail.maxPixelSize
            )
            // The still is decoded at full size rather than lifted from the playback frames: it is
            // what a static asset and a motionless rendition draw, and those should not be soft.
            guard let still = StickerPosterFrame.image(from: data) ?? UIImage(data: data) else {
                return nil
            }
            return StickerArtwork(still: still, animation: animation)
        }
        inFlight[key] = task
        let result = await task.value
        inFlight[key] = nil

        if let result {
            cache.setObject(
                CachedStickerArtwork(result),
                forKey: key as NSString,
                cost: result.animation?.byteCost ?? 0
            )
        }
        return result
    }
}

/// The container bytes behind one asset, kept on disk between launches.
///
/// Kingfisher's disk cache holds re-encoded `UIImage`s and cannot serve this: an APNG that goes
/// through it comes back as a single frame. The file is written under the asset's own id, and every
/// read re-checks the digest, so a truncated download or a tampered file is discarded rather than
/// played.
nonisolated enum StickerAssetData {
    static var directory: URL {
        URL.cachesDirectory.appending(path: "sticker-asset-data", directoryHint: .isDirectory)
    }

    static func load(
        assetID: String,
        expectedSHA256: String?,
        api: StickerAPIClientProtocol
    ) async throws -> Data {
        if let cached = cached(assetID: assetID, expectedSHA256: expectedSHA256) { return cached }

        let download = try await api.assetDownload(assetID: assetID)
        let (data, response) = try await URLSession.shared.data(from: download.url)
        if let http = response as? HTTPURLResponse, !(200 ..< 300).contains(http.statusCode) {
            throw StickerArtworkError.download(http.statusCode)
        }
        let expected = expectedSHA256 ?? download.asset.sha256
        if let expected, !matches(data, expected) { throw StickerArtworkError.checksumMismatch }

        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: fileURL(assetID: assetID), options: .atomic)
        return data
    }

    /// Removes every cached asset. Called when the signed-in account changes: these files are the
    /// previous account's private artwork.
    static func purge(fileManager: FileManager = .default) {
        try? fileManager.removeItem(at: directory)
    }

    private static func cached(assetID: String, expectedSHA256: String?) -> Data? {
        guard let data = try? Data(contentsOf: fileURL(assetID: assetID)) else { return nil }
        guard let expectedSHA256 else { return data }
        return matches(data, expectedSHA256) ? data : nil
    }

    /// Named by the digest of the id rather than the id itself: asset ids come from the server, and
    /// a path separator in one would write outside the cache directory.
    private static func fileURL(assetID: String) -> URL {
        let name = SHA256.hash(data: Data(assetID.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return directory.appending(path: name, directoryHint: .notDirectory)
    }

    private static func matches(_ data: Data, _ expectedSHA256: String) -> Bool {
        let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return actual.caseInsensitiveCompare(expectedSHA256) == .orderedSame
    }
}
