import Foundation
import Testing
@testable import AnimatedView

/// `arcTo` is covered numerically by `CompilerParityTests`, which compares it against the
/// TypeScript compiler sample for sample. These cover the properties that reading a column of
/// numbers would not make obvious: that the arc lands on its target, bows the way the sign says it
/// does regardless of travel direction, and never re-eases its own samples.
struct ArcCompilerTests {
    private let timing = AnimationTiming(kind: .animated, durationSeconds: 4)

    private func anchor(_ x: Double, _ y: Double) -> AnimatedAnchor {
        .init(position: .init(x: x, y: y), scale: .init(x: 1, y: 1), rotationDegrees: 0, opacity: 1, trim: .full)
    }

    @Test func landsExactlyOnItsTarget() throws {
        let compiled = try AnimationCompiler.compile(
            [.arcTo(x: 0.9, y: 0.3, duration: 1)],
            anchor: anchor(0.2, 0.7),
            timing: timing
        )
        #expect(compiled.position.count == AnimationCompiler.arcSegments + 1)
        let first = try #require(compiled.position.first)
        let last = try #require(compiled.position.last)
        #expect(first.x == 0.2 && first.y == 0.7)
        #expect(last.x == 0.9 && last.y == 0.3)
        #expect(last.timeSeconds == 1)
    }

    @Test func apexSitsArcHeightAboveTheChord() throws {
        // A horizontal travel, so the chord's midpoint is (0.5, 0.5) and an apex 0.25 above it is
        // y = 0.25 — negative y being up.
        let compiled = try AnimationCompiler.compile(
            [.arcTo(x: 0.9, y: 0.5, arcHeight: 0.25, duration: 1)],
            anchor: anchor(0.1, 0.5),
            timing: timing
        )
        let apex = compiled.position[AnimationCompiler.arcSegments / 2]
        #expect(apex.x == 0.5)
        #expect(apex.y == 0.25)
    }

    @Test func arcsOverTheTopInEitherDirection() throws {
        // The perpendicular of the travel vector flips with direction; without the sign
        // normalisation in `arcControlPoint` one of these two would sag instead of arc.
        let rightward = try AnimationCompiler.compile(
            [.arcTo(x: 0.9, y: 0.5, arcHeight: 0.3, duration: 1)],
            anchor: anchor(0.1, 0.5),
            timing: timing
        )
        let leftward = try AnimationCompiler.compile(
            [.arcTo(x: 0.1, y: 0.5, arcHeight: 0.3, duration: 1)],
            anchor: anchor(0.9, 0.5),
            timing: timing
        )
        #expect(rightward.position.allSatisfy { $0.y <= 0.5 })
        #expect(leftward.position.allSatisfy { $0.y <= 0.5 })
        #expect(rightward.position.map(\.y) == leftward.position.map(\.y).reversed())
    }

    @Test func returningToTheAnchorIsAStraightUpToss() throws {
        let compiled = try AnimationCompiler.compile(
            [.arcTo(x: 0.4, y: 0.6, arcHeight: 0.2, duration: 1)],
            anchor: anchor(0.4, 0.6),
            timing: timing
        )
        #expect(compiled.position.allSatisfy { $0.x == 0.4 })
        #expect(compiled.position.first?.y == 0.6)
        #expect(compiled.position.last?.y == 0.6)
        #expect(compiled.position.contains { $0.y < 0.45 })
    }

    @Test func samplesAreLinearSoTheInterpolatorDoesNotReEaseThem() throws {
        // The easing is baked into where each sample sits. Leaving it on the keyframes would drop
        // the velocity to zero eleven times over, which is exactly the stutter this replaces.
        let compiled = try AnimationCompiler.compile(
            [.arcTo(x: 0.9, y: 0.2, duration: 1, easing: .springBouncy)],
            timing: timing
        )
        #expect(compiled.position.allSatisfy { $0.easing == .linear })
    }

    @Test func aSpringStaysOnThePathInsteadOfExtrapolating() throws {
        // springBouncy's eased progress exceeds 1, and an unclamped Bézier parameter would throw the
        // layer clean off the canvas rather than overshoot along the arc.
        let compiled = try AnimationCompiler.compile(
            [.arcTo(x: 0.9, y: 0.5, arcHeight: 0, duration: 1, easing: .springBouncy)],
            anchor: anchor(0.1, 0.5),
            timing: timing
        )
        #expect(compiled.position.allSatisfy { $0.x >= 0.1 && $0.x <= 0.9 })
    }

    @Test func arcHeightZeroIsExactlyAStraightLine() throws {
        let compiled = try AnimationCompiler.compile(
            [.arcTo(x: 0.9, y: 0.9, arcHeight: 0, duration: 1)],
            timing: timing
        )
        // Every sample sits on the chord from (0.5, 0.5) to (0.9, 0.9), where x and y move together.
        #expect(compiled.position.allSatisfy { abs($0.x - $0.y) < 1e-9 })
    }

    @Test func cannotBeChainedBecauseEverySpecDepartsFromTheAnchor() throws {
        // The second arc starts at the anchor while the first has left the layer at its target, so
        // the shared boundary keyframe is a real discontinuity. Not specific to arcTo — moveTo does
        // the same — but it is the trap a "bounce it across the frame" instruction walks into.
        #expect(throws: AnimationCompileError.self) {
            try AnimationCompiler.compile(
                [
                    .arcTo(x: 0.9, y: 0.5, delay: 0, duration: 1),
                    .arcTo(x: 0.2, y: 0.5, delay: 1, duration: 1)
                ],
                timing: timing
            )
        }
    }
}
