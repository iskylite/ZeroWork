//! V3 session-tab colour chooser. Captures the original TabId, never active-tab state.
const ui = @import("ui");
const theme = @import("app_theme.zig");

pub const colors = [_]u32{ 0x818cf8, 0x67b88b, 0xe2ad67, 0xdf8598, 0x87bde8 };
pub const labels = [_][]const u8{ "#818cf8", "#67b88b", "#e2ad67", "#df8598", "#87bde8" };
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
    buttons: [colors.len]*ui.Node = undefined,

    pub fn mount(cx: *ui.Cx, scope: *ui.Scope, hooks: Hooks) !*View {
        const self = try cx.allocator.create(View);
        var registered = false;
        errdefer if (!registered) cx.allocator.destroy(self);
        self.* = .{ .cx = cx, .hooks = hooks, .open = try scope.createSignal(bool, false) };
        try scope.onCleanup(View, self, cleanup);
        registered = true;
        const popup = try ui.widgets.Popover(.{ .open = self.open, .trigger = .manual, .anchor = .{ .virtual = .{ .ctx = self, .getRect = anchorRect } }, .position = .bottom_start, .offset = .{ .static = 6 }, .width = 344, .max_width = 344, .viewport_padding = 12, .constrain_width_to_viewport = true, .shift_main_axis = true, .consume_outside_click = true, .close_on_escape = true, .a11y_role = .dialog, .on_open_change = cx.on(View, self, changed) }).mount(scope, cx);
        self.root = popup.wrapper;
        self.chrome = popup.chrome;
        self.chrome.meta.ownership.meta.test_id = "tabs.color";
        self.chrome.setStyleInline(cx.allocator, panel());
        try theme.bindMaterial(cx, popup.scope, self.chrome, "overlay");
        const body = try ui.box(cx, .{ .width = .fill(), .direction = .column, .gap = 12 }, .{});
        try popup.content.appendChild(cx.allocator, body);
        const heading = try ui.box(cx, .{ .width = .fill(), .height = .{ .px = 26 }, .direction = .row, .align_items = .center, .gap = 8, .padding = .{ .top = 2 }, .flex_shrink = 0 }, .{});
        try heading.appendChild(cx.allocator, try ui.iconTint(cx, ui.icons.get("palette").?, theme.current().accent, .{ .width = .{ .px = 17 }, .height = .{ .px = 17 }, .flex_shrink = 0 }));
        self.title = try ui.text(cx, "页签颜色", .{ .font_size = 13, .font_weight = 700, .line_height = 20.0 / 13.0, .color = theme.current().fg_1 });
        try heading.appendChild(cx.allocator, self.title);
        try heading.appendChild(cx.allocator, try ui.box(cx, .{ .width = .fill() }, .{}));
        const close = try ui.widgets.Button(.{ .variant = .ghost, .icon_only = true, .a11y_label = "关闭页签颜色", .base_style = .{ .width = .{ .px = 24 }, .height = .{ .px = 24 }, .padding = ui.Padding.all(5), .border = .{ .radius = 7 }, .flex_shrink = 0 }, .on_click = cx.on(View, self, hide) }).mount(popup.scope, cx);
        close.meta.ownership.meta.test_id = "tabs.color.close";
        try close.appendChild(cx.allocator, try ui.iconTint(cx, ui.icons.x, theme.current().fg_2, .{ .width = .{ .px = 14 }, .height = .{ .px = 14 } }));
        try heading.appendChild(cx.allocator, close);
        try body.appendChild(cx.allocator, heading);
        const choices = try ui.box(cx, .{ .width = .fill(), .height = .{ .px = 38 }, .direction = .row, .gap = 10, .padding = ui.Padding.all(5), .flex_shrink = 0 }, .{});
        try body.appendChild(cx.allocator, choices);
        inline for (colors, labels, 0..) |color, label, index| {
            const action = try popup.scope.createState(Choice, .{ .view = self, .color = color });
            const button = try ui.widgets.Button(.{ .variant = .ghost, .a11y_label = label, .focus_ring = .{ .color = theme.current().accent, .width = 1.5, .offset = 2 }, .hover_style = .{ .background = ui.Color.hex(color) }, .pressed_style = .{ .background = ui.Color.hex(color) }, .base_style = .{ .width = .{ .px = 28 }, .height = .{ .px = 28 }, .background = ui.Color.hex(color), .border = .{ .radius = 7 }, .flex_shrink = 0 }, .on_click = cx.on(Choice, action, Choice.choose) }).mount(popup.scope, cx);
            button.meta.ownership.meta.test_id = "tabs.color." ++ label[1..];
            self.buttons[index] = button;
            try choices.appendChild(cx.allocator, button);
        }
        return self;
    }

    pub fn show(self: *View, owner: u64, anchor: *ui.Node) void {
        self.owner = owner;
        self.anchor_id = anchor.id;
        self.chrome.setStyleInline(self.cx.allocator, panel());
        self.title.setTextColor(theme.current().fg_1);
        self.open.set(true);
        self.cx.setFocus(self.buttons[0]);
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

const Choice = struct {
    view: *View,
    color: u32,
    fn choose(self: *Choice) void {
        if (!self.view.isOpen()) return;
        _ = self.view.hooks.commit(self.view.hooks.context, self.view.owner, self.color);
        self.view.hide();
    }
};
fn find(node: *ui.Node, id: u32) ?*ui.Node {
    if (node.id == id) return node;
    for (node.children.items) |child| if (find(child, id)) |result| return result;
    return null;
}
// Zenit paints the 1px border without adding it to Yoga padding. HTML uses
// border-box: 14px padding + 1px border, so native content starts at 15px.
fn panel() ui.BoxStyle {
    return .{ .width = .{ .px = 344 }, .height = .{ .fit = .{} }, .direction = .column, .padding = ui.Padding.all(15), .background = theme.current().overlay, .glass = theme.overlayGlass(), .border = .{ .width = 1, .color = theme.current().border, .radius = 11 }, .shadow = .{ .blur = 24, .offset_y = 8, .color = theme.current().shadow } };
}
