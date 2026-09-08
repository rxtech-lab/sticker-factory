import CoreGraphics
import Foundation
import Testing
@testable import AnimatedView

/// Rasterises documents through the same `ImageRenderer` path the exporter uses.
///
/// Compiling is not the same as drawing: a layer can be laid out entirely off-canvas, a paint can
/// resolve to clear, or a trim can leave a stroke at zero length, and none of that shows up in a
/// model-level test. These count actual pixels.
@MainActor
struct RenderingTests {
    private let dimension = 96

    /// Draws `image` into a fresh RGBA buffer and hands the raw bytes to `body`.
    ///
    /// The buffer is held by the closure rather than by an `inout` array: passing `&array` to
    /// `CGContext(data:)` only guarantees the pointer for the duration of that one call, so drawing
    /// into the context afterwards and then reading the array back is undefined behaviour. It also
    /// *looks* like it works, which is worse — it read plausible-but-wrong pixel counts here before
    /// this was fixed.
    private func withPixels<T>(_ image: CGImage, _ body: (UnsafeMutableBufferPointer<UInt8>) -> T) -> T? {
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
        ) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return body(buffer)
    }

    /// Opaque pixel count and total alpha.
    private func coverage(_ image: CGImage) -> (pixels: Int, alpha: Double) {
        withPixels(image) { buffer in
            var opaque = 0
            var alphaSum = 0.0
            for index in stride(from: 3, to: buffer.count, by: 4) {
                let alpha = Double(buffer[index]) / 255
                alphaSum += alpha
                if alpha > 0.5 { opaque += 1 }
            }
            return (opaque, alphaSum)
        } ?? (0, 0)
    }

    private func bytes(_ image: CGImage) -> Data {
        withPixels(image) { Data(buffer: $0) } ?? Data()
    }

    // MARK: - Every fixture draws something

    @Test(arguments: AnimatedPreviewDocuments.all.map(\.title))
    func everyFixtureRendersVisiblePixels(_ title: String) throws {
        let document = try #require(AnimatedPreviewDocuments.all.first { $0.title == title }?.document)
        let renderer = AnimatedIconRenderer(document: document)
        // Just short of the end of the cycle. Exactly at the end, a looping document has already
        // wrapped back to t=0, where an entrance animation has not started and the canvas is blank.
        let time = document.kind == .static ? 0 : document.renderedCycleDuration * 0.99
        let image = try #require(renderer.cgImage(at: time, dimension: dimension), "\(title) rendered nothing")

        #expect(image.width == dimension)
        #expect(image.height == dimension)
        let painted = coverage(image)
        #expect(painted.pixels > 0, "\(title) rendered a fully transparent frame")
    }

    // MARK: - Transparency

    @Test func aDocumentWithNoBackgroundStaysTransparent() throws {
        let renderer = AnimatedIconRenderer(document: AnimatedPreviewDocuments.svgDrawOnSimple)
        // t=1.2 is where the stroke has finished drawing; the document runs to 2 s and then loops.
        let image = try #require(renderer.cgImage(at: 1.2, dimension: dimension))
        let painted = coverage(image)
        // A fully drawn check mark covers a small fraction of the canvas; the rest must stay clear,
        // or an exported PNG would carry an opaque box around the artwork.
        #expect(painted.pixels > 0)
        #expect(painted.pixels < dimension * dimension / 4)
    }

    @Test func aSolidBackgroundFillsTheWholeCanvas() throws {
        let renderer = AnimatedIconRenderer(document: AnimatedPreviewDocuments.solidBackground)
        let image = try #require(renderer.cgImage(at: 0, dimension: dimension))
        let painted = coverage(image)
        #expect(painted.pixels == dimension * dimension)
    }

    // MARK: - Motion actually happens

    @Test func drawOnGrowsOverTime() throws {
        let document = AnimatedPreviewDocuments.svgDrawOnSimple
        let renderer = AnimatedIconRenderer(document: document)
        let start = try #require(renderer.cgImage(at: 0, dimension: dimension))
        let middle = try #require(renderer.cgImage(at: 0.6, dimension: dimension))
        let end = try #require(renderer.cgImage(at: 1.2, dimension: dimension))

        let startCoverage = coverage(start).alpha
        let middleCoverage = coverage(middle).alpha
        let endCoverage = coverage(end).alpha

        // Measured after all three are rendered, deliberately: holding several frames and reading
        // them later is what an exporter does, and it is the access pattern that caught
        // `ImageRenderer` handing back a recycled buffer for the blank first frame.
        #expect(startCoverage == 0, "Frame zero of a draw-on should be blank")

        #expect(startCoverage < middleCoverage, "The stroke did not begin drawing")
        #expect(middleCoverage < endCoverage, "The stroke did not finish drawing")
    }

    @Test func staggeredDrawOnRevealsSubpathsInOrder() throws {
        let document = AnimatedPreviewDocuments.svgDrawOn
        let renderer = AnimatedIconRenderer(document: document)
        let samples = try [0.0, 0.8, 1.6, 2.4].map {
            coverage(try #require(renderer.cgImage(at: $0, dimension: dimension))).alpha
        }
        // Monotonically increasing: each stroke adds ink and nothing erases.
        for (earlier, later) in zip(samples, samples.dropFirst()) {
            #expect(earlier < later, "Coverage went backwards: \(samples)")
        }
    }

    @Test func differentTimesProduceDifferentFrames() throws {
        let renderer = AnimatedIconRenderer(document: AnimatedPreviewDocuments.composite)
        let first = try #require(renderer.cgImage(at: 0.2, dimension: dimension))
        let second = try #require(renderer.cgImage(at: 1.4, dimension: dimension))
        #expect(bytes(first) != bytes(second))
    }

    // MARK: - Determinism

    /// The exporter renders frames in a separate pass from the on-screen player. If the same
    /// document and time did not produce the same pixels, an exported GIF would not match the
    /// preview — and the particle field, which is hash-driven precisely to avoid that, is the part
    /// most likely to regress.
    @Test func renderingIsDeterministic() throws {
        let renderer = AnimatedIconRenderer(document: AnimatedPreviewDocuments.particles)
        let first = try #require(renderer.cgImage(at: 0.7, dimension: dimension))
        let second = try #require(renderer.cgImage(at: 0.7, dimension: dimension))
        #expect(bytes(first) == bytes(second))
    }

    @Test func rendersAtTheRequestedPixelSizeRegardlessOfDisplayScale() throws {
        let renderer = AnimatedIconRenderer(document: AnimatedPreviewDocuments.composite)
        for dimension in [32, 128, 512] {
            let image = try #require(renderer.cgImage(at: 0, dimension: dimension))
            #expect(image.width == dimension)
            #expect(image.height == dimension)
        }
    }

    @Test func rendersNonSquareCanvases() throws {
        let document = AnimatedPreviewDocuments.wideCanvas
        let renderer = AnimatedIconRenderer(document: document)
        let size = CGSize(width: 256, height: 96)
        let image = try #require(renderer.cgImage(at: 1, size: size))
        #expect(image.width == 256)
        #expect(image.height == 96)
        #expect(coverage(image).pixels > 0)
    }

    // MARK: - Frame budgets

    @Test func frameCountFollowsTheRenderedCycle() {
        let renderer = AnimatedIconRenderer(document: AnimatedPreviewDocuments.svgDrawOn)
        #expect(renderer.frameCount(fps: 30) == 90)

        var doubled = AnimatedPreviewDocuments.svgDrawOn
        doubled.speed = 2
        #expect(AnimatedIconRenderer(document: doubled).frameCount(fps: 30) == 45)

        var pingPong = AnimatedPreviewDocuments.svgDrawOn
        pingPong.loop = .pingPong
        #expect(AnimatedIconRenderer(document: pingPong).frameCount(fps: 30) == 180)
    }

    @Test func aStaticDocumentIsOneFrame() {
        let renderer = AnimatedIconRenderer(document: AnimatedPreviewDocuments.staticDocument)
        #expect(renderer.frameCount(fps: 30) == 1)
        #expect(renderer.frameTimes(fps: 30) == [0])
    }

    @Test func renderingAWholeCycleProducesEveryFrame() throws {
        var document = AnimatedPreviewDocuments.svgDrawOnSimple
        document.fps = 8
        let renderer = AnimatedIconRenderer(document: document)
        let frames = renderer.renderCycle(fps: 8, size: CGSize(width: 48, height: 48))
        #expect(frames.count == renderer.frameCount(fps: 8))
        #expect(frames.allSatisfy { $0.width == 48 })
    }

    // MARK: - Assets

    @Test func anImageLayerWithNoAssetStillDrawsItsPlaceholder() throws {
        let renderer = AnimatedIconRenderer(document: AnimatedPreviewDocuments.image, assets: EmptyAnimatedAssets())
        let image = try #require(renderer.cgImage(at: 1, dimension: dimension))
        #expect(coverage(image).pixels > 0)
    }

    @Test func anSVGLayerBackedByAMissingAssetRendersNothingRatherThanCrashing() throws {
        let document = AnimatedDocument(kind: .animated, layers: [
            .svg(.init(
                base: .init(id: "icon", name: "Icon"),
                source: .asset(assetId: AnimatedPreviewDocuments.imageAssetID)
            ))
        ])
        let image = try #require(AnimatedIconRenderer(document: document).cgImage(at: 0, dimension: 32))
        #expect(coverage(image).pixels == 0)
    }
}
