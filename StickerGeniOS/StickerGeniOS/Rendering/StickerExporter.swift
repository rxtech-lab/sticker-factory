import AnimatedView
import AVFoundation
import CoreVideo
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import UIKit

nonisolated struct RenderedStickerExport: Sendable {
    var url: URL
    var metadata: LocalExportMetadata
    /// What the 500 KB ceiling cost this rendition, when it cost anything.
    var compromise: SystemStickerCompromise?

    /// An animated sticker whose system rendition had to give up its motion. The publish request
    /// carries this so the server reads a single-frame rendition for an animated sticker as the
    /// deliberate floor of the ladder rather than as a client bug.
    var isStillFallback: Bool { compromise?.droppedMotion == true }
}

nonisolated struct SystemStickerPreset: Equatable, Sendable {
    var dimension: Int
    var fps: Int

    /// Spends frame rate before it spends dimension.
    ///
    /// Messages draws a sticker in the transcript at its own pixel size over 3, so `dimension` is
    /// the only rung that changes how big the sticker arrives: 618 lands at 206 pt, 300 at 100 pt
    /// — half the sticker. Colour is no longer a rung of its own: `IndexedPNGEncoder` tries three
    /// palettes inside every rung, in the same pass that renders it, and keeps the richest one that
    /// fits. That is why this ladder is half the length of the one it replaces and reaches further
    /// down: the bottom rungs used to be posterization levels that flattened art to eight colours
    /// and still overshot.
    ///
    /// The floor is 300 px — Apple's smallest sticker size class, which
    /// `SharedStickerCache.allowedPixelDimensions` and Messages both enforce — at 4 FPS, matching
    /// `validateAnimatedRenditionTiming`'s floor in `server/lib/services/stickers.ts`. A cycle that
    /// cannot fit even there falls back to a still rather than failing the export.
    static let adaptive: [Self] = [
        .init(dimension: 618, fps: 24),
        .init(dimension: 618, fps: 15),
        .init(dimension: 618, fps: 10),
        .init(dimension: 408, fps: 18),
        .init(dimension: 408, fps: 12),
        .init(dimension: 300, fps: 15),
        .init(dimension: 300, fps: 10),
        .init(dimension: 300, fps: 8),
        .init(dimension: 300, fps: 6),
        .init(dimension: 300, fps: 4),
    ]

    /// A palette size, and whether it is dithered.
    struct PaletteAttempt: Sendable {
        var count: Int
        var dithered: Bool
    }

    /// Palettes attempted within one rung, richest first.
    ///
    /// All of them are encoded in the rung's single rendering pass and the first that fits wins, so
    /// the cost of offering a fallback palette is a few milliseconds of deflate rather than another
    /// pass over the animation.
    ///
    /// Every dithered palette is followed by the same palette undithered. Dithering trades bytes for
    /// the banding it breaks up — a broken-up ramp is less compressible than a flat plate — and on a
    /// sticker tight enough that the extra bytes cost it a rung of frame rate, the flat version is
    /// the better sticker. Pairing them this way means the dither can only ever be spent out of
    /// slack that already existed.
    static let paletteLadder: [PaletteAttempt] = [
        .init(count: 256, dithered: true),
        .init(count: 256, dithered: false),
        .init(count: 64, dithered: true),
        .init(count: 64, dithered: false),
        .init(count: 16, dithered: true),
        .init(count: 16, dithered: false),
    ]
}

