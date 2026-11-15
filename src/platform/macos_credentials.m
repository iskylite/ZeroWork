#include <CoreFoundation/CoreFoundation.h>
#include <Security/Security.h>
#include <stdlib.h>
#include <string.h>
#include <pthread.h>
#if defined(ZW_CREDENTIALS_UI_FIXTURE)
#include <stdio.h>
#include <unistd.h>
// Only linked into the automation build. The fixture models a waiting system
// reply without reading the user's Keychain or authorizing a real request.
static int fixture_credential(unsigned char **out, size_t *length) {
    const char *mode = getenv("ZW_TEST_CREDENTIAL_RESPONSE");
    if (!mode) return 1;
    if (strcmp(mode, "silent-success") != 0) {
        fputs("ZW_TEST_CREDENTIAL_REQUEST\n", stderr);
        fflush(stderr);
        int slow_success = strcmp(mode, "slow-success") == 0;
        if (slow_success) sleep(3);
        else usleep(900000);
        if (!slow_success && strcmp(mode, "success") != 0) return -43001;
    }
    const char value[] = "fixture-only-secret";
    *length = sizeof(value) - 1;
    *out = malloc(*length);
    if (!*out) return errSecAllocate;
    memcpy(*out, value, *length);
    return 0;
}
#endif
#if !defined(ZW_CREDENTIALS_LOCAL) && !defined(ZW_CREDENTIALS_TESTING)
#include "credential_agent_client.h"
#endif
#if !defined(ZW_CREDENTIALS_LOCAL) && !defined(ZW_CREDENTIALS_TESTING) && !defined(ZW_CREDENTIALS_CONFIRM_EXTERNAL)
#import <LocalAuthentication/LocalAuthentication.h>
#include <stdatomic.h>
// This is an application-level gate. Legacy Keychain ACLs remain enforced by
// macOS in the agent; this does not claim biometric protection of the item.
static OSStatus confirm_vault(void) {
    @autoreleasepool {
        LAContext *context = [[LAContext alloc] init];
        NSError *error = nil;
        if (![context canEvaluatePolicy:LAPolicyDeviceOwnerAuthentication error:&error]) {
            [context release]; return errSecNotAvailable;
        }
        __block atomic_int outcome;
        atomic_init(&outcome, 0);
        [context evaluatePolicy:LAPolicyDeviceOwnerAuthentication
            localizedReason:@"解锁已保存的连接凭据和 API Key"
            reply:^(BOOL success, NSError *failure) {
                int value = success ? 1 :
                    (failure.code == LAErrorUserCancel || failure.code == LAErrorAppCancel || failure.code == LAErrorSystemCancel) ? 2 : 3;
                atomic_store(&outcome, value);
            }];
        while (atomic_load(&outcome) == 0) CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.05, true);
        int result = atomic_load(&outcome);
        [context invalidate]; [context release];
        return result == 1 ? errSecSuccess : result == 2 ? -43001 : -43002;
    }
}
#endif

// One item per app scope. The signed app reads it once, then updates that same
// item from its process cache. The agent keeps its own default macOS ACL.
static CFStringRef cached_service;
static CFMutableDictionaryRef cached_vault;
static int vault_exists;
#if !defined(ZW_CREDENTIALS_LOCAL)
static void discard_vault_cache(void) {
    if (cached_service) CFRelease(cached_service);
    if (cached_vault) CFRelease(cached_vault);
    cached_service = NULL; cached_vault = NULL; vault_exists = 0;
}
static pthread_rwlock_t vault_lock = PTHREAD_RWLOCK_INITIALIZER;
static void unlock_vault(pthread_rwlock_t **lock) { pthread_rwlock_unlock(*lock); }

// The populated cache is read-only under a shared lock. Loading a cold
// vault requires the exclusive lock, just as writes and conversion do.
static int lock_vault_read(void) {
    if (pthread_rwlock_tryrdlock(&vault_lock) != 0) return 0;
    if (cached_service) return 1;
    pthread_rwlock_unlock(&vault_lock);
    return pthread_rwlock_trywrlock(&vault_lock) == 0;
}
#define ZW_VAULT_GUARD \
    if (pthread_rwlock_trywrlock(&vault_lock) != 0) return -43003; \
    pthread_rwlock_t *guard __attribute__((cleanup(unlock_vault), unused)) = &vault_lock
