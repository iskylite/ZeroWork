#define _DARWIN_C_SOURCE
#include "tls_shim.h"
#include <mbedtls/base64.h>
#include <mbedtls/ctr_drbg.h>
#include <mbedtls/entropy.h>
#include <mbedtls/net_sockets.h>
#include <mbedtls/pk.h>
#include <mbedtls/platform_util.h>
#include <mbedtls/rsa.h>
#include <mbedtls/ssl.h>
#include <mbedtls/x509_crt.h>
#include <errno.h>
#include <fcntl.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

struct zw_bmc_tls {
    mbedtls_ssl_context ssl;
    mbedtls_ssl_config config;
    mbedtls_ctr_drbg_context rng;
    mbedtls_entropy_context entropy;
    int fd, last_error, handshake_done, authorized, denied, terminal;
    atomic_bool cancelled;
    char *original_host;
};

static int send_nonblocking(void *opaque, const unsigned char *data, size_t len) {
    zw_bmc_tls *ctx = opaque;
    if (atomic_load_explicit(&ctx->cancelled, memory_order_acquire)) return MBEDTLS_ERR_SSL_INTERNAL_ERROR;
    ssize_t n = send(ctx->fd, data, len, 0);
    if (n >= 0) return (int)n;
    if (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) return MBEDTLS_ERR_SSL_WANT_WRITE;
    return MBEDTLS_ERR_NET_SEND_FAILED;
}
static int recv_nonblocking(void *opaque, unsigned char *data, size_t len) {
    zw_bmc_tls *ctx = opaque;
    if (atomic_load_explicit(&ctx->cancelled, memory_order_acquire)) return MBEDTLS_ERR_SSL_INTERNAL_ERROR;
    ssize_t n = recv(ctx->fd, data, len, 0);
    if (n >= 0) return (int)n;
    if (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) return MBEDTLS_ERR_SSL_WANT_READ;
    return MBEDTLS_ERR_NET_RECV_FAILED;
}
/* Preserve all mbedTLS diagnostics. VERIFY_OPTIONAL only defers the decision to
 * SecTrust; the independent application-data gate remains closed. */
static int observe_verify(void *opaque, mbedtls_x509_crt *crt, int depth, uint32_t *flags) {
    (void)opaque; (void)crt; (void)depth; (void)flags;
    return 0;
}
static int result(zw_bmc_tls *ctx, int ret) {
    if (atomic_load_explicit(&ctx->cancelled, memory_order_acquire)) return ZW_BMC_TLS_CANCELLED;
    if (ret == MBEDTLS_ERR_SSL_WANT_READ) return ZW_BMC_TLS_WANT_READ;
    if (ret == MBEDTLS_ERR_SSL_WANT_WRITE) return ZW_BMC_TLS_WANT_WRITE;
    if (ret == MBEDTLS_ERR_SSL_PEER_CLOSE_NOTIFY) { ctx->terminal = 1; return ZW_BMC_TLS_CLOSED; }
    if (ret < 0) { ctx->last_error = ret; ctx->terminal = 1; return ZW_BMC_TLS_FAILED; }
    return ZW_BMC_TLS_OK;
}

zw_bmc_tls *zw_bmc_tls_create(int fd, const char *original_host, int *error_code) {
    int ret = MBEDTLS_ERR_SSL_BAD_INPUT_DATA;
    if (error_code) *error_code = ret;
    if (fd < 0 || !original_host || !*original_host || strlen(original_host) > 253) return NULL;
    zw_bmc_tls *ctx = calloc(1, sizeof(*ctx));
    if (!ctx) return NULL;
    ctx->fd = fd;
    atomic_init(&ctx->cancelled, 0);
    mbedtls_ssl_init(&ctx->ssl);
    mbedtls_ssl_config_init(&ctx->config);
    mbedtls_ctr_drbg_init(&ctx->rng);
    mbedtls_entropy_init(&ctx->entropy);
    ctx->original_host = strdup(original_host);
    if (!ctx->original_host) goto fail;
    int flags = fcntl(fd, F_GETFL, 0);
    if (flags < 0 || fcntl(fd, F_SETFL, flags | O_NONBLOCK) < 0) goto fail;
#ifdef SO_NOSIGPIPE
    int yes = 1;
    if (setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, sizeof(yes)) < 0) goto fail;
