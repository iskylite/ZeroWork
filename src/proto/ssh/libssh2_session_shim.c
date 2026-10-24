#include "libssh2_session_shim.h"
#include "libssh2.h"
#include "libssh2_sftp.h"
#include <errno.h>
#include <fcntl.h>
#include <netdb.h>
#include <arpa/inet.h>
#include <poll.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>
#include <time.h>
#include <stdlib.h>

/* Interrupt this owned connection without recycling its descriptor. The
   ordinary Session cleanup remains responsible for the one final close. */
void zw_ssh_socket_interrupt(int socket_fd) { if (socket_fd >= 0) (void)shutdown(socket_fd, SHUT_RDWR); }
int zw_ssh_socket_release(int socket_fd) { return socket_fd < 0 ? 0 : close(socket_fd); }

int zw_ssh_socketpair(int *target_fd, int *relay_fd) {
    int pair[2];
    *target_fd = -1; *relay_fd = -1;
    if (socketpair(AF_UNIX, SOCK_STREAM, 0, pair) != 0) return -1;
    int no_sigpipe = 1;
    for (int i = 0; i < 2; i++) {
        int flags = fcntl(pair[i], F_GETFL, 0);
        if (flags < 0 || fcntl(pair[i], F_SETFL, flags | O_NONBLOCK) < 0 ||
            setsockopt(pair[i], SOL_SOCKET, SO_NOSIGPIPE, &no_sigpipe, sizeof(no_sigpipe)) < 0) {
            close(pair[0]); close(pair[1]); return -1;
        }
    }
    *target_fd = pair[0]; *relay_fd = pair[1];
    return 0;
}

struct zw_ssh_relay {
    int fd, socket_eof, channel_eof, sent_eof;
    LIBSSH2_CHANNEL *channel;
    unsigned char upstream[32768], downstream[32768];
    size_t upstream_offset, upstream_len, downstream_offset, downstream_len;
};

ZW_SSH_RELAY *zw_ssh_relay_create(int fd, LIBSSH2_CHANNEL *channel) {
    ZW_SSH_RELAY *relay = calloc(1, sizeof(*relay));
    if (!relay) { close(fd); return NULL; }
    relay->fd = fd; relay->channel = channel;
    return relay;
}

int zw_ssh_relay_step(ZW_SSH_RELAY *r) {
    /* Zero channel reads indicate no decrypted packet unless channel_eof says
       otherwise. EAGAIN is flow control, never EOF or a dropped write. */
    if (!r->socket_eof && r->upstream_len == 0) {
        ssize_t n = recv(r->fd, r->upstream, sizeof(r->upstream), 0);
        if (n > 0) { r->upstream_len = (size_t)n; r->upstream_offset = 0; }
        else if (n == 0) r->socket_eof = 1;
        else if (errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR) return -1;
    }
    if (r->upstream_len) {
        ssize_t n = libssh2_channel_write(r->channel,
            (char *)r->upstream + r->upstream_offset, r->upstream_len);
        if (n > 0) { r->upstream_offset += (size_t)n; r->upstream_len -= (size_t)n; }
        else if (n < 0 && n != LIBSSH2_ERROR_EAGAIN) return -1;
    }
    if (r->socket_eof && !r->upstream_len && !r->sent_eof) {
        int rc = libssh2_channel_send_eof(r->channel);
        if (rc == 0) r->sent_eof = 1;
        else if (rc != LIBSSH2_ERROR_EAGAIN) return -1;
    }
    if (!r->channel_eof && !r->downstream_len) {
        ssize_t n = libssh2_channel_read(r->channel, (char *)r->downstream, sizeof(r->downstream));
        if (n > 0) { r->downstream_len = (size_t)n; r->downstream_offset = 0; }
        else if (n < 0 && n != LIBSSH2_ERROR_EAGAIN) return -1;
        else if (n == 0 && libssh2_channel_eof(r->channel)) r->channel_eof = 1;
    }
    if (r->downstream_len) {
        ssize_t n = send(r->fd, r->downstream + r->downstream_offset, r->downstream_len, 0);
        if (n > 0) { r->downstream_offset += (size_t)n; r->downstream_len -= (size_t)n; }
        else if (n == 0) return -1;
        else if (errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR) return -1;
    }
    if (r->channel_eof && !r->downstream_len) {
        shutdown(r->fd, SHUT_WR);
        if (r->socket_eof && !r->upstream_len && r->sent_eof) return 1;
    }
    return 0;
}

void zw_ssh_relay_interrupt(ZW_SSH_RELAY *relay) {
    if (relay) (void)shutdown(relay->fd, SHUT_RDWR);
}
void zw_ssh_relay_destroy(ZW_SSH_RELAY *relay) {
    if (!relay) return;
    zw_ssh_relay_interrupt(relay);
    close(relay->fd);
    free(relay);
}
void zw_ssh_relay_pause(void) { (void)poll(NULL, 0, 2); }

int zw_libssh2_library_init(void) { return libssh2_init(0); }
void zw_libssh2_library_exit(void) { libssh2_exit(); }

#define ZW_CONNECT_TIMEOUT_MS 8000

static _Thread_local int zw_last_connect_errno = 0;
int zw_ssh_socket_last_error(void) { return zw_last_connect_errno; }

static long long mono_ms(void) {
    struct timespec ts;
    if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0) return 0;
    return (long long)ts.tv_sec * 1000LL + ts.tv_nsec / 1000000LL;
}

