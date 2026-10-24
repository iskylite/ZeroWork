//! Process lifetime guard. Acquire before preparing/loading any data or
//! credentials; release only after every application and IO owner is gone.
const std = @import("std");
extern fn zw_data_scope_lock_acquire(directory: [*:0]const u8, isolated: c_int, out: *?*anyopaque) c_int;
extern fn zw_data_scope_lock_release(handle: ?*anyopaque) void;

pub const Lock = struct {
    handle: ?*anyopaque,

    pub fn acquire(allocator: std.mem.Allocator, directory: []const u8, isolated: bool) !Lock {
        if (std.mem.indexOfScalar(u8, directory, 0) != null) return error.UnsafeDataScopeLock;
        const path = try allocator.dupeSentinel(u8, std.mem.trimEnd(u8, directory, "/"), 0);
        defer allocator.free(path);
        var handle: ?*anyopaque = null;
        return switch (zw_data_scope_lock_acquire(path, if (isolated) 1 else 0, &handle)) {
            0 => .{ .handle = handle orelse return error.DataScopeLockFailure },
            1 => error.AlreadyRunning,
            2 => error.UnsafeDataScopeLock,
            else => error.DataScopeLockFailure,
        };
    }

    pub fn release(self: *Lock) void {
        zw_data_scope_lock_release(self.handle);
        self.handle = null;
    }
};

test "scope lock rejects same scope allows isolated scope and releases without a persistent owner" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(base);
    const other = try std.fs.path.join(std.testing.allocator, &.{ base, "other-instance" });
    defer std.testing.allocator.free(other);
    var first = try Lock.acquire(std.testing.allocator, base, true);
    defer first.release();
    try std.testing.expectError(error.AlreadyRunning, Lock.acquire(std.testing.allocator, base, true));
    var second = try Lock.acquire(std.testing.allocator, other, true);
    defer second.release();
    first.release();
    var recovered = try Lock.acquire(std.testing.allocator, base, true);
    recovered.release();
}
