const std = @import("std");
const FeedBridge = @import("feed_bridge.zig").FeedBridge;
const InputQueue = @import("input_queue.zig").InputQueue;
const ChannelWriter = @import("channel_pump.zig").ChannelWriter;
const pumpInputBatch = @import("channel_pump.zig").pumpInputBatch;
const Handler = @import("worker_dispatch.zig").Handler;
const Timeline = @import("timeline.zig").Timeline;
const CheckpointController = @import("checkpoint_controller.zig").Controller;
pub const Read = @import("../host/terminal_service.zig").Read;

pub const ChannelReader = struct {
    ctx: *anyopaque,
    read_fn: *const fn (*anyopaque, []u8) anyerror!Read,
    pub fn read(self: ChannelReader, buffer: []u8) !Read {
        return self.read_fn(self.ctx, buffer);
    }
};

pub const WorkerIo = struct {
    pub const TimestampFn = *const fn (*anyopaque) i64;
    feed: FeedBridge,
    input: *InputQueue,
    reader: ChannelReader,
    writer: ChannelWriter,
    read_buffer: []u8,
    write_buffer: []u8,
    timeline: ?*Timeline = null,
    checkpoint: ?*CheckpointController = null,
    stream_offset: u64 = 0,
    timestamp_ctx: ?*anyopaque = null,
    timestamp_fn: ?TimestampFn = null,
    closed: bool = false,
    /// A readiness EOF is only a hangup hint. Buffered protocol/PTY bytes
    /// remain readable until the transport itself returns .eof.
    hangup_seen: bool = false,
    /// Monotonic arrival time for shell readiness; independent of burst logs.
    last_output_ns: i128 = 0,
    // Burst-arrival diagnostics: timestamps the first and last data read of
    // each output burst so we can separate DATA ARRIVAL time (SSH/window)
    // from DISPLAY time (publish/consume/render). Printed when the burst
    // has been quiet for 500ms.
    diag_first_ms: i64 = 0,
    diag_last_ms: i64 = 0,
    diag_bytes: u64 = 0,
    diag_reads: u64 = 0,
    diag_quiet_logged: bool = true,

    pub fn handler(self: *WorkerIo) Handler {
        return .{ .ctx = self, .on_readable = onReadable, .on_writable = onWritable, .on_closed = onClosed };
    }
    fn onReadable(ctx: *anyopaque) !void {
        const self: *WorkerIo = @ptrCast(@alignCast(ctx));
        try self.drainOutput(4);
    }

    fn drainOutput(self: *WorkerIo, max_empty_retries: u8) !void {
        if (self.closed) return;
        if (self.read_buffer.len == 0) return error.EmptyReadBuffer;
        // Drain the socket in one wakeup: aggregating reads into a single
        // feed+publish pass cuts per-batch projection work and keeps the SSH
        // receive window moving under sustained output (dmesg without tail).
        var total: usize = 0;
        var eagain_retries: u8 = 0;
        var eof = false;
        var read_error: ?anyerror = null;
        while (total < self.read_buffer.len) {
            const result = self.reader.read(self.read_buffer[total..]) catch |err| {
                read_error = err;
                break;
            };
            switch (result) {
                .eof => {
                    eof = true;
                    break;
                },
                .would_block => {
                    // EAGAIN: no COMPLETE packet ready for the caller right now.
                    // libssh2's transport greedily RECVs up to PACKETBUFSIZE from
                    // the socket into its internal buffer while assembling one
                    // packet, so the socket can be empty while decrypted packets
                    // still sit in the session brigade — the kqueue (socket-only)
                    // will NOT fire for those, and without this retry the data
                    // stays trapped until the next 50ms step timeout. This was
                    // the dmesg "trickle": reads pacing at step-timeout cadence
                    // instead of draining back-to-back like the OpenSSH client.
                    if (eagain_retries >= max_empty_retries) break;
                    eagain_retries += 1;
                    std.Thread.yield() catch {};
                    continue;
                },
                .bytes => |count| {
                    if (count == 0 or count > self.read_buffer.len - total) {
                        read_error = error.InvalidReadCount;
                        break;
                    }
                    eagain_retries = 0;
                    total += count;
                },
            }
        }

        // Never discard a successfully read prefix when a later read reports
        // EOF or an error. Publication backpressure is handled by FeedBridge;
        // an actual parser failure must reach the owning worker.
        if (total != 0) try self.feedOutput(self.read_buffer[0..total]);
        if (eof) self.closed = true;
        if (read_error) |err| return err;
    }

    fn feedOutput(self: *WorkerIo, bytes: []const u8) !void {
        self.last_output_ns = @import("../platform/realtime.zig").monotonicNs();
        const timestamp_ms = if (self.timestamp_fn) |timestamp_fn| timestamp_fn(self.timestamp_ctx orelse unreachable) else 0;
        // Session-recording side effects are best-effort: a timeline or
        // checkpoint failure (disk, capacity) must never tear down the live
        // terminal connection — display is the primary path.
        if (self.timeline) |timeline| timeline.append(timestamp_ms, self.stream_offset, bytes) catch |err| {
            std.log.warn("[worker] timeline append dropped: {s}", .{@errorName(err)});
            self.timeline = null;
        };
        if (self.checkpoint) |checkpoint| _ = checkpoint.append(bytes, timestamp_ms) catch |err| {
            std.log.warn("[worker] checkpoint append dropped: {s}", .{@errorName(err)});
            self.checkpoint = null;
        };
        _ = try self.feed.feedAndPublish(bytes, timestamp_ms);
        self.stream_offset += bytes.len;
        self.diag_reads += 1;
        self.diag_bytes += bytes.len;
        if (self.diag_first_ms == 0) self.diag_first_ms = timestamp_ms;
        self.diag_last_ms = timestamp_ms;
        self.diag_quiet_logged = false;
    }

    /// Called from the worker step loop: prints burst-arrival stats once the
    /// channel has been quiet for 500ms, separating network arrival time
    /// from the display pipeline's cost.
    pub fn diagBurstIfQuiet(self: *WorkerIo, now_ms: i64) void {
        if (self.diag_quiet_logged or self.diag_first_ms == 0) return;
        if (now_ms - self.diag_last_ms < 500) return;
        std.log.debug("[io-diag] burst: {d} bytes in {d} reads, arrival span {d}ms, quiet+{d}ms ago", .{
            self.diag_bytes,
            self.diag_reads,
            self.diag_last_ms - self.diag_first_ms,
            now_ms - self.diag_last_ms,
        });
        self.diag_quiet_logged = true;
        self.diag_first_ms = 0;
        self.diag_last_ms = 0;
        self.diag_bytes = 0;
        self.diag_reads = 0;
    }
    fn onWritable(ctx: *anyopaque) !void {
        const self: *WorkerIo = @ptrCast(@alignCast(ctx));
        if (self.closed) return;
        const result = try pumpInputBatch(self.input, self.writer, self.write_buffer, 4);
        std.log.debug("[worker_io] pump written={d} state={s}", .{ result.written, @tagName(result.state) });
    }

    /// Worker-step probe, run unconditionally: one non-blocking read even
    /// with no kqueue READ event pending. libssh2's channel_read entry
    /// force-sends the receive-window adjust the remote needs to continue,
    /// and the remote stops (no READ event ever fires) once its window runs
    /// dry. A conditional probe missed the case where the burst's LAST read
    /// succeeded and the remote stopped right after — frozen until a user
    /// keypress happened to send a packet. Idle cost: one EAGAIN syscall.
    pub fn pollChannelRead(self: *WorkerIo) !void {
        try self.drainOutput(0);
    }
    fn onClosed(ctx: *anyopaque) void {
        @as(*WorkerIo, @ptrCast(@alignCast(ctx))).hangup_seen = true;
    }

    pub fn resetTransport(self: *WorkerIo, reader: ChannelReader, writer: ChannelWriter) void {
        self.reader = reader;
        self.writer = writer;
        self.closed = false;
        self.hangup_seen = false;
    }
};

