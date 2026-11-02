//! Worker submits owned CPU RGBA; only the constructing thread may touch GPU
//! callbacks. One producer/one consumer bounded queue, with explicit ownership.
const std = @import("std");
const identity = @import("identity.zig");
pub const budget_api = @import("frame_budget.zig");
pub const Budget = budget_api.Budget;
pub const Limits = budget_api.Limits;
pub const Frame = struct {
    allocator: std.mem.Allocator,
    owner: identity.SessionHandle,
    revision: u64,
    width: u32,
    height: u32,
    rgba: []u8,
    frame_generation: u64 = 1,
    // Defaulted for source compatibility with existing literals. A literal is
    // still owned/deinitializable, but only allocated Frames may be submitted.
    allocation: ?*Allocation = null,
    const State = enum { owned, queued, uploading };
    const Allocation = struct {
        allocator: std.mem.Allocator,
        owner: identity.SessionHandle,
        revision: u64,
        generation: u64,
        width: u32,
        height: u32,
        pixels: []u8,
        reservation: ?budget_api.Reservation,
        state: State = .owned,
    };
    pub fn copy(allocator: std.mem.Allocator, owner: identity.SessionHandle, revision: u64, width: u32, height: u32, rgba: []const u8) !Frame {
        return allocate(allocator, null, .{}, owner, revision, 1, width, height, rgba);
    }
    pub fn copyWithBudget(allocator: std.mem.Allocator, budget: *Budget, owner: identity.SessionHandle, revision: u64, width: u32, height: u32, rgba: []const u8) !Frame {
        return copyForGeneration(allocator, budget, owner, revision, 1, width, height, rgba);
    }
    pub fn copyForGeneration(allocator: std.mem.Allocator, budget: *Budget, owner: identity.SessionHandle, revision: u64, frame_generation: u64, width: u32, height: u32, rgba: []const u8) !Frame {
        return copyConfigured(allocator, budget, .kvm, owner, revision, frame_generation, width, height, rgba);
    }
    pub fn copyConfigured(allocator: std.mem.Allocator, budget: *Budget, limits: Limits, owner: identity.SessionHandle, revision: u64, frame_generation: u64, width: u32, height: u32, rgba: []const u8) !Frame {
        return allocate(allocator, budget, limits, owner, revision, frame_generation, width, height, rgba);
    }
    fn allocate(allocator: std.mem.Allocator, budget: ?*Budget, limits: Limits, owner: identity.SessionHandle, revision: u64, generation: u64, width: u32, height: u32, rgba: []const u8) !Frame {
        if (revision == 0 or generation == 0 or @backingInt(owner.session_id) == 0 or owner.generation == 0) return error.InvalidFrame;
        const length = try limits.byteLength(width, height);
        if (rgba.len != length) return error.InvalidFrame;
        var reservation: ?budget_api.Reservation = if (budget) |value| try value.reserve(owner, length, .display_frame) else null;
        errdefer if (reservation) |*value| value.release();
        const pixels = try allocator.dupe(u8, rgba);
        errdefer allocator.free(pixels);
        if (reservation) |value| try value.bind(pixels);
        const allocation = try allocator.create(Allocation);
        allocation.* = .{ .allocator = allocator, .owner = owner, .revision = revision, .generation = generation, .width = width, .height = height, .pixels = pixels, .reservation = reservation };
        return .{ .allocator = allocator, .owner = owner, .revision = revision, .frame_generation = generation, .width = width, .height = height, .rgba = pixels, .allocation = allocation };
    }
    fn validate(self: Frame, owner: identity.SessionHandle, limits: Limits, budget: ?*Budget, state: State) !void {
        if (!self.owner.eql(owner)) return error.StaleFrame;
        const length = try limits.byteLength(self.width, self.height);
        if (self.rgba.len != length or self.revision == 0 or self.frame_generation == 0) return error.InvalidFrame;
        const allocation = self.allocation orelse return error.InvalidFrame;
        if (allocation.state != state or !allocation.owner.eql(self.owner) or allocation.revision != self.revision or allocation.generation != self.frame_generation or allocation.width != self.width or allocation.height != self.height or allocation.pixels.ptr != self.rgba.ptr or allocation.pixels.len != length) return error.InvalidFrame;
        if (allocation.reservation) |reservation| {
            if (budget == null or reservation.budget != budget.?) return error.InvalidFrameReservation;
            try reservation.validate(owner, .display_frame, length, self.rgba);
        } else if (budget != null) return error.InvalidFrameReservation;
    }
    pub fn deinit(self: *Frame) void {
        if (self.allocation) |allocation| {
            if (allocation.reservation) |*reservation| reservation.release();
            const allocator = allocation.allocator;
            allocator.free(allocation.pixels);
            allocator.destroy(allocation);
        } else self.allocator.free(self.rgba);
        self.* = undefined;
    }
};
pub const Backend = struct {
    context: *anyopaque,
    create: *const fn (*anyopaque, u32, u32) anyerror!u32,
    update: *const fn (*anyopaque, u32, []const u8) anyerror!void,
    release: *const fn (*anyopaque, u32) void,
};
/// Adapts the project's actual Zenit shared ImageTextureStore, without exposing
/// that store to a plugin or importing renderer internals into this facade.
pub fn backendFor(store: anytype) Backend {
    const StoreType = @typeInfo(@TypeOf(store)).pointer.child;
    const Adapter = struct {
        fn create(ptr: *anyopaque, width: u32, height: u32) !u32 {
            const self: *StoreType = @ptrCast(@alignCast(ptr));
            return self.createStreamTexture(width, height);
        }
        fn update(ptr: *anyopaque, texture: u32, rgba: []const u8) !void {
            const self: *StoreType = @ptrCast(@alignCast(ptr));
            try self.updateStreamTexture(texture, rgba);
        }
        fn release(ptr: *anyopaque, texture: u32) void {
            const self: *StoreType = @ptrCast(@alignCast(ptr));
            self.unloadTexture(texture);
        }
    };
    return .{ .context = store, .create = Adapter.create, .update = Adapter.update, .release = Adapter.release };
}
pub const Sink = struct {
    pub const capacity = 2;
    owner: identity.SessionHandle,
    backend: Backend,
    main_thread: std.Thread.Id,
    entries: [capacity]Frame = undefined,
    write: std.atomic.Value(usize) = .init(0),
    read: std.atomic.Value(usize) = .init(0),
    accepting: std.atomic.Value(bool) = .init(true),
    texture: ?u32 = null,
    width: u32 = 0,
    height: u32 = 0,
    revision: u64 = 0,
    frame_generation: u64 = 0,
    presentation: @import("frame_performance.zig").Presentation = .{},
    newest_generation: std.atomic.Value(u64) = .init(1),
    producer_thread: std.atomic.Value(usize) = .init(0),
    submitting: std.atomic.Value(bool) = .init(false),
    limits: Limits = .{},
    budget: ?*Budget = null,
    texture_reservation: ?budget_api.Reservation = null,
    pub fn init(owner: identity.SessionHandle, backend: Backend) Sink {
        return .{ .owner = owner, .backend = backend, .main_thread = std.Thread.getCurrentId() };
    }
    pub fn initWithBudget(owner: identity.SessionHandle, backend: Backend, budget: *Budget, limits: Limits) Sink {
        var sink = init(owner, backend);
        sink.budget = budget;
        sink.limits = limits;
        return sink;
    }
    /// Successful publication transfers ownership. On error the producer must
    /// retain/deinit the frame. Stop/join producer before close/deinit.
    pub fn submit(self: *Sink, frame: Frame) !void {
        const thread: usize = @intCast(std.Thread.getCurrentId());
        if (self.producer_thread.cmpxchgStrong(0, thread, .acq_rel, .acquire)) |producer| {
            if (producer != thread) return error.MultipleFrameProducers;
        }
        if (self.submitting.swap(true, .acquire)) return error.MultipleFrameProducers;
        defer self.submitting.store(false, .release);
        if (!self.accepting.load(.acquire)) return error.FrameSinkClosed;
        try frame.validate(self.owner, self.limits, self.budget, .owned);
        const generation = self.newest_generation.load(.acquire);
        if (frame.frame_generation < generation) return error.StaleFrame;
        const write = self.write.load(.monotonic);
        const read = self.read.load(.acquire);
        if (write -% read == capacity) return error.FrameQueueFull;
        if (frame.frame_generation > generation) self.newest_generation.store(frame.frame_generation, .release);
        frame.allocation.?.state = .queued;
        self.entries[write % capacity] = frame;
        self.write.store(write +% 1, .release);
    }
    /// Processes at most the bounded queue. Old generations and revisions are
    /// freed on the main thread; they never update an unrelated texture.
    pub fn drain(self: *Sink) !bool {
        try self.requireMain();
        var changed = false;
        while (self.take()) |value| {
            var frame = value;
            defer frame.deinit();
            if (!self.accepting.load(.acquire) or !frame.owner.eql(self.owner) or frame.revision <= self.revision or frame.frame_generation < self.newest_generation.load(.acquire)) continue;
            try frame.validate(self.owner, self.limits, self.budget, .queued);
            frame.allocation.?.state = .uploading;
            if (self.texture == null or self.width != frame.width or self.height != frame.height) {
                var reservation: ?budget_api.Reservation = if (self.budget) |budget| try budget.reserve(self.owner, frame.rgba.len, .gpu_texture) else null;
                errdefer if (reservation) |*value_reservation| value_reservation.release();
                if (reservation) |value_reservation| try value_reservation.validate(self.owner, .gpu_texture, try self.limits.byteLength(frame.width, frame.height), null);
                const next = try self.backend.create(self.backend.context, frame.width, frame.height);
                errdefer self.backend.release(self.backend.context, next);
                try self.backend.update(self.backend.context, next, frame.rgba);
                if (self.texture) |old| self.backend.release(self.backend.context, old);
                if (self.texture_reservation) |*old| old.release();
                self.texture = next;
                self.texture_reservation = reservation;
                self.width = frame.width;
                self.height = frame.height;
            } else {
                if (self.texture_reservation) |reservation| try reservation.validate(self.owner, .gpu_texture, frame.rgba.len, null);
                try self.backend.update(self.backend.context, self.texture.?, frame.rgba);
            }
            self.revision = frame.revision;
            self.frame_generation = frame.frame_generation;
            changed = true;
        }
        return changed;
    }
    /// Revoke input/stop producer first, then join it, then close this sink.
    pub fn stop(self: *Sink) void {
        self.accepting.store(false, .release);
    }
    pub fn close(self: *Sink) !void {
        try self.requireMain();
        self.stop();
        if (self.submitting.load(.acquire)) return error.FrameProducerRunning;
        _ = try self.discardPending();
        if (self.texture) |texture| self.backend.release(self.backend.context, texture);
        if (self.texture_reservation) |*reservation| reservation.release();
        self.texture_reservation = null;
        self.texture = null;
    }
    /// Resize barrier: called on main, with the producer paused. This discards
    /// display copies only; the protocol's delta base remains in its service.
    pub fn discardPending(self: *Sink) !usize {
        try self.requireMain();
        var discarded: usize = 0;
        while (self.take()) |value| {
            var frame = value;
            frame.deinit();
            discarded += 1;
        }
        return discarded;
    }
    fn requireMain(self: *const Sink) !void {
        if (std.Thread.getCurrentId() != self.main_thread) return error.GraphicsOffMainThread;
    }
    fn take(self: *Sink) ?Frame {
        const read = self.read.load(.monotonic);
        const write = self.write.load(.acquire);
        if (read == write) return null;
        const frame = self.entries[read % capacity];
        self.read.store(read +% 1, .release);
        return frame;
    }
};
pub const FrameTextureSink = Sink;
test "synthetic RGBA queue is bounded and only current revisions reach graphics backend" {
    const Driver = struct {
        creates: usize = 0,
        updates: usize = 0,
        releases: usize = 0,
        fn create(ptr: *anyopaque, _: u32, _: u32) !u32 {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.creates += 1;
            return @intCast(self.creates);
        }
        fn update(ptr: *anyopaque, _: u32, pixels: []const u8) !void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255 }, pixels);
            self.updates += 1;
        }
        fn release(ptr: *anyopaque, _: u32) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.releases += 1;
        }
    };
    var driver: Driver = .{};
    const owner: identity.SessionHandle = .{ .session_id = @fromBackingInt(1) };
    var sink = Sink.init(owner, .{ .context = &driver, .create = Driver.create, .update = Driver.update, .release = Driver.release });
    defer sink.close() catch unreachable;
    try sink.submit(try Frame.copy(std.testing.allocator, owner, 2, 1, 1, &.{ 255, 0, 0, 255 }));
    try sink.submit(try Frame.copy(std.testing.allocator, owner, 1, 1, 1, &.{ 255, 0, 0, 255 }));
    var full = try Frame.copy(std.testing.allocator, owner, 3, 1, 1, &.{ 255, 0, 0, 255 });
    defer full.deinit();
    try std.testing.expectError(error.FrameQueueFull, sink.submit(full));
    try std.testing.expect(try sink.drain());
    try std.testing.expectEqual(@as(usize, 1), driver.updates);
    sink.stop();
    try std.testing.expectError(error.FrameSinkClosed, sink.submit(full));
}
test "graphics backend rejects calls from worker" {
    const Worker = struct {
        fn run(sink: *Sink) void {
            std.testing.expectError(error.GraphicsOffMainThread, sink.drain()) catch @panic("off-main-thread graphics accepted");
        }
    };
    var sink = Sink.init(.{ .session_id = @fromBackingInt(1) }, undefined);
    const thread = try std.Thread.spawn(.{}, Worker.run, .{&sink});
    thread.join();
}
