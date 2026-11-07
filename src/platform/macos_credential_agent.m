// Keep this executable independent of app version, UI, Zig and build mode.
// Its CodeDirectory hash remains stable across ordinary application rebuilds.
#define ZW_CREDENTIALS_LOCAL 1
#include <stdio.h>
#include "macos_credentials.m"
#include "credential_agent_protocol.h"

int main(void) {
    SecRequirementRef requirement = NULL;
    OSStatus status = zw_peer_requirement(0, &requirement);
    SecCodeRef parent = NULL;
    pid_t parent_pid = getppid();
    CFNumberRef number = CFNumberCreate(NULL, kCFNumberIntType, &parent_pid);
    const void *keys[] = { kSecGuestAttributePid }, *values[] = { number };
    CFDictionaryRef attributes = CFDictionaryCreate(NULL, keys, values, 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    if (!status) status = SecCodeCopyGuestWithAttributes(NULL, attributes, kSecCSDefaultFlags, &parent);
    if (!status) status = SecCodeCheckValidity(parent, kSecCSStrictValidate, requirement);
    CFRelease(attributes); CFRelease(number);
    if (parent) CFRelease(parent);
    if (requirement) CFRelease(requirement);
    if (status || parent_pid <= 1) return 1;
    struct zw_credential_request request;
    if (!zw_transfer(STDIN_FILENO, &request, sizeof(request), 0) || request.magic != ZW_CREDENTIAL_MAGIC ||
        request.operation > 4 || request.allow_ui > 1 || (request.allow_ui && request.operation != 0) ||
        !request.service_length || request.service_length >= 512 || request.data_length > ZW_CREDENTIAL_LIMIT ||
        ((request.operation != 1 && request.operation != 2) && request.data_length)) return 2;
    char service[512] = {0};
    if (!zw_transfer(STDIN_FILENO, service, request.service_length, 0) || strlen(service) != request.service_length) return 2;
    const char *prefix = "com.zerowork.app.credentials";
    size_t prefix_length = strlen(prefix);
    if (strcmp(service, prefix)) {
        if (strncmp(service, prefix, prefix_length) || strncmp(service + prefix_length, ".instance.", 10) ||
            strlen(service + prefix_length) != 74) return 2;
        for (const char *p = service + prefix_length + 10; *p; p++)
            if (!((*p >= '0' && *p <= '9') || (*p >= 'a' && *p <= 'f'))) return 2;
    }
    CFMutableDictionaryRef query = vault_query(service);
    if (!query) return 3;
    CFMutableDataRef input = CFDataCreateMutable(NULL, request.data_length);
    if (!input) { CFRelease(query); return 3; }
    CFDataSetLength(input, request.data_length);
    if (!zw_transfer(STDIN_FILENO, CFDataGetMutableBytePtr(input), request.data_length, 0)) { CFRelease(input); CFRelease(query); return 2; }
    CFTypeRef result = NULL;
    switch (request.operation) {
        case 0:
            CFDictionarySetValue(query, kSecReturnData, kCFBooleanTrue);
            CFDictionarySetValue(query, kSecMatchLimit, kSecMatchLimitOne);
            if (request.allow_ui) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
                CFDictionarySetValue(query, kSecUseAuthenticationUI, kSecUseAuthenticationUIAllow);
                status = SecItemCopyMatching(query, &result);
#pragma clang diagnostic pop
            } else status = no_ui_call(0, query, NULL, &result);
            break;
        case 1:
            CFDictionarySetValue(query, kSecValueData, input);
            CFDictionarySetValue(query, kSecAttrAccessible, kSecAttrAccessibleWhenUnlockedThisDeviceOnly);
            CFDictionarySetValue(query, kSecAttrSynchronizable, kCFBooleanFalse);
            status = no_ui_call(1, query, NULL, NULL);
            break;
        case 2: {
            const void *update_keys[] = { kSecValueData }, *update_values[] = { input };
            CFDictionaryRef updates = CFDictionaryCreate(NULL, update_keys, update_values, 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
            status = no_ui_call(2, query, updates, NULL); CFRelease(updates); break;
        }
        case 3: status = delete_vault(query); break;
        case 4:
            CFDictionarySetValue(query, kSecMatchLimit, kSecMatchLimitOne);
            status = no_ui_call(0, query, NULL, NULL); break;
    }
    struct zw_credential_response response = { status, 0 };
    if (!status && result && CFGetTypeID(result) == CFDataGetTypeID()) response.data_length = (uint32_t)CFDataGetLength(result);
    if (response.data_length > ZW_CREDENTIAL_LIMIT) { response.status = errSecDataTooLarge; response.data_length = 0; }
    int ok = zw_transfer(STDOUT_FILENO, &response, sizeof(response), 1) &&
        (!response.data_length || zw_transfer(STDOUT_FILENO, (void *)CFDataGetBytePtr(result), response.data_length, 1));
    if (result) CFRelease(result);
    memset(CFDataGetMutableBytePtr(input), 0, CFDataGetLength(input)); CFRelease(input); CFRelease(query);
    return ok ? 0 : 3;
}
