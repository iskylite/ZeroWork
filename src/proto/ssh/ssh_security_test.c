/* Exercise the actual vendored parsers with malformed already-received
   responses. No network, credentials or subprocesses. */
#include "libssh2_priv.h"
#include "libssh2_sftp.h"
#include "sftp.h"
#include "transport.h"
#include <assert.h>
#include <stdio.h>

static void sftp_name(size_t payload, uint32_t claimed, int expected) {
    LIBSSH2_SESSION *session = libssh2_session_init();
    assert(session);
    session->socket_state = LIBSSH2_SOCKET_CONNECTED;
    libssh2_session_set_blocking(session, 0);
    LIBSSH2_CHANNEL channel = {0}; channel.session = session;
    LIBSSH2_SFTP sftp = {0}; sftp.channel = &channel;
    sftp.symlink_state = libssh2_NB_state_sent;
    sftp.symlink_request_id = 42;
    LIBSSH2_SFTP_PACKET *packet = calloc(1, sizeof(*packet));
    packet->data_len = 13 + payload;
    packet->data = calloc(1, packet->data_len);
    packet->request_id = 42;
    packet->data[0] = 104; /* SSH_FXP_NAME */
    _libssh2_htonu32(packet->data + 1, 42);
    _libssh2_htonu32(packet->data + 5, 1);
    _libssh2_htonu32(packet->data + 9, claimed);
    if (payload) memset(packet->data + 13, 'a', payload);
    _libssh2_list_add(&sftp.packets, &packet->node);
    char target[4096]; memset(target, '!', sizeof(target));
    int rc = libssh2_sftp_realpath(&sftp, ".", target, sizeof(target));
    assert(rc == expected);
    if (expected < 0) assert(target[0] == '!');
    else { assert(target[expected] == 0); assert(target[0] == 'a'); }
    session->socket_state = LIBSSH2_SOCKET_DISCONNECTED;
    assert(libssh2_session_free(session) == 0);
}
static int oversized_length(LIBSSH2_SESSION *session, unsigned int seq,
    unsigned char *data, size_t size, unsigned int *len, void **abstract) {
    (void)session; (void)seq; (void)data; (void)size; (void)abstract;
    *len = 0xfffffff0U;
    return 0;
}
static void encrypted_length(void) {
    LIBSSH2_SESSION *session = libssh2_session_init(); assert(session);
    LIBSSH2_CRYPT_METHOD method = {0};
    method.blocksize = 8; method.auth_len = 16;
    method.flags = LIBSSH2_CRYPT_FLAG_REQUIRES_FULL_PACKET;
    method.get_len = oversized_length;
    session->remote.crypt = &method;
    session->state = LIBSSH2_STATE_NEWKEYS;
    session->socket_state = LIBSSH2_SOCKET_CONNECTED;
    session->packet.writeidx = 8;
    memset(session->packet.buf, 0, 8);
    assert(_libssh2_transport_read(session) == LIBSSH2_ERROR_OUT_OF_BOUNDARY);
    assert(session->packet.payload == NULL);
    session->remote.crypt = NULL; session->state = 0;
    session->socket_state = LIBSSH2_SOCKET_DISCONNECTED;
    assert(libssh2_session_free(session) == 0);
}
static void cbc_packet_padding(void) {
    _libssh2_cipher_ctx encrypt, decrypt;
    /* NIST SP 800-38A F.2.1: an independent expected ciphertext catches
       swapped encrypt/decrypt directions that a roundtrip alone misses. */
    unsigned char key[16] = {0x2b,0x7e,0x15,0x16,0x28,0xae,0xd2,0xa6,0xab,0xf7,0x15,0x88,0x09,0xcf,0x4f,0x3c};
    unsigned char iv[16] = {0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15};
    const unsigned char original[32] = {0x6b,0xc1,0xbe,0xe2,0x2e,0x40,0x9f,0x96,0xe9,0x3d,0x7e,0x11,0x73,0x93,0x17,0x2a,0xae,0x2d,0x8a,0x57,0x1e,0x03,0xac,0x9c,0x9e,0xb7,0x6f,0xac,0x45,0xaf,0x8e,0x51};
    const unsigned char expected[32] = {0x76,0x49,0xab,0xac,0x81,0x19,0xb2,0x46,0xce,0xe9,0x8e,0x9b,0x12,0xe9,0x19,0x7d,0x50,0x86,0xcb,0x9b,0x50,0x72,0x19,0xee,0x95,0xdb,0x11,0x3a,0x91,0x76,0x78,0xb2};
    unsigned char bytes[33]; memcpy(bytes, original, 32); bytes[32] = 0x5a;
    assert(_libssh2_cipher_init(&encrypt, _libssh2_cipher_aes128, iv, key, 1) == 0);
    assert(_libssh2_cipher_init(&decrypt, _libssh2_cipher_aes128, iv, key, 0) == 0);
    for (int i = 0; i < 2; ++i)
        assert(_libssh2_cipher_crypt(&encrypt, _libssh2_cipher_aes128, 1, bytes + i*16, 16, 0) == 0);
    assert(memcmp(bytes, expected, 32) == 0 && bytes[32] == 0x5a);
    for (int i = 0; i < 2; ++i)
        assert(_libssh2_cipher_crypt(&decrypt, _libssh2_cipher_aes128, 0, bytes + i*16, 16, 0) == 0);
    assert(memcmp(bytes, original, 32) == 0 && bytes[32] == 0x5a);
    _libssh2_cipher_dtor(&encrypt); _libssh2_cipher_dtor(&decrypt);
}
/* A peer can keep sibling channels busy while withholding one CLOSE.
   Feed an endless sequence of valid IGNORE packets through the real parser. */
