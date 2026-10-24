const std = @import("std");
const Pipeline = @import("sftp_pipeline.zig").Pipeline;
const Io = @import("sftp_pipeline.zig").Io;
const Chunk = @import("transfer_window.zig").Chunk;

const Memory = struct { bytes: []const u8, output: [64]u8 = undefined, out_len: usize = 0, reads: usize = 0 };
fn read(ctx: *anyopaque, chunk: Chunk, out: []u8) !usize {
    const self: *Memory = @ptrCast(@alignCast(ctx));
    self.reads += 1;
    @memcpy(out, self.bytes[chunk.offset .. chunk.offset + chunk.len]);
    return chunk.len;
}
fn write(ctx: *anyopaque, chunk: Chunk, bytes: []const u8) !void {
    const self: *Memory = @ptrCast(@alignCast(ctx));
    @memcpy(self.output[chunk.offset .. chunk.offset + bytes.len], bytes);
    self.out_len = @max(self.out_len, chunk.offset + bytes.len);
}

test "sftp pipeline drives coordinator over generic IO" {
    var memory: Memory = .{ .bytes = "abcdefgh" };
    var buffer: [4]u8 = undefined;
    var pipeline = try Pipeline.init(try @import("transfer_coordinator.zig").Coordinator.init(8, 4, 2, 1024), .{ .ctx = &memory, .read_chunk = read, .write_chunk = write }, &buffer);
    _ = try pipeline.step(1);
    const complete = try pipeline.step(1);
    try std.testing.expect(complete);
    try std.testing.expectEqualStrings("abcdefgh", memory.output[0..memory.out_len]);
}

test "sftp pipeline rejects buffers smaller than a chunk without losing work" {
    var memory: Memory = .{ .bytes = "abcdefgh" };
    var buffer: [2]u8 = undefined;
    var pipeline = try Pipeline.init(try @import("transfer_coordinator.zig").Coordinator.init(8, 4, 2, 1024), .{ .ctx = &memory, .read_chunk = read, .write_chunk = write }, &buffer);
    try std.testing.expectError(error.BufferTooSmall, pipeline.step(1));
    try std.testing.expectEqual(@as(usize, 0), memory.reads);
    try std.testing.expectEqual(@as(u64, 0), pipeline.coordinator.window.acknowledged);
}
