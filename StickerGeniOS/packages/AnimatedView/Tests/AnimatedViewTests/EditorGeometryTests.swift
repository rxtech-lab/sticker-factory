import CoreGraphics
import Foundation
import Testing
@testable import AnimatedView

/// The gesture math the canvas editor is built on.
///
/// Everything here is a pure function, so these tests are the cheapest place to catch the class of
/// bug that otherwise shows up as "my layer jumps when I start dragging" — which is nearly
/// impossible to diagnose by hand once it is buried under a gesture recogniser.
struct EditorGeometryTests {
    private func shape(
        id: String = "shape",
        anchor: AnimatedAnchor = .default,
        hidden: Bool = false
    ) -> AnimatedLayer {
        .shape(.init(
            base: .init(id: id, name: id, hidden: hidden, anchor: anchor),
            shape: .circle,
            fill: .solid("#FFFFFF")
        ))
    }

    private func document(canvas: AnimatedCanvas = .init(), layers: [AnimatedLayer]) -> AnimatedDocument {
        .init(canvas: canvas, kind: .static, layers: layers)
    }

    // MARK: - Letterboxing

    @Test func contentRectFillsASquareContainerWithASquareCanvas() {
        let rect = AnimatedCanvasGeometry.contentRect(in: CGSize(width: 300, height: 300), aspectRatio: 1)
        #expect(rect == CGRect(x: 0, y: 0, width: 300, height: 300))
    }

    @Test func contentRectPillarboxesATallCanvasInAWideContainer() {
        // A 1:2 canvas in a 400x200 box fits to the height and is centred horizontally.
        let rect = AnimatedCanvasGeometry.contentRect(in: CGSize(width: 400, height: 200), aspectRatio: 0.5)
        #expect(rect == CGRect(x: 150, y: 0, width: 100, height: 200))
    }

    @Test func contentRectLetterboxesAWideCanvasInASquareContainer() {
        // 1024x384 is 8:3; in a 240pt square it fits to the width and is centred vertically.
        let rect = AnimatedCanvasGeometry.contentRect(in: CGSize(width: 240, height: 240), aspectRatio: 1024.0 / 384.0)
        #expect(abs(rect.width - 240) < 1e-9)
        #expect(abs(rect.height - 90) < 1e-9)
        #expect(abs(rect.minY - 75) < 1e-9)
        #expect(abs(rect.minX) < 1e-9)
    }

    /// A `GeometryReader` reports `.zero` on its first layout pass, and an aspect ratio of zero is
    /// reachable from a malformed canvas. Neither may produce a NaN that then poisons every
    /// subsequent coordinate conversion.
    @Test func contentRectIsZeroForDegenerateInput() {
        #expect(AnimatedCanvasGeometry.contentRect(in: .zero, aspectRatio: 1) == .zero)
        #expect(AnimatedCanvasGeometry.contentRect(in: CGSize(width: 100, height: 100), aspectRatio: 0) == .zero)
        #expect(AnimatedCanvasGeometry.contentRect(in: CGSize(width: 100, height: -5), aspectRatio: 1) == .zero)
    }

    @Test func normalizedAndDenormalizedRoundTrip() {
        let rect = CGRect(x: 12, y: 30, width: 240, height: 90)
        for point in [AnimatedPoint.center, .zero, .init(x: 0.25, y: 0.75), .init(x: 1, y: 1)] {
            let round = AnimatedCanvasGeometry.normalized(
                AnimatedCanvasGeometry.denormalized(point, in: rect),
                in: rect
            )
            #expect(abs(round.x - point.x) < 1e-9)
            #expect(abs(round.y - point.y) < 1e-9)
        }
    }

    /// Conversion is relative to the rect's *size*, not its origin: the stage frames the artwork to
    /// `contentRect` and reads gestures in that view's local space, so the letterbox offset has
    /// already been applied by the time a point arrives here.
    @Test func normalizedIgnoresTheRectOrigin() {
        let point = CGPoint(x: 60, y: 45)
        let atOrigin = AnimatedCanvasGeometry.normalized(point, in: CGRect(x: 0, y: 0, width: 240, height: 90))
        let offset = AnimatedCanvasGeometry.normalized(point, in: CGRect(x: 100, y: 200, width: 240, height: 90))
        #expect(atOrigin == offset)
    }

