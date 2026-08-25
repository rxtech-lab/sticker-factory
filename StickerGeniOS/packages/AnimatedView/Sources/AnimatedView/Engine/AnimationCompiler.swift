import Foundation

/// Timing context a layer's specs are compiled against.
public struct AnimationTiming: Hashable, Sendable {
    public var kind: AnimatedKind
    public var durationSeconds: Double

    public init(kind: AnimatedKind, durationSeconds: Double) {
        self.kind = kind
        self.durationSeconds = durationSeconds
    }

    public init(document: AnimatedDocument) {
        self.init(kind: document.kind, durationSeconds: document.durationSeconds)
    }
}

public struct AnimationCompileError: Error, Equatable, LocalizedError {
    public var message: String
    /// Set when the failure is a per-channel keyframe overflow. Only that failure can be resolved
    /// by retrying at a lower cycle cap, so the budget allocator keys off it rather than matching
    /// on the message text.
    public var isChannelOverflow: Bool

    public init(_ message: String, isChannelOverflow: Bool = false) {
        self.message = message
        self.isChannelOverflow = isChannelOverflow
    }

    public var errorDescription: String? { message }
}

/// Compiles declarative animation specs into the keyframe tracks the renderer actually plays.
///
/// Everything here is pure and deterministic — the same specs always produce byte-identical
/// keyframes — because a document stores both representations and the server asserts they agree. A
/// non-deterministic compiler would make that invariant unsatisfiable, which is also why this is a
/// line-for-line port of `server/lib/animation/compile.ts` rather than an independent
/// implementation: the two must never disagree, and `CompilerParityTests` proves they don't.
///
/// Two interpolator facts drive the design:
///
///  1. Easing is read from the *upper* keyframe of the pair being blended, so a segment's easing
///     belongs on its end keyframe, never its start.
///  2. A channel with no keyframes falls back to a default, and values clamp outside the first and
///     last keyframe. That is why an anchor equal to the default emits nothing, and why a delay
///     simply means "no keyframe before this time".
public enum AnimationCompiler {
    /// Document-wide keyframe ceiling, mirrored from `AnimatedDocument`.
    public static let maximumDocumentKeyframes = AnimatedDocument.maximumKeyframeCount
    /// Per-channel ceiling, mirrored from `AnimatedLayerAnimation`.
    public static let maximumChannelKeyframes = AnimatedLayerAnimation.maximumKeyframesPerChannel
    /// Samples per cycle for the sine-driven specs. Four gives zero/peak/zero/trough.
    static let samplesPerCycle = 4

    // MARK: - Rounding

    /// JavaScript's `Math.round`, which breaks ties toward positive infinity rather than away from
    /// zero the way Swift's `rounded()` does. `Math.round(-2.5)` is `-2`, `(-2.5).rounded()` is
    /// `-3`; a document compiled on the server would not deep-equal one compiled here without this.
    static func jsRound(_ value: Double) -> Double { (value + 0.5).rounded(.down) }

    /// Rounds to 4 decimal places and normalises negative zero to positive zero.
    ///
    /// Both halves matter. Rounding kills float drift; the `+ 0` kills `-0`, because `sin(2π)` is a
    /// tiny negative number that rounds to `-0` while `JSON.stringify` writes `-0` as `"0"` — a
    /// stored track would read back as `0` and never equal a freshly compiled `-0`.
    static func roundTime(_ value: Double) -> Double { jsRound(value * 10_000) / 10_000 + 0 }

    /// Rounds to 5 decimal places, same negative-zero normalisation.
    static func roundValue(_ value: Double) -> Double { jsRound(value * 100_000) / 100_000 + 0 }

    static func clamp(_ value: Double, _ minimum: Double, _ maximum: Double) -> Double {
        Swift.min(maximum, Swift.max(minimum, value))
    }

    // MARK: - Keyframe constructors

    static func position(_ t: Double, _ x: Double, _ y: Double, _ easing: AnimatedEasing) -> PositionKeyframe {
        .init(timeSeconds: roundTime(t), x: roundValue(clamp(x, -1, 2)), y: roundValue(clamp(y, -1, 2)), easing: easing)
    }

    static func scale(_ t: Double, _ x: Double, _ y: Double, _ easing: AnimatedEasing) -> ScaleKeyframe {
        .init(timeSeconds: roundTime(t), x: roundValue(clamp(x, 0.05, 8)), y: roundValue(clamp(y, 0.05, 8)), easing: easing)
    }

    static func rotation(_ t: Double, _ degrees: Double, _ easing: AnimatedEasing) -> RotationKeyframe {
        .init(timeSeconds: roundTime(t), degrees: roundValue(clamp(degrees, -1080, 1080)), easing: easing)
    }

