import Foundation

/// A keyframe whose time and easing the editor may rewrite.
///
/// `AnimatedTimedKeyframe` exposes both read-only because the renderer never needs to move a
/// keyframe. Editing does, and doing it through one protocol is what keeps insert / retime / sort /
/// rescale as six one-line specialisations instead of six copies of the same algorithm.
protocol AnimatedEditableKeyframe: AnimatedTimedKeyframe {
    var timeSeconds: Double { get set }
    var easing: AnimatedEasing { get set }
}

extension PositionKeyframe: AnimatedEditableKeyframe {}
extension ScaleKeyframe: AnimatedEditableKeyframe {}
extension RotationKeyframe: AnimatedEditableKeyframe {}
extension OpacityKeyframe: AnimatedEditableKeyframe {}
extension EffectKeyframe: AnimatedEditableKeyframe {}
extension TrimKeyframe: AnimatedEditableKeyframe {}
extension WipeKeyframe: AnimatedEditableKeyframe {}
extension SheenKeyframe: AnimatedEditableKeyframe {}
extension GlowKeyframe: AnimatedEditableKeyframe {}

extension EffectKeyframe {
    /// This keyframe's three effect values as one bundle.
    ///
    /// The effects channel carries a triple where every other channel carries one or two scalars,
    /// so editing one component means rewriting the other two unchanged. `value` plus `with(…)`
    /// keeps that from being spelled out at every call site.
    public var value: AnimatedEffectValue {
        .init(blurRadius: blurRadius, hueDegrees: hueDegrees, saturation: saturation)
    }
}

extension WipeKeyframe {
    /// This keyframe's wipe values as one bundle, for the same reason `EffectKeyframe.value` exists:
    /// four components where editing one means rewriting the other three unchanged.
    public var value: AnimatedWipe {
        .init(start: start, end: end, angleDegrees: angleDegrees, softness: softness)
    }
}

extension AnimatedWipe {
    public func with(
        start: Double? = nil,
        end: Double? = nil,
        angleDegrees: Double? = nil,
        softness: Double? = nil
    ) -> Self {
        .init(
            start: start ?? self.start,
            end: end ?? self.end,
            angleDegrees: angleDegrees ?? self.angleDegrees,
            softness: softness ?? self.softness
        )
    }
}

extension SheenKeyframe {
    public var value: AnimatedSheen {
        .init(position: position, width: width, angleDegrees: angleDegrees, intensity: intensity)
    }
}

extension AnimatedSheen {
    public func with(
        position: Double? = nil,
        width: Double? = nil,
        angleDegrees: Double? = nil,
        intensity: Double? = nil
    ) -> Self {
        .init(
            position: position ?? self.position,
            width: width ?? self.width,
            angleDegrees: angleDegrees ?? self.angleDegrees,
            intensity: intensity ?? self.intensity
        )
    }
}

extension AnimatedEffectValue {
    public func with(blurRadius: Double? = nil, hueDegrees: Double? = nil, saturation: Double? = nil) -> Self {
        .init(
            blurRadius: blurRadius ?? self.blurRadius,
            hueDegrees: hueDegrees ?? self.hueDegrees,
            saturation: saturation ?? self.saturation
        )
    }
}

extension AnimatedLayerAnimation {
    // MARK: - Reading a channel

    public func count(of channel: AnimationChannel) -> Int {
        switch channel {
        case .position: position.count
        case .scale: scale.count
        case .rotation: rotation.count
        case .opacity: opacity.count
        case .effects: effects.count
        case .trim: trim.count
        case .wipe: wipe.count
        case .sheen: sheen.count
        case .glow: glow.count
        }
    }

    /// The keyframe times on a channel, in order. This is what the timeline draws.
    public func times(on channel: AnimationChannel) -> [Double] {
        switch channel {
        case .position: position.map(\.timeSeconds)
        case .scale: scale.map(\.timeSeconds)
        case .rotation: rotation.map(\.timeSeconds)
        case .opacity: opacity.map(\.timeSeconds)
        case .effects: effects.map(\.timeSeconds)
        case .trim: trim.map(\.timeSeconds)
        case .wipe: wipe.map(\.timeSeconds)
        case .sheen: sheen.map(\.timeSeconds)
        case .glow: glow.map(\.timeSeconds)
        }
    }

