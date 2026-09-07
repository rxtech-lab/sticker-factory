// A thin C shim over libvpx for Swift. Deliberately not named after the target: SwiftPM then
// builds the module from the whole include directory, which is what lets Swift see the libvpx
// headers under vpx/ through the same module.
//
// libvpx's public API leans on things Swift cannot import: variadic control calls, ABI-version
// macros baked into the init convenience macros, and union fields on the packet type. Each of
// those gets a plain function here. Everything else is used from Swift directly through the
// libvpx headers this module re-exports.

#ifndef CVPX_H
#define CVPX_H

#include <stddef.h>
#include <stdint.h>
#include "vpx/vpx_codec.h"
#include "vpx/vpx_decoder.h"
#include "vpx/vpx_encoder.h"
#include "vpx/vpx_image.h"
#include "vpx/vp8cx.h"
#include "vpx/vp8dx.h"

#ifdef __cplusplus
extern "C" {
#endif

/// The tunables the encoder exposes, mapped onto libvpx control ids in the implementation.
typedef enum {
    CVPX_CONTROL_CPU_USED = 1,
    CVPX_CONTROL_AUTO_ALT_REF,
    CVPX_CONTROL_ROW_MT,
    CVPX_CONTROL_TILE_COLUMNS,
    CVPX_CONTROL_AQ_MODE,
    CVPX_CONTROL_FRAME_PARALLEL_DECODING,
    CVPX_CONTROL_LOSSLESS,
    CVPX_CONTROL_CQ_LEVEL,
    CVPX_CONTROL_COLOR_RANGE,
} cvpx_control_t;

/// `vpx_codec_enc_config_default` for the VP9 encoder.
vpx_codec_err_t cvpx_vp9_encoder_default_config(vpx_codec_enc_cfg_t *config);

/// `vpx_codec_enc_init` for the VP9 encoder, with the ABI version this shim was compiled against.
vpx_codec_err_t cvpx_vp9_encoder_init(vpx_codec_ctx_t *context, const vpx_codec_enc_cfg_t *config);

/// `vpx_codec_dec_init` for the VP9 decoder.
vpx_codec_err_t cvpx_vp9_decoder_init(vpx_codec_ctx_t *context);

/// `vpx_codec_control` with one integer argument.
vpx_codec_err_t cvpx_control(vpx_codec_ctx_t *context, cvpx_control_t control, int value);

/// Reads a compressed-frame packet. Returns 0 for any other packet kind.
int cvpx_packet_frame(const vpx_codec_cx_pkt_t *packet,
                      const uint8_t **bytes, size_t *size, int64_t *pts, int *isKeyframe);

/// Plane accessors, because `vpx_image_t.planes` is a fixed C array that Swift imports as a tuple.
uint8_t *cvpx_image_plane(const vpx_image_t *image, int plane);
int cvpx_image_stride(const vpx_image_t *image, int plane);

/// The encoder's last error detail, or NULL.
const char *cvpx_error_detail(vpx_codec_ctx_t *context);

#ifdef __cplusplus
}
#endif

#endif
