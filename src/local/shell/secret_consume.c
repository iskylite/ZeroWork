/* Explicit zsh 5.9 native secret sink. boot_ is the public module ABI already
 * used by zw_execution. It never exposes plaintext through a shell parameter,
 * terminal output, digest, log or child. Its sole declared operation is consume
 * and erase; it does not claim to submit a password to an arbitrary program. */
#include <sys/types.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <poll.h>
#include <unistd.h>
#include <errno.h>
#include <stdint.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <time.h>
#include <limits.h>
#include <fcntl.h>
#include <signal.h>
extern long long getiparam(char *);
extern char *getsparam(char *);
extern void setiparam(char *, long long);
static volatile sig_atomic_t interrupted = 0;
static void defer_interrupt(int signal_number) { interrupted = signal_number; }
static void wipe(void *p, size_t n) { volatile unsigned char *v = p; while (n--) *v++ = 0; }
static int64_t now_ms(void) {
    struct timespec value;
    if (clock_gettime(CLOCK_MONOTONIC, &value)) return -1;
    return (int64_t)value.tv_sec * 1000 + value.tv_nsec / 1000000;
}
static int wait_fd(int fd, short events, int64_t deadline) {
    for (;;) {
        int64_t now = now_ms();
        if (interrupted || now < 0 || now >= deadline) return -1;
        struct pollfd p = { .fd = fd, .events = events };
        int result = poll(&p, 1, (int)((deadline - now) > 100 ? 100 : deadline - now));
        if (result < 0 && errno == EINTR) continue;
        if (result < 0 || (result > 0 && (p.revents & (POLLERR | POLLNVAL | POLLHUP)))) return -1;
        if (result > 0 && (p.revents & events)) return 0;
    }
}
static int transfer(int fd, unsigned char *p, size_t n, int writing, int64_t deadline) {
    while (n) {
        if (interrupted) return -1;
        ssize_t count = writing ? send(fd, p, n, MSG_NOSIGNAL) : read(fd, p, n);
        if (count > 0) { p += count; n -= (size_t)count; continue; }
        if (count == 0 || (errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR)) return -1;
        if (wait_fd(fd, writing ? POLLOUT : POLLIN, deadline)) return -1;
    }
    return 0;
}
struct field { unsigned char *p; size_t n; };
static int decimal(struct field f, uint64_t *out) {
    uint64_t value = 0;
    if (!f.n || f.n > 20 || (f.n > 1 && f.p[0] == '0')) return -1;
    for (size_t i = 0; i < f.n; ++i) {
        if (f.p[i] < '0' || f.p[i] > '9' || value > (UINT64_MAX - (f.p[i] - '0')) / 10) return -1;
        value = value * 10 + f.p[i] - '0';
    }
    *out = value;
    return 0;
}
static int equal(struct field f, const char *s) { return f.n == strlen(s) && !memcmp(f.p, s, f.n); }
static int decode(unsigned char *body, size_t n, struct field *fields, size_t *count) {
    size_t position = 0, index = 0;
    while (position < n) {
        size_t start = position;
        while (position < n && body[position] >= '0' && body[position] <= '9') ++position;
        if (index == 16 || position == start || position >= n || body[position] != ':') return -1;
        uint64_t length = 0;
        if (decimal((struct field){body + start, position - start}, &length) || length > 8192) return -1;
        ++position;
        if (length >= n - position || body[position + (size_t)length] != ',') return -1;
        fields[index++] = (struct field){body + position, (size_t)length};
        position += (size_t)length + 1;
    }
    *count = index;
    return 0;
}
static int append(unsigned char *body, size_t *n, const char *text) {
    size_t length = strlen(text);
    if (*n + length + 24 > 2048) return -1;
    int prefix = snprintf((char *)body + *n, 2048 - *n, "%zu:", length);
    if (prefix < 0) return -1;
    *n += (size_t)prefix;
    memcpy(body + *n, text, length); *n += length; body[(*n)++] = ',';
    return 0;
}
static int emit(int fd, const char **fields, size_t count, int64_t deadline) {
    unsigned char body[2048], frame[2056];
    size_t n = 0;
    int result = -1;
    long long sequence = getiparam("_zw_exec_sequence");
    if (sequence < 0 || sequence == LLONG_MAX) goto done;
    char session[24], generation[24], serial[24];
    snprintf(session, sizeof(session), "%lld", getiparam("_zw_session"));
    snprintf(generation, sizeof(generation), "%lld", getiparam("_zw_generation"));
    snprintf(serial, sizeof(serial), "%lld", sequence + 1);
    char *nonce = getsparam("_zw_nonce");
    if (!nonce || strlen(nonce) != 32) goto done;
    const char *envelope[] = {"1", session, generation, nonce, serial};
    for (size_t i = 0; i < 5; ++i) if (append(body, &n, envelope[i])) goto done;
    for (size_t i = 0; i < count; ++i) if (append(body, &n, fields[i])) goto done;
    snprintf((char *)frame, 9, "%08x", (unsigned)n);
    memcpy(frame + 8, body, n);
    setiparam("_zw_exec_sequence", sequence + 1);
    result = transfer(fd, frame, n + 8, 1, deadline);
done:
    wipe(body, sizeof(body)); wipe(frame, sizeof(frame));
    return result;
}
int setup_(void *module) { (void)module; return 0; }
int features_(void *module, char ***features) { (void)module; (void)features; return 1; }
int enables_(void *module, int **enables) { (void)module; (void)enables; return 1; }
int boot_(void *module) {
    (void)module;
    /* zsh can unwind an interrupted builtin. Defer its handlers until the
     * buffers are erased. Termination signals still interrupt the bounded IO
     * immediately; they are re-raised with the original handlers after cleanup.
     * Other catchable signals (including resize/job traps) remain pending. */
    const int termination_signals[] = {SIGINT, SIGQUIT, SIGHUP, SIGTERM};
    struct sigaction original_actions[4], action;
    memset(&action, 0, sizeof(action)); action.sa_handler = defer_interrupt;
    sigfillset(&action.sa_mask);
    sigset_t previous_mask, blocked_mask;
    if (sigfillset(&blocked_mask)) return 1;
    for (size_t i = 0; i < 4; ++i) sigdelset(&blocked_mask, termination_signals[i]);
    if (sigprocmask(SIG_SETMASK, &blocked_mask, &previous_mask)) return 1;
    interrupted = 0;
    size_t installed = 0;
    for (; installed < 4; ++installed) if (sigaction(termination_signals[installed], &action, &original_actions[installed])) break;
    if (installed != 4) {
        while (installed) { --installed; (void)sigaction(termination_signals[installed], &original_actions[installed], NULL); }
        (void)sigprocmask(SIG_SETMASK, &previous_mask, NULL);
        return 1;
    }
    unsigned char body[8192], header[8];
    struct field fields[16];
    int result = 1, fd = -1;
    long long raw_fd = getiparam("_zw_exec_fd"), parent = getiparam("_zw_parent");
    char *id_value = getsparam("_zw_exec_id"), *stage = getsparam("_zw_exec_stage");
    char *queued = getsparam("_zw_exec_tx"), *buffered = getsparam("_zw_exec_rx");
    char id[33], fence[24], epoch[24], wait_sequence[24];
    long long fence_value = getiparam("_zw_exec_fence"), epoch_value = getiparam("_zw_exec_epoch"), wait_value = getiparam("_zw_read_sequence");
    setiparam("_zw_secret_result", 1);
    if ((queued && *queued) || (buffered && *buffered) || raw_fd < 3 || raw_fd > INT_MAX || parent < 1 || !id_value || strlen(id_value) != 32 || !stage || strcmp(stage, "running") || fence_value <= 0 || epoch_value < 0 || wait_value <= 0) goto done;
    for (size_t i = 0; i < 32; ++i) if (!((id_value[i] >= '0' && id_value[i] <= '9') || (id_value[i] >= 'a' && id_value[i] <= 'f'))) goto done;
    memcpy(id, id_value, 33);
    snprintf(fence, sizeof(fence), "%lld", fence_value);
    snprintf(epoch, sizeof(epoch), "%lld", epoch_value);
    snprintf(wait_sequence, sizeof(wait_sequence), "%lld", wait_value);
    /* This socket is created only after entering the fixed native consumer.
     * Earlier forked children cannot inherit its descriptor. */
    char *execution_path = getsparam("_zw_exec_socket");
    struct sockaddr_un address = { .sun_family = AF_UNIX };
    if (!execution_path || snprintf(address.sun_path, sizeof(address.sun_path), "%s-secret", execution_path) >= (int)sizeof(address.sun_path)) goto done;
    fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0 || fcntl(fd, F_SETFD, FD_CLOEXEC) || connect(fd, (struct sockaddr *)&address, sizeof(address))) goto done;
    int options = fcntl(fd, F_GETFL);
    if (options < 0 || fcntl(fd, F_SETFL, options | O_NONBLOCK)) goto done;
    int type = 0; socklen_t length = sizeof(type), peer_length = sizeof(pid_t);
    uid_t uid; gid_t gid; pid_t peer = -1;
    if (getsockopt(fd, SOL_SOCKET, SO_TYPE, &type, &length) || type != SOCK_STREAM || getpeereid(fd, &uid, &gid) || uid != getuid() || getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &peer, &peer_length) || peer != parent) goto done;
    int64_t deadline = now_ms();
    if (deadline < 0) goto done;
    deadline += 90000;
    const char *waiting[] = {"input_wait", id, fence, epoch, wait_sequence, "host_secret", "4096"};
    if (emit(fd, waiting, 7, deadline)) goto broken;
    for (;;) {
        if (transfer(fd, header, 8, 0, deadline)) goto broken;
        size_t length_ = 0;
        for (size_t i = 0; i < 8; ++i) {
            unsigned char c = header[i];
            unsigned digit = c >= '0' && c <= '9' ? c - '0' : c >= 'a' && c <= 'f' ? c - 'a' + 10 : 16;
            if (digit == 16 || length_ > 8192 / 16) goto broken;
            length_ = length_ * 16 + digit;
        }
        if (!length_ || length_ > sizeof(body) || transfer(fd, body, length_, 0, deadline)) goto broken;
        size_t count = 0;
        uint64_t session = 0, generation = 0, serial = 0;
        char *nonce = getsparam("_zw_nonce");
        if (decode(body, length_, fields, &count) || count < 9 || !equal(fields[0], "1") || decimal(fields[1], &session) || session != (uint64_t)getiparam("_zw_session") || decimal(fields[2], &generation) || generation != (uint64_t)getiparam("_zw_generation") || !nonce || !equal(fields[3], nonce) || decimal(fields[4], &serial) || serial > LLONG_MAX || serial <= (uint64_t)getiparam("_zw_exec_received") || !equal(fields[6], id) || !equal(fields[7], fence) || !equal(fields[8], epoch)) goto broken;
        setiparam("_zw_exec_received", (long long)serial);
        if (equal(fields[5], "input_release") && count == 9) { result = 0; goto done; }
        if (count < 11 || !equal(fields[9], wait_sequence)) goto broken;
        uint64_t input_sequence = 0;
        if (decimal(fields[10], &input_sequence) || !input_sequence || input_sequence > LLONG_MAX) goto broken;
        if (equal(fields[5], "secret_cancel") && count == 11) { result = 0; goto done; }
        if (!equal(fields[5], "secret") || count != 12 || !fields[11].n || fields[11].n > 4096) goto broken;
        char input[24]; snprintf(input, sizeof(input), "%llu", (unsigned long long)input_sequence);
        /* The fixed sink consumes exactly once. Erase every frame byte before
         * acknowledging; never copy payload to shell memory or print it. */
        wipe(body, sizeof(body)); wipe(fields, sizeof(fields));
        const char *consumed[] = {"input_consumed", id, fence, epoch, wait_sequence, input, "host_secret", "0"};
        if (emit(fd, consumed, 8, deadline)) goto broken;
        setiparam("_zw_secret_result", 0);
        result = 0;
        goto done;
    }
broken:
    if (fd >= 0) shutdown(fd, SHUT_RDWR);
done:
    wipe(body, sizeof(body)); wipe(header, sizeof(header)); wipe(fields, sizeof(fields));
    wipe(id, sizeof(id)); wipe(fence, sizeof(fence)); wipe(epoch, sizeof(epoch)); wipe(wait_sequence, sizeof(wait_sequence));
    if (fd >= 0) close(fd);
    int pending_signal = interrupted;
    for (size_t i = 0; i < 4; ++i) (void)sigaction(termination_signals[i], &original_actions[i], NULL);
    (void)sigprocmask(SIG_SETMASK, &previous_mask, NULL);
    if (pending_signal) (void)raise(pending_signal);
    return result;
}
int cleanup_(void *module) { (void)module; return 0; }
int finish_(void *module) { (void)module; return 0; }
