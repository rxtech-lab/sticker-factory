import Foundation

public struct AnimatedEffectValue: Equatable, Sendable {
    public var blurRadius: Double
    public var hueDegrees: Double
    public var saturation: Double

    public init(blurRadius: Double = 0, hueDegrees: Double = 0, saturation: Double = 1) {
        self.blurRadius = blurRadius
        self.hueDegrees = hueDegrees
        self.saturation = saturation
    }

    public static let identity = AnimatedEffectValue()
    public var isIdentity: Bool { self == .identity }
}

/// How much of the layer a wipe is currently letting through.
///
/// `start`/`end` bound the visible band along the axis at `angleDegrees`, feathered by `softness`.
/// The identity — the whole layer, hard-edged — is what an empty channel resolves to, so a layer
/// that has never been wiped costs the renderer nothing.
public struct AnimatedWipe: Equatable, Sendable {
    public var start: Double
    public var end: Double
    public var angleDegrees: Double
    public var softness: Double

    public init(start: Double = 0, end: Double = 1, angleDegrees: Double = 0, softness: Double = 0) {
        self.start = start
        self.end = end
        self.angleDegrees = angleDegrees
        self.softness = softness
    }

    public static let identity = AnimatedWipe()
    public var isIdentity: Bool { self == .identity }
    /// A window that has closed past itself shows nothing, rather than inverting.
    public var isEmptyWindow: Bool { end <= start }
}

/// Where the highlight band is and how bright it burns.
///
/// Identity is `intensity == 0`: the band is always somewhere on the axis, it is just invisible.
public struct AnimatedSheen: Equatable, Sendable {
    public var position: Double
    public var width: Double
    public var angleDegrees: Double
    public var intensity: Double

    public init(position: Double = 0, width: Double = 0.25, angleDegrees: Double = 0, intensity: Double = 0) {
        self.position = position
        self.width = width
        self.angleDegrees = angleDegrees
        self.intensity = intensity
    }

    public static let identity = AnimatedSheen()
    /// Only `intensity` decides visibility, so a band parked mid-layer at zero strength is identity.
    public var isIdentity: Bool { intensity <= 0 }
}

/// How strong a halo the layer is shedding, and how far it spreads.
public struct AnimatedGlow: Equatable, Sendable {
    public var amount: Double
    public var radius: Double

    public init(amount: Double = 0, radius: Double = 0.08) {
        self.amount = amount
        self.radius = radius
    }

    public static let identity = AnimatedGlow()
    public var isIdentity: Bool { amount <= 0 }
}

/// Everything the renderer needs to draw one layer at one instant.
public struct AnimatedLayerState: Equatable, Sendable {
    public var position: AnimatedPoint
    public var scale: AnimatedPoint
    public var rotationDegrees: Double
    public var opacity: Double
    public var effects: AnimatedEffectValue
    public var trim: AnimatedTrim
    public var wipe: AnimatedWipe
    public var sheen: AnimatedSheen
    public var glow: AnimatedGlow

    // The three v3 parameters are appended last and defaulted so every existing caller — previews,
    // tests, the exporter — keeps compiling untouched.
    public init(
        position: AnimatedPoint = .center,
        scale: AnimatedPoint = .unit,
        rotationDegrees: Double = 0,
        opacity: Double = 1,
        effects: AnimatedEffectValue = .identity,
        trim: AnimatedTrim = .full,
        wipe: AnimatedWipe = .identity,
        sheen: AnimatedSheen = .identity,
        glow: AnimatedGlow = .identity
    ) {
        self.position = position
        self.scale = scale
        self.rotationDegrees = rotationDegrees
        self.opacity = opacity
        self.effects = effects
        self.trim = trim
        self.wipe = wipe
        self.sheen = sheen
        self.glow = glow
    }

    /// The state of a layer with no keyframes at all. These are exactly the fallbacks each channel
    /// resolves to when it is empty, which is what lets the compiler skip emitting an anchor
    /// keyframe for an undisturbed channel.
    public static let resting = AnimatedLayerState()
}

