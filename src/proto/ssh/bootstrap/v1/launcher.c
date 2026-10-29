/* BootstrapV1 launcher and private-channel relay. It never injects a command
 * into a PTY: sshd starts `shell` on a new PTY, and a separate no-PTY SSH exec
 * runs `control`. Only the owned shell gets the private integration config. */
#define _GNU_SOURCE 1
#include <sys/types.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <fcntl.h>
#include <unistd.h>
#include <poll.h>
#include <signal.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <time.h>

static int hex(const char *s, size_t n) {
    if (strlen(s) != n) return 0;
    for (size_t i = 0; i < n; ++i)
        if (!((s[i] >= '0' && s[i] <= '9') || (s[i] >= 'a' && s[i] <= 'f'))) return 0;
    return 1;
}
static int decimal(const char *s) {
    if (!*s || strlen(s) > 20) return 0;
    for (; *s; ++s) if (*s < '0' || *s > '9') return 0;
    return 1;
}
static int directory(const char *path) {
    const char *prefix = "/tmp/zw-bootstrap-v1-";
    struct stat st;
    return !strncmp(path, prefix, strlen(prefix)) && hex(path + strlen(prefix), 32) &&
        !lstat(path, &st) && S_ISDIR(st.st_mode) && st.st_uid == getuid() &&
        (st.st_mode & 0777) == 0700;
}
static int path_for(char *out, size_t capacity, const char *dir, const char *name) {
    int n = snprintf(out, capacity, "%s/%s", dir, name);
    return n > 0 && (size_t)n < capacity ? 0 : -1;
}
static int nonblocking(int fd) {
    int flags = fcntl(fd, F_GETFL), descriptor = fcntl(fd, F_GETFD);
    return flags < 0 || descriptor < 0 || fcntl(fd, F_SETFL, flags | O_NONBLOCK) ||
        fcntl(fd, F_SETFD, descriptor | FD_CLOEXEC) ? -1 : 0;
}
static int listener(const char *path) {
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    int created = 0;
    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr)); addr.sun_family = AF_UNIX;
    if (fd < 0 || strlen(path) >= sizeof(addr.sun_path)) goto fail;
    strcpy(addr.sun_path, path);
    if (bind(fd, (struct sockaddr *)&addr, sizeof(addr))) goto fail;
    created = 1;
    if (chmod(path, 0600) || listen(fd, 1) || nonblocking(fd)) goto fail;
    return fd;
fail:
    if (fd >= 0) close(fd);
    if (created) unlink(path);
    return -1;
}
static int peer(int fd, pid_t expected_pid) {
#if defined(__linux__)
    struct ucred info; socklen_t len = sizeof(info);
    return !getsockopt(fd, SOL_SOCKET, SO_PEERCRED, &info, &len) &&
        info.uid == getuid() && (!expected_pid || info.pid == expected_pid);
#elif defined(__APPLE__)
    uid_t uid; gid_t gid; pid_t pid = -1; socklen_t len = sizeof(pid);
    return !getpeereid(fd, &uid, &gid) && uid == getuid() &&
        !getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &len) &&
        (!expected_pid || pid == expected_pid);
#else
    (void)fd; (void)expected_pid; return 0;
