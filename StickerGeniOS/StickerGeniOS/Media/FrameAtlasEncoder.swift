import CoreGraphics
import Foundation
import UIKit

/// Packs lifted frames into the single transparent PNG the server and renderer both expect.
///
/// The atlas is a sprite sheet: an R×C grid of equally sized square tiles, read row-major from the
/// top-left. One still image, which is what lets it travel through every existing path — upload
/// validation, R2, sharp, the AI's reference loader — without anything learning a new format. The
/// renderer slices it back apart with `CGImage.cropping(to:)`, which costs nothing.
@MainActor
enum FrameAtlasEncoder {
    /// A packed atlas and the metadata that describes how to read it.
    struct Encoded {
        var data: Data
        var metadata: SequenceMetadata
    }

    /// Tile sizes to try, largest first, before giving up on fitting under the upload ceiling.
    private static let tileLadder = [640, 512, 384]
    /// Comfortably under the 25 MB upload cap, with room for the base64 the AI path adds.
    private static let byteBudget = 20 * 1024 * 1024

    /// Playback derivatives preserve the entire registered frame, without subject recropping.
    static func encodePlayback(frames: [CGImage], frameRate: Double) throws -> Encoded {
        guard let first = frames.first, frames.count <= 64 else { throw MediaNormalizationError.liftProducedNoSubject }
        let columns = min(8, max(1, Int(Double(frames.count).squareRoot().rounded(.up))))
        let rows = Int(ceil(Double(frames.count) / Double(columns)))
        let side = CGFloat(max(first.width, first.height))
        let crop = CGRect(x: (CGFloat(first.width) - side) / 2, y: (CGFloat(first.height) - side) / 2, width: side, height: side)
        for tile in tileLadder {
            let data = try draw(frames, crop: crop, columns: columns, rows: rows, tile: tile, outlinePixels: 0)
            if data.count <= byteBudget {
                return .init(data: data, metadata: .init(columns: columns, rows: rows, frameCount: frames.count, frameRate: frameRate))
            }
        }
        throw MediaNormalizationError.imageTooLarge
    }

    /// Packs `frames` into an atlas.
    ///
    /// Frames that failed to lift are dropped and the remainder renumbered, so a sequence is always
    /// contiguous — a transparent tile in the middle of a loop reads as a broken render, whereas a
    /// slightly shorter loop reads as nothing at all.
    static func encode(frames: [CGImage?], settings: SubjectLiftSettings) throws -> Encoded {
        let usable = frames.compactMap { $0 }
        guard !usable.isEmpty else { throw MediaNormalizationError.liftProducedNoSubject }

        let crop = sharedCropRect(for: usable, settings: settings)
        let count = min(usable.count, 64)
        let frames = Array(usable.prefix(count))
        let columns = min(8, max(1, Int(Double(count).squareRoot().rounded(.up))))
        let rows = min(8, max(1, Int((Double(count) / Double(columns)).rounded(.up))))
        guard count <= columns * rows else { throw MediaNormalizationError.liftProducedNoSubject }

        for tile in tileLadder {
            let data = try draw(
                frames,
                crop: crop,
                columns: columns,
                rows: rows,
                tile: tile,
                outlinePixels: Double(tile) * outlineMargin(settings)
            )
            if data.count <= byteBudget || tile == tileLadder.last {
                guard data.count <= 25 * 1024 * 1024 else { throw MediaNormalizationError.imageTooLarge }
                return .init(
                    data: data,
                    metadata: .init(
                        columns: columns,
                        rows: rows,
                        frameCount: count,
                        frameRate: count > 1 ? settings.frameRate : 1
                    )
                )
            }
        }
        throw MediaNormalizationError.imageTooLarge
    }

