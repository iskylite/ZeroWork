#ifndef ZW_BMC_TLS_TRUST_H
#define ZW_BMC_TLS_TRUST_H
#include <stddef.h>
#include <stdint.h>

enum {
    ZW_TLS_UNTRUSTED_ISSUER = 1u << 0,
    ZW_TLS_EXPIRED = 1u << 1,
    ZW_TLS_NOT_YET_VALID = 1u << 2,
    ZW_TLS_HOSTNAME_MISMATCH = 1u << 3,
    ZW_TLS_REVOKED = 1u << 4,
    ZW_TLS_INVALID_CHAIN = 1u << 5,
    ZW_TLS_EVALUATION_UNAVAILABLE = 1u << 6,
    ZW_TLS_EXCESSIVE_VALIDITY = 1u << 7
};
typedef struct { const uint8_t *data; size_t length; } zw_bmc_tls_der;
typedef struct {
    uint32_t failures;
    int32_t native_status;
    int64_t not_before_unix;
    int64_t not_after_unix;
    char subject[256];
    char issuer[256];
} zw_bmc_tls_verification;

/* Uses SSL server policy for the original host, all supplied DER certificates,
 * default local system roots and no network fetch. No application IO occurs. */
int zw_bmc_tls_evaluate(const char *host, const zw_bmc_tls_der *chain,
                        size_t count, zw_bmc_tls_verification *result);

/* Record payload is leaf SHA256 || ordered-chain SHA256 || big-endian flags.
 * 0 success, 1 absent(load), 2 CAS conflict(save), -1 storage failure. */
int zw_bmc_tls_pin_load(const char *directory, const uint8_t key[32], uint8_t out[68]);
int zw_bmc_tls_pin_save(const char *directory, const uint8_t key[32],
                        const uint8_t *expected, const uint8_t next[68]);
#endif
