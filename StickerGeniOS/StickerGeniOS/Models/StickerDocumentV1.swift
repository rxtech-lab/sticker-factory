import AnimatedView
import Foundation

/// The API-level enums that outlive the document contract.
///
/// The document itself now comes from the `AnimatedView` package as `AnimatedDocument`: the app
/// used to carry a hand-written mirror of the server's zod schema, and keeping two implementations
/// of one contract in step is exactly how the two renderers were drifting. These three types stay
/// because they describe the *API*, not the document — a sticker project has a kind, an export
/// request carries an MP4 background — and they are used in places no document is involved.
nonisolated enum StickerKind: String, Codable, CaseIterable, Hashable, Sendable, Identifiable {
    case `static`
    case animated
    var id: Self { self }
    var label: String { self == .static ? "Static" : "Animated" }
    var symbol: String { self == .static ? "photo" : "sparkles.rectangle.stack" }

    /// The document's own spelling of the same distinction.
    var animatedKind: AnimatedKind { self == .static ? .static : .animated }

    init(_ kind: AnimatedKind) { self = kind == .static ? .static : .animated }
}

nonisolated enum StickerLoopBehavior: String, Codable, CaseIterable, Hashable, Sendable {
    case once, loop, pingPong

    var animatedLoop: AnimatedLoop {
        switch self {
        case .once: .once
        case .loop: .loop
        case .pingPong: .pingPong
        }
    }
}

/// The background an export request asks the server to bake behind an MP4.
///
/// Deliberately still its own type rather than `AnimatedBackground`: the wire shape the server
/// accepts for this field is unchanged — a solid colour or a two-colour linear gradient — and it is
/// a property of the *export*, chosen at publish time, not of the artwork.
nonisolated enum StickerMP4BackgroundV1: Codable, Hashable, Sendable {
    case solid(String)
    case linearGradient(colors: [String], angleDegrees: Double)

    private enum CodingKeys: String, CodingKey { case type, color, colors, angleDegrees }
    private enum Kind: String, Codable { case solid, linearGradient }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .type) {
        case .solid:
            self = .solid(try container.decode(String.self, forKey: .color))
        case .linearGradient:
            let colors = try container.decode([String].self, forKey: .colors)
            guard colors.count == 2 else {
                throw DecodingError.dataCorruptedError(
                    forKey: .colors, in: container, debugDescription: "A linear gradient requires two colors"
                )
            }
            self = .linearGradient(colors: colors, angleDegrees: try container.decode(Double.self, forKey: .angleDegrees))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .solid(let color):
            try container.encode(Kind.solid, forKey: .type)
            try container.encode(color, forKey: .color)
        case .linearGradient(let colors, let angleDegrees):
            try container.encode(Kind.linearGradient, forKey: .type)
            try container.encode(colors, forKey: .colors)
            try container.encode(angleDegrees, forKey: .angleDegrees)
        }
    }

    var isValid: Bool {
        switch self {
        case .solid(let color): color.isAnimatedHexColor
        case .linearGradient(let colors, let angle):
            colors.count == 2 && colors.allSatisfy(\.isAnimatedHexColor) && (0...360).contains(angle)
        }
    }

    /// The document-level equivalent, for rendering a frame against this background.
    var animatedBackground: AnimatedBackground {
        switch self {
        case .solid(let color):
            .solid(color)
        case .linearGradient(let colors, let angleDegrees):
            .linearGradient(colors[0], colors[1], angleDegrees: angleDegrees)
        }
    }

    /// The export request's spelling of a document's MP4 background.
    ///
    /// Returns `nil` for the shapes the request cannot express — a radial gradient, an image, or
    /// `none` — so a caller has to decide what to send rather than silently shipping the wrong fill.
    init?(_ background: AnimatedBackground) {
        switch background {
        case .solid(let color):
            self = .solid(color)
        case .linearGradient(let stops, let angleDegrees) where stops.count >= 2:
            self = .linearGradient(
                colors: [stops.first!.color, stops.last!.color],
                angleDegrees: min(max(angleDegrees, 0), 360)
            )
        default:
            return nil
        }
    }
}

nonisolated enum StickerDocumentValidationError: Error, Equatable, LocalizedError {
    case unsupportedVersion(Int)

    var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let version):
            "This sticker was made with a newer version of the app (document version \(version))."
        }
    }
}
