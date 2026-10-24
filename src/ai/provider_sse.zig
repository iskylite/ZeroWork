const std = @import("std");

pub const Frame = struct { event: []const u8, data: []const u8 };
pub const Sink = *const fn (*anyopaque, Frame) void;

/// 只负责 SSE 传输分帧；JSON/provider 语义留给具体 Provider adapter。
pub const Decoder = struct {
    allocator: std.mem.Allocator,
    max_frame_bytes: usize = 1024 * 1024,
    line: std.ArrayList(u8) = .empty,
    data: std.ArrayList(u8) = .empty,
    event: std.ArrayList(u8) = .empty,

    pub fn init(allocator: std.mem.Allocator) Decoder {
        return initWithLimit(allocator, 1024 * 1024);
    }

    pub fn initWithLimit(allocator: std.mem.Allocator, max_frame_bytes: usize) Decoder {
        return .{ .allocator = allocator, .max_frame_bytes = max_frame_bytes };
    }

    pub fn deinit(self: *Decoder) void {
        self.line.deinit(self.allocator);
        self.data.deinit(self.allocator);
        self.event.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn feed(self: *Decoder, bytes: []const u8, sink: Sink, ctx: *anyopaque) !void {
        for (bytes) |byte| {
            if (byte == '\n') {
                try self.consumeLine(sink, ctx);
            } else if (byte != '\r') {
                try self.appendLimited(&self.line, byte);
            }
        }
    }

    pub fn finish(self: *Decoder, sink: Sink, ctx: *anyopaque) !void {
        if (self.line.items.len != 0) try self.consumeLine(sink, ctx);
        if (self.data.items.len != 0 or self.event.items.len != 0) self.dispatch(sink, ctx);
    }

    fn consumeLine(self: *Decoder, sink: Sink, ctx: *anyopaque) !void {
        const line = self.line.items;
        defer self.line.clearRetainingCapacity();
        if (line.len == 0) return self.dispatch(sink, ctx);
        if (line[0] == ':') return;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse line.len;
        const field = line[0..colon];
        var value = if (colon < line.len) line[colon + 1 ..] else "";
        if (value.len != 0 and value[0] == ' ') value = value[1..];
        if (std.mem.eql(u8, field, "data")) {
            if (self.data.items.len != 0) try self.appendLimited(&self.data, '\n');
            try self.appendSliceLimited(&self.data, value);
        } else if (std.mem.eql(u8, field, "event")) {
            self.event.clearRetainingCapacity();
            try self.appendSliceLimited(&self.event, value);
        }
    }

    fn appendLimited(self: *Decoder, list: *std.ArrayList(u8), byte: u8) !void {
        if (list.items.len >= self.max_frame_bytes) return error.FrameTooLarge;
        try list.append(self.allocator, byte);
    }

    fn appendSliceLimited(self: *Decoder, list: *std.ArrayList(u8), bytes: []const u8) !void {
        if (bytes.len > self.max_frame_bytes -| list.items.len) return error.FrameTooLarge;
        try list.appendSlice(self.allocator, bytes);
    }

    fn dispatch(self: *Decoder, sink: Sink, ctx: *anyopaque) void {
        if (self.data.items.len == 0 and self.event.items.len == 0) return;
        const frame: Frame = .{ .event = self.event.items, .data = self.data.items };
        sink(ctx, frame);
        self.data.clearRetainingCapacity();
        self.event.clearRetainingCapacity();
    }
};

test "sse decoder preserves chunk boundaries and multiline data" {
    const Capture = struct {
        count: usize = 0,
        data: [2][32]u8 = undefined,
        lengths: [2]usize = .{ 0, 0 },
        fn receive(ctx: *anyopaque, frame: Frame) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            @memcpy(self.data[self.count][0..frame.data.len], frame.data);
            self.lengths[self.count] = frame.data.len;
            self.count += 1;
        }
    };
    var decoder = Decoder.init(std.testing.allocator);
    defer decoder.deinit();
    var capture: Capture = .{};
    try decoder.feed("event: message\ndata: one\n", Capture.receive, &capture);
    try decoder.feed("data: two\n\n", Capture.receive, &capture);
    try decoder.finish(Capture.receive, &capture);
    try std.testing.expectEqual(@as(usize, 1), capture.count);
    try std.testing.expectEqualStrings("one\ntwo", capture.data[0][0..capture.lengths[0]]);
}

test "sse decoder rejects oversized frames" {
    var decoder = Decoder.initWithLimit(std.testing.allocator, 4);
    defer decoder.deinit();
    const Noop = struct {
        fn receive(ctx: *anyopaque, frame: Frame) void {
            _ = ctx;
            _ = frame;
        }
    };
    try std.testing.expectError(error.FrameTooLarge, decoder.feed("data: 12345", Noop.receive, undefined));
}

test "sse decoder ignores comments and dispatches done frame" {
    const Capture = struct {
        done: bool = false,
        fn receive(ctx: *anyopaque, frame: Frame) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.done = std.mem.eql(u8, frame.data, "[DONE]");
        }
    };
    var decoder = Decoder.init(std.testing.allocator);
    defer decoder.deinit();
    var capture: Capture = .{};
    try decoder.feed(": keepalive\n\ndata: [DONE]\n\n", Capture.receive, &capture);
    try std.testing.expect(capture.done);
}
