//! Tunnel to the already validated numeric target. The HTTP client above this
//! layer retains the original Host, SNI and certificate name.
const std = @import("std");
pub const Proxy = @import("../platform/darwin_url_proxy.zig").Proxy;
fn readExact(reader: *std.Io.Reader, bytes: []u8) !void {
    // readSliceAll may speculatively fill the reader's extra buffer as well.
    // Taking bytes through a 1-byte buffer leaves all tunnel data in the socket.
    for (bytes) |*byte| byte.* = try reader.takeByte();
}

pub fn handshake(io: std.Io, socket: std.Io.net.Socket, proxy: Proxy, target: std.Io.net.IpAddress) !void {
    const stream: std.Io.net.Stream = .{ .socket = socket };
    // Never consume bytes past the handshake into the subsequent TLS stream.
    var read_buffer: [1]u8 = undefined;
    var reader = stream.reader(io, &read_buffer);
    var write_buffer: [1024]u8 = undefined;
    var writer = stream.writer(io, &write_buffer);
    const r = &reader.interface;
    const w = &writer.interface;
    negotiate(r, w, proxy, target) catch |err| {
        // Reader/Writer erase the underlying Io cancellation into ReadFailed /
        // WriteFailed. Preserve it so HostName.connect cannot retry another
        // destination after the cancellation has already been consumed.
        if (err == error.ReadFailed) return reader.err.?;
        if (err == error.WriteFailed) return writer.err.?;
        return err;
    };
}
fn negotiate(r: *std.Io.Reader, w: *std.Io.Writer, proxy: Proxy, target: std.Io.net.IpAddress) !void {
    if (proxy.kind == .http) {
        try w.print("CONNECT {f} HTTP/1.1\r\nHost: {f}\r\n", .{ target, target });
        if (proxy.username.len != 0 or proxy.password.len != 0) {
            if (proxy.username.len + proxy.password.len > 1024) return error.ProxyAuthenticationFailed;
            var credentials: [1025]u8 = undefined;
            const raw = try std.fmt.bufPrint(&credentials, "{s}:{s}", .{ proxy.username, proxy.password });
            try w.print("Proxy-Authorization: Basic {b64}\r\n", .{raw});
        }
        try w.writeAll("\r\n");
        try w.flush();
        var headers: [8192]u8 = undefined;
        var used: usize = 0;
        while (used < headers.len) {
            headers[used] = try r.takeByte();
            used += 1;
            if (used >= 4 and std.mem.endsWith(u8, headers[0..used], "\r\n\r\n")) break;
        } else return error.ProxyConnectionFailed;
        const line = headers[0 .. std.mem.indexOf(u8, headers[0..used], "\r\n") orelse return error.ProxyConnectionFailed];
        if (!std.mem.startsWith(u8, line, "HTTP/1.1 ") and !std.mem.startsWith(u8, line, "HTTP/1.0 ")) return error.ProxyConnectionFailed;
        if (line.len < 12) return error.ProxyConnectionFailed;
        const status = std.fmt.parseInt(u16, line[9..12], 10) catch return error.ProxyConnectionFailed;
        if (status == 407) return error.ProxyAuthenticationFailed;
        if (status < 200 or status >= 300) return error.ProxyConnectionFailed;
        return;
    }
    const authenticate = proxy.username.len != 0 or proxy.password.len != 0;
    try w.writeAll(if (authenticate) &.{ 5, 2, 0, 2 } else &.{ 5, 1, 0 });
    try w.flush();
    var greeting: [2]u8 = undefined;
    try readExact(r, &greeting);
    if (greeting[0] != 5) return error.ProxyConnectionFailed;
    if (greeting[1] == 2 and authenticate) {
        if (proxy.username.len > 255 or proxy.password.len > 255) return error.ProxyAuthenticationFailed;
        try w.writeAll(&.{ 1, @intCast(proxy.username.len) });
        try w.writeAll(proxy.username);
        try w.writeByte(@intCast(proxy.password.len));
        try w.writeAll(proxy.password);
        try w.flush();
        var auth: [2]u8 = undefined;
        try readExact(r, &auth);
        if (auth[0] != 1 or auth[1] != 0) return error.ProxyAuthenticationFailed;
    } else if (greeting[1] != 0) return error.ProxyAuthenticationFailed;
    try w.writeAll(&.{ 5, 1, 0, if (target == .ip4) @as(u8, 1) else 4 });
    switch (target) {
        inline .ip4, .ip6 => |ip| try w.writeAll(&ip.bytes),
    }
    try w.writeInt(u16, target.getPort(), .big);
    try w.flush();
    var reply: [4]u8 = undefined;
    try readExact(r, &reply);
    if (reply[0] != 5 or reply[1] != 0 or reply[2] != 0) return error.ProxyConnectionFailed;
    const length: usize = switch (reply[3]) {
        1 => 4,
        4 => 16,
        3 => try r.takeByte(),
        else => return error.ProxyConnectionFailed,
    };
    var discard: [257]u8 = undefined;
    try readExact(r, discard[0 .. length + 2]);
}