// Real protocol adapters supply ChannelReader/ChannelWriter implementations.

const VtEngine = @import("engine.zig").VtEngine;
const TextSlot = @import("text_slot.zig").TextSlot;
const TimelineType = @import("timeline.zig").Timeline;
const dispatch = @import("worker_dispatch.zig").dispatch;
const text_frame = @import("text_frame.zig");

fn testTimestamp(_: *anyopaque) i64 {
    return 1234;
}

const FakeEngine = struct {
    dirty: [1]u32 = .{3},
    versions: [1]u64 = .{1},
    fed: [16]u8 = undefined,
    fed_len: usize = 0,
    fail_feed: bool = false,
    pub fn destroy(_: *FakeEngine) void {}
    pub fn feed(self: *FakeEngine, bytes: []const u8) !@import("engine.zig").FeedResult {
        if (self.fail_feed) return error.VtFeedFailed;
        @memcpy(self.fed[self.fed_len .. self.fed_len + bytes.len], bytes);
        self.fed_len += bytes.len;
        return .{ .dirty_pages = &self.dirty, .cursor_moved = true, .bell = false };
    }
    pub fn resize(_: *FakeEngine, _: u16, _: u16) !void {}
    pub fn snapshot(self: *FakeEngine) @import("engine.zig").Snapshot {
        return .{ .cols = 80, .rows = 24, .cursor = .{}, .page_versions = &self.versions, .scroll_offset = 0 };
    }
    pub fn lineAt(_: *FakeEngine, _: u64) ?@import("engine.zig").LineView {
        return null;
    }
    pub fn selectionText(_: *FakeEngine, _: @import("engine.zig").Selection, _: @import("engine.zig").CopyMode, allocator: std.mem.Allocator) ![]u8 {
        return allocator.dupe(u8, "");
    }
    pub fn setOscCallback(_: *FakeEngine, _: ?@import("engine.zig").OscCallback) void {}
};

