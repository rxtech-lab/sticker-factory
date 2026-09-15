import CoreGraphics
import SwiftUI

/// Rasterises document frames off-screen.
///
/// The exporter's only entry point into the renderer. It draws `AnimatedIconFrame`, the same view
/// the player uses, so an exported frame and an on-screen frame come from one code path — the
/// alternative, a parallel drawing implementation for export, is exactly how a preview and a
/// rendition drift apart.
///
/// Encoding is deliberately not here: GIF, APNG, and MP4 need `ImageIO` and `AVFoundation` and
/// belong to the app, which knows its own size budgets and format policy.
@MainActor
public struct AnimatedIconRenderer {
    public var document: AnimatedDocument
    public var assets: any AnimatedAssetProvider

    public init(document: AnimatedDocument, assets: any AnimatedAssetProvider = EmptyAnimatedAssets()) {
        self.document = (try? document.resolvingConfiguration()) ?? document
        self.assets = assets
    }

    /// One frame at an explicit wall-clock time, at `size` pixels.
    ///
    /// Draws into a bitmap context this function owns and clears, rather than returning
    /// `ImageRenderer.cgImage` directly. That is not defensiveness for its own sake: when the view
    /// draws nothing — which is exactly what frame 0 of an entrance animation is — `ImageRenderer`
    /// hands back an image over a recycled buffer still holding a previously rendered frame. In a
    /// quiet process that buffer happens to be zeroed and the bug is invisible; in a busy one every
    /// blank frame of an export comes out as whatever was rendered before it.
    ///
    /// The scale is pinned to 1 so the output is exactly `size` pixels regardless of the display it
    /// happens to be rendered on; an export whose resolution changed on a 3x device would fail the
    /// server's rendition validation.
    public func cgImage(at time: Double, size: CGSize) -> CGImage? {
        let width = Int(size.width.rounded())
        let height = Int(size.height.rounded())
        guard width > 0, height > 0 else { return nil }

        let content = AnimatedIconFrame(document: document, time: time, assets: assets)
            .frame(width: size.width, height: size.height)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 1
        renderer.proposedSize = ProposedViewSize(size)
        renderer.isOpaque = false

        var output: CGImage?
        renderer.render(rasterizationScale: 1) { _, draw in
            guard let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            ) else { return }
            context.clear(CGRect(x: 0, y: 0, width: width, height: height))
            draw(context)
            output = context.makeImage()
        }
        return output
    }

    public func cgImage(at time: Double, dimension: Int) -> CGImage? {
        cgImage(at: time, size: CGSize(width: dimension, height: dimension))
    }

    /// How many frames one visible cycle needs at `fps`.
    ///
    /// Reads `renderedCycleDuration`, so it already accounts for `speed` and for ping-pong being
    /// twice as long as its authored duration.
    public func frameCount(fps: Int) -> Int {
        guard fps > 0 else { return 1 }
        return max(1, Int(ceil(document.renderedCycleDuration * Double(fps))))
    }

    /// Every frame of one cycle, in order.
    ///
    /// Times are wall-clock, which is what `AnimatedIconFrame` expects, so speed is applied for
    /// free rather than being a second thing the caller has to remember.
    public func frameTimes(fps: Int) -> [Double] {
        let count = frameCount(fps: fps)
        guard fps > 0 else { return [0] }
        return (0..<count).map { Double($0) / Double(fps) }
    }

    public func renderCycle(fps: Int, size: CGSize) -> [CGImage] {
        frameTimes(fps: fps).compactMap { cgImage(at: $0, size: size) }
    }
}
