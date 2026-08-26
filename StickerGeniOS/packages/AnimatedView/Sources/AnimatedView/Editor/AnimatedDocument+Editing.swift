import Foundation

/// Document-level edits, as pure functions.
///
/// Naming follows `Engine/AnimatedDocument+Compile.swift` — `settingX`, `addingY` — and so does the
/// contract: every one returns a new document and never mutates in place. That is what lets
/// `AnimatedDocumentEditor` record an undo snapshot only after an edit has succeeded, and what
/// makes a failed edit a genuine no-op rather than a partially-applied one.
extension AnimatedDocument {
    // MARK: - Layer identity

    /// A layer id derived from `base` that no existing layer uses.
    ///
    /// Ids must match `^[A-Za-z0-9_-]{1,64}$` (`AnimatedLayerBase.isValid`), so anything else in the
    /// caller's suggestion is folded to `-` rather than rejected: this is called with human input
    /// like a duplicated layer's name.
    public func uniqueLayerID(preferring base: String) -> String {
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-")
        var seed = String(base.map { allowed.contains($0) ? $0 : "-" }.prefix(48))
        if seed.isEmpty { seed = "layer" }

        let taken = Set(layers.map(\.id))
        guard taken.contains(seed) else { return seed }
        // Start at 2 so the first duplicate of "star" is "star-2", not "star-1" — which would imply
        // the original had been renamed.
        for suffix in 2...(taken.count + 2) where !taken.contains("\(seed)-\(suffix)") {
            return "\(seed)-\(suffix)"
        }
        return "\(seed)-\(UUID().uuidString.prefix(8))"
    }

    private func requireIndex(ofLayer id: String) throws -> Int {
        guard let index = layers.firstIndex(where: { $0.id == id }) else {
            throw AnimatedEditorError.layerNotFound(id)
        }
        return index
    }

    // MARK: - Adding and removing layers

    /// Inserts a layer. `index` is a *model* index, where 0 is the bottom-most layer.
    public func addingLayer(_ layer: AnimatedLayer, at index: Int? = nil) throws -> Self {
        guard layers.count < Self.maximumLayerCount else { throw AnimatedEditorError.layerLimitReached }
        var result = self
        let target = Swift.min(Swift.max(index ?? layers.count, 0), layers.count)
        result.layers.insert(layer, at: target)
        return result
    }

    public func removingLayer(id: String) throws -> Self {
        let index = try requireIndex(ofLayer: id)
        var result = self
        result.layers.remove(at: index)
        return result
    }

    /// Copies a layer directly above the original, with a fresh id.
    ///
    /// The keyframes come along unchanged, which is the point: duplicating is how you build a
    /// second element that moves in step with the first and then diverges.
    public func duplicatingLayer(id: String) throws -> Self {
        let index = try requireIndex(ofLayer: id)
        guard layers.count < Self.maximumLayerCount else { throw AnimatedEditorError.layerLimitReached }
        guard totalKeyframeCount + layers[index].animation.keyframeCount <= Self.maximumKeyframeCount else {
            throw AnimatedEditorError.documentKeyframeLimitReached
        }
        var copy = layers[index]
        copy.base.id = uniqueLayerID(preferring: layers[index].id)
        copy.base.name = String("\(layers[index].name) copy".prefix(80))
        var result = self
        result.layers.insert(copy, at: index + 1)
        return result
    }

    /// Moves a layer to a new *model* index, changing paint order.
    public func movingLayer(id: String, toIndex index: Int) throws -> Self {
        let current = try requireIndex(ofLayer: id)
        var result = self
        let layer = result.layers.remove(at: current)
        result.layers.insert(layer, at: Swift.min(Swift.max(index, 0), result.layers.count))
        return result
    }

    // MARK: - Layer properties

    public func renamingLayer(id: String, to name: String) throws -> Self {
        try updatingLayer(id: id) { $0.base.name = String(name.prefix(80)) }
    }

    public func settingHidden(_ hidden: Bool, forLayer id: String) throws -> Self {
        try updatingLayer(id: id) { $0.base.hidden = hidden }
    }

    public func settingBlendMode(_ mode: AnimatedBlendMode, forLayer id: String) throws -> Self {
        try updatingLayer(id: id) { $0.base.blendMode = mode }
    }

