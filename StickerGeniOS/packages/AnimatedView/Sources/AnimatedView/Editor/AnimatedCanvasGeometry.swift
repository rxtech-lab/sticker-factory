import CoreGraphics
import Foundation

/// The pure geometry behind every canvas gesture in the editor.
///
/// Deliberately free of SwiftUI so it compiles — and is tested — on macOS, where `swift test` runs.
/// Every function here is a total function of its arguments; the views own the gesture recognisers
/// and nothing else, which is what makes "why did my layer jump" answerable by a unit test rather
/// than by running the app.
///
/// Two conventions are load-bearing and are shared with `AnimatedIconFrame`:
///
///  1. A layer's on-screen centre is exactly `state.position * canvasSize`. `AnimatedIconFrame`
///     applies `scaleEffect` and `rotationEffect` *before* `position`, and neither changes a view's
///     layout size, so the centre never moves as a side effect of scaling or rotating.
///  2. A layer's content is fitted into `AnimatedIconFrame.layerFit` of the canvas, for every layer
///     kind. That single factor is what lets one hit-test cover images, glyphs, shapes, and SVG.
/// One of the four corners of the selected layer's box, as both a drawn marker and a drag target.
public enum AnimatedCanvasHandle: String, CaseIterable, Hashable, Sendable {
    case topLeading, topTrailing, bottomLeading, bottomTrailing

    /// The corner in the layer's own untransformed box, as ±1 on each axis.
    ///
    /// Y grows downward, matching every other coordinate in the renderer, so `top` is `-1`.
    public var unit: AnimatedPoint {
        switch self {
        case .topLeading: AnimatedPoint(x: -1, y: -1)
        case .topTrailing: AnimatedPoint(x: 1, y: -1)
        case .bottomLeading: AnimatedPoint(x: -1, y: 1)
        case .bottomTrailing: AnimatedPoint(x: 1, y: 1)
        }
    }
}

public enum AnimatedCanvasGeometry {
    // MARK: - Clamps
    //
    // These mirror `AnimatedAnchor.isValid` and `AnimatedLayerAnimation.isValid` exactly. A gesture
    // that produced a value outside them would build a document that fails `validated()` at save
    // time, long after the user let go, so clamping happens here rather than at the boundary.

    /// Normalized position range. `-1...2` allows a layer to sit fully off-canvas, which is how a
    /// slide-in animation parks its start point.
    public static let positionRange: ClosedRange<Double> = -1...2
    public static let scaleRange: ClosedRange<Double> = 0.05...8

    /// Rotation for a *keyframe*, matching `AnimatedLayerAnimation.isValid`.
    public static let keyframeRotationRange: ClosedRange<Double> = -3600...3600

    /// Rotation for an *anchor*, deliberately tighter than `AnimatedAnchor.isValid`'s `-3600...3600`.
    ///
    /// The anchor is an input to the compiler, and `AnimationCompiler.rotation` clamps its output to
    /// `-1080...1080`. An anchor of 2000° on a declarative layer would therefore compile to 1080°,
    /// and the document would no longer equal its own recompilation — which is precisely what the
    /// server's agreement check rejects. Clamping the anchor to the compiler's range makes that
    /// state unreachable instead of merely unlikely.
    public static let anchorRotationRange: ClosedRange<Double> = -1080...1080

    /// How close to a round value a gesture has to land before it snaps.
    public static let positionSnapTolerance = 0.01
    public static let rotationSnapDegrees: Double = 15
    public static let rotationSnapTolerance: Double = 2

    /// Extra slop around a layer's box when hit-testing, in points.
    ///
    /// A fully transparent or hairline-thin layer is still something the user can see and means to
    /// tap, and a finger is not a pixel.
    public static let hitTestSlop: CGFloat = 8

    /// How close a touch has to land to a corner handle to grab it, in screen points.
    ///
    /// Generous on purpose: the handle is drawn at ten points so it doesn't obscure the artwork, but
    /// a finger covers far more than that, and a corner drag that misses becomes a *move* — visibly
    /// the wrong thing rather than nothing at all.
    public static let handleGrabRadius: CGFloat = 24

    /// How close a corner drag has to land to 1× before it snaps there.
    public static let scaleSnapTolerance = 0.02

    static func clamp(_ value: Double, to range: ClosedRange<Double>) -> Double {
        Swift.min(range.upperBound, Swift.max(range.lowerBound, value))
    }

    // MARK: - Letterboxing

