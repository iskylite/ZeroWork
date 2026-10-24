// GENERATED FILE, do not edit: generated from styles.yss; after editing the source run `zig build gen-yix` (yix-lsp regenerates it on save).
//! Modal styles: dialog panel, title bar, close button, body. Panel view in modal.yix, popover /
//! focus trap / animation in mod.zig.
const ui = @import("../../ui.zig");

/// Dialog panel: fixed width, grows with content up to max-height; default background bg-secondary.
/// Double-layer shadow: main theme shadow + large-extent ambient light soft shadow (simulates
/// extreme modal elevation, MD3 style).
pub const dialog = ui.paramStyle(struct { width: f32, max_height: f32, background: ?ui.Color = null, pub const declared = &[_][]const u8{ "width", "height", "background", "direction", "corner_radius", "shadows", }; pub fn resolve(args: @This(), t: *const ui.theme.Values) ui.BoxStyle { return ui.boxFrom(.{ .width = args.width, .height = .{ .fit = .{ .max = args.max_height } }, .background = ui.orElse(args.background, ui.tokenRef(.color, "bg-secondary")), .direction = .column, .corner_radius = 8, .shadows = .{ ui.tokenRef(.shadow, "lg"), .{ .offset_x = 0, .offset_y = 32, .blur = 80, .spread = 0, .color = ui.Color.rgba(0x00, 0x00, 0x00, 0x19) }, }, }, t); } });

/// Title bar: title + close button space-between
pub const header = ui.css(.{ .direction = .row, .justify = .space_between, .align_items = .center, .gap = 12, .padding = .{ .y = 12, .x = 16 }, .width = .{ .grow = .{} }, .border_width = 0, .border_color = ui.tokenRef(.color, "separator"), });
pub const title = ui.css(.{ .color = ui.tokenRef(.color, "fg-primary"), .font_size = 14, .font_weight = 600, .wrap = .word, });
/// Close button: 24x24
pub const close_button = ui.css(.{ .width = 24, .height = 24, .background = ui.Color.TRANSPARENT, .justify = .center, .align_items = .center, .corner_radius = 4, });
/// Text X fallback when no icon asset (24x24, same geometry as close button, no corner radius)
pub const close_glyph_box = ui.css(.{ .width = 24, .height = 24, .background = ui.Color.TRANSPARENT, .justify = .center, .align_items = .center, });
pub const close_glyph = ui.css(.{ .color = ui.tokenRef(.color, "fg-secondary"), .font_size = 14, });
pub const body = ui.css(.{ .direction = .column, .width = .{ .grow = .{} }, .height = .{ .grow = .{} }, .padding = 16, });
pub const close_icon = ui.css(.{ .width = 14, .height = 14, .icon_color = ui.tokenRef(.color, "fg-secondary"), });

//# yix-map styles.yss