#endif
    static const unsigned char personalization[] = "ZeroWork BMC TLS 1";
    ret = mbedtls_ctr_drbg_seed(&ctx->rng, mbedtls_entropy_func, &ctx->entropy,
                               personalization, sizeof(personalization) - 1);
    if (ret != 0) goto fail;
    ret = mbedtls_ssl_config_defaults(&ctx->config, MBEDTLS_SSL_IS_CLIENT,
                                    MBEDTLS_SSL_TRANSPORT_STREAM, MBEDTLS_SSL_PRESET_DEFAULT);
    if (ret != 0) goto fail;
    mbedtls_ssl_conf_min_tls_version(&ctx->config, MBEDTLS_SSL_VERSION_TLS1_2);
    mbedtls_ssl_conf_authmode(&ctx->config, MBEDTLS_SSL_VERIFY_OPTIONAL);
    mbedtls_ssl_conf_verify(&ctx->config, observe_verify, ctx);
    mbedtls_ssl_conf_rng(&ctx->config, mbedtls_ctr_drbg_random, &ctx->rng);
#if defined(MBEDTLS_SSL_RENEGOTIATION)
    mbedtls_ssl_conf_renegotiation(&ctx->config, MBEDTLS_SSL_RENEGOTIATION_DISABLED);
#endif
    ret = mbedtls_ssl_setup(&ctx->ssl, &ctx->config);
    if (ret != 0) goto fail;
    ret = mbedtls_ssl_set_hostname(&ctx->ssl, original_host);
    if (ret != 0) goto fail;
    mbedtls_ssl_set_bio(&ctx->ssl, ctx, send_nonblocking, recv_nonblocking, NULL);
    if (error_code) *error_code = 0;
    return ctx;
