#include "libssh2_channel_shim.h"
#include "libssh2.h"
long zw_libssh2_channel_read(LIBSSH2_CHANNEL *channel, unsigned char *buffer, size_t len) {
    ssize_t count = libssh2_channel_read(channel, (char *)buffer, len);
    return count == LIBSSH2_ERROR_EAGAIN ? 0 : (long)count;
}
long zw_libssh2_channel_write(LIBSSH2_CHANNEL *channel, const unsigned char *buffer, size_t len) {
    ssize_t count = libssh2_channel_write(channel, (const char *)buffer, len);
    return count == LIBSSH2_ERROR_EAGAIN ? 0 : (long)count;
}
int zw_libssh2_channel_resize(LIBSSH2_CHANNEL *channel, int cols, int rows) { return libssh2_channel_request_pty_size(channel, cols, rows); }
long zw_libssh2_channel_read_stderr(LIBSSH2_CHANNEL *channel, unsigned char *buffer, size_t len) {
    ssize_t count = libssh2_channel_read_stderr(channel, (char *)buffer, len);
    return count == LIBSSH2_ERROR_EAGAIN ? 0 : (long)count;
}
int zw_libssh2_channel_eof(LIBSSH2_CHANNEL *channel) { return libssh2_channel_eof(channel); }
int zw_libssh2_channel_exit_status(LIBSSH2_CHANNEL *channel) { return libssh2_channel_get_exit_status(channel); }
extern int libssh2_channel_get_exit_status_ex(LIBSSH2_CHANNEL *channel, int *status);
int zw_libssh2_channel_exit_status_received(LIBSSH2_CHANNEL *channel, int *status) { return libssh2_channel_get_exit_status_ex(channel, status); }
int zw_libssh2_channel_close_step(LIBSSH2_CHANNEL *channel) {
    int rc = libssh2_channel_close(channel);
    return rc == LIBSSH2_ERROR_EAGAIN ? 1 : rc;
}
int zw_libssh2_channel_wait_closed_step(LIBSSH2_CHANNEL *channel) {
    int rc = libssh2_channel_wait_closed(channel);
    return rc == LIBSSH2_ERROR_EAGAIN ? 1 : rc;
}
int zw_libssh2_channel_send_interrupt(LIBSSH2_CHANNEL *channel) {
    static const char interrupt = 0x03;
    return libssh2_channel_write(channel, &interrupt, 1) == 1 ? 0 : -1;
}