    /// The rect that `.aspectRatio(_, contentMode: .fit)` settles on inside `size`.
    ///
    /// The editor computes this itself rather than letting `AnimatedIconFrame`'s own `.aspectRatio`
    /// do it, then frames the frame to the result. That collapses the inner modifier to a no-op and
    /// makes the gesture surface and the artwork share one rect — so a gesture's local coordinates
    /// *are* canvas coordinates, and no call site does offset arithmetic.
    public static func contentRect(in size: CGSize, aspectRatio: Double) -> CGRect {
        guard size.width > 0, size.height > 0, aspectRatio > 0, aspectRatio.isFinite else { return .zero }
        let containerRatio = size.width / size.height
        let fitted = containerRatio > aspectRatio
            ? CGSize(width: size.height * aspectRatio, height: size.height)
            : CGSize(width: size.width, height: size.width / aspectRatio)
        return CGRect(
            x: (size.width - fitted.width) / 2,
            y: (size.height - fitted.height) / 2,
            width: fitted.width,
            height: fitted.height
        )
    }

    /// A point in `rect`'s own coordinate space, expressed in the document's normalized space.
    public static func normalized(_ point: CGPoint, in rect: CGRect) -> AnimatedPoint {
        guard rect.width > 0, rect.height > 0 else { return .center }
        return AnimatedPoint(x: Double(point.x) / Double(rect.width), y: Double(point.y) / Double(rect.height))
    }

    /// The inverse of ``normalized(_:in:)``.
    public static func denormalized(_ point: AnimatedPoint, in rect: CGRect) -> CGPoint {
        CGPoint(x: CGFloat(point.x) * rect.width, y: CGFloat(point.y) * rect.height)
    }

    // MARK: - Layer boxes

    /// The untransformed box a layer's content is laid out in, before its own scale and rotation.
    ///
    /// Particles are the one exception in `AnimatedIconFrame`: they are framed to the whole canvas
    /// rather than the fit box, because a particle field is a full-bleed effect.
    public static func layoutBox(canvasSize: CGSize, isParticle: Bool) -> CGSize {
        isParticle
            ? canvasSize
            : CGSize(
                width: canvasSize.width * AnimatedIconFrame.layerFit,
                height: canvasSize.height * AnimatedIconFrame.layerFit
            )
    }

    /// The scale actually applied on screen, which is not always the scale stored on the layer.
    ///
    /// `AnimatedIconFrame` renders text with `min(scale.x, scale.y)` on both axes — stretched glyphs
    /// read as a rendering fault rather than an effect. Hit-testing and the selection outline have
    /// to use the same collapsed value or they would drift from the artwork on any text layer whose
    /// scale is not already uniform.
    public static func renderedScale(_ scale: AnimatedPoint, isText: Bool) -> AnimatedPoint {
        guard isText else { return scale }
        let uniform = Swift.min(scale.x, scale.y)
        return AnimatedPoint(x: uniform, y: uniform)
    }

    // MARK: - Corner handles

    /// Rotates a vector about the origin. The one piece of trigonometry in this file, shared by the
    /// hit test (which un-rotates) and the handle math (which does both directions).
    static func rotate(_ point: CGPoint, byDegrees degrees: Double) -> CGPoint {
        let radians = degrees * .pi / 180
        let c = CGFloat(cos(radians))
        let s = CGFloat(sin(radians))
        return CGPoint(x: point.x * c - point.y * s, y: point.x * s + point.y * c)
    }

    /// Where a corner handle sits on screen, in the stage's coordinate space.
    ///
    /// Follows `AnimatedIconFrame.layerView`'s chain exactly — scale the corner, rotate it, then
    /// offset by the layer's centre — which is also how `AnimatedEditorSelectionOverlay` ends up
    /// drawing them. The two must agree: a handle you can see but not grab, or grab but not see, is
    /// worse than no handle.
    public static func handlePosition(
        _ handle: AnimatedCanvasHandle,
        layer: AnimatedLayer,
        state: AnimatedLayerState,
        in rect: CGRect
    ) -> CGPoint {
        let box = layoutBox(canvasSize: rect.size, isParticle: layer.type == .particle)
        let scale = renderedScale(state.scale, isText: layer.isText)
        let corner = CGPoint(
            x: CGFloat(handle.unit.x) * box.width / 2 * CGFloat(scale.x),
            y: CGFloat(handle.unit.y) * box.height / 2 * CGFloat(scale.y)
        )
        let rotated = rotate(corner, byDegrees: state.rotationDegrees)
        let centre = denormalized(state.position, in: rect)
        return CGPoint(x: centre.x + rotated.x, y: centre.y + rotated.y)
    }

