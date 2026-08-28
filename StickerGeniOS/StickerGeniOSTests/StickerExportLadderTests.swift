import AnimatedView
import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import StickerGeniOS

/// The sticker rendition is the one export with a hard external limit — Apple rejects anything at or
/// above 500 KB — and the ladder that fits into it is hand-written down to the PNG chunk. These tests
/// cover the two things that are easy to get wrong and impossible to notice late: a file that no
/// decoder accepts, and a ladder that runs out of rungs and refuses to export at all.
@Suite("System sticker ladder")
struct StickerExportLadderTests {
    /// Dense, moving artwork: a gradient body that never repeats a colour and a marker that crosses
    /// the canvas, so neither the palette nor the frame differencing gets an easy ride.
    private func frame(index: Int, frameCount: Int, dimension: Int) -> CGImage {
        let context = CGContext(
            data: nil, width: dimension, height: dimension, bitsPerComponent: 8,
            bytesPerRow: dimension * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        let side = Double(dimension)
        context.clear(CGRect(x: 0, y: 0, width: side, height: side))
        context.saveGState()
        context.addEllipse(in: CGRect(x: side * 0.1, y: side * 0.1, width: side * 0.8, height: side * 0.8))
        context.clip()
        let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [
                CGColor(red: 0.98, green: 0.71, blue: 0.2, alpha: 1),
                CGColor(red: 0.36, green: 0.28, blue: 0.92, alpha: 1),
            ] as CFArray,
            locations: [0, 1]
        )!
        context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: side, y: side), options: [])
        context.restoreGState()
        let progress = Double(index) / Double(frameCount)
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.9))
        context.fillEllipse(in: CGRect(
            x: side * 0.1 + progress * side * 0.7, y: side * 0.45,
            width: side * 0.2, height: side * 0.2
        ))
        return context.makeImage()!
    }

    private func census(frames: [CGImage]) -> IndexedPNGEncoder.ColorCensus {
        var census = IndexedPNGEncoder.ColorCensus(lattice: .init(colorLevels: 32, alphaLevels: 8))
        for frame in frames { census.add(frame) }
        return census
    }

    @Test("A palette APNG decodes to the frames and timing it was written with")
    func indexedAnimationRoundTrips() throws {
        let dimension = 300
        let frameCount = 32
        let frames = (0..<frameCount).map { frame(index: $0, frameCount: frameCount, dimension: dimension) }
        let delays = StickerExportMetadataPolicy.apngFrameDelays(frameCount: frameCount, fps: 8, holdSeconds: 0.6)
        let stream = IndexedPNGEncoder.AnimationStream(
            palette: census(frames: frames).palette(limit: 256),
            dimension: dimension,
            frameCount: frameCount,
            loopCount: 0,
            byteBudget: StickerExportMetadataPolicy.systemStickerByteCeiling - 1
        )
        for (index, image) in frames.enumerated() { stream.append(frame: image, delaySeconds: delays[index]) }
        let data = try #require(stream.finish())

        // The frames span 4 s at 8 FPS and the last one is held 0.6 s longer before the loop
        // restarts, which is the duration the server recomputes from the file.
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        #expect(CGImageSourceGetCount(source) == frameCount)
        let decodedDuration = (0..<CGImageSourceGetCount(source)).reduce(0.0) { total, index in
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
            let png = properties?[kCGImagePropertyPNGDictionary] as? [CFString: Any]
            return total + ((png?[kCGImagePropertyAPNGUnclampedDelayTime] as? Double) ?? 0)
        }
        #expect(abs(decodedDuration - 4.6) < 0.01)

        // Every frame is reconstructed from the palette and the rectangle that changed, so a
        // decoded frame has to match the frame it was written from — bar the quantization.
        for index in [0, frameCount / 2, frameCount - 1] {
            let decoded = try #require(CGImageSourceCreateImageAtIndex(source, index, nil))
            #expect(decoded.width == dimension && decoded.height == dimension)
            let rendered = try #require(IndexedPNGEncoder.rgbaBytes(from: decoded)?.pixels)
            let expected = try #require(IndexedPNGEncoder.rgbaBytes(from: frames[index])?.pixels)
            #expect(rendered.count == expected.count)
            var error = 0.0
            for offset in stride(from: 0, to: rendered.count, by: 4) {
                error += abs(Double(rendered[offset + 3]) - Double(expected[offset + 3])) / 255
            }
            #expect(error / Double(rendered.count / 4) < 0.05)
        }
    }

    @Test("The palette encoder beats ImageIO by enough to matter")
    func indexedAnimationIsSmallerThanImageIO() throws {
        let dimension = 300
        let frameCount = 32
        let frames = (0..<frameCount).map { frame(index: $0, frameCount: frameCount, dimension: dimension) }
        let stream = IndexedPNGEncoder.AnimationStream(
            palette: census(frames: frames).palette(limit: 256),
            dimension: dimension,
            frameCount: frameCount,
            loopCount: 0,
            byteBudget: StickerExportMetadataPolicy.systemStickerByteCeiling - 1
        )
        for image in frames { stream.append(frame: image, delaySeconds: 0.125) }
        let indexed = try #require(stream.finish())

        let reference = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(
            reference, UTType.png.identifier as CFString, frameCount, nil
        ))
        for image in frames {
            CGImageDestinationAddImage(destination, image, [
                kCGImagePropertyPNGDictionary: [kCGImagePropertyAPNGDelayTime: 0.125],
            ] as CFDictionary)
        }
        #expect(CGImageDestinationFinalize(destination))

        // This is the whole reason the encoder exists: the same animation ImageIO writes as full
        // RGBA frames does not fit under the ceiling, and indexed it does, several times over.
        #expect(reference.length > StickerExportMetadataPolicy.systemStickerByteCeiling)
        #expect(indexed.count < StickerExportMetadataPolicy.systemStickerByteCeiling)
        #expect(indexed.count * 4 < reference.length)
    }

    @Test("A still at the ladder's floor fits the ceiling even when nothing compresses")
    func stillFloorAlwaysFits() throws {
        // Noise is the worst case for deflate: nothing repeats, so the file is essentially the raw
        // scanlines. At 300 px and sixteen palette entries those are four bits a pixel — 45 KB — so
        // the bottom of the ladder is under Apple's limit by construction rather than by luck.
        var seed: UInt64 = 0x5DEECE66D
        func random() -> UInt8 {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return UInt8((seed >> 33) & 0xFF)
        }
        let dimension = 300
        var pixels = [UInt8](repeating: 0, count: dimension * dimension * 4)
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            pixels[offset] = random()
            pixels[offset + 1] = random()
            pixels[offset + 2] = random()
            pixels[offset + 3] = offset % 8 == 0 ? 0 : random()
        }
        let provider = try #require(CGDataProvider(data: Data(pixels) as CFData))
        let noise = try #require(CGImage(
            width: dimension, height: dimension, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: dimension * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        ))
        var noiseCensus = IndexedPNGEncoder.ColorCensus(lattice: .init(colorLevels: 32, alphaLevels: 8))
        noiseCensus.add(noise)
        let data = try #require(IndexedPNGEncoder.encodeStill(
            noise, palette: noiseCensus.palette(limit: 16), dimension: dimension
        ))
        #expect(data.count < StickerExportMetadataPolicy.systemStickerByteCeiling)
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        #expect(CGImageSourceGetCount(source) == 1)
        let decoded = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(decoded.width == dimension && decoded.height == dimension)
    }

    @Test("A frame that changes nothing still costs a frame, not a canvas")
    func changedRectangles() {
        let dimension = 8
        var first = [UInt8](repeating: 0, count: dimension * dimension)
        #expect(IndexedPNGEncoder.changedRect(from: nil, to: first, dimension: dimension)
            == .init(x: 0, y: 0, width: dimension, height: dimension))
        // Nothing moved: an APNG frame cannot be empty, so it degenerates to one pixel repainting
        // itself rather than to the whole canvas.
        #expect(IndexedPNGEncoder.changedRect(from: first, to: first, dimension: dimension)
            == .init(x: 0, y: 0, width: 1, height: 1))

        var second = first
        second[2 * dimension + 3] = 4
        second[5 * dimension + 6] = 7
        #expect(IndexedPNGEncoder.changedRect(from: first, to: second, dimension: dimension)
            == .init(x: 3, y: 2, width: 4, height: 4))
        first[0] = 9
        #expect(IndexedPNGEncoder.changedRect(from: first, to: second, dimension: dimension)
            == .init(x: 0, y: 0, width: 7, height: 6))
    }

    @MainActor
    @Test("An animated sticker always exports under the ceiling, at a size Messages accepts")
    func animatedSystemStickerAlwaysFits() throws {
        var document = PreviewFixtures.animatedBaseDocument
        document.layers = [
            .shape(.init(base: .init(id: "backdrop", name: "Backdrop"), shape: .burst, fill: .solid("#FFE7A3"))),
            .shape(.init(base: .init(id: "hero", name: "Hero"), shape: .circle, fill: .solid("#A88BFF"))),
        ]
        document.durationSeconds = 1
        document.fps = 12
        let rendition = try StickerExporter().exportSystemSticker(document: document, assets: [:], size: .small)
        defer { try? FileManager.default.removeItem(at: rendition.url) }
        let written = try Data(contentsOf: rendition.url)

        #expect(rendition.metadata.byteCount < StickerExportMetadataPolicy.systemStickerByteCeiling)
        #expect(rendition.metadata.byteCount == written.count)
        // The sizes Messages and `SharedStickerCache.allowedPixelDimensions` accept.
        #expect(StickerExportMetadataPolicy.staticSystemDimensions.contains(rendition.metadata.width))
        #expect(rendition.metadata.width == rendition.metadata.height)
        // Asking for Small means the ladder never starts above 300 px, whatever the artwork is.
        #expect(rendition.metadata.width <= SystemStickerSize.small.dimension)
        #expect(rendition.metadata.hasAlpha)

        let source = try #require(CGImageSourceCreateWithData(written as CFData, nil))
        if rendition.isStillFallback {
            #expect(CGImageSourceGetCount(source) == 1)
        } else {
            // The frame grid the server recovers from the file has to be the one the metadata
            // claims, or the publish is rejected for timing it cannot verify.
            let fps = try #require(rendition.metadata.fps)
            #expect(CGImageSourceGetCount(source)
                == StickerExportMetadataPolicy.frameCount(document: document, fps: fps))
            #expect(rendition.metadata.durationSeconds == StickerExportMetadataPolicy.renderedDuration(document))
        }
    }

    @MainActor
    @Test("Exporting as video renders the video and nothing else")
    func videoOnlyExportSkipsTheStickerLadder() async throws {
        var revision = PreviewFixtures.candidate
        revision.candidateState = .accepted
        // The cycle stays as authored — its keyframes live on it — and only the grid is thinned, so
        // this renders a handful of frames rather than sixty.
        revision.document.fps = 8
        let publisher = StickerPublisher(api: MockStickerAPIClient())

        let video = try await publisher.export(
            revision: revision, assets: [:], verifiedAssetIDs: [], size: .small, selection: .video
        )
        defer { video.forEach { try? FileManager.default.removeItem(at: $0.url) } }
        #expect(video.map(\.metadata.format) == [.mp4])

        let sticker = try await publisher.export(
            revision: revision, assets: [:], verifiedAssetIDs: [], size: .small, selection: .sticker
        )
        defer { sticker.forEach { try? FileManager.default.removeItem(at: $0.url) } }
        // The sharing GIF and the Messages rendition, and no video encode at all.
        #expect(sticker.map(\.metadata.format) == [.gif, .apng])
    }

    @MainActor
    @Test("A static sticker exports its own rendition without quantizing what already fits")
    func staticSystemSticker() throws {
        var document = PreviewFixtures.staticDocument
        document.layers = [
            .shape(.init(base: .init(id: "base", name: "Base"), shape: .roundedRectangle, fill: .solid("#A88BFF"))),
        ]
        let rendition = try StickerExporter().exportSystemSticker(document: document, assets: [:], size: .large)
        defer { try? FileManager.default.removeItem(at: rendition.url) }

        #expect(rendition.metadata.format == .png)
        #expect(rendition.metadata.durationSeconds == nil)
        #expect(rendition.metadata.byteCount < StickerExportMetadataPolicy.systemStickerByteCeiling)
        #expect(rendition.metadata.width == SystemStickerSize.large.dimension)
        // A still that fits is not a compromise, and the sheet should stay quiet about it.
        #expect(rendition.compromise?.message == nil)
        #expect(!rendition.isStillFallback)
    }
}
