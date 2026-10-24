// GENERATED FILE, do not edit: generated from styles.yss; after editing the source run `zig build gen-yix` (yix-lsp regenerates it on save).
//! Breadcrumb styles: link (accent) / current page (primary text) / divider (disabled), all colors
//! reference tokens.
//! View in breadcrumb.yix; BreadcrumbItem is public API defined in mod.zig.
const ui = @import("../../ui.zig");

pub const root = ui.css(.{ .width = .fit, .height = .fit, .align_items = .center, .gap = 4, });
pub const crumb = ui.css(.{ .width = .fit, .height = .fit, .align_items = .center, .gap = 4, });

/// One level: last is current page (primary text, unclickable), earlier are links (accent, hand
/// cursor)
pub const Crumb = ui.sva(.{ .slots = .{ .link, .label, }, .base = .{ .link = .{ .width = .fit, .height = .fit, .padding = 2, }, .label = .{ .font_size = ui.tokenRef(.font_size, "sm"), }, }, .variants = .{ .current = .{ .false = .{ .link = .{ .cursor = .pointer, }, .label = .{ .color = ui.tokenRef(.color, "accent"), }, }, .true = .{ .label = .{ .color = ui.tokenRef(.color, "fg-primary"), }, }, }, }, .defaults = .{ .current = false, }, });

pub const separator = ui.css(.{ .color = ui.tokenRef(.color, "fg-disabled"), .font_size = ui.tokenRef(.font_size, "sm"), });

//# yix-map styles.yss