    /// Whether a layer is drawn large enough for its corners to be distinguishable targets.
    ///
    /// At a small enough scale all four handles collapse into the layer's centre, and a grab radius
    /// that overlapped them all would swallow every drag — the layer could be scaled but never
    /// moved again, with no way to tell why. Below the threshold there are no handles at all and the
    /// inspector's sliders are the way to scale.
    public static func handlesAreGrabbable(
        layer: AnimatedLayer,
        state: AnimatedLayerState,
        in rect: CGRect
    ) -> Bool {
        let position = handlePosition(.bottomTrailing, layer: layer, state: state, in: rect)
        let centre = denormalized(state.position, in: rect)
        return hypot(position.x - centre.x, position.y - centre.y) > handleGrabRadius
    }

    /// The corner handle nearest `point`, if one is within grabbing distance.
    public static func handleHitTest(
        _ point: CGPoint,
        layer: AnimatedLayer,
        state: AnimatedLayerState,
        in rect: CGRect,
        radius: CGFloat = handleGrabRadius
    ) -> AnimatedCanvasHandle? {
        guard handlesAreGrabbable(layer: layer, state: state, in: rect) else { return nil }
        return AnimatedCanvasHandle.allCases
            .map { ($0, handlePosition($0, layer: layer, state: state, in: rect)) }
            .map { ($0.0, hypot($0.1.x - point.x, $0.1.y - point.y)) }
            .filter { $0.1 <= radius }
            .min { $0.1 < $1.1 }?.0
    }

    /// A corner drag folded into a scale.
    ///
    /// Scaling happens about the layer's **centre**, not about the opposite corner. Anchoring the
    /// opposite corner is the more familiar behaviour in drawing apps, but a layer's stored position
    /// *is* its centre, so holding a corner still would mean writing the position channel on every
    /// frame of a scale gesture — silently editing motion the user did not touch, and on a layer
    /// with position keyframes, writing to whichever one the playhead happens to sit near.
    ///
    /// `box` is the layer's *untransformed* layout box, so the caller and ``handlePosition(_:layer:state:in:)``
    /// share one definition of where the corner started.
    public static func handleScale(
        start: AnimatedPoint,
        handle: AnimatedCanvasHandle,
        translation: CGSize,
        rotationDegrees: Double,
        box: CGSize,
        uniform: Bool,
        snapping: Bool = true
    ) -> AnimatedPoint {
        let corner = CGPoint(x: CGFloat(handle.unit.x) * box.width / 2, y: CGFloat(handle.unit.y) * box.height / 2)
        guard abs(corner.x) > 1e-6, abs(corner.y) > 1e-6 else { return start }
        // Text renders at `min(x, y)` on both axes, so a stored pair that disagrees would make the
        // gesture start from a corner the artwork never had.
        let start = renderedScale(start, isText: uniform)

        // Where the corner is now, where the finger has taken it, and what that is in the layer's
        // own unrotated frame. Going through screen space and back is what makes a drag on a rotated
        // layer follow the finger instead of the layer's tilted axes.
        let began = rotate(CGPoint(x: corner.x * CGFloat(start.x), y: corner.y * CGFloat(start.y)), byDegrees: rotationDegrees)
        let moved = CGPoint(x: began.x + translation.width, y: began.y + translation.height)
        let local = rotate(moved, byDegrees: -rotationDegrees)

        var x = Double(local.x / corner.x)
        var y = Double(local.y / corner.y)
        if uniform {
            // One factor from how far the corner is from the centre, relative to where it started.
            let value = Double(hypot(local.x, local.y) / hypot(corner.x, corner.y))
            x = value
            y = value
        }
        if snapping {
            if abs(x - 1) < scaleSnapTolerance { x = 1 }
            if abs(y - 1) < scaleSnapTolerance { y = 1 }
        }
        return AnimatedPoint(
            x: AnimationCompiler.roundValue(clamp(x, to: scaleRange)),
            y: AnimationCompiler.roundValue(clamp(y, to: scaleRange))
        )
    }

    // MARK: - Hit testing

    /// The id of the top-most visible layer under `point`, or `nil`.
    ///
    /// Walks the layer array in reverse because index 0 is drawn first and is therefore bottom-most.
    /// Particles are considered last regardless of their z-order: they occupy the entire canvas, so
    /// letting one win on depth alone would make every tap select the particle field and nothing
    /// else. The layer list stays the way to select one deliberately.
    public static func hitTest(
        _ point: CGPoint,
        document: AnimatedDocument,
        atDocumentTime time: Double,
        in rect: CGRect
    ) -> String? {
        let candidates = document.layers.enumerated().reversed().filter { !$0.element.hidden }
        let ordered = candidates.filter { $0.element.type != .particle } + candidates.filter { $0.element.type == .particle }
        for (_, layer) in ordered {
            let state = AnimationInterpolator.state(for: layer, atDocumentTime: time)
            if contains(point, layer: layer, state: state, in: rect) { return layer.id }
        }
        return nil
    }

