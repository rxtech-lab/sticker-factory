import AnimatedView
import AVFoundation
import CoreImage
import CoreVideo
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import UIKit

nonisolated struct RenderedStickerExport: Sendable {
    var url: URL
    var metadata: LocalExportMetadata
}

nonisolated struct SystemStickerPreset: Equatable, Sendable {
    var dimension: Int
    var fps: Int
    var colorLevels: Int

    /// Spends frame rate and color depth before it spends dimension.
    ///
    /// Messages draws a sticker in the transcript at its own pixel size over 3, so `dimension` is
    /// the only rung that changes how big the sticker arrives: 618 lands at 206 pt, 300 at 100 pt
    /// — half the sticker. The 618 rungs are worth attempting because flat, poster-like art does
    /// reach them; dense photographic art does not, and no ordering fixes that. A 618 frame of it
    /// costs well over the 500 KB budget on its own, and the server's 8 FPS floor for adaptive
    /// renditions bounds how many frames can be dropped chasing it.
    ///
    /// Every rung the previous ladder ended on is still here. Detailed art genuinely needs the
    /// 300 @ 8 floor, and a ladder that cannot reach it fails the export outright rather than
    /// shipping a small sticker.
    static let adaptive: [Self] = [
        .init(dimension: 618, fps: 24, colorLevels: 32),
        .init(dimension: 618, fps: 15, colorLevels: 16),
        .init(dimension: 618, fps: 10, colorLevels: 8),
        .init(dimension: 408, fps: 18, colorLevels: 24),
        .init(dimension: 408, fps: 12, colorLevels: 12),
        .init(dimension: 300, fps: 15, colorLevels: 16),
        .init(dimension: 300, fps: 10, colorLevels: 12),
        .init(dimension: 300, fps: 8, colorLevels: 8),
    ]
}

