#ifndef ZEROWORK_LIBSSH2_CHANNEL_SHIM_H
#define ZEROWORK_LIBSSH2_CHANNEL_SHIM_H
#include <stddef.h>
typedef struct _LIBSSH2_CHANNEL LIBSSH2_CHANNEL;
long zw_libssh2_channel_read(LIBSSH2_CHANNEL *channel, unsigned char *buffer, size_t len);
long zw_libssh2_channel_write(LIBSSH2_CHANNEL *channel, const unsigned char *buffer, size_t len);
int zw_libssh2_channel_resize(LIBSSH2_CHANNEL *channel, int cols, int rows);
void zw_libssh2_channel_close_free(LIBSSH2_CHANNEL *channel);
int zw_libssh2_channel_release(LIBSSH2_CHANNEL *channel);
long zw_libssh2_channel_read_stderr(LIBSSH2_CHANNEL *channel, unsigned char *buffer, size_t len);
int zw_libssh2_channel_eof(LIBSSH2_CHANNEL *channel);
int zw_libssh2_channel_exit_status(LIBSSH2_CHANNEL *channel);
/* 1 = an actual exit-status packet, 0 = unknown. Query before native free. */
int zw_libssh2_channel_exit_status_received(LIBSSH2_CHANNEL *channel, int *status);
int zw_libssh2_channel_close_step(LIBSSH2_CHANNEL *channel);
/* Nonblocking receive-side close acknowledgement: do not send an early close
   before the peer has delivered its optional exit-status after EOF. */
int zw_libssh2_channel_wait_closed_step(LIBSSH2_CHANNEL *channel);
int zw_libssh2_channel_send_interrupt(LIBSSH2_CHANNEL *channel);
#endif
