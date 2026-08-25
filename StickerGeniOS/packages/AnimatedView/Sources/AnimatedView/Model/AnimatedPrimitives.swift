import Foundation

/// A point in the document's normalized coordinate space, where `(0, 0)` is the top-left of the
/// canvas and `(1, 1)` is the bottom-right.
///
/// Normalized rather than absolute so a document renders identically at any size — the same
/// contract the v1 sticker document used, and the reason `AnimatedCanvas` can carry a size at all.
public struct AnimatedPoint: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    public static let center = AnimatedPoint(x: 0.5, y: 0.5)
    public static let zero = AnimatedPoint(x: 0, y: 0)
    public static let unit = AnimatedPoint(x: 1, y: 1)
}

/// One stop in a gradient, positioned along the gradient's axis in `0...1`.
public struct AnimatedGradientStop: Codable, Hashable, Sendable {
    /// `#RRGGBB` or `#RRGGBBAA`.
    public var color: String
    public var location: Double

    public init(color: String, location: Double) {
        self.color = color
        self.location = location
    }

    public var isValid: Bool { color.isAnimatedHexColor && (0...1).contains(location) }
}

/// Decoding here is deliberately lenient about missing keys that carry a default.
///
/// The zod contract applies every `.default()` before it serializes, so a document that came from
/// the server is always complete. Hand-written Swift documents, preview fixtures, and upcast v1
/// payloads are not, and Swift's synthesized `init(from:)` ignores property default values — it
/// would reject all three. Encoding stays exhaustive so what this package writes is always a
/// complete document.
extension KeyedDecodingContainer {
    func value<T: Decodable>(_ key: Key, default fallback: T) throws -> T {
        try decodeIfPresent(T.self, forKey: key) ?? fallback
    }
}

extension String {
    /// `#RRGGBB` or `#RRGGBBAA`, matching the server's `HexColorSchema`.
    public var isAnimatedHexColor: Bool {
        range(of: "^#[0-9A-Fa-f]{6}([0-9A-Fa-f]{2})?$", options: .regularExpression) != nil
    }

    var isAnimatedLayerID: Bool {
        range(of: "^[A-Za-z0-9_-]{1,64}$", options: .regularExpression) != nil
    }

    var isAnimatedUUID: Bool { UUID(uuidString: self) != nil }
}
