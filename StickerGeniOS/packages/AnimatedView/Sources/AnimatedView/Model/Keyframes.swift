import Foundation

public enum AnimatedEasing: String, Codable, CaseIterable, Hashable, Sendable {
    case linear, easeIn, easeOut, easeInOut, springSoft, springBouncy
}

/// A keyframe's shared shape.
///
/// `easing` governs the segment *ending* at this keyframe. The interpolator reads easing from the
/// upper keyframe of the pair it is blending, so easing on the first keyframe of a channel is never
/// used — the compiler relies on that when it emits `start`/`end` pairs.
public protocol AnimatedTimedKeyframe: Sendable {
    var timeSeconds: Double { get }
    var easing: AnimatedEasing { get }
}

public struct PositionKeyframe: Codable, Hashable, Sendable, AnimatedTimedKeyframe {
    public var timeSeconds: Double
    public var x: Double
    public var y: Double
    public var easing: AnimatedEasing

    public init(timeSeconds: Double, x: Double, y: Double, easing: AnimatedEasing = .linear) {
        self.timeSeconds = timeSeconds
        self.x = x
        self.y = y
        self.easing = easing
    }

    private enum CodingKeys: String, CodingKey { case timeSeconds, x, y, easing }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        timeSeconds = try container.decode(Double.self, forKey: .timeSeconds)
        x = try container.decode(Double.self, forKey: .x)
        y = try container.decode(Double.self, forKey: .y)
        easing = try container.value(.easing, default: .linear)
    }
}

public struct ScaleKeyframe: Codable, Hashable, Sendable, AnimatedTimedKeyframe {
    public var timeSeconds: Double
    public var x: Double
    public var y: Double
    public var easing: AnimatedEasing

    public init(timeSeconds: Double, x: Double, y: Double, easing: AnimatedEasing = .linear) {
        self.timeSeconds = timeSeconds
        self.x = x
        self.y = y
        self.easing = easing
    }

    private enum CodingKeys: String, CodingKey { case timeSeconds, x, y, easing }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        timeSeconds = try container.decode(Double.self, forKey: .timeSeconds)
        x = try container.decode(Double.self, forKey: .x)
        y = try container.decode(Double.self, forKey: .y)
        easing = try container.value(.easing, default: .linear)
    }
}

public struct RotationKeyframe: Codable, Hashable, Sendable, AnimatedTimedKeyframe {
    public var timeSeconds: Double
    public var degrees: Double
    public var easing: AnimatedEasing

    public init(timeSeconds: Double, degrees: Double, easing: AnimatedEasing = .linear) {
        self.timeSeconds = timeSeconds
        self.degrees = degrees
        self.easing = easing
    }

    private enum CodingKeys: String, CodingKey { case timeSeconds, degrees, easing }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        timeSeconds = try container.decode(Double.self, forKey: .timeSeconds)
        degrees = try container.decode(Double.self, forKey: .degrees)
        easing = try container.value(.easing, default: .linear)
    }
}

public struct OpacityKeyframe: Codable, Hashable, Sendable, AnimatedTimedKeyframe {
    public var timeSeconds: Double
    public var value: Double
    public var easing: AnimatedEasing

    public init(timeSeconds: Double, value: Double, easing: AnimatedEasing = .linear) {
        self.timeSeconds = timeSeconds
        self.value = value
        self.easing = easing
    }

    private enum CodingKeys: String, CodingKey { case timeSeconds, value, easing }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        timeSeconds = try container.decode(Double.self, forKey: .timeSeconds)
        value = try container.decode(Double.self, forKey: .value)
        easing = try container.value(.easing, default: .linear)
    }
}

public struct EffectKeyframe: Codable, Hashable, Sendable, AnimatedTimedKeyframe {
    public var timeSeconds: Double
    public var blurRadius: Double
    public var hueDegrees: Double
    public var saturation: Double
    public var easing: AnimatedEasing

    public init(
        timeSeconds: Double,
        blurRadius: Double = 0,
        hueDegrees: Double = 0,
        saturation: Double = 1,
        easing: AnimatedEasing = .linear
    ) {
        self.timeSeconds = timeSeconds
        self.blurRadius = blurRadius
        self.hueDegrees = hueDegrees
        self.saturation = saturation
        self.easing = easing
    }

    private enum CodingKeys: String, CodingKey { case timeSeconds, blurRadius, hueDegrees, saturation, easing }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        timeSeconds = try container.decode(Double.self, forKey: .timeSeconds)
        blurRadius = try container.value(.blurRadius, default: 0)
        hueDegrees = try container.value(.hueDegrees, default: 0)
        saturation = try container.value(.saturation, default: 1)
        easing = try container.value(.easing, default: .linear)
    }
}