struct zw_drive_wait {
    const ZW_SSH_DRIVE *options;
    long long deadline;
    int failure;
};
static struct zw_drive_wait drive_begin(const ZW_SSH_DRIVE *options) {
    struct zw_drive_wait wait = { options, mono_ms() + (options->timeout_ms ? options->timeout_ms : ZW_CONNECT_TIMEOUT_MS), 0 };
#ifdef SO_NOSIGPIPE
    int enabled = 1;
    (void)setsockopt(options->socket_fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, sizeof(enabled));
#endif
    return wait;
}
static int drive_check(struct zw_drive_wait *wait) {
    if (wait->failure) return wait->failure;
    if (wait->options->cancelled && wait->options->cancelled(wait->options->ctx))
        return wait->failure = ZW_SSH_CANCELLED;
    if (mono_ms() >= wait->deadline) return wait->failure = ZW_SSH_TIMED_OUT;
    return 0;
}
static int drive_poll(struct zw_drive_wait *wait, int fd, short events) {
    for (;;) {
        int checked = drive_check(wait);
        if (checked) return checked;
        long long remaining = wait->deadline - mono_ms();
        int slice = (int)(remaining < 25 ? remaining : 25);
        if (slice < 1) slice = 1;
        struct pollfd descriptor = { fd, events, 0 };
        int rc = poll(events ? &descriptor : NULL, events ? 1 : 0, slice);
        checked = drive_check(wait);
        if (checked) return checked;
        if (rc < 0) {
            if (errno == EINTR) continue;
            return wait->failure = ZW_SSH_WAIT_FAILED;
        }
        if (!events) return 0; /* Missing directions: bounded backoff, no spin. */
        if (rc == 0) continue;
        if (descriptor.revents & POLLNVAL) return wait->failure = ZW_SSH_WAIT_FAILED;
        if (descriptor.revents & events) return 0;
        if (descriptor.revents & (POLLERR | POLLHUP)) return wait->failure = ZW_SSH_WAIT_FAILED;
    }
}
static int drive_again(LIBSSH2_SESSION *session, struct zw_drive_wait *wait) {
    int directions = libssh2_session_block_directions(session);
    short events = 0;
    if (directions & LIBSSH2_SESSION_BLOCK_INBOUND) events |= POLLIN;
    if (directions & LIBSSH2_SESSION_BLOCK_OUTBOUND) events |= POLLOUT;
    return drive_poll(wait, wait->options->socket_fd, events);
}
/* Resume one operation with unchanged pointers/state, not a new auth attempt.
   In particular, failure/PARTIAL state is reset only before this loop. */
#define DRIVE_STEP(result, call, session, wait) do { \
    for (;;) { \
        result = drive_check(wait); \
        if (result) break; \
        result = (call); \
        if ((wait)->failure) { result = (wait)->failure; break; } \
        if (result != LIBSSH2_ERROR_EAGAIN) break; \
        result = drive_again(session, wait); \
        if (result) break; \
    } \
} while (0)

int zw_libssh2_session_handshake_driven(LIBSSH2_SESSION *session, const ZW_SSH_DRIVE *options) {
    struct zw_drive_wait wait = drive_begin(options);
    int result;
    DRIVE_STEP(result, libssh2_session_handshake(session, options->socket_fd), session, &wait);
    return result;
}

static int connect_cancelled(zw_ssh_cancel_cb cancelled, void *ctx) {
    if (!cancelled || !cancelled(ctx)) return 0;
    errno = ECANCELED;
    zw_last_connect_errno = ECANCELED;
    return 1;
}
static int wait_connected(int socket_fd, unsigned int timeout_ms,
                          zw_ssh_cancel_cb cancelled, void *ctx) {
    struct pollfd pfd = { .fd = socket_fd, .events = POLLOUT };
    const long long deadline = mono_ms() + (long long)timeout_ms;
    for (;;) {
        if (connect_cancelled(cancelled, ctx)) return -1;
        long long remaining = deadline - mono_ms();
        if (remaining <= 0) { errno = ETIMEDOUT; return -1; }
        int slice = (int)(remaining > 0x7fffffffLL ? 0x7fffffffLL : remaining);
        if (cancelled && slice > 50) slice = 50;
        int rc = poll(&pfd, 1, slice);
        if (rc < 0) { if (errno == EINTR) continue; return -1; }
        if (rc > 0) break;
    }
    int so_error = 0;
    socklen_t len = sizeof(so_error);
    if (getsockopt(socket_fd, SOL_SOCKET, SO_ERROR, &so_error, &len) != 0) return -1;
    if (so_error != 0) { errno = so_error; return -1; }
    return 0;
}

int zw_ssh_socket_connect(const char *host, unsigned short port, unsigned int timeout_ms) {
    return zw_ssh_socket_connect_cancellable(host, port, timeout_ms, NULL, NULL);
}

