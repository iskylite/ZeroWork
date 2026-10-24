// GENERATED FILE, do not edit: generated from review_style.yss; after editing the source run `zig build gen-yix` (yix-lsp regenerates it on save).
const ui = @import("ui");
const Flag = bool;
const Width = ?f32;

pub const aliased = ui.paramStyle(struct { enabled: Flag, width: Width, pub const declared = &[_][]const u8{ "width", "gap", }; pub fn resolve(args: @This(), t: *const ui.theme.Values) ui.BoxStyle { var out = ui.boxFrom(.{ .width = ui.orElse(args.width, .fit), }, t); if (args.enabled) out = out.merge(ui.boxFrom(.{ .gap = 3, }, t)); return out; } });

//# yix-map review_style.yss
