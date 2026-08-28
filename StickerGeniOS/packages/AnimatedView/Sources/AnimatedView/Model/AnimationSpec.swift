import Foundation

public enum AnimationDirection: String, Codable, CaseIterable, Hashable, Sendable {
    case up, down, left, right
}

public enum AnimationSpinDirection: String, Codable, CaseIterable, Hashable, Sendable {
    case cw, ccw
}

/// The type-specific half of a spec. Delay, duration, and easing live on `AnimationSpec` because
/// every effect has them.
public enum AnimationEffect: Hashable, Sendable {
    // Entrances and exits.
    case fadeIn
    case fadeOut
    /// `from` is a fraction of the layer's resting scale.
    case popIn(from: Double)
    case popOut(to: Double)
    /// `distance` is an offset from the resting position in normalized canvas units.
    case slideIn(direction: AnimationDirection, distance: Double)
    case slideOut(direction: AnimationDirection, distance: Double)

    // Absolute moves.
    case moveTo(x: Double, y: Double)
    /// A curved move. `arcHeight` is how far the path bows away from the straight line at its
    /// midpoint, measured perpendicular to the travel and signed so positive always bows toward the
    /// top of the canvas. `0` is exactly `moveTo`.
    case arcTo(x: Double, y: Double, arcHeight: Double)
    case scaleTo(x: Double, y: Double)
    case rotateTo(degrees: Double)
    case spin(turns: Double, direction: AnimationSpinDirection)

    // Cyclic.
    case wiggle(amplitudeDegrees: Double, cycles: Int)
    case pulse(minScale: Double, maxScale: Double, cycles: Int)
    /// `height` is the peak of the first hop in normalized units; later hops decay.
    case bounce(height: Double, bounces: Int)
    case float(amplitude: Double, cycles: Int)

    // Effects.
    case blurIn(radius: Double)
    case blurOut(radius: Double)
    case hueShift(degrees: Double)

    // Path drawing.
    /// Sweeps the trim window's `end` from `from` to 1, drawing a stroke on.
    case drawOn(from: Double)
    /// Sweeps `start` from 0 to `to`, erasing a stroke from its beginning.
    case drawOff(to: Double)
    case trimTo(start: Double, end: Double)

    // Spatial wipes. Unlike the trim cases above these need no geometry, so they work on images,
    // glyphs and particles too. `softness` feathers the edge; 0 is a hard cut.
    case wipeIn(direction: AnimationDirection, softness: Double)
    case wipeOut(direction: AnimationDirection, softness: Double)
    case wipeTo(start: Double, end: Double, angleDegrees: Double, softness: Double)

    // Light.
    /// A highlight band sweeping across the layer. `easing` is ignored — the band must travel at a
    /// constant speed or it reads as a stutter rather than as light moving.
    case shine(angleDegrees: Double, width: Double, intensity: Double, cycles: Int)
    /// Glow: the layer stays sharp and grows a halo of its own colours. `radius` is a fraction of
    /// the layer's box width.
    case bloomIn(radius: Double, intensity: Double)
    case bloomOut(radius: Double, intensity: Double)
    case bloomPulse(radius: Double, intensity: Double, cycles: Int)

    public var type: AnimationEffectType {
        switch self {
        case .fadeIn: .fadeIn
        case .fadeOut: .fadeOut
        case .popIn: .popIn
        case .popOut: .popOut
        case .slideIn: .slideIn
        case .slideOut: .slideOut
        case .moveTo: .moveTo
        case .arcTo: .arcTo
        case .scaleTo: .scaleTo
        case .rotateTo: .rotateTo
        case .spin: .spin
        case .wiggle: .wiggle
        case .pulse: .pulse
        case .bounce: .bounce
        case .float: .float
        case .blurIn: .blurIn
        case .blurOut: .blurOut
        case .hueShift: .hueShift
        case .drawOn: .drawOn
        case .drawOff: .drawOff
        case .trimTo: .trimTo
        case .wipeIn: .wipeIn
        case .wipeOut: .wipeOut
        case .wipeTo: .wipeTo
        case .shine: .shine
        case .bloomIn: .bloomIn
        case .bloomOut: .bloomOut
        case .bloomPulse: .bloomPulse
        }
    }
}

