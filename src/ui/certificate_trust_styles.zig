//! docs/UI_V3/kvm/certificate-trust.html. Shared SSH authentication geometry
//! and color roles; the wider surface keeps a full SHA-256 on one line.
const ui = @import("ui");
pub const shared = @import("auth_challenge_styles.zig");
pub const width: f32 = 560;
pub const height: f32 = 680;

pub fn root() ui.BoxStyle {
    return .{ .width = .fill(), .height = .fill(), .direction = .column, .gap = 0, .padding = .{}, .min_height = 0, .background = ui.Color.TRANSPARENT };
}
pub fn text(size: f32, weight: u16, mono: bool) ui.TextStyle {
    var result = shared.text(size, weight, mono);
    result.line_height = (if (size >= 13) @as(f32, 20) else if (size >= 12) @as(f32, 18) else @as(f32, 16)) / size;
    return result;
}
pub fn value(mono: bool) ui.TextStyle {
    var result = text(if (mono) 10 else 11, 400, mono);
    result.color = shared.theme.current().fg_1;
    result.selectable = true;
    return result;
}
pub fn notice(changed: bool) ui.BoxStyle {
    var result = shared.well();
    const color = if (changed) shared.theme.current().danger else shared.theme.current().warn;
    result.background = color.withAlpha(23);
    result.padding = ui.Padding.all(12);
    return result;
}
pub fn metadata() ui.BoxStyle {
    var result = shared.well();
    result.gap = 6;
    return result;
}
pub fn metadataRow() ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .fit = .{} }, .direction = .row, .gap = 10, .align_items = .start, .flex_shrink = 0, .min_width = 0 };
}
pub fn metadataLabel() ui.BoxStyle {
    return .{ .width = .{ .px = 64 }, .height = .{ .fit = .{} }, .flex_shrink = 0 };
}