#endif
}
static int64_t now_ms(void) {
    struct timespec ts;
    if (clock_gettime(CLOCK_MONOTONIC, &ts)) return -1;
    return (int64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}
struct buffer { unsigned char bytes[262144]; size_t used, sent; };
/* Each partial write retains the exact buffer and offset. No resend after an
 * ambiguous failure, no framing or text interpretation in this relay. */
static int relay(int input, int output, int socket_fd, pid_t shell) {
    struct buffer to_socket = {{0},0,0}, from_socket = {{0},0,0};
    if (nonblocking(input) || nonblocking(output) || nonblocking(socket_fd)) return -1;
    for (;;) {
        if (shell) {
            siginfo_t info; memset(&info, 0, sizeof(info));
            if (!waitid(P_PID, (id_t)shell, &info, WEXITED | WNOHANG | WNOWAIT) && info.si_pid) return 0;
        }
        struct pollfd p[3] = {
            {input, to_socket.used == 0 ? POLLIN : 0, 0},
            {socket_fd, (short)((from_socket.used == 0 ? POLLIN : 0) | (to_socket.used ? POLLOUT : 0)), 0},
            {output, from_socket.used ? POLLOUT : 0, 0}
        };
        int rc = poll(p, 3, 50);
        if (rc < 0) { if (errno == EINTR) continue; return -1; }
        if (p[0].revents & POLLIN) {
            ssize_t n = read(input, to_socket.bytes, sizeof(to_socket.bytes));
            if (n == 0) return 0;
            if (n > 0) { to_socket.used = (size_t)n; to_socket.sent = 0; }
            else if (errno != EAGAIN && errno != EINTR) return -1;
        }
        if (p[1].revents & POLLIN) {
            ssize_t n = read(socket_fd, from_socket.bytes, sizeof(from_socket.bytes));
            if (n == 0) return 0;
            if (n > 0) { from_socket.used = (size_t)n; from_socket.sent = 0; }
            else if (errno != EAGAIN && errno != EINTR) return -1;
        }
        if ((p[1].revents & POLLOUT) && to_socket.used) {
            ssize_t n = write(socket_fd, to_socket.bytes + to_socket.sent, to_socket.used - to_socket.sent);
            if (n > 0) { to_socket.sent += (size_t)n; if (to_socket.sent == to_socket.used) to_socket.used = to_socket.sent = 0; }
            else if (n < 0 && errno != EAGAIN && errno != EINTR) return -1;
        }
        if ((p[2].revents & POLLOUT) && from_socket.used) {
            ssize_t n = write(output, from_socket.bytes + from_socket.sent, from_socket.used - from_socket.sent);
            if (n > 0) { from_socket.sent += (size_t)n; if (from_socket.sent == from_socket.used) from_socket.used = from_socket.sent = 0; }
            else if (n < 0 && errno != EAGAIN && errno != EINTR) return -1;
        }
        if ((p[0].revents | p[1].revents | p[2].revents) & (POLLERR | POLLNVAL)) return -1;
        if ((p[0].revents & POLLHUP) && !(p[0].revents & POLLIN)) return 0;
        if ((p[1].revents & POLLHUP) && !(p[1].revents & POLLIN)) return 0;
    }
}
static int create_config(const char *dir, const char *session, const char *generation, const char *nonce) {
    char path[128];
    if (path_for(path, sizeof(path), dir, ".zshrc")) return -1;
    int fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
    if (fd < 0) return -1;
    FILE *file = fdopen(fd, "w");
    if (!file) { close(fd); unlink(path); return -1; }
    int rc = fprintf(file,
        "unset HISTFILE\nSAVEHIST=0\nPS1='ZeroWork> '\n"
        "typeset -g _zw_session=%s _zw_generation=%s _zw_nonce='%s' _zw_module_dir='%s' _zw_exec_socket='%s/shell.sock'\n"
        "typeset -gi _zw_parent=%ld _zw_token=1\nsource '%s/execution.zsh'\n",
        session, generation, nonce, dir, dir, (long)getpid(), dir);
    int error = rc < 0 || fflush(file) || fsync(fd);
    if (fclose(file)) error = 1;
    if (error) unlink(path);
    return error ? -1 : 0;
}
static int control(const char *dir) {
    char path[128]; struct sockaddr_un addr;
    if (path_for(path, sizeof(path), dir, "control.sock")) return 70;
    memset(&addr, 0, sizeof(addr)); addr.sun_family = AF_UNIX;
    if (strlen(path) >= sizeof(addr.sun_path)) return 70;
    strcpy(addr.sun_path, path);
    int fd = -1;
    int64_t deadline = now_ms() + 15000;
    while (now_ms() < deadline) {
        fd = socket(AF_UNIX, SOCK_STREAM, 0);
        if (fd < 0 || nonblocking(fd)) { if (fd >= 0) close(fd); return 70; }
        if (!connect(fd, (struct sockaddr *)&addr, sizeof(addr))) break;
        int saved = errno; close(fd); fd = -1;
        if (saved != ENOENT && saved != ECONNREFUSED && saved != EAGAIN && saved != EINPROGRESS) return 70;
        struct pollfd cancelled = {STDIN_FILENO, 0, 0};
        if (poll(&cancelled, 1, 5) < 0 || (cancelled.revents & (POLLHUP | POLLERR))) return 70;
    }
    if (fd < 0 || !peer(fd, 0)) { if (fd >= 0) close(fd); return 70; }
    int rc = relay(STDIN_FILENO, STDOUT_FILENO, fd, 0);
    close(fd);
    return rc ? 70 : 0;
}
static int shell(const char *dir, const char *session, const char *generation, const char *nonce, const char *zsh) {
    char shell_path[128], control_path[128], rc_path[128];
    if (!isatty(0) || !isatty(1) || !decimal(session) || !decimal(generation) || !hex(nonce, 64) ||
        (strcmp(zsh, "/bin/zsh") && strcmp(zsh, "/usr/bin/zsh"))) return 64;
    if (path_for(shell_path, sizeof(shell_path), dir, "shell.sock") ||
        path_for(control_path, sizeof(control_path), dir, "control.sock") ||
        path_for(rc_path, sizeof(rc_path), dir, ".zshrc")) return 64;
    int a = listener(shell_path), b = listener(control_path), x = -1, y = -1, status = 0;
    if (a < 0 || b < 0 || create_config(dir, session, generation, nonce)) goto fail;
    pid_t child = fork();
    if (child < 0) goto fail;
    if (!child) {
        close(a); close(b);
        /* The launcher owns every inherited fd above stderr. */
        long max = sysconf(_SC_OPEN_MAX); if (max < 0 || max > 1048576) max = 1048576;
        for (int fd = 3; fd < max; ++fd) close(fd);
        if (setenv("ZDOTDIR", dir, 1)) _exit(70);
        execl(zsh, zsh, "-d", "-i", (char *)NULL); _exit(70);
    }
    signal(SIGINT, SIG_IGN); signal(SIGQUIT, SIG_IGN);
    int64_t deadline = now_ms() + 15000;
    while ((x < 0 || y < 0) && now_ms() < deadline) {
        struct pollfd p[2] = {{a, x < 0 ? POLLIN : 0, 0}, {b, y < 0 ? POLLIN : 0, 0}};
        int rc = poll(p, 2, 50);
        if (rc < 0 && errno != EINTR) break;
        if (x < 0 && (p[0].revents & POLLIN)) {
            int fd = accept(a, NULL, NULL);
            if (fd >= 0 && peer(fd, child) && !nonblocking(fd)) x = fd;
            else if (fd >= 0) close(fd);
        }
        if (y < 0 && (p[1].revents & POLLIN)) {
            int fd = accept(b, NULL, NULL);
            if (fd >= 0 && peer(fd, 0) && !nonblocking(fd)) y = fd;
            else if (fd >= 0) close(fd);
        }
        if (waitpid(child, &status, WNOHANG) == child) { child = 0; break; }
    }
    close(a); a = -1; close(b); b = -1;
    if (x >= 0 && y >= 0 && child) (void)relay(y, y, x, child);
    if (x >= 0) close(x);
    if (y >= 0) close(y);
    /* Integration loss revokes the private socket, but never kills a user's
     * foreground program or invents its completion. The PTY remains usable. */
    if (child) while (waitpid(child, &status, 0) < 0 && errno == EINTR) {}
    unlink(shell_path); unlink(control_path); unlink(rc_path);
    return WIFEXITED(status) ? WEXITSTATUS(status) : 128 + WTERMSIG(status);
fail:
    if (a >= 0) { close(a); unlink(shell_path); }
    if (b >= 0) { close(b); unlink(control_path); }
    return 70;
}
int main(int argc, char **argv) {
    signal(SIGPIPE, SIG_IGN);
    if (argc == 2 && !strcmp(argv[1], "version")) {
        puts("ZeroWork BootstrapV1 zsh5.9 session_interval private-relay-v1"); return 0;
    }
    if (argc < 3 || !directory(argv[2])) return 64;
    if (argc == 3 && !strcmp(argv[1], "control")) return control(argv[2]);
    if (argc == 7 && !strcmp(argv[1], "shell")) return shell(argv[2], argv[3], argv[4], argv[5], argv[6]);
    return 64;
}