    static func opacity(_ t: Double, _ value: Double, _ easing: AnimatedEasing) -> OpacityKeyframe {
        .init(timeSeconds: roundTime(t), value: roundValue(clamp(value, 0, 1)), easing: easing)
    }

    static func effect(
        _ t: Double,
        blurRadius: Double = 0,
        hueDegrees: Double = 0,
        saturation: Double = 1,
        _ easing: AnimatedEasing
    ) -> EffectKeyframe {
        .init(
            timeSeconds: roundTime(t),
            blurRadius: roundValue(clamp(blurRadius, 0, 20)),
            hueDegrees: roundValue(clamp(hueDegrees, -180, 180)),
            saturation: roundValue(clamp(saturation, 0, 2)),
            easing: easing
        )
    }

    static func trim(_ t: Double, _ start: Double, _ end: Double, _ easing: AnimatedEasing) -> TrimKeyframe {
        .init(timeSeconds: roundTime(t), start: roundValue(clamp(start, 0, 1)), end: roundValue(clamp(end, 0, 1)), easing: easing)
    }

    // MARK: - Conflict detection

    /// Rejects two specs that write the same channel over overlapping time.
    ///
    /// There is no meaningful blend of "fade to 0" and "fade to 1" across one instant, and picking a
    /// winner silently produces motion the author never asked for. Touching windows — one ending
    /// exactly where the next begins — are allowed; that is the normal fade-in-then-fade-out shape,
    /// and the duplicate boundary keyframe is reconciled in `merge`.
    static func assertNoChannelConflicts(_ specs: [AnimationSpec]) throws {
        var windows: [AnimationChannel: [(spec: AnimationSpec, start: Double, end: Double)]] = [:]
        for spec in specs {
            for channel in spec.channels {
                let start = spec.delay
                let end = spec.endSeconds
                for existing in windows[channel, default: []] where start < existing.end && existing.start < end {
                    throw AnimationCompileError(
                        "Animations \"\(existing.spec.type.rawValue)\" and \"\(spec.type.rawValue)\" both drive the "
                        + "\(channel.rawValue) channel between \(Swift.max(start, existing.start))s and "
                        + "\(Swift.min(end, existing.end))s. Give them non-overlapping delay/duration windows, or drop one."
                    )
                }
                windows[channel, default: []].append((spec, start, end))
            }
        }
    }

    /// Folds a spec's keyframes into a channel, reconciling a shared boundary timestamp.
    ///
    /// Two keyframes may not sit on the same time — the interpolator sorts by time and would pick
    /// one arbitrarily. When windows merely touch and both sides agree on the value (a fade in
    /// ending at 1, a fade out starting at 1) the duplicate is dropped. When they disagree it is a
    /// real discontinuity that keyframes cannot express, so it is an error rather than a silent jump.
    static func merge<Frame: CompiledKeyframe>(
        _ existing: inout [Frame],
        _ incoming: [Frame],
        _ channel: AnimationChannel
    ) throws {
        for frame in incoming {
            guard let clash = existing.first(where: { $0.timeSeconds == frame.timeSeconds }) else {
                existing.append(frame)
                continue
            }
            guard clash.valueSignature == frame.valueSignature else {
                throw AnimationCompileError(
                    "Two animations set different \(channel.rawValue) values at \(frame.timeSeconds)s. "
                    + "Separate them in time so one finishes before the other starts."
                )
            }
        }
        existing.sort { $0.timeSeconds < $1.timeSeconds }
    }

    /// Phase samples for a cyclic spec: 0, 0.25, … cycles, inclusive of the closing sample.
    static func cyclePhases(_ cycles: Int) -> [Double] {
        stride(from: 0, through: cycles * samplesPerCycle, by: 1).map { Double($0) / Double(samplesPerCycle) }
    }

    static func directionOffset(_ direction: AnimationDirection, _ distance: Double) -> AnimatedPoint {
        switch direction {
        case .up: AnimatedPoint(x: 0, y: distance)      // slides in from below, moving up
        case .down: AnimatedPoint(x: 0, y: -distance)
        case .left: AnimatedPoint(x: distance, y: 0)    // slides in from the right, moving left
        case .right: AnimatedPoint(x: -distance, y: 0)
        }
    }

    // MARK: - Compilation