    public func easing(on channel: AnimationChannel, index: Int) -> AnimatedEasing? {
        switch channel {
        case .position: position.indices.contains(index) ? position[index].easing : nil
        case .scale: scale.indices.contains(index) ? scale[index].easing : nil
        case .rotation: rotation.indices.contains(index) ? rotation[index].easing : nil
        case .opacity: opacity.indices.contains(index) ? opacity[index].easing : nil
        case .effects: effects.indices.contains(index) ? effects[index].easing : nil
        case .trim: trim.indices.contains(index) ? trim[index].easing : nil
        case .wipe: wipe.indices.contains(index) ? wipe[index].easing : nil
        case .sheen: sheen.indices.contains(index) ? sheen[index].easing : nil
        case .glow: glow.indices.contains(index) ? glow[index].easing : nil
        }
    }

    /// The index of the keyframe nearest `time` on a channel, if one is within `tolerance`.
    public func keyframeIndex(on channel: AnimationChannel, near time: Double, tolerance: Double) -> Int? {
        let all = times(on: channel)
        guard let best = all.indices.min(by: { abs(all[$0] - time) < abs(all[$1] - time) }) else { return nil }
        return abs(all[best] - time) <= tolerance ? best : nil
    }

    // MARK: - Generic channel surgery

    /// Applies `body` to one channel's array, then re-establishes the channel's invariants.
    ///
    /// Every mutation funnels through here so the invariants cannot be forgotten at a call site:
    /// times are rounded the way the compiler rounds them, no two keyframes share a time, the array
    /// stays sorted, and the per-channel cap holds.
    private func editing<Frame: AnimatedEditableKeyframe>(
        _ keyPath: WritableKeyPath<Self, [Frame]>,
        _ channel: AnimationChannel,
        _ body: (inout [Frame]) throws -> Void
    ) throws -> Self {
        var result = self
        try body(&result[keyPath: keyPath])

        // Rounding happens *before* the duplicate check, because two times that differ only in the
        // fifth decimal round to the same stored value and would collide once written.
        for index in result[keyPath: keyPath].indices {
            result[keyPath: keyPath][index].timeSeconds =
                AnimationCompiler.roundTime(result[keyPath: keyPath][index].timeSeconds)
        }
        result[keyPath: keyPath].sort { $0.timeSeconds < $1.timeSeconds }

        guard result[keyPath: keyPath].count <= Self.maximumKeyframesPerChannel else {
            throw AnimatedEditorError.keyframeLimitReached(channel)
        }
        for pair in zip(result[keyPath: keyPath], result[keyPath: keyPath].dropFirst())
        where pair.0.timeSeconds == pair.1.timeSeconds {
            throw AnimatedEditorError.duplicateKeyframeTime(channel, pair.0.timeSeconds)
        }
        return result
    }

    private func keyPathEditing(
        _ channel: AnimationChannel,
        position editPosition: (inout [PositionKeyframe]) throws -> Void = { _ in },
        scale editScale: (inout [ScaleKeyframe]) throws -> Void = { _ in },
        rotation editRotation: (inout [RotationKeyframe]) throws -> Void = { _ in },
        opacity editOpacity: (inout [OpacityKeyframe]) throws -> Void = { _ in },
        effects editEffects: (inout [EffectKeyframe]) throws -> Void = { _ in },
        trim editTrim: (inout [TrimKeyframe]) throws -> Void = { _ in },
        wipe editWipe: (inout [WipeKeyframe]) throws -> Void = { _ in },
        sheen editSheen: (inout [SheenKeyframe]) throws -> Void = { _ in },
        glow editGlow: (inout [GlowKeyframe]) throws -> Void = { _ in }
    ) throws -> Self {
        switch channel {
        case .position: try editing(\.position, channel, editPosition)
        case .scale: try editing(\.scale, channel, editScale)
        case .rotation: try editing(\.rotation, channel, editRotation)
        case .opacity: try editing(\.opacity, channel, editOpacity)
        case .effects: try editing(\.effects, channel, editEffects)
        case .trim: try editing(\.trim, channel, editTrim)
        case .wipe: try editing(\.wipe, channel, editWipe)
        case .sheen: try editing(\.sheen, channel, editSheen)
        case .glow: try editing(\.glow, channel, editGlow)
        }
    }

    // MARK: - Inserting

