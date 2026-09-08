import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
import VP9Encoder
@testable import StickerGeniOS

/// Every output is checked by something other than the encoder that wrote it: ImageIO for PNG and
/// WebP, and an EBML reader plus libvpx's decoder for WebM. Dimensions, byte limits, duration and
/// transparency are the four things a messenger rejects a sticker over.
@Suite("Messenger sticker rendering")
struct MessengerStickerRendererTests {
    /// A soft-edged gradient blob on transparency that drifts across the canvas.
    private func frame(index: Int, count: Int, dimension: Int) -> CGImage {
        let context = CGContext(
            data: nil, width: dimension, height: dimension, bitsPerComponent: 8,
            bytesPerRow: dimension * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        let side = Double(dimension)
        context.clear(CGRect(x: 0, y: 0, width: side, height: side))
        let progress = Double(index) / Double(max(1, count))
        let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [
                CGColor(red: 0.98, green: 0.4, blue: 0.35, alpha: 1),
                CGColor(red: 0.2, green: 0.3, blue: 0.9, alpha: 0)
            ] as CFArray,
            locations: [0, 1]
        )!
        let centre = CGPoint(x: side * (0.3 + progress * 0.4), y: side * 0.5)
        context.drawRadialGradient(gradient, startCenter: centre, startRadius: 0, endCenter: centre, endRadius: side * 0.35, options: [])
        return context.makeImage()!
    }

    private func png(_ image: CGImage) -> Data {
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }

