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
    /// Segments an `arcTo` is sampled into; it emits one more keyframe than this.
    ///
    /// Eleven keyframes is a third of a channel's budget, which is the price of curving a channel
    /// the interpolator blends linearly. It is enough that the chord error on the widest arc the
    /// schema allows stays well under a pixel at export sizes, and few enough that eight arcing
    /// layers still fit the document's 128-keyframe ceiling.
    static let arcSegments = 10
    /// The fraction of a `shine` cycle spent traversing; the rest is an invisible return leg.
    ///
    /// A repeating sweep has to jump back to the leading edge, and two keyframes cannot share a
    /// timestamp. Reserving a slice at the end of each cycle — travelled at zero intensity, so
    /// nothing is on screen — is what lets `cycles > 1` exist without a discontinuity.
    static let shineSweepFraction = 0.88
    /// Where a `shine` reaches full brightness, as a fraction of its traverse, and its mirror.
    ///
    /// A triangular envelope reads as a brightening blob rather than a travelling highlight; holding
    /// full intensity across the middle and ramping only at the ends is what makes it read as light.
    static let shineRampFraction = 0.18

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

    static func wipe(
        _ t: Double,
        _ start: Double,
        _ end: Double,
        _ angleDegrees: Double,
        _ softness: Double,
        _ easing: AnimatedEasing
    ) -> WipeKeyframe {
        .init(
            timeSeconds: roundTime(t),
            start: roundValue(clamp(start, 0, 1)),
            end: roundValue(clamp(end, 0, 1)),
            angleDegrees: roundValue(clamp(angleDegrees, -360, 360)),
            softness: roundValue(clamp(softness, 0, 0.5)),
            easing: easing
        )
    }

    static func sheen(
        _ t: Double,
        _ position: Double,
        _ width: Double,
        _ angleDegrees: Double,
        _ intensity: Double,
        _ easing: AnimatedEasing
    ) -> SheenKeyframe {
        .init(
            timeSeconds: roundTime(t),
            // Clamped to the position channel's range, not 0…1: the band has to be representable
            // fully off-canvas at both ends or a sweep starts at the layer's leading edge.
            position: roundValue(clamp(position, -1, 2)),
            width: roundValue(clamp(width, 0.02, 1)),
            angleDegrees: roundValue(clamp(angleDegrees, -360, 360)),
            intensity: roundValue(clamp(intensity, 0, 1)),
            easing: easing
        )
    }

    static func glow(_ t: Double, _ amount: Double, _ radius: Double, _ easing: AnimatedEasing) -> GlowKeyframe {
        .init(
            timeSeconds: roundTime(t),
            amount: roundValue(clamp(amount, 0, 1)),
            radius: roundValue(clamp(radius, 0.01, 0.5)),
            easing: easing
        )
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

    /// The control point of the quadratic Bézier an `arcTo` follows.
    ///
    /// The apex sign is normalized rather than taken straight from the perpendicular: a raw
    /// perpendicular flips with the direction of travel, so one `arcHeight` would arc a rightward
    /// throw over and a leftward one under. Forcing the normal to point at the top of the canvas
    /// makes the sign mean the same thing whichever way the layer is going, and leaves a purely
    /// vertical move — where "up" is meaningless — bowing to the right.
    static func arcControlPoint(_ from: AnimatedPoint, _ to: AnimatedPoint, _ arcHeight: Double) -> AnimatedPoint {
        let dx = to.x - from.x
        let dy = to.y - from.y
        // `sqrt` rather than `hypot`: hypot is not correctly rounded and implementations disagree,
        // which would break the byte-equality with `compile.ts` this port has to hold to.
        let length = (dx * dx + dy * dy).squareRoot()
        // A move that goes nowhere has no direction to be perpendicular to; straight up is the only
        // sensible reading, and it makes an in-place `arcTo` a toss that comes back down.
        var normalX = length > 0 ? dy / length : 0
        var normalY = length > 0 ? -dx / length : -1
        if normalY > 0 || (normalY == 0 && normalX < 0) {
            normalX = -normalX
            normalY = -normalY
        }
        // A quadratic Bézier passes half way to its control point at the midpoint of the curve, so
        // the control is displaced twice as far as the apex height the caller actually asked for.
        return AnimatedPoint(
            x: (from.x + to.x) / 2 + 2 * arcHeight * normalX,
            y: (from.y + to.y) / 2 + 2 * arcHeight * normalY
        )
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
        out.wipe.sort { $0.timeSeconds < $1.timeSeconds }
        out.sheen.sort { $0.timeSeconds < $1.timeSeconds }
        out.glow.sort { $0.timeSeconds < $1.timeSeconds }

        // Counted through `AnimationChannel.allCases` and the exhaustive `count(of:)` rather than a
        // hand-written list, so a channel added later cannot silently escape the per-channel cap.
        // The sorts above still have to be written out — the arrays have nine different element
        // types — but an unsorted track shows up as a rendering glitch, not a wrong-looking cap.
        let counts = AnimationChannel.allCases.map { ($0, out.count(of: $0)) }
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
                scale(end, anchorScale.x, anchorScale.y, ease)
            ], .scale)
            try merge(&out.opacity, [opacity(start, 0, .linear), opacity(end, anchorOpacity, ease)], .opacity)

        case .popOut(let to):
            try merge(&out.scale, [
                scale(start, anchorScale.x, anchorScale.y, .linear),
                scale(end, anchorScale.x * to, anchorScale.y * to, ease)
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
                    : position(end, away.x, away.y, ease)
            ], .position)
            try merge(&out.opacity, [
                opacity(start, entering ? 0 : anchorOpacity, .linear),
                opacity(end, entering ? anchorOpacity : 0, ease)
            ], .opacity)

        case .moveTo(let x, let y):
            try merge(&out.position, [
                position(start, anchorPosition.x, anchorPosition.y, .linear),
                position(end, x, y, ease)
            ], .position)

        case .arcTo(let x, let y, let arcHeight):
            let target = AnimatedPoint(x: x, y: y)
            let control = arcControlPoint(anchorPosition, target, arcHeight)
            try merge(&out.position, (0...arcSegments).map { index in
                let fraction = Double(index) / Double(arcSegments)
                // Easing is baked into *where* each sample sits, and every keyframe is emitted
                // linear, so the interpolator replays the curve at the parameter speed the easing
                // asked for. Putting the easing on the segments instead would drop the velocity to
                // zero at all eleven samples and read as a stutter rather than a throw. The closing
                // sample is pinned rather than eased so an arc lands exactly on its target the way
                // `moveTo` does, even under a spring's overshoot.
                //
                // The parameter is clamped rather than allowed to overshoot: a spring's easing
                // exceeds 1, and extrapolating a Bézier past its endpoint throws the layer clean off
                // the canvas instead of past its target. Clamped, a spring rings back and forth
                // *along* the arc, which is what "springy throw" should mean.
                let curve = clamp(index == arcSegments ? 1 : AnimationInterpolator.easedProgress(fraction, easing: ease), 0, 1)
                let inverse = 1 - curve
                let fromWeight = inverse * inverse
                let controlWeight = 2 * inverse * curve
                let toWeight = curve * curve
                return position(
                    start + fraction * spec.duration,
                    fromWeight * anchorPosition.x + controlWeight * control.x + toWeight * target.x,
                    fromWeight * anchorPosition.y + controlWeight * control.y + toWeight * target.y,
                    .linear
                )
            }, .position)

        case .scaleTo(let x, let y):
            try merge(&out.scale, [
                scale(start, anchorScale.x, anchorScale.y, .linear),
                scale(end, x, y, ease)
            ], .scale)

        case .rotateTo(let degrees):
            try merge(&out.rotation, [
                rotation(start, anchorRotation, .linear),
                rotation(end, degrees, ease)
            ], .rotation)

        case .spin(let turns, let direction):
            try merge(&out.rotation, [
                rotation(start, anchorRotation, .linear),
                rotation(end, anchorRotation + 360 * turns * (direction == .cw ? 1 : -1), ease)
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
                effect(end, blurRadius: 0, ease)
            ], .effects)

        case .blurOut(let radius):
            try merge(&out.effects, [
                effect(start, blurRadius: 0, .linear),
                effect(end, blurRadius: radius, ease)
            ], .effects)

        case .hueShift(let degrees):
            try merge(&out.effects, [
                effect(start, hueDegrees: 0, .linear),
                effect(end, hueDegrees: degrees, ease)
            ], .effects)

        case .drawOn(let from):
            // Only `end` moves: the stroke grows from its own beginning to its full length.
            try merge(&out.trim, [
                trim(start, anchorTrim.start, from, .linear),
                trim(end, anchorTrim.start, anchorTrim.end, ease)
            ], .trim)

        case .drawOff(let to):
            // Only `start` moves: the stroke is eaten from its beginning, so it reads as erasing
            // rather than as un-drawing backwards.
            try merge(&out.trim, [
                trim(start, anchorTrim.start, anchorTrim.end, .linear),
                trim(end, to, anchorTrim.end, ease)
            ], .trim)

        case .trimTo(let trimStart, let trimEnd):
            try merge(&out.trim, [
                trim(start, anchorTrim.start, anchorTrim.end, .linear),
                trim(end, trimStart, trimEnd, ease)
            ], .trim)

        case .wipeIn(let direction, let softness):
            // Only `end` moves: the visible window grows from the leading edge across the layer.
            let angle = wipeDirectionAngle(direction)
            try merge(&out.wipe, [
                wipe(start, 0, 0, angle, softness, .linear),
                wipe(end, 0, 1, angle, softness, ease)
            ], .wipe)

        case .wipeOut(let direction, let softness):
            // Only `start` moves, so the layer is eaten from the same edge a matching wipeIn
            // revealed from — it reads as the reveal running on rather than as it rewinding.
            let angle = wipeDirectionAngle(direction)
            try merge(&out.wipe, [
                wipe(start, 0, 1, angle, softness, .linear),
                wipe(end, 1, 1, angle, softness, ease)
            ], .wipe)

        case .wipeTo(let wipeStart, let wipeEnd, let angleDegrees, let softness):
            try merge(&out.wipe, [
                wipe(start, 0, 1, angleDegrees, softness, .linear),
                wipe(end, wipeStart, wipeEnd, angleDegrees, softness, ease)
            ], .wipe)

        case .shine(let angleDegrees, let width, let intensity, let specCycles):
            let cycles = Swift.min(specCycles, cycleCap)
            let step = spec.duration / Double(cycles)
            // The band is centred on `position`, so half a width past each edge is fully off-canvas.
            let from = -width / 2
            let span = 1 + width
            var frames: [SheenKeyframe] = []
            for index in 0..<cycles {
                let base = start + Double(index) * step
                let traverse = shineSweepFraction * step
                for phase in [0, shineRampFraction, 1 - shineRampFraction, 1] {
                    frames.append(sheen(
                        base + phase * traverse,
                        from + phase * span,
                        width,
                        angleDegrees,
                        // Dark at both extremes, full brightness across the middle. The dark ends are
                        // also what make the retreat to the next cycle's leading edge invisible.
                        phase == 0 || phase == 1 ? 0 : intensity,
                        // Always linear, whatever the spec asked for. Easing the closing keyframe
                        // would decelerate only the second half of the traverse, which reads as a
                        // stutter rather than a glint — the same reason `arcTo` pins its samples.
                        .linear
                    ))
                }
            }
            try merge(&out.sheen, frames, .sheen)

        case .bloomIn(let radius, let intensity):
            try merge(&out.glow, [
                glow(start, 0, radius, .linear),
                glow(end, intensity, radius, ease)
            ], .glow)

        case .bloomOut(let radius, let intensity):
            try merge(&out.glow, [
                glow(start, intensity, radius, .linear),
                glow(end, 0, radius, ease)
            ], .glow)

        case .bloomPulse(let radius, let intensity, let specCycles):
            let cycles = Swift.min(specCycles, cycleCap)
            let step = spec.duration / Double(cycles)
            // Shaped like `bounce` rather than `pulse`: a glow only brightens, so sampling a full
            // sine would spend half of every cycle clamped flat at zero and cost twice the
            // keyframes for the same breathing motion.
            var frames: [GlowKeyframe] = [glow(start, 0, radius, .linear)]
            for index in 0..<cycles {
                frames.append(glow(start + (Double(index) + 0.5) * step, intensity, radius, ease))
                frames.append(glow(start + (Double(index) + 1) * step, 0, radius, ease))
            }
            try merge(&out.glow, frames, .glow)
        }
    }

    /// The wipe axis for a direction, in the paint convention: 0° left-to-right, clockwise.
    ///
    /// Names the *direction of travel*, matching `directionOffset` — a `wipeIn` with direction
    /// `right` uncovers the layer starting at its left edge and sweeps rightwards, the same way a
    /// `slideIn` with direction `right` ends up travelling rightwards.
    static func wipeDirectionAngle(_ direction: AnimationDirection) -> Double {
        switch direction {
        case .right: 0
        case .down: 90
        case .left: 180
        case .up: 270
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
                case .wiggle(_, let cycles), .pulse(_, _, let cycles), .float(_, let cycles),
                     .shine(_, _, _, let cycles), .bloomPulse(_, _, let cycles):
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

// Every value field has to appear below. The TypeScript side compares the whole keyframe object
// minus easing, so a signature that omits a field would let Swift accept a boundary the server
// rejects — and the client would then be writing documents the server refuses to store.
extension WipeKeyframe: CompiledKeyframe {
    public var valueSignature: [Double] { [timeSeconds, start, end, angleDegrees, softness] }
}

extension SheenKeyframe: CompiledKeyframe {
    public var valueSignature: [Double] { [timeSeconds, position, width, angleDegrees, intensity] }
}

extension GlowKeyframe: CompiledKeyframe {
    public var valueSignature: [Double] { [timeSeconds, amount, radius] }
}

extension TrimKeyframe: CompiledKeyframe {
    public var valueSignature: [Double] { [timeSeconds, start, end] }
}
