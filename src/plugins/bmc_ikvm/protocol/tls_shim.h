#ifndef ZEROWORK_BMC_TLS_SHIM_H
#define ZEROWORK_BMC_TLS_SHIM_H
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif

typedef struct zw_bmc_tls zw_bmc_tls;
enum zw_bmc_tls_status {
    ZW_BMC_TLS_OK = 0, ZW_BMC_TLS_WANT_READ = 1,
    ZW_BMC_TLS_WANT_WRITE = 2, ZW_BMC_TLS_NEEDS_TRUST = 3,
    ZW_BMC_TLS_CLOSED = 4, ZW_BMC_TLS_FAILED = -1,
    ZW_BMC_TLS_CANCELLED = -2, ZW_BMC_TLS_UNTRUSTED = -3,
    ZW_BMC_TLS_INVALID = -4
};
/* Borrows fd. All operations are nonblocking. Only cancel may run concurrently;
 * one worker owns all other calls. destroy never closes the OwnedStream fd.
 * original_host is the actual BMC name/IP, never localhost or a tunnel address.
 * No application read/write can occur before authorize_trust(1). */
zw_bmc_tls *zw_bmc_tls_create(int fd, const char *original_host, int *error_code);
void zw_bmc_tls_destroy(zw_bmc_tls *ctx);
int zw_bmc_tls_handshake_step(zw_bmc_tls *ctx);
int zw_bmc_tls_authorize_trust(zw_bmc_tls *ctx, int authorized);
int zw_bmc_tls_read(zw_bmc_tls *ctx, unsigned char *out, size_t cap, size_t *read_count);
int zw_bmc_tls_write(zw_bmc_tls *ctx, const unsigned char *data, size_t len, size_t *written);
int zw_bmc_tls_close_notify_step(zw_bmc_tls *ctx);
void zw_bmc_tls_cancel(zw_bmc_tls *ctx);
int zw_bmc_tls_last_error(const zw_bmc_tls *ctx);
const char *zw_bmc_tls_original_host(const zw_bmc_tls *ctx);
/* DER slices borrow ctx, leaf first. Valid after NEEDS_TRUST and until destroy.
 * These are the presented chain, not a manufactured trusted chain. */
size_t zw_bmc_tls_cert_count(const zw_bmc_tls *ctx);
const unsigned char *zw_bmc_tls_cert_der(const zw_bmc_tls *ctx, size_t index, size_t *len);
/* Diagnostic only: the chain must independently pass the host trust facade.
 * An empty mbedTLS CA store is never an authorization result. */
uint32_t zw_bmc_tls_verify_flags(const zw_bmc_tls *ctx);

/* PEM (with or without NUL) or DER public key; RSA exactly 2048 bits, PKCS#1
 * v1.5 randomized encryption. base64 output is 344 bytes, plus a NUL if cap >344.
 * The key must come from profile evidence; this function does not discover one.
 * The caller owns and wipes plaintext and output. */
int zw_bmc_rsa2048_encrypt(const unsigned char *public_key, size_t key_len,
                         const unsigned char *plaintext, size_t plaintext_len,
                         unsigned char *output, size_t output_cap, size_t *output_len);
int zw_bmc_rsa2048_base64(const unsigned char *public_key, size_t key_len,
                        const unsigned char *plaintext, size_t plaintext_len,
                        unsigned char *output, size_t output_cap, size_t *output_len);
#ifdef __cplusplus
}
#endif
#endif
