/* BootstrapV1 zsh 5.9 module. The execution socket is shell-local and CLOEXEC;
 * terminal output never supplies a protocol event. No zsh structure ABI is used. */
#define _GNU_SOURCE 1
#include <sys/types.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <fcntl.h>
#include <unistd.h>
#include <limits.h>
static int connection = -1;
extern long long getiparam(char *);
static int number(char *name) {
    long long n = getiparam(name);
    return n < 0 || n > INT_MAX ? -1 : (int)n;
}
int setup_(void *m) { (void)m; return 0; }
int features_(void *m, char ***f) { (void)m; (void)f; return 1; }
int enables_(void *m, int **e) { (void)m; (void)e; return 1; }
int boot_(void *m) {
    (void)m;
    int fd = number("_zw_exec_fd"), parent = number("_zw_parent"), type = 0;
    socklen_t length = sizeof(type);
    if (connection >= 0 || fd < 3 || parent < 1 ||
        getsockopt(fd, SOL_SOCKET, SO_TYPE, &type, &length) || type != SOCK_STREAM)
        return 1;
#if defined(__linux__)
    struct ucred peer;
    length = sizeof(peer);
    if (getsockopt(fd, SOL_SOCKET, SO_PEERCRED, &peer, &length) ||
        peer.uid != getuid() || peer.pid != parent) return 1;
#elif defined(__APPLE__)
    uid_t uid; gid_t gid; pid_t peer = -1;
    length = sizeof(peer);
    if (getpeereid(fd, &uid, &gid) || uid != getuid() ||
        getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &peer, &length) || peer != parent)
        return 1;
#else
#error BootstrapV1 needs a verified local peer credential API
#endif
    int flags = fcntl(fd, F_GETFL), descriptor = fcntl(fd, F_GETFD);
    if (flags < 0 || descriptor < 0 || fcntl(fd, F_SETFL, flags | O_NONBLOCK) ||
        fcntl(fd, F_SETFD, descriptor | FD_CLOEXEC) ||
        !(fcntl(fd, F_GETFL) & O_NONBLOCK) || !(fcntl(fd, F_GETFD) & FD_CLOEXEC))
        return 1;
    connection = fd;
    return 0;
}
int cleanup_(void *m) {
    (void)m;
    if (connection >= 0) close(connection);
    connection = -1;
    return 0;
}
int finish_(void *m) { (void)m; return 0; }