    /// Compiles one layer's specs against its resting anchor.
    ///
    /// `cycleCap` is the budget lever: reducing the cycle count degrades a wiggle from three shakes
    /// to one but keeps it a wiggle, whereas reducing samples-per-cycle below four would sample the
    /// sine only at its zero crossings and flatten the motion entirely.
    public static func compile(
        _ specs: [AnimationSpec],
        anchor: AnimatedAnchor = .default,
        timing: AnimationTiming,
        cycleCap: Int = .max
    ) throws -> AnimatedLayerAnimation {
        var out = AnimatedLayerAnimation.empty
        guard !specs.isEmpty else {
            applyAnchors(anchor, driven: [], into: &out)
            return out
        }
        guard timing.kind != .static else {
            throw AnimationCompileError(
                "A static sticker cannot animate, but \(specs.count) animation(s) were supplied. "
                + "Create the sticker as animated, or remove the animations."
            )
        }
        for spec in specs where spec.endSeconds > timing.durationSeconds + 1e-9 {
            throw AnimationCompileError(
                "Animation \"\(spec.type.rawValue)\" ends at \(roundTime(spec.endSeconds))s but the sticker is only "
                + "\(timing.durationSeconds)s long. Shorten its duration, reduce its delay, or lengthen the sticker."
            )
        }
        try assertNoChannelConflicts(specs)

        var driven: Set<AnimationChannel> = []
        for spec in specs { driven.formUnion(spec.channels) }
        for spec in specs {
            try compile(spec, anchor: anchor, cycleCap: spec.type.isCyclic ? cycleCap : .max, into: &out)
        }
        applyAnchors(anchor, driven: driven, into: &out)

        try sortAndCheck(&out)
        return out
    }