static unsigned int close_reads;
static LIBSSH2_RECV_FUNC(busy_sibling_recv) {
    (void)socket; (void)flags; (void)abstract;
    static const unsigned char ignore[16] = {0,0,0,12,6,2,0,0,0,0,0,0,0,0,0,0};
    assert(length >= sizeof(ignore));
    memcpy(buffer, ignore, sizeof(ignore));
    ++close_reads;
    assert(close_reads <= 64); /* fails rather than hanging without the budget */
    return sizeof(ignore);
}
extern int zw_libssh2_channel_write_pending(LIBSSH2_CHANNEL *channel);
static void bounded_channel_close(void) {
    LIBSSH2_SESSION *session = libssh2_session_init(); assert(session);
    libssh2_session_set_blocking(session, 0);
    session->socket_state = LIBSSH2_SOCKET_CONNECTED;
    session->recv = busy_sibling_recv;
    LIBSSH2_CHANNEL channel = {0}; channel.session = session;
    channel.remote.window_size = channel.remote.window_size_initial = 4096;
    char byte;
    close_reads = 0;
    assert(libssh2_channel_read(&channel, &byte, 1) == LIBSSH2_ERROR_EAGAIN);
    assert(close_reads == 32);
    close_reads = 0;
    assert(libssh2_channel_write(&channel, "x", 1) == LIBSSH2_ERROR_EAGAIN);
    assert(close_reads == 32);
    assert(zw_libssh2_channel_write_pending(&channel) == 0);
    channel.write_state = libssh2_NB_state_created;
    assert(zw_libssh2_channel_write_pending(&channel) == 1);
    channel.write_state = libssh2_NB_state_idle;
    LIBSSH2_LISTENER listener = {0}; listener.session = session;
    close_reads = 0;
    assert(libssh2_channel_forward_accept(&listener) == NULL);
    assert(libssh2_session_last_errno(session) == LIBSSH2_ERROR_EAGAIN);
    assert(close_reads == 32);
    channel.local.eof = 1;
    channel.close_state = libssh2_NB_state_sent;
    close_reads = 0;
    assert(libssh2_channel_close(&channel) == LIBSSH2_ERROR_EAGAIN);
    assert(close_reads > 0 && close_reads <= 32);
    assert(!channel.local.close && channel.close_state == libssh2_NB_state_sent);
    channel.remote.close = 1;
    assert(libssh2_channel_close(&channel) == 0);
    session->socket_state = LIBSSH2_SOCKET_DISCONNECTED;
    assert(libssh2_session_free(session) == 0);
}
int main(void) {
    assert(libssh2_init(0) == 0);
    sftp_name(1, 2048, LIBSSH2_ERROR_SFTP_PROTOCOL);
    sftp_name(0, 0xffffffffU, LIBSSH2_ERROR_SFTP_PROTOCOL);
    sftp_name(3, 3, 3);
    encrypted_length();
    cbc_packet_padding();
    bounded_channel_close();
    libssh2_exit();
    puts("PASS SFTP malformed lengths rejected, valid response accepted; encrypted oversize rejected before allocation; CBC packet padding/roundtrip; bounded channel read/write/accept/close");
}
