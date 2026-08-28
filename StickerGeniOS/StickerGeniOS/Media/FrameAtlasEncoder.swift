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

    /// Packs `frames` into an atlas.
    ///
    /// Frames that failed to lift are dropped and the remainder renumbered, so a sequence is always
    /// contiguous — a transparent tile in the middle of a loop reads as a broken render, whereas a
    /// slightly shorter loop reads as nothing at all.
    static func encode(frames: [CGImage?], settings: SubjectLiftSettings) throws -> Encoded {
        let usable = frames.compactMap { $0 }
        guard !usable.isEmpty else { throw MediaNormalizationError.liftProducedNoSubject }

        let crop = sharedCropRect(for: usable)
        let count = min(usable.count, 64)
        let frames = Array(usable.prefix(count))
        let columns = min(8, max(1, Int(Double(count).squareRoot().rounded(.up))))
        let rows = min(8, max(1, Int((Double(count) / Double(columns)).rounded(.up))))
        guard count <= columns * rows else { throw MediaNormalizationError.liftProducedNoSubject }

        for tile in tileLadder {
            let data = try draw(frames, crop: crop, columns: columns, rows: rows, tile: tile)
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
    private static func sharedCropRect(for frames: [CGImage]) -> CGRect {
        let width = CGFloat(frames[0].width)
        let height = CGFloat(frames[0].height)
        var union: CGRect?
        for frame in frames {
            guard let descriptor = SubjectSegmenter.describe(frame) else { continue }
            // Straight back into pixels: `describe` reports top-left normalized coordinates and
            // `CGImage.cropping(to:)` takes top-left pixel coordinates, so the two already agree.
            let rect = CGRect(
                x: descriptor.bounds.minX * width,
                y: descriptor.bounds.minY * height,
                width: descriptor.bounds.width * width,
                height: descriptor.bounds.height * height
            )
            union = union.map { $0.union(rect) } ?? rect
        }
        let full = CGRect(x: 0, y: 0, width: width, height: height)
        guard var rect = union, rect.width > 1, rect.height > 1 else { return full }

        rect = rect.insetBy(dx: -rect.width * 0.08, dy: -rect.height * 0.08)
        // Squared around its own centre so tiles are square, which is what lets the renderer and the
        // server's SVG viewport treat one grid cell as one frame with no aspect correction.
        let side = max(rect.width, rect.height)
        rect = CGRect(x: rect.midX - side / 2, y: rect.midY - side / 2, width: side, height: side)
        return rect.intersection(full).isEmpty ? full : rect.intersection(full)
    }

    private static func draw(
        _ frames: [CGImage],
        crop: CGRect,
        columns: Int,
        rows: Int,
        tile: Int
    ) throws -> Data {
        let sheet = CGSize(width: CGFloat(tile * columns), height: CGFloat(tile * rows))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let image = UIGraphicsImageRenderer(size: sheet, format: format).image { context in
            let cg = context.cgContext
            // `.copy` so alpha is written verbatim rather than composited over the (transparent but
            // still blended) backdrop — the same reason `MediaNormalizer.hasEditableAlpha` sets it.
            cg.setBlendMode(.copy)
            for (index, frame) in frames.enumerated() {
                guard let cropped = frame.cropping(to: crop.integral) ?? frame.cropping(to: crop) else { continue }
                let column = index % columns
                let row = index / columns
                cg.draw(
                    cropped,
                    in: CGRect(x: column * tile, y: row * tile, width: tile, height: tile)
                )
            }
        }
        guard let data = image.pngData() else { throw MediaNormalizationError.unreadableImage }
        return data
    }
}