/// Samples compiled keyframes at a point in time.
///
/// Deterministic and free of any notion of "now": the renderer, the exporter, and the tests all
/// call the same function with an explicit time. That is the only reason an exported GIF frame can
/// be guaranteed to match what was on screen.
public enum AnimationInterpolator {
    // MARK: - Time

    /// Converts wall-clock seconds since playback started into a position inside the document's
    /// authored timeline, applying `speed` and the loop behavior.
    public static func mappedTime(_ time: Double, document: AnimatedDocument) -> Double {
        guard document.kind == .animated, document.durationSeconds > 0, document.speed > 0 else { return 0 }
        let duration = document.durationSeconds
        // Speed scales elapsed time on the way in rather than rewriting keyframes, so the same
        // compiled document plays at any speed without recompiling.
        let scaled = time * document.speed
        switch document.loop {
        case .once:
            return min(max(scaled, 0), duration)
        case .loop:
            let remainder = scaled.truncatingRemainder(dividingBy: duration)
            return remainder >= 0 ? remainder : remainder + duration
        case .pingPong:
            let period = duration * 2
            let remainder = scaled.truncatingRemainder(dividingBy: period)
            let positive = remainder >= 0 ? remainder : remainder + period
            return positive <= duration ? positive : period - positive
        }
    }

    /// Which tile of a sequence layer's atlas is showing at a given document time.
    ///
    /// Deliberately a pure function of the *document* time — the value `mappedTime` already
    /// produced, after `speed` and after the document's own loop. Three consequences, all of them
    /// the point:
    ///
    /// - `speed` scales the footage exactly as it scales keyframes. A sticker played at 2x plays
    ///   everything at 2x, which is the only reading a user would predict.
    /// - A ping-pong *document* plays real footage backwards on the way home, which is what turns
    ///   1.2s of Live Photo into a seamless 2.4s cycle with no visible cut.
    /// - `durationSeconds` stays the sole authority on how long a sticker runs. Footage shorter
    ///   than the cycle repeats according to its own `playback`; footage longer is truncated. The
    ///   atlas never extends the document, which is why the export duration checks need to know
    ///   nothing about sequence layers.
    ///
    /// Mirrored byte for byte by `sequenceFrameIndex` in `server/lib/animation/sample.ts`, and
    /// pinned from both sides by `sequence-frame-index-parity.json`.
    public static func sequenceFrameIndex(_ layer: AnimatedSequenceLayer, atDocumentTime time: Double) -> Int {
        let count = max(1, layer.frameCount)
        if count == 1 { return 0 }

        let elapsed = time - layer.startSeconds
        // Before the layer's start the first tile is held rather than the layer being hidden: a
        // sequence that vanished for its first second would read as a failed asset load.
        if elapsed <= 0 { return 0 }

        let raw = Int((elapsed * layer.frameRate).rounded(.down))
        switch layer.playback {
        case .once:
            return min(raw, count - 1)
        case .loop:
            return ((raw % count) + count) % count
        case .pingPong:
            let period = count * 2 - 2
            let offset = ((raw % period) + period) % period
            return offset < count ? offset : period - offset
        }
    }

    /// The wall-clock length of one visible cycle. Ping-pong is there and back.
    public static func renderedCycleDuration(_ document: AnimatedDocument) -> Double {
        document.renderedCycleDuration
    }

    // MARK: - Sampling

    public static func state(for layer: AnimatedLayer, at rawTime: Double, in document: AnimatedDocument) -> AnimatedLayerState {
        state(for: layer, atDocumentTime: mappedTime(rawTime, document: document))
    }

