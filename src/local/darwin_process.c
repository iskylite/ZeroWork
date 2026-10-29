#include "darwin_process.h"
#include <crt_externs.h>
#include <errno.h>
#include <fcntl.h>
#include <libproc.h>
#include <limits.h>
#include <poll.h>
#include <pwd.h>
#include <signal.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/proc.h>
#include <sys/proc_info.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <termios.h>
#include <time.h>
#include <unistd.h>
#include <util.h>

typedef struct { pid_t pid, pgid; uint64_t seconds, micros; } Member;
struct zw_local_process {
    pid_t pid, sid;
    Member leader;
    Member *members;
    size_t member_count;
    int fd, error_fd, pty, eof, error_eof, reaped, exit_observed, closed;
    int close_started, close_phase, close_retry;
    uint64_t signal_ms, close_retry_ms;
    ZW_LOCAL_EXIT exit;
    ZW_LOCAL_OBSERVATION_FAILURE observation_failure;
    char *cwd;
};

int zw_local_poll_fd(ZW_LOCAL_PROCESS *p) { return p && !p->closed ? p->fd : -1; }

static void close_fd(int *fd) { if (*fd >= 0) { close(*fd); *fd = -1; } }
static int configure_fd(int fd, int nonblocking) {
    if (fcntl(fd, F_SETFD, FD_CLOEXEC) < 0) return -1;
    if (nonblocking && fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) < 0) return -1;
    return 0;
}
static int process_info(pid_t pid, struct proc_bsdinfo *info) {
    errno = 0;
    int bytes = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, info, sizeof(*info));
    if (bytes == sizeof(*info)) return 1;
    if (!errno) errno = EIO;
    return 0;
}
static Member member_info(const struct proc_bsdinfo *info) {
    return (Member){ (pid_t)info->pbi_pid, (pid_t)info->pbi_pgid, info->pbi_start_tvsec, info->pbi_start_tvusec };
}
static int still_owned(const ZW_LOCAL_PROCESS *p, const Member *member) {
    struct proc_bsdinfo info;
    return process_info(member->pid, &info) && info.pbi_start_tvsec == member->seconds &&
        info.pbi_start_tvusec == member->micros && getsid(member->pid) == p->sid &&
        (pid_t)info.pbi_pgid == member->pgid;
}

/* Stages: 1 list size, 2 list data, 3 allocation, 4 member metadata,
 * 5 session trust, 6 wait observation, 7 wait reap, 8 group trust, 9 signal. */
static int observation_failed(ZW_LOCAL_PROCESS *p, int stage, int error_number, pid_t pid) {
    if (!error_number) error_number = EIO;
    p->observation_failure = (ZW_LOCAL_OBSERVATION_FAILURE){stage, error_number, pid};
    if (getenv("ZEROWORK_LOCAL_CLOSE_DIAGNOSTICS"))
        fprintf(stderr, "local observation failure owner_pid=%d stage=%d errno=%d pid=%d\n", p->pid, stage, error_number, pid);
    errno = error_number;
    return -1;
}

/* Session numbers alone are not ownership. At least one previously observed
 * process birth identity must survive before a non-empty set may be trusted. */
