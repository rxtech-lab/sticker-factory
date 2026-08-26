import Foundation

/// What a canvas gesture will actually write to.
///
/// This exists because of one fact about the interpolator that is invisible in the UI: a channel
/// with any keyframes at all *clamps* outside the first and last of them, so its anchor value can
/// never be observed again. Editing the anchor of an animated channel therefore does nothing, at
/// any point on the timeline — the layer simply refuses to move and the drag reads as broken.
///
/// So a gesture cannot just write the anchor. It has to ask, per channel and per instant, whether
/// the anchor is still live, whether it is standing on an existing keyframe, or whether it needs to
/// create one. Resolving that up front also gives the overlay something honest to display, which is
/// the difference between a drag that feels precise and one that feels arbitrary.
public enum AnimatedEditTarget: Equatable, Sendable {
    /// The channel has no keyframes, so the anchor is what the renderer reads.
    case anchor
    /// The playhead is sitting on an existing keyframe; the gesture edits it in place.
    case keyframe(index: Int)
    /// The channel is animated but nothing is near the playhead, so the gesture adds a keyframe.
    case newKeyframe(atTime: Double)
    /// The layer's motion is generated from declarative specs and cannot be hand-edited until it
    /// is detached.
    case blockedByDeclarative

    /// Whether acting on this target would change the document at all.
    public var isEditable: Bool { self != .blockedByDeclarative }
}

public enum AnimatedEditTargetResolver {
    /// How close the playhead has to be to a keyframe to count as standing on it.
    ///
    /// Generous enough that scrubbing to a keyframe by hand lands on it — at 30 fps a single frame
    /// is 33 ms, so this is under a frame and cannot accidentally capture a neighbour.
    public static let snapToleranceSeconds = 0.02

    /// What the **timeline** can do to a channel: edit a keyframe, add one, or write the anchor.
    ///
    /// Declarative layers are blocked outright here, because their keyframes are derived and any
    /// direct edit would put the document out of agreement with its own specs.
    public static func target(
        channel: AnimationChannel,
        layer: AnimatedLayer,
        atDocumentTime time: Double
    ) -> AnimatedEditTarget {
        guard layer.animations.isEmpty else { return .blockedByDeclarative }
        let animation = layer.animation
        guard animation.count(of: channel) > 0 else { return .anchor }
        if let index = animation.keyframeIndex(on: channel, near: time, tolerance: snapToleranceSeconds) {
            return .keyframe(index: index)
        }
        return .newKeyframe(atTime: AnimationCompiler.roundTime(time))
    }

    /// What a **canvas gesture** does to a channel, which is not the same question.
    ///
    /// A declarative layer can still be dragged, pinched, and rotated: those write the anchor, and
    /// `settingAnchor` recompiles the specs against it, so the two representations stay in
    /// agreement. That is a genuinely useful edit — laying out a layer whose *motion* is a preset —
    /// and blocking it would force a pointless detach just to move something.
    ///
    /// The exception is `effects`, which the anchor cannot express at all. Blur, hue, and
    /// saturation exist only as keyframes, so on a declarative layer there is nowhere to put them.
    public static func canvasTarget(
        channel: AnimationChannel,
        layer: AnimatedLayer,
        atDocumentTime time: Double
    ) -> AnimatedEditTarget {
        guard layer.animations.isEmpty else {
            return channel.hasAnchorValue ? .anchor : .blockedByDeclarative
        }
        return target(channel: channel, layer: layer, atDocumentTime: time)
    }

    /// A short caption naming what the next gesture will touch.
    ///
    /// Shown under the selection outline. Without it the same drag produces three different
    /// outcomes for reasons the user has no way to see.
    public static func caption(for target: AnimatedEditTarget, channel: AnimationChannel, total: Int) -> String {
        switch target {
        case .anchor:
            "Editing \(channel.rawValue)"
        case .keyframe(let index):
            "Editing \(channel.rawValue) keyframe \(index + 1) of \(total)"
        case .newKeyframe(let time):
            "Adds a \(channel.rawValue) keyframe at \(String(format: "%.2f", time)) s"
        case .blockedByDeclarative:
            "Preset motion — convert to keyframes to edit"
        }
    }
}

