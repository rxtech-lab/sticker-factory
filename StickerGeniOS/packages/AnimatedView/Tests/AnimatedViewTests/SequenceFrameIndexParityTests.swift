import Foundation
import Testing
@testable import AnimatedView

/// Proves `AnimationInterpolator.sequenceFrameIndex` agrees with `sequenceFrameIndex` in
/// `server/lib/animation/sample.ts`, tile for tile.
///
/// The server draws the same document when the agent reviews its own work, and picks a frame with
/// its own copy of this function. If the two disagreed, the agent would be refining a frame the user
/// never sees — and the divergence would be invisible, because both renderers would look internally
/// consistent. This is what catches it.
///
/// Regenerate the fixture with `bunx tsx scripts/generate-sequence-parity-fixture.ts` in `server/`
/// after any change to either implementation.
struct SequenceFrameIndexParityTests {
    struct Fixture: Decodable {
        var times: [Double]
        var cases: [Case]

        struct Case: Decodable {
            var name: String
            var layer: Layer
            var expected: [Int]

            struct Layer: Decodable {
                var frameCount: Int
                var frameRate: Double
                var playback: AnimatedSequencePlayback
                var startSeconds: Double
            }
        }
    }

    static let fixture: Fixture = {
        guard let url = Bundle.module.url(forResource: "sequence-frame-index-parity", withExtension: "json", subdirectory: "Fixtures")
            ?? Bundle.module.url(forResource: "sequence-frame-index-parity", withExtension: "json")
        else {
            fatalError("sequence-frame-index-parity.json is missing from the test bundle")
        }
        // swiftlint:disable:next force_try
        return try! JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }()

    private static func layer(_ raw: Fixture.Case.Layer) -> AnimatedSequenceLayer {
        .init(
            base: .init(id: "hero", name: "Live capture"),
            assetId: "33333333-3333-4333-8333-333333333333",
            columns: 8,
            rows: 8,
            frameCount: raw.frameCount,
            frameRate: raw.frameRate,
            playback: raw.playback,
            startSeconds: raw.startSeconds
        )
    }

    @Test func fixtureCoversEveryPlaybackMode() {
        let covered = Set(Self.fixture.cases.map(\.layer.playback))
        let expected = Set(AnimatedSequencePlayback.allCases)
        #expect(covered == expected, "Missing parity coverage for \(expected.subtracting(covered))")
        // Negative times are reachable — a layer whose `startSeconds` is ahead of the playhead
        // produces one on every frame before it begins — so the fixture must exercise them.
        #expect(Self.fixture.times.contains { $0 < 0 })
    }

    @Test(arguments: Self.fixture.cases)
    func matchesTypeScript(_ testCase: Fixture.Case) {
        let layer = Self.layer(testCase.layer)
        let actual = Self.fixture.times.map { AnimationInterpolator.sequenceFrameIndex(layer, atDocumentTime: $0) }
        #expect(actual == testCase.expected, "\(testCase.name): \(actual) != \(testCase.expected)")
    }

    @Test(arguments: Self.fixture.cases)
    func neverLeavesTheSheet(_ testCase: Fixture.Case) {
        let layer = Self.layer(testCase.layer)
        for index in Self.fixture.times.map({ AnimationInterpolator.sequenceFrameIndex(layer, atDocumentTime: $0) }) {
            #expect(index >= 0)
            #expect(index < testCase.layer.frameCount)
        }
    }
}

extension SequenceFrameIndexParityTests.Fixture.Case: CustomTestStringConvertible {
    var testDescription: String { name }
}