static int scan_members(ZW_LOCAL_PROCESS *p) {
    int trusted = (!p->reaped && p->exit_observed) || still_owned(p, &p->leader);
    for (size_t i = 0; !trusted && i < p->member_count; ++i) trusted = still_owned(p, &p->members[i]);
    errno = 0;
    int size = proc_listpids(PROC_ALL_PIDS, 0, NULL, 0);
    if (size <= 0 || size > INT_MAX / 2) return observation_failed(p, 1, size <= 0 ? errno : EOVERFLOW, p->pid);
    size += 1024 * sizeof(pid_t);
    pid_t *pids = malloc((size_t)size);
    if (!pids) return observation_failed(p, 3, ENOMEM, p->pid);
    errno = 0;
    int bytes = proc_listpids(PROC_ALL_PIDS, 0, pids, size);
    if (bytes <= 0 || bytes >= size) { int saved = bytes <= 0 ? errno : EOVERFLOW; free(pids); return observation_failed(p, 2, saved, p->pid); }
    size_t capacity = (size_t)bytes / sizeof(pid_t), count = 0;
    Member *members = capacity ? malloc(capacity * sizeof(Member)) : NULL;
    if (capacity && !members) { free(pids); return observation_failed(p, 3, ENOMEM, p->pid); }
    for (size_t i = 0; i < capacity; ++i) {
        if (pids[i] <= 0 || getsid(pids[i]) != p->sid) continue;
        struct proc_bsdinfo info;
        if (!process_info(pids[i], &info)) {
            int metadata_error = errno;
            if (kill(pids[i], 0) == 0 || errno != ESRCH) { pid_t pid = pids[i]; free(pids); free(members); return observation_failed(p, 4, metadata_error, pid); }
            continue;
        }
        if (info.pbi_status == SZOMB) continue;
        members[count++] = member_info(&info);
    }
    free(pids);
    if (count && !trusted) { free(members); return observation_failed(p, 5, ESTALE, p->pid); }
    free(p->members);
    p->members = members;
    p->member_count = count;
    return 0;
}

static int signal_groups(ZW_LOCAL_PROCESS *p, int signal_number) {
    for (size_t i = 0; i < p->member_count; ++i) {
        pid_t group = p->members[i].pgid;
        if (group <= 0 || group == getpgrp()) return observation_failed(p, 8, EPERM, p->members[i].pid);
        int earlier = 0;
        for (size_t j = 0; j < i; ++j) if (p->members[j].pgid == group) earlier = 1;
        if (earlier) continue;
        int verified = 0;
        for (size_t j = i; j < p->member_count; ++j) {
            if (p->members[j].pgid == group && still_owned(p, &p->members[j])) { verified = 1; break; }
        }
        if (!verified) {
            int probe = kill(-group, 0);
            if (probe < 0 && errno == ESRCH) continue;
            if (probe < 0 && errno != EPERM) return observation_failed(p, 8, errno, p->members[i].pid);
            /* Exit can invalidate every scanned birth identity while the
             * process group still contains unreaped zombies. Darwin may
             * return EPERM for that group's signal-zero probe. Do not signal
             * that group, or call the whole cleanup unknown on one sample. */
            observation_failed(p, 8, probe < 0 ? errno : ESTALE, p->members[i].pid);
            return -2;
        }
        if (kill(-group, signal_number) < 0 && errno != ESRCH) return observation_failed(p, 9, errno, p->members[i].pid);
    }
    return 0;
}

static char *resolve_cwd(const char *cwd) {
    if (cwd) return realpath(cwd, NULL);
    long needed = sysconf(_SC_GETPW_R_SIZE_MAX);
    size_t size = needed > 0 ? (size_t)needed : 16384;
    if (size > 1024 * 1024) { errno = ERANGE; return NULL; }
    char *buffer = malloc(size);
    if (!buffer) return NULL;
    struct passwd record, *result = NULL;
    int rc = getpwuid_r(getuid(), &record, buffer, size, &result);
    char *resolved = rc == 0 && result ? realpath(result->pw_dir, NULL) : NULL;
    if (!resolved && rc) errno = rc;
    free(buffer);
    return resolved;
}

static void child_failed(int fd, int stage) {
    ZW_LOCAL_FAILURE failure = { stage, errno };
    ssize_t ignored;
    do { ignored = write(fd, &failure, sizeof(failure)); } while (ignored < 0 && errno == EINTR);
    _exit(127);
}

/* Darwin does not acquire a controlling tty from posix_spawn's open action.
 * Prepare everything in the parent; the child uses only descriptor/signal/
 * process syscalls before execve, with no allocator, logging or Zig runtime. */
