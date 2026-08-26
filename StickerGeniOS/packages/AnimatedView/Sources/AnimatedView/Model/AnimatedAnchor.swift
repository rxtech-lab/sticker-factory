import Foundation

/// The layer's resting state, which declarative animations depart from and return to.
///
/// Stored rather than inferred because the compiler has to be able to rebuild a layer's keyframes
/// from its specs alone; reading the anchor back out of already-compiled keyframes would be
/// circular. The defaults are exactly the values `AnimationInterpolator` falls back to for an empty
/// channel, which is what lets the compiler skip emitting an anchor keyframe for an undisturbed one.
public struct AnimatedAnchor: Codable, Hashable, Sendable {
    public var position: AnimatedPoint
    public var scale: AnimatedPoint
    public var rotationDegrees: Double
    public var opacity: Double
    public var trim: AnimatedTrim

    public init(
        position: AnimatedPoint = .center,
        scale: AnimatedPoint = .unit,
        rotationDegrees: Double = 0,
        opacity: Double = 1,
        trim: AnimatedTrim = .full
    ) {
        self.position = position
        self.scale = scale
        self.rotationDegrees = rotationDegrees
        self.opacity = opacity
        self.trim = trim
    }

    public static let `default` = AnimatedAnchor()

    private enum CodingKeys: String, CodingKey { case position, scale, rotationDegrees, opacity, trim }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        position = try container.value(.position, default: .center)
        scale = try container.value(.scale, default: .unit)
        rotationDegrees = try container.value(.rotationDegrees, default: 0)
        opacity = try container.value(.opacity, default: 1)
        trim = try container.value(.trim, default: .full)
    }

    public var isValid: Bool {
        (-1...2).contains(position.x) && (-1...2).contains(position.y)
            && (0.05...8).contains(scale.x) && (0.05...8).contains(scale.y)
            && (-3600...3600).contains(rotationDegrees)
            && (0...1).contains(opacity)
            && trim.isValid
    }
}
