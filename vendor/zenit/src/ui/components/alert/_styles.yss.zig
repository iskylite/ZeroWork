// GENERATED FILE, do not edit: generated from styles.yss; after editing the source run `zig build gen-yix` (yix-lsp regenerates it on save).
//! Alert styles: variant determines accent; background and border are accent toward bg-primary
//! blend.
//! View in alert.yix; AlertVariant is public API defined in mod.zig.
const ui = @import("../../ui.zig");



/// root: full alert (with title, content top-aligned, else centered); accent: left accent bar.
pub const Alert = ui.sva(.{ .slots = .{ .root, .accent, }, .base = .{ .root = .{ .width = .fill, .height = .fit, .direction = .row, .padding = 12, .border_width = 1, .corner_radius = 8, }, .accent = .{ .width = 3, .height = 24, .corner_radius = 2, .align_self = .stretch, }, }, .variants = .{ .kind = .{ .info = .{ .root = .{ .background = ui.mix(ui.tokenRef(.color, "info"), ui.tokenRef(.color, "bg-primary"), 0.78), .border_color = ui.mix(ui.tokenRef(.color, "info"), ui.tokenRef(.color, "bg-primary"), 0.35), }, .accent = .{ .background = ui.tokenRef(.color, "info"), }, }, .success = .{ .root = .{ .background = ui.mix(ui.tokenRef(.color, "success"), ui.tokenRef(.color, "bg-primary"), 0.78), .border_color = ui.mix(ui.tokenRef(.color, "success"), ui.tokenRef(.color, "bg-primary"), 0.35), }, .accent = .{ .background = ui.tokenRef(.color, "success"), }, }, .warning = .{ .root = .{ .background = ui.mix(ui.tokenRef(.color, "warning"), ui.tokenRef(.color, "bg-primary"), 0.78), .border_color = ui.mix(ui.tokenRef(.color, "warning"), ui.tokenRef(.color, "bg-primary"), 0.35), }, .accent = .{ .background = ui.tokenRef(.color, "warning"), }, }, .@"error" = .{ .root = .{ .background = ui.mix(ui.tokenRef(.color, "danger"), ui.tokenRef(.color, "bg-primary"), 0.78), .border_color = ui.mix(ui.tokenRef(.color, "danger"), ui.tokenRef(.color, "bg-primary"), 0.35), }, .accent = .{ .background = ui.tokenRef(.color, "danger"), }, }, }, .titled = .{ .false = .{ .root = .{ .align_items = .center, }, }, .true = .{ .root = .{ .align_items = .start, }, }, }, }, .defaults = .{ .kind = .info, .titled = false, }, });

pub const content = ui.css(.{ .width = .fill, .height = .fit, .direction = .column, .gap = 4, .padding = .{ .y = 0, .x = 10 }, });
pub const title = ui.css(.{ .color = ui.tokenRef(.color, "fg-primary"), .font_size = ui.tokenRef(.font_size, "md"), .font_weight = 600, });
pub const message = ui.css(.{ .color = ui.tokenRef(.color, "fg-secondary"), .font_size = ui.tokenRef(.font_size, "sm"), });

/// Close button: hover floats bg-hover (150ms fade-in)
pub const close = ui.css(.{ .width = 20, .height = 20, .background = ui.Color.TRANSPARENT, .corner_radius = ui.tokenRef(.radius, "sm"), .justify = .center, .align_items = .center, .cursor = .pointer, ._hover = .{ .background = ui.tokenRef(.color, "bg-hover"), }, .transition = ui.transition("background 150ms ease-out"), });
pub const close_label = ui.css(.{ .color = ui.tokenRef(.color, "fg-secondary"), .font_size = 12, });
pub const close_icon = ui.css(.{ .width = 12, .height = 12, .icon_color = ui.tokenRef(.color, "fg-secondary"), });

//# yix-map styles.yss
