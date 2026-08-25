import Foundation
import Testing
@testable import AnimatedView

/// The trim channel and its three specs exist only on the Swift side until the server contract
/// catches up, so they have no parity fixture. These are their coverage.
struct TrimCompilerTests {
    private let timing = AnimationTiming(kind: .animated, durationSeconds: 4)

    @Test func drawOnSweepsTheEndOfTheWindow() throws {
        let compiled = try AnimationCompiler.compile(
            [.init(.drawOn(from: 0), delay: 0.5, duration: 2, easing: .easeOut)],
            timing: timing
        )
        #expect(compiled.trim.count == 2)
        let first = try #require(compiled.trim.first)
        let last = try #require(compiled.trim.last)
        #expect(first.timeSeconds == 0.5)
        #expect(first.start == 0)
        #expect(first.end == 0)
        #expect(last.timeSeconds == 2.5)
        #expect(last.end == 1)
        // Easing belongs on the closing keyframe; the opening one is always linear.
        #expect(first.easing == .linear)
        #expect(last.easing == .easeOut)
        // Trim is the only channel it drives.
        #expect(compiled.position.isEmpty && compiled.opacity.isEmpty && compiled.scale.isEmpty)
    }

    @Test func drawOffEatsTheStartOfTheWindow() throws {
        let compiled = try AnimationCompiler.compile([.drawOff(to: 1, duration: 1)], timing: timing)
        let first = try #require(compiled.trim.first)
        let last = try #require(compiled.trim.last)
        #expect(first.start == 0)
        #expect(first.end == 1)
        #expect(last.start == 1)
        #expect(last.end == 1)
    }

    @Test func trimToMovesBothEnds() throws {
        let compiled = try AnimationCompiler.compile(
            [.init(.trimTo(start: 0.25, end: 0.75), duration: 1)],
            timing: timing
        )
        let last = try #require(compiled.trim.last)
        #expect(last.start == 0.25)
        #expect(last.end == 0.75)
    }

    @Test func drawOnDepartsFromANonRestingAnchor() throws {
        let anchor = AnimatedAnchor(trim: .init(start: 0.1, end: 0.9))
        let compiled = try AnimationCompiler.compile([.drawOn(duration: 1)], anchor: anchor, timing: timing)
        #expect(compiled.trim.first?.start == 0.1)
        #expect(compiled.trim.last?.end == 0.9)
    }

    @Test func anEmptyAnchorTrimEmitsNoKeyframe() throws {
        let compiled = try AnimationCompiler.compile([], anchor: .default, timing: timing)
        #expect(compiled.trim.isEmpty)
    }

    @Test func aNonRestingAnchorTrimEmitsOneKeyframe() throws {
        let anchor = AnimatedAnchor(trim: .init(start: 0, end: 0.4))
        let compiled = try AnimationCompiler.compile([], anchor: anchor, timing: timing)
        #expect(compiled.trim.count == 1)
        #expect(compiled.trim.first?.end == 0.4)
        #expect(compiled.trim.first?.timeSeconds == 0)
    }

    @Test func twoOverlappingTrimSpecsAreRejected() {
        #expect(throws: AnimationCompileError.self) {
            try AnimationCompiler.compile(
                [.drawOn(delay: 0, duration: 2), .drawOff(delay: 1, duration: 2)],
                timing: timing
            )
        }
    }

    @Test func touchingTrimWindowsAreAllowed() throws {
        let compiled = try AnimationCompiler.compile(
            [.drawOn(delay: 0, duration: 2), .drawOff(delay: 2, duration: 2)],
            timing: timing
        )
        // The shared boundary keyframe at t=2 is reconciled rather than duplicated.
        #expect(compiled.trim.count == 3)
        #expect(Set(compiled.trim.map(\.timeSeconds)).count == compiled.trim.count)
    }

    @Test func aSpecPastTheDocumentEndIsRejected() {
        #expect(throws: AnimationCompileError.self) {
            try AnimationCompiler.compile([.drawOn(delay: 3.5, duration: 1)], timing: timing)
        }
    }

    @Test func specsOnAStaticDocumentAreRejected() {
        #expect(throws: AnimationCompileError.self) {
            try AnimationCompiler.compile(
                [.fadeIn()],
                timing: .init(kind: .static, durationSeconds: 0)
            )
        }
    }

    // MARK: - Budget allocation

    @Test func theCycleCapShrinksUntilTheDocumentFits() throws {
        // Eight layers each asking for eight wiggle cycles is 8 × 33 = 264 keyframes at full
        // density, well past the 128 budget, so the allocator must lower the cap for all of them.
        let layers = (0..<8).map { index in
            AnimationCompiler.LayerCompileInput(
                layerId: "layer\(index)",
                specs: [.wiggle(amplitudeDegrees: 10, cycles: 8, duration: 4)]
            )
        }
        let compiled = try AnimationCompiler.compileAll(layers, timing: timing)
        let total = compiled.reduce(0) { $0 + $1.keyframeCount }
        #expect(total <= AnimatedDocument.maximumKeyframeCount)
        // Lowered uniformly, so the result cannot depend on layer order.
        #expect(Set(compiled.map(\.keyframeCount)).count == 1)
    }

    @Test func theAllocatorRethrowsFailuresACapCannotFix() {
        let layers = [
            AnimationCompiler.LayerCompileInput(
                layerId: "a",
                specs: [.fadeIn(delay: 0, duration: 2), .fadeOut(delay: 1, duration: 2)]
            ),
        ]
        // A channel conflict is invariant to the cycle cap; retrying at a lower cap would just loop.
        #expect(throws: AnimationCompileError.self) {
            try AnimationCompiler.compileAll(layers, timing: timing)
        }
    }

    // MARK: - JavaScript rounding parity

    /// `Math.round` breaks ties toward positive infinity; Swift's `rounded()` breaks them away from
    /// zero. The compiler must use the JavaScript rule or a document compiled here would not
    /// deep-equal the same document compiled on the server.
    @Test func roundingMatchesJavaScriptSemantics() {
        #expect(AnimationCompiler.jsRound(2.5) == 3)
        #expect(AnimationCompiler.jsRound(-2.5) == -2)
        #expect(AnimationCompiler.jsRound(-3.5) == -3)
        #expect(AnimationCompiler.jsRound(0.5) == 1)
        #expect(AnimationCompiler.jsRound(-0.5) == 0)
    }

    /// `sin(2π)` is a tiny negative number that rounds to `-0`, and `JSON.stringify` writes `-0` as
    /// `"0"`. Without the normalisation a stored track would read back as `0` and never compare
    /// equal to a freshly compiled `-0`.
    @Test func negativeZeroIsNormalised() {
        #expect(AnimationCompiler.roundValue(-0.0000001).sign == .plus)
        #expect(AnimationCompiler.roundTime(-0.0).sign == .plus)
        let compiled = try? AnimationCompiler.compile([.wiggle(cycles: 2, duration: 2)], timing: timing)
        #expect(compiled?.rotation.allSatisfy { $0.degrees.sign == .plus || $0.degrees < 0 } == true)
        #expect(compiled?.rotation.allSatisfy { !($0.degrees == 0 && $0.degrees.sign == .minus) } == true)
    }
}
