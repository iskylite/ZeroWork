const std = @import("std");

/// Colors are RGBA8888, matching the renderer contract in DESIGN 02 §7.
pub const Theme = struct {
    name: []const u8,
    bg: u32,
    fg: u32,
    accent: u32,
    selection: u32,
    cursor: u32,
    ansi: [16]u32,
    bright_bold_uses_bright: bool,
    gutter_fg: u32,
    gutter_bg: u32,
    overlay: OverlayTokens,

    pub const sauber: Theme = .{
        .name = "sauber",
        .bg = 0xECFFE5FF,
        .fg = 0x1345F6FF,
        .accent = 0x1345F6FF,
        .selection = 0xB3D7FFFF,
        .cursor = 0x000000FF,
        .ansi = .{
            0x0F172AFF, 0xDC4C3FFF, 0x10B981FF, 0xD49A0CFF,
            0x2563EBFF, 0xC241E0FF, 0x06B6D4FF, 0xD6E2F0FF,
            0x64748BFF, 0xDD7975FF, 0x3FCD76FF, 0xC6BB00FF,
            0xA7ABF2FF, 0xE17EE1FF, 0x048B8FFF, 0xA4801CFF,
        },
        .bright_bold_uses_bright = true,
        .gutter_fg = 0x64748BFF,
        .gutter_bg = 0xE3F6DEFF,
        .overlay = .{
            .bg = 0xF6FFF3F2,
            .border = 0x1345F638,
            .shadow = 0x0F172A24,
            .ai_idle = 0x1345F659,
            .ai_running = 0x06B6D4FF,
            .ai_success = 0x10B981FF,
            .ai_failure = 0xDC4C3FFF,
            .ai_confirmation = 0xD49A0CFF,
        },
    };
};

pub const OverlayTokens = struct {
    bg: u32,
    border: u32,
    shadow: u32,
    ai_idle: u32,
    ai_running: u32,
    ai_success: u32,
    ai_failure: u32,
    ai_confirmation: u32,
};

test "Sauber carries renderer and future overlay tokens" {
    try std.testing.expectEqualStrings("sauber", Theme.sauber.name);
    try std.testing.expectEqual(@as(u32, 0x1345F6FF), Theme.sauber.accent);
    try std.testing.expectEqual(@as(usize, 16), Theme.sauber.ansi.len);
    try std.testing.expect(Theme.sauber.overlay.bg != Theme.sauber.bg);
    try std.testing.expect(Theme.sauber.overlay.ai_confirmation != Theme.sauber.overlay.ai_failure);
}
