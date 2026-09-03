import UIKit

extension UIImage {
    /// A compact cartoon mark for UIKit controls in the Messages extension.
    @MainActor
    static func stickerCartoonIcon(named name: String, pointSize: CGFloat = 20) -> UIImage {
        let art: String
        let isEmoji: Bool
        switch name {
        case "chevron.left": (art, isEmoji) = ("‹", false)
        case "wand.and.stars": (art, isEmoji) = ("🪄", true)
        case "photo.badge.plus": (art, isEmoji) = ("🖼️", true)
        case "paperplane.fill": (art, isEmoji) = ("📤", true)
        case "arrow.triangle.2.circlepath": (art, isEmoji) = ("🔀", true)
        case "checkmark.circle.fill": (art, isEmoji) = ("✓", false)
        case "xmark.circle.fill": (art, isEmoji) = ("×", false)
        default: (art, isEmoji) = ("✦", false)
        }

        let side = max(24, pointSize * 1.45)
        let format = UIGraphicsImageRendererFormat.preferred()
        format.opaque = false
        let image = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { _ in
            let font: UIFont
            if isEmoji {
                font = UIFont(name: "AppleColorEmoji", size: pointSize) ?? .systemFont(ofSize: pointSize)
            } else {
                let base = UIFont.systemFont(ofSize: pointSize, weight: .black)
                font = base.fontDescriptor.withDesign(.rounded).map { UIFont(descriptor: $0, size: pointSize) } ?? base
            }
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: UIColor.black,
            ]
            let measured = (art as NSString).size(withAttributes: attributes)
            let origin = CGPoint(
                x: (side - measured.width) / 2,
                y: (side - measured.height) / 2
            )
            (art as NSString).draw(at: origin, withAttributes: attributes)
        }
        return image.withRenderingMode(isEmoji ? .alwaysOriginal : .alwaysTemplate)
    }
}
