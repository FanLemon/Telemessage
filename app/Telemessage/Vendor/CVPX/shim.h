// libvpx VP9 decoder, statically linked from libs/ (build-libs.sh); see LIBS_PREFIX in project.xcproj.
#include "vpx/vpx_decoder.h"
#include "vpx/vp8dx.h"

// vpx_codec_dec_init is a macro over the ABI version, which Swift cannot import.
static inline vpx_codec_err_t tm_vp9_decoder_init(vpx_codec_ctx_t *ctx, unsigned int threads) {
  vpx_codec_dec_cfg_t cfg = {threads, 0, 0};
  return vpx_codec_dec_init(ctx, vpx_codec_vp9_dx(), &cfg, 0);
}
