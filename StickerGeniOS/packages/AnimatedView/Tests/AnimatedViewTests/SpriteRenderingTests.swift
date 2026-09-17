import CoreGraphics
import Foundation
import Testing
@testable import AnimatedView

/// A sprite frame is a body cell with a face drawn into its slot. These tests draw real pixels and
/// read them back, because "the layer decodes" says nothing about whether the face landed on the
/// face — and the server composites the same frame, so what is pinned here is one half of a parity.
@MainActor
struct SpriteRenderingTests {
    private let clipID = "31111111-1111-4111-8111-111111111111"
    private let facesID = "33333333-3333-4333-8333-333333333333"
    private let maskID = "35555555-5555-4555-8555-555555555555"
    private let cell = (width: 60, height: 90)

    private func context(width: Int, height: Int) -> CGContext {
        CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
    }

    /// A 3x2 clip sheet: every cell is a flat orange body on transparent, inset from the cell edge.
    /// Cell 2 is blue so "which cell" is answerable from one pixel.
    private func bodySheet() -> PlatformImage {
        let ctx = context(width: cell.width * 3, height: cell.height * 2)
        for index in 0..<6 {
            let column = index % 3, row = index / 3
            // CoreGraphics is bottom-up: row 0 (top) is the upper half of the context.
            let rect = CGRect(x: column * cell.width + 6, y: (1 - row) * cell.height + 6, width: cell.width - 12, height: cell.height - 12)
            ctx.setFillColor(index == 2 ? CGColor(red: 0, green: 0, blue: 1, alpha: 1) : CGColor(red: 1, green: 0.5, blue: 0, alpha: 1))
            ctx.fill(rect)
        }
        return PlatformImage(animatedCGImage: ctx.makeImage()!)!
    }

