import Foundation
import Testing
@testable import AnimatedView

/// Proves the Swift compiler agrees with `server/lib/animation/compile.ts` keyframe for keyframe.
///
/// A document carries both its declarative specs and their compiled keyframes, and the server
/// rejects any document where recompiling the specs does not reproduce the stored keyframes exactly.
/// So a Swift client that rounded one value differently, or defaulted one field differently, would
/// silently start writing documents the server refuses — with an error message pointing at the
/// layer, not at the compiler. This test is the thing that catches it first.
///
/// Regenerate the fixture with `bun run scripts/emit-animation-parity-fixture.ts` in `server/`
/// after any change to either compiler.
struct CompilerParityTests {
    struct ParityCase: Decodable {
        var name: String
        var timing: Timing
        var anchor: Anchor
        var cycleCap: Int?
        var specs: [AnimationSpec]
        var expected: AnimatedLayerAnimation

        struct Timing: Decodable {
            var kind: AnimatedKind
            var durationSeconds: Double
        }

        /// The TypeScript anchor, which has no `trim` — that channel exists only on the Swift side
        /// until the server contract catches up, and every case here must therefore leave it at rest.
        struct Anchor: Decodable {
            var position: AnimatedPoint
            var scale: AnimatedPoint
            var rotationDegrees: Double
            var opacity: Double
            /// Optional because fixtures emitted before the server contract grew a trim channel do
            /// not carry one; a missing value means the whole path, exactly as the schema defaults.
            var trim: AnimatedTrim?

            var animated: AnimatedAnchor {
                .init(
                    position: position,
                    scale: scale,
                    rotationDegrees: rotationDegrees,
                    opacity: opacity,
                    trim: trim ?? .full
                )
            }
        }
    }

    static let cases: [ParityCase] = {
        guard let url = Bundle.module.url(forResource: "animation-compiler-parity", withExtension: "json", subdirectory: "Fixtures")
            ?? Bundle.module.url(forResource: "animation-compiler-parity", withExtension: "json")
        else {
            fatalError("animation-compiler-parity.json is missing from the test bundle")
        }
        // swiftlint:disable:next force_try
        return try! JSONDecoder().decode([ParityCase].self, from: Data(contentsOf: url))
    }()

    @Test func fixtureIsPresentAndComplete() throws {
        #expect(Self.cases.count >= 30)
        let covered = Set(Self.cases.flatMap { $0.specs.map(\.type) })
        // Every spec type the TypeScript contract knows about must appear, so a newly added effect
        // cannot ship without a parity case.
        let expected = Set(AnimationEffectType.allCases)
        #expect(covered == expected, "Missing parity coverage for \(expected.subtracting(covered))")
    }

    @Test(arguments: Self.cases)
    func matchesTypeScriptCompiler(_ testCase: ParityCase) throws {
        let compiled = try AnimationCompiler.compile(
            testCase.specs,
            anchor: testCase.anchor.animated,
            timing: .init(kind: testCase.timing.kind, durationSeconds: testCase.timing.durationSeconds),
            cycleCap: testCase.cycleCap ?? .max
        )

        // Compared channel by channel so a failure names the channel rather than dumping two whole
        // animation objects.
        #expect(compiled.position == testCase.expected.position, "\(testCase.name): position")
        #expect(compiled.scale == testCase.expected.scale, "\(testCase.name): scale")
        #expect(compiled.rotation == testCase.expected.rotation, "\(testCase.name): rotation")
        #expect(compiled.opacity == testCase.expected.opacity, "\(testCase.name): opacity")
        #expect(compiled.effects == testCase.expected.effects, "\(testCase.name): effects")
        // Trim used to be asserted empty here, because the channel existed only on the Swift side.
        // Now that `compile.ts` implements it, it is compared like every other channel.
        #expect(compiled.trim == testCase.expected.trim, "\(testCase.name): trim")
        #expect(compiled.wipe == testCase.expected.wipe, "\(testCase.name): wipe")
        #expect(compiled.sheen == testCase.expected.sheen, "\(testCase.name): sheen")
        #expect(compiled.glow == testCase.expected.glow, "\(testCase.name): glow")

        // Belt and braces: every channel is asserted above, but the list is hand-written and a
        // future channel could be added to the model without anyone adding a line here. Comparing
        // the totals catches that, since a channel compared by nobody still shows up in the count.
        #expect(
            compiled.keyframeCount == testCase.expected.keyframeCount,
            "\(testCase.name): keyframe total differs — a channel may be missing an assertion above"
        )
    }

    /// The fixture stores the specs *after* zod applied its defaults, so decoding them back and
    /// re-encoding proves the Swift decoder defaults identically. A drifted default would otherwise
    /// only surface as a mysterious keyframe difference.
    @Test(arguments: Self.cases)
    func specsRoundTripWithIdenticalDefaults(_ testCase: ParityCase) throws {
        for spec in testCase.specs {
            let data = try JSONEncoder().encode(spec)
            let decoded = try JSONDecoder().decode(AnimationSpec.self, from: data)
            #expect(decoded == spec, "\(testCase.name): \(spec.type.rawValue) did not round-trip")
        }
    }
}

extension CompilerParityTests.ParityCase: CustomTestStringConvertible {
    var testDescription: String { name }
}
