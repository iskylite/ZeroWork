//! Shared Linux surface/frame ownership.
pub fn For(comptime commands: type) type {
    return struct {
        //! Render-thread frame admission for synchronous Linux GPU submissions. Commands
        //! can be registered before submit; their leases survive caller destruction.

        pub const FrameSync = struct {
            slots: [64]?commands.CommandBuffer = @splat(null),
            capacity: u32,
            head: u32 = 0,
            pending: u32 = 0,
            acquired: u32 = 0,

            pub fn init(capacity: u32) FrameSync {
                if (capacity == 0 or capacity > 64) @panic("invalid Linux GPU frame capacity");
                return .{ .capacity = capacity };
            }
            pub fn collectChecked(self: *FrameSync) !void {
                while (self.pending != 0) {
                    const command = &self.slots[self.head].?;
                    if (command.state == null) return error.InvalidCommandBuffer;
                    if (!command.isCompleted()) return;
                    command.deinit();
                    self.slots[self.head] = null;
                    self.head = (self.head + 1) % self.capacity;
                    self.pending -= 1;
                }
            }
            pub fn waitForNextFrame(self: *FrameSync) !void {
                try self.collectChecked();
                if (self.acquired + self.pending >= self.capacity) {
                    // Submit is synchronous: there is no asynchronous fence to wait
                    // for here. A full ring means its owner has not submitted yet.
                    return if (self.pending != 0) error.CommandNotSubmitted else error.UnbalancedFrameSync;
                }
                self.acquired += 1;
            }
            pub fn signalOnCompletionChecked(self: *FrameSync, command: *const commands.CommandBuffer) !void {
                if (self.acquired == 0) return error.UnbalancedFrameSync;
                const state = command.state orelse return error.InvalidCommandBuffer;
                for (0..self.pending) |i| {
                    if (self.slots[(self.head + i) % self.capacity].?.state == state) return error.CommandAlreadyRegistered;
                }
                self.slots[(self.head + self.pending) % self.capacity] = command.retained();
                self.pending += 1;
                self.acquired -= 1;
            }
            pub fn signalOnCompletion(self: *FrameSync, command: *const commands.CommandBuffer) void {
                self.signalOnCompletionChecked(command) catch @panic("unbalanced Linux GPU frame completion");
            }
            pub fn signalChecked(self: *FrameSync) !void {
                if (self.acquired == 0) return error.UnbalancedFrameSync;
                self.acquired -= 1;
            }
            pub fn signal(self: *FrameSync) void {
                self.signalChecked() catch @panic("unbalanced Linux GPU frame slot return");
            }
            pub fn drainChecked(self: *FrameSync, capacity: u32) !void {
                if (capacity != self.capacity or self.acquired != 0) return error.UnbalancedFrameSync;
                try self.collectChecked();
                if (self.pending != 0) return error.CommandNotSubmitted;
            }
            pub fn drain(self: *FrameSync, capacity: u32) void {
                self.drainChecked(capacity) catch @panic("Linux GPU frames must be submitted before drain");
            }
            pub fn deinitChecked(self: *FrameSync) !void {
                try self.drainChecked(self.capacity);
            }
            pub fn deinit(self: *FrameSync) void {
                self.deinitChecked() catch @panic("Linux GPU FrameSync teardown failed");
            }
        };
    };
}