    /// Adds a keyframe on `channel` at `time`, taking its value from `state`.
    ///
    /// Sampling the *interpolated* state rather than the layer's anchor is what makes "add a
    /// keyframe here" a non-destructive act: the new keyframe holds exactly the value the layer
    /// already had at that instant, so the artwork does not move until the user actually edits it.
    ///
    /// The default easing inherits from the segment being split, and that is load-bearing rather
    /// than cosmetic. Easing governs the segment *ending* at a keyframe, so a new keyframe dropped
    /// into the middle of a track redefines the curve leading up to it. Forcing a fixed easing would
    /// visibly re-shape motion the user did not touch; inheriting makes splitting a linear segment
    /// exactly inert, which is the case the "add a keyframe" button is really for.
    public func insertingKeyframe(
        on channel: AnimationChannel,
        atTime time: Double,
        sampledFrom state: AnimatedLayerState,
        easing: AnimatedEasing? = nil
    ) throws -> Self {
        let t = AnimationCompiler.roundTime(time)
        guard !times(on: channel).contains(t) else {
            throw AnimatedEditorError.duplicateKeyframeTime(channel, t)
        }
        let easing = easing ?? inheritedEasing(on: channel, at: t)
        return try keyPathEditing(
            channel,
            position: { $0.append(AnimationCompiler.position(t, state.position.x, state.position.y, easing)) },
            scale: { $0.append(AnimationCompiler.scale(t, state.scale.x, state.scale.y, easing)) },
            rotation: { $0.append(AnimationCompiler.rotation(t, state.rotationDegrees, easing)) },
            opacity: { $0.append(AnimationCompiler.opacity(t, state.opacity, easing)) },
            effects: {
                $0.append(AnimationCompiler.effect(
                    t,
                    blurRadius: state.effects.blurRadius,
                    hueDegrees: state.effects.hueDegrees,
                    saturation: state.effects.saturation,
                    easing
                ))
            },
            trim: { $0.append(AnimationCompiler.trim(t, state.trim.start, state.trim.end, easing)) },
            wipe: {
                $0.append(AnimationCompiler.wipe(
                    t, state.wipe.start, state.wipe.end, state.wipe.angleDegrees, state.wipe.softness, easing
                ))
            },
            sheen: {
                $0.append(AnimationCompiler.sheen(
                    t, state.sheen.position, state.sheen.width, state.sheen.angleDegrees, state.sheen.intensity, easing
                ))
            },
            glow: { $0.append(AnimationCompiler.glow(t, state.glow.amount, state.glow.radius, easing)) }
        )
    }

    /// The easing currently governing the segment that `time` falls inside.
    ///
    /// That is the easing of the first keyframe *after* `time`, since a keyframe owns the segment
    /// ending at it. Past the last keyframe — or on an empty channel — there is no segment to
    /// inherit from and the value would be unobservable anyway, so `.linear` is the honest answer.
    private func inheritedEasing(on channel: AnimationChannel, at time: Double) -> AnimatedEasing {
        let all = times(on: channel)
        guard let upper = all.firstIndex(where: { $0 > time }) else { return .linear }
        return easing(on: channel, index: upper) ?? .linear
    }

    // MARK: - Retiming, removing, easing

    /// Moves one keyframe to a new time, clamped into the document's timeline.
    ///
    /// Retiming past a neighbour is allowed and simply reorders the track — the shared `editing`
    /// helper re-sorts. Landing *exactly* on a neighbour is not, because two keyframes at the same
    /// instant have no defined blend.
    public func movingKeyframe(
        on channel: AnimationChannel,
        index: Int,
        toTime time: Double,
        clampedTo duration: Double
    ) throws -> Self {
        guard index >= 0, index < count(of: channel) else {
            throw AnimatedEditorError.keyframeIndexOutOfRange(channel, index)
        }
        let clamped = Swift.min(Swift.max(time, 0), Swift.max(duration, 0))
        return try keyPathEditing(
            channel,
            position: { $0[index].timeSeconds = clamped },
            scale: { $0[index].timeSeconds = clamped },
            rotation: { $0[index].timeSeconds = clamped },
            opacity: { $0[index].timeSeconds = clamped },
            effects: { $0[index].timeSeconds = clamped },
            trim: { $0[index].timeSeconds = clamped },
            wipe: { $0[index].timeSeconds = clamped },
            sheen: { $0[index].timeSeconds = clamped },
            glow: { $0[index].timeSeconds = clamped }
        )
    }

    public func removingKeyframe(on channel: AnimationChannel, index: Int) throws -> Self {
        guard index >= 0, index < count(of: channel) else {
            throw AnimatedEditorError.keyframeIndexOutOfRange(channel, index)
        }
        return try keyPathEditing(
            channel,
            position: { $0.remove(at: index) },
            scale: { $0.remove(at: index) },
            rotation: { $0.remove(at: index) },
            opacity: { $0.remove(at: index) },
            effects: { $0.remove(at: index) },
            trim: { $0.remove(at: index) },
            wipe: { $0.remove(at: index) },
            sheen: { $0.remove(at: index) },
            glow: { $0.remove(at: index) }
        )
    }

