//! DPI-aware client sizing on an owned background HWND, without activation.
const std = @import("std");
const App = @import("zenit_app").App;
const Window = @FieldType(App, "win");
const Rect = extern struct { left: i32, top: i32, right: i32, bottom: i32 };
extern "user32" fn GetClientRect(*anyopaque, *Rect) callconv(.winapi) c_int;
extern "user32" fn GetWindowRect(*anyopaque, *Rect) callconv(.winapi) c_int;
extern "user32" fn GetForegroundWindow() callconv(.winapi) ?*anyopaque;
extern "user32" fn GetDpiForWindow(*anyopaque) callconv(.winapi) u32;
const WindowLong = if (@import("builtin").cpu.arch == .x86) struct {
    extern "user32" fn GetWindowLongW(*anyopaque, c_int) callconv(.winapi) i32;
    extern "user32" fn SetWindowLongW(*anyopaque, c_int, i32) callconv(.winapi) i32;
    const get = GetWindowLongW;
    const set = SetWindowLongW;
} else struct {
    extern "user32" fn GetWindowLongPtrW(*anyopaque, c_int) callconv(.winapi) isize;
    extern "user32" fn SetWindowLongPtrW(*anyopaque, c_int, isize) callconv(.winapi) isize;
    const get = GetWindowLongPtrW;
    const set = SetWindowLongPtrW;
};
extern "user32" fn SetWindowPos(*anyopaque, ?*anyopaque, c_int, c_int, c_int, c_int, u32) callconv(.winapi) c_int;
extern "user32" fn SendMessageW(*anyopaque, u32, usize, isize) callconv(.winapi) isize;
extern "user32" fn CreateMenu() callconv(.winapi) ?*anyopaque;
extern "user32" fn AppendMenuW(*anyopaque, u32, usize, [*:0]const u16) callconv(.winapi) c_int;
extern "user32" fn GetMenu(*anyopaque) callconv(.winapi) ?*anyopaque;
extern "user32" fn SetMenu(*anyopaque, ?*anyopaque) callconv(.winapi) c_int;
extern "user32" fn DestroyMenu(*anyopaque) callconv(.winapi) c_int;
extern "user32" fn DrawMenuBar(*anyopaque) callconv(.winapi) c_int;
const MonitorInfo = extern struct { size: u32 = @sizeOf(MonitorInfo), monitor: Rect, work: Rect, flags: u32 };
extern "user32" fn MonitorFromWindow(*anyopaque, u32) callconv(.winapi) ?*anyopaque;
extern "user32" fn GetMonitorInfoW(*anyopaque, *MonitorInfo) callconv(.winapi) c_int;
extern "user32" fn AdjustWindowRectExForDpi(*Rect, u32, c_int, u32, u32) callconv(.winapi) c_int;
extern "user32" fn GetSystemMetricsForDpi(c_int, u32) callconv(.winapi) c_int;
extern "user32" fn GetPropW(*anyopaque, [*:0]const u16) callconv(.winapi) ?*anyopaque;
extern "user32" fn IsZoomed(*anyopaque) callconv(.winapi) c_int;
extern "user32" fn GetMenuItemCount(*anyopaque) callconv(.winapi) c_int;
extern "user32" fn GetMenuStringW(*anyopaque, u32, [*]u16, c_int, u32) callconv(.winapi) c_int;
extern "user32" fn CreateWindowExW(u32, [*:0]const u16, [*:0]const u16, u32, c_int, c_int, c_int, c_int, ?*anyopaque, ?*anyopaque, ?*anyopaque, ?*anyopaque) callconv(.winapi) ?*anyopaque;
extern fn zenit_win_custom_frame(*anyopaque, c_int, f32, f32) c_int;
extern "user32" fn DestroyWindow(*anyopaque) callconv(.winapi) c_int;