test "fetch_url proxy handshakes pin IPv4 IPv6 and credentials without consuming tunneled bytes" {
    const Case = struct { kind: @FieldType(Proxy, "kind"), ip: []const u8, auth: bool = false, request: []const u8, response: []const u8, failure: ?anyerror = null };
    const cases = [_]Case{
        .{ .kind = .http, .ip = "1.1.1.1", .request = "CONNECT 1.1.1.1:443 HTTP/1.1\r\nHost: 1.1.1.1:443\r\n\r\n", .response = "HTTP/1.1 200 OK\r\n\r\nX" },
        .{ .kind = .http, .ip = "2606:4700::1111", .auth = true, .request = "CONNECT [2606:4700::1111]:443 HTTP/1.1\r\nHost: [2606:4700::1111]:443\r\nProxy-Authorization: Basic dXNlcjpwYXNz\r\n\r\n", .response = "HTTP/1.1 200 OK\r\n\r\nX" },
        .{ .kind = .http, .ip = "1.1.1.1", .request = "CONNECT 1.1.1.1:443 HTTP/1.1\r\nHost: 1.1.1.1:443\r\n\r\n", .response = "HTTP/1.1 407 Proxy Authentication Required\r\n\r\n", .failure = error.ProxyAuthenticationFailed },
        .{ .kind = .http, .ip = "1.1.1.1", .request = "CONNECT 1.1.1.1:443 HTTP/1.1\r\nHost: 1.1.1.1:443\r\n\r\n", .response = "HTTP/1.1 502 Bad Gateway\r\n\r\n", .failure = error.ProxyConnectionFailed },
        .{ .kind = .socks5, .ip = "1.1.1.1", .request = "\x05\x01\x00\x05\x01\x00\x01\x01\x01\x01\x01\x01\xbb", .response = "\x05\x00\x05\x00\x00\x01\x00\x00\x00\x00\x00\x00X" },
        .{ .kind = .socks5, .ip = "2606:4700::1111", .auth = true, .request = "\x05\x02\x00\x02\x01\x04user\x04pass\x05\x01\x00\x04\x26\x06\x47\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x11\x11\x01\xbb", .response = "\x05\x02\x01\x00\x05\x00\x00\x04" ++ "\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00" ++ "X" },
        .{ .kind = .socks5, .ip = "1.1.1.1", .request = "\x05\x01\x00", .response = "\x05\xff", .failure = error.ProxyAuthenticationFailed },
    };
    for (cases) |case| {
        var fds: [2]std.c.fd_t = undefined;
        try std.testing.expectEqual(@as(c_int, 0), std.c.socketpair(std.c.AF.UNIX, std.c.SOCK.STREAM, 0, &fds));
        defer _ = std.c.close(fds[0]);
        defer _ = std.c.close(fds[1]);
        const address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
        const client: std.Io.net.Stream = .{ .socket = .{ .handle = fds[0], .address = address } };
        const server: std.Io.net.Stream = .{ .socket = .{ .handle = fds[1], .address = address } };
        var write_buffer: [256]u8 = undefined;
        var writer = server.writer(std.testing.io, &write_buffer);
        try writer.interface.writeAll(case.response);
        try writer.interface.flush();
        const target = std.Io.net.IpAddress.parseIp4(case.ip, 443) catch try std.Io.net.IpAddress.parseIp6(case.ip, 443);
        const proxy: Proxy = .{ .kind = case.kind, .host = "127.0.0.1", .port = 1080, .username = if (case.auth) "user" else "", .password = if (case.auth) "pass" else "" };
        if (case.failure) |failure| {
            try std.testing.expectError(failure, handshake(std.testing.io, client.socket, proxy, target));
        } else {
            try handshake(std.testing.io, client.socket, proxy, target);
            var one: [1]u8 = undefined;
            var reader = client.reader(std.testing.io, &one);
            try std.testing.expectEqual(@as(u8, 'X'), try reader.interface.takeByte());
        }
        var buffer: [512]u8 = undefined;
        var reader = server.reader(std.testing.io, &.{});
        try reader.interface.readSliceAll(buffer[0..case.request.len]);
        try std.testing.expectEqualStrings(case.request, buffer[0..case.request.len]);
    }
}

test "fetch_url pending proxy handshake is cancellable through the supplied Io runtime" {
    var fds: [2]std.c.fd_t = undefined;
    try std.testing.expectEqual(@as(c_int, 0), std.c.socketpair(std.c.AF.UNIX, std.c.SOCK.STREAM, 0, &fds));
    defer _ = std.c.close(fds[0]);
    defer _ = std.c.close(fds[1]);
    const address = try std.Io.net.IpAddress.parseIp4("1.1.1.1", 443);
    const Task = struct {
        socket: std.Io.net.Socket,
        target: std.Io.net.IpAddress,
        cancelled: bool = false,
        fn run(self: *@This()) void {
            handshake(std.testing.io, self.socket, .{ .kind = .http, .host = "127.0.0.1", .port = 7890 }, self.target) catch |err| {
                self.cancelled = err == error.Canceled;
            };
        }
    };
    var task: Task = .{ .socket = .{ .handle = fds[0], .address = address }, .target = address };
    var future = try std.Io.concurrent(std.testing.io, Task.run, .{&task});
    defer future.cancel(std.testing.io);
    const server: std.Io.net.Stream = .{ .socket = .{ .handle = fds[1], .address = address } };
    var reader = server.reader(std.testing.io, &.{});
    var request: [55]u8 = undefined;
    const expected = "CONNECT 1.1.1.1:443 HTTP/1.1\r\nHost: 1.1.1.1:443\r\n\r\n";
    try reader.interface.readSliceAll(request[0..expected.len]);
    const start = @import("../platform/realtime.zig").monotonicNs();
    // The worker is now blocked waiting for the proxy response, not DNS or
    // admission. Cancellation must join it without waiting for the peer.
    future.cancel(std.testing.io);
    try std.testing.expect(task.cancelled);
    try std.testing.expect(@import("../platform/realtime.zig").monotonicNs() - start < std.time.ns_per_s);
}
