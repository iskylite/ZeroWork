// GENERATED FILE, do not edit: generated from styles.yss; after editing the source run `zig build gen-yix` (yix-lsp regenerates it on save).
//! Timeline styles: status determines dot / connector color and title color / font-weight; all
//! colors reference tokens.
//! View in timeline.yix; TimelineStatus is public API defined in mod.zig.
const ui = @import("../../ui.zig");

pub const dot_size: f32 = 12;

/// One row: indicator column (dot + connector), content column (title / description / time)
pub const Row = ui.sva(.{ .slots = .{ .dot, .line, .title, }, .base = .{ .dot = .{ .width = 12, .height = 12, .corner_radius = 6, }, .line = .{ .width = 2, .height = .{ .grow = .{} }, }, .title = .{ .font_size = ui.tokenRef(.font_size, "md"), }, }, .variants = .{ .status = .{ .completed = .{ .dot = .{ .background = ui.tokenRef(.color, "success"), }, .line = .{ .background = ui.tokenRef(.color, "success"), }, .title = .{ .color = ui.tokenRef(.color, "fg-primary"), .font_weight = 400, }, }, .active = .{ .dot = .{ .background = ui.tokenRef(.color, "accent"), }, .line = .{ .background = ui.tokenRef(.color, "border"), }, .title = .{ .color = ui.tokenRef(.color, "fg-primary"), .font_weight = 600, }, }, .pending = .{ .dot = .{ .background = ui.tokenRef(.color, "border"), }, .line = .{ .background = ui.tokenRef(.color, "border"), }, .title = .{ .color = ui.tokenRef(.color, "fg-secondary"), .font_weight = 400, }, }, }, }, .defaults = .{ .status = .pending, }, });

pub const list = ui.css(.{ .width = .{ .grow = .{} }, .height = .fit, .direction = .column, });
pub const row = ui.css(.{ .width = .fill, .height = .{ .fit = .{ .min = 48 } }, .gap = 12, });
pub const indicator = ui.css(.{ .width = 24, .height = .{ .grow = .{} }, .direction = .column, .align_items = .center, });

/// Content column; last row has no bottom padding
pub const Content = ui.cva(.{ .base = .{ .width = .fill, .height = .fit, .direction = .column, .gap = 2, .padding = .{ .top = 0, .right = 0, .bottom = 16, .left = 0 }, }, .variants = .{ .last = .{ .false = .{ }, .true = .{ .padding = 0, }, }, }, .defaults = .{ .last = false, }, });

pub const description = ui.css(.{ .color = ui.tokenRef(.color, "fg-secondary"), .font_size = ui.tokenRef(.font_size, "sm"), });
pub const time = ui.css(.{ .color = ui.tokenRef(.color, "fg-disabled"), .font_size = ui.tokenRef(.font_size, "xs"), });

//# yix-map styles.yss
