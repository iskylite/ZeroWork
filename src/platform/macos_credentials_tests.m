// Standalone native regression: all Security calls are replaced before including
// the production bridge. This binary cannot access Keychain or display its UI.
#include <CoreFoundation/CoreFoundation.h>
#include <Security/Security.h>
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#if defined(ZW_CREDENTIALS_UI_FIXTURE)
// This executable is deliberately linked without Security or LocalAuthentication.
// Missing responses and warm-cache mutations must both remain off the host.
#include "macos_credentials.m"
static int count_export(void *context, const char *reference, const unsigned char *value, size_t length) {
    assert(owned_reference(reference) && value && length);
    ++*(int *)context;
    return 0;
}
int main(void) {
    const char *service = "com.zerowork.tests.fixture";
    const char *a = "zw1_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const char *b = "zw1_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
    const char *c = "zw1_cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc";
    const struct import_entry entry = { c, (const unsigned char *)"local", 5 };
    unsigned char *out = NULL; size_t length = 0;
    int count = 0;
    assert(unsetenv("ZW_TEST_CREDENTIAL_RESPONSE") == 0);
    assert(!zw_credentials_cached());
    assert(zw_credentials_authorize(service) == errSecNotAvailable);
    assert(zw_credentials_get(service, a, &out, &length) == errSecNotAvailable);
    assert(zw_credentials_add(service, b, (const unsigned char *)"mock", 4) == errSecNotAvailable);
    assert(zw_credentials_delete(service, b) == errSecNotAvailable);
    assert(zw_credentials_collect(service, NULL, 0) == errSecNotAvailable);
    assert(zw_credentials_erase(service) == errSecNotAvailable);
    assert(zw_credentials_export(service, &count, count_export) == errSecNotAvailable && !count);
    assert(zw_credentials_import(service, &entry, 1) == errSecNotAvailable && !zw_credentials_cached());
    assert(setenv("ZW_TEST_CREDENTIAL_RESPONSE", "cancel", 1) == 0);
    assert(zw_credentials_authorize(service) == -43001 && !zw_credentials_cached());
    assert(setenv("ZW_TEST_CREDENTIAL_RESPONSE", "silent-success", 1) == 0);
    assert(zw_credentials_authorize(service) == errSecSuccess && zw_credentials_cached());
    assert(zw_credentials_get("com.zerowork.tests.other", a, &out, &length) == errSecParam);
    assert(zw_credentials_add(service, b, (const unsigned char *)"mock", 4) == errSecSuccess);
    assert(zw_credentials_import(service, &entry, 1) == errSecSuccess);
    assert(zw_credentials_export(service, &count, count_export) == errSecSuccess && count == 3);
    assert(zw_credentials_get(service, b, &out, &length) == errSecSuccess && length == 4 && !memcmp(out, "mock", 4));
    zw_credentials_free(out, length);
    assert(zw_credentials_delete(service, b) == errSecSuccess);
    assert(zw_credentials_collect(service, &c, 1) == errSecSuccess);
    assert(zw_credentials_get(service, a, &out, &length) == errSecItemNotFound);
    assert(zw_credentials_erase(service) == errSecSuccess);
    assert(zw_credentials_get(service, c, &out, &length) == errSecItemNotFound);
    discard_vault_cache();
    puts("UI fixture bridge: cold/denial and warm read/write/convert/erase passed without system Keychain linkage");
    return 0;
}
#else
static CFDataRef fake_item;
static Boolean fake_interaction = true;
static int reads, ref_reads, additions, updates, deletions, legacy_deletions;
static CFStringRef expected_service = CFSTR("com.zerowork.tests.mock-only");
static int other_item_exists;
static OSStatus fail_read, fail_write, fail_delete, fail_authorize;
static int ignore_update;
static int authorization_reads;
static int confirmations;
static OSStatus fail_confirmation;
static OSStatus confirm_vault(void) { confirmations++; return fail_confirmation; }
#define ZW_CREDENTIALS_TESTING 1
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
static void check_query(CFDictionaryRef q) {
    assert((fake_interaction && CFEqual(CFDictionaryGetValue(q, kSecUseAuthenticationUI), kSecUseAuthenticationUIAllow)) ||
           (!fake_interaction && CFEqual(CFDictionaryGetValue(q, kSecUseAuthenticationUI), kSecUseAuthenticationUIFail)));
    assert(CFEqual(CFDictionaryGetValue(q, kSecAttrService), expected_service));
    assert(CFEqual(CFDictionaryGetValue(q, kSecAttrAccount), CFSTR("vault-v1")));
}
#pragma clang diagnostic pop
static OSStatus fake_copy(CFDictionaryRef q, CFTypeRef *result) {
    check_query(q);
    if (!CFDictionaryGetValue(q, kSecReturnData) && !CFDictionaryGetValue(q, kSecReturnRef))
        return fake_item ? errSecSuccess : errSecItemNotFound;
    if (CFDictionaryGetValue(q, kSecReturnRef)) {
        ref_reads++;
        assert(!CFDictionaryGetValue(q, kSecReturnData));
        if (!fake_item) return errSecItemNotFound;
        *result = CFRetain(CFSTR("legacy-owned-reference")); return errSecSuccess;
    }
    reads++;
    if (fake_interaction) { authorization_reads++; if (fail_authorize) return fail_authorize; }
    else if (fail_read) return fail_read;
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
    if (ignore_update) return errSecSuccess;
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
static void *read_concurrently(void *reference) {
    expect_secret(reference, "preserved-secret");
    return NULL;
}
static int verify_export(void *raw, const char *reference, const unsigned char *value, size_t length) {
    int *count = raw;
    assert(!strncmp(reference, "zw1_", 4));
    assert(length == 16 && !memcmp(value, "preserved-secret", length));
    ++*count;
    return 0;
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
    assert(zw_credentials_authorize(scope) == errSecSuccess);
    assert(reads == 1 && !confirmations && !authorization_reads && !vault_exists);
    assert(zw_credentials_add(scope, a, (const unsigned char *)"owned-first", 11) == errSecSuccess);
    assert(reads == 1 && additions == 1 && updates == 0 && fake_interaction);
    assert(zw_credentials_add(scope, b, (const unsigned char *)"owned-second", 12) == errSecSuccess);
    expect_secret(a, "owned-first"); expect_secret(b, "owned-second");
    assert(reads == 1 && additions == 1 && updates == 1 && fake_interaction);
    assert(confirmations == 0); // Nothing saved before this process: no biometric prompt.
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
    fail_read = errSecSuccess;
    assert(zw_credentials_add(scope, a, (const unsigned char *)"preserved-secret", 16) == errSecSuccess);
    reset_cache();
    fail_read = errSecAuthFailed;
    assert(zw_credentials_get(scope, a, &missing, &length) == errSecAuthFailed);
    assert(!cached_service && authorization_reads == 0);
    int writes_before_authorize = additions + updates + deletions;
    fake_interaction = false;
    fail_authorize = errSecUserCanceled;
    assert(zw_credentials_authorize(scope) == errSecUserCanceled);
    assert(!cached_service && !fake_interaction);
    fail_authorize = errSecSuccess;
    assert(zw_credentials_authorize(scope) == errSecSuccess);
    assert(!fake_interaction && authorization_reads == 2);
    assert(additions + updates + deletions == writes_before_authorize);
    expect_secret(a, "preserved-secret");
    assert(authorization_reads == 2); // Cached use never prompts again.
    fake_interaction = true;
    reset_cache();
    int reads_before_confirmation = reads;
    int confirmations_before = confirmations;
    fail_confirmation = -43001;
    fail_read = errSecSuccess;
    assert(zw_credentials_authorize(scope) == errSecSuccess);
    expect_secret(a, "preserved-secret"); expect_secret(a, "preserved-secret");
    assert(confirmations == confirmations_before && reads == reads_before_confirmation + 1);
    assert(authorization_reads == 2);
    assert(zw_credentials_get("com.zerowork.tests.other-scope", a, &missing, &length) == errSecParam);
    // A cached read succeeds with another reader active, while writes stay exclusive.
    assert(pthread_rwlock_rdlock(&vault_lock) == 0);
    pthread_t reader;
    assert(pthread_create(&reader, NULL, read_concurrently, (void *)a) == 0);
    assert(pthread_join(reader, NULL) == 0);
    assert(zw_credentials_add(scope, c, (const unsigned char *)"concurrent", 10) == -43003);
    assert(pthread_rwlock_unlock(&vault_lock) == 0);
    reset_cache();
    int copied = 0;
    fail_confirmation = -43001;
    assert(zw_credentials_export(scope, &copied, verify_export) == -43001 && copied == 0);
    fail_confirmation = errSecSuccess;
    fail_read = errSecAuthFailed;
    fail_authorize = errSecUserCanceled;
    assert(zw_credentials_export(scope, &copied, verify_export) == errSecUserCanceled && copied == 0);
    fail_authorize = errSecSuccess;
    assert(zw_credentials_export(scope, &copied, verify_export) == errSecSuccess && copied == 1);
    const struct import_entry imported[] = {
        {b, (const unsigned char *)"local-one", 9},
        {c, (const unsigned char *)"local-two", 9},
    };
    reset_cache();
    fail_read = errSecSuccess;
    fail_confirmation = -43001;
    int writes_before_import = updates + additions + deletions;
    assert(zw_credentials_import(scope, imported, 2) == -43001);
    assert(updates + additions + deletions == writes_before_import);
    fail_confirmation = errSecSuccess;
    expect_secret(a, "preserved-secret");
    const struct import_entry conflicting[] = {
        imported[0], {a, (const unsigned char *)"changed-source", 14}
    };
    assert(zw_credentials_import(scope, conflicting, 2) == errSecDuplicateItem);
    assert(updates + additions + deletions == writes_before_import);
    assert(zw_credentials_get(scope, b, &missing, &length) == errSecItemNotFound);
    expect_secret(a, "preserved-secret");
    fail_write = errSecIO;
    assert(zw_credentials_import(scope, imported, 2) == errSecIO);
    expect_secret(a, "preserved-secret");
    fail_write = errSecSuccess;
    ignore_update = 1;
    assert(zw_credentials_import(scope, imported, 2) == errSecDecode);
    assert(!cached_service && !cached_vault);
    ignore_update = 0;
    expect_secret(a, "preserved-secret");
    fail_read = errSecIO;
    assert(zw_credentials_import(scope, imported, 2) == errSecIO);
    assert(!cached_service && !cached_vault);
    fail_read = errSecSuccess;
    int reads_before_import = reads;
    assert(zw_credentials_import(scope, imported, 2) == errSecSuccess);
    assert(reads == reads_before_import + 2); // Fresh load and read-back after the write.
    reset_cache();
    expect_secret(a, "preserved-secret");
    expect_secret(b, "local-one");
    expect_secret(c, "local-two");
    int writes_after_import = updates + additions + deletions;
    assert(zw_credentials_import(scope, imported, 2) == errSecSuccess);
    assert(zw_credentials_import(scope, NULL, 0) == errSecSuccess);
    assert(fake_item && updates + additions + deletions == writes_after_import);
    reset_cache(); expect_secret(a, "preserved-secret"); expect_secret(b, "local-one"); expect_secret(c, "local-two");
    reset_cache();
    puts("native vault mock regression passed: verified batch import, cancellation, write and read-back failures, restart, cached reads, rollback, scope isolation, legacy deletion, no UI");
    return 0;
}
#endif
