// Standalone native regression: all Security calls are replaced before including
// the production bridge. This binary cannot access Keychain or display its UI.
#include <CoreFoundation/CoreFoundation.h>
#include <Security/Security.h>
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static CFDataRef fake_item;
static Boolean fake_interaction = true;
static int reads, ref_reads, additions, updates, deletions, legacy_deletions;
static CFStringRef expected_service = CFSTR("com.zerowork.tests.mock-only");
static int other_item_exists;
static OSStatus fail_read, fail_write, fail_delete;
static void check_query(CFDictionaryRef q) {
    assert(!fake_interaction);
    assert(CFEqual(CFDictionaryGetValue(q, kSecAttrService), expected_service));
    assert(CFEqual(CFDictionaryGetValue(q, kSecAttrAccount), CFSTR("vault-v1")));
}
static OSStatus fake_copy(CFDictionaryRef q, CFTypeRef *result) {
    check_query(q);
    if (CFDictionaryGetValue(q, kSecReturnRef)) {
        ref_reads++;
        assert(!CFDictionaryGetValue(q, kSecReturnData));
        if (!fake_item) return errSecItemNotFound;
        *result = CFRetain(CFSTR("legacy-owned-reference")); return errSecSuccess;
    }
    reads++;
    if (fail_read) return fail_read;
    if (!fake_item) return errSecItemNotFound;
    *result = CFRetain(fake_item); return errSecSuccess;
}
static OSStatus fake_add(CFDictionaryRef q, CFTypeRef *result) {
    (void)result; check_query(q); additions++;
    if (fail_write) return fail_write;
    if (fake_item) return errSecDuplicateItem;
    fake_item = CFRetain(CFDictionaryGetValue(q, kSecValueData)); return errSecSuccess;
}
static OSStatus fake_update(CFDictionaryRef q, CFDictionaryRef changes) {
    check_query(q); updates++;
    if (fail_write) return fail_write;
    if (!fake_item) return errSecItemNotFound;
    CFRelease(fake_item); fake_item = CFRetain(CFDictionaryGetValue(changes, kSecValueData)); return errSecSuccess;
}
static OSStatus fake_delete(CFDictionaryRef q) {
    check_query(q); deletions++;
    assert(!CFDictionaryGetValue(q, kSecReturnData));
    if (CFEqual(expected_service, CFSTR("com.zerowork.tests.other-scope"))) {
        if (!other_item_exists) return errSecItemNotFound;
        other_item_exists = 0; return errSecSuccess;
    }
    if (fail_delete) return fail_delete;
    if (fail_write) return fail_write;
    if (!fake_item) return errSecItemNotFound;
    CFRelease(fake_item); fake_item = NULL; return errSecSuccess;
}
static CFTypeID fake_item_type_id(void) { return CFStringGetTypeID(); }
static OSStatus fake_legacy_delete(SecKeychainItemRef item) {
    assert(!fake_interaction && CFEqual(item, CFSTR("legacy-owned-reference")));
    legacy_deletions++;
    if (!fake_item) return errSecItemNotFound;
    CFRelease(fake_item); fake_item = NULL; return errSecSuccess;
}
static OSStatus fake_get_interaction(Boolean *value) { *value = fake_interaction; return errSecSuccess; }
static OSStatus fake_set_interaction(Boolean value) { fake_interaction = value; return errSecSuccess; }
#define SecItemCopyMatching fake_copy
#define SecItemAdd fake_add
#define SecItemUpdate fake_update
#define SecItemDelete fake_delete
#define SecKeychainGetUserInteractionAllowed fake_get_interaction
#define SecKeychainSetUserInteractionAllowed fake_set_interaction
#define SecKeychainItemGetTypeID fake_item_type_id
#define SecKeychainItemDelete fake_legacy_delete
#include "macos_credentials.m"

