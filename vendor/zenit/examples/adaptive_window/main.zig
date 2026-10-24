//! Platform-adaptive title bar, based on Pencil m97vV.
const std = @import("std");
const ui = @import("ui");
const app = @import("zenit_app");
const v = ui.view;
const W = ui.widgets;
const S = @import("styles.zig");
const M = @import("model.zig");
const Header = @import("header.zig");
var window: ?*app.App = null;
var current: ?*Context = null;
var native_preference = false;
var rebuild = false;
const Context = struct {
    native_header_lease: ?*ui.Cx.HeaderRevealLease = null,
    cx: *ui.Cx,
    scope: *ui.Scope,
    chrome: *ui.Signal(app.window_chrome.State),
    menu_bar: *ui.Signal(bool),
    menu_open: *ui.Signal(bool),
    file_open: *ui.Signal(bool),
    status: *ui.Signal([]const u8),
    editor: *ui.Signal([]const u8),
    reveal: *ui.Signal(bool),
    project: *ui.Signal([]const u8),
    branch: *ui.Signal([]const u8),
    /// The gallery window owns the harness routes; "Try" windows do not.
    is_main: bool = true,
    timer: ?u64 = null,
    alt_pending: bool = false,
    fn command(c: *Context, id: []const u8) void {
        c.menu_bar.set(false);
        if (std.mem.eql(u8, id, "fullscreen")) {
            c.fullscreen();
            return;
        }
        if (std.mem.eql(u8, id, "minimize")) {
            c.cx.performWindowAction(.minimize) catch {};
            return;
        }
        if (std.mem.eql(u8, id, "maximize")) {
            c.cx.performWindowAction(.toggle_maximize) catch {};
            return;
        }
        if (std.mem.eql(u8, id, "close") or std.mem.eql(u8, id, "quit")) {
            c.cx.performWindowAction(.close) catch {};
            return;
        }
        if (std.mem.eql(u8, id, "new")) {
            c.editor.set("");
            c.status.set("新建文件");
            return;
        }
        if (std.mem.eql(u8, id, "copy")) {
            _ = ui.platform_services.clipboardSetText(c.cx.system_sdk, c.editor.peek());
            c.status.set("已复制编辑器内容");
            return;
        }
        if (std.mem.eql(u8, id, "insert-heading")) {
            c.editor.set("# Heading\n");
            c.status.set("已插入标题");
            return;
        }
        if (std.mem.eql(u8, id, "insert-code")) {
            c.editor.set("```zig\n\n```\n");
            c.status.set("已插入代码块");
            return;
        }
        // Project / branch chips (mock: no workspace behind them).
        if (std.mem.startsWith(u8, id, "project:")) {
            c.project.set(id["project:".len..]);
            c.statusFmt("已切换项目：{s}（演示）", .{id["project:".len..]});
            return;
        }
        if (std.mem.startsWith(u8, id, "branch:")) {
            c.branch.set(id["branch:".len..]);
            c.statusFmt("已检出分支：{s}（演示）", .{id["branch:".len..]});
            return;
        }
        if (std.mem.eql(u8, id, "project-open")) {
            c.status.set("打开项目…（演示：真实应用在这里弹系统文件选择器）");
            return;
        }
        if (std.mem.eql(u8, id, "project-new")) {
            c.status.set("新建项目…（演示）");
            return;
        }
        if (std.mem.eql(u8, id, "branch-new")) {
            c.status.set("新建分支…（演示）");
            return;
        }
        if (std.mem.eql(u8, id, "branch-sync")) {
            c.statusFmt("拉取 / 推送 {s}（演示）", .{c.branch.peek()});
            return;
        }
        const message = std.fmt.allocPrint(c.cx.allocator, "Example command: {s}", .{id}) catch return;
        defer c.cx.allocator.free(message);
        c.status.set(message);
    }
    fn statusFmt(c: *Context, comptime fmt: []const u8, args: anytype) void {
        const message = std.fmt.allocPrint(c.cx.allocator, fmt, args) catch return;
        defer c.cx.allocator.free(message);
        c.status.set(message);
    }
    fn fullscreen(c: *Context) void {
        c.cx.performWindowAction(.{ .fullscreen = !c.chrome.peek().fullscreen }) catch {};
    }
    fn maximize(c: *Context) void {
        c.cx.performWindowAction(.toggle_maximize) catch {};
    }
    fn preference(_: *Context) void {
        native_preference = !native_preference;
        rebuild = true;
        if (window) |w| w.requestClose() catch {};
    }
    fn enter(c: *Context) void {
        if (app.build_environment.os == .macos or !c.chrome.peek().fullscreen) return;
        if (c.timer) |id| c.cx.clearTimer(id);
        c.timer = c.cx.setTimer(300 * std.time.ns_per_ms, show, c) catch null;
    }
    fn leave(c: *Context) void {
        if (app.build_environment.os == .macos or !c.chrome.peek().fullscreen) return;
        if (c.timer) |id| c.cx.clearTimer(id);
        c.timer = c.cx.setTimer(600 * std.time.ns_per_ms, hide, c) catch null;
    }
    fn show(raw: ?*anyopaque) void {
        const c: *Context = @ptrCast(@alignCast(raw.?));
        c.timer = null;
        c.reveal.set(true);
    }
    fn hide(raw: ?*anyopaque) void {
        const c: *Context = @ptrCast(@alignCast(raw.?));
        c.timer = null;
        c.reveal.set(false);
    }
    fn cleanup(c: *Context) void {
        if (c.timer) |id| c.cx.clearTimer(id);
        if (c.is_main) current = null;
    }
    fn closeWindow(c: *Context) void {
        c.cx.performWindowAction(.close) catch {};
    }
    fn event(ev: ui.events.Event, raw: ?*anyopaque) ui.events.EventResult {
        const c: *Context = @ptrCast(@alignCast(raw.?));
        switch (ev) {
            .key_down => |key| {
                if (app.build_environment.os != .macos) {
                    if (key.key == .left_alt or key.key == .right_alt) {
                        c.alt_pending = true;
                        return .ignored;
                    }
                    if (key.modifiers.alt and key.key == .f) {
                        c.alt_pending = false;
                        c.menu_bar.set(true);
                        c.file_open.set(true);
                        return .stop;
                    }
                    c.alt_pending = false;
                }
                if (key.key == .f11) {
                    c.fullscreen();
                    return .stop;
                }
                if (key.key == .escape) {
                    c.menu_bar.set(false);
                    c.menu_open.set(false);
                    c.alt_pending = false;
                }
                if (key.key == .f10 and app.build_environment.os != .macos) {
                    c.menu_bar.set(!c.menu_bar.peek());
                    return .stop;
                }
            },
            .key_up => |key| {
                if ((key.key == .left_alt or key.key == .right_alt) and c.alt_pending) {
                    c.alt_pending = false;
                    c.menu_bar.set(!c.menu_bar.peek());
                    return .stop;
                }
            },
            .mouse_down => {
                c.alt_pending = false;
            },
            else => {},
        }
        return .ignored;
    }
};
fn route(path: []const u8, _: []const u8, out: []u8) ?[]const u8 {
    const c = current orelse return null;
    if (comptime app.build_environment.os == .macos) {
        if (std.mem.eql(u8, path, "/native-header-ready")) {
            const w = window orelse return null;
            return if (w.headerReadyForTesting()) "{\"ok\":true}" else "{\"ok\":false}";
        }
        if (std.mem.eql(u8, path, "/native-header-hover-edge") or std.mem.eql(u8, path, "/native-header-hover-body")) {
            const w = window orelse return null;
            w.postHeaderSystemHoverForTesting(std.mem.eql(u8, path, "/native-header-hover-edge")) catch return "{\"ok\":false}";
            return "{\"ok\":true}";
        }
        if (std.mem.eql(u8, path, "/native-header-lock")) {
            if (c.native_header_lease == null) c.native_header_lease = c.cx.acquireWindowHeaderReveal(c.scope) catch return "{\"ok\":false}";
            return "{\"ok\":true}";
        }
        if (std.mem.eql(u8, path, "/native-header-unlock")) {
            if (c.native_header_lease) |lease| lease.release();
            c.native_header_lease = null;
            return "{\"ok\":true}";
        }
        if (std.mem.eql(u8, path, "/native-activate")) {
            if (window) |w| w.win.activate();
            return "{\"ok\":true}";
        }
        if (std.mem.eql(u8, path, "/native-header-more")) {
            const w = window orelse return null;
            w.postHeaderPointerForTesting(c.chrome.peek().width - 42, 19, false) catch return "{\"ok\":false}";
            return "{\"ok\":true}";
        }
        if (std.mem.eql(u8, path, "/native-header-green")) {
            const w = window orelse return null;
            const s = c.chrome.peek();
            if (!s.controls_geometry_known or s.native_controls_count != 3) return "{\"ok\":false}";
            const r = s.native_controls[2];
            w.postHeaderPointerForTesting(r.x + r.w / 2, r.y + r.h / 2, false) catch return "{\"ok\":false}";
            return "{\"ok\":true}";
        }
    }
    if (std.mem.eql(u8, path, "/window-state")) {
        const s = c.chrome.peek();
        var writer = std.Io.Writer.fixed(out);
        std.json.Stringify.value(.{ .appearance = @tagName(s.appearance), .effective = @tagName(s.effective_mode), .owner = @tagName(s.controls_owner), .fallback = @tagName(s.fallback_reason), .maximized = s.maximized, .fullscreen = s.fullscreen, .fullscreen_transitioning = s.fullscreen_transitioning, .active = s.active, .tiled = s.tiled, .width = s.width, .height = s.height, .render_size = if (window) |w| w.win.getSize() else [2]u32{ 0, 0 }, .drawable_size = if (window) |w| w.win.getDrawableSize() else [2]u32{ 0, 0 }, .render_scale = if (window) |w| w.win.getScaleFactor() else 1.0, .layout = s.button_layout, .menu = c.menu_bar.peek(), .revealed = c.reveal.peek(), .header_hosted = s.fullscreen_header_hosted, .header_visible = s.fullscreen_header_visible, .header_presented = s.fullscreen_header_presented, .header_offset = c.cx.window_header_offset, .status = c.status.peek(), .windows = app.MultiWindowApp.nativeWindowCount() }, .{}, &writer) catch return null;
        return writer.buffered();
    }
    return null;
}
/// Horizontal space the content column and gallery take from the window width.
const gallery_inset: f32 = 2 * 20 + 2 * 10;
const Responsive = struct {
    state: *ui.Signal(app.window_chrome.State),
    fn resized(r: *Responsive, chrome: app.window_chrome.State, _: app.window_chrome.State) void {
        var s = r.state.peek();
        const width = @max(320, chrome.width - gallery_inset);
        if (s.width == width) return;
        s.width = width;
        r.state.set(s);
    }
};
/// `fixed` null: the preview fills the gallery width and its chrome state follows
/// the real window width, so the Header re-flows like the real one would.
fn preview(p: M.Preset, fixed: ?f32, scope: *ui.Scope, cx: *ui.Cx) !*ui.Node {
    const live = current.?.chrome;
    const width = fixed orelse @max(320, live.peek().width - gallery_inset);
    const state = try scope.createSignal(app.window_chrome.State, M.state(p, width));
    if (fixed == null) {
        const responsive = try scope.createState(Responsive, .{ .state = state });
        try scope.watch(live, responsive, Responsive.resized);
    }
    const menu_bar = try scope.createSignal(bool, false);
    const menu_open = try scope.createSignal(bool, false);
    const ids = try scope.createState([6][]const u8, undefined);
    for ([_][]const u8{ "header", "drag", "minimize", "maximize", "close", "try" }, 0..) |suffix, i| {
        ids[i] = try std.fmt.allocPrint(cx.allocator, "preview.{s}.{s}", .{ p.id, suffix });
        const text = try scope.createText(ids[i], .{});
        cx.allocator.free(ids[i]);
        ids[i] = text.peek();
    }
    const header = try Header.mount(.{ .state = state, .preview = true, .radius = p.radius, .menu_bar = menu_bar, .menu_open = menu_open, .on_command = cx.on(Context, current.?, Context.command), .test_id = ids[0], .drag_id = ids[1], .control_ids = .{ ids[2], ids[3], ids[4] } }, scope, cx);
    // "Try" opens a real window configured like this preset; only presets that
    // match the running desktop can be opened, the rest are disabled and say why.
    const trial = try scope.createState(Trial, .{ .preset = p });
    const unavailable = if (M.fits(p)) null else try v.render(scope, cx, v.text(.{ .style = S.note }, M.fitsNote(p)));
    return v.render(scope, cx, v.col(.{ .style = if (fixed) |w| ui.BoxStyle{ .width = .{ .px = w }, .gap = 8 } else ui.BoxStyle{ .width = ui.Sizing.fill(), .gap = 8 } }, .{
        v.row(.{ .style = S.label_row }, .{
            v.text(.{ .style = S.row_label }, p.label),
            v.text(.{ .style = S.note }, p.note),
            v.attrs(.{ .test_id = ids[5] }, W.Button(.{ .label = "Try", .size = .sm, .variant = .secondary, .disabled = !M.fits(p), .on_click = cx.on(Trial, trial, Trial.open) })),
            unavailable,
        }),
        if (p.native) try v.render(scope, cx, v.row(.{ .style = S.native_title }, .{ v.text(.{ .style = S.note }, "System title bar"), v.text(.{ .style = S.note }, "—  □  ×") })) else null,
        header,
    }));
}
fn mount(cx: *ui.Cx, scope: *ui.Scope) anyerror!*ui.Node {
    cx.setTheme(&ui.theme.light);
    const c = try scope.createState(Context, .{ .cx = cx, .scope = scope, .chrome = try cx.windowChrome(), .menu_bar = try scope.createSignal(bool, false), .menu_open = try scope.createSignal(bool, false), .file_open = try scope.createSignal(bool, false), .status = try scope.createText("Ready · F11 fullscreen / F10 menu", .{}), .editor = try scope.createText("# Window Header\n\nOne application header, adapted to the host desktop.\n\n中文输入与选择也可以在这里验收。", .{}), .reveal = try scope.createSignal(bool, false), .project = try scope.createText("markdown-editor", .{}), .branch = try scope.createText("main", .{}) });
    current = c;
    try scope.onCleanup(Context, c, Context.cleanup);
    const header = try Header.mount(.{ .state = c.chrome, .menu_bar = c.menu_bar, .menu_open = c.menu_open, .file_open = c.file_open, .project = c.project, .branch = c.branch, .on_command = cx.on(Context, c, Context.command) }, scope, cx);
    const gallery = try v.render(scope, cx, v.col(.{ .style = S.gallery }, .{}));
    for (M.presets) |p| try gallery.appendChild(cx.allocator, try preview(p, null, scope, cx));
    for ([_]f32{ 720, 640, 520 }, 0..) |width, i| {
        var p = M.presets[1];
        p.id = ([_][]const u8{ "narrow720", "narrow640", "narrow520" })[i];
        p.label = ([_][:0]const u8{ "720px · 完整 Header", "640px · 分支仅图标", "520px · 操作折叠" })[i];
        p.note = "拖拽区至少 160px";
        try gallery.appendChild(cx.allocator, try preview(p, width, scope, cx));
    }
    const body = try v.render(scope, cx, v.with(W.ScrollArea(.{ .direction = .both }), v.col(.{ .style = S.content }, .{
        v.text(.{ .style = S.title }, "Adaptive Window · 跨平台窗口适配"),
        v.text(.{ .style = S.note }, "m97vV · 38px 共用 Header · 预览按钮只改变预览，顶部 Header 控制真实窗口 · 每个预设的 Try 会真的打开一个该配置的窗口（仅限当前系统支持的款）。"),
        v.row(.{ .style = S.controls_row }, .{
            v.attrs(.{ .test_id = "window.maximize" }, W.Button(.{ .label = "最大化 / 还原", .on_click = cx.on(Context, c, Context.maximize) })),
            v.attrs(.{ .test_id = "window.fullscreen" }, W.Button(.{ .label = "全屏 / 退出", .on_click = cx.on(Context, c, Context.fullscreen) })),
            if (app.build_environment.os != .macos) v.attrs(.{ .test_id = "window.preference" }, W.Button(.{ .label = if (native_preference) "切换自定义标题栏" else "切换系统标题栏", .on_click = cx.on(Context, c, Context.preference) })) else W.Button(.{ .label = "macOS 使用系统红绿灯", .disabled = true }),
        }),
        v.text(.{ .test_id = "window.state", .style = S.note }, v.fmt("effective={any} · owner={any} · fallback={any}", .{ ui.field(c.chrome, .effective_mode), ui.field(c.chrome, .controls_owner), ui.field(c.chrome, .fallback_reason) })),
        v.attrs(.{ .test_id = "window.editor" }, W.Textarea(.{ .value = c.editor, .rows = 4, .width = 680 })),
        v.text(.{ .test_id = "window.status", .style = S.note }, c.status),
        gallery,
    })));
    return assemble(c, cx, scope, header, body);
}
/// Root shared by the gallery window and every "Try" window: Header overlay,
/// fullscreen reveal edge, keyboard capture and menu actions.
fn assemble(c: *Context, cx: *ui.Cx, scope: *ui.Scope, header: *ui.Node, body: *ui.Node) !*ui.Node {
    const visible = try scope.createMemo(bool, c, struct {
        fn read(ctx: *Context) bool {
            return !ctx.chrome.get().fullscreen or ctx.chrome.get().fullscreen_header_hosted or (app.build_environment.os != .macos and ctx.reveal.get());
        }
    }.read);
    const spacer = try scope.createMemo(f32, c.chrome, struct {
        fn read(s: *ui.Signal(app.window_chrome.State)) f32 {
            return if (s.get().fullscreen and !s.get().fullscreen_header_hosted) 0 else 38;
        }
    }.read);
    const root = try v.render(scope, cx, v.col(.{ .style = S.root }, .{
        v.box(.{ .style = v.styleBy(spacer, S.headerSpacer) }, .{}),
        v.box(.{ .test_id = "window.fullscreen.edge", .style = .{ .position = .absolute, .inset = .{ .top = .{ .px = 0 }, .left = .{ .px = 0 } }, .z_index = 30, .width = .fill, .height = 2 }, .on_hover = cx.on(Context, c, Context.enter) }, .{}),
        v.box(.{ .visible = visible, .on_hover = cx.on(Context, c, Context.enter), .on_leave = cx.on(Context, c, Context.leave), .style = .{ .position = .absolute, .inset = .{ .top = .{ .px = 0 }, .left = .{ .px = 0 } }, .z_index = 20, .width = .fill, .height = 38 } }, .{header}),
        body,
    }));
    root.behavior.events.on_event_capture = Context.event;
    root.behavior.events.capture_context = c;
    root.behavior.interaction.key_context = "window";
    root.behavior.events.on_action = struct {
        fn action(a: ui.actions.Action, raw: ?*anyopaque) ui.events.EventResult {
            const ctx: *Context = @ptrCast(@alignCast(raw.?));
            ctx.command(a.name);
            return .stop;
        }
    }.action;
    root.behavior.events.action_context = c;
    return root;
}
/// Chrome state of a "Try" window: the real window's state with the preset's
/// caption appearance and button layout. The host desktop always reports its
/// own (on Fedora: Adwaita, appmenu:close), so without this every Linux preset
/// opened the same window. Only application-drawn controls take the preset;
/// native controls (macOS, system title bar) stay as the platform draws them.
const PresetChrome = struct {
    preset: M.Preset,
    state: *ui.Signal(app.window_chrome.State),
    fn apply(p: M.Preset, host: app.window_chrome.State) app.window_chrome.State {
        var s = host;
        if (s.controls_owner == .application) {
            s.appearance = p.appearance;
            s.button_layout = p.layout;
        }
        return s;
    }
    fn changed(self: *PresetChrome, host: app.window_chrome.State, _: app.window_chrome.State) void {
        const next = apply(self.preset, host);
        if (!std.meta.eql(next, self.state.peek())) self.state.set(next);
    }
};
/// Content of a window opened from a preset's "Try" button.
fn mountTry(cx: *ui.Cx, scope: *ui.Scope) anyerror!*ui.Node {
    cx.setTheme(&ui.theme.light);
    const p = try_preset orelse return error.NoPreset;
    const host = try cx.windowChrome();
    const chrome = try scope.createSignal(app.window_chrome.State, PresetChrome.apply(p, host.peek()));
    try scope.watch(host, try scope.createState(PresetChrome, .{ .preset = p, .state = chrome }), PresetChrome.changed);
    const c = try scope.createState(Context, .{ .cx = cx, .scope = scope, .chrome = chrome, .menu_bar = try scope.createSignal(bool, false), .menu_open = try scope.createSignal(bool, false), .file_open = try scope.createSignal(bool, false), .status = try scope.createText("真实窗口 · 按钮外观与布局取自预设，窗口外形与阴影由当前桌面决定", .{}), .editor = try scope.createText("# Try\n\n这是按预设真实创建的窗口：拖拽、双击、最小化/最大化、全屏都走真实的窗口系统。", .{}), .reveal = try scope.createSignal(bool, false), .project = try scope.createText("markdown-editor", .{}), .branch = try scope.createText("main", .{}), .is_main = false });
    try scope.onCleanup(Context, c, Context.cleanup);
    const header = try Header.mount(.{ .state = c.chrome, .menu_bar = c.menu_bar, .menu_open = c.menu_open, .file_open = c.file_open, .project = c.project, .branch = c.branch, .on_command = cx.on(Context, c, Context.command), .test_id = "try.header", .drag_id = "try.drag", .control_ids = .{ "try.controls.minimize", "try.controls.maximize", "try.controls.close" } }, scope, cx);
    const body = try v.render(scope, cx, v.with(W.ScrollArea(.{ .direction = .both }), v.col(.{ .style = S.content }, .{
        v.text(.{ .style = S.title }, p.label),
        v.text(.{ .style = S.note }, p.note),
        v.row(.{ .style = S.controls_row }, .{
            W.Button(.{ .label = "最大化 / 还原", .on_click = cx.on(Context, c, Context.maximize) }),
            W.Button(.{ .label = "全屏 / 退出", .on_click = cx.on(Context, c, Context.fullscreen) }),
            v.attrs(.{ .test_id = "try.close" }, W.Button(.{ .label = "关闭窗口", .variant = .secondary, .on_click = cx.on(Context, c, Context.closeWindow) })),
        }),
        v.text(.{ .style = S.note }, v.fmt("effective={any} · owner={any} · fallback={any} · appearance={any}", .{ ui.field(c.chrome, .effective_mode), ui.field(c.chrome, .controls_owner), ui.field(c.chrome, .fallback_reason), ui.field(c.chrome, .appearance) })),
        W.Textarea(.{ .value = c.editor, .rows = 4, .width = 680 }),
        v.text(.{ .style = S.note }, c.status),
    })));
    return assemble(c, cx, scope, header, body);
}
/// A preset's "Try" button. Windows are created at the loop boundary, never
/// inside the click dispatch of another window.
const Trial = struct {
    preset: M.Preset,
    fn open(t: *Trial) void {
        if (M.fits(t.preset)) pending_try = t.preset;
    }
};
var pending_try: ?M.Preset = null;
var try_preset: ?M.Preset = null;
fn tryWindowConfig(p: M.Preset, header_policy: app.window_chrome.HeaderVisibility) app.WindowConfig {
    // A native titlebar has no hosted fullscreen Header; requesting one is rejected.
    return .{ .width = 1100, .height = 720, .min_width = 480, .min_height = 320, .title = p.label, .titlebar_height = 38, .fullscreen_header = if (p.native) .hidden else header_policy, .chrome = if (p.native) .native else .{ .custom = .{ .controls = if (app.build_environment.os == .macos) .automatic else .application } } };
}
pub fn main(init: std.process.Init) !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var header_policy: app.window_chrome.HeaderVisibility = .hidden;
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--native")) native_preference = true else if (std.mem.eql(u8, arg, "--header-autohide")) header_policy = .autohide else if (std.mem.eql(u8, arg, "--header-pinned")) header_policy = .pinned else return error.InvalidArgument;
    }
    while (true) {
        rebuild = false;
        var application = app.MultiWindowApp.init(gpa.allocator(), .{});
        defer application.deinit();
        const w = try application.createWindowWith(.{ .io = init.io, .window = .{ .width = 1500, .height = 1040, .min_width = 480, .min_height = 320, .title = "Adaptive Window — Zenit", .titlebar_height = 38, .fullscreen_header = header_policy, .chrome = if (native_preference) .native else .{ .custom = .{ .controls = if (app.build_environment.os == .macos) .automatic else .application } } } }, mount);
        window = w;
        if (comptime app.test_harness.enabled) app.setTestRouteHandler(route);
        defer window = null;
        while (try application.tick()) {
            const p = pending_try orelse continue;
            pending_try = null;
            try_preset = p;
            const child = application.createWindowWith(.{ .io = init.io, .window = tryWindowConfig(p, header_policy) }, mountTry) catch |err| {
                std.log.err("Try window for preset {s} failed: {s}", .{ p.id, @errorName(err) });
                continue;
            };
            if (p.maximized) child.setMaximized(true) catch {};
            _ = application.activateWindow(child.windowId());
        }
        if (!rebuild) break;
    }
}