public enum AnimationEffectType: String, Codable, CaseIterable, Hashable, Sendable {
    case fadeIn, fadeOut, popIn, popOut, slideIn, slideOut
    case moveTo, arcTo, scaleTo, rotateTo, spin
    case wiggle, pulse, bounce, float
    case blurIn, blurOut, hueShift
    case drawOn, drawOff, trimTo
    case wipeIn, wipeOut, wipeTo
    case shine, bloomIn, bloomOut, bloomPulse

    /// Which channels each effect writes.
    ///
    /// Two effects that write the same channel and overlap in time are rejected by the compiler
    /// rather than merged: there is no sensible blend of "fade to 0" and "fade to 1" over the same
    /// instant, and letting one silently win produces motion nobody asked for.
    public var channels: [AnimationChannel] {
        switch self {
        case .fadeIn, .fadeOut: [.opacity]
        case .popIn, .popOut: [.scale, .opacity]
        case .slideIn, .slideOut: [.position, .opacity]
        case .moveTo, .arcTo: [.position]
        case .scaleTo: [.scale]
        case .rotateTo, .spin, .wiggle: [.rotation]
        case .pulse: [.scale]
        case .bounce, .float: [.position]
        case .blurIn, .blurOut, .hueShift: [.effects]
        case .drawOn, .drawOff, .trimTo: [.trim]
        case .wipeIn, .wipeOut, .wipeTo: [.wipe]
        case .shine: [.sheen]
        case .bloomIn, .bloomOut, .bloomPulse: [.glow]
        }
    }

    /// Effects sampled over a curve, whose sample density the compiler's budget allocator may
    /// reduce when a document runs out of keyframes.
    public var isCyclic: Bool {
        switch self {
        case .wiggle, .pulse, .bounce, .float, .shine, .bloomPulse: true
        default: false
        }
    }
}

/// Declarative motion: a named effect with a delay and a duration, never an absolute timestamp.
///
/// This is the authoring vocabulary. Staggering eight layers is eight `delay` values, not forty
/// hand-computed keyframe times that have to stay consistent with the document's duration and its
/// keyframe budget. `AnimationCompiler` turns specs into the keyframes the renderer reads.
///
/// There is deliberately no generic `repeat`: the cyclic effects carry their own `cycles`/`bounces`
/// count, and a generic repeat would need a discontinuity at every cycle boundary that the
/// interpolator cannot express, since two keyframes cannot share a timestamp.
public struct AnimationSpec: Codable, Hashable, Sendable {
    public var effect: AnimationEffect
    public var delay: Double
    public var duration: Double
    public var easing: AnimatedEasing

    public init(_ effect: AnimationEffect, delay: Double = 0, duration: Double = 0.5, easing: AnimatedEasing = .easeInOut) {
        self.effect = effect
        self.delay = delay
        self.duration = duration
        self.easing = easing
    }

    public var type: AnimationEffectType { effect.type }
    public var channels: [AnimationChannel] { effect.type.channels }
    /// Total seconds this spec occupies, measured from t=0.
    public var endSeconds: Double { delay + duration }

