//! Local UI feedback: one content-sized surface inside the transcript scroll.
//! It is not an assistant message and never enters model history.
const ui = @import("ui");
const S = @import("ai_assistant_styles.zig");
const theme = @import("app_theme.zig");

pub const Kind = enum { rollback, warning };
pub const rollback_label = "已回退，原消息已恢复到输入框，此回合及后续对话已移除。";

pub const View = struct {
    cx: *ui.Cx,
    root: *ui.Node,
    text: *ui.Node,
    rollback_icon: *ui.Node,
    warning_icon: *ui.Node,
    dismiss_button: *ui.Node,

    pub fn mount(cx: *ui.Cx, scope: *ui.Scope) !*View {
        const root = try ui.boxStyled(cx, S.noticeHolder, .{});
        root.meta.ownership.meta.test_id = "ai.feedback";
        root.behavior.interaction.a11y = .{ .role = .status, .live = "polite" };
        root.setDisplay(.none);
        const row = try ui.boxStyled(cx, S.notice, .{});
        try root.appendChild(cx.allocator, row);
        const slot = try ui.box(cx, .{ .width = .{ .px = 14 }, .height = .{ .px = 22 }, .flex_shrink = 0, .align_items = .center, .justify = .center }, .{});
        const rollback_icon = try ui.iconTint(cx, ui.icons.get("undo-2").?, theme.current().fg_2, S.icon());
        rollback_icon.meta.ownership.meta.test_id = "ai.feedback.rollback";
        const warning_icon = try ui.iconTint(cx, ui.icons.get("circle-alert").?, theme.current().warn, S.icon());
        warning_icon.meta.ownership.meta.test_id = "ai.feedback.warning";
        try slot.appendChild(cx.allocator, rollback_icon);
        try slot.appendChild(cx.allocator, warning_icon);
        try row.appendChild(cx.allocator, slot);
        const text = try ui.textStyled(cx, S.noticeText, "");
        text.meta.ownership.meta.test_id = "ai.feedback.text";
        text.setStyleInline(cx.allocator, .{ .width = .fill(), .min_width = 0, .flex = 1, .flex_shrink = 1, .margin = .{ .top = 2, .bottom = 2 } });
        try row.appendChild(cx.allocator, text);
        const self = try scope.createState(View, .{ .cx = cx, .root = root, .text = text, .rollback_icon = rollback_icon, .warning_icon = warning_icon, .dismiss_button = undefined });
        self.dismiss_button = try ui.widgets.Button(.{ .variant = .ghost, .icon_only = true, .icon_asset = ui.icons.x, .icon_size = @as(f32, 12), .a11y_label = "关闭提示", .base_style = S.windowControl(), .hover_style = S.controlHover(.close), .on_click = cx.on(View, self, dismiss) }).mount(scope, cx);
        self.dismiss_button.meta.ownership.meta.test_id = "ai.feedback.dismiss";
        try row.appendChild(cx.allocator, self.dismiss_button);
        return self;
    }

    pub fn show(self: *View, label: []const u8, kind: Kind) void {
        self.text.setTextContent(self.cx.allocator, label) catch return;
        self.rollback_icon.setDisplay(if (kind == .rollback) .flex else .none);
        self.warning_icon.setDisplay(if (kind == .warning) .flex else .none);
        // Blocking reasons stay visible until resolved; completed actions may be dismissed.
        self.dismiss_button.setDisplay(if (kind == .rollback) .flex else .none);
        self.root.setDisplay(if (label.len == 0) .none else .flex);
        _ = self.rollback_icon.setTint(theme.current().fg_2);
        _ = self.warning_icon.setTint(theme.current().warn);
        self.root.markRenderDirty();
    }

    fn dismiss(self: *View) void {
        self.root.setDisplay(.none);
        self.root.markRenderDirty();
    }
};
