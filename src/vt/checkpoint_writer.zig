//! A bounded SPSC recording queue. The SSH owner never waits for disk IO.
//! Overflow stops admission permanently; the writer preserves the accepted
//! prefix, so a missing segment can never be presented as continuous history.
const std = @import("std");
const Controller = @import("checkpoint_controller.zig").Controller;
const Wakeup = @import("../platform/wakeup.zig").Wakeup;
pub const Writer = struct {
    const capacity = 32;
    const Item = struct { bytes: [64 * 1024]u8 = undefined, len: usize, timestamp_ms: i64 };
    allocator: std.mem.Allocator,
    controller: *Controller,
    items: [capacity]Item = undefined,
    write: std.atomic.Value(usize) = .init(0),
    read: std.atomic.Value(usize) = .init(0),
    accepting: std.atomic.Value(bool) = .init(true),
    stopping: std.atomic.Value(bool) = .init(false),
    wake: Wakeup,
    thread: ?std.Thread = null,

    pub fn start(allocator: std.mem.Allocator, controller: *Controller) !*Writer {
        const self = try init(allocator, controller);
        errdefer {
            self.wake.deinit();
            allocator.destroy(self);
        }
        self.thread = try std.Thread.spawn(.{}, run, .{self});
        return self;
    }
    fn init(allocator: std.mem.Allocator, controller: *Controller) !*Writer {
        const self = try allocator.create(Writer);
        errdefer allocator.destroy(self);
        self.* = .{ .allocator = allocator, .controller = controller, .wake = try Wakeup.init() };
        return self;
    }
    pub fn append(self: *Writer, bytes: []const u8, timestamp_ms: i64) !void {
        if (!self.accepting.load(.acquire)) return error.RecordingUnavailable;
        const write = self.write.load(.monotonic);
        if (write -% self.read.load(.acquire) == capacity or bytes.len > self.items[0].bytes.len) {
            self.accepting.store(false, .release);
            return error.RecordingQueueFull;
        }
        const item = &self.items[write % capacity];
        @memcpy(item.bytes[0..bytes.len], bytes);
        item.len = bytes.len;
        item.timestamp_ms = timestamp_ms;
        self.write.store(write +% 1, .release);
        self.wake.notify();
    }
    /// The producer must have stopped before this call. Drain before the
    /// controller, IO runtime, directory or checkpoint path can be destroyed.
    pub fn deinit(self: *Writer) void {
        self.stopping.store(true, .release);
        self.wake.notify();
        if (self.thread) |thread| thread.join() else self.run();
        self.wake.deinit();
        self.allocator.destroy(self);
    }
    fn run(self: *Writer) void {
        var disk_failed = false;
        while (true) {
            const read = self.read.load(.monotonic);
            if (read != self.write.load(.acquire)) {
                const item = &self.items[read % capacity];
                if (!disk_failed) _ = self.controller.append(item.bytes[0..item.len], item.timestamp_ms) catch |err| stop: {
                    disk_failed = true;
                    self.accepting.store(false, .release);
                    std.log.warn("[worker] recording stopped: {s}", .{@errorName(err)});
                    break :stop false;
                };
                self.read.store(read +% 1, .release);
                continue;
            }
            if (self.stopping.load(.acquire)) return;
            self.wake.wait(-1, false, 1000);
        }
    }
};

test "checkpoint writer drains in order before controller closes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var controller = try Controller.init(std.testing.allocator, 16, 1, 0, std.testing.io, tmp.dir, "checkpoint");
    defer controller.deinit();
    try controller.enableRawFile("stream");
    const writer = try Writer.start(std.testing.allocator, &controller);
    try writer.append("abc", 1);
    try writer.append("def", 1001);
    writer.deinit();
    const raw = try Controller.loadRaw(std.testing.allocator, std.testing.io, tmp.dir, "stream", 16);
    defer std.testing.allocator.free(raw);
    try std.testing.expectEqualStrings("abcdef", raw);
}

test "checkpoint writer overflow is sticky and retains only accepted prefix" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var controller = try Controller.init(std.testing.allocator, 64, 1, 0, std.testing.io, tmp.dir, "checkpoint");
    defer controller.deinit();
    const writer = try Writer.init(std.testing.allocator, &controller);
    for (0..Writer.capacity) |_| try writer.append("a", 0);
    try std.testing.expectError(error.RecordingQueueFull, writer.append("missing", 0));
    try std.testing.expectError(error.RecordingUnavailable, writer.append("later", 0));
    writer.deinit();
    try std.testing.expectEqual(@as(u64, Writer.capacity), controller.tap.sequence);
}