int zw_ssh_socket_connect_cancellable(const char *host, unsigned short port,
    unsigned int timeout_ms, zw_ssh_cancel_cb cancelled, void *ctx) {
    zw_last_connect_errno = 0;
    if (connect_cancelled(cancelled, ctx)) return -1;
    if (timeout_ms == 0) timeout_ms = ZW_CONNECT_TIMEOUT_MS;
    const long long deadline = mono_ms() + (long long)timeout_ms;
    struct addrinfo hints;
    struct addrinfo *addresses = NULL;
    struct addrinfo *address;
    char service[6];
    int socket_fd = -1;
    int connected = 0;
    memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    /* Numeric IPv4 host entries (the normal SSH host asset form) must not
       take an unreachable IPv6 candidate first inside an app process. */
    struct in_addr numeric_v4;
    if (inet_pton(AF_INET, host, &numeric_v4) == 1) hints.ai_family = AF_INET;
    (void)snprintf(service, sizeof(service), "%u", (unsigned int)port);
    int gai = getaddrinfo(host, service, &hints, &addresses);
    if (gai != 0) { zw_last_connect_errno = gai; return -1; }
    for (address = addresses; address; address = address->ai_next) {

        // First reachability attempt can fail instantly (cold ARP/first
        // route lookup, EHOSTUNREACH/ENETUNREACH) even though the host is
        // reachable — retry transient errors briefly before giving up.
        for (;;) {
            if (connect_cancelled(cancelled, ctx)) goto finish;
            long long remaining = deadline - mono_ms();
            if (remaining <= 0) break;
            socket_fd = socket(address->ai_family, address->ai_socktype, address->ai_protocol);
            if (socket_fd < 0) {
                if (errno == EMFILE || errno == ENFILE) break;
                continue;
            }
            int flags = fcntl(socket_fd, F_GETFL, 0);
            if (flags < 0 || fcntl(socket_fd, F_SETFL, flags | O_NONBLOCK) < 0) {
                zw_last_connect_errno = errno;
                close(socket_fd);
                socket_fd = -1;
                break;
            }
            if (connect(socket_fd, address->ai_addr, address->ai_addrlen) == 0) {
                goto connected;
            }
            if (errno == EINPROGRESS && wait_connected(socket_fd, (unsigned int)(remaining > 0x7fffffffLL ? 0x7fffffffLL : remaining), cancelled, ctx) == 0) {
                goto connected;
            }
            if (connect_cancelled(cancelled, ctx)) goto finish;
            /* IMPORTANT: keep the socket O_NONBLOCK after connect. The
               worker drives this session with kqueue + a nonblocking
               libssh2 session; a blocking socket makes libssh2's transport
               recv() BLOCK THE WORKER THREAD whenever the TCP buffer runs
               dry mid-burst (EAGAIN semantics silently void). That stalled
               the whole event loop inside recv() until the remote happened
               to send more — the "output trickle / multi-second dead air"
               bug. libssh2 blocking mode (used only during handshake/auth)
               is fine with nonblocking sockets too: it polls internally
               via _libssh2_wait_socket. */
            int transient = (errno == EHOSTUNREACH || errno == ENETUNREACH ||
                             errno == ENETDOWN || errno == ETIMEDOUT ||
                             errno == ECONNREFUSED || errno == EAGAIN);
            zw_last_connect_errno = errno;
            close(socket_fd);
            socket_fd = -1;
            if (!transient) break;
            remaining = deadline - mono_ms();
            if (remaining <= 0) break;
            unsigned int delay = (unsigned int)(remaining < 300 ? remaining : 300);
            do {
                if (connect_cancelled(cancelled, ctx)) goto finish;
                unsigned int slice = cancelled && delay > 50 ? 50 : delay;
                usleep((useconds_t)(slice * 1000));
                delay -= slice;
            } while (delay > 0);
        }
        continue;
    connected:
        {
            if (connect_cancelled(cancelled, ctx)) goto finish;
            struct sockaddr_storage peer;
            socklen_t peer_len = sizeof(peer);
            if (getpeername(socket_fd, (struct sockaddr *)&peer, &peer_len) != 0) {
                zw_last_connect_errno = errno;
                close(socket_fd);
                socket_fd = -1;
                continue;
            }
            connected = 1;
            zw_last_connect_errno = 0;
        }
        break;
    }
finish:
    freeaddrinfo(addresses);
    if (!connected) {
        if (socket_fd >= 0) close(socket_fd);
        if (!zw_last_connect_errno) zw_last_connect_errno = ETIMEDOUT;
        return -1;
    }
    return socket_fd;
}
void zw_ssh_socket_close(int socket_fd) { if (socket_fd >= 0) close(socket_fd); }
int zw_ssh_socket_set_blocking(int socket_fd) {
    int flags = fcntl(socket_fd, F_GETFL, 0);
    if (flags < 0) return -1;
    return fcntl(socket_fd, F_SETFL, flags & ~O_NONBLOCK);
}
int zw_ssh_socket_set_nonblocking(int socket_fd) {
    int flags = fcntl(socket_fd, F_GETFL, 0);
    if (flags < 0) return -1;
    return fcntl(socket_fd, F_SETFL, flags | O_NONBLOCK);
}
LIBSSH2_SESSION *zw_libssh2_session_create(void) { return libssh2_session_init(); }
int zw_libssh2_session_handshake(LIBSSH2_SESSION *session, int socket_fd) {
    /* Session creation uses libssh2's blocking API with the configured total
       timeout. It already waits internally for EAGAIN; retrying this call
       hundreds of times could multiply the configured timeout. */
    errno = 0;
    int result = libssh2_session_handshake(session, socket_fd);
    zw_last_connect_errno = result == 0 ? 0 : errno;
    return result;
}
int zw_libssh2_session_hostkey_fingerprint(LIBSSH2_SESSION *session,
                                            char *algorithm, size_t algorithm_len,
                                            char *fingerprint, size_t fingerprint_len) {
    if (!session || !algorithm || !fingerprint || algorithm_len == 0 || fingerprint_len < 9) return -1;
    size_t key_len = 0;
    int key_type = 0;
    const unsigned char *key = (const unsigned char *)libssh2_session_hostkey(session, &key_len, &key_type);
    (void)key;
    if (!key || key_len == 0) return -1;
    const char *name = "unknown";
    switch (key_type) {
        case LIBSSH2_HOSTKEY_TYPE_RSA: name = "rsa"; break;
        case LIBSSH2_HOSTKEY_TYPE_DSS: name = "dss"; break;
        case LIBSSH2_HOSTKEY_TYPE_ECDSA_256: name = "ecdsa-sha2-nistp256"; break;
        case LIBSSH2_HOSTKEY_TYPE_ECDSA_384: name = "ecdsa-sha2-nistp384"; break;
        case LIBSSH2_HOSTKEY_TYPE_ECDSA_521: name = "ecdsa-sha2-nistp521"; break;
        case LIBSSH2_HOSTKEY_TYPE_ED25519: name = "ssh-ed25519"; break;
        default: break;
    }
    if (strlen(name) + 1 > algorithm_len) return -1;
    strcpy(algorithm, name);
    const unsigned char *hash = (const unsigned char *)libssh2_hostkey_hash(session, LIBSSH2_HOSTKEY_HASH_SHA256);
    if (!hash) return -1;
    /* libssh2 returns the raw 32-byte digest. Encode the same base64 form
       users see in known_hosts/OpenSSH, without introducing a crypto dep. */
    static const char b64[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    char encoded[45];
    size_t out = 0;
    for (size_t i = 0; i < 32; i += 3) {
        unsigned int v = ((unsigned int)hash[i] << 16) |
                         ((unsigned int)(i + 1 < 32 ? hash[i + 1] : 0) << 8) |
                         (unsigned int)(i + 2 < 32 ? hash[i + 2] : 0);
        encoded[out++] = b64[(v >> 18) & 63];
        encoded[out++] = b64[(v >> 12) & 63];
        encoded[out++] = (i + 1 < 32) ? b64[(v >> 6) & 63] : '=';
        encoded[out++] = (i + 2 < 32) ? b64[v & 63] : '=';
    }
    encoded[out] = '\0';
    if (9 + out + 1 > fingerprint_len) return -1;
    memcpy(fingerprint, "SHA256:", 7);
    memcpy(fingerprint + 7, encoded, out + 1);
    return 0;
}
const unsigned char *zw_libssh2_session_hostkey_raw(LIBSSH2_SESSION *session, size_t *length) {
    int type = 0;
    return (const unsigned char *)libssh2_session_hostkey(session, length, &type);
}
LIBSSH2_KNOWNHOSTS *zw_ssh_knownhosts_create(LIBSSH2_SESSION *session) { return libssh2_knownhost_init(session); }
void zw_ssh_knownhosts_free(LIBSSH2_KNOWNHOSTS *hosts) { if (hosts) libssh2_knownhost_free(hosts); }
static int zw_knownhost_key_type(const char *algorithm) {
    if (!strcmp(algorithm, "ssh-rsa")) return LIBSSH2_KNOWNHOST_KEY_SSHRSA;
    if (!strcmp(algorithm, "ssh-dss")) return LIBSSH2_KNOWNHOST_KEY_SSHDSS;
    if (!strcmp(algorithm, "ssh-ed25519")) return LIBSSH2_KNOWNHOST_KEY_ED25519;
    if (!strcmp(algorithm, "ecdsa-sha2-nistp256")) return LIBSSH2_KNOWNHOST_KEY_ECDSA_256;
    if (!strcmp(algorithm, "ecdsa-sha2-nistp384")) return LIBSSH2_KNOWNHOST_KEY_ECDSA_384;
    if (!strcmp(algorithm, "ecdsa-sha2-nistp521")) return LIBSSH2_KNOWNHOST_KEY_ECDSA_521;
    return 0;
}
int zw_ssh_knownhosts_add_raw(LIBSSH2_KNOWNHOSTS *hosts, const char *host,
    const char *salt, const char *algorithm, const unsigned char *key, size_t length) {
    int type = zw_knownhost_key_type(algorithm);
    if (!type) return -1;
    return libssh2_knownhost_addc(hosts, host, salt, (const char *)key, length, NULL, 0,
        (salt ? LIBSSH2_KNOWNHOST_TYPE_SHA1 : LIBSSH2_KNOWNHOST_TYPE_PLAIN) | LIBSSH2_KNOWNHOST_KEYENC_RAW | type, NULL);
}
int zw_ssh_knownhosts_check(LIBSSH2_KNOWNHOSTS *hosts, const char *endpoint,
    const unsigned char *key, size_t length) {
    /* A different algorithm at a known endpoint is a mismatch, not unknown. */
    return libssh2_knownhost_check(hosts, endpoint, (const char *)key, length,
        LIBSSH2_KNOWNHOST_TYPE_PLAIN | LIBSSH2_KNOWNHOST_KEYENC_RAW, NULL);
}
int zw_ssh_knownhosts_write(LIBSSH2_KNOWNHOSTS *hosts, char *output, size_t capacity, size_t *length) {
    struct libssh2_knownhost *entry = NULL;
    if (libssh2_knownhost_get(hosts, &entry, NULL) != 0 || !entry) return -1;
    return libssh2_knownhost_writeline(hosts, entry, output, capacity, length, LIBSSH2_KNOWNHOST_FILE_OPENSSH);
}
void zw_libssh2_session_set_timeout(LIBSSH2_SESSION *session, long timeout_ms) { libssh2_session_set_timeout(session, timeout_ms); }
void zw_libssh2_session_config_keepalive(LIBSSH2_SESSION *session, unsigned int interval_sec) {
    /* libssh2 uses interval=0 to disable keepalive. want_reply=1 makes dead
       peers observable while keeping the call non-blocking in worker mode. */
    libssh2_keepalive_config(session, interval_sec != 0, interval_sec);
}
int zw_libssh2_session_send_keepalive(LIBSSH2_SESSION *session) {
    int seconds = 0;
    return libssh2_keepalive_send(session, &seconds);
}
int zw_libssh2_session_set_compression(LIBSSH2_SESSION *session, int enabled) {
    /* Must be selected before handshake. Keep the server's normal fallback
       when disabled; when enabled prefer zlib then OpenSSH delayed zlib. */
    static const char *const compressed = "zlib,zlib@openssh.com,none";
    static const char *const plain = "none,zlib,zlib@openssh.com";
    int flag_rc = libssh2_session_flag(session, LIBSSH2_FLAG_COMPRESS, enabled);
    if(flag_rc != 0) return flag_rc;
    int rc1 = libssh2_session_method_pref(session, LIBSSH2_METHOD_COMP_CS, enabled ? compressed : plain);
    int rc2 = libssh2_session_method_pref(session, LIBSSH2_METHOD_COMP_SC, enabled ? compressed : plain);
    return rc1 == 0 && rc2 == 0 ? 0 : -1;
}
int zw_libssh2_auth_password(LIBSSH2_SESSION *session, const char *user, const char *password) {
    libssh2_userauth_result_reset(session);
    return libssh2_userauth_password(session, user, password);
}
int zw_libssh2_auth_password_driven(LIBSSH2_SESSION *session, const char *user, const char *password, const ZW_SSH_DRIVE *options) {
    struct zw_drive_wait wait = drive_begin(options);
    int rc;
    libssh2_userauth_result_reset(session);
    DRIVE_STEP(rc, libssh2_userauth_password(session, user, password), session, &wait);
    return rc;
}
int zw_libssh2_auth_methods(LIBSSH2_SESSION *session, const char *user, char *methods, size_t capacity, size_t *length) {
    int partial = 0;
    libssh2_userauth_result_reset(session);
    (void)libssh2_userauth_list(session, user, (unsigned int)strlen(user));
    if (libssh2_userauth_authenticated(session)) { *length = 0; if (capacity) methods[0] = 0; return 1; }
    return libssh2_userauth_last_result(session, &partial, methods, capacity, length) == 1 ? 0 : -1;
}
int zw_libssh2_auth_methods_driven(LIBSSH2_SESSION *session, const char *user, char *methods, size_t capacity, size_t *length, const ZW_SSH_DRIVE *options) {
    struct zw_drive_wait wait = drive_begin(options);
    libssh2_userauth_result_reset(session);
    *length = 0;
    if (capacity) methods[0] = 0;
    for (;;) {
        int checked = drive_check(&wait);
        if (checked) return checked;
        char *advertised = libssh2_userauth_list(session, user, (unsigned int)strlen(user));
        if (libssh2_userauth_authenticated(session)) return 1;
        if (advertised || libssh2_session_last_errno(session) != LIBSSH2_ERROR_EAGAIN) break;
        checked = drive_again(session, &wait);
        if (checked) return checked;
    }
    int partial = 0;
    return libssh2_userauth_last_result(session, &partial, methods, capacity, length) == 1 ? 0 : -1;
}
int zw_libssh2_auth_result(LIBSSH2_SESSION *session, int *partial, char *methods, size_t capacity, size_t *length) {
    if (libssh2_userauth_authenticated(session)) { *partial = 0; *length = 0; if (capacity) methods[0] = 0; return 2; }
    return libssh2_userauth_last_result(session, partial, methods, capacity, length);
}
int zw_libssh2_last_error_code(LIBSSH2_SESSION *session) { return libssh2_session_last_errno(session); }
const char *zw_libssh2_last_error(LIBSSH2_SESSION *session) { int code = 0; char *message = NULL; libssh2_session_last_error(session, &message, &code, 0); return message ? message : ""; }
int zw_libssh2_auth_private_key(LIBSSH2_SESSION *session, const char *user, const char *private_key_path, const char *passphrase) {
    libssh2_userauth_result_reset(session);
    return libssh2_userauth_publickey_fromfile(session, user, NULL, private_key_path, passphrase);
}
int zw_libssh2_auth_private_key_driven(LIBSSH2_SESSION *session, const char *user, const char *path, const char *passphrase, const ZW_SSH_DRIVE *options) {
    struct zw_drive_wait wait = drive_begin(options);
    int rc;
    libssh2_userauth_result_reset(session);
    DRIVE_STEP(rc, libssh2_userauth_publickey_fromfile(session, user, NULL, path, passphrase), session, &wait);
    return rc;
}
int zw_ssh_private_key_readable(const char *path) {
    FILE *file = fopen(path, "rb");
    if (!file) return 0;
    fclose(file);
    return 1;
}
int zw_libssh2_auth_agent(LIBSSH2_SESSION *session, const char *user) {
    libssh2_userauth_result_reset(session);
    LIBSSH2_AGENT *agent = libssh2_agent_init(session);
    struct libssh2_agent_publickey *identity = NULL;
    struct libssh2_agent_publickey *previous = NULL;
    int rc = -1;
    if (!agent) return -1;
    if (libssh2_agent_connect(agent) != 0 || libssh2_agent_list_identities(agent) != 0) goto done;
    while (libssh2_agent_get_identity(agent, &identity, previous) == 0) {
        int partial = 0;
        char methods[1024];
        size_t length = 0;
        libssh2_userauth_result_reset(session);
        rc = libssh2_agent_userauth(agent, user, identity);
        if (rc == 0) break;
        /* A signed identity accepted as one factor must not be retried or
           overwritten by the next agent identity. */
        if (libssh2_userauth_last_result(session, &partial, methods, sizeof(methods), &length) == 1 && partial) break;
        previous = identity;
    }
done:
    libssh2_agent_disconnect(agent);
    libssh2_agent_free(agent);
    return rc;
}

/* libssh2's UNIX agent transport uses blocking recv-all loops even when its
   SSH transport is nonblocking. Scope these callbacks to this Session and
   this synchronous worker call; another Session/thread never sees them. */
struct zw_agent_io { struct zw_drive_wait *wait; };
static ssize_t driven_agent_recv(libssh2_socket_t fd, void *buffer, size_t length, int flags, void **abstract) {
    struct zw_agent_io *io = (struct zw_agent_io *)*abstract;
    for (;;) {
        if (drive_check(io->wait)) return -EIO;
        ssize_t rc = recv(fd, buffer, length, flags | MSG_DONTWAIT);
        if (rc > 0 || (rc == 0 && fd == io->wait->options->socket_fd)) return rc;
        if (rc == 0) return -ECONNRESET; /* recv-all must not spin on EOF. */
        if (errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR) return -errno;
        if (fd == io->wait->options->socket_fd) return -EAGAIN;
        if (drive_poll(io->wait, fd, POLLIN)) return -EIO;
    }
}
static ssize_t driven_agent_send(libssh2_socket_t fd, const void *buffer, size_t length, int flags, void **abstract) {
    struct zw_agent_io *io = (struct zw_agent_io *)*abstract;
#ifdef SO_NOSIGPIPE
    int enabled = 1;
    (void)setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, sizeof(enabled));
#endif
    for (;;) {
        if (drive_check(io->wait)) return -EIO;
        ssize_t rc = send(fd, buffer, length, flags | MSG_DONTWAIT);
        if (rc >= 0) return rc;
        if (errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR) return -errno;
        if (fd == io->wait->options->socket_fd) return -EAGAIN;
        if (drive_poll(io->wait, fd, POLLOUT)) return -EIO;
    }
}
int zw_libssh2_auth_agent_driven(LIBSSH2_SESSION *session, const char *user, const ZW_SSH_DRIVE *options) {
    struct zw_drive_wait wait = drive_begin(options);
    int rc = drive_check(&wait);
    if (rc) return rc;
    LIBSSH2_AGENT *agent = libssh2_agent_init(session);
    if (!agent) return LIBSSH2_ERROR_ALLOC;
    struct zw_agent_io io = { &wait };
    void **abstract = libssh2_session_abstract(session);
    void *previous_abstract = *abstract;
    libssh2_cb_generic *previous_recv = libssh2_session_callback_set2(session, LIBSSH2_CALLBACK_RECV, (libssh2_cb_generic *)driven_agent_recv);
    libssh2_cb_generic *previous_send = libssh2_session_callback_set2(session, LIBSSH2_CALLBACK_SEND, (libssh2_cb_generic *)driven_agent_send);
    *abstract = &io;
    libssh2_userauth_result_reset(session);
    rc = libssh2_agent_connect(agent);
    if (rc) goto done_driven_agent;
    rc = libssh2_agent_list_identities(agent);
    if (rc || wait.failure) goto done_driven_agent;
    struct libssh2_agent_publickey *identity = NULL, *previous = NULL;
    while (libssh2_agent_get_identity(agent, &identity, previous) == 0) {
        int partial = 0;
        char methods[1024];
        size_t length = 0;
        libssh2_userauth_result_reset(session);
        DRIVE_STEP(rc, libssh2_agent_userauth(agent, user, identity), session, &wait);
        if (rc == 0 || wait.failure) break;
        if (libssh2_userauth_last_result(session, &partial, methods, sizeof(methods), &length) == 1 && partial) break;
        previous = identity;
    }
done_driven_agent:
    *abstract = previous_abstract;
    libssh2_session_callback_set2(session, LIBSSH2_CALLBACK_RECV, previous_recv);
    libssh2_session_callback_set2(session, LIBSSH2_CALLBACK_SEND, previous_send);
    libssh2_agent_disconnect(agent);
    libssh2_agent_free(agent);
    return wait.failure ? wait.failure : rc;
}

