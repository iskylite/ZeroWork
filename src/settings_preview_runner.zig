//! Explicit component acceptance runner. Reuses the production settings page;
//! selecting a planning projection here creates no plugin job or permission.
const std = @import("std");
const ui = @import("ui");
const App = @import("zenit_app").App;
const Controller = @import("config/settings_controller.zig").Controller;
const plugins = @import("config/plugin_page.zig");
const view = @import("config/settings_content_view.zig");
const theme = @import("ui/app_theme.zig");

const Options = struct { preview_kind: plugins.PreviewKind, selected_theme: theme.Name = .sauber };
var options: Options = undefined;

const Preview = struct {
    cx: *ui.Cx,
    scope: *ui.Scope,
    root: *ui.Node,
    controller: Controller,
    content_scope: ?*ui.Scope = null,
    pending_rebuild: bool = false,

    fn cleanup(self: *Preview) void {
        // Parent teardown already disposed all child scopes.
        self.content_scope = null;
        self.cx.removeAfterLayoutHook(self);
        self.controller.deinit();
        self.cx.allocator.destroy(self);
    }

    fn rebuild(self: *Preview) !void {
        if (self.controller.model.dirty or self.controller.state() != .clean) return error.PlanningPreviewDirtiedConfig;
        if (self.content_scope) |old| old.dispose();
        self.content_scope = null;
        while (self.root.children.items.len > 0) {
            const old = self.root.children.items[self.root.children.items.len - 1];
            self.cx.detachChild(self.root, old);
            self.cx.destroyDetached(old);
        }
        const content_scope = try self.scope.childScope();
        self.content_scope = content_scope;
        const mounted = try view.mountPage(self.cx, content_scope, &self.controller, .{
            .context = self,
            .changed = changed,
            .request_edit = requestEdit,
            .action = action,
        });
        try self.root.appendChild(self.cx.allocator, mounted.root);
    }

    fn changed(raw: *anyopaque) void {
        const self: *Preview = @ptrCast(@alignCast(raw));
        self.pending_rebuild = true;
        self.cx.requestRedraw();
    }

    fn afterLayout(raw: *anyopaque, _: u8, _: bool) ui.AfterLayoutResult {
        const self: *Preview = @ptrCast(@alignCast(raw));
        if (!self.pending_rebuild) return .done;
        self.pending_rebuild = false;
        self.rebuild() catch |err| {
            std.log.err("planning component rebuild failed: {s}", .{@errorName(err)});
            return .done;
        };
        return .needs_layout;
    }

    fn requestEdit(_: *anyopaque, _: view.Key, _: *ui.Node) void {}
    fn action(_: *anyopaque, _: view.Action) void {}
};

fn mountPreview(cx: *ui.Cx, scope: *ui.Scope) !*ui.Node {
    theme.select(options.selected_theme);
    cx.setTheme(theme.widgetTheme(options.selected_theme));
    const root = try ui.box(cx, .{ .width = .fill(), .height = .fill(), .direction = .column, .background = theme.current().surface_1 }, .{});
    root.meta.ownership.meta.test_id = "settings.preview.component";
    const state = try cx.allocator.create(Preview);
    var adopted = false;
    errdefer if (!adopted) cx.allocator.destroy(state);
    state.* = .{ .cx = cx, .scope = scope, .root = root, .controller = try Controller.init(cx.allocator, .{}) };
    errdefer if (!adopted) state.controller.deinit();
    state.controller.model.selectPage(5);
    // The source planning row was expanded before entering its detail.
    state.controller.folded_sections &= ~(@as(u64, 1) << 41);
    state.controller.plugin_page.select(.{ .planned = .ftp_ftps });
    try state.controller.plugin_page.showPreview(options.preview_kind);
    try scope.onCleanup(Preview, state, Preview.cleanup);
    adopted = true;
    try cx.addAfterLayoutHook(state, Preview.afterLayout);
    try state.rebuild();
    return root;
}

pub fn main(init: std.process.Init) !void {
    var preview_kind: ?plugins.PreviewKind = null;
    var selected_theme: theme.Name = .sauber;
    var args = init.minimal.args.iterate();
    _ = args.next();
    while (args.next()) |arg| {
        if (std.mem.startsWith(u8, arg, "--preview-kind=")) {
            preview_kind = std.meta.stringToEnum(plugins.PreviewKind, arg[15..]) orelse return error.InvalidPreviewKind;
        } else if (std.mem.startsWith(u8, arg, "--theme=")) {
            selected_theme = std.meta.stringToEnum(theme.Name, arg[8..]) orelse return error.InvalidTheme;
        } else if (std.mem.eql(u8, arg, "--help")) {
            std.debug.print("settings-preview-runner --preview-kind=validation|incompatible|wait_sessions|acquisition|loading [--theme=sauber|dark|light]\nRead-only planning component acceptance; no install, permission, or loading operation.\n", .{});
            return;
        } else return error.InvalidOption;
    }
    options = .{ .preview_kind = preview_kind orelse return error.PreviewKindRequired, .selected_theme = selected_theme };
    const app = try App.init(std.heap.c_allocator, .{
        .io = init.io,
        .window = .{ .width = 636, .height = 628, .min_width = 636, .min_height = 628, .title = "ZeroWork · 规划视图组件验收" },
    });
    defer app.deinit();
    try app.runWith(mountPreview);
}