#define ZW_VAULT_READ_GUARD \
    if (!lock_vault_read()) return -43003; \
    pthread_rwlock_t *guard __attribute__((cleanup(unlock_vault), unused)) = &vault_lock

int zw_credentials_cached(void) {
    if (pthread_rwlock_tryrdlock(&vault_lock) != 0) return 0;
    int ready = cached_service != NULL;
    pthread_rwlock_unlock(&vault_lock);
    return ready;
}
#else
#define ZW_VAULT_GUARD
#define ZW_VAULT_READ_GUARD
#endif

static const CFStringRef vault_account = CFSTR("vault-v1");

// AuthenticationUIFail alone does not suppress legacy-keychain dialogs.
// This guard also disables classic Keychain interaction for each Security call.
// The process vault lock serializes the legacy Security interaction flag.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
static OSStatus no_ui_call(int operation, CFDictionaryRef query, CFDictionaryRef updates, CFTypeRef *result) {
#if !defined(ZW_CREDENTIALS_LOCAL) && !defined(ZW_CREDENTIALS_TESTING)
    // Keep the existing standalone Zig/dev runners working. Packaged apps fail
    // closed if their signed helper is missing, invalid or refuses the caller.
    if (credential_agent_is_bundled()) return credential_agent_call(operation, query, updates, result, 0);
#endif
    Boolean previous = false;
    OSStatus status = SecKeychainGetUserInteractionAllowed(&previous);
    if (status) return status;
    status = SecKeychainSetUserInteractionAllowed(false);
    if (status) return status;
    switch (operation) {
        case 0: status = SecItemCopyMatching(query, result); break;
        case 1: status = SecItemAdd(query, NULL); break;
        case 2: status = SecItemUpdate(query, updates); break;
        case 3: status = SecItemDelete(query); break;
        default: status = errSecParam; break;
    }
    (void)SecKeychainSetUserInteractionAllowed(previous);
    return status;
}
static CFMutableDictionaryRef vault_query(const char *service) {
    CFMutableDictionaryRef q = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    if (!q) return NULL;
    CFDictionarySetValue(q, kSecClass, kSecClassGenericPassword);
    CFStringRef name = CFStringCreateWithCString(NULL, service, kCFStringEncodingUTF8);
    if (!name) { CFRelease(q); return NULL; }
    CFDictionarySetValue(q, kSecAttrService, name); CFRelease(name);
    CFDictionarySetValue(q, kSecAttrAccount, vault_account);
    CFDictionarySetValue(q, kSecUseAuthenticationUI, kSecUseAuthenticationUIFail);
    return q;
}
// Legacy file-based keychains can reject SecItemDelete with InvalidOwnerEdit.
// Resolve only this exact service/account to an item reference, never its data.
static OSStatus delete_vault(CFDictionaryRef query) {
    OSStatus status = no_ui_call(3, query, NULL, NULL);
#if !defined(ZW_CREDENTIALS_LOCAL) && !defined(ZW_CREDENTIALS_TESTING)
    // Legacy deletion fallback is performed inside the agent as the owner.
    if (credential_agent_is_bundled()) return status;
#endif
    if (status != errSecInvalidOwnerEdit) return status;
    CFMutableDictionaryRef ref_query = CFDictionaryCreateMutableCopy(NULL, 0, query);
    if (!ref_query) return errSecAllocate;
    CFDictionarySetValue(ref_query, kSecReturnRef, kCFBooleanTrue);
    CFDictionarySetValue(ref_query, kSecMatchLimit, kSecMatchLimitOne);
    CFTypeRef item = NULL;
    status = no_ui_call(0, ref_query, NULL, &item); CFRelease(ref_query);
    if (status) return status;
    if (!item || CFGetTypeID(item) != SecKeychainItemGetTypeID()) {
        if (item) CFRelease(item);
        return errSecParam;
    }
    Boolean previous = false;
    status = SecKeychainGetUserInteractionAllowed(&previous);
    if (!status) {
        status = SecKeychainSetUserInteractionAllowed(false);
        if (!status) {
            status = SecKeychainItemDelete((SecKeychainItemRef)item);
            (void)SecKeychainSetUserInteractionAllowed(previous);
        }
    }
    CFRelease(item); return status;
}
#pragma clang diagnostic pop