    /// The escape hatch the per-type inspectors use to write their own fields.
    ///
    /// Deliberately does not recompile: none of the type-specific fields — text, paint, shape kind,
    /// SVG markup, particle count — is compiler input. Motion-bearing fields have their own
    /// functions below precisely because they are.
    public func updatingLayer(id: String, _ body: (inout AnimatedLayer) -> Void) throws -> Self {
        let index = try requireIndex(ofLayer: id)
        var result = self
        body(&result.layers[index])
        return result
    }

    /// Replaces a layer's resting state, recompiling if its motion is declarative.
    ///
    /// The recompile is not optional. The anchor is an *input* to `AnimationCompiler` — every spec
    /// departs from and returns to it — so on a layer with specs, writing the anchor alone leaves
    /// the stored keyframes describing the old resting state, and the document stops equalling its
    /// own recompilation. The server rejects exactly that.
    public func settingAnchor(_ anchor: AnimatedAnchor, forLayer id: String) throws -> Self {
        let index = try requireIndex(ofLayer: id)
        var result = self
        result.layers[index].base.anchor = anchor
        guard !result.layers[index].animations.isEmpty else { return result }
        do {
            return try result.compiled()
        } catch {
            throw AnimatedEditorError.compile(error.localizedDescription)
        }
    }

    /// Replaces a layer's compiled keyframes wholesale.
    ///
    /// Refuses on a declarative layer. This is the Swift counterpart of the server's
    /// `assertNotDeclarative`, and it is the single choke point every raw keyframe edit passes
    /// through — which is why the editor cannot produce a document the schema rejects.
    public func settingAnimation(_ animation: AnimatedLayerAnimation, forLayer id: String) throws -> Self {
        let index = try requireIndex(ofLayer: id)
        guard layers[index].animations.isEmpty else {
            throw AnimatedEditorError.layerIsDeclarative(id)
        }
        let delta = animation.keyframeCount - layers[index].animation.keyframeCount
        guard totalKeyframeCount + delta <= Self.maximumKeyframeCount else {
            throw AnimatedEditorError.documentKeyframeLimitReached
        }
        var result = self
        result.layers[index].base.animation = animation
        return result
    }

    /// Converts a layer's preset motion into plain, editable keyframes.
    ///
    /// Clearing `animations` while leaving `animation` untouched is legal by construction: the
    /// keyframes left behind *are* the compiled output of the specs that just went away, and with
    /// no specs left nothing will ever recompile over them.
    ///
    /// It is a one-way door. Duration changes can afterwards only rescale or clamp those keyframes,
    /// never re-derive them — which is exactly what specs exist to make possible. Undo is the only
    /// way back, so the UI confirms before calling this.
    public func detachingAnimations(forLayer id: String) throws -> Self {
        let index = try requireIndex(ofLayer: id)
        var result = self
        result.layers[index].base.animations = []
        return result
    }

    /// Whether a layer's motion is generated, and so off-limits to direct keyframe editing.
    public func layerIsDeclarative(_ id: String) -> Bool {
        layer(id: id).map { !$0.animations.isEmpty } ?? false
    }

    // MARK: - Document properties

    /// Resizes the canvas, clamping to the supported range.
    ///
    /// No layer moves: positions are normalized. But the per-layer fit box takes the canvas's
    /// aspect ratio, so a non-square canvas does stretch shape layers and thicken strokes. That is
    /// left visible rather than compensated for — silently rewriting every layer's scale to
    /// preserve appearance would be the bigger surprise.
    public func settingCanvas(_ canvas: AnimatedCanvas) -> Self {
        var result = self
        result.canvas = AnimatedCanvas(
            width: Swift.min(Swift.max(canvas.width, AnimatedCanvas.minimumDimension), AnimatedCanvas.maximumDimension),
            height: Swift.min(Swift.max(canvas.height, AnimatedCanvas.minimumDimension), AnimatedCanvas.maximumDimension),
            transparent: canvas.transparent
        )
        return result
    }

    /// Sets the playback multiplier.
    ///
    /// Never recompiles, by design: `speed` divides elapsed time on the way into the interpolator
    /// rather than touching keyframe times, so the same compiled document can play at any speed.
    public func settingSpeed(_ speed: Double) -> Self {
        var result = self
        result.speed = Swift.min(Swift.max(speed, Self.speedRange.lowerBound), Self.speedRange.upperBound)
        return result
    }

