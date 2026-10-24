//! zig_native styles: pure Zig style objects (`ui.css` / `ui.cva` / `ui.sva`), same as
//! .yss-generated. Enum literals are token names, looked up at compile time by field's
//! token category (misspell is error); tokens fetch value on apply, follow theme.
const ui = @import("ui");

pub const root = ui.css(.{ .width = .fill, .height = .fill, .direction = .column, .gap = .space400, .padding = .space800, .background = .bg_primary });
pub const title = ui.css(.{ .color = .fg_primary, .font_size = .xxl, .font_weight = .semibold });
pub const row = ui.css(.{ .height = .fit, .direction = .row, .align_items = .center, .gap = .space300 });
pub const caption = ui.css(.{ .color = .fg_secondary, .font_size = .md });

/// Capsule tag tone (public enum; recipe's same-name option matches by name)
pub const Tone = enum { neutral, accent, success };

/// Capsule tag: tone is variant, bg mixed from text and bg color
pub const Pill = ui.cva(.{
    .base = .{ .width = .fit, .height = .fit, .padding = .{ .y = 2, .x = .space200 }, .corner_radius = .full },
    .variants = .{ .tone = .{
        .neutral = .{ .background = .bg_secondary, .color = .fg_secondary },
        .accent = .{ .background = ui.mix(ui.theme.refs.color.bg_primary, ui.theme.refs.color.accent, 0.18), .color = .accent },
        .success = .{ .background = ui.mix(ui.theme.refs.color.bg_primary, ui.theme.refs.color.success, 0.18), .color = .success },
    } },
    .defaults = .{ .tone = .neutral },
});
pub const pill_text = ui.css(.{ .font_size = .sm, .font_weight = .medium });

/// Group: title + content (slot)
pub const section = ui.css(.{ .width = .fill, .height = .fit, .direction = .column, .gap = .space200 });
pub const section_title = ui.css(.{ .color = .fg_secondary, .font_size = .sm, .font_weight = .semibold });
pub const section_body = ui.css(.{ .width = .fill, .height = .fit, .direction = .column, .gap = .space100 });

/// Stepper numeric value
pub const stepper_value = ui.css(.{ .color = .fg_primary, .font_size = .lg, .width = 32, .text_align = .center });

/// Task row: multi-part recipe (root / check / title), done state is flag; hover
/// changes row bg
pub const TaskRow = ui.sva(.{
    .slots = .{ .root, .check, .title },
    .base = .{
        .root = .{ .width = .fill, .height = .fit, .direction = .row, .align_items = .center, .gap = .space300, .padding = .{ .y = .space150, .x = .space300 }, .corner_radius = .md, ._hover = .{ .background = .bg_hover } },
        .check = .{ .width = 16, .height = 16, .corner_radius = 4, .border_width = 1.5, .border_color = .border_strong, .cursor = .pointer },
        .title = .{ .font_size = .md },
    },
    .variants = .{ .done = .{
        .false = .{ .title = .{ .color = .fg_primary } },
        .true = .{ .check = .{ .background = .accent, .border_color = .accent }, .title = .{ .color = .fg_disabled, .strikethrough = true } },
    } },
    .defaults = .{ .done = false },
});

/// Progress bar: track + fill by completion ratio (continuous value uses styleBy:
/// plain Zig function, parameter is source current value)
pub const progress_track = ui.css(.{ .width = .fill, .height = 6, .corner_radius = 3, .background = .bg_tertiary, .overflow_hidden = true });
pub fn progressFill(ratio: f32, t: *const ui.theme.Values) ui.BoxStyle {
    return .{ .width = .{ .percent = ratio * 100 }, .height = ui.Sizing.fill(), .background = t.tokens.color.accent };
}