static int owned_reference(const char *reference) {
    if (strlen(reference) != 68 || strncmp(reference, "zw1_", 4)) return 0;
    for (size_t i = 4; i < 68; i++) {
        char c = reference[i];
        if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F'))) return 0;
    }
    return 1;
}
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
static OSStatus load_vault_with_ui(const char *service, int allow_ui) {
    CFStringRef name = CFStringCreateWithCString(NULL, service, kCFStringEncodingUTF8);
    if (!name) return errSecAllocate;
    if (cached_service) {
        int same = CFEqual(name, cached_service); CFRelease(name);
        return same ? errSecSuccess : errSecParam;
    }
    CFMutableDictionaryRef q = vault_query(service);
    if (!q) { CFRelease(name); return errSecAllocate; }
    CFDictionarySetValue(q, kSecReturnData, kCFBooleanTrue);
    CFDictionarySetValue(q, kSecMatchLimit, kSecMatchLimitOne);
    CFTypeRef data = NULL;
    OSStatus status;
    if (allow_ui) {
        // Startup recovery and explicit conversion may request system UI.
        // This reads the same vault and preserves its existing access control.
#if !defined(ZW_CREDENTIALS_LOCAL) && !defined(ZW_CREDENTIALS_TESTING)
        if (credential_agent_is_bundled()) status = credential_agent_call(0, q, NULL, &data, 1);
        else
#endif
        {
        CFDictionarySetValue(q, kSecUseAuthenticationUI, kSecUseAuthenticationUIAllow);
        Boolean previous = false;
        status = SecKeychainGetUserInteractionAllowed(&previous);
        if (!status) {
            status = SecKeychainSetUserInteractionAllowed(true);
            if (!status) status = SecItemCopyMatching(q, &data);
            (void)SecKeychainSetUserInteractionAllowed(previous);
        }
        }
    } else status = no_ui_call(0, q, NULL, &data);
    CFRelease(q);
    CFMutableDictionaryRef next = NULL;
    int exists = 0;
    if (status == errSecItemNotFound) {
        next = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        status = errSecSuccess;
    } else if (!status) {
        if (!data || CFGetTypeID(data) != CFDataGetTypeID() || CFDataGetLength(data) > 8 * 1024 * 1024) status = errSecDecode;
        else {
            CFPropertyListRef decoded = CFPropertyListCreateWithData(NULL, data, kCFPropertyListMutableContainers, NULL, NULL);
            if (!decoded || CFGetTypeID(decoded) != CFDictionaryGetTypeID()) {
                if (decoded) CFRelease(decoded);
                status = errSecDecode;
            } else next = (CFMutableDictionaryRef)decoded;
        }
        if (data) CFRelease(data);
        if (!status) exists = 1;
    }
    if (status) { CFRelease(name); return status; }
    if (!next) { CFRelease(name); return errSecAllocate; }
    CFIndex count = CFDictionaryGetCount(next);
    const void **keys = calloc((size_t)count + 1, sizeof(void *));
    const void **values = calloc((size_t)count + 1, sizeof(void *));
    if (!keys || !values) { free(keys); free(values); CFRelease(next); CFRelease(name); return errSecAllocate; }
    CFDictionaryGetKeysAndValues(next, keys, values);
    for (CFIndex i = 0; i < count; i++) {
        char reference[128];
        if (CFGetTypeID(keys[i]) != CFStringGetTypeID() || CFGetTypeID(values[i]) != CFDataGetTypeID() ||
            !CFStringGetCString(keys[i], reference, sizeof(reference), kCFStringEncodingUTF8) || !owned_reference(reference)) {
            status = errSecDecode; break;
        }
    }
    free(keys); free(values);
    if (status) { CFRelease(next); CFRelease(name); return status; }
    cached_service = name; cached_vault = next; vault_exists = exists; return errSecSuccess;
}
static OSStatus load_vault(const char *service) { return load_vault_with_ui(service, 0); }
#if defined(ZW_CREDENTIALS_LOCAL)
int zw_credentials_authorize(const char *service) { ZW_VAULT_GUARD; return (int)load_vault_with_ui(service, 1); }
#else
static OSStatus authorize_vault(const char *service) {
    OSStatus status = load_vault(service);
    if (status == errSecInteractionNotAllowed || status == errSecAuthFailed) status = load_vault_with_ui(service, 1);
    return status;
}

