import Foundation
import Testing
@testable import AnimatedView

/// Proves `AnimationInterpolator.spriteFrameIndex` agrees with `spriteFrameIndex` in
/// `server/lib/animation/sample.ts`, frame for frame, including at instants that sit on a frame
/// boundary in floating point. Regenerate with `bun run scripts/emit-sprite-parity-fixture.ts` in
/// `server/` and copy the fixture here after any change to either implementation.
struct SpriteFrameIndexParityTests {
    struct Fixture: Decodable {
        var times: [Double]
        var cases: [Case]

        struct Case: Decodable {
            var name: String
            var durations: [Double]
            var expected: [Int]
        }
    }

    static let fixture: Fixture = {
        guard let url = Bundle.module.url(forResource: "sprite-frame-index-parity", withExtension: "json", subdirectory: "Fixtures")
            ?? Bundle.module.url(forResource: "sprite-frame-index-parity", withExtension: "json")
        else {
            fatalError("sprite-frame-index-parity.json is missing from the test bundle")
        }
        // swiftlint:disable:next force_try
        return try! JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }()

    private static func frames(_ durations: [Double]) -> [AnimatedSpriteFrame] {
        durations.map { AnimatedSpriteFrame(duration: $0, faceX: 0.5, faceY: 0.4, faceSize: 0.4) }
    }

    @Test func fixtureCoversHoldsBlinksAndNegativeTime() {
        #expect(Self.fixture.cases.contains { $0.durations.contains { $0 < 0.2 } })
        #expect(Self.fixture.cases.contains { $0.durations.contains { $0 > 2 } })
        #expect(Self.fixture.cases.contains { $0.durations.count == 1 })
        #expect(Self.fixture.times.contains { $0 < 0 })
    }

    @Test(arguments: Self.fixture.cases)
    func matchesTypeScript(_ testCase: Fixture.Case) {
        let frames = Self.frames(testCase.durations)
        let actual = Self.fixture.times.map { AnimationInterpolator.spriteFrameIndex(frames, atDocumentTime: $0) }
        #expect(actual == testCase.expected, "\(testCase.name): \(actual) != \(testCase.expected)")
    }

    @Test(arguments: Self.fixture.cases)
    func neverLeavesTheClip(_ testCase: Fixture.Case) {
        let frames = Self.frames(testCase.durations)
        for index in Self.fixture.times.map({ AnimationInterpolator.spriteFrameIndex(frames, atDocumentTime: $0) }) {
            #expect(index >= 0)
            #expect(index < testCase.durations.count)
        }
    }
}
