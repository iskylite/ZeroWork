#include "bmc_tls_trust.h"
#include <CoreFoundation/CoreFoundation.h>
#include <Security/Security.h>
#include <Security/SecCertificateOIDs.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <unistd.h>

static void copy_string(CFStringRef value, char out[256]) {
    out[0] = 0;
    if (!value || CFGetTypeID(value) != CFStringGetTypeID()) return;
    /* Truncate by characters while preserving UTF-8 validity. */
    CFIndex used = 0;
    CFStringGetBytes(value, CFRangeMake(0, CFStringGetLength(value)),
                     kCFStringEncodingUTF8, '?', false, (UInt8 *)out, 255, &used);
    out[used] = 0;
}

static CFTypeRef certificate_value(CFDictionaryRef values, CFStringRef oid) {
    CFDictionaryRef entry = CFDictionaryGetValue(values, oid);
    if (!entry || CFGetTypeID(entry) != CFDictionaryGetTypeID()) return NULL;
    return CFDictionaryGetValue(entry, kSecPropertyKeyValue);
}

static void append_property_strings(CFTypeRef value, char out[256], unsigned depth) {
    if (!value || depth > 8) return;
    if (CFGetTypeID(value) == CFStringGetTypeID()) {
        char text[256]; copy_string(value, text);
        size_t used = strlen(out), length = strlen(text);
        if (!length || used + length + 3 > 256) return;
        if (used) { memcpy(out + used, ", ", 2); used += 2; }
        memcpy(out + used, text, length + 1);
    } else if (CFGetTypeID(value) == CFArrayGetTypeID()) {
        for (CFIndex i = 0; i < CFArrayGetCount(value); ++i)
            append_property_strings(CFArrayGetValueAtIndex(value, i), out, depth + 1);
    } else if (CFGetTypeID(value) == CFDictionaryGetTypeID())
        append_property_strings(CFDictionaryGetValue(value, kSecPropertyKeyValue), out, depth + 1);
}

static int64_t certificate_time(CFDictionaryRef values, CFStringRef oid) {
    CFTypeRef value = certificate_value(values, oid);
    double time = 0;
    if (value && CFGetTypeID(value) == CFDateGetTypeID())
        time = CFDateGetAbsoluteTime(value);
    else if (value && CFGetTypeID(value) == CFNumberGetTypeID()) {
        if (!CFNumberGetValue(value, kCFNumberDoubleType, &time)) return 0;
    } else return 0;
    return (int64_t)(time + kCFAbsoluteTimeIntervalSince1970);
}

static uint32_t failure_for_status(OSStatus status) {
    switch (status) {
    case errSecHostNameMismatch: return ZW_TLS_HOSTNAME_MISMATCH;
    case errSecCertificateExpired: return ZW_TLS_EXPIRED;
    case errSecCertificateNotValidYet: return ZW_TLS_NOT_YET_VALID;
    /* SecBase.h: errSecCertificateValidityPeriodTooLong is -67901. This
     * specific policy error is not errSecCertificateExpired (-67818). */
    case errSecCertificateValidityPeriodTooLong: return ZW_TLS_EXCESSIVE_VALIDITY;
    case errSecCertificateRevoked: return ZW_TLS_REVOKED;
    case errSecNotTrusted: case errSecCreateChainFailed: return ZW_TLS_UNTRUSTED_ISSUER;
    case errSecNotAvailable: case errSecServiceNotAvailable: return ZW_TLS_EVALUATION_UNAVAILABLE;
    default: return ZW_TLS_INVALID_CHAIN;
    }
}

/* SecTrustCopyResult is public. Its optional per-check details provide all
 * simultaneous failures instead of only the prioritized CFError. Unknown
 * detail names, missing details or changed shapes fail closed: we never infer
 * that an unreported error was covered by a user exception. */
typedef struct { uint32_t failures; int count; int malformed; } detail_context;
static void collect_detail(const void *key, const void *value, void *opaque) {
    detail_context *context = opaque;
    if (CFGetTypeID(key) == CFStringGetTypeID() && CFEqual(key, CFSTR("StatusCodes"))) return;
    if (CFGetTypeID(key) != CFStringGetTypeID() ||
        CFGetTypeID(value) != CFBooleanGetTypeID()) {
        context->malformed = 1;
        return;
    }
    if (CFBooleanGetValue(value)) return;
    context->count++;
    if (CFEqual(key, CFSTR("SSLHostname"))) context->failures |= ZW_TLS_HOSTNAME_MISMATCH;
    else if (CFEqual(key, CFSTR("OtherTrustValidityPeriod")))
        context->failures |= ZW_TLS_EXCESSIVE_VALIDITY;
    else if (CFEqual(key, CFSTR("AnchorTrusted")) || CFEqual(key, CFSTR("MissingIntermediate")))
        context->failures |= ZW_TLS_UNTRUSTED_ISSUER;
    else if (CFEqual(key, CFSTR("TemporalValidity")) || CFEqual(key, CFSTR("ValidLeaf")) ||
             CFEqual(key, CFSTR("ValidIntermediates"))) {
        /* Exact direction is read from certificate dates below. */
    } else if (CFEqual(key, CFSTR("Revocation"))) context->failures |= ZW_TLS_REVOKED;
    else context->failures |= ZW_TLS_INVALID_CHAIN;
}

