//! The web proxy uses RFC 1929 on every TCP connection. This incremental
//! parser shares the SOCKS5 wire codec with terminal forwarding but does not
//! share its unauthenticated admission policy.
const std = @import("std");
const socks = @import("socks5.zig");

pub const Credentials = struct {
    username: [32]u8,
    password: [64]u8,

    pub fn generate() Credentials {
        var user_bytes: [16]u8 = undefined;
        var pass_bytes: [32]u8 = undefined;
        defer std.crypto.secureZero(u8, &pass_bytes);
        std.c.arc4random_buf(&user_bytes, user_bytes.len);
        std.c.arc4random_buf(&pass_bytes, pass_bytes.len);
        return .{
            .username = std.fmt.bytesToHex(user_bytes, .lower),
            .password = std.fmt.bytesToHex(pass_bytes, .lower),
        };
    }
};

pub const Target = struct {
    host: [255]u8,
    len: u8,
    port: u16,

    pub fn hostname(self: *const Target) []const u8 {
        return self.host[0..self.len];
    }
};

pub const Handshake = struct {
    pub const Phase = enum { greeting, credentials, request, opening, stream, closed };

    phase: Phase = .greeting,
    next: Phase = .closed,
    target: Target = undefined,
    // RFC 1929 permits two separate 255-byte fields.
    input: [513]u8 = undefined,
    have: usize = 0,
    need: usize = 2,
    output: [10]u8 = undefined,
    output_len: usize = 0,
    sent: usize = 0,

    /// Expose exactly the bytes needed by the current protocol stage.
    /// CONNECT-pipelined application data remains in the socket buffer.
    pub fn readBuffer(self: *Handshake) []u8 {
        std.debug.assert(self.pendingReply().len == 0);
        return self.input[self.have..self.need];
    }

    pub fn received(self: *Handshake, count: usize, credentials: *const Credentials) void {
        std.debug.assert(count <= self.readBuffer().len);
        self.have += count;
        if (self.have != self.need) return;
        switch (self.phase) {
            .greeting => self.greeting(),
            .credentials => self.authenticate(credentials),
            .request => self.parseRequest(),
            else => unreachable,
        }
    }

    pub fn pendingReply(self: *const Handshake) []const u8 {
        return self.output[self.sent..self.output_len];
    }

    pub fn replySent(self: *Handshake, count: usize) void {
        std.debug.assert(count <= self.pendingReply().len);
        self.sent += count;
        if (self.sent != self.output_len) return;
        self.phase = self.next;
        self.have = 0;
        self.need = if (self.phase == .request) 4 else 2;
        self.sent = 0;
        self.output_len = 0;
    }

    pub fn finishConnect(self: *Handshake, reply: socks.Reply) void {
        self.output_len = (socks.Codec.encodeConnectResponse(.{ .reply = reply }, &self.output) catch unreachable).len;
        self.next = if (reply == .succeeded) .stream else .closed;
    }

    pub fn clear(self: *Handshake) void {
        std.crypto.secureZero(u8, &self.input);
    }

    fn methodReply(self: *Handshake, version: u8, status: u8, next: Phase) void {
        self.output[0..2].* = .{ version, status };
        self.output_len = 2;
        self.next = next;
    }

    fn greeting(self: *Handshake) void {
        if (self.input[0] == socks.version and self.have == 2 and self.input[1] > 0) {
            self.need = 2 + @as(usize, self.input[1]);
            return;
        }
        const method = socks.Codec.selectMethod(self.input[0..self.have], &.{.user_pass}) catch .no_acceptable;
        self.methodReply(socks.version, @backingInt(method), if (method == .user_pass) .credentials else .closed);
    }

    fn authenticate(self: *Handshake, credentials: *const Credentials) void {
        // Our generated lengths are fixed and public. Reject malformed frames
        // without buffering password bytes beyond what this generation accepts.
        const username_length = credentials.username.len;
        const password_length = credentials.password.len;
        if (self.have == 2 and self.input[0] == 1 and self.input[1] == username_length) {
            self.need = 3 + username_length;
            return;
        }
        if (self.have == 3 + username_length and self.input[2 + username_length] == password_length) {
            self.need += password_length;
            return;
        }
        var accepted = false;
        if (self.have == 3 + username_length + password_length) {
            const username: [32]u8 = self.input[2..][0..32].*;
            const password = self.input[3 + username_length ..][0..64];
            const compare = std.crypto.timing_safe.eql;
            accepted = compare([32]u8, username, credentials.username) &
                compare([64]u8, password.*, credentials.password);
        }
        self.clear();
        self.methodReply(1, if (accepted) 0 else 1, if (accepted) .request else .closed);
    }

    fn parseRequest(self: *Handshake) void {
        if (self.have == 4) {
            if (self.input[0] != socks.version or self.input[2] != 0) return self.finishConnect(.general_failure);
            if (self.input[1] != @backingInt(socks.Command.connect)) return self.finishConnect(.command_not_supported);
            self.need = switch (self.input[3]) {
                1 => 10,
                3 => 5,
                4 => 22,
                else => return self.finishConnect(.address_type_not_supported),
            };
            return;
        }
        if (self.have == 5) {
            if (self.input[4] == 0) return self.finishConnect(.host_unreachable);
            self.need = 7 + @as(usize, self.input[4]);
            return;
        }
        const port = std.mem.readInt(u16, self.input[self.have - 2 ..][0..2], .big);
        if (port == 0) return self.finishConnect(.not_allowed);
        self.target = .{ .host = undefined, .len = 0, .port = port };
        const host = switch (self.input[3]) {
            1 => std.fmt.bufPrint(&self.target.host, "{d}.{d}.{d}.{d}", .{
                self.input[4], self.input[5], self.input[6], self.input[7],
            }) catch unreachable,
            3 => domain: {
                const domain = self.input[5 .. self.have - 2];
                for (domain) |byte| if (byte <= 32 or byte >= 127) return self.finishConnect(.host_unreachable);
                @memcpy(self.target.host[0..domain.len], domain);
                break :domain self.target.host[0..domain.len];
            },
            4 => ipv6: {
                const bytes = self.input[4..20];
                var groups: [8]u16 = undefined;
                for (&groups, 0..) |*value, index| value.* = std.mem.readInt(u16, bytes[index * 2 ..][0..2], .big);
                break :ipv6 std.fmt.bufPrint(&self.target.host, "{x}:{x}:{x}:{x}:{x}:{x}:{x}:{x}", .{
                    groups[0], groups[1], groups[2], groups[3], groups[4], groups[5], groups[6], groups[7],
                }) catch unreachable;
            },
            else => unreachable,
        };
        self.target.len = @intCast(host.len);
        self.phase = .opening;
    }
};

