/// devtools_probe: real-window acceptance probe for DevTools Performance panel.
///
/// Two native windows: target (force-driven/paused) + DevTools panel (mountPanel,
/// switch to Performance page). Under `ZENIT_SMOKE_FRAMES=N`, assert by phase:
///
///   Phase A (active): force redraw target each tick:
///     a) target frame interval history populated (frame_perf.interval non-empty);
///     b) DevTools FPS text leaves mount initial ("FPS: {n}" rolling average, non-zero);
///     c) DevTools window keeps rendering (keep-alive chain intact; it must schedule the next
///        poll while target is active, not only move on mouse hover).
///
///   Phase B (idle): stop driving target for >= 1.3s:
///     d) target truly stops (renderer.frame_count barely moves);
///     e) DevTools still self-polling render (frame_count continues);
///     f) FPS text shows idle annotation (distinguish "not rendering" from "stable high fps").
///
/// Target UI is written in view.yix. Without ZENIT_SMOKE_FRAMES it runs as a normal demo
/// for manual inspection.
const std = @import("std");
const ui = @import("ui");
const zenit_app = @import("zenit_app");
const MultiWindowApp = zenit_app.MultiWindowApp;
const Target = @import("_view.yix.zig").Target;

var g_target_cx: ?*ui.Cx = null;

fn mountTarget(cx: *ui.Cx, scope: *ui.Scope) anyerror!*ui.Node {
    return ui.view.render(scope, cx, Target(.{}));
}

fn mountDevtools(cx: *ui.Cx, scope: *ui.Scope) anyerror!*ui.Node {
    _ = scope;
    const target = g_target_cx orelse return error.TargetNotReady;
    return ui.devtools.mountPanel(cx, target, .{ .title = "Probe DevTools" });
}

fn findByTestId(node: *ui.Node, test_id: []const u8) ?*ui.Node {
    if (node.meta.ownership.meta.test_id) |tid| {
        if (std.mem.eql(u8, tid, test_id)) return node;
    }
    for (node.children.items) |child| {
        if (findByTestId(child, test_id)) |found| return found;
    }
    return null;
}

fn fpsText(dev_cx: *ui.Cx) ?[]const u8 {
    const root = dev_cx.root orelse return null;
    const node = findByTestId(root, "devtools.perf.fps") orelse return null;
    const tp = node.getText() orelse return null;
    return tp.content;
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

    var application = MultiWindowApp.init(allocator, .{ .pump_timeout_ms = 16 });
    defer application.deinit();

    // idle frame gating must be on: Phase B verifies "DevTools self-polls after target stops".
    const app_target = try application.createWindowWith(.{
        .io = init.io,
        .window = .{ .width = 480, .height = 320, .title = "probe target" },
        .frame_pacing = frame_pacing,
        .idle_skip_frames = true,
    }, mountTarget);
    g_target_cx = app_target.cx;

    const app_dev = try application.createWindowWith(.{
        .io = init.io,
        .window = .{ .width = 760, .height = 560, .title = "Probe DevTools" },
        .frame_pacing = frame_pacing,
        .idle_skip_frames = true,
    }, mountDevtools);

    if (!ui.devtools.setViewMode(app_dev.cx, "performance")) {
        std.log.err("[devtools_probe] setViewMode(performance) 失败", .{});
        return error.SetViewModeFailed;
    }

    if (smoke_frames) |limit| {
        // -- Phase A: target active --
        for (0..@max(limit, 60)) |_| {
            app_target.cx.needs_redraw = true;
            _ = try application.tick();
        }
        if (app_target.cx.frame_perf.interval.isEmpty() or (app_target.cx.frame_perf.interval.latest() orelse 0) == 0) {
            std.log.err("[devtools_probe] FAIL: 帧间隔历史未回填（数据链仍断）", .{});
            return error.FrameIntervalHistoryEmpty;
        }
        const fps_a = fpsText(app_dev.cx) orelse {
            std.log.err("[devtools_probe] FAIL: 找不到 devtools.perf.fps 节点", .{});
            return error.FpsNodeMissing;
        };
        if (!std.mem.startsWith(u8, fps_a, "FPS: ")) {
            std.log.err("[devtools_probe] FAIL: FPS 文本停在 mount 初值: '{s}'", .{fps_a});
            return error.FpsTextNeverUpdated;
        }
        const live_a = ui.devtools.perfCurrentFps(app_dev.cx) orelse return error.DevtoolsStateMissing;
        if (live_a == 0) {
            std.log.err("[devtools_probe] FAIL: 活跃期监控 FPS 为 0: '{s}'", .{fps_a});
            return error.FpsStuckAtZero;
        }
        if (app_dev.renderer.frame_count < 3) {
            std.log.err("[devtools_probe] FAIL: DevTools 窗口活跃期几乎没渲染（保活断链） frames={d}", .{app_dev.renderer.frame_count});
            return error.DevtoolsStarvedWhileTargetActive;
        }
        std.log.info("[devtools_probe] phase-A ok: target_frames={d} dev_frames={d} live_fps={d} fps='{s}'", .{
            app_target.renderer.frame_count, app_dev.renderer.frame_count, live_a, fps_a,
        });

        // -- Phase B: target paused --
        const target_frames_before = app_target.renderer.frame_count;
        const dev_frames_before = app_dev.renderer.frame_count;
        const idle_start = try @import("zenit_time").Instant.now(init.io);
        while (true) {
            _ = try application.tick();
            const now = try @import("zenit_time").Instant.now(init.io);
            if (now.since(idle_start) > 1_300_000_000) break;
        }
        // Allow minimal trailing frames (dirty mark consumption); no sustained rendering.
        if (app_target.renderer.frame_count > target_frames_before + 5) {
            std.log.err("[devtools_probe] FAIL: target 未真正停帧 {d}→{d}", .{ target_frames_before, app_target.renderer.frame_count });
            return error.TargetNeverIdled;
        }
        if (app_dev.renderer.frame_count <= dev_frames_before + 2) {
            std.log.err("[devtools_probe] FAIL: target 停帧后 DevTools 保活失效 {d}→{d}", .{ dev_frames_before, app_dev.renderer.frame_count });
            return error.DevtoolsKeepaliveDead;
        }
        const fps_b = fpsText(app_dev.cx) orelse return error.FpsNodeMissing;
        if (std.mem.indexOf(u8, fps_b, "idle") == null) {
            std.log.err("[devtools_probe] FAIL: 停帧 >1.3s 后无 idle 标注: '{s}'", .{fps_b});
            return error.IdleIndicatorMissing;
        }
        // Chart scroll: during pause, chart must advance (current FPS drops to 0), not
        // freeze active snapshot. Assert monitor data itself; FPS line text only displays.
        const live_b = ui.devtools.perfCurrentFps(app_dev.cx) orelse return error.DevtoolsStateMissing;
        if (live_b != 0) {
            std.log.err("[devtools_probe] FAIL: 停帧后监控 FPS 未掉 0（监控没在滚动）: {d} '{s}'", .{ live_b, fps_b });
            return error.MonitorNotRolling;
        }
        std.log.info("[devtools_probe] phase-B ok: target {d}->{d} dev {d}->{d} live_fps={d} fps='{s}'", .{
            target_frames_before, app_target.renderer.frame_count,
            dev_frames_before,    app_dev.renderer.frame_count,
            live_b,               fps_b,
        });
        std.log.info("[devtools_probe] smoke ok", .{});
        return;
    }

    try application.run();
}
