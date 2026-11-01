#ifndef ZEROWORK_SSH_PRIVATE_KEY_H
#define ZEROWORK_SSH_PRIVATE_KEY_H

#include <sys/stat.h>
#include <mbedtls/pk.h>
#include <mbedtls/pem.h>
#include <mbedtls/oid.h>
#include <mbedtls/pkcs5.h>
#include <mbedtls/platform_util.h>
/* The pinned libssh2 parser already implements OpenSSH bcrypt/AES decoding.
   Its Mbed TLS RSA loader does not consume that format. Reuse its bounded SSH
   field reader and decryptor, then let Mbed TLS validate/export the RSA key. */
#include "../../../vendor/libssh2/src/misc.h"
extern int _libssh2_openssh_pem_parse_memory(LIBSSH2_SESSION *, const unsigned char *, const char *, size_t, struct string_buf **);
static int zw_key_random(void *context, unsigned char *output, size_t length) {
    (void)context;
    arc4random_buf(output, length);
    return 0;
}

#define ZW_PRIVATE_KEY_MAX (1024 * 1024)
typedef struct { unsigned char *data; size_t length; size_t capacity; } zw_private_key;

static void zw_private_key_free(zw_private_key *key) {
    if (key->data) {
        mbedtls_platform_zeroize(key->data, key->capacity);
        free(key->data);
    }
    memset(key, 0, sizeof(*key));
}

static int zw_private_key_read(const char *path, zw_private_key *key) {
    /* Do not wait for a writer if a configured path is a FIFO. fstat below
       accepts regular files only; O_NONBLOCK does not affect their reads. */
    int fd = open(path, O_RDONLY | O_CLOEXEC | O_NONBLOCK);
    if (fd < 0) return ZW_SSH_KEY_UNREADABLE;
    struct stat info;
    int result = ZW_SSH_KEY_INVALID;
    if (fstat(fd, &info) != 0) { result = ZW_SSH_KEY_UNREADABLE; goto done; }
    if (!S_ISREG(info.st_mode) || info.st_size <= 0 || info.st_size > ZW_PRIVATE_KEY_MAX) goto done;
    key->capacity = (size_t)info.st_size + 1;
    key->data = calloc(1, key->capacity);
    if (!key->data) { result = LIBSSH2_ERROR_ALLOC; goto done; }
    while (key->length < (size_t)info.st_size) {
        ssize_t count = read(fd, key->data + key->length, (size_t)info.st_size - key->length);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) { result = ZW_SSH_KEY_UNREADABLE; goto done; }
        key->length += (size_t)count;
    }
    result = 0;
done:
    close(fd);
    if (result) zw_private_key_free(key);
    return result;
}

/* libssh2's Mbed TLS frommemory loader appends a NUL. Normalize strict DER
   through Mbed TLS's PEM writer, without a plaintext temporary file. */
static int zw_private_key_export(mbedtls_pk_context *pk, zw_private_key *key) {
    zw_private_key pem = { .data = calloc(1, 16384), .capacity = 16384 };
    if (!pem.data) return LIBSSH2_ERROR_ALLOC;
    if (mbedtls_pk_write_key_pem(pk, pem.data, pem.capacity)) { zw_private_key_free(&pem); return ZW_SSH_KEY_INVALID; }
    pem.length = strlen((const char *)pem.data);
    zw_private_key_free(key);
    *key = pem;
    return 0;
}

static int zw_key_string(struct string_buf *buffer, unsigned char **value, size_t *length) {
    return _libssh2_get_string(buffer, value, length) || *length > ZW_PRIVATE_KEY_MAX;
}

static int zw_key_equal(const unsigned char *value, size_t length, const char *expected) {
    return length == strlen(expected) && memcmp(value, expected, length) == 0;
}

static size_t zw_openssh_cipher_blocksize(const unsigned char *cipher, size_t length) {
    /* These are the cipher block sizes in the pinned Mbed TLS backend's
       libssh2 crypt.c table. The supported-algorithm check remains separate. */
    static const char *aes[] = { "aes128-ctr", "aes192-ctr", "aes256-ctr", "aes128-cbc", "aes192-cbc", "aes256-cbc", "rijndael-cbc@lysator.liu.se" };
    static const char *legacy[] = { "3des-cbc", "blowfish-cbc", "arcfour", "arcfour128" };
    for (size_t index = 0; index < sizeof(aes) / sizeof(*aes); index++) if (zw_key_equal(cipher, length, aes[index])) return 16;
    for (size_t index = 0; index < sizeof(legacy) / sizeof(*legacy); index++) if (zw_key_equal(cipher, length, legacy[index])) return 8;
    return 0;
}

