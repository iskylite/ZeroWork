//! Owned HWND titlebar hit-test contract; never activates or moves the desktop.
const std = @import("std");
const App = @import("zenit_app").App;
const ui = @import("ui");
const Point = extern struct { x: i32, y: i32 };
const Rect = extern struct { left: i32, top: i32, right: i32, bottom: i32 };
extern "user32" fn ClientToScreen(*anyopaque, *Point) callconv(.winapi) c_int;
extern "user32" fn SendMessageW(*anyopaque, u32, usize, isize) callconv(.winapi) isize;
extern "user32" fn GetForegroundWindow() callconv(.winapi) ?*anyopaque;
extern "user32" fn GetWindowRect(*anyopaque, *Rect) callconv(.winapi) c_int;
extern fn zenit_win_titlebar_region(*anyopaque, f32, f32) c_int;
extern fn zenit_win_window_drag(*anyopaque) c_int;
extern fn zenit_win_custom_frame(*anyopaque, c_int, f32, f32) c_int;
extern "dwmapi" fn DwmFlush() callconv(.winapi) i32;
extern "dwmapi" fn DwmGetWindowAttribute(*anyopaque, u32, *anyopaque, u32) callconv(.winapi) i32;
extern "user32" fn ScreenToClient(*anyopaque, *Point) callconv(.winapi) c_int;
fn require(ok: bool, location: std.builtin.SourceLocation) !void {
    if (!ok) {
        std.log.err("Windows window assertion {s}:{d}", .{ location.file, location.line });
        return error.WindowContractFailed;
    }
}
fn hit(app: *App, x: f32, y: f32) !isize {
    const scale = app.win.getScaleFactor();
    var point = Point{ .x = @intFromFloat(x * scale), .y = @intFromFloat(y * scale) };
    const hwnd = app.win.getNativeSurfaceHandle();
    try require(ClientToScreen(hwnd, &point) != 0, @src());
    const packed_point = @as(u32, @as(u16, @truncate(@as(u32, @bitCast(point.x))))) | (@as(u32, @as(u16, @truncate(@as(u32, @bitCast(point.y))))) << 16);
    return SendMessageW(hwnd, 0x84, 0, @as(isize, @as(i32, @bitCast(packed_point))));
}
const HitContext = struct {
    blocked: bool = true,
    calls: usize = 0,
    x: f32 = 0,
    y: f32 = 0,
    fn callback(raw: ?*anyopaque, x: f32, y: f32) callconv(.c) c_int {
        const self: *HitContext = @ptrCast(@alignCast(raw.?));
        self.calls += 1;
        self.x = x;
        self.y = y;
        return @intFromBool(self.blocked);
    }
};
pub fn run(app: *App) !void {
    const foreground = GetForegroundWindow();
    defer {
        app.win.setTitlebarHitCallback(null, null);
        app.win.setTitlebarDragHeight(0);
        app.win.setTitlebarDragRightInset(0);
    }
    try require(try hit(app, 40, 10) == 1, @src()); // HTCLIENT by default.
    app.win.setTitlebarDragHeight(32);
    try require(try hit(app, 40, 10) == 2, @src()); // HTCAPTION only inside the declared band.
    try require(try hit(app, 40, 40) == 1, @src());
    app.win.setTitlebarDragRightInset(64);
    const size = app.win.getSize();
    try require(try hit(app, @as(f32, @floatFromInt(size[0])) - 10, 10) == 1, @src());
    var context = HitContext{};
    app.win.setTitlebarHitCallback(HitContext.callback, &context);
    try require(try hit(app, 40, 10) == 1, @src());
    try require(context.calls == 1 and @abs(context.x - 40) < 1 and @abs(context.y - 10) < 1, @src());
    context.blocked = false;
    try require(try hit(app, 40, 10) == 2, @src());
    app.win.setTitlebarHitCallback(null, null);
    try require(zenit_win_titlebar_region(app.win.getNativeSurfaceHandle(), std.math.nan(f32), 0) == 0, @src());
    try require(zenit_win_titlebar_region(app.win.getNativeSurfaceHandle(), -1, 0) == 0, @src());
    try require(try hit(app, 40, 10) == 2, @src()); // Rejection preserves the old band.
    const ForeignThread = struct {
        fn check(hwnd: *anyopaque, result: *c_int) void {
            result.* = zenit_win_titlebar_region(hwnd, 1, 0);
        }
    };
    var foreign_result: c_int = -1;
    const thread = try std.Thread.spawn(.{}, ForeignThread.check, .{ app.win.getNativeSurfaceHandle(), &foreign_result });
    thread.join();
    try require(foreign_result == 0 and try hit(app, 40, 10) == 2, @src());
    app.win.setTitlebarDragHeight(0);
    try require(try hit(app, 40, 10) == 1, @src());
    if (foreground != app.win.getNativeSurfaceHandle()) {
        var before: Rect = undefined;
        var after: Rect = undefined;
        try require(GetWindowRect(app.win.getNativeSurfaceHandle(), &before) != 0, @src());
        try require(zenit_win_window_drag(app.win.getNativeSurfaceHandle()) == 0, @src());
        try require(GetWindowRect(app.win.getNativeSurfaceHandle(), &after) != 0, @src());
        try require(std.meta.eql(before, after), @src());
    }
    try require(GetForegroundWindow() == foreground, @src());
}

