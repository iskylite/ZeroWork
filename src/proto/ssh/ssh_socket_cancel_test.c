/* Real sockets plus a deliberately delayed resolver. Include the production
   shim so only getaddrinfo is injected, preserving deadline/ownership logic. */
#include <netdb.h>
#include <unistd.h>
#include <stdatomic.h>
#include <string.h>
static atomic_int resolving = 0;
static int delayed_getaddrinfo(const char *host, const char *service,
    const struct addrinfo *hints, struct addrinfo **result) {
    if (!strcmp(host, "slow.invalid")) {
        atomic_store(&resolving, 1);
        usleep(300000);
        host = "127.0.0.1";
    }
    return getaddrinfo(host, service, hints, result);
}
#define getaddrinfo delayed_getaddrinfo
#include "libssh2_session_shim.c"
#undef getaddrinfo
#include <assert.h>

struct attempt { unsigned short port; atomic_int cancelled; int fd, error; };
static int cancelled(void *raw) { return atomic_load(&((struct attempt *)raw)->cancelled); }
static void *connect_worker(void *raw) {
    struct attempt *a = raw;
    a->fd = zw_ssh_socket_connect_cancellable("slow.invalid", a->port, 15000, cancelled, a);
    a->error = zw_ssh_socket_last_error();
    return NULL;
}
int main(void) {
    int server = socket(AF_INET, SOCK_STREAM, 0); assert(server >= 0);
    struct sockaddr_in address = { .sin_family = AF_INET, .sin_addr.s_addr = htonl(INADDR_LOOPBACK) };
    assert(bind(server, (struct sockaddr *)&address, sizeof(address)) == 0);
    socklen_t length = sizeof(address);
    assert(getsockname(server, (struct sockaddr *)&address, &length) == 0);
    unsigned short port = ntohs(address.sin_port);
    close(server); /* a bound non-listening socket can blackhole SYNs on macOS */
    long long start = mono_ms();
    assert(zw_ssh_socket_connect("127.0.0.1", port, 15000) < 0);
    assert(zw_ssh_socket_last_error() == ECONNREFUSED && mono_ms() - start < 1000);
    server = socket(AF_INET, SOCK_STREAM, 0); assert(server >= 0);
    assert(bind(server, (struct sockaddr *)&address, sizeof(address)) == 0);
    assert(listen(server, 5) == 0);
    int fd = zw_ssh_socket_connect("localhost", port, 1000);
    assert(fd >= 0 && (fcntl(fd, F_GETFL) & O_NONBLOCK)); close(fd);
    int accepted = accept(server, NULL, NULL); assert(accepted >= 0); close(accepted);
    start = mono_ms();
    assert(zw_ssh_socket_connect("slow.invalid", port, 80) < 0);
    assert(zw_ssh_socket_last_error() == ETIMEDOUT && mono_ms() - start < 250);
    atomic_store(&resolving, 0);
    struct attempt a = { .port = port };
    pthread_t worker; assert(pthread_create(&worker, NULL, connect_worker, &a) == 0);
    while (!atomic_load(&resolving)) usleep(1000);
    start = mono_ms(); atomic_store(&a.cancelled, 1);
    pthread_join(worker, NULL);
    assert(a.fd < 0 && a.error == ECANCELED && mono_ms() - start < 100);
    assert(zw_ssh_socket_connect_cancellable("127.0.0.1", port, 1000, cancelled, &a) < 0);
    assert(zw_ssh_socket_last_error() == ECANCELED);
    usleep(400000); /* abandoned resolver owns and frees its eventual result */
    assert(atomic_load(&zw_resolver_count) == 0);
    close(server);
    puts("PASS refused TCP fails promptly; localhost fallback/nonblocking; DNS deadline/cancel; abandoned resolver cleanup");
}
