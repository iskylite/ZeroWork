// GENERATED FILE, do not edit: generated from styles.yss; after editing the source run `zig build gen-yix` (yix-lsp regenerates it on save).
//! Badge / StatusBadge styling: color, size, spacing, font all reference tokens.
//! View in badge.yix; BadgeStatus / BadgeSize are public API, defined in mod.zig.
const ui = @import("../../ui.zig");

/// Badge: root is capsule (pill, corner full), label is text inside. status
/// determines bg and text color, size determines height / padding / font, dot
/// shrinks root to 8x8 dot.
pub const Badge = ui.sva(.{ .slots = .{ .root, .label, }, .base = .{ .root = .{ .width = .fit, .justify = .center, .align_items = .center, .corner_radius = ui.tokenRef(.radius, "full"), }, .label = .{ .font_weight = 600, }, }, .variants = .{ .status = .{ .info = .{ .root = .{ .background = ui.tokenRef(.color, "accent"), }, .label = .{ .color = ui.tokenRef(.color, "button-primary-fg"), }, }, .success = .{ .root = .{ .background = ui.tokenRef(.color, "success"), }, .label = .{ .color = ui.tokenRef(.color, "button-primary-fg"), }, }, .warning = .{ .root = .{ .background = ui.tokenRef(.color, "warning"), }, .label = .{ .color = ui.tokenRef(.color, "button-primary-fg"), }, }, .@"error" = .{ .root = .{ .background = ui.tokenRef(.color, "danger"), }, .label = .{ .color = ui.Color.hex(0xffffff), }, }, }, .size = .{ .sm = .{ .root = .{ .height = ui.tokenRef(.size, "md"), .padding = .{ .y = ui.tokenRef(.space, "space50"), .x = ui.tokenRef(.space, "space150") }, }, .label = .{ .font_size = 10, }, }, .md = .{ .root = .{ .height = ui.tokenRef(.size, "lg"), .padding = .{ .y = ui.tokenRef(.space, "space50"), .x = ui.tokenRef(.space, "space200") }, }, .label = .{ .font_size = ui.tokenRef(.font_size, "xs"), }, }, }, .dot = .{ .false = .{ }, .true = .{ }, }, }, .defaults = .{ .status = .info, .size = .md, .dot = false, }, .compound = .{ .{ .when = .{ .dot = true, }, .style = .{ .root = .{ .width = 8, .height = 8, .padding = 0, .corner_radius = 4, }, } }, }, });

/// StatusBadge: status dot + label.
pub const status_row = ui.css(.{ .width = .fit, .height = .fit, .direction = .row, .gap = 6, .align_items = .center, });

/// 8x8 status dot (same size as Badge dot mode), bg color same as Badge status
pub const StatusDot = ui.cva(.{ .base = .{ .width = 8, .height = 8, .padding = 0, .corner_radius = 4, }, .variants = .{ .status = .{ .info = .{ .background = ui.tokenRef(.color, "accent"), }, .success = .{ .background = ui.tokenRef(.color, "success"), }, .warning = .{ .background = ui.tokenRef(.color, "warning"), }, .@"error" = .{ .background = ui.tokenRef(.color, "danger"), }, }, }, .defaults = .{ .status = .info, }, });

pub const status_label = ui.css(.{ .color = ui.tokenRef(.color, "fg-primary"), .font_size = 12, });

//# yix-map styles.yss
