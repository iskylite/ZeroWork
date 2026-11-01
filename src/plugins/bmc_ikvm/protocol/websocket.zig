//! RFC 6455, binary byte-stream delivery with bounded control-frame storage.
//! A binary message may span frames, and an RFB message may span WS messages.
const std = @import("std");
const http = @import("http.zig");

pub const Upgrade = struct {
    key: [24]u8,
    subprotocol: []const u8,

    pub fn init(subprotocol: []const u8) !Upgrade {
        if (!http.isToken(subprotocol) or subprotocol.len > 4096) return error.InvalidSubprotocol;
        var nonce: [16]u8 = undefined;
        std.c.arc4random_buf(&nonce, nonce.len);
        var result: Upgrade = .{ .key = undefined, .subprotocol = subprotocol };
        _ = std.base64.standard.Encoder.encode(&result.key, &nonce);
        return result;
    }
    pub fn buildRequest(self: Upgrade, allocator: std.mem.Allocator, origin: http.Origin, path: []const u8) ![]u8 {
        if (!http.isToken(self.subprotocol)) return error.InvalidSubprotocol;
        const authority = try origin.authority(allocator);
        defer allocator.free(authority);
        const origin_header = try std.fmt.allocPrint(allocator, "https://{s}", .{authority});
        defer allocator.free(origin_header);
        return http.buildRequest(allocator, "GET", origin, path, &.{
            .{ .name = "Upgrade", .value = "websocket" },
            .{ .name = "Connection", .value = "Upgrade" },
            .{ .name = "Sec-WebSocket-Key", .value = &self.key },
            .{ .name = "Sec-WebSocket-Version", .value = "13" },
            .{ .name = "Sec-WebSocket-Protocol", .value = self.subprotocol },
            .{ .name = "Origin", .value = origin_header },
        }, "");
    }
    pub fn validate(self: Upgrade, response: *const http.ResponseParser) !void {
        if (!response.isDone() or response.status != 101) return error.UpgradeRejected;
        if (!response.hasToken("Connection", "upgrade") or !response.hasToken("Upgrade", "websocket")) return error.InvalidUpgrade;
        if (response.headerCount("Sec-WebSocket-Accept") != 1 or response.headerCount("Sec-WebSocket-Protocol") != 1 or response.headerCount("Sec-WebSocket-Extensions") != 0) return error.InvalidUpgrade;
        const expected = acceptForKey(&self.key);
        if (!std.mem.eql(u8, response.header("Sec-WebSocket-Accept").?, &expected)) return error.InvalidAccept;
        if (!std.mem.eql(u8, response.header("Sec-WebSocket-Protocol").?, self.subprotocol)) return error.InvalidSubprotocol;
    }
};

pub fn acceptForKey(key: []const u8) [28]u8 {
    var hash = std.crypto.hash.Sha1.init(.{});
    hash.update(key);
    hash.update("258EAFA5-E914-47DA-95CA-C5AB0DC85B11");
    var digest: [20]u8 = undefined;
    hash.final(&digest);
    var result: [28]u8 = undefined;
    _ = std.base64.standard.Encoder.encode(&result, &digest);
    return result;
}

pub const Opcode = enum(u4) { continuation = 0, binary = 2, close = 8, ping = 9, pong = 10 };
pub const Close = struct { code: ?u16, reason: []const u8 };
/// Event slices are valid only during sink.onEvent(event). Control frames never
/// enter the binary/RFB stream. Reply to ping with a new masked pong frame.
pub const Event = union(enum) { binary: []const u8, ping: []const u8, pong: []const u8, close: Close };
pub const Limits = struct {
    /// Protocol-frame bound, independent of the 8 MiB transport staging budget.
    /// Legal full-resolution Raw data can be streamed through a much smaller IO
    /// buffer without being accumulated in this parser.
    max_frame_bytes: u64 = 64 * 1024 * 1024,
};