    private static func sortAndCheck(_ out: inout AnimatedLayerAnimation) throws {
        out.position.sort { $0.timeSeconds < $1.timeSeconds }
        out.scale.sort { $0.timeSeconds < $1.timeSeconds }
        out.rotation.sort { $0.timeSeconds < $1.timeSeconds }
        out.opacity.sort { $0.timeSeconds < $1.timeSeconds }
        out.effects.sort { $0.timeSeconds < $1.timeSeconds }
        out.trim.sort { $0.timeSeconds < $1.timeSeconds }

        let counts: [(AnimationChannel, Int)] = [
            (.position, out.position.count), (.scale, out.scale.count), (.rotation, out.rotation.count),
            (.opacity, out.opacity.count), (.effects, out.effects.count), (.trim, out.trim.count),
        ]
        for (channel, count) in counts where count > maximumChannelKeyframes {
            throw AnimationCompileError(
                "The \(channel.rawValue) channel compiled to \(count) keyframes, over the "
                + "\(maximumChannelKeyframes) limit. Use fewer cycles or fewer animations on this layer.",
                isChannelOverflow: true
            )
        }
    }

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    private static func compile(
        _ spec: AnimationSpec,
        anchor: AnimatedAnchor,
        cycleCap: Int,
        into out: inout AnimatedLayerAnimation
    ) throws {
        let start = spec.delay
        let end = spec.endSeconds
        let ease = spec.easing
        let anchorPosition = anchor.position
        let anchorScale = anchor.scale
        let anchorRotation = anchor.rotationDegrees
        let anchorOpacity = anchor.opacity
        let anchorTrim = anchor.trim

        switch spec.effect {
        case .fadeIn:
            try merge(&out.opacity, [opacity(start, 0, .linear), opacity(end, anchorOpacity, ease)], .opacity)

        case .fadeOut:
            try merge(&out.opacity, [opacity(start, anchorOpacity, .linear), opacity(end, 0, ease)], .opacity)

        case .popIn(let from):
            try merge(&out.scale, [
                scale(start, anchorScale.x * from, anchorScale.y * from, .linear),
                scale(end, anchorScale.x, anchorScale.y, ease),
            ], .scale)
            try merge(&out.opacity, [opacity(start, 0, .linear), opacity(end, anchorOpacity, ease)], .opacity)

        case .popOut(let to):
            try merge(&out.scale, [
                scale(start, anchorScale.x, anchorScale.y, .linear),
                scale(end, anchorScale.x * to, anchorScale.y * to, ease),
            ], .scale)
            try merge(&out.opacity, [opacity(start, anchorOpacity, .linear), opacity(end, 0, ease)], .opacity)

        case .slideIn(let direction, let distance), .slideOut(let direction, let distance):
            let offset = directionOffset(direction, distance)
            let away = AnimatedPoint(x: anchorPosition.x + offset.x, y: anchorPosition.y + offset.y)
            let entering = spec.type == .slideIn
            try merge(&out.position, [
                entering
                    ? position(start, away.x, away.y, .linear)
                    : position(start, anchorPosition.x, anchorPosition.y, .linear),
                entering
                    ? position(end, anchorPosition.x, anchorPosition.y, ease)
                    : position(end, away.x, away.y, ease),
            ], .position)
            try merge(&out.opacity, [
                opacity(start, entering ? 0 : anchorOpacity, .linear),
                opacity(end, entering ? anchorOpacity : 0, ease),
            ], .opacity)

        case .moveTo(let x, let y):
            try merge(&out.position, [
                position(start, anchorPosition.x, anchorPosition.y, .linear),
                position(end, x, y, ease),
            ], .position)

        case .scaleTo(let x, let y):
            try merge(&out.scale, [
                scale(start, anchorScale.x, anchorScale.y, .linear),
                scale(end, x, y, ease),
            ], .scale)

        case .rotateTo(let degrees):
            try merge(&out.rotation, [
                rotation(start, anchorRotation, .linear),
                rotation(end, degrees, ease),
            ], .rotation)

        case .spin(let turns, let direction):
            try merge(&out.rotation, [
                rotation(start, anchorRotation, .linear),
                rotation(end, anchorRotation + 360 * turns * (direction == .cw ? 1 : -1), ease),
            ], .rotation)

        case .wiggle(let amplitudeDegrees, let requestedCycles):
            let cycles = Swift.min(requestedCycles, cycleCap)
            let step = spec.duration / Double(cycles)
            try merge(&out.rotation, cyclePhases(cycles).map { phase in
                rotation(
                    start + phase * step,
                    anchorRotation + amplitudeDegrees * sin(2 * .pi * phase),
                    ease
                )
            }, .rotation)

        case .pulse(let minScale, let maxScale, let requestedCycles):
            let cycles = Swift.min(requestedCycles, cycleCap)
            let step = spec.duration / Double(cycles)
            try merge(&out.scale, cyclePhases(cycles).map { phase in
                let wave = sin(2 * .pi * phase)
                let factor = wave >= 0 ? 1 + wave * (maxScale - 1) : 1 + wave * (1 - minScale)
                return scale(start + phase * step, anchorScale.x * factor, anchorScale.y * factor, ease)
            }, .scale)

        case .float(let amplitude, let requestedCycles):
            let cycles = Swift.min(requestedCycles, cycleCap)
            let step = spec.duration / Double(cycles)
            try merge(&out.position, cyclePhases(cycles).map { phase in
                position(
                    start + phase * step,
                    anchorPosition.x,
                    // Negative y is up: the canvas origin is top-left.
                    anchorPosition.y - amplitude * sin(2 * .pi * phase),
                    ease
                )
            }, .position)

        case .bounce(let height, let requestedBounces):
            let bounces = Swift.min(requestedBounces, cycleCap)
            let step = spec.duration / Double(bounces)
            var frames = [position(start, anchorPosition.x, anchorPosition.y, .linear)]
            for index in 0..<bounces {
                // Each hop is weaker than the last, which reads as gravity rather than a sine wave.
                let hop = height * pow(0.6, Double(index))
                frames.append(position(start + (Double(index) + 0.5) * step, anchorPosition.x, anchorPosition.y - hop, .easeOut))
                frames.append(position(start + Double(index + 1) * step, anchorPosition.x, anchorPosition.y, .easeIn))
            }
            try merge(&out.position, frames, .position)

        case .blurIn(let radius):
            try merge(&out.effects, [
                effect(start, blurRadius: radius, .linear),
                effect(end, blurRadius: 0, ease),
            ], .effects)

        case .blurOut(let radius):
            try merge(&out.effects, [
                effect(start, blurRadius: 0, .linear),
                effect(end, blurRadius: radius, ease),
            ], .effects)

        case .hueShift(let degrees):
            try merge(&out.effects, [
                effect(start, hueDegrees: 0, .linear),
                effect(end, hueDegrees: degrees, ease),
            ], .effects)

        case .drawOn(let from):
            // Only `end` moves: the stroke grows from its own beginning to its full length.
            try merge(&out.trim, [
                trim(start, anchorTrim.start, from, .linear),
                trim(end, anchorTrim.start, anchorTrim.end, ease),
            ], .trim)

        case .drawOff(let to):
            // Only `start` moves: the stroke is eaten from its beginning, so it reads as erasing
            // rather than as un-drawing backwards.
            try merge(&out.trim, [
                trim(start, anchorTrim.start, anchorTrim.end, .linear),
                trim(end, to, anchorTrim.end, ease),
            ], .trim)

        case .trimTo(let trimStart, let trimEnd):
            try merge(&out.trim, [
                trim(start, anchorTrim.start, anchorTrim.end, .linear),
                trim(end, trimStart, trimEnd, ease),
            ], .trim)
        }
    }

