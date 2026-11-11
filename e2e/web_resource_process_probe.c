/* Read only the isolated ZeroWork fixture's open sockets and exact worker IDs. */
#include <inttypes.h>
#include <libproc.h>
#include <limits.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/proc_info.h>
#include <sys/socket.h>

int main(int argc, char **argv) {
    if (argc < 2) return 2;
    char *end;
    long pid = strtol(argv[1], &end, 10);
    if (*end || pid <= 0 || pid > INT_MAX || kill((int)pid, 0) != 0) return 2;
    struct proc_fdinfo descriptors[4096];
    int bytes = proc_pidinfo((int)pid, PROC_PIDLISTFDS, 0, descriptors, sizeof(descriptors));
    if (bytes <= 0 || bytes >= (int)sizeof(descriptors) || bytes % sizeof(descriptors[0])) return 3;
    size_t sockets = 0, unix_sockets = 0, inet_sockets = 0, other_sockets = 0;
    for (size_t i = 0; i < (size_t)bytes / sizeof(descriptors[0]); ++i) {
        if (descriptors[i].proc_fdtype != PROX_FDTYPE_SOCKET) continue;
        ++sockets;
        struct socket_fdinfo info;
        int size = proc_pidfdinfo((int)pid, descriptors[i].proc_fd, PROC_PIDFDSOCKETINFO, &info, sizeof(info));
        if (size != sizeof(info)) {
            ++other_sockets;
        } else if (info.psi.soi_family == AF_UNIX) {
            ++unix_sockets;
        } else if (info.psi.soi_family == AF_INET || info.psi.soi_family == AF_INET6) {
            ++inet_sockets;
        } else {
            ++other_sockets;
        }
    }
    printf("{\"sockets\":%zu,\"families\":{\"unix\":%zu,\"inet\":%zu,\"other\":%zu},\"liveWorkers\":[",
        sockets, unix_sockets, inet_sockets, other_sockets);
    int first = 1;
    for (int i = 2; i < argc; ++i) {
        uint64_t id = strtoull(argv[i], &end, 10);
        if (*end || id == 0) return 2;
        struct proc_threadinfo info;
        int size = proc_pidinfo((int)pid, PROC_PIDTHREADID64INFO, id, &info, sizeof(info));
        if (size == sizeof(info)) {
            printf("%s%" PRIu64, first ? "" : ",", id);
            first = 0;
        }
    }
    puts("]}");
    return 0;
}
