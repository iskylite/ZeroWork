//! A producer owns one reference, the UI owns the other. No UI or registry
//! pointers escape into results, and cancelling never joins a worker.
const std = @import("std");
const vt = @import("snapshot.zig");
const search = @import("search_snapshot.zig");
const identity = @import("../host/identity.zig");
pub const allocator = std.heap.page_allocator;
pub var live_count: std.atomic.Value(usize) = .init(0);
pub const Shape = struct {
    cols: u16,
    rows: u16,
    colors: vt.Colors,
    alternate: bool,
    pub fn from(p: *const vt.Projection) Shape {
        return .{ .cols = p.cols, .rows = p.rows, .colors = p.colors, .alternate = p.modes.alternate_screen };
    }
    pub fn matches(self: Shape, p: *const vt.Projection) bool {
        return std.meta.eql(self, from(p));
    }
};
pub const Result = struct { owner: identity.SessionHandle, document: search.Document, shape: Shape };
pub const Task = struct {
    owner: identity.SessionHandle,
    references: std.atomic.Value(usize) = .init(2),
    cancelled: std.atomic.Value(bool) = .init(false),
    done: std.atomic.Value(bool) = .init(false),
    result: ?Result = null,
    failure: ?anyerror = null,
    pub fn create(owner: identity.SessionHandle) !*Task {
        const self = try std.heap.c_allocator.create(Task);
        self.* = .{ .owner = owner };
        _ = live_count.fetchAdd(1, .monotonic);
        return self;
    }
    pub fn finish(self: *Task, result: ?Result, failure: ?anyerror) void {
        self.result = result;
        self.failure = failure;
        self.done.store(true, .release);
    }
    pub fn take(self: *Task) ?Result {
        if (!self.done.load(.acquire)) return null;
        const result = self.result;
        self.result = null;
        return result;
    }
    pub fn release(self: *Task) void {
        if (self.references.fetchSub(1, .acq_rel) != 1) return;
        if (self.result) |*result| result.document.deinit(allocator);
        _ = live_count.fetchSub(1, .monotonic);
        std.heap.c_allocator.destroy(self);
    }
};

test "search task can finish after the consumer cancels and releases it" {
    const owner: identity.SessionHandle = .{ .session_id = @fromBackingInt(1), .generation = 1 };
    const task = try Task.create(owner);
    task.cancelled.store(true, .release);
    task.release();
    task.finish(null, error.Cancelled);
    task.release();
}
