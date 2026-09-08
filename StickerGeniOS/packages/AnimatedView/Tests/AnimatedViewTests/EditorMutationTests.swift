import Foundation
import Testing
@testable import AnimatedView

/// Document-level editing: adding, removing, reordering, and renaming layers, plus the document's
/// own settings.
///
/// The recurring assertion is `try document.validated()` — an editor that can put a document into a
/// state the schema rejects has only moved the failure to save time, where the user can no longer
/// tell which edit caused it.
struct EditorMutationTests {
    private let assetID = "11111111-1111-4111-8111-111111111111"

    private func staticDocument(layers: [AnimatedLayer] = []) -> AnimatedDocument {
        .init(kind: .static, layers: layers)
    }

    private func shape(_ id: String) -> AnimatedLayer {
        .shape(.init(base: .init(id: id, name: id), shape: .circle, fill: .solid("#FFFFFF")))
    }

    // MARK: - Starter layers

    @Test(arguments: AnimatedLayerType.allCases.filter(\.isAuthorable))
    func everyStarterLayerProducesAValidDocument(type: AnimatedLayerType) throws {
        let (document, id) = try staticDocument().addingStarterLayer(type, assetID: assetID)
        #expect(document.layers.count == 1)
        #expect(document.layer(id: id) != nil)
        #expect(try document.validated().layers.count == 1)
        #expect(document.editorIssues.filter { $0.severity == .blocking }.isEmpty)
    }

    /// The add menu is driven by `isAuthorable`, so a type that reports itself authorable but has no
    /// starter would put a dead button in the menu — and one with a starter that the menu hides
    /// would be unreachable. This pins the two halves together.
    @Test(arguments: AnimatedLayerType.allCases)
    func onlyAuthorableTypesHaveAStarter(type: AnimatedLayerType) {
        let starter = AnimatedEditorDefaults.layer(type, id: "probe", assetID: assetID)
        #expect((starter != nil) == type.isAuthorable)
    }

