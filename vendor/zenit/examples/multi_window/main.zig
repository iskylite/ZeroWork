/// multi_window: demo of two true native windows coexisting
///
/// Verification points:
///   - `MultiWindowApp` manages two windows (each Window/GPU surface/SystemSdk/Cx)
///   - Second Cx.init doesn't panic (no concurrency guard)
///   - Events route per window: each window's button counts independently, no cross-talk
///   - Text measure is per-App context: two windows measure fonts independently
///   - a11y C ABI routes per window_id (registered at init, no mutual override)
///   - Close A, B continues pump/render; closing the last window exits
///
/// Main loop is driven by public `MultiWindowApp.run()`: first window pump can block, other windows
/// drain non-blocking, events and menu commands route per native window_id.
///
/// Each window's UI is in view.yix (`WindowUi`, props distinguish A/B).
///
/// Smoke test: ZENIT_SMOKE_FRAMES=N runs N frames then auto-exits (exit 0), so scripts/CI can
/// assert "both windows truly rendered" without manual close.
const std = @import("std");
const ui = @import("ui");
const zenit_app = @import("zenit_app");
const MultiWindowApp = zenit_app.MultiWindowApp;
const WindowUi = @import("_view.yix.zig").WindowUi;

fn mountWindowA(cx: *ui.Cx, scope: *ui.Scope) anyerror!*ui.Node {
    return ui.view.render(scope, cx, WindowUi(.{ .tag = "A", .heading = "zenit multi-window: A", .button = "Click me (A)" }));
}

fn mountWindowB(cx: *ui.Cx, scope: *ui.Scope) anyerror!*ui.Node {
    return ui.view.render(scope, cx, WindowUi(.{ .tag = "B", .heading = "zenit multi-window: B", .button = "Click me (B)" }));
}

fn verifyApplicationQuitContract(allocator: std.mem.Allocator, io: std.Io) !void {
    var application = MultiWindowApp.init(allocator, .{ .pump_timeout_ms = 0 });
    defer application.deinit();

    // Exercise both public creation styles in the real native lifecycle.
    const app_a = try application.createWindow(.{
        .io = io,
        .window = .{ .width = 420, .height = 300, .title = "zenit quit-contract A" },
        .frame_pacing = .poll,
        .idle_skip_frames = false,
    });
    try app_a.mount(mountWindowA);
    const app_b = try application.createWindowWith(.{
        .io = io,
        .window = .{ .width = 420, .height = 300, .title = "zenit quit-contract B" },
        .frame_pacing = .poll,
        .idle_skip_frames = false,
    }, mountWindowB);

    if (!application.activateWindow(app_a.windowId()) or
        application.activeWindow() == null or
        application.activeWindow().?.windowId() != app_a.windowId())
        return error.ActivationFailed;
    if (!application.activateWindow(app_b.windowId()) or
        application.activeWindow() == null or
        application.activeWindow().?.windowId() != app_b.windowId())
        return error.ActivationFailed;

    _ = try application.tick();
    application.quit();
    try application.run();

    // Application-wide quit ends pumping. It deliberately leaves ownership in
    // place so the deferred manager deinit performs one ordered teardown pass.
    if (application.windowCount() != 2 or MultiWindowApp.nativeWindowCount() != 2)
        return error.QuitDestroyedWindowsEarly;
}

pub fn main(init: std.process.Init) !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const smoke_frames: ?u64 = blk: {
        const env = @import("zenit_environment").getBorrowed("ZENIT_SMOKE_FRAMES") orelse break :blk null;
        break :blk std.fmt.parseInt(u64, env, 10) catch null;
    };
    const frame_pacing: zenit_app.runtime.FramePacing = if (smoke_frames != null) .poll else .display_link;
    const idle_skip_frames = smoke_frames == null;

    var application = MultiWindowApp.init(allocator, .{ .pump_timeout_ms = 16 });
    defer application.deinit();

    const app_a = try application.createWindowWith(.{
        .io = init.io,
        .window = .{ .width = 520, .height = 380, .title = "zenit A" },
        .frame_pacing = frame_pacing,
        .idle_skip_frames = idle_skip_frames,
    }, mountWindowA);

    const app_b = try application.createWindowWith(.{
        .io = init.io,
        .window = .{ .width = 520, .height = 380, .title = "zenit B" },
        .frame_pacing = frame_pacing,
        .idle_skip_frames = idle_skip_frames,
    }, mountWindowB);

    std.log.info("[multi_window] two windows up: a11y window_id A={d} B={d}", .{
        app_a.cx.window_id, app_b.cx.window_id,
    });
    if (app_a.cx.window_id == app_b.cx.window_id) {
        std.log.err("[multi_window] window_id collision — a11y/system API 路由会互相覆盖", .{});
        return error.WindowIdCollision;
    }

    if (smoke_frames) |limit| {
        const a_id = app_a.windowId();
        const b_id = app_b.windowId();
        for (0..@max(limit, 1)) |_| _ = try application.tick();
        const a_frames = app_a.renderer.frame_count;
        const b_frames_before_close = app_b.renderer.frame_count;
        if (a_frames == 0 or b_frames_before_close == 0) return error.WindowDidNotRender;
        std.log.info("[multi_window] smoke ok: A={d} B={d} rendered", .{ a_frames, b_frames_before_close });

        // The pointer for A becomes invalid at this explicit teardown boundary.
        if (!application.closeWindow(a_id)) return error.CloseFailed;
        if (application.windowCount() != 1 or MultiWindowApp.nativeWindowCount() != 1 or application.window(a_id) != null or application.window(b_id) == null)
            return error.SingleWindowCloseFailed;
        for (0..@max(limit / 4, 1)) |_| _ = try application.tick();
        const b_live = application.window(b_id) orelse return error.SurvivorMissing;
        if (b_live.renderer.frame_count <= b_frames_before_close) return error.SurvivorDidNotRender;
        std.log.info("[multi_window] single-close ok: native=1 B continued to frame {d}", .{b_live.renderer.frame_count});

        if (!application.closeWindow(b_id)) return error.CloseFailed;
        if (application.windowCount() != 0 or MultiWindowApp.nativeWindowCount() != 0 or application.shouldContinue())
            return error.LastWindowDidNotExit;
        std.log.info("[multi_window] last-window exit ok: native=0", .{});

        try verifyApplicationQuitContract(allocator, init.io);
        if (MultiWindowApp.nativeWindowCount() != 0) return error.ApplicationQuitCleanupFailed;
        std.log.info("[multi_window] app-quit cleanup ok: create styles + activation + native=0", .{});
        return;
    }

    try application.run();
}
