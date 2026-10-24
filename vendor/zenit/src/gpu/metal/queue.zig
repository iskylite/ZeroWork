/// Metal Queue implementation
///
/// Used to submit command buffers
const mtl = @import("metal_bindings.zig");

pub const Queue = struct {
    raw: *mtl.MTLCommandQueue,

    pub fn submit(self: *Queue, commands: []const CommandBuffer) void {
        _ = self;
        for (commands) |cmd| {
            mtl.metal_command_buffer_commit(cmd.raw);
        }
    }

    pub fn deinit(self: *Queue) void {
        mtl.release(self.raw);
    }
};

// Placeholder type (implemented in Phase 4)
pub const CommandBuffer = struct {
    raw: *mtl.MTLCommandBuffer,
};
