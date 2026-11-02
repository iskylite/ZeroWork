//! Component state colors are part of the theme, never per-page color fixes.
//! Builtins and imported palettes use the same derivation and contrast policy.
//! scripts/sync_theme_states.mjs publishes the identical roles to editable HTML.
const std = @import("std");
const ui = @import("ui");

pub const text_min: f64 = 4.5;
pub const state_min: f64 = 1.12;
pub const focus_min: f64 = 1.15;
pub const hover_amount: f32 = 0.09;
pub const pressed_amount: f32 = 0.18;
pub const graphic_min: f64 = 3.0;

pub const Palette = struct {
    control: ui.Color,
    action: ui.Color,
    disabled: ui.Color,
    hover: ui.Color,
    pressed: ui.Color,
    focus: ui.Color,
    selected: ui.Color,
    selected_hover: ui.Color,
    drop_target: ui.Color,
    primary: ui.Color,
    primary_to: ui.Color,
    primary_hover: ui.Color,
    primary_hover_to: ui.Color,
    primary_pressed: ui.Color,
    primary_pressed_to: ui.Color,
    primary_ink: ui.Color,
    danger: ui.Color,
    danger_hover: ui.Color,
    danger_pressed: ui.Color,
    danger_ink: ui.Color,
    tag: ui.Color,
    tag_ok: ui.Color,
    tag_warn: ui.Color,
    tag_danger: ui.Color,
    error_focus: ui.Color,
    muted_ink: ui.Color,
    choice_off: ui.Color,
    choice_on: ui.Color,
    choice_ink: ui.Color,
    choice_disabled_off: ui.Color,
    choice_disabled_on: ui.Color,
    choice_disabled_ink: ui.Color,
    choice_thumb_off: ui.Color,
    choice_disabled_thumb_off: ui.Color,
    range_track: ui.Color,
    range_fill: ui.Color,
    range_hover: ui.Color,
    range_drag: ui.Color,
    range_thumb: ui.Color,
    range_disabled: ui.Color,
    range_disabled_thumb: ui.Color,
    progress_ok: ui.Color,
    progress_warn: ui.Color,
    progress_danger: ui.Color,
    feedback_info: ui.Color,
    feedback_ok: ui.Color,
    feedback_warn: ui.Color,
    feedback_danger: ui.Color,
    search_match: ui.Color,
    search_match_ink: ui.Color,
    search_current: ui.Color,
    search_current_ink: ui.Color,
};

pub fn derive(c: anytype) Palette {
    const overlay = c.overlay.withAlpha(255);
    const well = c.well.withAlpha(255);
    const blended = ui.Color.lerp(overlay, well, 0.3);
    const control = if (contrast(overlay, blended) >= 1.1) blended else well;
    const action = ui.Color.lerp(overlay, c.fg_2.withAlpha(255), 0.12);
    const disabled = separate(action, &.{control}, &.{c.fg_3}, state_min);
    const inks = [_]ui.Color{ c.fg_1, c.fg_2 };
    const selected_inks = [_]ui.Color{ c.fg_1, c.fg_2, c.fg_3, c.accent_ink };
    const hover = separate(c.hover.withAlpha(255), &.{ overlay, action }, &inks, state_min);
    const pressed = separate(hover, &.{hover}, &inks, state_min);
    const dark = @as(u32, c.app.r) * 299 + @as(u32, c.app.g) * 587 + @as(u32, c.app.b) * 114 < 128000;
    const seed = ui.Color.lerp(overlay, c.accent.withAlpha(255), if (dark) 0.16 else 0.10);
    const selected = separate(seed, &.{overlay}, &selected_inks, state_min);
    const focus = separate(seed, &.{control}, &inks, focus_min);
    const selected_hover = separate(selected, &.{selected}, &selected_inks, state_min);
    const drop_target = separate(ui.Color.lerp(overlay, c.accent.withAlpha(255), 0.28), &.{selected}, &inks, focus_min);
    const primary_ink = foreground(c.action_accent);
    const primary_pole = if (ui.Color.eql(primary_ink, ui.Color.WHITE)) ui.Color.BLACK else ui.Color.WHITE;
    const danger_ink = foreground(c.action_danger);
    const danger_pole = if (ui.Color.eql(danger_ink, ui.Color.WHITE)) ui.Color.BLACK else ui.Color.WHITE;
    const choice_off = separate(ui.Color.lerp(overlay, c.fg_2, 0.4), &.{ overlay, control, c.action_accent }, &.{}, 1.5);
    const choice_disabled_on = separate(ui.Color.lerp(c.action_accent, overlay, 0.55), &.{disabled}, &.{}, 1.5);
    const range_fill = separate(c.action_accent, &.{action}, &.{}, graphic_min);
    const range_hover = rangeStep(range_fill, action, range_fill);
    const range_drag = rangeStep(range_hover, action, range_hover);
    const range_disabled = separate(c.fg_3, &.{action}, &.{}, graphic_min);
    const feedback_info = readableTint(overlay, c.accent, c.accent_ink);
    const feedback_warn = readableTint(overlay, c.warn, c.warn_ink);
    const search_match = separate(feedback_warn, &.{c.terminal.withAlpha(255)}, &.{c.fg_1}, 1.5);
    const search_current = separate(c.action_accent, &.{ c.terminal.withAlpha(255), search_match }, &.{}, graphic_min);
    return .{
        .control = control,
        .action = action,
        .disabled = disabled,
        .hover = hover,
        .pressed = pressed,
        .focus = focus,
        .selected = selected,
        .selected_hover = selected_hover,
        .drop_target = drop_target,
        .primary = c.action_accent,
        .primary_to = c.action_accent_2,
        .primary_hover = ui.Color.lerp(c.action_accent, primary_pole, hover_amount),
        .primary_hover_to = ui.Color.lerp(c.action_accent_2, primary_pole, hover_amount),
        .primary_pressed = ui.Color.lerp(c.action_accent, primary_pole, pressed_amount),
        .primary_pressed_to = ui.Color.lerp(c.action_accent_2, primary_pole, pressed_amount),
        .primary_ink = primary_ink,
        .danger = c.action_danger,
        .danger_hover = ui.Color.lerp(c.action_danger, danger_pole, hover_amount),
        .danger_pressed = ui.Color.lerp(c.action_danger, danger_pole, pressed_amount),
        .danger_ink = danger_ink,
        .tag = control,
        .tag_ok = readableTint(overlay, c.ok, c.ok_ink),
        .tag_warn = readableTint(overlay, c.warn, c.warn_ink),
        .tag_danger = readableTint(overlay, c.danger, c.danger_ink),
        .error_focus = separate(readableTint(overlay, c.danger, c.danger_ink), &.{readableTint(overlay, c.danger, c.danger_ink)}, &.{c.danger_ink}, focus_min),
        .muted_ink = readableInk(c.fg_3, c.fg_1, &.{ hover, pressed, focus, selected, selected_hover, drop_target }),
        .choice_off = choice_off,
        .choice_on = c.action_accent,
        .choice_ink = primary_ink,
        .choice_disabled_off = disabled,
        .choice_disabled_on = choice_disabled_on,
        .choice_disabled_ink = foreground(choice_disabled_on),
        .choice_thumb_off = separate(overlay, &.{choice_off}, &.{}, graphic_min),
        .choice_disabled_thumb_off = foreground(disabled),
        .range_track = action,
        .range_fill = range_fill,
        .range_hover = range_hover,
        .range_drag = range_drag,
        .range_thumb = foreground(range_fill),
        .range_disabled = range_disabled,
        .range_disabled_thumb = foreground(range_disabled),
        .progress_ok = separate(c.ok, &.{action}, &.{}, graphic_min),
        .progress_warn = separate(c.warn, &.{action}, &.{}, graphic_min),
        .progress_danger = separate(c.danger, &.{action}, &.{}, graphic_min),
        .feedback_info = feedback_info,
        .feedback_ok = readableTint(overlay, c.ok, c.ok_ink),
        .feedback_warn = feedback_warn,
        .feedback_danger = readableTint(overlay, c.danger, c.danger_ink),
        .search_match = search_match,
        .search_match_ink = c.fg_1,
        .search_current = search_current,
        .search_current_ink = foreground(search_current),
    };
}

