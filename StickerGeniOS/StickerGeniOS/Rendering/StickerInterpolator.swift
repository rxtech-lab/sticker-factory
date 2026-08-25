import Foundation

nonisolated struct StickerPoint: Equatable, Sendable {
    var x: Double
    var y: Double
}

nonisolated struct StickerEffectValue: Equatable, Sendable {
    var blurRadius: Double
    var hueDegrees: Double
    var saturation: Double
}

nonisolated struct StickerLayerState: Equatable, Sendable {
    var position: StickerPoint
    var scale: StickerPoint
    var rotationDegrees: Double
    var opacity: Double
    var effects: StickerEffectValue
}

nonisolated enum StickerInterpolator {
    static func renderedCycleDuration(_ document: StickerDocumentV1) -> Double {
        document.kind == .animated && document.loop == .pingPong
            ? document.durationSeconds * 2
            : document.durationSeconds
    }

    static func mappedTime(_ time: Double, document: StickerDocumentV1) -> Double {
        guard document.kind == .animated, document.durationSeconds > 0 else { return 0 }
        switch document.loop {
        case .once:
            return min(max(time, 0), document.durationSeconds)
        case .loop:
            let remainder = time.truncatingRemainder(dividingBy: document.durationSeconds)
            return remainder >= 0 ? remainder : remainder + document.durationSeconds
        case .pingPong:
            let period = document.durationSeconds * 2
            let remainder = time.truncatingRemainder(dividingBy: period)
            let positive = remainder >= 0 ? remainder : remainder + period
            return positive <= document.durationSeconds ? positive : period - positive
        }
    }

    static func state(for layer: StickerLayerV1, at rawTime: Double, in document: StickerDocumentV1) -> StickerLayerState {
        let time = mappedTime(rawTime, document: document)
        let animation = layer.animation
        return .init(
            position: point(animation.position, at: time, default: .init(x: 0.5, y: 0.5)),
            scale: scale(animation.scale, at: time),
            rotationDegrees: rotation(animation.rotation, at: time),
            opacity: scalar(animation.opacity, at: time, default: 1, value: \.value),
            effects: effect(animation.effects, at: time)
        )
    }

    static func easedProgress(_ progress: Double, easing: StickerEasing) -> Double {
        let t = min(max(progress, 0), 1)
        switch easing {
        case .linear: return t
        case .easeIn: return t * t * t
        case .easeOut: return 1 - pow(1 - t, 3)
        case .easeInOut:
            return t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
        case .springSoft:
            return 1 - exp(-7 * t) * cos(8 * t)
        case .springBouncy:
            return 1 - exp(-5 * t) * cos(12 * t)
        }
    }

    private static func point(_ frames: [PositionKeyframeV1], at time: Double, default fallback: StickerPoint) -> StickerPoint {
        interpolate(frames, at: time, default: fallback, time: \.timeSeconds, easing: \.easing) { frame in
            .init(x: frame.x, y: frame.y)
        } blend: { a, b, t in
            .init(x: mix(a.x, b.x, t), y: mix(a.y, b.y, t))
        }
    }

    private static func scale(_ frames: [ScaleKeyframeV1], at time: Double) -> StickerPoint {
        interpolate(frames, at: time, default: .init(x: 1, y: 1), time: \.timeSeconds, easing: \.easing) { frame in
            .init(x: frame.x, y: frame.y)
        } blend: { a, b, t in
            .init(x: mix(a.x, b.x, t), y: mix(a.y, b.y, t))
        }
    }

    private static func rotation(_ frames: [RotationKeyframeV1], at time: Double) -> Double {
        scalar(frames, at: time, default: 0, value: \.degrees)
    }

    private static func scalar<Frame>(
        _ frames: [Frame],
        at time: Double,
        default fallback: Double,
        value: KeyPath<Frame, Double>
    ) -> Double where Frame: StickerTimedKeyframe & Sendable {
        interpolate(frames, at: time, default: fallback, time: \.timeSeconds, easing: \.easing) {
            $0[keyPath: value]
        } blend: { mix($0, $1, $2) }
    }

    private static func effect(_ frames: [EffectKeyframeV1], at time: Double) -> StickerEffectValue {
        interpolate(
            frames,
            at: time,
            default: .init(blurRadius: 0, hueDegrees: 0, saturation: 1),
            time: \.timeSeconds,
            easing: \.easing
        ) { .init(blurRadius: $0.blurRadius, hueDegrees: $0.hueDegrees, saturation: $0.saturation) }
        blend: { a, b, t in
            .init(
                blurRadius: mix(a.blurRadius, b.blurRadius, t),
                hueDegrees: mix(a.hueDegrees, b.hueDegrees, t),
                saturation: mix(a.saturation, b.saturation, t)
            )
        }
    }

    private static func interpolate<Frame, Value>(
        _ frames: [Frame],
        at timeValue: Double,
        default fallback: Value,
        time: KeyPath<Frame, Double>,
        easing: KeyPath<Frame, StickerEasing>,
        value: (Frame) -> Value,
        blend: (Value, Value, Double) -> Value
    ) -> Value {
        let sorted = frames.sorted { $0[keyPath: time] < $1[keyPath: time] }
        guard let first = sorted.first else { return fallback }
        if timeValue <= first[keyPath: time] { return value(first) }
        guard let last = sorted.last, timeValue < last[keyPath: time] else { return value(sorted.last!) }
        guard let upperIndex = sorted.firstIndex(where: { $0[keyPath: time] >= timeValue }), upperIndex > 0 else { return value(first) }
        let lower = sorted[upperIndex - 1]
        let upper = sorted[upperIndex]
        let span = upper[keyPath: time] - lower[keyPath: time]
        let raw = span > 0 ? (timeValue - lower[keyPath: time]) / span : 1
        return blend(value(lower), value(upper), easedProgress(raw, easing: upper[keyPath: easing]))
    }

    private static func mix(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }
}
