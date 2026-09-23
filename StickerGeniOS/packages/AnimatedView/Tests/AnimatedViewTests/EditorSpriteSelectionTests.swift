import Foundation
import Testing
@testable import AnimatedView

/// Selecting a controllable character must leave it on the canvas: the stage draws
/// `displayDocument`, and the outline samples the selected layer's state at the playhead.
@MainActor
struct EditorSpriteSelectionTests {
    private func spriteDocument() throws -> AnimatedDocument {
        let url = try #require(Bundle.module.url(
            forResource: "sticker-document-v5-sprite", withExtension: "json", subdirectory: "Fixtures"
        ))
        return try JSONDecoder().decode(AnimatedDocument.self, from: Data(contentsOf: url)).validated()
    }

    @Test func selectingTheSpriteKeepsItDrawnWithAFiniteOutline() throws {
        let editor = AnimatedDocumentEditor(document: try spriteDocument())
        let sprite = try #require(editor.document.layers.first { $0.type == .sprite })
        let before = editor.displayDocument

        editor.selectedLayerID = sprite.id

        #expect(editor.displayDocument == before)
        let selected = try #require(editor.selectedLayer)
        #expect(!selected.hidden)
        for time in stride(from: 0, through: editor.document.durationSeconds, by: 0.25) {
            let state = AnimationInterpolator.state(for: selected, atDocumentTime: time)
            let finite = [state.position.x, state.position.y, state.scale.x, state.scale.y].allSatisfy { $0.isFinite }
            #expect(finite)
        }
    }

    @Test func previewingAnOptionKeepsTheSpriteResolved() throws {
        let editor = AnimatedDocumentEditor(document: try spriteDocument())
        let sprite = try #require(editor.document.layers.first { $0.type == .sprite })
        editor.previewControlValues = ["mood": .string("sad"), "pose": .string("wave")]
        editor.selectedLayerID = sprite.id

        guard case .sprite(let shown)? = editor.selectedLayer else { Issue.record("Expected a sprite"); return }
        #expect(shown.clipId == "wave" && shown.expressionId == "sad")
        #expect(editor.displayDocument.configuration == nil)
    }
}
