#include <CoreFoundation/CoreFoundation.h>
#include <Security/Security.h>
#include <stdlib.h>
#include <string.h>

// One item per app scope. The signed app reads it once, then updates that same
// item from its process cache. Never relax the item's default macOS ACL.
static CFStringRef cached_service;
static CFMutableDictionaryRef cached_vault;
static int vault_exists;
static const CFStringRef vault_account = CFSTR("vault-v1");

// AuthenticationUIFail alone does not suppress legacy-keychain dialogs.
// This guard also disables classic Keychain interaction for each Security call.
// Credential store operations are serialized on the application's main thread.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
static OSStatus no_ui_call(int operation, CFDictionaryRef query, CFDictionaryRef updates, CFTypeRef *result) {
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
        // Only the explicit startup recovery action may request system UI.
        // This reads the same vault and preserves its existing access control.
        CFDictionarySetValue(q, kSecUseAuthenticationUI, kSecUseAuthenticationUIAllow);
        Boolean previous = false;
        status = SecKeychainGetUserInteractionAllowed(&previous);
        if (!status) {
            status = SecKeychainSetUserInteractionAllowed(true);
            if (!status) status = SecItemCopyMatching(q, &data);
            (void)SecKeychainSetUserInteractionAllowed(previous);
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
int zw_credentials_authorize(const char *service) { return (int)load_vault_with_ui(service, 1); }
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
int zw_credentials_get(const char *service, const char *reference, unsigned char **out, size_t *length) {
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