int zw_credentials_authorize(const char *service) {
    ZW_VAULT_GUARD;
#if defined(ZW_CREDENTIALS_UI_FIXTURE)
    if (!cached_service) {
        unsigned char *value = NULL; size_t length = 0;
        int result = fixture_credential(&value, &length);
        if (result != 1) {
            if (result) return result;
            CFDataRef data = CFDataCreate(NULL, value, (CFIndex)length);
            memset(value, 0, length); free(value);
            CFStringRef name = CFStringCreateWithCString(NULL, service, kCFStringEncodingUTF8);
            CFMutableDictionaryRef vault = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
            if (data && name && vault) {
                CFDictionarySetValue(vault, CFSTR("zw1_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"), data);
                cached_service = name; cached_vault = vault;
            } else {
                if (name) CFRelease(name);
                if (vault) CFRelease(vault);
                result = errSecAllocate;
            }
            if (data) CFRelease(data);
            return result;
        }
    }
#endif
    return authorize_vault(service);
}

static OSStatus authorize_conversion(const char *service) {
    if (!cached_service) {
        CFMutableDictionaryRef query = vault_query(service);
        if (!query) return errSecAllocate;
        OSStatus presence = no_ui_call(0, query, NULL, NULL);
        CFRelease(query);
        if (presence == errSecSuccess) {
            OSStatus confirmation = confirm_vault();
            if (confirmation) return confirmation;
        } else if (presence != errSecItemNotFound && presence != errSecInteractionNotAllowed && presence != errSecAuthFailed) {
            return presence;
        }
    }
    return authorize_vault(service);
}

typedef int (*export_value)(void *, const char *, const unsigned char *, size_t);
struct export_context { export_value write; void *context; int failed; };
static void write_exported_value(const void *key, const void *value, void *raw) {
    struct export_context *export = raw;
    if (export->failed) return;
    char reference[69];
    if (!CFStringGetCString(key, reference, sizeof(reference), kCFStringEncodingASCII)) {
        export->failed = 1;
        return;
    }
    export->failed = export->write(export->context, reference, CFDataGetBytePtr(value), (size_t)CFDataGetLength(value));
}
int zw_credentials_export(const char *service, void *context, export_value write) {
    ZW_VAULT_GUARD;
#if defined(ZW_CREDENTIALS_UI_FIXTURE)
    unsigned char *fixture_value = NULL;
    size_t fixture_length = 0;
    int fixture = cached_service ? 1 : fixture_credential(&fixture_value, &fixture_length);
    if (fixture != 1) {
        if (fixture) return fixture;
        int failed = write(context, "zw1_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", fixture_value, fixture_length);
        memset(fixture_value, 0, fixture_length);
        free(fixture_value);
        return failed ? errSecIO : errSecSuccess;
    }
#endif
    OSStatus status = authorize_conversion(service);
    if (status) return status;
    struct export_context state = { write, context, 0 };
    CFDictionaryApplyFunction(cached_vault, write_exported_value, &state);
    return state.failed ? errSecIO : errSecSuccess;
}
#endif
#pragma clang diagnostic pop
static OSStatus save_vault(const char *service, CFMutableDictionaryRef candidate) {
    CFMutableDictionaryRef q = vault_query(service);
    if (!q) return errSecAllocate;
    OSStatus status;
    if (CFDictionaryGetCount(candidate) == 0) {
        status = vault_exists ? delete_vault(q) : errSecSuccess;
        if (status == errSecItemNotFound) status = errSecSuccess;
        if (!status) vault_exists = 0;
    } else {
        CFDataRef data = CFPropertyListCreateData(NULL, candidate, kCFPropertyListBinaryFormat_v1_0, 0, NULL);
        if (!data) { CFRelease(q); return errSecAllocate; }
        if (CFDataGetLength(data) > 8 * 1024 * 1024) { CFRelease(data); CFRelease(q); return errSecDataTooLarge; }
        if (vault_exists) {
            CFMutableDictionaryRef updates = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
            if (!updates) { CFRelease(data); CFRelease(q); return errSecAllocate; }
            CFDictionarySetValue(updates, kSecValueData, data);
            status = no_ui_call(2, q, updates, NULL); CFRelease(updates);
        } else {
            CFDictionarySetValue(q, kSecValueData, data);
            CFDictionarySetValue(q, kSecAttrAccessible, kSecAttrAccessibleWhenUnlockedThisDeviceOnly);
            CFDictionarySetValue(q, kSecAttrSynchronizable, kCFBooleanFalse);
            status = no_ui_call(1, q, NULL, NULL);
        }
        CFRelease(data);
        if (!status) vault_exists = 1;
    }
    CFRelease(q);
    if (!status) { CFRelease(cached_vault); cached_vault = candidate; }
    return status;
}
#if !defined(ZW_CREDENTIALS_LOCAL)
struct import_entry { const char *reference; const unsigned char *value; size_t length; };