static void reset_cache(void) {
    if (cached_service) CFRelease(cached_service);
    if (cached_vault) CFRelease(cached_vault);
    cached_service = NULL; cached_vault = NULL; vault_exists = 0;
}
static void expect_secret(const char *reference, const char *expected) {
    unsigned char *value = NULL; size_t length = 0;
    assert(zw_credentials_get("com.zerowork.tests.mock-only", reference, &value, &length) == errSecSuccess);
    assert(length == strlen(expected) && !memcmp(value, expected, length));
    zw_credentials_free(value, length);
}
int main(void) {
    const char *scope = "com.zerowork.tests.mock-only";
    const char *a = "zw1_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const char *b = "zw1_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
    const char *c = "zw1_cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc";
    // Reset is metadata-only, even on the first call with unreadable contents.
    fail_read = errSecInteractionNotAllowed;
    fake_item = CFDataCreate(NULL, (const unsigned char *)"unreadable fixture", 18);
    assert(fake_item && zw_credentials_erase(scope) == errSecSuccess);
    assert(!fake_item && !cached_service && reads == 0 && fake_interaction);
    assert(zw_credentials_erase(scope) == errSecSuccess); // Missing is success.
    assert(reads == 0 && ref_reads == 0 && fake_interaction);
    fail_read = errSecSuccess;
    assert(zw_credentials_add(scope, a, (const unsigned char *)"owned-first", 11) == errSecSuccess);
    assert(reads == 1 && additions == 1 && updates == 0 && fake_interaction);
    assert(zw_credentials_add(scope, b, (const unsigned char *)"owned-second", 12) == errSecSuccess);
    expect_secret(a, "owned-first"); expect_secret(b, "owned-second");
    assert(reads == 1 && additions == 1 && updates == 1 && fake_interaction);
    assert(zw_credentials_add(scope, a, (const unsigned char *)"overwrite", 9) == errSecDuplicateItem);
    fail_write = errSecAuthFailed;
    assert(zw_credentials_add(scope, c, (const unsigned char *)"owned-rejected", 14) == errSecAuthFailed);
    unsigned char *missing = NULL; size_t length = 0;
    assert(zw_credentials_get(scope, c, &missing, &length) == errSecItemNotFound);
    expect_secret(a, "owned-first"); assert(fake_interaction);
    fail_write = errSecSuccess;
    unsigned char *large = malloc(8 * 1024 * 1024); assert(large); memset(large, 'x', 8 * 1024 * 1024);
    int writes_before = updates;
    assert(zw_credentials_add(scope, c, large, 8 * 1024 * 1024) == errSecDataTooLarge);
    free(large); assert(updates == writes_before);
    assert(zw_credentials_get(scope, c, &missing, &length) == errSecItemNotFound);
    expect_secret(a, "owned-first");
    // Simulate a new app process by dropping only its in-memory cache.
    reset_cache(); expect_secret(a, "owned-first"); expect_secret(b, "owned-second");
    assert(reads == 2 && additions == 1 && fake_interaction);
    assert(zw_credentials_collect(scope, &a, 1) == errSecSuccess);
    assert(zw_credentials_get(scope, b, &missing, &length) == errSecItemNotFound);
    expect_secret(a, "owned-first");
    CFMutableDictionaryRef before_erase = cached_vault;
    fail_delete = errSecAuthFailed;
    assert(zw_credentials_erase(scope) == errSecAuthFailed);
    assert(cached_vault == before_erase && vault_exists && CFDictionaryGetCount(cached_vault) == 1);
    expect_secret(a, "owned-first"); assert(reads == 2 && fake_interaction);
    fail_delete = errSecSuccess;
    // A successful deletion in another service cannot clear this scope's cache.
    expected_service = CFSTR("com.zerowork.tests.other-scope"); other_item_exists = 1;
    assert(zw_credentials_erase("com.zerowork.tests.other-scope") == errSecSuccess);
    assert(!other_item_exists && cached_vault == before_erase && vault_exists && fake_item);
    expected_service = CFSTR("com.zerowork.tests.mock-only"); expect_secret(a, "owned-first");
    assert(zw_credentials_erase(scope) == errSecSuccess);
    assert(!fake_item && reads == 2 && fake_interaction && !vault_exists && CFDictionaryGetCount(cached_vault) == 0);
    assert(zw_credentials_add(scope, a, (const unsigned char *)"owned-first", 11) == errSecSuccess);
    fail_delete = errSecInvalidOwnerEdit; fail_read = errSecInteractionNotAllowed;
    int reads_before_metadata_delete = reads;
    assert(zw_credentials_erase(scope) == errSecSuccess);
    assert(legacy_deletions == 1 && ref_reads == 1 && !fake_item && fake_interaction);
    assert(reads == reads_before_metadata_delete && !vault_exists && CFDictionaryGetCount(cached_vault) == 0);
    fail_delete = errSecSuccess;
    reset_cache(); fail_read = errSecInteractionNotAllowed;
    assert(zw_credentials_get(scope, a, &missing, &length) == errSecInteractionNotAllowed);
    assert(!cached_service && fake_interaction);
    puts("native vault mock regression passed: one item, cached reads, immutable refs, rollback, size limit, restart, metadata-only erase, cache isolation, legacy deletion fallback, no UI");
    return 0;
}
