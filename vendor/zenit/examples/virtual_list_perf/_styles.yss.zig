// GENERATED FILE, do not edit: generated from styles.yss; after editing the source run `zig build gen-yix` (yix-lsp regenerates it on save).
//! virtual_list_perf styles
const ui = @import("ui");

pub const root = ui.css(.{ .width = .{ .grow = .{} }, .height = .{ .grow = .{} }, .background = ui.tokenRef(.color, "bg-primary"), });
pub const header = ui.css(.{ .width = .{ .grow = .{} }, .height = 48, .padding = .{ .y = 0, .x = 20 }, .align_items = .center, .background = ui.tokenRef(.color, "bg-secondary"), });
pub const header_text = ui.css(.{ .font_size = ui.tokenRef(.font_size, "lg"), .font_weight = 600, .color = ui.tokenRef(.color, "fg-primary"), });
pub const list = ui.css(.{ .width = .{ .grow = .{} }, .height = .{ .grow = .{} }, });
/// Zebra stripes: odd/even rows two background colors, switches theme
pub const Row = ui.cva(.{ .base = .{ .width = .fill, .height = .fill, .padding = .{ .y = ui.tokenRef(.space, "space200"), .x = ui.tokenRef(.space, "space400") }, .align_items = .center, .gap = ui.tokenRef(.space, "space300"), }, .variants = .{ .odd = .{ .false = .{ .background = ui.tokenRef(.color, "bg-secondary"), }, .true = .{ .background = ui.tokenRef(.color, "bg-primary"), }, }, }, .defaults = .{ .odd = false, }, });
pub const index = ui.css(.{ .font_size = ui.tokenRef(.font_size, "sm"), .font_weight = 500, .color = ui.tokenRef(.color, "fg-secondary"), });
pub const title = ui.css(.{ .font_size = ui.tokenRef(.font_size, "lg"), .color = ui.tokenRef(.color, "fg-primary"), });

//# yix-map styles.yss
