const std = @import("std");
const Runtime = @import("../host/runtime_service.zig").Runtime;

pub const Registry = struct {
    allocator: std.mem.Allocator,
    entries: std.AutoHashMap(u32, *Runtime),

    pub fn init(allocator: std.mem.Allocator) Registry {
        return .{ .allocator = allocator, .entries = std.AutoHashMap(u32, *Runtime).init(allocator) };
    }
    pub fn deinit(self: *Registry) void {
        self.entries.deinit();
        self.* = undefined;
    }
    pub fn bind(self: *Registry, pane_id: u32, worker: *Runtime) !void {
        try self.entries.put(pane_id, worker);
    }
    pub fn unbind(self: *Registry, pane_id: u32) void {
        _ = self.entries.remove(pane_id);
    }
    pub fn send(ctx: *anyopaque, pane_id: u32, bytes: []const u8) !void {
        const self: *Registry = @ptrCast(@alignCast(ctx));
        const worker = self.entries.get(pane_id) orelse return error.PaneNotBound;
        try worker.pushInputFrom(bytes, .broadcast);
    }
};
