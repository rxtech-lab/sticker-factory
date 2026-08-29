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
        frame(subjectsAt: [rect], side: side)
    }

    /// The same, with more than one region — for asserting an asymmetry a single square cannot show.
    private func frame(subjectsAt rects: [CGRect], side: Int = 200) -> CGImage {
        frame(subjectsAt: rects, size: CGSize(width: side, height: side))
    }

    /// The same again on an arbitrary canvas. Camera footage is never square, and a square fixture
    /// cannot show an aspect-ratio bug at all — every ratio is 1.
    private func frame(subjectsAt rects: [CGRect], size: CGSize) -> CGImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.systemPink.setFill()
            for rect in rects {
                context.fill(CGRect(
                    x: rect.minX * size.width,
                    y: rect.minY * size.height,
                    width: rect.width * size.width,
                    height: rect.height * size.height
                ))
            }
        }
        return image.cgImage!
    }

    /// A tile-sized cut-out with one opaque region, in pixels rather than normalized units — which
    /// is the frame of reference `StickerOutline` works in.
    private func tile(side: Int, square: CGRect) -> CGImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let image = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { context in
            UIColor.systemPink.setFill()
            context.fill(square)
        }
        return image.cgImage!
    }

    /// Raw premultiplied RGBA, so a test can assert on a colour and not only on a shape.
    ///
    /// Same shape as `SubjectSegmenter.hitMask`: copy-blended from a zeroed buffer, so transparent
    /// really reads as zero rather than as whatever the context was last used for.
    private func rgba(of image: CGImage) -> [UInt8] {
        let width = image.width
        let height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        bytes.withUnsafeMutableBytes { buffer in
            let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
            context?.setBlendMode(.copy)
            context?.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return bytes
    }

    private func pixel(_ bytes: [UInt8], x: Int, y: Int, width: Int) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        let index = (y * width + x) * 4
        return (bytes[index], bytes[index + 1], bytes[index + 2], bytes[index + 3])
    }

    /// Whether any fully opaque pixel is white — the rim's colour, which the systemPink fixtures
    /// cannot produce on their own.
    private func containsWhite(_ image: CGImage) -> Bool {
        let bytes = rgba(of: image)
        for index in stride(from: 0, to: bytes.count, by: 4) where bytes[index + 3] == 255 {
            if bytes[index] > 250, bytes[index + 1] > 250, bytes[index + 2] > 250 { return true }
        }
        return false
    }

    /// One grid cell of an encoded sheet.
    private func cell(of sheet: CGImage, index: Int, metadata: SequenceMetadata) -> CGImage? {
        let width = sheet.width / metadata.columns
        let height = sheet.height / metadata.rows
        return sheet.cropping(to: CGRect(
            x: (index % metadata.columns) * width,
            y: (index / metadata.columns) * height,
            width: width,
            height: height
        ))
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

    /// The other way the encoder can be silently wrong: right crop, wrong way up.
    ///
    /// `UIGraphicsImageRenderer` hands out a UIKit context — origin top-left, y increasing down —
    /// and `CGContext.draw(_:in:)` places an image bottom-up in *user* space, so drawing a frame
    /// through the raw context mirrors every tile vertically. Nothing else notices: the atlas is
    /// still the right size, still transparent, and the subject still moves left to right, so every
    /// other test here passes while the sticker plays upside down.
    ///
    /// A single square cannot catch it — it is symmetric, and the shared crop centres it. This uses
    /// a heavy block near the top and a light one near the bottom, which puts the alpha-weighted
    /// centroid well above the middle of the crop and keeps it there only if the tile is upright.
    @Test("A tile is packed the same way up as the frame it came from")
    func packsTilesUpright() throws {
        let source = frame(subjectsAt: [
            CGRect(x: 0.30, y: 0.10, width: 0.4, height: 0.2),
            CGRect(x: 0.45, y: 0.70, width: 0.1, height: 0.1),
        ])
        #expect(try #require(SubjectSegmenter.describe(source)).centroid.y < 0.4)

        let encoded = try FrameAtlasEncoder.encode(frames: [source], settings: .still)
        let sheet = try #require(UIImage(data: encoded.data)?.cgImage)
        let described = try #require(SubjectSegmenter.describe(sheet))
        #expect(described.centroid.y < 0.45, "the tile is mirrored vertically against its source frame")
    }

    /// The bug every animated sticker cut from a Live Photo shipped with.
    ///
    /// The crop is squared so one grid cell is one frame with no aspect correction — but squaring a
    /// padded, selfie-framed subject on portrait footage produces a rect wider than the photo, and
    /// clamping it back inside the frame un-squares it. The tile then stretched a tall crop into a
    /// square cell and the subject played ~30% too wide. Only a non-square *source* can show it: on
    /// the square fixtures the rest of this suite uses, every ratio is 1 either way.
    @Test("A subject keeps its proportions when the crop runs off the edge of the frame")
    func preservesAspectWhenCropOverflowsTheFrame() throws {
        // Tall and narrow, and tall enough that padding pushes the squared crop past both sides.
        let subject = CGRect(x: 0.3, y: 0.05, width: 0.4, height: 0.9)
        let size = CGSize(width: 200, height: 300)
        let expected = (subject.width * size.width) / (subject.height * size.height)

        // The rim is switched off deliberately: this test pins the crop's geometry, and a rim adds
        // the same absolute thickness to both axes, which pulls a narrow subject's measured ratio
        // toward 1 — to 0.353 here, past the tolerance that separates a true 0.30 from the 0.44 the
        // stretch bug produced. Widening the tolerance would give the bug room to come back.
        var settings = SubjectLiftSettings.still
        settings.outlineFraction = 0
        let encoded = try FrameAtlasEncoder.encode(
            frames: [frame(subjectsAt: [subject], size: size)],
            settings: settings
        )
        let sheet = try #require(UIImage(data: encoded.data)?.cgImage)
        #expect(sheet.width == sheet.height, "one tile, so the sheet is the tile")

        // The tile is square, so normalized bounds are pixel proportions.
        let bounds = try #require(SubjectSegmenter.describe(sheet)).bounds
        let actual = bounds.width / bounds.height
        // Stretching to fill reports ~0.44 here against a true 0.30, so the tolerance separates the
        // two comfortably while absorbing `describe`'s sampling stride.
        #expect(abs(actual - expected) < 0.05, "subject is \(actual) wide per tall, expected \(expected)")
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

    // MARK: - The die-cut rim

    @Test("A rim grows the silhouette by its own width")
    func aRimGrowsTheSilhouetteByItsWidth() throws {
        let source = tile(side: 200, square: CGRect(x: 60, y: 60, width: 80, height: 80))
        let rim = try #require(StickerOutline.rim(for: source, widthPixels: 10))
        let bounds = try #require(SubjectSegmenter.describe(rim)).bounds
        // 80 + 2 × 10 in a 200px tile. `widthPixels` is a disc *radius*, and a disc grows a shape by
        // exactly its radius in every direction — so the parameter is the visible thickness, with no
        // factor of two hiding at the call site. This is the test that catches that confusion.
        #expect(abs(bounds.width * 200 - 100) < 8, "rim spans \(bounds.width * 200)px, expected 100")
        #expect(abs(bounds.height * 200 - 100) < 8)
    }

    /// The one that catches a colour matrix applied in unpremultiplied space.
    ///
    /// `CIColorMatrix` and the rest of the colour category operate on unpremultiplied values and
    /// re-premultiply on output, so the obvious "set RGB to alpha" formulation yields (a², a², a², a)
    /// — white in the middle, ringed by a gamma-squared grey fringe that reads as a dark halo
    /// against a light Messages bubble. Premultiplied white has every channel equal to alpha at
    /// every level of coverage, which is what this asserts.
    @Test("A rim is premultiplied white at every level of coverage")
    func aRimIsPremultipliedWhite() throws {
        // Fractional edges so UIKit antialiases the fill, which guarantees the partial coverage
        // this test needs something to say about.
        let source = tile(side: 200, square: CGRect(x: 60.5, y: 60.5, width: 79, height: 79))
        let rim = try #require(StickerOutline.rim(for: source, widthPixels: 12))
        let bytes = rgba(of: rim)

        let solid = pixel(bytes, x: 54, y: 100, width: 200)
        #expect(solid.a == 255)
        #expect(solid.r == 255 && solid.g == 255 && solid.b == 255, "solid rim pixel is \(solid)")

        var partials = 0
        for index in stride(from: 0, to: bytes.count, by: 4) {
            let alpha = bytes[index + 3]
            guard alpha > 0, alpha < 255 else { continue }
            partials += 1
            #expect(
                bytes[index] == alpha && bytes[index + 1] == alpha && bytes[index + 2] == alpha,
                "partially covered rim pixel is not premultiplied white"
            )
        }
        #expect(partials > 0, "no partially covered pixels, so this test proved nothing")
    }

    @Test("A rim never leaves the tile it was built from")
    func aRimNeverLeavesItsTile() throws {
        // Flush against the right edge, where the dilation has nowhere to go. This is the property
        // the whole per-cell design exists for: the rim of a subject at a cell border must stop at
        // that border rather than grow into the next frame.
        let source = tile(side: 200, square: CGRect(x: 150, y: 60, width: 50, height: 80))
        let rim = try #require(StickerOutline.rim(for: source, widthPixels: 12))
        #expect(rim.width == 200 && rim.height == 200, "the rim changed its tile's dimensions")
        #expect(pixel(rgba(of: rim), x: 199, y: 100, width: 200).a == 255, "the rim stopped short of the edge")
    }

    @Test("A rim thinner than the antialiasing that would draw it is not drawn")
    func aSubPixelRimIsSkipped() {
        let source = tile(side: 100, square: CGRect(x: 30, y: 30, width: 40, height: 40))
        #expect(StickerOutline.rim(for: source, widthPixels: 0.4) == nil)
    }

    /// The most likely way the encoder's second pass goes wrong, and one a whole-sheet assertion
    /// cannot see: a sheet with only its first cell outlined still contains white.
    @Test("Every tile gets a rim, not just the first")
    func outlinesEveryTile() throws {
        let frames = [
            frame(subjectAt: CGRect(x: 0.05, y: 0.4, width: 0.2, height: 0.2)),
            frame(subjectAt: CGRect(x: 0.40, y: 0.4, width: 0.2, height: 0.2)),
            frame(subjectAt: CGRect(x: 0.75, y: 0.4, width: 0.2, height: 0.2)),
        ]
        var settings = SubjectLiftSettings.default
        settings.frameCount = 3
        var bare = settings
        bare.outlineFraction = 0

        let outlined = try FrameAtlasEncoder.encode(frames: frames, settings: settings)
        let plain = try FrameAtlasEncoder.encode(frames: frames, settings: bare)
        let outlinedSheet = try #require(UIImage(data: outlined.data)?.cgImage)
        let plainSheet = try #require(UIImage(data: plain.data)?.cgImage)

        for index in 0..<outlined.metadata.frameCount {
            #expect(containsWhite(try #require(cell(of: outlinedSheet, index: index, metadata: outlined.metadata))), "tile \(index) has no rim")
            #expect(!containsWhite(try #require(cell(of: plainSheet, index: index, metadata: plain.metadata))), "tile \(index) has a rim it was not asked for")
        }
    }

    /// The direct test of the crop window's expansion.
    ///
    /// The window is opened by exactly the rim's own width on each side, so the outermost ring of a
    /// tile stays transparent. Take that expansion away — or compute it as a flat fraction of the
    /// un-expanded side, which comes up a few per cent short — and the rim runs into the tile edge
    /// and flattens against it on whichever side the subject sat nearest.
    @Test("The rim has room, and does not clip against the tile's edge")
    func theRimDoesNotClipAtTheTileEdge() throws {
        let encoded = try FrameAtlasEncoder.encode(
            frames: [frame(subjectAt: CGRect(x: 0.35, y: 0.35, width: 0.3, height: 0.3))],
            settings: .still
        )
        let sheet = try #require(UIImage(data: encoded.data)?.cgImage)
        #expect(containsWhite(sheet), "nothing was outlined, so the border below proves nothing")

        let bytes = rgba(of: sheet)
        var opaqueOnBorder = 0
        for x in 0..<sheet.width {
            if pixel(bytes, x: x, y: 0, width: sheet.width).a > 0 { opaqueOnBorder += 1 }
            if pixel(bytes, x: x, y: sheet.height - 1, width: sheet.width).a > 0 { opaqueOnBorder += 1 }
        }
        for y in 0..<sheet.height {
            if pixel(bytes, x: 0, y: y, width: sheet.width).a > 0 { opaqueOnBorder += 1 }
            if pixel(bytes, x: sheet.width - 1, y: y, width: sheet.width).a > 0 { opaqueOnBorder += 1 }
        }
        #expect(opaqueOnBorder == 0, "\(opaqueOnBorder) border pixels are painted, so the rim is clipping")
    }

    /// `packsTilesUpright` guards the subject sheet, and it passes on a vertically flipped *rim* —
    /// its centroid lands at 0.409 against a 0.45 bar. The rim makes a second round trip through
    /// Core Image and back, which is a second chance to pick up a flip, so it gets its own bar.
    @Test("The rim lands on the subject, not on its mirror image")
    func theRimIsNotVerticallyMirrored() throws {
        let source = frame(subjectsAt: [
            CGRect(x: 0.30, y: 0.10, width: 0.4, height: 0.2),
            CGRect(x: 0.45, y: 0.70, width: 0.1, height: 0.1),
        ])
        let encoded = try FrameAtlasEncoder.encode(frames: [source], settings: .still)
        let sheet = try #require(UIImage(data: encoded.data)?.cgImage)
        let bytes = rgba(of: sheet)

        // The big block is near the top, so most of the rim's perimeter is too.
        var top = 0
        var bottom = 0
        for y in 0..<sheet.height {
            for x in 0..<sheet.width {
                let sample = pixel(bytes, x: x, y: y, width: sheet.width)
                guard sample.a == 255, sample.r > 250, sample.g > 250, sample.b > 250 else { continue }
                if y < sheet.height / 2 { top += 1 } else { bottom += 1 }
            }
        }
        #expect(top > 0 && bottom > 0, "both blocks should be outlined")
        #expect(top > bottom * 2, "the rim is heavier at the bottom (\(top) vs \(bottom)), so it is mirrored")
    }

    /// A preset that quietly lost the rim would surface only as "my photos have a border and my
    /// Live Photos don't", which is a long way from the line that caused it.
    @Test("A still lift is outlined too")
    func aStillIsOutlinedToo() throws {
        let encoded = try FrameAtlasEncoder.encode(
            frames: [frame(subjectAt: CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2))],
            settings: .still
        )
        #expect(containsWhite(try #require(UIImage(data: encoded.data)?.cgImage)))
    }

    @Test("Turning the rim off leaves the encoder exactly as it was")
    func aZeroOutlineIsTheOldEncoder() throws {
        var settings = SubjectLiftSettings.still
        settings.outlineFraction = 0
        let encoded = try FrameAtlasEncoder.encode(
            frames: [frame(subjectAt: CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2))],
            settings: settings
        )
        let sheet = try #require(UIImage(data: encoded.data)?.cgImage)
        #expect(!containsWhite(sheet))
        // The pre-rim window: the subject padded 8% per axis and squared, so it spans 1/1.16 of the
        // tile. If the expansion leaked into the disabled path this would come back smaller.
        let bounds = try #require(SubjectSegmenter.describe(sheet)).bounds
        #expect(abs(bounds.width - 1 / 1.16) < 0.05, "the window moved with the rim switched off")
    }

    @Test("Every preset's rim survives the clamp the crop window applies")
    func theRimIsNeverSilentlyClamped() {
        #expect(FrameAtlasEncoder.outlineMargin(.default) > 0)
        // The crop window and the dilation both go through `outlineMargin`, so a preset outside its
        // range would make the window reserve one width and the rim draw another — which clips on
        // every side, and looks nothing like a clamp.
        for preset in [SubjectLiftSettings.default, .smooth, .still] {
            #expect(preset.outlineFraction == FrameAtlasEncoder.outlineMargin(preset))
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
