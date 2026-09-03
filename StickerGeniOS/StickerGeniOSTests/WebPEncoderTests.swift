import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import StickerGeniOS

/// WebP is written by a linked encoder and read by the system, so these tests are deliberately
/// asymmetric: everything is encoded by `WebPEncoder` and decoded by ImageIO, which is what the
/// recipient's Messages will use. A file only this project can read would pass a round trip against
/// itself and fail on the one device that matters.
@Suite("WebP encoder")
struct WebPEncoderTests {
    /// A soft-edged blob on transparency that moves across the canvas — alpha at every value
    /// between 0 and 255, which is what separates WebP from the GIF it is offered beside.
    private func frame(index: Int, frameCount: Int, dimension: Int) -> CGImage {
        let context = CGContext(
            data: nil, width: dimension, height: dimension, bitsPerComponent: 8,
            bytesPerRow: dimension * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        let side = Double(dimension)
        context.clear(CGRect(x: 0, y: 0, width: side, height: side))
        let progress = Double(index) / Double(frameCount)
        let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [
                CGColor(red: 0.98, green: 0.4, blue: 0.35, alpha: 1),
                CGColor(red: 0.2, green: 0.3, blue: 0.9, alpha: 0),
            ] as CFArray,
            locations: [0, 1]
        )!
        let centre = CGPoint(x: side * (0.25 + progress * 0.5), y: side * 0.5)
        context.drawRadialGradient(
            gradient,
            startCenter: centre, startRadius: 0,
            endCenter: centre, endRadius: side * 0.35,
            options: []
        )
        return context.makeImage()!
    }

    @Test("An animated WebP decodes through ImageIO to the frames and timing it was written with")
    func animationRoundTripsThroughImageIO() throws {
        let dimension = 256
        let frameCount = 12
        let frames = (0..<frameCount).map { frame(index: $0, frameCount: frameCount, dimension: dimension) }
        // The same grid the APNG is written on, so the two containers of one document agree.
        let delays = StickerExportMetadataPolicy.apngFrameDelays(frameCount: frameCount, fps: 10, holdSeconds: 0.6)
        let data = try WebPEncoder.encodeAnimation(
            frames: frames.enumerated().map { index, image in
                .init(image: image, delayMilliseconds: Int((delays[index] * 1_000).rounded()))
            },
            loops: 0
        )

        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        #expect(CGImageSourceGetType(source) as String? == UTType.webP.identifier)
        #expect(CGImageSourceGetCount(source) == frameCount)

        // 12 frames at 10 FPS is 1.2 s, with the last one held 0.6 s longer before the loop
        // restarts — the duration the server recomputes from the file it is handed.
        let decodedDuration = (0..<CGImageSourceGetCount(source)).reduce(0.0) { total, index in
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
            let webp = properties?[kCGImagePropertyWebPDictionary] as? [CFString: Any]
            return total + ((webp?[kCGImagePropertyWebPUnclampedDelayTime] as? Double) ?? 0)
        }
        #expect(abs(decodedDuration - 1.8) < 0.02)

        // Alpha is the channel this format was chosen for, so it is the one checked: a decoded
        // frame's transparency has to match what went in, soft edge and all.
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

    @Test("A still WebP decodes to a transparent image of the size it was written at")
    func stillRoundTripsThroughImageIO() throws {
        let dimension = 512
        let image = frame(index: 0, frameCount: 1, dimension: dimension)
        let data = try WebPEncoder.encodeStill(image)

        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        #expect(CGImageSourceGetType(source) as String? == UTType.webP.identifier)
        #expect(CGImageSourceGetCount(source) == 1)
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        #expect(properties[kCGImagePropertyPixelWidth] as? Int == dimension)
        #expect(properties[kCGImagePropertyPixelHeight] as? Int == dimension)
        #expect(properties[kCGImagePropertyHasAlpha] as? Bool == true)
    }

    /// The size claim this whole path exists for, measured rather than asserted in a comment.
    ///
    /// The comparison is against ImageIO writing the same frames as an APNG, which is the file
    /// WinkySticker attaches when there is no WebP to prefer.
    @Test("An animated WebP is dramatically smaller than the same frames as an APNG")
    func animationIsSmallerThanApng() throws {
        let dimension = 256
        let frameCount = 12
        let frames = (0..<frameCount).map { frame(index: $0, frameCount: frameCount, dimension: dimension) }
        let webp = try WebPEncoder.encodeAnimation(
            frames: frames.map { .init(image: $0, delayMilliseconds: 100) },
            loops: 0
        )

        let reference = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(
            reference, UTType.png.identifier as CFString, frameCount, nil
        ))
        for image in frames {
            CGImageDestinationAddImage(destination, image, [
                kCGImagePropertyPNGDictionary: [kCGImagePropertyAPNGDelayTime: 0.1],
            ] as CFDictionary)
        }
        #expect(CGImageDestinationFinalize(destination))
        #expect(webp.count * 4 < reference.length)
    }

    @Test("Frames that disagree about their size are refused rather than silently cropped")
    func mismatchedFramesAreRefused() {
        let frames: [WebPEncoder.Frame] = [
            .init(image: frame(index: 0, frameCount: 2, dimension: 128), delayMilliseconds: 100),
            .init(image: frame(index: 1, frameCount: 2, dimension: 256), delayMilliseconds: 100),
        ]
        #expect(throws: WebPEncoder.Failure.mismatchedFrameSize) {
            try WebPEncoder.encodeAnimation(frames: frames, loops: 0)
        }
    }

    @Test("An empty animation is refused")
    func emptyAnimationIsRefused() {
        #expect(throws: WebPEncoder.Failure.noFrames) {
            try WebPEncoder.encodeAnimation(frames: [], loops: 0)
        }
    }
}