nonisolated enum StickerExportMetadataPolicy {
    static let staticSystemDimensions = [618, 408, 300]

    /// Apple's ceiling, in the decimal kilobytes Messages measures it in.
    static let systemStickerByteCeiling = 500_000

    static func hasAlpha(for format: StickerExportFormat) -> Bool { format != .mp4 }
    static func frameCount(document: AnimatedDocument, fps: Int) -> Int {
        max(1, Int(ceil(document.renderedCycleDuration * Double(fps))))
    }

    /// Stillness held on the last frame before a repeating export starts over.
    ///
    /// Export-only, and deliberately so: the document still describes nothing but its motion, and
    /// the in-app preview plays that motion as a seamless loop. A shared sticker is different — it
    /// autoplays forever in someone else's timeline, where a cycle that restarts the instant it
    /// ends reads as a stutter rather than a loop. The hold is display time on a frame that already
    /// exists, so it never changes `frameCount`.
    ///
    /// `EXPORT_LOOP_HOLD_SECONDS` in `server/lib/services/stickers.ts` carries the same number; the
    /// server rejects a rendition whose duration does not account for it.
    static let loopHoldSeconds = 0.6

    /// Nothing is held on a play-once export: there is no repeat to separate it from.
    static func holdSeconds(for loop: AnimatedLoop) -> Double {
        loop == .once ? 0 : loopHoldSeconds
    }

    /// The hold, for a container that can only say it in frames.
    ///
    /// GIF and APNG give every frame its own delay, so the hold is one longer delay on the last one
    /// and the frame grid still spans exactly the motion cycle. An H.264 track has no such field:
    /// AVAssetWriter re-derives each sample's duration from the spacing of the next, so a final
    /// sample handed a longer duration is written at the cadence like every other one and the file
    /// measures exactly the cycle — which the server rejects for missing the hold. Repeating the
    /// last frame is the only hold an MP4 can state, and it costs close to nothing: identical
    /// frames encode as near-empty P-frames.
    ///
    /// `validateAnimatedRenditionTiming` in `server/lib/services/stickers.ts` computes the same
    /// count the same way, and admits it only for the MP4 rendition.
    static func holdFrameCount(document: AnimatedDocument, fps: Int) -> Int {
        Int((holdSeconds(for: document.loop) * Double(fps)).rounded())
    }

    /// Frame delays on an integer tick grid, distributed so the cycle they sum to is exact.
    ///
    /// Animated containers store a delay per frame as a whole number of ticks — hundredths of a
    /// second for GIF, and whatever denominator the encoder picks for APNG, which is milliseconds
    /// here. Rounding each frame independently compounds: 30 FPS rounded to 3 centiseconds a frame
    /// shortens a 2-second cycle to 1.8. Rounding the *cumulative* time instead spreads 30 and 40 ms
    /// frames across the cycle and lands on its exact length, which matters because the server
    /// recomputes a rendition's duration from the file and rejects one that drifts.
    ///
    /// `holdSeconds` is added to the final frame, so the returned delays sum to the cycle plus the
    /// hold while the count still matches the motion grid.
    static func frameDelays(
        frameCount: Int,
        fps: Int,
        holdSeconds: Double = 0,
        ticksPerSecond: Int
    ) -> [Double] {
        guard frameCount > 0, fps > 0, ticksPerSecond > 0 else { return [] }
        let ticks = Double(ticksPerSecond)
        var previousTicks = 0
        var delays = (0..<frameCount).map { index in
            let target = Int((Double(index + 1) * ticks / Double(fps)).rounded())
            let delay = max(1, target - previousTicks)
            previousTicks += delay
            return Double(delay) / ticks
        }
        // Rounded onto the same grid as every other delay, or the sum drifts off the duration the
        // server recomputes from the encoded file.
        if holdSeconds > 0 { delays[delays.count - 1] += Double(Int((holdSeconds * ticks).rounded())) / ticks }
        return delays
    }

    static func gifFrameDelays(frameCount: Int, fps: Int, holdSeconds: Double = 0) -> [Double] {
        frameDelays(frameCount: frameCount, fps: fps, holdSeconds: holdSeconds, ticksPerSecond: 100)
    }

    /// `IndexedPNGEncoder` writes `fcTL` delays with a denominator of 1000.
    static func apngFrameDelays(frameCount: Int, fps: Int, holdSeconds: Double = 0) -> [Double] {
        frameDelays(frameCount: frameCount, fps: fps, holdSeconds: holdSeconds, ticksPerSecond: 1000)
    }

    /// What an export of `document` actually occupies on a timeline: its motion plus the hold.
    static func renderedDuration(_ document: AnimatedDocument) -> Double {
        document.renderedCycleDuration + holdSeconds(for: document.loop)
    }
}

nonisolated enum StickerExportError: Error, LocalizedError {
    case invalidDocument
    case renderFailed
    case destinationFailed
    case videoWriterFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidDocument: String(localized: "The animation document is invalid.")
        case .renderFailed: String(localized: "A sticker frame could not be rendered.")
        case .destinationFailed: String(localized: "The export file could not be created.")
        case .videoWriterFailed(let reason): String(localized: "The MP4 export failed: \(reason)")
        }
    }
}