    /// The one rectangle, in source-image pixels, that every frame is cropped to.
    ///
    /// This is the detail that decides whether the result looks like motion or like a bug. Cropping
    /// each frame to its *own* subject bounds is the obvious implementation, and it makes the
    /// subject jump and change size every single frame, because the crop tracks the subject instead
    /// of the subject moving within the crop. So: take the union of every frame's opaque bounds,
    /// pad it, square it, and use that one rect for all of them. The subject then moves inside a
    /// fixed window, which is what a Live Photo actually looks like.
    ///
    /// **The returned rect is always square and may extend outside the frame.** Clamping it to the
    /// frame instead is the obvious move and it is the bug: a padded selfie-framed subject on
    /// portrait footage squares to a rect wider than the photo, so clipping hands `draw` a *tall*
    /// rect that it then stretches into a square tile — the whole sticker plays ~30% too wide.
    /// Overhang is not data to be recovered by reshaping the window; it is empty space, and `draw`
    /// renders it as the transparency it is.
    private static func sharedCropRect(for frames: [CGImage], settings: SubjectLiftSettings) -> CGRect {
        let size = CGSize(width: frames[0].width, height: frames[0].height)
        var union: CGRect?
        for frame in frames {
            guard let descriptor = SubjectSegmenter.describe(frame) else { continue }
            // Straight back into pixels: `describe` reports top-left normalized coordinates and
            // `CGImage.cropping(to:)` takes top-left pixel coordinates, so the two already agree.
            let rect = CGRect(
                x: descriptor.bounds.minX * size.width,
                y: descriptor.bounds.minY * size.height,
                width: descriptor.bounds.width * size.width,
                height: descriptor.bounds.height * size.height
            )
            union = union.map { $0.union(rect) } ?? rect
        }
        return window(around: union, in: size, settings: settings)
    }

    /// Breathing room around the subject before the window is squared. Kept separate from the rim's
    /// margin: this one is applied per axis to the un-squared union, so folding the two together
    /// would make the rim's apparent thickness depend on the subject's aspect ratio.
    private static let subjectPadFraction: CGFloat = 0.08

    /// The rim's width as a fraction of a tile, clamped once.
    ///
    /// One function, called by both the window and the draw, because a rim dilated wider than the
    /// window left room for clips flat on every side — and nobody would trace that back to two
    /// copies of a clamp expression drifting apart.
    static func outlineMargin(_ settings: SubjectLiftSettings) -> Double {
        min(max(settings.outlineFraction, 0), 0.15)
    }

    /// The square source-pixel window a subject is cropped to.
    ///
    /// Shared with the lift preview so the rim the user is shown is the rim they get: the encoder
    /// passes the union of every frame's opaque bounds, the preview passes the single frame it is
    /// displaying. A nil subject falls back to the whole frame, squared the same way, so even the
    /// no-subject path keeps the footage's proportions rather than squashing it into the tile.
    static func window(around subject: CGRect?, in frame: CGSize, settings: SubjectLiftSettings) -> CGRect {
        var rect = CGRect(origin: .zero, size: frame)
        if let subject, subject.width > 1, subject.height > 1 {
            rect = subject.insetBy(
                dx: -subject.width * subjectPadFraction,
                dy: -subject.height * subjectPadFraction
            )
        }
        // Squared around its own centre so tiles are square, which is what lets the renderer and the
        // server's SVG viewport treat one grid cell as one frame with no aspect correction.
        let squared = max(rect.width, rect.height)
        // Then opened up by exactly the rim's own width on each side. The width is a fraction of the
        // *final* tile, so the side and the margin are mutually dependent — side = squared + 2·side·m
        // — and the answer is that ratio's fixed point. Padding by a flat fraction of the un-expanded
        // side instead leaves the rim a few per cent short of its room, which clips it on whichever
        // edge the subject sits nearest and on that edge alone.
        //
        // This grows the overhang and never reshapes the rect, so the never-clamp rule above is
        // untouched: the expansion is uniform and centred, which is exactly the two properties that
        // comment defends. Transparent margin is what the rim needs to grow into.
        let side = squared / (1 - 2 * CGFloat(outlineMargin(settings)))
        return CGRect(x: rect.midX - side / 2, y: rect.midY - side / 2, width: side, height: side)
    }

    /// One grid cell, in the sheet's top-left pixel coordinates.
    private static func cellRect(_ index: Int, columns: Int, tile: Int) -> CGRect {
        CGRect(
            x: CGFloat((index % columns) * tile),
            y: CGFloat((index / columns) * tile),
            width: CGFloat(tile),
            height: CGFloat(tile)
        )
    }

