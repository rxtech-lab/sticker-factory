import CoreGraphics
import Foundation
import SwiftUI
import Testing
import UIKit
@testable import StickerGeniOS

/// The parts of the subject-lift pipeline that do not need a camera, a photo library, or Vision.
///
/// Deliberately covers the two things most likely to be wrong in a way nobody notices: the atlas's
/// shared crop rect, and the geometry that decides which segmented instance is "the same subject".
/// Both produce plausible-looking output when they are broken.
@MainActor
struct SubjectLiftTests {
    /// A frame with an opaque square at `rect` (normalized, top-left origin) on transparency.
    private func frame(subjectAt rect: CGRect, side: Int = 200) -> CGImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let image = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { context in
            UIColor.systemPink.setFill()
            context.fill(CGRect(
                x: rect.minX * CGFloat(side),
                y: rect.minY * CGFloat(side),
                width: rect.width * CGFloat(side),
                height: rect.height * CGFloat(side)
            ))
        }
        return image.cgImage!
    }

    // MARK: - Describing a cut-out

    @Test("An opaque region is described where it actually is")
    func describesBounds() throws {
        // UIKit draws top-left, and the descriptor reports top-left, so a square in the upper-left
        // quadrant has to come back in the upper-left quadrant. A y-flip bug here would put every
        // subject on the wrong half of the frame and quietly wreck the crop rect.
        let described = try #require(SubjectSegmenter.describe(frame(subjectAt: CGRect(x: 0.1, y: 0.1, width: 0.3, height: 0.3))))
        #expect(abs(described.bounds.minX - 0.1) < 0.05)
        #expect(abs(described.bounds.minY - 0.1) < 0.05)
        #expect(abs(described.centroid.x - 0.25) < 0.05)
        #expect(abs(described.centroid.y - 0.25) < 0.05)
        #expect(described.areaFraction > 0.05 && described.areaFraction < 0.15)
    }

    /// Orientation, asserted in both directions.
    ///
    /// A `CGBitmapContext` has a bottom-left user-space origin but top-left memory, and getting that
    /// backwards flips every subject to the wrong half of the frame while still producing perfectly
    /// plausible numbers — the crop rect just quietly frames the wrong region. One-sided tests miss
    /// it, so this pins a high subject as high and a low subject as low.
    @Test("Vertical position is not inverted")
    func describesVerticalPositionUpright() throws {
        let high = try #require(SubjectSegmenter.describe(frame(subjectAt: CGRect(x: 0.4, y: 0.05, width: 0.2, height: 0.2))))
        let low = try #require(SubjectSegmenter.describe(frame(subjectAt: CGRect(x: 0.4, y: 0.75, width: 0.2, height: 0.2))))
        #expect(high.centroid.y < 0.3, "a subject near the top must report a small y")
        #expect(low.centroid.y > 0.7, "a subject near the bottom must report a large y")
        #expect(high.centroid.y < low.centroid.y)
    }

    @Test("A fully transparent frame describes nothing")
    func describesNothingWhenEmpty() {
        #expect(SubjectSegmenter.describe(frame(subjectAt: .zero)) == nil)
    }

    // MARK: - Tracking geometry

    private func descriptor(_ rect: CGRect) -> SubjectAnchorDescriptor {
        .init(bounds: rect)
    }

    @Test("A subject that barely moved scores higher than one that did not move at all but is elsewhere")
    func scoresProximity() {
        let previous = descriptor(CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2))
        let nudged = descriptor(CGRect(x: 0.42, y: 0.4, width: 0.2, height: 0.2))
        let across = descriptor(CGRect(x: 0.05, y: 0.05, width: 0.2, height: 0.2))
        #expect(SubjectSegmenter.score(nudged, against: previous) > SubjectSegmenter.score(across, against: previous))
    }

    @Test("A candidate that swallowed the background scores below a nudge")
    func penalisesRunawayArea() {
        // The failure this guards: the mask leaks into the background, area explodes, and the
        // tracker follows it — after which every later frame is matched against the whole image.
        let previous = descriptor(CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2))
        let nudged = descriptor(CGRect(x: 0.42, y: 0.42, width: 0.2, height: 0.2))
        let bloated = descriptor(CGRect(x: 0.0, y: 0.0, width: 1.0, height: 1.0))
        #expect(SubjectSegmenter.score(nudged, against: previous) > SubjectSegmenter.score(bloated, against: previous))
    }

    @Test("An identical subject scores the maximum")
    func scoresIdentity() {
        let same = descriptor(CGRect(x: 0.3, y: 0.3, width: 0.3, height: 0.3))
        #expect(SubjectSegmenter.score(same, against: same) > 0.99)
    }

    @Test("Disjoint subjects have no overlap")
    func overlapIsZeroWhenDisjoint() {
        let a = CGRect(x: 0, y: 0, width: 0.2, height: 0.2)
        let b = CGRect(x: 0.8, y: 0.8, width: 0.2, height: 0.2)
        #expect(SubjectSegmenter.intersectionOverUnion(a, b) == 0)
        #expect(abs(SubjectSegmenter.intersectionOverUnion(a, a) - 1) < 0.0001)
    }

    // MARK: - Atlas encoding

    @Test("Frames pack into a grid that holds them")
    func packsAGrid() throws {
        let frames = (0..<12).map { index in
            frame(subjectAt: CGRect(x: 0.3 + Double(index) * 0.01, y: 0.3, width: 0.3, height: 0.3))
        }
        let encoded = try FrameAtlasEncoder.encode(frames: frames, settings: .default)
        #expect(encoded.metadata.frameCount == 12)
        #expect(encoded.metadata.columns * encoded.metadata.rows >= 12)
        #expect(encoded.metadata.columns <= 8 && encoded.metadata.rows <= 8)
        #expect(encoded.metadata.frameRate == SubjectLiftSettings.default.frameRate)

        let sheet = try #require(UIImage(data: encoded.data)?.cgImage)
        #expect(sheet.width == encoded.metadata.columns * SubjectLiftSettings.default.tilePixels)
        #expect(sheet.height == encoded.metadata.rows * SubjectLiftSettings.default.tilePixels)
    }

    @Test("The atlas keeps its transparency")
    func preservesAlpha() throws {
        let encoded = try FrameAtlasEncoder.encode(
            frames: [frame(subjectAt: CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2))],
            settings: .still
        )
        let sheet = try #require(UIImage(data: encoded.data)?.cgImage)
        let alpha = sheet.alphaInfo
        #expect([.first, .last, .premultipliedFirst, .premultipliedLast].contains(alpha))
        // A sprite sheet with no transparent pixels means the cut-out failed and the whole photo was
        // packed instead, which upload validation rejects — better to know here.
        #expect(SubjectSegmenter.describe(sheet) != nil)
    }

    /// The single most consequential detail in the encoder.
    ///
    /// Every frame must be cropped to *one* rect. Cropping each to its own subject bounds is the
    /// obvious implementation and it is wrong: the crop then tracks the subject, so the subject
    /// appears pinned in place while the background lurches around it. This asserts the opposite —
    /// that a subject moving across the source moves across its tiles too.
    @Test("Every tile shares one crop, so a moving subject moves within the frame")
    func usesOneCropForEveryFrame() throws {
        let frames = [
            frame(subjectAt: CGRect(x: 0.05, y: 0.4, width: 0.2, height: 0.2)),
            frame(subjectAt: CGRect(x: 0.40, y: 0.4, width: 0.2, height: 0.2)),
            frame(subjectAt: CGRect(x: 0.75, y: 0.4, width: 0.2, height: 0.2)),
        ]
        var settings = SubjectLiftSettings.default
        settings.frameCount = 3
        let encoded = try FrameAtlasEncoder.encode(frames: frames, settings: settings)
        let sheet = try #require(UIImage(data: encoded.data)?.cgImage)

        let tile = sheet.width / encoded.metadata.columns
        var centroids: [Double] = []
        for index in 0..<encoded.metadata.frameCount {
            let column = index % encoded.metadata.columns
            let row = index / encoded.metadata.columns
            let cropped = try #require(sheet.cropping(to: CGRect(
                x: column * tile,
                y: row * (sheet.height / encoded.metadata.rows),
                width: tile,
                height: sheet.height / encoded.metadata.rows
            )))
            centroids.append(try #require(SubjectSegmenter.describe(cropped)).centroid.x)
        }
        #expect(centroids.count == 3)
        // Strictly increasing: the subject travels left to right inside a fixed window. A per-frame
        // crop would centre it in every tile and collapse these to nearly the same value.
        #expect(centroids[0] < centroids[1])
        #expect(centroids[1] < centroids[2])
        #expect(centroids[2] - centroids[0] > 0.2)
    }

    @Test("Frames that failed to lift are dropped, not left as holes")
    func skipsMissingFrames() throws {
        let good = frame(subjectAt: CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2))
        var settings = SubjectLiftSettings.default
        settings.frameCount = 4
        let encoded = try FrameAtlasEncoder.encode(frames: [good, nil, good, nil], settings: settings)
        // Renumbered to a contiguous run: a transparent tile mid-loop reads as a broken render.
        #expect(encoded.metadata.frameCount == 2)
    }

    @Test("A lift that found nothing is an error, not an empty sticker")
    func refusesAnEmptyLift() {
        #expect(throws: MediaNormalizationError.self) {
            try FrameAtlasEncoder.encode(frames: [nil, nil], settings: .default)
        }
    }

    // MARK: - Stage sizing

    /// The bug this pins: a `UIViewRepresentable` wrapping `UIImageView` inherits the image's pixel
    /// size as its intrinsic size, so a camera photo asked for ~3000pt of width. Nothing looked
    /// wrong at the point of failure — the *siblings* broke, centred in a scroll canvas far wider
    /// than the screen with their text clipped off both edges.
    @Test(arguments: [
        CGSize(width: 4032, height: 3024),
        CGSize(width: 3024, height: 4032),
        CGSize(width: 1024, height: 1024),
        CGSize(width: 8000, height: 400),
    ])
    func stageNeverExceedsWhatItIsOffered(imageSize: CGSize) {
        let proposal = ProposedViewSize(width: 361, height: 340)
        let fitted = SubjectLiftView.fittedSize(imageSize: imageSize, proposal: proposal)
        #expect(fitted.width <= 361.5)
        #expect(fitted.height <= 340.5)
        #expect(fitted.width > 0 && fitted.height > 0)
    }

    @Test("The stage keeps the photo's aspect ratio")
    func stagePreservesAspect() {
        let fitted = SubjectLiftView.fittedSize(
            imageSize: CGSize(width: 4000, height: 2000),
            proposal: ProposedViewSize(width: 300, height: 340)
        )
        // Width binds first at 2:1, so the height follows from it rather than filling the box.
        #expect(abs(fitted.width - 300) < 0.5)
        #expect(abs(fitted.height - 150) < 0.5)
    }

    @Test("An unconstrained or degenerate proposal still produces a usable box")
    func stageHandlesOpenProposals() {
        let image = CGSize(width: 1000, height: 500)
        let unbounded = SubjectLiftView.fittedSize(imageSize: image, proposal: .unspecified)
        #expect(unbounded.width.isFinite && unbounded.height.isFinite)
        #expect(unbounded.width > 0 && unbounded.height > 0)

        let infinite = SubjectLiftView.fittedSize(
            imageSize: image,
            proposal: ProposedViewSize(width: .infinity, height: .infinity)
        )
        #expect(infinite.width.isFinite && infinite.height.isFinite)

        // A zero-size image must not divide by zero or return NaN.
        let empty = SubjectLiftView.fittedSize(imageSize: .zero, proposal: ProposedViewSize(width: 200, height: 100))
        #expect(empty.width == 200 && empty.height == 100)
    }

    // MARK: - Hit-testing a touch

    /// A detection wrapping a synthetic cut-out, so the choosing rule can be tested without Vision.
    private func detection(at rect: CGRect, isInstance: Bool = true) throws -> SubjectSegmenter.Detection {
        let cutout = frame(subjectAt: rect)
        return SubjectSegmenter.Detection(
            cutout: cutout,
            descriptor: try #require(SubjectSegmenter.describe(cutout)),
            hitMask: try #require(SubjectSegmenter.hitMask(cutout)),
            isInstance: isInstance
        )
    }

    @Test("The alpha map agrees with where the subject was drawn")
    func hitMaskFollowsAlpha() throws {
        let mask = try #require(SubjectSegmenter.hitMask(frame(subjectAt: CGRect(x: 0.1, y: 0.1, width: 0.3, height: 0.3))))
        #expect(mask.isOpaque(at: CGPoint(x: 0.25, y: 0.25)), "inside the subject")
        #expect(!mask.isOpaque(at: CGPoint(x: 0.8, y: 0.8)), "well outside it")
        // The same top-left orientation `describe` depends on. Flipped, this point would read as a
        // hit and every touch would select the subject's mirror image.
        #expect(!mask.isOpaque(at: CGPoint(x: 0.25, y: 0.85)), "mirrored below the subject")
        #expect(!mask.isOpaque(at: CGPoint(x: -0.5, y: 2)), "outside the image entirely")
    }

    /// The rule that makes nested subjects selectable.
    ///
    /// Vision offers each instance *and* their union, and the union's box contains every instance's
    /// box. Choosing by area alone, or by first match, means a touch anywhere always lands on the
    /// union and the user can never pick just the person.
    @Test("A touch picks the tightest subject under it")
    func hitTestPrefersTheSmallestMatch() throws {
        let person = try detection(at: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2))
        let everything = try detection(at: CGRect(x: 0.05, y: 0.05, width: 0.9, height: 0.9), isInstance: false)
        let ordered = [person, everything].sorted { $0.descriptor.areaFraction < $1.descriptor.areaFraction }

        let onPerson = try #require(SubjectSegmenter.subject(at: CGPoint(x: 0.2, y: 0.2), among: ordered))
        #expect(onPerson.id == person.id)

        // Outside the person but still inside the union: the union is the only correct answer.
        let onUnion = try #require(SubjectSegmenter.subject(at: CGPoint(x: 0.7, y: 0.7), among: ordered))
        #expect(onUnion.id == everything.id)
    }

    @Test("A touch on the background selects nothing")
    func hitTestMissesTheBackground() throws {
        let subject = try detection(at: CGRect(x: 0.05, y: 0.05, width: 0.15, height: 0.15))
        #expect(SubjectSegmenter.subject(at: CGPoint(x: 0.9, y: 0.9), among: [subject]) == nil)
    }

    /// A finger is far wider than the edge it is aiming at, so a near miss counts.
    @Test("A touch just off an edge still selects the subject")
    func hitTestForgivesANearMiss() throws {
        let subject = try detection(at: CGRect(x: 0.3, y: 0.3, width: 0.3, height: 0.3))
        #expect(SubjectSegmenter.subject(at: CGPoint(x: 0.295, y: 0.45), among: [subject]) != nil)
    }

    // MARK: - Settings

    @Test("The default grid holds the default frame count")
    func gridFitsFrames() {
        for settings in [SubjectLiftSettings.default, .smooth, .still] {
            let grid = settings.grid
            #expect(grid.columns * grid.rows >= settings.frameCount)
            #expect(grid.columns <= 8 && grid.rows <= 8)
        }
    }

    @Test("The default capture fits inside the document duration the contract allows")
    func captureFitsTheContract() {
        // Ping-pong doubles it, and an animated document tops out at 30s with plan timing capped at
        // 4s, so 1.2s of footage has to stay well inside both.
        #expect(SubjectLiftSettings.default.captureSeconds > 0)
        #expect(SubjectLiftSettings.default.captureSeconds <= 4)
        #expect(SubjectLiftSettings.smooth.captureSeconds <= 4)
    }
}
