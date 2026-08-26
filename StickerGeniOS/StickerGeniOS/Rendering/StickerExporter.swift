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

    static let adaptive: [Self] = [
        .init(dimension: 618, fps: 24, colorLevels: 32),
        .init(dimension: 408, fps: 18, colorLevels: 24),
        .init(dimension: 300, fps: 15, colorLevels: 16),
        .init(dimension: 300, fps: 10, colorLevels: 12),
        .init(dimension: 300, fps: 8, colorLevels: 8),
    ]
}

nonisolated enum StickerExportMetadataPolicy {
    static let staticSystemDimensions = [618, 408, 300]
    static let staticSystemColorLevels: [Int?] = [nil, 64, 32, 16, 8]

    static func hasAlpha(for format: StickerExportFormat) -> Bool { format != .mp4 }
    static func frameCount(document: StickerDocumentV1, fps: Int) -> Int {
        max(1, Int(ceil(StickerInterpolator.renderedCycleDuration(document) * Double(fps))))
    }

    /// GIF frame delays are stored in integer centiseconds by widely used
    /// decoders. Cumulative rounding distributes 30/40 ms frames while
    /// preserving the exact intended cycle instead of shortening 30 FPS to
    /// 33.33 FPS.
    static func gifFrameDelays(frameCount: Int, fps: Int) -> [Double] {
        guard frameCount > 0, fps > 0 else { return [] }
        var previousCentiseconds = 0
        return (0..<frameCount).map { index in
            let target = Int((Double(index + 1) * 100 / Double(fps)).rounded())
            let delay = max(1, target - previousCentiseconds)
            previousCentiseconds += delay
            return Double(delay) / 100
        }
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

    func exportStaticPNG(document: StickerDocumentV1, assets: [String: UIImage]) throws -> RenderedStickerExport {
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

    func exportGIF(document: StickerDocumentV1, assets: [String: UIImage]) throws -> RenderedStickerExport {
        _ = try document.validated()
        let data = try animatedImageData(document: document, assets: assets, format: .gif, dimension: 1024, fps: document.fps, colorLevels: nil)
        let url = try outputURL(extension: "gif")
        try data.write(to: url, options: .atomic)
        return .init(
            url: url,
            metadata: .init(
                format: .gif, width: 1024, height: 1024, byteCount: data.count,
                durationSeconds: StickerInterpolator.renderedCycleDuration(document), fps: document.fps, hasAlpha: true
            )
        )
    }

    func exportAPNG(document: StickerDocumentV1, assets: [String: UIImage], dimension: Int = 618, fps: Int? = nil) throws -> RenderedStickerExport {
        _ = try document.validated()
        let frameRate = fps ?? document.fps
        let data = try animatedImageData(document: document, assets: assets, format: .apng, dimension: dimension, fps: frameRate, colorLevels: nil)
        let url = try outputURL(extension: "png")
        try data.write(to: url, options: .atomic)
        return .init(
            url: url,
            metadata: .init(
                format: .apng, width: dimension, height: dimension, byteCount: data.count,
                durationSeconds: StickerInterpolator.renderedCycleDuration(document), fps: frameRate, hasAlpha: true
            )
        )
    }

    func exportMP4(document: StickerDocumentV1, assets: [String: UIImage]) async throws -> RenderedStickerExport {
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

        let cycleDuration = StickerInterpolator.renderedCycleDuration(document)
        let frameCount = StickerExportMetadataPolicy.frameCount(document: document, fps: document.fps)
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
            drawOpaqueVideoFrame(sticker: sticker, background: document.mp4Background, into: buffer, dimension: dimension)
            let timestamp = CMTime(value: CMTimeValue(index), timescale: CMTimeScale(document.fps))
            guard adaptor.append(buffer, withPresentationTime: timestamp) else {
                throw StickerExportError.videoWriterFailed(writer.error?.localizedDescription ?? "Could not append a frame")
            }
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw StickerExportError.videoWriterFailed(writer.error?.localizedDescription ?? "Writer did not complete")
        }
        let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return .init(
            url: url,
            metadata: .init(
                format: .mp4, width: dimension, height: dimension, byteCount: bytes,
                durationSeconds: cycleDuration, fps: document.fps,
                hasAlpha: StickerExportMetadataPolicy.hasAlpha(for: .mp4)
            )
        )
    }

    func exportSystemSticker(document: StickerDocumentV1, assets: [String: UIImage]) throws -> RenderedStickerExport {
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
                            byteCount: data.count, durationSeconds: StickerInterpolator.renderedCycleDuration(document),
                            fps: min(document.fps, preset.fps), hasAlpha: true
                        )
                    )
                }
            }
        }
        throw StickerExportError.systemStickerTooLarge
    }

    func renderFrame(document: StickerDocumentV1, time: Double, dimension: Int, assets: [String: UIImage]) -> CGImage? {
        let content = StickerScene(document: document, time: time, assets: assets)
            .frame(width: CGFloat(dimension), height: CGFloat(dimension))
        let renderer = ImageRenderer(content: content)
        renderer.scale = 1
        renderer.proposedSize = .init(width: CGFloat(dimension), height: CGFloat(dimension))
        return renderer.cgImage
    }

    private func animatedImageData(
        document: StickerDocumentV1,
        assets: [String: UIImage],
        format: StickerExportFormat,
        dimension: Int,
        fps: Int,
        colorLevels: Int?
    ) throws -> Data {
        guard format == .gif || format == .apng, fps > 0 else { throw StickerExportError.invalidDocument }
        let frameCount = StickerExportMetadataPolicy.frameCount(document: document, fps: fps)
        let gifDelays = format == .gif
            ? StickerExportMetadataPolicy.gifFrameDelays(frameCount: frameCount, fps: fps)
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
            let delay = format == .gif ? gifDelays[index] : 1 / Double(fps)
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
            context.setFillColor(UIColor(Color(stickerHex: hex)).cgColor)
            context.fill(rect)
        case .linearGradient(let colors, let angle):
            let cgColors = colors.map { UIColor(Color(stickerHex: $0)).cgColor } as CFArray
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
