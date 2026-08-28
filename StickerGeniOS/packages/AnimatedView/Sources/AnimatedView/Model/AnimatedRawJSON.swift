import Foundation

/// An arbitrary JSON value, decoded and re-encoded without interpretation.
///
/// This exists for exactly one job: letting `AnimatedUnsupportedLayer` carry a layer this build does
/// not understand through a decode/encode round trip byte for byte. A client that dropped such a
/// layer on save would silently delete the user's work the first time they opened a document
/// authored by a newer build and touched anything.
///
/// Deliberately not a general-purpose helper. It has no subscripting, no conversions, and no
/// pretty-printing, because nothing should be reading values back out of it — the moment something
/// wants to, that layer kind deserves a real type.
public enum AnimatedRawJSON: Codable, Hashable, Sendable {
    case null
    case bool(Bool)
    /// JSON has one number type. Keeping it as `Double` means `12` re-encodes as `12`, not `12.0`,
    /// because `JSONEncoder` writes a whole `Double` without a fractional part.
    case number(Double)
    case string(String)
    case array([AnimatedRawJSON])
    case object([String: AnimatedRawJSON])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([AnimatedRawJSON].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: AnimatedRawJSON].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unrepresentable JSON value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}
