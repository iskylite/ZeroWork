//! Input / Textarea style layer
//!
//! Error state uses the ConditionalStyle `invalid` condition: resolve chain
//! (base <- hover <- focus <- invalid) makes the error border beat hover/focus
//! (error suppresses interaction-state border changes).
//! Edit logic (cursor/IME/scroll) is not here; style only declares color + text style.
const core = @import("../../core.zig");
const theme = core.theme;
const Color = core.Color;
const ConditionalStyle = core.ConditionalStyle;

// ============================================================================
// Border color, single source of truth
// ============================================================================

/// Input resting border: danger > has_value border_strong > empty input_border.
/// (TextInputState.restingBorderColor delegates here.)
pub fn restingBorderColor(t: *const theme.ThemeTokens, has_error: bool, has_value: bool) Color {
    if (t.tokens.color.input_border.a == 0) return Color.TRANSPARENT;
    if (has_error) return t.tokens.color.danger;
    return if (has_value) t.tokens.color.border_strong else t.tokens.color.input_border;
}

/// Border conditional style: resting caller-provided (Input vs Textarea differ,
/// Input picks border_strong/input_border by value, Textarea always input_border).
pub fn borderConditional(t: *const theme.ThemeTokens, resting: Color) ConditionalStyle {
    return .{
        .base = .{ .border_color = resting },
        .hover = .{ .border_color = t.tokens.color.border_focus },
        .focus = .{ .border_color = t.tokens.color.border_focus },
        .invalid = .{ .border_color = if (t.tokens.color.input_border.a == 0) Color.TRANSPARENT else t.tokens.color.danger },
    };
}

/// Interactive border color: hover/focus -> accent, invalid beats all interaction.
pub fn borderColor(t: *const theme.ThemeTokens, resting: Color, hovered: bool, focused: bool, has_error: bool) Color {
    const resolved = borderConditional(t, resting).resolve(.{
        .is_hovered = hovered,
        .is_focused = focused,
        .is_invalid = has_error,
    });
    // Each condition state declares border_color, always has value
    return resolved.border_color.?;
}

/// Hover border effect gate (Input and Textarea shared: suppress hover color when
/// focused or error; focus/error border takes priority).
pub fn hoverBorderApplies(focused: bool, has_error: bool) bool {
    return !focused and !has_error;
}

// ============================================================================
// Text and icon color
// ============================================================================

/// Display text color: error > has_content fg_primary > placeholder (can be overridden by props)
pub fn displayTextColor(t: *const theme.ThemeTokens, has_error: bool, has_content: bool, placeholder_color: ?Color) Color {
    if (has_error) return t.tokens.color.danger;
    if (has_content) return t.tokens.color.fg_primary;
    return placeholder_color orelse t.tokens.color.fg_secondary;
}

/// leading/append icon tint: error -> danger, else weak tertiary
pub fn iconTintColor(t: *const theme.ThemeTokens, has_error: bool) Color {
    return if (has_error) t.tokens.color.danger else t.tokens.color.fg_tertiary;
}

/// Input label text
pub fn labelTextStyle(t: *const theme.ThemeTokens) core.TextStyle {
    return .{ .color = t.tokens.color.fg_primary, .font_size = 14, .font_weight = 500 };
}

/// Required asterisk (content "*")
pub fn requiredMarkStyle(t: *const theme.ThemeTokens) core.TextStyle {
    return .{ .color = t.tokens.color.danger, .font_size = 14, .font_weight = 500 };
}

/// Input helper/error text
pub fn helperTextStyle(t: *const theme.ThemeTokens, has_error: bool) core.TextStyle {
    return .{
        .color = if (has_error) t.tokens.color.danger else t.tokens.color.fg_secondary,
        .font_size = 12,
    };
}

/// append text (1 size smaller than input, min 11)
pub fn appendTextStyle(t: *const theme.ThemeTokens, input_font_size: f32) core.TextStyle {
    return .{
        .color = t.tokens.color.fg_tertiary,
        .font_size = @max(@as(f32, 11), input_font_size - 1),
    };
}

// ── Textarea-specific (size/resting differ from Input, preserve existing visual) ──

/// Textarea label text (12/fg_secondary, differs from Input 14/fg_primary)
pub fn textareaLabelStyle(t: *const theme.ThemeTokens) core.TextStyle {
    return .{ .color = t.tokens.color.fg_secondary, .font_size = 12 };
}

/// Textarea helper/error text (11pt)
pub fn textareaHelperStyle(t: *const theme.ThemeTokens, has_error: bool) core.TextStyle {
    return .{
        .color = if (has_error) t.tokens.color.danger else t.tokens.color.fg_secondary,
        .font_size = 11,
    };
}

/// Textarea background (disabled downgrade bg_secondary)
pub fn textareaBackground(t: *const theme.ThemeTokens, disabled: bool) Color {
    return if (disabled) t.tokens.color.bg_secondary else t.tokens.color.input_bg;
}

/// Textarea mount initial border: danger > disabled separator > border_strong.
/// Note: differs from unfocused resting (input_border) intentionally, preserve behavior.
pub fn textareaInitialBorderColor(t: *const theme.ThemeTokens, has_error: bool, disabled: bool) Color {
    if (t.tokens.color.input_border.a == 0) return Color.TRANSPARENT;
    if (has_error) return t.tokens.color.danger;
    if (disabled) return t.tokens.color.separator;
    return t.tokens.color.border_strong;
}

// ============================================================================
// Overlay / effect color
// ============================================================================

/// Pick overflow fade intensity by input background brightness: dark bg needs darker
/// inner shadow to show (light bg same alpha blurs gray edge).
pub fn innerShadowAlpha(t: *const theme.ThemeTokens) u8 {
    return if (t.tokens.color.input_bg.r <= 64 and t.tokens.color.input_bg.g <= 64 and t.tokens.color.input_bg.b <= 64) 90 else 44;
}

/// Overflow fade color (black + brightness-adaptive alpha)
pub fn overflowFadeColor(t: *const theme.ThemeTokens) Color {
    return Color.rgba(0, 0, 0, innerShadowAlpha(t));
}

/// IME preedit underline (accent high opacity)
pub fn imePreeditUnderlineColor(t: *const theme.ThemeTokens) Color {
    return Color.rgba(t.tokens.color.accent.r, t.tokens.color.accent.g, t.tokens.color.accent.b, 220);
}

/// IME highlight / preedit selection background (accent semi-transparent)
pub fn imeHighlightColor(t: *const theme.ThemeTokens) Color {
    return Color.rgba(t.tokens.color.accent.r, t.tokens.color.accent.g, t.tokens.color.accent.b, 64);
}
