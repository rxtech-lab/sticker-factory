import Foundation
import Testing
@testable import AnimatedView

/// The seam between wall-clock time and document time.
///
/// `AnimatedIconFrame` accepts either, and confusing them is invisible at 1× and wrong everywhere
/// else — which is exactly the kind of bug that ships. The editor's playhead is a document time, so
/// these pin down that the two initialisers agree when they should and differ when they must.
@MainActor
struct EditorFrameTimeTests {
    private func document(speed: Double, loop: AnimatedLoop = .loop, duration: Double = 2) -> AnimatedDocument {
        let animation = AnimatedLayerAnimation(opacity: [
            .init(timeSeconds: 0, value: 0),
            .init(timeSeconds: duration, value: 1)
        ])
        let layer = AnimatedLayer.shape(.init(
            base: .init(id: "hero", name: "Hero", animation: animation),
            shape: .circle,
            fill: .solid("#FFFFFF")
        ))
        return .init(kind: .animated, durationSeconds: duration, loop: loop, speed: speed, layers: [layer])
    }

    /// The whole reason the second initialiser exists: `mappedTime` scales by `speed`, so feeding a
    /// document time to the wall-clock path lands on the wrong frame at any speed but 1.
    @Test(arguments: [0.5, 1.0, 2.0, 4.0])
    func aDocumentTimeSelectsTheSameStateTheInterpolatorWould(speed: Double) {
        let subject = document(speed: speed)
        for documentTime in stride(from: 0.0, through: 2.0, by: 0.25) {
            let expected = AnimationInterpolator.state(for: subject.layers[0], atDocumentTime: documentTime)
            let frame = AnimatedIconFrame(document: subject, documentTime: documentTime)
            let actual = AnimationInterpolator.state(for: subject.layers[0], atDocumentTime: frame.documentTime)
            #expect(actual == expected, "speed \(speed) at t=\(documentTime)")
        }
    }

    @Test func theWallClockInitialiserStillAppliesSpeed() {
        let subject = document(speed: 2)
        // One second of wall clock is two seconds of document at 2×, which a 2s loop wraps to 0.
        let frame = AnimatedIconFrame(document: subject, time: 1)
        #expect(frame.documentTime == 0)
    }

    /// Strictly inside one cycle at 1× the two conventions coincide, which is why the distinction
    /// is so easy to miss.
    @Test func theTwoInitialisersAgreeInsideACycleAtUnitSpeed() {
        let subject = document(speed: 1)
        for time in stride(from: 0.0, to: 2.0, by: 0.5) {
            let wall = AnimatedIconFrame(document: subject, time: time)
            let doc = AnimatedIconFrame(document: subject, documentTime: time)
            #expect(wall.documentTime == doc.documentTime, "t=\(time)")
        }
    }

    /// They part company at the cycle boundary even at 1×: wall-clock wraps to the start of the
    /// next repetition, while a playhead parked on the last frame must stay there.
    @Test func theyDivergeAtTheCycleBoundary() {
        let subject = document(speed: 1)
        #expect(AnimatedIconFrame(document: subject, time: 2).documentTime == 0)
        #expect(AnimatedIconFrame(document: subject, documentTime: 2).documentTime == 2)
    }

    /// A document time is taken verbatim — no loop wrapping. A scrubber owns its own bounds, and
    /// wrapping here would make the playhead jump to zero at the end of the timeline.
    @Test func aDocumentTimeIsNotLoopWrapped() {
        let subject = document(speed: 1, loop: .pingPong)
        #expect(AnimatedIconFrame(document: subject, documentTime: 2).documentTime == 2)
        // The wall-clock path does fold, which is what ping-pong means.
        #expect(AnimatedIconFrame(document: subject, time: 3).documentTime == 1)
    }
}
