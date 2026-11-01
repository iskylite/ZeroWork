#ifndef ZW_RFB_ZLIB_SHIM_H
#define ZW_RFB_ZLIB_SHIM_H
#include <stddef.h>
void *zw_rfb_inflate_create(void);
void zw_rfb_inflate_destroy(void *context);
int zw_rfb_inflate_reset(void *context);
/* One Tight Z_SYNC_FLUSH fragment, exactly expected output bytes, all input consumed. */
int zw_rfb_inflate_exact(void *context, const unsigned char *input, size_t input_size,
                         unsigned char *output, size_t output_size);
/* Separate gzip stream for reviewed public-material hashing; Tight ABI above
 * is unchanged. step returns 0 for progress/need-input, 1 for complete, -1 on
 * invalid data. consumed/produced always describe this call's bounded slices. */
void *zw_bmc_gzip_create(void);
void zw_bmc_gzip_destroy(void *context);
int zw_bmc_gzip_step(void *context, const unsigned char *input, size_t input_size,
                     size_t *consumed, unsigned char *output, size_t output_size,
                     size_t *produced);
#endif
