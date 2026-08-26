import Foundation
import Testing
@testable import AnimatedView

/// The undo stack and the observable editor that drives it.
///
/// `AnimatedDocumentEditor` is `@MainActor`, so the suite is too — it still runs headless under
/// `swift test` on macOS, which is the whole reason the editing model is kept out of `#if os(iOS)`.
@MainActor
struct EditorUndoTests {
    private func editor(layers: Int = 1) -> AnimatedDocumentEditor {
        let shapes = (0..<layers).map { index in
            AnimatedLayer.shape(.init(
                base: .init(id: "layer\(index)", name: "Layer \(index)"),
                shape: .circle,
                fill: .solid("#FFFFFF")
            ))
        }
        return .init(document: .init(kind: .animated, durationSeconds: 2, layers: shapes))
    }

    // MARK: - The stack in isolation

    @Test func undoRestoresAnExactlyEqualDocument() {
        let subject = editor()
        let original = subject.document
        subject.renameLayer(id: "layer0", to: "Renamed")
        #expect(subject.document != original)

        subject.undo()
        #expect(subject.document == original, "undo must restore the document exactly")
        #expect(!subject.canUndo)
    }

    @Test func redoReappliesTheUndoneEdit() {
        let subject = editor()
        subject.renameLayer(id: "layer0", to: "Renamed")
        let edited = subject.document

        subject.undo()
        #expect(subject.canRedo)
        subject.redo()
        #expect(subject.document == edited)
        #expect(!subject.canRedo)
    }

    /// A new edit after an undo forks the timeline, so the redo branch is no longer reachable.
    @Test func aNewEditInvalidatesRedo() {
        let subject = editor()
        subject.renameLayer(id: "layer0", to: "First")
        subject.undo()
        #expect(subject.canRedo)

        subject.renameLayer(id: "layer0", to: "Second")
        #expect(!subject.canRedo)
    }

    /// A drag emits an edit per frame. Without coalescing, undoing a two-second drag would take
    /// sixty taps.
    @Test func aCoalescedGestureCollapsesIntoOneUndoStep() {
        let subject = editor()
        let original = subject.document

        subject.beginGesture("drag")
        for step in 1...60 {
            subject.setPosition(AnimatedPoint(x: 0.5 + Double(step) / 1000, y: 0.5), forLayer: "layer0")
        }
        subject.endGesture()

        #expect(subject.document != original)
        subject.undo()
        #expect(subject.document == original, "the whole drag should undo in one step")
        #expect(!subject.canUndo)
    }

    /// Two separate drags are two separate undo steps, even though they share a coalescing key.
    @Test func endingAGestureStartsAFreshUndoStep() {
        let subject = editor()
        let original = subject.document

        subject.beginGesture("drag")
        subject.setPosition(AnimatedPoint(x: 0.6, y: 0.5), forLayer: "layer0")
        subject.endGesture()
        let afterFirst = subject.document

        subject.beginGesture("drag")
        subject.setPosition(AnimatedPoint(x: 0.7, y: 0.5), forLayer: "layer0")
        subject.endGesture()

        subject.undo()
        #expect(subject.document == afterFirst)
        subject.undo()
        #expect(subject.document == original)
    }

    @Test func theStackIsBoundedAndDropsTheOldestEntry() {
        var stack = AnimatedEditorUndoStack()
        let document = AnimatedDocument(kind: .static, layers: [])
        for index in 0..<(AnimatedEditorUndoStack.limit + 20) {
            stack.record(document, name: "Edit \(index)")
        }
        #expect(stack.undoDepth == AnimatedEditorUndoStack.limit)
        // The most recent entries are the ones kept.
        #expect(stack.undoActionName == "Edit \(AnimatedEditorUndoStack.limit + 19)")
    }

    @Test func replacingTheDocumentClearsTheHistory() {
        let subject = editor()
        subject.renameLayer(id: "layer0", to: "Renamed")
        #expect(subject.canUndo)

        subject.replaceDocument(.init(kind: .static, layers: []))
        #expect(!subject.canUndo)
        #expect(!subject.canRedo)
    }

    // MARK: - Refused edits

    /// A refused edit must be a true no-op: no document change, and nothing pushed onto the stack
    /// that would make undo appear to do something.
    @Test func arefusedEditChangesNothingAndRecordsNoUndoStep() {
        let subject = editor(layers: AnimatedDocument.maximumLayerCount)
        let original = subject.document

        subject.addLayer(.shape)
        #expect(subject.document == original)
        #expect(!subject.canUndo)
        #expect(subject.lastError == .layerLimitReached)
    }

    @Test func anEditThatChangesNothingRecordsNoUndoStep() {
        let subject = editor()
        subject.setHidden(false, forLayer: "layer0")   // already visible
        #expect(!subject.canUndo)
    }

    // MARK: - Selection follows the document

    /// Undoing an "add layer" removes the thing that is selected. A dangling selection would leave
    /// the inspector rendering an empty shell.
    @Test func undoingAnAddClearsTheSelectionItLeftBehind() {
        let subject = editor()
        let created = subject.addLayer(.text)
        #expect(subject.selectedLayerID == created)

        subject.undo()
        #expect(subject.selectedLayerID == nil)
    }

