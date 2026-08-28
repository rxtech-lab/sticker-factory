import CoreGraphics
import Foundation
import Testing
@testable import AnimatedView

/// The frame atlas, from tile-slicing up to rasterised frames.
///
/// A sequence layer is the one layer kind whose *content* changes over time rather than only its
/// transform, so "the document compiles" and "the document animates" come apart here in a way they
/// do not for any other kind. These tests draw real pixels and compare them.
@MainActor
struct SequenceRenderingTests {
    private let assetID = "33333333-3333-4333-8333-333333333333"

    /// A 2x2 sheet whose four tiles are solid red, green, blue, and white.
    ///
    /// Distinct flat colours rather than a photo, so "did the renderer pick tile 2" is answerable by
    /// reading one pixel instead of by comparing images.
    private func atlas(tile: Int = 32) -> PlatformImage {
        let side = tile * 2
        let context = CGContext(
            data: nil,
            width: side,
            height: side,
            bitsPerComponent: 8,
            bytesPerRow: side * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        // Tile 0 is the top-left, and CoreGraphics' origin is bottom-left, so the row order here is
        // flipped relative to the index order. Getting this backwards is exactly the bug that makes
        // a sequence play its rows in the wrong order, so it is asserted explicitly below.
        let colours: [(CGRect, CGColor)] = [
            (CGRect(x: 0, y: tile, width: tile, height: tile), CGColor(red: 1, green: 0, blue: 0, alpha: 1)),
            (CGRect(x: tile, y: tile, width: tile, height: tile), CGColor(red: 0, green: 1, blue: 0, alpha: 1)),
            (CGRect(x: 0, y: 0, width: tile, height: tile), CGColor(red: 0, green: 0, blue: 1, alpha: 1)),
            (CGRect(x: tile, y: 0, width: tile, height: tile), CGColor(red: 1, green: 1, blue: 1, alpha: 1)),
        ]
        for (rect, colour) in colours {
            context.setFillColor(colour)
            context.fill(rect)
        }
        return PlatformImage(animatedCGImage: context.makeImage()!)!
    }

    private func layer(
        frameCount: Int = 4,
        frameRate: Double = 10,
        playback: AnimatedSequencePlayback = .loop
    ) -> AnimatedSequenceLayer {
        .init(
            base: .init(id: "hero", name: "Live capture"),
            assetId: assetID,
            columns: 2,
            rows: 2,
            frameCount: frameCount,
            frameRate: frameRate,
            playback: playback
        )
    }

    private func document(_ layer: AnimatedSequenceLayer, durationSeconds: Double = 0.4) -> AnimatedDocument {
        .init(
            kind: .animated,
            durationSeconds: durationSeconds,
            fps: 30,
            loop: .loop,
            layers: [.sequence(layer)]
        )
    }

    /// The average colour of an image, as 0...1 RGB.
    private func averageColour(_ image: CGImage) -> (r: Double, g: Double, b: Double) {
        let width = image.width
        let height = image.height
        let buffer = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: width * height * 4)
        defer { buffer.deallocate() }
        buffer.initialize(repeating: 0)
        guard let context = CGContext(
            data: buffer.baseAddress,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return (0, 0, 0) }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        var totals = (r: 0.0, g: 0.0, b: 0.0)
        var opaque = 0.0
        for index in stride(from: 0, to: buffer.count, by: 4) where buffer[index + 3] > 127 {
            totals.r += Double(buffer[index]) / 255
            totals.g += Double(buffer[index + 1]) / 255
            totals.b += Double(buffer[index + 2]) / 255
            opaque += 1
        }
        guard opaque > 0 else { return (0, 0, 0) }
        return (totals.r / opaque, totals.g / opaque, totals.b / opaque)
    }

    // MARK: - Tile slicing

    /// Asserts *which* swatch each tile is, by nearest match rather than by exact component values.
    ///
    /// Colour management shifts a flat fill by a few percent on the way through a `CGContext`, and
    /// pinning components to two decimal places was measuring that rather than the slicing. Nearest
    /// match is what the test actually cares about: tile 1 must be the green swatch, not a green
    /// within 0.02 of a nominal value.
    @Test func slicesTilesInRowMajorOrderFromTheTopLeft() {
        let assets = AnimatedAssetDictionary(images: [assetID: atlas()])
        let sequence = layer()
        let swatches: [(name: String, rgb: (r: Double, g: Double, b: Double))] = [
            ("red", (1, 0, 0)), ("green", (0, 1, 0)), ("blue", (0, 0, 1)), ("white", (1, 1, 1)),
        ]
        for index in 0..<4 {
            let tile = FrameAtlasCache.shared.tile(for: sequence, index: index, assets: assets)
            guard let cgTile = tile?.animatedCGImage else {
                Issue.record("tile \(index) did not slice")
                return
            }
            #expect(cgTile.width == 32 && cgTile.height == 32)
            let colour = averageColour(cgTile)
            let nearest = swatches.min { a, b in
                distance(colour, a.rgb) < distance(colour, b.rgb)
            }
            #expect(nearest?.name == swatches[index].name, "tile \(index) sliced the wrong swatch")
        }
        FrameAtlasCache.shared.removeAll()
    }

