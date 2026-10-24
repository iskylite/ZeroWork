const std = @import("std");

pub const version: u8 = 5;
pub const Method = enum(u8) { no_auth = 0x00, user_pass = 0x02, no_acceptable = 0xff };
pub const Command = enum(u8) { connect = 1, bind = 2, udp_associate = 3 };
pub const Reply = enum(u8) { succeeded = 0, general_failure = 1, not_allowed = 2, network_unreachable = 3, host_unreachable = 4, connection_refused = 5, ttl_expired = 6, command_not_supported = 7, address_type_not_supported = 8 };

pub const Address = union(enum) { ipv4: [4]u8, domain: []const u8, ipv6: [16]u8 };
pub const ConnectRequest = struct { command: Command, address: Address, port: u16 };
pub const ConnectResponse = struct { reply: Reply, address: Address = .{ .ipv4 = .{ 0, 0, 0, 0 } }, port: u16 = 0 };

pub fn addressHost(allocator: std.mem.Allocator, address: Address) ![:0]u8 {
    switch (address) {
        .domain => |value| return allocator.dupeSentinel(u8, value, 0),
        .ipv4 => |value| {
            var buffer: [15]u8 = undefined;
            const text = try std.fmt.bufPrint(&buffer, "{d}.{d}.{d}.{d}", .{ value[0], value[1], value[2], value[3] });
            return allocator.dupeSentinel(u8, text, 0);
        },
        .ipv6 => return error.UnsupportedAddressType,
    }
}

pub const Codec = struct {
    pub fn greeting(methods: []const Method, out: []u8) ![]u8 {
        if (methods.len > 255 or out.len < methods.len + 2) return error.BufferTooSmall;
        out[0] = version;
        out[1] = @intCast(methods.len);
        for (methods, 0..) |method, i| out[2 + i] = @backingInt(method);
        return out[0 .. methods.len + 2];
    }

    pub fn selectMethod(bytes: []const u8, allowed: []const Method) !Method {
        if (bytes.len < 2 or bytes[0] != version or bytes.len != @as(usize, bytes[1]) + 2) return error.InvalidGreeting;
        for (bytes[2..]) |raw| for (allowed) |method| if (raw == @backingInt(method)) return method;
        return .no_acceptable;
    }

    pub fn encodeConnectRequest(request: ConnectRequest, out: []u8) ![]u8 {
        if (out.len < 7) return error.BufferTooSmall;
        out[0] = version;
        out[1] = @backingInt(request.command);
        out[2] = 0;
        var cursor: usize = 4;
        switch (request.address) {
            .ipv4 => |value| {
                out[3] = 1;
                @memcpy(out[cursor..][0..4], &value);
                cursor += 4;
            },
            .domain => |value| {
                if (value.len > 255 or out.len < 5 + value.len) return error.InvalidDomain;
                out[3] = 3;
                out[cursor] = @intCast(value.len);
                cursor += 1;
                @memcpy(out[cursor..][0..value.len], value);
                cursor += value.len;
            },
            .ipv6 => |value| {
                out[3] = 4;
                @memcpy(out[cursor..][0..16], &value);
                cursor += 16;
            },
        }
        if (out.len < cursor + 2) return error.BufferTooSmall;
        std.mem.writeInt(u16, out[cursor..][0..2], request.port, .big);
        return out[0 .. cursor + 2];
    }

    pub fn encodeConnectResponse(response: ConnectResponse, out: []u8) ![]u8 {
        if (out.len < 10) return error.BufferTooSmall;
        out[0] = version;
        out[1] = @backingInt(response.reply);
        out[2] = 0;
        var cursor: usize = 4;
        switch (response.address) {
            .ipv4 => |value| {
                out[3] = 1;
                @memcpy(out[cursor..][0..4], &value);
                cursor += 4;
            },
            .domain => |value| {
                if (value.len > 255 or out.len < 5 + value.len + 2) return error.InvalidDomain;
                out[3] = 3;
                out[cursor] = @intCast(value.len);
                cursor += 1;
                @memcpy(out[cursor..][0..value.len], value);
                cursor += value.len;
            },
            .ipv6 => |value| {
                out[3] = 4;
                if (out.len < cursor + 16 + 2) return error.BufferTooSmall;
                @memcpy(out[cursor..][0..16], &value);
                cursor += 16;
            },
        }
        if (out.len < cursor + 2) return error.BufferTooSmall;
        std.mem.writeInt(u16, out[cursor..][0..2], response.port, .big);
        return out[0 .. cursor + 2];
    }

    pub fn decodeConnectResponse(bytes: []const u8) !ConnectResponse {
        if (bytes.len < 10 or bytes[0] != version or bytes[2] != 0) return error.InvalidResponse;
        const reply: Reply = @fromBackingInt(@intCast(bytes[1]));
        var cursor: usize = 4;
        const address: Address = switch (bytes[3]) {
            1 => blk: {
                if (bytes.len < cursor + 4 + 2) return error.TruncatedResponse;
                var value: [4]u8 = undefined;
                @memcpy(&value, bytes[cursor..][0..4]);
                cursor += 4;
                break :blk .{ .ipv4 = value };
            },
            3 => blk: {
                if (bytes.len < cursor + 1) return error.TruncatedResponse;
                const len = bytes[cursor];
                cursor += 1;
                if (bytes.len < cursor + len + 2) return error.TruncatedResponse;
                const value = bytes[cursor .. cursor + len];
                cursor += len;
                break :blk .{ .domain = value };
            },
            4 => blk: {
                if (bytes.len < cursor + 16 + 2) return error.TruncatedResponse;
                var value: [16]u8 = undefined;
                @memcpy(&value, bytes[cursor..][0..16]);
                cursor += 16;
                break :blk .{ .ipv6 = value };
            },
            else => return error.UnsupportedAddressType,
        };
        return .{ .reply = reply, .address = address, .port = std.mem.readInt(u16, bytes[cursor..][0..2], .big) };
    }
};

