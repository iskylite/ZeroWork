//! Local Figma Bridge, session-mvgeqdxp-kmw89t, page 214:329905:
//! 236:418206 / 420441 / 422643 / 424343 / 428090.
const ui = @import("ui");
pub const theme = @import("app_theme.zig");
pub const Step = enum { move_select, move_confirm, move_success, delete_confirm, delete_success };
pub const width: f32 = 340;
pub const list_height: f32 = 98;
pub const item_height: f32 = 54;
pub const error_height: f32 = 48;

pub fn height(step: Step) f32 {
    return switch (step) {
        .move_select => 268,
        .move_confirm => 321,
        .move_success => 301,
        .delete_confirm => 162,
        .delete_success => 269,
    };
}
pub fn panel(h: f32) ui.BoxStyle {
    return .{ .width = .{ .px = width }, .height = .{ .px = h }, .direction = .column, .padding = .{}, .gap = 0, .background = theme.current().overlay, .glass = theme.overlayGlass(), .border = .{ .radius = 11 }, .shadow = .{ .offset_y = 12, .blur = 24, .color = theme.current().shadow } };
}
pub fn header() ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = 32 }, .direction = .row, .align_items = .center, .gap = 6, .padding = .{ .left = 12, .right = 12 }, .flex_shrink = 0 };
}
pub fn body() ui.BoxStyle {
    return .{ .width = .fill(), .height = .fill(), .min_height = 0, .direction = .column, .padding = .{ .top = 0, .left = 12, .right = 12, .bottom = 12 }, .gap = 8 };
}
pub fn stack(gap: f32) ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .fit = .{} }, .direction = .column, .gap = gap, .flex_shrink = 0 };
}
pub fn row(h: f32, gap: f32) ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = h }, .direction = .row, .align_items = .center, .gap = gap, .flex_shrink = 0 };
}
pub fn label(h: f32) ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = h }, .min_width = 0, .flex_shrink = 0 };
}
pub fn identityText() ui.BoxStyle {
    var result = stack(2);
    result.flex = 1;
    result.min_width = 0;
    return result;
}
pub fn text(size: f32, weight: u16, mono: bool) ui.TextStyle {
    const line: f32 = if (size == 14) 21 else if (size == 13) 20 else if (size == 12) 18 else 16;
    return .{ .font_size = ui.arb.px(size), .font_weight = weight, .line_height = line / size, .color = if (weight >= 500) theme.current().fg_1 else theme.current().fg_2, .selectable = false, .text_overflow = .ellipsis, .use_monospace_font = mono };
}
pub fn paragraph() ui.TextStyle {
    var result = text(11, 400, false);
    result.wrap = .word;
    result.text_overflow = .clip;
    return result;
}
pub fn icon(size: f32) ui.Style {
    return .{ .width = .{ .px = size }, .height = .{ .px = size }, .flex_shrink = 0 };
}
pub fn pair() ui.BoxStyle {
    var result = stack(8);
    result.height = .{ .px = 68 };
    result.padding = ui.Padding.all(12);
    result.background = theme.popupAction();
    result.border = .{ .radius = 9 };
    return result;
}
pub fn target() ui.BoxStyle {
    var result = row(48, 10);
    result.padding = ui.Padding.all(10);
    result.background = theme.popupAction();
    result.border = .{ .radius = 9 };
    return result;
}
pub fn notice(_: Step) ui.BoxStyle {
    var result = stack(0);
    result.height = .{ .px = 32 };
    return result;
}
pub fn noticeColor(step: Step, ink: bool) ui.Color {
    const c = theme.current();
    return switch (step) {
        .move_success, .delete_success => if (ink) c.ok_ink else c.ok,
        .delete_confirm => if (ink) c.danger_ink else c.danger,
        else => if (ink) c.accent_ink else c.accent,
    };
}
pub fn errorBox() ui.BoxStyle {
    var result = stack(2);
    result.height = .{ .px = error_height };
    result.padding = ui.Padding.all(8);
    result.background = theme.current().danger.withAlpha(23);
    result.border = .{ .radius = 9 };
    return result;
}
pub fn footer() ui.BoxStyle {
    var result = row(30, 8);
    result.justify = .end;
    return result;
}
pub fn primaryWidth(step: Step) f32 {
    return switch (step) {
        .move_confirm => 120,
        .delete_confirm => 150,
        else => 144,
    };
}
pub fn secondaryWidth(step: Step) f32 {
    return switch (step) {
        .delete_confirm => 112,
        .delete_success => 140,
        else => 84,
    };
}
pub fn close() ui.BoxStyle {
    return .{ .width = .{ .px = 22 }, .height = .{ .px = 22 }, .padding = .{}, .border = .{ .radius = 8 }, .background = ui.Color.TRANSPARENT, .flex_shrink = 0 };
}
pub fn button(w: f32, h: f32, primary: bool, danger: bool) ui.BoxStyle {
    const c = theme.current();
    return .{ .width = .{ .px = w }, .height = .{ .px = h }, .padding = .{}, .background = if (danger) c.action_danger else if (primary) c.action_accent else theme.popupAction(), .border = .{ .radius = 8 }, .align_items = .center, .justify = .center, .flex_shrink = 0 };
}
pub fn actionColor(primary: bool, disabled: bool) ui.Color {
    return if (disabled) theme.current().fg_3 else if (primary) theme.widgetTheme(theme.currentName()).tokens.color.button_primary_fg else theme.current().fg_2;
}
const GroupRecipe = ui.recipe.recipe(struct {
    pub const Variants = struct { selected: bool = false };
    pub fn base(_: *const ui.ThemeTokens) ui.ConditionalStyle {
        return .{ .base = .{ .width = .fill(), .height = .{ .px = 44 }, .direction = .row, .align_items = .center, .padding = ui.Padding.all(10), .gap = 8, .background = theme.popupAction(), .border = .{ .radius = 9 }, .flex_shrink = 0 } };
    }
    pub const variants = .{ .selected = struct {
        fn resolve(selected: bool, _: *const ui.ThemeTokens) ui.ConditionalStyle {
            return .{ .base = .{ .background = if (selected) theme.popupSelection() else theme.popupAction() } };
        }
    }.resolve };
});
pub fn group(selected: bool, tokens: *const ui.ThemeTokens) ui.BoxStyle {
    return GroupRecipe.resolveBase(.{ .selected = selected }, tokens);
}
pub fn groupLabel() ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = 18 }, .min_width = 0, .flex = 1 };
}
pub fn groupList() ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = list_height }, .flex_shrink = 0 };
}
