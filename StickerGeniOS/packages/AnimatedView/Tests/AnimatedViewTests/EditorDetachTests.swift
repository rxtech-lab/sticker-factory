import Foundation
import Testing
@testable import AnimatedView

/// The boundary between declarative motion and hand-authored keyframes.
///
/// A layer stores its motion twice — as `animations` (specs) and as `animation` (their compiled
/// output) — and the server rejects any document where the two disagree, byte-comparing a fresh
/// recompilation against what was stored. Everything here exists to make that state unreachable
/// from the editor rather than merely unlikely.
struct EditorDetachTests {
    /// A layer whose motion is genuinely declarative, compiled the same way the server would.
    ///
    /// The two specs deliberately drive *different* channels — `fadeIn` writes opacity, `spin`
    /// writes rotation. The compiler rejects two specs that overlap on one channel, since there is
    /// no sensible blend of them, so a fixture that tripped that would be testing the wrong thing.
    private func declarativeDocument(
        _ specs: [AnimationSpec] = [.fadeIn(duration: 0.5), .spin(turns: 1, delay: 0.5, duration: 1)],
        duration: Double = 2
    ) throws -> AnimatedDocument {
        let layer = AnimatedLayer.shape(.init(
            base: .init(id: "hero", name: "Hero", animations: specs),
            shape: .circle,
            fill: .solid("#7C5CFF")
        ))
        return try AnimatedDocument(kind: .animated, durationSeconds: duration, layers: [layer]).compiled()
    }

    private func handAuthoredDocument(_ animation: AnimatedLayerAnimation, duration: Double = 2) -> AnimatedDocument {
        let layer = AnimatedLayer.shape(.init(
            base: .init(id: "hero", name: "Hero", animation: animation),
            shape: .circle,
            fill: .solid("#7C5CFF")
        ))
        return .init(kind: .animated, durationSeconds: duration, layers: [layer])
    }

    // MARK: - The invariant itself

    /// The exact check `lib/contracts/sticker.ts` performs. If this ever fails for a document the
    /// editor produced, the server would reject that document on save.
    private func expectAgreesWithItsOwnRecompilation(
        _ document: AnimatedDocument,
        _ comment: Comment? = nil,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        let recompiled = try document.compiled()
        #expect(recompiled == document, comment ?? "document no longer equals its own recompilation", sourceLocation: sourceLocation)
    }

    @Test func aFreshlyCompiledDocumentAgreesWithItself() throws {
        try expectAgreesWithItsOwnRecompilation(try declarativeDocument())
    }

    @Test(arguments: AnimatedPreviewDocuments.all.map(\.document))
    func everyPreviewFixtureAgreesWithItsOwnRecompilation(document: AnimatedDocument) throws {
        try expectAgreesWithItsOwnRecompilation(document)
    }

    // MARK: - Detaching

    @Test func detachingClearsTheSpecsAndLeavesTheKeyframesBitIdentical() throws {
        let document = try declarativeDocument()
        let before = document.layers[0].animation
        #expect(!before.isEmpty, "the fixture must actually have compiled to something")

        let detached = try document.detachingAnimations(forLayer: "hero")
        #expect(detached.layers[0].animations.isEmpty)
        #expect(detached.layers[0].animation == before, "detaching must not touch the keyframes")
    }

    /// With no specs left, `compiled()` has nothing to recompile, so the keyframes it left behind
    /// are permanently safe — which is what makes detaching legal rather than a loophole.
    @Test func aDetachedDocumentStillValidatesAndIsANoOpToRecompile() throws {
        let detached = try declarativeDocument().detachingAnimations(forLayer: "hero")
        #expect(try detached.validated().layers.count == 1)
        try expectAgreesWithItsOwnRecompilation(detached)
        #expect(detached.editorIssues.filter { $0.severity == .blocking }.isEmpty)
    }

    @Test func detachingIsIdempotent() throws {
        let once = try declarativeDocument().detachingAnimations(forLayer: "hero")
        let twice = try once.detachingAnimations(forLayer: "hero")
        #expect(once == twice)
    }

