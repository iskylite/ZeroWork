//! Local Figma Bridge: 236:414709 / 236:416262, 320×164 anchored forms.
//! Rename/color share this chrome; empty-delete keeps its consequence text.
const ui = @import("ui");
pub const theme = @import("app_theme.zig");
const common = @import("asset_action_styles.zig");
pub const Mode = enum { create, rename, color, delete_empty, created };
pub const width: f32 = 320;
pub fn height(mode: Mode) f32 {
    return switch (mode) {
        .create => 135,
        .created => 130,
        .delete_empty => 200,
        .rename, .color => 135,
    };
}
pub fn panel(mode: Mode, viewport: ui.Size, field_error: bool, notice_error: bool) ui.BoxStyle {
    var result = common.panel(@min(height(mode) + @as(f32, if (field_error) 21 else if (notice_error and mode != .delete_empty) 70 else 0), @max(0, viewport.height - 16)));
    result.width = .{ .px = @min(width, @max(0, viewport.width - 16)) };
    return result;
}
pub const header = common.header;
pub const body = common.body;
pub const row = common.row;
pub const label = common.label;
pub const icon = common.icon;
pub const text = common.text;
pub const button = common.button;
pub fn hover() ui.BoxStyle {
    return .{ .background = theme.current().hover };
}
pub const close = common.close;
pub const footer = common.footer;
pub const summary = common.target;
pub fn field(show_error: bool) ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = if (show_error) 74 else 53 }, .direction = .column, .gap = 5, .flex_shrink = 0 };
}
pub fn input() ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = 32 }, .padding = .{ .left = 12, .right = 12 }, .background = theme.current().well, .border = .{ .radius = 8 }, .flex_shrink = 0 };
}
pub fn tuneInput(value: *ui.widgets.input.InputResult) void {
    value.state.font_size = 12;
    value.state.line_height = 18;
    value.state.char_width = 7.2;
    value.state.dirty = true;
    if (value.state.text_display_node) |node| if (node.getText()) |current| {
        var next = current;
        next.font_size = 12;
        next.line_height = 1.5;
        next.color = theme.current().fg_1;
        node.setText(next);
    };
}
pub fn notice(mode: Mode, failed: bool) ui.BoxStyle {
    var result = common.stack(4);
    if (!failed and mode != .delete_empty) return result;
    result.height = .{ .px = 62 };
    result.padding = ui.Padding.all(12);
    const c = theme.current();
    result.background = (if (failed or mode == .delete_empty) c.danger else if (mode == .created) c.ok else c.accent).withAlpha(23);
    result.border = .{ .radius = 9 };
    return result;
}
pub fn ink(mode: Mode, failed: bool) ui.Color {
    const c = theme.current();
    return if (failed or mode == .delete_empty) c.danger_ink else if (mode == .created) c.ok_ink else c.accent_ink;
}
pub fn paragraph() ui.TextStyle {
    var result = text(11, 400, false);
    result.wrap = .word;
    result.text_overflow = .clip;
    return result;
}
