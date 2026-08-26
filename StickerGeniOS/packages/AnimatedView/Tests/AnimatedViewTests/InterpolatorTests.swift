import Foundation
import Testing
@testable import AnimatedView

struct InterpolatorTests {
    private func document(
        loop: AnimatedLoop = .loop,
        duration: Double = 2,
        speed: Double = 1,
        layers: [AnimatedLayer] = []
    ) -> AnimatedDocument {
        .init(kind: .animated, durationSeconds: duration, fps: 30, loop: loop, speed: speed, layers: layers)
    }

    private func layer(_ animation: AnimatedLayerAnimation, anchor: AnimatedAnchor = .default) -> AnimatedLayer {
        .shape(.init(
            base: .init(id: "layer", name: "Layer", anchor: anchor, animation: animation),
            shape: .circle,
            fill: .solid("#FFFFFF")
        ))
    }

    // MARK: - Time mapping

    @Test func loopWrapsWithinDuration() {
        let subject = document(loop: .loop, duration: 2)
        #expect(AnimationInterpolator.mappedTime(0, document: subject) == 0)
        #expect(AnimationInterpolator.mappedTime(2.5, document: subject) == 0.5)
        #expect(AnimationInterpolator.mappedTime(4, document: subject) == 0)
    }

    @Test func onceClampsAtTheEnd() {
        let subject = document(loop: .once, duration: 2)
        #expect(AnimationInterpolator.mappedTime(9, document: subject) == 2)
        #expect(AnimationInterpolator.mappedTime(-3, document: subject) == 0)
    }

    @Test func pingPongReversesAndDoublesTheCycle() {
        let subject = document(loop: .pingPong, duration: 2)
        #expect(AnimationInterpolator.mappedTime(1, document: subject) == 1)
        #expect(abs(AnimationInterpolator.mappedTime(3, document: subject) - 1) < 1e-9)
        #expect(abs(AnimationInterpolator.mappedTime(3.5, document: subject) - 0.5) < 1e-9)
        #expect(subject.renderedCycleDuration == 4)
    }

    // MARK: - Speed

    @Test func speedScalesElapsedTimeWithoutTouchingKeyframes() {
        let fast = document(duration: 2, speed: 2)
        // Twice the speed means the document reaches its midpoint in half the wall-clock time.
        #expect(AnimationInterpolator.mappedTime(0.5, document: fast) == 1)
        #expect(fast.playbackDuration == 1)
        #expect(fast.renderedCycleDuration == 1)

        let slow = document(duration: 2, speed: 0.5)
        #expect(AnimationInterpolator.mappedTime(2, document: slow) == 1)
        #expect(slow.playbackDuration == 4)
    }

    @Test func speedCompoundsWithPingPong() {
        let subject = document(loop: .pingPong, duration: 2, speed: 2)
        #expect(subject.renderedCycleDuration == 2)
        // Half a wall-clock cycle in, the document is at its far end and about to come back.
        #expect(abs(AnimationInterpolator.mappedTime(0.5, document: subject) - 1) < 1e-9)
    }

    @Test func staticDocumentsAlwaysSampleAtZero() {
        let subject = AnimatedDocument(kind: .static, layers: [])
        #expect(AnimationInterpolator.mappedTime(7, document: subject) == 0)
        #expect(subject.renderedCycleDuration == 0)
    }

    // MARK: - Channels

    @Test func emptyChannelsFallBackToTheAnchor() {
        let anchor = AnimatedAnchor(
            position: .init(x: 0.2, y: 0.8),
            scale: .init(x: 2, y: 3),
            rotationDegrees: 45,
            opacity: 0.25
        )
        let state = AnimationInterpolator.state(for: layer(.empty, anchor: anchor), atDocumentTime: 1)
        #expect(state.position == anchor.position)
        #expect(state.scale == anchor.scale)
        #expect(state.rotationDegrees == 45)
        #expect(state.opacity == 0.25)
        #expect(state.trim == .full)
        #expect(state.effects == .identity)
    }

    @Test func valuesClampOutsideTheKeyframeRange() {
        let animation = AnimatedLayerAnimation(opacity: [
            .init(timeSeconds: 1, value: 0.2),
            .init(timeSeconds: 2, value: 0.8),
        ])
        let subject = layer(animation)
        #expect(AnimationInterpolator.state(for: subject, atDocumentTime: 0).opacity == 0.2)
        #expect(AnimationInterpolator.state(for: subject, atDocumentTime: 5).opacity == 0.8)
    }

    @Test func easingComesFromTheUpperKeyframe() {
        // The lower keyframe's easing must be ignored. If it were read instead, `linear` here would
        // put the midpoint at exactly 0.5 rather than on the ease-in curve.
        let animation = AnimatedLayerAnimation(opacity: [
            .init(timeSeconds: 0, value: 0, easing: .linear),
            .init(timeSeconds: 1, value: 1, easing: .easeIn),
        ])
        let midpoint = AnimationInterpolator.state(for: layer(animation), atDocumentTime: 0.5).opacity
        #expect(abs(midpoint - AnimationInterpolator.easedProgress(0.5, easing: .easeIn)) < 1e-9)
        #expect(midpoint < 0.2)
    }

    @Test func unsortedKeyframesStillInterpolateInTimeOrder() {
        let animation = AnimatedLayerAnimation(rotation: [
            .init(timeSeconds: 2, degrees: 180),
            .init(timeSeconds: 0, degrees: 0),
            .init(timeSeconds: 1, degrees: 90, easing: .linear),
        ])
        #expect(AnimationInterpolator.state(for: layer(animation), atDocumentTime: 1).rotationDegrees == 90)
    }

    @Test func trimChannelInterpolates() {
        let animation = AnimatedLayerAnimation(trim: [
            .init(timeSeconds: 0, start: 0, end: 0),
            .init(timeSeconds: 2, start: 0, end: 1, easing: .linear),
        ])
        let midpoint = AnimationInterpolator.state(for: layer(animation), atDocumentTime: 1).trim
        #expect(midpoint.start == 0)
        #expect(abs(midpoint.end - 0.5) < 1e-9)
    }

    @Test func effectsBlendEveryComponent() {
        let animation = AnimatedLayerAnimation(effects: [
            .init(timeSeconds: 0, blurRadius: 10, hueDegrees: -100, saturation: 0),
            .init(timeSeconds: 2, blurRadius: 0, hueDegrees: 100, saturation: 2, easing: .linear),
        ])
        let midpoint = AnimationInterpolator.state(for: layer(animation), atDocumentTime: 1).effects
        #expect(abs(midpoint.blurRadius - 5) < 1e-9)
        #expect(abs(midpoint.hueDegrees) < 1e-9)
        #expect(abs(midpoint.saturation - 1) < 1e-9)
    }

    // MARK: - Easing

    @Test(arguments: AnimatedEasing.allCases)
    func easingIsPinnedAtBothEnds(_ easing: AnimatedEasing) {
        #expect(AnimationInterpolator.easedProgress(0, easing: easing) == 0)
        // The spring curves overshoot on the way and settle at 1 — anything else would leave a
        // layer permanently off its anchor at the end of an animation.
        #expect(abs(AnimationInterpolator.easedProgress(1, easing: easing) - 1) < 0.01)
    }

    @Test func easingClampsOutOfRangeProgress() {
        #expect(AnimationInterpolator.easedProgress(-4, easing: .easeInOut) == 0)
        #expect(AnimationInterpolator.easedProgress(9, easing: .linear) == 1)
    }
}
