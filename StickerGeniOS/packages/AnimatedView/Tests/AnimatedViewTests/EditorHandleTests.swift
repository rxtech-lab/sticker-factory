import CoreGraphics
import Foundation
import Testing
@testable import AnimatedView

/// Corner handles: where they are drawn, when they can be grabbed, and what dragging one does.
///
/// The handle a finger grabs and the handle the eye sees are computed by different code — the drag
/// resolves a position from `handlePosition`, the overlay draws it as a corner of a rotated,
/// scaled `Rectangle`. If those two ever disagree the symptom is a handle that visibly misses the
/// touch, so the geometry is pinned here against hand-computed screen coordinates rather than
/// against itself.
struct EditorHandleTests {
    /// A 200pt square stage, so the layout box is 200 × 0.86 = 172pt and each corner sits 86pt from
    /// the centre on each axis at 1×.
    private let rect = CGRect(x: 0, y: 0, width: 200, height: 200)
    private let half = 200 * Double(AnimatedIconFrame.layerFit) / 2

    private func shape(anchor: AnimatedAnchor = .default) -> AnimatedLayer {
        .shape(.init(
            base: .init(id: "shape", name: "Shape", anchor: anchor),
            shape: .circle,
            fill: .solid("#FFFFFF")
        ))
    }

    private func text(anchor: AnimatedAnchor = .default) -> AnimatedLayer {
        .text(.init(base: .init(id: "caption", name: "Caption", anchor: anchor), text: "Hi"))
    }

    private func state(
        position: AnimatedPoint = .center,
        scale: AnimatedPoint = .unit,
        rotationDegrees: Double = 0
    ) -> AnimatedLayerState {
        AnimationInterpolator.state(
            for: shape(anchor: .init(position: position, scale: scale, rotationDegrees: rotationDegrees)),
            atDocumentTime: 0
        )
    }

    // MARK: - Where the handles are

    @Test func handlesSitAtTheCornersOfTheLayoutBox() {
        let subject = state()
        let topLeading = AnimatedCanvasGeometry.handlePosition(.topLeading, layer: shape(), state: subject, in: rect)
        let bottomTrailing = AnimatedCanvasGeometry.handlePosition(.bottomTrailing, layer: shape(), state: subject, in: rect)
        #expect(abs(topLeading.x - CGFloat(100 - half)) < 1e-9)
        #expect(abs(topLeading.y - CGFloat(100 - half)) < 1e-9)
        #expect(abs(bottomTrailing.x - CGFloat(100 + half)) < 1e-9)
        #expect(abs(bottomTrailing.y - CGFloat(100 + half)) < 1e-9)
    }

    @Test func handlesFollowScaleAndPosition() {
        let subject = state(position: AnimatedPoint(x: 0.25, y: 0.5), scale: AnimatedPoint(x: 0.5, y: 2))
        let corner = AnimatedCanvasGeometry.handlePosition(.bottomTrailing, layer: shape(), state: subject, in: rect)
        #expect(abs(corner.x - CGFloat(50 + half * 0.5)) < 1e-9)
        #expect(abs(corner.y - CGFloat(100 + half * 2)) < 1e-9)
    }

    /// At 90° the box's bottom-trailing corner swings round to sit below-left of the centre.
    @Test func handlesFollowRotation() {
        let subject = state(rotationDegrees: 90)
        let corner = AnimatedCanvasGeometry.handlePosition(.bottomTrailing, layer: shape(), state: subject, in: rect)
        #expect(abs(corner.x - CGFloat(100 - half)) < 1e-6)
        #expect(abs(corner.y - CGFloat(100 + half)) < 1e-6)
    }

    /// Text renders at `min(x, y)` on both axes, so its handles have to as well or they would frame
    /// a box the artwork never occupies.
    @Test func textHandlesUseTheCollapsedScale() {
        let subject = state(scale: AnimatedPoint(x: 2, y: 0.5))
        let corner = AnimatedCanvasGeometry.handlePosition(.bottomTrailing, layer: text(), state: subject, in: rect)
        #expect(abs(corner.x - CGFloat(100 + half * 0.5)) < 1e-9)
        #expect(abs(corner.y - CGFloat(100 + half * 0.5)) < 1e-9)
    }

    // MARK: - Grabbing one

