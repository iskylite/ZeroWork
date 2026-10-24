const std = @import("std");
const socks = @import("socks5.zig");
const Server = @import("socks5_server.zig").Server;

pub const Channel = struct {
    ctx: *anyopaque,
    read_fn: *const fn (*anyopaque, []u8) anyerror!usize,
    write_fn: *const fn (*anyopaque, []const u8) anyerror!usize,

    pub fn read(self: Channel, buffer: []u8) !usize {
        return self.read_fn(self.ctx, buffer);
    }
    pub fn writeAll(self: Channel, bytes: []const u8) !void {
        var offset: usize = 0;
        while (offset < bytes.len) {
            const count = try self.write_fn(self.ctx, bytes[offset..]);
            if (count == 0 or count > bytes.len - offset) return error.InvalidWriteCount;
            offset += count;
        }
    }
};

pub const Handshake = struct {
    server: Server,

    pub fn init(allowed: []const socks.Method) !Handshake {
        return .{ .server = try Server.init(allowed) };
    }

    pub fn run(self: *Handshake, channel: Channel, scratch: []u8) !socks.ConnectRequest {
        if (scratch.len < 4) return error.BufferTooSmall;
        const greeting_len = try readFrame(channel, scratch, 2, 257);
        const method = try self.server.receiveGreeting(scratch[0..greeting_len]);
        try channel.writeAll(&[_]u8{ socks.version, @backingInt(method) });
        if (method == .no_acceptable) return error.NoAcceptableMethod;
        const request_len = try readRequest(channel, scratch);
        const request = try self.server.receiveRequest(scratch[0..request_len]);
        try self.server.establish();
        return request;
    }

    /// Run the handshake and let the caller establish the requested outbound
    /// target before the success/failure reply is written.
    pub fn runAndReply(self: *Handshake, channel: Channel, scratch: []u8, open_target: *const fn (*anyopaque, socks.ConnectRequest) anyerror!socks.ConnectResponse, ctx: *anyopaque) !socks.ConnectRequest {
        const request = self.run(channel, scratch) catch |err| {
            var failure: [32]u8 = undefined;
            const encoded = try socks.Codec.encodeConnectResponse(.{ .reply = .general_failure }, &failure);
            try channel.writeAll(encoded);
            return err;
        };
        const response = open_target(ctx, request) catch |err| {
            var failure: [32]u8 = undefined;
            const encoded = try socks.Codec.encodeConnectResponse(.{ .reply = .general_failure }, &failure);
            try channel.writeAll(encoded);
            return err;
        };
        var encoded: [300]u8 = undefined;
        try channel.writeAll(try socks.Codec.encodeConnectResponse(response, &encoded));
        return request;
    }
};

fn readExact(channel: Channel, out: []u8) !void {
    var offset: usize = 0;
    while (offset < out.len) {
        const count = try channel.read(out[offset..]);
        if (count == 0 or count > out.len - offset) return error.EndOfStream;
        offset += count;
    }
}

fn readFrame(channel: Channel, scratch: []u8, prefix_len: usize, max_len: usize) !usize {
    try readExact(channel, scratch[0..prefix_len]);
    const total = prefix_len + scratch[1];
    if (total > max_len or total > scratch.len) return error.FrameTooLarge;
    try readExact(channel, scratch[prefix_len..total]);
    return total;
}

fn readRequest(channel: Channel, scratch: []u8) !usize {
    try readExact(channel, scratch[0..4]);
    const total: usize = 4;
    const extra = switch (scratch[3]) {
        1 => 4,
        3 => blk: {
            try readExact(channel, scratch[4..5]);
            break :blk 1 + scratch[4];
        },
        4 => 16,
        else => return error.UnsupportedAddressType,
    };
    if (total + extra + 2 > scratch.len) return error.FrameTooLarge;
    try readExact(channel, scratch[total .. total + extra + 2]);
    return total + extra + 2;
}

test "streaming SOCKS5 handshake handles fragmented frames" {
    const Fake = struct {
        input: []const u8,
        position: usize = 0,
        output: [16]u8 = undefined,
        output_len: usize = 0,
        fn read(ctx: *anyopaque, out: []u8) !usize {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            if (self.position == self.input.len) return 0;
            const count = @min(@as(usize, 1), self.input.len - self.position);
            out[0] = self.input[self.position];
            self.position += count;
            return count;
        }
        fn write(ctx: *anyopaque, bytes: []const u8) !usize {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            @memcpy(self.output[self.output_len .. self.output_len + bytes.len], bytes);
            self.output_len += bytes.len;
            return bytes.len;
        }
    };
    var fake: Fake = .{ .input = &[_]u8{ 5, 1, 0, 5, 1, 0, 1, 127, 0, 0, 1, 0x15, 0xb3 } };
    var handshake = try Handshake.init(&.{.no_auth});
    var scratch: [32]u8 = undefined;
    const request = try handshake.run(.{ .ctx = &fake, .read_fn = Fake.read, .write_fn = Fake.write }, &scratch);
    try std.testing.expectEqual(@as(u16, 5555), request.port);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 5, 0 }, fake.output[0..fake.output_len]);
}
