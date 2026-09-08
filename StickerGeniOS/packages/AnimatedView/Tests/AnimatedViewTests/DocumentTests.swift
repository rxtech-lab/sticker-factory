import Foundation
import Testing
@testable import AnimatedView

struct DocumentTests {
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private func roundTrip(_ document: AnimatedDocument) throws -> AnimatedDocument {
        try JSONDecoder().decode(AnimatedDocument.self, from: Self.encoder.encode(document))
    }

    // MARK: - Preview fixtures

    /// Every shipped fixture must compile and validate.
    ///
    /// This is what makes the `try!` inside `AnimatedPreviewDocuments` safe: a fixture whose specs
    /// cannot compile is a bug that should stop the build here rather than trap in someone's Xcode
    /// canvas, and one that compiles but fails validation would be a document the server refuses.
    @Test(arguments: AnimatedPreviewDocuments.all.map(\.title))
    func previewFixturesValidate(_ title: String) throws {
        let document = try #require(AnimatedPreviewDocuments.all.first { $0.title == title }?.document)
        try document.validated()
        #expect(document.totalKeyframeCount <= AnimatedDocument.maximumKeyframeCount)
        #expect(!document.layers.isEmpty)
    }

    @Test(arguments: AnimatedPreviewDocuments.all.map(\.title))
    func previewFixturesRoundTripThroughJSON(_ title: String) throws {
        let document = try #require(AnimatedPreviewDocuments.all.first { $0.title == title }?.document)
        #expect(try roundTrip(document) == document)
    }

    /// Compiling an already-compiled document must be a no-op, which is the same invariant the
    /// server's document schema enforces when it recompiles and compares.
    @Test(arguments: AnimatedPreviewDocuments.all.map(\.title))
    func compilationIsIdempotent(_ title: String) throws {
        let document = try #require(AnimatedPreviewDocuments.all.first { $0.title == title }?.document)
        #expect(try document.compiled() == document)
    }

    // MARK: - Lenient decoding

    /// The server materialises every default before it serialises, but hand-written documents,
    /// upcast v1 payloads, and fixtures do not. Swift's synthesized decoder ignores property
    /// defaults, so these have to be explicit — and this is what proves they are.
    @Test func decodesAMinimalDocument() throws {
        let json = """
        {"kind":"animated","layers":[{"type":"shape","id":"a","name":"A","shape":{"kind":"circle"},"fill":{"type":"solid",\
        "color":"#FF0000"}}]}
        """
        let document = try JSONDecoder().decode(AnimatedDocument.self, from: Data(json.utf8))
        #expect(document.version == AnimatedDocument.currentVersion)
        #expect(document.canvas == AnimatedCanvas())
        #expect(document.durationSeconds == 2)
        #expect(document.fps == 30)
        #expect(document.loop == .loop)
        #expect(document.speed == 1)
        #expect(document.background == AnimatedBackground.none)
        let layer = try #require(document.layers.first)
        #expect(layer.hidden == false)
        #expect(layer.anchor == .default)
        #expect(layer.animation.isEmpty)
        #expect(layer.blendMode == .normal)
    }

    @Test func staticDocumentDefaultsToZeroTiming() throws {
        let json = #"{"kind":"static","layers":[]}"#
        let document = try JSONDecoder().decode(AnimatedDocument.self, from: Data(json.utf8))
        #expect(document.durationSeconds == 0)
        #expect(document.fps == 0)
        #expect(document.loop == .once)
    }

    @Test func layersEncodeWithATypeDiscriminator() throws {
        for (_, document) in AnimatedPreviewDocuments.all {
            let data = try Self.encoder.encode(document)
            let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            let layers = try #require(object["layers"] as? [[String: Any]])
            for layer in layers {
                let type = try #require(layer["type"] as? String)
                #expect(AnimatedLayerType(rawValue: type) != nil, "Unknown layer type \(type)")
            }
        }
    }

    // MARK: - Validation

    @Test func rejectsAnUnsupportedVersion() {
        var document = AnimatedPreviewDocuments.staticDocument
        document.version = 99
        #expect(throws: AnimatedDocumentError.unsupportedVersion(99)) { try document.validated() }
    }

    @Test func rejectsDuplicateLayerIDs() {
        var document = AnimatedPreviewDocuments.staticDocument
        document.layers.append(document.layers[0])
        #expect(throws: AnimatedDocumentError.duplicateLayerID) { try document.validated() }
    }

    @Test func rejectsAKeyframeBeyondTheDuration() {
        var document = AnimatedPreviewDocuments.svgDrawOnSimple
        document.layers[0].base.animations = []
        document.layers[0].base.animation = .init(opacity: [.init(timeSeconds: 99, value: 1)])
        #expect(throws: AnimatedDocumentError.self) { try document.validated() }
    }

    @Test func rejectsMotionOnAStaticDocument() {
        var document = AnimatedPreviewDocuments.staticDocument
        document.layers[0].base.animation = .init(opacity: [.init(timeSeconds: 0.5, value: 1)])
        #expect(throws: AnimatedDocumentError.self) { try document.validated() }
    }

    @Test func rejectsASpeedOutsideTheSupportedRange() {
        var document = AnimatedPreviewDocuments.composite
        document.speed = 0
        #expect(throws: AnimatedDocumentError.invalidSpeed) { try document.validated() }
    }

    @Test func rejectsAShapeThatDrawsNothing() {
        let layer = AnimatedShapeLayer(base: .init(id: "a", name: "A"), shape: .circle)
        #expect(layer.isValid == false)
    }

