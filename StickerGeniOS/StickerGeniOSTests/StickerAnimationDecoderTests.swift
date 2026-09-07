import CoreGraphics
import Foundation
import ImageIO
import Testing
import UIKit
@testable import StickerGeniOS

/// Playback's half of the export contract.
///
/// `StickerExportLadderTests` proves the encoder writes a file with the frames and timing it was
/// asked for; these prove the app can get them back out. The two halves were out of step for as long
/// as the library and the marketplace drew animated stickers as a single poster frame — the artwork
/// moved everywhere except in the app that made it.
@Suite("Sticker animation decoding")
struct StickerAnimationDecoderTests {
    /// A marker crossing a plain disc: enough motion that a dropped frame is a different picture.
    private func frame(index: Int, frameCount: Int, dimension: Int) -> CGImage {
        let context = CGContext(
            data: nil, width: dimension, height: dimension, bitsPerComponent: 8,
            bytesPerRow: dimension * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        let side = Double(dimension)
        context.clear(CGRect(x: 0, y: 0, width: side, height: side))
        context.setFillColor(CGColor(red: 0.36, green: 0.28, blue: 0.92, alpha: 1))
        context.fillEllipse(in: CGRect(x: side * 0.1, y: side * 0.1, width: side * 0.8, height: side * 0.8))
        let progress = Double(index) / Double(frameCount)
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.9))
        context.fillEllipse(in: CGRect(
            x: side * 0.1 + progress * side * 0.7, y: side * 0.45,
            width: side * 0.2, height: side * 0.2
        ))
        return context.makeImage()!
    }

    /// The same file a publish uploads: an indexed, frame-differenced APNG out of `IndexedPNGEncoder`.
    private func publishedAPNG(dimension: Int, frameCount: Int, fps: Int) throws -> Data {
        let frames = (0..<frameCount).map { frame(index: $0, frameCount: frameCount, dimension: dimension) }
        var census = IndexedPNGEncoder.ColorCensus(lattice: .init(colorLevels: 32, alphaLevels: 8))
        for frame in frames { census.add(frame) }
        let delays = StickerExportMetadataPolicy.apngFrameDelays(
            frameCount: frameCount,
            fps: fps,
            holdSeconds: StickerExportMetadataPolicy.loopHoldSeconds
        )
        let stream = IndexedPNGEncoder.AnimationStream(
            palette: census.palette(limit: 256),
            dimension: dimension,
            frameCount: frameCount,
            loopCount: 0,
            byteBudget: StickerExportMetadataPolicy.uploadByteCeiling
        )
        for (index, image) in frames.enumerated() { stream.append(frame: image, delaySeconds: delays[index]) }
        return try #require(stream.finish())
    }

    @Test("A published APNG decodes to every frame it was written with, at the playback size")
    func decodesPublishedAnimation() throws {
        let data = try publishedAPNG(dimension: 618, frameCount: 24, fps: 12)
        let animation = try #require(StickerAnimationDecoder.decode(data, id: "asset@192", maxPixelSize: 192))

        #expect(animation.frames.count == 24)
        #expect(animation.delays.count == 24)
        // 24 frames at 12 FPS is two seconds, and the last frame is held `loopHoldSeconds` longer
        // so the loop reads as a loop. Playback has to honour that or the sticker stutters.
        #expect(abs(animation.duration - (2 + StickerExportMetadataPolicy.loopHoldSeconds)) < 0.01)
        #expect(animation.delays.last! > animation.delays.first!)

        // Decoded down to the surface's size rather than the file's, which is the whole reason a
        // grid of these fits in memory.
        for image in animation.frames {
            #expect(max(image.size.width, image.size.height) == 192)
        }
    }

    /// The blank-first-frame problem `StickerPosterFrame` exists for, from the other side: a decoder
    /// that composited APNG sub-rectangles wrongly would hand back frames that are mostly empty.
    @Test("Decoded frames carry the artwork, not just the rectangle that changed")
    func decodedFramesAreComposited() throws {
        let data = try publishedAPNG(dimension: 300, frameCount: 12, fps: 12)
        let animation = try #require(StickerAnimationDecoder.decode(data, id: "asset@192", maxPixelSize: 192))

        for image in animation.frames {
            let coverage = StickerPosterFrame.opaqueCoverage(of: try #require(image.cgImage))
            // The disc covers most of the canvas in every frame; a bare diff rectangle would score
            // a small fraction of this.
            #expect(coverage > 24 * 24 * 255 / 4)
        }
    }

    /// The file a WhatsApp export hands over, out of the same encoder the export uses.
    private func exportedWebP(dimension: Int, frameCount: Int, delayMilliseconds: Int) throws -> Data {
        let stream = try #require(WebPEncoder.AnimationStream(width: dimension, height: dimension, loops: 0))
        for index in 0..<frameCount {
            #expect(stream.append(
                frame: frame(index: index, frameCount: frameCount, dimension: dimension),
                delayMilliseconds: delayMilliseconds
            ))
        }
        return try #require(stream.finish())
    }

    /// The messenger export sheet previews the file it is about to hand over, and WhatsApp's is an
    /// animated WebP. WebP states its frame delays in its own property dictionary, so a decoder
    /// reading only the GIF and APNG ones falls through to `minimumDelay` and plays every sticker
    /// at 100 FPS — a 2.4 s animation in under half a second.
    @Test("An exported animated WebP decodes at the speed it was encoded at")
    func decodesExportedWebP() throws {
        let data = try exportedWebP(dimension: 512, frameCount: 48, delayMilliseconds: 50)
        let animation = try #require(StickerAnimationDecoder.decode(data, id: "webp@192", maxPixelSize: 192))

        #expect(animation.frames.count == 48)
        #expect(abs(animation.duration - 2.4) < 0.01)
        for delay in animation.delays { #expect(abs(delay - 0.05) < 0.001) }
    }

    @Test("A still asset decodes to no animation, so the caller draws it as a still")
    func stillAssetHasNoAnimation() throws {
        let context = CGContext(
            data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 64 * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        let data = try #require(UIImage(cgImage: context.makeImage()!).pngData())

        #expect(StickerAnimationDecoder.decode(data, id: "asset@192", maxPixelSize: 192) == nil)
    }

    @Test("An animation past the memory budget loses frames, not its running time")
    func longAnimationSubsamples() throws {
        let data = try publishedAPNG(dimension: 300, frameCount: 24, fps: 12)
        let full = try #require(StickerAnimationDecoder.decode(data, id: "asset@192", maxPixelSize: 192))
        // Room for six 192² frames and no more.
        let budget = 6 * 192 * 192 * 4
        let trimmed = try #require(StickerAnimationDecoder.decode(
            data, id: "asset@192", maxPixelSize: 192, byteBudget: budget
        ))

        #expect(trimmed.frames.count <= 6)
        #expect(trimmed.frames.count > 1)
        #expect(trimmed.byteCost <= budget)
        // A dropped frame's time is spent on the frame that replaced it, so the sticker still runs
        // at the length it was authored at — slower, never shorter.
        #expect(abs(trimmed.duration - full.duration) < 0.01)
    }
}