    /// Sets the easing of the segment *ending* at this keyframe.
    ///
    /// On index 0 this is inert: the interpolator reads easing from the upper keyframe of the pair
    /// it is blending, so the first keyframe of a channel has no incoming segment. The value is
    /// still stored — refusing it would be surprising, and it becomes meaningful the moment another
    /// keyframe is inserted before it — but the inspector disables the control and says why.
    public func settingEasing(_ easing: AnimatedEasing, on channel: AnimationChannel, index: Int) throws -> Self {
        guard index >= 0, index < count(of: channel) else {
            throw AnimatedEditorError.keyframeIndexOutOfRange(channel, index)
        }
        return try keyPathEditing(
            channel,
            position: { $0[index].easing = easing },
            scale: { $0[index].easing = easing },
            rotation: { $0[index].easing = easing },
            opacity: { $0[index].easing = easing },
            effects: { $0[index].easing = easing },
            trim: { $0[index].easing = easing },
            wipe: { $0[index].easing = easing },
            sheen: { $0[index].easing = easing },
            glow: { $0[index].easing = easing }
        )
    }

    // MARK: - Typed value setters
    //
    // Separate per channel rather than one `set(value:)` because the six channels genuinely carry
    // different payloads, and a stringly-typed union would only move the switch to the call site.
    // Each rebuilds the keyframe through the compiler's constructors so a hand-edited value is
    // clamped and rounded exactly like a compiled one.

    public func settingPosition(_ value: AnimatedPoint, index: Int) throws -> Self {
        try requireIndex(index, on: .position)
        return try editing(\.position, .position) {
            $0[index] = AnimationCompiler.position($0[index].timeSeconds, value.x, value.y, $0[index].easing)
        }
    }

    public func settingScale(_ value: AnimatedPoint, index: Int) throws -> Self {
        try requireIndex(index, on: .scale)
        return try editing(\.scale, .scale) {
            $0[index] = AnimationCompiler.scale($0[index].timeSeconds, value.x, value.y, $0[index].easing)
        }
    }

    public func settingRotation(_ degrees: Double, index: Int) throws -> Self {
        try requireIndex(index, on: .rotation)
        return try editing(\.rotation, .rotation) {
            $0[index] = AnimationCompiler.rotation($0[index].timeSeconds, degrees, $0[index].easing)
        }
    }

    public func settingOpacity(_ value: Double, index: Int) throws -> Self {
        try requireIndex(index, on: .opacity)
        return try editing(\.opacity, .opacity) {
            $0[index] = AnimationCompiler.opacity($0[index].timeSeconds, value, $0[index].easing)
        }
    }

    public func settingEffects(_ value: AnimatedEffectValue, index: Int) throws -> Self {
        try requireIndex(index, on: .effects)
        return try editing(\.effects, .effects) {
            $0[index] = AnimationCompiler.effect(
                $0[index].timeSeconds,
                blurRadius: value.blurRadius,
                hueDegrees: value.hueDegrees,
                saturation: value.saturation,
                $0[index].easing
            )
        }
    }

    public func settingTrim(_ value: AnimatedTrim, index: Int) throws -> Self {
        try requireIndex(index, on: .trim)
        return try editing(\.trim, .trim) {
            $0[index] = AnimationCompiler.trim($0[index].timeSeconds, value.start, value.end, $0[index].easing)
        }
    }

    public func settingWipe(_ value: AnimatedWipe, index: Int) throws -> Self {
        try requireIndex(index, on: .wipe)
        return try editing(\.wipe, .wipe) {
            $0[index] = AnimationCompiler.wipe(
                $0[index].timeSeconds,
                value.start,
                value.end,
                value.angleDegrees,
                value.softness,
                $0[index].easing
            )
        }
    }

    public func settingSheen(_ value: AnimatedSheen, index: Int) throws -> Self {
        try requireIndex(index, on: .sheen)
        return try editing(\.sheen, .sheen) {
            $0[index] = AnimationCompiler.sheen(
                $0[index].timeSeconds,
                value.position,
                value.width,
                value.angleDegrees,
                value.intensity,
                $0[index].easing
            )
        }
    }