    @Test func deletingTheSelectedLayerClearsTheSelection() {
        let subject = editor()
        subject.selectedLayerID = "layer0"
        subject.removeLayer(id: "layer0")
        #expect(subject.selectedLayerID == nil)
    }

    @Test func deletingAKeyframeClearsAStaleSelection() {
        let subject = editor()
        subject.selectedLayerID = "layer0"
        subject.scrubDocumentTime = 1
        subject.insertKeyframe(on: .opacity, forLayer: "layer0")
        #expect(subject.selectedKeyframe != nil)

        subject.removeKeyframe(on: .opacity, forLayer: "layer0", index: 0)
        #expect(subject.selectedKeyframe == nil)
    }

    /// Shortening a document while the playhead sits past the new end would leave the scrubber
    /// pointing outside the timeline.
    @Test func theScrubTimeStaysInsideTheTimeline() {
        let subject = editor()
        subject.scrubDocumentTime = 2
        subject.setTiming(durationSeconds: 1)
        #expect(subject.scrubDocumentTime == 1)

        subject.scrubDocumentTime = 99
        #expect(subject.scrubDocumentTime == 1)
        subject.scrubDocumentTime = -5
        #expect(subject.scrubDocumentTime == 0)
    }

    /// A static document has no timeline at all, so the playhead has nowhere to be but zero.
    @Test func aStaticDocumentPinsThePlayheadToZero() {
        let subject = editor()
        subject.scrubDocumentTime = 1.5
        subject.setKind(.static)
        #expect(subject.scrubDocumentTime == 0)
    }

    // MARK: - Issues

    @Test func issuesTrackTheDocumentAfterEachEdit() {
        let subject = editor()
        #expect(subject.canSave)

        subject.renameLayer(id: "layer0", to: "  ")
        #expect(!subject.canSave)
        #expect(subject.blockingIssues.contains { $0.layerID == "layer0" })

        subject.undo()
        #expect(subject.canSave)
        #expect(throws: Never.self) { try subject.validatedDocument() }
    }

    // MARK: - Detach confirmation

    @Test func detachIsConfirmedOncePerLayer() throws {
        let declarative = AnimatedLayer.shape(.init(
            base: .init(id: "hero", name: "Hero", animations: [.fadeIn(duration: 0.5)]),
            shape: .circle,
            fill: .solid("#FFFFFF")
        ))
        let document = try AnimatedDocument(kind: .animated, durationSeconds: 2, layers: [declarative]).compiled()
        let subject = AnimatedDocumentEditor(document: document)

        #expect(subject.needsDetachConfirmation(forLayer: "hero"))
        subject.detachAnimations(forLayer: "hero")
        #expect(!subject.needsDetachConfirmation(forLayer: "hero"))
        #expect(subject.document.layers[0].animations.isEmpty)
        // The keyframes the specs produced are still there, and still valid.
        #expect(!subject.document.layers[0].animation.isEmpty)
        #expect(throws: Never.self) { try subject.validatedDocument() }
    }

    /// The one canvas edit a declarative layer cannot take: the anchor has no effects field, and
    /// its keyframes are derived.
    @Test func anEffectEditOnADeclarativeLayerSurfacesTheError() throws {
        let declarative = AnimatedLayer.shape(.init(
            base: .init(id: "hero", name: "Hero", animations: [.fadeIn(duration: 0.5)]),
            shape: .circle,
            fill: .solid("#FFFFFF")
        ))
        let document = try AnimatedDocument(kind: .animated, durationSeconds: 2, layers: [declarative]).compiled()
        let subject = AnimatedDocumentEditor(document: document)
        let original = subject.document

        subject.scrubDocumentTime = 1
        subject.setEffects(AnimatedEffectValue(blurRadius: 4), forLayer: "hero")
        #expect(subject.lastError == .layerIsDeclarative("hero"))
        #expect(subject.document == original, "a refused edit must change nothing")
        #expect(!subject.canUndo)
    }

    /// Moving a declarative layer around the canvas *is* allowed — it writes the anchor and
    /// recompiles, which keeps the document in agreement with itself.
    @Test func draggingADeclarativeLayerWritesTheAnchorAndRecompiles() throws {
        let declarative = AnimatedLayer.shape(.init(
            base: .init(id: "hero", name: "Hero", animations: [.fadeIn(duration: 0.5)]),
            shape: .circle,
            fill: .solid("#FFFFFF")
        ))
        let document = try AnimatedDocument(kind: .animated, durationSeconds: 2, layers: [declarative]).compiled()
        let subject = AnimatedDocumentEditor(document: document)

        subject.setPosition(AnimatedPoint(x: 0.2, y: 0.8), forLayer: "hero")
        #expect(subject.lastError == nil)
        #expect(subject.document.layers[0].anchor.position == AnimatedPoint(x: 0.2, y: 0.8))
        #expect(!subject.document.layers[0].animations.isEmpty, "the specs survive")
        #expect(try subject.document.compiled() == subject.document, "still agrees with its own recompilation")
    }
}