    /// Samples at an already-mapped time inside the authored timeline.
    ///
    /// Exposed separately because the exporter walks the timeline directly and must not have loop
    /// mapping applied twice.
    public static func state(for layer: AnimatedLayer, atDocumentTime time: Double) -> AnimatedLayerState {
        let animation = layer.animation
        let anchor = layer.anchor
        return .init(
            position: point(animation.position, at: time, default: anchor.position),
            scale: point(animation.scale, at: time, default: anchor.scale, x: \.x, y: \.y),
            rotationDegrees: scalar(animation.rotation, at: time, default: anchor.rotationDegrees, value: \.degrees),
            opacity: scalar(animation.opacity, at: time, default: anchor.opacity, value: \.value),
            effects: effect(animation.effects, at: time),
            trim: trim(animation.trim, at: time, default: anchor.trim),
            // These three fall back to their own identity rather than to the anchor: like `effects`,
            // they have no resting state on `AnimatedAnchor`, so an empty channel means "off".
            wipe: wipe(animation.wipe, at: time),
            sheen: sheen(animation.sheen, at: time),
            glow: glow(animation.glow, at: time)
        )
    }

    // MARK: - Easing

    /// The easing curves, as a plain function of normalized progress.
    ///
    /// `AnimationCompiler` calls this when it bakes eased progress into an `arcTo`'s samples, which
    /// makes it part of the cross-language contract: `server/lib/animation/easing.ts` is its twin
    /// and the two must agree bit for bit. That is why the polynomials are written as repeated
    /// multiplication rather than `pow` — `pow` is not required to be correctly rounded, so libm and
    /// V8 may disagree in the last bit, while multiplication is exact IEEE-754 in both.
    ///
    /// The two springs deliberately overshoot 1 before settling, so `easedProgress(1)` is not
    /// exactly 1 for them; callers that must land on a target pin the closing sample themselves.
    public static func easedProgress(_ progress: Double, easing: AnimatedEasing) -> Double {
        let t = min(max(progress, 0), 1)
        switch easing {
        case .linear:
            return t
        case .easeIn:
            return t * t * t
        case .easeOut:
            let remaining = 1 - t
            return 1 - remaining * remaining * remaining
        case .easeInOut:
            if t < 0.5 { return 4 * t * t * t }
            let remaining = -2 * t + 2
            return 1 - (remaining * remaining * remaining) / 2
        case .springSoft:
            return 1 - exp(-7 * t) * cos(8 * t)
        case .springBouncy:
            return 1 - exp(-5 * t) * cos(12 * t)
        }
    }

    // MARK: - Channels

    private static func point(
        _ frames: [PositionKeyframe],
        at time: Double,
        default fallback: AnimatedPoint
    ) -> AnimatedPoint {
        interpolate(frames, at: time, default: fallback, easing: \.easing) {
            AnimatedPoint(x: $0.x, y: $0.y)
        } blend: { a, b, t in
            AnimatedPoint(x: mix(a.x, b.x, t), y: mix(a.y, b.y, t))
        }
    }

    private static func point(
        _ frames: [ScaleKeyframe],
        at time: Double,
        default fallback: AnimatedPoint,
        x: KeyPath<ScaleKeyframe, Double>,
        y: KeyPath<ScaleKeyframe, Double>
    ) -> AnimatedPoint {
        interpolate(frames, at: time, default: fallback, easing: \.easing) {
            AnimatedPoint(x: $0[keyPath: x], y: $0[keyPath: y])
        } blend: { a, b, t in
            AnimatedPoint(x: mix(a.x, b.x, t), y: mix(a.y, b.y, t))
        }
    }

    private static func scalar<Frame: AnimatedTimedKeyframe>(
        _ frames: [Frame],
        at time: Double,
        default fallback: Double,
        value: KeyPath<Frame, Double>
    ) -> Double {
        interpolate(frames, at: time, default: fallback, easing: \.easing) {
            $0[keyPath: value]
        } blend: {
            mix($0, $1, $2)
        }
    }