/// Uses a separate owned App; no system move loop, activation or clicks.
pub fn runCustom(io: std.Io) !void {
    const foreground = GetForegroundWindow();
    const before = @FieldType(App, "win").liveWindowCount();
    {
        const app = try App.init(std.heap.page_allocator, .{ .io = io, .window = .{ .width = 401, .height = 301, .title = "Zenit custom caption contract", .titlebar = .custom_inset, .titlebar_height = 52, .titlebar_drag_right_inset = 160 } });
        defer app.deinit();
        const hwnd = app.win.getNativeSurfaceHandle();
        try require(app.win.getTitlebarHeight() == 52, @src());
        try require(std.meta.eql(app.win.getSize(), [2]u32{ 401, 301 }), @src());
        var outer: Rect = undefined;
        var origin = Point{ .x = 0, .y = 0 };
        try require(GetWindowRect(hwnd, &outer) != 0 and ClientToScreen(hwnd, &origin) != 0, @src());
        try require(origin.y == outer.top, @src()); // No second native caption above UI.
        try require(origin.x > outer.left, @src()); // Native side resize border retained.
        const button = try ui.box(app.cx, .{ .width = .{ .px = 70 }, .height = .{ .px = 32 }, .position = .absolute, .background = ui.Color.WHITE }, .{});
        const ext = try button.style.ensureExtFallible(app.allocator);
        ext.inset = .{ .left = .{ .px = 100 }, .top = .{ .px = 8 } };
        var clicks: usize = 0;
        button.behavior.events.on_click = ui.Cx.simpleHandler(struct {
            fn clicked(raw: *anyopaque) void {
                const count: *usize = @ptrCast(@alignCast(raw));
                count.* += 1;
            }
        }.clicked, &clicks);
        app.cx.root = try ui.box(app.cx, .{ .width = .{ .grow = .{} }, .height = .{ .grow = .{} } }, .{button});
        try app.frame();
        try require(try hit(app, 40, 20) == 2, @src());
        try require(try hit(app, 120, 20) == 1, @src()); // App callback excludes interactive UI.
        try require(try hit(app, 245, 20) == 1, @src()); // Declared right-hand exclusion.
        try require(try hit(app, 40, 60) == 1, @src());
        try require(try hit(app, 40, 1) == 12, @src()); // HTTOP retained over the custom caption.
        var controls: Rect = undefined;
        try require(DwmGetWindowAttribute(hwnd, 5, &controls, @sizeOf(Rect)) >= 0, @src());
        try require(controls.right > controls.left and controls.bottom > controls.top, @src());
        var reserved: Rect = undefined;
        try require(zenit_win_caption_button_rect(hwnd, &reserved) == 1, @src());
        try require(reserved.left == controls.left + outer.left - origin.x and
            reserved.top == controls.top + outer.top - origin.y and
            reserved.right == controls.right + outer.left - origin.x and
            reserved.bottom == controls.bottom + outer.top - origin.y, @src());
        try require(zenit_win_caption_button_rect(hwnd, null) == -1, @src());
        const third = @divTrunc(controls.right - controls.left, 3);
        for ([_]isize{ 8, 9, 20 }, 0..) |expected, index| {
            var point = Point{ .x = outer.left + controls.left + third * @as(i32, @intCast(index)) + @divTrunc(third, 2), .y = outer.top + @divTrunc(controls.top + controls.bottom, 2) };
            try require(ScreenToClient(hwnd, &point) != 0, @src());
            const scale = app.win.getScaleFactor();
            const actual = try hit(app, @as(f32, @floatFromInt(point.x)) / scale, @as(f32, @floatFromInt(point.y)) / scale);
            if (actual != expected) std.log.err("custom caption control {d}: hit={d}, expected={d}, bounds={any}", .{ index, actual, expected, controls });
            try require(actual == expected, @src());
        }
        try require(zenit_win_custom_frame(hwnd, 1, std.math.nan(f32), 0) == 0, @src());
        try require(zenit_win_custom_frame(hwnd, 1, -1, 0) == 0, @src());
        try require(app.win.getTitlebarHeight() == 52 and GetForegroundWindow() == foreground and clicks == 0, @src());
        _ = ShowWindow(hwnd, 7); // SW_SHOWMINNOACTIVE, owned contract App only.
        try require(IsIconic(hwnd) != 0 and zenit_win_caption_button_rect(hwnd, &reserved) == 0, @src());
        app.cx.needs_redraw = true;
        try app.frame(); // DWM caption bounds are undefined while minimized.
        _ = ShowWindow(hwnd, 4); // Restore without activating.
        try require(IsIconic(hwnd) == 0 and GetForegroundWindow() == foreground, @src());
        try require(app.win.setSizeChecked(503, 307), @src());
        try app.frame();
        try require(std.meta.eql(app.win.getSize(), [2]u32{ 503, 307 }), @src());
        try require(zenit_win_custom_frame(hwnd, 0, 52, 0) != 0, @src());
        try require(app.win.setSizeChecked(401, 301), @src());
        try require(app.win.getTitlebarHeight() == 0, @src());
        try require(zenit_win_caption_button_rect(hwnd, &reserved) == 0, @src());
        origin = .{ .x = 0, .y = 0 };
        try require(GetWindowRect(hwnd, &outer) != 0 and ClientToScreen(hwnd, &origin) != 0 and origin.y > outer.top, @src());
        try require(GetForegroundWindow() == foreground, @src());
    }
    try require(@FieldType(App, "win").liveWindowCount() == before, @src());
    std.log.info("Windows custom caption contract: App config, client sizing, UI exclusion, DWM controls and restore PASS", .{});
}