// Independent native HWND: no Zenit WndProc, sizing helper, or renderer.
fn expectedClient(app: *App, width: u32, height: u32, info: MonitorInfo, dpi: u32, style: u32, ex_style: u32) ![3]u32 {
    const hwnd = app.win.getNativeSurfaceHandle();
    var menu: ?*anyopaque = null;
    if (GetMenu(hwnd)) |source| {
        menu = CreateMenu() orelse return error.WindowSizeContractFailed;
        var label: [256]u16 = @splat(0);
        const count = GetMenuItemCount(source);
        try require(count >= 0, @src());
        for (0..@intCast(count)) |index| {
            const len = GetMenuStringW(source, @intCast(index), &label, @intCast(label.len), 0x400);
            try require(len > 0 and len < label.len - 1, @src());
            label[@intCast(len)] = 0;
            try require(AppendMenuW(menu.?, 0, index + 1, @ptrCast(&label)) != 0, @src());
        }
    }
    const probe = CreateWindowExW(ex_style, std.unicode.utf8ToUtf16LeStringLiteral("STATIC"), std.unicode.utf8ToUtf16LeStringLiteral("Native size oracle"), style & ~@as(u32, 0x10000000), info.work.left, info.work.top, info.work.right - info.work.left, info.work.bottom - info.work.top, null, menu, null, null) orelse return error.WindowSizeContractFailed;
    defer _ = DestroyWindow(probe); // DestroyWindow also destroys its menu.
    var client: Rect = undefined;
    var frame: Rect = undefined;
    try require(GetClientRect(probe, &client) != 0 and GetWindowRect(probe, &frame) != 0, @src());
    const inset_w = frame.right - frame.left - client.right;
    const wanted_w = (@as(u64, width) * dpi + 95) / 96;
    const wanted_h = (@as(u64, height) * dpi + 95) / 96;
    const zoomed = IsZoomed(hwnd) != 0;
    const cap_w: u64 = if (zoomed) std.math.maxInt(i32) else @intCast(info.work.right - info.work.left);
    const cap_h: u64 = if (zoomed) std.math.maxInt(i32) else @intCast(info.work.bottom - info.work.top);
    const outer_w: c_int = @intCast(@min(wanted_w + @as(u64, @intCast(inset_w)), cap_w));
    // Measure menu rows at the final width, independently of Zenit's result.
    try require(SetWindowPos(probe, null, 0, 0, outer_w, info.work.bottom - info.work.top, 0x16) != 0, @src());
    try require(GetClientRect(probe, &client) != 0 and GetWindowRect(probe, &frame) != 0, @src());
    var removed: i32 = 0;
    if (GetPropW(hwnd, std.unicode.utf8ToUtf16LeStringLiteral("Zenit.CustomFrame")) != null) {
        removed = GetSystemMetricsForDpi(4, dpi);
        if (!zoomed) removed += GetSystemMetricsForDpi(33, dpi) + GetSystemMetricsForDpi(92, dpi);
    }
    const inset_h = frame.bottom - frame.top - client.bottom - removed;
    return .{ @intCast(@min(wanted_w, cap_w - @as(u64, @intCast(inset_w)))), @intCast(@min(wanted_h, cap_h - @as(u64, @intCast(inset_h)))), @intCast(inset_h) };
}