static int spawn_pty(pid_t *pid, int slave, int cwd_fd, char **argv, char **env, int *stage) {
    int status[2];
    if (pipe(status) < 0) return errno;
    if (configure_fd(status[0], 0) < 0 || configure_fd(status[1], 0) < 0) {
        int saved = errno; close(status[0]); close(status[1]); return saved;
    }
    /* Prepare the exec policy before fork. Darwin's SETEXEC replaces this
     * child in place; CLOEXEC_DEFAULT closes even descriptors inherited from
     * other libraries/threads. Iterating OPEN_MAX here used a million close()
     * calls on systems with a large descriptor limit. Only stdio is inherited. */
    posix_spawn_file_actions_t exec_actions;
    posix_spawnattr_t exec_attr;
    int saved = posix_spawn_file_actions_init(&exec_actions);
    if (saved) { close(status[0]); close(status[1]); return saved; }
    saved = posix_spawnattr_init(&exec_attr);
    if (saved) { posix_spawn_file_actions_destroy(&exec_actions); close(status[0]); close(status[1]); return saved; }
    saved = posix_spawnattr_setflags(&exec_attr, POSIX_SPAWN_SETEXEC | POSIX_SPAWN_CLOEXEC_DEFAULT);
    for (int fd = 0; !saved && fd < 3; ++fd) saved = posix_spawn_file_actions_adddup2(&exec_actions, fd, fd);
    if (saved) {
        posix_spawnattr_destroy(&exec_attr); posix_spawn_file_actions_destroy(&exec_actions);
        close(status[0]); close(status[1]); return saved;
    }
    pid_t child = fork();
    if (child < 0) {
        saved = errno;
        posix_spawnattr_destroy(&exec_attr); posix_spawn_file_actions_destroy(&exec_actions);
        close(status[0]); close(status[1]); return saved;
    }
    if (child == 0) {
        close(status[0]);
        sigset_t mask;
        sigemptyset(&mask);
        if (sigprocmask(SIG_SETMASK, &mask, NULL) < 0) child_failed(status[1], 4);
        struct sigaction reset = { .sa_handler = SIG_DFL };
        sigemptyset(&reset.sa_mask);
        for (int signal_number = 1; signal_number < NSIG; ++signal_number) {
            if (signal_number != SIGKILL && signal_number != SIGSTOP && sigaction(signal_number, &reset, NULL) < 0) child_failed(status[1], 4);
        }
        if (setsid() < 0 || ioctl(slave, TIOCSCTTY, 0) < 0 || tcsetpgrp(slave, getpid()) < 0) child_failed(status[1], 2);
        if (fchdir(cwd_fd) < 0) child_failed(status[1], 1);
        for (int fd = 0; fd < 3; ++fd) {
            if (dup2(slave, fd) < 0 || fcntl(fd, F_SETFD, 0) < 0) child_failed(status[1], 2);
        }
        pid_t unused;
        errno = posix_spawn(&unused, "/bin/zsh", &exec_actions, &exec_attr, argv, env);
        child_failed(status[1], 4);
    }
    posix_spawnattr_destroy(&exec_attr);
    posix_spawn_file_actions_destroy(&exec_actions);
    close(status[1]);
    ZW_LOCAL_FAILURE failure;
    ssize_t count;
    do { count = read(status[0], &failure, sizeof(failure)); } while (count < 0 && errno == EINTR);
    close(status[0]);
    if (count != 0) {
        int saved = count == sizeof(failure) ? failure.error_number : EIO;
        if (count == sizeof(failure)) *stage = failure.stage;
        kill(child, SIGKILL);
        while (waitpid(child, NULL, 0) < 0 && errno == EINTR) {}
        return saved;
    }
    *pid = child;
    return 0;
}