fn rangeStep(seed: ui.Color, track: ui.Color, previous: ui.Color) ui.Color {
    for (1..256) |step| {
        for ([_]ui.Color{ ui.Color.BLACK, ui.Color.WHITE }) |pole| {
            const candidate = ui.Color.lerp(seed, pole, @as(f32, @floatFromInt(step)) / 255);
            if (contrast(candidate, track) >= graphic_min and contrast(candidate, previous) >= state_min) return candidate;
        }
    }
    return seed;
}

fn readableTint(parent: ui.Color, tint: ui.Color, ink: ui.Color) ui.Color {
    const seed = ui.Color.lerp(parent, tint, 0.09);
    if (contrast(seed, ink) >= text_min) return seed;
    return separate(seed, &.{}, &.{ink}, 1);
}

fn readableInk(seed: ui.Color, primary: ui.Color, backgrounds: []const ui.Color) ui.Color {
    for (0..256) |step| {
        const candidate = ui.Color.lerp(seed, primary, @as(f32, @floatFromInt(step)) / 255);
        var readable = true;
        for (backgrounds) |background| if (contrast(candidate, background) < text_min) {
            readable = false;
            break;
        };
        if (readable) return candidate;
    }
    return primary;
}

/// Make the smallest RGB adjustment toward either pole that satisfies the
/// component's actual foreground and neighboring state. No theme-name branches.
fn separate(seed: ui.Color, references: []const ui.Color, inks: []const ui.Color, minimum: f64) ui.Color {
    if (passes(seed, references, inks, minimum)) return seed;
    for (1..256) |step| {
        const amount: f32 = @as(f32, @floatFromInt(step)) / 255;
        for ([_]ui.Color{ ui.Color.BLACK, ui.Color.WHITE }) |pole| {
            const candidate = ui.Color.lerp(seed, pole, amount);
            if (passes(candidate, references, inks, minimum)) return candidate;
        }
    }
    // Arbitrary imports can be internally contradictory. Preserve their hue;
    // builtin/theme acceptance below rejects unsatisfiable published palettes.
    return seed;
}
fn passes(color: ui.Color, references: []const ui.Color, inks: []const ui.Color, minimum: f64) bool {
    for (references) |reference| if (contrast(color, reference) < minimum) return false;
    for (inks) |ink| if (contrast(color, ink) < text_min) return false;
    return true;
}
pub fn foreground(background: ui.Color) ui.Color {
    return if (contrast(background, ui.Color.WHITE) >= text_min) ui.Color.WHITE else ui.Color.BLACK;
}
pub fn contrast(a: ui.Color, b: ui.Color) f64 {
    const x = luminance(a);
    const y = luminance(b);
    return (@max(x, y) + 0.05) / (@min(x, y) + 0.05);
}
fn luminance(c: ui.Color) f64 {
    var result: f64 = 0;
    inline for (.{ "r", "g", "b" }, .{ 0.2126, 0.7152, 0.0722 }) |channel, weight| {
        const value = @as(f64, @floatFromInt(@field(c, channel))) / 255;
        result += weight * (if (value <= 0.04045) value / 12.92 else std.math.pow(f64, (value + 0.055) / 1.055, 2.4));
    }
    return result;
}
