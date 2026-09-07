import Foundation

/// Just enough EBML to write a WebM file: element ids, variable-length sizes, and the handful of
/// payload types a video-only Matroska segment needs.
///
/// Matroska sizes are written at their minimal length. Every element is assembled in memory
/// before its parent, which is fine here — a Telegram video sticker is capped at 256 KB and a
/// WhatsApp one is never muxed at all — and it keeps the writer free of the "unknown size" and
/// seek-back tricks a streaming muxer needs.
enum EBML {
    /// The ids used by this writer, as their raw big-endian byte form (ids carry their own
    /// length marker, so they are written verbatim rather than as vints).
    enum ID {
        static let header: [UInt8] = [0x1A, 0x45, 0xDF, 0xA3]
        static let version: [UInt8] = [0x42, 0x86]
        static let readVersion: [UInt8] = [0x42, 0xF7]
        static let maxIDLength: [UInt8] = [0x42, 0xF2]
        static let maxSizeLength: [UInt8] = [0x42, 0xF3]
        static let docType: [UInt8] = [0x42, 0x82]
        static let docTypeVersion: [UInt8] = [0x42, 0x87]
        static let docTypeReadVersion: [UInt8] = [0x42, 0x85]

        static let segment: [UInt8] = [0x18, 0x53, 0x80, 0x67]
        static let info: [UInt8] = [0x15, 0x49, 0xA9, 0x66]
        static let timecodeScale: [UInt8] = [0x2A, 0xD7, 0xB1]
        static let duration: [UInt8] = [0x44, 0x89]
        static let muxingApp: [UInt8] = [0x4D, 0x80]
        static let writingApp: [UInt8] = [0x57, 0x41]

        static let tracks: [UInt8] = [0x16, 0x54, 0xAE, 0x6B]
        static let trackEntry: [UInt8] = [0xAE]
        static let trackNumber: [UInt8] = [0xD7]
        static let trackUID: [UInt8] = [0x73, 0xC5]
        static let trackType: [UInt8] = [0x83]
        static let flagLacing: [UInt8] = [0x9C]
        static let codecID: [UInt8] = [0x86]
        static let language: [UInt8] = [0x22, 0xB5, 0x9C]
        static let video: [UInt8] = [0xE0]
        static let pixelWidth: [UInt8] = [0xB0]
        static let pixelHeight: [UInt8] = [0xBA]
        static let alphaMode: [UInt8] = [0x53, 0xC0]

        static let cluster: [UInt8] = [0x1F, 0x43, 0xB6, 0x75]
        static let timecode: [UInt8] = [0xE7]
        static let blockGroup: [UInt8] = [0xA0]
        static let block: [UInt8] = [0xA1]
        static let blockDuration: [UInt8] = [0x9B]
        static let referenceBlock: [UInt8] = [0xFB]
        static let blockAdditions: [UInt8] = [0x75, 0xA1]
        static let blockMore: [UInt8] = [0xA6]
        static let blockAddID: [UInt8] = [0xEE]
        static let blockAdditional: [UInt8] = [0xA5]
    }

    /// A size as a variable-length integer, at the shortest width that can hold it.
    static func vint(_ value: UInt64) -> [UInt8] {
        var length = 1
        // 2^(7·n) − 1 is reserved at every width (it means "unknown size"), hence the strict <.
        while length < 8 && value >= (UInt64(1) << (7 * UInt64(length))) - 1 { length += 1 }
        var bytes = [UInt8](repeating: 0, count: length)
        var remaining = value
        for index in stride(from: length - 1, through: 0, by: -1) {
            bytes[index] = UInt8(remaining & 0xFF)
            remaining >>= 8
        }
        bytes[0] |= UInt8(0x80 >> (length - 1))
        return bytes
    }

    static func element(_ id: [UInt8], _ payload: [UInt8]) -> [UInt8] {
        id + vint(UInt64(payload.count)) + payload
    }

    static func element(_ id: [UInt8], _ payload: Data) -> [UInt8] {
        element(id, [UInt8](payload))
    }

    /// An unsigned integer payload, big-endian, at its minimal width (at least one byte).
    static func unsigned(_ value: UInt64) -> [UInt8] {
        var bytes: [UInt8] = []
        var remaining = value
        repeat {
            bytes.insert(UInt8(remaining & 0xFF), at: 0)
            remaining >>= 8
        } while remaining > 0
        return bytes
    }

    static func uint(_ id: [UInt8], _ value: UInt64) -> [UInt8] {
        element(id, unsigned(value))
    }

    /// A signed integer payload, two's complement, at its minimal width.
    static func sint(_ id: [UInt8], _ value: Int64) -> [UInt8] {
        var length = 1
        while length < 8 {
            let limit = Int64(1) << (8 * Int64(length) - 1)
            if value >= -limit && value < limit { break }
            length += 1
        }
        var bytes = [UInt8](repeating: 0, count: length)
        var remaining = UInt64(bitPattern: value)
        for index in stride(from: length - 1, through: 0, by: -1) {
            bytes[index] = UInt8(remaining & 0xFF)
            remaining >>= 8
        }
        return element(id, bytes)
    }

    static func float(_ id: [UInt8], _ value: Double) -> [UInt8] {
        let bits = value.bitPattern
        return element(id, (0..<8).map { UInt8((bits >> (8 * UInt64(7 - $0))) & 0xFF) })
    }

    static func string(_ id: [UInt8], _ value: String) -> [UInt8] {
        element(id, Array(value.utf8))
    }
}
