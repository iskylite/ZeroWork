const ui = @import("ui");

pub const root = ui.css(.{
    .width = .fill,
    .height = .fill,
    .gap = .space400,
    .padding = .space1000,
    .background = .bg_primary,
    .align_items = .center,
    .justify = .center,
});
pub const title = ui.css(.{ .font_size = .xxxl, .font_weight = .semibold, .color = .fg_primary });
pub const caption = ui.css(.{ .font_size = .lg, .color = .fg_secondary });
