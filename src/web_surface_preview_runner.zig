//! Isolated Zenit/WebKit content-slot acceptance fixture. The caller supplies
//! an HTTP(S) test URL. No ZeroWork application data or transport is loaded.
const std = @import("std");
const ui = @import("ui");
const zenit = @import("zenit_app");
const App = zenit.App;
const web = @import("host/web_surface.zig");
const identity = @import("host/identity.zig");
const theme = @import("ui/app_theme.zig");

const owner: identity.SessionHandle = .{ .session_id = @fromBackingInt(60) };
var app: *App = undefined;
var target: []const u8 = "";
var active_fixture: ?*Fixture = null;

const Fixture = struct {
    cx: *ui.Cx,
    sidebar: *ui.Node,
    slot: *ui.Node,
    cover: *ui.Signal(bool),
    address: *ui.Node = undefined,
    surface: web.Surface,
    binding: ?web.Mount = null,
    showing_web: bool = true,
    started: bool = false,
    last_slot: ?ui.ComputedRect = null,

    fn cleanup(self: *Fixture) void {
        self.cx.removeAfterLayoutHook(self);
        self.surface.deinit();
        active_fixture = null;
    }

    fn frame(raw: *anyopaque, _: u8, _: bool) ui.AfterLayoutResult {
        const self: *Fixture = @ptrCast(@alignCast(raw));
        self.sync() catch |err| std.log.err("web fixture: {s}", .{@errorName(err)});
        return .done;
    }

    fn sync(self: *Fixture) !void {
        if (!self.showing_web) {
            if (self.binding) |binding| {
                try self.surface.unbind(binding);
                self.binding = null;
            }
            return;
        }
        const rect = self.slot.globalRect();
        if (rect.w <= 0 or rect.h <= 0) return;
        if (self.binding == null) self.binding = try self.surface.bind(owner, app.windowId());
        try self.surface.sync(self.binding.?, app, .{
            .slot = rect,
            .clip = rect,
            .visible = !self.cover.peek(),
            .host_key = hostKey,
        });
        if (self.last_slot == null or !std.meta.eql(self.last_slot.?, rect)) {
            self.last_slot = rect;
            std.log.info("web slot x={d:.0} y={d:.0} w={d:.0} h={d:.0} scale={d:.2}", .{ rect.x, rect.y, rect.w, rect.h, app.scale });
        }
        if (!self.started and !self.cover.peek()) {
            try self.surface.navigate(target);
            self.started = true;
        }
    }

    fn webTab(self: *Fixture) void {
        self.showing_web = true;
        self.cx.requestRedraw();
    }

    fn otherTab(self: *Fixture) void {
        self.showing_web = false;
        self.cx.requestRedraw();
    }

    fn toggleSidebar(self: *Fixture) void {
        self.sidebar.setDisplay(if (self.sidebar.isDisplayedInTree()) .none else .flex);
        self.cx.requestRedraw();
    }

    fn toggleCover(self: *Fixture) void {
        self.cover.set(!self.cover.peek());
        self.cx.requestRedraw();
    }

    fn navigate(self: *Fixture, url: []const u8) void {
        self.surface.navigate(url) catch |err| std.log.err("web fixture navigate: {s}", .{@errorName(err)});
    }

    fn back(self: *Fixture) void {
        _ = self.surface.goBack() catch false;
    }

    fn forward(self: *Fixture) void {
        _ = self.surface.goForward() catch false;
    }

    fn reload(self: *Fixture) void {
        const state = self.surface.snapshot() catch return;
        if (state.loading) {
            self.surface.stop() catch {};
        } else {
            _ = self.surface.reload() catch false;
        }
    }

    fn quit(_: *Fixture) void {
        app.quit();
    }
};

fn hostKey(_: ?*anyopaque, keycode: u16, modifiers: u32) callconv(.c) c_int {
    const command: u32 = 1 << 20;
    const key_l: u16 = 37;
    return @intFromBool((modifiers & command) != 0 and keycode == key_l);
}

fn onKey(_: *App, event: zenit.KeyEvent) bool {
    const self = active_fixture orelse return false;
    if (event.pressed and event.modifiers.super and event.key == .l) {
        if (self.binding) |binding| self.surface.releaseFocus(binding) catch {};
        self.cx.setFocus(self.address);
        return true;
    }
    return false;
}

