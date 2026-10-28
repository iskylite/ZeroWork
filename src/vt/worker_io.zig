const std = @import("std");
const FeedBridge = @import("feed_bridge.zig").FeedBridge;
const InputQueue = @import("input_queue.zig").InputQueue;
const ChannelWriter = @import("channel_pump.zig").ChannelWriter;
const Handler = @import("worker_dispatch.zig").Handler;
const Timeline = @import("timeline.zig").Timeline;
const CheckpointController = @import("checkpoint_controller.zig").Controller;
const output_timing = @import("output_timing.zig");
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
    output_filter: ?struct { context: *anyopaque, feed: *const fn (*anyopaque, *WorkerIo, []const u8) anyerror!void, finish: ?*const fn (*anyopaque, *WorkerIo) anyerror!void = null } = null,
    feed: FeedBridge,
    input: *InputQueue,
    reader: ChannelReader,
    writer: ChannelWriter,
    read_buffer: []u8,
    write_buffer: []u8,
    // A native EAGAIN retry must retain the exact pointer, length and bytes.
    write_len: usize = 0,
    write_blocked: bool = false,
    timeline: ?*Timeline = null,
    checkpoint: ?*CheckpointController = null,
    checkpoint_writer: ?*@import("checkpoint_writer.zig").Writer = null,
    stream_offset: u64 = 0,
    reply_buffer: [4096]u8 = undefined,
    reply_len: usize = 0,
    reply_offset: usize = 0,
    timestamp_ctx: ?*anyopaque = null,
    timestamp_fn: ?TimestampFn = null,
    closed: bool = false,
    /// A readiness EOF is only a hangup hint. Buffered protocol/PTY bytes
    /// remain readable until the transport itself returns .eof.
    hangup_seen: bool = false,
    /// A full batch does not prove libssh2's internal packet queue is empty.
    /// Continue on the next worker turn without waiting for socket readiness.
    read_budget_exhausted: bool = false,
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
        self.read_budget_exhausted = false;
        if (self.closed) return;
        if (self.read_buffer.len == 0) return error.EmptyReadBuffer;
        const started = if (output_timing.enabled) output_timing.now() else 0;
        var retries: u32 = 0;
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
                    if (output_timing.enabled) retries += 1;
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

        self.read_budget_exhausted = total == self.read_buffer.len and !eof and read_error == null;
        const parsed = if (output_timing.enabled) output_timing.now() else 0;
        defer if (output_timing.enabled) output_timing.read(@intFromPtr(self), started, parsed, total, if (read_error != null) "error" else if (eof) "eof" else if (total == self.read_buffer.len) "full" else "would_block", retries);
        // Never discard a successfully read prefix when a later read reports
        // EOF or an error. Publication backpressure is handled by FeedBridge;
        // an actual parser failure must reach the owning worker.
        if (total != 0) {
            if (self.output_filter) |filter| try filter.feed(filter.context, self, self.read_buffer[0..total]) else try self.feedOutput(self.read_buffer[0..total]);
        }
        if (eof or read_error != null) if (self.output_filter) |filter| if (filter.finish) |finish| try finish(filter.context, self);
        if (eof) self.closed = true;
        if (read_error) |err| return err;
    }

    pub fn feedOutput(self: *WorkerIo, bytes: []const u8) !void {
        if (@import("input_timing.zig").enabled) if (self.feed.text_slot) |slot| slot.timing.received(self.feed.engine.snapshot().output_sequence + 1);
        self.last_output_ns = @import("../platform/realtime.zig").monotonicNs();
        const timestamp_ms = if (self.timestamp_fn) |timestamp_fn| timestamp_fn(self.timestamp_ctx orelse unreachable) else 0;
        // Session-recording side effects are best-effort: a timeline or
        // checkpoint failure (disk, capacity) must never tear down the live
        // terminal connection — display is the primary path.
        if (self.timeline) |timeline| timeline.append(timestamp_ms, self.stream_offset, bytes) catch |err| {
            std.log.warn("[worker] timeline append dropped: {s}", .{@errorName(err)});
            self.timeline = null;
        };
        if (self.checkpoint_writer) |writer| writer.append(bytes, timestamp_ms) catch |err| {
            std.log.warn("[worker] recording queue stopped: {s}", .{@errorName(err)});
            self.checkpoint_writer = null;
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
        try self.pumpWrites();
    }

    pub fn repliesPending(self: *const WorkerIo) bool {
        return self.reply_offset < self.reply_len;
    }
    /// Replies share the sole SSH writer, not the UI/reconnect input queue.
    /// Finish a started reply before keys; drain queued user bytes before
    /// starting a reply so UTF-8 and bracketed pastes are never bisected.
    pub fn pumpWrites(self: *WorkerIo) !void {
        if (self.closed) return;
        self.write_blocked = false;
        if (!self.repliesPending()) {
            for (0..4) |_| {
                if (self.write_len == 0) self.write_len = self.input.peek(self.write_buffer).len;
                if (self.write_len == 0) break;
                const count = try self.writer.write(self.write_buffer[0..self.write_len]);
                if (count > self.write_len) return error.InvalidWriteCount;
                if (count == 0) {
                    self.write_blocked = true;
                    return;
                }
                try self.input.consume(count);
                if (self.feed.text_slot) |slot| slot.timing.written(0, self.input.read_index.load(.acquire));
                // A positive result completes this call; the next call may
                // take a new queue snapshot, including newly arrived keys.
                self.write_len = 0;
            }
            if (self.input.pending() != 0) return;
            self.reply_len = try self.feed.engine.readReply(&self.reply_buffer);
            self.reply_offset = 0;
        }
        if (self.repliesPending()) {
            const bytes = self.reply_buffer[self.reply_offset..self.reply_len];
            const count = try self.writer.write(bytes);
            if (count > bytes.len) return error.InvalidWriteCount;
            self.reply_offset += count;
            self.write_blocked = count == 0;
        }
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
    pub fn readTimeout(self: *const WorkerIo, timeout_ms: u32) u32 {
        return if (self.read_budget_exhausted) 0 else timeout_ms;
    }
    fn onClosed(ctx: *anyopaque) void {
        @as(*WorkerIo, @ptrCast(@alignCast(ctx))).hangup_seen = true;
    }

    pub fn resetTransport(self: *WorkerIo, reader: ChannelReader, writer: ChannelWriter) void {
        self.read_budget_exhausted = false;
        if (self.output_filter) |filter| if (filter.finish) |finish| finish(filter.context, self) catch {};
        self.write_len = 0;
        self.write_blocked = false;
        self.reply_offset = 0;
        self.reply_len = 0;
        // Old peer queries never become input to a successor shell.
        while ((self.feed.engine.readReply(&self.reply_buffer) catch 0) != 0) {}
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
    replies: []const u8 = "",
    pub fn readReply(self: *FakeEngine, buffer: []u8) !usize {
        const count = @min(self.replies.len, buffer.len);
        @memcpy(buffer[0..count], self.replies[0..count]);
        self.replies = self.replies[count..];
        return count;
    }
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
    sent: [128]u8 = undefined,
    write_limit: usize = std.math.maxInt(usize),
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
        const count = @min(bytes.len, self.write_limit);
        @memcpy(self.sent[self.sent_len .. self.sent_len + count], bytes[0..count]);
        self.sent_len += count;
        return count;
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

test "worker IO sends VT replies through partial writes without bisecting paste or replaying old replies" {
    const a = std.testing.allocator;
    var engine: FakeEngine = .{ .replies = "\x1b[1;1R" };
    var input = try InputQueue.init(a, 128);
    defer input.deinit(a);
    const paste = "\x1b[200~ABC\x1b[201~";
    try input.push(paste);
    var channel: FakeChannel = .{ .output = "", .write_limit = 2 };
    var read_buffer: [16]u8 = undefined;
    var write_buffer: [16]u8 = undefined;
    var worker: WorkerIo = .{ .feed = .{ .engine = VtEngine.from(FakeEngine, &engine) }, .input = &input, .reader = .{ .ctx = &channel, .read_fn = FakeChannel.read }, .writer = .{ .ctx = &channel, .write_fn = FakeChannel.write }, .read_buffer = &read_buffer, .write_buffer = &write_buffer };
    var inserted = false;
    for (0..32) |_| {
        try worker.pumpWrites();
        if (!inserted and input.pending() == 0 and worker.repliesPending()) {
            inserted = true;
            try input.push("KEY");
            channel.write_limit = 0;
            const previous = channel.sent_len;
            try worker.pumpWrites();
            try std.testing.expectEqual(previous, channel.sent_len);
            try std.testing.expect(worker.repliesPending());
            channel.write_limit = 2;
        }
    }
    try std.testing.expect(inserted);
    try std.testing.expectEqualStrings(paste ++ "\x1b[1;1RKEY", channel.sent[0..channel.sent_len]);
    engine.replies = "OLD_PEER_QUERY_REPLY";
    worker.resetTransport(worker.reader, worker.writer);
    try worker.pumpWrites();
    try std.testing.expectEqualStrings(paste ++ "\x1b[1;1RKEY", channel.sent[0..channel.sent_len]);
}

test "worker IO pins an EAGAIN write while new input arrives" {
    const RetryWriter = struct {
        bytes: [32]u8 = undefined,
        length: usize = 0,
        address: usize = 0,
        retry: bool = false,
        accepted: [64]u8 = undefined,
        used: usize = 0,
        fn write(raw: *anyopaque, bytes: []const u8) !usize {
            const self: *@This() = @ptrCast(@alignCast(raw));
            if (!self.retry and self.used == 0) {
                self.length = bytes.len;
                self.address = @intFromPtr(bytes.ptr);
                @memcpy(self.bytes[0..bytes.len], bytes);
                self.retry = true;
                return 0;
            }
            if (self.retry) {
                try std.testing.expectEqual(self.address, @intFromPtr(bytes.ptr));
                try std.testing.expectEqualStrings(self.bytes[0..self.length], bytes);
                self.retry = false;
            }
            @memcpy(self.accepted[self.used..][0..bytes.len], bytes);
            self.used += bytes.len;
            return bytes.len;
        }
    };
    var input = try InputQueue.init(std.testing.allocator, 64);
    defer input.deinit(std.testing.allocator);
    var engine: FakeEngine = .{};
    var channel: FakeChannel = .{ .output = "" };
    var writer: RetryWriter = .{};
    var read_buffer: [32]u8 = undefined;
    var write_buffer: [32]u8 = undefined;
    var worker: WorkerIo = .{ .feed = .{ .engine = VtEngine.from(FakeEngine, &engine) }, .input = &input, .reader = .{ .ctx = &channel, .read_fn = FakeChannel.read }, .writer = .{ .ctx = &writer, .write_fn = RetryWriter.write }, .read_buffer = &read_buffer, .write_buffer = &write_buffer };
    try input.push("first");
    try worker.pumpWrites();
    try std.testing.expect(worker.write_blocked);
    try input.push("second");
    try worker.pumpWrites();
    try std.testing.expectEqualStrings("firstsecond", writer.accepted[0..writer.used]);
    try std.testing.expect(!worker.write_blocked);
    try std.testing.expectEqual(@as(usize, 0), input.pending());
}

test "worker IO drains buffered packets after socket readiness disappears without timer pacing" {
    const BufferedChannel = struct {
        channel: FakeChannel = .{ .output = "abcdefghijklmn" },
        fd: i32,
        signal_consumed: bool = false,
        fn read(ctx: *anyopaque, buffer: []u8) !Read {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            if (!self.signal_consumed) {
                var signal: [1]u8 = undefined;
                if (std.c.read(self.fd, &signal, 1) != 1) return error.ReadFailed;
                self.signal_consumed = true;
            }
            return FakeChannel.read(&self.channel, buffer);
        }
    };
    var pipe: [2]c_int = undefined;
    if (std.c.pipe(&pipe) != 0) return error.PipeFailed;
    defer _ = std.c.close(pipe[0]);
    defer _ = std.c.close(pipe[1]);
    var channel: BufferedChannel = .{ .fd = pipe[0] };
    var engine: FakeEngine = .{};
    var input = try InputQueue.init(std.testing.allocator, 8);
    defer input.deinit(std.testing.allocator);
    var read_buffer: [4]u8 = undefined;
    var write_buffer: [4]u8 = undefined;
    var worker: WorkerIo = .{
        .feed = .{ .engine = VtEngine.from(FakeEngine, &engine) },
        .input = &input,
        .reader = .{ .ctx = &channel, .read_fn = BufferedChannel.read },
        .writer = .{ .ctx = &channel.channel, .write_fn = FakeChannel.write },
        .read_buffer = &read_buffer,
        .write_buffer = &write_buffer,
    };
    var loop = try @import("worker_loop.zig").Loop.init(pipe[0], worker.handler());
    defer loop.deinit();
    try loop.setInterest(.{ .read = true });
    try std.testing.expectEqual(@as(isize, 1), std.c.write(pipe[1], "x", 1));
    const started = output_timing.now();
    try loop.step(worker.readTimeout(1000)); // The sole socket wakeup.
    try worker.pollChannelRead();
    try std.testing.expect(worker.read_budget_exhausted);
    while (worker.read_budget_exhausted) {
        try loop.step(worker.readTimeout(1000)); // No socket bytes remain.
        try worker.pollChannelRead();
    }
    try std.testing.expect(output_timing.now() - started < std.time.ns_per_s);
    try std.testing.expectEqualStrings("abcdefghijklmn", engine.fed[0..engine.fed_len]);
    try std.testing.expectEqual(@as(u32, 1000), worker.readTimeout(1000));
    // Transport replacement must not inherit the previous queue's state.
    worker.read_budget_exhausted = true;
    worker.resetTransport(worker.reader, worker.writer);
    try std.testing.expectEqual(@as(u32, 1000), worker.readTimeout(1000));
}
