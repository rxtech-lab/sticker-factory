import Foundation

public enum AnimatedContentMode: String, Codable, CaseIterable, Hashable, Sendable {
    case fit, fill
}

/// What sits behind the layer stack.
///
/// Two backgrounds exist on a document and they are not interchangeable. `AnimatedDocument.background`
/// is part of the artwork and renders into every output including the transparent ones, which is why
/// it defaults to `.none` — a sticker is transparent unless the author says otherwise.
/// `AnimatedDocument.mp4Background` only fills the alpha when an output format cannot carry it.
public enum AnimatedBackground: Codable, Hashable, Sendable {
    case none
    case solid(String)
    case linearGradient(stops: [AnimatedGradientStop], angleDegrees: Double)
    case radialGradient(stops: [AnimatedGradientStop], center: AnimatedPoint, radius: Double)
    case image(assetId: String, contentMode: AnimatedContentMode)

    private enum CodingKeys: String, CodingKey {
        case type, color, stops, angleDegrees, center, radius, assetId, contentMode
    }
    private enum Kind: String, Codable { case none, solid, linearGradient, radialGradient, image }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .type) {
        case .none:
            self = .none
        case .solid:
            self = .solid(try container.decode(String.self, forKey: .color))
        case .linearGradient:
            self = .linearGradient(
                stops: try container.decode([AnimatedGradientStop].self, forKey: .stops),
                angleDegrees: try container.value(.angleDegrees, default: 0)
            )
        case .radialGradient:
            self = .radialGradient(
                stops: try container.decode([AnimatedGradientStop].self, forKey: .stops),
                center: try container.value(.center, default: .center),
                radius: try container.value(.radius, default: 0.5)
            )
        case .image:
            self = .image(
                assetId: try container.decode(String.self, forKey: .assetId),
                contentMode: try container.value(.contentMode, default: .fill)
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .none:
            try container.encode(Kind.none, forKey: .type)
        case .solid(let color):
            try container.encode(Kind.solid, forKey: .type)
            try container.encode(color, forKey: .color)
        case .linearGradient(let stops, let angleDegrees):
            try container.encode(Kind.linearGradient, forKey: .type)
            try container.encode(stops, forKey: .stops)
            try container.encode(angleDegrees, forKey: .angleDegrees)
        case .radialGradient(let stops, let center, let radius):
            try container.encode(Kind.radialGradient, forKey: .type)
            try container.encode(stops, forKey: .stops)
            try container.encode(center, forKey: .center)
            try container.encode(radius, forKey: .radius)
        case .image(let assetId, let contentMode):
            try container.encode(Kind.image, forKey: .type)
            try container.encode(assetId, forKey: .assetId)
            try container.encode(contentMode, forKey: .contentMode)
        }
    }

    public static func linearGradient(_ from: String, _ to: String, angleDegrees: Double = 0) -> Self {
        .linearGradient(
            stops: [.init(color: from, location: 0), .init(color: to, location: 1)],
            angleDegrees: angleDegrees
        )
    }

    /// The paint equivalent, or `nil` for `.none` and `.image` which paint cannot express.
    public var paint: AnimatedPaint? {
        switch self {
        case .none, .image: nil
        case .solid(let color): .solid(color)
        case .linearGradient(let stops, let angle): .linearGradient(stops: stops, angleDegrees: angle)
        case .radialGradient(let stops, let center, let radius):
            .radialGradient(stops: stops, center: center, radius: radius)
        }
    }

    public var isValid: Bool {
        switch self {
        case .none: true
        case .image(let assetId, _): assetId.isAnimatedUUID
        default: paint?.isValid ?? false
        }
    }

    /// Whether this background makes the canvas fully opaque, which the exporter uses to decide
    /// whether an alpha-carrying format is still worth it.
    public var isOpaque: Bool {
        switch self {
        case .none: false
        case .solid(let color): color.count == 7
        case .linearGradient(let stops, _), .radialGradient(let stops, _, _):
            stops.allSatisfy { $0.color.count == 7 }
        case .image: false
        }
    }
}