    private static func effect(_ frames: [EffectKeyframe], at time: Double) -> AnimatedEffectValue {
        interpolate(frames, at: time, default: .identity, easing: \.easing) {
            AnimatedEffectValue(blurRadius: $0.blurRadius, hueDegrees: $0.hueDegrees, saturation: $0.saturation)
        } blend: { a, b, t in
            AnimatedEffectValue(
                blurRadius: mix(a.blurRadius, b.blurRadius, t),
                hueDegrees: mix(a.hueDegrees, b.hueDegrees, t),
                saturation: mix(a.saturation, b.saturation, t)
            )
        }
    }

    private static func trim(_ frames: [TrimKeyframe], at time: Double, default fallback: AnimatedTrim) -> AnimatedTrim {
        interpolate(frames, at: time, default: fallback, easing: \.easing) {
            AnimatedTrim(start: $0.start, end: $0.end)
        } blend: { a, b, t in
            AnimatedTrim(start: mix(a.start, b.start, t), end: mix(a.end, b.end, t))
        }
    }

    private static func wipe(_ frames: [WipeKeyframe], at time: Double) -> AnimatedWipe {
        interpolate(frames, at: time, default: .identity, easing: \.easing) {
            AnimatedWipe(start: $0.start, end: $0.end, angleDegrees: $0.angleDegrees, softness: $0.softness)
        } blend: { a, b, t in
            AnimatedWipe(
                start: mix(a.start, b.start, t),
                end: mix(a.end, b.end, t),
                angleDegrees: mix(a.angleDegrees, b.angleDegrees, t),
                softness: mix(a.softness, b.softness, t)
            )
        }
    }

    private static func sheen(_ frames: [SheenKeyframe], at time: Double) -> AnimatedSheen {
        interpolate(frames, at: time, default: .identity, easing: \.easing) {
            AnimatedSheen(position: $0.position, width: $0.width, angleDegrees: $0.angleDegrees, intensity: $0.intensity)
        } blend: { a, b, t in
            AnimatedSheen(
                position: mix(a.position, b.position, t),
                width: mix(a.width, b.width, t),
                angleDegrees: mix(a.angleDegrees, b.angleDegrees, t),
                intensity: mix(a.intensity, b.intensity, t)
            )
        }
    }

    private static func glow(_ frames: [GlowKeyframe], at time: Double) -> AnimatedGlow {
        interpolate(frames, at: time, default: .identity, easing: \.easing) {
            AnimatedGlow(amount: $0.amount, radius: $0.radius)
        } blend: { a, b, t in
            AnimatedGlow(amount: mix(a.amount, b.amount, t), radius: mix(a.radius, b.radius, t))
        }
    }

    /// Finds the keyframe pair bracketing `timeValue` and blends between them.
    ///
    /// Easing is read from the *upper* keyframe because it governs the segment ending there; the
    /// easing on a channel's first keyframe is therefore never used.
    private static func interpolate<Frame: AnimatedTimedKeyframe, Value>(
        _ frames: [Frame],
        at timeValue: Double,
        default fallback: Value,
        easing: KeyPath<Frame, AnimatedEasing>,
        value: (Frame) -> Value,
        blend: (Value, Value, Double) -> Value
    ) -> Value {
        let sorted = frames.sorted { $0.timeSeconds < $1.timeSeconds }
        guard let first = sorted.first else { return fallback }
        if timeValue <= first.timeSeconds { return value(first) }
        guard let last = sorted.last else { return fallback }
        if timeValue >= last.timeSeconds { return value(last) }
        guard let upperIndex = sorted.firstIndex(where: { $0.timeSeconds >= timeValue }), upperIndex > 0 else {
            return value(first)
        }
        let lower = sorted[upperIndex - 1]
        let upper = sorted[upperIndex]
        let span = upper.timeSeconds - lower.timeSeconds
        let raw = span > 0 ? (timeValue - lower.timeSeconds) / span : 1
        return blend(value(lower), value(upper), easedProgress(raw, easing: upper[keyPath: easing]))
    }

    private static func mix(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }
}
