//! CPU-only complete frame service. The full-frame decoder path keeps one
//! published buffer; rectangle updates additionally use one bounded work buffer.
//! A borrowed slot is immutable. A writer must backpressure FrameBorrowed, or
//! keep decoding into its own complete-frame base and skip this display copy.
const std = @import("std");
const identity = @import("../../host/identity.zig");
const typed = @import("../../host/plugin_services.zig");
const frames = @import("../../host/frame_texture_sink.zig");
const budgets = @import("../../host/frame_budget.zig");

pub const service_key: typed.ServiceKey = .{ .name = "bmc_ikvm.framebuffer" };
pub const key = service_key;
pub const Format = enum { rgba8 };
pub const Snapshot = struct {
    session_handle: identity.SessionHandle,
    frame_generation: u64,
    sequence: u64,
    width: u32,
    height: u32,
    stride: usize,
    format: Format = .rgba8,
    pixels: []const u8,
    received_monotonic_ns: u64,
};
pub const FrameLease = struct {
    snapshot: Snapshot,
    context: *anyopaque,
    token: u64,
    release_fn: *const fn (*anyopaque, u64) void,

    pub fn release(self: *FrameLease) void {
        if (self.token == 0) return;
        self.release_fn(self.context, self.token);
        self.token = 0;
    }
};
pub const Unavailable = enum { awaiting_frame, closed, lease_limit };
pub const AcquireResult = union(enum) { frame: FrameLease, unchanged, unavailable: Unavailable, stale_binding };
pub const Interface = struct {
    acquire_latest: *const fn (*anyopaque, typed.Binding, u64) AcquireResult,
};
pub const definition = typed.Definition.of(Interface, key);

