//! Worker submits owned CPU RGBA; only the constructing thread may touch GPU
//! callbacks. One producer/one consumer bounded queue, with explicit ownership.
const std = @import("std");
const identity = @import("identity.zig");
pub const Frame = struct {
    allocator: std.mem.Allocator,
    owner: identity.SessionHandle,
    revision: u64,
    width: u32,
    height: u32,
    rgba: []u8,
    pub fn copy(allocator: std.mem.Allocator, owner: identity.SessionHandle, revision: u64, width: u32, height: u32, rgba: []const u8) !Frame {
        if (revision == 0 or width == 0 or height == 0 or width > 8192 or height > 8192) return error.InvalidFrame;
        const length = @as(usize, width) * height * 4;
        if (length > 32 * 1024 * 1024 or rgba.len != length) return error.InvalidFrame;
        return .{ .allocator = allocator, .owner = owner, .revision = revision, .width = width, .height = height, .rgba = try allocator.dupe(u8, rgba) };
    }
    pub fn deinit(self: *Frame) void {
        self.allocator.free(self.rgba);
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
    pub fn init(owner: identity.SessionHandle, backend: Backend) Sink {
        return .{ .owner = owner, .backend = backend, .main_thread = std.Thread.getCurrentId() };
    }
    /// Successful publication transfers ownership. On error the producer must
    /// retain/deinit the frame. Stop/join producer before close/deinit.
    pub fn submit(self: *Sink, frame: Frame) !void {
        if (!self.accepting.load(.acquire)) return error.FrameSinkClosed;
        if (!frame.owner.eql(self.owner)) return error.StaleFrame;
        const write = self.write.load(.monotonic);
        const read = self.read.load(.acquire);
        if (write -% read == capacity) return error.FrameQueueFull;
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
            if (!self.accepting.load(.acquire) or !frame.owner.eql(self.owner) or frame.revision <= self.revision) continue;
            if (self.texture == null or self.width != frame.width or self.height != frame.height) {
                const next = try self.backend.create(self.backend.context, frame.width, frame.height);
                errdefer self.backend.release(self.backend.context, next);
                try self.backend.update(self.backend.context, next, frame.rgba);
                if (self.texture) |old| self.backend.release(self.backend.context, old);
                self.texture = next;
                self.width = frame.width;
                self.height = frame.height;
            } else try self.backend.update(self.backend.context, self.texture.?, frame.rgba);
            self.revision = frame.revision;
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
        while (self.take()) |value| {
            var frame = value;
            frame.deinit();
        }
        if (self.texture) |texture| self.backend.release(self.backend.context, texture);
        self.texture = null;
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
