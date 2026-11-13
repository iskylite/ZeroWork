//! V3 session-tab colour chooser. Captures the original TabId, never active-tab state.
const ui = @import("ui");
const theme = @import("app_theme.zig");

const palette = @import("color_palette.zig");
pub const colors = palette.colors;
pub const labels = palette.labels;
pub const Hooks = struct {
    context: *anyopaque,
    // Return false when the captured tab no longer exists or is closing.
    commit: *const fn (*anyopaque, u64, u32) bool,
};

pub const View = struct {
    cx: *ui.Cx,
    hooks: Hooks,
    root: *ui.Node = undefined,
    chrome: *ui.Node = undefined,
    title: *ui.Node = undefined,
    open: *ui.Signal(bool),
    owner: u64 = 0,
    anchor_id: ?u32 = null,
    palette: *palette.View = undefined,

    pub fn mount(cx: *ui.Cx, scope: *ui.Scope, hooks: Hooks) !*View {
        const self = try cx.allocator.create(View);
        var registered = false;
        errdefer if (!registered) cx.allocator.destroy(self);
        self.* = .{ .cx = cx, .hooks = hooks, .open = try scope.createSignal(bool, false) };
        try scope.onCleanup(View, self, cleanup);
        registered = true;
        const popup = try ui.widgets.Popover(.{ .group = @import("floating_surface.zig").workspace_popup, .open = self.open, .trigger = .manual, .anchor = .{ .virtual = .{ .ctx = self, .getRect = anchorRect } }, .position = .bottom_start, .offset = .{ .static = 6 }, .width = 344, .max_width = 344, .viewport_padding = 12, .constrain_width_to_viewport = true, .shift_main_axis = true, .consume_outside_click = true, .close_on_escape = true, .a11y_role = .dialog, .on_open_change = cx.on(View, self, changed) }).mount(scope, cx);
        self.root = popup.wrapper;
        self.chrome = popup.chrome;
        self.chrome.meta.ownership.meta.test_id = "tabs.color";
        self.chrome.setStyleInline(cx.allocator, panel());
        try theme.bindMaterial(cx, popup.scope, self.chrome, "overlay");
        const body = try ui.box(cx, .{ .width = .fill(), .direction = .column, .gap = 12 }, .{});
        try popup.content.appendChild(cx.allocator, body);
        const heading = try ui.box(cx, .{ .width = .fill(), .height = .{ .px = 26 }, .direction = .row, .align_items = .center, .gap = 8, .padding = .{ .top = 2 }, .flex_shrink = 0 }, .{});
        try heading.appendChild(cx.allocator, try theme.icon(cx, ui.icons.get("palette").?, "accent_ink", .{ .width = .{ .px = 17 }, .height = .{ .px = 17 }, .flex_shrink = 0 }));
        self.title = try ui.textStyled(cx, titleStyle, "页签颜色");
        try heading.appendChild(cx.allocator, self.title);
        try heading.appendChild(cx.allocator, try ui.box(cx, .{ .width = .fill() }, .{}));
        const close = try ui.widgets.Button(.{ .variant = .ghost, .icon_only = true, .a11y_label = "关闭页签颜色", .base_style = .{ .width = .{ .px = 24 }, .height = .{ .px = 24 }, .padding = ui.Padding.all(5), .border = .{ .radius = 7 }, .flex_shrink = 0 }, .on_click = cx.on(View, self, hide) }).mount(popup.scope, cx);
        close.meta.ownership.meta.test_id = "tabs.color.close";
        try close.appendChild(cx.allocator, try theme.icon(cx, ui.icons.x, "fg_2", .{ .width = .{ .px = 14 }, .height = .{ .px = 14 } }));
        try heading.appendChild(cx.allocator, close);
        try body.appendChild(cx.allocator, heading);
        self.palette = try palette.View.mount(cx, popup.scope, "tabs.color", try popup.scope.createSignal(bool, false), .{ .context = self, .choose = chooseColor });
        try body.appendChild(cx.allocator, self.palette.root);
        return self;
    }

    pub fn show(self: *View, owner: u64, anchor: *ui.Node) void {
        self.owner = owner;
        self.anchor_id = anchor.id;
        self.chrome.setStyleInline(self.cx.allocator, panel());
        self.title.setTextColor(theme.current().fg_1);
        self.open.set(true);
        self.cx.setFocus(self.palette.buttons[0]);
        self.cx.requestRedraw();
    }
    pub fn hide(self: *View) void {
        self.open.set(false);
        self.restoreFocus();
        self.cx.requestRedraw();
    }
    pub fn isOpen(self: *const View) bool {
        return self.open.peek();
    }
    fn changed(self: *View, open: bool) void {
        if (!open) self.restoreFocus();
    }
    fn restoreFocus(self: *View) void {
        if (self.cx.root) |root| if (self.anchor_id) |id| if (find(root, id)) |anchor| self.cx.setFocus(anchor);
    }
    fn anchorRect(raw: *anyopaque) ui.widgets.popover.AnchorRect {
        const self: *View = @ptrCast(@alignCast(raw));
        const root = self.cx.root orelse return .{ .x = 0, .y = 0, .w = 0, .h = 0 };
        const anchor = find(root, self.anchor_id orelse return .{ .x = 0, .y = 0, .w = 0, .h = 0 }) orelse return .{ .x = 0, .y = 0, .w = 0, .h = 0 };
        const rect = anchor.globalRect();
        return .{ .x = rect.x, .y = rect.y, .w = rect.w, .h = rect.h };
    }
    fn cleanup(self: *View) void {
        self.cx.allocator.destroy(self);
    }
};

fn chooseColor(raw: *anyopaque, color: u32) void {
    const self: *View = @ptrCast(@alignCast(raw));
    if (!self.isOpen()) return;
    _ = self.hooks.commit(self.hooks.context, self.owner, color);
    self.hide();
}
fn find(node: *ui.Node, id: u32) ?*ui.Node {
    if (node.id == id) return node;
    for (node.children.items) |child| if (find(child, id)) |result| return result;
    return null;
}
// Match the shared HTML popover: 14px padding without an outline.
fn panel() ui.BoxStyle {
    return .{ .width = .{ .px = 344 }, .height = .{ .fit = .{} }, .direction = .column, .padding = ui.Padding.all(14), .background = theme.current().overlay, .glass = theme.overlayGlass(), .border = .{ .width = 0, .radius = 11 }, .shadow = .{ .blur = 24, .offset_y = 8, .color = theme.current().shadow } };
}

fn titleStyle(_: *const ui.ThemeTokens) ui.TextStyle {
    return .{ .font_size = 13, .font_weight = 700, .line_height = 20.0 / 13.0, .color = theme.current().fg_1 };
}
