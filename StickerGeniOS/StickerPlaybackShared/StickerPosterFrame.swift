import ImageIO
import UIKit

/// Picks the frame a *still* preview of an animated sticker should show.
///
/// Frame zero is the obvious choice and the wrong one. A sticker whose layer fades in, or slides in
/// from off-canvas, is fully transparent at t=0 — every surface that renders one still frame (the
/// library card, any `UIImage` built from GIF/APNG data) then draws an empty square, which reads as
/// a sticker that failed to load rather than one that has not started moving yet.
///
/// The most-covered frame is a good enough stand-in for "the pose this sticker is about": intros
/// build up to it and outros decay from it, so it is the settled state in both cases.
nonisolated enum StickerPosterFrame {
    /// Alpha is summed on a downsample because only the ranking between frames matters, and an
    /// animated sticker can carry up to 240 of them.
    private static let sampleSide = 24

    /// Returns `nil` for single-frame data, leaving the caller's normal decode path in charge.
    static func image(from data: Data) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let frameCount = CGImageSourceGetCount(source)
        guard frameCount > 1 else { return nil }

        var bestIndex = 0
        var bestCoverage = -1
        for index in 0 ..< frameCount {
            guard let frame = CGImageSourceCreateImageAtIndex(source, index, nil) else { continue }
            let coverage = opaqueCoverage(of: frame)
            if coverage > bestCoverage {
                bestCoverage = coverage
                bestIndex = index
            }
        }
        guard bestCoverage > 0, let poster = CGImageSourceCreateImageAtIndex(source, bestIndex, nil) else {
            return nil
        }
        return UIImage(cgImage: poster)
    }

    /// Summed alpha over a downsample of the frame — a ranking, not a measurement.
    ///
    /// `StickerExporter` scores the frames it renders with the same function, so the still it falls
    /// back to and the still the library shows are chosen the same way.
    static func opaqueCoverage(of image: CGImage) -> Int {
        var pixels = [UInt8](repeating: 0, count: sampleSide * sampleSide * 4)
        return pixels.withUnsafeMutableBytes { buffer -> Int in
            // Copy rather than blend, and start from a zeroed buffer: source-over onto an opaque
            // backdrop makes every transparent frame score full coverage.
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: sampleSide,
                height: sampleSide,
                bitsPerComponent: 8,
                bytesPerRow: sampleSide * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return 0 }
            context.setBlendMode(.copy)
            context.draw(image, in: CGRect(x: 0, y: 0, width: sampleSide, height: sampleSide))
            return stride(from: 3, to: buffer.count, by: 4).reduce(into: 0) { total, index in
                total += Int(buffer[index])
            }
        }
    }
}