    public func settingGlow(_ value: AnimatedGlow, index: Int) throws -> Self {
        try requireIndex(index, on: .glow)
        return try editing(\.glow, .glow) {
            $0[index] = AnimationCompiler.glow($0[index].timeSeconds, value.amount, value.radius, $0[index].easing)
        }
    }

    private func requireIndex(_ index: Int, on channel: AnimationChannel) throws {
        guard index >= 0, index < count(of: channel) else {
            throw AnimatedEditorError.keyframeIndexOutOfRange(channel, index)
        }
    }

    // MARK: - Whole-track time changes

    /// Scales every keyframe time by a constant.
    ///
    /// This is how a hand-authored layer survives a duration change. Compiled keyframe times are
    /// absolute, so shortening a document would otherwise leave keyframes beyond the new end and
    /// fail validation; rescaling preserves the motion's shape, which is what recompiling does for
    /// a declarative layer.
    public func rescalingTimes(by factor: Double) -> Self {
        guard factor > 0, factor.isFinite, factor != 1 else { return self }
        return transformingEveryChannel(MapTimes { AnimationCompiler.roundTime($0 * factor) })
            .deduplicatingTimes()
    }

    /// Pulls every keyframe time inside `0...duration`.
    ///
    /// The alternative to rescaling when a document is shortened. It flattens whatever ran past the
    /// new end onto the final instant, which is lossy — several keyframes can collapse onto one
    /// time — so `deduplicatingTimes` nudges the survivors apart rather than letting the channel
    /// end up with a collision the interpolator cannot resolve.
    public func clampingTimes(to duration: Double) -> Self {
        let limit = Swift.max(duration, 0)
        return transformingEveryChannel(MapTimes { Swift.min($0, limit) }).deduplicatingTimes()
    }

    /// Drops keyframes that collided onto an identical time after a whole-track time change.
    ///
    /// Deletion rather than nudging: a nudge would invent a time the user never authored and could
    /// itself collide, whereas two keyframes at one instant carry no information the first does not
    /// already carry. The earliest one wins because tracks are sorted ascending.
    private func deduplicatingTimes() -> Self {
        transformingEveryChannel(Deduplicate())
    }
}

// MARK: - Whole-animation transforms

/// A transform applied uniformly to every channel, whatever its keyframe type.
///
/// A protocol rather than a plain closure because the nine channels hold nine different element
/// types and Swift closures cannot be generic. This exists so `transformingEveryChannel` is the
/// *single* place that enumerates the channels: retiming, clamping and de-duplicating used to keep
/// three separate hand-written lists, and a channel added later only had to be forgotten in one of
/// them to produce keyframes stranded past the end of a shortened document.
private protocol AnimatedChannelTransform {
    func apply<Frame: AnimatedEditableKeyframe>(_ frames: [Frame]) -> [Frame]
}

private struct MapTimes: AnimatedChannelTransform {
    let transform: (Double) -> Double

    init(_ transform: @escaping (Double) -> Double) { self.transform = transform }

    func apply<Frame: AnimatedEditableKeyframe>(_ frames: [Frame]) -> [Frame] {
        frames.map { frame in
            var copy = frame
            copy.timeSeconds = transform(frame.timeSeconds)
            return copy
        }
    }
}

/// Drops keyframes that collided onto an identical time after a whole-track time change.
///
/// Deletion rather than nudging: a nudge would invent a time the user never authored and could
/// itself collide, whereas two keyframes at one instant carry no information the first does not
/// already carry. The earliest one wins because tracks are sorted ascending.
private struct Deduplicate: AnimatedChannelTransform {
    func apply<Frame: AnimatedEditableKeyframe>(_ frames: [Frame]) -> [Frame] {
        var seen = Set<Double>()
        return frames.sorted { $0.timeSeconds < $1.timeSeconds }.filter { seen.insert($0.timeSeconds).inserted }
    }
}

extension AnimatedLayerAnimation {
    /// The one place that touches all nine channels. `ChannelCoverageTests` walks
    /// `AnimationChannel.allCases` and fails if a channel is ever missing from this list.
    fileprivate func transformingEveryChannel(_ transform: some AnimatedChannelTransform) -> Self {
        var result = self
        result.position = transform.apply(result.position)
        result.scale = transform.apply(result.scale)
        result.rotation = transform.apply(result.rotation)
        result.opacity = transform.apply(result.opacity)
        result.effects = transform.apply(result.effects)
        result.trim = transform.apply(result.trim)
        result.wipe = transform.apply(result.wipe)
        result.sheen = transform.apply(result.sheen)
        result.glow = transform.apply(result.glow)
        return result
    }
}
