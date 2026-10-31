/* Real loopback sockets distinguish reset/EOF before authentication. This
   exercises the production callback forwarding, not a replacement driver. */
#include "libssh2_session_shim.c"
#include <assert.h>

struct peer { int listener; int reset; int partial; };
static void *peer_worker(void *raw) {
    struct peer *peer = raw;
    int fd = accept(peer->listener, NULL, NULL);
    assert(fd >= 0);
    char banner[256];
    ssize_t count = recv(fd, banner, sizeof(banner), 0);
    assert(count > 0 && !memcmp(banner, "SSH-2.0-", 8));
    if (peer->partial) {
        assert(send(fd, "SSH-2.0-fixture", 15, 0) == 15);
        (void)poll(NULL, 0, 20);
    }
    if (peer->reset) {
        struct linger linger = { 1, 0 };
        assert(setsockopt(fd, SOL_SOCKET, SO_LINGER, &linger, sizeof(linger)) == 0);
    }
    close(fd);
    return NULL;
}
static void check_failure(int reset, int partial) {
    struct peer peer = { .listener = socket(AF_INET, SOCK_STREAM, 0), .reset = reset, .partial = partial };
    assert(peer.listener >= 0);
    struct sockaddr_in address = { .sin_family = AF_INET, .sin_addr.s_addr = htonl(INADDR_LOOPBACK) };
    assert(bind(peer.listener, (struct sockaddr *)&address, sizeof(address)) == 0);
    socklen_t length = sizeof(address);
    assert(getsockname(peer.listener, (struct sockaddr *)&address, &length) == 0);
    assert(listen(peer.listener, 1) == 0);
    pthread_t thread;
    assert(pthread_create(&thread, NULL, peer_worker, &peer) == 0);
    int fd = zw_ssh_socket_connect("127.0.0.1", ntohs(address.sin_port), 1000);
    assert(fd >= 0);
    LIBSSH2_SESSION *session = zw_libssh2_session_create();
    assert(session);
    libssh2_session_set_blocking(session, 0);
    void *marker = &peer;
    *libssh2_session_abstract(session) = marker;
    libssh2_cb_generic *recv_cb = libssh2_session_callback_set2(session, LIBSSH2_CALLBACK_RECV, NULL);
    libssh2_cb_generic *send_cb = libssh2_session_callback_set2(session, LIBSSH2_CALLBACK_SEND, NULL);
    libssh2_session_callback_set2(session, LIBSSH2_CALLBACK_RECV, recv_cb);
    libssh2_session_callback_set2(session, LIBSSH2_CALLBACK_SEND, send_cb);
    ZW_SSH_DRIVE drive = { .socket_fd = fd, .timeout_ms = 1000 };
    ZW_SSH_HANDSHAKE_DIAGNOSTIC diagnostic;
    int rc = zw_libssh2_session_handshake_observed(session, &drive, &diagnostic);
    assert(rc == (reset ? LIBSSH2_ERROR_SOCKET_RECV : LIBSSH2_ERROR_SOCKET_DISCONNECT));
    assert(diagnostic.recv_code == (reset ? -ECONNRESET : 0));
    assert(diagnostic.recv_errno == (reset ? ECONNRESET : 0));
    assert(diagnostic.received_bytes == (partial ? 15 : 0));
    assert(diagnostic.sent_bytes == diagnostic.identification_bytes);
    assert(diagnostic.identification_bytes > 8 && diagnostic.identification_complete);
    assert(diagnostic.identification_hash != 14695981039346656037ULL);
    assert(diagnostic.socket_flags & O_NONBLOCK);
    assert(!strcmp(diagnostic.peer_address, "127.0.0.1"));
    assert(diagnostic.peer_port == ntohs(address.sin_port) && diagnostic.local_port != 0);
    assert(*libssh2_session_abstract(session) == marker);
    assert(libssh2_session_callback_set2(session, LIBSSH2_CALLBACK_RECV, recv_cb) == recv_cb);
    assert(libssh2_session_callback_set2(session, LIBSSH2_CALLBACK_SEND, send_cb) == send_cb);
    libssh2_session_free(session);
    close(fd);
    pthread_join(thread, NULL);
    close(peer.listener);
    printf("PASS handshake %s partial=%d rc=%d recv_code=%lld errno=%d received=%llu identification=%llu/%llx callbacks_restored=true\n",
        reset ? "reset" : "eof", partial, rc, diagnostic.recv_code, diagnostic.recv_errno,
        diagnostic.received_bytes, diagnostic.identification_bytes, diagnostic.identification_hash);
}
int main(void) {
    assert(zw_libssh2_library_init() == 0);
    check_failure(1, 0);
    check_failure(1, 1);
    check_failure(0, 0);
    zw_libssh2_library_exit();
}