/* Validate framing and KDF work before invoking the existing decryptor. No
   encryption is inferred from a generic parse/file/server error. */
static int zw_openssh_key_metadata(LIBSSH2_SESSION *session, const zw_private_key *key, int *encrypted) {
    mbedtls_pem_context pem;
    mbedtls_pem_init(&pem);
    size_t used = 0;
    int result = ZW_SSH_KEY_INVALID;
    if (mbedtls_pem_read_buffer(&pem, "-----BEGIN OPENSSH PRIVATE KEY-----", "-----END OPENSSH PRIVATE KEY-----", key->data, NULL, 0, &used)) goto done;
    unsigned char *data = pem.MBEDTLS_PRIVATE(buf);
    size_t length = pem.MBEDTLS_PRIVATE(buflen);
    static const char magic[] = "openssh-key-v1";
    if (length < sizeof(magic) || memcmp(data, magic, sizeof(magic))) goto done;
    struct string_buf buffer = { data, data + sizeof(magic), length };
    unsigned char *cipher, *kdf, *options, *public_key, *private_key;
    size_t cipher_len, kdf_len, options_len, public_len, private_len;
    uint32_t count;
    if (zw_key_string(&buffer, &cipher, &cipher_len) || zw_key_string(&buffer, &kdf, &kdf_len) || zw_key_string(&buffer, &options, &options_len) ||
        _libssh2_get_u32(&buffer, &count) || count != 1 || zw_key_string(&buffer, &public_key, &public_len) || zw_key_string(&buffer, &private_key, &private_len) || !private_len) goto done;
    if (!cipher_len || cipher_len > 64 || memchr(cipher, 0, cipher_len) || !kdf_len || kdf_len > 64 || memchr(kdf, 0, kdf_len)) goto done;
    *encrypted = !zw_key_equal(cipher, cipher_len, "none");
    size_t blocksize = 8;
    if (*encrypted) {
        if (!zw_key_equal(kdf, kdf_len, "bcrypt")) goto done;
        const char **algorithms = NULL;
        int algorithm_count = libssh2_session_supported_algs(session, LIBSSH2_METHOD_CRYPT_CS, &algorithms);
        int supported = 0;
        for (int index = 0; index < algorithm_count; index++) if (zw_key_equal(cipher, cipher_len, algorithms[index])) supported = 1;
        if (algorithms) libssh2_free(session, (void *)algorithms);
        if (!supported) goto done;
        blocksize = zw_openssh_cipher_blocksize(cipher, cipher_len);
        if (!blocksize) goto done;
        struct string_buf kdf_buffer = { options, options, options_len };
        unsigned char *salt;
        size_t salt_len;
        uint32_t rounds;
        /* Default OpenSSH work factor is 16. Refuse unbounded local KDF work. */
        if (zw_key_string(&kdf_buffer, &salt, &salt_len) || !salt_len || salt_len > 1024 || _libssh2_get_u32(&kdf_buffer, &rounds) || !rounds || rounds > 1024 || !_libssh2_eob(&kdf_buffer)) goto done;
    } else if (!zw_key_equal(kdf, kdf_len, "none") || options_len) goto done;
    /* Checkints, ssh-rsa, six nonempty mpints and a comment length must fit.
       A damaged encrypted blob cannot be repaired with another passphrase. */
    if (private_len < 8 + 4 + 7 + 6 * (4 + 1) + 4 || private_len % blocksize || !_libssh2_eob(&buffer)) goto done;
    struct string_buf public_buffer = { public_key, public_key, public_len };
    unsigned char *type;
    size_t type_len;
    if (zw_key_string(&public_buffer, &type, &type_len) || !zw_key_equal(type, type_len, "ssh-rsa")) goto done;
    result = 0;
done:
    mbedtls_pem_free(&pem);
    return result;
}

/* Validate the unencrypted envelope before attributing a decrypted ASN.1
   failure to a passphrase. No KDF/decryption runs during this check. */
