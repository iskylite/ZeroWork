//! Adapter operations may hold the VT guard while parsing, copying history or
//! formatting selections. Contenders must sleep rather than burn another core.
//! UI paths that can defer continue to use tryLock and retain their last frame.
const std = @import("std");

pub const Mutex = struct {
    allocator: std.mem.Allocator,
    // Adapter is a value returned by init and transferred to its owner. POSIX
    // mutexes must keep their address even when that outer value is moved.
    native: *std.c.pthread_mutex_t,

    pub fn init(allocator: std.mem.Allocator) !Mutex {
        const native = try allocator.create(std.c.pthread_mutex_t);
        native.* = .{};
        return .{ .allocator = allocator, .native = native };
    }

    pub fn lock(self: *Mutex) void {
        const result = std.c.pthread_mutex_lock(self.native);
        std.debug.assert(result == .SUCCESS);
    }
    pub fn tryLock(self: *Mutex) bool {
        const result = std.c.pthread_mutex_trylock(self.native);
        std.debug.assert(result == .SUCCESS or result == .BUSY);
        return result == .SUCCESS;
    }
    pub fn unlock(self: *Mutex) void {
        const result = std.c.pthread_mutex_unlock(self.native);
        std.debug.assert(result == .SUCCESS);
    }
    pub fn deinit(self: *Mutex) void {
        const result = std.c.pthread_mutex_destroy(self.native);
        std.debug.assert(result == .SUCCESS);
        self.allocator.destroy(self.native);
    }
};

test "VT native mutex blocks a competing owner and preserves nonblocking probes" {
    const Context = struct {
        mutex: Mutex,
        entered: std.atomic.Value(bool) = .init(false),
        acquired: std.atomic.Value(bool) = .init(false),
        value: usize = 0,
        fn work(self: *@This()) void {
            self.entered.store(true, .release);
            self.mutex.lock();
            defer self.mutex.unlock();
            self.value += 1;
            self.acquired.store(true, .release);
        }
    };
    var context: Context = .{ .mutex = try Mutex.init(std.testing.allocator) };
    defer context.mutex.deinit();
    context.mutex.lock();
    try std.testing.expect(!context.mutex.tryLock());
    const thread = try std.Thread.spawn(.{}, Context.work, .{&context});
    while (!context.entered.load(.acquire)) std.atomic.spinLoopHint();
    try std.testing.expect(!context.acquired.load(.acquire));
    context.value = 41;
    context.mutex.unlock();
    thread.join();
    try std.testing.expectEqual(@as(usize, 42), context.value);
    try std.testing.expect(context.acquired.load(.acquire));
    try std.testing.expect(context.mutex.tryLock());
    context.mutex.unlock();
}
