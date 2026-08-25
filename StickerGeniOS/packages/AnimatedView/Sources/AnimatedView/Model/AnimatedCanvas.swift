import CoreGraphics
import Foundation

/// The document's intrinsic pixel size and alpha expectation.
///
/// v1 pinned this to exactly 1024×1024. It is a real, validated range here so the same engine can
/// drive a 64 pt toolbar glyph and a 2048 px export without a second contract.
public struct AnimatedCanvas: Codable, Hashable, Sendable {
    public static let minimumDimension = 16
    public static let maximumDimension = 4096

    public var width: Int
    public var height: Int
    /// Always `"normalized"`. Carried on the wire so a future absolute-coordinate document is
    /// distinguishable rather than silently misread.
    public var coordinateSpace: String
    public var transparent: Bool

    public init(width: Int = 1024, height: Int = 1024, coordinateSpace: String = "normalized", transparent: Bool = true) {
        self.width = width
        self.height = height
        self.coordinateSpace = coordinateSpace
        self.transparent = transparent
    }

    public init(square dimension: Int, transparent: Bool = true) {
        self.init(width: dimension, height: dimension, transparent: transparent)
    }

    private enum CodingKeys: String, CodingKey { case width, height, coordinateSpace, transparent }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        width = try container.value(.width, default: 1024)
        height = try container.value(.height, default: 1024)
        coordinateSpace = try container.value(.coordinateSpace, default: "normalized")
        transparent = try container.value(.transparent, default: true)
    }

    public var size: CGSize { CGSize(width: width, height: height) }
    public var aspectRatio: Double { Double(width) / Double(height) }

    public var isValid: Bool {
        (Self.minimumDimension...Self.maximumDimension).contains(width)
            && (Self.minimumDimension...Self.maximumDimension).contains(height)
            && coordinateSpace == "normalized"
    }
}

public enum AnimatedKind: String, Codable, CaseIterable, Hashable, Sendable, Identifiable {
    case `static`
    case animated

    public var id: Self { self }
    public var label: String { self == .static ? "Static" : "Animated" }
    public var symbol: String { self == .static ? "photo" : "sparkles.rectangle.stack" }
}

public enum AnimatedLoop: String, Codable, CaseIterable, Hashable, Sendable {
    case once, loop, pingPong
}

public enum AnimatedBlendMode: String, Codable, CaseIterable, Hashable, Sendable {
    case normal, multiply, screen, overlay, softLight, hardLight, difference, plusLighter
}