    // MARK: - Layout boxes

    @Test func layoutBoxUsesTheSharedFitFactorExceptForParticles() {
        let canvas = CGSize(width: 200, height: 100)
        let fitted = AnimatedCanvasGeometry.layoutBox(canvasSize: canvas, isParticle: false)
        #expect(fitted.width == 200 * AnimatedIconFrame.layerFit)
        #expect(fitted.height == 100 * AnimatedIconFrame.layerFit)
        #expect(AnimatedCanvasGeometry.layoutBox(canvasSize: canvas, isParticle: true) == canvas)
    }

    /// The renderer collapses a text layer's scale to `min(x, y)` on both axes. If the editor did
    /// not do the same, a selection outline would sit at a size the artwork never renders at.
    @Test func renderedScaleCollapsesTextToUniform() {
        let scale = AnimatedPoint(x: 2, y: 0.5)
        #expect(AnimatedCanvasGeometry.renderedScale(scale, isText: false) == scale)
        let text = AnimatedCanvasGeometry.renderedScale(scale, isText: true)
        #expect(text.x == 0.5)
        #expect(text.y == 0.5)
    }

    // MARK: - Drag

    @Test func draggedPositionConvertsTranslationAgainstTheContentRect() {
        // A 2.67:1 canvas: the same pixel translation is a bigger normalized step horizontally.
        let rect = CGRect(x: 0, y: 0, width: 240, height: 90)
        let moved = AnimatedCanvasGeometry.draggedPosition(
            start: .center,
            translation: CGSize(width: 24, height: 9),
            in: rect,
            snapping: false
        )
        #expect(abs(moved.x - 0.6) < 1e-9)
        #expect(abs(moved.y - 0.6) < 1e-9)
    }

    @Test func draggedPositionClampsToTheStorableRange() {
        let rect = CGRect(x: 0, y: 0, width: 100, height: 100)
        let far = AnimatedCanvasGeometry.draggedPosition(
            start: .center, translation: CGSize(width: 900, height: -900), in: rect, snapping: false
        )
        #expect(far.x == AnimatedCanvasGeometry.positionRange.upperBound)
        #expect(far.y == AnimatedCanvasGeometry.positionRange.lowerBound)

        // And the clamped result must still satisfy the model's own validation.
        var anchor = AnimatedAnchor.default
        anchor.position = far
        #expect(anchor.isValid)
    }

    @Test func draggedPositionSnapsToTheCentre() {
        let rect = CGRect(x: 0, y: 0, width: 100, height: 100)
        // 0.4 of a point off centre — well inside the tolerance.
        let snapped = AnimatedCanvasGeometry.draggedPosition(
            start: AnimatedPoint(x: 0.496, y: 0.2), translation: CGSize(width: 0, height: 0), in: rect
        )
        #expect(snapped.x == 0.5)
        #expect(snapped.y == 0.2)
    }

    @Test func draggedPositionIsInertWhenTheRectIsEmpty() {
        let start = AnimatedPoint(x: 0.3, y: 0.7)
        let result = AnimatedCanvasGeometry.draggedPosition(start: start, translation: CGSize(width: 50, height: 50), in: .zero)
        #expect(result == start)
    }

    // MARK: - Pinch

    @Test func magnifiedScaleMultipliesTheStartingScale() {
        let scaled = AnimatedCanvasGeometry.magnifiedScale(start: .unit, magnification: 1.5, uniform: false)
        #expect(scaled.x == 1.5)
        #expect(scaled.y == 1.5)
    }

    @Test func magnifiedScaleClampsToTheStorableRange() {
        let huge = AnimatedCanvasGeometry.magnifiedScale(start: .unit, magnification: 100, uniform: false)
        #expect(huge.x == AnimatedCanvasGeometry.scaleRange.upperBound)
        let tiny = AnimatedCanvasGeometry.magnifiedScale(start: .unit, magnification: 0.0001, uniform: false)
        #expect(tiny.x == AnimatedCanvasGeometry.scaleRange.lowerBound)

        var anchor = AnimatedAnchor.default
        anchor.scale = huge
        #expect(anchor.isValid)
        anchor.scale = tiny
        #expect(anchor.isValid)
    }

