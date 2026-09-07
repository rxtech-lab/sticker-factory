import CVPX
import Foundation

/// Reads back what `WebMWriter` wrote — and, being a plain EBML walk, anything else with the same
/// shape — so a test can check a file with something other than the code that produced it.
public struct WebMDocument: Sendable {
    public struct Track: Sendable {
        public var codecID: String
        public var pixelWidth: Int
        public var pixelHeight: Int
        public var alphaMode: Int
    }

    public struct Block: Sendable {
        public var timestampMilliseconds: Int
        public var durationMilliseconds: Int?
        public var isKeyframe: Bool
        public var color: Data
        public var alpha: Data?
    }

    public var docType: String
    public var timecodeScaleNanoseconds: UInt64
    public var durationMilliseconds: Double?
    public var track: Track?
    public var blocks: [Block]
}

public enum WebMReader {
    public struct Failure: Error, Sendable, Equatable {
        public let reason: String
    }

    public static func read(_ data: Data) throws -> WebMDocument {
        let bytes = [UInt8](data)
        var cursor = 0
        var document = WebMDocument(docType: "", timecodeScaleNanoseconds: 1_000_000, durationMilliseconds: nil, track: nil, blocks: [])

        let (headerID, headerBody) = try readElement(bytes, &cursor)
        guard headerID == EBML.ID.header else { throw Failure(reason: "not an EBML file") }
        var headerCursor = 0
        while headerCursor < headerBody.count {
            let (id, body) = try readElement(headerBody, &headerCursor)
            if id == EBML.ID.docType { document.docType = String(decoding: body, as: UTF8.self) }
        }

        let (segmentID, segment) = try readElement(bytes, &cursor)
        guard segmentID == EBML.ID.segment else { throw Failure(reason: "no segment") }
        var segmentCursor = 0
        while segmentCursor < segment.count {
            let (id, body) = try readElement(segment, &segmentCursor)
            switch id {
            case EBML.ID.info:
                var infoCursor = 0
                while infoCursor < body.count {
                    let (infoID, value) = try readElement(body, &infoCursor)
                    if infoID == EBML.ID.timecodeScale { document.timecodeScaleNanoseconds = unsigned(value) }
                    if infoID == EBML.ID.duration { document.durationMilliseconds = float(value) }
                }
            case EBML.ID.tracks:
                var tracksCursor = 0
                while tracksCursor < body.count {
                    let (entryID, entry) = try readElement(body, &tracksCursor)
                    guard entryID == EBML.ID.trackEntry else { continue }
                    var track = WebMDocument.Track(codecID: "", pixelWidth: 0, pixelHeight: 0, alphaMode: 0)
                    var entryCursor = 0
                    while entryCursor < entry.count {
                        let (fieldID, value) = try readElement(entry, &entryCursor)
                        switch fieldID {
                        case EBML.ID.codecID: track.codecID = String(decoding: value, as: UTF8.self)
                        case EBML.ID.video:
                            var videoCursor = 0
                            while videoCursor < value.count {
                                let (videoID, videoValue) = try readElement(value, &videoCursor)
                                switch videoID {
                                case EBML.ID.pixelWidth: track.pixelWidth = Int(unsigned(videoValue))
                                case EBML.ID.pixelHeight: track.pixelHeight = Int(unsigned(videoValue))
                                case EBML.ID.alphaMode: track.alphaMode = Int(unsigned(videoValue))
                                default: break
                                }
                            }
                        default: break
                        }
                    }
                    document.track = track
                }
            case EBML.ID.cluster:
                var clusterCursor = 0
                var clusterTimecode = 0
                while clusterCursor < body.count {
                    let (childID, child) = try readElement(body, &clusterCursor)
                    switch childID {
                    case EBML.ID.timecode: clusterTimecode = Int(unsigned(child))
                    case EBML.ID.blockGroup:
                        var block = WebMDocument.Block(timestampMilliseconds: 0, durationMilliseconds: nil, isKeyframe: true, color: Data(), alpha: nil)
                        var groupCursor = 0
                        while groupCursor < child.count {
                            let (partID, part) = try readElement(child, &groupCursor)
                            switch partID {
                            case EBML.ID.block:
                                var blockCursor = 0
                                _ = try readVint(part, &blockCursor)
                                guard part.count >= blockCursor + 3 else { throw Failure(reason: "truncated block") }
                                let relative = Int(Int16(bitPattern: UInt16(part[blockCursor]) << 8 | UInt16(part[blockCursor + 1])))
                                block.timestampMilliseconds = clusterTimecode + relative
                                block.color = Data(part[(blockCursor + 3)...])
                            case EBML.ID.blockDuration: block.durationMilliseconds = Int(unsigned(part))
                            case EBML.ID.referenceBlock: block.isKeyframe = false
                            case EBML.ID.blockAdditions:
                                var additionsCursor = 0
                                while additionsCursor < part.count {
                                    let (moreID, more) = try readElement(part, &additionsCursor)
                                    guard moreID == EBML.ID.blockMore else { continue }
                                    var moreCursor = 0
                                    var addID: UInt64 = 1
                                    var additional: Data?
                                    while moreCursor < more.count {
                                        let (fieldID, value) = try readElement(more, &moreCursor)
                                        if fieldID == EBML.ID.blockAddID { addID = unsigned(value) }
                                        if fieldID == EBML.ID.blockAdditional { additional = Data(value) }
                                    }
                                    if addID == 1 { block.alpha = additional }
                                }
                            default: break
                            }
                        }
                        document.blocks.append(block)
                    default: break
                    }
                }
            default: break
            }
        }
        return document
    }