const FakeChannel = struct {
    output: []const u8,
    eof: bool = false,
    sent: [16]u8 = undefined,
    sent_len: usize = 0,
    pub fn read(ctx: *anyopaque, buffer: []u8) !Read {
        const self: *FakeChannel = @ptrCast(@alignCast(ctx));
        if (self.output.len == 0) return if (self.eof) .eof else .would_block;
        const count = @min(buffer.len, self.output.len);
        @memcpy(buffer[0..count], self.output[0..count]);
        self.output = self.output[count..];
        return .{ .bytes = count };
    }
    pub fn write(ctx: *anyopaque, bytes: []const u8) !usize {
        const self: *FakeChannel = @ptrCast(@alignCast(ctx));
        @memcpy(self.sent[self.sent_len .. self.sent_len + bytes.len], bytes);
        self.sent_len += bytes.len;
        return bytes.len;
    }
};

test "worker IO dispatches channel output and input end to end" {
    var engine: FakeEngine = .{};
    var text = try TextSlot.init(std.testing.allocator, 256);
    defer text.deinit(std.testing.allocator);
    var input = try InputQueue.init(std.testing.allocator, 8);
    defer input.deinit(std.testing.allocator);
    try input.push("ls\n");
    var channel: FakeChannel = .{ .output = "remote" };
    var read_buffer: [16]u8 = undefined;
    var write_buffer: [16]u8 = undefined;
    var timeline = try TimelineType.init(std.testing.allocator, 4, 64);
    defer timeline.deinit();
    var worker: WorkerIo = .{
        .feed = .{ .engine = VtEngine.from(FakeEngine, &engine), .text_slot = &text },
        .input = &input,
        .reader = .{ .ctx = &channel, .read_fn = FakeChannel.read },
        .writer = .{ .ctx = &channel, .write_fn = FakeChannel.write },
        .read_buffer = &read_buffer,
        .write_buffer = &write_buffer,
        .timeline = &timeline,
        .timestamp_ctx = undefined,
        .timestamp_fn = testTimestamp,
    };
    try dispatch(.{ .fd = 1, .readable = true, .writable = true, .eof = true }, worker.handler());
    try std.testing.expectEqualStrings("remote", engine.fed[0..engine.fed_len]);
    try std.testing.expectEqual(@as(usize, 1), timeline.eventCount());
    try std.testing.expectEqual(@as(u64, 0), timeline.events.items[0].stream_offset);
    try std.testing.expectEqual(@as(i64, 1234), timeline.events.items[0].timestamp_ms);
    try std.testing.expectEqualStrings("remote", timeline.events.items[0].payload);
    try std.testing.expectEqualStrings("ls\n", channel.sent[0..channel.sent_len]);
    try std.testing.expect(worker.hangup_seen and !worker.closed);
    channel.eof = true;
    try worker.pollChannelRead();
    try std.testing.expect(worker.closed);
    // The published frame carries cursor metadata alongside the projected text.
    var frame_scratch: [256]u8 = undefined;
    const payload = (try text.take(0, &frame_scratch)).?;
    const frame = text_frame.decode(payload.text).?;
    try std.testing.expectEqual(@as(u16, 80), frame.cols);
    try std.testing.expectEqual(@as(u16, 24), frame.rows);
    try std.testing.expect(frame.cursor.visible);
}

const InvalidReader = struct {
    pub fn read(_: *anyopaque, buffer: []u8) !Read {
        return .{ .bytes = buffer.len + 1 };
    }
};

