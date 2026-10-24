const std = @import("std");
const InputQueue = @import("input_queue.zig").InputQueue;

pub const ChannelWriter = struct {
    ctx: *anyopaque,
    write_fn: *const fn (*anyopaque, []const u8) anyerror!usize,

    pub fn write(self: ChannelWriter, bytes: []const u8) !usize {
        return self.write_fn(self.ctx, bytes);
    }
};

/// Worker-side input pump. Bytes leave the queue only after the channel confirms them.
pub const PumpResult = union(enum) { empty, would_block, wrote: usize };

pub fn pumpInput(queue: *InputQueue, writer: ChannelWriter, scratch: []u8) !PumpResult {
    const pending = queue.peek(scratch);
    if (pending.len == 0) return .empty;
    const written = try writer.write(pending);
    if (written > pending.len) return error.InvalidWriteCount;
    if (written == 0) return .would_block;
    try queue.consume(written);
    return .{ .wrote = written };
}

/// Drain until empty or the channel stops making progress. Iteration is bounded
/// so a continuously refilled queue cannot starve socket reads.
pub fn pumpInputBatch(queue: *InputQueue, writer: ChannelWriter, scratch: []u8, max_iterations: usize) !BatchResult {
    if (max_iterations == 0) return error.InvalidIterationLimit;
    var total: usize = 0;
    for (0..max_iterations) |_| switch (try pumpInput(queue, writer, scratch)) {
        .empty => return .{ .written = total, .state = .empty },
        .would_block => return .{ .written = total, .state = .would_block },
        .wrote => |count| total += count,
    };
    return .{ .written = total, .state = .iteration_limit };
}

pub const BatchResult = struct {
    written: usize,
    state: enum { empty, would_block, iteration_limit },
};

const PartialWriter = struct {
    limit: usize,
    received: [16]u8 = undefined,
    len: usize = 0,
    pub fn write(ctx: *anyopaque, bytes: []const u8) !usize {
        const self: *PartialWriter = @ptrCast(@alignCast(ctx));
        const count = @min(self.limit, bytes.len);
        @memcpy(self.received[self.len .. self.len + count], bytes[0..count]);
        self.len += count;
        return count;
    }
};

test "channel pump preserves bytes across partial writes" {
    var queue = try InputQueue.init(std.testing.allocator, 8);
    defer queue.deinit(std.testing.allocator);
    try queue.push("hello");
    var partial: PartialWriter = .{ .limit = 2 };
    const writer: ChannelWriter = .{ .ctx = &partial, .write_fn = PartialWriter.write };
    var scratch: [8]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 2), (try pumpInput(&queue, writer, &scratch)).wrote);
    partial.limit = 8;
    try std.testing.expectEqual(@as(usize, 3), (try pumpInput(&queue, writer, &scratch)).wrote);
    try std.testing.expectEqualStrings("hello", partial.received[0..partial.len]);
    try std.testing.expectEqual(PumpResult.empty, try pumpInput(&queue, writer, &scratch));
}

const FailingWriter = struct {
    pub fn write(_: *anyopaque, _: []const u8) !usize {
        return error.WouldBlock;
    }
};

const InvalidWriter = struct {
    pub fn write(_: *anyopaque, bytes: []const u8) !usize {
        return bytes.len + 1;
    }
};

test "channel batch drain is bounded and reports completion" {
    var queue = try InputQueue.init(std.testing.allocator, 8);
    defer queue.deinit(std.testing.allocator);
    try queue.push("hello");
    var partial: PartialWriter = .{ .limit = 2 };
    var scratch: [8]u8 = undefined;
    const limited = try pumpInputBatch(&queue, .{ .ctx = &partial, .write_fn = PartialWriter.write }, &scratch, 2);
    try std.testing.expectEqual(@as(usize, 4), limited.written);
    try std.testing.expectEqual(.iteration_limit, limited.state);
    const completed = try pumpInputBatch(&queue, .{ .ctx = &partial, .write_fn = PartialWriter.write }, &scratch, 2);
    try std.testing.expectEqual(@as(usize, 1), completed.written);
    try std.testing.expectEqual(.empty, completed.state);
}

test "channel pump reports zero-progress would block" {
    var queue = try InputQueue.init(std.testing.allocator, 8);
    defer queue.deinit(std.testing.allocator);
    try queue.push("wait");
    var partial: PartialWriter = .{ .limit = 0 };
    var scratch: [8]u8 = undefined;
    try std.testing.expectEqual(PumpResult.would_block, try pumpInput(&queue, .{ .ctx = &partial, .write_fn = PartialWriter.write }, &scratch));
    try std.testing.expectEqualStrings("wait", queue.peek(&scratch));
}

test "channel pump retains input on writer failure" {
    var queue = try InputQueue.init(std.testing.allocator, 8);
    defer queue.deinit(std.testing.allocator);
    try queue.push("retry");
    var failing: FailingWriter = .{};
    var scratch: [8]u8 = undefined;
    try std.testing.expectError(error.WouldBlock, pumpInput(&queue, .{ .ctx = &failing, .write_fn = FailingWriter.write }, &scratch));
    try std.testing.expectEqualStrings("retry", queue.peek(&scratch));
}

test "channel pump rejects invalid channel write counts" {
    var queue = try InputQueue.init(std.testing.allocator, 8);
    defer queue.deinit(std.testing.allocator);
    try queue.push("input");
    var invalid: InvalidWriter = .{};
    var scratch: [8]u8 = undefined;
    try std.testing.expectError(error.InvalidWriteCount, pumpInput(&queue, .{ .ctx = &invalid, .write_fn = InvalidWriter.write }, &scratch));
    try std.testing.expectEqualStrings("input", queue.peek(&scratch));
}
