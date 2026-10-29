/* Darwin TerminalExecutionProtocol output guard. This short-lived child reads
 * kernel process/FD metadata only; it never opens another process's files,
 * reads contents, changes a process or emits terminal/control output.
 * 0: no concurrent owner observed, 1: concurrent owner, 2..7: observation
 * unknown (setup, process identity, descriptor set/identity or time bound).
 * This is a bounded, non-atomic observation, not a sandbox or a proof against
 * deliberate FD transfer/reopening by existing processes. Exact protocol ranges
 * require the slave not to be transferred or independently reopened outside
 * this shell's workload. Writers created/reopening after inspection are outside
 * that support contract; either visible concurrent work or incomplete metadata
 * prevents an END receipt. */
#include <errno.h>
#include <libproc.h>
#include <limits.h>
#include <stdint.h>
#include <signal.h>
#include <stdlib.h>
#include <sys/proc.h>
#include <sys/proc_info.h>
#include <sys/stat.h>
#include <sys/sysctl.h>
#include <time.h>
#include <unistd.h>
static uint64_t clock_ms(void) {
    struct timespec value;
    if (clock_gettime(CLOCK_MONOTONIC, &value)) return 0;
    return (uint64_t)value.tv_sec * 1000 + value.tv_nsec / 1000000;
}
static int later(const struct proc_bsdinfo *value, const struct proc_bsdinfo *shell) {
    return value->pbi_start_tvsec > shell->pbi_start_tvsec ||
        (value->pbi_start_tvsec == shell->pbi_start_tvsec && value->pbi_start_tvusec >= shell->pbi_start_tvusec);
}
/* Some pre-existing protected processes reject libproc's extended BSD info.
 * The kernel's public birth metadata is enough to exclude an older process
 * from inherited descriptors of this newly-created slave. Never infer age
 * from PID order or suppress an unreadable newer process. */
static int predates_shell(pid_t pid, const struct proc_bsdinfo *shell) {
    int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_PID, pid };
    struct kinfo_proc value;
    size_t size = sizeof(value);
    if (sysctl(mib, 4, &value, &size, NULL, 0) || size != sizeof(value) ||
        value.kp_proc.p_starttime.tv_sec <= 0) return 0;
    return (uint64_t)value.kp_proc.p_starttime.tv_sec < shell->pbi_start_tvsec ||
        ((uint64_t)value.kp_proc.p_starttime.tv_sec == shell->pbi_start_tvsec &&
         (uint64_t)value.kp_proc.p_starttime.tv_usec < shell->pbi_start_tvusec);
}
static int gone_or_zombie(pid_t pid) {
    struct proc_bsdinfo value;
    if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &value, sizeof(value)) == sizeof(value))
        return value.pbi_status == SZOMB;
    return kill(pid, 0) < 0 && errno == ESRCH;
}
int main(int argc, char **argv) {
    if (argc != 2 || !*argv[1]) return 2;
    char *end = NULL;
    long argument = strtol(argv[1], &end, 10);
    if (*end || argument < 1 || argument > INT_MAX || getppid() != (pid_t)argument) return 2;
    pid_t shell_pid = (pid_t)argument, self = getpid();
    struct proc_bsdinfo shell;
    struct stat tty;
    if (!isatty(1) || fstat(1, &tty) || !S_ISCHR(tty.st_mode) ||
        proc_pidinfo(shell_pid, PROC_PIDTBSDINFO, 0, &shell, sizeof(shell)) != sizeof(shell)) return 2;
    pid_t shell_session = getsid(shell_pid);
    if (shell_session <= 0) return 2;
    uint64_t started = clock_ms();
    int size = proc_listpids(PROC_ALL_PIDS, 0, NULL, 0);
    if (size <= 0 || size > 65536 * (int)sizeof(pid_t)) return 2;
    size += 1024 * (int)sizeof(pid_t);
    pid_t *pids = malloc((size_t)size);
    if (!pids) return 2;
    int bytes = proc_listpids(PROC_ALL_PIDS, 0, pids, size), result = 0;
    if (bytes <= 0 || bytes >= size) { free(pids); return 2; }
    for (size_t i = 0; i < (size_t)bytes / sizeof(pid_t); ++i) {
        pid_t pid = pids[i];
        if (pid <= 0 || pid == self || pid == shell_pid) continue;
        if (!started || clock_ms() - started > 250) { result = 7; break; }
        struct proc_bsdinfo process;
        if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &process, sizeof(process)) != sizeof(process)) {
            /* A process gone before observation cannot retain the slave. */
            if (gone_or_zombie(pid)) continue;
            if (predates_shell(pid, &shell)) continue;
            if (gone_or_zombie(pid)) continue;
            result = 4; break;
        }
        if (process.pbi_status == SZOMB || !later(&process, &shell)) continue;
        /* Children still in the shell session are background work even when
         * they temporarily close stdout and could reopen their controlling tty. */
        if (getsid(pid) == shell_session) { result = 1; break; }
        int required = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, NULL, 0);
        if (required < 0 || required > 16384 * (int)sizeof(struct proc_fdinfo)) { result = 5; break; }
        if (required == 0) {
            if (gone_or_zombie(pid)) continue;
            result = 5; break;
        }
        required += 32 * (int)sizeof(struct proc_fdinfo);
        struct proc_fdinfo *fds = malloc((size_t)required);
        if (!fds) { result = 2; break; }
        int count = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, fds, required);
        if (count <= 0 || count >= required) {
            free(fds);
            if (gone_or_zombie(pid)) continue;
            result = 5; break;
        }
        for (size_t n = 0; n < (size_t)count / sizeof(*fds); ++n) {
            if (fds[n].proc_fdtype != PROX_FDTYPE_VNODE) continue;
            struct vnode_fdinfo vnode;
            if (proc_pidfdinfo(pid, (int)fds[n].proc_fd, PROC_PIDFDVNODEINFO, &vnode, sizeof(vnode)) != sizeof(vnode)) {
                if (errno == EBADF || errno == ENOENT || errno == ESRCH) continue;
                result = 6; break;
            }
            if ((vnode.pvi.vi_stat.vst_mode & S_IFMT) == S_IFCHR && vnode.pvi.vi_stat.vst_rdev == (uint32_t)tty.st_rdev) { result = 1; break; }
        }
        free(fds);
        if (result) break;
    }
    free(pids);
    return result;
}
