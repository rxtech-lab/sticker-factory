import Foundation
import Testing
@testable import AnimatedView

/// The editor's playback clock.
///
/// The bug these exist for: the canvas used to be driven by a `TimelineView` that re-rendered on
/// its own schedule while reading an unchanging `scrubDocumentTime`. Pressing play swapped the
/// button to a pause icon and animated nothing at all — the artwork was redrawn thirty times a
/// second at the same instant. The clock now moves the model, so anything that reads the playhead
/// (canvas, timeline, readout) moves with it.
@MainActor
struct EditorPlaybackTests {
    private func editor(
        duration: Double = 2,
        loop: AnimatedLoop = .loop,
        speed: Double = 1,
        kind: AnimatedKind = .animated
    ) -> AnimatedDocumentEditor {
        let layer = AnimatedLayer.shape(.init(
            base: .init(id: "dot", name: "Dot"),
            shape: .circle,
            fill: .solid("#FFFFFF")
        ))
        return .init(document: .init(
            kind: kind,
            durationSeconds: kind == .static ? 0 : duration,
            fps: kind == .static ? 0 : 30,
            loop: kind == .static ? .once : loop,
            speed: kind == .static ? 1 : speed,
            layers: [layer]
        ))
    }

    /// A fixed instant to measure from, so nothing here depends on how long the test took to run.
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    @Test func playingAdvancesThePlayhead() {
        let subject = editor()
        subject.setPlaying(true, now: start)
        #expect(subject.scrubDocumentTime == 0)

        subject.advancePlayback(now: start.addingTimeInterval(0.5))
        #expect(abs(subject.scrubDocumentTime - 0.5) < 1e-6)

        subject.advancePlayback(now: start.addingTimeInterval(1.25))
        #expect(abs(subject.scrubDocumentTime - 1.25) < 1e-6)
    }

    /// Each position is computed from wall clock rather than accumulated per tick, so a dropped or
    /// coalesced tick costs a frame instead of permanently desynchronising the playhead.
    @Test func positionsComeFromWallClockNotAccumulatedTicks() {
        let subject = editor()
        subject.setPlaying(true, now: start)
        // One long gap, as if the app had been backgrounded mid-play.
        subject.advancePlayback(now: start.addingTimeInterval(1.5))
        #expect(abs(subject.scrubDocumentTime - 1.5) < 1e-6)
    }

    @Test func pausingAndResumingContinuesFromWhereItStopped() {
        let subject = editor()
        subject.setPlaying(true, now: start)
        subject.advancePlayback(now: start.addingTimeInterval(1.2))
        subject.setPlaying(false, now: start)
        #expect(abs(subject.scrubDocumentTime - 1.2) < 1e-6)

        // Resuming much later in wall clock still picks up at 1.2s of document time.
        subject.setPlaying(true, now: start.addingTimeInterval(60))
        subject.advancePlayback(now: start.addingTimeInterval(60))
        #expect(abs(subject.scrubDocumentTime - 1.2) < 0.05)
    }

    @Test func aLoopingDocumentWrapsRatherThanStopping() {
        let subject = editor(duration: 2, loop: .loop)
        subject.setPlaying(true, now: start)
        subject.advancePlayback(now: start.addingTimeInterval(2.5))
        #expect(abs(subject.scrubDocumentTime - 0.5) < 1e-6)
        #expect(subject.isPlaying)
    }

    @Test func pingPongFoldsBackOnItself() {
        let subject = editor(duration: 2, loop: .pingPong)
        subject.setPlaying(true, now: start)
        subject.advancePlayback(now: start.addingTimeInterval(3))
        // Three seconds into a there-and-back cycle is one second back down.
        #expect(abs(subject.scrubDocumentTime - 1) < 1e-6)
    }

    /// A play-once document that has finished should settle on its last frame rather than leaving a
    /// pause button that no longer pauses anything.
    @Test func aPlayOnceDocumentStopsAtTheEnd() {
        let subject = editor(duration: 2, loop: .once)
        subject.setPlaying(true, now: start)
        let stillRunning = subject.advancePlayback(now: start.addingTimeInterval(2.5))
        #expect(!stillRunning)
        #expect(!subject.isPlaying)
        #expect(abs(subject.scrubDocumentTime - 2) < 1e-6)
    }

