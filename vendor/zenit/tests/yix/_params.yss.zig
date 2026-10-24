// GENERATED FILE, do not edit: generated from params.yss; after editing the source run `zig build gen-yix` (yix-lsp regenerates it on save).
//! Parameterized style runtime behavior (style name($p: T) { ... }): tests/yix/runtime_tests.zig
const ui = @import("ui");

pub const Tone = enum { calm, loud };

/// Optional parameter without fallback: when null, property not declared (fall to lower / default);
/// with ?? use fallback
pub const panel = ui.paramStyle(struct { width: ?f32, background: ?ui.Color, tone: Tone = .calm, pad: bool = false, pub const declared = &[_][]const u8{ "width", "background", "opacity", "padding", "flex_wrap", }; pub fn resolve(args: @This(), t: *const ui.theme.Values) ui.BoxStyle { var out = ui.boxFrom(.{ .width = ui.orElse(args.width, .fit), .background = args.background, }, t); if (args.tone == .loud) out = out.merge(ui.boxFrom(.{ .opacity = 0.5, }, t)); if (args.pad) out = out.merge(ui.boxFrom(.{ .padding = 4, .flex_wrap = .wrap, }, t)); return out; } });

/// Multi-layer shadow + token fallback (switches theme)
pub const framed = ui.paramStyle(struct { fill: ?ui.Color, pub const declared = &[_][]const u8{ "shadows", "background", }; pub fn resolve(args: @This(), t: *const ui.theme.Values) ui.BoxStyle { return ui.boxFrom(.{ .shadows = .{ ui.tokenRef(.shadow, "md"), .{ .offset_x = 0, .offset_y = 2, .blur = 4, .spread = 0, .color = ui.tokenRef(.color, "accent") }, }, .background = ui.orElse(args.fill, ui.tokenRef(.color, "bg-secondary")), }, t); } });

//# yix-map params.yss