struct zw_kbd_ctx { zw_ssh_kbd_prompt_cb callback; void *ctx; };
static void zw_kbd_adapter(const char *name, int name_len, const char *instruction,
                           int instruction_len, int num_prompts,
                           const LIBSSH2_USERAUTH_KBDINT_PROMPT *prompts,
                           LIBSSH2_USERAUTH_KBDINT_RESPONSE *responses, void **abstract) {
    struct zw_kbd_ctx *bridge = (struct zw_kbd_ctx *)*abstract;
    (void)name; (void)name_len; (void)instruction; (void)instruction_len;
    for (int i = 0; i < num_prompts; ++i) {
        responses[i].text = NULL; responses[i].length = 0;
        if (!bridge || !bridge->callback) continue;
        char answer[256];
        int n = bridge->callback(bridge->ctx, (const char *)prompts[i].text, (size_t)prompts[i].length, answer, sizeof(answer));
        /* Negative or oversized answers reject the challenge. Never copy
           beyond the bounded stack buffer into libssh2's response. */
        if (n > (int)sizeof(answer)) return;
        if (n > 0) {
            responses[i].text = malloc((size_t)n);
            if (responses[i].text) { memcpy(responses[i].text, answer, (size_t)n); responses[i].length = n; }
        }
    }
}
int zw_libssh2_auth_keyboard_interactive(LIBSSH2_SESSION *session, const char *user,
                                         zw_ssh_kbd_prompt_cb callback, void *ctx) {
    libssh2_userauth_result_reset(session);
    struct zw_kbd_ctx bridge = { callback, ctx };
    /* libssh2 passes its session abstract pointer to the callback. Preserve
       the caller's value and install our bridge only for this auth attempt. */
    void **abstract = libssh2_session_abstract(session);
    void *previous = abstract ? *abstract : NULL;
    if (abstract) *abstract = &bridge;
    int rc = libssh2_userauth_keyboard_interactive_ex(session, user, (unsigned int)strlen(user), zw_kbd_adapter);
    if (abstract) *abstract = previous;
    return rc;
}

