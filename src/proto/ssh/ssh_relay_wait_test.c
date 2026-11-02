/* Exercise the production relay and aggregate wait. Substitute SSH channel
   endpoints, poll observation and a buffer-tuning refusal; byte delivery uses
   real nonblocking socketpairs, including partial writes and an EOF tail. */
#include "libssh2.h"
#include <sys/socket.h>
#include <poll.h>
#include <assert.h>

static ssize_t fixture_read(LIBSSH2_CHANNEL *, int, char *, size_t);
static ssize_t fixture_write(LIBSSH2_CHANNEL *, int, const char *, size_t);
static int fixture_eof(LIBSSH2_CHANNEL *);
static int fixture_send_eof(LIBSSH2_CHANNEL *);
static int fixture_block_directions(LIBSSH2_SESSION *);
static int fixture_poll(struct pollfd *, nfds_t, int);
static int fixture_setsockopt(int, int, int, const void *, socklen_t);
#define libssh2_channel_read_ex fixture_read
#define libssh2_channel_write_ex fixture_write
#define libssh2_channel_eof fixture_eof
#define libssh2_channel_send_eof fixture_send_eof
#define libssh2_session_block_directions fixture_block_directions
#define poll fixture_poll
#define setsockopt fixture_setsockopt
#include "libssh2_session_shim.c"
#undef libssh2_channel_read_ex
#undef libssh2_channel_write_ex
#undef libssh2_channel_eof
#undef libssh2_channel_send_eof
#undef libssh2_session_block_directions
#undef poll
#undef setsockopt

struct channel_fixture {
    const unsigned char *incoming;
    size_t incoming_len, incoming_offset;
    unsigned char outgoing[64];
    size_t outgoing_len;
    unsigned int reads, sent_eof;
};
static unsigned int poll_calls;
static nfds_t polled_count;
static struct pollfd polled[ZW_SSH_RELAY_WAIT_MAX + 1];
static int polled_timeout, poll_result, use_real_poll, block_directions;
static int refuse_buffer_tuning;

static int fixture_setsockopt(int fd, int level, int option, const void *value, socklen_t length) {
    if (refuse_buffer_tuning && level == SOL_SOCKET && (option == SO_SNDBUF || option == SO_RCVBUF)) {
        errno = ENOBUFS;
        return -1;
    }
    return setsockopt(fd, level, option, value, length);
}

static void socket_buffer_capacity(void) {
    int target, relay;
    assert(zw_ssh_socketpair(&target, &relay) == 0);
    int fds[] = { target, relay };
    unsigned char bytes[32768], received[32768];
    for (size_t i = 0; i < sizeof(bytes); ++i) bytes[i] = (unsigned char)(i % 251);
    for (size_t i = 0; i < 2; ++i) {
        int send_bytes = 0, receive_bytes = 0;
        socklen_t length = sizeof(int);
        assert(getsockopt(fds[i], SOL_SOCKET, SO_SNDBUF, &send_bytes, &length) == 0);
        length = sizeof(int);
        assert(getsockopt(fds[i], SOL_SOCKET, SO_RCVBUF, &receive_bytes, &length) == 0);
        assert(send_bytes >= (int)sizeof(bytes) && receive_bytes >= (int)sizeof(bytes));
        assert(fcntl(fds[i], F_GETFL) & O_NONBLOCK);
        /* A full relay batch fits in either direction without a consumer
           draining concurrently or a blocking write masking partial sends. */
        assert(send(fds[i], bytes, sizeof(bytes), 0) == (ssize_t)sizeof(bytes));
        size_t offset = 0;
        while (offset < sizeof(received)) {
            ssize_t n = recv(fds[1 - i], received + offset, sizeof(received) - offset, 0);
            assert(n > 0);
            offset += (size_t)n;
        }
        assert(!memcmp(bytes, received, sizeof(bytes)));
        printf("socketpair endpoint %zu: send=%d receive=%d, full 32768-byte batch verified\n", i, send_bytes, receive_bytes);
    }
    close(target);
    close(relay);

    refuse_buffer_tuning = 1;
    assert(zw_ssh_socketpair(&target, &relay) == 0);
    refuse_buffer_tuning = 0;
    assert(fcntl(target, F_GETFL) & O_NONBLOCK);
    assert(fcntl(relay, F_GETFL) & O_NONBLOCK);
    int no_sigpipe = 0;
    socklen_t length = sizeof(no_sigpipe);
    assert(getsockopt(target, SOL_SOCKET, SO_NOSIGPIPE, &no_sigpipe, &length) == 0 && no_sigpipe);
    assert(send(target, "x", 1, 0) == 1);
    assert(recv(relay, received, 1, 0) == 1 && received[0] == 'x');
    close(target);
    close(relay);
    puts("PASS socketpair buffers: per-socket full relay batches in both directions; refused tuning keeps a usable nonblocking pair");
}