static ZW_LOCAL_PROCESS *start(const char *cwd, const char *term, const char *command,
                             unsigned short cols, unsigned short rows, const char *bootstrap, ZW_LOCAL_FAILURE *failure) {
    ZW_LOCAL_PROCESS *p = calloc(1, sizeof(*p));
    if (!p) { *failure = (ZW_LOCAL_FAILURE){ 1, ENOMEM }; return NULL; }
    p->fd = p->error_fd = -1;
    p->pty = command == NULL;
    p->error_eof = p->pty;
    int stage = 1, cwd_fd = -1, slave = -1, out_pipe[2] = {-1,-1}, err_pipe[2] = {-1,-1};
    int actions_live = 0, attr_live = 0, saved_error = 0;
    posix_spawn_file_actions_t actions;
    posix_spawnattr_t attr;
    char slave_name[PATH_MAX];
    char **environment = NULL, *term_value = NULL, *zdotdir_value = NULL;
    p->cwd = resolve_cwd(cwd);
    if (!p->cwd) goto fail;
    cwd_fd = open(p->cwd, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    if (cwd_fd < 0) goto fail;
    if (p->pty) {
        stage = 2;
        struct winsize dimensions = { .ws_row = rows, .ws_col = cols };
        if (openpty(&p->fd, &slave, slave_name, NULL, &dimensions) < 0 || configure_fd(p->fd, 1) < 0 || configure_fd(slave, 0) < 0) goto fail;
    } else {
        stage = 3;
        if (pipe(out_pipe) < 0 || pipe(err_pipe) < 0) goto fail;
        for (int i = 0; i < 2; ++i) if (configure_fd(out_pipe[i], i == 0) < 0 || configure_fd(err_pipe[i], i == 0) < 0) goto fail;
        p->fd = out_pipe[0]; out_pipe[0] = -1;
        p->error_fd = err_pipe[0]; err_pipe[0] = -1;
    }
    stage = 4;
    if ((saved_error = posix_spawn_file_actions_init(&actions))) goto fail;
    actions_live = 1;
    if ((saved_error = posix_spawnattr_init(&attr))) goto fail;
    attr_live = 1;
    sigset_t mask, defaults;
    sigemptyset(&mask); sigfillset(&defaults);
    sigdelset(&defaults, SIGKILL); sigdelset(&defaults, SIGSTOP);
    if ((saved_error = posix_spawnattr_setsigmask(&attr, &mask)) ||
        (saved_error = posix_spawnattr_setsigdefault(&attr, &defaults)) ||
        (saved_error = posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF))) goto fail;
    /* macOS 14 baseline: the unsuffixed replacement requires macOS 26. */
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    saved_error = posix_spawn_file_actions_addfchdir_np(&actions, cwd_fd);
#pragma clang diagnostic pop
    if (saved_error) goto fail;
    if (!p->pty) {
        if ((saved_error = posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)) ||
            (saved_error = posix_spawn_file_actions_adddup2(&actions, out_pipe[1], STDOUT_FILENO)) ||
            (saved_error = posix_spawn_file_actions_adddup2(&actions, err_pipe[1], STDERR_FILENO))) goto fail;
    }
    char **inherited = *_NSGetEnviron();
    size_t env_count = 0;
    while (inherited[env_count]) ++env_count;
    environment = calloc(env_count + 3, sizeof(char *));
    if (!environment) { saved_error = ENOMEM; goto fail; }
    size_t next = 0;
    for (size_t i = 0; i < env_count; ++i) if ((!p->pty || strncmp(inherited[i], "TERM=", 5)) && (!bootstrap || strncmp(inherited[i], "ZDOTDIR=", 8))) environment[next++] = inherited[i];
    if (p->pty) {
        size_t len = strlen(term);
        term_value = malloc(len + 6);
        if (!term_value) { saved_error = ENOMEM; goto fail; }
        memcpy(term_value, "TERM=", 5); memcpy(term_value + 5, term, len + 1);
        environment[next++] = term_value;
        if (bootstrap) {
            size_t dir_len = strlen(bootstrap);
            zdotdir_value = malloc(dir_len + 9);
            if (!zdotdir_value) { saved_error = ENOMEM; goto fail; }
            memcpy(zdotdir_value, "ZDOTDIR=", 8); memcpy(zdotdir_value + 8, bootstrap, dir_len + 1);
            environment[next++] = zdotdir_value;
        }
    }
    char *interactive[] = { "/bin/zsh", "-l", "-i", NULL };
    char *exec_args[] = { "/bin/zsh", "-l", "-c", (char *)command, NULL };
    saved_error = p->pty ? spawn_pty(&p->pid, slave, cwd_fd, interactive, environment, &stage) :
        posix_spawn(&p->pid, "/bin/zsh", &actions, &attr, exec_args, environment);
    if (saved_error) goto fail;
    p->sid = p->pid;
    stage = 5;
    struct proc_bsdinfo leader;
    if (!process_info(p->pid, &leader) || getsid(p->pid) != p->sid) {
        saved_error = ECHILD;
        /* A not-yet-reaped direct child cannot have had its PID reused. */
        kill(p->pid, SIGKILL);
        while (waitpid(p->pid, NULL, 0) < 0 && errno == EINTR) {}
        goto fail;
    }
    p->leader = member_info(&leader);
    posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attr);
    close_fd(&cwd_fd); close_fd(&slave); close_fd(&out_pipe[1]); close_fd(&err_pipe[1]);
    free(environment); free(term_value); free(zdotdir_value);
    return p;
