//! Real-window reactive scope teardown reentry probe.
const std = @import("std");
const ui = @import("ui");
const App = @import("zenit_app").App;
const State = struct {
    scope: ?*ui.Scope = null,
    sibling: ?*ui.Scope = null,
    calls: [3]u32 = .{ 0, 0, 0 },
    clicked: u32 = 0,
    fn parent(self: *@This()) void {
        self.calls[0] += 1;
    }
    fn first(self: *@This()) void {
        self.calls[1] += 1;
        if (self.sibling) |sibling| {
            self.sibling = null;
            sibling.dispose();
        }
    }
    fn second(self: *@This()) void {
        self.calls[2] += 1;
    }
    fn unmount(raw: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(raw));
        self.clicked += 1;
        const scope = self.scope orelse return;
        self.scope = null;
        scope.dispose();
    }
};
var state: State = .{};
pub fn route(app: *App, path: []const u8, out: []u8) ?[]const u8 {
    if (std.mem.eql(u8, path, "/review/scope-reentry-mount")) {
        mount(app) catch |err| return std.fmt.bufPrint(out, "{{\"error\":\"{s}\"}}", .{@errorName(err)}) catch null;
        return "{\"ok\":true}";
    }
    if (std.mem.eql(u8, path, "/review/scope-reentry-state")) return std.fmt.bufPrint(out, "{{\"clicked\":{d},\"calls\":[{d},{d},{d}]}}", .{ state.clicked, state.calls[0], state.calls[1], state.calls[2] }) catch null;
    return null;
}
fn mount(app: *App) !void {
    state = .{};
    const scope = try ui.Scope.init(app.allocator, null, app.cx.owner);
    state.scope = scope;
    const first = try scope.childScope();
    const second = try scope.childScope();
    state.sibling = second;
    try scope.onCleanup(State, &state, State.parent);
    try first.onCleanup(State, &state, State.first);
    try second.onCleanup(State, &state, State.second);
    const node = try ui.box(app.cx, .{ .position = .absolute, .width = .{ .px = 300 }, .height = .{ .px = 80 }, .background = ui.Color.WHITE }, .{});
    (try node.style.ensureExtFallible(app.allocator)).inset = .{ .left = .{ .px = 400 }, .top = .{ .px = 350 } };
    node.meta.ownership.meta.test_id = "review.scope-reentry.unmount";
    node.behavior.events.on_click = ui.Cx.simpleHandler(State.unmount, &state);
    const label = try ui.text(app.cx, "Dispose scope with sibling cleanup", .{ .font_size = 18, .color = ui.Color.BLACK });
    try node.appendChild(app.allocator, label);
    try app.cx.root.?.appendChild(app.allocator, node);
    app.cx.root.?.markLayoutDirty();
    app.cx.needs_redraw = true;
}