    private enum CodingKeys: String, CodingKey {
        case type, delay, duration, easing
        case from, to, direction, distance, x, y, degrees, turns
        case amplitudeDegrees, cycles, minScale, maxScale, height, bounces, amplitude, radius
        case start, end, arcHeight
        case angleDegrees, softness, width, intensity
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        delay = try c.value(.delay, default: 0)
        duration = try c.value(.duration, default: 0.5)
        easing = try c.value(.easing, default: .easeInOut)
        switch try c.decode(AnimationEffectType.self, forKey: .type) {
        case .fadeIn: effect = .fadeIn
        case .fadeOut: effect = .fadeOut
        case .popIn: effect = .popIn(from: try c.value(.from, default: 0.6))
        case .popOut: effect = .popOut(to: try c.value(.to, default: 0.6))
        case .slideIn:
            effect = .slideIn(
                direction: try c.decode(AnimationDirection.self, forKey: .direction),
                distance: try c.value(.distance, default: 0.3)
            )
        case .slideOut:
            effect = .slideOut(
                direction: try c.decode(AnimationDirection.self, forKey: .direction),
                distance: try c.value(.distance, default: 0.3)
            )
        case .moveTo:
            effect = .moveTo(x: try c.decode(Double.self, forKey: .x), y: try c.decode(Double.self, forKey: .y))
        case .arcTo:
            effect = .arcTo(
                x: try c.decode(Double.self, forKey: .x),
                y: try c.decode(Double.self, forKey: .y),
                arcHeight: try c.value(.arcHeight, default: 0.25)
            )
        case .scaleTo:
            effect = .scaleTo(x: try c.decode(Double.self, forKey: .x), y: try c.decode(Double.self, forKey: .y))
        case .rotateTo:
            effect = .rotateTo(degrees: try c.decode(Double.self, forKey: .degrees))
        case .spin:
            effect = .spin(turns: try c.value(.turns, default: 1), direction: try c.value(.direction, default: .cw))
        case .wiggle:
            effect = .wiggle(
                amplitudeDegrees: try c.value(.amplitudeDegrees, default: 8),
                cycles: try c.value(.cycles, default: 3)
            )
        case .pulse:
            effect = .pulse(
                minScale: try c.value(.minScale, default: 0.92),
                maxScale: try c.value(.maxScale, default: 1.08),
                cycles: try c.value(.cycles, default: 3)
            )
        case .bounce:
            effect = .bounce(height: try c.value(.height, default: 0.12), bounces: try c.value(.bounces, default: 2))
        case .float:
            effect = .float(amplitude: try c.value(.amplitude, default: 0.04), cycles: try c.value(.cycles, default: 2))
        case .blurIn: effect = .blurIn(radius: try c.value(.radius, default: 8))
        case .blurOut: effect = .blurOut(radius: try c.value(.radius, default: 8))
        case .hueShift: effect = .hueShift(degrees: try c.decode(Double.self, forKey: .degrees))
        case .drawOn: effect = .drawOn(from: try c.value(.from, default: 0))
        case .drawOff: effect = .drawOff(to: try c.value(.to, default: 1))
        case .trimTo:
            effect = .trimTo(start: try c.value(.start, default: 0), end: try c.value(.end, default: 1))
        case .wipeIn:
            effect = .wipeIn(
                direction: try c.decode(AnimationDirection.self, forKey: .direction),
                softness: try c.value(.softness, default: 0)
            )
        case .wipeOut:
            effect = .wipeOut(
                direction: try c.decode(AnimationDirection.self, forKey: .direction),
                softness: try c.value(.softness, default: 0)
            )
        case .wipeTo:
            effect = .wipeTo(
                start: try c.value(.start, default: 0),
                end: try c.value(.end, default: 1),
                angleDegrees: try c.value(.angleDegrees, default: 0),
                softness: try c.value(.softness, default: 0)
            )
        case .shine:
            effect = .shine(
                angleDegrees: try c.value(.angleDegrees, default: -30),
                width: try c.value(.width, default: 0.25),
                intensity: try c.value(.intensity, default: 0.6),
                cycles: try c.value(.cycles, default: 1)
            )
        case .bloomIn:
            effect = .bloomIn(
                radius: try c.value(.radius, default: 0.08),
                intensity: try c.value(.intensity, default: 0.7)
            )
        case .bloomOut:
            effect = .bloomOut(
                radius: try c.value(.radius, default: 0.08),
                intensity: try c.value(.intensity, default: 0.7)
            )
        case .bloomPulse:
            effect = .bloomPulse(
                radius: try c.value(.radius, default: 0.08),
                intensity: try c.value(.intensity, default: 0.7),
                cycles: try c.value(.cycles, default: 2)
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(effect.type, forKey: .type)
        try c.encode(delay, forKey: .delay)
        try c.encode(duration, forKey: .duration)
        try c.encode(easing, forKey: .easing)
        switch effect {
        case .fadeIn, .fadeOut:
            break
        case .popIn(let from):
            try c.encode(from, forKey: .from)
        case .popOut(let to):
            try c.encode(to, forKey: .to)
        case .slideIn(let direction, let distance), .slideOut(let direction, let distance):
            try c.encode(direction, forKey: .direction)
            try c.encode(distance, forKey: .distance)
        case .moveTo(let x, let y), .scaleTo(let x, let y):
            try c.encode(x, forKey: .x)
            try c.encode(y, forKey: .y)
        case .arcTo(let x, let y, let arcHeight):
            try c.encode(x, forKey: .x)
            try c.encode(y, forKey: .y)
            try c.encode(arcHeight, forKey: .arcHeight)
        case .rotateTo(let degrees), .hueShift(let degrees):
            try c.encode(degrees, forKey: .degrees)
        case .spin(let turns, let direction):
            try c.encode(turns, forKey: .turns)
            try c.encode(direction, forKey: .direction)
        case .wiggle(let amplitudeDegrees, let cycles):
            try c.encode(amplitudeDegrees, forKey: .amplitudeDegrees)
            try c.encode(cycles, forKey: .cycles)
        case .pulse(let minScale, let maxScale, let cycles):
            try c.encode(minScale, forKey: .minScale)
            try c.encode(maxScale, forKey: .maxScale)
            try c.encode(cycles, forKey: .cycles)
        case .bounce(let height, let bounces):
            try c.encode(height, forKey: .height)
            try c.encode(bounces, forKey: .bounces)
        case .float(let amplitude, let cycles):
            try c.encode(amplitude, forKey: .amplitude)
            try c.encode(cycles, forKey: .cycles)
        case .blurIn(let radius), .blurOut(let radius):
            try c.encode(radius, forKey: .radius)
        case .drawOn(let from):
            try c.encode(from, forKey: .from)
        case .drawOff(let to):
            try c.encode(to, forKey: .to)
        case .trimTo(let start, let end):
            try c.encode(start, forKey: .start)
            try c.encode(end, forKey: .end)
        case .wipeIn(let direction, let softness), .wipeOut(let direction, let softness):
            try c.encode(direction, forKey: .direction)
            try c.encode(softness, forKey: .softness)
        case .wipeTo(let start, let end, let angleDegrees, let softness):
            try c.encode(start, forKey: .start)
            try c.encode(end, forKey: .end)
            try c.encode(angleDegrees, forKey: .angleDegrees)
            try c.encode(softness, forKey: .softness)
        case .shine(let angleDegrees, let width, let intensity, let cycles):
            try c.encode(angleDegrees, forKey: .angleDegrees)
            try c.encode(width, forKey: .width)
            try c.encode(intensity, forKey: .intensity)
            try c.encode(cycles, forKey: .cycles)
        case .bloomIn(let radius, let intensity), .bloomOut(let radius, let intensity):
            try c.encode(radius, forKey: .radius)
            try c.encode(intensity, forKey: .intensity)
        case .bloomPulse(let radius, let intensity, let cycles):
            try c.encode(radius, forKey: .radius)
            try c.encode(intensity, forKey: .intensity)
            try c.encode(cycles, forKey: .cycles)
        }
    }
}

// MARK: - Authoring shorthands

extension AnimationSpec {
    public static func fadeIn(delay: Double = 0, duration: Double = 0.5, easing: AnimatedEasing = .easeInOut) -> Self {
        .init(.fadeIn, delay: delay, duration: duration, easing: easing)
    }