nonisolated enum StickerExportMetadataPolicy {
    static let staticSystemDimensions = [618, 408, 300]
    static let staticSystemColorLevels: [Int?] = [nil, 64, 32, 16, 8]

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

    /// GIF frame delays are stored in integer centiseconds by widely used
    /// decoders. Cumulative rounding distributes 30/40 ms frames while
    /// preserving the exact intended cycle instead of shortening 30 FPS to
    /// 33.33 FPS.
    ///
    /// `holdSeconds` is added to the final frame, so the returned delays sum to the cycle plus the
    /// hold while the count still matches the motion grid.
    static func gifFrameDelays(frameCount: Int, fps: Int, holdSeconds: Double = 0) -> [Double] {
        guard frameCount > 0, fps > 0 else { return [] }
        var previousCentiseconds = 0
        var delays = (0..<frameCount).map { index in
            let target = Int((Double(index + 1) * 100 / Double(fps)).rounded())
            let delay = max(1, target - previousCentiseconds)
            previousCentiseconds += delay
            return Double(delay) / 100
        }
        // Rounded to whole centiseconds like every other delay, or the sum drifts off the duration
        // the server recomputes from the encoded file.
        if holdSeconds > 0 { delays[delays.count - 1] += Double(Int((holdSeconds * 100).rounded())) / 100 }
        return delays
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
    case systemStickerTooLarge

    var errorDescription: String? {
        switch self {
        case .invalidDocument: "The animation document is invalid."
        case .renderFailed: "A sticker frame could not be rendered."
        case .destinationFailed: "The export file could not be created."
        case .videoWriterFailed(let reason): "The MP4 export failed: \(reason)"
        case .systemStickerTooLarge: "The sticker could not be reduced below 500 KB."
        }
    }
}

@MainActor
final class StickerExporter {
    private let fileManager: FileManager
    private let ciContext = CIContext(options: [.cacheIntermediates: false])

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
        let data = try animatedImageData(document: document, assets: assets, format: .gif, dimension: 1024, fps: document.fps, colorLevels: nil)
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

    func exportAPNG(document: AnimatedDocument, assets: [String: UIImage], dimension: Int = 618, fps: Int? = nil) throws -> RenderedStickerExport {
        _ = try document.validated()
        let frameRate = fps ?? document.fps
        let data = try animatedImageData(document: document, assets: assets, format: .apng, dimension: dimension, fps: frameRate, colorLevels: nil)
        let url = try outputURL(extension: "png")
        try data.write(to: url, options: .atomic)
        return .init(
            url: url,
            metadata: .init(
                format: .apng, width: dimension, height: dimension, byteCount: data.count,
                durationSeconds: StickerExportMetadataPolicy.renderedDuration(document), fps: frameRate, hasAlpha: true
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
        guard writer.canAdd(input) else { throw StickerExportError.videoWriterFailed("Unsupported writer settings") }
        writer.add(input)
        guard writer.startWriting() else { throw StickerExportError.videoWriterFailed(writer.error?.localizedDescription ?? "Could not start") }
        writer.startSession(atSourceTime: .zero)

        let renderedDuration = StickerExportMetadataPolicy.renderedDuration(document)
        let frameCount = StickerExportMetadataPolicy.frameCount(document: document, fps: document.fps)
        let holdSeconds = StickerExportMetadataPolicy.holdSeconds(for: document.loop)
        for index in 0..<frameCount {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(4)) }
            guard let sticker = renderFrame(
                document: document,
                time: Double(index) / Double(document.fps),
                dimension: dimension,
                assets: assets
            ), let pool = adaptor.pixelBufferPool else { throw StickerExportError.renderFailed }
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
            let appended: Bool
            if index == frameCount - 1 {
                // The hold has to ride on the final sample's own duration — see `heldSampleBuffer`.
                let held = try heldSampleBuffer(
                    buffer,
                    at: timestamp,
                    lasting: CMTime(seconds: 1 / Double(document.fps) + holdSeconds, preferredTimescale: 600)
                )
                appended = input.append(held)
            } else {
                appended = adaptor.append(buffer, withPresentationTime: timestamp)
            }
            guard appended else {
                throw StickerExportError.videoWriterFailed(writer.error?.localizedDescription ?? "Could not append a frame")
            }
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(seconds: renderedDuration, preferredTimescale: 600))
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw StickerExportError.videoWriterFailed(writer.error?.localizedDescription ?? "Writer did not complete")
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

    func exportSystemSticker(document: AnimatedDocument, assets: [String: UIImage]) throws -> RenderedStickerExport {
        _ = try document.validated()
        if document.kind == .static {
            for dimension in StickerExportMetadataPolicy.staticSystemDimensions {
                guard let rendered = renderFrame(document: document, time: 0, dimension: dimension, assets: assets) else { continue }
                for colorLevels in StickerExportMetadataPolicy.staticSystemColorLevels {
                    let image = colorLevels.flatMap { posterized(rendered, levels: $0) } ?? rendered
                    guard let data = UIImage(cgImage: image).pngData(), data.count < 500_000 else { continue }
                    let url = try outputURL(extension: "png")
                    try data.write(to: url, options: .atomic)
                    return .init(
                        url: url,
                        metadata: .init(format: .png, width: dimension, height: dimension, byteCount: data.count, durationSeconds: nil, fps: nil, hasAlpha: true)
                    )
                }
            }
        } else {
            for preset in SystemStickerPreset.adaptive {
                for format in [StickerExportFormat.apng, .gif] {
                    guard let data = try? animatedImageData(
                        document: document,
                        assets: assets,
                        format: format,
                        dimension: preset.dimension,
                        fps: min(document.fps, preset.fps),
                        colorLevels: preset.colorLevels
                    ), data.count < 500_000 else { continue }
                    let url = try outputURL(extension: format == .gif ? "gif" : "png")
                    try data.write(to: url, options: .atomic)
                    return .init(
                        url: url,
                        metadata: .init(
                            format: format, width: preset.dimension, height: preset.dimension,
                            byteCount: data.count, durationSeconds: StickerExportMetadataPolicy.renderedDuration(document),
                            fps: min(document.fps, preset.fps), hasAlpha: true
                        )
                    )
                }
            }
        }
        throw StickerExportError.systemStickerTooLarge
    }

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
        fps: Int,
        colorLevels: Int?
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
            guard var image = renderFrame(document: document, time: sourceTime, dimension: dimension, assets: assets) else {
                throw StickerExportError.renderFailed
            }
            if let colorLevels { image = posterized(image, levels: colorLevels) ?? image }
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

    /// Wraps a frame so it carries its own display duration instead of inheriting the frame cadence.
    ///
    /// `endSession(atSourceTime:)` does not stretch the final sample: AVAssetWriter times it from
    /// the cadence that preceded it, so a file ended a hold past the cycle still measures exactly
    /// the cycle in `mdhd`. The server recomputes the duration from the container and rejects an
    /// export missing the hold, so the hold has to be spelled out on the sample itself. No extra
    /// frame is written for it — the last frame simply lingers, which is what the hold means.
    private func heldSampleBuffer(_ pixelBuffer: CVPixelBuffer, at presentationTime: CMTime, lasting duration: CMTime) throws -> CMSampleBuffer {
        var format: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pixelBuffer, formatDescriptionOut: &format) == noErr,
              let format
        else { throw StickerExportError.videoWriterFailed("The final frame could not be described") }
        var timing = CMSampleTimingInfo(duration: duration, presentationTimeStamp: presentationTime, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(
            allocator: nil,
            imageBuffer: pixelBuffer,
            formatDescription: format,
            sampleTiming: &timing,
            sampleBufferOut: &sample
        ) == noErr, let sample
        else { throw StickerExportError.videoWriterFailed("The final frame could not be timed") }
        return sample
    }

    private func posterized(_ image: CGImage, levels: Int) -> CGImage? {
        let input = CIImage(cgImage: image)
        let output = input.applyingFilter("CIColorPosterize", parameters: ["inputLevels": max(2, levels)])
        return ciContext.createCGImage(output, from: input.extent)
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

    private func outputURL(extension fileExtension: String) throws -> URL {
        let directory = fileManager.temporaryDirectory.appending(path: "StickerFactoryExports", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appending(path: UUID().uuidString).appendingPathExtension(fileExtension)
    }
}
