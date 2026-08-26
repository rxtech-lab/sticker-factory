import Foundation
import Testing
@testable import AnimatedView

/// Raw keyframe editing: insert, retime, delete, easing, and the whole-track time changes a
/// duration edit depends on.
///
/// The invariants under test are the ones the interpolator and the compiler silently assume —
/// sorted tracks, no two keyframes sharing an instant, and values rounded exactly the way the
/// compiler rounds them. Violating any of them produces a document that either renders
/// unpredictably or fails the server's byte-comparison, both of which are far harder to diagnose
/// later than here.
struct EditorKeyframeTests {
    private func animation(
        opacity: [OpacityKeyframe] = [],
        position: [PositionKeyframe] = []
    ) -> AnimatedLayerAnimation {
        .init(position: position, opacity: opacity)
    }

    private func layer(_ animation: AnimatedLayerAnimation, anchor: AnimatedAnchor = .default) -> AnimatedLayer {
        .shape(.init(
            base: .init(id: "layer", name: "Layer", anchor: anchor, animation: animation),
            shape: .circle,
            fill: .solid("#FFFFFF")
        ))
    }

    private func document(_ animation: AnimatedLayerAnimation, duration: Double = 2) -> AnimatedDocument {
        .init(kind: .animated, durationSeconds: duration, layers: [layer(animation)])
    }

    // MARK: - Insert

    /// A new keyframe takes the value the layer already had at that instant, so adding one is
    /// visually inert. Anything else would make "add a keyframe" a destructive act.
    @Test func insertingSamplesTheInterpolatedStateSoNothingMoves() throws {
        let source = animation(opacity: [
            .init(timeSeconds: 0, value: 0),
            .init(timeSeconds: 2, value: 1),
        ])
        let before = AnimationInterpolator.state(for: layer(source), atDocumentTime: 1)
        let edited = try source.insertingKeyframe(on: .opacity, atTime: 1, sampledFrom: before)
        let after = AnimationInterpolator.state(for: layer(edited), atDocumentTime: 1)

        #expect(edited.opacity.count == 3)
        #expect(abs(after.opacity - before.opacity) < 1e-6)
        // Not just at the insertion point — the whole curve is unchanged.
        for time in stride(from: 0.0, through: 2.0, by: 0.2) {
            let original = AnimationInterpolator.state(for: layer(source), atDocumentTime: time)
            let now = AnimationInterpolator.state(for: layer(edited), atDocumentTime: time)
            #expect(abs(original.opacity - now.opacity) < 1e-6, "the curve moved at t=\(time)")
        }
    }

    /// An empty channel falls back to the anchor, so a keyframe inserted into one has to capture
    /// the anchor's value — not the channel default — or the layer jumps the moment it is added.
    @Test func insertingIntoAnEmptyChannelCapturesTheAnchor() throws {
        var anchor = AnimatedAnchor.default
        anchor.opacity = 0.3
        let subject = layer(.empty, anchor: anchor)
        let state = AnimationInterpolator.state(for: subject, atDocumentTime: 0.5)

        let edited = try AnimatedLayerAnimation.empty.insertingKeyframe(on: .opacity, atTime: 0.5, sampledFrom: state)
        #expect(edited.opacity.count == 1)
        #expect(edited.opacity[0].value == 0.3)
    }

    /// Easing governs the segment *ending* at a keyframe, so a keyframe dropped into the middle of
    /// a track redefines the curve leading up to it. Inheriting the split segment's easing is what
    /// keeps an insert from visibly re-shaping motion the user never touched.
    @Test func insertingInheritsTheEasingOfTheSegmentItSplits() throws {
        let source = animation(opacity: [
            .init(timeSeconds: 0, value: 0, easing: .linear),
            .init(timeSeconds: 2, value: 1, easing: .springBouncy),
        ])
        let split = try source.insertingKeyframe(on: .opacity, atTime: 1, sampledFrom: .resting)
        #expect(split.opacity[1].easing == .springBouncy)
        // The keyframe that used to close the segment keeps its own easing.
        #expect(split.opacity[2].easing == .springBouncy)
    }