pub const Parser = struct {
    limits: Limits = .{},
    header: [10]u8 = undefined,
    header_len: usize = 0,
    header_needed: usize = 2,
    remaining: u64 = 0,
    opcode: Opcode = .binary,
    final: bool = false,
    fragmented: bool = false,
    in_payload: bool = false,
    control: [125]u8 = undefined,
    control_len: usize = 0,
    closed: bool = false,
    failed: bool = false,

    /// sink must expose `pub fn onEvent(self, event: Event) !void`.
    pub fn feed(self: *Parser, bytes: []const u8, sink: anytype) !usize {
        errdefer self.failed = true;
        if (self.failed) return error.ParserFailed;
        if (self.closed) return 0;
        var offset: usize = 0;
        while (offset < bytes.len and !self.closed) {
            if (!self.in_payload) {
                const n = @min(self.header_needed - self.header_len, bytes.len - offset);
                @memcpy(self.header[self.header_len..][0..n], bytes[offset..][0..n]);
                offset += n;
                self.header_len += n;
                if (self.header_len == 2) {
                    if (self.header[0] & 0x70 != 0) return error.UnnegotiatedExtension;
                    if (self.header[1] & 0x80 != 0) return error.MaskedServerFrame;
                    self.header_needed = switch (self.header[1] & 127) {
                        126 => 4,
                        127 => 10,
                        else => 2,
                    };
                }
                if (self.header_len < self.header_needed) continue;
                try self.beginFrame();
                if (self.remaining == 0) try self.endFrame(sink);
            } else {
                const n: usize = @intCast(@min(self.remaining, bytes.len - offset));
                const payload = bytes[offset..][0..n];
                if (@backingInt(self.opcode) >= 8) {
                    @memcpy(self.control[self.control_len..][0..n], payload);
                    self.control_len += n;
                } else try sink.onEvent(Event{ .binary = payload });
                self.remaining -= n;
                offset += n;
                if (self.remaining == 0) try self.endFrame(sink);
            }
        }
        return offset;
    }
    pub fn finishEof(self: *Parser) !void {
        if (!self.closed) {
            self.failed = true;
            return error.AbnormalClosure;
        }
    }
    fn beginFrame(self: *Parser) !void {
        self.final = self.header[0] & 128 != 0;
        self.opcode = switch (self.header[0] & 15) {
            0 => .continuation,
            2 => .binary,
            8 => .close,
            9 => .ping,
            10 => .pong,
            1 => return error.UnsupportedTextFrame,
            else => return error.UnknownOpcode,
        };
        if (self.opcode == .continuation and !self.fragmented) return error.UnexpectedContinuation;
        if (self.opcode == .binary and self.fragmented) return error.InterleavedDataMessage;
        self.remaining = self.header[1] & 127;
        if (self.remaining == 126) {
            self.remaining = std.mem.readInt(u16, self.header[2..4], .big);
            if (self.remaining < 126) return error.NonCanonicalLength;
        } else if (self.remaining == 127) {
            self.remaining = std.mem.readInt(u64, self.header[2..10], .big);
            if (self.remaining & (@as(u64, 1) << 63) != 0 or self.remaining < 65536) return error.NonCanonicalLength;
        }
        if (@backingInt(self.opcode) >= 8 and (!self.final or self.remaining > 125)) return error.InvalidControlFrame;
        if (self.remaining > self.limits.max_frame_bytes) return error.FrameTooLarge;
        self.control_len = 0;
        self.in_payload = true;
    }
    fn endFrame(self: *Parser, sink: anytype) !void {
        const payload = self.control[0..self.control_len];
        switch (self.opcode) {
            .binary => self.fragmented = !self.final,
            .continuation => if (self.final) {
                self.fragmented = false;
            },
            .ping => try sink.onEvent(Event{ .ping = payload }),
            .pong => try sink.onEvent(Event{ .pong = payload }),
            .close => {
                if (payload.len == 1) return error.InvalidClose;
                var code: ?u16 = null;
                var reason: []const u8 = "";
                if (payload.len >= 2) {
                    code = std.mem.readInt(u16, payload[0..2], .big);
                    if (!validCloseCode(code.?)) return error.InvalidClose;
                    reason = payload[2..];
                    if (!std.unicode.utf8ValidateSlice(reason)) return error.InvalidClose;
                }
                try sink.onEvent(Event{ .close = .{ .code = code, .reason = reason } });
                self.closed = true;
            },
        }
        self.header_len = 0;
        self.header_needed = 2;
        self.in_payload = false;
    }
};

fn validCloseCode(code: u16) bool {
    return (code >= 1000 and code <= 1014 and code != 1004 and code != 1005 and code != 1006) or (code >= 3000 and code <= 4999);
}

/// A fresh unpredictable mask is generated on every call, including ping/pong.
/// The caller uses http.WriteCursor so partial TLS writes preserve frame order.
pub fn clientFrame(allocator: std.mem.Allocator, opcode: Opcode, final: bool, payload: []const u8) ![]u8 {
    if (@backingInt(opcode) >= 8 and (!final or payload.len > 125)) return error.InvalidControlFrame;
    if (opcode == .close) {
        if (payload.len == 1) return error.InvalidClose;
        if (payload.len >= 2 and (!validCloseCode(std.mem.readInt(u16, payload[0..2], .big)) or !std.unicode.utf8ValidateSlice(payload[2..]))) return error.InvalidClose;
    }
    const ext: usize = if (payload.len < 126) 0 else if (payload.len <= 65535) 2 else 8;
    const header_len = 2 + ext + 4;
    const total = std.math.add(usize, header_len, payload.len) catch return error.FrameTooLarge;
    const result = try allocator.alloc(u8, total);
    result[0] = @as(u8, @backingInt(opcode)) | (if (final) @as(u8, 128) else 0);
    result[1] = 128 | (if (ext == 0) @as(u8, @intCast(payload.len)) else if (ext == 2) @as(u8, 126) else 127);
    if (ext == 2) std.mem.writeInt(u16, result[2..4], @intCast(payload.len), .big);
    if (ext == 8) std.mem.writeInt(u64, result[2..10], @intCast(payload.len), .big);
    var mask: [4]u8 = undefined;
    std.c.arc4random_buf(&mask, mask.len);
    @memcpy(result[2 + ext ..][0..4], &mask);
    for (payload, 0..) |ch, i| result[header_len + i] = ch ^ mask[i % 4];
    return result;
}