fn require(ok: bool, location: std.builtin.SourceLocation) !void {
    if (!ok) {
        std.log.err("Windows size assertion {s}:{d}", .{ location.file, location.line });
        return error.WindowSizeContractFailed;
    }
}
fn sized(app: *App, width: u32, height: u32) !void {
    try require(app.win.setSizeChecked(width, height), @src());
    const actual = app.win.getSize();
    const pixels = app.win.getDrawableSize();
    const dpi = GetDpiForWindow(app.win.getNativeSurfaceHandle());
    std.log.info("Windows size contract requested={d}x{d} actual={d}x{d} physical={d}x{d} dpi={d}", .{ width, height, actual[0], actual[1], pixels[0], pixels[1], dpi });
    const hwnd = app.win.getNativeSurfaceHandle();
    var info: MonitorInfo = undefined;
    info.size = @sizeOf(MonitorInfo);
    try require(GetMonitorInfoW(MonitorFromWindow(hwnd, 2).?, &info) != 0, @src());
    const style: u32 = @truncate(@as(usize, @bitCast(WindowLong.get(hwnd, -16))));
    const ex_style: u32 = @truncate(@as(usize, @bitCast(WindowLong.get(hwnd, -20))));
    const expected = try expectedClient(app, width, height, info, dpi, style, ex_style);
    const expected_w = expected[0];
    const expected_h = expected[1];
    var outer: Rect = undefined;
    try require(GetWindowRect(hwnd, &outer) != 0, @src());
    try require(pixels[0] == expected_w and pixels[1] == expected_h, @src());
    try require(outer.left >= info.work.left and outer.top >= info.work.top and
        outer.right <= info.work.right and outer.bottom <= info.work.bottom, @src());
    try require(actual[0] == expected_w * 96 / dpi and actual[1] == expected_h * 96 / dpi, @src());
    _ = SendMessageW(app.win.getNativeSurfaceHandle(), 0xf, 0, 0);
    const logical = app.win.getLogicalSize();
    try require(app.width == actual[0] and app.height == actual[1], @src());
    try require(app.cx.viewport.width == logical[0] and app.cx.viewport.height == logical[1], @src());
}
pub fn run(app: *App) !void {
    const hwnd = app.win.getNativeSurfaceHandle();
    const foreground = GetForegroundWindow();
    const old_style = WindowLong.get(hwnd, -16);
    const old_ex_style = WindowLong.get(hwnd, -20);
    const old_menu = GetMenu(hwnd);
    const old_custom = GetPropW(hwnd, std.unicode.utf8ToUtf16LeStringLiteral("Zenit.CustomFrame")) != null;
    const old_titlebar = app.win.getTitlebarHeight();
    var before: Rect = undefined;
    try require(GetWindowRect(hwnd, &before) != 0, @src());
    const menu = CreateMenu() orelse return error.WindowSizeContractFailed;
    defer {
        _ = zenit_win_custom_frame(hwnd, @intFromBool(old_custom), if (old_titlebar > 0) old_titlebar else 52, 0);
        _ = SetMenu(hwnd, old_menu);
        _ = WindowLong.set(hwnd, -16, old_style);
        _ = WindowLong.set(hwnd, -20, old_ex_style);
        _ = SetWindowPos(hwnd, null, 0, 0, before.right - before.left, before.bottom - before.top, 0x36);
        _ = DrawMenuBar(hwnd);
        _ = DestroyMenu(menu);
        _ = SendMessageW(hwnd, 0xf, 0, 0);
    }
    try sized(app, 801, 601);
    try sized(app, 1150, 850);
    try require(AppendMenuW(menu, 0, 1, std.unicode.utf8ToUtf16LeStringLiteral("Sizing 菜单")) != 0, @src());
    try require(SetMenu(hwnd, menu) != 0, @src());
    _ = DrawMenuBar(hwnd);
    try sized(app, 803, 603);
    var single_row: Rect = undefined;
    try require(GetWindowRect(hwnd, &single_row) != 0, @src());
    for (2..10) |id| {
        try require(AppendMenuW(menu, 0, id, std.unicode.utf8ToUtf16LeStringLiteral("Extended sizing menu 菜单")) != 0, @src());
    }
    _ = DrawMenuBar(hwnd);
    try sized(app, 803, 603); // Multiple menu rows must not steal client height.
    var wrapped: Rect = undefined;
    try require(GetWindowRect(hwnd, &wrapped) != 0, @src());
    try require(wrapped.bottom - wrapped.top > single_row.bottom - single_row.top, @src());
    std.log.info("Windows wrapped menu outer height {d}->{d}, client height stays 603", .{ single_row.bottom - single_row.top, wrapped.bottom - wrapped.top });
    try sized(app, 10000, 10000); // Both axes clamp with wrapped menus.
    // Find a native row threshold without resizing/rendering Zenit at every width.
    var info: MonitorInfo = undefined;
    info.size = @sizeOf(MonitorInfo);
    try require(GetMonitorInfoW(MonitorFromWindow(hwnd, 2).?, &info) != 0, @src());
    const dpi = GetDpiForWindow(hwnd);
    const style: u32 = @truncate(@as(usize, @bitCast(WindowLong.get(hwnd, -16))));
    const ex_style: u32 = @truncate(@as(usize, @bitCast(WindowLong.get(hwnd, -20))));
    var previous_inset: ?u32 = null;
    var found_threshold = false;
    var threshold_width: u32 = 0;
    for (200..805) |width| {
        const expected = try expectedClient(app, @intCast(width), 301, info, dpi, style, ex_style);
        if (previous_inset) |prior| {
            if (prior != expected[2]) {
                try sized(app, @intCast(width - 1), 301);
                try sized(app, @intCast(width), 301);
                try sized(app, @intCast(width + 1), 301);
                threshold_width = @intCast(width);
                found_threshold = true;
                break;
            }
        }
        previous_inset = expected[2];
    }
    try require(found_threshold, @src());
    // Repeat both the wrap boundary and oversize with the other chrome policy.
    try require(zenit_win_custom_frame(hwnd, @intFromBool(!old_custom), 52, 0) != 0, @src());
    try sized(app, threshold_width - 1, 301);
    try sized(app, threshold_width, 301);
    try sized(app, threshold_width + 1, 301);
    try sized(app, 10000, 10000);
    try require(zenit_win_custom_frame(hwnd, @intFromBool(old_custom), if (old_titlebar > 0) old_titlebar else 52, 0) != 0, @src());
    _ = WindowLong.set(hwnd, -16, old_style & ~@as(isize, 0x40000)); // No WS_THICKFRAME.
    _ = WindowLong.set(hwnd, -20, old_ex_style | 0x200); // WS_EX_CLIENTEDGE.
    _ = SetWindowPos(hwnd, null, 0, 0, 0, 0, 0x37);
    try require(WindowLong.get(hwnd, -16) == old_style & ~@as(isize, 0x40000), @src());
    try require(WindowLong.get(hwnd, -20) == old_ex_style | 0x200, @src());
    try sized(app, 805, 605);
    _ = WindowLong.set(hwnd, -16, (old_style & ~@as(isize, 0x40000)) | 0x300000); // Native scrollbars.
    _ = SetWindowPos(hwnd, null, 0, 0, 0, 0, 0x37);
    try sized(app, 807, 607);
    var stable: Rect = undefined;
    try require(GetWindowRect(hwnd, &stable) != 0, @src());
    const cached = .{ app.win.width, app.win.height };
    for ([_][2]u32{ .{ 0, 600 }, .{ 800, 0 }, .{ std.math.maxInt(u32), 600 }, .{ 800, std.math.maxInt(u32) } }) |size| {
        try require(!app.win.setSizeChecked(size[0], size[1]), @src());
        var after: Rect = undefined;
        try require(GetWindowRect(hwnd, &after) != 0 and std.meta.eql(stable, after), @src());
        try require(app.win.width == cached[0] and app.win.height == cached[1], @src());
        const count = Window.liveWindowCount();
        std.log.info("Windows size invalid probe {any} count={d}", .{ size, count });
        if (Window.init(size[0], size[1], "Invalid sizing contract")) |created| {
            var owned = created;
            owned.deinit();
            return error.WindowSizeContractFailed;
        } else |err| try require(err == error.WindowCreationFailed, @src());
        try require(Window.liveWindowCount() == count, @src());
    }
    var accepted = true;
    const thread = try std.Thread.spawn(.{}, struct {
        fn worker(win: *Window, result: *bool) void {
            result.* = win.setSizeChecked(807, 607);
        }
    }.worker, .{ &app.win, &accepted });
    thread.join();
    std.log.info("Windows size thread accepted={} foreground before={any} after={any}", .{ accepted, foreground, GetForegroundWindow() });
    try require(!accepted and GetForegroundWindow() == foreground, @src());
    var final: Rect = undefined;
    try require(GetWindowRect(hwnd, &final) != 0 and std.meta.eql(stable, final), @src());
}