fail:
    if (error_code) *error_code = ret;
    zw_bmc_tls_destroy(ctx);
    return NULL;
}
void zw_bmc_tls_destroy(zw_bmc_tls *ctx) {
    if (!ctx) return;
    mbedtls_ssl_free(&ctx->ssl);
    mbedtls_ssl_config_free(&ctx->config);
    mbedtls_ctr_drbg_free(&ctx->rng);
    mbedtls_entropy_free(&ctx->entropy);
    free(ctx->original_host);
    mbedtls_platform_zeroize(ctx, sizeof(*ctx));
    free(ctx);
}
static int check_context(zw_bmc_tls *ctx) {
    if (!ctx) return ZW_BMC_TLS_INVALID;
    if (atomic_load_explicit(&ctx->cancelled, memory_order_acquire)) return ZW_BMC_TLS_CANCELLED;
    if (ctx->denied) return ZW_BMC_TLS_UNTRUSTED;
    if (ctx->terminal) return ZW_BMC_TLS_CLOSED;
    return ZW_BMC_TLS_OK;
}
int zw_bmc_tls_handshake_step(zw_bmc_tls *ctx) {
    int check = check_context(ctx);
    if (check != ZW_BMC_TLS_OK) return check;
    if (!ctx->handshake_done) {
        int status = result(ctx, mbedtls_ssl_handshake(&ctx->ssl));
        if (status != ZW_BMC_TLS_OK) return status;
        ctx->handshake_done = 1;
        size_t count = 0, total = 0;
        const mbedtls_x509_crt *cert = mbedtls_ssl_get_peer_cert(&ctx->ssl);
        for (; cert; cert = cert->next) {
            if (++count > 16 || cert->raw.len == 0 || cert->raw.len > 65536 || total > 262144 - cert->raw.len) {
                ctx->last_error = MBEDTLS_ERR_SSL_BAD_CERTIFICATE;
                ctx->terminal = 1;
                return ZW_BMC_TLS_FAILED;
            }
            total += cert->raw.len;
        }
        if (count == 0) { ctx->terminal = 1; ctx->last_error = MBEDTLS_ERR_SSL_NO_CLIENT_CERTIFICATE; return ZW_BMC_TLS_FAILED; }
    }
    return ctx->authorized ? ZW_BMC_TLS_OK : ZW_BMC_TLS_NEEDS_TRUST;
}
int zw_bmc_tls_authorize_trust(zw_bmc_tls *ctx, int authorized) {
    int check = check_context(ctx);
    if (check != ZW_BMC_TLS_OK) return check;
    if (!ctx->handshake_done) return ZW_BMC_TLS_INVALID;
    if (!authorized) { ctx->denied = 1; return ZW_BMC_TLS_UNTRUSTED; }
    ctx->authorized = 1;
    return ZW_BMC_TLS_OK;
}
static int check_application(zw_bmc_tls *ctx) {
    int check = check_context(ctx);
    if (check != ZW_BMC_TLS_OK) return check;
    return ctx->authorized && ctx->handshake_done ? ZW_BMC_TLS_OK : ZW_BMC_TLS_NEEDS_TRUST;
}
int zw_bmc_tls_read(zw_bmc_tls *ctx, unsigned char *out, size_t cap, size_t *read_count) {
    if (read_count) *read_count = 0;
    int check = check_application(ctx);
    if (check != ZW_BMC_TLS_OK) return check;
    if (!out || !read_count || cap == 0) return ZW_BMC_TLS_INVALID;
    int ret = mbedtls_ssl_read(&ctx->ssl, out, cap);
    if (ret == 0) { ctx->terminal = 1; ctx->last_error = MBEDTLS_ERR_SSL_CONN_EOF; return ZW_BMC_TLS_FAILED; }
    int status = result(ctx, ret);
    if (status == ZW_BMC_TLS_OK) *read_count = (size_t)ret;
    return status;
}
int zw_bmc_tls_write(zw_bmc_tls *ctx, const unsigned char *data, size_t len, size_t *written) {
    if (written) *written = 0;
    int check = check_application(ctx);
    if (check != ZW_BMC_TLS_OK) return check;
    if (!data || !written || len == 0) return ZW_BMC_TLS_INVALID;
    /* mbedTLS requires the same pointer/length after WANT_WRITE; callers retain
     * their WriteCursor and advance only after an actual positive byte count. */
    int ret = mbedtls_ssl_write(&ctx->ssl, data, len);
    int status = result(ctx, ret);
    if (status == ZW_BMC_TLS_OK) *written = (size_t)ret;
    return status;
}
int zw_bmc_tls_close_notify_step(zw_bmc_tls *ctx) {
    int check = check_context(ctx);
    if (check != ZW_BMC_TLS_OK) return check;
    if (!ctx->handshake_done) return ZW_BMC_TLS_CLOSED;
    int status = result(ctx, mbedtls_ssl_close_notify(&ctx->ssl));
    if (status == ZW_BMC_TLS_OK) ctx->terminal = 1;
    return status;
}
void zw_bmc_tls_cancel(zw_bmc_tls *ctx) {
    if (ctx) atomic_store_explicit(&ctx->cancelled, 1, memory_order_release);
}
int zw_bmc_tls_last_error(const zw_bmc_tls *ctx) { return ctx ? ctx->last_error : MBEDTLS_ERR_SSL_BAD_INPUT_DATA; }
const char *zw_bmc_tls_original_host(const zw_bmc_tls *ctx) { return ctx ? ctx->original_host : NULL; }
size_t zw_bmc_tls_cert_count(const zw_bmc_tls *ctx) {
    if (!ctx || !ctx->handshake_done) return 0;
    size_t n = 0;
    for (const mbedtls_x509_crt *c = mbedtls_ssl_get_peer_cert(&ctx->ssl); c; c = c->next) ++n;
    return n;
}
const unsigned char *zw_bmc_tls_cert_der(const zw_bmc_tls *ctx, size_t index, size_t *len) {
    if (len) *len = 0;
    if (!ctx || !ctx->handshake_done || !len) return NULL;
    const mbedtls_x509_crt *c = mbedtls_ssl_get_peer_cert(&ctx->ssl);
    while (c && index--) c = c->next;
    if (!c) return NULL;
    *len = c->raw.len;
    return c->raw.p;
}
uint32_t zw_bmc_tls_verify_flags(const zw_bmc_tls *ctx) {
    return ctx && ctx->handshake_done ? mbedtls_ssl_get_verify_result(&ctx->ssl) : UINT32_MAX;
}