static int zw_private_key_encrypted_der(const zw_private_key *key) {
    unsigned char *cursor = key->data;
    const unsigned char *end = key->data + key->length;
    size_t length;
    mbedtls_asn1_buf algorithm, parameters;
    mbedtls_md_type_t digest;
    mbedtls_cipher_type_t cipher;
    if (mbedtls_asn1_get_tag(&cursor, end, &length, MBEDTLS_ASN1_CONSTRUCTED | MBEDTLS_ASN1_SEQUENCE) || length != (size_t)(end - cursor) ||
        mbedtls_asn1_get_alg(&cursor, end, &algorithm, &parameters) ||
        parameters.tag != (MBEDTLS_ASN1_CONSTRUCTED | MBEDTLS_ASN1_SEQUENCE) || !parameters.len ||
        mbedtls_asn1_get_tag(&cursor, end, &length, MBEDTLS_ASN1_OCTET_STRING) || !length || length != (size_t)(end - cursor)) return 0;
    unsigned char *parameters_cursor = parameters.p;
    const unsigned char *parameters_end = parameters.p + parameters.len;
    if (MBEDTLS_OID_CMP(MBEDTLS_OID_PKCS5_PBES2, &algorithm) == 0) {
        mbedtls_asn1_buf kdf, kdf_parameters, encryption, iv;
        if (mbedtls_asn1_get_alg(&parameters_cursor, parameters_end, &kdf, &kdf_parameters) ||
            MBEDTLS_OID_CMP(MBEDTLS_OID_PKCS5_PBKDF2, &kdf) != 0 ||
            mbedtls_asn1_get_alg(&parameters_cursor, parameters_end, &encryption, &iv) || parameters_cursor != parameters_end ||
            mbedtls_oid_get_cipher_alg(&encryption, &cipher)) return 0;
        /* The public PBES2 routine validates KDF/PRF/cipher/IV parameters before
           returning for a zero-sized output, without deriving a key. */
        unsigned char unused;
        size_t output_length = 0;
        if (mbedtls_pkcs5_pbes2_ext(&parameters, MBEDTLS_PKCS5_DECRYPT, (const unsigned char *)"", 0,
            cursor, length, &unused, 0, &output_length) != MBEDTLS_ERR_ASN1_BUF_TOO_SMALL) return 0;
        parameters_cursor = kdf_parameters.p;
        parameters_end = kdf_parameters.p + kdf_parameters.len;
    } else {
        if (mbedtls_oid_get_pkcs12_pbe_alg(&algorithm, &digest, &cipher) || !mbedtls_md_info_from_type(digest)) return 0;
    }
    size_t salt_length;
    int iterations;
    if (mbedtls_asn1_get_tag(&parameters_cursor, parameters_end, &salt_length, MBEDTLS_ASN1_OCTET_STRING)) return 0;
    parameters_cursor += salt_length;
    if (mbedtls_asn1_get_int(&parameters_cursor, parameters_end, &iterations) || iterations <= 0) return 0;
    if (MBEDTLS_OID_CMP(MBEDTLS_OID_PKCS5_PBES2, &algorithm) != 0 && parameters_cursor != parameters_end) return 0;
    const mbedtls_cipher_info_t *info = mbedtls_cipher_info_from_type(cipher);
    if (!info || mbedtls_cipher_info_get_mode(info) != MBEDTLS_MODE_CBC) return 0;
    size_t blocksize = mbedtls_cipher_info_get_block_size(info);
    if (!blocksize || length < blocksize || length % blocksize) return 0;
    return 1;
}

static int zw_private_key_armor_encrypted_der(zw_private_key *key) {
    zw_private_key pem = { .capacity = key->length * 2 + 128 };
    pem.data = calloc(1, pem.capacity);
    if (!pem.data) return LIBSSH2_ERROR_ALLOC;
    size_t written = 0;
    int result = mbedtls_pem_write_buffer("-----BEGIN ENCRYPTED PRIVATE KEY-----\n", "-----END ENCRYPTED PRIVATE KEY-----\n",
        key->data, key->length, pem.data, pem.capacity, &written);
    if (result) { zw_private_key_free(&pem); return result; }
    pem.length = written - 1;
    zw_private_key_free(key);
    *key = pem;
    return 0;
}

