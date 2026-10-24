#include <libssh2.h>
#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <unistd.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <time.h>

static double monotonic_seconds(void) {
    struct timespec value;
    if (clock_gettime(CLOCK_MONOTONIC, &value) != 0) return 0;
    return (double)value.tv_sec + (double)value.tv_nsec / 1000000000.0;
}

static int agent_auth(LIBSSH2_SESSION *session, const char *user) {
    LIBSSH2_AGENT *agent = libssh2_agent_init(session);
    if (!agent) return -1;
    if (libssh2_agent_connect(agent) != 0 || libssh2_agent_list_identities(agent) != 0) { libssh2_agent_free(agent); return -1; }
    struct libssh2_agent_publickey *identity = NULL, *previous = NULL; int rc = -1;
    while (libssh2_agent_get_identity(agent, &identity, previous) == 0) {
        if (libssh2_agent_userauth(agent, user, identity) == 0) { rc = 0; break; } previous = identity;
    }
    libssh2_agent_disconnect(agent); libssh2_agent_free(agent); return rc;
}

int main(int argc, char **argv) {
    const char *host = argc > 1 ? argv[1] : "127.0.0.1";
    const char *user = argc > 2 ? argv[2] : "root";
    const char *credential = getenv("ZEROWORK_SSH_PASSWORD");
    const char *key = getenv("ZEROWORK_SSH_KEY");
    const char *use_agent = getenv("ZEROWORK_SSH_AGENT");
    if ((!credential || !credential[0]) && (!key || !key[0]) && (!use_agent || !use_agent[0])) return 11;
    const char *port_text = getenv("ZEROWORK_SSH_PORT");
    char *port_end = NULL;
    long port = port_text ? strtol(port_text, &port_end, 10) : 22;
    if (port < 1 || port > 65535 || (port_text && (!port_text[0] || *port_end))) return 15;
    int sock = socket(AF_INET, SOCK_STREAM, 0);
    if (sock < 0) return 2;
    struct timeval timeout = {.tv_sec = 15};
    if (setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout)) != 0 ||
        setsockopt(sock, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout)) != 0) return 2;
    struct sockaddr_in addr = {0}; addr.sin_family = AF_INET; addr.sin_port = htons((unsigned short)port);
    if (inet_pton(AF_INET, host, &addr.sin_addr) != 1 || connect(sock, (struct sockaddr *)&addr, sizeof(addr)) != 0) return 2;
    if (libssh2_init(0) != 0) return 3;
    LIBSSH2_SESSION *s = libssh2_session_init(); if (!s) return 4;
    libssh2_session_set_timeout(s, 15000);
    if (libssh2_session_handshake(s, sock) != 0) return 5;
    int auth_rc = use_agent && use_agent[0]
        ? agent_auth(s, user)
        : (key && key[0]
            ? libssh2_userauth_publickey_fromfile(s, user, NULL, key, credential)
            : libssh2_userauth_password(s, user, credential));
    if (auth_rc != 0) return 6;
    LIBSSH2_CHANNEL *ch = libssh2_channel_open_session(s); if (!ch) return 7;
    if (libssh2_channel_request_pty(ch, "xterm-256color") != 0) return 8;
    if (libssh2_channel_request_pty_size(ch, 100, 30) != 0) return 9;
    if (libssh2_channel_shell(ch) != 0) return 10;
    /* The expected output must not occur in the submitted line: PTY echo is
       not evidence that the remote shell executed our command. */
    const char command[] = "printf '\\n%s%s\\n' 'zerowork-pty-' 'ok'; exit\n";
    size_t sent = 0;
    while (sent < sizeof(command)-1) {
        ssize_t n = libssh2_channel_write(ch, command + sent, sizeof(command)-1-sent);
        if (n <= 0) return 12;
        sent += (size_t)n;
    }
    char buf[2048]; size_t used = 0;
    double deadline = monotonic_seconds() + 20;
    while (used < sizeof(buf)-1 && !libssh2_channel_eof(ch)) {
        if (monotonic_seconds() >= deadline) return 16;
        ssize_t n = libssh2_channel_read(ch, buf + used, sizeof(buf)-1-used);
        if (n > 0) used += (size_t)n;
        else if (n == LIBSSH2_ERROR_EAGAIN) continue;
        else if (n < 0) return 13;
    }
    buf[used] = 0; printf("%s\n", buf);
    int ok = strstr(buf, "\nzerowork-pty-ok\r\n") != NULL || strstr(buf, "\nzerowork-pty-ok\n") != NULL;
    libssh2_channel_free(ch); libssh2_session_disconnect(s, "done"); libssh2_session_free(s); libssh2_exit(); close(sock);
    return ok ? 0 : 14;
}
