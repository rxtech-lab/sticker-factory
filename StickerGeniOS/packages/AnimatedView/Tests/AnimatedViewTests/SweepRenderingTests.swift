import CoreGraphics
import Foundation
import Testing
@testable import AnimatedView

/// Rasterisation coverage for the wipe, sheen and glow channels.
///
/// These channels are the first ones whose whole point is compositing rather than transform, so
/// model-level tests cannot see whether they work: a wrong gradient axis, a blend that escapes its
/// group, or a mask SwiftUI silently ignores all compile and all interpolate correctly. These count
/// pixels through the same `ImageRenderer` path the exporter uses.
@MainActor
struct SweepRenderingTests {
    private let dimension = 96

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

    /// A plain filled square, which makes coverage arithmetic easy to reason about.
    /// The document runs longer than the specs on purpose. `cgImage(at:)` applies loop mapping, so
    /// sampling at exactly `durationSeconds` has already wrapped back to t=0 and reads as a blank
    /// frame — the same trap `RenderingTests.everyFixtureRendersVisiblePixels` documents. Every
    /// "finished" assertion below therefore samples inside the tail, after the spec has ended.
    private func square(_ specs: [AnimationSpec], duration: Double = 3) throws -> AnimatedDocument {
        try AnimatedDocument(
            kind: .animated,
            durationSeconds: duration,
            layers: [
                .shape(.init(
                    base: .init(id: "square", name: "Square", animations: specs),
                    shape: .roundedRectangle,
                    fill: .solid("#3366FF"),
                    cornerRadius: 0
                ))
            ]
        ).compiled()
    }

    private func image(_ document: AnimatedDocument, at time: Double) throws -> CGImage {
        try #require(AnimatedIconRenderer(document: document).cgImage(at: time, dimension: dimension))
    }

    // MARK: - Wipe