    @Test func detachingAnUnknownLayerThrows() throws {
        let document = try declarativeDocument()
        #expect(throws: AnimatedEditorError.layerNotFound("ghost")) {
            try document.detachingAnimations(forLayer: "ghost")
        }
    }

    // MARK: - Raw keyframe edits are gated

    @Test func rawKeyframeEditsAreRefusedOnADeclarativeLayer() throws {
        let document = try declarativeDocument()
        #expect(document.layerIsDeclarative("hero"))
        #expect(throws: AnimatedEditorError.layerIsDeclarative("hero")) {
            try document.settingAnimation(.empty, forLayer: "hero")
        }
    }

    /// Canvas gestures are a different question from timeline edits. Dragging a declarative layer
    /// writes the *anchor* and recompiles, which keeps both representations in agreement — and is a
    /// genuinely useful edit: laying out a layer whose motion happens to be a preset. Forcing a
    /// detach just to move something would be gratuitous.
    @Test func canvasGesturesAreAllowedOnADeclarativeLayerAndKeepItInAgreement() throws {
        let document = try declarativeDocument()

        let moved = try document.applyingPosition(AnimatedPoint(x: 0.2, y: 0.2), toLayer: "hero", atDocumentTime: 1)
        #expect(moved.layers[0].anchor.position == AnimatedPoint(x: 0.2, y: 0.2))
        #expect(!moved.layers[0].animations.isEmpty, "the specs survive")
        try expectAgreesWithItsOwnRecompilation(moved)

        // Even on a channel the specs actively drive: the anchor is the resting value the compiler
        // departs from, so re-deriving picks the change up.
        let faded = try document.applyingOpacity(0.5, toLayer: "hero", atDocumentTime: 1)
        #expect(faded.layers[0].anchor.opacity == 0.5)
        try expectAgreesWithItsOwnRecompilation(faded)
    }

    /// The anchor has no effects field, so on a declarative layer there is nowhere to put a blur:
    /// the keyframes are derived and off-limits, and the anchor cannot express it.
    @Test func effectsAreTheOneCanvasEditADeclarativeLayerCannotAccept() throws {
        let document = try declarativeDocument()
        #expect(throws: AnimatedEditorError.layerIsDeclarative("hero")) {
            try document.applyingEffects(AnimatedEffectValue(blurRadius: 4), toLayer: "hero", atDocumentTime: 1)
        }
    }

    /// The timeline asks the stricter question, and gets the stricter answer.
    @Test func theTimelineStillTreatsADeclarativeLayerAsOffLimits() throws {
        let document = try declarativeDocument()
        for channel in AnimationChannel.allCases {
            #expect(
                AnimatedEditTargetResolver.target(channel: channel, layer: document.layers[0], atDocumentTime: 1)
                    == .blockedByDeclarative
            )
        }
    }

    @Test func theSameEditSucceedsAfterDetaching() throws {
        let detached = try declarativeDocument().detachingAnimations(forLayer: "hero")
        #expect(!detached.layerIsDeclarative("hero"))

        let edited = try detached.applyingOpacity(0.25, toLayer: "hero", atDocumentTime: 1)
        #expect(try edited.validated().layers.count == 1)
        let state = AnimationInterpolator.state(for: edited.layers[0], atDocumentTime: 1)
        #expect(abs(state.opacity - 0.25) < 1e-6)
    }

    // MARK: - Anchor edits do not need detaching

    /// The anchor is compiler *input*, so writing it on a declarative layer must recompile. Without
    /// that the stored keyframes would still describe the old resting state and the document would
    /// fail the server's agreement check.
    @Test func settingAnAnchorOnADeclarativeLayerRecompilesAndStaysInAgreement() throws {
        let document = try declarativeDocument()
        var anchor = AnimatedAnchor.default
        anchor.position = AnimatedPoint(x: 0.3, y: 0.7)
        anchor.scale = AnimatedPoint(x: 1.4, y: 1.4)

        let moved = try document.settingAnchor(anchor, forLayer: "hero")
        #expect(moved.layers[0].anchor == anchor)
        #expect(!moved.layers[0].animations.isEmpty, "the specs survive an anchor edit")
        #expect(moved.layers[0].animation != document.layers[0].animation, "the keyframes were re-derived")
        try expectAgreesWithItsOwnRecompilation(moved)
        #expect(try moved.validated().layers.count == 1)
    }

    /// The rule the whole canvas UI is built on: once a channel has keyframes, its anchor is dead
    /// and editing it changes nothing at any point on the timeline.
    @Test func anAnchorIsInertOnceItsChannelHasKeyframes() throws {
        let document = handAuthoredDocument(.init(opacity: [
            .init(timeSeconds: 0, value: 0.2),
            .init(timeSeconds: 2, value: 0.9),
        ]))
        var anchor = AnimatedAnchor.default
        anchor.opacity = 0.05
        let edited = try document.settingAnchor(anchor, forLayer: "hero")

        for time in stride(from: 0.0, through: 2.0, by: 0.25) {
            let before = AnimationInterpolator.state(for: document.layers[0], atDocumentTime: time)
            let after = AnimationInterpolator.state(for: edited.layers[0], atDocumentTime: time)
            #expect(before.opacity == after.opacity, "the anchor moved the render at t=\(time)")
        }
        // A channel with *no* keyframes is still live, which is why the resolver has to ask per
        // channel rather than per layer.
        #expect(edited.layers[0].anchor.opacity == 0.05)
    }

    // MARK: - Target resolution

    @Test func theResolverReportsAnchorForAnEmptyChannel() throws {
        let document = handAuthoredDocument(.empty)
        let target = AnimatedEditTargetResolver.target(channel: .position, layer: document.layers[0], atDocumentTime: 1)
        #expect(target == .anchor)
    }

    @Test func theResolverSnapsToAKeyframeUnderThePlayhead() throws {
        let document = handAuthoredDocument(.init(position: [
            .init(timeSeconds: 0, x: 0.5, y: 0.5),
            .init(timeSeconds: 1, x: 0.2, y: 0.2),
        ]))
        let layer = document.layers[0]
        #expect(AnimatedEditTargetResolver.target(channel: .position, layer: layer, atDocumentTime: 1) == .keyframe(index: 1))
        // Just inside the tolerance still counts as standing on it.
        #expect(AnimatedEditTargetResolver.target(channel: .position, layer: layer, atDocumentTime: 1.015) == .keyframe(index: 1))
    }

    @Test func theResolverProposesANewKeyframeAwayFromExistingOnes() throws {
        let document = handAuthoredDocument(.init(position: [
            .init(timeSeconds: 0, x: 0.5, y: 0.5),
            .init(timeSeconds: 2, x: 0.2, y: 0.2),
        ]))
        let target = AnimatedEditTargetResolver.target(channel: .position, layer: document.layers[0], atDocumentTime: 1)
        #expect(target == .newKeyframe(atTime: 1))
    }

    @Test func theResolverBlocksADeclarativeLayerOnEveryChannel() throws {
        let document = try declarativeDocument()
        for channel in AnimationChannel.allCases {
            #expect(
                AnimatedEditTargetResolver.target(channel: channel, layer: document.layers[0], atDocumentTime: 1)
                    == .blockedByDeclarative,
                "\(channel.rawValue) was not blocked"
            )
        }
    }

    // MARK: - Writing through the resolver

    @Test func draggingOnAnUnanimatedChannelMovesTheAnchor() throws {
        let document = handAuthoredDocument(.empty)
        let moved = try document.applyingPosition(AnimatedPoint(x: 0.2, y: 0.8), toLayer: "hero", atDocumentTime: 1)
        #expect(moved.layers[0].anchor.position == AnimatedPoint(x: 0.2, y: 0.8))
        #expect(moved.layers[0].animation.count(of: .position) == 0, "no keyframe should have been invented")
    }

    @Test func draggingOnAKeyframeEditsThatKeyframeInPlace() throws {
        let document = handAuthoredDocument(.init(position: [
            .init(timeSeconds: 0, x: 0.5, y: 0.5),
            .init(timeSeconds: 1, x: 0.2, y: 0.2),
        ]))
        let moved = try document.applyingPosition(AnimatedPoint(x: 0.9, y: 0.1), toLayer: "hero", atDocumentTime: 1)
        #expect(moved.layers[0].animation.count(of: .position) == 2, "no keyframe was added")
        #expect(moved.layers[0].animation.position[1].x == 0.9)
        #expect(moved.layers[0].animation.position[0].x == 0.5, "the other keyframe is untouched")
    }

    /// Dragging between keyframes adds one at the playhead rather than dragging the whole track —
    /// which is what makes the canvas usable for building motion, not just for adjusting it.
    @Test func draggingBetweenKeyframesInsertsOneAtThePlayhead() throws {
        let document = handAuthoredDocument(.init(position: [
            .init(timeSeconds: 0, x: 0.5, y: 0.5),
            .init(timeSeconds: 2, x: 0.5, y: 0.5),
        ]))
        let moved = try document.applyingPosition(AnimatedPoint(x: 0.1, y: 0.9), toLayer: "hero", atDocumentTime: 1)
        let track = moved.layers[0].animation
        #expect(track.count(of: .position) == 3)
        #expect(track.times(on: .position) == [0, 1, 2])
        #expect(track.position[1].x == 0.1)
        // The endpoints are exactly as they were.
        #expect(track.position[0].x == 0.5)
        #expect(track.position[2].x == 0.5)
        #expect(try moved.validated().layers.count == 1)
    }

    /// The anchor has no effects field, so an effect edit must create a keyframe rather than
    /// silently doing nothing.
    @Test func settingAnEffectOnAnEmptyChannelCreatesAKeyframe() throws {
        let document = handAuthoredDocument(.empty)
        #expect(!AnimationChannel.effects.hasAnchorValue)

        let blurred = try document.applyingEffects(
            AnimatedEffectValue(blurRadius: 6), toLayer: "hero", atDocumentTime: 1
        )
        #expect(blurred.layers[0].animation.count(of: .effects) == 1)
        #expect(blurred.layers[0].animation.effects[0].blurRadius == 6)
        #expect(try blurred.validated().layers.count == 1)
    }

    // MARK: - Kind switching

    @Test func convertingToStaticBakesTheStateAtTheScrubbedInstant() throws {
        let document = handAuthoredDocument(.init(
            position: [.init(timeSeconds: 0, x: 0.5, y: 0.5), .init(timeSeconds: 2, x: 0.1, y: 0.9)],
            opacity: [.init(timeSeconds: 0, value: 0), .init(timeSeconds: 2, value: 1)]
        ))
        let atEnd = try document.settingKind(.static, bakingAtDocumentTime: 2)

        #expect(atEnd.kind == .static)
        #expect(atEnd.durationSeconds == 0)
        #expect(atEnd.fps == 0)
        #expect(atEnd.loop == .once)
        #expect(atEnd.layers[0].animation.isEmpty, "a static document has no timeline")
        #expect(atEnd.layers[0].anchor.position == AnimatedPoint(x: 0.1, y: 0.9))
        #expect(atEnd.layers[0].anchor.opacity == 1)
        #expect(try atEnd.validated().kind == .static)
    }

    /// Documented loss: the anchor cannot carry blur, hue, or saturation, so those are dropped.
    @Test func convertingToStaticDropsEffects() throws {
        let document = handAuthoredDocument(.init(effects: [
            .init(timeSeconds: 0, blurRadius: 10),
            .init(timeSeconds: 2, blurRadius: 10),
        ]))
        let flattened = try document.settingKind(.static, bakingAtDocumentTime: 1)
        #expect(flattened.layers[0].animation.effects.isEmpty)
        #expect(try flattened.validated().kind == .static)
    }

    @Test func convertingADeclarativeDocumentToStaticAlsoDropsItsSpecs() throws {
        let flattened = try declarativeDocument().settingKind(.static, bakingAtDocumentTime: 2)
        #expect(flattened.layers[0].animations.isEmpty)
        #expect(flattened.layers[0].animation.isEmpty)
        try expectAgreesWithItsOwnRecompilation(flattened)
        #expect(try flattened.validated().kind == .static)
    }

    @Test func convertingBackToAnimatedRestoresAUsableTimeline() throws {
        let flattened = try handAuthoredDocument(.empty).settingKind(.static)
        let animated = try flattened.settingKind(.animated)
        #expect(animated.kind == .animated)
        #expect(AnimatedDocument.durationRange.contains(animated.durationSeconds))
        #expect(AnimatedDocument.fpsRange.contains(animated.fps))
        #expect(try animated.validated().kind == .animated)
    }
}
