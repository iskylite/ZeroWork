//! Bounded Sugon-style OEM RFB byte stream, independent of WebSocket framing.
//! The profile caller must authenticate TLS / WEB / KVM before websocketReady.
//! Synthetic tests establish parser behaviour, not compatibility with hardware.
const std = @import("std");
pub const raw = @import("rfb_raw.zig");
pub const tight = @import("rfb_tight.zig");

pub const MemoryBudget = struct {
    context: *anyopaque,
    reserve: *const fn (*anyopaque, usize) anyerror!void,
    release: *const fn (*anyopaque, usize) void,
};
pub const Limits = struct {
    max_width: u16 = 4096,
    max_height: u16 = 2160,
    max_frame_bytes: usize = 4096 * 2160 * 4,
    max_buffered_bytes: usize = 8 * 1024 * 1024,
    max_decode_bytes: usize = 64 * 1024 * 1024,
    max_name_bytes: usize = 64 * 1024,
    max_text_bytes: usize = 1024 * 1024,
    max_cursor_pixels: usize = 256 * 256,
    max_steps_per_feed: usize = 1024,
    client_pixel_format: raw.PixelFormat = .{},
    advertise_cursor: bool = false,
    /// Conflicting historical 3+1440 / 1444 descriptions cannot select this.
    /// Only a profile with independently fixed evidence may set 1443 or 1444.
    oem_macro_message_bytes: ?u16 = null,
    memory_budget: ?MemoryBudget = null,
};
pub const Authenticated = struct { tls_trusted: bool, web_authenticated: bool, oem_authenticated: bool };
pub const Phase = enum { websocket, version, oem_magic, security_types, security_result, server_init, server_name, normal, rectangle_header, raw_pixels, tight_pixels, copy_rect, cursor, failed };
pub const Failure = struct { phase: Phase, message_type: ?u8, code: anyerror };
pub const ControlState = enum { read_only, major, awaiting_authorization, rejected };
pub const Control = struct { context: [4]u8, state: ControlState };
pub const FrameComplete = struct {
    sequence: u64,
    generation: u64,
    width: u16,
    height: u16,
    stride: usize,
    /// Borrowed until the next call to feed/websocketReady/deinit. Drain and
    /// synchronously copy/publish before feeding further bytes. Never free it.
    pixels: []const u8,
};
pub const Event = union(enum) {
    outbound: []u8,
    control: Control,
    control_request: [4]u8,
    resize: struct { generation: u64, width: u16, height: u16 },
    frame_complete: FrameComplete,
    /// Known OEM message including its type; UTF-8 may contain a serial number.
    /// This is UI/read-only data and must never be written to diagnostic logs.
    notice: []u8,
    cursor: struct { x: u16, y: u16, width: u16, height: u16, rgba: []u8 },
    pointer_position: struct { x: u16, y: u16 },
    bell: void,
    pub fn deinit(self: *Event, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .outbound, .notice => |bytes| allocator.free(bytes),
            .cursor => |value| allocator.free(value.rgba),
            else => {},
        }
        self.* = undefined;
    }
};
pub const ControlReply = enum(u8) { full_control = 1, video_only = 0, reject = 127 };

pub fn frameBytesForSize(limits: Limits, width: u16, height: u16) !usize {
    if (width == 0 or height == 0 or width > limits.max_width or height > limits.max_height or width > 4096 or height > 2160) return error.FrameLimitExceeded;
    const length = try raw.byteLength(width, height, 4);
    if (length > limits.max_frame_bytes) return error.FrameLimitExceeded;
    return length;
}