static int zw_private_key_decrypted_format_error(int result) {
    /* Only malformed inner ASN.1 qualifies. Allocation, cipher/KDF support,
       IO and other parse failures must not be relabelled as a passphrase. */
    switch (result) {
    case MBEDTLS_ERR_ASN1_OUT_OF_DATA:
    case MBEDTLS_ERR_ASN1_UNEXPECTED_TAG:
    case MBEDTLS_ERR_ASN1_INVALID_LENGTH:
    case MBEDTLS_ERR_ASN1_LENGTH_MISMATCH:
    case MBEDTLS_ERR_ASN1_INVALID_DATA:
    case MBEDTLS_ERR_PK_KEY_INVALID_FORMAT:
    case MBEDTLS_ERR_PK_KEY_INVALID_FORMAT + MBEDTLS_ERR_ASN1_OUT_OF_DATA:
    case MBEDTLS_ERR_PK_KEY_INVALID_FORMAT + MBEDTLS_ERR_ASN1_UNEXPECTED_TAG:
    case MBEDTLS_ERR_PK_KEY_INVALID_FORMAT + MBEDTLS_ERR_ASN1_INVALID_LENGTH:
    case MBEDTLS_ERR_PK_KEY_INVALID_FORMAT + MBEDTLS_ERR_ASN1_LENGTH_MISMATCH:
    case MBEDTLS_ERR_PK_KEY_INVALID_FORMAT + MBEDTLS_ERR_ASN1_INVALID_DATA: return 1;
    default: return 0;
    }
}

static int zw_openssh_rsa_prepare(LIBSSH2_SESSION *session, const char *passphrase, zw_private_key *key) {
    int encrypted = 0;
    int result = zw_openssh_key_metadata(session, key, &encrypted);
    if (result) return result;
    if (encrypted && (!passphrase || !*passphrase)) return ZW_SSH_KEY_PASSPHRASE;
    struct string_buf *decoded = NULL;
    mbedtls_pk_context pk;
    mbedtls_pk_init(&pk);
    result = _libssh2_openssh_pem_parse_memory(session, (const unsigned char *)passphrase, (const char *)key->data, key->length, &decoded);
    if (result) {
        result = encrypted && (result == LIBSSH2_ERROR_KEYFILE_AUTH_FAILED || result == LIBSSH2_ERROR_DECRYPT) ? ZW_SSH_KEY_PASSPHRASE : ZW_SSH_KEY_INVALID;
        goto done;
    }
    unsigned char *type, *part[6], *comment;
    size_t type_len, length[6], comment_len;
    result = ZW_SSH_KEY_INVALID;
    if (zw_key_string(decoded, &type, &type_len) || !zw_key_equal(type, type_len, "ssh-rsa")) goto done;
    /* OpenSSH RSA fields: n, e, d, iqmp, p, q. */
    for (size_t index = 0; index < 6; index++) {
        if (_libssh2_get_bignum_bytes(decoded, &part[index], &length[index]) || !length[index] || length[index] > MBEDTLS_MPI_MAX_SIZE) goto done;
    }
    if (zw_key_string(decoded, &comment, &comment_len)) goto done;
    size_t padding = decoded->len - (size_t)(decoded->dataptr - decoded->data);
    if (padding > 255) goto done;
    for (size_t index = 0; index < padding; index++) if (decoded->dataptr[index] != index + 1) goto done;
    if (mbedtls_pk_setup(&pk, mbedtls_pk_info_from_type(MBEDTLS_PK_RSA))) goto done;
    mbedtls_rsa_context *rsa = mbedtls_pk_rsa(pk);
    if (mbedtls_rsa_import_raw(rsa, part[0], length[0], part[4], length[4], part[5], length[5], part[2], length[2], part[1], length[1]) || mbedtls_rsa_complete(rsa) || mbedtls_rsa_check_privkey(rsa)) goto done;
    result = zw_private_key_export(&pk, key);
done:
    if (decoded) {
        mbedtls_platform_zeroize(decoded->data, decoded->len);
        _libssh2_string_buf_free(session, decoded);
    }
    mbedtls_pk_free(&pk);
    return result;
}