extern "user32" fn SetWindowPos(*anyopaque, ?*anyopaque, c_int, c_int, c_int, c_int, u32) callconv(.winapi) c_int;
extern fn zenit_win_caption_button_rect(*anyopaque, ?*Rect) c_int;
extern "user32" fn ShowWindow(*anyopaque, c_int) callconv(.winapi) c_int;
extern "user32" fn IsIconic(*anyopaque) callconv(.winapi) c_int;
extern fn zenit_win_contract_refresh_source(*anyopaque, u32, u32) void;

pub fn runRefresh(app: *App) !void {
    const hwnd = app.win.getNativeSurfaceHandle();
    const foreground = GetForegroundWindow();
    const actual = app.win.getDisplayRefreshRate();
    try require(std.math.isFinite(actual) and actual > 1, @src());
    defer {
        zenit_win_contract_refresh_source(app.win.native, 0, 0);
        _ = SendMessageW(hwnd, 0x7e, 0, 0); // WM_DISPLAYCHANGE invalidates cache.
        _ = SendMessageW(hwnd, 0xf, 0, 0);
    }
    zenit_win_contract_refresh_source(app.win.native, 60000, 1001);
    // Changing the source alone must not bypass the per-monitor cache.
    try require(app.win.getDisplayRefreshRate() == actual, @src());
    _ = SendMessageW(hwnd, 0x7e, 0, 0);
    _ = SendMessageW(hwnd, 0xf, 0, 0);
    try require(@abs(app.win.getDisplayRefreshRate() - 59.94006) < 0.001, @src());
    try require(@abs(app.cx.display_refresh_hz - 59.94006) < 0.001, @src());
    zenit_win_contract_refresh_source(app.win.native, 120000, 1001);
    _ = SendMessageW(hwnd, 0x7e, 0, 0);
    _ = SendMessageW(hwnd, 0xf, 0, 0);
    try require(@abs(app.cx.display_refresh_hz - 119.88012) < 0.001, @src());
    // Invalid/default frequencies restore the real driver source, not zero Hz.
    zenit_win_contract_refresh_source(app.win.native, 1, 0);
    _ = SendMessageW(hwnd, 0x7e, 0, 0);
    _ = SendMessageW(hwnd, 0xf, 0, 0);
    try require(app.cx.display_refresh_hz == actual, @src());
    try require(GetForegroundWindow() == foreground, @src());
    std.log.info("Windows display refresh contract actual={d:.3} fractional=59.940/119.880", .{actual});
}