    /// `AnimatedShapeLayer.isValid` rejects a shape with neither fill nor stroke, because it draws
    /// nothing. A starter that tripped that would look like a broken button.
    @Test func theStarterShapeHasAFill() throws {
        let (document, id) = try staticDocument().addingStarterLayer(.shape)
        guard case .shape(let layer) = try #require(document.layer(id: id)) else {
            Issue.record("expected a shape layer")
            return
        }
        #expect(layer.fill != nil)
        #expect(layer.isValid)
    }

    @Test func theStarterTextIsNotEmpty() throws {
        let (document, id) = try staticDocument().addingStarterLayer(.text)
        guard case .text(let layer) = try #require(document.layer(id: id)) else {
            Issue.record("expected a text layer")
            return
        }
        #expect(!layer.text.isEmpty)
        #expect(layer.isValid)
    }

    /// A document carries no pixels, so an image layer without a host-resolved asset is meaningless.
    @Test func anImageLayerNeedsAValidAsset() {
        #expect(AnimatedEditorDefaults.layer(.image, id: "img", assetID: nil) == nil)
        #expect(AnimatedEditorDefaults.layer(.image, id: "img", assetID: "not-a-uuid") == nil)
        #expect(AnimatedEditorDefaults.layer(.image, id: "img", assetID: assetID) != nil)
    }

    @Test func theStarterSVGPassesTheHostileMarkupCheck() {
        #expect(AnimatedSVGSource.inline(markup: AnimatedEditorDefaults.starterSVGMarkup).isValid)
    }

    // MARK: - Limits

    @Test func addingBeyondTheLayerLimitIsRefused() throws {
        var document = staticDocument()
        for index in 0..<AnimatedDocument.maximumLayerCount {
            document = try document.addingLayer(shape("layer\(index)"))
        }
        #expect(document.layers.count == AnimatedDocument.maximumLayerCount)
        #expect(throws: AnimatedEditorError.layerLimitReached) {
            try document.addingLayer(shape("overflow"))
        }
        // And the refusal left the document exactly as it was.
        #expect(document.layers.count == AnimatedDocument.maximumLayerCount)
        #expect(try document.validated().layers.count == AnimatedDocument.maximumLayerCount)
    }

    // MARK: - Ordering

    @Test func addingPutsALayerOnTopByDefault() throws {
        let document = try staticDocument(layers: [shape("a")]).addingLayer(shape("b"))
        // Index 0 is drawn first, so the last element is the top-most layer.
        #expect(document.layers.map(\.id) == ["a", "b"])
    }

    @Test func movingALayerChangesPaintOrder() throws {
        let document = staticDocument(layers: [shape("a"), shape("b"), shape("c")])
        #expect(try document.movingLayer(id: "a", toIndex: 2).layers.map(\.id) == ["b", "c", "a"])
        #expect(try document.movingLayer(id: "c", toIndex: 0).layers.map(\.id) == ["c", "a", "b"])
    }

    @Test func movingClampsAnOutOfRangeDestination() throws {
        let document = staticDocument(layers: [shape("a"), shape("b")])
        #expect(try document.movingLayer(id: "a", toIndex: 99).layers.map(\.id) == ["b", "a"])
        #expect(try document.movingLayer(id: "b", toIndex: -5).layers.map(\.id) == ["b", "a"])
    }

    /// The layer list shows top-most first, so it renders the array reversed. Getting the index
    /// translation wrong is the classic way a reorder silently moves the wrong layer.
    @Test func displayAndModelIndicesAreMirrorImages() {
        let count = 4
        #expect(AnimatedLayerListOrder.modelIndex(displayIndex: 0, count: count) == 3)
        #expect(AnimatedLayerListOrder.modelIndex(displayIndex: 3, count: count) == 0)
        // The mapping is its own inverse, which is what makes a round trip safe.
        let round = (0..<count).map {
            AnimatedLayerListOrder.modelIndex(
                displayIndex: AnimatedLayerListOrder.modelIndex(displayIndex: $0, count: count),
                count: count
            )
        }
        #expect(round == Array(0..<count))
    }

    /// `.onMove` hands back a destination that is an insertion point in the *pre-removal* display
    /// array, while `movingLayer` wants a final index in the model array. Reconciling those two
    /// conventions across a reversal is the sharpest edge in the whole layer list, so this walks a
    /// real reorder end to end rather than asserting on the arithmetic alone.
    @Test func onMoveDestinationTranslatesIntoModelSpace() throws {
        // Model [a, b, c] displays as [c, b, a] — c on top.
        let document = staticDocument(layers: [shape("a"), shape("b"), shape("c")])
        let count = document.layers.count

        func reorder(fromDisplay displayIndex: Int, toDisplayDestination destination: Int) throws -> [String] {
            let displayed = Array(document.layers.reversed())
            let target = AnimatedLayerListOrder.modelDestination(
                displayDestination: destination, movingFrom: displayIndex, count: count
            )
            return try document.movingLayer(id: displayed[displayIndex].id, toIndex: target).layers.map(\.id)
        }

        // Drag the top layer ("c") to the bottom of the list: display [b, a, c] → model [c, a, b].
        #expect(try reorder(fromDisplay: 0, toDisplayDestination: 3) == ["c", "a", "b"])
        // Drag the bottom layer ("a") to the top of the list: display [a, c, b] → model [b, c, a].
        #expect(try reorder(fromDisplay: 2, toDisplayDestination: 0) == ["b", "c", "a"])
        // A one-step nudge down the list moves it one step down the array.
        #expect(try reorder(fromDisplay: 0, toDisplayDestination: 2) == ["a", "c", "b"])
        // Dropping a row back where it started is a no-op.
        #expect(try reorder(fromDisplay: 1, toDisplayDestination: 1) == ["a", "b", "c"])
    }

    @Test func moveDestinationStaysInBoundsForDegenerateInput() {
        #expect(AnimatedLayerListOrder.modelDestination(displayDestination: 99, movingFrom: 0, count: 3) == 0)
        #expect(AnimatedLayerListOrder.modelDestination(displayDestination: -5, movingFrom: 2, count: 3) == 2)
        #expect(AnimatedLayerListOrder.modelDestination(displayDestination: 0, movingFrom: 0, count: 0) == 0)
    }

    // MARK: - Duplicate

    @Test func duplicatingMintsAUniqueIDAndKeepsKeyframes() throws {
        let animation = AnimatedLayerAnimation(opacity: [
            .init(timeSeconds: 0, value: 0),
            .init(timeSeconds: 1, value: 1)
        ])
        let original = AnimatedLayer.shape(.init(
            base: .init(id: "star", name: "Star", animation: animation),
            shape: .fivePointStar,
            fill: .solid("#FFCC00")
        ))
        var document = AnimatedDocument(kind: .animated, durationSeconds: 2, layers: [original])
        document = try document.duplicatingLayer(id: "star")

        #expect(document.layers.count == 2)
        #expect(Set(document.layers.map(\.id)).count == 2, "duplicate must not reuse the source id")
        #expect(document.layers[1].id == "star-2")
        #expect(document.layers[1].name == "Star copy")
        #expect(document.layers[1].animation == animation, "keyframes come along unchanged")
        // Sits directly above its source.
        #expect(document.layers.map(\.id) == ["star", "star-2"])
        #expect(try document.validated().layers.count == 2)
    }

    @Test func uniqueLayerIDSanitisesAndDeduplicates() {
        let document = staticDocument(layers: [shape("hero"), shape("hero-2")])
        #expect(document.uniqueLayerID(preferring: "hero") == "hero-3")
        #expect(document.uniqueLayerID(preferring: "fresh") == "fresh")
        // Characters the id pattern forbids are folded rather than rejected, because this is called
        // with human input like a layer's name.
        #expect(document.uniqueLayerID(preferring: "my layer!").isAnimatedLayerID)
        #expect(document.uniqueLayerID(preferring: "").isAnimatedLayerID)
    }

    // MARK: - Layer properties

    @Test func hiddenBlendAndNameRoundTrip() throws {
        var document = staticDocument(layers: [shape("a")])
        document = try document.settingHidden(true, forLayer: "a")
        document = try document.settingBlendMode(.multiply, forLayer: "a")
        document = try document.renamingLayer(id: "a", to: "Backdrop")

        #expect(document.layers[0].hidden)
        #expect(document.layers[0].blendMode == .multiply)
        #expect(document.layers[0].name == "Backdrop")
        #expect(try document.validated().layers.count == 1)
    }

    /// A name is empty for a moment while it is being retyped. That has to be reportable without
    /// being refused, or the editor fights the user mid-keystroke.
    @Test func aBlankNameIsAnIssueRatherThanAnError() throws {
        let document = try staticDocument(layers: [shape("a")]).renamingLayer(id: "a", to: "   ")
        #expect(document.layers[0].name == "   ")
        let blocking = document.editorIssues.filter { $0.severity == .blocking }
        #expect(blocking.contains { $0.layerID == "a" && $0.message.contains("needs a name") })
        #expect(throws: (any Error).self) { try document.validated() }
    }

    @Test func editingAnUnknownLayerThrows() {
        let document = staticDocument(layers: [shape("a")])
        #expect(throws: AnimatedEditorError.layerNotFound("ghost")) {
            try document.renamingLayer(id: "ghost", to: "x")
        }
    }

    @Test func anchorEditsRoundTripAndStayValid() throws {
        var anchor = AnimatedAnchor.default
        anchor.position = AnimatedPoint(x: 0.25, y: 0.75)
        anchor.scale = AnimatedPoint(x: 1.5, y: 0.5)
        anchor.rotationDegrees = -30
        anchor.opacity = 0.4

        let document = try staticDocument(layers: [shape("a")]).settingAnchor(anchor, forLayer: "a")
        #expect(document.layers[0].anchor == anchor)
        #expect(try document.validated().layers.count == 1)
    }

    // MARK: - Document settings

    @Test func canvasSizeIsClampedToTheSupportedRange() throws {
        let document = staticDocument(layers: [shape("a")])
        let tiny = document.settingCanvas(.init(width: 4, height: 4))
        #expect(tiny.canvas.width == AnimatedCanvas.minimumDimension)
        #expect(try tiny.validated().canvas.width == 16)

        let huge = document.settingCanvas(.init(width: 99_999, height: 99_999))
        #expect(huge.canvas.width == AnimatedCanvas.maximumDimension)
        #expect(try huge.validated().canvas.width == 4096)
    }

    /// Positions are normalized, so reshaping the canvas moves nothing. This is the assertion
    /// behind telling the user "no layer moves" when they resize.
    @Test func resizingTheCanvasDoesNotMoveLayers() throws {
        var anchor = AnimatedAnchor.default
        anchor.position = AnimatedPoint(x: 0.25, y: 0.75)
        let document = try staticDocument(layers: [shape("a")]).settingAnchor(anchor, forLayer: "a")
        let wide = document.settingCanvas(.init(width: 1024, height: 384))
        #expect(wide.layers[0].anchor.position == anchor.position)
        #expect(wide.canvas.aspectRatio > 2.6)
    }

    @Test func speedIsClampedAndNeverTouchesKeyframes() throws {
        let animation = AnimatedLayerAnimation(opacity: [.init(timeSeconds: 0.5, value: 0.5)])
        let layer = AnimatedLayer.shape(.init(
            base: .init(id: "a", name: "A", animation: animation),
            shape: .circle,
            fill: .solid("#FFFFFF")
        ))
        let document = AnimatedDocument(kind: .animated, durationSeconds: 2, layers: [layer])

        let fast = document.settingSpeed(4)
        #expect(fast.speed == 4)
        #expect(fast.layers[0].animation == animation, "speed is a playback multiplier, not a rewrite")

        #expect(document.settingSpeed(99).speed == AnimatedDocument.speedRange.upperBound)
        #expect(document.settingSpeed(0).speed == AnimatedDocument.speedRange.lowerBound)
    }
}
