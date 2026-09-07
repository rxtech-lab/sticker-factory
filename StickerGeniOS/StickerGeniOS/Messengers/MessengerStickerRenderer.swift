import CoreGraphics
import Foundation
import ImageIO
import UIKit
import UniformTypeIdentifiers
import VP9Encoder

nonisolated enum MessengerStickerFormat: String, Sendable {
    case webp
    case png
    case webm

    var mimeType: String {
        switch self {
        case .webp: "image/webp"
        case .png: "image/png"
        case .webm: "video/webm"
        }
    }

    init?(mimeType: String) {
        switch mimeType {
        case "image/webp": self = .webp
        case "image/png": self = .png
        case "video/webm": self = .webm
        default: return nil
        }
    }
}

/// One sticker, encoded for a messenger and ready to hand over.
///
/// Produced by `MessengerRenditionPreparer` when a sticker is added to a pack, uploaded, and from
/// then on downloaded rather than made again — see `MessengerPreparedSticker`, which is what the
/// export sheet holds.
nonisolated struct MessengerRenderedSticker: Sendable, Equatable {
    var stickerID: String
    var kind: StickerKind
    var format: MessengerStickerFormat
    var data: Data
    var frameCount: Int
    var durationMilliseconds: Int
    /// How much faster than the original it plays. 1 for a still or an animation that fit as is.
    var speedFactor: Double
    /// A small PNG of the settled pose, for the export screen's preview.
    var posterPNG: Data

    var byteCount: Int { data.count }
    var isAnimated: Bool { frameCount > 1 }
    var isAccelerated: Bool { speedFactor > 1.001 }
}

/// One sticker's messenger rendition, fetched from the server and ready to hand over.
///
/// What the export sheet works with now that it no longer encodes. The timing is read off the
/// server's asset record rather than recomputed, which is a quiet payoff of inspecting the file
/// when it was uploaded: the sheet can say "1.2 s · 240 KB" without decoding a frame.
///
/// `speedFactor` has no equivalent here and is deliberately gone. It was a fact about the encode,
/// and the encode now happened on a different day — possibly on someone else's phone.
nonisolated struct MessengerPreparedSticker: Sendable, Equatable {
    var stickerID: String
    var kind: StickerKind
    var format: MessengerStickerFormat
    var data: Data
    /// Nil for a WebM, which never reports one: counting a Matroska's frames means walking every
    /// cluster block, and nothing needs the number.
    var frameCount: Int?
    var durationMilliseconds: Int?

    var byteCount: Int { data.count }
    var isAnimated: Bool { kind == .animated }

    /// The rendition as the server described it, matched to the container it arrived in.
    init?(stickerID: String, kind: StickerKind, asset: AssetRecord, data: Data) {
        guard let format = MessengerStickerFormat(mimeType: asset.mimeType) else { return nil }
        self.stickerID = stickerID
        self.kind = kind
        self.format = format
        self.data = data
        self.frameCount = asset.frameCount
        self.durationMilliseconds = asset.durationSeconds.map { Int(($0 * 1_000).rounded()) }
    }
}

nonisolated enum MessengerRenderError: Error, LocalizedError, Equatable {
    case noArtwork
    case undecodable
    case renderFailed
    /// The smallest encoding still overshot the messenger's limit; carries the best size reached.
    case tooLarge(bytes: Int, limit: Int)

    var errorDescription: String? {
        switch self {
        case .noArtwork: String(localized: "This sticker has no published artwork to send.")
        case .undecodable: String(localized: "This sticker's artwork could not be read.")
        case .renderFailed: String(localized: "This sticker could not be drawn at the messenger's size.")
        case .tooLarge(let bytes, let limit):
            String(localized: "Even the smallest encoding is \(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)), over the \(ByteCountFormatter.string(fromByteCount: Int64(limit), countStyle: .file)) limit.")
        }
    }
}