    /// An APNG at `fps` for `seconds`, the way a publish writes the sharing rendition.
    private func apng(dimension: Int, fps: Int, seconds: Double) -> Data {
        let count = Int(Double(fps) * seconds)
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, count, nil)!
        CGImageDestinationSetProperties(destination, [kCGImagePropertyPNGDictionary: [kCGImagePropertyAPNGLoopCount: 0]] as CFDictionary)
        for index in 0..<count {
            CGImageDestinationAddImage(destination, frame(index: index, count: count, dimension: dimension), [
                kCGImagePropertyPNGDictionary: [
                    kCGImagePropertyAPNGDelayTime: 1.0 / Double(fps),
                    kCGImagePropertyAPNGUnclampedDelayTime: 1.0 / Double(fps)
                ]
            ] as CFDictionary)
        }
        CGImageDestinationFinalize(destination)
        return data as Data
    }

    private func sticker(kind: StickerKind) -> Sticker {
        Sticker(
            id: "s-\(kind.rawValue)",
            title: "Test",
            kind: kind,
            status: .published,
            activeRevisionId: "r",
            createdAt: Date(),
            updatedAt: Date(),
            previewAsset: nil,
            systemSticker: nil
        )
    }

    private struct ImageFacts {
        let type: String
        let count: Int
        let width: Int
        let height: Int
        let hasAlpha: Bool
    }

    private func properties(_ data: Data) -> ImageFacts {
        let source = CGImageSourceCreateWithData(data as CFData, nil)!
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        return ImageFacts(
            type: CGImageSourceGetType(source)! as String,
            count: CGImageSourceGetCount(source),
            width: properties[kCGImagePropertyPixelWidth] as? Int ?? 0,
            height: properties[kCGImagePropertyPixelHeight] as? Int ?? 0,
            hasAlpha: properties[kCGImagePropertyHasAlpha] as? Bool ?? false
        )
    }

    @Test("A still becomes a transparent 512² WebP under WhatsApp's 100 KB")
    func whatsAppStill() throws {
        let rendered = try MessengerStickerRenderer.render(
            sticker: sticker(kind: .static),
            artwork: png(frame(index: 0, count: 1, dimension: 1_024)),
            destination: .whatsapp
        )
        #expect(rendered.format == .webp)
        #expect(!rendered.isAnimated)
        #expect(rendered.byteCount <= 100 * 1024)
        let facts = properties(rendered.data)
        #expect(facts.type == UTType.webP.identifier)
        #expect(facts.count == 1)
        #expect(facts.width == 512 && facts.height == 512)
        #expect(facts.hasAlpha)
        // The poster is what the export screen previews.
        #expect(properties(rendered.posterPNG).type == UTType.png.identifier)
    }

    @Test("A still becomes a 512² PNG under Telegram's 512 KB")
    func telegramStill() throws {
        // Non-square artwork is fitted, not stretched: the output is square and transparent.
        let context = CGContext(
            data: nil,
            width: 800,
            height: 400,
            bitsPerComponent: 8,
            bytesPerRow: 3_200,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: 0.1, green: 0.8, blue: 0.4, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 800, height: 400))
        let rendered = try MessengerStickerRenderer.render(
            sticker: sticker(kind: .static),
            artwork: png(context.makeImage()!),
            destination: .telegram
        )
        #expect(rendered.format == .png)
        #expect(rendered.byteCount <= 512 * 1024)
        let facts = properties(rendered.data)
        #expect(facts.type == UTType.png.identifier)
        #expect(facts.width == 512 && facts.height == 512)
        let decoded = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithData(rendered.data as CFData, nil)!, 0, nil)!
        let raster = IndexedPNGEncoder.rgbaBytes(from: decoded)!.pixels
        // Letterboxed above and below: the top row is transparent, the middle row opaque.
        #expect(raster[3] == 0)
        #expect(raster[(256 * 512 + 256) * 4 + 3] == 255)
    }

    @Test("A long animation reaches WhatsApp under 500 KB, within 10 s, sped up rather than cut")
    func whatsAppAnimation() throws {
        // 12 s at 12 fps: past the ceiling, so it must be accelerated.
        let rendered = try MessengerStickerRenderer.render(
            sticker: sticker(kind: .animated),
            artwork: apng(dimension: 512, fps: 12, seconds: 12),
            destination: .whatsapp
        )
        #expect(rendered.format == .webp)
        #expect(rendered.isAnimated)
        #expect(rendered.isAccelerated)
        #expect(rendered.byteCount <= 500 * 1024)
        #expect(rendered.durationMilliseconds <= 10_000)
        let image = try WAStickerImageFacts(data: rendered.data)
        #expect(image.width == 512 && image.height == 512)
        #expect(image.frameCount == rendered.frameCount)
        #expect(image.totalDurationMilliseconds <= 10_000)
        #expect(image.totalDurationMilliseconds >= 9_500)
        #expect(image.minimumFrameDurationMilliseconds >= 8)
        #expect(image.hasAlpha)
    }

    @Test("A short animation reaches WhatsApp at its own speed")
    func whatsAppShortAnimation() throws {
        let rendered = try MessengerStickerRenderer.render(
            sticker: sticker(kind: .animated),
            artwork: apng(dimension: 300, fps: 10, seconds: 2),
            destination: .whatsapp
        )
        #expect(!rendered.isAccelerated)
        #expect(rendered.frameCount == 20)
        #expect(abs(rendered.durationMilliseconds - 2_000) <= 20)
        let facts = properties(rendered.data)
        #expect(facts.width == 512 && facts.height == 512)
    }

    @Test("An animation reaches Telegram as transparent VP9 WebM under 256 KB and 3 s")
    func telegramAnimation() throws {
        let rendered = try MessengerStickerRenderer.render(
            sticker: sticker(kind: .animated),
            artwork: apng(dimension: 512, fps: 24, seconds: 4.5),
            destination: .telegram
        )
        #expect(rendered.format == .webm)
        #expect(rendered.isAccelerated)
        #expect(rendered.byteCount <= 256 * 1024)
        #expect(rendered.durationMilliseconds <= 3_000)

        let document = try WebMReader.read(rendered.data)
        #expect(document.docType == "webm")
        #expect(document.track?.codecID == "V_VP9")
        #expect(document.track?.pixelWidth == 512 && document.track?.pixelHeight == 512)
        #expect(document.track?.alphaMode == 1)
        #expect(document.blocks.count == rendered.frameCount)
        #expect(document.blocks.first?.isKeyframe == true)
        let end = document.blocks.last.map { $0.timestampMilliseconds + ($0.durationMilliseconds ?? 0) } ?? 0
        #expect(end <= 3_000 && end >= 2_900)
        #expect(document.blocks.count <= 91)

        let color = try VP9Decoder()
        let alpha = try VP9Decoder()
        for block in document.blocks {
            let decoded = try color.decode(block.color)
            #expect(decoded.width == 512 && decoded.height == 512)
            let decodedAlpha = try alpha.decode(try #require(block.alpha))
            #expect(decodedAlpha.width == 512)
            // The canvas corner is transparent in every frame.
            #expect(decodedAlpha.luma[0] < 8)
        }
    }

    @Test("A single-frame rendition of an animated sticker still ships as an animation")
    func animatedStillFallback() throws {
        let rendered = try MessengerStickerRenderer.render(
            sticker: sticker(kind: .animated),
            artwork: png(frame(index: 0, count: 1, dimension: 618)),
            destination: .whatsapp
        )
        #expect(rendered.isAnimated)
        #expect(properties(rendered.data).count == 2)
    }

    @Test("Unreadable artwork is reported rather than sent")
    func undecodable() {
        #expect(throws: MessengerRenderError.undecodable) {
            try MessengerStickerRenderer.render(sticker: sticker(kind: .static), artwork: Data([0, 1, 2, 3]), destination: .telegram)
        }
    }

    @Test("The WhatsApp tray icon is a 96² PNG under 50 KB")
    func trayIcon() throws {
        let rendered = try MessengerStickerRenderer.render(
            sticker: sticker(kind: .static),
            artwork: png(frame(index: 0, count: 1, dimension: 1_024)),
            destination: .whatsapp
        )
        let tray = try MessengerStickerRenderer.trayIconPNG(from: rendered.posterPNG)
        #expect(tray.count <= 50 * 1024)
        let facts = properties(tray)
        #expect(facts.type == UTType.png.identifier)
        #expect(facts.width == 96 && facts.height == 96)
    }
}

/// What ImageIO says about a WebP, independent of the WASticker package's own reader.
private struct WAStickerImageFacts {
    let width: Int
    let height: Int
    let frameCount: Int
    let frameDurationsMilliseconds: [Int]
    let hasAlpha: Bool

    init(data: Data) throws {
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        width = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
        height = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
        hasAlpha = properties[kCGImagePropertyHasAlpha] as? Bool ?? false
        frameCount = CGImageSourceGetCount(source)
        frameDurationsMilliseconds = (0..<frameCount).map { index in
            let frame = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
            let webp = frame?[kCGImagePropertyWebPDictionary] as? [CFString: Any]
            let unclamped = webp?[kCGImagePropertyWebPUnclampedDelayTime] as? Double
            let seconds = unclamped ?? (webp?[kCGImagePropertyWebPDelayTime] as? Double) ?? 0
            return Int((seconds * 1_000).rounded())
        }
    }

    var totalDurationMilliseconds: Int { frameDurationsMilliseconds.reduce(0, +) }
    var minimumFrameDurationMilliseconds: Int { frameDurationsMilliseconds.min() ?? 0 }
}