    public static func fadeOut(delay: Double = 0, duration: Double = 0.5, easing: AnimatedEasing = .easeInOut) -> Self {
        .init(.fadeOut, delay: delay, duration: duration, easing: easing)
    }

    public static func popIn(from: Double = 0.6, delay: Double = 0, duration: Double = 0.5, easing: AnimatedEasing = .springBouncy) -> Self {
        .init(.popIn(from: from), delay: delay, duration: duration, easing: easing)
    }

    public static func slideIn(_ direction: AnimationDirection, distance: Double = 0.3, delay: Double = 0, duration: Double = 0.5, easing: AnimatedEasing = .easeOut) -> Self {
        .init(.slideIn(direction: direction, distance: distance), delay: delay, duration: duration, easing: easing)
    }

    /// Defaults to `linear`, unlike the other shorthands: the arc's own geometry already supplies
    /// the slow-at-the-apex feel, and a linear parameter over a parabola is exactly what a thrown
    /// object does. Reach for `easeOut` to lob something that settles into its landing.
    public static func arcTo(x: Double, y: Double, arcHeight: Double = 0.25, delay: Double = 0, duration: Double = 0.8, easing: AnimatedEasing = .linear) -> Self {
        .init(.arcTo(x: x, y: y, arcHeight: arcHeight), delay: delay, duration: duration, easing: easing)
    }

