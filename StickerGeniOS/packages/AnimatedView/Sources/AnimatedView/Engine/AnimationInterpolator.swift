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

/// Everything the renderer needs to draw one layer at one instant.
public struct AnimatedLayerState: Equatable, Sendable {
    public var position: AnimatedPoint
    public var scale: AnimatedPoint
    public var rotationDegrees: Double
    public var opacity: Double
    public var effects: AnimatedEffectValue
    public var trim: AnimatedTrim

    public init(
        position: AnimatedPoint = .center,
        scale: AnimatedPoint = .unit,
        rotationDegrees: Double = 0,
        opacity: Double = 1,
        effects: AnimatedEffectValue = .identity,
        trim: AnimatedTrim = .full
    ) {
        self.position = position
        self.scale = scale
        self.rotationDegrees = rotationDegrees
        self.opacity = opacity
        self.effects = effects
        self.trim = trim
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
            trim: trim(animation.trim, at: time, default: anchor.trim)
        )
    }

    // MARK: - Easing

    public static func easedProgress(_ progress: Double, easing: AnimatedEasing) -> Double {
        let t = min(max(progress, 0), 1)
        switch easing {
        case .linear:
            return t
        case .easeIn:
            return t * t * t
        case .easeOut:
            return 1 - pow(1 - t, 3)
        case .easeInOut:
            return t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
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
