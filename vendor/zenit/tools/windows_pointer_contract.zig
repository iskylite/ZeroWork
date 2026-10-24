//! Gallery-only native capture loss -> SDK -> App cancellation contract.
//! Seeds owned queues; never changes native focus/capture or injects desktop input.
const std = @import("std");
const ui = @import("ui");
const App = @import("zenit_app").App;
extern "user32" fn SendMessageW(*anyopaque, u32, usize, isize) callconv(.winapi) isize;
extern "user32" fn GetForegroundWindow() callconv(.winapi) ?*anyopaque;
extern "user32" fn GetCapture() callconv(.winapi) ?*anyopaque;
extern fn zenit_windows_contract_press(*anyopaque, c_int, c_int, c_int) c_int;
extern fn zenit_windows_contract_key(*anyopaque, u16, u32, c_int) c_int;
var clicks: usize = 0;
var lost: usize = 0;
fn require(ok: bool) !void {
    if (!ok) return error.PointerContractFailed;
}
fn pump(app: *App) !void {
    _ = try app.sdk.pump(0);
    for (app.sdk.events()) |event| app.processTestContractEvent(event);
}
fn press(app: *App, x: c_int, y: c_int) !void {
    try require(zenit_windows_contract_press(app.win.getNativeSurfaceHandle(), 0, x, y) != 0);
    try pump(app);
}
fn release(app: *App, x: c_int, y: c_int) !void {
    const point = @as(u32, @as(u16, @intCast(x))) | (@as(u32, @as(u16, @intCast(y))) << 16);
    _ = SendMessageW(app.win.getNativeSurfaceHandle(), 0x202, 0, @as(isize, @as(i32, @bitCast(point))));
    try pump(app);
}
fn sendPoint(app: *App, message: u32, x: c_int, y: c_int) void {
    sendPointFlags(app, message, x, y, 0);
}
fn sendPointFlags(app: *App, message: u32, x: c_int, y: c_int, flags: usize) void {
    const point = @as(u32, @as(u16, @truncate(@as(u32, @bitCast(x))))) |
        (@as(u32, @as(u16, @truncate(@as(u32, @bitCast(y))))) << 16);
    _ = SendMessageW(app.win.getNativeSurfaceHandle(), message, flags, @as(isize, @as(i32, @bitCast(point))));
}
fn batchedDrag(app: *App, node: *ui.Node, x: c_int, y: c_int) !void {
    const drag = ui.interaction.drag;
    const Record = struct {
        starts: usize = 0,
        moves: usize = 0,
        ends: usize = 0,
        cancels: usize = 0,
        delta: f32 = 0,
        fn event(e: drag.Event, raw: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            switch (e.phase) {
                .start => self.starts += 1,
                .move => self.moves += 1,
                .end => {
                    self.ends += 1;
                    self.delta = e.delta.x;
                },
                .cancel => self.cancels += 1,
            }
        }
    };
    var record = Record{};
    const scope = try ui.Scope.init(app.cx.allocator, null, app.cx.owner);
    defer scope.dispose();
    _ = try drag.Binding.attach(scope, app.cx, node, .{}, Record.event, &record);
    app.cx.layout();
    clicks = 0;
    const metrics = @TypeOf(app.win).inputQueueMetrics();
    // All messages arrive before a single SDK pump. A key separates the two
    // move bursts; an up separates the last move from the drag sequence.
    try require(zenit_windows_contract_press(app.win.getNativeSurfaceHandle(), 0, x, y) != 0);
    sendPoint(app, 0x200, x + 8, y);
    sendPoint(app, 0x200, x + 20, y);
    try require(zenit_windows_contract_key(app.win.getNativeSurfaceHandle(), 0x87, 0, 1) != 0); // Owned F24 separator.
    sendPoint(app, 0x200, x + 35, y);
    sendPoint(app, 0x200, x + 40, y);
    sendPoint(app, 0x202, x + 40, y);
    sendPoint(app, 0x200, x + 45, y);
    _ = try app.sdk.pump(0);
    const events = app.sdk.events();
    try require(events.len == 6);
    try require(events[0] == .mouse_button and events[0].mouse_button.pressed);
    try require(events[1] == .mouse_move and events[2] == .key and events[3] == .mouse_move);
    try require(events[4] == .mouse_button and !events[4].mouse_button.pressed and events[5] == .mouse_move);
    const scale = app.win.getScaleFactor();
    try require(@abs(events[1].mouse_move.dx - 20 / scale) < 0.01);
    try require(@abs(events[3].mouse_move.dx - 20 / scale) < 0.01);
    try require(@abs(events[5].mouse_move.dx - 5 / scale) < 0.01);
    for (events) |event| app.processTestContractEvent(event);
    try require(record.starts == 1 and record.moves >= 1 and record.ends == 1 and record.cancels == 0);
    try require(@abs(record.delta - 40 / scale) < 0.01 and clicks == 0);
    try require(!app.cx.dispatcher.hasPointerCapture() and app.cx.drag_manager.session == null);
    try require(@TypeOf(app.win).inputQueueMetrics().mouse_move_coalesced >= metrics.mouse_move_coalesced + 2);
}
pub fn run(app: *App, node: *ui.Node) !void {
    const foreground = GetForegroundWindow();
    const capture = GetCapture();
    // Never risk releasing an attended session's OS capture.
    try require(capture == null);
    const old_click = node.behavior.events.on_click;
    const old_lost = node.on_capture_lost;
    defer {
        _ = SendMessageW(app.win.getNativeSurfaceHandle(), 0x215, 0, 0);
        pump(app) catch {};
        app.cx.cancelPointerInteractions(.explicit);
        node.behavior.events.on_click = old_click;
        node.on_capture_lost = old_lost;
    }
    node.behavior.events.on_click = ui.Cx.simpleHandler(struct {
        fn clicked(_: *anyopaque) void {
            clicks += 1;
        }
    }.clicked, app);
    node.on_capture_lost = struct {
        fn cancelled(_: *ui.Node) void {
            lost += 1;
        }
    }.cancelled;
    const rect = node.globalRect();
    const scale = app.win.getScaleFactor();
    const x: c_int = @intFromFloat((rect.x + rect.w / 2) * scale);
    const y: c_int = @intFromFloat((rect.y + rect.h / 2) * scale);
    for ([_]u32{ 0x215, 0x8, 0x1f }) |message| { // capture changed, kill focus, cancel mode.
        clicks = 0;
        lost = 0;
        try press(app, x, y);
        app.cx.dispatcher.setPointerCapture(node);
        try require(app.cx.dispatcher.hasPointerCapture() and app.win.isMouseButtonPressed(.left));
        _ = SendMessageW(app.win.getNativeSurfaceHandle(), message, 0, 0);
        try pump(app);
        try require(!app.cx.dispatcher.hasPointerCapture() and !app.win.isMouseButtonPressed(.left));
        try require(lost == 1 and clicks == 0);
        // Duplicate native cancellation must be idempotent; a late up must not click.
        _ = SendMessageW(app.win.getNativeSurfaceHandle(), message, 0, 0);
        try release(app, x, y);
        try require(lost == 1 and clicks == 0);
        try press(app, x, y);
        try release(app, x, y);
        try require(clicks == 1);
    }
    // Releasing one button preserves the other native button state.
    try require(zenit_windows_contract_press(app.win.getNativeSurfaceHandle(), 0, x, y) != 0);
    try require(zenit_windows_contract_press(app.win.getNativeSurfaceHandle(), 1, x, y) != 0);
    _ = SendMessageW(app.win.getNativeSurfaceHandle(), 0x205, 0, 0);
    try require(app.win.isMouseButtonPressed(.left) and !app.win.isMouseButtonPressed(.right));
    _ = SendMessageW(app.win.getNativeSurfaceHandle(), 0x215, 0, 0);
    try pump(app);
    try require(!app.win.isMouseButtonPressed(.left));
    // Negative client coordinates and the message's Shift/Ctrl snapshot must
    // survive scaling. Modifier changes also prevent adjacent coalescing.
    sendPointFlags(app, 0x200, -20, -15, 12);
    sendPointFlags(app, 0x200, -10, -5, 12);
    sendPointFlags(app, 0x200, -10, -5, 0);
    _ = try app.sdk.pump(0);
    const negative = app.sdk.events();
    try require(negative.len == 2 and negative[0] == .mouse_move and negative[1] == .mouse_move);
    try require(@abs(negative[0].mouse_move.x - (-10 / scale)) < 0.01);
    try require(@abs(negative[0].mouse_move.y - (-5 / scale)) < 0.01);
    try require(negative[0].mouse_move.modifiers.shift and negative[0].mouse_move.modifiers.ctrl);
    try require(!negative[1].mouse_move.modifiers.shift and !negative[1].mouse_move.modifiers.ctrl);
    for (negative) |event| app.processTestContractEvent(event);
    try batchedDrag(app, node, x, y);
    try require(GetForegroundWindow() == foreground and GetCapture() == capture);
}