pub fn runPaint(app: *App) !void {
    const hwnd = app.win.getNativeSurfaceHandle();
    const foreground = GetForegroundWindow();
    var before: Rect = undefined;
    try require(GetWindowRect(hwnd, &before) != 0, @src());
    const original = app.win.getSize();
    try require(!app.win.isInLiveResize() and !app.native_frame_active, @src());
    defer {
        app.native_frame_active = false;
        _ = SendMessageW(hwnd, 0x232, 0, 0);
        _ = SetWindowPos(hwnd, null, 0, 0, before.right - before.left, before.bottom - before.top, 0x16);
        _ = SendMessageW(hwnd, 0xf, 0, 0);
    }
    _ = SendMessageW(hwnd, 0x231, 0, 0);
    try require(app.win.isInLiveResize(), @src());
    app.win.setSize(original[0] - 80, original[1] - 60);
    const size = app.win.getSize();
    // No SDK pump or App.frame here: the native WM_PAINT callback must update
    // viewport/layout while Win32 owns its nested move/size loop.
    _ = SendMessageW(hwnd, 0xf, 0, 0);
    try require(app.width == size[0] and app.height == size[1], @src());
    try require(app.cx.viewport.width == @as(f32, @floatFromInt(size[0])), @src());
    try require(app.cx.viewport.height == @as(f32, @floatFromInt(size[1])), @src());
    const root = app.cx.root orelse return error.WindowContractFailed;
    try require(@abs(root.globalRect().w - app.cx.viewport.width) < 0.1, @src());
    // A one-physical-pixel resize must survive the logical conversion even
    // when it does not change the compatibility integer size.
    var fractional: Rect = undefined;
    try require(GetWindowRect(hwnd, &fractional) != 0, @src());
    try require(SetWindowPos(hwnd, null, 0, 0, fractional.right - fractional.left - 1, fractional.bottom - fractional.top - 1, 0x16) != 0, @src());
    _ = SendMessageW(hwnd, 0xf, 0, 0);
    const exact = app.win.getLogicalSize();
    try require(@abs(app.cx.viewport.width - exact[0]) < 0.001 and @abs(app.cx.viewport.height - exact[1]) < 0.001, @src());
    const frames = app.cx.frame_count;
    _ = SendMessageW(hwnd, 0x113, 0x5a4e0001, 0);
    try require(app.cx.frame_count > frames, @src()); // Timer keeps animation ticking.
    app.native_frame_active = true;
    app.native_redraw_pending = false;
    const stable_frames = app.cx.frame_count;
    _ = SendMessageW(hwnd, 0xf, 0, 0);
    try require(app.native_redraw_pending and app.cx.frame_count == stable_frames, @src());
    app.native_frame_active = false;
    _ = SendMessageW(hwnd, 0x232, 0, 0);
    try require(!app.win.isInLiveResize(), @src());
    const ended_frames = app.cx.frame_count;
    _ = SendMessageW(hwnd, 0x113, 0x5a4e0001, 0);
    try require(app.cx.frame_count == ended_frames, @src()); // A stale timer cannot render.
    try require(GetForegroundWindow() == foreground, @src());
}