    /// Whether `point` falls inside a layer's transformed box.
    ///
    /// Undoes `AnimatedIconFrame`'s transform chain in reverse order — translate by the layer's
    /// centre, un-rotate, un-scale — and then tests an origin-centred box. Doing it this way rather
    /// than forward-transforming the box corners means a rotated layer is tested against its true
    /// oriented rectangle, not its bounding box.
    public static func contains(
        _ point: CGPoint,
        layer: AnimatedLayer,
        state: AnimatedLayerState,
        in rect: CGRect
    ) -> Bool {
        let canvasSize = rect.size
        let centre = denormalized(state.position, in: rect)
        let scale = renderedScale(state.scale, isText: layer.isText)
        guard abs(scale.x) > 1e-6, abs(scale.y) > 1e-6 else { return false }

        let translated = CGPoint(x: point.x - centre.x, y: point.y - centre.y)
        let rotated = rotate(translated, byDegrees: -state.rotationDegrees)

        // `rotated` now sits in the layer's scaled-but-unrotated frame, where the box is simply the
        // layout box times the layer's scale. The slop is added in screen points afterwards, so it
        // stays a constant finger-sized margin rather than shrinking with a scaled-down layer.
        let box = layoutBox(canvasSize: canvasSize, isParticle: layer.type == .particle)
        let halfWidth = box.width * CGFloat(abs(scale.x)) / 2 + hitTestSlop
        let halfHeight = box.height * CGFloat(abs(scale.y)) / 2 + hitTestSlop
        return abs(rotated.x) <= halfWidth && abs(rotated.y) <= halfHeight
    }

    // MARK: - Gesture reducers
    //
    // Each takes the value captured when the gesture began plus the gesture's current delta, never
    // an accumulated running total. SwiftUI reports `translation`, `magnification`, and `rotation`
    // relative to the gesture's start, so accumulating would apply each frame's delta repeatedly.

    /// A drag translation folded into a normalized position.
    public static func draggedPosition(
        start: AnimatedPoint,
        translation: CGSize,
        in rect: CGRect,
        snapping: Bool = true
    ) -> AnimatedPoint {
        guard rect.width > 0, rect.height > 0 else { return start }
        var x = start.x + Double(translation.width) / Double(rect.width)
        var y = start.y + Double(translation.height) / Double(rect.height)
        if snapping {
            if abs(x - 0.5) < positionSnapTolerance { x = 0.5 }
            if abs(y - 0.5) < positionSnapTolerance { y = 0.5 }
        }
        return AnimatedPoint(
            x: AnimationCompiler.roundValue(clamp(x, to: positionRange)),
            y: AnimationCompiler.roundValue(clamp(y, to: positionRange))
        )
    }

    /// A pinch folded into a scale.
    ///
    /// `uniform` collapses both axes to one factor and is set for text layers, because the renderer
    /// already collapses them — storing unequal axes would make the inspector's numbers describe a
    /// render that never happens.
    public static func magnifiedScale(
        start: AnimatedPoint,
        magnification: CGFloat,
        uniform: Bool
    ) -> AnimatedPoint {
        let factor = magnification.isFinite && magnification > 0 ? Double(magnification) : 1
        var x = start.x * factor
        var y = start.y * factor
        if uniform {
            let value = Swift.min(x, y)
            x = value
            y = value
        }
        return AnimatedPoint(
            x: AnimationCompiler.roundValue(clamp(x, to: scaleRange)),
            y: AnimationCompiler.roundValue(clamp(y, to: scaleRange))
        )
    }

    /// A rotation gesture folded into degrees, snapping to 15° increments near them.
    ///
    /// `range` is the caller's choice of ``anchorRotationRange`` or ``keyframeRotationRange``; see
    /// the note on `anchorRotationRange` for why the two differ.
    public static func rotatedDegrees(
        start: Double,
        delta: Double,
        snapping: Bool = true,
        range: ClosedRange<Double> = anchorRotationRange
    ) -> Double {
        var degrees = start + delta
        if snapping {
            let nearest = (degrees / rotationSnapDegrees).rounded() * rotationSnapDegrees
            if abs(degrees - nearest) < rotationSnapTolerance { degrees = nearest }
        }
        return AnimationCompiler.roundValue(clamp(degrees, to: range))
    }
}
