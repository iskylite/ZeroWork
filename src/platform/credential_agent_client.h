#include <mach-o/dyld.h>
#include <spawn.h>
#include <sys/socket.h>
#include <sys/wait.h>
#include <signal.h>
#include <limits.h>
#include <stdio.h>
#include <fcntl.h>
#include "credential_agent_protocol.h"

static int credential_agent_is_bundled(void) {
    CFBundleRef bundle = CFBundleGetMainBundle();
    CFTypeRef enabled = bundle ? CFBundleGetValueForInfoDictionaryKey(bundle, CFSTR("ZeroWorkCredentialAgent")) : NULL;
    // Only the signed packaging paths opt in. Existing standalone and custom
    // UI-test bundles retain their legacy development backend.
    return enabled && CFEqual(enabled, kCFBooleanTrue);
}

static OSStatus credential_agent_call(int operation, CFDictionaryRef query, CFDictionaryRef updates, CFTypeRef *result, int allow_ui) {
    char executable[PATH_MAX], helper[PATH_MAX];
    uint32_t size = sizeof(executable);
    if (_NSGetExecutablePath(executable, &size) || !realpath(executable, helper)) return errSecNotAvailable;
    char *slash = strrchr(helper, '/');
    if (!slash) return errSecNotAvailable;
    *slash = 0;
    if (strlen(helper) + strlen("/../Helpers/ZeroWorkCredentials") >= sizeof(helper)) return errSecParam;
    strcat(helper, "/../Helpers/ZeroWorkCredentials");
    SecRequirementRef requirement = NULL;
    OSStatus status = zw_peer_requirement(1, &requirement);
    SecStaticCodeRef code = NULL;
    CFURLRef url = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8 *)helper, strlen(helper), false);
    if (!status) status = SecStaticCodeCreateWithPath(url, kSecCSDefaultFlags, &code);
    if (!status) status = SecStaticCodeCheckValidity(code, kSecCSStrictValidate, requirement);
    if (code) CFRelease(code);
    if (requirement) CFRelease(requirement);
    CFRelease(url);
    if (status) return errSecNotAvailable;
    char service[512];
    if (!CFStringGetCString(CFDictionaryGetValue(query, kSecAttrService), service, sizeof(service), kCFStringEncodingUTF8)) return errSecParam;
    CFDataRef data = operation == 1 ? CFDictionaryGetValue(query, kSecValueData) :
        operation == 2 ? CFDictionaryGetValue(updates, kSecValueData) : NULL;
    if (operation == 0 && !CFDictionaryGetValue(query, kSecReturnData)) operation = 4;
    struct zw_credential_request request = { ZW_CREDENTIAL_MAGIC, (uint32_t)operation, (uint32_t)allow_ui,
        (uint32_t)strlen(service), data ? (uint32_t)CFDataGetLength(data) : 0 };
    if (request.data_length > ZW_CREDENTIAL_LIMIT) return errSecDataTooLarge;
    int sockets[2];
    if (socketpair(AF_UNIX, SOCK_STREAM, 0, sockets)) return errSecIO;
    fcntl(sockets[0], F_SETFD, FD_CLOEXEC);
    fcntl(sockets[1], F_SETFD, FD_CLOEXEC);
    int one = 1;
    setsockopt(sockets[0], SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));
    struct timeval timeout = { allow_ui ? 180 : 20, 0 };
    setsockopt(sockets[0], SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
    setsockopt(sockets[0], SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));
    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_adddup2(&actions, sockets[1], STDIN_FILENO);
    posix_spawn_file_actions_adddup2(&actions, sockets[1], STDOUT_FILENO);
    posix_spawn_file_actions_addclose(&actions, sockets[0]);
    posix_spawn_file_actions_addclose(&actions, sockets[1]);
    posix_spawnattr_t attributes;
    posix_spawnattr_init(&attributes);
    posix_spawnattr_setflags(&attributes, POSIX_SPAWN_CLOEXEC_DEFAULT);
    char *argv[] = { helper, NULL };
    // A clean environment prevents loader injection and accidental secret/env
    // inheritance. The helper obtains identity from the actual parent process.
    char *environment[] = { "PATH=/usr/bin:/bin", NULL };
    pid_t child;
    int spawned = posix_spawn(&child, helper, &actions, &attributes, argv, environment);
    posix_spawnattr_destroy(&attributes);
    posix_spawn_file_actions_destroy(&actions);
    close(sockets[1]);
    if (spawned) { close(sockets[0]); return errSecNotAvailable; }
    struct zw_credential_response response = { errSecIO, 0 };
    int ok = zw_transfer(sockets[0], &request, sizeof(request), 1) &&
        zw_transfer(sockets[0], service, request.service_length, 1) &&
        (!data || zw_transfer(sockets[0], (void *)CFDataGetBytePtr(data), request.data_length, 1)) &&
        zw_transfer(sockets[0], &response, sizeof(response), 0) && response.data_length <= ZW_CREDENTIAL_LIMIT;
    CFMutableDataRef received = NULL;
    if (ok && response.data_length) {
        received = CFDataCreateMutable(NULL, response.data_length);
        if (!received) ok = 0;
        else {
            CFDataSetLength(received, response.data_length);
            ok = zw_transfer(sockets[0], CFDataGetMutableBytePtr(received), response.data_length, 0);
        }
    }
    close(sockets[0]);
    if (!ok) kill(child, SIGKILL);
    int child_status = 0;
    pid_t waited;
    do { waited = waitpid(child, &child_status, 0); } while (waited < 0 && errno == EINTR);
    if (!ok || waited != child || !WIFEXITED(child_status) || WEXITSTATUS(child_status)) response.status = errSecIO;
    if (!response.status && result) { *result = received; received = NULL; }
    if (received) { memset(CFDataGetMutableBytePtr(received), 0, CFDataGetLength(received)); CFRelease(received); }
    return response.status;
}
