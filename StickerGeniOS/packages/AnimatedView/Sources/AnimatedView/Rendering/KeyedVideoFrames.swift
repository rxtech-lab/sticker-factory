import CoreGraphics
import Foundation

/// A video layer's clip, decoded and keyed, ready to draw.
///
/// The frames are `CGImage`s with real alpha: the chroma backdrop the clip was shot against has
/// already been removed by `VideoFrameDecoder`. Nothing downstream — the renderer, the exporter,
/// the inspector — knows there was ever a green screen.
///
/// A value rather than a class so it can cross actors: the app decodes off the main actor and
/// hands the result to its main-actor asset store.
public struct KeyedVideoFrames: Sendable {
    public var frames: [CGImage]
    /// The clip's own playback rate, as decoded. Informational; the document's layer carries the
    /// rate the interpolator actually uses.
    public var frameRate: Double
    public var size: CGSize

    public init(frames: [CGImage], frameRate: Double, size: CGSize) {
        self.frames = frames
        self.frameRate = frameRate
        self.size = size
    }

    public var frameCount: Int { frames.count }

    /// The frame at `index`, clamped into range so a clip that decoded to slightly fewer frames
    /// than the document declared still plays to its end instead of blinking out.
    public func frame(at index: Int) -> CGImage? {
        guard !frames.isEmpty else { return nil }
        return frames[min(max(index, 0), frames.count - 1)]
    }
}
