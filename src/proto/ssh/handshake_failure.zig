const std = @import("std");

/// libssh2 error codes from the vendored include/libssh2.h.
pub fn fromCode(code: c_int) anyerror {
    return switch (code) {
        -43 => error.SshHandshakeReceiveFailed,
        -7, -3 => error.SshHandshakeSendFailed,
        -13 => error.SshHandshakeDisconnected,
        -2 => error.SshHandshakeBannerFailed,
        -5, -8, -17, -33, -51 => error.SshHandshakeNegotiationFailed,
        -9, -30 => error.SshHandshakeTimedOut,
        else => error.HandshakeFailed,
    };
}

pub fn description(err: anyerror) ?[]const u8 {
    return switch (err) {
        error.SshHandshakeReceiveFailed => "SSH 握手接收失败，请检查网络或服务端日志（详情见应用日志）",
        error.SshHandshakeSendFailed => "SSH 握手发送失败，请检查网络或服务端日志（详情见应用日志）",
        error.SshHandshakeDisconnected => "SSH 握手期间连接已断开（详情见应用日志）",
        error.SshHandshakeBannerFailed => "未能读取 SSH 服务标识，请检查目标端口（详情见应用日志）",
        error.SshHandshakeNegotiationFailed => "SSH 密钥交换或算法协商失败（详情见应用日志）",
        error.SshHandshakeTimedOut => "SSH 握手超时，请检查网络与服务端状态（详情见应用日志）",
        error.HandshakeFailed => "SSH 握手失败，尚未进行登录认证（详情见应用日志）",
        else => null,
    };
}

/// Server-provided text must not inject extra lines into the diagnostic log.
pub fn logMessage(buffer: []u8, message: []const u8) []const u8 {
    const len = @min(buffer.len, message.len);
    for (message[0..len], buffer[0..len]) |byte, *out| {
        out.* = if (byte < 0x20 or byte == 0x7f) ' ' else byte;
    }
    return buffer[0..len];
}

test "handshake diagnostics classify receive errors and preserve unknown fallback" {
    try std.testing.expectEqual(error.SshHandshakeReceiveFailed, fromCode(-43));
    try std.testing.expectEqual(error.HandshakeFailed, fromCode(-999));
    try std.testing.expect(description(fromCode(-43)) != null);
    try std.testing.expect(description(error.AuthenticationFailed) == null);
    var buffer: [8]u8 = undefined;
    try std.testing.expectEqualStrings("bad  msg", logMessage(&buffer, "bad\r\nmsg extra"));
}
