import Foundation
import UIKit

nonisolated enum MediaNormalizationError: Error, LocalizedError {
    case unreadableImage
    case imageTooLarge
    case maskRequiresTransparency
    case liftProducedNoSubject

    var errorDescription: String? {
        switch self {
        case .unreadableImage: String(localized: "That image format could not be read.")
        case .imageTooLarge: String(localized: "The normalized image is still larger than 25 MB.")
        case .maskRequiresTransparency: String(localized: """
            Choose a PNG mask with transparent and painted areas. \
            Regular opaque photos cannot be used as masks.
            """)
        case .liftProducedNoSubject: String(localized: "No subject could be lifted out of that photo. Try one with a clearer foreground.")
        }
    }
}

@MainActor
enum MediaNormalizer {
    static func reference(data: Data, basename: String) throws -> PendingMediaAttachment {
        guard let source = UIImage(data: data) else { throw MediaNormalizationError.unreadableImage }
        let image = resizedToFit(source, maximumDimension: 2_048, opaque: !sourceMayContainAlpha(source))
        let encoded: Data
        let filename: String
        let mime: String
        if sourceMayContainAlpha(source), let png = image.pngData() {
            encoded = png
            filename = "\(basename).png"
            mime = "image/png"
        } else if let jpeg = image.jpegData(compressionQuality: 0.9) {
            encoded = jpeg
            filename = "\(basename).jpg"
            mime = "image/jpeg"
        } else {
            throw MediaNormalizationError.unreadableImage
        }
        guard encoded.count <= 25 * 1024 * 1024 else { throw MediaNormalizationError.imageTooLarge }
        return .init(data: encoded, filename: filename, mimeType: mime)
    }

    static func mask(data: Data, dimension: Int = 1_024) throws -> PendingMediaAttachment {
        guard let source = UIImage(data: data) else { throw MediaNormalizationError.unreadableImage }
        // Validate the original pixels before aspect-fit adds transparent
        // letterboxing. A usable mask needs both editable transparency and a
        // nontransparent painted region.
        guard hasEditableAlpha(source) else { throw MediaNormalizationError.maskRequiresTransparency }
        let normalized = squareAspectFit(source, dimension: dimension)
        guard let png = normalized.pngData() else {
            throw MediaNormalizationError.maskRequiresTransparency
        }
        return .init(data: png, filename: "mask-1024.png", mimeType: "image/png")
    }

    private static func resizedToFit(_ image: UIImage, maximumDimension: CGFloat, opaque: Bool) -> UIImage {
        let sourceSize = image.size
        let scale = min(1, maximumDimension / max(sourceSize.width, sourceSize.height))
        let size = CGSize(width: max(1, sourceSize.width * scale), height: max(1, sourceSize.height * scale))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = opaque
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
    }

    private static func squareAspectFit(_ image: UIImage, dimension: Int) -> UIImage {
        let side = CGFloat(dimension)
        let scale = min(side / image.size.width, side / image.size.height)
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let origin = CGPoint(x: (side - size.width) / 2, y: (side - size.height) / 2)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { _ in
            UIColor.clear.setFill()
            UIRectFill(CGRect(x: 0, y: 0, width: side, height: side))
            image.draw(in: CGRect(origin: origin, size: size))
        }
    }

    private static func sourceMayContainAlpha(_ image: UIImage) -> Bool {
        guard let alpha = image.cgImage?.alphaInfo else { return false }
        return [.first, .last, .premultipliedFirst, .premultipliedLast].contains(alpha)
    }

    private static func hasEditableAlpha(_ image: UIImage) -> Bool {
        guard let cgImage = image.cgImage else { return false }
        let width = cgImage.width
        let height = cgImage.height
        // Start transparent and copy source pixels verbatim. Initializing the
        // destination opaque (or source-over blending) turns transparent input
        // into opaque pixels and makes a valid alpha mask look empty.
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        return bytes.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.setBlendMode(.copy)
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            var hasTransparency = false
            var hasPaint = false
            for index in stride(from: 3, to: buffer.count, by: 4) {
                let alpha = buffer[index]
                hasTransparency = hasTransparency || alpha < 250
                hasPaint = hasPaint || alpha > 5
                if hasTransparency && hasPaint { return true }
            }
            return false
        }
    }
}
