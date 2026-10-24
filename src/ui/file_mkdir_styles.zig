//! Local Bridge 302:665864, 319:709641/710402/711162.
const ui = @import("ui");
const files = @import("file_workspace_styles.zig");
pub const theme = files.theme;
pub fn editor(_: *const ui.ThemeTokens) ui.BoxStyle {
    var value = files.columns(files.min_columns);
    value.position = .absolute;
    value.inset = .{ .left = .{ .px = 0 }, .top = .{ .px = 0 } };
    value.background = theme.current().surface_2;
    return value;
}
pub fn name(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .flex = 1, .height = .{ .px = 28 }, .min_width = 0, .direction = .row, .align_items = .center, .gap = 6 };
}
pub fn field(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .flex = 1, .height = .{ .px = 24 }, .min_width = 0, .padding = .{ .left = 10, .right = 8 }, .background = theme.current().well, .border = .{ .width = 0, .color = theme.current().accent, .radius = 8 }, .align_items = .center, .overflow = .hidden, .overflow_hidden = true };
}
pub fn input() ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = 20 }, .flex = 1, .min_width = 0, .padding = .{}, .background = ui.Color.TRANSPARENT, .border = .{ .width = 0 } };
}
pub fn result(t: *const ui.ThemeTokens) ui.BoxStyle {
    return files.errorBox(t);
}
pub fn heading(_: *const ui.ThemeTokens) ui.TextStyle {
    return .{ .font_size = 11.5, .font_weight = 500, .line_height = 18.0 / 11.5, .color = theme.current().fg_1, .wrap = .none, .text_overflow = .ellipsis };
}
pub fn path(_: *const ui.ThemeTokens) ui.TextStyle {
    return .{ .font_size = 10.5, .line_height = 16.0 / 10.5, .color = theme.current().fg_1, .wrap = .none, .text_overflow = .ellipsis };
}
pub fn actions() ui.BoxStyle {
    var value = files.line(30);
    value.justify = .end;
    return value;
}
pub fn button() files.ButtonStyle {
    return files.iconButton(28);
}
pub fn tune(input_: *ui.widgets.input.InputResult) void {
    input_.node.setStyleInline(input_.state.allocator, input());
    input_.input_container.setStyleInline(input_.state.allocator, input());
    input_.state.font_size = 11.5;
    input_.state.line_height = 17;
    input_.state.char_width = 11.5 * 0.6;
    if (input_.state.text_display_node) |node| if (node.getText()) |current| {
        var value = current;
        value.font_size = 11.5;
        value.line_height = 17.0 / 11.5;
        node.setText(value);
    };
    input_.state.dirty = true;
}

pub fn tooltip() ui.BoxStyle {
    return .{ .width = .{ .px = 28 }, .height = .{ .px = 28 }, .flex_shrink = 0 };
}