extension AnimatedDocument {
    /// Writes a channel value for a layer at an instant, choosing anchor or keyframe automatically.
    ///
    /// Every canvas gesture funnels through one of the five wrappers below, so the anchor-is-dead
    /// rule is enforced in exactly one place rather than re-derived by each gesture handler.
    /// `updateAnchor` is `nil` for channels the anchor cannot express — only `effects`. Those fall
    /// through to creating a keyframe instead, because the alternative is a control that silently
    /// does nothing until the user happens to have added a keyframe first.
    private func applying(
        channel: AnimationChannel,
        toLayer id: String,
        atDocumentTime time: Double,
        anchor updateAnchor: ((inout AnimatedAnchor) -> Void)?,
        keyframe updateKeyframe: (AnimatedLayerAnimation, Int) throws -> AnimatedLayerAnimation
    ) throws -> Self {
        guard let layer = layer(id: id) else { throw AnimatedEditorError.layerNotFound(id) }

        var resolved = AnimatedEditTargetResolver.canvasTarget(channel: channel, layer: layer, atDocumentTime: time)
        if case .anchor = resolved, updateAnchor == nil {
            resolved = .newKeyframe(atTime: AnimationCompiler.roundTime(time))
        }

        switch resolved {
        case .blockedByDeclarative:
            throw AnimatedEditorError.layerIsDeclarative(id)

        case .anchor:
            var anchor = layer.anchor
            updateAnchor?(&anchor)
            return try settingAnchor(anchor, forLayer: id)

        case .keyframe(let index):
            return try settingAnimation(try updateKeyframe(layer.animation, index), forLayer: id)

        case .newKeyframe(let time):
            // Seed the new keyframe with the value the layer already has at this instant, then
            // apply the gesture to it. Doing it in that order means the gesture's delta is measured
            // from what is on screen, not from whatever the previous keyframe happened to hold.
            let state = AnimationInterpolator.state(for: layer, atDocumentTime: time)
            let seeded = try layer.animation.insertingKeyframe(on: channel, atTime: time, sampledFrom: state)
            guard let index = seeded.keyframeIndex(on: channel, near: time, tolerance: 1e-6) else {
                throw AnimatedEditorError.keyframeIndexOutOfRange(channel, 0)
            }
            return try settingAnimation(try updateKeyframe(seeded, index), forLayer: id)
        }
    }

    public func applyingPosition(_ value: AnimatedPoint, toLayer id: String, atDocumentTime time: Double) throws -> Self {
        try applying(
            channel: .position,
            toLayer: id,
            atDocumentTime: time,
            anchor: { $0.position = value },
            keyframe: { try $0.settingPosition(value, index: $1) }
        )
    }

    public func applyingScale(_ value: AnimatedPoint, toLayer id: String, atDocumentTime time: Double) throws -> Self {
        try applying(
            channel: .scale,
            toLayer: id,
            atDocumentTime: time,
            anchor: { $0.scale = value },
            keyframe: { try $0.settingScale(value, index: $1) }
        )
    }

    /// Rotation is the one channel whose anchor and keyframe ranges differ.
    ///
    /// `AnimationCompiler.rotation` clamps its output to ±1080, so an anchor beyond that would make
    /// a declarative layer stop equalling its own recompilation. Keyframes are not compiler input
    /// and keep the model's wider ±3600, which is what lets a hand-authored spin exceed three turns.
    public func applyingRotation(_ degrees: Double, toLayer id: String, atDocumentTime time: Double) throws -> Self {
        try applying(
            channel: .rotation,
            toLayer: id,
            atDocumentTime: time,
            anchor: {
                $0.rotationDegrees = AnimatedCanvasGeometry.clamp(
                    degrees, to: AnimatedCanvasGeometry.anchorRotationRange
                )
            },
            keyframe: {
                try $0.settingRotation(
                    AnimatedCanvasGeometry.clamp(degrees, to: AnimatedCanvasGeometry.keyframeRotationRange),
                    index: $1
                )
            }
        )
    }

    public func applyingOpacity(_ value: Double, toLayer id: String, atDocumentTime time: Double) throws -> Self {
        try applying(
            channel: .opacity,
            toLayer: id,
            atDocumentTime: time,
            anchor: { $0.opacity = Swift.min(Swift.max(value, 0), 1) },
            keyframe: { try $0.settingOpacity(value, index: $1) }
        )
    }

    public func applyingTrim(_ value: AnimatedTrim, toLayer id: String, atDocumentTime time: Double) throws -> Self {
        try applying(
            channel: .trim,
            toLayer: id,
            atDocumentTime: time,
            anchor: { $0.trim = value },
            keyframe: { try $0.settingTrim(value, index: $1) }
        )
    }

    /// Blur, hue shift, and saturation have no anchor to write, so setting one always lands on a
    /// keyframe — created at the playhead if the channel is empty.
    public func applyingEffects(_ value: AnimatedEffectValue, toLayer id: String, atDocumentTime time: Double) throws -> Self {
        try applying(
            channel: .effects,
            toLayer: id,
            atDocumentTime: time,
            anchor: nil,
            keyframe: { try $0.settingEffects(value, index: $1) }
        )
    }
}

extension AnimationChannel {
    /// Whether `AnimatedAnchor` can hold a resting value for this channel.
    ///
    /// Only `effects` cannot: the anchor has no blur/hue/saturation fields, so an effect exists
    /// solely on the timeline. Two consequences the UI has to state out loud — an effect always
    /// creates a keyframe, and converting an animated sticker to a static one bakes position,
    /// scale, rotation, opacity, and trim into anchors while dropping the effects.
    public var hasAnchorValue: Bool { self != .effects }

    public var label: String {
        switch self {
        case .position: "Position"
        case .scale: "Scale"
        case .rotation: "Rotation"
        case .opacity: "Opacity"
        case .effects: "Effects"
        case .trim: "Trim"
        }
    }

    public var symbolName: String {
        switch self {
        case .position: "arrow.up.and.down.and.arrow.left.and.right"
        case .scale: "arrow.up.left.and.arrow.down.right"
        case .rotation: "rotate.right"
        case .opacity: "circle.lefthalf.filled"
        case .effects: "camera.filters"
        case .trim: "scissors"
        }
    }
}
