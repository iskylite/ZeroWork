// GENERATED FILE, do not edit: generated from styles.yss; after editing the source run `zig build gen-yix` (yix-lsp regenerates it on save).
//! Menu styles: menu item recipe (danger variant + hover highlight + disabled state) and panel /
//! divider / inline layout.
//! View in menu.yix; popover, keyboard nav and selection pipeline in mod.zig.
const ui = @import("../../ui.zig");
const core = @import("../../core.zig");
const theme = core.theme;
const Color = core.Color;
const Padding = core.Padding;

/// Menu item: root (row, hover / keyboard virtual highlight use list-hover-bg), label (text), icon
/// (icon, color follows text).
/// lit is menu's current virtual highlight (pointer enter and keyboard move both write it); danger
/// is per-item kind; disabled overrides danger and highlight.
pub const MenuRow = ui.sva(.{ .slots = .{ .root, .label, .icon, }, .base = .{ .root = .{ .width = .{ .grow = .{} }, .height = 32, .direction = .row, .align_items = .center, .justify = .space_between, .padding = .{ .y = 0, .x = 10 }, .corner_radius = 3, .background = ui.Color.TRANSPARENT, }, .label = .{ .font_size = 13, .color = ui.tokenRef(.color, "fg-primary"), }, .icon = .{ .width = 16, .height = 16, .icon_color = ui.tokenRef(.color, "fg-primary"), }, }, .variants = .{ .danger = .{ .false = .{ }, .true = .{ .label = .{ .color = ui.tokenRef(.color, "danger"), }, .icon = .{ .icon_color = ui.tokenRef(.color, "danger"), }, }, }, .lit = .{ .false = .{ }, .true = .{ }, }, .disabled = .{ .false = .{ .root = .{ .cursor = .pointer, }, }, .true = .{ .label = .{ .color = ui.tokenRef(.color, "fg-disabled"), }, .icon = .{ .icon_color = ui.tokenRef(.color, "fg-disabled"), }, }, }, }, .defaults = .{ .danger = false, .lit = false, .disabled = false, }, .compound = .{ .{ .when = .{ .lit = true, .disabled = false, }, .style = .{ .root = .{ .background = ui.tokenRef(.color, "list-hover-bg"), }, } }, }, });

/// Item list in panel
pub const list = ui.css(.{ .width = .{ .grow = .{} }, .height = .fit, .direction = .column, .padding = 4, });

/// Divider outer: vertical padding, line itself 1px
pub const separator = ui.css(.{ .width = .{ .grow = .{} }, .height = .fit, .padding = .{ .y = 4, .x = 0 }, });
pub const separator_line = ui.css(.{ .width = .{ .grow = .{} }, .height = 1, .background = ui.tokenRef(.color, "separator"), });
pub const item_left = ui.css(.{ .width = .fit, .height = .fit, .direction = .row, .align_items = .center, .gap = 8, });
pub const shortcut = ui.css(.{ .color = ui.tokenRef(.color, "fg-disabled"), .font_size = 11, });

//# yix-map styles.yss