int zw_bmc_rsa2048_encrypt(const unsigned char *public_key, size_t key_len,
                        const unsigned char *plaintext, size_t plaintext_len,
                        unsigned char *output, size_t output_cap, size_t *output_len) {
    if (output_len) *output_len = 0;
    if (!public_key || key_len == 0 || key_len > 16384 || !plaintext || plaintext_len > 245 || !output || output_cap < 256 || !output_len) return ZW_BMC_TLS_INVALID;
    int ret = MBEDTLS_ERR_PK_BAD_INPUT_DATA;
    mbedtls_pk_context pk;
    mbedtls_ctr_drbg_context rng;
    mbedtls_entropy_context entropy;
    unsigned char encrypted[256];
    unsigned char *pem = NULL;
    size_t encrypted_len = 0;
    mbedtls_pk_init(&pk);
    mbedtls_ctr_drbg_init(&rng);
    mbedtls_entropy_init(&entropy);
    if (key_len >= 10 && memcmp(public_key, "-----BEGIN", 10) == 0) {
        pem = calloc(key_len + 1, 1);
        if (!pem) goto cleanup;
        memcpy(pem, public_key, key_len);
        public_key = pem;
        if (public_key[key_len - 1] != 0) ++key_len;
    }
    ret = mbedtls_pk_parse_public_key(&pk, public_key, key_len);
    if (ret != 0) goto cleanup;
    if (mbedtls_pk_get_type(&pk) != MBEDTLS_PK_RSA || mbedtls_pk_get_bitlen(&pk) != 2048) { ret = MBEDTLS_ERR_PK_TYPE_MISMATCH; goto cleanup; }
    ret = mbedtls_rsa_set_padding(mbedtls_pk_rsa(pk), MBEDTLS_RSA_PKCS_V15, MBEDTLS_MD_NONE);
    if (ret != 0) goto cleanup;
    static const unsigned char personalization[] = "ZeroWork BMC RSA 1";
    ret = mbedtls_ctr_drbg_seed(&rng, mbedtls_entropy_func, &entropy, personalization, sizeof(personalization) - 1);
    if (ret != 0) goto cleanup;
    ret = mbedtls_pk_encrypt(&pk, plaintext, plaintext_len, encrypted, &encrypted_len, sizeof(encrypted), mbedtls_ctr_drbg_random, &rng);
    if (ret != 0 || encrypted_len != 256) goto cleanup;
    if (ret == 0 && encrypted_len == 256) {
        memcpy(output, encrypted, encrypted_len);
        *output_len = encrypted_len;
    } else if (ret == 0) ret = MBEDTLS_ERR_PK_BAD_INPUT_DATA;
cleanup:
    free(pem);
    mbedtls_platform_zeroize(encrypted, sizeof(encrypted));
    mbedtls_pk_free(&pk);
    mbedtls_ctr_drbg_free(&rng);
    mbedtls_entropy_free(&entropy);
    return ret;
}

int zw_bmc_rsa2048_base64(const unsigned char *public_key, size_t key_len,
                        const unsigned char *plaintext, size_t plaintext_len,
                        unsigned char *output, size_t output_cap, size_t *output_len) {
    if (output_len) *output_len = 0;
    if (!output || output_cap < 344 || !output_len) return ZW_BMC_TLS_INVALID;
    unsigned char encrypted[256], encoded[345];
    size_t encrypted_len = 0, encoded_len = 0;
    int ret = zw_bmc_rsa2048_encrypt(public_key, key_len, plaintext, plaintext_len,
                                   encrypted, sizeof(encrypted), &encrypted_len);
    if (ret == 0) ret = mbedtls_base64_encode(encoded, sizeof(encoded), &encoded_len, encrypted, encrypted_len);
    if (ret == 0 && encoded_len == 344) {
        memcpy(output, encoded, encoded_len);
        if (output_cap > encoded_len) output[encoded_len] = 0;
        *output_len = encoded_len;
    } else if (ret == 0) ret = MBEDTLS_ERR_PK_BAD_INPUT_DATA;
    mbedtls_platform_zeroize(encrypted, sizeof(encrypted));
    mbedtls_platform_zeroize(encoded, sizeof(encoded));
    return ret;
}
