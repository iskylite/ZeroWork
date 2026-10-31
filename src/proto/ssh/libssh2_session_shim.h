#ifndef ZEROWORK_LIBSSH2_SESSION_SHIM_H
#define ZEROWORK_LIBSSH2_SESSION_SHIM_H
#include "libssh2_channel_shim.h"

typedef struct _LIBSSH2_SESSION LIBSSH2_SESSION;

int zw_libssh2_library_init(void);
void zw_libssh2_library_exit(void);
int zw_ssh_socket_connect(const char *host, unsigned short port, unsigned int timeout_ms);
/* Borrowed callback/context stay valid only for this synchronous call. */
typedef int (*zw_ssh_cancel_cb)(void *ctx);
/* Synchronous owned-worker driver. All fields are borrowed for one call. */
typedef struct {
    int socket_fd;
    unsigned int timeout_ms;
    /* Optional shared monotonic deadline; human prompts extend it. */
    long long *deadline_ms;
    zw_ssh_cancel_cb cancelled;
    void *ctx;
} ZW_SSH_DRIVE;
#define ZW_SSH_CANCELLED (-1001)
#define ZW_SSH_WAIT_FAILED (-1002)
#define ZW_SSH_TIMED_OUT (-9)
int zw_ssh_socket_connect_cancellable(const char *host, unsigned short port,
    unsigned int timeout_ms, zw_ssh_cancel_cb cancelled, void *ctx);
int zw_ssh_socket_last_error(void);
int zw_ssh_socket_last_gai_error(void);
long long zw_ssh_monotonic_ms(void);
void zw_ssh_socket_close(int socket_fd);
void zw_ssh_socket_interrupt(int socket_fd);
/* Consumes the descriptor only on 0. A failure must not be blindly retried:
   close(EINTR) can leave its numeric descriptor available for reuse. */
int zw_ssh_socket_release(int socket_fd);
int zw_ssh_socket_set_blocking(int socket_fd);
int zw_ssh_socket_set_nonblocking(int socket_fd);
/* Both endpoints are nonblocking and owned by the caller. */
int zw_ssh_socketpair(int *target_fd, int *relay_fd);
typedef struct zw_ssh_relay ZW_SSH_RELAY;
/* Borrows the channel, consumes relay_fd. Only one thread may use its session. */
ZW_SSH_RELAY *zw_ssh_relay_create(int relay_fd, LIBSSH2_CHANNEL *channel);
/* 0 running, 1 gracefully finished, -1 failed. Preserves partial writes. */
int zw_ssh_relay_step(ZW_SSH_RELAY *relay);
/* Propagate a stopped upstream owner to the downstream Session without
   recycling its socketpair descriptor; destroy remains the final closer. */
void zw_ssh_relay_interrupt(ZW_SSH_RELAY *relay);
void zw_ssh_relay_destroy(ZW_SSH_RELAY *relay);
void zw_ssh_relay_pause(void);
void zw_ssh_relay_wait(ZW_SSH_RELAY *relay, int transport_fd, LIBSSH2_SESSION *session, int timeout_ms);
LIBSSH2_SESSION *zw_libssh2_session_create(void);
int zw_libssh2_session_handshake(LIBSSH2_SESSION *session, int socket_fd);
int zw_libssh2_session_handshake_driven(LIBSSH2_SESSION *session, const ZW_SSH_DRIVE *drive);
/* Handshake-only transport metadata. No banner, packet or credential bytes
   are retained. Callback codes preserve libssh2's negative-errno convention. */
typedef struct {
    long long recv_code, send_code;
    int recv_errno, send_errno;
    unsigned long long received_bytes, sent_bytes;
    unsigned long long identification_bytes, identification_hash;
    int identification_complete, socket_flags;
    unsigned short peer_port, local_port;
    char peer_address[64];
} ZW_SSH_HANDSHAKE_DIAGNOSTIC;
int zw_libssh2_session_handshake_observed(LIBSSH2_SESSION *session,
    const ZW_SSH_DRIVE *drive, ZW_SSH_HANDSHAKE_DIAGNOSTIC *diagnostic);
/// Writes the negotiated host-key algorithm and SHA256 fingerprint. The
/// fingerprint is returned as `SHA256:<base64>` (RFC 4716/OpenSSH form).
/// Returns 0 on success and -1 when libssh2 has no host key/hash available or
/// the destination buffers are too small.
int zw_libssh2_session_hostkey_fingerprint(LIBSSH2_SESSION *session,
                                            char *algorithm, size_t algorithm_len,
                                            char *fingerprint, size_t fingerprint_len);
