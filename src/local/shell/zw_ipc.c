/* System-zsh 5.9 module. Uses only the public module lifecycle ABI: no zsh
 * internal structures or arbitrary-fd builtin. Loading prepares this session's
 * connected socket; unloading closes that connection. */
#include <sys/types.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <fcntl.h>
#include <unistd.h>
#include <stdlib.h>
#include <errno.h>
#include <limits.h>
#include <string.h>
static int connection = -1;
/* System-zsh's exported module parameter API. Values stay shell-local; the
 * App's private channel does not use exported environment variables. */
extern long long getiparam(char *name);
static int number(const char *name) {
    const long long n = getiparam((char *)name);
    return n < 0 || n > INT_MAX ? -1 : (int)n;
}
int setup_(void *module) { (void)module; return 0; }
int features_(void *module, char ***features) { (void)module; (void)features; return 1; }
int enables_(void *module, int **enables) { (void)module; (void)enables; return 1; }
int boot_(void *module) {
    (void)module;
    int fd = number("_zw_fd"), parent = number("_zw_parent");
    int type = 0; socklen_t length = sizeof(type);
    uid_t uid; gid_t gid;
    pid_t peer = -1; socklen_t peer_length = sizeof(peer);
    if (connection >= 0 || fd < 3 || parent < 1 ||
        getsockopt(fd, SOL_SOCKET, SO_TYPE, &type, &length) || type != SOCK_STREAM ||
        getpeereid(fd, &uid, &gid) || uid != getuid() ||
        getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &peer, &peer_length) || peer != parent)
        return 1;
    int flags = fcntl(fd, F_GETFL), descriptor = fcntl(fd, F_GETFD);
    if (flags < 0 || descriptor < 0 ||
        fcntl(fd, F_SETFL, flags | O_NONBLOCK) ||
        fcntl(fd, F_SETFD, descriptor | FD_CLOEXEC) ||
        !(fcntl(fd, F_GETFL) & O_NONBLOCK) || !(fcntl(fd, F_GETFD) & FD_CLOEXEC)) return 1;
    connection = fd;
    return 0;
}
int cleanup_(void *module) {
    (void)module;
    if (connection >= 0) close(connection);
    connection = -1;
    return 0;
}
int finish_(void *module) { (void)module; return 0; }