/// What the ladder had to give up to fit Apple's ceiling, in the words the export sheet shows.
///
/// Nothing here is an error. The export always produces a sticker; this says which one, so a person
/// who asked for Large and received Small can see why instead of guessing.
nonisolated struct SystemStickerCompromise: Equatable, Sendable {
    var requestedDimension: Int
    var dimension: Int
    var fps: Int?
    var droppedMotion: Bool

    var message: String? {
        if droppedMotion {
            return String(localized: """
            This animation could not fit Apple's 500 KB sticker limit at any frame rate, so the \
            sticker is a still frame. The animated GIF and MP4 exports are unaffected. Shortening \
            the animation, or switching a ping-pong loop to a plain loop, brings the motion back.
            """)
        }
        guard dimension < requestedDimension else { return nil }
        return String(localized: "Exported at \(dimension) px to stay under Apple's 500 KB sticker limit.")
    }
}

@MainActor
final class StickerExporter {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) { self.fileManager = fileManager }

    func exportStaticPNG(document: AnimatedDocument, assets: [String: UIImage]) throws -> RenderedStickerExport {
        _ = try document.validated()
        guard let image = renderFrame(document: document, time: 0, dimension: 1024, assets: assets),
              let data = UIImage(cgImage: image).pngData()
        else { throw StickerExportError.renderFailed }
        let url = try outputURL(extension: "png")
        try data.write(to: url, options: .atomic)
        return .init(
            url: url,
            metadata: .init(format: .png, width: 1024, height: 1024, byteCount: data.count, durationSeconds: nil, fps: nil, hasAlpha: true)
        )
    }

    func exportGIF(document: AnimatedDocument, assets: [String: UIImage]) throws -> RenderedStickerExport {
        _ = try document.validated()
        let data = try animatedImageData(document: document, assets: assets, format: .gif, dimension: 1024, fps: document.fps)
        let url = try outputURL(extension: "gif")
        try data.write(to: url, options: .atomic)
        return .init(
            url: url,
            metadata: .init(
                format: .gif, width: 1024, height: 1024, byteCount: data.count,
                durationSeconds: StickerExportMetadataPolicy.renderedDuration(document), fps: document.fps, hasAlpha: true
            )
        )
    }

    func exportMP4(document: AnimatedDocument, assets: [String: UIImage]) async throws -> RenderedStickerExport {
        _ = try document.validated()
        let dimension = 1024
        let url = try outputURL(extension: "mp4")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: dimension,
            AVVideoHeightKey: dimension,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 5_000_000,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ],
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: dimension,
                kCVPixelBufferHeightKey as String: dimension,
            ]
        )
        guard writer.canAdd(input) else {
            throw StickerExportError.videoWriterFailed(String(localized: "Unsupported writer settings"))
        }
        writer.add(input)
        guard writer.startWriting() else {
            throw StickerExportError.videoWriterFailed(
                writer.error?.localizedDescription ?? String(localized: "Could not start")
            )
        }
        writer.startSession(atSourceTime: .zero)

        let frameCount = StickerExportMetadataPolicy.frameCount(document: document, fps: document.fps)
        let holdFrames = StickerExportMetadataPolicy.holdFrameCount(document: document, fps: document.fps)
        // One uniform cadence for the whole file, motion and hold alike. The hold frames are the
        // last rendered frame again — see `holdFrameCount` for why an MP4 cannot say it any other
        // way — so they are drawn from the image already in hand rather than rendered afresh.
        var lastSticker: CGImage?
        for index in 0..<(frameCount + holdFrames) {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(4)) }
            let rendered = index < frameCount
                ? renderFrame(
                    document: document,
                    time: Double(index) / Double(document.fps),
                    dimension: dimension,
                    assets: assets
                )
                : lastSticker
            guard let sticker = rendered, let pool = adaptor.pixelBufferPool else {
                throw StickerExportError.renderFailed
            }
            lastSticker = sticker
            var optionalBuffer: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &optionalBuffer) == kCVReturnSuccess,
                  let buffer = optionalBuffer
            else { throw StickerExportError.renderFailed }
            // Only the shapes an MP4 fill can actually be: a document could carry a radial
            // gradient or an image here, and neither has a meaningful flat backdrop, so those fall
            // through to the default white rather than being approximated.
            drawOpaqueVideoFrame(
                sticker: sticker,
                background: StickerMP4BackgroundV1(document.mp4Background) ?? .solid("#FFFFFF"),
                into: buffer,
                dimension: dimension
            )
            let timestamp = CMTime(value: CMTimeValue(index), timescale: CMTimeScale(document.fps))
            guard adaptor.append(buffer, withPresentationTime: timestamp) else {
                throw StickerExportError.videoWriterFailed(
                    writer.error?.localizedDescription ?? String(localized: "Could not append a frame")
                )
            }
        }
        input.markAsFinished()
        // The end of the sample grid, not `renderedDuration`: a cycle that is not a whole number of
        // frames ends a fraction past it, and ending the session early would trim the hold back off.
        let renderedDuration = Double(frameCount + holdFrames) / Double(document.fps)
        writer.endSession(atSourceTime: CMTime(seconds: renderedDuration, preferredTimescale: 600))
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw StickerExportError.videoWriterFailed(
                writer.error?.localizedDescription ?? String(localized: "Writer did not complete")
            )
        }
        let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return .init(
            url: url,
            metadata: .init(
                format: .mp4, width: dimension, height: dimension, byteCount: bytes,
                durationSeconds: renderedDuration, fps: document.fps,
                hasAlpha: StickerExportMetadataPolicy.hasAlpha(for: .mp4)
            )
        )
    }

    /// The rendition Messages actually carries, guaranteed to fit Apple's 500 KB ceiling.
    ///
    /// This never fails for size. The ladder walks frame rate and then pixels, encoding three
    /// palettes inside each rung, and if an animation still will not fit at 300 px and 4 FPS it
    /// ships the sticker's poster frame as a still. Refusing the export was the old behaviour and it
    /// was the wrong trade: a sticker that arrives smaller, or that arrives without its motion, is
    /// worth more than an error message, and the GIF and MP4 exports keep the full animation either
    /// way.
    ///
    /// - Parameter size: the rung the ladder starts at. Larger rungs are skipped rather than
    ///   removed, so a sticker that cannot be squeezed into 500 KB at the requested size still
    ///   exports — one size down — instead of failing.
    func exportSystemSticker(
        document: AnimatedDocument,
        assets: [String: UIImage],
        size: SystemStickerSize = .default
    ) throws -> RenderedStickerExport {
        _ = try document.validated()
        let survey = colorSurvey(document: document, assets: assets)
        if document.kind == .animated,
           let rendition = animatedSystemRendition(
               document: document,
               assets: assets,
               survey: survey,
               maximumDimension: size.dimension
           ) {
            let url = try outputURL(extension: "png")
            try rendition.data.write(to: url, options: .atomic)
            return .init(
                url: url,
                metadata: .init(
                    format: .apng, width: rendition.dimension, height: rendition.dimension,
                    byteCount: rendition.data.count,
                    durationSeconds: StickerExportMetadataPolicy.renderedDuration(document),
                    fps: rendition.fps, hasAlpha: true
                ),
                compromise: .init(
                    requestedDimension: size.dimension,
                    dimension: rendition.dimension,
                    fps: rendition.fps,
                    droppedMotion: false
                )
            )
        }

        let still = try stillSystemRendition(
            document: document,
            assets: assets,
            survey: survey,
            maximumDimension: size.dimension
        )
        return .init(
            url: still.url,
            metadata: .init(
                format: .png, width: still.dimension, height: still.dimension,
                byteCount: still.byteCount, durationSeconds: nil, fps: nil, hasAlpha: true
            ),
            compromise: .init(
                requestedDimension: size.dimension,
                dimension: still.dimension,
                fps: nil,
                droppedMotion: document.kind == .animated
            )
        )
    }

    /// One rendering pass per rung, every palette in the ladder encoded inside it.
    ///
    /// The pass stops the moment every candidate has outgrown the ceiling, so an animation that is
    /// hopeless at 618 px pays for a handful of frames there rather than for all of them. The old
    /// ladder re-rendered the whole cycle for each of its thirteen rungs and each of two formats.
    private func animatedSystemRendition(
        document: AnimatedDocument,
        assets: [String: UIImage],
        survey: ColorSurvey,
        maximumDimension: Int
    ) -> (data: Data, dimension: Int, fps: Int)? {
        var attempted = Set<[Int]>()
        // Colours that reproduce this sticker faithfully. Flat art keeps all of them and behaves as
        // it always did; a lifted photograph keeps only the rich ones.
        let faithful = faithfulPaletteCounts(survey: survey)
        var fallback: (data: Data, dimension: Int, fps: Int)?
        for preset in SystemStickerPreset.adaptive where preset.dimension <= maximumDimension {
            // A 6 FPS document clamps every rung below it onto the same grid; rendering that grid
            // once is enough to know it does not fit.
            let fps = min(document.fps, preset.fps)
            guard fps > 0, attempted.insert([preset.dimension, fps]).inserted else { continue }
            guard let attempt = indexedAnimation(
                document: document,
                assets: assets,
                survey: survey,
                dimension: preset.dimension,
                fps: fps
            ) else { continue }
            // Taking the first rung that fits at *any* palette is what posterized lifted photographs
            // in the field: a dense Live Photo fit 618 px at 24 FPS only by dropping to sixteen
            // colours, and shipped full size and perfectly smooth with a face made of plates. Pixels
            // and frame rate are worth less than the subject being recognisable, so a rung that can
            // only be met by wrecking the colour is passed over for a smaller, slower one that
            // keeps it.
            if faithful.contains(attempt.paletteCount) {
                return (attempt.data, preset.dimension, fps)
            }
            // Unless nothing on the ladder can keep it, in which case the old behaviour — the
            // biggest rung that fit at all — is still better than no animation.
            if fallback == nil { fallback = (attempt.data, preset.dimension, fps) }
        }
        return fallback
    }

    /// Palette sizes whose quantization this sticker's own colours can absorb.
    ///
    /// The threshold is the census lattice's own step: at or below it the palette resolves the art
    /// as finely as the survey ever recorded it, so a richer one has nothing left to add. The
    /// richest palette is always included — when even 256 colours cannot hold a sticker, the ladder
    /// still has to choose something, and that is the something.
    private func faithfulPaletteCounts(survey: ColorSurvey) -> Set<Int> {
        let step = Double(255 / max(1, survey.census.lattice.colorLevels - 1))
        var counts = Set<Int>()
        // The ladder pairs each palette with a dithered twin, and both share their entries — so the
        // error is the same for both and the nearest-colour search behind it runs once per size.
        var measured = Set<Int>()
        var richest = 0
        for attempt in SystemStickerPreset.paletteLadder {
            richest = max(richest, attempt.count)
            guard measured.insert(attempt.count).inserted else { continue }
            if survey.census.error(of: survey.census.palette(limit: attempt.count)) <= step {
                counts.insert(attempt.count)
            }
        }
        counts.insert(richest)
        return counts
    }

    private func indexedAnimation(
        document: AnimatedDocument,
        assets: [String: UIImage],
        survey: ColorSurvey,
        dimension: Int,
        fps: Int
    ) -> (data: Data, paletteCount: Int)? {
        let frameCount = StickerExportMetadataPolicy.frameCount(document: document, fps: fps)
        let delays = StickerExportMetadataPolicy.apngFrameDelays(
            frameCount: frameCount,
            fps: fps,
            holdSeconds: StickerExportMetadataPolicy.holdSeconds(for: document.loop)
        )
        guard delays.count == frameCount else { return nil }
        let streams = SystemStickerPreset.paletteLadder.map { attempt in
            IndexedPNGEncoder.AnimationStream(
                palette: survey.census.palette(limit: attempt.count, dithered: attempt.dithered),
                dimension: dimension,
                frameCount: frameCount,
                loopCount: document.loop == .once ? 1 : 0,
                byteBudget: StickerExportMetadataPolicy.systemStickerByteCeiling - 1
            )
        }
        for index in 0..<frameCount {
            guard let frame = renderFrame(
                document: document,
                time: Double(index) / Double(fps),
                dimension: dimension,
                assets: assets
            ) else { return nil }
            for stream in streams where !stream.isAbandoned {
                stream.append(frame: frame, delaySeconds: delays[index])
            }
            guard streams.contains(where: { !$0.isAbandoned }) else { return nil }
        }
        // Ordered richest palette first, so the first one still standing is the best that fits.
        return zip(streams, SystemStickerPreset.paletteLadder)
            .lazy
            .compactMap { stream, attempt in stream.finish().map { ($0, attempt.count) } }
            .first
    }

    /// A single-frame rendition, and the one part of the ladder that cannot run out of room.
    ///
    /// 300 px at sixteen palette entries is four bits a pixel — 45 KB before it is even compressed —
    /// so the last rung is under the ceiling by construction rather than by luck.
    private func stillSystemRendition(
        document: AnimatedDocument,
        assets: [String: UIImage],
        survey: ColorSurvey,
        maximumDimension: Int
    ) throws -> (url: URL, dimension: Int, byteCount: Int) {
        let ceiling = StickerExportMetadataPolicy.systemStickerByteCeiling
        // The same preference the animated ladder makes: a smaller sticker that still looks like its
        // subject beats a full-size one quantized past recognition.
        let faithful = faithfulPaletteCounts(survey: survey)
        var fallback: (data: Data, dimension: Int)?
        for dimension in StickerExportMetadataPolicy.staticSystemDimensions where dimension <= maximumDimension {
            guard let rendered = renderFrame(
                document: document,
                time: survey.posterTime,
                dimension: dimension,
                assets: assets
            ) else { continue }
            // Full colour first: a single frame usually fits without being quantized at all, and a
            // static sticker deserves its gradients.
            if let data = UIImage(cgImage: rendered).pngData(), data.count < ceiling {
                return (try write(data, extension: "png"), dimension, data.count)
            }
            for attempt in Self.stillPaletteLadder {
                guard let data = IndexedPNGEncoder.encodeStill(
                    rendered,
                    palette: survey.census.palette(limit: attempt.count, dithered: attempt.dithered),
                    dimension: dimension
                ), data.count < ceiling else { continue }
                if faithful.contains(attempt.count) {
                    return (try write(data, extension: "png"), dimension, data.count)
                }
                if fallback == nil { fallback = (data, dimension) }
                break
            }
        }
        if let fallback {
            return (try write(fallback.data, extension: "png"), fallback.dimension, fallback.data.count)
        }
        throw StickerExportError.renderFailed
    }

    /// The colour census the palettes are drawn from, plus the frame a still should show.
    ///
    /// Both come from the same handful of sampled frames because both need the whole cycle and
    /// neither needs it at full size: a palette has to exist before the first frame can be encoded,
    /// so surveying every frame would mean rendering the animation twice over. Sampling at 300 px
    /// costs a fraction of a rung and the colours it finds are the same ones.
    private struct ColorSurvey {
        var census: IndexedPNGEncoder.ColorCensus
        var posterTime: Double
    }

    private func colorSurvey(document: AnimatedDocument, assets: [String: UIImage]) -> ColorSurvey {
        var census = IndexedPNGEncoder.ColorCensus(lattice: .init(colorLevels: 32, alphaLevels: 8))
        var posterTime = 0.0
        guard document.kind == .animated else {
            if let frame = renderFrame(document: document, time: 0, dimension: Self.surveyDimension, assets: assets) {
                census.add(frame)
            }
            return .init(census: census, posterTime: 0)
        }
        let cycle = document.renderedCycleDuration
        var bestCoverage = -1
        for sample in 0..<Self.surveySampleCount {
            let time = cycle * Double(sample) / Double(Self.surveySampleCount)
            guard let frame = renderFrame(
                document: document,
                time: time,
                dimension: Self.surveyDimension,
                assets: assets
            ) else { continue }
            census.add(frame)
            // The still fallback shows the sticker's settled pose rather than frame zero, which for
            // anything that fades or slides in is an empty square.
            let coverage = StickerPosterFrame.opaqueCoverage(of: frame)
            if coverage > bestCoverage {
                bestCoverage = coverage
                posterTime = time
            }
        }
        return .init(census: census, posterTime: posterTime)
    }

    /// The animated ladder, plus the two emergency palettes only a still ever reaches.
    ///
    /// Four and two entries are past the point where dithering helps: at that size the pattern reads
    /// as the image rather than as texture on it.
    private static let stillPaletteLadder = SystemStickerPreset.paletteLadder + [
        .init(count: 4, dithered: false),
        .init(count: 2, dithered: false),
    ]

    /// Enough of the cycle to find its colours; more samples stop changing the palette.
    private static let surveySampleCount = 12
    private static let surveyDimension = 300

    func renderFrame(document: AnimatedDocument, time: Double, dimension: Int, assets: [String: UIImage]) -> CGImage? {
        let content = AnimatedIconFrame(
            document: document,
            documentTime: time,
            assets: AnimatedAssetDictionary(images: assets)
        )
            .frame(width: CGFloat(dimension), height: CGFloat(dimension))
        let renderer = ImageRenderer(content: content)
        renderer.scale = 1
        renderer.proposedSize = .init(width: CGFloat(dimension), height: CGFloat(dimension))
        return renderer.cgImage
    }

    private func animatedImageData(
        document: AnimatedDocument,
        assets: [String: UIImage],
        format: StickerExportFormat,
        dimension: Int,
        fps: Int
    ) throws -> Data {
        guard format == .gif || format == .apng, fps > 0 else { throw StickerExportError.invalidDocument }
        let frameCount = StickerExportMetadataPolicy.frameCount(document: document, fps: fps)
        let hold = StickerExportMetadataPolicy.holdSeconds(for: document.loop)
        let gifDelays = format == .gif
            ? StickerExportMetadataPolicy.gifFrameDelays(frameCount: frameCount, fps: fps, holdSeconds: hold)
            : []
        let data = NSMutableData()
        let type = format == .gif ? UTType.gif.identifier : UTType.png.identifier
        guard let destination = CGImageDestinationCreateWithData(data, type as CFString, frameCount, nil) else {
            throw StickerExportError.destinationFailed
        }
        if format == .gif {
            CGImageDestinationSetProperties(destination, [
                kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: document.loop == .once ? 1 : 0],
            ] as CFDictionary)
        } else {
            CGImageDestinationSetProperties(destination, [
                kCGImagePropertyPNGDictionary: [kCGImagePropertyAPNGLoopCount: document.loop == .once ? 1 : 0],
            ] as CFDictionary)
        }

        for index in 0..<frameCount {
            let sourceTime = Double(index) / Double(fps)
            guard let image = renderFrame(document: document, time: sourceTime, dimension: dimension, assets: assets) else {
                throw StickerExportError.renderFailed
            }
            // APNG delays are uniform, so the hold is simply the last frame lingering; the GIF
            // delays already carry it from `gifFrameDelays`.
            let isLast = index == frameCount - 1
            let delay = format == .gif ? gifDelays[index] : 1 / Double(fps) + (isLast ? hold : 0)
            let properties: [CFString: Any] = format == .gif
                ? [kCGImagePropertyGIFDictionary: [
                    kCGImagePropertyGIFDelayTime: delay,
                    kCGImagePropertyGIFUnclampedDelayTime: delay,
                ]]
                : [kCGImagePropertyPNGDictionary: [kCGImagePropertyAPNGDelayTime: delay]]
            CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        }
        guard CGImageDestinationFinalize(destination) else { throw StickerExportError.destinationFailed }
        return data as Data
    }

    private func drawOpaqueVideoFrame(
        sticker: CGImage,
        background: StickerMP4BackgroundV1,
        into buffer: CVPixelBuffer,
        dimension: Int
    ) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer),
              let context = CGContext(
                data: base,
                width: dimension,
                height: dimension,
                bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
              )
        else { return }

        let rect = CGRect(x: 0, y: 0, width: dimension, height: dimension)
        switch background {
        case .solid(let hex):
            context.setFillColor(UIColor(Color(animatedHex: hex)).cgColor)
            context.fill(rect)
        case .linearGradient(let colors, let angle):
            let cgColors = colors.map { UIColor(Color(animatedHex: $0)).cgColor } as CFArray
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: cgColors, locations: [0, 1]) {
                let radians = angle * .pi / 180
                let delta = CGPoint(x: cos(radians) * Double(dimension) / 2, y: sin(radians) * Double(dimension) / 2)
                let center = CGPoint(x: Double(dimension) / 2, y: Double(dimension) / 2)
                context.drawLinearGradient(
                    gradient,
                    start: CGPoint(x: center.x - delta.x, y: center.y - delta.y),
                    end: CGPoint(x: center.x + delta.x, y: center.y + delta.y),
                    options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
                )
            }
        }
        context.draw(sticker, in: rect)
    }

    private func write(_ data: Data, extension fileExtension: String) throws -> URL {
        let url = try outputURL(extension: fileExtension)
        try data.write(to: url, options: .atomic)
        return url
    }

    private func outputURL(extension fileExtension: String) throws -> URL {
        let directory = fileManager.temporaryDirectory.appending(path: "StickerFactoryExports", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appending(path: UUID().uuidString).appendingPathExtension(fileExtension)
    }
}
