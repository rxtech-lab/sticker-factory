import SwiftUI

/// Draws an `AnimatedBackground` behind a document's layer stack.
struct AnimatedBackgroundView: View {
    let background: AnimatedBackground
    let assets: any AnimatedAssetProvider

    var body: some View {
        switch background {
        case .none:
            Color.clear
        case .image(let assetId, let contentMode):
            if let image = assets.image(for: assetId) {
                Image(platformImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode == .fit ? .fit : .fill)
            } else {
                Color.clear
            }
        default:
            if let paint = background.paint {
                Rectangle().fill(paint.shapeStyle)
            } else {
                Color.clear
            }
        }
    }
}

/// The alpha checkerboard used to show a transparent sticker against something.
///
/// Lives in the package rather than the app because every preview needs it and because a sticker
/// preview that renders transparent-on-white silently lies about what will be exported.
public struct AnimatedCheckerboard: View {
    public var squareSize: CGFloat
    public var light: Color
    public var dark: Color

    public init(squareSize: CGFloat = 12, light: Color = Color(white: 0.98), dark: Color = Color(white: 0.90)) {
        self.squareSize = squareSize
        self.light = light
        self.dark = dark
    }

    public var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(light))
            let columns = Int(ceil(size.width / squareSize))
            let rows = Int(ceil(size.height / squareSize))
            for row in 0..<max(rows, 0) {
                for column in 0..<max(columns, 0) where (row + column).isMultiple(of: 2) {
                    let rect = CGRect(
                        x: CGFloat(column) * squareSize,
                        y: CGFloat(row) * squareSize,
                        width: squareSize,
                        height: squareSize
                    )
                    context.fill(Path(rect), with: .color(dark))
                }
            }
        }
        .drawingGroup()
    }
}
