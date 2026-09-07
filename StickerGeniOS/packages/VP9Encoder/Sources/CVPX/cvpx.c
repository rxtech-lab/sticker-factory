#include "cvpx_shim.h"

vpx_codec_err_t cvpx_vp9_encoder_default_config(vpx_codec_enc_cfg_t *config) {
    return vpx_codec_enc_config_default(vpx_codec_vp9_cx(), config, 0);
}

vpx_codec_err_t cvpx_vp9_encoder_init(vpx_codec_ctx_t *context, const vpx_codec_enc_cfg_t *config) {
    return vpx_codec_enc_init(context, vpx_codec_vp9_cx(), config, 0);
}

vpx_codec_err_t cvpx_vp9_decoder_init(vpx_codec_ctx_t *context) {
    return vpx_codec_dec_init(context, vpx_codec_vp9_dx(), NULL, 0);
}

vpx_codec_err_t cvpx_control(vpx_codec_ctx_t *context, cvpx_control_t control, int value) {
    switch (control) {
    case CVPX_CONTROL_CPU_USED: return vpx_codec_control_(context, VP8E_SET_CPUUSED, value);
    case CVPX_CONTROL_AUTO_ALT_REF: return vpx_codec_control_(context, VP8E_SET_ENABLEAUTOALTREF, (unsigned int)value);
    case CVPX_CONTROL_ROW_MT: return vpx_codec_control_(context, VP9E_SET_ROW_MT, (unsigned int)value);
    case CVPX_CONTROL_TILE_COLUMNS: return vpx_codec_control_(context, VP9E_SET_TILE_COLUMNS, value);
    case CVPX_CONTROL_AQ_MODE: return vpx_codec_control_(context, VP9E_SET_AQ_MODE, (unsigned int)value);
    case CVPX_CONTROL_FRAME_PARALLEL_DECODING: return vpx_codec_control_(context, VP9E_SET_FRAME_PARALLEL_DECODING, (unsigned int)value);
    case CVPX_CONTROL_LOSSLESS: return vpx_codec_control_(context, VP9E_SET_LOSSLESS, (unsigned int)value);
    case CVPX_CONTROL_CQ_LEVEL: return vpx_codec_control_(context, VP8E_SET_CQ_LEVEL, (unsigned int)value);
    case CVPX_CONTROL_COLOR_RANGE: return vpx_codec_control_(context, VP9E_SET_COLOR_RANGE, value);
    }
    return VPX_CODEC_INVALID_PARAM;
}

int cvpx_packet_frame(const vpx_codec_cx_pkt_t *packet,
                      const uint8_t **bytes, size_t *size, int64_t *pts, int *isKeyframe) {
    if (packet == NULL || packet->kind != VPX_CODEC_CX_FRAME_PKT) return 0;
    *bytes = (const uint8_t *)packet->data.frame.buf;
    *size = packet->data.frame.sz;
    *pts = packet->data.frame.pts;
    *isKeyframe = (packet->data.frame.flags & VPX_FRAME_IS_KEY) != 0;
    return 1;
}

uint8_t *cvpx_image_plane(const vpx_image_t *image, int plane) {
    if (image == NULL || plane < 0 || plane > 3) return NULL;
    return image->planes[plane];
}

int cvpx_image_stride(const vpx_image_t *image, int plane) {
    if (image == NULL || plane < 0 || plane > 3) return 0;
    return image->stride[plane];
}

const char *cvpx_error_detail(vpx_codec_ctx_t *context) {
    return vpx_codec_error_detail(context);
}
