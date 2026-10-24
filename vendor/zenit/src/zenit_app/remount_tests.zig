//! Runs the selected runtime's real mount/remount transaction without a native window.
const std = @import("std");
const ui = @import("ui");
const App = @import("app.zig").App;

const OnceFail = struct {
    failing: std.testing.FailingAllocator,
    fn allocator(self: *OnceFail) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }
    fn alloc(ptr: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *OnceFail = @ptrCast(@alignCast(ptr));
        const result = self.failing.allocator().rawAlloc(len, alignment, ra);
        if (result == null) self.failing.fail_index = std.math.maxInt(usize);
        return result;
    }
    fn resize(ptr: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, len: usize, ra: usize) bool {
        const self: *OnceFail = @ptrCast(@alignCast(ptr));
        if (self.failing.alloc_index == self.failing.fail_index) return false;
        return self.failing.allocator().rawResize(bytes, alignment, len, ra);
    }
    fn remap(ptr: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, len: usize, ra: usize) ?[*]u8 {
        const self: *OnceFail = @ptrCast(@alignCast(ptr));
        if (self.failing.alloc_index == self.failing.fail_index) return null;
        return self.failing.allocator().rawRemap(bytes, alignment, len, ra);
    }
    fn free(ptr: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self: *OnceFail = @ptrCast(@alignCast(ptr));
        self.failing.allocator().rawFree(bytes, alignment, ra);
    }
};
var injection: *OnceFail = undefined;
var second_append: bool = false;
var failed_handle: ui.hit.NodeHandle = undefined;
fn empty(cx: *ui.Cx, _: *ui.Scope) anyerror!*ui.Node {
    return ui.box(cx, .{}, .{});
}
fn focusedThenFail(cx: *ui.Cx, _: *ui.Scope) anyerror!*ui.Node {
    const node = try ui.box(cx, .{}, .{});
    node.setFocusable(true);
    cx.setFocus(node);
    failed_handle = cx.node_registry.handleFor(node);
    if (second_append) try cx.root.?.children.ensureTotalCapacityPrecise(cx.allocator, 1);
    injection.failing.fail_index = injection.failing.alloc_index;
    return node;
}

test "remount append OOM retires builder focus and registry before fallback" {
    for ([_]bool{ false, true }) |second| {
        var fail = OnceFail{ .failing = std.testing.FailingAllocator.init(std.testing.allocator, .{}) };
        injection = &fail;
        second_append = second;
        const cx = try ui.Cx.init(fail.allocator(), std.testing.io);
        defer cx.deinit();
        // Only Cx is used by these methods with test-mode disabled.
        var window: App = undefined;
        window.cx = cx;
        try window.mount(empty);
        try std.testing.expectError(error.OutOfMemory, window.remount(focusedThenFail));
        try std.testing.expect(fail.failing.has_induced_failure);
        try std.testing.expect(cx.is_mounted);
        try std.testing.expect(cx.focus_manager.getFocused() == null);
        try std.testing.expect(cx.node_registry.resolve(failed_handle, null) == null);
        cx.handleKeyDown(.a, .{});
        cx.handleKeyDown(.tab, .{});
        cx.layout();
        _ = cx.render();
    }
}
