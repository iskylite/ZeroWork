/* Optional macOS CPU probe for ssh_output_performance_native.ts.
 * Build: xcrun clang -O2 e2e/native_thread_cpu.c -o /private/tmp/thread-cpu
 * Read-only libproc counters, no task port or stack inspection required.
 * Compare matching thread IDs across samples; exited/new threads are excluded
 * from per-thread deltas, while the ps process total includes all threads. */
#include <errno.h>
#include <inttypes.h>
#include <limits.h>
#include <libproc.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/proc_info.h>

int main(int argc, char **argv) {
    if (argc != 2) return 2;
    char *end = NULL;
    errno = 0;
    long value = strtol(argv[1], &end, 10);
    if (errno || !end || *end || value <= 0 || value > INT_MAX) return 2;
    uint64_t ids[8192];
    int bytes = proc_pidinfo((int)value, PROC_PIDLISTTHREADS, 0, ids, sizeof(ids));
    if (bytes <= 0 || bytes >= (int)sizeof(ids) || bytes % sizeof(ids[0])) return 3;
    printf("{\"threads\":[");
    int first = 1;
    for (size_t i = 0; i < (size_t)bytes / sizeof(ids[0]); i++) {
        struct proc_threadinfo info;
        if (proc_pidinfo((int)value, PROC_PIDTHREADINFO, ids[i], &info, sizeof(info)) != sizeof(info)) continue;
        printf("%s{\"id\":%" PRIu64 ",\"cpu_ns\":%" PRIu64 "}", first ? "" : ",", ids[i], info.pth_user_time + info.pth_system_time);
        first = 0;
    }
    puts("]}");
    return 0;
}