static ssize_t fixture_read(LIBSSH2_CHANNEL *raw, int stream, char *buffer, size_t length) {
    struct channel_fixture *channel = (void *)raw;
    assert(stream == 0);
    channel->reads++;
    size_t available = channel->incoming_len - channel->incoming_offset;
    if (!available) return 0;
    if (length > available) length = available;
    memcpy(buffer, channel->incoming + channel->incoming_offset, length);
    channel->incoming_offset += length;
    return (ssize_t)length;
}
static ssize_t fixture_write(LIBSSH2_CHANNEL *raw, int stream, const char *bytes, size_t length) {
    struct channel_fixture *channel = (void *)raw;
    assert(stream == 0);
    if (length > 3) length = 3; /* Preserve offsets across short SSH writes. */
    assert(channel->outgoing_len + length <= sizeof(channel->outgoing));
    memcpy(channel->outgoing + channel->outgoing_len, bytes, length);
    channel->outgoing_len += length;
    return (ssize_t)length;
}
static int fixture_eof(LIBSSH2_CHANNEL *raw) {
    struct channel_fixture *channel = (void *)raw;
    return channel->incoming_offset == channel->incoming_len;
}
static int fixture_send_eof(LIBSSH2_CHANNEL *raw) {
    struct channel_fixture *channel = (void *)raw;
    channel->sent_eof++;
    return 0;
}
static int fixture_block_directions(LIBSSH2_SESSION *session) {
    assert(session);
    return block_directions;
}
static int fixture_poll(struct pollfd *fds, nfds_t count, int timeout) {
    assert(count <= ZW_SSH_RELAY_WAIT_MAX + 1);
    poll_calls++;
    polled_count = count;
    polled_timeout = timeout;
    for (nfds_t i = 0; i < count; ++i) polled[i] = fds[i];
    poll_result = use_real_poll ? poll(fds, count, use_real_poll == 2 ? timeout : 0) : 0;
    return poll_result;
}
static void reset_poll(void) {
    poll_calls = 0;
    polled_count = 0;
    polled_timeout = -1;
    poll_result = 0;
    use_real_poll = 0;
    block_directions = 0;
}