/// The channel that makes "give it a path and draw it" work.
///
/// `start`/`end` are fractions of a path's total length, so a `0 → 1` sweep of `end` is a stroke
/// drawing itself on. Layers with no geometry to trim — images, particles — ignore it.
public struct TrimKeyframe: Codable, Hashable, Sendable, AnimatedTimedKeyframe {
    public var timeSeconds: Double
    public var start: Double
    public var end: Double
    public var easing: AnimatedEasing

    public init(timeSeconds: Double, start: Double = 0, end: Double = 1, easing: AnimatedEasing = .linear) {
        self.timeSeconds = timeSeconds
        self.start = start
        self.end = end
        self.easing = easing
    }

    private enum CodingKeys: String, CodingKey { case timeSeconds, start, end, easing }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        timeSeconds = try container.decode(Double.self, forKey: .timeSeconds)
        start = try container.value(.start, default: 0)
        end = try container.value(.end, default: 1)
        easing = try container.value(.easing, default: .linear)
    }
}

/// The six independent tracks a layer's motion is expressed on.
///
/// Compiled output only. When a layer carries declarative `animations`, this is derived from them
/// by `AnimationCompiler` and must not be hand-edited — the server rejects a document whose two
/// representations disagree.
public struct AnimatedLayerAnimation: Codable, Hashable, Sendable {
    public static let maximumKeyframesPerChannel = 32

    public var position: [PositionKeyframe]
    public var scale: [ScaleKeyframe]
    public var rotation: [RotationKeyframe]
    public var opacity: [OpacityKeyframe]
    public var effects: [EffectKeyframe]
    public var trim: [TrimKeyframe]

    public init(
        position: [PositionKeyframe] = [],
        scale: [ScaleKeyframe] = [],
        rotation: [RotationKeyframe] = [],
        opacity: [OpacityKeyframe] = [],
        effects: [EffectKeyframe] = [],
        trim: [TrimKeyframe] = []
    ) {
        self.position = position
        self.scale = scale
        self.rotation = rotation
        self.opacity = opacity
        self.effects = effects
        self.trim = trim
    }

    public static let empty = AnimatedLayerAnimation()

    private enum CodingKeys: String, CodingKey { case position, scale, rotation, opacity, effects, trim }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        position = try container.value(.position, default: [])
        scale = try container.value(.scale, default: [])
        rotation = try container.value(.rotation, default: [])
        opacity = try container.value(.opacity, default: [])
        effects = try container.value(.effects, default: [])
        trim = try container.value(.trim, default: [])
    }

    public var isEmpty: Bool {
        position.isEmpty && scale.isEmpty && rotation.isEmpty
            && opacity.isEmpty && effects.isEmpty && trim.isEmpty
    }

    public var allKeyframes: [any AnimatedTimedKeyframe] {
        position.map { $0 as any AnimatedTimedKeyframe }
            + scale.map { $0 as any AnimatedTimedKeyframe }
            + rotation.map { $0 as any AnimatedTimedKeyframe }
            + opacity.map { $0 as any AnimatedTimedKeyframe }
            + effects.map { $0 as any AnimatedTimedKeyframe }
            + trim.map { $0 as any AnimatedTimedKeyframe }
    }

    public var keyframeCount: Int {
        position.count + scale.count + rotation.count + opacity.count + effects.count + trim.count
    }

    public var isValid: Bool {
        let cap = Self.maximumKeyframesPerChannel
        guard position.count <= cap, scale.count <= cap, rotation.count <= cap,
              opacity.count <= cap, effects.count <= cap, trim.count <= cap
        else { return false }
        return position.allSatisfy { (-1...2).contains($0.x) && (-1...2).contains($0.y) }
            && scale.allSatisfy { (0.05...8).contains($0.x) && (0.05...8).contains($0.y) }
            && rotation.allSatisfy { (-3600...3600).contains($0.degrees) }
            && opacity.allSatisfy { (0...1).contains($0.value) }
            && effects.allSatisfy {
                (0...20).contains($0.blurRadius) && (-180...180).contains($0.hueDegrees)
                    && (0...2).contains($0.saturation)
            }
            && trim.allSatisfy { (0...1).contains($0.start) && (0...1).contains($0.end) }
            && allKeyframes.allSatisfy { $0.timeSeconds >= 0 }
    }
}

/// The five-plus-one channel names, matching `AnimatedLayerAnimation`'s keys exactly.
public enum AnimationChannel: String, CaseIterable, Hashable, Sendable {
    case position, scale, rotation, opacity, effects, trim
}