    /// Emits the resting keyframe for channels no spec drives.
    ///
    /// Only channels whose anchor differs from the interpolator's own default get a keyframe.
    /// Emitting all six unconditionally would burn most of the 128-keyframe budget on layers that
    /// mostly just sit where they were put.
    static func applyAnchors(
        _ anchor: AnimatedAnchor,
        driven: Set<AnimationChannel>,
        into out: inout AnimatedLayerAnimation
    ) {
        if !driven.contains(.position), anchor.position.x != 0.5 || anchor.position.y != 0.5 {
            out.position.append(position(0, anchor.position.x, anchor.position.y, .linear))
        }
        if !driven.contains(.scale), anchor.scale.x != 1 || anchor.scale.y != 1 {
            out.scale.append(scale(0, anchor.scale.x, anchor.scale.y, .linear))
        }
        if !driven.contains(.rotation), anchor.rotationDegrees != 0 {
            out.rotation.append(rotation(0, anchor.rotationDegrees, .linear))
        }
        if !driven.contains(.opacity), anchor.opacity != 1 {
            out.opacity.append(opacity(0, anchor.opacity, .linear))
        }
        if !driven.contains(.trim), !anchor.trim.isFull {
            out.trim.append(trim(0, anchor.trim.start, anchor.trim.end, .linear))
        }
    }

    // MARK: - Budget allocation

    public struct LayerCompileInput: Sendable {
        public var layerId: String
        public var specs: [AnimationSpec]
        public var anchor: AnimatedAnchor

        public init(layerId: String, specs: [AnimationSpec], anchor: AnimatedAnchor = .default) {
            self.layerId = layerId
            self.specs = specs
            self.anchor = anchor
        }
    }

    /// Compiles every layer, shrinking cyclic specs until the document fits its keyframe budget.
    ///
    /// The cap is lowered uniformly rather than per-layer so the result stays independent of layer
    /// order — the compiler has to be deterministic for the document invariant to hold.
    public static func compileAll(
        _ layers: [LayerCompileInput],
        timing: AnimationTiming
    ) throws -> [AnimatedLayerAnimation] {
        let maxCycles = layers.reduce(1) { highest, layer in
            layer.specs.reduce(highest) { inner, spec in
                switch spec.effect {
                case .wiggle(_, let cycles), .pulse(_, _, let cycles), .float(_, let cycles):
                    Swift.max(inner, cycles)
                case .bounce(_, let bounces):
                    Swift.max(inner, bounces)
                default:
                    inner
                }
            }
        }

        var lastError: AnimationCompileError?
        for cap in stride(from: maxCycles, through: 1, by: -1) {
            do {
                let compiled = try layers.map { try compile($0.specs, anchor: $0.anchor, timing: timing, cycleCap: cap) }
                let total = compiled.reduce(0) { $0 + $1.keyframeCount }
                if total <= maximumDocumentKeyframes { return compiled }
                lastError = AnimationCompileError(
                    "The animations compiled to \(total) keyframes, over the \(maximumDocumentKeyframes) limit for a "
                    + "document. Use fewer layers, fewer animations per layer, or fewer cycles."
                )
            } catch let error as AnimationCompileError {
                // A per-channel overflow may also clear up at a lower cycle cap, so keep shrinking.
                // Any other failure — conflicts, timing — is invariant to the cap and rethrows.
                lastError = error
                guard error.isChannelOverflow else { throw error }
            }
        }
        throw lastError ?? AnimationCompileError("Animations could not be compiled within the keyframe budget")
    }
}

/// Lets `merge` compare two keyframes for value equality while ignoring easing, which is what
/// decides whether a shared boundary timestamp is a harmless duplicate or a real discontinuity.
public protocol CompiledKeyframe: AnimatedTimedKeyframe {
    var valueSignature: [Double] { get }
}

extension PositionKeyframe: CompiledKeyframe {
    public var valueSignature: [Double] { [timeSeconds, x, y] }
}

extension ScaleKeyframe: CompiledKeyframe {
    public var valueSignature: [Double] { [timeSeconds, x, y] }
}

extension RotationKeyframe: CompiledKeyframe {
    public var valueSignature: [Double] { [timeSeconds, degrees] }
}

extension OpacityKeyframe: CompiledKeyframe {
    public var valueSignature: [Double] { [timeSeconds, value] }
}

extension EffectKeyframe: CompiledKeyframe {
    public var valueSignature: [Double] { [timeSeconds, blurRadius, hueDegrees, saturation] }
}

extension TrimKeyframe: CompiledKeyframe {
    public var valueSignature: [Double] { [timeSeconds, start, end] }
}
