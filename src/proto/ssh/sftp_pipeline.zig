const std = @import("std");
const Coordinator = @import("transfer_coordinator.zig").Coordinator;
const Chunk = @import("transfer_window.zig").Chunk;

pub const Io = struct {
    ctx: *anyopaque,
    read_chunk: *const fn (*anyopaque, Chunk, []u8) anyerror!usize,
    write_chunk: *const fn (*anyopaque, Chunk, []const u8) anyerror!void,
};

pub const Pipeline = struct {
    coordinator: Coordinator,
    io: Io,
    buffer: []u8,
    pending: ?Chunk = null,

    pub fn init(coordinator: Coordinator, io: Io, buffer: []u8) !Pipeline {
        if (buffer.len == 0) return error.EmptyBuffer;
        return .{ .coordinator = coordinator, .io = io, .buffer = buffer };
    }

    pub fn step(self: *Pipeline, elapsed_ms: u64) !bool {
        const chunk = self.pending orelse self.coordinator.next() orelse return self.coordinator.complete();
        self.pending = chunk;
        if (!self.coordinator.canSend(chunk)) return false;
        if (chunk.len > self.buffer.len) return error.BufferTooSmall;
        const count = try self.io.read_chunk(self.io.ctx, chunk, self.buffer[0..chunk.len]);
        if (count != chunk.len) return error.ShortRead;
        try self.io.write_chunk(self.io.ctx, chunk, self.buffer[0..count]);
        try self.coordinator.record(chunk, elapsed_ms);
        self.pending = null;
        return self.coordinator.complete();
    }
};
