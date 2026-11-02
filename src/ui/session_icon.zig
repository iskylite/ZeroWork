//! Shared OS-first icon selection for session tabs and saved connections.
const ui = @import("ui");
pub const Kind = enum { local, history, file, terminal };
pub fn resolve(kind: Kind) ui.SvgAsset {
    return switch (kind) {
        .local => @import("assets_generated.zig").local_apple,
        .history => ui.icons.history,
        .file => ui.icons.folder,
        .terminal => ui.icons.terminal,
    };
}
pub fn forTab(local: bool, archived: bool, has_terminal: bool) ui.SvgAsset {
    return resolve(if (local) .local else if (archived) .history else if (!has_terminal) .file else .terminal);
}

/// Resolve contributed assets without branching on provider identity.
/// Application assets participate in the same catalog as the UI icon set.
pub fn asset(name: []const u8) ui.SvgAsset {
    if (@import("std").mem.eql(u8, name, "local_apple")) return @import("assets_generated.zig").local_apple;
    return ui.icons.get(name) orelse ui.icons.plug;
}
pub fn forPlugin(source: @import("../host/plugin_registry.zig").Registry, protocol_id: []const u8, archived: bool) ui.SvgAsset {
    const manifest = source.find(protocol_id) orelse return if (archived) ui.icons.history else ui.icons.plug;
    return asset(if (archived) manifest.icons.archive else manifest.icons.tab);
}

pub const Os = @import("../proto/ssh/remote_os.zig").Kind;
pub fn forOs(kind: Os) ?ui.SvgAsset {
    const os = @import("session_os_assets.zig");
    return switch (kind) {
        .unknown => null,
        .macos => @import("assets_generated.zig").local_apple,
        .windows => os.windows,
        .ubuntu => os.ubuntu,
        .rocky => @import("rocky_os_asset.zig").rocky,
        .linux, .debian, .fedora, .arch, .alpine, .freebsd => os.linux,
    };
}
pub fn forConnection(source: @import("../host/plugin_registry.zig").Registry, protocol_id: []const u8, kind: Os, archived: bool) ui.SvgAsset {
    return forOs(kind) orelse forPlugin(source, protocol_id, archived);
}
pub fn setNode(node: *ui.Node, kind: Os) void {
    const selected = forOs(kind) orelse return;
    const old = node.getIcon() orelse return;
    node.setIcon(.{ .icon_id = selected.icon_id.?, .rep = selected.pickRep(14).?, .tint = old.tint });
    node.markRenderDirty();
}

test "OS icons take precedence over protocol and retain unknown fallback" {
    const std = @import("std");
    try std.testing.expectEqual(forOs(.ubuntu).?.icon_id, forConnection(.{}, "sftp", .ubuntu, false).icon_id);
    try std.testing.expectEqual(forOs(.windows).?.icon_id, forConnection(.{}, "ssh", .windows, false).icon_id);
    try std.testing.expectEqual(forPlugin(.{}, "ssh", false).icon_id, forConnection(.{}, "ssh", .unknown, false).icon_id);
}

/// Saved OS artwork uses source colours; protocol glyphs use theme ink.
/// Live tabs keep their existing status tint.
pub fn forHost(source: @import("../host/plugin_registry.zig").Registry, protocol_id: []const u8, kind: Os) ui.SvgAsset {
    if (@import("std").mem.eql(u8, protocol_id, "bmc_ikvm")) return ui.icons.screen_share;
    const os = @import("host_os_assets.zig");
    return switch (kind) {
        .ubuntu => os.ubuntu,
        .rocky => os.rocky,
        .debian => os.debian,
        .fedora => os.fedora,
        .arch => os.archlinux,
        .linux => os.linux,
        .alpine => os.alpine,
        .freebsd => os.freebsd,
        .windows => os.windows,
        .macos => forOs(kind).?,
        .unknown => if (@import("std").mem.eql(u8, protocol_id, "ssh") or @import("std").mem.eql(u8, protocol_id, "sftp")) os.linux else forPlugin(source, protocol_id, false),
    };
}
pub fn setHostNode(node: *ui.Node, source: @import("../host/plugin_registry.zig").Registry, protocol_id: []const u8, kind: Os) void {
    const selected = forHost(source, protocol_id, kind);
    node.setImage(null); // Replace an already-uploaded generic OS texture after discovery.
    node.setIcon(.{ .icon_id = selected.icon_id.?, .rep = selected.pickRep(18).?, .tint = ui.Color.WHITE });
    refreshHostTint(node);
    node.markRenderDirty();
}

/// Coloured host SVGs become images after upload; both forms retain source RGB.
pub fn refreshHostTint(node: *ui.Node) void {
    const artwork = if (node.getIcon()) |icon| @import("host_os_assets.zig").index(icon.icon_id) != null else node.getImage() != null;
    const remote_screen = if (node.getIcon()) |icon| icon.icon_id == ui.icons.screen_share.icon_id.? else false;
    _ = node.setTint(if (artwork) ui.Color.WHITE else if (remote_screen) @import("sidebar_styles.zig").kvmIconInk() else @import("app_theme.zig").current().fg_2);
}

test "saved host artwork has independent coloured assets without changing tab OS assets" {
    const std = @import("std");
    const artwork = @import("host_os_assets.zig");
    const kinds = [_]Os{ .ubuntu, .debian, .fedora, .arch, .alpine, .freebsd, .windows, .linux, .rocky };
    for (kinds, 0..) |kind, i| {
        const saved = forHost(.{}, "ssh", kind);
        const index = artwork.index(saved.icon_id.?).?;
        try std.testing.expectEqual(@as(usize, 72 * 72 * 4), artwork.pixels[index].len);
        for (kinds[0..i]) |previous| try std.testing.expect(forHost(.{}, "ssh", previous).icon_id != saved.icon_id);
    }
    try std.testing.expectEqual(artwork.linux.icon_id, forHost(.{}, "ssh", .unknown).icon_id);
    try std.testing.expectEqual(@import("session_os_assets.zig").ubuntu.icon_id, forOs(.ubuntu).?.icon_id);
}