static int zw_private_key_prepare(LIBSSH2_SESSION *session, const char *path, const char *passphrase, zw_private_key *key) {
    int result = zw_private_key_read(path, key);
    if (result) return result;
    if (strstr((const char *)key->data, "-----BEGIN OPENSSH PRIVATE KEY-----")) {
        result = zw_openssh_rsa_prepare(session, passphrase, key);
    } else {
        mbedtls_pk_context pk;
        mbedtls_pk_init(&pk);
        int is_pem = strstr((const char *)key->data, "-----BEGIN ") != NULL;
        if (!is_pem) {
            unsigned char *cursor = key->data;
            const unsigned char *end = key->data + key->length;
            size_t length;
            if (mbedtls_asn1_get_tag(&cursor, end, &length, MBEDTLS_ASN1_CONSTRUCTED | MBEDTLS_ASN1_SEQUENCE) || length != (size_t)(end - cursor)) result = ZW_SSH_KEY_INVALID;
        }
        int encrypted = !result && !is_pem && zw_private_key_encrypted_der(key);
        if (is_pem && strstr((const char *)key->data, "-----BEGIN RSA PRIVATE KEY-----") && strstr((const char *)key->data, "Proc-Type: 4,ENCRYPTED")) {
            mbedtls_pem_context pem;
            mbedtls_pem_init(&pem);
            size_t used = 0;
            result = mbedtls_pem_read_buffer(&pem, "-----BEGIN RSA PRIVATE KEY-----", "-----END RSA PRIVATE KEY-----", key->data, NULL, 0, &used);
            mbedtls_pem_free(&pem);
            /* PASSWORD_REQUIRED confirms this PEM block is encrypted. An
               empty-password probe additionally validates cipher block length;
               it uses only the public parser and never the caller's secret. */
            if (result == MBEDTLS_ERR_PEM_PASSWORD_REQUIRED) {
                mbedtls_pem_init(&pem);
                result = mbedtls_pem_read_buffer(&pem, "-----BEGIN RSA PRIVATE KEY-----", "-----END RSA PRIVATE KEY-----", key->data, (const unsigned char *)"", 0, &used);
                if (!result || result == MBEDTLS_ERR_PEM_PASSWORD_MISMATCH) { encrypted = 1; result = 0; }
                mbedtls_pem_free(&pem);
            }
        }
        if (is_pem && strstr((const char *)key->data, "-----BEGIN ENCRYPTED PRIVATE KEY-----")) {
            mbedtls_pem_context pem;
            mbedtls_pem_init(&pem);
            size_t used = 0;
            result = mbedtls_pem_read_buffer(&pem, "-----BEGIN ENCRYPTED PRIVATE KEY-----", "-----END ENCRYPTED PRIVATE KEY-----", key->data, NULL, 0, &used);
            zw_private_key der = { .data = pem.MBEDTLS_PRIVATE(buf), .length = pem.MBEDTLS_PRIVATE(buflen) };
            if (!result && !(encrypted = zw_private_key_encrypted_der(&der))) result = ZW_SSH_KEY_INVALID;
            mbedtls_pem_free(&pem);
        }
        /* DER auto-discovery masks some decrypt/parse errors, including an
           inner ASN.1 failure after a wrong password happens to pass padding.
           The public PEM entry point preserves their actual source. */
        if (!result && encrypted && !is_pem) result = zw_private_key_armor_encrypted_der(key);
        if (!result) result = mbedtls_pk_parse_key(&pk, key->data, key->length + (is_pem || encrypted ? 1 : 0),
            (const unsigned char *)passphrase, passphrase ? strlen(passphrase) : 0, zw_key_random, NULL);
        if (encrypted && zw_private_key_decrypted_format_error(result)) result = MBEDTLS_ERR_PK_PASSWORD_MISMATCH;
        /* The pinned backend's public-key extraction supports RSA only. Do
           not misreport another locally parsed key type as a server denial. */
        if (!result && mbedtls_pk_get_type(&pk) != MBEDTLS_PK_RSA) result = ZW_SSH_KEY_INVALID;
        if (!result && !is_pem) result = zw_private_key_export(&pk, key);
        mbedtls_pk_free(&pk);
        if (result && result != LIBSSH2_ERROR_ALLOC) result = result == MBEDTLS_ERR_PK_PASSWORD_REQUIRED || result == MBEDTLS_ERR_PK_PASSWORD_MISMATCH || result == MBEDTLS_ERR_PEM_PASSWORD_REQUIRED || result == MBEDTLS_ERR_PEM_PASSWORD_MISMATCH ? ZW_SSH_KEY_PASSPHRASE : ZW_SSH_KEY_INVALID;
    }
    if (result) zw_private_key_free(key);
    return result;
}
#endif