    @Test func rejectsAnInvalidCanvas() {
        var document = AnimatedPreviewDocuments.staticDocument
        document.canvas = .init(width: 4, height: 4)
        #expect(throws: AnimatedDocumentError.invalidCanvas) { try document.validated() }
    }

    // MARK: - SVG source safety

    @Test func acceptsOrdinarySVGMarkup() {
        #expect(AnimatedSVGSource.inline(markup: AnimatedPreviewSVG.gradientBadge).isValid)
        #expect(AnimatedSVGSource.inline(markup: AnimatedPreviewSVG.textBadge).isValid)
        // The xmlns declaration is an http URL and must not be mistaken for a remote reference.
        #expect(AnimatedPreviewSVG.gradientBadge.contains("http://www.w3.org/2000/svg"))
    }

    @Test func acceptsInternalReferencesAndDataURIs() {
        // Double-hash delimiters: the markup itself contains `"#`, which would close a `#"…"#` literal.
        let internalRef = ##"<svg xmlns="http://www.w3.org/2000/svg"><use href="#a"/><rect fill="url(#g)"/></svg>"##
        #expect(AnimatedSVGSource.inline(markup: internalRef).isValid)
        let dataURI = #"<svg xmlns="http://www.w3.org/2000/svg"><image href="data:image/png;base64,iVBORw0KGgo//8AAAA="/></svg>"#
        #expect(AnimatedSVGSource.inline(markup: dataURI).isValid)
    }

    @Test(arguments: [
        #"<svg xmlns="http://www.w3.org/2000/svg"><script>alert(1)</script></svg>"#,
        #"<svg xmlns="http://www.w3.org/2000/svg"><foreignObject><div/></foreignObject></svg>"#,
        #"<svg xmlns="http://www.w3.org/2000/svg"><image href="https://example.com/a.png"/></svg>"#,
        ##"<svg xmlns="http://www.w3.org/2000/svg"><use href="//example.com/a.svg#x"/></svg>"##,
        #"<svg xmlns="http://www.w3.org/2000/svg"><a href="javascript:alert(1)"><rect/></a></svg>"#
    ])
    func rejectsHostileSVGMarkup(_ markup: String) {
        #expect(AnimatedSVGSource.inline(markup: markup).isValid == false)
    }

    @Test func rejectsANonUUIDAssetReference() {
        #expect(AnimatedSVGSource.asset(assetId: "not-a-uuid").isValid == false)
        #expect(AnimatedSVGSource.asset(assetId: AnimatedPreviewDocuments.imageAssetID).isValid)
    }

    // MARK: - Paint

    @Test func paintRoundTrips() throws {
        let paints: [AnimatedPaint] = [
            .solid("#123456"),
            .solid("#12345678"),
            .linearGradient("#000000", "#FFFFFF", angleDegrees: 45),
            .radialGradient(
                stops: [.init(color: "#FF0000", location: 0), .init(color: "#00FF00", location: 1)],
                center: .center,
                radius: 0.4
            )
        ]
        for paint in paints {
            #expect(paint.isValid)
            let decoded = try JSONDecoder().decode(AnimatedPaint.self, from: Self.encoder.encode(paint))
            #expect(decoded == paint)
        }
    }

    @Test func rejectsMalformedColors() {
        #expect(AnimatedPaint.solid("red").isValid == false)
        #expect(AnimatedPaint.solid("#12345").isValid == false)
        #expect(AnimatedPaint.linearGradient(stops: [.init(color: "#000000", location: 0)], angleDegrees: 0).isValid == false)
    }

    @Test func backgroundRoundTrips() throws {
        let backgrounds: [AnimatedBackground] = [
            .none,
            .solid("#FFFFFF"),
            .linearGradient("#FFE7A3", "#FF8FA3", angleDegrees: 35),
            .image(assetId: AnimatedPreviewDocuments.imageAssetID, contentMode: .fill)
        ]
        for background in backgrounds {
            #expect(background.isValid)
            let decoded = try JSONDecoder().decode(AnimatedBackground.self, from: Self.encoder.encode(background))
            #expect(decoded == background)
        }
    }

    @Test func shapeKindRoundTrips() throws {
        let kinds: [AnimatedShapeKind] = AnimatedShapeKind.presets + [
            .star(points: 9, innerRatio: 0.3),
            .polygon(sides: 12),
            .path(d: AnimatedPreviewSVG.boltPathData)
        ]
        for kind in kinds {
            #expect(kind.isValid)
            let decoded = try JSONDecoder().decode(AnimatedShapeKind.self, from: Self.encoder.encode(kind))
            #expect(decoded == kind)
        }
    }

    // MARK: - Timing helpers

    @Test func changingTimingRecompilesAgainstTheNewDuration() throws {
        let original = AnimatedPreviewDocuments.svgDrawOnSimple
        let stretched = try original.settingTiming(durationSeconds: 4, fps: 30, loop: .loop)
        try stretched.validated()
        // Specs are relative, so a longer document does not push a keyframe past its end.
        #expect(stretched.layers[0].animation.trim.allSatisfy { $0.timeSeconds <= 4 })
        #expect(stretched.renderedCycleDuration == 4)
    }

    @Test func settingAnimationsReplacesTheCompiledTrack() throws {
        let updated = try AnimatedPreviewDocuments.svgDrawOnSimple
            .settingAnimations([.fadeIn(duration: 0.5), .drawOn(delay: 0.5, duration: 1)], forLayer: "check")
        try updated.validated()
        #expect(updated.layers[0].animation.opacity.count == 2)
        #expect(updated.layers[0].animation.trim.count == 2)
    }
}
