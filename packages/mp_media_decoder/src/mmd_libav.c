// The helpers that mmd_libav adds to the functions of libavcodec, for the
// parts of the decoder context that the options do not reach.
#include <string.h>

#include "libavcodec/avcodec.h"
#include "libavutil/mem.h"

// Gives the context [c], before it opens, a copy of the [size] bytes of
// codec data at [data], such as the format extension of a WAVE file that
// the ATRAC3 decoder reads. Returns 0, or a negative error code.
int mmd_set_extradata(AVCodecContext *c, const uint8_t *data, int size) {
  uint8_t *copy;
  if (size < 0) return AVERROR(EINVAL);
  copy = av_mallocz((size_t)size + AV_INPUT_BUFFER_PADDING_SIZE);
  if (!copy) return AVERROR(ENOMEM);
  if (size > 0) memcpy(copy, data, (size_t)size);
  av_freep(&c->extradata);
  c->extradata = copy;
  c->extradata_size = size;
  return 0;
}
