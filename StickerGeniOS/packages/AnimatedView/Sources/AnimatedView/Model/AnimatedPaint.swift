import Foundation

/// How a shape, glyph, or SVG subpath is filled.
///
/// This replaces the single hex string that v1 layers carried. Gradients are part of the paint
/// rather than a layer kind of their own so that any fillable thing — a shape, a letter, a stroke,
/// an SVG path — can take one without the renderer growing a special case per combination.
public enum AnimatedPaint: Codable, Hashable, Sendable {
    case solid(String)
    case linearGradient(stops: [AnimatedGradientStop], angleDegrees: Double)
    case radialGradient(stops: [AnimatedGradientStop], center: AnimatedPoint, radius: Double)

    private enum CodingKeys: String, CodingKey { case type, color, stops, angleDegrees, center, radius }
    private enum Kind: String, Codable { case solid, linearGradient, radialGradient }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .type) {
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
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
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
        }
    }

    /// Two evenly spaced stops, which is how most gradients are authored.
    public static func linearGradient(_ from: String, _ to: String, angleDegrees: Double = 0) -> Self {
        .linearGradient(
            stops: [.init(color: from, location: 0), .init(color: to, location: 1)],
            angleDegrees: angleDegrees
        )
    }

    public static func radialGradient(_ inner: String, _ outer: String, radius: Double = 0.5) -> Self {
        .radialGradient(
            stops: [.init(color: inner, location: 0), .init(color: outer, location: 1)],
            center: .center,
            radius: radius
        )
    }

    public var isValid: Bool {
        switch self {
        case .solid(let color):
            color.isAnimatedHexColor
        case .linearGradient(let stops, let angle):
            stops.count >= 2 && stops.allSatisfy(\.isValid) && (-360...360).contains(angle)
        case .radialGradient(let stops, let center, let radius):
            stops.count >= 2 && stops.allSatisfy(\.isValid)
                && (-1...2).contains(center.x) && (-1...2).contains(center.y)
                && (0.01...4).contains(radius)
        }
    }

    /// The paint's representative color, used where a gradient cannot be expressed — particle
    /// glyphs and the MP4 background's `CGGradient` fallback.
    public var primaryColor: String {
        switch self {
        case .solid(let color): color
        case .linearGradient(let stops, _): stops.first?.color ?? "#000000"
        case .radialGradient(let stops, _, _): stops.first?.color ?? "#000000"
        }
    }
}

public enum AnimatedLineCap: String, Codable, CaseIterable, Hashable, Sendable {
    case butt, round, square
}

public enum AnimatedLineJoin: String, Codable, CaseIterable, Hashable, Sendable {
    case miter, round, bevel
}

/// An outline.
///
/// `width` is a fraction of the layer's fit box, not of the canvas and not in points — the same
/// convention `AnimatedShapeLayer.cornerRadius` uses. That way a stroke keeps its visual weight
/// whether the document renders at 64 pt or 2048 px, and an SVG layer's stroke override means the
/// same thing as a shape layer's regardless of the artwork's viewBox units.
public struct AnimatedStroke: Codable, Hashable, Sendable {
    public var paint: AnimatedPaint
    public var width: Double
    public var lineCap: AnimatedLineCap
    public var lineJoin: AnimatedLineJoin
    /// Dash lengths in normalized canvas units. Empty means a solid line.
    public var dash: [Double]

    public init(
        paint: AnimatedPaint,
        width: Double = 0.01,
        lineCap: AnimatedLineCap = .round,
        lineJoin: AnimatedLineJoin = .round,
        dash: [Double] = []
    ) {
        self.paint = paint
        self.width = width
        self.lineCap = lineCap
        self.lineJoin = lineJoin
        self.dash = dash
    }

    private enum CodingKeys: String, CodingKey { case paint, width, lineCap, lineJoin, dash }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        paint = try container.decode(AnimatedPaint.self, forKey: .paint)
        width = try container.value(.width, default: 0.01)
        lineCap = try container.value(.lineCap, default: .round)
        lineJoin = try container.value(.lineJoin, default: .round)
        dash = try container.value(.dash, default: [])
    }

    public var isValid: Bool {
        paint.isValid && (0...0.5).contains(width) && dash.allSatisfy { (0...2).contains($0) }
    }
}