test "SOCKS5 addresses convert to libssh2 host strings" {
    const domain = try addressHost(std.testing.allocator, .{ .domain = "db.internal" });
    defer std.testing.allocator.free(domain);
    try std.testing.expectEqualStrings("db.internal", domain);
    const ipv4 = try addressHost(std.testing.allocator, .{ .ipv4 = .{ 127, 0, 0, 1 } });
    defer std.testing.allocator.free(ipv4);
    try std.testing.expectEqualStrings("127.0.0.1", ipv4);
    const ipv6: [16]u8 = @splat(0);
    try std.testing.expectError(error.UnsupportedAddressType, addressHost(std.testing.allocator, .{ .ipv6 = ipv6 }));
}

test "SOCKS5 greeting selects the first allowed method" {
    var buffer: [8]u8 = undefined;
    const greeting = try Codec.greeting(&.{ .user_pass, .no_auth }, &buffer);
    try std.testing.expectEqual(Method.user_pass, try Codec.selectMethod(greeting, &.{.user_pass}));
}

test "SOCKS5 domain connect request encodes RFC1928 fields" {
    var buffer: [64]u8 = undefined;
    const encoded = try Codec.encodeConnectRequest(.{ .command = .connect, .address = .{ .domain = "db.internal" }, .port = 5432 }, &buffer);
    try std.testing.expectEqual(@as(u8, 5), encoded[0]);
    try std.testing.expectEqual(@as(u8, 3), encoded[3]);
    try std.testing.expectEqual(@as(u8, 11), encoded[4]);
    try std.testing.expectEqual(@as(u16, 5432), std.mem.readInt(u16, encoded[16..18], .big));
}

test "SOCKS5 response decodes IPv4 bind address" {
    const response = [_]u8{ 5, 0, 0, 1, 127, 0, 0, 1, 0x15, 0xb3 };
    const decoded = try Codec.decodeConnectResponse(&response);
    try std.testing.expectEqual(Reply.succeeded, decoded.reply);
    try std.testing.expectEqual(@as(u16, 5555), decoded.port);
}