    /// A 2x1 expression sheet: a green tile then a red tile, each inset from its cell.
    private func faceSheet() -> PlatformImage {
        let ctx = context(width: 80, height: 40)
        ctx.setFillColor(CGColor(red: 0, green: 1, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 8, y: 8, width: 24, height: 24))
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 48, y: 8, width: 24, height: 24))
        return PlatformImage(animatedCGImage: ctx.makeImage()!)!
    }

    /// Only the upper half of the face slot is visible; the body below represents a foreground cup.
    private func maskSheet() -> PlatformImage {
        let ctx = context(width: cell.width * 3, height: cell.height * 2)
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        for index in 0..<6 {
            let column = index % 3, row = index / 3
            ctx.fill(CGRect(x: column * cell.width + 17, y: (1 - row) * cell.height + 58, width: 26, height: 14))
        }
        return PlatformImage(animatedCGImage: ctx.makeImage()!)!
    }

    private func layer(clipId: String = "idle", expressionId: String = "neutral") -> AnimatedSpriteLayer {
        let frames = (0..<6).map { AnimatedSpriteFrame(duration: $0 == 0 ? 2.4 : 0.3, faceX: 0.5, faceY: 0.3, faceSize: 0.4) }
        return .init(
            base: .init(id: "hero", name: "Cat"),
            clips: [.init(id: "idle", assetId: clipID, columns: 3, rows: 2, frames: frames)],
            expressions: .init(assetId: facesID, columns: 2, rows: 1, tiles: [
                .init(id: "neutral", x: 0.1, y: 0.2, width: 0.3, height: 0.6),
                .init(id: "happy", x: 0.6, y: 0.2, width: 0.3, height: 0.6)
            ]),
            clipId: clipId,
            expressionId: expressionId,
            posterAssetId: "34444444-4444-4444-8444-444444444444"
        )
    }

    /// The pixel at a top-down `(x, y)` of an image, as 0...255 RGBA.
    private func pixel(_ image: CGImage, x: Int, y: Int) -> [Int] {
        let ctx = context(width: image.width, height: image.height)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let data = ctx.data!.assumingMemoryBound(to: UInt8.self)
        let offset = (y * image.width + x) * 4
        return (0..<4).map { Int(data[offset + $0]) }
    }

    /// Which flat swatch a pixel is, by nearest match: colour management shifts a fill by a few
    /// percent through a `CGContext`, and the test cares which colour landed, not its exact bytes.
    private func swatch(_ pixel: [Int]) -> String {
        guard pixel[3] > 200 else { return "clear" }
        let swatches: [(String, [Int])] = [("orange", [255, 128, 0]), ("blue", [0, 0, 255]), ("green", [0, 255, 0]), ("red", [255, 0, 0])]
        return swatches.min { a, b in
            zip(pixel, a.1).reduce(0) { $0 + abs($1.0 - $1.1) } < zip(pixel, b.1).reduce(0) { $0 + abs($1.0 - $1.1) }
        }!.0
    }

    @Test func drawsTheChosenFaceIntoTheFrameSlotAndNothingElse() throws {
        let cache = SpriteFrameCache()
        let assets = AnimatedAssetDictionary(images: [clipID: bodySheet(), facesID: faceSheet()])
        let sprite = layer()
        let frame = try #require(cache.frame(for: sprite, index: 2, assets: assets)?.animatedCGImage)
        #expect(frame.width == cell.width)
        #expect(frame.height == cell.height)
        // Frame 2 is the blue cell; its slot is centred at (30, 27) and the face is green there.
        #expect(swatch(pixel(frame, x: 30, y: 27)) == "green")
        // Outside the slot the body shows through: 0.4 * 60 * 1.08 = 26px wide, so x=50 is body.
        #expect(swatch(pixel(frame, x: 50, y: 27)) == "blue")
        #expect(swatch(pixel(frame, x: 30, y: 75)) == "blue")
        // The cell's transparent inset survives compositing.
        #expect(swatch(pixel(frame, x: 1, y: 1)) == "clear")

        // A different expression changes the slot and only the slot; a different frame changes the body.
        let happy = try #require(cache.frame(for: layer(expressionId: "happy"), index: 2, assets: assets)?.animatedCGImage)
        #expect(swatch(pixel(happy, x: 30, y: 27)) == "red")
        #expect(pixel(happy, x: 30, y: 75) == pixel(frame, x: 30, y: 75))
        let first = try #require(cache.frame(for: sprite, index: 0, assets: assets)?.animatedCGImage)
        #expect(swatch(pixel(first, x: 30, y: 75)) == "orange")
        #expect(swatch(pixel(first, x: 30, y: 27)) == "green")
    }

    @Test func missingSheetsDrawNothingAndOutOfRangeFramesAreRefused() {
        let cache = SpriteFrameCache()
        let sprite = layer()
        #expect(cache.frame(for: sprite, index: 0, assets: EmptyAnimatedAssets()) == nil)
        let assets = AnimatedAssetDictionary(images: [clipID: bodySheet(), facesID: faceSheet()])
        #expect(cache.frame(for: sprite, index: 6, assets: assets) == nil)
        #expect(cache.frame(for: sprite, index: -1, assets: assets) == nil)
        // Only the sheets that are missing keep it from drawing: with both present it composes.
        #expect(cache.frame(for: sprite, index: 0, assets: assets) != nil)
    }

    @Test func aMaskKeepsForegroundBodyPixelsAboveTheExpression() throws {
        var sprite = layer()
        sprite.clips[0].faceCompositing = .masked
        sprite.clips[0].faceMaskAssetId = maskID
        let assets = AnimatedAssetDictionary(images: [
            clipID: bodySheet(), facesID: faceSheet(), maskID: maskSheet()
        ])
        let frame = try #require(SpriteFrameCache().frame(for: sprite, index: 2, assets: assets)?.animatedCGImage)
        #expect(swatch(pixel(frame, x: 30, y: 22)) == "green")
        #expect(swatch(pixel(frame, x: 30, y: 36)) == "blue")
        #expect(sprite.base.id == "hero")
        #expect(sprite.currentClip.faceMaskAssetId == maskID)
    }

    @Test func documentWalksTheClipOnItsOwnClock() throws {
        let sprite = layer()
        let document = AnimatedDocument(kind: .animated, durationSeconds: 4.2, fps: 24, loop: .loop, layers: [.sprite(sprite)])
        try document.validated()
        #expect(document.hasMotion)
        #expect(document.layers[0].referencedImageAssetIDs == [clipID, facesID])
        let frames = sprite.currentClip.frames
        #expect(AnimationInterpolator.spriteFrameIndex(frames, atDocumentTime: 2.39) == 0)
        #expect(AnimationInterpolator.spriteFrameIndex(frames, atDocumentTime: 2.4) == 1)
        #expect(AnimationInterpolator.spriteFrameIndex(frames, atDocumentTime: 3.89) == 5)
        // 2.4 + 5 * 0.3 is the total, so just past it the clip has wrapped.
        #expect(AnimationInterpolator.spriteFrameIndex(frames, atDocumentTime: 3.91) == 0)
    }
}