/// Where a sticker's pixels come from and how they are decoded, one frame at a time.
///
/// The preview asset — the 1024 px master PNG, or the sharing APNG at the document's own frame
/// rate — is the richest artwork the server holds for any published sticker, own or borrowed, and
/// the messenger's 512 px square is drawn from it. Frames are decoded on demand: a 90-frame 1024²
/// APNG is 360 MB decoded, which is not something to hold while an encoder runs.
nonisolated struct MessengerFrameSource {
    let source: CGImageSource
    let frameCount: Int
    let delaysMilliseconds: [Int]

    init(data: Data) throws {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0
        else { throw MessengerRenderError.undecodable }
        self.source = source
        frameCount = CGImageSourceGetCount(source)
        delaysMilliseconds = (0..<frameCount).map { index in
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
            let png = properties?[kCGImagePropertyPNGDictionary] as? [CFString: Any]
            let gif = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            let webp = properties?[kCGImagePropertyWebPDictionary] as? [CFString: Any]
            let seconds = [
                png?[kCGImagePropertyAPNGUnclampedDelayTime], png?[kCGImagePropertyAPNGDelayTime],
                gif?[kCGImagePropertyGIFUnclampedDelayTime], gif?[kCGImagePropertyGIFDelayTime],
                webp?[kCGImagePropertyWebPUnclampedDelayTime], webp?[kCGImagePropertyWebPDelayTime],
            ].compactMap { $0 as? Double }.first { $0 > 0 } ?? 0.1
            return max(1, Int((seconds * 1_000).rounded()))
        }
    }

    func frame(at index: Int) -> CGImage? {
        CGImageSourceCreateImageAtIndex(source, min(max(0, index), frameCount - 1), nil)
    }

    /// The artwork asset to export from, richest first. Nil for a sticker with nothing published.
    static func asset(for sticker: Sticker) -> (id: String, sha256: String?)? {
        if let preview = sticker.previewAsset { return (preview.id, preview.sha256) }
        if let system = sticker.systemSticker { return (system.assetId, system.sha256) }
        return nil
    }
}