    @Test func aTouchOnACornerGrabsThatHandle() {
        let subject = state()
        for handle in AnimatedCanvasHandle.allCases {
            let point = AnimatedCanvasGeometry.handlePosition(handle, layer: shape(), state: subject, in: rect)
            #expect(AnimatedCanvasGeometry.handleHitTest(point, layer: shape(), state: subject, in: rect) == handle)
        }
    }

    @Test func aTouchInTheMiddleOfTheLayerGrabsNoHandle() {
        let subject = state()
        #expect(AnimatedCanvasGeometry.handleHitTest(CGPoint(x: 100, y: 100), layer: shape(), state: subject, in: rect) == nil)
    }

    /// The whole reason a drag resolves once at `startLocation`: a touch that misses every corner
    /// has to fall through to moving the layer, not do nothing.
    @Test func aTouchJustOutsideTheGrabRadiusGrabsNoHandle() {
        let subject = state()
        let corner = AnimatedCanvasGeometry.handlePosition(.bottomTrailing, layer: shape(), state: subject, in: rect)
        let justOutside = CGPoint(x: corner.x - AnimatedCanvasGeometry.handleGrabRadius - 1, y: corner.y)
        #expect(AnimatedCanvasGeometry.handleHitTest(justOutside, layer: shape(), state: subject, in: rect) == nil)
    }

    /// Below a certain size all four corners fall inside one grab radius of each other and of the
    /// centre. Were handles still live there, every drag would scale and the layer could never be
    /// moved again — with nothing on screen to explain why.
    @Test func aTinyLayerHasNoGrabbableHandles() {
        let tiny = state(scale: AnimatedPoint(x: 0.05, y: 0.05))
        #expect(!AnimatedCanvasGeometry.handlesAreGrabbable(layer: shape(), state: tiny, in: rect))
        let corner = AnimatedCanvasGeometry.handlePosition(.bottomTrailing, layer: shape(), state: tiny, in: rect)
        #expect(AnimatedCanvasGeometry.handleHitTest(corner, layer: shape(), state: tiny, in: rect) == nil)

        let normal = state()
        #expect(AnimatedCanvasGeometry.handlesAreGrabbable(layer: shape(), state: normal, in: rect))
    }

    // MARK: - Dragging one

    private var box: CGSize { CGSize(width: rect.width * AnimatedIconFrame.layerFit, height: rect.height * AnimatedIconFrame.layerFit) }

    private func drag(
        _ handle: AnimatedCanvasHandle,
        by translation: CGSize,
        from start: AnimatedPoint = .unit,
        rotationDegrees: Double = 0,
        uniform: Bool = false
    ) -> AnimatedPoint {
        AnimatedCanvasGeometry.handleScale(
            start: start,
            handle: handle,
            translation: translation,
            rotationDegrees: rotationDegrees,
            box: box,
            uniform: uniform
        )
    }

    /// Pulling the bottom-trailing corner down and right by exactly the half-box doubles the layer,
    /// because the scale is measured from the centre.
    @Test func draggingACornerOutwardGrowsTheLayer() {
        let result = drag(.bottomTrailing, by: CGSize(width: half, height: half))
        #expect(abs(result.x - 2) < 1e-6)
        #expect(abs(result.y - 2) < 1e-6)
    }

    @Test func draggingACornerInwardShrinksTheLayer() {
        let result = drag(.bottomTrailing, by: CGSize(width: -half / 2, height: -half / 2))
        #expect(abs(result.x - 0.5) < 1e-6)
        #expect(abs(result.y - 0.5) < 1e-6)
    }

    /// The leading corners point the other way, so the same rightward drag has to shrink rather
    /// than grow. Getting this sign wrong is the classic corner-handle bug.
    @Test func theLeadingCornersRespondInTheOppositeDirection() {
        let trailing = drag(.bottomTrailing, by: CGSize(width: half, height: 0))
        #expect(abs(trailing.x - 2) < 1e-6)

        // The same rightward drag brings the leading corner all the way to the centre — a scale of
        // zero, which the range floor catches.
        let leading = drag(.bottomLeading, by: CGSize(width: half, height: 0))
        #expect(leading.x == AnimatedCanvasGeometry.scaleRange.lowerBound)

        // Half as far is half the width, with no clamping involved.
        let halfway = drag(.bottomLeading, by: CGSize(width: half / 2, height: 0))
        #expect(abs(halfway.x - 0.5) < 1e-6)
    }