    public func settingBackground(_ background: AnimatedBackground, mp4: AnimatedBackground? = nil) -> Self {
        var result = self
        result.background = background
        if let mp4 { result.mp4Background = mp4 }
        return result
    }

    /// The shortest duration this document's declarative motion can fit in.
    ///
    /// `AnimationCompiler` refuses to compile a spec that ends past the document's duration, so
    /// this is the floor a duration slider must not go below. Surfacing it as a bound is better
    /// than catching the resulting error: the user never reaches an invalid state to be told about.
    public var minimumDurationForAnimations: Double {
        layers.flatMap(\.animations).map(\.endSeconds).max() ?? 0
    }

    /// The latest instant any hand-authored keyframe sits at.
    public var lastKeyframeTime: Double {
        layers.filter { $0.animations.isEmpty }.flatMap(\.animation.allKeyframes).map(\.timeSeconds).max() ?? 0
    }

    /// Changes the timeline, keeping every layer's motion inside it.
    ///
    /// The two representations need opposite treatment, which is the whole reason this is not just
    /// `settingTiming`:
    ///
    ///  - Declarative layers are re-derived. Specs are relative, so recompiling against the new
    ///    duration is lossless — that is `settingTiming`'s job and it already does it.
    ///  - Hand-authored layers cannot be re-derived. Their keyframe times are absolute, so
    ///    shortening a document would strand keyframes past the end and fail validation. They are
    ///    rescaled (preserving the shape of the motion, matching what recompiling does for a spec)
    ///    or clamped, at the caller's choice.
    public func settingDuration(
        _ seconds: Double,
        fps newFPS: Int? = nil,
        loop newLoop: AnimatedLoop? = nil,
        rescalingDetachedKeyframes: Bool = true
    ) throws -> Self {
        guard kind == .animated else { throw AnimatedEditorError.staticDocumentCannotAnimate }
        let floor = minimumDurationForAnimations
        guard seconds >= floor else { throw AnimatedEditorError.durationTooShortForAnimations(minimum: floor) }

        let clamped = Swift.min(Swift.max(seconds, Self.durationRange.lowerBound), Self.durationRange.upperBound)
        var result = self
        if durationSeconds > 0, clamped != durationSeconds {
            let factor = clamped / durationSeconds
            for index in result.layers.indices where result.layers[index].animations.isEmpty {
                result.layers[index].base.animation = rescalingDetachedKeyframes
                    ? result.layers[index].animation.rescalingTimes(by: factor)
                    : result.layers[index].animation.clampingTimes(to: clamped)
            }
        }
        do {
            return try result.settingTiming(
                durationSeconds: clamped,
                fps: Swift.min(Swift.max(newFPS ?? fps, Self.fpsRange.lowerBound), Self.fpsRange.upperBound),
                loop: newLoop ?? loop
            )
        } catch {
            throw AnimatedEditorError.compile(error.localizedDescription)
        }
    }

    /// Switches between a still image and an animation.
    ///
    /// Going to `.static` is destructive and cannot be otherwise: `validated()` requires zero
    /// duration and every keyframe at t=0, so the timeline has to be collapsed into the anchors.
    /// The state at `time` is baked in so the result looks like the frame the user was looking at,
    /// not like frame zero — but `AnimatedAnchor` has no effects field, so blur, hue shift, and
    /// saturation at that instant are lost. The caller confirms before invoking this.
    public func settingKind(_ newKind: AnimatedKind, bakingAtDocumentTime time: Double = 0) throws -> Self {
        guard newKind != kind else { return self }
        var result = self
        result.kind = newKind

        switch newKind {
        case .static:
            for index in result.layers.indices {
                let state = AnimationInterpolator.state(for: result.layers[index], atDocumentTime: time)
                result.layers[index].base.anchor = AnimatedAnchor(
                    position: state.position,
                    scale: state.scale,
                    rotationDegrees: AnimatedCanvasGeometry.clamp(
                        state.rotationDegrees, to: AnimatedCanvasGeometry.anchorRotationRange
                    ),
                    opacity: state.opacity,
                    trim: state.trim
                )
                result.layers[index].base.animations = []
                result.layers[index].base.animation = .empty
            }
            result.durationSeconds = 0
            result.fps = 0
            result.loop = .once
            result.speed = 1
        case .animated:
            result.durationSeconds = durationSeconds > 0 ? durationSeconds : 2
            result.fps = fps > 0 ? fps : 30
            result.loop = .loop
        }
        return result
    }
}
