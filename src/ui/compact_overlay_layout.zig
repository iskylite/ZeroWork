//! Content-driven overlay height; only the body scrolls at its limit.
const ui = @import("ui");
const Layout = struct {
    cx: *ui.Cx,
    dialog: *ui.Node,
    viewport: *ui.Node,
    content: *ui.Node,
    mirror: ?*ui.Node = null,
    fixed: f32,
    maximum: f32,
    actions: ?*ui.Node,
    actions_top: f32,
    fn cleanup(self: *Layout) void {
        self.cx.removeAfterLayoutHook(self);
    }
    fn layout(raw: *anyopaque, _: u8, _: bool) ui.AfterLayoutResult {
        const self: *Layout = @ptrCast(@alignCast(raw));
        if (self.dialog.globalRect().w == 0) return .done;
        const height = @min(@max(16, self.content.globalRect().h), @max(16, @min(self.maximum, self.cx.viewport.height - 16 - self.fixed)));
        const total = height + self.fixed;
        if (self.mirror) |mirror| {
            if (mirror.style.height != .px or @abs(mirror.style.height.px - total) > 0.1) mirror.setStyleInline(self.cx.allocator, .{ .height = .{ .px = total } });
        }
        if (self.dialog.style.height == .px and @abs(self.dialog.style.height.px - total) < 0.1 and self.viewport.style.height == .px and @abs(self.viewport.style.height.px - height) < 0.1) return .done;
        self.viewport.setStyleInline(self.cx.allocator, .{ .height = .{ .px = height } });
        self.dialog.setStyleInline(self.cx.allocator, .{ .height = .{ .px = total } });
        if (self.actions) |actions| actions.setStyle(self.cx.allocator, .inset, .{ .left = .{ .px = 12 }, .top = .{ .px = self.actions_top + height } });
        return .needs_layout;
    }
};
pub fn mount(cx: *ui.Cx, scope: *ui.Scope, dialog: *ui.Node, viewport: *ui.Node, content: *ui.Node, fixed: f32, maximum: f32, actions: ?*ui.Node, actions_top: f32) !void {
    return mountMirrored(cx, scope, dialog, viewport, content, fixed, maximum, actions, actions_top, null);
}
pub fn mountMirrored(cx: *ui.Cx, scope: *ui.Scope, dialog: *ui.Node, viewport: *ui.Node, content: *ui.Node, fixed: f32, maximum: f32, actions: ?*ui.Node, actions_top: f32, mirror: ?*ui.Node) !void {
    const state = try scope.createState(Layout, .{ .cx = cx, .dialog = dialog, .viewport = viewport, .content = content, .fixed = fixed, .maximum = maximum, .actions = actions, .actions_top = actions_top, .mirror = mirror });
    try scope.onCleanup(Layout, state, Layout.cleanup);
    try cx.addAfterLayoutHook(state, Layout.layout);
}