static OSStatus verify_vault_storage(const char *service, CFDictionaryRef expected) {
    CFMutableDictionaryRef query = vault_query(service);
    if (!query) return errSecAllocate;
    CFDictionarySetValue(query, kSecReturnData, kCFBooleanTrue);
    CFDictionarySetValue(query, kSecMatchLimit, kSecMatchLimitOne);
    CFTypeRef data = NULL;
    OSStatus status = no_ui_call(0, query, NULL, &data);
    CFRelease(query);
    if (status == errSecItemNotFound && CFDictionaryGetCount(expected) == 0) return errSecSuccess;
    if (!status) {
        CFPropertyListRef actual = NULL;
        if (data && CFGetTypeID(data) == CFDataGetTypeID() && CFDataGetLength(data) <= 8 * 1024 * 1024)
            actual = CFPropertyListCreateWithData(NULL, data, kCFPropertyListImmutable, NULL, NULL);
        if (!actual || !CFEqual(actual, expected)) status = errSecDecode;
        if (actual) CFRelease(actual);
    }
    if (data) CFRelease(data);
    return status;
}

int zw_credentials_import(const char *service, const struct import_entry *entries, size_t count) {
    ZW_VAULT_GUARD;
    CFMutableDictionaryRef next = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    if (!next) return errSecAllocate;
    OSStatus status = errSecSuccess;
    for (size_t i = 0; i < count; i++) {
        const struct import_entry *entry = &entries[i];
        if (!owned_reference(entry->reference) || entry->length > 8 * 1024 * 1024) { status = errSecParam; break; }
        CFStringRef key = CFStringCreateWithCString(NULL, entry->reference, kCFStringEncodingASCII);
        CFDataRef value = CFDataCreate(NULL, entry->value, (CFIndex)entry->length);
        if (!key || !value) status = errSecAllocate;
        else if (CFDictionaryContainsKey(next, key)) status = errSecDuplicateItem;
        else CFDictionarySetValue(next, key, value);
        if (value) CFRelease(value);
        if (key) CFRelease(key);
        if (status) break;
    }
#if defined(ZW_CREDENTIALS_UI_FIXTURE)
    const char *fixture_mode = getenv("ZW_TEST_CREDENTIAL_RESPONSE");
    if (!status && fixture_mode) {
        if (!strcmp(fixture_mode, "write-fail") || !strcmp(fixture_mode, "verify-fail")) status = errSecIO;
        else {
            unsigned char *value = NULL; size_t length = 0;
            status = fixture_credential(&value, &length);
            if (value) { memset(value, 0, length); free(value); }
        }
        if (!status) {
            CFStringRef name = CFStringCreateWithCString(NULL, service, kCFStringEncodingUTF8);
            if (!name) status = errSecAllocate;
            else { discard_vault_cache(); cached_service = name; cached_vault = next; return errSecSuccess; }
        }
    }
    if (fixture_mode) { CFRelease(next); return status; }
#endif
    if (!status) status = authorize_conversion(service);
    if (!status) status = save_vault(service, next);
    if (status) { CFRelease(next); return status; }
    // Verify through Security (or the signed agent), not the process cache.
    status = verify_vault_storage(service, next);
    if (status) discard_vault_cache();
    return status;
}
#endif
int zw_credentials_get(const char *service, const char *reference, unsigned char **out, size_t *length) {
    ZW_VAULT_READ_GUARD;
    if (!owned_reference(reference)) return errSecParam;
    OSStatus status = load_vault(service); if (status) return status;
    CFStringRef key = CFStringCreateWithCString(NULL, reference, kCFStringEncodingUTF8);
    if (!key) return errSecAllocate;
    CFDataRef data = CFDictionaryGetValue(cached_vault, key); CFRelease(key);
    if (!data) return errSecItemNotFound;
    *length = (size_t)CFDataGetLength(data); *out = malloc(*length ? *length : 1);
    if (!*out) return errSecAllocate;
    memcpy(*out, CFDataGetBytePtr(data), *length); return errSecSuccess;
}
void zw_credentials_free(unsigned char *value, size_t length) { if (value) { memset(value, 0, length); free(value); } }
int zw_credentials_add(const char *service, const char *reference, const unsigned char *value, size_t length) {
    ZW_VAULT_GUARD;
    if (!owned_reference(reference)) return errSecParam;
    OSStatus status = load_vault(service); if (status) return status;
    CFStringRef key = CFStringCreateWithCString(NULL, reference, kCFStringEncodingUTF8);
    if (!key) return errSecAllocate;
    if (CFDictionaryContainsKey(cached_vault, key)) { CFRelease(key); return errSecDuplicateItem; }
    CFMutableDictionaryRef next = CFDictionaryCreateMutableCopy(NULL, 0, cached_vault);
    if (!next) { CFRelease(key); return errSecAllocate; }
    if (length > 8 * 1024 * 1024) { CFRelease(next); CFRelease(key); return errSecDataTooLarge; }
    CFDataRef data = CFDataCreate(NULL, value, (CFIndex)length);
    if (!data) { CFRelease(next); CFRelease(key); return errSecAllocate; }
    CFDictionarySetValue(next, key, data); CFRelease(data); CFRelease(key);
    status = save_vault(service, next); if (status) CFRelease(next); return status;
}
int zw_credentials_delete(const char *service, const char *reference) {
    ZW_VAULT_GUARD;
    if (!owned_reference(reference)) return errSecParam;
    OSStatus status = load_vault(service); if (status) return status;
    CFStringRef key = CFStringCreateWithCString(NULL, reference, kCFStringEncodingUTF8);
    if (!key) return errSecAllocate;
    if (!CFDictionaryContainsKey(cached_vault, key)) { CFRelease(key); return errSecSuccess; }
    CFMutableDictionaryRef next = CFDictionaryCreateMutableCopy(NULL, 0, cached_vault);
    if (!next) { CFRelease(key); return errSecAllocate; }
    CFDictionaryRemoveValue(next, key); CFRelease(key);
    status = save_vault(service, next); if (status) CFRelease(next); return status;
}
int zw_credentials_collect(const char *service, const char *const *keep, size_t count) {
    ZW_VAULT_GUARD;
    OSStatus status = load_vault(service); if (status) return status;
    CFIndex entries = CFDictionaryGetCount(cached_vault);
    const void **keys = calloc((size_t)entries + 1, sizeof(void *)); if (!keys) return errSecAllocate;
    CFDictionaryGetKeysAndValues(cached_vault, keys, NULL);
    CFMutableDictionaryRef next = CFDictionaryCreateMutableCopy(NULL, 0, cached_vault);
    if (!next) { free(keys); return errSecAllocate; }
    int changed = 0;
    for (CFIndex i = 0; i < entries; i++) {
        char reference[128]; CFStringGetCString(keys[i], reference, sizeof(reference), kCFStringEncodingUTF8);
        int retained = 0;
        for (size_t k = 0; k < count; k++) if (!strcmp(keep[k], reference)) { retained = 1; break; }
        if (!retained) { CFDictionaryRemoveValue(next, keys[i]); changed = 1; }
    }
    free(keys);
    if (!changed) { CFRelease(next); return errSecSuccess; }
    status = save_vault(service, next); if (status) CFRelease(next); return status;
}
// Explicit reset must work even when this app cannot decrypt the vault.
// Delete only its exact metadata identity; never call load_vault here.
int zw_credentials_erase(const char *service) {
    ZW_VAULT_GUARD;
    CFMutableDictionaryRef q = vault_query(service);
    if (!q) return errSecAllocate;
    int same_scope = cached_service && CFEqual(cached_service, CFDictionaryGetValue(q, kSecAttrService));
    OSStatus status = delete_vault(q); CFRelease(q);
    if (status == errSecItemNotFound) status = errSecSuccess;
    if (!status && same_scope) {
        CFDictionaryRemoveAllValues(cached_vault);
        vault_exists = 0;
    }
    return status;
}
