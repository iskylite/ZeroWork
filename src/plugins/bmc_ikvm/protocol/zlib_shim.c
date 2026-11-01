#include "zlib_shim.h"
#include <limits.h>
#include <stdlib.h>
#include <zlib.h>

void *zw_rfb_inflate_create(void) {
    z_stream *stream = calloc(1, sizeof(*stream));
    if (!stream) return NULL;
    if (inflateInit(stream) != Z_OK) { free(stream); return NULL; }
    return stream;
}
void zw_rfb_inflate_destroy(void *context) {
    if (context) { inflateEnd((z_stream *)context); free(context); }
}
int zw_rfb_inflate_reset(void *context) {
    return context && inflateReset((z_stream *)context) == Z_OK ? 0 : -1;
}
int zw_rfb_inflate_exact(void *context, const unsigned char *input, size_t input_size,
                         unsigned char *output, size_t output_size) {
    z_stream *stream = context;
    if (!stream || input_size > UINT_MAX || output_size > UINT_MAX) return -1;
    stream->next_in = (Bytef *)input;
    stream->avail_in = (uInt)input_size;
    stream->next_out = output;
    stream->avail_out = (uInt)output_size;
    unsigned char overflow;
    size_t produced = 0;
    for (;;) {
        uInt before_in = stream->avail_in, before_out = stream->avail_out;
        int status = inflate(stream, Z_SYNC_FLUSH);
        size_t written = before_out - stream->avail_out;
        if (stream->next_out == &overflow + 1 && written) return -1;
        produced += written;
        if (produced > output_size || (status != Z_OK && status != Z_BUF_ERROR)) return -1;
        if (!stream->avail_in && stream->avail_out) break;
        if (before_in == stream->avail_in && !written) return -1;
        if (!stream->avail_out) { stream->next_out = &overflow; stream->avail_out = 1; }
    }
    stream->next_in = NULL;
    stream->next_out = NULL;
    return produced == output_size ? 0 : -1;
}

void *zw_bmc_gzip_create(void) {
    z_stream *stream = calloc(1, sizeof(*stream));
    if (!stream) return NULL;
    if (inflateInit2(stream, 16 + MAX_WBITS) != Z_OK) { free(stream); return NULL; }
    return stream;
}
void zw_bmc_gzip_destroy(void *context) {
    if (context) { inflateEnd((z_stream *)context); free(context); }
}
int zw_bmc_gzip_step(void *context, const unsigned char *input, size_t input_size,
                     size_t *consumed, unsigned char *output, size_t output_size,
                     size_t *produced) {
    if (!consumed || !produced) return -1;
    *consumed = 0;
    *produced = 0;
    z_stream *stream = context;
    if (!stream || input_size > UINT_MAX || !output_size || output_size > UINT_MAX) return -1;
    stream->next_in = (Bytef *)input;
    stream->avail_in = (uInt)input_size;
    stream->next_out = output;
    stream->avail_out = (uInt)output_size;
    int status = inflate(stream, Z_NO_FLUSH);
    *consumed = input_size - stream->avail_in;
    *produced = output_size - stream->avail_out;
    stream->next_in = NULL;
    stream->next_out = NULL;
    if (status == Z_STREAM_END) return 1;
    return status == Z_OK || status == Z_BUF_ERROR ? 0 : -1;
}
