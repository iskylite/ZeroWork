/* Worker-owned private local ZLE channel. No state crosses into the PTY. */
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <stdint.h>
#include <limits.h>
#include <mach-o/dyld.h>

typedef struct zw_local_edit {
    int listener, connection;
    char directory[PATH_MAX], socket_path[104], nonce[33];
} ZW_LOCAL_EDIT;
int zw_local_edit_poll_fd(ZW_LOCAL_EDIT *edit) { return edit->connection >= 0 ? edit->connection : edit->listener; }
static int edit_flags(int fd) {
    int flags = fcntl(fd, F_GETFL);
    return flags < 0 || fcntl(fd, F_SETFL, flags | O_NONBLOCK) || fcntl(fd, F_SETFD, FD_CLOEXEC);
}
static int edit_file(const char *directory, const char *name, const char *text, size_t length) {
    char path[PATH_MAX];
    if (snprintf(path, sizeof(path), "%s/%s", directory, name) >= (int)sizeof(path)) return -1;
    int fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0600);
    if (fd < 0) return -1;
    size_t offset = 0;
    while (offset < length) {
        ssize_t n = write(fd, text + offset, length - offset);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) { close(fd); return -1; }
        offset += (size_t)n;
    }
    return close(fd);
}
/* Quote only our generated constants and the original ZDOTDIR, never protocol
 * payloads. Shell text is not used to encode replacement buffers. */
static void edit_quote(FILE *file, const char *text) {
    fputc('\'', file);
    for (; *text; ++text) {
        if (*text == '\'') fputs("'\\''", file); else fputc(*text, file);
    }
    fputc('\'', file);
}
void zw_local_edit_destroy(ZW_LOCAL_EDIT *edit) {
    if (!edit) return;
    if (edit->connection >= 0) close(edit->connection);
    if (edit->listener >= 0) close(edit->listener);
    if (*edit->socket_path) unlink(edit->socket_path);
    if (*edit->directory) {
        char path[PATH_MAX];
        const char *files[] = {".zshenv", "integration.zsh"};
        for (size_t i = 0; i < 2; ++i) {
            snprintf(path, sizeof(path), "%s/%s", edit->directory, files[i]); unlink(path);
        }
        rmdir(edit->directory);
    }
    free(edit);
}
ZW_LOCAL_EDIT *zw_local_edit_create(uint64_t session, uint64_t generation, const char *script, size_t length) {
    ZW_LOCAL_EDIT *edit = calloc(1, sizeof(*edit));
    if (!edit) return NULL;
    edit->listener = edit->connection = -1;
    char executable[PATH_MAX], resolved[PATH_MAX]; uint32_t capacity = sizeof(executable);
    if (_NSGetExecutablePath(executable, &capacity) || !realpath(executable, resolved)) goto fail;
    char *slash = strrchr(resolved, '/');
    if (!slash) goto fail;
    *slash = 0;
    char module[PATH_MAX];
    if (snprintf(module, sizeof(module), "%s/zw_ipc.so", resolved) >= (int)sizeof(module) || access(module, R_OK)) goto fail;
    snprintf(edit->directory, sizeof(edit->directory), "/tmp/zw-edit-%u-XXXXXX", getuid());
    if (!mkdtemp(edit->directory) || chmod(edit->directory, 0700)) goto fail;
    if (snprintf(edit->socket_path, sizeof(edit->socket_path), "%s/control", edit->directory) >= (int)sizeof(edit->socket_path)) goto fail;
    unsigned char random[16]; arc4random_buf(random, sizeof(random));
    for (size_t i = 0; i < sizeof(random); ++i) snprintf(edit->nonce + 2*i, 3, "%02x", random[i]);
    edit->listener = socket(AF_UNIX, SOCK_STREAM, 0);
    if (edit->listener < 0 || edit_flags(edit->listener)) goto fail;
    struct sockaddr_un address = {.sun_family = AF_UNIX};
    strcpy(address.sun_path, edit->socket_path);
    if (bind(edit->listener, (struct sockaddr *)&address, sizeof(address)) || chmod(edit->socket_path, 0600) || listen(edit->listener, 2)) goto fail;
    if (edit_file(edit->directory, "integration.zsh", script, length)) goto fail;
    char *wrapper = NULL; size_t wrapper_length = 0;
    FILE *file = open_memstream(&wrapper, &wrapper_length);
    if (!file) goto fail;
    const char *original = getenv("ZDOTDIR");
    if (original) { fputs("export ZDOTDIR=", file); edit_quote(file, original); fputc('\n', file); }
    else fputs("unset ZDOTDIR\n", file);
    fputs("[[ ! -r ${ZDOTDIR-$HOME}/.zshenv ]] || source ${ZDOTDIR-$HOME}/.zshenv\n", file);
    fputs("[[ -o interactive && -o rcs ]] || return\n", file);
    fprintf(file, "typeset -g _zw_session=%llu _zw_generation=%llu _zw_parent=%d _zw_nonce='%s' _zw_socket=", (unsigned long long)session, (unsigned long long)generation, getpid(), edit->nonce);
    edit_quote(file, edit->socket_path); fputs(" _zw_module_dir=", file); edit_quote(file, resolved);
    fputs("\nsource ", file); char script_path[PATH_MAX]; snprintf(script_path, sizeof(script_path), "%s/integration.zsh", edit->directory); edit_quote(file, script_path); fputc('\n', file);
    int failed = fclose(file);
    if (!failed) failed = edit_file(edit->directory, ".zshenv", wrapper, wrapper_length);
    free(wrapper);
    if (failed) goto fail;
    return edit;
fail:
    zw_local_edit_destroy(edit); return NULL;
}
const char *zw_local_edit_directory(ZW_LOCAL_EDIT *edit) { return edit->directory; }
const char *zw_local_edit_nonce(ZW_LOCAL_EDIT *edit) { return edit->nonce; }
/* 0 would-block, 1 bytes, 2 disconnected, 3 newly authenticated connection. */
int zw_local_edit_read(ZW_LOCAL_EDIT *edit, int shell_pid, unsigned char *buffer, size_t length, size_t *count) {
    *count = 0;
    if (edit->connection < 0) {
        int fd = accept(edit->listener, NULL, NULL);
        if (fd < 0) return errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR ? 0 : -1;
        uid_t uid; gid_t gid; pid_t peer = -1; socklen_t size = sizeof(peer);
        if (edit_flags(fd) || getpeereid(fd, &uid, &gid) || uid != getuid() ||
            getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &peer, &size) || peer != shell_pid) { close(fd); return 0; }
        edit->connection = fd;
        return 3;
    }
    ssize_t n = read(edit->connection, buffer, length);
    if (n > 0) { *count = (size_t)n; return 1; }
    if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR)) return 0;
    close(edit->connection); edit->connection = -1;
    return 2;
}
int zw_local_edit_write(ZW_LOCAL_EDIT *edit, const unsigned char *buffer, size_t length, size_t *count) {
    *count = 0;
    if (edit->connection < 0) return -1;
    ssize_t n = send(edit->connection, buffer, length, MSG_NOSIGNAL);
    if (n >= 0) { *count = (size_t)n; return 1; }
    return errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR ? 0 : -1;
}
