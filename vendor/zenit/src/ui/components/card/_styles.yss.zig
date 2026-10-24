// GENERATED FILE, do not edit: generated from styles.yss; after editing the source run `zig build gen-yix` (yix-lsp regenerates it on save).
//! Card styles: appearance = variant (default / outlined / elevated) x selected x hover-responsive;
//! all values reference tokens.
//! View in card.yix; CardVariant is public API defined in mod.zig.
const ui = @import("../../ui.zig");

/// Card root: when selected, 2px accent border and no hover highlight; hover highlight changes
/// border color for outlined, background for others.
/// Background and border color changes via 120ms transition.
pub const Card = ui.cva(.{ .base = .{ .direction = .column, .background = ui.tokenRef(.color, "bg-primary"), .corner_radius = 6, .transition = ui.transition("background 120ms ease-out, border-color 120ms ease-out"), }, .variants = .{ .kind = .{ .default = .{ .border_width = 1, .border_color = ui.tokenRef(.color, "border"), }, .outlined = .{ .border_width = 1, .border_color = ui.tokenRef(.color, "border-strong"), }, .elevated = .{ .shadow = ui.tokenRef(.shadow, "md"), }, }, .selected = .{ .false = .{ }, .true = .{ .border_width = 2, .border_color = ui.tokenRef(.color, "accent"), }, }, .hoverable = .{ .false = .{ }, .true = .{ }, }, }, .defaults = .{ .kind = .default, .selected = false, .hoverable = false, }, .compound = .{ .{ .when = .{ .hoverable = true, .selected = false, .kind = .default, }, .style = .{ ._hover = .{ .background = ui.tokenRef(.color, "bg-hover"), }, } }, .{ .when = .{ .hoverable = true, .selected = false, .kind = .elevated, }, .style = .{ ._hover = .{ .background = ui.tokenRef(.color, "bg-hover"), }, } }, .{ .when = .{ .hoverable = true, .selected = false, .kind = .outlined, }, .style = .{ ._hover = .{ .border_color = ui.tokenRef(.color, "accent"), }, } }, }, });

/// Shrink to content when size not specified
pub const size = ui.paramStyle(struct { width: ?f32, height: ?f32, pub const declared = &[_][]const u8{ "width", "height", }; pub fn resolve(args: @This(), t: *const ui.theme.Values) ui.BoxStyle { return ui.boxFrom(.{ .width = ui.orElse(args.width, .fit), .height = ui.orElse(args.height, .fit), }, t); } });

pub const header = ui.css(.{ .direction = .column, .gap = 4, .padding = 12, });
pub const title_row = ui.css(.{ .height = 18, });
pub const title = ui.css(.{ .color = ui.tokenRef(.color, "fg-primary"), .font_size = 14, .font_weight = 600, });
pub const subtitle_row = ui.css(.{ .height = 16, });
pub const subtitle = ui.css(.{ .color = ui.tokenRef(.color, "fg-secondary"), .font_size = 12, });

/// Content area: children go here; when padded = false, flush to edges
pub const Body = ui.cva(.{ .base = .{ .width = .{ .grow = .{} }, .direction = .column, }, .variants = .{ .padded = .{ .false = .{ }, .true = .{ .padding = 12, }, }, }, .defaults = .{ .padded = true, }, });

//# yix-map styles.yss
