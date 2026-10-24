const Channel = @import("socks5_handshake.zig").Channel;
const SshChannel = @import("channel.zig").Channel;

/// Bridges libssh2 channel I/O into the generic streaming SOCKS5 handshake.
/// The caller owns the channel and must keep it alive for the entire handshake.
pub fn channelAdapter(channel: *SshChannel) Channel {
    return .{ .ctx = channel, .read_fn = read, .write_fn = write };
}

fn read(ctx: *anyopaque, buffer: []u8) !usize {
    const channel: *SshChannel = @ptrCast(@alignCast(ctx));
    return switch (try channel.reader().read(buffer)) {
        .bytes => |count| count,
        .eof => 0,
        .would_block => error.WouldBlock,
    };
}

fn write(ctx: *anyopaque, bytes: []const u8) !usize {
    const channel: *SshChannel = @ptrCast(@alignCast(ctx));
    return channel.writer().write(bytes);
}
