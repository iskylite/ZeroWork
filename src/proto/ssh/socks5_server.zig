const std = @import("std");
const socks = @import("socks5.zig");

pub const State = enum { greeting, method_selected, request, established, rejected };

pub const Server = struct {
    allowed: []const socks.Method,
    state: State = .greeting,
    method: socks.Method = .no_acceptable,

    pub fn init(allowed: []const socks.Method) !Server {
        if (allowed.len == 0) return error.NoMethods;
        return .{ .allowed = allowed };
    }

    pub fn receiveGreeting(self: *Server, bytes: []const u8) !socks.Method {
        if (self.state != .greeting) return error.InvalidTransition;
        const method = try socks.Codec.selectMethod(bytes, self.allowed);
        self.method = method;
        self.state = if (method == .no_acceptable) .rejected else .method_selected;
        return method;
    }

    pub fn receiveRequest(self: *Server, bytes: []const u8) !socks.ConnectRequest {
        if (self.state != .method_selected) return error.InvalidTransition;
        if (self.method != .no_auth) return error.AuthenticationRequired;
        const request = try decodeRequest(bytes);
        self.state = .request;
        return request;
    }

    pub fn establish(self: *Server) !void {
        if (self.state != .request) return error.InvalidTransition;
        self.state = .established;
    }

    pub fn reject(self: *Server) void {
        self.state = .rejected;
    }
};

fn decodeRequest(bytes: []const u8) !socks.ConnectRequest {
    if (bytes.len < 7 or bytes[0] != socks.version or bytes[2] != 0) return error.InvalidRequest;
    const command: socks.Command = @fromBackingInt(@intCast(bytes[1]));
    var cursor: usize = 4;
    const address: socks.Address = switch (bytes[3]) {
        1 => blk: {
            if (bytes.len < cursor + 4 + 2) return error.TruncatedRequest;
            var value: [4]u8 = undefined;
            @memcpy(&value, bytes[cursor..][0..4]);
            cursor += 4;
            break :blk .{ .ipv4 = value };
        },
        3 => blk: {
            if (bytes.len < cursor + 1) return error.TruncatedRequest;
            const len = bytes[cursor];
            cursor += 1;
            if (bytes.len < cursor + len + 2) return error.TruncatedRequest;
            const value = bytes[cursor .. cursor + len];
            cursor += len;
            break :blk .{ .domain = value };
        },
        4 => blk: {
            if (bytes.len < cursor + 16 + 2) return error.TruncatedRequest;
            var value: [16]u8 = undefined;
            @memcpy(&value, bytes[cursor..][0..16]);
            cursor += 16;
            break :blk .{ .ipv6 = value };
        },
        else => return error.UnsupportedAddressType,
    };
    return .{ .command = command, .address = address, .port = std.mem.readInt(u16, bytes[cursor..][0..2], .big) };
}

test "SOCKS5 server walks no-auth connect handshake" {
    var server = try Server.init(&.{.no_auth});
    try std.testing.expectEqual(socks.Method.no_auth, try server.receiveGreeting(&[_]u8{ 5, 1, 0 }));
    const request = try server.receiveRequest(&[_]u8{ 5, 1, 0, 1, 127, 0, 0, 1, 0x15, 0xb3 });
    try std.testing.expectEqual(@as(u16, 5555), request.port);
    try server.establish();
    try std.testing.expectEqual(State.established, server.state);
}

test "SOCKS5 server rejects request before method selection" {
    var server = try Server.init(&.{.no_auth});
    try std.testing.expectError(error.InvalidTransition, server.receiveRequest(&[_]u8{}));
}