struct zw_batch_ctx { zw_ssh_auth_prompts_cb callback; void *ctx; int invalid; struct zw_drive_wait *wait; };
static void zw_batch_adapter(const char *name, int name_len, const char *instruction,
    int instruction_len, int count, const LIBSSH2_USERAUTH_KBDINT_PROMPT *prompts,
    LIBSSH2_USERAUTH_KBDINT_RESPONSE *responses, void **abstract) {
    struct zw_batch_ctx *bridge = (struct zw_batch_ctx *)*abstract;
    ZW_SSH_AUTH_PROMPT group[16];
    ZW_SSH_AUTH_RESPONSE answers[16];
    char buffers[16][256] = {{0}};
    size_t total = 0;
    (void)name; (void)name_len; (void)instruction; (void)instruction_len;
    for (int i = 0; i < count; ++i) { responses[i].text = NULL; responses[i].length = 0; }
    if (count == 0) return;
    if (!bridge) return;
    if (count < 0 || count > 16 || !bridge->callback) { bridge->invalid = 1; return; }
    for (int i = 0; i < count; ++i) {
        if (prompts[i].length > 4096 - total) { bridge->invalid = 1; return; }
        total += prompts[i].length;
        group[i] = (ZW_SSH_AUTH_PROMPT){ (const char *)prompts[i].text, prompts[i].length, prompts[i].echo != 0 };
        answers[i] = (ZW_SSH_AUTH_RESPONSE){ buffers[i], sizeof(buffers[i]), 0 };
    }
    long long prompt_start = mono_ms();
    int answer_rc = bridge->callback(bridge->ctx, group, (size_t)count, answers);
    /* Human prompt time has its own scoped challenge deadline. Do not charge
       it against the network wait timeout or restart the wire operation. */
    if (bridge->wait) bridge->wait->deadline += mono_ms() - prompt_start;
    if (answer_rc != 0) goto cleanup;
    /* Validate every response before exposing any of the group to libssh2. */
    for (int i = 0; i < count; ++i)
        if (answers[i].text != buffers[i] || answers[i].length == 0 || answers[i].length > sizeof(buffers[i])) goto cleanup;
    for (int i = 0; i < count; ++i) {
        responses[i].text = malloc(answers[i].length);
        if (!responses[i].text) {
            for (int j = 0; j < i; ++j) { memset(responses[j].text, 0, responses[j].length); free(responses[j].text); responses[j].text = NULL; responses[j].length = 0; }
            goto cleanup;
        }
        memcpy(responses[i].text, buffers[i], answers[i].length);
        responses[i].length = (unsigned int)answers[i].length;
    }
cleanup:
    /* Volatile clearing keeps the bounded callback copies out of later stack use. */
    { volatile unsigned char *p = (volatile unsigned char *)buffers; for (size_t i = 0; i < sizeof(buffers); ++i) p[i] = 0; }
}
int zw_libssh2_auth_keyboard_interactive_batch(LIBSSH2_SESSION *session, const char *user,
    zw_ssh_auth_prompts_cb callback, void *ctx) {
    struct zw_batch_ctx bridge = { callback, ctx, 0, NULL };
    void **abstract = libssh2_session_abstract(session);
    void *previous = abstract ? *abstract : NULL;
    libssh2_userauth_result_reset(session);
    if (abstract) *abstract = &bridge;
    int rc = libssh2_userauth_keyboard_interactive_ex(session, user, (unsigned int)strlen(user), zw_batch_adapter);
    if (abstract) *abstract = previous;
    return bridge.invalid ? -1000 : rc;
}
int zw_libssh2_auth_keyboard_interactive_batch_driven(LIBSSH2_SESSION *session, const char *user,
    zw_ssh_auth_prompts_cb callback, void *ctx, const ZW_SSH_DRIVE *options) {
    struct zw_drive_wait wait = drive_begin(options);
    struct zw_batch_ctx bridge = { callback, ctx, 0, &wait };
    void **abstract = libssh2_session_abstract(session);
    void *previous = abstract ? *abstract : NULL;
    libssh2_userauth_result_reset(session);
    if (abstract) *abstract = &bridge;
    int rc;
    DRIVE_STEP(rc, libssh2_userauth_keyboard_interactive_ex(session, user, (unsigned int)strlen(user), zw_batch_adapter), session, &wait);
    if (abstract) *abstract = previous;
    return bridge.invalid ? -1000 : rc;
}
int zw_libssh2_open_shell_driven(LIBSSH2_SESSION *session, const char *term, int cols, int rows,
    LIBSSH2_CHANNEL **output, const ZW_SSH_DRIVE *options) {
    *output = NULL;
    struct zw_drive_wait wait = drive_begin(options);
    LIBSSH2_CHANNEL *channel;
    int rc;
    for (;;) {
        rc = drive_check(&wait);
        if (rc) return rc;
        channel = libssh2_channel_open_session(session);
        if (channel) break;
        rc = libssh2_session_last_errno(session);
        if (rc != LIBSSH2_ERROR_EAGAIN) return rc ? rc : LIBSSH2_ERROR_CHANNEL_FAILURE;
        rc = drive_again(session, &wait);
        if (rc) return rc;
    }
    DRIVE_STEP(rc, libssh2_channel_request_pty_ex(channel, term, (unsigned int)strlen(term), NULL, 0, cols, rows, 0, 0), session, &wait);
    if (rc) return rc;
    DRIVE_STEP(rc, libssh2_channel_shell(channel), session, &wait);
    if (rc) return rc;
    *output = channel;
    return 0;
}
LIBSSH2_CHANNEL *zw_libssh2_open_shell(LIBSSH2_SESSION *session, const char *term, int cols, int rows) {
    LIBSSH2_CHANNEL *channel = libssh2_channel_open_session(session);
    if (!channel) return NULL;
    if (libssh2_channel_request_pty_ex(channel, term, (unsigned int)strlen(term), NULL, 0, cols, rows, 0, 0) != 0 || libssh2_channel_shell(channel) != 0) {
        libssh2_channel_free(channel);
        return NULL;
    }
    return channel;
}
LIBSSH2_CHANNEL *zw_libssh2_open_direct_tcpip(LIBSSH2_SESSION *session, const char *host, unsigned short port) {
    if (!session || !host || !host[0] || port == 0) return NULL;
    return libssh2_channel_direct_tcpip_ex(session, host, port, "127.0.0.1", 0);
}
LIBSSH2_CHANNEL *zw_libssh2_open_exec(LIBSSH2_SESSION *session, const char *command) {
    if (!session || !command || !command[0]) return NULL;
    LIBSSH2_CHANNEL *channel = libssh2_channel_open_session(session);
    if (!channel) return NULL;
    if (libssh2_channel_exec(channel, command) != 0) {
        libssh2_channel_free(channel);
        return NULL;
    }
    return channel;
}
int zw_libssh2_exec_channel_open_step(LIBSSH2_SESSION *session, LIBSSH2_CHANNEL **channel) {
    if (!session || !channel) return LIBSSH2_ERROR_BAD_USE;
    if (*channel) return 0;
    *channel = libssh2_channel_open_session(session);
    if (*channel) return 0;
    int rc = libssh2_session_last_errno(session);
    return rc == LIBSSH2_ERROR_EAGAIN ? 1 : rc ? rc : LIBSSH2_ERROR_CHANNEL_FAILURE;
}
int zw_libssh2_session_channel_open_step(LIBSSH2_SESSION *session, LIBSSH2_CHANNEL **channel) {
    return zw_libssh2_exec_channel_open_step(session, channel);
}
int zw_libssh2_exec_request_step(LIBSSH2_CHANNEL *channel, const char *command) {
    if (!channel || !command || !command[0]) return LIBSSH2_ERROR_BAD_USE;
    int rc = libssh2_channel_exec(channel, command);
    return rc == LIBSSH2_ERROR_EAGAIN ? 1 : rc;
}
void zw_libssh2_session_nonblocking(LIBSSH2_SESSION *session) { libssh2_session_set_blocking(session, 0); }
void zw_libssh2_session_set_blocking(LIBSSH2_SESSION *session) { libssh2_session_set_blocking(session, 1); }
const char *zw_libssh2_session_cipher_sc(LIBSSH2_SESSION *session) {
    return libssh2_session_methods(session, LIBSSH2_METHOD_CRYPT_SC);
}
const char *zw_libssh2_session_cipher_cs(LIBSSH2_SESSION *session) {
    return libssh2_session_methods(session, LIBSSH2_METHOD_CRYPT_CS);
}
const char *zw_libssh2_session_hostkey_method(LIBSSH2_SESSION *session) {
    return libssh2_session_methods(session, LIBSSH2_METHOD_HOSTKEY);
}
int zw_libssh2_session_last_error(LIBSSH2_SESSION *session) {
    return libssh2_session_last_errno(session);
}
int zw_libssh2_session_prefer_rsa_sha2(LIBSSH2_SESSION *session) {
    return libssh2_session_method_pref(session, LIBSSH2_METHOD_SIGN_ALGO,
                                       "rsa-sha2-512,rsa-sha2-256,ssh-rsa");
}