int zw_bmc_tls_evaluate(const char *host, const zw_bmc_tls_der *chain,
                        size_t count, zw_bmc_tls_verification *out) {
    if (!host || !*host || !chain || !out || !count || count > 16) return -1;
    memset(out, 0, sizeof(*out));
    CFMutableArrayRef certificates = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
    CFStringRef hostname = CFStringCreateWithCString(NULL, host, kCFStringEncodingUTF8);
    SecPolicyRef policy = hostname ? SecPolicyCreateSSL(true, hostname) : NULL;
    SecTrustRef trust = NULL;
    CFErrorRef error = NULL;
    if (!certificates || !hostname || !policy) goto unavailable;
    size_t total = 0;
    const int64_t now = (int64_t)(CFAbsoluteTimeGetCurrent() + kCFAbsoluteTimeIntervalSince1970);
    for (size_t i = 0; i < count; ++i) {
        if (!chain[i].data || !chain[i].length || chain[i].length > 1024 * 1024 - total) goto invalid;
        total += chain[i].length;
        CFDataRef der = CFDataCreate(NULL, chain[i].data, (CFIndex)chain[i].length);
        SecCertificateRef cert = der ? SecCertificateCreateWithData(NULL, der) : NULL;
        if (der) CFRelease(der);
        if (!cert) goto invalid;
        CFArrayAppendValue(certificates, cert);
        CFDictionaryRef values = SecCertificateCopyValues(cert, NULL, NULL);
        if (!values) { CFRelease(cert); goto invalid; }
        int64_t before = certificate_time(values, kSecOIDX509V1ValidityNotBefore);
        int64_t after = certificate_time(values, kSecOIDX509V1ValidityNotAfter);
        if (!before || !after || before > after) out->failures |= ZW_TLS_INVALID_CHAIN;
        else {
            if (now < before) out->failures |= ZW_TLS_NOT_YET_VALID;
            if (now > after) out->failures |= ZW_TLS_EXPIRED;
        }
        if (i == 0) {
            CFStringRef subject = SecCertificateCopySubjectSummary(cert);
            copy_string(subject, out->subject);
            if (subject) CFRelease(subject);
            append_property_strings(certificate_value(values, kSecOIDX509V1IssuerName), out->issuer, 0);
            out->not_before_unix = before;
            out->not_after_unix = after;
        }
        CFRelease(values);
        CFRelease(cert);
    }
    out->native_status = SecTrustCreateWithCertificates(certificates, policy, &trust);
    if (out->native_status != errSecSuccess || !trust) goto unavailable;
    /* Do not call SecTrustSetAnchorCertificates: local system roots are the
     * default. A route must never trigger AIA/OCSP/CRL traffic outside itself. */
    out->native_status = SecTrustSetNetworkFetchAllowed(trust, false);
    if (out->native_status != errSecSuccess) goto unavailable;
    if (!SecTrustEvaluateWithError(trust, &error)) {
        out->native_status = error ? (OSStatus)CFErrorGetCode(error) : errSecNotAvailable;
        detail_context context = {0};
        CFDictionaryRef result = SecTrustCopyResult(trust);
        CFArrayRef details = result ? CFDictionaryGetValue(result, CFSTR("TrustResultDetails")) : NULL;
        if (details && CFGetTypeID(details) == CFArrayGetTypeID()) {
            for (CFIndex i = 0; i < CFArrayGetCount(details); ++i) {
                CFTypeRef detail = CFArrayGetValueAtIndex(details, i);
                if (CFGetTypeID(detail) != CFDictionaryGetTypeID()) context.malformed = 1;
                else CFDictionaryApplyFunction(detail, collect_detail, &context);
            }
        } else context.malformed = 1;
        out->failures |= context.failures | failure_for_status(out->native_status);
        if (context.malformed || !context.count) out->failures |= ZW_TLS_INVALID_CHAIN;
        if (result) CFRelease(result);
    } else out->native_status = 0;
    goto done;
invalid:
    out->failures |= ZW_TLS_INVALID_CHAIN;
    goto done;
unavailable:
    out->failures |= ZW_TLS_EVALUATION_UNAVAILABLE;
done:
    if (error) CFRelease(error);
    if (trust) CFRelease(trust);
    if (policy) CFRelease(policy);
    if (hostname) CFRelease(hostname);
    if (certificates) CFRelease(certificates);
    return 0;
}

