//! Worker-to-UI owned text batches. Neither thread borrows the other's bytes.
const std = @import("std");
pub const Batch = struct { reset: bool, bytes: []u8, thinking: []u8 };
pub const Mailbox = struct {
    allocator: std.mem.Allocator,
    mutex: std.atomic.Mutex = .unlocked,
    pending: std.ArrayList(u8) = .empty,
    reset_pending: bool = false,
    thinking: std.ArrayList(u8) = .empty,
    total_bytes: usize = 0,
    pub const limit = 8 * 1024 * 1024;
    pub fn init(allocator: std.mem.Allocator) Mailbox {
        return .{ .allocator = allocator };
    }
    fn lock(self: *Mailbox) void {
        while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
    }
    pub fn reset(self: *Mailbox) void {
        self.lock();
        defer self.mutex.unlock();
        self.pending.clearRetainingCapacity();
        self.thinking.clearRetainingCapacity();
        self.total_bytes = 0;
        self.reset_pending = true;
    }
    pub fn append(self: *Mailbox, bytes: []const u8) !void {
        self.lock();
        defer self.mutex.unlock();
        if (bytes.len > limit -| self.total_bytes) return error.StreamTooLarge;
        try self.pending.appendSlice(self.allocator, bytes);
        self.total_bytes += bytes.len;
    }
    pub fn appendThinking(self: *Mailbox, bytes: []const u8) !void {
        self.lock();
        defer self.mutex.unlock();
        if (bytes.len > limit -| self.total_bytes) return error.StreamTooLarge;
        try self.thinking.appendSlice(self.allocator, bytes);
        self.total_bytes += bytes.len;
    }
    pub fn drain(self: *Mailbox) !?Batch {
        self.lock();
        defer self.mutex.unlock();
        if (!self.reset_pending and self.pending.items.len == 0 and self.thinking.items.len == 0) return null;
        const thinking = try self.thinking.toOwnedSlice(self.allocator);
        errdefer self.allocator.free(thinking);
        const bytes = try self.pending.toOwnedSlice(self.allocator);
        const reset_pending = self.reset_pending;
        self.reset_pending = false;
        return .{ .reset = reset_pending, .bytes = bytes, .thinking = thinking };
    }
    /// Terminal owner calls this only after joining the producer.
    pub fn discard(self: *Mailbox) void {
        self.lock();
        defer self.mutex.unlock();
        self.pending.clearRetainingCapacity();
        self.thinking.clearRetainingCapacity();
        self.reset_pending = false;
        self.total_bytes = 0;
    }
    /// Caller joins the producer before teardown.
    pub fn deinit(self: *Mailbox) void {
        self.pending.deinit(self.allocator);
        self.thinking.deinit(self.allocator);
    }
};

test "stream mailbox copies worker fragments and resets retry output atomically" {
    var mailbox = Mailbox.init(std.testing.allocator);
    defer mailbox.deinit();
    mailbox.reset();
    var source = "first".*;
    try mailbox.append(&source);
    @memset(&source, 'x');
    const first = (try mailbox.drain()).?;
    defer std.testing.allocator.free(first.bytes);
    defer std.testing.allocator.free(first.thinking);
    try std.testing.expect(first.reset);
    try std.testing.expectEqualStrings("first", first.bytes);
    try mailbox.append("stale");
    mailbox.reset();
    try mailbox.append("retry");
    const second = (try mailbox.drain()).?;
    defer std.testing.allocator.free(second.bytes);
    defer std.testing.allocator.free(second.thinking);
    try std.testing.expect(second.reset);
    try std.testing.expectEqualStrings("retry", second.bytes);
    try std.testing.expect((try mailbox.drain()) == null);
    mailbox.total_bytes = Mailbox.limit;
    try std.testing.expectError(error.StreamTooLarge, mailbox.append("!"));
    mailbox.discard();
    try std.testing.expect((try mailbox.drain()) == null);
    try mailbox.append("next");
    const next = (try mailbox.drain()).?;
    defer std.testing.allocator.free(next.bytes);
    defer std.testing.allocator.free(next.thinking);
    try std.testing.expect(!next.reset);
    try std.testing.expectEqualStrings("next", next.bytes);
}

test "stream mailbox delivers before producer EOF and cancellation joins before teardown" {
    const Producer = struct {
        mailbox: *Mailbox,
        ready: std.atomic.Value(bool) = .init(false),
        release_tail: std.atomic.Value(bool) = .init(false),
        cancel: @import("provider.zig").CancelToken = .{},
        done: std.atomic.Value(bool) = .init(false),
        failure: ?anyerror = null,

        fn run(self: *@This()) void {
            defer self.done.store(true, .release);
            self.mailbox.reset();
            var first = "first".*;
            self.mailbox.append(&first) catch |err| {
                self.failure = err;
                return;
            };
            @memset(&first, 'x');
            self.ready.store(true, .release);
            while (!self.release_tail.load(.acquire)) {
                if (self.cancel.isCancelled()) return;
                std.Thread.yield() catch {};
            }
            if (self.cancel.isCancelled()) return;
            self.mailbox.append("last") catch |err| {
                self.failure = err;
            };
        }
    };
    for ([_]bool{ false, true }) |stop| {
        var mailbox = Mailbox.init(std.testing.allocator);
        defer mailbox.deinit();
        var producer: Producer = .{ .mailbox = &mailbox };
        const thread = try std.Thread.spawn(.{}, Producer.run, .{&producer});
        var joined = false;
        defer if (!joined) {
            producer.cancel.cancel();
            thread.join();
        };
        const started = std.Io.Clock.Timestamp.now(std.testing.io, .awake);
        while (!producer.ready.load(.acquire)) {
            if (producer.done.load(.acquire)) return error.ProducerFailed;
            if (started.durationTo(std.Io.Clock.Timestamp.now(std.testing.io, .awake)).raw.toMilliseconds() > 2000) return error.ProducerDidNotStart;
            std.Thread.yield() catch {};
        }
        const first = (try mailbox.drain()).?;
        defer std.testing.allocator.free(first.bytes);
        defer std.testing.allocator.free(first.thinking);
        try std.testing.expect(first.reset);
        try std.testing.expectEqualStrings("first", first.bytes);
        // This assertion is deterministic: the producer cannot finish until
        // this consumer either releases its tail or sends cancellation.
        try std.testing.expect(!producer.done.load(.acquire));
        if (stop) producer.cancel.cancel() else producer.release_tail.store(true, .release);
        thread.join();
        joined = true;
        try std.testing.expect(producer.done.load(.acquire));
        try std.testing.expect(producer.failure == null);
        if (!stop) {
            const final = (try mailbox.drain()).?;
            defer std.testing.allocator.free(final.bytes);
            defer std.testing.allocator.free(final.thinking);
            try std.testing.expect(!final.reset);
            try std.testing.expectEqualStrings("last", final.bytes);
        }
        try std.testing.expect((try mailbox.drain()) == null);
        // The deferred mailbox teardown runs only after the producer join.
    }
}
