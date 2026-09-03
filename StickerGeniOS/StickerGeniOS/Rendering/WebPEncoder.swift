import CoreGraphics
import Foundation
import libwebp

/// Writes WebP, which on this platform is the one image format the system will read but not write.
///
/// `CGImageSourceCopyTypeIdentifiers()` has listed `org.webmproject.webp` since iOS 14, so anything
/// that decodes through ImageIO — `UIImageView`, Quick Look, `insertAttachment`'s bubble — already
/// handles the format. `CGImageDestinationCopyTypeIdentifiers()` does not list it on iOS or macOS,
/// so nothing in the SDK can produce one. That asymmetry is the whole reason this file links
/// libwebp: the sticker only has to be *made* here once, and can then be read everywhere for free.
///
/// What it is for is size. A published 618 px sharing APNG measured 9.8 MB and a 1024 px one
/// 23.5 MB; the same frames as WebP land in a small fraction of that, which is a download the person
/// tapping Send in WinkySticker is otherwise waiting on. It is never the *only* rendition — see
/// `StickerPublisher` — so an encode that fails costs nothing but the smaller file.
nonisolated enum WebPEncoder {
    /// One frame and how long it is shown.
    struct Frame {
        var image: CGImage
        /// Whole milliseconds, which is the only unit the format stores. Values below 1 are clamped:
        /// a zero-length frame is skipped entirely by most decoders.
        var delayMilliseconds: Int
    }

    enum Failure: Error, LocalizedError {
        case noFrames
        case mismatchedFrameSize
        case unreadableFrame
        /// libwebp refused to initialise — an ABI mismatch between the headers and the linked
        /// library, which is a build problem rather than anything about this sticker.
        case encoderUnavailable
        case encodeFailed

        var errorDescription: String? {
            switch self {
            case .noFrames: String(localized: "The animation had no frames to encode.")
            case .mismatchedFrameSize: String(localized: "The animation's frames are not all the same size.")
            case .unreadableFrame: String(localized: "A sticker frame could not be read for encoding.")
            case .encoderUnavailable: String(localized: "The WebP encoder is unavailable.")
            case .encodeFailed: String(localized: "The WebP export could not be encoded.")
            }
        }
    }

    /// Lossy, because a sticker is artwork rather than a screenshot and the alpha channel is where
    /// the quality that matters lives — which is why `alpha_quality` is pinned at 100 while colour
    /// is not. Lossless WebP on lifted photography runs several times larger for a difference no one
    /// sees in a transcript bubble.
    static let defaultQuality: Float = 90

    static func encodeStill(_ image: CGImage, quality: Float = defaultQuality) throws -> Data {
        guard let raster = IndexedPNGEncoder.rgbaBytes(from: image) else { throw Failure.unreadableFrame }
        var output: UnsafeMutablePointer<UInt8>?
        let written = raster.pixels.withUnsafeBufferPointer { input -> Int in
            guard let base = input.baseAddress else { return 0 }
            return WebPEncodeRGBA(
                base,
                Int32(raster.width),
                Int32(raster.height),
                Int32(raster.width * 4),
                quality,
                &output
            )
        }
        guard written > 0, let output else { throw Failure.encodeFailed }
        defer { WebPFree(output) }
        return Data(bytes: output, count: written)
    }

    /// An animation encoded a frame at a time, so a long cycle is never held in memory at once.
    ///
    /// This is the shape the export actually needs. Collecting the frames first and encoding them
    /// afterwards costs a `CGImage` per frame for the length of the pass — a 90-frame 1024²
    /// animation is around 370 MB of them, which on a device means a stall and then a jetsam kill
    /// right at the end of the render. Streaming holds one frame at a time, and libwebp keeps only
    /// the compressed result. `IndexedPNGEncoder.AnimationStream` exists for the same reason and
    /// this deliberately mirrors it.
    ///
    /// - Parameter loops: 0 repeats forever, 1 settles on the last frame. Mirrors the `playCount`
    ///   the APNG encoder writes, so the two containers of one document loop the same way.
    final class AnimationStream {
        private var encoder: OpaquePointer?
        private var config = WebPConfig()
        private let width: Int
        private let height: Int
        /// Cumulative *end* time of the frames added so far, which is what libwebp wants rather
        /// than a per-frame duration.
        private var timestamp: Int32 = 0
        /// Set by the first `append` that fails. Later frames are dropped rather than encoded into
        /// a file with a hole in it, and `finish` returns nil.
        private var isAbandoned = false

        init?(width: Int, height: Int, loops: Int, quality: Float = WebPEncoder.defaultQuality) {
            self.width = width
            self.height = height
            guard width > 0, height > 0 else { return nil }
            var options = WebPAnimEncoderOptions()
            guard WebPAnimEncoderOptionsInit(&options) != 0 else { return nil }
            options.anim_params.loop_count = Int32(loops)
            guard let created = WebPAnimEncoderNew(Int32(width), Int32(height), &options) else { return nil }
            encoder = created
            guard WebPConfigInit(&config) != 0 else { return nil }
            config.quality = quality
            // The cutout's edge is the one thing a sticker cannot afford to lose, and alpha is
            // cheap to keep: it compresses separately from colour and is mostly flat 0 or 255.
            config.alpha_quality = 100
            guard WebPValidateConfig(&config) != 0 else { return nil }
        }

        deinit {
            if let encoder { WebPAnimEncoderDelete(encoder) }
        }

        @discardableResult
        func append(frame: CGImage, delayMilliseconds: Int) -> Bool {
            guard !isAbandoned, let encoder else { return false }
            guard frame.width == width, frame.height == height,
                  let raster = IndexedPNGEncoder.rgbaBytes(from: frame) else {
                isAbandoned = true
                return false
            }
            var picture = WebPPicture()
            guard WebPPictureInit(&picture) != 0 else {
                isAbandoned = true
                return false
            }
            defer { WebPPictureFree(&picture) }
            picture.use_argb = 1
            picture.width = Int32(width)
            picture.height = Int32(height)
            let imported = raster.pixels.withUnsafeBufferPointer { input -> Int32 in
                guard let base = input.baseAddress else { return 0 }
                return WebPPictureImportRGBA(&picture, base, Int32(width * 4))
            }
            guard imported != 0, WebPAnimEncoderAdd(encoder, &picture, timestamp, &config) != 0 else {
                isAbandoned = true
                return false
            }
            timestamp += Int32(max(delayMilliseconds, 1))
            return true
        }

        /// The assembled file, or nil if any frame failed or none were added. Consumes the encoder,
        /// so it answers once.
        func finish() -> Data? {
            guard !isAbandoned, let encoder, timestamp > 0 else { return nil }
            self.encoder = nil
            defer { WebPAnimEncoderDelete(encoder) }
            // A closing frame of nothing, carrying the time the last real frame ends. Without it
            // that frame has no duration and decoders drop straight back to the first.
            guard WebPAnimEncoderAdd(encoder, nil, timestamp, nil) != 0 else { return nil }
            var assembled = WebPData()
            WebPDataInit(&assembled)
            defer { WebPDataClear(&assembled) }
            guard WebPAnimEncoderAssemble(encoder, &assembled) != 0,
                  let bytes = assembled.bytes,
                  assembled.size > 0
            else { return nil }
            return Data(bytes: bytes, count: assembled.size)
        }
    }

    /// The whole animation at once, for callers already holding every frame — which in practice
    /// means tests. The export path streams; see `AnimationStream`.
    static func encodeAnimation(
        frames: [Frame],
        loops: Int,
        quality: Float = defaultQuality
    ) throws -> Data {
        guard let first = frames.first else { throw Failure.noFrames }
        guard let stream = AnimationStream(
            width: first.image.width,
            height: first.image.height,
            loops: loops,
            quality: quality
        ) else { throw Failure.encoderUnavailable }
        for frame in frames {
            guard frame.image.width == first.image.width, frame.image.height == first.image.height else {
                throw Failure.mismatchedFrameSize
            }
            guard stream.append(frame: frame.image, delayMilliseconds: frame.delayMilliseconds) else {
                throw Failure.encodeFailed
            }
        }
        guard let data = stream.finish() else { throw Failure.encodeFailed }
        return data
    }
}