const testing = std.testing;

fn feed(handshake: *Handshake, credentials: *const Credentials, bytes: []const u8) void {
    for (bytes) |byte| {
        handshake.readBuffer()[0] = byte;
        handshake.received(1, credentials);
    }
}

fn credentialFrame(value: Credentials) [99]u8 {
    return [_]u8{ 1, 32 } ++ value.username ++ [_]u8{64} ++ value.password;
}

test "web SOCKS accepts only this generation and keeps original domain" {
    const current: Credentials = .{ .username = @splat('u'), .password = @splat('p') };
    const previous: Credentials = .{ .username = @splat('u'), .password = @splat('q') };
    var handshake: Handshake = .{};
    feed(&handshake, &current, &.{ 5, 2, 0, 2 });
    try testing.expectEqualSlices(u8, &.{ 5, 2 }, handshake.pendingReply());
    handshake.replySent(2);
    feed(&handshake, &current, &credentialFrame(previous));
    try testing.expectEqualSlices(u8, &.{ 1, 1 }, handshake.pendingReply());
    handshake.replySent(2);
    try testing.expectEqual(.closed, handshake.phase);

    handshake = .{};
    feed(&handshake, &current, &.{ 5, 1, 2 });
    handshake.replySent(2);
    feed(&handshake, &current, &credentialFrame(current));
    try testing.expectEqualSlices(u8, &.{ 1, 0 }, handshake.pendingReply());
    handshake.replySent(2);
    var request: [64]u8 = undefined;
    const encoded = try socks.Codec.encodeConnectRequest(.{
        .command = .connect,
        .address = .{ .domain = "only-at-exit.invalid" },
        .port = 443,
    }, &request);
    feed(&handshake, &current, encoded);
    try testing.expectEqual(.opening, handshake.phase);
    try testing.expectEqualStrings("only-at-exit.invalid", handshake.target.hostname());
    try testing.expectEqual(@as(u16, 443), handshake.target.port);
    try testing.expectEqual(@as(usize, 0), handshake.pendingReply().len);
    handshake.finishConnect(.succeeded);
    try testing.expectEqual(.succeeded, (try socks.Codec.decodeConnectResponse(handshake.pendingReply())).reply);
}

test "web SOCKS rejects no-auth, BIND and UDP ASSOCIATE" {
    const credentials: Credentials = .{ .username = @splat('u'), .password = @splat('p') };
    var handshake: Handshake = .{};
    feed(&handshake, &credentials, &.{ 5, 1, 0 });
    try testing.expectEqualSlices(u8, &.{ 5, 255 }, handshake.pendingReply());
    handshake.replySent(2);
    try testing.expectEqual(.closed, handshake.phase);
    for ([_]u8{ 2, 3 }) |command| {
        handshake = .{ .phase = .request, .need = 4 };
        feed(&handshake, &credentials, &.{ 5, command, 0, 1 });
        try testing.expectEqual(.command_not_supported, (try socks.Codec.decodeConnectResponse(handshake.pendingReply())).reply);
        handshake.replySent(10);
        try testing.expectEqual(.closed, handshake.phase);
    }
}