static int safe_fd(int fd, int directory) {
    struct stat st;
    return fd >= 0 && fstat(fd, &st) == 0 && st.st_uid == getuid() &&
           !(st.st_mode & 0022) && (directory ? S_ISDIR(st.st_mode) : S_ISREG(st.st_mode));
}
static int open_directory(const char *path, int create) {
    if (!path || path[0] != '/' || !path[1]) return -1;
    int created = 0;
    int fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (fd < 0 && errno == ENOENT && create) {
        if (mkdir(path, 0700) == 0) created = 1;
        else if (errno != EEXIST) return -1;
        fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    }
    if (!safe_fd(fd, 1)) {
        if (fd >= 0) { close(fd); errno = EPERM; }
        return -1;
    }
    if (created) {
        const char *slash = strrchr(path, '/');
        char *parent = slash == path ? strdup("/") : strndup(path, (size_t)(slash - path));
        int parent_fd = parent ? open(parent, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) : -1;
        free(parent);
        int synced = parent_fd >= 0 ? fsync(parent_fd) : -1;
        if (parent_fd >= 0) close(parent_fd);
        if (synced != 0) { close(fd); errno = EIO; return -1; }
    }
    return fd;
}
static void pin_name(const uint8_t key[32], char name[69]) {
    static const char hex[] = "0123456789abcdef";
    for (size_t i = 0; i < 32; ++i) {
        name[i * 2] = hex[key[i] >> 4]; name[i * 2 + 1] = hex[key[i] & 15];
    }
    memcpy(name + 64, ".pin", 5);
}
static int read_all(int fd, uint8_t *bytes, size_t count) {
    while (count) {
        ssize_t n = read(fd, bytes, count);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) return -1;
        bytes += n; count -= (size_t)n;
    }
    uint8_t extra;
    return read(fd, &extra, 1) == 0 ? 0 : -1;
}
static int write_all(int fd, const uint8_t *bytes, size_t count) {
    while (count) {
        ssize_t n = write(fd, bytes, count);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) return -1;
        bytes += n; count -= (size_t)n;
    }
    return 0;
}
/* The version and authority digest are inside the record as well as its name. */
static int load_at(int dir, const uint8_t key[32], uint8_t out[68]) {
    char name[69]; pin_name(key, name);
    int fd = openat(dir, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
    if (fd < 0) return errno == ENOENT ? 1 : -1;
    uint8_t record[108];
    int result = -1;
    if (safe_fd(fd, 0) && read_all(fd, record, sizeof(record)) == 0 &&
        !memcmp(record, "ZWTLS001", 8) && !memcmp(record + 8, key, 32)) {
        memcpy(out, record + 40, 68); result = 0;
    }
    close(fd); return result;
}
static int lock_at(int dir) {
    int fd = openat(dir, ".lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0600);
    if (!safe_fd(fd, 0)) { if (fd >= 0) close(fd); return -1; }
    while (flock(fd, LOCK_EX) != 0) {
        if (errno == EINTR) continue;
        close(fd); return -1;
    }
    return fd;
}
int zw_bmc_tls_pin_load(const char *directory, const uint8_t key[32], uint8_t out[68]) {
    if (!key || !out) return -1;
    int dir = open_directory(directory, 0);
    if (dir < 0) return errno == ENOENT ? 1 : -1;
    int lock = lock_at(dir);
    if (lock < 0) { close(dir); return -1; }
    int result = load_at(dir, key, out);
    close(lock); close(dir); return result;
}
int zw_bmc_tls_pin_save(const char *directory, const uint8_t key[32],
                        const uint8_t *expected, const uint8_t next[68]) {
    if (!key || !next) return -1;
    int dir = open_directory(directory, 1);
    if (dir < 0) return -1;
    int lock = lock_at(dir);
    if (lock < 0) { close(dir); return -1; }
    uint8_t current[68];
    int loaded = load_at(dir, key, current);
    int result = -1;
    if (loaded < 0) goto done;
    if ((!expected && loaded != 1) || (expected && (loaded != 0 || memcmp(expected, current, 68)))) {
        result = 2; goto done;
    }
    char name[69], temporary[80];
    pin_name(key, name);
    uint8_t random[16]; arc4random_buf(random, sizeof(random));
    static const char hex[] = "0123456789abcdef";
    memcpy(temporary, ".tmp-", 5);
    for (size_t i = 0; i < sizeof(random); ++i) {
        temporary[5 + i * 2] = hex[random[i] >> 4]; temporary[6 + i * 2] = hex[random[i] & 15];
    }
    temporary[37] = 0;
    int fd = openat(dir, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
    if (fd < 0) goto done;
    uint8_t record[108];
    memcpy(record, "ZWTLS001", 8); memcpy(record + 8, key, 32); memcpy(record + 40, next, 68);
    int wrote = write_all(fd, record, sizeof(record));
    if (wrote == 0) wrote = fsync(fd);
    if (close(fd) != 0) wrote = -1;
    if (wrote == 0 && renameat(dir, temporary, dir, name) == 0 && fsync(dir) == 0) result = 0;
    unlinkat(dir, temporary, 0);
done:
    close(lock); close(dir); return result;
}
