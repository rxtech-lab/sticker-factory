import Foundation
import Testing
@testable import AnimatedView

struct ConfigurationTests {
    private func document() throws -> AnimatedDocument {
        let url = try #require(Bundle.module.url(forResource: "sticker-document-v5", withExtension: "json", subdirectory: "Fixtures"))
        return try JSONDecoder().decode(AnimatedDocument.self, from: Data(contentsOf: url)).validated()
    }
    @Test func sharedFixtureRoundTripAndComposition() throws {
        let source = try document()
        #expect(try JSONDecoder().decode(AnimatedDocument.self, from: JSONEncoder().encode(source)) == source)
        #expect(source.configuration?.choiceSelections.count == 4)
        let rendered = try source.resolvingConfiguration([
            "mood": .string("sad"), "pose": .string("hop"), "sparkles": .bool(false), "speed": .number(2)
        ])
        guard case .image(let image) = rendered.layers[0] else { Issue.record("Expected expression image"); return }
        #expect(image.assetId == "22222222-2222-4222-8222-222222222222")
        #expect(image.base.animation.position.count > 1)
        #expect(rendered.layers[1].hidden)
        #expect(rendered.speed == 2)
        #expect(rendered.configuration == nil)
        #expect(!source.layers[1].hidden)
        #expect(source.allConfigurationImageAssetIDs.contains(image.assetId))
    }
    @Test func authoredDefaultsAndInvalidSelections() throws {
        let source = try document()
        let result = try source.resolvingConfiguration(["mood": .string("gone"), "speed": .number(200)])
        #expect(result.layers[0].referencedImageAssetIDs == source.layers[0].referencedImageAssetIDs)
        #expect(result.speed == 2)
    }
    @Test func missingCombinationAndConflictingBindingsAreRejected() throws {
        var source = try document()
        source.configuration?.variants.removeLast()
        #expect(throws: AnimatedConfigurationError.self) { try source.validated() }
        source = try document()
        source.configuration?.variants[2].layers[0] = .init(layerId: "hero", source: .init(kind: .base))
        #expect(throws: AnimatedConfigurationError.self) { try source.validated() }
    }
    @Test func removingLayerRemovesItsControlsAndBindings() throws {
        let result = try document().removingLayer(id: "hero")
        try result.validated()
        #expect(result.configuration?.controls.map(\.id) == ["sparkles", "speed"])
        #expect(result.configuration?.variants.isEmpty == true)
    }
    @MainActor @Test func optionPlacementInitializesTheFamilyAndUndoRestoresIt() throws {
        let editor = AnimatedDocumentEditor(document: try document())
        editor.selectVariant("sad")
        editor.selectedLayerID = "hero"
        editor.setOptionAnchor(forLayer: "hero") { $0.position.x = 0.72 }
        let mood = try #require(editor.document.configuration?.variants.filter { $0.selections["mood"] != nil })
        #expect(mood.allSatisfy { $0.layers.first(where: { $0.layerId == "hero" })?.anchor != nil })
        #expect(editor.displayDocument.layer(id: "hero")?.anchor.position.x == 0.72)
        editor.moveLayer(id: "hero", toIndex: 1)
        #expect(editor.displayDocument.layers.map(\.id) == ["spark", "hero"])
        editor.undo()
        #expect(editor.displayDocument.layers.map(\.id) == ["hero", "spark"])
        editor.undo()
        #expect(editor.document.configuration?.variants.first(where: { $0.id == "sad" })?.layers[0].anchor == nil)
    }
    @Test func everyChoiceCombinationResolvesDeterministically() throws {
        let source = try document()
        for values in try #require(source.configuration).choiceSelections {
            #expect(try source.resolvingConfiguration(values) == source.resolvingConfiguration(values))
        }
    }

    private func spriteDocument() throws -> AnimatedDocument {
        let url = try #require(Bundle.module.url(
            forResource: "sticker-document-v5-sprite", withExtension: "json", subdirectory: "Fixtures"
        ))
        return try JSONDecoder().decode(AnimatedDocument.self, from: Data(contentsOf: url)).validated()
    }
    @Test func spriteFixtureSelectsClipAndExpressionIndependently() throws {
        let source = try spriteDocument()
        #expect(try JSONDecoder().decode(AnimatedDocument.self, from: JSONEncoder().encode(source)) == source)
        #expect(source.configuration?.choiceSelections.count == 6)
        #expect(source.hasMotion)
        let rendered = try source.resolvingConfiguration([
            "mood": .string("sad"), "pose": .string("wave"), "sparkles": .bool(false), "speed": .number(0.5)
        ])
        guard case .sprite(let sprite) = rendered.layers[0] else { Issue.record("Expected a sprite"); return }
        #expect(sprite.clipId == "wave")
        #expect(sprite.expressionId == "sad")
        #expect(sprite.currentClip.assetId == "32222222-2222-4222-8222-222222222222")
        #expect(sprite.currentTile.x == 0.71)
        #expect(rendered.layers[1].hidden)
        #expect(rendered.speed == 0.5)
        // Only the mood changed: the pose stays on the authored default, and the sheets never change.
        let happy = try source.resolvingConfiguration(["mood": .string("happy")])
        guard case .sprite(let moodOnly) = happy.layers[0] else { Issue.record("Expected a sprite"); return }
        #expect(moodOnly.clipId == "idle" && moodOnly.expressionId == "happy")
        #expect(AnimatedLayer.sprite(moodOnly).referencedImageAssetIDs.count == 3)
        #expect(source.allConfigurationImageAssetIDs.count == 3)
    }
    @Test func spriteBindingsAreCheckedAgainstTheSprite() throws {
        var source = try spriteDocument()
        source.configuration?.variants[4].layers[0] = .init(layerId: "hero", clip: "dance")
        #expect(throws: AnimatedConfigurationError.self) { try source.validated() }
        source = try spriteDocument()
        source.configuration?.variants[1].layers[0] = .init(layerId: "hero", expression: "angry")
        #expect(throws: AnimatedConfigurationError.self) { try source.validated() }
        // Two families claiming `hero.clip` conflict, as two families claiming a source would.
        source = try spriteDocument()
        source.configuration?.variants[1].layers[0] = .init(layerId: "hero", clip: "wave")
        #expect(throws: AnimatedConfigurationError.self) { try source.validated() }
        // A clip binding on a layer that is not a sprite has nothing to select.
        source = try spriteDocument()
        source.configuration?.variants[3].layers[0] = .init(layerId: "spark", clip: "idle")
        #expect(throws: AnimatedConfigurationError.self) { try source.validated() }
    }

    private func castDocument() throws -> AnimatedDocument {
        let url = try #require(Bundle.module.url(
            forResource: "sticker-document-v5-cast", withExtension: "json", subdirectory: "Fixtures"
        ))
        return try JSONDecoder().decode(AnimatedDocument.self, from: Data(contentsOf: url)).validated()
    }

    /// The numbers here are the whole point of the per-layer model, and they are asserted the same
    /// way on the server: thirty-six pairings, but only twelve states to prepare.
    @Test func aCastPreparesPerCharacterRatherThanAcrossTheWholeSticker() throws {
        let source = try castDocument()
        let configuration = try #require(source.configuration)
        #expect(try JSONDecoder().decode(AnimatedDocument.self, from: JSONEncoder().encode(source)) == source)
        #expect(configuration.combinationCount == 36)
        #expect(configuration.layerCombinationCounts == ["hero": 6, "sidekick": 6])
        #expect(configuration.preparedStateCount == 12)
        #expect(configuration.coverageSelections.count == 12)

        let rendered = try source.resolvingConfiguration([
            "catMood": .string("sad"), "catPose": .string("wave"), "dogMood": .string("happy")
        ])
        guard case .sprite(let cat) = rendered.layers[0], case .sprite(let dog) = rendered.layers[1] else {
            Issue.record("Expected both characters to stay sprites"); return
        }
        #expect(cat.clipId == "wave" && cat.expressionId == "sad")
        // The dog's pose was never chosen, so it stays on its own authored default rather than the cat's.
        #expect(dog.clipId == "idle" && dog.expressionId == "happy")
    }

    @Test func controlsGroupUnderTheCharacterTheyPose() throws {
        let cast: AnimatedControlConfiguration = try #require(castDocument().configuration)
        let groups = cast.controlGroups
        #expect(groups.map(\.layerID) == ["hero", "sidekick", nil])
        // Sparkles hides an accessory rather than posing a character, so it belongs to the sticker.
        #expect(groups.map { $0.controls.map(\.id) } == [["catMood", "catPose"], ["dogMood", "dogPose"], ["sparkles", "speed"]])
        // One character is one group, which is what keeps a single-character sheet ungrouped.
        let solo: AnimatedControlConfiguration = try #require(spriteDocument().configuration)
        #expect(solo.controlGroups.filter { $0.layerID != nil }.count == 1)
    }

    /// The device counts a character's states; it does not price them.
    ///
    /// Eighty-one states on one sprite is over every budget the server has ever set, and this
    /// document still validates here — how much may be prepared is the server's to say, over
    /// `GET /api/v1/configuration-limits` and its own check on the way in. What the device owes is
    /// the count those decisions are made from.
    @Test func aCharactersCombinationsAreCountedRatherThanPriced() throws {
        var source = try castDocument()
        // Two axes selected together, twice over, is the only shape that can overrun one sprite:
        // three options on each of four axes acting on the dog is eighty-one states for it alone.
        source.configuration?.controls.removeAll { $0.id.hasPrefix("dog") }
        source.configuration?.variants.removeAll { $0.id.hasPrefix("dog_") }
        for (first, second, faces) in [("hat", "scarf", true), ("gait", "tilt", false)].map({ ($0.0, $0.1, $0.2) }) {
            for axis in [first, second] {
                source.configuration?.controls.append(.init(
                    id: axis, label: axis, type: .choice, defaultValue: .string("a"),
                    options: ["a", "b", "c"].map { .init(id: $0, label: $0.uppercased()) }
                ))
            }
            for (index, left) in ["a", "b", "c"].enumerated() {
                for right in ["a", "b", "c"] {
                    source.configuration?.variants.append(.init(
                        id: "\(first)_\(left)_\(right)", selections: [first: left, second: right],
                        layers: [faces
                            ? .init(layerId: "sidekick", expression: ["neutral", "happy", "sad"][index])
                            : .init(layerId: "sidekick", clip: ["idle", "wave", "idle"][index])]
                    ))
                }
            }
        }
        #expect(try #require(source.configuration).layerCombinationCounts["sidekick"] == 81)
        #expect(try #require(source.configuration).preparedStateCount == 87)
        #expect(throws: Never.self) { try source.validated() }
    }
}
