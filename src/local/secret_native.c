/* Fresh per-consumer secret connection. Existing execution sockets can be
 * inherited by forked shell builtins, so secret bytes never use those FDs. */
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
extern const char *zw_local_edit_directory(void *);
typedef struct { int listener, connection, bound; char path[104]; } ZW_LOCAL_SECRET;
static int flags(int fd) {
    int value = fcntl(fd, F_GETFL);
    return value < 0 || fcntl(fd, F_SETFL, value | O_NONBLOCK) || fcntl(fd, F_SETFD, FD_CLOEXEC);
}
void zw_local_secret_destroy(ZW_LOCAL_SECRET *secret) {
    if (!secret) return;
    if (secret->connection >= 0) close(secret->connection);
    if (secret->listener >= 0) close(secret->listener);
    if (secret->bound) unlink(secret->path);
    free(secret);
}
ZW_LOCAL_SECRET *zw_local_secret_create(void *edit) {
    ZW_LOCAL_SECRET *secret = calloc(1, sizeof(*secret));
    if (!secret) return NULL;
    secret->listener = secret->connection = -1;
    const char *directory = zw_local_edit_directory(edit);
    if (!directory || snprintf(secret->path, sizeof(secret->path), "%s/execution-secret", directory) >= (int)sizeof(secret->path)) goto fail;
    secret->listener = socket(AF_UNIX, SOCK_STREAM, 0);
    if (secret->listener < 0 || flags(secret->listener)) goto fail;
    struct sockaddr_un address = { .sun_family = AF_UNIX };
    strcpy(address.sun_path, secret->path);
    if (bind(secret->listener, (struct sockaddr *)&address, sizeof(address))) goto fail;
    secret->bound = 1;
    if (chmod(secret->path, 0600) || listen(secret->listener, 4)) goto fail;
    return secret;
fail:
    zw_local_secret_destroy(secret); return NULL;
}
int zw_local_secret_read(ZW_LOCAL_SECRET *secret, int shell_pid, unsigned char *buffer, size_t length, size_t *count) {
    *count = 0;
    if (secret->connection < 0) {
        int fd = accept(secret->listener, NULL, NULL);
        if (fd < 0) return errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR ? 0 : -1;
        uid_t uid; gid_t gid; pid_t peer = -1; socklen_t size = sizeof(peer);
        /* A child forked before the consumer can connect but cannot impersonate
         * the original zsh process. Native consumer creates its FD after fork. */
        if (flags(fd) || getpeereid(fd, &uid, &gid) || uid != getuid() || getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &peer, &size) || peer != shell_pid) { close(fd); return 0; }
        secret->connection = fd; return 3;
    }
    ssize_t n = read(secret->connection, buffer, length);
    if (n > 0) { *count = (size_t)n; return 1; }
    if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR)) return 0;
    close(secret->connection); secret->connection = -1; return 2;
}
int zw_local_secret_write(ZW_LOCAL_SECRET *secret, const unsigned char *buffer, size_t length, size_t *count) {
    *count = 0;
    if (secret->connection < 0) return -1;
    ssize_t n = send(secret->connection, buffer, length, MSG_NOSIGNAL);
    if (n >= 0) { *count = (size_t)n; return 1; }
    return errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR ? 0 : -1;
}
void zw_local_secret_close(ZW_LOCAL_SECRET *secret) {
    if (secret->connection >= 0) close(secret->connection);
    secret->connection = -1;
}