const MonitorInfo = extern struct { size: u32 = @sizeOf(MonitorInfo), monitor: Rect, work: Rect, flags: u32 };
extern "user32" fn MonitorFromWindow(*anyopaque, u32) callconv(.winapi) ?*anyopaque;
extern "user32" fn GetMonitorInfoW(*anyopaque, *MonitorInfo) callconv(.winapi) c_int;
extern "user32" fn AdjustWindowRectExForDpi(*Rect, u32, c_int, u32, u32) callconv(.winapi) c_int;
extern "user32" fn GetSystemMetricsForDpi(c_int, u32) callconv(.winapi) c_int;
extern fn zenit_win_chrome_minimum(*anyopaque, u32, u32) c_int;
extern "user32" fn GetWindow(*anyopaque, u32) callconv(.winapi) ?*anyopaque;
extern fn zenit_windows_contract_owner_resize_failure() void;
extern fn zenit_windows_contract_taskbar_failure() void;
extern fn zenit_windows_contract_background(c_int) c_int;
extern fn zenit_win_chrome_action(*anyopaque, c_int, c_int) c_int;
extern fn zenit_windows_set_origin(*anyopaque, f64, f64) void;
extern fn zenit_windows_contract_initial_geometry(*anyopaque, u32, u32) c_int;
extern "user32" fn IsWindowVisible(*anyopaque) callconv(.winapi) c_int;
extern "user32" fn GetDpiForWindow(*anyopaque) callconv(.winapi) u32;
extern "user32" fn GetClientRect(*anyopaque, *Rect) callconv(.winapi) c_int;