    private func distance(_ a: (r: Double, g: Double, b: Double), _ b: (r: Double, g: Double, b: Double)) -> Double {
        (a.r - b.r) * (a.r - b.r) + (a.g - b.g) * (a.g - b.g) + (a.b - b.b) * (a.b - b.b)
    }

    @Test func refusesAnIndexOutsideTheGrid() {
        let assets = AnimatedAssetDictionary(images: [assetID: atlas()])
        #expect(FrameAtlasCache.shared.tile(for: layer(), index: 4, assets: assets) == nil)
        #expect(FrameAtlasCache.shared.tile(for: layer(), index: -1, assets: assets) == nil)
        FrameAtlasCache.shared.removeAll()
    }

    /// The grid is part of the cache key, so re-laying-out an atlas must not serve stale tiles.
    @Test func aDifferentGridIsADifferentTile() {
        let assets = AnimatedAssetDictionary(images: [assetID: atlas()])
        let asFour = FrameAtlasCache.shared.tile(for: layer(), index: 1, assets: assets)?.animatedCGImage
        var wide = layer()
        wide.columns = 1
        wide.rows = 2
        wide.frameCount = 2
        let asTwo = FrameAtlasCache.shared.tile(for: wide, index: 1, assets: assets)?.animatedCGImage
        #expect(asFour?.width == 32)
        #expect(asTwo?.width == 64, "a 1x2 grid slices full-width rows, not quarters")
        FrameAtlasCache.shared.removeAll()
    }

    @Test func servesNothingWhenTheAtlasHasNotLoaded() {
        #expect(FrameAtlasCache.shared.tile(for: layer(), index: 0, assets: EmptyAnimatedAssets()) == nil)
    }

    // MARK: - Rendering over time

    @Test func drawsADifferentTileAsTheTimelineAdvances() throws {
        let assets = AnimatedAssetDictionary(images: [assetID: atlas()])
        let renderer = AnimatedIconRenderer(document: document(layer()), assets: assets)

        // 10fps footage: tile 0 at t=0, tile 1 at t=0.1, tile 2 at t=0.2.
        let first = try #require(renderer.cgImage(at: 0, dimension: 64))
        let second = try #require(renderer.cgImage(at: 0.1, dimension: 64))
        let third = try #require(renderer.cgImage(at: 0.2, dimension: 64))

        let red = averageColour(first)
        let green = averageColour(second)
        let blue = averageColour(third)
        #expect(red.r > 0.8 && red.g < 0.2, "t=0 should draw the red tile")
        #expect(green.g > 0.8 && green.r < 0.2, "t=0.1 should draw the green tile")
        #expect(blue.b > 0.8 && blue.r < 0.2, "t=0.2 should draw the blue tile")
        FrameAtlasCache.shared.removeAll()
    }

    /// A single-frame sequence is what a still lift produces, and it must render as an ordinary
    /// image rather than flickering or disappearing.
    @Test func aSingleFrameSequenceHoldsItsOnlyTile() throws {
        let assets = AnimatedAssetDictionary(images: [assetID: atlas()])
        var single = layer(frameCount: 1)
        single.columns = 1
        single.rows = 1
        let renderer = AnimatedIconRenderer(document: document(single), assets: assets)
        let first = try #require(renderer.cgImage(at: 0, dimension: 64))
        let later = try #require(renderer.cgImage(at: 0.3, dimension: 64))
        let a = averageColour(first)
        let b = averageColour(later)
        #expect(abs(a.r - b.r) < 0.02 && abs(a.g - b.g) < 0.02 && abs(a.b - b.b) < 0.02)
        FrameAtlasCache.shared.removeAll()
    }

    @Test func rendersItsPlaceholderWhenTheAtlasIsMissing() throws {
        let renderer = AnimatedIconRenderer(document: document(layer()), assets: EmptyAnimatedAssets())
        let frame = try #require(renderer.cgImage(at: 0, dimension: 64))
        // Something visible, so a layer whose asset is still downloading does not read as deleted.
        let colour = averageColour(frame)
        #expect(colour.r + colour.g + colour.b > 0)
    }

    // MARK: - Document interaction

    /// The whole timing design in one assertion: `speed` reaches the footage because the frame index
    /// is derived from document time, which already has speed folded in.
    @Test func documentSpeedScalesTheFootage() throws {
        let assets = AnimatedAssetDictionary(images: [assetID: atlas()])
        var fast = document(layer())
        fast.speed = 2
        let renderer = AnimatedIconRenderer(document: fast, assets: assets)
        // At 2x, half a tile-interval of wall clock is a whole tile of footage.
        let atHalfInterval = try #require(renderer.cgImage(at: 0.05, dimension: 64))
        let colour = averageColour(atHalfInterval)
        #expect(colour.g > 0.8 && colour.r < 0.2, "2x speed should already be on tile 1 at t=0.05")
        FrameAtlasCache.shared.removeAll()
    }
}