int zw_libssh2_session_prefer_stream_ciphers(LIBSSH2_SESSION *session) {
    /* chacha20-poly1305 + hmac-sha2-256 in this libssh2 build degrades sshd's
       send pattern to an intermittent trickle (measured: 3-9 bursty wakes vs
       a single back-to-back wake with CTR). Prefer AES-CTR (ARMv8 hardware
       path, what the OpenSSH client negotiates on this host: aes128-gcm).
       AES-GCM is unavailable in this vendored build (METHOD_NOT_SUPPORTED). */
    static const char *const prefs =
        "aes128-ctr,aes192-ctr,aes256-ctr,aes128-gcm@openssh.com,aes256-gcm@openssh.com";
    int rc1 = libssh2_session_method_pref(session, LIBSSH2_METHOD_CRYPT_CS, prefs);
    int rc2 = libssh2_session_method_pref(session, LIBSSH2_METHOD_CRYPT_SC, prefs);
    return (rc1 == 0 && rc2 == 0) ? 0 : -1;
}
void zw_libssh2_channel_close_free(LIBSSH2_CHANNEL *channel) {
    if (!channel) return;
    libssh2_channel_send_eof(channel);
    libssh2_channel_close(channel);
    libssh2_channel_free(channel);
}
static int release_receipt(int native_result) {
    return native_result == 0 ? 0 : native_result == LIBSSH2_ERROR_EAGAIN ? 1 : -1;
}
int zw_libssh2_channel_release(LIBSSH2_CHANNEL *channel) {
    /* channel_free performs the close itself, and retains the complete
       allocation when the peer acknowledgement has not arrived (EAGAIN). */
    return channel ? release_receipt(libssh2_channel_free(channel)) : 0;
}
static LIBSSH2_SEND_FUNC(released_session_send) {
    (void)socket; (void)buffer; (void)length; (void)flags; (void)abstract;
    return -EPIPE;
}
static LIBSSH2_RECV_FUNC(released_session_recv) {
    (void)socket; (void)buffer; (void)length; (void)flags; (void)abstract;
    return -ECONNRESET;
}
void zw_libssh2_session_abort_io(LIBSSH2_SESSION *session, int socket_fd) {
    zw_ssh_socket_interrupt(socket_fd);
    if (!session) return;
    libssh2_session_set_blocking(session, 0);
    /* These callbacks belong only to this terminally closing Session. They
       cannot affect another Session, and are never installed for one child
       channel cancellation. Preserve fd identity until session_free restores
       any native socket flags and actually frees all its child allocations. */
    libssh2_session_callback_set2(session, LIBSSH2_CALLBACK_SEND, (libssh2_cb_generic *)released_session_send);
    libssh2_session_callback_set2(session, LIBSSH2_CALLBACK_RECV, (libssh2_cb_generic *)released_session_recv);
}
int zw_libssh2_session_release(LIBSSH2_SESSION *session) {
    return session ? release_receipt(libssh2_session_free(session)) : 0;
}
LIBSSH2_SFTP *zw_libssh2_sftp_init(LIBSSH2_SESSION *session) { return libssh2_sftp_init(session); }
LIBSSH2_SFTP_HANDLE *zw_libssh2_sftp_open_write(LIBSSH2_SFTP *sftp, const char *path) { return libssh2_sftp_open(sftp, path, LIBSSH2_FXF_WRITE | LIBSSH2_FXF_CREAT | LIBSSH2_FXF_TRUNC, 0644); }
/* Fresh targets are always created exclusively; a name race never truncates. */
LIBSSH2_SFTP_HANDLE *zw_libssh2_sftp_open_exclusive(LIBSSH2_SFTP *sftp, const char *path) {
    return libssh2_sftp_open(sftp, path, LIBSSH2_FXF_WRITE | LIBSSH2_FXF_CREAT | LIBSSH2_FXF_EXCL, 0644);
}
/* Called only on the original opened-and-fstat-verified destination handle. */
int zw_libssh2_sftp_truncate(LIBSSH2_SFTP_HANDLE *handle, unsigned long long size) {
    LIBSSH2_SFTP_ATTRIBUTES attrs = {0};
    attrs.flags = LIBSSH2_SFTP_ATTR_SIZE;
    attrs.filesize = size;
    return libssh2_sftp_fsetstat(handle, &attrs);
}
LIBSSH2_SFTP_HANDLE *zw_libssh2_sftp_open_append(LIBSSH2_SFTP *sftp, const char *path, unsigned long long offset) {
    /* Resume never creates or truncates a destination which disappeared. */
    LIBSSH2_SFTP_HANDLE *handle = libssh2_sftp_open(sftp, path, LIBSSH2_FXF_WRITE, 0);
    if (handle) libssh2_sftp_seek64(handle, (libssh2_uint64_t)offset);
    return handle;
}
LIBSSH2_SFTP_HANDLE *zw_libssh2_sftp_open_read(LIBSSH2_SFTP *sftp, const char *path) { return libssh2_sftp_open(sftp, path, LIBSSH2_FXF_READ, 0); }
long zw_libssh2_sftp_read(LIBSSH2_SFTP_HANDLE *handle, unsigned char *buffer, size_t len) { return (long)libssh2_sftp_read(handle, (char *)buffer, len); }
long zw_libssh2_sftp_write(LIBSSH2_SFTP_HANDLE *handle, const unsigned char *buffer, size_t len) { return (long)libssh2_sftp_write(handle, (const char *)buffer, len); }
long long zw_libssh2_sftp_size(LIBSSH2_SFTP *sftp, const char *path) {
    LIBSSH2_SFTP_ATTRIBUTES attrs;
    if (libssh2_sftp_stat(sftp, path, &attrs) != 0 || !(attrs.flags & LIBSSH2_SFTP_ATTR_SIZE)) return -1;
    if (attrs.filesize > 0x7fffffffffffffffULL) return -1;
    return (long long)attrs.filesize;
}
int zw_libssh2_sftp_close(LIBSSH2_SFTP_HANDLE *handle) { return libssh2_sftp_close(handle); }
void zw_libssh2_sftp_shutdown(LIBSSH2_SFTP *sftp) { if (sftp) libssh2_sftp_shutdown(sftp); }
int zw_libssh2_sftp_release(LIBSSH2_SFTP *sftp) {
    return sftp ? release_receipt(libssh2_sftp_shutdown(sftp)) : 0;
}