pub fn runInitialGeometry() !void {
    const old_background = zenit_windows_contract_background(1);
    defer _ = zenit_windows_contract_background(old_background);
    const Window = @FieldType(App, "win");
    const before = Window.liveWindowCount();
    const foreground = GetForegroundWindow();
    {
        var owner = try Window.initHidden(401, 301, "Zenit geometry owner contract");
        defer owner.deinit();
        var window = try Window.initHidden(10000, 10000, "Zenit oversized geometry contract");
        defer window.deinit();
        const hwnd = window.getNativeSurfaceHandle();
        // Background mouse activation is a message policy, reversible on this HWND.
        try require(SendMessageW(hwnd, 0x21, @intFromPtr(hwnd), 0x02010001) == 4, @src());
        _ = zenit_windows_contract_background(0);
        try require(SendMessageW(hwnd, 0x21, @intFromPtr(hwnd), 0x02010001) == 1, @src());
        _ = zenit_windows_contract_background(1);
        try require(SendMessageW(hwnd, 0x21, @intFromPtr(hwnd), 0x02010001) == 4, @src());
        var info: MonitorInfo = undefined;
        info.size = @sizeOf(MonitorInfo);
        var frame: Rect = undefined;
        try require(GetMonitorInfoW(MonitorFromWindow(hwnd, 2).?, &info) != 0 and GetWindowRect(hwnd, &frame) != 0, @src());
        try require(frame.left >= info.work.left and frame.top >= info.work.top and frame.right <= info.work.right and frame.bottom <= info.work.bottom, @src());
        try window.setCustomTitlebar(52, 0);
        const fitting_height: u32 = @intFromFloat(@floor(window.getLogicalSize()[1]) - 1);
        try require(window.setSizeChecked(401, fitting_height), @src());
        std.log.info("Windows custom frame fit requested=401x{d} actual={any} logical={any}", .{ fitting_height, window.getSize(), window.getLogicalSize() });
        try require(std.meta.eql(window.getSize(), [2]u32{ 401, fitting_height }), @src());
        try require(zenit_win_chrome_minimum(hwnd, 10000, 10000) != 0, @src());
        try require(window.setSizeChecked(10000, 10000), @src());
        try require(GetWindowRect(hwnd, &frame) != 0 and frame.left >= info.work.left and frame.top >= info.work.top and frame.right <= info.work.right and frame.bottom <= info.work.bottom, @src());
        const Limits = extern struct { reserved: Point, max_size: Point, max_position: Point, min_track: Point, max_track: Point };
        const dpi: u32 = @intFromFloat(window.getScaleFactor() * 96);
        var native_bounds = Rect{ .left = 0, .top = 0, .right = @intCast((401 * dpi + 95) / 96), .bottom = @intCast((301 * dpi + 95) / 96) };
        try require(AdjustWindowRectExForDpi(&native_bounds, 0x00cf0000, 0, 0, dpi) != 0, @src());
        try require(zenit_win_chrome_minimum(hwnd, 401, 301) != 0, @src());
        var limits: Limits = std.mem.zeroes(Limits);
        _ = SendMessageW(hwnd, 0x24, 0, @bitCast(@intFromPtr(&limits)));
        const expected_min_height = native_bounds.bottom - native_bounds.top - GetSystemMetricsForDpi(4, dpi) - GetSystemMetricsForDpi(33, dpi) - GetSystemMetricsForDpi(92, dpi);
        std.log.info("Windows custom min-track actual={any} expected={d}x{d} dpi={d}", .{ limits.min_track, native_bounds.right - native_bounds.left, expected_min_height, dpi });
        try require(limits.min_track.x == native_bounds.right - native_bounds.left, @src());
        try require(limits.min_track.y == expected_min_height, @src());
        const before_owner = frame;
        const previous_owner = GetWindow(hwnd, 4);
        zenit_windows_contract_owner_resize_failure();
        try require(!window.setOwner(&owner), @src());
        try require(GetWindow(hwnd, 4) == previous_owner and GetWindowRect(hwnd, &frame) != 0 and std.meta.eql(frame, before_owner), @src());
        try require(window.setOwner(&owner), @src());
        try require(GetWindowRect(hwnd, &frame) != 0 and std.meta.eql(frame, before_owner), @src());
        // Ownership has no placement side effect; explicit origin changes no extent.
        zenit_windows_set_origin(window.native, -123, -77);
        var moved: Rect = undefined;
        try require(GetWindowRect(hwnd, &moved) != 0 and moved.left == -123 and moved.top == -77, @src());
        try require(moved.right - moved.left == frame.right - frame.left and moved.bottom - moved.top == frame.bottom - frame.top, @src());
        zenit_windows_set_origin(window.native, @floatFromInt(frame.left), @floatFromInt(frame.top));
        zenit_windows_set_origin(window.native, @floatFromInt(info.work.left - 1), @floatFromInt(info.work.top));
        try require(GetWindowRect(hwnd, &moved) != 0, @src());
        const partly_outside = moved;
        try require(window.setOwner(&owner), @src());
        try require(GetWindowRect(hwnd, &moved) != 0 and std.meta.eql(moved, partly_outside), @src());
        try require(zenit_win_chrome_minimum(hwnd, 1, 1) != 0, @src());
        var renders: usize = 0;
        const Count = struct {
            fn callback(raw: ?*anyopaque) callconv(.c) void {
                const count: *usize = @ptrCast(@alignCast(raw.?));
                count.* += 1;
            }
        };
        window.setRenderCallback(Count.callback, &renders);
        defer window.setRenderCallback(null, null);
        var dpi_frame = frame;
        dpi_frame.right -= 2;
        _ = SendMessageW(hwnd, 0x2e0, 0, @bitCast(@intFromPtr(&dpi_frame)));
        try require(renders == 1, @src());
        renders = 0;
        _ = SendMessageW(hwnd, 0x2e0, 0, @bitCast(@intFromPtr(&dpi_frame)));
        try require(renders == 1, @src()); // Scale-only message still renders once.
        zenit_windows_set_origin(window.native, @floatFromInt(frame.left), @floatFromInt(frame.top));
        try require(window.getScaleFactor() == owner.getScaleFactor(), @src());
        const owned_geometry = window.frameWorkArea() orelse return error.WindowContractFailed;
        try require(owned_geometry[0] >= owned_geometry[6] and owned_geometry[1] >= owned_geometry[7] and
            owned_geometry[0] + owned_geometry[2] <= owned_geometry[6] + owned_geometry[8] and owned_geometry[1] + owned_geometry[3] <= owned_geometry[7] + owned_geometry[9], @src());
        const pixels = window.getDrawableSize();
        const logical = window.getLogicalSize();
        const scale = window.getScaleFactor();
        try require(@as(u32, @intFromFloat(@round(logical[0] * scale))) == pixels[0] and @as(u32, @intFromFloat(@round(logical[1] * scale))) == pixels[1], @src());
        window.clearOwner(&owner);
        try require(zenit_win_chrome_action(hwnd, 3, 1) != 0, @src());
        var fullscreen: Rect = undefined;
        try require(GetWindowRect(hwnd, &fullscreen) != 0 and std.meta.eql(fullscreen, info.monitor), @src());
        try require(window.setOwner(&owner), @src());
        try require(GetWindowRect(hwnd, &frame) != 0 and std.meta.eql(frame, fullscreen), @src());
        try require(zenit_win_chrome_action(hwnd, 3, 0) != 0, @src());
    }
    {
        var owner = try Window.initHidden(401, 301, "Edge owner contract");
        defer owner.deinit();
        var window = try Window.init(401, 301, "Visible edge geometry contract");
        defer window.deinit();
        const hwnd = window.getNativeSurfaceHandle();
        var info: MonitorInfo = undefined;
        info.size = @sizeOf(MonitorInfo);
        var frame: Rect = undefined;
        var visible: Rect = undefined;
        try require(GetMonitorInfoW(MonitorFromWindow(hwnd, 2).?, &info) != 0 and GetWindowRect(hwnd, &frame) != 0, @src());
        try require(DwmFlush() >= 0, @src());
        try require(DwmGetWindowAttribute(hwnd, 9, &visible, @sizeOf(Rect)) >= 0 and visible.right > visible.left and visible.bottom > visible.top, @src());
        const inset_left = visible.left - frame.left;
        const inset_top = visible.top - frame.top;
        const visual_width = visible.right - visible.left;
        for ([_]i32{ info.work.left, info.work.right - visual_width, info.work.left - 1 }) |visual_x| {
            window.clearOwner(&owner);
            zenit_windows_set_origin(window.native, @floatFromInt(visual_x - inset_left), @floatFromInt(info.work.top - inset_top));
            try require(DwmFlush() >= 0, @src());
            var before_edge: Rect = undefined;
            try require(GetWindowRect(hwnd, &before_edge) != 0, @src());
            try require(window.setOwner(&owner), @src());
            try require(GetWindowRect(hwnd, &frame) != 0 and std.meta.eql(frame, before_edge), @src());
        }
        window.clearOwner(&owner);
        var before_failure: Rect = undefined;
        try require(GetWindowRect(hwnd, &before_failure) != 0, @src());
        zenit_windows_contract_taskbar_failure();
        try require(window.setOwner(&owner), @src());
        try require(GetWindow(hwnd, 4) == owner.getNativeSurfaceHandle(), @src());
        try require(GetWindowRect(hwnd, &frame) != 0 and std.meta.eql(frame, before_failure), @src());
        try require(IsWindowVisible(hwnd) != 0 and GetForegroundWindow() == foreground, @src());
        zenit_windows_set_origin(window.native, @floatFromInt(info.work.right + 100 - inset_left), @floatFromInt(info.work.bottom + 100 - inset_top));
        try require(DwmFlush() >= 0, @src());
        try require(window.setOwner(&owner), @src());
        try require(DwmFlush() >= 0, @src());
        try require(DwmGetWindowAttribute(hwnd, 9, &visible, @sizeOf(Rect)) >= 0 and visible.left >= info.work.left and visible.top >= info.work.top and visible.right <= info.work.right and visible.bottom <= info.work.bottom, @src());
    }
    {
        var owner = try Window.initHidden(401, 301, "Visible owner geometry contract");
        defer owner.deinit();
        var window = try Window.initApplication(401, 301, "Cloaked owner geometry contract", false);
        defer window.deinit();
        const hwnd = window.getNativeSurfaceHandle();
        var info: MonitorInfo = undefined;
        info.size = @sizeOf(MonitorInfo);
        try require(GetMonitorInfoW(MonitorFromWindow(hwnd, 2).?, &info) != 0, @src());
        var cloaked: u32 = 0;
        try require(DwmGetWindowAttribute(hwnd, 14, &cloaked, @sizeOf(u32)) >= 0 and cloaked != 0, @src());
        zenit_windows_set_origin(window.native, @floatFromInt(info.work.right - 1), @floatFromInt(info.work.bottom - 1));
        const Presentation = struct {
            window: *Window,
            owner: *anyopaque,
            renders: usize = 0,
            complete: bool = true,
            fn callback(raw: ?*anyopaque) callconv(.c) void {
                const self: *@This() = @ptrCast(@alignCast(raw.?));
                self.renders += 1;
                self.complete = self.complete and GetWindow(self.window.getNativeSurfaceHandle(), 4) == self.owner;
                self.window.notePresented();
            }
        };
        var presentation = Presentation{ .window = &window, .owner = owner.getNativeSurfaceHandle() };
        window.setRenderCallback(Presentation.callback, &presentation);
        defer window.setRenderCallback(null, null);
        try require(window.setOwner(&owner), @src());
        try require(presentation.renders == 1 and presentation.complete, @src());
        try require(IsWindowVisible(hwnd) != 0 and GetForegroundWindow() == foreground, @src());
        try require(DwmGetWindowAttribute(hwnd, 14, &cloaked, @sizeOf(u32)) >= 0 and cloaked == 0, @src());
    }
    {
        var window = try Window.initHidden(401, 301, "Production initial extent contract");
        defer window.deinit();
        for ([_]bool{ false, true }) |custom| {
            if (custom) try window.setCustomTitlebar(52, 0);
            try require(zenit_windows_contract_initial_geometry(window.native, 401, 301) != 0, @src());
            var actual_client: Rect = undefined;
            try require(GetClientRect(window.getNativeSurfaceHandle(), &actual_client) != 0, @src());
            const dpi = GetDpiForWindow(window.getNativeSurfaceHandle());
            // Independent requested-pixel oracle; the result is read from the real HWND.
            try require(actual_client.right == (401 * dpi + 95) / 96 and actual_client.bottom == (301 * dpi + 95) / 96, @src());
            try require(zenit_windows_contract_initial_geometry(window.native, 10000, 10000) != 0, @src());
            var info: MonitorInfo = undefined;
            info.size = @sizeOf(MonitorInfo);
            var actual_frame: Rect = undefined;
            try require(GetMonitorInfoW(MonitorFromWindow(window.getNativeSurfaceHandle(), 2).?, &info) != 0 and GetWindowRect(window.getNativeSurfaceHandle(), &actual_frame) != 0, @src());
            try require(actual_frame.left == info.work.left and actual_frame.top == info.work.top and actual_frame.right == info.work.right and actual_frame.bottom == info.work.bottom, @src());
        }
    }
    try require(Window.liveWindowCount() == before and GetForegroundWindow() == foreground, @src());
    std.log.info("Windows initial geometry contract: real HWND requested pixels and oversized work area PASS", .{});
}