pub const Service = struct {
    const Slot = struct {
        pixels: ?[]u8 = null,
        reservation: ?budgets.Reservation = null,
        width: u32 = 0,
        height: u32 = 0,
        generation: u64 = 0,
        sequence: u64 = 0,
        received_ns: u64 = 0,
        borrowers: usize = 0,
    };
    const LeaseRecord = struct { token: u64, slot: usize };
    allocator: std.mem.Allocator,
    owner: identity.SessionHandle,
    budget: *budgets.Budget,
    limits: budgets.Limits = .kvm,
    slots: [2]Slot = .{ .{}, .{} },
    latest: ?usize = null,
    pending: ?usize = null,
    working: ?usize = null,
    width: u32 = 0,
    height: u32 = 0,
    frame_generation: u64 = 0,
    sequence: u64 = 0,
    last_submitted_sequence: u64 = 0,
    next_lease: u64 = 1,
    leases: [64]?LeaseRecord = @splat(null),
    full_frame_mode: bool = true,
    closed: bool = false,
    mutex: std.atomic.Value(bool) = .init(false),

    pub fn init(allocator: std.mem.Allocator, owner: identity.SessionHandle, budget: *budgets.Budget) Service {
        return .{ .allocator = allocator, .owner = owner, .budget = budget };
    }
    pub fn binding(self: *Service) typed.Binding {
        return typed.Binding.init(Interface, key, self, &vtable, self.owner, 1);
    }
    pub fn acquireLatest(self: *Service, binding_value: typed.Binding, after_sequence: u64) AcquireResult {
        self.lock();
        defer self.unlock();
        if (!self.matches(binding_value)) return .stale_binding;
        if (self.closed) return .{ .unavailable = .closed };
        const index = self.latest orelse return .{ .unavailable = .awaiting_frame };
        const slot = &self.slots[index];
        if (slot.sequence <= after_sequence) return .unchanged;
        if (self.next_lease == std.math.maxInt(u64)) return .{ .unavailable = .lease_limit };
        for (&self.leases) |*record| {
            if (record.* != null) continue;
            const token = self.next_lease;
            self.next_lease += 1;
            record.* = .{ .token = token, .slot = index };
            slot.borrowers += 1;
            return .{ .frame = .{
                .snapshot = .{ .session_handle = self.owner, .frame_generation = slot.generation, .sequence = slot.sequence, .width = slot.width, .height = slot.height, .stride = @as(usize, slot.width) * 4, .pixels = slot.pixels.?, .received_monotonic_ns = slot.received_ns },
                .context = self,
                .token = token,
                .release_fn = releaseLease,
            } };
        }
        return .{ .unavailable = .lease_limit };
    }
    /// Allocate the new size transactionally. Failure preserves the latest
    /// complete frame. Call with the display producer paused and old sink queue
    /// drained on main; the sink owns the GPU/uploaded geometry until success.
    pub fn configure(self: *Service, width: u32, height: u32) !u64 {
        self.lock();
        defer self.unlock();
        return self.configureLocked(width, height, false);
    }
    /// Reconnect/full-refresh barrier even when the dimensions are unchanged.
    pub fn advanceGeneration(self: *Service) !u64 {
        self.lock();
        defer self.unlock();
        if (self.width == 0) return error.FrameUnavailable;
        return self.configureLocked(self.width, self.height, true);
    }
    fn configureLocked(self: *Service, width: u32, height: u32, force: bool) !u64 {
        if (self.closed) return error.FramebufferClosed;
        _ = try self.limits.byteLength(width, height);
        if (self.working != null) return error.FrameUpdateInProgress;
        if (!force and width == self.width and height == self.height) return self.frame_generation;
        for (self.slots) |slot| if (slot.borrowers != 0) return error.FrameBorrowed;
        const next_generation = if (self.frame_generation == 0) 1 else try identity.advance(self.frame_generation);
        // Superseding an uncompleted resize frees only its unused candidate.
        // Restore a valid target first, so allocation rejection cannot leave
        // pending pointing at freed memory. The old complete frame survives.
        if (self.pending) |pending| {
            self.freeSlot(pending);
            self.pending = null;
            self.width = if (self.latest) |latest| self.slots[latest].width else 0;
            self.height = if (self.latest) |latest| self.slots[latest].height else 0;
        }
        const index = if (self.latest) |latest| 1 - latest else 0;
        try self.allocateSlot(index, width, height);
        self.slots[index].generation = next_generation;
        self.slots[index].sequence = 0;
        self.pending = index;
        self.width = width;
        self.height = height;
        self.frame_generation = next_generation;
        return next_generation;
    }
    /// Complete RGBA from an external decoder. That decoder must keep applying
    /// every delta even if this returns FrameBorrowed or the sink queue is full.
    pub fn publishComplete(self: *Service, width: u32, height: u32, rgba: []const u8, received_ns: u64) !u64 {
        self.lock();
        defer self.unlock();
        if (self.closed) return error.FramebufferClosed;
        const length = try self.limits.byteLength(width, height);
        if (rgba.len != length) return error.InvalidFrame;
        if (self.working != null) return error.FrameUpdateInProgress;
        if (width != self.width or height != self.height) _ = try self.configureLocked(width, height, false);
        const index = self.pending orelse self.latest orelse return error.FrameUnavailable;
        const slot = &self.slots[index];
        if (slot.borrowers != 0) return error.FrameBorrowed;
        const next = if (self.sequence == 0) 1 else try identity.advance(self.sequence);
        try slot.reservation.?.validate(self.owner, .cpu_frame, length, slot.pixels.?);
        @memcpy(slot.pixels.?, rgba);
        slot.sequence = next;
        slot.generation = self.frame_generation;
        slot.received_ns = received_ns;
        self.sequence = next;
        self.latest = index;
        self.pending = null;
        self.full_frame_mode = true;
        self.reapOther();
        return next;
    }
    /// Start a delta update from the latest complete base. The first frame of
    /// each generation is supplied through publishComplete; partial rectangles
    /// can never implicitly establish a new-size base.
    pub fn beginUpdate(self: *Service) !void {
        self.lock();
        defer self.unlock();
        if (self.closed) return error.FramebufferClosed;
        if (self.working != null) return error.FrameUpdateInProgress;
        if (self.pending != null) return error.FullFrameRequired;
        const latest = self.latest orelse return error.FullFrameRequired;
        if (self.slots[latest].generation != self.frame_generation) return error.FullFrameRequired;
        const index = 1 - latest;
        if (self.slots[index].borrowers != 0) return error.FrameBorrowed;
        try self.allocateSlot(index, self.width, self.height);
        @memcpy(self.slots[index].pixels.?, self.slots[latest].pixels.?);
        self.working = index;
        self.full_frame_mode = false;
    }
    pub fn applyRectangle(self: *Service, x: u32, y: u32, width: u32, height: u32, rgba: []const u8, stride: usize) !void {
        self.lock();
        defer self.unlock();
        if (self.closed) return error.FramebufferClosed;
        const index = self.working orelse return error.FrameUpdateNotStarted;
        if (width == 0 or height == 0 or x >= self.width or y >= self.height or width > self.width - x or height > self.height - y) return error.InvalidRectangle;
        const row = std.math.mul(usize, width, 4) catch return error.InvalidRectangle;
        if (stride < row) return error.InvalidRectangle;
        const preceding = std.math.mul(usize, height - 1, stride) catch return error.InvalidRectangle;
        const required = std.math.add(usize, preceding, row) catch return error.InvalidRectangle;
        if (rgba.len != required) return error.InvalidRectangle;
        const slot = &self.slots[index];
        try slot.reservation.?.validate(self.owner, .cpu_frame, try self.limits.byteLength(self.width, self.height), slot.pixels.?);
        const target_stride = @as(usize, self.width) * 4;
        for (0..height) |line| {
            const destination = (@as(usize, y) + line) * target_stride + @as(usize, x) * 4;
            @memcpy(slot.pixels.?[destination..][0..row], rgba[line * stride ..][0..row]);
        }
    }
    pub fn finishUpdate(self: *Service, received_ns: u64) !u64 {
        self.lock();
        defer self.unlock();
        if (self.closed) return error.FramebufferClosed;
        const index = self.working orelse return error.FrameUpdateNotStarted;
        const next = try identity.advance(self.sequence);
        const slot = &self.slots[index];
        slot.sequence = next;
        slot.generation = self.frame_generation;
        slot.received_ns = received_ns;
        self.sequence = next;
        self.latest = index;
        self.working = null;
        return next;
    }
    pub fn abortUpdate(self: *Service) void {
        self.lock();
        defer self.unlock();
        self.working = null;
    }
    /// SPSC producer adapter. Queue saturation skips only the owned display
    /// copy, never the protocol base. This method never accesses a GPU callback.
    pub fn publishToSink(self: *Service, sink: *frames.Sink) !bool {
        if (!sink.owner.eql(self.owner)) return error.StaleFrame;
        var lease = switch (self.acquireLatest(self.binding(), self.last_submitted_sequence)) {
            .frame => |value| value,
            .unchanged, .unavailable => return false,
            .stale_binding => return error.StaleBinding,
        };
        defer lease.release();
        const snapshot = lease.snapshot;
        var frame = try frames.Frame.copyForGeneration(self.allocator, self.budget, self.owner, snapshot.sequence, snapshot.frame_generation, snapshot.width, snapshot.height, snapshot.pixels);
        sink.submit(frame) catch |err| {
            frame.deinit();
            if (err == error.FrameQueueFull) return false;
            return err;
        };
        self.last_submitted_sequence = snapshot.sequence;
        return true;
    }
    /// Stop/join the decoder first. Live leases retain their storage and must
    /// release before close/deinit can complete.
    pub fn close(self: *Service) !void {
        self.lock();
        defer self.unlock();
        self.closed = true;
        for (self.slots) |slot| if (slot.borrowers != 0) return error.FrameBorrowed;
        for (0..self.slots.len) |index| self.freeSlot(index);
        self.latest = null;
        self.pending = null;
        self.working = null;
    }
    pub fn deinit(self: *Service) !void {
        try self.close();
    }
    fn allocateSlot(self: *Service, index: usize, width: u32, height: u32) !void {
        const slot = &self.slots[index];
        if (slot.borrowers != 0) return error.FrameBorrowed;
        const length = try self.limits.byteLength(width, height);
        if (slot.pixels != null and slot.width == width and slot.height == height) return;
        // Only an unused working slot is freed here, never the latest image.
        self.freeSlot(index);
        var reservation = try self.budget.reserve(self.owner, length, .cpu_frame);
        errdefer reservation.release();
        const pixels = try self.allocator.alloc(u8, length);
        errdefer self.allocator.free(pixels);
        try reservation.bind(pixels);
        slot.* = .{ .pixels = pixels, .reservation = reservation, .width = width, .height = height };
    }
    fn freeSlot(self: *Service, index: usize) void {
        const slot = &self.slots[index];
        std.debug.assert(slot.borrowers == 0);
        if (slot.pixels) |pixels| self.allocator.free(pixels);
        if (slot.reservation) |*reservation| reservation.release();
        slot.* = .{};
    }
    fn reapOther(self: *Service) void {
        if (self.latest) |latest| {
            const other = 1 - latest;
            if (self.full_frame_mode and self.working != other and self.pending != other and self.slots[other].borrowers == 0) self.freeSlot(other);
        }
    }
    fn matches(self: *Service, binding_value: typed.Binding) bool {
        _ = binding_value.borrow(Interface, key, self.owner) catch return false;
        return binding_value.context == @as(*anyopaque, @ptrCast(self));
    }
    fn releaseLease(context: *anyopaque, token: u64) void {
        const self: *Service = @ptrCast(@alignCast(context));
        self.lock();
        defer self.unlock();
        for (&self.leases) |*record| {
            if (record.*) |value| {
                if (value.token != token) continue;
                self.slots[value.slot].borrowers -= 1;
                record.* = null;
                self.reapOther();
                return;
            }
        }
    }
    const vtable: Interface = .{ .acquire_latest = acquireFromBinding };
    fn acquireFromBinding(context: *anyopaque, binding_value: typed.Binding, after_sequence: u64) AcquireResult {
        const self: *Service = @ptrCast(@alignCast(context));
        return self.acquireLatest(binding_value, after_sequence);
    }
    fn lock(self: *Service) void {
        while (self.mutex.swap(true, .acquire)) std.atomic.spinLoopHint();
    }
    fn unlock(self: *Service) void {
        self.mutex.store(false, .release);
    }
};
pub const FramebufferService = Service;