static void readonly_attributes(ZW_SFTP_ATTRIBUTES *out, const LIBSSH2_SFTP_ATTRIBUTES *in) {
    out->flags = in->flags; out->size = in->filesize;
    out->permissions = in->permissions; out->mtime = in->mtime;
}
int zw_libssh2_sftp_realpath(LIBSSH2_SFTP *sftp, const char *path, char *output, size_t capacity) {
    if (capacity > 0xffffffffU) return LIBSSH2_ERROR_BAD_USE;
    return libssh2_sftp_realpath(sftp, path, output, (unsigned int)capacity);
}
LIBSSH2_SFTP_HANDLE *zw_libssh2_sftp_opendir(LIBSSH2_SFTP *sftp, const char *path) {
    return libssh2_sftp_opendir(sftp, path);
}
long zw_libssh2_sftp_readdir(LIBSSH2_SFTP_HANDLE *handle, char *name, size_t capacity, ZW_SFTP_ATTRIBUTES *out) {
    LIBSSH2_SFTP_ATTRIBUTES attrs = {0};
    int rc = libssh2_sftp_readdir_ex(handle, name, capacity, NULL, 0, &attrs);
    if (rc > 0) readonly_attributes(out, &attrs);
    return rc;
}
int zw_libssh2_sftp_stat_attributes(LIBSSH2_SFTP *sftp, const char *path, int follow, ZW_SFTP_ATTRIBUTES *out) {
    LIBSSH2_SFTP_ATTRIBUTES attrs = {0};
    int rc = libssh2_sftp_stat_ex(sftp, path, (unsigned int)strlen(path), follow ? LIBSSH2_SFTP_STAT : LIBSSH2_SFTP_LSTAT, &attrs);
    if (!rc) readonly_attributes(out, &attrs);
    return rc;
}
int zw_libssh2_sftp_fstat_attributes(LIBSSH2_SFTP_HANDLE *handle, ZW_SFTP_ATTRIBUTES *out) {
    LIBSSH2_SFTP_ATTRIBUTES attrs = {0};
    int rc = libssh2_sftp_fstat(handle, &attrs);
    if (!rc) readonly_attributes(out, &attrs);
    return rc;
}
unsigned long zw_libssh2_sftp_status(LIBSSH2_SFTP *sftp) { return libssh2_sftp_last_error(sftp); }
int zw_libssh2_sftp_mkdir(LIBSSH2_SFTP *sftp, const char *path) {
    return libssh2_sftp_mkdir_ex(sftp, path, (unsigned int)strlen(path), 0755);
}

void zw_libssh2_session_disconnect_free(LIBSSH2_SESSION *session) {
    if (!session) return;
    libssh2_session_disconnect(session, "ZeroWork session closed");
    libssh2_session_free(session);
}
