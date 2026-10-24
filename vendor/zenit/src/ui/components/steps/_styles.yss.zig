// GENERATED FILE, do not edit: generated from styles.yss; after editing the source run `zig build gen-yix` (yix-lsp regenerates it on save).
//! Steps styling: circles / numbers / titles / connectors change appearance by step state (done /
//! current); horizontal and vertical layouts share the same structure.
//! Views in steps.yix; StepItem / StepsDirection are public API, defined in mod.zig.
const core = @import("../../core.zig");
const ui = @import("../../ui.zig");
const mod = @import("mod.zig");

pub const circle_size: f32 = 28;
/// Min length of vertical connector line (also min vertical spacing between steps)
pub const v_connector_min: f32 = 24;

/// One step: circle with number (number text or checkmark icon); num is the number within circle;
/// icon is checkmark; title is the label; connector is the line to next step in vertical layout
/// (grow fills remaining height below circle). Done and current steps have accent color circles;
/// current step title is primary color + bold, done step accent, others secondary.
pub const Step = ui.sva(.{ .slots = .{ .circle, .num, .icon, .title, .connector, }, .base = .{ .circle = .{ .width = 28, .height = 28, .corner_radius = 14, .justify = .center, .align_items = .center, .background = ui.tokenRef(.color, "border"), }, .num = .{ .color = ui.Color.hex(0xffffff), .font_size = ui.tokenRef(.font_size, "sm"), .font_weight = 600, .text_align = .center, }, .icon = .{ .width = 14, .height = 14, .icon_color = ui.Color.hex(0xffffff), }, .title = .{ .color = ui.tokenRef(.color, "fg-secondary"), .font_size = ui.tokenRef(.font_size, "sm"), .font_weight = 400, }, .connector = .{ .width = 2, .height = .{ .grow = .{ .min = v_connector_min } }, .background = ui.tokenRef(.color, "border"), }, }, .variants = .{ .completed = .{ .false = .{ }, .true = .{ .circle = .{ .background = ui.tokenRef(.color, "accent"), }, .title = .{ .color = ui.tokenRef(.color, "accent"), }, .connector = .{ .background = ui.tokenRef(.color, "accent"), }, }, }, .active = .{ .false = .{ }, .true = .{ .circle = .{ .background = ui.tokenRef(.color, "accent"), }, .title = .{ .color = ui.tokenRef(.color, "fg-primary"), .font_weight = 600, }, }, }, }, .defaults = .{ .completed = false, .active = false, }, });

pub const desc = ui.css(.{ .color = ui.tokenRef(.color, "fg-secondary"), .font_size = ui.tokenRef(.font_size, "xs"), });

/// Container: fills horizontal row (equal width per step), vertical follows content
pub const Container = ui.cva(.{ .base = .{ .height = .fit, .gap = 0, }, .variants = .{ .horizontal = .{ .false = .{ .width = .fit, .direction = .column, }, .true = .{ .width = .{ .grow = .{} }, .direction = .row, }, }, }, .defaults = .{ .horizontal = false, }, });

pub const h_step = ui.css(.{ .width = .{ .grow = .{} }, .height = .fit, .direction = .column, .align_items = .center, .gap = 6, });
/// Vertical row: align_items = start pins circle to top (centering would lower last step
/// circle, breaking from prior connector)
pub const v_step = ui.css(.{ .width = .fit, .height = .fit, .direction = .row, .align_items = .start, .gap = 4, });
/// Indicator column fills row height; connector (grow) fills space below circle; line bottom
/// meets next step circle top
pub const v_indicator = ui.css(.{ .width = .fit, .height = .{ .grow = .{} }, .direction = .column, .align_items = .center, });

/// Vertical text column: top margin centers title first line with circle (row uses
/// align_items = start, circle pinned to top); margin based on theme font size
pub fn vText(t: *const core.ThemeTokens) core.BoxStyle {
    const title_line_h = t.tokens.font_size.sm * (core.TextProps{}).line_height;
    return .{ .width = .{ .fit = .{} }, .height = .{ .fit = .{} }, .direction = .column, .align_items = .start, .gap = 2, .padding = .{ .top = @max(0, (circle_size - title_line_h) / 2) } };
}

/// Horizontal connector: track from first circle center to last (each step equal width,
/// center at midpoint). left/right inset only stretch when width = grow (default fit parses as
/// 0 width, line not drawn)
pub const track = ui.paramStyle(struct { steps: usize, pub const declared = &[_][]const u8{ "position", "width", "height", "background", "inset", }; pub fn resolve(args: @This(), t: *const ui.theme.Values) ui.BoxStyle { return ui.boxFrom(.{ .position = .absolute, .width = .{ .grow = .{} }, .height = 2, .background = ui.tokenRef(.color, "border-strong"), .inset = lineInset(args.steps, args.steps -| 1), }, t); } });

/// Completed segment: from first circle center to current circle center (stops at last if past
/// end; not shown when current = 0)
pub const progress = ui.paramStyle(struct { steps: usize, current: usize, pub const declared = &[_][]const u8{ "position", "width", "height", "background", "inset", "display", }; pub fn resolve(args: @This(), t: *const ui.theme.Values) ui.BoxStyle { var out = ui.boxFrom(.{ .position = .absolute, .width = .{ .grow = .{} }, .height = 2, .background = ui.tokenRef(.color, "accent"), .inset = lineInset(args.steps, @min(args.current, args.steps -| 1)), }, t); if (@min(args.current, args.steps -| 1) == 0) out = out.merge(ui.boxFrom(.{ .display = .none, }, t)); return out; } });

/// Horizontal line position from first circle center to circle #reached (0-indexed)
fn lineInset(n: usize, reached: usize) core.Inset {
    const half = halfStepPct(n);
    const nf: f32 = @floatFromInt(@max(n, 1));
    const end_pct = half + @as(f32, @floatFromInt(reached)) / nf * 100.0;
    return .{ .top = .{ .px = circle_size / 2 - 1 }, .left = .{ .percent = half }, .right = .{ .percent = 100.0 - end_pct } };
}

fn halfStepPct(n: usize) f32 {
    return if (n > 0) 50.0 / @as(f32, @floatFromInt(n)) else 0;
}

//# yix-map styles.yss
