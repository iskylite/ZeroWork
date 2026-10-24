//! The fixture reuses the host's Vanta editor rows and typography. The synthetic
//! raster deliberately has a fixed preview height inside the content slot.
const ui = @import("ui");
pub const host = @import("../../ui/wizard_styles.zig");
pub fn canvas() ui.Style {
    return .{ .width = .fill(), .height = .{ .px = ui.arb.px(320) }, .flex_shrink = 0 };
}
pub fn inputSlot() ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = ui.arb.px(32) }, .min_width = 0, .flex_shrink = 0 };
}