/* Borrowed until the Session is freed; caller copies before publishing. */
const unsigned char *zw_libssh2_session_hostkey_raw(LIBSSH2_SESSION *session, size_t *length);
typedef struct _LIBSSH2_KNOWNHOSTS LIBSSH2_KNOWNHOSTS;
LIBSSH2_KNOWNHOSTS *zw_ssh_knownhosts_create(LIBSSH2_SESSION *session);
void zw_ssh_knownhosts_free(LIBSSH2_KNOWNHOSTS *hosts);
int zw_ssh_knownhosts_add_raw(LIBSSH2_KNOWNHOSTS *hosts, const char *host,
    const char *salt, const char *algorithm, const unsigned char *key, size_t length);
/* Exact canonical endpoint only; deliberately no checkp bare-host fallback. */
int zw_ssh_knownhosts_check(LIBSSH2_KNOWNHOSTS *hosts, const char *endpoint,
    const unsigned char *key, size_t length);
int zw_ssh_knownhosts_write(LIBSSH2_KNOWNHOSTS *hosts, char *output, size_t capacity, size_t *length);
int zw_libssh2_auth_password(LIBSSH2_SESSION *session, const char *user, const char *password);
int zw_libssh2_auth_agent(LIBSSH2_SESSION *session, const char *user);
/* 1 authenticated, 0 complete server failure/method list, -1 invalid/local error. */
int zw_libssh2_auth_methods(LIBSSH2_SESSION *session, const char *user, char *methods, size_t capacity, size_t *length);
int zw_libssh2_auth_result(LIBSSH2_SESSION *session, int *partial, char *methods, size_t capacity, size_t *length);
typedef int (*zw_ssh_kbd_prompt_cb)(void *ctx, const char *prompt, size_t prompt_len, char *answer, size_t answer_cap);
int zw_libssh2_auth_keyboard_interactive(LIBSSH2_SESSION *session, const char *user, zw_ssh_kbd_prompt_cb callback, void *ctx);
typedef struct { const char *text; size_t length; int echo; } ZW_SSH_AUTH_PROMPT;
typedef struct { char *text; size_t capacity; size_t length; } ZW_SSH_AUTH_RESPONSE;
/* One callback receives the complete ordered prompt group, including echo. */
typedef int (*zw_ssh_auth_prompts_cb)(void *ctx, const ZW_SSH_AUTH_PROMPT *prompts, size_t count, ZW_SSH_AUTH_RESPONSE *responses);
int zw_libssh2_auth_keyboard_interactive_batch(LIBSSH2_SESSION *session, const char *user, zw_ssh_auth_prompts_cb callback, void *ctx);
int zw_libssh2_last_error_code(LIBSSH2_SESSION *session);
int zw_libssh2_transport_failed(LIBSSH2_SESSION *session);
const char *zw_libssh2_last_error(LIBSSH2_SESSION *session);
int zw_libssh2_auth_private_key(LIBSSH2_SESSION *session, const char *user, const char *private_key_path, const char *passphrase);
int zw_libssh2_auth_methods_driven(LIBSSH2_SESSION *session, const char *user, char *methods, size_t capacity, size_t *length, const ZW_SSH_DRIVE *drive);
int zw_libssh2_auth_password_driven(LIBSSH2_SESSION *session, const char *user, const char *password, const ZW_SSH_DRIVE *drive);
int zw_libssh2_auth_private_key_driven(LIBSSH2_SESSION *session, const char *user, const char *path, const char *passphrase, const ZW_SSH_DRIVE *drive);
int zw_libssh2_auth_agent_driven(LIBSSH2_SESSION *session, const char *user, const ZW_SSH_DRIVE *drive);
int zw_libssh2_auth_keyboard_interactive_batch_driven(LIBSSH2_SESSION *session, const char *user, zw_ssh_auth_prompts_cb callback, void *ctx, const ZW_SSH_DRIVE *drive);
/* A partially created channel remains owned by its Session on failure. */
int zw_libssh2_open_shell_driven(LIBSSH2_SESSION *session, const char *term, int cols, int rows, LIBSSH2_CHANNEL **channel, const ZW_SSH_DRIVE *drive);
/* New owned channel startup, never an exec request on an existing shell. */
int zw_libssh2_open_bootstrap_driven(LIBSSH2_SESSION *session, const char *command, const char *term, int cols, int rows, LIBSSH2_CHANNEL **channel, const ZW_SSH_DRIVE *drive);
int zw_ssh_private_key_readable(const char *path);
LIBSSH2_CHANNEL *zw_libssh2_open_shell(LIBSSH2_SESSION *session, const char *term, int cols, int rows);
int zw_libssh2_open_direct_tcpip_driven(LIBSSH2_SESSION *session, const char *host, unsigned short port, LIBSSH2_CHANNEL **output, const ZW_SSH_DRIVE *drive);
LIBSSH2_CHANNEL *zw_libssh2_open_direct_tcpip(LIBSSH2_SESSION *session, const char *host, unsigned short port);
/* Per-request native open state. Pending replies must not block unrelated
   forwarding targets. Only the Session IO owner calls these functions. */