pub const Decoder = struct {
    allocator: std.mem.Allocator,
    limits: Limits,
    phase: Phase = .websocket,
    failure: ?Failure = null,
    current_message: ?u8 = null,
    buffer: std.ArrayList(u8) = .empty,
    start: usize = 0,
    events: [64]Event = undefined,
    event_head: usize = 0,
    event_count: usize = 0,
    frame_waiting: bool = false,
    format: raw.PixelFormat,
    tight_decoder: tight.Decoder,
    width: u16 = 0,
    height: u16 = 0,
    frame: []u8 = &.{},
    coverage: []u8 = &.{},
    uncovered: usize = 0,
    generation: u64 = 0,
    sequence: u64 = 0,
    name_remaining: usize = 0,
    rectangles_remaining: u16 = 0,
    rectangle: raw.Rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
    raw_index: usize = 0,
    request_outstanding: bool = false,
    force_full_next: bool = false,
    control_state: ControlState = .read_only,
    pending_control_request: ?[4]u8 = null,

    pub fn init(allocator: std.mem.Allocator, limits: Limits) !Decoder {
        try limits.client_pixel_format.validate();
        if (limits.max_buffered_bytes < 24 or limits.max_buffered_bytes > 8 * 1024 * 1024 or
            limits.max_decode_bytes > 64 * 1024 * 1024 or limits.max_decode_bytes == 0 or limits.max_steps_per_feed == 0) return error.InvalidLimits;
        if (limits.oem_macro_message_bytes) |length| if (length != 1443 and length != 1444) return error.InvalidLimits;
        return .{ .allocator = allocator, .limits = limits, .format = limits.client_pixel_format, .tight_decoder = tight.Decoder.init(allocator) };
    }
    pub fn deinit(self: *Decoder) void {
        while (self.nextEvent()) |value| {
            var event = value;
            event.deinit(self.allocator);
        }
        self.buffer.deinit(self.allocator);
        self.tight_decoder.deinit();
        self.releaseFrame();
        self.* = undefined;
    }
    pub fn websocketReady(self: *Decoder, auth: Authenticated) !void {
        if (self.phase != .websocket) return error.InvalidRfbState;
        if (!auth.tls_trusted or !auth.web_authenticated or !auth.oem_authenticated) return self.fail(error.AuthenticationRequired);
        try self.send("KVM ");
        self.phase = .version;
    }
    pub fn nextEvent(self: *Decoder) ?Event {
        if (self.event_count == 0) return null;
        const event = self.events[self.event_head];
        self.event_head = (self.event_head + 1) % self.events.len;
        self.event_count -= 1;
        if (event == .frame_complete) self.frame_waiting = false;
        return event;
    }
    pub fn bufferedBytes(self: *const Decoder) usize {
        return self.buffer.items.len - self.start;
    }

    /// Returns accepted byte count. A short/zero return is ordinary backpressure:
    /// drain events, process borrowed frame, then feed remaining input. feed(&.{})
    /// continues processing already-buffered bytes and provides bounded yields.
    pub fn feed(self: *Decoder, bytes: []const u8) !usize {
        if (self.phase == .failed) return error.RfbFailed;
        if (self.phase == .websocket) return error.InvalidRfbState;
        return self.feedInner(bytes) catch |err| return self.fail(err);
    }
    fn feedInner(self: *Decoder, bytes: []const u8) !usize {
        var accepted: usize = 0;
        var steps: usize = 0;
        while (steps < self.limits.max_steps_per_feed and self.event_count < self.events.len - 4 and !self.frame_waiting) {
            steps += 1;
            if (try self.step()) continue;
            if (accepted == bytes.len) break;
            const queued_bytes = self.bufferedBytes();
            if (queued_bytes == self.limits.max_buffered_bytes) return error.TransportLimitExceeded;
            const amount = @min(bytes.len - accepted, self.limits.max_buffered_bytes - queued_bytes, 64 * 1024);
            if (self.start != 0) {
                std.mem.copyForwards(u8, self.buffer.items[0..queued_bytes], self.buffer.items[self.start..]);
                self.buffer.shrinkRetainingCapacity(queued_bytes);
                self.start = 0;
            }
            if (self.buffer.capacity < queued_bytes + amount) {
                // ArrayList's geometric growth may exceed the 8 MiB transport
                // budget even when the live byte count fits. Cap capacity too.
                const capacity = @min(self.limits.max_buffered_bytes, @max(queued_bytes + amount, @min(self.limits.max_buffered_bytes, self.buffer.capacity * 2)));
                try self.buffer.ensureTotalCapacityPrecise(self.allocator, capacity);
            }
            try self.buffer.appendSlice(self.allocator, bytes[accepted..][0..amount]);
            accepted += amount;
        }
        return accepted;
    }
    pub fn finish(self: *Decoder) !void {
        if (self.phase == .failed) return error.RfbFailed;
        if (self.phase != .normal or self.bufferedBytes() != 0 or self.rectangles_remaining != 0) return self.fail(error.TruncatedRfbStream);
    }
    pub fn requestControl(self: *Decoder) !void {
        if (!self.runtime()) return error.InvalidRfbState;
        try self.send(&.{109}); // exclusively invoked by an explicit user action
    }
    pub fn replyControl(self: *Decoder, expected_context: [4]u8, reply: ControlReply) !void {
        if (!self.runtime()) return error.InvalidRfbState;
        var context = self.pending_control_request orelse return error.NoControlRequest;
        if (!std.mem.eql(u8, &context, &expected_context)) return error.StaleControlRequest;
        context[0] = 108;
        context[1] = @backingInt(reply);
        try self.send(&context);
        self.pending_control_request = null;
    }
    /// The worker owns the ~30s timer. Expiry cannot manufacture a server verdict.
    pub fn expireControlRequest(self: *Decoder) void {
        self.pending_control_request = null;
    }

    /// Foreground/resume refresh respects the single outstanding request rule.
    /// The next request after the current FBU will ask for the entire base.
    pub fn requestFullRefresh(self: *Decoder) !void {
        if (!self.runtime()) return error.InvalidRfbState;
        self.force_full_next = true;
    }

    fn runtime(self: *const Decoder) bool {
        return switch (self.phase) {
            .normal, .rectangle_header, .raw_pixels, .tight_pixels, .copy_rect, .cursor => true,
            else => false,
        };
    }

    fn fail(self: *Decoder, err: anyerror) anyerror {
        if (self.failure == null) self.failure = .{ .phase = self.phase, .message_type = self.current_message, .code = err };
        self.phase = .failed;
        return err;
    }
    fn emit(self: *Decoder, event: Event) !void {
        if (self.event_count == self.events.len) return error.EventQueueFull;
        self.events[(self.event_head + self.event_count) % self.events.len] = event;
        self.event_count += 1;
    }
    fn send(self: *Decoder, bytes: []const u8) !void {
        const copy = try self.allocator.dupe(u8, bytes);
        errdefer self.allocator.free(copy);
        try self.emit(.{ .outbound = copy });
    }
    fn notice(self: *Decoder, bytes: []const u8) !void {
        const copy = try self.allocator.dupe(u8, bytes);
        errdefer self.allocator.free(copy);
        try self.emit(.{ .notice = copy });
    }
    fn pending(self: *const Decoder) []const u8 {
        return self.buffer.items[self.start..];
    }
    fn consume(self: *Decoder, count: usize) void {
        self.start += count;
        if (self.start == self.buffer.items.len) {
            self.buffer.clearRetainingCapacity();
            self.start = 0;
        }
    }
    fn step(self: *Decoder) !bool {
        const bytes = self.pending();
        switch (self.phase) {
            .version => {
                if (bytes.len < 12) return false;
                if (!std.mem.eql(u8, bytes[0..12], "RFB 003.008\n")) return error.UnsupportedRfbVersion;
                self.consume(12);
                try self.send("RFB 003.008\n");
                self.phase = .oem_magic;
                return true;
            },
            .oem_magic => {
                if (bytes.len < 4) return false;
                self.current_message = bytes[0];
                switch (bytes[0]) {
                    105, 106 => try self.controlMessage(bytes[0..4]),
                    104 => switch (bytes[1]) {
                        0 => self.phase = .security_types,
                        1 => return error.OemExclusiveSession,
                        2 => return error.OemSessionLimit,
                        else => return error.UnsupportedOemHandshake,
                    },
                    else => return error.UnsupportedOemHandshake,
                }
                self.consume(4);
                return true;
            },
            .security_types => {
                if (bytes.len < 1) return false;
                const count: usize = bytes[0];
                if (count == 0) return error.RfbAuthenticationRejected;
                if (bytes.len < count + 1) return false;
                if (std.mem.indexOfScalar(u8, bytes[1..][0..count], 1) == null) return error.UnsupportedSecurityType;
                self.consume(count + 1);
                try self.send(&.{1});
                self.phase = .security_result;
                return true;
            },
            .security_result => {
                if (bytes.len < 4) return false;
                if (read32(bytes, 0) != 0) return error.RfbAuthenticationRejected;
                self.consume(4);
                try self.send(&.{1}); // ClientInit shared; never force-exclusive
                self.phase = .server_init;
                return true;
            },
            .server_init => {
                if (bytes.len < 24) return false;
                _ = try raw.PixelFormat.parse(bytes[4..20]);
                const width = read16(bytes, 0);
                const height = read16(bytes, 2);
                self.name_remaining = read32(bytes, 20);
                if (self.name_remaining > self.limits.max_name_bytes) return error.ServerNameLimitExceeded;
                try self.resize(width, height);
                self.consume(24);
                self.phase = .server_name;
                return true;
            },
            .server_name => {
                const amount = @min(bytes.len, self.name_remaining);
                self.consume(amount);
                self.name_remaining -= amount;
                if (self.name_remaining != 0) return amount != 0;
                try self.negotiate();
                self.phase = .normal;
                return true;
            },
            .normal => return self.normal(bytes),
            .rectangle_header => {
                if (bytes.len < 12) return false;
                self.rectangle = .{ .x = read16(bytes, 0), .y = read16(bytes, 2), .width = read16(bytes, 4), .height = read16(bytes, 6) };
                const encoding: i32 = @bitCast(read32(bytes, 8));
                self.consume(12);
                switch (encoding) {
                    -224 => try self.completeUpdate(),
                    -223 => {
                        if (self.rectangle.x != 0 or self.rectangle.y != 0) return error.InvalidDesktopSize;
                        try self.resize(self.rectangle.width, self.rectangle.height);
                        try self.completeRectangle();
                    },
                    -239 => {
                        const rect = self.rectangle;
                        const pixels = try raw.byteLength(rect.width, rect.height, 1);
                        if (pixels > self.limits.max_cursor_pixels or (pixels != 0 and (rect.x >= rect.width or rect.y >= rect.height))) return error.InvalidCursor;
                        self.phase = .cursor;
                    },
                    -232 => {
                        if (self.rectangle.x >= self.width or self.rectangle.y >= self.height) return error.RectangleOutOfBounds;
                        try self.emit(.{ .pointer_position = .{ .x = self.rectangle.x, .y = self.rectangle.y } });
                        try self.completeRectangle();
                    },
                    0, 1, 7 => {
                        try raw.checkRectangle(self.rectangle, self.width, self.height);
                        self.raw_index = 0;
                        self.phase = switch (encoding) {
                            0 => .raw_pixels,
                            1 => .copy_rect,
                            7 => .tight_pixels,
                            else => unreachable,
                        };
                    },
                    else => return error.UnsupportedEncoding,
                }
                return true;
            },
            .raw_pixels => {
                const pixel_bytes = self.format.bytesPerPixel();
                const total = try raw.byteLength(self.rectangle.width, self.rectangle.height, 1);
                const count = @min(total - self.raw_index, bytes.len / pixel_bytes);
                if (count == 0) return false;
                for (0..count) |i| {
                    raw.put(self.frame, self.width, self.rectangle, self.raw_index + i, self.format.rgba(bytes[i * pixel_bytes ..][0..pixel_bytes], false));
                    self.markPixel(self.rectangle, self.raw_index + i);
                }
                self.raw_index += count;
                self.consume(count * pixel_bytes);
                if (self.raw_index == total) try self.completeRectangle();
                return true;
            },
            .tight_pixels => {
                const packet = try tight.inspect(self.format, self.rectangle.width, self.rectangle.height, bytes, self.limits.max_decode_bytes) orelse return false;
                try self.tight_decoder.apply(packet, self.format, self.rectangle, self.width, self.frame, self.limits.max_decode_bytes);
                self.markRectangle(self.rectangle);
                self.consume(packet.consumed);
                try self.completeRectangle();
                return true;
            },
            .copy_rect => {
                if (bytes.len < 4) return false;
                if (self.uncovered != 0) return error.MissingFramebufferBase;
                const source: raw.Rect = .{ .x = read16(bytes, 0), .y = read16(bytes, 2), .width = self.rectangle.width, .height = self.rectangle.height };
                try raw.checkRectangle(source, self.width, self.height);
                const row_length = @as(usize, source.width) * 4;
                for (0..source.height) |step_index| {
                    const row = if (self.rectangle.y > source.y) source.height - 1 - step_index else step_index;
                    const from = ((@as(usize, source.y) + row) * self.width + source.x) * 4;
                    const to = ((@as(usize, self.rectangle.y) + row) * self.width + self.rectangle.x) * 4;
                    if (to > from) std.mem.copyBackwards(u8, self.frame[to..][0..row_length], self.frame[from..][0..row_length]) else std.mem.copyForwards(u8, self.frame[to..][0..row_length], self.frame[from..][0..row_length]);
                }
                self.consume(4);
                try self.completeRectangle();
                return true;
            },
            .cursor => {
                const rect = self.rectangle;
                const pixels = try raw.byteLength(rect.width, rect.height, 1);
                const pixel_length = pixels * self.format.bytesPerPixel();
                const mask_length = ((@as(usize, rect.width) + 7) / 8) * rect.height;
                if (bytes.len < pixel_length + mask_length) return false;
                const rgba = try self.allocator.alloc(u8, pixels * 4);
                var owned = true;
                errdefer if (owned) self.allocator.free(rgba);
                for (0..pixels) |index| {
                    var colour = self.format.rgba(bytes[index * self.format.bytesPerPixel() ..][0..self.format.bytesPerPixel()], false);
                    const mask = bytes[pixel_length + (index / rect.width) * ((@as(usize, rect.width) + 7) / 8) + index % rect.width / 8];
                    colour[3] = if (mask & (@as(u8, 0x80) >> @intCast(index % rect.width % 8)) != 0) 255 else 0;
                    @memcpy(rgba[index * 4 ..][0..4], &colour);
                }
                try self.emit(.{ .cursor = .{ .x = rect.x, .y = rect.y, .width = rect.width, .height = rect.height, .rgba = rgba } });
                owned = false;
                self.consume(pixel_length + mask_length);
                try self.completeRectangle();
                return true;
            },
            .websocket, .failed => return error.InvalidRfbState,
        }
    }
    fn normal(self: *Decoder, bytes: []const u8) !bool {
        if (bytes.len == 0) return false;
        self.current_message = bytes[0];
        var length: usize = 0;
        switch (bytes[0]) {
            0 => {
                if (bytes.len < 4) return false;
                if (!self.request_outstanding) return error.UnexpectedFramebufferUpdate;
                self.rectangles_remaining = read16(bytes, 2);
                self.consume(4);
                if (self.rectangles_remaining == 0) try self.completeUpdate() else self.phase = .rectangle_header;
                return true;
            },
            1 => { // unused true-colour colour-map, with known standard length
                if (bytes.len < 6) return false;
                length = 6 + @as(usize, read16(bytes, 4)) * 6;
            },
            2 => {
                try self.emit(.bell);
                self.consume(1);
                return true;
            },
            3 => { // Clipboard is excluded; consume bounded standard ServerCutText.
                if (bytes.len < 8) return false;
                const text_length = read32(bytes, 4);
                if (text_length > self.limits.max_text_bytes) return error.TextLimitExceeded;
                length = 8 + @as(usize, text_length);
            },
            102 => {
                try self.send(&.{102});
                self.consume(1);
                return true;
            },
            105, 106 => {
                if (bytes.len < 4) return false;
                try self.controlMessage(bytes[0..4]);
                self.consume(4);
                return true;
            },
            107 => {
                if (bytes.len < 4) return false;
                self.pending_control_request = bytes[0..4].*;
                try self.emit(.{ .control_request = bytes[0..4].* });
                self.consume(4);
                return true;
            },
            125, 122 => length = 2,
            123, 113 => length = 8,
            121 => {
                if (bytes.len < 4) return false;
                length = 4;
                if (bytes[1] == 4 and bytes[3] != 127) length += bytes[3];
                if (bytes.len < length) return false;
                if (!std.unicode.utf8ValidateSlice(bytes[4..length])) return error.InvalidOemText;
            },
            126 => length = self.limits.oem_macro_message_bytes orelse return error.UnverifiedOemMacroLength,
            else => return error.UnsupportedServerMessage,
        }
        if (length > self.limits.max_buffered_bytes) return error.TransportLimitExceeded;
        if (bytes.len < length) return false;
        if (bytes[0] >= 100 and bytes[0] != 126) try self.notice(bytes[0..length]);
        self.consume(length);
        return true;
    }
    fn controlMessage(self: *Decoder, bytes: []const u8) !void {
        self.control_state = if (bytes[1] == 127) .rejected else if (bytes[1] == 1) .major else if (bytes[1] == 0 and bytes[2] == 1) .awaiting_authorization else .read_only;
        try self.emit(.{ .control = .{ .context = bytes[0..4].*, .state = self.control_state } });
        if (bytes[0] == 105) {
            var reply = bytes[0..4].*;
            reply[0] = 106;
            try self.send(&reply);
        }
    }
    fn negotiate(self: *Decoder) !void {
        var pixel_format: [20]u8 = @splat(0);
        var encoded: [16]u8 = undefined;
        self.format.write(&encoded);
        @memcpy(pixel_format[4..20], &encoded);
        try self.send(&pixel_format);
        // JPEG quality is declared because ImageIO decoding is implemented.
        const encodings = [_]i32{ 7, 0, 1, -224, -223, -26, -239, -232 };
        const count: usize = if (self.limits.advertise_cursor) encodings.len else encodings.len - 2;
        var message: [4 + encodings.len * 4]u8 = @splat(0);
        message[0] = 2;
        std.mem.writeInt(u16, message[2..4], @intCast(count), .big);
        for (encodings[0..count], 0..) |encoding, index| std.mem.writeInt(i32, message[4 + index * 4 ..][0..4], encoding, .big);
        try self.send(message[0 .. 4 + count * 4]);
        try self.requestUpdate(false);
    }
    fn requestUpdate(self: *Decoder, incremental: bool) !void {
        // One outstanding FBU: completion queues the next request for the
        // pipeline to write. Receive/decode and request latency affect FPS;
        // this mode has no fixed-FPS timer or negotiated ContinuousUpdates.
        if (self.request_outstanding) return error.InvalidRfbState;
        var message: [10]u8 = @splat(0);
        message[0] = 3;
        message[1] = @intFromBool(incremental);
        std.mem.writeInt(u16, message[6..8], self.width, .big);
        std.mem.writeInt(u16, message[8..10], self.height, .big);
        try self.send(&message);
        self.request_outstanding = true;
    }
    fn completeRectangle(self: *Decoder) !void {
        if (self.rectangles_remaining == 0) return error.InvalidRfbState;
        self.rectangles_remaining -= 1;
        if (self.rectangles_remaining == 0) try self.completeUpdate() else self.phase = .rectangle_header;
    }
    fn completeUpdate(self: *Decoder) !void {
        self.rectangles_remaining = 0;
        self.request_outstanding = false;
        self.phase = .normal;
        if (self.uncovered == 0) {
            if (self.coverage.len != 0) {
                const length = self.coverage.len;
                self.allocator.free(self.coverage);
                self.coverage = &.{};
                if (self.limits.memory_budget) |budget| budget.release(budget.context, length);
            }
            self.sequence = try std.math.add(u64, self.sequence, 1);
            try self.emit(.{ .frame_complete = .{ .sequence = self.sequence, .generation = self.generation, .width = self.width, .height = self.height, .stride = @as(usize, self.width) * 4, .pixels = self.frame } });
            self.frame_waiting = true;
        }
        try self.requestUpdate(self.uncovered == 0 and !self.force_full_next);
        self.force_full_next = false;
    }
    fn resize(self: *Decoder, width: u16, height: u16) !void {
        const length = try frameBytesForSize(self.limits, width, height);
        const pixels = length / 4;
        const coverage_length = (pixels + 7) / 8;
        if (coverage_length > self.limits.max_decode_bytes) return error.DecodeLimitExceeded;
        const reservation = length + coverage_length;
        if (self.limits.memory_budget) |budget| try budget.reserve(budget.context, reservation);
        errdefer if (self.limits.memory_budget) |budget| budget.release(budget.context, reservation);
        const frame = try self.allocator.alloc(u8, length);
        errdefer self.allocator.free(frame);
        const coverage = try self.allocator.alloc(u8, coverage_length);
        errdefer self.allocator.free(coverage);
        @memset(frame, 0);
        for (0..pixels) |i| frame[i * 4 + 3] = 255;
        @memset(coverage, 0);
        const generation = try std.math.add(u64, self.generation, 1);
        try self.emit(.{ .resize = .{ .generation = generation, .width = width, .height = height } });
        self.releaseFrame();
        self.frame = frame;
        self.coverage = coverage;
        self.uncovered = pixels;
        self.width = width;
        self.height = height;
        self.generation = generation;
    }
    fn releaseFrame(self: *Decoder) void {
        const length = self.frame.len + self.coverage.len;
        self.allocator.free(self.frame);
        self.allocator.free(self.coverage);
        self.frame = &.{};
        self.coverage = &.{};
        if (length != 0) if (self.limits.memory_budget) |budget| budget.release(budget.context, length);
    }
    fn markPixel(self: *Decoder, rect: raw.Rect, index: usize) void {
        if (self.uncovered == 0) return;
        const absolute = (@as(usize, rect.y) + index / rect.width) * self.width + rect.x + index % rect.width;
        const mask = @as(u8, 1) << @intCast(absolute % 8);
        if (self.coverage[absolute / 8] & mask == 0) {
            self.coverage[absolute / 8] |= mask;
            self.uncovered -= 1;
        }
    }
    fn markRectangle(self: *Decoder, rect: raw.Rect) void {
        if (self.uncovered == 0) return;
        const pixels = @as(usize, rect.width) * rect.height;
        for (0..pixels) |index| self.markPixel(rect, index);
    }
};

fn read16(bytes: []const u8, offset: usize) u16 {
    return std.mem.readInt(u16, bytes[offset..][0..2], .big);
}
fn read32(bytes: []const u8, offset: usize) u32 {
    return std.mem.readInt(u32, bytes[offset..][0..4], .big);
}