    @Test func magnifiedScaleStaysUniformForText() {
        let result = AnimatedCanvasGeometry.magnifiedScale(
            start: AnimatedPoint(x: 2, y: 0.5), magnification: 2, uniform: true
        )
        #expect(result.x == result.y)
        #expect(result.x == 1)
    }

    /// SwiftUI can report a zero or non-finite magnification on the first event of a pinch.
    @Test func magnifiedScaleIgnoresNonFiniteMagnification() {
        let start = AnimatedPoint(x: 1.25, y: 1.25)
        #expect(AnimatedCanvasGeometry.magnifiedScale(start: start, magnification: .nan, uniform: false) == start)
        #expect(AnimatedCanvasGeometry.magnifiedScale(start: start, magnification: 0, uniform: false) == start)
    }

    // MARK: - Rotation

    @Test func rotatedDegreesAddsTheDelta() {
        #expect(AnimatedCanvasGeometry.rotatedDegrees(start: 10, delta: 23, snapping: false) == 33)
    }

    @Test func rotatedDegreesSnapsToFifteens() {
        #expect(AnimatedCanvasGeometry.rotatedDegrees(start: 0, delta: 44) == 45)
        #expect(AnimatedCanvasGeometry.rotatedDegrees(start: 0, delta: 38) == 38)
    }

    /// The anchor is compiler input and `AnimationCompiler.rotation` clamps to ±1080, so an anchor
    /// outside that range would make a declarative document stop equalling its own recompilation.
    /// Raw keyframes are not compiler input and keep the model's wider range.
    @Test func rotatedDegreesUsesADifferentRangeForAnchorsAndKeyframes() {
        let anchor = AnimatedCanvasGeometry.rotatedDegrees(
            start: 0, delta: 5000, snapping: false, range: AnimatedCanvasGeometry.anchorRotationRange
        )
        #expect(anchor == 1080)

        let keyframe = AnimatedCanvasGeometry.rotatedDegrees(
            start: 0, delta: 5000, snapping: false, range: AnimatedCanvasGeometry.keyframeRotationRange
        )
        #expect(keyframe == 3600)

        var settled = AnimatedAnchor.default
        settled.rotationDegrees = anchor
        #expect(settled.isValid)
    }

    // MARK: - Hit testing

    private let rect = CGRect(x: 0, y: 0, width: 200, height: 200)

    @Test func hitTestFindsTheLayerUnderThePoint() {
        let subject = document(layers: [shape(id: "only")])
        #expect(AnimatedCanvasGeometry.hitTest(CGPoint(x: 100, y: 100), document: subject, atDocumentTime: 0, in: rect) == "only")
    }

    @Test func hitTestMissesOutsideTheBox() {
        let subject = document(layers: [shape(id: "only")])
        // The fit box is 0.86 * 200 = 172pt wide, so it ends 14pt from each edge; 8pt of slop
        // leaves a 6pt dead band. 2pt in from the edge is outside it.
        #expect(AnimatedCanvasGeometry.hitTest(CGPoint(x: 2, y: 100), document: subject, atDocumentTime: 0, in: rect) == nil)
    }

    @Test func hitTestPrefersTheTopMostLayer() {
        let subject = document(layers: [shape(id: "bottom"), shape(id: "top")])
        #expect(AnimatedCanvasGeometry.hitTest(CGPoint(x: 100, y: 100), document: subject, atDocumentTime: 0, in: rect) == "top")
    }

    @Test func hitTestSkipsHiddenLayers() {
        let subject = document(layers: [shape(id: "bottom"), shape(id: "top", hidden: true)])
        #expect(AnimatedCanvasGeometry.hitTest(CGPoint(x: 100, y: 100), document: subject, atDocumentTime: 0, in: rect) == "bottom")
    }

