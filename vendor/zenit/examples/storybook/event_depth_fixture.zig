//! Real-window event propagation depth probe.
const std = @import("std");
const ui = @import("ui");
const App = @import("zenit_app").App;
const State = struct { capture: u32 = 0, clicks: u32 = 0 };
var shallow: State = .{};
var deep: State = .{};
var deep_leaf: ?*ui.Node = null;
fn capture(event: ui.events.Event, context: ?*anyopaque) ui.events.EventResult {
    if (event != .click) return .ignored;
    const state: *State = @ptrCast(@alignCast(context.?));
    state.capture += 1;
    return .stop;
}
fn clicked(context: *anyopaque) void {
    const state: *State = @ptrCast(@alignCast(context));
    state.clicks += 1;
}
pub fn route(app: *App, path: []const u8, out: []u8) ?[]const u8 {
    if (std.mem.eql(u8, path, "/review/event-depth-mount")) {
        mount(app) catch |err| return std.fmt.bufPrint(out, "{{\"error\":\"{s}\"}}", .{@errorName(err)}) catch null;
        return "{\"ok\":true}";
    }
    if (std.mem.eql(u8, path, "/review/event-depth-dispatch")) {
        _ = app.cx.dispatcher.dispatch(.{ .click = .{ .x = 0, .y = 0 } }, deep_leaf orelse return null);
        return "{\"ok\":true}";
    }
    if (std.mem.eql(u8, path, "/review/event-depth-state")) return std.fmt.bufPrint(out, "{{\"shallow_capture\":{d},\"shallow_clicks\":{d},\"deep_capture\":{d},\"deep_clicks\":{d}}}", .{ shallow.capture, shallow.clicks, deep.capture, deep.clicks }) catch null;
    return null;
}
fn mount(app: *App) !void {
    shallow = .{};
    deep = .{};
    try branch(app, &shallow, 12, 350, "review.event-depth.shallow", "Shallow capture control");
    try branch(app, &deep, 180, 450, "review.event-depth.deep", "Deep capture control");
    app.cx.root.?.markLayoutDirty();
    app.cx.needs_redraw = true;
}
fn branch(app: *App, state: *State, depth: usize, y: f32, id: []const u8, label: []const u8) !void {
    const root = try ui.box(app.cx, .{ .position = .absolute, .width = .{ .px = 280 }, .height = .{ .px = 60 }, .background = ui.Color.WHITE }, .{});
    (try root.style.ensureExtFallible(app.allocator)).inset = .{ .left = .{ .px = 400 }, .top = .{ .px = y } };
    root.behavior.events.on_event_capture = capture;
    root.behavior.events.capture_context = state;
    var parent = root;
    for (0..depth) |_| {
        const child = try ui.box(app.cx, .{ .width = .{ .px = 280 }, .height = .{ .px = 60 } }, .{});
        try parent.appendChild(app.allocator, child);
        parent = child;
    }
    const leaf = try ui.text(app.cx, label, .{ .font_size = 18, .color = ui.Color.BLACK });
    leaf.meta.ownership.meta.test_id = id;
    if (state == &deep) deep_leaf = leaf;
    leaf.behavior.events.on_click = ui.Cx.simpleHandler(clicked, state);
    try parent.appendChild(app.allocator, leaf);
    try app.cx.root.?.appendChild(app.allocator, root);
}