    public static func spin(turns: Double = 1, direction: AnimationSpinDirection = .cw, delay: Double = 0, duration: Double = 1, easing: AnimatedEasing = .easeInOut) -> Self {
        .init(.spin(turns: turns, direction: direction), delay: delay, duration: duration, easing: easing)
    }

    public static func wiggle(amplitudeDegrees: Double = 8, cycles: Int = 3, delay: Double = 0, duration: Double = 1, easing: AnimatedEasing = .easeInOut) -> Self {
        .init(.wiggle(amplitudeDegrees: amplitudeDegrees, cycles: cycles), delay: delay, duration: duration, easing: easing)
    }

    public static func pulse(minScale: Double = 0.92, maxScale: Double = 1.08, cycles: Int = 3, delay: Double = 0, duration: Double = 1.5, easing: AnimatedEasing = .easeInOut) -> Self {
        .init(.pulse(minScale: minScale, maxScale: maxScale, cycles: cycles), delay: delay, duration: duration, easing: easing)
    }

    public static func bounce(height: Double = 0.12, bounces: Int = 2, delay: Double = 0, duration: Double = 1, easing: AnimatedEasing = .easeOut) -> Self {
        .init(.bounce(height: height, bounces: bounces), delay: delay, duration: duration, easing: easing)
    }

    public static func float(amplitude: Double = 0.04, cycles: Int = 2, delay: Double = 0, duration: Double = 2, easing: AnimatedEasing = .easeInOut) -> Self {
        .init(.float(amplitude: amplitude, cycles: cycles), delay: delay, duration: duration, easing: easing)
    }

    public static func drawOn(from: Double = 0, delay: Double = 0, duration: Double = 1, easing: AnimatedEasing = .easeInOut) -> Self {
        .init(.drawOn(from: from), delay: delay, duration: duration, easing: easing)
    }

    public static func drawOff(to: Double = 1, delay: Double = 0, duration: Double = 1, easing: AnimatedEasing = .easeInOut) -> Self {
        .init(.drawOff(to: to), delay: delay, duration: duration, easing: easing)
    }

    /// Defaults to `easeOut`: a reveal that decelerates into place reads as deliberate, where a
    /// linear wipe reads as a scanline.
    public static func wipeIn(_ direction: AnimationDirection, softness: Double = 0, delay: Double = 0, duration: Double = 0.6, easing: AnimatedEasing = .easeOut) -> Self {
        .init(.wipeIn(direction: direction, softness: softness), delay: delay, duration: duration, easing: easing)
    }

    public static func wipeOut(_ direction: AnimationDirection, softness: Double = 0, delay: Double = 0, duration: Double = 0.6, easing: AnimatedEasing = .easeIn) -> Self {
        .init(.wipeOut(direction: direction, softness: softness), delay: delay, duration: duration, easing: easing)
    }

    /// `easing` is accepted for symmetry but never reaches the keyframes: see ``AnimationEffect/shine(angleDegrees:width:intensity:cycles:)``.
    public static func shine(angleDegrees: Double = -30, width: Double = 0.25, intensity: Double = 0.6, cycles: Int = 1, delay: Double = 0, duration: Double = 1, easing: AnimatedEasing = .linear) -> Self {
        .init(
            .shine(angleDegrees: angleDegrees, width: width, intensity: intensity, cycles: cycles),
            delay: delay,
            duration: duration,
            easing: easing
        )
    }

    public static func bloomIn(radius: Double = 0.08, intensity: Double = 0.7, delay: Double = 0, duration: Double = 0.6, easing: AnimatedEasing = .easeOut) -> Self {
        .init(.bloomIn(radius: radius, intensity: intensity), delay: delay, duration: duration, easing: easing)
    }

    public static func bloomOut(radius: Double = 0.08, intensity: Double = 0.7, delay: Double = 0, duration: Double = 0.6, easing: AnimatedEasing = .easeIn) -> Self {
        .init(.bloomOut(radius: radius, intensity: intensity), delay: delay, duration: duration, easing: easing)
    }

    public static func bloomPulse(radius: Double = 0.08, intensity: Double = 0.7, cycles: Int = 2, delay: Double = 0, duration: Double = 1.5, easing: AnimatedEasing = .easeInOut) -> Self {
        .init(
            .bloomPulse(radius: radius, intensity: intensity, cycles: cycles),
            delay: delay,
            duration: duration,
            easing: easing
        )
    }
}