fail:
    *failure = (ZW_LOCAL_FAILURE){ stage, saved_error ? saved_error : errno };
    if (actions_live) posix_spawn_file_actions_destroy(&actions);
    if (attr_live) posix_spawnattr_destroy(&attr);
    close_fd(&cwd_fd); close_fd(&slave); close_fd(&p->fd); close_fd(&p->error_fd);
    close_fd(&out_pipe[0]); close_fd(&out_pipe[1]); close_fd(&err_pipe[0]); close_fd(&err_pipe[1]);
    free(environment); free(term_value); free(zdotdir_value); free(p->cwd); free(p);
    return NULL;
}

ZW_LOCAL_PROCESS *zw_local_start_pty(const char *cwd, const char *term, unsigned short cols, unsigned short rows, ZW_LOCAL_FAILURE *failure) {
    return start(cwd, term, NULL, cols, rows, NULL, failure);
}
ZW_LOCAL_PROCESS *zw_local_start_pty_edit(const char *cwd, const char *term, unsigned short cols, unsigned short rows, const char *bootstrap, ZW_LOCAL_FAILURE *failure) {
    return start(cwd, term, NULL, cols, rows, bootstrap, failure);
}
ZW_LOCAL_PROCESS *zw_local_start_exec(const char *cwd, const char *command, ZW_LOCAL_FAILURE *failure) {
    return start(cwd, NULL, command, 0, 0, NULL, failure);
}
int zw_local_read(ZW_LOCAL_PROCESS *p, int stream, unsigned char *buffer, size_t len, size_t *count) {
    if (p->closed) { errno = EBADF; return -1; }
    int *eof = stream == 0 ? &p->eof : &p->error_eof;
    int fd = stream == 0 ? p->fd : p->error_fd;
    *count = 0;
    if (*eof) return 2;
    if (!len) return 0;
    ssize_t n;
    do { n = read(fd, buffer, len); } while (n < 0 && errno == EINTR);
    if (n > 0) { *count = (size_t)n; return 1; }
    if (n == 0) { *eof = 1; return 2; }
    if (errno == EAGAIN || errno == EWOULDBLOCK) return 0;
    if (p->pty && errno == EIO) {
        struct pollfd ready = { .fd = fd, .events = POLLIN };
        if (p->reaped || (poll(&ready, 1, 0) > 0 && (ready.revents & POLLHUP))) { *eof = 1; return 2; }
    }
    return -1;
}
int zw_local_write(ZW_LOCAL_PROCESS *p, const unsigned char *bytes, size_t len, size_t *count) {
    if (!p->pty || p->closed || p->close_started || p->eof || p->reaped) { errno = EBADF; return -1; }
    ssize_t n;
    do { n = write(p->fd, bytes, len); } while (n < 0 && errno == EINTR);
    if (n >= 0) { *count = (size_t)n; return 1; }
    if (errno == EAGAIN || errno == EWOULDBLOCK) { *count = 0; return 0; }
    return -1;
}
int zw_local_resize(ZW_LOCAL_PROCESS *p, unsigned short cols, unsigned short rows) {
    if (!p->pty || p->closed || p->close_started || !cols || !rows) { errno = EINVAL; return -1; }
    struct winsize value = { .ws_col = cols, .ws_row = rows };
    return ioctl(p->fd, TIOCSWINSZ, &value);
}
int zw_local_dimensions(ZW_LOCAL_PROCESS *p, unsigned short *cols, unsigned short *rows) {
    struct winsize value;
    if (!p->pty || p->closed || ioctl(p->fd, TIOCGWINSZ, &value) < 0) return -1;
    *cols = value.ws_col; *rows = value.ws_row; return 0;
}
int zw_local_poll_exit(ZW_LOCAL_PROCESS *p, ZW_LOCAL_EXIT *out) {
    if (p->reaped) { *out = p->exit; return 1; }
    siginfo_t pending = {0};
    int probe;
    do { probe = waitid(P_PID, (id_t)p->pid, &pending, WEXITED | WNOHANG | WNOWAIT); } while (probe < 0 && errno == EINTR);
    if (probe < 0) return observation_failed(p, 6, errno, p->pid);
    if (pending.si_pid == 0) return 0;
    if (pending.si_pid != p->pid) return observation_failed(p, 6, ECHILD, p->pid);
    /* WNOWAIT proves this is still our unreaped direct child even on Darwin
     * versions where getsid/proc_pidinfo no longer expose zombie metadata. */
    p->exit_observed = 1;
    /* Freeze surviving members after exit is observable but while the zombie
     * leader still proves the session identity. A pre-exit scan races a final
     * fork and must not be used as the only ownership evidence after reap. */
    if (scan_members(p) < 0) return -1;
    int status;
    pid_t result;
    do { result = waitpid(p->pid, &status, WNOHANG); } while (result < 0 && errno == EINTR);
    if (result == 0) return 0;
    if (result < 0) return observation_failed(p, 7, errno, p->pid);
    if (WIFEXITED(status)) p->exit = (ZW_LOCAL_EXIT){ 1, WEXITSTATUS(status) };
    else if (WIFSIGNALED(status)) p->exit = (ZW_LOCAL_EXIT){ 2, WTERMSIG(status) };
    else return observation_failed(p, 7, ECHILD, p->pid);
    p->reaped = 1; *out = p->exit; return 1;
}
int zw_local_foreground(ZW_LOCAL_PROCESS *p, ZW_LOCAL_FOREGROUND *out) {
    if (!p->pty || p->closed || p->reaped || !still_owned(p, &p->leader)) return 0;
    pid_t group = tcgetpgrp(p->fd);
    if (group <= 0) return 0;
    /* Foreground metadata needs only this process group. A machine-wide
     * session scan here held the terminal mutex across unrelated processes.
     * Exit/close still perform their full ownership scan before signalling. */
    int size = proc_listpids(PROC_PGRP_ONLY, (uint32_t)group, NULL, 0);
    if (size <= 0 || size > INT_MAX - (int)(32 * sizeof(pid_t))) return 0;
    size += 32 * sizeof(pid_t);
    pid_t *pids = malloc((size_t)size);
    if (!pids) return 0;
    int bytes = proc_listpids(PROC_PGRP_ONLY, (uint32_t)group, pids, size);
    int found = 0;
    if (bytes > 0 && bytes < size) for (size_t i = 0; i < (size_t)bytes / sizeof(pid_t); ++i) {
        struct proc_bsdinfo info;
        if (pids[i] <= 0 || !process_info(pids[i], &info) || info.pbi_status == SZOMB ||
            (pid_t)info.pbi_pgid != group || getsid(pids[i]) != p->sid) continue;
        Member member = member_info(&info);
        if (!still_owned(p, &member) || tcgetpgrp(p->fd) != group) continue;
        *out = (ZW_LOCAL_FOREGROUND){ .pid = pids[i], .process_group = group, .session_id = p->sid };
        memcpy(out->name, info.pbi_name, sizeof(info.pbi_name)); out->name[sizeof(out->name)-1] = 0;
        found = 1;
        break;
    }
    free(pids);
    return found;
}
int zw_local_interrupt_foreground(ZW_LOCAL_PROCESS *p) {
    ZW_LOCAL_FOREGROUND foreground;
    if (!zw_local_foreground(p, &foreground) || foreground.process_group == p->pid ||
        foreground.session_id != p->sid || tcgetpgrp(p->fd) != foreground.process_group ||
        !still_owned(p, &p->leader)) return 0;
    /* No shared transport is aborted, and the shell's own process group is
     * excluded. This is an interrupt request, not an exit acknowledgment. */
    return kill(-foreground.process_group, SIGINT) == 0 ? 1 : -1;
}
int zw_local_pid(ZW_LOCAL_PROCESS *p) { return p->pid; }
const char *zw_local_initial_cwd(ZW_LOCAL_PROCESS *p) { return p->cwd; }
int zw_local_cwd(ZW_LOCAL_PROCESS *p, char *buffer, size_t capacity) {
    if (p->closed || p->reaped || !still_owned(p, &p->leader)) return 0;
    struct proc_vnodepathinfo paths;
    if (proc_pidinfo(p->pid, PROC_PIDVNODEPATHINFO, 0, &paths, sizeof(paths)) != sizeof(paths)) return 0;
    size_t len = strnlen(paths.pvi_cdir.vip_path, sizeof(paths.pvi_cdir.vip_path));
    if (len == 0 || len >= capacity || !still_owned(p, &p->leader)) return 0;
    memcpy(buffer, paths.pvi_cdir.vip_path, len); buffer[len] = 0; return 1;
}
int zw_local_close_step(ZW_LOCAL_PROCESS *p, uint64_t now) {
    if (p->closed) return 1;
    p->close_started = 1;
    ZW_LOCAL_EXIT status;
    if (zw_local_poll_exit(p, &status) < 0) return 2;
    if (scan_members(p) < 0) return 2;
    if (!p->close_phase || (p->member_count && p->close_phase < 3 && now - p->signal_ms >= 2000)) {
        int result = signal_groups(p, !p->close_phase ? SIGHUP : p->close_phase == 1 ? SIGTERM : SIGKILL);
        if (result == -2) {
            if (!p->close_retry) { p->close_retry = 1; p->close_retry_ms = now; }
            /* The owner, birth identities and SID stay unchanged. A fresh
             * scan must verify ownership before any later signal/release.
             * Persistent uncertainty remains unknown after this small budget. */
            return now - p->close_retry_ms < 250 ? 0 : 2;
        }
        if (result < 0) return 2;
        p->close_retry = 0;
        ++p->close_phase; p->signal_ms = now;
    }
    if (p->reaped && p->member_count == 0 && p->eof && p->error_eof) {
        close_fd(&p->fd); close_fd(&p->error_fd); p->closed = 1; return 1;
    }
    return 0;
}
int zw_local_destroy(ZW_LOCAL_PROCESS *p) {
    if (!p->closed) return -1;
    free(p->members); free(p->cwd); free(p); return 0;
}
int zw_local_observation_failure(ZW_LOCAL_PROCESS *p, ZW_LOCAL_OBSERVATION_FAILURE *out) {
    if (!p->observation_failure.stage) return 0;
    *out = p->observation_failure; return 1;
}
uint64_t zw_local_monotonic_ms(void) {
    struct timespec value;
    if (clock_gettime(CLOCK_MONOTONIC, &value) < 0) return 0;
    return (uint64_t)value.tv_sec * 1000 + (uint64_t)value.tv_nsec / 1000000;
}
int zw_local_last_error(void) { return errno; }