    private static func draw(
        _ frames: [CGImage],
        crop: CGRect,
        columns: Int,
        rows: Int,
        tile: Int,
        outlinePixels: Double
    ) throws -> Data {
        let sheet = CGSize(width: CGFloat(tile * columns), height: CGFloat(tile * rows))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        // The crop is square but may hang off the edge of the frame, so each tile is drawn at the
        // sub-rect the readable part maps to and the overhang is left as the transparency it is.
        // Scaling the readable part to fill the tile instead is what distorted every sticker cut
        // from portrait footage: same pixels, wrong proportions, and no way to tell downstream.
        let scale = CGFloat(tile) / max(crop.width, 1)
        let image = UIGraphicsImageRenderer(size: sheet, format: format).image { _ in
            for (index, frame) in frames.enumerated() {
                let bounds = CGRect(x: 0, y: 0, width: frame.width, height: frame.height)
                let visible = crop.intersection(bounds).integral
                guard !visible.isNull, visible.width >= 1, visible.height >= 1,
                      let cropped = frame.cropping(to: visible) else { continue }
                let column = index % columns
                let row = index / columns
                let destination = CGRect(
                    x: CGFloat(column * tile) + (visible.minX - crop.minX) * scale,
                    y: CGFloat(row * tile) + (visible.minY - crop.minY) * scale,
                    width: visible.width * scale,
                    height: visible.height * scale
                )
                // Drawn as a `UIImage`, never with `CGContext.draw(_:in:)`. The renderer's context is
                // UIKit's — origin top-left, y increasing down — and CoreGraphics places an image
                // bottom-up in user space, so the raw call mirrors every tile vertically. Nothing
                // downstream can tell: the atlas is the right size, the alpha survives, the subject
                // still travels the way it did. The sticker simply plays upside down.
                //
                // `.copy` so alpha is written verbatim rather than composited over the (transparent
                // but still blended) backdrop — the same reason `MediaNormalizer.hasEditableAlpha`
                // sets it. Passed per draw because `UIImage.draw` does not read the context's mode.
                UIImage(cgImage: cropped).draw(in: destination, blendMode: .copy, alpha: 1)
            }
        }
        guard outlinePixels >= 1, let subjects = image.cgImage else {
            guard let data = image.pngData() else { throw MediaNormalizationError.unreadableImage }
            return data
        }
        return try outline(
            subjects,
            sheet: sheet,
            format: format,
            count: frames.count,
            columns: columns,
            tile: tile,
            width: outlinePixels
        )
    }

    /// Lays the white die-cut rim under every subject on an already-packed sheet.
    ///
    /// Three things make this a separate pass over the finished sheet rather than something folded
    /// into the draw above. The rim is built from *one cell at a time*, which is what stops a
    /// subject flush against a cell border from growing white into its neighbour. The subject's own
    /// pixels are never handed to Core Image, so no photographic colour makes a round trip through
    /// a null working colour space. And the packing above — with its two load-bearing rules about
    /// `UIImage.draw` and `.copy` — is left exactly as it was, so the test that pins tiles upright
    /// still pins the same code.
    private static func outline(
        _ subjects: CGImage,
        sheet: CGSize,
        format: UIGraphicsImageRendererFormat,
        count: Int,
        columns: Int,
        tile: Int,
        width: Double
    ) throws -> Data {
        var rims = [Int: CGImage]()
        for index in 0..<count {
            autoreleasepool {
                guard let cell = subjects.cropping(to: cellRect(index, columns: columns, tile: tile)) else { return }
                // A cell whose crop fell entirely outside its frame is transparent, and the rim of
                // nothing is nothing. Skipping it here saves a Core Image pass per empty cell.
                guard StickerPosterFrame.opaqueCoverage(of: cell) > 0 else { return }
                rims[index] = StickerOutline.rim(for: cell, widthPixels: width)
            }
        }
        guard !rims.isEmpty else {
            guard let data = UIImage(cgImage: subjects).pngData() else {
                throw MediaNormalizationError.unreadableImage
            }
            return data
        }

        let image = UIGraphicsImageRenderer(size: sheet, format: format).image { _ in
            for index in 0..<count {
                let destination = cellRect(index, columns: columns, tile: tile)
                guard let cell = subjects.cropping(to: destination) else { continue }
                guard let rim = rims[index] else {
                    UIImage(cgImage: cell).draw(in: destination, blendMode: .copy, alpha: 1)
                    continue
                }
                // `.copy` for the rim, then `.normal` — CoreGraphics' spelling of source-over — for
                // the subject. The rim is written verbatim over a cell nothing has touched yet; the
                // subject then blends its feathered alpha against the white underneath, which is
                // the die cut: a hair of rim showing through the subject's own edge. Copying the
                // subject too would punch the rim back out inside that antialiased boundary and
                // ring the whole subject with a one-pixel transparent seam.
                UIImage(cgImage: rim).draw(in: destination, blendMode: .copy, alpha: 1)
                UIImage(cgImage: cell).draw(in: destination, blendMode: .normal, alpha: 1)
            }
        }
        guard let data = image.pngData() else { throw MediaNormalizationError.unreadableImage }
        return data
    }
}