static void wait_arguments(void) {
    ZW_SSH_RELAY first = { .fd = 11 }, second = { .fd = 12 };
    ZW_SSH_RELAY *relays[] = { &first, &second };
    int session_marker;
    LIBSSH2_SESSION *session = (void *)&session_marker;

    reset_poll();
    second.progressed = 1;
    assert(zw_ssh_relay_wait_many(relays, 2, 13, session, 2) == 1);
    assert(poll_calls == 0); /* A productive sibling must skip the wait. */

    reset_poll();
    second.progressed = 0;
    second.downstream_len = 1;
    block_directions = LIBSSH2_SESSION_BLOCK_OUTBOUND;
    assert(zw_ssh_relay_wait_many(relays, 2, 13, session, 2) == 0);
    assert(poll_calls == 1 && polled_count == 3 && polled_timeout == 2);
    assert(polled[0].fd == 11 && polled[0].events == POLLIN);
    assert(polled[1].fd == 12 && polled[1].events == (POLLIN | POLLOUT));
    assert(polled[2].fd == 13 && polled[2].events == (POLLIN | POLLOUT));

    reset_poll();
    first.socket_eof = 1;
    first.downstream_len = 1;
    second.upstream_len = 1;
    second.downstream_len = 0;
    assert(zw_ssh_relay_wait_many(relays, 2, -1, NULL, 2) == 0);
    assert(poll_calls == 1 && polled_count == 1);
    assert(polled[0].fd == 11 && polled[0].events == POLLOUT);

    reset_poll();
    assert(zw_ssh_relay_wait_many(NULL, 0, 13, session, 2) == 0);
    assert(poll_calls == 1 && polled_count == 1);
    assert(polled[0].fd == 13 && polled[0].events == POLLIN);
    reset_poll();
    assert(zw_ssh_relay_wait_many(NULL, 0, -1, NULL, 2) == 0);
    assert(poll_calls == 1 && polled_count == 0 && polled_timeout == 2);

    reset_poll();
    ZW_SSH_RELAY many[ZW_SSH_RELAY_WAIT_MAX] = {0};
    ZW_SSH_RELAY *bounded[ZW_SSH_RELAY_WAIT_MAX + 1];
    for (size_t i = 0; i < ZW_SSH_RELAY_WAIT_MAX; ++i) {
        many[i].fd = 100 + (int)i;
        bounded[i] = &many[i];
    }
    bounded[ZW_SSH_RELAY_WAIT_MAX] = NULL; /* Must not dereference beyond cap. */
    assert(zw_ssh_relay_wait_many(bounded, ZW_SSH_RELAY_WAIT_MAX + 1, 13, session, 2) == 0);
    assert(poll_calls == 1 && polled_count == ZW_SSH_RELAY_WAIT_MAX + 1);

    reset_poll();
    zw_ssh_relay_wait(&first, -1, NULL, 7);
    assert(poll_calls == 1 && polled_count == 1 && polled_timeout == 7);
    assert(polled[0].fd == 11 && polled[0].events == POLLOUT);
    puts("PASS relay aggregate wait: sibling progress, one poll, flow directions, pending open, no-fd timeout, bounded count, single-wait compatibility");
}

static void pending_transport_readiness(void) {
    int target, relay;
    assert(zw_ssh_socketpair(&target, &relay) == 0);
    assert(send(target, "x", 1, 0) == 1);
    reset_poll();
    use_real_poll = 1;
    assert(zw_ssh_relay_wait_many(NULL, 0, relay, NULL, 2) == 0);
    assert(poll_calls == 1 && polled_count == 1 && poll_result == 1);
    assert(polled[0].fd == relay && polled[0].events == POLLIN);
    close(target);
    close(relay);
    puts("PASS relay pending channel open: real transport readability without active relays");
}

static void backpressured_transport_readiness(void) {
    int target, relay, network[2];
    assert(zw_ssh_socketpair(&target, &relay) == 0);
    assert(socketpair(AF_UNIX, SOCK_STREAM, 0, network) == 0);
    unsigned char bytes[32768];
    memset(bytes, 'x', sizeof(bytes));
    while (send(relay, bytes, sizeof(bytes), 0) > 0) {}
    assert(errno == EAGAIN || errno == EWOULDBLOCK);
    assert(send(network[0], "s", 1, 0) == 1); /* SSH stays readable. */

    ZW_SSH_RELAY state = { .fd = relay, .socket_eof = 1, .sent_eof = 1, .downstream_len = 1 };
    ZW_SSH_RELAY *relays[] = { &state };
    assert(zw_ssh_relay_step(&state) == 0 && !state.progressed);
    reset_poll();
    use_real_poll = 2;
    assert(zw_ssh_relay_wait_many(relays, 1, network[1], NULL, 20) == 0);
    /* No meaningless SSH POLLIN wakeup while channel_read cannot run. */
    assert(poll_calls == 1 && polled_count == 1 && poll_result == 0 && polled_timeout == 2);
    assert(polled[0].fd == relay && polled[0].events == POLLOUT);

    reset_poll();
    int marker;
    block_directions = LIBSSH2_SESSION_BLOCK_OUTBOUND;
    zw_ssh_relay_wait(&state, network[1], (void *)&marker, 20);
    assert(polled_timeout == 2 && polled_count == 2);
    assert(polled[1].fd == network[1] && polled[1].events == POLLOUT);

    /* Consumer progress wakes the relay promptly; the SSH byte is untouched. */
    while (recv(target, bytes, sizeof(bytes), 0) > 0) {}
    assert(errno == EAGAIN || errno == EWOULDBLOCK);
    reset_poll();
    use_real_poll = 2;
    assert(zw_ssh_relay_wait_many(relays, 1, network[1], NULL, 20) == 0);
    assert(poll_result == 1 && polled_count == 1 && polled[0].events == POLLOUT);
    assert(recv(network[1], bytes, 1, 0) == 1 && bytes[0] == 's');
    close(target);
    close(relay);
    close(network[0]);
    close(network[1]);
    puts("PASS relay backpressure: readable SSH input cannot spin a full consumer; writable wakeup and bounded session retry preserved");
}

