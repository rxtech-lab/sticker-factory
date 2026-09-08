import Foundation

/// A vector primitive drawn in the layer's fit box.
///
/// The first seven cases are the v1 sticker shapes plus the two obvious omissions (`capsule`,
/// `triangle`) and a general `polygon`. `path` is the escape hatch: it takes SVG path data, so a
/// caller who wants "here is a path, draw it" does not need a whole SVG document to do it.
public enum AnimatedShapeKind: Codable, Hashable, Sendable {
    case circle
    case roundedRectangle
    case capsule
    case triangle
    case star(points: Int, innerRatio: Double)
    case heart
    case burst
    case polygon(sides: Int)
    /// SVG path data, parsed by the same reader that handles `<path d="…">` inside an SVG document.
    case path(d: String)

    private enum CodingKeys: String, CodingKey { case kind, points, innerRatio, sides, d }
    private enum Kind: String, Codable {
        case circle, roundedRectangle, capsule, triangle, star, heart, burst, polygon, path
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .circle: self = .circle
        case .roundedRectangle: self = .roundedRectangle
        case .capsule: self = .capsule
        case .triangle: self = .triangle
        case .heart: self = .heart
        case .burst: self = .burst
        case .star:
            self = .star(
                points: try container.value(.points, default: 5),
                innerRatio: try container.value(.innerRatio, default: 0.42)
            )
        case .polygon:
            self = .polygon(sides: try container.value(.sides, default: 6))
        case .path:
            self = .path(d: try container.decode(String.self, forKey: .d))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .circle: try container.encode(Kind.circle, forKey: .kind)
        case .roundedRectangle: try container.encode(Kind.roundedRectangle, forKey: .kind)
        case .capsule: try container.encode(Kind.capsule, forKey: .kind)
        case .triangle: try container.encode(Kind.triangle, forKey: .kind)
        case .heart: try container.encode(Kind.heart, forKey: .kind)
        case .burst: try container.encode(Kind.burst, forKey: .kind)
        case .star(let points, let innerRatio):
            try container.encode(Kind.star, forKey: .kind)
            try container.encode(points, forKey: .points)
            try container.encode(innerRatio, forKey: .innerRatio)
        case .polygon(let sides):
            try container.encode(Kind.polygon, forKey: .kind)
            try container.encode(sides, forKey: .sides)
        case .path(let d):
            try container.encode(Kind.path, forKey: .kind)
            try container.encode(d, forKey: .d)
        }
    }

    /// The v1 five-pointed star, kept as a shorthand because it is by far the common case.
    ///
    /// Deliberately not named `star`: that would be ambiguous with the case's own unapplied
    /// `(Int, Double) -> AnimatedShapeKind` form.
    public static let fivePointStar = AnimatedShapeKind.star(points: 5, innerRatio: 0.42)

    public var isValid: Bool {
        switch self {
        case .star(let points, let innerRatio):
            (3...24).contains(points) && (0.05...1).contains(innerRatio)
        case .polygon(let sides):
            (3...24).contains(sides)
        case .path(let d):
            !d.isEmpty && d.count <= 20_000
        default:
            true
        }
    }

    /// Every case except `path` and `polygon`/`star` with non-default parameters, for previews and
    /// pickers that want to show the built-in vocabulary.
    public static let presets: [AnimatedShapeKind] = [
        .circle, .roundedRectangle, .capsule, .triangle, .fivePointStar, .heart, .burst, .polygon(sides: 6)
    ]
}

/// A normalized `from`/`to` window over a path's length, driving draw-on animation.
///
/// `start`/`end` mirror SwiftUI's `Shape.trim(from:to:)`. A layer's resting trim is `0...1` — the
/// whole path — so a layer with no trim keyframes looks exactly as it would without the feature.
public struct AnimatedTrim: Codable, Hashable, Sendable {
    public var start: Double
    public var end: Double

    public init(start: Double = 0, end: Double = 1) {
        self.start = start
        self.end = end
    }

    public static let full = AnimatedTrim()
    public static let empty = AnimatedTrim(start: 0, end: 0)

    private enum CodingKeys: String, CodingKey { case start, end }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        start = try container.value(.start, default: 0)
        end = try container.value(.end, default: 1)
    }

    public var isValid: Bool { (0...1).contains(start) && (0...1).contains(end) }
    public var isFull: Bool { start == 0 && end == 1 }
}
