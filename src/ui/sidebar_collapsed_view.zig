//! Compatibility name for the status bar's single connection-library restore
//! control. V3 hides the library completely; no collapsed host rail is mounted.
const ui = @import("ui");
const Sidebar = @import("sidebar_view.zig");
const theme = @import("app_theme.zig");
const Workspace = @import("workspace.zig").Workspace;
const identity = @import("../host/identity.zig");
pub const HostAction = enum { edit, connect };
pub const Actions = struct {
    context: *anyopaque,
    search: *const fn (*anyopaque) void,
    new_host: *const fn (*anyopaque) void,
    expand: *const fn (*anyopaque) void,
    host_action: ?*const fn (*anyopaque, identity.AssetOwner, HostAction) void = null,
};
pub const View = struct {
    cx: *ui.Cx,
    root: *ui.Node,
    pub fn mount(cx: *ui.Cx, scope: *ui.Scope, _: *Workspace, actions: Actions) !*View {
        const tint = try scope.createSignal(?ui.Color, theme.current().fg_2);
        const hover = try scope.createSignal(?ui.BoxStyle, .{ .background = theme.current().hover });
        const button = try Sidebar.iconButton(cx, scope, "panel-left-open", "显示连接列表 ⌘B", "sidebar.restore", Sidebar.styles.railAction(26), tint, hover, ui.Cx.simpleHandler(actions.expand, actions.context), null);
        const root = try Sidebar.hint(cx, scope, button, "显示连接列表 ⌘B", .top);
        root.meta.ownership.meta.test_id = "workspace.sidebar.restore";
        root.setStyleInline(cx.allocator, .{ .width = .{ .px = 26 }, .height = .{ .px = 26 }, .flex_shrink = 0 });
        root.setDisplay(.none);
        return scope.createState(View, .{ .cx = cx, .root = root });
    }
    pub fn setCollapsed(self: *View, hidden: bool) void {
        self.root.setDisplay(if (hidden) .flex else .none);
        self.cx.requestRedraw();
    }
    pub fn ownsSidebar(_: *const View) bool {
        return false;
    }
    pub fn refresh(_: *View) !void {}
};