    @Test func draggingOneCornerCanScaleTheAxesIndependently() {
        let result = drag(.bottomTrailing, by: CGSize(width: half, height: 0))
        #expect(abs(result.x - 2) < 1e-6)
        #expect(abs(result.y - 1) < 1e-6)
    }

    /// Text must stay uniform: the renderer collapses its scale to `min(x, y)`, so storing unequal
    /// axes would mean the inspector reports a size the artwork never takes.
    @Test func aUniformDragKeepsBothAxesEqual() {
        let result = drag(.bottomTrailing, by: CGSize(width: half, height: 0), uniform: true)
        #expect(result.x == result.y)
        #expect(result.x > 1)
    }

    @Test func aUniformDragStartsFromTheCollapsedScale() {
        // Stored 2 × 0.5 renders at 0.5; a zero-length drag must therefore report 0.5, not 2.
        let result = drag(.bottomTrailing, by: .zero, from: AnimatedPoint(x: 2, y: 0.5), uniform: true)
        #expect(abs(result.x - 0.5) < 1e-6)
        #expect(abs(result.y - 0.5) < 1e-6)
    }

    /// On a rotated layer the finger moves in screen space while the box's axes are tilted. The drag
    /// has to be resolved in the layer's own frame, or dragging a corner of a 45° layer would scale
    /// along the wrong axis.
    @Test func aDragOnARotatedLayerFollowsTheLayersOwnAxes() {
        // At 90°, the layer's +x axis points down the screen. A purely downward drag is therefore a
        // pure +x scale.
        let result = drag(.bottomTrailing, by: CGSize(width: 0, height: half), rotationDegrees: 90)
        #expect(abs(result.x - 2) < 1e-6)
        #expect(abs(result.y - 1) < 1e-6)
    }

    /// A drag that starts on a handle and never moves must leave the layer exactly where it was,
    /// including at a non-unit starting scale — otherwise every corner grab snaps the layer first.
    @Test func aZeroLengthDragIsInert() {
        for handle in AnimatedCanvasHandle.allCases {
            for rotation in [0.0, 33, -120] {
                let start = AnimatedPoint(x: 1.4, y: 0.6)
                let result = drag(handle, by: .zero, from: start, rotationDegrees: rotation)
                #expect(abs(result.x - start.x) < 1e-6)
                #expect(abs(result.y - start.y) < 1e-6)
            }
        }
    }

    @Test func aCornerDragClampsToTheScaleRange() {
        let huge = drag(.bottomTrailing, by: CGSize(width: half * 40, height: half * 40))
        #expect(huge.x == AnimatedCanvasGeometry.scaleRange.upperBound)

        // Dragging past the centre inverts the corner; scale stays positive at its floor rather
        // than flipping the layer, which the model has no representation for.
        let inverted = drag(.bottomTrailing, by: CGSize(width: -half * 3, height: -half * 3))
        #expect(inverted.x == AnimatedCanvasGeometry.scaleRange.lowerBound)
        #expect(inverted.y == AnimatedCanvasGeometry.scaleRange.lowerBound)
    }

    @Test func aCornerDragSnapsBackToOne() {
        let nudged = drag(.bottomTrailing, by: CGSize(width: half * 0.005, height: half * 0.005))
        #expect(nudged.x == 1)
        #expect(nudged.y == 1)
    }

    /// Everything a gesture writes goes into a document the server byte-compares, so a corner drag
    /// has to land on the same rounding grid the compiler emits.
    @Test func cornerDragsProduceCompilerRoundedValues() {
        let result = drag(.bottomTrailing, by: CGSize(width: 37.31313, height: -11.7777))
        #expect(result.x == AnimationCompiler.roundValue(result.x))
        #expect(result.y == AnimationCompiler.roundValue(result.y))
    }

    /// A degenerate box would divide by zero. `GeometryReader` reports `.zero` on its first pass.
    @Test func aZeroBoxLeavesTheScaleAlone() {
        let result = AnimatedCanvasGeometry.handleScale(
            start: AnimatedPoint(x: 1.5, y: 1.5),
            handle: .bottomTrailing,
            translation: CGSize(width: 40, height: 40),
            rotationDegrees: 0,
            box: .zero,
            uniform: false
        )
        #expect(result == AnimatedPoint(x: 1.5, y: 1.5))
    }
}
