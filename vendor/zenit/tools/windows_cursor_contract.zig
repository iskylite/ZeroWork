//! Native cursor state/routing acceptance without changing the desktop cursor.
const std = @import("std");
const ui = @import("ui");
const App = @import("zenit_app").App;
extern "user32" fn LoadCursorW(?*anyopaque, *const anyopaque) callconv(.winapi) ?*anyopaque;
extern "user32" fn GetCursor() callconv(.winapi) ?*anyopaque;
extern "user32" fn GetForegroundWindow() callconv(.winapi) ?*anyopaque;
extern fn zenit_win_cursor_shape(*anyopaque, c_uint) c_int;
extern fn zenit_windows_contract_cursor(*anyopaque, *c_uint, *?*anyopaque) c_int;
extern fn zenit_windows_contract_cursor_route(*anyopaque, ?*anyopaque, c_int, *?*anyopaque) c_int;
fn require(ok: bool) !void {
    if (!ok) return error.CursorContractFailed;
}
fn current(app: *App, expected: u8) !?*anyopaque {
    var shape: c_uint = 255;
    var cursor: ?*anyopaque = null;
    try require(zenit_windows_contract_cursor(app.win.getNativeSurfaceHandle(), &shape, &cursor) != 0);
    try require(shape == expected);
    return cursor;
}
pub fn run(app: *App) !void {
    const hwnd = app.win.getNativeSurfaceHandle();
    const foreground = GetForegroundWindow();
    const before = GetCursor();
    // This is a background contract; setters must only cache state here.
    try require(foreground != hwnd);
    defer {
        app.cx.setCursorOverride(null);
        app.cx.replayCursor();
    }
    const resources = [_]u16{ 32512, 32512, 32649, 32513, 32515, 32646, 32648, 32646, 32646, 32644, 32645, 32642, 32643, 32644, 32645, 32514, 32650, 32651 };
    for (resources, 0..) |resource, shape| {
        try app.sdk.setCursorShape(app.windowId(), @intCast(shape));
        const native = try current(app, @intCast(shape));
        const expected = LoadCursorW(null, @ptrFromInt(resource));
        try require(expected != null and native == expected);
        var routed: ?*anyopaque = null;
        try require(zenit_windows_contract_cursor_route(hwnd, hwnd, 1, &routed) == 1 and routed == expected);
        try require(zenit_windows_contract_cursor_route(hwnd, hwnd, 10, &routed) == 0); // HTLEFT owned by Windows.
        try require(zenit_windows_contract_cursor_route(hwnd, null, 1, &routed) == 0); // Child view.
    }
    try app.sdk.setCursorShape(app.windowId(), 18);
    try require(try current(app, 18) == null);
    var routed: ?*anyopaque = @ptrFromInt(1);
    try require(zenit_windows_contract_cursor_route(hwnd, hwnd, 1, &routed) == 1 and routed == null);
    try app.sdk.setCursorShape(app.windowId(), 20);
    try require(zenit_windows_contract_cursor_route(hwnd, hwnd, 1, &routed) == 0);
    try require(zenit_win_cursor_shape(hwnd, 255) == 0 and zenit_win_cursor_shape(hwnd, 19) == 0);
    _ = try current(app, 20);
    const Foreign = struct {
        fn set(owner: *anyopaque, result: *c_int) void {
            result.* = zenit_win_cursor_shape(owner, 2);
        }
    };
    var rejected: c_int = -1;
    const thread = try std.Thread.spawn(.{}, Foreign.set, .{ hwnd, &rejected });
    thread.join();
    try require(rejected == 0);
    _ = try current(app, 20);
    // Exercise the UI decision -> SDK -> native state path, including custom fallback.
    for ([_]ui.CursorShape{ .pointer, .text, .ew_resize, .none, .uncontrolled, .custom }) |shape| {
        app.cx.setCursorOverride(shape);
        const expected: u8 = if (shape == .custom) 4 else @backingInt(shape);
        _ = try current(app, expected);
        try require(app.cx.cursor_state.submitted);
    }
    try require(!app.sdk.customCursorSupported());
    try require(GetCursor() == before and GetForegroundWindow() == foreground);
}
