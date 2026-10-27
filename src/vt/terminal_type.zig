//! Built-in TERM declarations share one VT/rendering core. Compatibility
//! differences belong here only after a terminfo contract demonstrates them.
const std = @import("std");
pub const Type = enum { xterm_256color, xterm, vt100, custom };
pub const builtin = [_]struct { name: []const u8, kind: Type }{
    .{ .name = "xterm-256color", .kind = .xterm_256color },
    .{ .name = "xterm", .kind = .xterm },
    .{ .name = "vt100", .kind = .vt100 },
};
pub fn classify(name: []const u8) Type {
    for (builtin) |entry| if (std.mem.eql(u8, name, entry.name)) return entry.kind;
    return .custom;
}
/// ncurses vt100's F5–F10 aliases are old application-keypad sequences.
/// PF1–PF4, numeric keypad modes, modifiers and negotiated protocols continue
/// through Ghostty. Unknown/custom declarations never inherit this mapping.
pub fn legacyFunctionKey(kind: Type, event: @import("input_event.zig").KeyEvent) ?[]const u8 {
    if (kind != .vt100 or event.action == .release or event.composing or event.modifiers.shift or event.modifiers.control or event.modifiers.alt or event.modifiers.super) return null;
    return switch (event.key) {
        .f5 => "\x1bOt",
        .f6 => "\x1bOu",
        .f7 => "\x1bOv",
        .f8 => "\x1bOl",
        .f9 => "\x1bOw",
        .f10 => "\x1bOx",
        else => null,
    };
}