typedef struct zw_ssh_direct_open ZW_SSH_DIRECT_OPEN;
int zw_libssh2_direct_open_step(LIBSSH2_SESSION *session,
    ZW_SSH_DIRECT_OPEN **all, ZW_SSH_DIRECT_OPEN **operation,
    const char *host, unsigned short port, LIBSSH2_CHANNEL **channel);
/* After native Session release only: frees retained request buffers without
   dereferencing any channel or the released Session. */
void zw_libssh2_direct_open_released(ZW_SSH_DIRECT_OPEN **all);
LIBSSH2_CHANNEL *zw_libssh2_open_exec(LIBSSH2_SESSION *session, const char *command);
/* Single nonblocking remote forwarding operations. Listener stays owned until
   cancel returns 0 or the owning Session release receipt is complete. */
typedef struct _LIBSSH2_LISTENER LIBSSH2_LISTENER;
LIBSSH2_LISTENER *zw_libssh2_forward_listen(LIBSSH2_SESSION *session, const char *host, unsigned short port, int *bound_port, int queue_max);
LIBSSH2_CHANNEL *zw_libssh2_forward_accept(LIBSSH2_LISTENER *listener);
int zw_libssh2_forward_cancel(LIBSSH2_LISTENER *listener);
/* Fixed remote-forward target: numeric IPv4/IPv6 or localhost, no blocking DNS
   on the PTY owner. fd is nonblocking; ready returns 0 pending/1 ready/-1 fail. */
int zw_ssh_forward_target_valid(const char *host);
int zw_ssh_forward_connect(const char *host, unsigned short port);
int zw_ssh_forward_connect_ready(int fd);

/* Single nonblocking steps: 0 success, 1 EAGAIN, negative native failure.
   Retain the same channel/command across retries. One channel-open per Session. */
int zw_libssh2_exec_channel_open_step(LIBSSH2_SESSION *session, LIBSSH2_CHANNEL **channel);
int zw_libssh2_session_channel_open_step(LIBSSH2_SESSION *session, LIBSSH2_CHANNEL **channel);
int zw_libssh2_exec_request_step(LIBSSH2_CHANNEL *channel, const char *command);
long zw_libssh2_channel_read_stderr(LIBSSH2_CHANNEL *channel, unsigned char *buffer, size_t len);
int zw_libssh2_channel_eof(LIBSSH2_CHANNEL *channel);
int zw_libssh2_channel_exit_status(LIBSSH2_CHANNEL *channel);
void zw_libssh2_session_set_timeout(LIBSSH2_SESSION *session, long timeout_ms);
void zw_libssh2_session_config_keepalive(LIBSSH2_SESSION *session, unsigned int interval_sec);
int zw_libssh2_session_send_keepalive(LIBSSH2_SESSION *session);
unsigned long zw_libssh2_session_received_packets(LIBSSH2_SESSION *session);
int zw_libssh2_session_set_compression(LIBSSH2_SESSION *session, int enabled);
void zw_libssh2_session_nonblocking(LIBSSH2_SESSION *session);
void zw_libssh2_session_set_blocking(LIBSSH2_SESSION *session);
int zw_libssh2_session_prefer_stream_ciphers(LIBSSH2_SESSION *session);
int zw_libssh2_session_prefer_rsa_sha2(LIBSSH2_SESSION *session);
const char *zw_libssh2_session_cipher_sc(LIBSSH2_SESSION *session);
const char *zw_libssh2_session_cipher_cs(LIBSSH2_SESSION *session);
const char *zw_libssh2_session_hostkey_method(LIBSSH2_SESSION *session);
int zw_libssh2_session_last_error(LIBSSH2_SESSION *session);
void zw_libssh2_channel_close_free(LIBSSH2_CHANNEL *channel);
void zw_libssh2_session_disconnect_free(LIBSSH2_SESSION *session);
/* Release receipts: 0 = native free completed, 1 = EAGAIN (still owned),
   -1 = unknown (still owned). No channel-only helper interrupts its Session. */
