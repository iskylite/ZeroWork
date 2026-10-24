//! Real-window cleanup traversal mutation probe.
const std = @import("std");
const ui = @import("ui");
const App = @import("zenit_app").App;
const State = struct { cx: *ui.Cx, parent: *ui.Node, outer: ?*ui.Node = null, nodes: [3]*ui.Node, calls: [3]u32 = .{ 0, 0, 0 } };
var state: ?State = null;
fn first(context: *anyopaque) void {
    const s: *State = @ptrCast(@alignCast(context));
    s.calls[0] += 1;
    // A cleanup hook may detach its own node; it never frees memory here.
    s.cx.detachChild(s.parent, s.nodes[0]);
}
fn second(context: *anyopaque) void {
    const s: *State = @ptrCast(@alignCast(context));
    s.calls[1] += 1;
}
fn third(context: *anyopaque) void {
    const s: *State = @ptrCast(@alignCast(context));
    s.calls[2] += 1;
}
pub fn route(app: *App, path: []const u8, out: []u8) ?[]const u8 {
    if (std.mem.eql(u8, path, "/review/cleanup-mount") or std.mem.eql(u8, path, "/review/cleanup-nested-mount")) {
        mount(app, std.mem.eql(u8, path, "/review/cleanup-nested-mount")) catch |err| return std.fmt.bufPrint(out, "{{\"error\":\"{s}\"}}", .{@errorName(err)}) catch null;
        return "{\"ok\":true}";
    }
    if (!std.mem.eql(u8, path, "/review/cleanup-remove")) return null;
    if (state == null) return null;
    const live = &state.?;
    const mounted = live.nodes[0].frame_state.state_bits.flags.is_mounted and live.nodes[1].frame_state.state_bits.flags.is_mounted and live.nodes[2].frame_state.state_bits.flags.is_mounted;
    (live.outer orelse live.parent).removeAllChildren();
    const expected_sibling_parent: ?*ui.Node = if (live.outer != null) live.parent else null;
    const detached = live.nodes[0].parent == null and live.nodes[1].parent == expected_sibling_parent and live.nodes[2].parent == expected_sibling_parent and (live.outer == null or live.parent.parent == null);
    const calls = live.calls;
    // Normalize ownership only after observing the result, so failed probes
    // still exit without leaks or stale links.
    for (live.nodes) |node| {
        if (node.parent) |parent| parent.removeChildRetained(node);
        app.cx.freeNode(node);
    }
    if (live.outer != null) app.cx.freeNode(live.parent);
    app.cx.needs_redraw = true;
    return std.fmt.bufPrint(out, "{{\"mounted\":{},\"calls\":[{d},{d},{d}],\"detached\":{}}}", .{ mounted, calls[0], calls[1], calls[2], detached }) catch null;
}
fn mount(app: *App, nested: bool) !void {
    const parent = try ui.box(app.cx, .{ .position = .absolute, .width = .{ .px = 300 }, .height = .{ .px = 100 }, .background = ui.Color.WHITE }, .{});
    (try parent.style.ensureExtFallible(app.allocator)).inset = .{ .left = .{ .px = 400 }, .top = .{ .px = 350 } };
    var nodes: [3]*ui.Node = undefined;
    for (&nodes) |*slot| {
        slot.* = try ui.text(app.cx, "Cleanup reentry", .{ .font_size = 18, .color = ui.Color.BLACK });
        try parent.appendChild(app.allocator, slot.*);
    }
    var outer: ?*ui.Node = null;
    if (nested) {
        outer = try ui.box(app.cx, .{ .width = .{ .px = 800 }, .height = .{ .px = 600 } }, .{});
        try outer.?.appendChild(app.allocator, parent);
    }
    state = .{ .cx = app.cx, .parent = parent, .outer = outer, .nodes = nodes };
    nodes[0].meta.ownership.hooks.on_cleanup = ui.Cx.simpleHandler(first, &state.?);
    nodes[1].meta.ownership.hooks.on_cleanup = ui.Cx.simpleHandler(second, &state.?);
    nodes[2].meta.ownership.hooks.on_cleanup = ui.Cx.simpleHandler(third, &state.?);
    try app.cx.root.?.appendChild(app.allocator, outer orelse parent);
    app.cx.root.?.markLayoutDirty();
    app.cx.needs_redraw = true;
}
