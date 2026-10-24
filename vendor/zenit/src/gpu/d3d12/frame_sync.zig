//! Render-thread confined frame slots. Retained commands pin Context until the
//! ordered GPU fence completes; no worker thread touches non-atomic owners.
const std = @import("std");
const commands = @import("renderer_commands.zig");
/// A frame-slot wait is sliced so a long GPU frame is logged, never fatal: a
/// software adapter (WARP) legitimately spends seconds on a heavy frame. A real
/// hang ends in TDR, which the fence reports as device loss.
const wait_slice_ms: u32 = 1000;
pub const FrameSync = struct {
    const max_slots = 64;
    slots: [max_slots]?commands.CommandBuffer = @splat(null),
    capacity: u32,
    inflight_limit: u32,
    head: u32 = 0,
    pending: u32 = 0,
    acquired: u32 = 0,
    pub fn init(max_frames_in_flight: u32) FrameSync {
        return initWithLimit(max_frames_in_flight, max_frames_in_flight);
    }
    /// Keep resource-slot indexing stable while limiting queued work on slow
    /// software adapters. Reducing admission never permits early resource reuse.
    pub fn initWithLimit(storage_slots: u32, inflight_limit: u32) FrameSync {
        if (storage_slots == 0 or storage_slots > max_slots or inflight_limit == 0 or inflight_limit > storage_slots)
            @panic("invalid D3D12 frame slot capacity/limit");
        return .{ .capacity = storage_slots, .inflight_limit = inflight_limit };
    }
    fn releaseHead(self: *FrameSync) void {
        self.slots[self.head].?.deinit();
        self.slots[self.head] = null;
        self.head = (self.head + 1) % self.capacity;
        self.pending -= 1;
    }
    pub fn collectChecked(self: *FrameSync) !void {
        while (self.pending > 0) {
            self.slots[self.head].?.waitChecked(0) catch |err| switch (err) {
                error.GpuTimeout, error.CommandNotSubmitted => return,
                else => return err,
            };
            self.releaseHead();
        }
    }
    pub fn waitForNextFrameChecked(self: *FrameSync, timeout_ms: u32) !void {
        try self.collectChecked();
        if (self.acquired + self.pending == self.inflight_limit) {
            if (self.pending == 0) return error.UnbalancedFrameSync;
            try self.slots[self.head].?.waitChecked(timeout_ms);
            self.releaseHead();
            try self.collectChecked();
        }
        self.acquired += 1;
    }
    /// Waits for a slot without a deadline. Device loss releases every pending
    /// slot (the GPU will never complete them) and returns error.DeviceLost.
    pub fn waitForNextFrame(self: *FrameSync) !void {
        var waited_ms: u64 = 0;
        while (true) {
            self.waitForNextFrameChecked(wait_slice_ms) catch |err| switch (err) {
                error.GpuTimeout => {
                    waited_ms += wait_slice_ms;
                    if (waited_ms == wait_slice_ms or waited_ms % 10_000 == 0)
                        std.log.warn("[d3d12] frame slot: GPU frame still running after {d} ms", .{waited_ms});
                    continue;
                },
                error.DeviceLost => {
                    self.releaseLost();
                    return err;
                },
                else => return err,
            };
            return;
        }
    }
    /// After device loss no fence will advance; the retained commands only pin
    /// resources, which are safe to release once the device is removed.
    fn releaseLost(self: *FrameSync) void {
        while (self.pending > 0) self.releaseHead();
    }
    /// May be called before submit, matching the shared renderer's call order.
    /// The command must later be submitted before drain or a full-ring wait.
    pub fn signalOnCompletionChecked(self: *FrameSync, command: *const commands.CommandBuffer) !void {
        if (self.acquired == 0) return error.UnbalancedFrameSync;
        for (0..self.pending) |i| {
            const index = (self.head + i) % self.capacity;
            if (self.slots[index].?.shared == command.shared) return error.CommandAlreadyRegistered;
        }
        const tail = (self.head + self.pending) % self.capacity;
        self.slots[tail] = command.retained();
        self.pending += 1;
        self.acquired -= 1;
    }
    pub fn signalOnCompletion(self: *FrameSync, command: *const commands.CommandBuffer) void {
        self.signalOnCompletionChecked(command) catch @panic("unbalanced D3D12 frame completion registration");
    }
    /// Recovery when submission failed before executing any GPU work. A command
    /// with an assigned serial (including Signal failure) must finish its fence.
    pub fn cancelUnsubmittedChecked(self: *FrameSync, command: *const commands.CommandBuffer) !void {
        if (command.shared.serial != null) return error.CommandAlreadySubmitted;
        for (0..self.pending) |i| {
            const index = (self.head + i) % self.capacity;
            if (self.slots[index].?.shared != command.shared) continue;
            self.slots[index].?.deinit();
            for (i..self.pending - 1) |j| self.slots[(self.head + j) % self.capacity] = self.slots[(self.head + j + 1) % self.capacity];
            self.slots[(self.head + self.pending - 1) % self.capacity] = null;
            self.pending -= 1;
            return;
        }
        return error.CommandNotRegistered;
    }
    /// Returns an acquired slot on an encode error before command registration.
    pub fn signalChecked(self: *FrameSync) !void {
        if (self.acquired == 0) return error.UnbalancedFrameSync;
        self.acquired -= 1;
    }
    pub fn signal(self: *FrameSync) void {
        self.signalChecked() catch @panic("unbalanced D3D12 frame slot return");
    }
    pub fn drainChecked(self: *FrameSync, max_frames: u32, timeout_ms: u32) !void {
        if (max_frames != self.capacity or self.acquired != 0) return error.UnbalancedFrameSync;
        while (self.pending > 0) {
            try self.slots[self.head].?.waitChecked(timeout_ms);
            self.releaseHead();
        }
    }
    /// Drains without a deadline (teardown, resize, readback). Device loss is
    /// logged and releases the pending slots; callers cannot act on it here and
    /// the next frame reports it.
    pub fn drain(self: *FrameSync, max_frames: u32) void {
        var waited_ms: u64 = 0;
        while (true) {
            self.drainChecked(max_frames, wait_slice_ms) catch |err| switch (err) {
                error.GpuTimeout => {
                    waited_ms += wait_slice_ms;
                    if (waited_ms == wait_slice_ms or waited_ms % 10_000 == 0)
                        std.log.warn("[d3d12] frame drain: GPU still running after {d} ms", .{waited_ms});
                    continue;
                },
                error.DeviceLost => {
                    std.log.err("[d3d12] frame drain: device lost; releasing {d} pending frame(s)", .{self.pending});
                    self.releaseLost();
                    return;
                },
                else => @panic("unbalanced D3D12 frame drain"),
            };
            return;
        }
    }
    pub fn deinitChecked(self: *FrameSync) !void {
        if (self.pending != 0 or self.acquired != 0) return error.UnbalancedFrameSync;
        self.* = undefined;
    }
    pub fn deinit(self: *FrameSync) void {
        self.deinitChecked() catch @panic("D3D12 FrameSync must be drained before deinit");
    }
};