test "worker IO rejects invalid channel read counts" {
    var engine: FakeEngine = .{};
    var input = try InputQueue.init(std.testing.allocator, 2);
    defer input.deinit(std.testing.allocator);
    var channel: FakeChannel = .{ .output = "" };
    var invalid: InvalidReader = .{};
    var read_buffer: [2]u8 = undefined;
    var write_buffer: [2]u8 = undefined;
    var worker: WorkerIo = .{
        .feed = .{ .engine = VtEngine.from(FakeEngine, &engine) },
        .input = &input,
        .reader = .{ .ctx = &invalid, .read_fn = InvalidReader.read },
        .writer = .{ .ctx = &channel, .write_fn = FakeChannel.write },
        .read_buffer = &read_buffer,
        .write_buffer = &write_buffer,
    };
    try std.testing.expectError(error.InvalidReadCount, dispatch(.{ .fd = 1, .readable = true }, worker.handler()));
}

test "worker IO drains output beyond a buffer after a hangup before EOF" {
    var engine: FakeEngine = .{};
    var input = try InputQueue.init(std.testing.allocator, 8);
    defer input.deinit(std.testing.allocator);
    var channel: FakeChannel = .{ .output = "abcdefghij", .eof = true };
    var read_buffer: [4]u8 = undefined;
    var write_buffer: [4]u8 = undefined;
    var worker: WorkerIo = .{
        .feed = .{ .engine = VtEngine.from(FakeEngine, &engine) },
        .input = &input,
        .reader = .{ .ctx = &channel, .read_fn = FakeChannel.read },
        .writer = .{ .ctx = &channel, .write_fn = FakeChannel.write },
        .read_buffer = &read_buffer,
        .write_buffer = &write_buffer,
    };
    try dispatch(.{ .fd = 1, .readable = true, .eof = true }, worker.handler());
    try std.testing.expect(worker.hangup_seen and !worker.closed);
    try std.testing.expectEqualStrings("abcd", engine.fed[0..engine.fed_len]);
    try worker.pollChannelRead();
    try std.testing.expect(!worker.closed);
    try worker.pollChannelRead();
    try std.testing.expect(worker.closed);
    try std.testing.expectEqualStrings("abcdefghij", engine.fed[0..engine.fed_len]);
    try std.testing.expectEqual(@as(u64, 10), worker.stream_offset);
    try input.push("late");
    try dispatch(.{ .fd = 1, .writable = true }, worker.handler());
    try std.testing.expectEqual(@as(usize, 0), channel.sent_len);
    try std.testing.expectEqual(@as(usize, 4), input.pending());
    worker.resetTransport(.{ .ctx = &channel, .read_fn = FakeChannel.read }, .{ .ctx = &channel, .write_fn = FakeChannel.write });
    try std.testing.expect(!worker.closed and !worker.hangup_seen);
}

test "worker IO feeds a read prefix and propagates the following transport error" {
    const Failing = struct {
        calls: usize = 0,
        fn read(ctx: *anyopaque, buffer: []u8) !Read {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.calls += 1;
            if (self.calls != 1) return error.TransportFailed;
            @memcpy(buffer[0..3], "end");
            return .{ .bytes = 3 };
        }
    };
    var engine: FakeEngine = .{};
    var input = try InputQueue.init(std.testing.allocator, 2);
    defer input.deinit(std.testing.allocator);
    var reader: Failing = .{};
    var channel: FakeChannel = .{ .output = "" };
    var read_buffer: [8]u8 = undefined;
    var write_buffer: [2]u8 = undefined;
    var worker: WorkerIo = .{
        .feed = .{ .engine = VtEngine.from(FakeEngine, &engine) },
        .input = &input,
        .reader = .{ .ctx = &reader, .read_fn = Failing.read },
        .writer = .{ .ctx = &channel, .write_fn = FakeChannel.write },
        .read_buffer = &read_buffer,
        .write_buffer = &write_buffer,
    };
    try std.testing.expectError(error.TransportFailed, worker.pollChannelRead());
    try std.testing.expectEqualStrings("end", engine.fed[0..engine.fed_len]);
    try std.testing.expectEqual(@as(u64, 3), worker.stream_offset);
}

test "worker IO probe propagates parser errors instead of dropping output silently" {
    var engine: FakeEngine = .{ .fail_feed = true };
    var input = try InputQueue.init(std.testing.allocator, 2);
    defer input.deinit(std.testing.allocator);
    var channel: FakeChannel = .{ .output = "data" };
    var read_buffer: [8]u8 = undefined;
    var write_buffer: [2]u8 = undefined;
    var worker: WorkerIo = .{
        .feed = .{ .engine = VtEngine.from(FakeEngine, &engine) },
        .input = &input,
        .reader = .{ .ctx = &channel, .read_fn = FakeChannel.read },
        .writer = .{ .ctx = &channel, .write_fn = FakeChannel.write },
        .read_buffer = &read_buffer,
        .write_buffer = &write_buffer,
    };
    try std.testing.expectError(error.VtFeedFailed, worker.pollChannelRead());
}