int zw_libssh2_channel_release(LIBSSH2_CHANNEL *channel);
/* True only once a native channel write owns its retry arguments. */
int zw_libssh2_channel_write_pending(LIBSSH2_CHANNEL *channel);
int zw_libssh2_session_release(LIBSSH2_SESSION *session);
/* Final whole-Session release only. Does not close/recycle the owned fd. */
void zw_libssh2_session_abort_io(LIBSSH2_SESSION *session, int socket_fd);
typedef struct _LIBSSH2_SFTP LIBSSH2_SFTP;
typedef struct _LIBSSH2_SFTP_HANDLE LIBSSH2_SFTP_HANDLE;
LIBSSH2_SFTP *zw_libssh2_sftp_init(LIBSSH2_SESSION *session);
LIBSSH2_SFTP_HANDLE *zw_libssh2_sftp_open_write(LIBSSH2_SFTP *sftp, const char *path);
LIBSSH2_SFTP_HANDLE *zw_libssh2_sftp_open_exclusive(LIBSSH2_SFTP *sftp, const char *path);
int zw_libssh2_sftp_truncate(LIBSSH2_SFTP_HANDLE *handle, unsigned long long size);
LIBSSH2_SFTP_HANDLE *zw_libssh2_sftp_open_append(LIBSSH2_SFTP *sftp, const char *path, unsigned long long offset);
LIBSSH2_SFTP_HANDLE *zw_libssh2_sftp_open_read(LIBSSH2_SFTP *sftp, const char *path);
long zw_libssh2_sftp_read(LIBSSH2_SFTP_HANDLE *handle, unsigned char *buffer, size_t len);
long zw_libssh2_sftp_write(LIBSSH2_SFTP_HANDLE *handle, const unsigned char *buffer, size_t len);
long long zw_libssh2_sftp_size(LIBSSH2_SFTP *sftp, const char *path);
int zw_libssh2_sftp_close(LIBSSH2_SFTP_HANDLE *handle);
void zw_libssh2_sftp_shutdown(LIBSSH2_SFTP *sftp);
int zw_libssh2_sftp_release(LIBSSH2_SFTP *sftp);
/* Read-only, single nonblocking operations. EAGAIN is -37: retry the same
   operation with unchanged buffers/arguments on its owning IO thread. */
typedef struct {
    unsigned long long flags, size, permissions, mtime;
} ZW_SFTP_ATTRIBUTES;
int zw_libssh2_sftp_realpath(LIBSSH2_SFTP *sftp, const char *path, char *output, size_t capacity);
LIBSSH2_SFTP_HANDLE *zw_libssh2_sftp_opendir(LIBSSH2_SFTP *sftp, const char *path);
long zw_libssh2_sftp_readdir(LIBSSH2_SFTP_HANDLE *handle, char *name, size_t capacity, ZW_SFTP_ATTRIBUTES *attrs);
int zw_libssh2_sftp_stat_attributes(LIBSSH2_SFTP *sftp, const char *path, int follow, ZW_SFTP_ATTRIBUTES *attrs);
int zw_libssh2_sftp_mkdir(LIBSSH2_SFTP *sftp, const char *path);
int zw_libssh2_sftp_mkdir_private(LIBSSH2_SFTP *sftp, const char *path);
LIBSSH2_SFTP_HANDLE *zw_libssh2_sftp_open_private(LIBSSH2_SFTP *sftp, const char *path, unsigned int mode);
int zw_libssh2_sftp_unlink_owned(LIBSSH2_SFTP *sftp, const char *path);
int zw_libssh2_sftp_rmdir_owned(LIBSSH2_SFTP *sftp, const char *path);
int zw_libssh2_sftp_fstat_attributes(LIBSSH2_SFTP_HANDLE *handle, ZW_SFTP_ATTRIBUTES *attrs);
unsigned long zw_libssh2_sftp_status(LIBSSH2_SFTP *sftp);
#endif

int zw_libssh2_shared_shell_step(LIBSSH2_SESSION *session, const char *term, int cols, int rows, LIBSSH2_CHANNEL **channel, int *phase);
int zw_libssh2_shared_bootstrap_step(LIBSSH2_SESSION *session, const char *command, const char *term, int cols, int rows, LIBSSH2_CHANNEL **channel, int *phase);
int zw_libssh2_shared_shell_cancel_step(LIBSSH2_SESSION *session, LIBSSH2_CHANNEL **channel, int *phase);