static void partial_writes_and_eof(void) {
    enum { count = 2, max_bytes = 3 * 32768 + 31 };
    unsigned char incoming[count][max_bytes], received[count][max_bytes];
    struct channel_fixture channels[count] = {0};
    ZW_SSH_RELAY *relays[count];
    int targets[count], finished[count] = {0}, local_eof[count] = {0};
    size_t received_len[count] = {0};
    const char upstream[] = "preserve-ssh-tail";
    for (int i = 0; i < count; ++i) {
        channels[i].incoming = incoming[i];
        channels[i].incoming_len = max_bytes - (size_t)i * 32768;
        for (size_t n = 0; n < channels[i].incoming_len; ++n)
            incoming[i][n] = (unsigned char)((n + (size_t)i * 73) % 251);
        int fd;
        assert(zw_ssh_socketpair(&targets[i], &fd) == 0);
        int small = 4096;
        assert(setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &small, sizeof(small)) == 0);
        socklen_t size = sizeof(small);
        assert(getsockopt(fd, SOL_SOCKET, SO_SNDBUF, &small, &size) == 0);
        assert(small < 32768); /* Force a partial write of a full SSH chunk. */
        relays[i] = zw_ssh_relay_create(fd, (void *)&channels[i]);
        assert(relays[i]);
        assert(send(targets[i], upstream, sizeof(upstream) - 1, 0) == sizeof(upstream) - 1);
        assert(shutdown(targets[i], SHUT_WR) == 0);
        assert(zw_ssh_relay_step(relays[i]) == 0);
        assert(relays[i]->downstream_len > 0 && relays[i]->upstream_len > 0);
    }
    /* Both streams receive one step before a single aggregate decision. */
    assert(channels[0].reads == 1 && channels[1].reads == 1);
    reset_poll();
    assert(zw_ssh_relay_wait_many(relays, count, -1, NULL, 2) == 1);
    assert(poll_calls == 0);

    unsigned int rounds;
    for (rounds = 0; rounds < 5000; ++rounds) {
        ZW_SSH_RELAY *active[count];
        size_t active_count = 0;
        for (int i = 0; i < count; ++i) {
            if (!finished[i]) {
                int result = zw_ssh_relay_step(relays[i]);
                assert(result >= 0);
                finished[i] = result == 1;
                if (!finished[i]) active[active_count++] = relays[i];
            }
            unsigned char bytes[257];
            ssize_t n = recv(targets[i], bytes, sizeof(bytes), 0);
            if (n > 0) {
                assert(received_len[i] + (size_t)n <= sizeof(received[i]));
                memcpy(received[i] + received_len[i], bytes, (size_t)n);
                received_len[i] += (size_t)n;
            } else if (n == 0) local_eof[i] = 1;
            else assert(errno == EAGAIN || errno == EWOULDBLOCK);
        }
        reset_poll();
        (void)zw_ssh_relay_wait_many(active, active_count, -1, NULL, 2);
        assert(poll_calls <= 1);
        if (finished[0] && finished[1] && local_eof[0] && local_eof[1]) break;
    }
    assert(rounds < 5000);
    for (int i = 0; i < count; ++i) {
        assert(received_len[i] == channels[i].incoming_len);
        assert(!memcmp(received[i], incoming[i], received_len[i]));
        assert(channels[i].outgoing_len == sizeof(upstream) - 1);
        assert(!memcmp(channels[i].outgoing, upstream, sizeof(upstream) - 1));
        assert(channels[i].sent_eof == 1);
        assert(relays[i]->downstream_len == 0 && relays[i]->upstream_len == 0);
        zw_ssh_relay_destroy(relays[i]);
        close(targets[i]);
    }
    puts("PASS relay data: two-stream rounds, socket/SSH partial writes, byte integrity, EOF tail drained exactly once");
}

int main(void) {
    socket_buffer_capacity();
    wait_arguments();
    pending_transport_readiness();
    backpressured_transport_readiness();
    partial_writes_and_eof();
    return 0;
}
