//! Shared CPU/GPU reservations. Keep a Budget at a stable address until every
//! reservation is released; the mutex protects decoder/main-thread accounting.
const std = @import("std");
const identity = @import("identity.zig");

pub const default_frame_bytes = 32 * 1024 * 1024;
pub const kvm_frame_bytes = 4096 * 2160 * 4;
pub const application_bytes = 512 * 1024 * 1024;
pub const Kind = enum { cpu_frame, display_frame, gpu_texture, transport, decode };
pub const Limits = struct {
    max_width: u32 = 8192,
    max_height: u32 = 8192,
    max_frame_bytes: usize = default_frame_bytes,

    pub const kvm: Limits = .{ .max_width = 4096, .max_height = 2160, .max_frame_bytes = kvm_frame_bytes };

    pub fn byteLength(self: Limits, width: u32, height: u32) !usize {
        if (width == 0 or height == 0 or width > self.max_width or height > self.max_height) return error.InvalidFrame;
        const pixels = std.math.mul(usize, width, height) catch return error.InvalidFrame;
        const bytes = std.math.mul(usize, pixels, 4) catch return error.InvalidFrame;
        if (bytes > self.max_frame_bytes) return error.InvalidFrame;
        return bytes;
    }
};

pub const Reservation = struct {
    budget: *Budget,
    id: u64,
    owner: identity.SessionHandle,
    bytes: usize,
    kind: Kind,

    pub fn bind(self: Reservation, memory: []const u8) !void {
        try self.budget.bind(self, memory);
    }
    pub fn validate(self: Reservation, owner: identity.SessionHandle, kind: Kind, bytes: usize, memory: ?[]const u8) !void {
        try self.budget.validate(self, owner, kind, bytes, memory);
    }
    pub fn release(self: *Reservation) void {
        self.budget.release(self.*);
        self.id = 0;
    }
};

pub const Budget = struct {
    pub const capacity = 256;
    const Entry = struct { id: u64, owner: identity.SessionHandle, bytes: usize, kind: Kind, address: ?usize = null };
    limit: usize,
    used: usize = 0,
    peak: usize = 0,
    next_id: u64 = 1,
    entries: [capacity]?Entry = @splat(null),
    mutex: std.atomic.Value(bool) = .init(false),

    pub fn init(limit: usize) Budget {
        return .{ .limit = limit };
    }
    pub fn reserve(self: *Budget, owner: identity.SessionHandle, bytes: usize, kind: Kind) !Reservation {
        if (@backingInt(owner.session_id) == 0 or owner.generation == 0 or bytes == 0) return error.InvalidReservation;
        self.lock();
        defer self.unlock();
        if (bytes > self.limit - self.used) return error.FrameBudgetExceeded;
        if (self.next_id == std.math.maxInt(u64)) return error.ReservationIdentityExhausted;
        for (&self.entries) |*slot| {
            if (slot.* != null) continue;
            const value: Entry = .{ .id = self.next_id, .owner = owner, .bytes = bytes, .kind = kind };
            slot.* = value;
            self.next_id += 1;
            self.used += bytes;
            self.peak = @max(self.peak, self.used);
            return .{ .budget = self, .id = value.id, .owner = owner, .bytes = bytes, .kind = kind };
        }
        return error.FrameReservationFull;
    }
    pub fn usedBytes(self: *Budget) usize {
        self.lock();
        defer self.unlock();
        return self.used;
    }
    pub fn peakBytes(self: *Budget) usize {
        self.lock();
        defer self.unlock();
        return self.peak;
    }
    pub fn deinit(self: *Budget) !void {
        if (self.usedBytes() != 0) return error.FrameBudgetBusy;
    }
    fn bind(self: *Budget, reservation: Reservation, memory: []const u8) !void {
        self.lock();
        defer self.unlock();
        const entry = self.find(reservation) orelse return error.InvalidFrameReservation;
        if (entry.bytes != memory.len or entry.address != null) return error.InvalidFrameReservation;
        entry.address = @intFromPtr(memory.ptr);
    }
    fn validate(self: *Budget, reservation: Reservation, owner: identity.SessionHandle, kind: Kind, bytes: usize, memory: ?[]const u8) !void {
        self.lock();
        defer self.unlock();
        const entry = self.find(reservation) orelse return error.InvalidFrameReservation;
        if (!entry.owner.eql(owner) or entry.kind != kind or entry.bytes != bytes) return error.InvalidFrameReservation;
        if (memory) |value| {
            if (value.len != bytes or entry.address == null or entry.address.? != @intFromPtr(value.ptr)) return error.InvalidFrameReservation;
        }
    }
    fn release(self: *Budget, reservation: Reservation) void {
        self.lock();
        defer self.unlock();
        for (&self.entries) |*slot| {
            if (slot.*) |entry| {
                if (!matches(entry, reservation)) continue;
                self.used -= entry.bytes;
                slot.* = null;
                return;
            }
        }
    }
    fn find(self: *Budget, reservation: Reservation) ?*Entry {
        if (reservation.budget != self or reservation.id == 0) return null;
        for (&self.entries) |*slot| {
            if (slot.*) |*entry| if (matches(entry.*, reservation)) return entry;
        }
        return null;
    }
    fn matches(entry: Entry, reservation: Reservation) bool {
        return entry.id == reservation.id and entry.owner.eql(reservation.owner) and entry.bytes == reservation.bytes and entry.kind == reservation.kind;
    }
    fn lock(self: *Budget) void {
        while (self.mutex.swap(true, .acquire)) std.atomic.spinLoopHint();
    }
    fn unlock(self: *Budget) void {
        self.mutex.store(false, .release);
    }
};
