/* Deterministic exit/ownership races. All process observations and signals are
 * mocked; this executable cannot start, signal, or reap a real child. */
#include <errno.h>
#include <libproc.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <sys/proc.h>
#include <sys/proc_info.h>
#include <sys/wait.h>
#include <unistd.h>

static int observe_process(int, int, uint64_t, void *, int);
static int list_processes(uint32_t, uint32_t, void *, int);
static pid_t observe_session(pid_t);
static int signal_process(pid_t, int);
static int observe_exit(idtype_t, id_t, siginfo_t *, int);
static pid_t reap_process(pid_t, int *, int);
#define proc_pidinfo observe_process
#define proc_listpids list_processes
#define getsid observe_session
#define kill signal_process
#define waitid observe_exit
#define waitpid reap_process
#include "darwin_process.c"

enum { leader_pid = 400001, child_pid = 400002 };
static int child_present, exit_visible, metadata_error, sent_signals, reaps;
static int wrong_birth, group_race, child_observations;

static int observe_process(int pid, int flavor, uint64_t arg, void *buffer, int size) {
    (void)flavor; (void)arg;
    if (pid != child_pid || !child_present) { errno = ESRCH; return 0; }
    if (metadata_error) { errno = metadata_error; return 0; }
    if (group_race && ++child_observations > 3) { errno = ESRCH; return 0; }
    struct proc_bsdinfo info = {0};
    info.pbi_pid = child_pid; info.pbi_pgid = leader_pid;
    info.pbi_start_tvsec = wrong_birth ? 30 : 20;
    info.pbi_status = SRUN;
    memcpy(buffer, &info, (size_t)size);
    return size;
}
static int list_processes(uint32_t type, uint32_t info, void *buffer, int size) {
    (void)type; (void)info; (void)size;
    if (buffer) *(pid_t *)buffer = child_present ? child_pid : 0;
    return sizeof(pid_t);
}
static pid_t observe_session(pid_t pid) {
    if (pid == child_pid && child_present) return leader_pid;
    errno = ESRCH; return -1;
}
static int signal_process(pid_t pid, int number) {
    if (number == 0) {
        if (child_present) { if (pid < 0) { errno = EPERM; return -1; } return 0; }
        errno = ESRCH; return -1;
    }
    if (pid != -leader_pid) { fprintf(stderr, "unowned signal\n"); _exit(90); }
    sent_signals++;
    return 0;
}
static int observe_exit(idtype_t type, id_t pid, siginfo_t *info, int flags) {
    if (type != P_PID || pid != leader_pid || !(flags & WNOWAIT)) _exit(91);
    memset(info, 0, sizeof(*info));
    if (exit_visible) info->si_pid = leader_pid;
    return 0;
}
static pid_t reap_process(pid_t pid, int *status, int flags) {
    if (pid != leader_pid || !exit_visible || flags != WNOHANG) _exit(92);
    *status = 0; reaps++; return leader_pid;
}
static ZW_LOCAL_PROCESS process(void) {
    child_present = 1; exit_visible = metadata_error = sent_signals = reaps = 0;
    wrong_birth = group_race = child_observations = 0;
    return (ZW_LOCAL_PROCESS){ .pid = leader_pid, .sid = leader_pid,
        .leader = {leader_pid, leader_pid, 10, 0}, .fd = -1, .error_fd = -1,
        .eof = 1, .error_eof = 1 };
}
#define CHECK(value) do { if (!(value)) { fprintf(stderr, "line %d: %s\n", __LINE__, #value); return 1; } } while (0)
int main(void) {
    ZW_LOCAL_PROCESS p = process();
    /* Leader metadata is already gone but waitid has not exposed its exit.
     * The remaining child has never yet been captured by a trusted scan. */
    CHECK(zw_local_close_step(&p, 100) == 0);
    CHECK(p.observation_failure.stage == 5 && !p.closed && !p.reaped);
    CHECK(sent_signals == 0 && reaps == 0 && p.members == NULL);
    exit_visible = 1;
    CHECK(zw_local_close_step(&p, 101) == 0);
    CHECK(p.reaped && reaps == 1 && sent_signals == 1 && !p.closed);
    CHECK(p.member_count == 1 && p.members[0].seconds == 20 && !p.close_retry);
    child_present = 0;
    CHECK(zw_local_close_step(&p, 102) == 1 && p.closed);
    free(p.members);

    p = process(); p.close_phase = 1; p.signal_ms = 99;
    p.members = malloc(sizeof(Member)); CHECK(p.members != NULL);
    p.members[0] = p.leader; p.member_count = 1;
    /* The observed production failure occurred after HUP: preserve the last
     * known birth record until the unreaped leader proves the new scan. */
    CHECK(zw_local_close_step(&p, 100) == 0);
    CHECK(p.member_count == 1 && p.members[0].seconds == 10 && sent_signals == 0);
    exit_visible = 1;
    CHECK(zw_local_close_step(&p, 101) == 0);
    CHECK(!p.close_retry && p.members[0].seconds == 20 && sent_signals == 0);
    child_present = 0;
    CHECK(zw_local_close_step(&p, 102) == 1);
    free(p.members);

    p = process();
    /* An unproved/reused SID never authorizes signalling or release. */
    CHECK(zw_local_close_step(&p, 100) == 0);
    CHECK(zw_local_close_step(&p, 349) == 0);
    CHECK(zw_local_close_step(&p, 350) == 2);
    CHECK(!p.closed && sent_signals == 0 && reaps == 0);
    free(p.members);

    p = process();
    p.reaped = 1;
    p.members = malloc(sizeof(Member)); CHECK(p.members != NULL);
    p.members[0] = (Member){child_pid, leader_pid, 19, 0}; p.member_count = 1;
    wrong_birth = 1;
    CHECK(zw_local_close_step(&p, 100) == 0);
    CHECK(zw_local_close_step(&p, 350) == 2);
    CHECK(!p.closed && sent_signals == 0);
    free(p.members);

    p = process(); metadata_error = ESRCH;
    CHECK(zw_local_close_step(&p, 100) == 0);
    CHECK(p.observation_failure.stage == 4 && !p.exit_observed && sent_signals == 0);
    exit_visible = 1;
    ZW_LOCAL_EXIT status;
    CHECK(zw_local_poll_exit(&p, &status) == 0 && !p.reaped);
    CHECK(zw_local_close_step(&p, 101) == 0 && reaps == 0 && sent_signals == 0);
    metadata_error = 0;
    CHECK(zw_local_close_step(&p, 102) == 0 && p.reaped && sent_signals == 1);
    child_present = 0;
    CHECK(zw_local_close_step(&p, 103) == 1);
    free(p.members);

    p = process(); metadata_error = ESRCH; exit_visible = 1;
    CHECK(zw_local_close_step(&p, 100) == 0);
    CHECK(zw_local_close_step(&p, 350) == 2);
    CHECK(!p.closed && sent_signals == 0 && reaps == 0);
    free(p.members);

    p = process(); metadata_error = EACCES;
    CHECK(zw_local_close_step(&p, 100) == 2);
    CHECK(p.observation_failure.stage == 4 && sent_signals == 0 && !p.closed);
    free(p.members);

    p = process(); exit_visible = 1; group_race = 1;
    CHECK(zw_local_close_step(&p, 100) == 0);
    CHECK(p.observation_failure.stage == 8 && sent_signals == 0 && !p.closed);
    child_present = 0;
    CHECK(zw_local_close_step(&p, 101) == 1);
    free(p.members);
    puts("PASS 8 native close observation regressions");
    return 0;
}
