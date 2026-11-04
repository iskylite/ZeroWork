//! Metadata/theme projection for the dedicated native secure collector.
//! The Zenit Input is deliberately not used: its general editing pipeline has
//! retained undo/IME/model snapshots. No secret ever belongs to a Zenit node.
const ui = @import("ui");
const theme = @import("app_theme.zig");
const controller = @import("ai_host_secret_controller.zig");
pub fn palette() controller.Theme {
    const colors = theme.current();
    // This separate native security window owns an opaque window background;
    // it is not a nested L4 card in the main window.
    return .{ .background = rgba(colors.overlay.withAlpha(255)), .foreground = rgba(colors.fg_1.withAlpha(255)), .secondary = rgba(colors.fg_2.withAlpha(255)), .well = rgba(theme.popupInset()), .accent = rgba(colors.action_accent) };
}
fn rgba(color: ui.Color) u32 {
    return (@as(u32, color.r) << 24) | (@as(u32, color.g) << 16) | (@as(u32, color.b) << 8) | color.a;
}
pub fn statusText(state: controller.State) []const u8 {
    return switch (state) {
        .awaiting_host_secret => "等待安全输入",
        .secret_submitted => "安全输入已处理",
        .cancelled => "安全输入已取消",
    };
}