    /// A particle layer is framed to the whole canvas, so on z-order alone it would swallow every
    /// tap on the stage. It has to lose to anything else that also contains the point.
    @Test func hitTestLetsTapsFallThroughAParticleLayerToShapesBelowIt() {
        let particle = AnimatedLayer.particle(.init(
            base: .init(id: "sparkles", name: "Sparkles"),
            preset: .sparkles
        ))
        // The particle layer is on top, and yet the shape underneath wins.
        let subject = document(layers: [shape(id: "face"), particle])
        #expect(AnimatedCanvasGeometry.hitTest(CGPoint(x: 100, y: 100), document: subject, atDocumentTime: 0, in: rect) == "face")

        // Away from the shape but still on canvas, the particle field is selectable.
        #expect(AnimatedCanvasGeometry.hitTest(CGPoint(x: 4, y: 4), document: subject, atDocumentTime: 0, in: rect) == "sparkles")
    }

    /// A rotated layer must be tested against its oriented rectangle, not its bounding box —
    /// otherwise the corners of a 45° layer would register as hits on empty space.
    @Test func hitTestRespectsRotation() {
        var anchor = AnimatedAnchor.default
        anchor.rotationDegrees = 45
        // A narrow, tall layer rotated 45°: the point along its rotated long axis hits, and the
        // point the same distance along the unrotated axis misses.
        anchor.scale = AnimatedPoint(x: 0.1, y: 1)
        let subject = document(layers: [shape(id: "bar", anchor: anchor)])

        let alongRotatedAxis = CGPoint(x: 100 + 40, y: 100 - 40)
        let alongOriginalAxis = CGPoint(x: 100, y: 100 - 56)
        #expect(AnimatedCanvasGeometry.hitTest(alongRotatedAxis, document: subject, atDocumentTime: 0, in: rect) == "bar")
        #expect(AnimatedCanvasGeometry.hitTest(alongOriginalAxis, document: subject, atDocumentTime: 0, in: rect) == nil)
    }

    /// Hit-testing samples the interpolated state, so a moving layer is selectable where it
    /// currently *is*, not where its anchor says it rests.
    @Test func hitTestFollowsAnimationToTheScrubbedTime() {
        let animation = AnimatedLayerAnimation(position: [
            .init(timeSeconds: 0, x: 0.5, y: 0.5),
            .init(timeSeconds: 2, x: 0.5, y: 0.1),
        ])
        let moving = AnimatedLayer.shape(.init(
            base: .init(id: "mover", name: "Mover", animation: animation),
            shape: .circle,
            fill: .solid("#FFFFFF")
        ))
        var subject = document(layers: [moving])
        subject.kind = .animated
        subject.durationSeconds = 2

        // The layer's half-height is 172/2 + 8pt of slop = 94pt. At rest it is centred at y=100 and
        // so covers 6...194; at t=2 it has risen to y=20 and covers -74...114. y=3 is the band that
        // separates the two.
        #expect(AnimatedCanvasGeometry.hitTest(CGPoint(x: 100, y: 100), document: subject, atDocumentTime: 0, in: rect) == "mover")
        #expect(AnimatedCanvasGeometry.hitTest(CGPoint(x: 100, y: 3), document: subject, atDocumentTime: 2, in: rect) == "mover")
        #expect(AnimatedCanvasGeometry.hitTest(CGPoint(x: 100, y: 3), document: subject, atDocumentTime: 0, in: rect) == nil)
    }

    /// A text layer's outline follows the collapsed uniform scale, so hit-testing must too.
    @Test func hitTestUsesTheCollapsedScaleForText() {
        var anchor = AnimatedAnchor.default
        anchor.scale = AnimatedPoint(x: 2, y: 0.2)
        let text = AnimatedLayer.text(.init(
            base: .init(id: "caption", name: "Caption", anchor: anchor),
            text: "Hi"
        ))
        let subject = document(layers: [text])

        // Rendered scale is min(2, 0.2) = 0.2, so the box is 172 * 0.2 = 34.4pt wide (±17.2 plus
        // 8pt slop = 25.2). A point 60pt out would hit at scale.x = 2 but must miss at 0.2.
        #expect(AnimatedCanvasGeometry.hitTest(CGPoint(x: 160, y: 100), document: subject, atDocumentTime: 0, in: rect) == nil)
        #expect(AnimatedCanvasGeometry.hitTest(CGPoint(x: 110, y: 100), document: subject, atDocumentTime: 0, in: rect) == "caption")
    }
}
