import CVPX
import Foundation

/// What went wrong inside libvpx, with the codec's own words when it has any.
public struct VP9CodecError: Error, Sendable, CustomStringConvertible {
    public let operation: String
    public let code: Int
    public let detail: String?

    public var description: String {
        var text = "\(operation) failed (vpx error \(code))"
        if let detail { text += ": \(detail)" }
        return text
    }
}

/// One VP9 encoder instance: I420 frames in, compressed frames out, one packet per frame.
///
/// Configured for a sticker rather than a broadcast: no lookahead, no alt-ref frames — both of
/// which would let the encoder emit invisible frames or hold packets back, and a muxer that has to
/// pair every colour frame with its alpha companion needs exactly one packet per input frame from
/// both streams. Single keyframe at the start, since a 3-second file is never seeked into.
final class VP9StreamEncoder {
    struct Packet {
        var data: Data
        var isKeyframe: Bool
        var pts: Int64
    }

    private var context = vpx_codec_ctx_t()
    private var config = vpx_codec_enc_cfg_t()
    private var image: UnsafeMutablePointer<vpx_image_t>
    private var isOpen = false
    let width: Int
    let height: Int

    /// - Parameter targetBitrateKilobits: the rate control target. Bytes are what the sticker
    ///   limit is written in, so callers derive this from a byte budget and a duration and walk it
    ///   down when the result overshoots.
    /// - Parameter speed: libvpx's `cpu-used`, 0 (slowest, best) to 9. 5 is a sensible phone
    ///   default: a 90-frame 512² cycle encodes in a few seconds.
    init(
        width: Int,
        height: Int,
        targetBitrateKilobits: Int,
        speed: Int = 5,
        threads: Int = 4,
        lossless: Bool = false,
        fullRange: Bool = false
    ) throws {
        self.width = width
        self.height = height
        guard let allocated = vpx_img_alloc(nil, VPX_IMG_FMT_I420, UInt32(width), UInt32(height), 16) else {
            throw VP9CodecError(operation: "vpx_img_alloc", code: -1, detail: nil)
        }
        image = allocated

        var status = cvpx_vp9_encoder_default_config(&config)
        guard status == VPX_CODEC_OK else {
            vpx_img_free(image)
            throw VP9CodecError(operation: "default config", code: Int(status.rawValue), detail: nil)
        }
        config.g_w = UInt32(width)
        config.g_h = UInt32(height)
        // Milliseconds, which is what WebM stores and what the frames are scheduled in.
        config.g_timebase = vpx_rational(num: 1, den: 1000)
        config.g_threads = UInt32(max(1, threads))
        config.g_pass = VPX_RC_ONE_PASS
        config.g_lag_in_frames = 0
        config.g_error_resilient = 0
        config.rc_end_usage = VPX_VBR
        config.rc_target_bitrate = UInt32(max(1, targetBitrateKilobits))
        config.rc_min_quantizer = 0
        config.rc_max_quantizer = 63
        config.kf_mode = VPX_KF_AUTO
        config.kf_min_dist = 0
        // One keyframe, at the front. Every later frame predicts from its neighbour, which is
        // what makes a 90-frame cycle fit a 256 KB budget at all.
        config.kf_max_dist = 9_999
        config.g_profile = 0

        status = cvpx_vp9_encoder_init(&context, &config)
        guard status == VPX_CODEC_OK else {
            vpx_img_free(image)
            throw VP9CodecError(operation: "encoder init", code: Int(status.rawValue), detail: nil)
        }
        isOpen = true
        try control(CVPX_CONTROL_CPU_USED, min(9, max(0, speed)))
        try control(CVPX_CONTROL_AUTO_ALT_REF, 0)
        try control(CVPX_CONTROL_ROW_MT, 1)
        try control(CVPX_CONTROL_TILE_COLUMNS, 1)
        try control(CVPX_CONTROL_FRAME_PARALLEL_DECODING, 0)
        try control(CVPX_CONTROL_AQ_MODE, 0)
        try control(CVPX_CONTROL_LOSSLESS, lossless ? 1 : 0)
        try control(CVPX_CONTROL_COLOR_RANGE, fullRange ? 1 : 0)
    }

    deinit {
        if isOpen { vpx_codec_destroy(&context) }
        vpx_img_free(image)
    }

    private func control(_ id: cvpx_control_t, _ value: Int) throws {
        let status = cvpx_control(&context, id, Int32(value))
        guard status == VPX_CODEC_OK else {
            throw VP9CodecError(operation: "control \(id.rawValue)", code: Int(status.rawValue), detail: errorDetail)
        }
    }

    private var errorDetail: String? {
        cvpx_error_detail(&context).map { String(cString: $0) }
    }

    /// Writes the planes into the encoder's own image buffer and encodes them.
    ///
    /// - Parameter fill: called with the Y, U and V plane pointers and strides. U and V are
    ///   quarter-size (4:2:0).
    /// - Returns: the packets the encoder released, which with this configuration is exactly one.
    func encode(
        pts: Int64,
        durationMilliseconds: Int,
        fill: (_ planes: [UnsafeMutablePointer<UInt8>], _ strides: [Int]) -> Void
    ) throws -> [Packet] {
        let planes = (0..<3).map { cvpx_image_plane(image, Int32($0))! }
        let strides = (0..<3).map { Int(cvpx_image_stride(image, Int32($0))) }
        fill(planes, strides)
        let status = vpx_codec_encode(&context, image, pts, UInt(max(1, durationMilliseconds)), 0, UInt(VPX_DL_GOOD_QUALITY))
        guard status == VPX_CODEC_OK else {
            throw VP9CodecError(operation: "encode", code: Int(status.rawValue), detail: errorDetail)
        }
        return drain()
    }

    /// Flushes whatever the encoder still holds. Empty with no lookahead, but called anyway so the
    /// contract does not depend on that setting.
    func finish() throws -> [Packet] {
        let status = vpx_codec_encode(&context, nil, 0, 0, 0, UInt(VPX_DL_GOOD_QUALITY))
        guard status == VPX_CODEC_OK else {
            throw VP9CodecError(operation: "flush", code: Int(status.rawValue), detail: errorDetail)
        }
        return drain()
    }

    private func drain() -> [Packet] {
        var packets: [Packet] = []
        var iterator: vpx_codec_iter_t?
        while let packet = vpx_codec_get_cx_data(&context, &iterator) {
            var bytes: UnsafePointer<UInt8>?
            var size = 0
            var pts: Int64 = 0
            var isKey: Int32 = 0
            guard cvpx_packet_frame(packet, &bytes, &size, &pts, &isKey) != 0, let bytes else { continue }
            packets.append(.init(data: Data(bytes: bytes, count: size), isKeyframe: isKey != 0, pts: pts))
        }
        return packets
    }
}