/// Encodes one sticker for one messenger.
///
/// Every output is a transparent 512 × 512 square. Sizes are met by walking a ladder — quality
/// first, then frame rate — and never by shrinking the canvas, which both messengers require at
/// exactly 512. Animations longer than the messenger allows are sped up, never cut.
nonisolated enum MessengerStickerRenderer {
    /// The rendered frames an encode pass reads, cached only while they are cheap to keep.
    ///
    /// A 512² RGBA frame is a megabyte, so a short cycle is decoded once and shared by every rung
    /// of the ladder; a long one is decoded again per rung rather than held in memory.
    static let cacheableFrameCount = 96

    static func render(
        sticker: Sticker,
        artwork: Data,
        destination: MessengerDestination,
        progress: (@Sendable (String) -> Void)? = nil
    ) throws -> MessengerRenderedSticker {
        let limits = destination.limits
        let source = try MessengerFrameSource(data: artwork)
        try Task.checkCancellation()

        let animated = sticker.kind == .animated
        if !animated {
            return try renderStill(sticker: sticker, source: source, destination: destination)
        }

        // An animated sticker whose published rendition is a single frame — the Messages ladder
        // fell back to a still — is still an *animated* sticker to the messenger, which refuses a
        // still inside an animated pack. Two frames keep the pack consistent. They cannot be
        // identical: libwebp folds a repeated frame into the one before it, which would hand back
        // the very still this avoids — so the second differs by one transparent corner pixel.
        let isStillFallback = source.frameCount == 1
        let delays = isStillFallback ? [500, 500] : source.delaysMilliseconds
        var framesPerSecond = limits.maximumFramesPerSecond
        var lastFailure: MessengerRenderError = .renderFailed
        var frameCache: [Int: CGImage] = [:]

        for rung in 0..<3 {
            let schedule = MessengerAnimationSchedule.plan(
                sourceDelaysMilliseconds: delays,
                maximumDurationMilliseconds: limits.maximumDurationMilliseconds,
                maximumFramesPerSecond: framesPerSecond,
                minimumFrameDurationMilliseconds: limits.minimumFrameDurationMilliseconds
            )
            guard !schedule.frames.isEmpty else { throw MessengerRenderError.renderFailed }
            // Every rung samples a subset of the same source frames, so the cache built for the
            // first stays valid for the ones after it.
            let canCache = schedule.frames.count <= cacheableFrameCount
            let frame: (Int) throws -> CGImage = { index in
                if let cached = frameCache[index] { return cached }
                guard let decoded = source.frame(at: isStillFallback ? 0 : index),
                      var square = Self.square(decoded, side: limits.dimension)
                else { throw MessengerRenderError.renderFailed }
                if isStillFallback, index == 1, let nudged = Self.nudged(square) { square = nudged }
                if canCache { frameCache[index] = square }
                return square
            }

            let attempt: (data: Data, format: MessengerStickerFormat)?
            switch destination {
            case .whatsapp:
                attempt = try encodeAnimatedWebP(schedule: schedule, frame: frame, limit: limits.animatedByteLimit, side: limits.dimension, rung: rung, progress: progress)
            case .telegram:
                attempt = try encodeWebM(schedule: schedule, frame: frame, limit: limits.animatedByteLimit, side: limits.dimension, rung: rung, progress: progress)
            }
            if let attempt {
                let poster = try posterPNG(schedule: schedule, frame: frame)
                return .init(
                    stickerID: sticker.id,
                    kind: .animated,
                    format: attempt.format,
                    data: attempt.data,
                    frameCount: schedule.frames.count,
                    durationMilliseconds: schedule.durationMilliseconds,
                    speedFactor: schedule.speedFactor,
                    posterPNG: poster
                )
            }
            lastFailure = .tooLarge(bytes: lastAttemptBytes, limit: limits.animatedByteLimit)
            // Half the frame rate for the next rung: fewer frames is the one lever left once
            // quality has run out, and it keeps every frame at the full 512 px.
            framesPerSecond = max(4, framesPerSecond / 2)
        }
        throw lastFailure
    }

    /// The last overshooting size, for the error that says how far off it was. Not thread-safe by
    /// design: renders run one sticker at a time.
    nonisolated(unsafe) private static var lastAttemptBytes = 0

    // MARK: - Stills

    private static func renderStill(
        sticker: Sticker,
        source: MessengerFrameSource,
        destination: MessengerDestination
    ) throws -> MessengerRenderedSticker {
        let limits = destination.limits
        // For a still with several frames — a static sticker never has them, but the source is
        // not trusted to know that — the settled pose is the one to keep.
        let index = source.frameCount > 1 ? posterIndex(source: source) : 0
        guard let decoded = source.frame(at: index), let square = square(decoded, side: limits.dimension) else {
            throw MessengerRenderError.renderFailed
        }
        try Task.checkCancellation()
        let poster = try posterPNG(square)
        let limit = limits.staticByteLimit
        switch destination {
        case .whatsapp:
            var best = 0
            let ladder: [(color: Float, alpha: Int)] = [(92, 100), (85, 90), (78, 80), (70, 70), (60, 60), (50, 50), (40, 40), (30, 30), (20, 20)]
            for quality in ladder {
                try Task.checkCancellation()
                let data = try WebPEncoder.encodeStill(square, quality: quality.color, alphaQuality: quality.alpha)
                best = data.count
                if data.count <= limit {
                    return .init(stickerID: sticker.id, kind: .static, format: .webp, data: data, frameCount: 1, durationMilliseconds: 0, speedFactor: 1, posterPNG: poster)
                }
            }
            throw MessengerRenderError.tooLarge(bytes: best, limit: limit)
        case .telegram:
            guard let full = UIImage(cgImage: square).pngData() else { throw MessengerRenderError.renderFailed }
            if full.count <= limit {
                return .init(stickerID: sticker.id, kind: .static, format: .png, data: full, frameCount: 1, durationMilliseconds: 0, speedFactor: 1, posterPNG: poster)
            }
            // A 512² PNG over 512 KB is dense photography; a palette brings it under without
            // touching the dimensions Telegram checks.
            var census = IndexedPNGEncoder.ColorCensus(lattice: .init(colorLevels: 32, alphaLevels: 8))
            census.add(square)
            var best = full.count
            for count in [256, 64, 16] {
                try Task.checkCancellation()
                guard let data = IndexedPNGEncoder.encodeStill(square, palette: census.palette(limit: count, dithered: true), dimension: limits.dimension) else { continue }
                best = min(best, data.count)
                if data.count <= limit {
                    return .init(stickerID: sticker.id, kind: .static, format: .png, data: data, frameCount: 1, durationMilliseconds: 0, speedFactor: 1, posterPNG: poster)
                }
            }
            throw MessengerRenderError.tooLarge(bytes: best, limit: limit)
        }
    }

    // MARK: - Animated WebP (WhatsApp)

    private static func encodeAnimatedWebP(
        schedule: MessengerAnimationSchedule,
        frame: (Int) throws -> CGImage,
        limit: Int,
        side: Int,
        rung: Int,
        progress: (@Sendable (String) -> Void)?
    ) throws -> (data: Data, format: MessengerStickerFormat)? {
        // Quality is spent before frame rate. The first rung tries the whole ladder; later rungs,
        // at half the frames, only the lower half of it — the top already failed with more frames
        // and would only be slower a second time. Alpha quality walks down with it: a soft-edged
        // alpha plane compressed losslessly is routinely the largest part of the file.
        let qualities: [(color: Float, alpha: Int)] = rung == 0
            ? [(80, 90), (65, 75), (50, 60), (35, 45)]
            : [(50, 60), (35, 45), (20, 30)]
        for quality in qualities {
            try Task.checkCancellation()
            guard let stream = WebPEncoder.AnimationStream(width: side, height: side, loops: 0, quality: quality.color, alphaQuality: quality.alpha) else {
                throw MessengerRenderError.renderFailed
            }
            for (index, entry) in schedule.frames.enumerated() {
                try Task.checkCancellation()
                progress?(String(localized: "Encoding frame \(index + 1) of \(schedule.frames.count)"))
                guard stream.append(frame: try frame(entry.sourceIndex), delayMilliseconds: entry.durationMilliseconds) else {
                    throw MessengerRenderError.renderFailed
                }
            }
            guard let data = stream.finish() else { throw MessengerRenderError.renderFailed }
            lastAttemptBytes = data.count
            if data.count <= limit { return (data, .webp) }
        }
        return nil
    }

    // MARK: - VP9 WebM (Telegram)

    private static func encodeWebM(
        schedule: MessengerAnimationSchedule,
        frame: (Int) throws -> CGImage,
        limit: Int,
        side: Int,
        rung: Int,
        progress: (@Sendable (String) -> Void)?
    ) throws -> (data: Data, format: MessengerStickerFormat)? {
        // Rate control is a target, not a ceiling: each pass aims under the limit by a margin and
        // the next pass aims lower still when the file lands over it.
        let headrooms: [Double] = rung == 0 ? [0.85, 0.6, 0.4, 0.25] : [0.4, 0.25, 0.15]
        for headroom in headrooms {
            try Task.checkCancellation()
            let encoder = try VP9WebMEncoder(
                width: side, height: side,
                settings: .fitting(byteBudget: limit, durationMilliseconds: schedule.durationMilliseconds, headroom: headroom)
            )
            for (index, entry) in schedule.frames.enumerated() {
                try Task.checkCancellation()
                progress?(String(localized: "Encoding frame \(index + 1) of \(schedule.frames.count)"))
                guard let raster = IndexedPNGEncoder.rgbaBytes(from: try frame(entry.sourceIndex)) else {
                    throw MessengerRenderError.renderFailed
                }
                try encoder.append(
                    RGBAFrame(width: raster.width, height: raster.height, bytesPerRow: raster.width * 4, pixels: raster.pixels, isPremultiplied: false),
                    durationMilliseconds: entry.durationMilliseconds
                )
            }
            let data = try encoder.finish()
            lastAttemptBytes = data.count
            if data.count <= limit { return (data, .webm) }
        }
        return nil
    }

    // MARK: - Drawing

    /// The artwork fitted into a transparent square, centred, never stretched.
    static func square(_ image: CGImage, side: Int) -> CGImage? {
        guard image.width > 0, image.height > 0,
              let context = CGContext(
                  data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }
        context.clear(CGRect(x: 0, y: 0, width: side, height: side))
        context.interpolationQuality = .high
        let scale = min(Double(side) / Double(image.width), Double(side) / Double(image.height))
        let width = Double(image.width) * scale
        let height = Double(image.height) * scale
        context.draw(image, in: CGRect(x: (Double(side) - width) / 2, y: (Double(side) - height) / 2, width: width, height: height))
        return context.makeImage()
    }

    /// The same image with one corner pixel made faintly translucent — invisible, but not equal.
    static func nudged(_ image: CGImage) -> CGImage? {
        guard var raster = IndexedPNGEncoder.rgbaBytes(from: image) else { return nil }
        raster.pixels[3] = raster.pixels[3] == 0 ? 1 : raster.pixels[3] - 1
        let pixels = raster.pixels
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(
            width: raster.width, height: raster.height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: raster.width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )
    }

    /// The frame with the most opaque coverage among a handful sampled across the cycle — the
    /// settled pose rather than a fade-in's empty first frame.
    static func posterIndex(source: MessengerFrameSource) -> Int {
        let samples = min(source.frameCount, 12)
        var best = 0
        var bestCoverage = -1
        for sample in 0..<samples {
            let index = source.frameCount * sample / samples
            guard let frame = source.frame(at: index) else { continue }
            let coverage = StickerPosterFrame.opaqueCoverage(of: frame)
            if coverage > bestCoverage {
                bestCoverage = coverage
                best = index
            }
        }
        return best
    }

    private static func posterPNG(schedule: MessengerAnimationSchedule, frame: (Int) throws -> CGImage) throws -> Data {
        let samples = min(schedule.frames.count, 8)
        var best: CGImage?
        var bestCoverage = -1
        for sample in 0..<samples {
            let entry = schedule.frames[schedule.frames.count * sample / samples]
            let image = try frame(entry.sourceIndex)
            let coverage = StickerPosterFrame.opaqueCoverage(of: image)
            if coverage > bestCoverage {
                bestCoverage = coverage
                best = image
            }
        }
        guard let best else { throw MessengerRenderError.renderFailed }
        return try posterPNG(best)
    }

    /// The export screen's thumbnail: 256 px is plenty for a row, and a quarter of the bytes.
    private static func posterPNG(_ image: CGImage) throws -> Data {
        guard let small = square(image, side: 256), let data = UIImage(cgImage: small).pngData() else {
            throw MessengerRenderError.renderFailed
        }
        return data
    }

    /// WhatsApp's tray icon, drawn from the pack's own WhatsApp rendition.
    ///
    /// The rendition is a WebP and this app cannot *write* one — but it can read one: `ImageIO`
    /// decodes WebP, animated ones included, which is the same fact the export sheet's preview
    /// relies on to play a sticker back. So the first sticker in the pack is decoded, its settled
    /// pose picked out, and the icon squared down from that.
    ///
    /// It matters that this cannot quietly fail: a missing tray image fails the *entire* WhatsApp
    /// hand-off, not one sticker, so the caller is expected to fall back to other artwork rather
    /// than surface the error.
    static func trayIconPNG(fromEncoded data: Data) throws -> Data {
        let source = try MessengerFrameSource(data: data)
        let index = source.frameCount > 1 ? posterIndex(source: source) : 0
        guard let frame = source.frame(at: index) else { throw MessengerRenderError.undecodable }
        return try trayIconPNG(from: frame)
    }

    /// WhatsApp's tray icon: a 96 × 96 PNG under 50 KB, drawn from a rendered sticker's poster.
    static func trayIconPNG(from posterPNG: Data) throws -> Data {
        guard let poster = UIImage(data: posterPNG)?.cgImage else { throw MessengerRenderError.renderFailed }
        return try trayIconPNG(from: poster)
    }

    private static func trayIconPNG(from image: CGImage) throws -> Data {
        guard let small = square(image, side: 96) else { throw MessengerRenderError.renderFailed }
        if let data = UIImage(cgImage: small).pngData(), data.count <= 50 * 1024 { return data }
        var census = IndexedPNGEncoder.ColorCensus(lattice: .init(colorLevels: 32, alphaLevels: 8))
        census.add(small)
        for count in [256, 64, 16] {
            if let data = IndexedPNGEncoder.encodeStill(small, palette: census.palette(limit: count, dithered: true), dimension: 96),
               data.count <= 50 * 1024 {
                return data
            }
        }
        throw MessengerRenderError.renderFailed
    }
}