    /// `speed` divides elapsed time on the way into the interpolator, so it changes how fast the
    /// playhead crosses the timeline without touching a single keyframe.
    @Test func speedScalesHowFastThePlayheadMoves() {
        let fast = editor(duration: 2, speed: 2)
        fast.setPlaying(true, now: start)
        fast.advancePlayback(now: start.addingTimeInterval(0.5))
        #expect(abs(fast.scrubDocumentTime - 1) < 1e-6)

        let slow = editor(duration: 2, speed: 0.5)
        slow.setPlaying(true, now: start)
        slow.advancePlayback(now: start.addingTimeInterval(1))
        #expect(abs(slow.scrubDocumentTime - 0.5) < 1e-6)
    }

    /// Resuming has to convert the playhead back into wall clock, so a non-unit speed does not
    /// teleport the playhead on the first tick after pausing.
    @Test func resumingAtANonUnitSpeedDoesNotJump() {
        let subject = editor(duration: 4, speed: 2)
        subject.setPlaying(true, now: start)
        subject.advancePlayback(now: start.addingTimeInterval(1))
        #expect(abs(subject.scrubDocumentTime - 2) < 1e-6)

        subject.setPlaying(false, now: start.addingTimeInterval(1))
        subject.setPlaying(true, now: start.addingTimeInterval(1))
        // The very first tick after resuming is essentially no time at all, so the playhead should
        // still be at 2 rather than snapping back to zero.
        subject.advancePlayback(now: start.addingTimeInterval(1.001))
        #expect(abs(subject.scrubDocumentTime - 2) < 0.05)
    }

    @Test func aPausedEditorDoesNotAdvance() {
        let subject = editor()
        subject.scrubDocumentTime = 0.75
        #expect(!subject.advancePlayback(now: start.addingTimeInterval(5)))
        #expect(subject.scrubDocumentTime == 0.75)
    }

    /// A still image has no timeline to move along.
    @Test func aStaticDocumentNeverAdvances() {
        let subject = editor(kind: .static)
        subject.setPlaying(true, now: start)
        #expect(!subject.advancePlayback(now: start.addingTimeInterval(5)))
        #expect(subject.scrubDocumentTime == 0)
    }

    /// Setting `isPlaying` to the value it already holds must not silently re-anchor playback, or
    /// any incidental re-assignment during a view update would restart the cycle.
    @Test func redundantlySettingIsPlayingIsInert() {
        let subject = editor()
        subject.setPlaying(true, now: start)
        subject.advancePlayback(now: start.addingTimeInterval(1))
        // A redundant start must not re-anchor; if it did, the next tick would read 0.5 not 1.5.
        subject.setPlaying(true, now: start.addingTimeInterval(1))
        subject.advancePlayback(now: start.addingTimeInterval(1.5))
        #expect(abs(subject.scrubDocumentTime - 1.5) < 1e-6)
    }

    /// The playhead is what the canvas renders, so a moving clock has to move the artwork too.
    @Test func advancingChangesWhatTheCanvasWouldDraw() {
        let animation = AnimatedLayerAnimation(opacity: [
            .init(timeSeconds: 0, value: 0),
            .init(timeSeconds: 2, value: 1)
        ])
        let layer = AnimatedLayer.shape(.init(
            base: .init(id: "dot", name: "Dot", animation: animation),
            shape: .circle,
            fill: .solid("#FFFFFF")
        ))
        let subject = AnimatedDocumentEditor(document: .init(
            kind: .animated, durationSeconds: 2, fps: 30, loop: .loop, layers: [layer]
        ))
        subject.setPlaying(true, now: start)

        let before = AnimationInterpolator.state(for: subject.document.layers[0], atDocumentTime: subject.scrubDocumentTime)
        subject.advancePlayback(now: start.addingTimeInterval(1))
        let after = AnimationInterpolator.state(for: subject.document.layers[0], atDocumentTime: subject.scrubDocumentTime)
        #expect(before.opacity != after.opacity, "the clock moved but the rendered frame did not")
    }

    /// Playback is not an edit: it must not put anything on the undo stack, or a second of playing
    /// would bury every real change under sixty snapshots.
    @Test func playbackIsNotUndoable() {
        let subject = editor()
        subject.setPlaying(true, now: start)
        for step in 1...30 {
            subject.advancePlayback(now: start.addingTimeInterval(Double(step) / 30))
        }
        #expect(!subject.canUndo)
    }
}