    /// Past the last keyframe there is no segment to inherit from, and easing on a trailing
    /// keyframe with nothing after it is unobservable anyway.
    @Test func insertingPastTheLastKeyframeFallsBackToLinear() throws {
        let source = animation(opacity: [.init(timeSeconds: 0, value: 0, easing: .easeInOut)])
        let appended = try source.insertingKeyframe(on: .opacity, atTime: 1, sampledFrom: .resting)
        #expect(appended.opacity[1].easing == .linear)
    }

    @Test func insertingKeepsTheChannelSorted() throws {
        var subject = AnimatedLayerAnimation.empty
        for time in [1.5, 0.25, 2.0, 0.75] {
            subject = try subject.insertingKeyframe(on: .opacity, atTime: time, sampledFrom: .resting)
        }
        #expect(subject.times(on: .opacity) == [0.25, 0.75, 1.5, 2.0])
    }

    /// Two keyframes at one instant have no defined blend: the interpolator picks arbitrarily and
    /// the compiler treats a collision as an error.
    @Test func insertingOnAnExistingTimeIsRefused() throws {
        let subject = animation(opacity: [.init(timeSeconds: 1, value: 1)])
        #expect(throws: AnimatedEditorError.duplicateKeyframeTime(.opacity, 1)) {
            try subject.insertingKeyframe(on: .opacity, atTime: 1, sampledFrom: .resting)
        }
    }

    /// Times are rounded to four decimals on the way in, so two requests that differ below that
    /// resolution collide once stored — the check has to happen after rounding, not before.
    @Test func insertingDetectsACollisionThatOnlyAppearsAfterRounding() throws {
        let subject = try AnimatedLayerAnimation.empty
            .insertingKeyframe(on: .opacity, atTime: 1.00001, sampledFrom: .resting)
        #expect(subject.times(on: .opacity) == [1])
        #expect(throws: (any Error).self) {
            try subject.insertingKeyframe(on: .opacity, atTime: 1.000004, sampledFrom: .resting)
        }
    }

    @Test func insertingBeyondTheChannelCapIsRefused() throws {
        var subject = AnimatedLayerAnimation.empty
        for index in 0..<AnimatedLayerAnimation.maximumKeyframesPerChannel {
            subject = try subject.insertingKeyframe(on: .opacity, atTime: Double(index) * 0.01, sampledFrom: .resting)
        }
        #expect(subject.count(of: .opacity) == 32)
        #expect(throws: AnimatedEditorError.keyframeLimitReached(.opacity)) {
            try subject.insertingKeyframe(on: .opacity, atTime: 9, sampledFrom: .resting)
        }
    }

    /// The per-channel cap is not the only ceiling — the document has a shared budget of 128, and
    /// a layer can hit it while every individual channel still has room.
    @Test func theDocumentKeyframeBudgetIsEnforcedOnWrite() throws {
        // Six channels at 21 frames each is 126; two more channels' worth would pass the per-channel
        // cap but breach the document total.
        var full = AnimatedLayerAnimation.empty
        for index in 0..<21 {
            let t = Double(index) * 0.05
            full = try full.insertingKeyframe(on: .position, atTime: t, sampledFrom: .resting)
            full = try full.insertingKeyframe(on: .scale, atTime: t, sampledFrom: .resting)
            full = try full.insertingKeyframe(on: .rotation, atTime: t, sampledFrom: .resting)
            full = try full.insertingKeyframe(on: .opacity, atTime: t, sampledFrom: .resting)
            full = try full.insertingKeyframe(on: .effects, atTime: t, sampledFrom: .resting)
            full = try full.insertingKeyframe(on: .trim, atTime: t, sampledFrom: .resting)
        }
        #expect(full.keyframeCount == 126)

        let subject = document(full)
        let overBudget = try full.insertingKeyframe(on: .opacity, atTime: 1.9, sampledFrom: .resting)
            .insertingKeyframe(on: .trim, atTime: 1.9, sampledFrom: .resting)
            .insertingKeyframe(on: .scale, atTime: 1.9, sampledFrom: .resting)
        #expect(throws: AnimatedEditorError.documentKeyframeLimitReached) {
            try subject.settingAnimation(overBudget, forLayer: "layer")
        }
    }

    // MARK: - Retime

    @Test func retimingClampsIntoTheDocumentTimeline() throws {
        let subject = animation(opacity: [.init(timeSeconds: 1, value: 1)])
        #expect(try subject.movingKeyframe(on: .opacity, index: 0, toTime: 99, clampedTo: 2).times(on: .opacity) == [2])
        #expect(try subject.movingKeyframe(on: .opacity, index: 0, toTime: -5, clampedTo: 2).times(on: .opacity) == [0])
    }

    /// Dragging a keyframe past its neighbour is a legitimate edit and simply reorders the track.
    @Test func retimingAcrossANeighbourReordersRatherThanFailing() throws {
        let subject = animation(opacity: [
            .init(timeSeconds: 0, value: 0),
            .init(timeSeconds: 0.5, value: 0.5),
            .init(timeSeconds: 1, value: 1),
        ])
        let moved = try subject.movingKeyframe(on: .opacity, index: 0, toTime: 0.75, clampedTo: 2)
        #expect(moved.times(on: .opacity) == [0.5, 0.75, 1])
        // The value travelled with the keyframe rather than staying at its old index.
        #expect(moved.opacity[1].value == 0)
    }

    @Test func retimingOntoANeighbourIsRefused() {
        let subject = animation(opacity: [
            .init(timeSeconds: 0, value: 0),
            .init(timeSeconds: 1, value: 1),
        ])
        #expect(throws: AnimatedEditorError.duplicateKeyframeTime(.opacity, 1)) {
            try subject.movingKeyframe(on: .opacity, index: 0, toTime: 1, clampedTo: 2)
        }
    }

    @Test func outOfRangeIndicesThrowRatherThanTrap() {
        let subject = animation(opacity: [.init(timeSeconds: 0, value: 0)])
        #expect(throws: AnimatedEditorError.keyframeIndexOutOfRange(.opacity, 5)) {
            try subject.movingKeyframe(on: .opacity, index: 5, toTime: 1, clampedTo: 2)
        }
        #expect(throws: AnimatedEditorError.keyframeIndexOutOfRange(.opacity, -1)) {
            try subject.removingKeyframe(on: .opacity, index: -1)
        }
        #expect(throws: AnimatedEditorError.keyframeIndexOutOfRange(.rotation, 0)) {
            try subject.settingRotation(90, index: 0)
        }
    }

    // MARK: - Delete and easing

    @Test func removingDropsExactlyOneKeyframe() throws {
        let subject = animation(opacity: [
            .init(timeSeconds: 0, value: 0),
            .init(timeSeconds: 1, value: 0.5),
            .init(timeSeconds: 2, value: 1),
        ])
        #expect(try subject.removingKeyframe(on: .opacity, index: 1).times(on: .opacity) == [0, 2])
    }

    /// The interpolator reads easing from the *upper* keyframe of the pair it is blending, so the
    /// first keyframe of a channel has no incoming segment and its easing can never be observed.
    /// The editor still stores it — refusing would be surprising, and it becomes meaningful the
    /// moment something is inserted before it — but the inspector disables the control and says so.
    @Test func easingOnTheFirstKeyframeOfAChannelIsInert() throws {
        let base = animation(opacity: [
            .init(timeSeconds: 0, value: 0, easing: .linear),
            .init(timeSeconds: 2, value: 1, easing: .linear),
        ])
        let bouncy = try base.settingEasing(.springBouncy, on: .opacity, index: 0)
        #expect(bouncy.opacity[0].easing == .springBouncy)

        for time in stride(from: 0.0, through: 2.0, by: 0.25) {
            let original = AnimationInterpolator.state(for: layer(base), atDocumentTime: time)
            let edited = AnimationInterpolator.state(for: layer(bouncy), atDocumentTime: time)
            #expect(original.opacity == edited.opacity, "index 0 easing changed the render at t=\(time)")
        }
    }

    @Test func easingOnALaterKeyframeDoesChangeTheRender() throws {
        let base = animation(opacity: [
            .init(timeSeconds: 0, value: 0, easing: .linear),
            .init(timeSeconds: 2, value: 1, easing: .linear),
        ])
        let eased = try base.settingEasing(.easeInOut, on: .opacity, index: 1)
        let original = AnimationInterpolator.state(for: layer(base), atDocumentTime: 0.5)
        let edited = AnimationInterpolator.state(for: layer(eased), atDocumentTime: 0.5)
        #expect(original.opacity != edited.opacity)
    }

    // MARK: - Values

    @Test func typedSettersClampToTheStorableRanges() throws {
        var subject = animation(position: [.init(timeSeconds: 0, x: 0.5, y: 0.5)])
        subject = try subject.settingPosition(AnimatedPoint(x: 99, y: -99), index: 0)
        #expect(subject.position[0].x == 2)
        #expect(subject.position[0].y == -1)
        #expect(subject.isValid)

        var scaled = AnimatedLayerAnimation(scale: [.init(timeSeconds: 0, x: 1, y: 1)])
        scaled = try scaled.settingScale(AnimatedPoint(x: 0, y: 900), index: 0)
        #expect(scaled.scale[0].x == 0.05)
        #expect(scaled.scale[0].y == 8)
        #expect(scaled.isValid)
    }

    @Test func typedSettersPreserveTimeAndEasing() throws {
        let subject = try animation(opacity: [.init(timeSeconds: 1.25, value: 0.2, easing: .springSoft)])
            .settingOpacity(0.9, index: 0)
        #expect(subject.opacity[0].timeSeconds == 1.25)
        #expect(subject.opacity[0].easing == .springSoft)
        #expect(subject.opacity[0].value == 0.9)
    }

    /// Hand-authored keyframes must be numerically indistinguishable from compiled ones. The server
    /// compares a stored document against a freshly compiled one as canonical JSON, so a value that
    /// rounded differently — or a `-0` that `JSON.stringify` writes as `"0"` — would fail a
    /// byte-comparison for reasons no one could see on screen.
    @Test func everyEmittedValueIsAFixedPointOfTheCompilersRounding() throws {
        var subject = AnimatedLayerAnimation.empty
        var state = AnimatedLayerState.resting
        state.position = AnimatedPoint(x: 0.123456789, y: -0.0)
        state.rotationDegrees = -0.0
        subject = try subject.insertingKeyframe(on: .position, atTime: 0.333333333, sampledFrom: state)
        subject = try subject.insertingKeyframe(on: .rotation, atTime: 1.666666666, sampledFrom: state)

        for frame in subject.allKeyframes {
            #expect(AnimationCompiler.roundTime(frame.timeSeconds) == frame.timeSeconds)
        }
        #expect(AnimationCompiler.roundValue(subject.position[0].x) == subject.position[0].x)
        // A negative zero would serialise as "0" and never compare equal on the way back.
        #expect(subject.position[0].y.sign == .plus)
        #expect(subject.rotation[0].degrees.sign == .plus)
    }

    @Test func anEditedTrackSurvivesAJSONRoundTripByteForByte() throws {
        var subject = AnimatedLayerAnimation.empty
        for index in 0..<5 {
            subject = try subject.insertingKeyframe(
                on: .opacity, atTime: Double(index) * 0.37, sampledFrom: .resting, easing: .easeInOut
            )
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let first = try encoder.encode(subject)
        let decoded = try JSONDecoder().decode(AnimatedLayerAnimation.self, from: first)
        #expect(decoded == subject)
        #expect(try encoder.encode(decoded) == first)
    }

    // MARK: - Whole-track time changes

    @Test func rescalingStretchesEveryTrackProportionally() {
        let subject = AnimatedLayerAnimation(
            position: [.init(timeSeconds: 1, x: 0.5, y: 0.5)],
            opacity: [.init(timeSeconds: 0, value: 0), .init(timeSeconds: 2, value: 1)]
        )
        let doubled = subject.rescalingTimes(by: 2)
        #expect(doubled.times(on: .opacity) == [0, 4])
        #expect(doubled.times(on: .position) == [2])
        // Values are untouched — only the timeline moved.
        #expect(doubled.opacity.map(\.value) == subject.opacity.map(\.value))
    }

    @Test func rescalingIsInertForADegenerateFactor() {
        let subject = AnimatedLayerAnimation(opacity: [.init(timeSeconds: 1, value: 1)])
        #expect(subject.rescalingTimes(by: 1) == subject)
        #expect(subject.rescalingTimes(by: 0) == subject)
        #expect(subject.rescalingTimes(by: .nan) == subject)
    }

    @Test func clampingPullsKeyframesInsideTheNewDuration() {
        let subject = AnimatedLayerAnimation(opacity: [
            .init(timeSeconds: 0, value: 0),
            .init(timeSeconds: 3, value: 1),
        ])
        #expect(subject.clampingTimes(to: 1).times(on: .opacity) == [0, 1])
    }

    /// Clamping is lossy: several keyframes past the new end all land on it. Two keyframes at one
    /// instant is exactly the state the interpolator cannot resolve, so the collisions have to be
    /// resolved here rather than stored.
    @Test func clampingCollapsesCollisionsInsteadOfStoringThem() {
        let subject = AnimatedLayerAnimation(opacity: [
            .init(timeSeconds: 0, value: 0),
            .init(timeSeconds: 3, value: 0.5),
            .init(timeSeconds: 4, value: 1),
        ])
        let clamped = subject.clampingTimes(to: 1)
        #expect(clamped.times(on: .opacity) == [0, 1])
        #expect(Set(clamped.times(on: .opacity)).count == clamped.count(of: .opacity))
        // The earliest survivor wins, so the value that was at t=3 is what remains.
        #expect(clamped.opacity[1].value == 0.5)
    }

    @Test func rescalingThenRestoringReturnsTheOriginalTimes() {
        let subject = AnimatedLayerAnimation(opacity: [
            .init(timeSeconds: 0, value: 0),
            .init(timeSeconds: 0.7, value: 0.5),
            .init(timeSeconds: 1.9, value: 1),
        ])
        let round = subject.rescalingTimes(by: 3).rescalingTimes(by: 1.0 / 3.0)
        for (original, restored) in zip(subject.times(on: .opacity), round.times(on: .opacity)) {
            #expect(abs(original - restored) < 1e-3)
        }
    }

    // MARK: - Duration

    @Test func shorteningRescalesHandAuthoredKeyframesAndStaysValid() throws {
        let subject = document(animation(opacity: [
            .init(timeSeconds: 0, value: 0),
            .init(timeSeconds: 2, value: 1),
        ]), duration: 2)

        let shortened = try subject.settingDuration(1)
        #expect(shortened.durationSeconds == 1)
        #expect(shortened.layers[0].animation.times(on: .opacity) == [0, 1])
        #expect(try shortened.validated().durationSeconds == 1)
    }

    @Test func shorteningCanClampInsteadOfRescaling() throws {
        let subject = document(animation(opacity: [
            .init(timeSeconds: 0, value: 0),
            .init(timeSeconds: 2, value: 1),
        ]), duration: 2)

        let shortened = try subject.settingDuration(1, rescalingDetachedKeyframes: false)
        #expect(shortened.layers[0].animation.times(on: .opacity) == [0, 1])
        #expect(try shortened.validated().durationSeconds == 1)
    }

    @Test func durationIsClampedToTheSupportedRange() throws {
        let subject = document(.empty)
        #expect(try subject.settingDuration(999).durationSeconds == AnimatedDocument.durationRange.upperBound)
        #expect(try subject.settingDuration(0.001).durationSeconds == AnimatedDocument.durationRange.lowerBound)
    }

    @Test func aStaticDocumentHasNoTimelineToSet() {
        let subject = AnimatedDocument(kind: .static, layers: [])
        #expect(throws: AnimatedEditorError.staticDocumentCannotAnimate) {
            try subject.settingDuration(2)
        }
    }
}
