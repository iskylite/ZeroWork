//! A different Header is compiled for each window backend. GPU choice is irrelevant.
const std = @import("std");
const builtin = @import("builtin");
const ui = @import("ui");
const app = @import("zenit_app");
const v = ui.view;
const W = ui.widgets;
var test_window: ?*app.App = null;
var test_search: ?*ui.Signal([]const u8) = null;
fn testRoute(path: []const u8, _: []const u8, out: []u8) ?[]const u8 {
    const window = test_window orelse return null;
    if (std.mem.eql(u8, path, "/chrome-input")) {
        var writer = std.Io.Writer.fixed(out);
        std.json.Stringify.value(if (test_search) |value| value.peek() else "", .{}, &writer) catch return null;
        return writer.buffered();
    }
    if (std.mem.eql(u8, path, "/chrome-double-maximize")) {
        window.toggleMaximize() catch return null;
        window.toggleMaximize() catch return null;
    } else if (std.mem.eql(u8, path, "/chrome-fullscreen-cancel")) {
        window.setFullscreen(true) catch return null;
        window.setFullscreen(false) catch return null;
    } else if (!std.mem.eql(u8, path, "/chrome-state")) return null;
    const s = window.chromeState();
    return std.fmt.bufPrint(out, "{{\"requested\":\"{s}\",\"effective\":\"{s}\",\"owner\":\"{s}\",\"fallback\":\"{s}\",\"maximized\":{},\"fullscreen\":{},\"transitioning\":{},\"active\":{},\"width\":{d},\"height\":{d},\"native_controls\":{d},\"capabilities\":{d},\"generation\":{d}}}", .{ @tagName(s.requested_mode), @tagName(s.effective_mode), @tagName(s.controls_owner), @tagName(s.fallback_reason), s.maximized, s.fullscreen, s.fullscreen_transitioning, s.active, s.width, s.height, s.native_controls_count, @as(u8, @bitCast(s.capabilities)), s.state_generation }) catch null;
}
var accept_close = false;
var close_count: ?*ui.Signal(u32) = null;
fn closeRequest(_: *app.App) bool {
    if (close_count) |count| count.set(count.peek() + 1);
    return accept_close;
}
fn allowClose(_: *ui.Cx) void {
    accept_close = true;
}
fn clearCount() void {
    close_count = null;
    test_search = null;
}
fn close(cx: *ui.Cx) void {
    cx.performWindowAction(.close) catch {};
}
fn maximize(cx: *ui.Cx) void {
    cx.performWindowAction(.toggle_maximize) catch |err| std.log.warn("Maximize request: {s}", .{@errorName(err)});
}
fn fullscreen(cx: *ui.Cx) void {
    const s = cx.windowChrome() catch return;
    cx.performWindowAction(.{ .fullscreen = !s.peek().fullscreen }) catch |err| std.log.warn("Fullscreen request: {s}", .{@errorName(err)});
}
fn commonHeader(scope: *ui.Scope, cx: *ui.Cx, title: []const u8) !*ui.Node {
    const search = try scope.createText("", .{});
    test_search = search;
    const owner = (try cx.windowChrome()).peek().controls_owner;
    const controls = if (owner == .application or owner == .none) try W.WindowControls(.{}).mount(scope, cx) else null;
    return W.WindowHeader(.{ .test_id = "chrome.header", .style = header_style }, .{
        W.DragRegion(.{ .test_id = "chrome.drag", .style = .{ .width = .fill, .height = .fill, .justify = .center } }, .{v.text(.{ .test_id = "chrome.backend" }, title)}),
        controls,
        v.box(.{ .test_id = "chrome.search", .window_region = .client }, .{W.Input(.{ .value = search, .placeholder = "Search", .width = 180 })}),
    }).mount(scope, cx);
}
const header_style = ui.css(.{ .width = .fill, .height = ui.arb.px(52), .padding = .{ .left = 12, .right = 12 }, .align_items = .center, .gap = 12, .background = ui.arb.hex(0xe9edf4) });
const MacHeader = struct {
    fn mount(scope: *ui.Scope, cx: *ui.Cx) !*ui.Node {
        return commonHeader(scope, cx, "AppKit Header");
    }
};
const WindowsHeader = struct {
    fn mount(scope: *ui.Scope, cx: *ui.Cx) !*ui.Node {
        return commonHeader(scope, cx, "Win32 Header");
    }
};
const LinuxHeader = struct {
    fn mount(scope: *ui.Scope, cx: *ui.Cx) !*ui.Node {
        return commonHeader(scope, cx, "Wayland Header");
    }
};
const Header = switch (app.build_environment.window_backend) {
    .appkit => MacHeader,
    .win32 => WindowsHeader,
    .wayland => LinuxHeader,
    else => @compileError("Unsupported window backend"),
};
fn mount(cx: *ui.Cx, scope: *ui.Scope) anyerror!*ui.Node {
    cx.setTheme(&ui.theme.light);
    const count = try scope.createSignal(u32, 0);
    close_count = count;
    try scope.onCleanup(ui.Cx, cx, struct {
        fn clean(_: *ui.Cx) void {
            clearCount();
        }
    }.clean);
    const header = try Header.mount(scope, cx);
    const s = try cx.windowChrome();
    return v.render(scope, cx, v.col(.{ .style = .{ .width = .fill, .height = .fill } }, .{
        header,
        v.col(.{ .style = .{ .width = .fill, .padding = ui.Padding.all(20), .gap = 12 } }, .{
            v.text(.{ .test_id = "chrome.state" }, v.fmt("requested={any}, effective={any}, owner={any}, fallback={any}", .{ ui.field(s, .requested_mode), ui.field(s, .effective_mode), ui.field(s, .controls_owner), ui.field(s, .fallback_reason) })),
            v.text(.{ .test_id = "chrome.close-count" }, v.fmt("Close requests: {d}", .{count})),
            v.attrs(.{ .test_id = "chrome.close" }, W.Button(.{ .label = "Request close (initially cancelled)", .on_click = cx.on(ui.Cx, cx, close) })),
            v.attrs(.{ .test_id = "chrome.allow-close" }, W.Button(.{ .label = "Allow closing", .on_click = cx.on(ui.Cx, cx, allowClose) })),
            v.attrs(.{ .test_id = "chrome.maximize" }, W.Button(.{ .label = "Toggle maximize", .on_click = cx.on(ui.Cx, cx, maximize) })),
            v.attrs(.{ .test_id = "chrome.fullscreen" }, W.Button(.{ .label = "Toggle fullscreen", .on_click = cx.on(ui.Cx, cx, fullscreen) })),
        }),
    }));
}
var smoke_close_calls: u32 = 0;
var smoke_keys_seen: u32 = 0;
fn smokeKeyFilter(_: *app.App, event: app.KeyEvent) bool {
    smoke_keys_seen += 1;
    // Consume only the platform command key + K; everything else reaches the UI.
    return event.key == .k and ui.events.primaryModifier(event.modifiers);
}
fn smokeVeto(window: *app.App) bool {
    smoke_close_calls += 1;
    // A close hook may itself request close; it must never recursively re-enter.
    window.requestClose() catch {};
    return false;
}
fn smokeMount(cx: *ui.Cx, scope: *ui.Scope) anyerror!*ui.Node {
    return v.render(scope, cx, W.WindowHeader(.{}, .{"Independent window"}));
}
fn findTestId(node: *ui.Node, id: []const u8) ?*ui.Node {
    if (node.meta.ownership.meta.test_id) |value| if (std.mem.eql(u8, value, id)) return node;
    for (node.children.items) |child| if (findTestId(child, id)) |found| return found;
    return null;
}
var remount_cleanups: u32 = 0;
fn remountCleanup(_: *ui.Cx) void {
    remount_cleanups += 1;
}
fn remountRoot(cx: *ui.Cx, scope: *ui.Scope) anyerror!*ui.Node {
    try scope.onCleanup(ui.Cx, cx, remountCleanup);
    return v.render(scope, cx, v.text(.{ .test_id = "smoke.remounted" }, "Replacement"));
}
fn failedRemount(cx: *ui.Cx, scope: *ui.Scope) anyerror!*ui.Node {
    try scope.onCleanup(ui.Cx, cx, remountCleanup);
    return error.SmokeMountFailure;
}
var smoke_application: ?*app.MultiWindowApp = null;
var destroyed_ids: [16]u64 = undefined;
var destroyed_count: usize = 0;
fn smokeDestroy(window: *app.App) void {
    const id = window.windowId();
    // Both public close paths must be safe inside the teardown callback.
    window.requestClose() catch {};
    if (smoke_application) |application| _ = application.closeWindow(id);
    // App is still complete here, including the mounted UI and native window.
    std.debug.assert(window.cx.root != null);
    destroyed_ids[destroyed_count] = id;
    destroyed_count += 1;
}
var shared_texture_id: u32 = 0;
fn sharedRoot(cx: *ui.Cx, _: *ui.Scope) anyerror!*ui.Node {
    const image = try ui.image(cx, shared_texture_id, .{ .width = .fixed(64), .height = .fixed(64) });
    image.meta.ownership.meta.test_id = "smoke.shared-image";
    return image;
}
fn sharedSmoke(allocator: std.mem.Allocator, io: std.Io) !void {
    if (comptime app.build_environment.os == .linux) {
        var application = app.MultiWindowApp.init(allocator, .{ .pump_timeout_ms = 0, .shared_gpu = true });
        defer application.deinit();
        const a = try application.createWindowWith(.{ .io = io }, smokeMount);
        const b = try application.createWindowWith(.{ .io = io }, smokeMount);
        if (a.sharedImageStore() != null or b.sharedImageStore() != null) return error.LinuxSharedStore;
        if (a.renderer.image_renderer.device == b.renderer.image_renderer.device) return error.LinuxSharedDevice;
        if (!try application.tick()) return error.LinuxIndependentTickStopped;
        if (!application.closeWindow(a.windowId())) return error.LinuxFirstCloseFailed;
        if (!try application.tick()) return error.LinuxSurvivorTickStopped;
        std.log.info("chrome Linux shared_gpu fallback: independent windows and survivor passed", .{});
        return;
    }

    if (comptime app.build_environment.os == .windows) {
        const Painter = @typeInfo(@FieldType(app.App, "renderer")).pointer.child;
        // The Windows painter embeds its image renderer by value.
        const ImageField = @FieldType(Painter, "image_renderer");
        const ImageRenderer = switch (@typeInfo(ImageField)) {
            .pointer => |p| p.child,
            else => ImageField,
        };
        if (comptime !@hasField(ImageRenderer, "device")) return;
    }

    var application = app.MultiWindowApp.init(allocator, .{ .pump_timeout_ms = 0, .shared_gpu = true });
    defer application.deinit();
    const a = try application.createWindow(.{ .io = io });
    const store = a.sharedImageStore() orelse return error.SharedStoreMissing;
    shared_texture_id = try store.loadTexture(2, 2, &.{ 255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255, 255, 255, 255, 255 });
    try a.mount(sharedRoot);
    const b = try application.createWindowWith(.{ .io = io }, sharedRoot);
    if (b.sharedImageStore() != store) return error.SharedStoreIdentityMismatch;
    if (a.renderer.image_renderer.device != store.device or b.renderer.image_renderer.device != store.device) return error.SharedDeviceIdentityMismatch;
    if (comptime app.build_environment.os == .windows) {
        if (a.painter.state.queue != b.painter.state.queue) return error.SharedQueueIdentityMismatch;
    } else {
        if (a.renderer.queue != b.renderer.queue) return error.SharedQueueIdentityMismatch;
    }
    if (a.renderer.image_renderer.getTextureSize(shared_texture_id) == null or b.renderer.image_renderer.getTextureSize(shared_texture_id) == null) return error.SharedTextureMissing;
    if (findTestId(a.cx.root.?, "smoke.shared-image") == null or findTestId(b.cx.root.?, "smoke.shared-image") == null) return error.SharedImageNodeMissing;
    try a.frame();
    try b.frame();
    if (comptime app.test_harness.enabled and app.build_environment.os != .linux) {
        a.rebindTestHarness();
        if (!app.test_harness.startRecording("/tmp/zenit-phasea-shared-owner.mp4", 30).active) return error.SharedRecordingStartFailed;
        b.rebindTestHarness();
        try b.frame();
        try a.frame();
        const stopped = app.test_harness.stopRecording();
        if (!stopped.ok or stopped.active or stopped.frame_count == 0) return error.SharedRecordingStopFailed;
    }
    if (!application.closeWindow(a.windowId())) return error.SharedFirstCloseFailed;
    if (b.sharedImageStore() != store or b.renderer.image_renderer.getTextureSize(shared_texture_id) == null) return error.SharedSurvivorTextureMissing;
    try b.frame();
    // Closing the last window must not destroy the store or invalidate ids.
    if (!application.closeWindow(b.windowId())) return error.SharedLastCloseFailed;
    if (store.getTextureSize(shared_texture_id) == null) return error.SharedStoreEndedAtLastClose;
    const c = try application.createWindowWith(.{ .io = io }, sharedRoot);
    if (c.sharedImageStore() != store or c.renderer.image_renderer.getTextureSize(shared_texture_id) == null) return error.SharedReopenLostTexture;
    c.win.setSize(480, 280);
    if (comptime app.build_environment.os != .windows) try c.maybeReconfigureSurface();
    c.cx.requestRedraw();
    if (!try application.tick()) return error.SharedReopenTickStopped;
    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 1 });
    application.allocator = failing.allocator();
    const failed_init = application.createWindow(.{ .io = io });
    application.allocator = allocator;
    if (failed_init) |unexpected| {
        _ = application.closeWindow(unexpected.windowId());
        return error.SharedInitFailureNotInjected;
    } else |err| if (err != error.OutOfMemory) return err;
    // A failed builder rolls its App back, without releasing borrowed GPU state.
    if (application.createWindowWith(.{ .io = io }, failedRemount)) |_| return error.SharedFailedMountAccepted else |err| if (err != error.SmokeMountFailure) return err;
    c.cx.requestRedraw();
    if (!try application.tick()) return error.SharedReopenTickStopped;
    std.log.info("chrome shared GPU: shared texture rendering, survivor, reopen, failure rollback passed", .{});
}
var reopen_application: ?*app.MultiWindowApp = null;
var reopened_window: ?*app.App = null;
var reopen_error: ?anyerror = null;
var reopen_peer_id: ?u64 = null;
fn reopenOnDestroy(window: *app.App) void {
    const application = reopen_application orelse return;
    if (reopen_peer_id) |id| {
        reopen_peer_id = null;
        if (!application.closeWindow(id)) reopen_error = error.DestroyPeerCloseRejected;
    }
    reopened_window = application.createWindowWith(.{ .io = window.cx.io }, smokeMount) catch |err| {
        reopen_error = err;
        return;
    };
}
fn reopenSmoke(allocator: std.mem.Allocator, io: std.Io) !void {
    var application = app.MultiWindowApp.init(allocator, .{ .pump_timeout_ms = 0 });
    defer application.deinit();
    reopen_application = &application;
    defer reopen_application = null;
    reopened_window = null;
    reopen_error = null;
    const peer = try application.createWindowWith(.{ .io = io }, smokeMount);
    const peer_id = peer.windowId();
    reopen_peer_id = peer_id;
    defer reopen_peer_id = null;
    const a = try application.createWindowWith(.{ .io = io, .on_destroy = reopenOnDestroy }, smokeMount);
    const old_id = a.windowId();
    if (!try application.tick()) return error.InitialTickStopped;
    try a.requestClose();
    // The last window is removed inside the real pump/tick, and its destroy
    // callback creates B. The loop must render B and continue receiving events.
    const close_start = std.Io.Clock.awake.now(io);
    while (application.window(old_id) != null or application.window(peer_id) != null or reopened_window == null) {
        if (close_start.durationTo(std.Io.Clock.awake.now(io)).toMilliseconds() >= 5000) return error.DestroyReplacementCloseTimeout;
        if (!try application.tick()) return error.DestroyReplacementTickStopped;
        std.Io.sleep(io, .fromMilliseconds(2), .awake) catch {};
        if (reopen_error) |err| return err;
    }
    if (reopen_error) |err| return err;
    const b = reopened_window orelse return error.DestroyReplacementMissing;
    if (application.windowCount() != 1 or application.window(old_id) != null) return error.DestroyReplacementRegistration;
    b.win.setSize(480, 280);
    for (0..3) |_| {
        b.cx.requestRedraw();
        if (!try application.tick()) return error.DestroyReplacementLaterTickStopped;
    }
    if (b.cx.display_list.items.items.len == 0) return error.DestroyReplacementNotRendered;
    application.quit();
    _ = try application.createWindowWith(.{ .io = io }, smokeMount);
    if (try application.tick()) return error.ExplicitQuitWithdrawn;
    std.log.info("chrome last-window on_destroy replacement: real tick rendering and explicit quit passed", .{});
}
var smoke_menu_seen: [4]app.MenuCommand = undefined;
var smoke_menu_count: usize = 0;
var smoke_menu_events: u32 = 0;
fn smokeMenuCommand(_: *app.MultiWindowApp, command: app.MenuCommand) bool {
    if (smoke_menu_count < smoke_menu_seen.len) smoke_menu_seen[smoke_menu_count] = command;
    smoke_menu_count += 1;
    // 901 is an application command; everything else goes to its window.
    return command.command_id == 901;
}
fn smokeObserveEvent(_: *app.MultiWindowApp, event: app.NativeEvent) void {
    if (event == .menu_command) smoke_menu_events += 1;
}
extern fn macos_menu_post_command_for_testing(window_id: u64, command_id: u64) void;
var smoke_hook_runs: u32 = 0;
fn smokeCountingHook(node: *ui.Node) void {
    smoke_hook_runs += 1;
    // Like a reveal countdown: ask for the next frame without changing the tree.
    node.markRenderDirty();
}
var smoke_task_runs: u32 = 0;
const SmokeTask = struct {
    const Result = @typeInfo(@TypeOf(ui.Task.runSlice)).@"fn".return_type.?;
    fn run(_: *ui.Task, _: *anyopaque, _: u32) Result {
        smoke_task_runs += 1;
        return .{ .step = .done };
    }
    fn deinit(_: *ui.Task, _: std.mem.Allocator) void {}
};
var smoke_acquire_faults: u32 = 0;
var smoke_acquire_always: u32 = 0;
fn smokeFailAcquireAlways(_: ?*anyopaque) bool {
    smoke_acquire_always += 1;
    return true;
}
fn smokeFailAcquireOnce(_: ?*anyopaque) bool {
    if (smoke_acquire_faults != 0) return false;
    smoke_acquire_faults += 1;
    return true;
}

