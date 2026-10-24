/* Real loopback socket regression; no SSH server or credentials required.
   Link this file with libssh2_session_shim.c, libssh2 and mbedcrypto. */
#include "libssh2_session_shim.h"
#include <arpa/inet.h>
#include <assert.h>
#include <errno.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

static long long now_ms(void) {
    struct timespec time;
    assert(clock_gettime(CLOCK_MONOTONIC, &time) == 0);
    return (long long)time.tv_sec * 1000 + time.tv_nsec / 1000000;
}

struct attempt {
    unsigned short port;
    atomic_bool cancelled, entered, done;
    int fd, error;
    long long elapsed;
};

static int cancelled(void *raw) {
    struct attempt *attempt = raw;
    atomic_store_explicit(&attempt->entered, 1, memory_order_release);
    return atomic_load_explicit(&attempt->cancelled, memory_order_acquire);
}

static void *connect_worker(void *raw) {
    struct attempt *attempt = raw;
    long long start = now_ms();
    attempt->fd = zw_ssh_socket_connect_cancellable("127.0.0.1", attempt->port,
        15000, cancelled, attempt);
    attempt->error = zw_ssh_socket_last_error();
    attempt->elapsed = now_ms() - start;
    atomic_store_explicit(&attempt->done, 1, memory_order_release);
    return NULL;
}

int main(void) {
    /* A bound, non-listening socket reserves an unused port that refuses TCP. */
    int server = socket(AF_INET, SOCK_STREAM, 0);
    assert(server >= 0);
    struct sockaddr_in address = { .sin_family = AF_INET,
        .sin_addr.s_addr = htonl(INADDR_LOOPBACK) };
    assert(bind(server, (struct sockaddr *)&address, sizeof(address)) == 0);
    socklen_t length = sizeof(address);
    assert(getsockname(server, (struct sockaddr *)&address, &length) == 0);
    unsigned short port = ntohs(address.sin_port);
    struct attempt attempt = { .port = port, .fd = -1 };
    pthread_t worker;
    assert(pthread_create(&worker, NULL, connect_worker, &attempt) == 0);
    while (!atomic_load_explicit(&attempt.entered, memory_order_acquire)) usleep(1000);
    usleep(100000);
    assert(!atomic_load_explicit(&attempt.done, memory_order_acquire));
    long long cancel_start = now_ms();
    atomic_store_explicit(&attempt.cancelled, 1, memory_order_release);
    assert(pthread_join(worker, NULL) == 0);
    long long cancel_elapsed = now_ms() - cancel_start;
    assert(attempt.fd < 0 && attempt.error == ECANCELED);
    assert(cancel_elapsed < 1000 && attempt.elapsed < 2000);
    printf("cancel during refused connection retry: %lld ms after cancel\n", cancel_elapsed);

    assert(zw_ssh_socket_connect_cancellable("127.0.0.1", port, 15000,
        cancelled, &attempt) < 0);
    assert(zw_ssh_socket_last_error() == ECANCELED);

    long long start = now_ms();
    assert(zw_ssh_socket_connect("127.0.0.1", port, 200) < 0);
    long long elapsed = now_ms() - start;
    assert(elapsed >= 150 && elapsed < 2000);
    assert(zw_ssh_socket_last_error() == ECONNREFUSED ||
        zw_ssh_socket_last_error() == ETIMEDOUT);
    printf("uncancelled original ABI retains retry deadline: %lld ms\n", elapsed);

    assert(listen(server, 1) == 0);
    int fd = zw_ssh_socket_connect("127.0.0.1", port, 1000);
    assert(fd >= 0);
    zw_ssh_socket_close(fd);
    atomic_store_explicit(&attempt.cancelled, 0, memory_order_release);
    fd = zw_ssh_socket_connect_cancellable("127.0.0.1", port, 1000,
        cancelled, &attempt);
    assert(fd >= 0);
    zw_ssh_socket_close(fd);
    close(server);
    puts("original and cancellable ABI both connect successfully");
    return 0;
}