    @Test func aWipeInStartsHiddenAndEndsWhole() throws {
        let wiped = try square([.wipeIn(.right, duration: 2, easing: .linear)])
        let plain = try square([])

        #expect(coverage(try image(wiped, at: 0)).alpha == 0, "A wipeIn should show nothing at t=0")

        // The decisive assertion: a finished wipe must be indistinguishable from no wipe at all. If
        // the gradient axis stopped short of the corners this would differ by exactly the corners.
        #expect(
            bytes(try image(wiped, at: 2.5)) == bytes(try image(plain, at: 0)),
            "A finished wipe did not restore the layer exactly"
        )
    }

    @Test func aWipeRevealsMonotonically() throws {
        let document = try square([.wipeIn(.right, duration: 2, easing: .linear)])
        // Only up to the end of the spec: past it the layer is fully revealed and holds steady, so
        // demanding a strict increase there would be asserting the wipe never finishes.
        let sweeping = try [0.0, 0.5, 1.0, 1.5, 2.0].map { coverage(try image(document, at: $0)).alpha }
        for (earlier, later) in zip(sweeping, sweeping.dropFirst()) {
            #expect(earlier < later, "Coverage went backwards during a wipe: \(sweeping)")
        }
        let afterwards = coverage(try image(document, at: 2.5)).alpha
        #expect(afterwards == sweeping.last, "A finished wipe should hold, not keep changing")
    }

    /// The corner-coverage regression. `AnimatedPaint.unitPoint(forAngle:)` spans only the inscribed
    /// circle, so a 45° wipe driven by it leaves the two far corners masked out forever. This is the
    /// test that fails if `sweepUnitPoint` is ever swapped back for it.
    @Test func adiagonalWipeStillRevealsTheCorners() throws {
        let openEverywhere = try square([
            .init(.wipeTo(start: 0, end: 1, angleDegrees: 45, softness: 0), duration: 1, easing: .linear)
        ])
        let plain = try square([])
        #expect(
            bytes(try image(openEverywhere, at: 1.5)) == bytes(try image(plain, at: 0)),
            "A fully open 45° wipe clipped the corners — the sweep axis is not reaching them"
        )
    }

    @Test func aWipeHonoursItsDelay() throws {
        // The interpolator clamps before the first keyframe, so a delayed wipe must hide the layer
        // from t=0 rather than showing it until the wipe starts. This is what makes a staggered
        // entrance look right.
        let document = try square([.wipeIn(.right, delay: 1, duration: 1, easing: .linear)])
        #expect(coverage(try image(document, at: 0)).alpha == 0)
        #expect(coverage(try image(document, at: 0.9)).alpha == 0)
        #expect(coverage(try image(document, at: 2.5)).alpha > 0)
    }

    @Test func oppositeWipeDirectionsUncoverOppositeHalves() throws {
        let rightward = try square([.wipeIn(.right, duration: 2, easing: .linear)])
        let leftward = try square([.wipeIn(.left, duration: 2, easing: .linear)])
        // Half way through, both show about half the square — but different halves.
        let a = try image(rightward, at: 1)
        let b = try image(leftward, at: 1)
        #expect(abs(coverage(a).alpha - coverage(b).alpha) < coverage(a).alpha * 0.1, "Both halves should be similar in area")
        #expect(bytes(a) != bytes(b), "Opposite wipe directions produced identical frames")
    }

    // MARK: - Sheen

    @Test func aShineBrightensTheArtworkWithoutSpillingOutsideIt() throws {
        let shone = try square([.shine(width: 0.4, intensity: 1, duration: 2)])
        let plain = try square([])

        let mid = try image(shone, at: 1)
        let plainImage = try image(plain, at: 0)
        #expect(bytes(mid) != bytes(plainImage), "The shine did not change any pixels")

        // `sourceAtop` must clip the highlight to the artwork, so the alpha channel is untouched:
        // the band brightens the square without lighting up the transparent space around it.
        #expect(
            abs(coverage(mid).alpha - coverage(plainImage).alpha) < 1,
            "The shine leaked outside the layer's silhouette — the blend escaped its group"
        )
    }

    @Test func aShineIsInvisibleAtBothEndsOfItsSweep() throws {
        let shone = try square([.shine(width: 0.3, intensity: 1, duration: 2)])
        let plain = try square([])
        let plainBytes = bytes(try image(plain, at: 0))
        // At t=0 and t=duration the band sits fully off-canvas at zero intensity, so the frame has
        // to be pixel-identical to the un-shone layer.
        #expect(bytes(try image(shone, at: 0)) == plainBytes)
        #expect(bytes(try image(shone, at: 2.5)) == plainBytes)
    }

    // MARK: - Glow

    @Test func aBloomAddsLightAroundTheArtwork() throws {
        let bloomed = try square([.bloomIn(radius: 0.1, intensity: 1, duration: 2)])
        let plain = try square([])

        let lit = try image(bloomed, at: 2.5)
        let plainImage = try image(plain, at: 0)
        #expect(bytes(lit) != bytes(plainImage), "The bloom did not change any pixels")
        // Unlike the sheen, a halo is *supposed* to extend past the silhouette, so total alpha grows.
        #expect(
            coverage(lit).alpha > coverage(plainImage).alpha,
            "A bloom should spread light beyond the layer, raising total alpha"
        )
    }

    @Test func aBloomPulseReturnsToDark() throws {
        let document = try square([.bloomPulse(radius: 0.1, intensity: 1, cycles: 1, duration: 2)])
        let plain = try square([])
        let plainBytes = bytes(try image(plain, at: 0))
        #expect(bytes(try image(document, at: 0)) == plainBytes, "A bloomPulse should start dark")
        #expect(bytes(try image(document, at: 1)) != plainBytes, "A bloomPulse should peak mid-cycle")
        #expect(bytes(try image(document, at: 2.5)) == plainBytes, "A bloomPulse should end dark")
    }

    // MARK: - Composition and determinism

    @Test func allThreeChannelsComposeOnOneLayer() throws {
        // The pairing that motivated three separate channels: on one channel this would not compile.
        let document = try square([
            .wipeIn(.right, softness: 0.1, duration: 2, easing: .linear),
            .shine(width: 0.3, intensity: 0.8, duration: 2),
            .bloomIn(radius: 0.08, intensity: 0.6, duration: 2)
        ])
        #expect(coverage(try image(document, at: 0)).alpha == 0)
        #expect(coverage(try image(document, at: 2.5)).alpha > 0)
    }

    /// The exporter renders in a separate pass from the player, and these effects add offscreen
    /// compositing to that path. If it were not deterministic an exported GIF would not match.
    @Test func sweepsRenderDeterministically() throws {
        let document = try square([
            .wipeIn(.down, softness: 0.2, duration: 2, easing: .linear),
            .shine(width: 0.3, intensity: 0.9, duration: 2)
        ])
        #expect(bytes(try image(document, at: 1.3)) == bytes(try image(document, at: 1.3)))
    }

    /// A layer with none of the three must take the untouched path, byte for byte — the guard that
    /// keeps every existing document off the offscreen-compositing route.
    @Test func aLayerWithNoSweepsIsUnaffected() throws {
        let withEmptyChannels = try square([.fadeIn(duration: 1)])
        let first = bytes(try image(withEmptyChannels, at: 1))
        #expect(!first.isEmpty)
        #expect(first == bytes(try image(withEmptyChannels, at: 1)))
    }
}