fn multiSmoke(allocator: std.mem.Allocator, io: std.Io) !void {
    var application = app.MultiWindowApp.init(allocator, .{ .pump_timeout_ms = 0, .on_menu_command = smokeMenuCommand, .on_event = smokeObserveEvent });
    defer application.deinit();
    smoke_application = &application;
    defer smoke_application = null;
    destroyed_count = 0;
    const a = try application.createWindowWith(.{ .io = io, .window = .{ .width = 500, .height = 300, .chrome = .{ .custom = .{ .controls = .application } } }, .on_destroy = smokeDestroy, .on_close_request = smokeVeto, .on_key = smokeKeyFilter }, smokeMount);
    const b = try application.createWindowWith(.{ .io = io, .window = .{ .width = 420, .height = 280, .chrome = .{ .frameless = .{} } }, .on_destroy = smokeDestroy }, smokeMount);
    // An owned panel closes with its owner (b) and never outlives it natively.
    const panel = try application.createWindowWith(.{ .io = io, .window = .{ .width = 320, .height = 160, .chrome = .{ .frameless = .{} }, .owner = b.windowId(), .placement = .center_on_owner }, .on_destroy = smokeDestroy }, smokeMount);
    remount_cleanups = 0;
    try a.remount(remountRoot);
    try a.remount(remountRoot);
    if (remount_cleanups != 1) return error.RemountCleanupCount;
    if (findTestId(a.cx.root.?, "smoke.remounted") == null) return error.RemountRootMissing;
    if (a.remount(failedRemount)) |_| return error.FailedRemountAccepted else |err| if (err != error.SmokeMountFailure) return err;
    if (remount_cleanups != 3 or a.cx.root == null or a.cx.root_scope == null or a.cx.popover_portal_root == null) return error.RemountRollbackFailed;
    try a.remount(smokeMount);
    const a_id = a.windowId();
    const b_id = b.windowId();
    const panel_id = panel.windowId();
    if (panel.owner_window != b_id) return error.OwnerNotRecorded;
    if (application.createWindowWith(.{ .io = io, .window = .{ .owner = 0xdead } }, smokeMount)) |_| return error.UnknownOwnerAccepted else |err| if (err != error.UnknownOwnerWindow) return err;
    if ((try a.cx.windowChrome()) == (try b.cx.windowChrome())) return error.SharedChromeSignal;
    // Another thread wakes a pump that would otherwise block for 2 s. Only
    // Windows can hold its pump idle here (AppKit returns on any native event
    // in this smoke), and the Windows wake is the new path; macOS just calls it.
    if (comptime app.build_environment.os == .windows) {
        const Waker = struct {
            fn run(io_: std.Io) void {
                std.Io.sleep(io_, .fromMilliseconds(50), .awake) catch {};
                app.MultiWindowApp.wakeFromAnyThread();
            }
        };
        const waker = try std.Thread.spawn(.{}, Waker.run, .{io});
        const wake_start = std.Io.Clock.awake.now(io);
        _ = try application.pump(2000);
        const waited_ms = wake_start.durationTo(std.Io.Clock.awake.now(io)).toMilliseconds();
        waker.join();
        if (waited_ms >= 1000) {
            std.log.err("pump woke after {d} ms", .{waited_ms});
            return error.WakeFromAnyThreadIgnored;
        }
    } else app.MultiWindowApp.wakeFromAnyThread();
    // Runtime accessors shared by every platform.
    const logical = a.viewportLogicalSize();
    if (logical[0] != 500 or logical[1] != 300) return error.ViewportLogicalSize;
    if (comptime app.build_environment.os != .windows) {
        if (a.appRenderer() == null) return error.AppRendererMissing;
    } else _ = a.appRenderer();
    a.bindMenuCommand(4242, .{ .context = "smoke", .name = "noop" });
    if (a.chromeState().controls_owner != .application or b.chromeState().controls_owner != .none) return error.SharedChromePolicy;
    _ = try application.tick();
    if (comptime app.test_harness.enabled and app.build_environment.os != .linux) {
        a.rebindTestHarness();
        const recording = app.test_harness.startRecording("/tmp/zenit-phasea-owner.mp4", 30);
        if (!recording.ok or !recording.active) return error.RecordingStartFailed;
        b.rebindTestHarness();
        const rebound = app.test_harness.recordingStatus();
        if (!rebound.active or !std.mem.eql(u8, rebound.pathText(), recording.pathText())) return error.RecordingOwnerChanged;
        try b.frame();
        try a.frame();
        const stopped = app.test_harness.stopRecording();
        if (stopped.active or a.win.windowRecordingStatus().active != 0 or stopped.frame_count == 0) return error.RecordingStopWrongOwner;
        // Teardown must stop the owner even after another window takes the harness.
        a.rebindTestHarness();
        if (!app.test_harness.startRecording("/tmp/zenit-phasea-owner-close.mp4", 30).active) return error.RecordingRestartFailed;
        b.rebindTestHarness();
    }
    if (comptime app.build_environment.os == .macos) {
        // Process-level menu commands: one chosen with no key window (dropped
        // before on_menu_command existed) and one for window a, which the
        // handler declines so it still reaches the window. The observer sees
        // both before routing.
        smoke_menu_count = 0;
        smoke_menu_events = 0;
        macos_menu_post_command_for_testing(0, 901);
        macos_menu_post_command_for_testing(a.win.getWindowId(), 902);
        _ = try application.tick();
        if (smoke_menu_count != 2 or smoke_menu_events != 2) return error.MenuCommandNotOffered;
        if (smoke_menu_seen[0].command_id != 901 or smoke_menu_seen[0].window_id != 0) return error.ProcessMenuCommandLost;
        if (smoke_menu_seen[1].command_id != 902 or smoke_menu_seen[1].window_id != a.windowId()) return error.WindowMenuCommandMisrouted;

        // before_render hooks run once per rendered frame. Window `a` has a
        // custom header, whose region publication used to re-tick every hook
        // after the frame when a hook left the tree dirty.
        a.cx.root.?.addBeforeRender(smokeCountingHook);
        const hook_frames_before = a.renderer.frame_count;
        smoke_hook_runs = 0;
        var hook_ticks: u32 = 0;
        while (a.renderer.frame_count - hook_frames_before < 3 and hook_ticks < 300) : (hook_ticks += 1) {
            a.cx.needs_redraw = true;
            if (!try application.tick()) return error.HookTickEndedLoop;
            std.Io.sleep(io, .fromMilliseconds(2), .awake) catch {};
        }
        const hook_frames = a.renderer.frame_count - hook_frames_before;
        a.cx.root.?.removeBeforeRender(smokeCountingHook);
        if (hook_frames < 3 or smoke_hook_runs != hook_frames) {
            std.log.err("before_render ran {d} times over {d} rendered frames", .{ smoke_hook_runs, hook_frames });
            return error.HookRanOutsideFrame;
        }

        // Work scheduled on a window's Cx runs from the runtime's frame (the
        // macOS runtime never drained the deferred scheduler before).
        smoke_task_runs = 0;
        var task: ui.Task = .{
            .allocator = allocator,
            .key = .{ .int = 0x5307 },
            .priority = @fromBackingInt(@intCast(1)),
            .version = 1,
            .state_ptr = undefined,
            .vtable = &.{ .runSlice = SmokeTask.run, .deinit = SmokeTask.deinit },
        };
        _ = try a.cx.enqueueTask(&task);
        var task_ticks: u32 = 0;
        while (smoke_task_runs == 0 and task_ticks < 300) : (task_ticks += 1) {
            if (!try application.tick()) return error.DeferredTaskEndedLoop;
            std.Io.sleep(io, .fromMilliseconds(2), .awake) catch {};
        }
        if (smoke_task_runs != 1) return error.DeferredTaskNeverRan;

        // requestFrame renders on the very next frame() without a display
        // tick (an application's own harness commands rely on it). Back to
        // back frame() calls share one tick, so with macOS display-link pacing
        // a dirty window alone is held for the next tick; that control keeps
        // the check meaningful.
        {
            var settle: u32 = 0;
            const settle_from = a.renderer.frame_count;
            while (a.renderer.frame_count == settle_from and settle < 300) : (settle += 1) {
                a.cx.needs_redraw = true;
                if (!try application.tick()) return error.RequestFrameEndedLoop;
                std.Io.sleep(io, .fromMilliseconds(2), .awake) catch {};
            }
            // The poll fallback (ZENIT_FRAME_PACING=poll) has no tick gate.
            if (builtin.os.tag == .macos and a.config.frame_pacing == .display_link) {
                const held_from = a.renderer.frame_count;
                a.cx.needs_redraw = true;
                try application.frame();
                if (a.renderer.frame_count != held_from) return error.FrameWithoutDisplayTick;
            }
            const forced_from = a.renderer.frame_count;
            application.requestFrame(a.windowId());
            try application.frame();
            if (a.renderer.frame_count != forced_from + 1) return error.RequestFrameNotRendered;
        }

        // A drawable timeout skips one frame instead of ending the loop, and
        // the next tick repaints.
        smoke_acquire_faults = 0;
        a.setAcquireFaultHook(.{ .should_fail = smokeFailAcquireOnce });
        const frames_before = a.renderer.frame_count;
        // Frames follow the display cadence: tick (bounded) until the next
        // frame attempt reaches the hook.
        var attempts: u32 = 0;
        while (smoke_acquire_faults == 0 and attempts < 300) : (attempts += 1) {
            a.cx.needs_redraw = true;
            if (!try application.tick()) return error.AcquireTimeoutEndedLoop;
            std.Io.sleep(io, .fromMilliseconds(2), .awake) catch {};
        }
        if (smoke_acquire_faults != 1 or a.surface_timeouts != 1 or a.renderer.frame_count != frames_before) return error.AcquireFaultNotSkipped;
        attempts = 0;
        while (a.renderer.frame_count == frames_before and attempts < 300) : (attempts += 1) {
            if (!try application.tick()) return error.AcquireTimeoutEndedLoop;
            std.Io.sleep(io, .fromMilliseconds(2), .awake) catch {};
        }
        if (a.renderer.frame_count == frames_before) return error.AcquireTimeoutNoRepaint;

        // A drawable that stays unavailable is retried with backoff, not on
        // every tick (16, 32, 64, 128, 250 ms...).
        smoke_acquire_always = 0;
        a.setAcquireFaultHook(.{ .should_fail = smokeFailAcquireAlways });
        a.cx.needs_redraw = true;
        const spin_start = std.Io.Clock.awake.now(io);
        while (spin_start.durationTo(std.Io.Clock.awake.now(io)).toMilliseconds() < 400) {
            // Like a running animation: every pass asks for a frame again.
            a.cx.needs_redraw = true;
            if (!try application.tick()) return error.AcquireTimeoutEndedLoop;
            std.Io.sleep(io, .fromMilliseconds(1), .awake) catch {};
        }
        if (smoke_acquire_always == 0 or smoke_acquire_always > 10) {
            std.log.err("acquire retries in 400 ms: {d}", .{smoke_acquire_always});
            return error.AcquireRetrySpins;
        }
        a.setAcquireFaultHook(null);
    }
    // Application shortcuts see native keys before UI dispatch.
    const k_code: u16 = switch (app.build_environment.os) {
        .windows => 'K',
        .linux => 37, // evdev KEY_K
        else => 40, // macOS kVK_ANSI_K
    };
    const NativeEvent = @typeInfo(@TypeOf(app.App.processEvent)).@"fn".param_types[1].?;
    const command: @FieldType(@FieldType(NativeEvent, "key"), "modifiers") = if (app.build_environment.os == .macos) .{ .super = true } else .{ .ctrl = true };
    _ = a.processEvent(.{ .key = .{ .window_id = a.windowId(), .keycode = k_code, .pressed = true, .modifiers = command } });
    if (smoke_keys_seen != 1) return error.KeyPrefilterNotCalled;
    _ = a.processEvent(.{ .key = .{ .window_id = a.windowId(), .keycode = k_code, .pressed = true } });
    if (smoke_keys_seen != 2) return error.KeyPrefilterSkipped;
    try a.requestClose();
    _ = try application.tick();
    if (smoke_close_calls != 1 or application.windowCount() != 3 or application.window(a_id) == null) return error.CloseVetoFailed;
    try b.requestClose();
    _ = try application.tick();
    if (application.windowCount() != 1 or application.window(a_id) == null or application.window(b_id) != null) return error.CloseIsolationFailed;
    if (application.window(panel_id) != null) return error.OwnedWindowOutlivedOwner;
    if (destroyed_count != 2 or destroyed_ids[0] != panel_id or destroyed_ids[1] != b_id) return error.DestroyCascadeOrder;
    if (!application.closeWindow(a_id)) return error.SurvivorCleanupFailed;
    if (application.windowCount() != 0 or app.MultiWindowApp.nativeWindowCount() != 0) return error.NativeWindowLeak;
    if (comptime app.test_harness.enabled and app.build_environment.os != .linux) {
        if (app.test_harness.recordingStatus().active) return error.DestroyedRecordingOwnerActive;
    }
    if (destroyed_count != 3 or destroyed_ids[2] != a_id) return error.DestroyNotExactlyOnce;
    const remaining = try application.createWindowWith(.{ .io = io, .on_destroy = smokeDestroy }, smokeMount);
    const remaining_id = remaining.windowId();
    application.deinit();
    if (destroyed_count != 4 or destroyed_ids[3] != remaining_id) return error.DeinitDestroyNotExactlyOnce;
    const standalone = try app.App.init(allocator, .{ .io = io, .on_destroy = smokeDestroy });
    try standalone.mount(smokeMount);
    const standalone_id = standalone.windowId();
    standalone.deinit();
    if (destroyed_count != 5 or destroyed_ids[4] != standalone_id) return error.StandaloneDestroyNotExactlyOnce;
    try reopenSmoke(allocator, io);
    try sharedSmoke(allocator, io);
    if (app.MultiWindowApp.nativeWindowCount() != 0) return error.SharedNativeWindowLeak;
    std.log.info("chrome multi-window: independent state, reentrant veto, accepted close, owned panel cascade, survivor and native cleanup passed", .{});
}
// Real dispatch regression: callbacks must return before their window/owner is freed.
// Run separately with --lifetime-smoke or as part of the existing multi-window gate.
const LifetimeTrigger = enum { click, focus, key, cleanup };
const LifetimeState = struct {
    application: *app.MultiWindowApp,
    source: *app.App,
    close_id: u64,
    calls: u32 = 0,
    failure: ?anyerror = null,
};
var lifetime_state: ?*LifetimeState = null;
var lifetime_destroyed: [8]u64 = undefined;
var lifetime_destroy_count: usize = 0;
fn lifetimeDestroyed(window: *app.App) void {
    lifetime_destroyed[lifetime_destroy_count] = window.windowId();
    lifetime_destroy_count += 1;
}
fn lifetimeClose(_: *anyopaque) void {
    const state = lifetime_state.?;
    state.calls += 1;
    const source_id = state.source.windowId();
    if (!state.application.closeWindow(state.close_id)) {
        state.failure = error.CallbackCloseRejected;
        return;
    }
    // Check registration before touching the source again: the pre-fix runtime
    // destroys it synchronously here (and subsequently resumes its dispatch stack).
    if (state.application.window(source_id) == null or state.application.window(state.close_id) == null or lifetime_destroy_count != 0) {
        state.failure = error.WindowDestroyedInsideCallback;
        return;
    }
    state.source.cx.requestRedraw();
    if (state.application.pump(0)) |_| {
        state.failure = error.NestedPumpAccepted;
    } else |err| if (err != error.ReentrantWindowLoop) {
        state.failure = err;
    }
    if (state.application.frame()) |_| {
        state.failure = error.NestedFrameAccepted;
    } else |err| if (err != error.ReentrantWindowLoop) {
        state.failure = err;
    }
}
fn lifetimeCleanup(state: *LifetimeState) void {
    lifetimeClose(state);
}
fn lifetimeKey(_: ui.events.KeyCode, _: ui.events.Modifiers, context: ?*anyopaque) ui.events.EventResult {
    lifetimeClose(context.?);
    return .handled;
}
var duplicate_mount_calls: usize = 0;
fn duplicateMount(_: *ui.Cx, _: *ui.Scope) anyerror!*ui.Node {
    duplicate_mount_calls += 1;
    return error.DuplicateMountBuilderInvoked;
}
fn lifetimeRoot(cx: *ui.Cx, scope: *ui.Scope) anyerror!*ui.Node {
    return v.render(scope, cx, v.box(.{ .test_id = "lifetime.target", .style = .{ .width = .fill, .height = .fill } }, .{"Lifetime callback target"}));
}
fn lifetimeSmoke(allocator: std.mem.Allocator, io: std.Io) !void {
    for ([_]LifetimeTrigger{ .click, .focus, .key, .cleanup }) |trigger| {
        for ([_]bool{ false, true }) |close_owner| {
            var application = app.MultiWindowApp.init(allocator, .{ .pump_timeout_ms = 0 });
            defer application.deinit();
            lifetime_destroy_count = 0;
            const survivor = try application.createWindowWith(.{ .io = io }, lifetimeRoot);
            const original_root = survivor.cx.root;
            const original_scope = survivor.cx.root_scope;
            duplicate_mount_calls = 0;
            if (survivor.mount(duplicateMount)) |_| return error.DuplicateMountAccepted else |err| {
                if (err != error.AlreadyMounted) return err;
            }
            if (duplicate_mount_calls != 0 or survivor.cx.root != original_root or survivor.cx.root_scope != original_scope) return error.DuplicateMountChangedTree;
            const owner = try application.createWindowWith(.{ .io = io, .on_destroy = lifetimeDestroyed }, lifetimeRoot);
            const owner_id = owner.windowId();
            const source = if (close_owner) try application.createWindowWith(.{ .io = io, .window = .{ .owner = owner_id }, .on_destroy = lifetimeDestroyed }, lifetimeRoot) else owner;
            const source_id = source.windowId();
            for (0..3) |_| _ = try application.tick();
            const target = findTestId(source.cx.root.?, "lifetime.target") orelse return error.LifetimeTargetMissing;
            target.setFocusable(true);
            var state = LifetimeState{ .application = &application, .source = source, .close_id = owner_id };
            lifetime_state = &state;
            defer lifetime_state = null;
            switch (trigger) {
                .click => {
                    target.behavior.events.on_click = ui.Cx.simpleHandler(lifetimeClose, &state);
                    const rect = target.globalRect();
                    source.cx.handleMouseDown(rect.x + rect.w / 2, rect.y + rect.h / 2, .{});
                    source.cx.handleMouseUp(rect.x + rect.w / 2, rect.y + rect.h / 2);
                },
                .focus => {
                    target.behavior.events.on_focus = ui.Cx.simpleHandler(lifetimeClose, &state);
                    source.cx.setFocus(target);
                },
                .cleanup => {
                    const scope = try ui.Scope.init(allocator, source.cx.root_scope, source.cx.owner);
                    try scope.onCleanup(LifetimeState, &state, lifetimeCleanup);
                    scope.dispose();
                },
                .key => {
                    source.cx.setFocus(target);
                    target.behavior.events.on_key_down = lifetimeKey;
                    target.behavior.events.key_context = &state;
                    source.cx.handleKeyDown(.a, .{});
                },
            }
            if (state.failure) |err| return err;
            if (state.calls != 1) return error.LifetimeCallbackNotExactlyOnce;
            if (application.window(source_id) == null) return error.CloseCommittedBeforeHostBoundary;
            const survivor_frames = survivor.cx.frame_count;
            // AppKit finishes its native close asynchronously. Observe completion,
            // bounded by elapsed time, instead of assuming a fixed tick count.
            const close_start = std.Io.Clock.awake.now(io);
            while (application.window(owner_id) != null or application.window(source_id) != null or survivor.cx.frame_count <= survivor_frames) {
                if (close_start.durationTo(std.Io.Clock.awake.now(io)).toMilliseconds() >= 5000) return error.LifetimeCloseNotCommitted;
                survivor.cx.requestRedraw();
                if (!try application.tick()) return error.LifetimeSurvivorStopped;
                std.Io.sleep(io, .fromMilliseconds(2), .awake) catch {};
            }
            if (lifetime_destroy_count != @as(usize, if (close_owner) 2 else 1)) return error.LifetimeDestroyCount;
            if (lifetime_destroyed[0] != source_id or lifetime_destroyed[lifetime_destroy_count - 1] != owner_id) return error.LifetimeDestroyOrder;
            const survivor_target = findTestId(survivor.cx.root.?, "lifetime.target").?;
            survivor_target.setFocusable(true);
            survivor.cx.setFocus(survivor_target);
            survivor.cx.handleKeyDown(.a, .{});
            if (!survivor.cx.isFocused(survivor_target) or survivor.cx.frame_count <= survivor_frames) return error.LifetimeSurvivorUnusable;
            std.log.info("lifetime callback passed: trigger={s} close_owner={any}", .{ @tagName(trigger), close_owner });
        }
    }
    try reopenSmoke(allocator, io);
    if (app.MultiWindowApp.nativeWindowCount() != 0) return error.LifetimeNativeWindowLeak;
    std.log.info("lifetime smoke complete: eight direct dispatch/cleanup cases, nested loop rejection, child-first teardown, survivor focus/render and replacement passed", .{});
}
pub fn main(init: std.process.Init) !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);
    var config: @typeInfo(@TypeOf(app.App.init)).@"fn".param_types[1].? = .{ .io = init.io, .window = .{ .width = 900, .height = 600, .title = "Zenit Window Chrome", .chrome = .{ .custom = .{} } }, .on_close_request = closeRequest };
    var strict = false;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--lifetime-smoke")) return lifetimeSmoke(gpa.allocator(), init.io);
        if (std.mem.eql(u8, arg, "--multi-smoke")) {
            try multiSmoke(gpa.allocator(), init.io);
            return lifetimeSmoke(gpa.allocator(), init.io);
        }
        if (std.mem.eql(u8, arg, "--native")) config.window.chrome = .native else if (std.mem.eql(u8, arg, "--application-controls")) config.window.chrome = .{ .custom = .{ .controls = .application } } else if (std.mem.eql(u8, arg, "--frameless")) config.window.chrome = .{ .frameless = .{} } else if (std.mem.eql(u8, arg, "--strict")) strict = true else if (std.mem.eql(u8, arg, "--validation")) {
            if (comptime app.build_environment.os == .linux) config.require_gpu_validation = true;
        } else return error.InvalidArgument;
    }
    if (strict) switch (config.window.chrome.?) {
        .custom => |*c| c.unsupported = .fail,
        .frameless => |*c| c.unsupported = .fail,
        .native => {},
    };
    const window = try app.App.init(gpa.allocator(), config);
    defer window.deinit();
    if (comptime app.test_harness.enabled) {
        test_window = window;
        app.setTestRouteHandler(testRoute);
    }
    defer test_window = null;
    try window.runWith(mount);
}
