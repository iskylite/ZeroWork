const std = @import("std");
const Window = @import("transfer_window.zig").Window;
const Chunk = @import("transfer_window.zig").Chunk;
const Pacer = @import("transfer_pacer.zig").Pacer;

pub const Coordinator = struct {
    window: Window,
    pacer: Pacer,

    pub fn init(total_bytes: u64, chunk_bytes: u32, capacity: u16, target_kbps: u32) !Coordinator {
        return .{ .window = try Window.init(total_bytes, chunk_bytes, capacity), .pacer = try Pacer.init(target_kbps) };
    }

    pub fn next(self: *Coordinator) ?Chunk {
        return self.window.next();
    }

    pub fn canSend(self: Coordinator, chunk: Chunk) bool {
        return self.pacer.delayMs(chunk.len) == 0;
    }

    pub fn record(self: *Coordinator, chunk: Chunk, elapsed_ms: u64) !void {
        try self.window.ack(chunk.index);
        self.pacer.record(chunk.len, elapsed_ms);
    }

    pub fn resumeAt(self: *Coordinator, offset: u64) !void {
        try self.window.resumeAt(offset);
    }
    pub fn complete(self: Coordinator) bool {
        return self.window.complete();
    }
};

test "coordinator combines ACK window and pacing" {
    var transfer = try Coordinator.init(8, 4, 2, 1024);
    const first = transfer.next().?;
    try std.testing.expect(transfer.canSend(first));
    try transfer.record(first, 1);
    const second = transfer.next().?;
    try transfer.record(second, 1);
    try std.testing.expect(transfer.complete());
}
