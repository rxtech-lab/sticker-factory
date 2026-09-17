import AnimatedView
import Foundation
import Testing
@testable import StickerGeniOS

@Suite("The server's configuration budget")
struct ConfigurationLimitsTests {
    private let limits = ConfigurationLimits(
        controls: 16, controlOptions: 8, controlOptionsMinimum: 2,
        variants: 128, layerCombinations: 64, preparedStates: 256, planLayers: 12
    )

    /// A cast at four poses and four moods each: sixteen states per character, so the total is
    /// what the cast size buys and no single character is ever the problem.
    private func cast(_ layerCount: Int) -> AnimatedControlConfiguration {
        let options = ["a", "b", "c", "d"].map { AnimatedControlOption(id: $0, label: $0.uppercased()) }
        let ids = (0..<layerCount).map { "layer_\($0)" }
        return .init(
            controls: ["pose", "mood"].map {
                .init(id: $0, label: $0.capitalized, type: .choice, defaultValue: .string("a"), options: options)
            },
            variants: options.flatMap { pose in options.map { mood in
                AnimatedVariant(
                    id: "v_\(pose.id)_\(mood.id)",
                    selections: ["pose": pose.id, "mood": mood.id],
                    layers: ids.map { .init(layerId: $0, text: "\(pose.id)\(mood.id)") }
                )
            } }
        )
    }

    @Test func nothingIsRefusedUntilTheServerHasSaidWhatTheBudgetIs() {
        // Sixty-four characters is four times any cap the server has ever set, and an app that has
        // never reached the server still has nothing to say about it.
        #expect(cast(64).preparedStateCount == 1_024)
        #expect(ConfigurationLimits?.none?.issue(for: cast(64)) == nil)
    }

    @Test func thePreparedTotalIsJudgedAtExactlyTheServersNumber() {
        #expect(limits.issue(for: cast(16)) == nil)
        let over = try? #require(limits.issue(for: cast(17)))
        #expect(over?.contains("At most 256 states in total") == true)
        #expect(over?.contains("reach 272") == true)
    }

    @Test func aSingleCharacterIsNamedWhenItIsTheOneOverTheCeiling() {
        var configuration = cast(1)
        // A third and fourth axis on the same character is four-to-the-fourth: over its own
        // ceiling well before the sticker's total is in any danger.
        for axis in ["hat", "scarf"] {
            configuration.controls.append(.init(
                id: axis, label: axis.capitalized, type: .choice, defaultValue: .string("a"),
                options: ["a", "b", "c", "d"].map { .init(id: $0, label: $0.uppercased()) }
            ))
            for option in ["a", "b", "c", "d"] {
                configuration.variants.append(.init(
                    id: "\(axis)_\(option)", selections: [axis: option],
                    layers: [.init(layerId: "layer_0", text: option)]
                ))
            }
        }
        #expect(configuration.layerCombinationCounts["layer_0"] == 256)
        let issue = limits.issue(for: configuration)
        #expect(issue?.contains("layer_0 has 256 mood/pose combinations") == true)
    }

    @Test func theEditorStopsOneStepShortRatherThanAfterTheOverrun() {
        // A new control arrives with two options, so a character at 32 is the last one that can
        // take another; one at 33 cannot.
        #expect(!limits.exceedsLayerCombinations(addingControlTo: 32))
        #expect(limits.exceedsLayerCombinations(addingControlTo: 33))
        // A fifth option on a character at sixteen (four by four) takes it to twenty, which fits.
        #expect(!limits.exceedsLayerCombinations(addingOptionTo: 16, options: 4))
        // Three four-option axes is already the ceiling exactly, so a fifth option on any of them
        // is eighty and refused.
        #expect(limits.exceedsLayerCombinations(addingOptionTo: 64, options: 4))
        // And a control at eight options is done however little its character has spent.
        #expect(limits.exceedsLayerCombinations(addingOptionTo: 8, options: 8))
    }

    @Test func nonsenseFromTheServerIsRefusedRatherThanGreyingOutTheScreen() throws {
        #expect(try limits.validated() == limits)
        var zeroed = limits
        zeroed.controls = 0
        #expect(throws: (any Error).self) { try zeroed.validated() }
        var inverted = limits
        inverted.controlOptionsMinimum = 9
        #expect(throws: (any Error).self) { try inverted.validated() }
    }
}
