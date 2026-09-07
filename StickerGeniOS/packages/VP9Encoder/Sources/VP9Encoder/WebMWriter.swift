import Foundation

/// One encoded video frame: the VP9 colour frame, its alpha companion, and when it is shown.
public struct WebMFrame: Sendable {
    public var color: Data
    /// A second VP9 stream carrying the alpha plane as luma, stored as a `BlockAdditional` with
    /// `BlockAddID` 1 — the layout FFmpeg writes for `yuva420p` and Telegram's clients decode.
    public var alpha: Data?
    public var isKeyframe: Bool
    /// Presentation time, milliseconds from the start.
    public var timestampMilliseconds: Int
    public var durationMilliseconds: Int

    public init(color: Data, alpha: Data?, isKeyframe: Bool, timestampMilliseconds: Int, durationMilliseconds: Int) {
        self.color = color
        self.alpha = alpha
        self.isKeyframe = isKeyframe
        self.timestampMilliseconds = timestampMilliseconds
        self.durationMilliseconds = durationMilliseconds
    }
}

/// Writes a video-only WebM (Matroska) file around VP9 frames.
///
/// The output has one segment, one track, and a millisecond timecode scale. Frames go into
/// `BlockGroup`s rather than `SimpleBlock`s because that is the only container element that can
/// carry `BlockAdditions`, which is where the alpha stream lives. A non-key frame carries a
/// `ReferenceBlock` pointing at its predecessor, which is how a demuxer tells the two apart inside a
/// `BlockGroup`. Clusters restart before the 16-bit relative timecode could overflow.
public enum WebMWriter {
    public static let timecodeScaleNanoseconds: UInt64 = 1_000_000
    static let trackNumber: UInt64 = 1
    /// Kept well under the 32 767 ms a 16-bit relative timecode allows.
    static let maximumClusterSpanMilliseconds = 30_000

    public struct Failure: Error, Equatable, Sendable {
        public let reason: String
    }

    public static func write(
        frames: [WebMFrame],
        width: Int,
        height: Int,
        hasAlpha: Bool,
        writingApp: String = "VP9Encoder"
    ) throws -> Data {
        guard !frames.isEmpty else { throw Failure(reason: "no frames") }
        guard let first = frames.first, first.isKeyframe else { throw Failure(reason: "first frame must be a keyframe") }
        if hasAlpha, frames.contains(where: { $0.alpha == nil }) {
            throw Failure(reason: "every frame of an alpha stream needs an alpha companion")
        }

        var header: [UInt8] = []
        header += EBML.uint(EBML.ID.version, 1)
        header += EBML.uint(EBML.ID.readVersion, 1)
        header += EBML.uint(EBML.ID.maxIDLength, 4)
        header += EBML.uint(EBML.ID.maxSizeLength, 8)
        header += EBML.string(EBML.ID.docType, "webm")
        header += EBML.uint(EBML.ID.docTypeVersion, 4)
        header += EBML.uint(EBML.ID.docTypeReadVersion, 2)

        let last = frames[frames.count - 1]
        let durationMilliseconds = last.timestampMilliseconds + last.durationMilliseconds
        var info: [UInt8] = []
        info += EBML.uint(EBML.ID.timecodeScale, timecodeScaleNanoseconds)
        info += EBML.float(EBML.ID.duration, Double(durationMilliseconds))
        info += EBML.string(EBML.ID.muxingApp, writingApp)
        info += EBML.string(EBML.ID.writingApp, writingApp)

        var video: [UInt8] = []
        video += EBML.uint(EBML.ID.pixelWidth, UInt64(width))
        video += EBML.uint(EBML.ID.pixelHeight, UInt64(height))
        if hasAlpha { video += EBML.uint(EBML.ID.alphaMode, 1) }

        var trackEntry: [UInt8] = []
        trackEntry += EBML.uint(EBML.ID.trackNumber, trackNumber)
        trackEntry += EBML.uint(EBML.ID.trackUID, 0x5649_4445_4F31)
        trackEntry += EBML.uint(EBML.ID.trackType, 1)
        trackEntry += EBML.uint(EBML.ID.flagLacing, 0)
        trackEntry += EBML.string(EBML.ID.codecID, "V_VP9")
        trackEntry += EBML.string(EBML.ID.language, "und")
        trackEntry += EBML.element(EBML.ID.video, video)
        let tracks = EBML.element(EBML.ID.tracks, EBML.element(EBML.ID.trackEntry, trackEntry))

        var clusters: [UInt8] = []
        var clusterStart = 0
        var clusterBody: [UInt8] = []
        var previousTimestamp: Int?

        func flushCluster() {
            guard !clusterBody.isEmpty else { return }
            let body = EBML.uint(EBML.ID.timecode, UInt64(clusterStart)) + clusterBody
            clusters += EBML.element(EBML.ID.cluster, body)
            clusterBody = []
        }

        for (index, frame) in frames.enumerated() {
            if let previousTimestamp, frame.timestampMilliseconds < previousTimestamp {
                throw Failure(reason: "frame \(index) goes backwards in time")
            }
            // A cluster starts on a keyframe, and restarts when its relative timecodes would
            // outgrow 16 bits. Only the first frame is guaranteed to be a keyframe, so the span
            // rule is what actually bounds a long stream; the keyframe rule keeps seeking sane.
            if index > 0, frame.isKeyframe || frame.timestampMilliseconds - clusterStart > maximumClusterSpanMilliseconds {
                flushCluster()
                clusterStart = frame.timestampMilliseconds
            }
            let relative = frame.timestampMilliseconds - clusterStart
            guard relative >= 0, relative <= Int(Int16.max) else {
                throw Failure(reason: "frame \(index) is too far from its cluster start")
            }

            var block: [UInt8] = EBML.vint(trackNumber)
            block += [UInt8((relative >> 8) & 0xFF), UInt8(relative & 0xFF)]
            block += [0x00]
            block += [UInt8](frame.color)

            var group: [UInt8] = EBML.element(EBML.ID.block, block)
            group += EBML.uint(EBML.ID.blockDuration, UInt64(frame.durationMilliseconds))
            if !frame.isKeyframe, let previousTimestamp {
                group += EBML.sint(EBML.ID.referenceBlock, Int64(previousTimestamp - frame.timestampMilliseconds))
            }
            if hasAlpha, let alpha = frame.alpha {
                var more: [UInt8] = EBML.uint(EBML.ID.blockAddID, 1)
                more += EBML.element(EBML.ID.blockAdditional, alpha)
                group += EBML.element(EBML.ID.blockAdditions, EBML.element(EBML.ID.blockMore, more))
            }
            clusterBody += EBML.element(EBML.ID.blockGroup, group)
            previousTimestamp = frame.timestampMilliseconds
        }
        flushCluster()

        let segment = EBML.element(EBML.ID.segment, EBML.element(EBML.ID.info, info) + tracks + clusters)
        return Data(EBML.element(EBML.ID.header, header) + segment)
    }
}
