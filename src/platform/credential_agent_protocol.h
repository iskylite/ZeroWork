#ifndef ZW_CREDENTIAL_AGENT_PROTOCOL_H
#define ZW_CREDENTIAL_AGENT_PROTOCOL_H
#include <Security/Security.h>
#include <CommonCrypto/CommonDigest.h>
#include <stdint.h>
#include <stdio.h>
#include <unistd.h>
#include <errno.h>

#define ZW_CREDENTIAL_MAGIC 0x5a574331u
#define ZW_CREDENTIAL_LIMIT (8u * 1024u * 1024u)
struct zw_credential_request { uint32_t magic, operation, allow_ui, service_length, data_length; };
struct zw_credential_response { int32_t status; uint32_t data_length; };

static int zw_transfer(int fd, void *bytes, size_t length, int writing) {
    unsigned char *p = bytes;
    while (length) {
        ssize_t n = writing ? write(fd, p, length) : read(fd, p, length);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) return 0;
        p += n; length -= (size_t)n;
    }
    return 1;
}

// Pin both the code identifier and the exact leaf certificate. Trust settings,
// a matching display name, a shared UID, or a path alone never authorize a peer.
static OSStatus zw_peer_requirement(int helper_peer, SecRequirementRef *out) {
    SecCodeRef self = NULL;
    CFDictionaryRef info = NULL;
    OSStatus status = SecCodeCopySelf(kSecCSDefaultFlags, &self);
    if (!status) status = SecCodeCheckValidity(self, kSecCSStrictValidate, NULL);
    if (!status) status = SecCodeCopySigningInformation(self, kSecCSSigningInformation, &info);
    if (self) CFRelease(self);
    if (status) return status;
    CFStringRef identifier = CFDictionaryGetValue(info, kSecCodeInfoIdentifier);
    CFArrayRef certificates = CFDictionaryGetValue(info, kSecCodeInfoCertificates);
    if (!identifier || !certificates || CFArrayGetCount(certificates) == 0) {
        CFRelease(info); return errSecAuthFailed;
    }
    CFMutableStringRef peer = CFStringCreateMutableCopy(NULL, 0, identifier);
    const CFStringRef suffix = CFSTR(".credentials");
    if (helper_peer) CFStringAppend(peer, suffix);
    else if (CFStringHasSuffix(peer, suffix))
        CFStringDelete(peer, CFRangeMake(CFStringGetLength(peer) - CFStringGetLength(suffix), CFStringGetLength(suffix)));
    else { CFRelease(peer); CFRelease(info); return errSecAuthFailed; }
    char name[256];
    if (!CFStringGetCString(peer, name, sizeof(name), kCFStringEncodingUTF8)) {
        CFRelease(peer); CFRelease(info); return errSecAuthFailed;
    }
    for (const char *p = name; *p; p++) if (!((*p >= 'a' && *p <= 'z') || (*p >= 'A' && *p <= 'Z') ||
        (*p >= '0' && *p <= '9') || *p == '.' || *p == '-')) {
        CFRelease(peer); CFRelease(info); return errSecAuthFailed;
    }
    CFDataRef der = SecCertificateCopyData((SecCertificateRef)CFArrayGetValueAtIndex(certificates, 0));
    unsigned char digest[CC_SHA1_DIGEST_LENGTH];
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    CC_SHA1(CFDataGetBytePtr(der), (CC_LONG)CFDataGetLength(der), digest);
#pragma clang diagnostic pop
    char hex[CC_SHA1_DIGEST_LENGTH * 2 + 1];
    for (size_t i = 0; i < sizeof(digest); i++) snprintf(hex + i * 2, 3, "%02x", digest[i]);
    CFStringRef text = CFStringCreateWithFormat(NULL, NULL, CFSTR("identifier \"%@\" and certificate leaf = H\"%s\""), peer, hex);
    status = SecRequirementCreateWithString(text, kSecCSDefaultFlags, out);
    CFRelease(text); CFRelease(der); CFRelease(peer); CFRelease(info);
    return status;
}
#endif
