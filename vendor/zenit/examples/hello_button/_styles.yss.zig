// GENERATED FILE, do not edit: generated from styles.yss; after editing the source run `zig build gen-yix` (yix-lsp regenerates it on save).
//! JSON token reference + component recipe, separated from interface structure (view.yix).
//! Auto-replay on theme / variant change.
const ui = @import("ui");

pub const root = ui.css(.{ .width = .fill, .height = .fill, .direction = .column, .gap = ui.tokenRef(.space, "space400"), .padding = ui.tokenRef(.space, "space1000"), .background = ui.tokenRef(.color, "bg-primary"), .align_items = .center, .justify = .center, });
pub const title = ui.css(.{ .typography = ui.tokenRef(.typography, "counterTitle"), .color = ui.tokenRef(.color, "fg-primary"), });
pub const counter_label = ui.css(.{ .font_size = ui.tokenRef(.font_size, "lg"), .color = ui.tokenRef(.color, "fg-secondary"), });

/// Count panel: after clicked, switches to highlight
pub const Panel = ui.cva(.{ .base = .{ .padding = .{ .y = ui.tokenRef(.space, "space200"), .x = ui.tokenRef(.space, "space400") }, .corner_radius = ui.tokenRef(.radius, "md"), }, .variants = .{ .emphasis = .{ .neutral = .{ .background = ui.tokenRef(.color, "bg-secondary"), }, .highlight = .{ .background = ui.tokenRef(.color, "bg-tertiary"), .border_width = ui.tokenRef(.border_width, "thin"), .border_color = ui.tokenRef(.color, "accent"), }, }, }, .defaults = .{ .emphasis = .neutral, }, });
pub const PanelEmphasis = Panel.Dim(.emphasis);

//# yix-map styles.yss
