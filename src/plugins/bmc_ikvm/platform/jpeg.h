#ifndef ZW_RFB_JPEG_H
#define ZW_RFB_JPEG_H
#include <stddef.h>
#include <stdint.h>
/* Checks JPEG type and source dimensions before creating/decoding a CGImage.
   output is caller-owned RGBA8, with exactly width*height*4 bytes. */
int zw_rfb_decode_jpeg(const uint8_t *data, size_t size, uint32_t width, uint32_t height,
                       uint8_t *output, size_t output_size);
#endif