    private static func readElement(_ bytes: [UInt8], _ cursor: inout Int) throws -> ([UInt8], [UInt8]) {
        guard cursor < bytes.count else { throw Failure(reason: "unexpected end of data") }
        let idLength = leadingLength(bytes[cursor])
        guard idLength >= 1, idLength <= 4, cursor + idLength <= bytes.count else { throw Failure(reason: "bad element id") }
        let id = Array(bytes[cursor..<(cursor + idLength)])
        cursor += idLength
        let size = try readVint(bytes, &cursor)
        guard cursor + Int(size) <= bytes.count else { throw Failure(reason: "element overruns file") }
        let body = Array(bytes[cursor..<(cursor + Int(size))])
        cursor += Int(size)
        return (id, body)
    }

    private static func readVint(_ bytes: [UInt8], _ cursor: inout Int) throws -> UInt64 {
        guard cursor < bytes.count else { throw Failure(reason: "unexpected end of data") }
        let length = leadingLength(bytes[cursor])
        guard length >= 1, length <= 8, cursor + length <= bytes.count else { throw Failure(reason: "bad vint") }
        var value = UInt64(bytes[cursor] & (0xFF >> length))
        for index in 1..<length { value = value << 8 | UInt64(bytes[cursor + index]) }
        cursor += length
        return value
    }

    private static func leadingLength(_ byte: UInt8) -> Int {
        var length = 1
        var mask: UInt8 = 0x80
        while length <= 8, byte & mask == 0 {
            mask >>= 1
            length += 1
        }
        return length
    }

    private static func unsigned(_ bytes: [UInt8]) -> UInt64 {
        bytes.reduce(0) { $0 << 8 | UInt64($1) }
    }

    private static func float(_ bytes: [UInt8]) -> Double? {
        switch bytes.count {
        case 4: return Double(Float(bitPattern: UInt32(unsigned(bytes))))
        case 8: return Double(bitPattern: unsigned(bytes))
        default: return nil
        }
    }
}

/// A decoded VP9 frame, as planes.
public struct DecodedVP9Frame: Sendable {
    public var width: Int
    public var height: Int
    public var luma: [UInt8]
}

/// Decodes raw VP9 frames through libvpx. Used by tests to prove that what the encoder wrote is
/// a frame a real decoder accepts, at the size it claims.
public final class VP9Decoder {
    private var context = vpx_codec_ctx_t()
    private var isOpen = false

    public init() throws {
        let status = cvpx_vp9_decoder_init(&context)
        guard status == VPX_CODEC_OK else {
            throw VP9CodecError(operation: "decoder init", code: Int(status.rawValue), detail: nil)
        }
        isOpen = true
    }

    deinit {
        if isOpen { vpx_codec_destroy(&context) }
    }

    /// Decodes one compressed frame and returns its luma plane (which for an alpha stream *is* the
    /// alpha), cropped to the displayed size.
    public func decode(_ frame: Data) throws -> DecodedVP9Frame {
        let status = frame.withUnsafeBytes { buffer -> vpx_codec_err_t in
            vpx_codec_decode(&context, buffer.baseAddress?.assumingMemoryBound(to: UInt8.self), UInt32(buffer.count), nil, 0)
        }
        guard status == VPX_CODEC_OK else {
            throw VP9CodecError(operation: "decode", code: Int(status.rawValue), detail: cvpx_error_detail(&context).map { String(cString: $0) })
        }
        var iterator: vpx_codec_iter_t?
        guard let image = vpx_codec_get_frame(&context, &iterator) else {
            throw VP9CodecError(operation: "decode", code: -1, detail: "no frame produced")
        }
        let width = Int(image.pointee.d_w)
        let height = Int(image.pointee.d_h)
        let stride = Int(cvpx_image_stride(image, 0))
        guard let plane = cvpx_image_plane(image, 0) else {
            throw VP9CodecError(operation: "decode", code: -1, detail: "no luma plane")
        }
        var luma = [UInt8](repeating: 0, count: width * height)
        for row in 0..<height {
            luma.withUnsafeMutableBufferPointer { destination in
                (destination.baseAddress! + row * width).update(from: plane + row * stride, count: width)
            }
        }
        return DecodedVP9Frame(width: width, height: height, luma: luma)
    }
}