fn mount(cx: *ui.Cx, scope: *ui.Scope) !*ui.Node {
    theme.selectTokens(@import("config/theme_registry.zig").builtinTokens("reference-light"));
    _ = theme.setMaterialParameters(0, 0);
    cx.setTheme(theme.widgetTheme(theme.currentName()));
    const colors = theme.current();
    const root = try ui.box(cx, .{
        .width = .fill(),
        .height = .fill(),
        .direction = .column,
        .background = theme.baseColors().app,
        .padding = .{ .top = 32, .right = 12, .bottom = 12, .left = 12 },
        .gap = 8,
    }, .{});
    const tabs = try ui.box(cx, .{ .width = .fill(), .height = .{ .px = 30 }, .direction = .row, .gap = 6 }, .{});
    try root.appendChild(cx.allocator, tabs);

    const body = try ui.box(cx, .{ .width = .fill(), .height = .fill(), .direction = .row, .gap = 24 }, .{});
    try root.appendChild(cx.allocator, body);
    const sidebar = try ui.box(cx, .{
        .width = .{ .px = 238 },
        .height = .fill(),
        .flex_shrink = 0,
        .background = colors.surface_2,
        .padding = ui.Padding.all(16),
        .border = .{ .width = 1, .radius = 12, .color = colors.border },
    }, .{});
    try sidebar.appendChild(cx.allocator, try ui.text(cx, "主机与连接", .{ .font_size = 13, .color = colors.fg_1 }));
    try body.appendChild(cx.allocator, sidebar);

    const workspace = try ui.box(cx, .{ .width = .fill(), .height = .fill(), .direction = .column, .gap = 12 }, .{});
    try body.appendChild(cx.allocator, workspace);
    const toolbar = try ui.box(cx, .{
        .width = .fill(),
        .height = .{ .px = 44 },
        .direction = .row,
        .gap = 6,
        .flex_shrink = 0,
        .align_items = .center,
        .background = colors.surface_2,
        .padding = .{ .left = 8, .right = 8 },
        .border = .{ .width = 1, .radius = 12, .color = colors.border },
    }, .{});
    toolbar.meta.ownership.meta.test_id = "web.toolbar";
    try workspace.appendChild(cx.allocator, toolbar);
    const slot = try ui.box(cx, .{ .width = .fill(), .height = .fill(), .background = colors.surface_2, .padding = ui.Padding.all(20) }, .{});
    slot.meta.ownership.meta.test_id = "web.document";
    try workspace.appendChild(cx.allocator, slot);
    const cover = try scope.createSignal(bool, false);
    const modal = try ui.widgets.Modal(.{
        .open = cover,
        .title = "偏好设置",
        .width = @as(f32, 300),
        .enter_transition = .none,
        .exit_transition = .none,
    }).mount(scope, cx);
    if (!modal.portaled) try root.appendChild(cx.allocator, modal.overlay);
    modal.dialog.meta.ownership.meta.test_id = "web.fixture.cover";

    var surface = try web.Surface.init(owner);
    const self = scope.createState(Fixture, .{ .cx = cx, .sidebar = sidebar, .slot = slot, .cover = cover, .surface = surface }) catch |err| {
        surface.deinit();
        return err;
    };
    scope.onCleanup(Fixture, self, Fixture.cleanup) catch |err| {
        self.surface.deinit();
        return err;
    };
    try button(cx, scope, tabs, self, "生产监控", "web.fixture.tab.web", Fixture.webTab);
    try button(cx, scope, tabs, self, "其他页签", "web.fixture.tab.other", Fixture.otherTab);
    try button(cx, scope, tabs, self, "侧栏", "web.fixture.sidebar", Fixture.toggleSidebar);
    try button(cx, scope, tabs, self, "偏好设置", "web.fixture.preferences", Fixture.toggleCover);
    try button(cx, scope, tabs, self, "关闭", "web.fixture.close", Fixture.quit);
    try button(cx, scope, modal.body, self, "完成", "web.fixture.cover.done", Fixture.toggleCover);
    try button(cx, scope, toolbar, self, "←", "web.back", Fixture.back);
    try button(cx, scope, toolbar, self, "→", "web.forward", Fixture.forward);
    try button(cx, scope, toolbar, self, "↻", "web.reload", Fixture.reload);
    const input = try ui.widgets.Input(.{
        .value = try scope.createText(target, .{}),
        .placeholder = "输入网址",
        .on_submit = cx.on(Fixture, self, Fixture.navigate),
    }).mountResult(scope, cx);
    input.input_container.meta.ownership.meta.test_id = "web.address";
    try toolbar.appendChild(cx.allocator, input.node);
    self.address = input.input_container;
    try cx.addAfterLayoutHook(self, Fixture.frame);
    active_fixture = self;
    return root;
}

fn button(cx: *ui.Cx, scope: *ui.Scope, parent: *ui.Node, fixture: *Fixture, label: []const u8, id: []const u8, comptime action: *const fn (*Fixture) void) !void {
    const node = try ui.widgets.Button(.{ .label = label, .on_click = cx.on(Fixture, fixture, action), .variant = .ghost }).mount(scope, cx);
    node.meta.ownership.meta.test_id = id;
    try parent.appendChild(cx.allocator, node);
}

pub fn main(init: std.process.Init) !void {
    var args = init.minimal.args.iterate();
    _ = args.next();
    target = args.next() orelse return error.WebFixtureURLRequired;
    app = try App.init(std.heap.c_allocator, .{
        .io = init.io,
        .on_key = onKey,
        .window = .{
            .width = 1440,
            .height = 900,
            .min_width = 660,
            .min_height = 450,
            .title = "ZeroWork · Web Surface Preview",
            .titlebar = .custom_inset,
            .titlebar_height = 30,
        },
    });
    defer app.deinit();
    try app.runWith(mount);
}
