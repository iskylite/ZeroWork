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
pub const TabState = enum { normal, connecting, failed };

/// A separate neutral backplate preserves iSoft's dark source ink on any theme.
pub fn artworkBackdrop(icon_id: u32) ui.Color {
    return if (icon_id == @import("host_os_assets.zig").isoft.icon_id.?) ui.Color.WHITE else ui.Color.TRANSPARENT;
}

pub fn tabTint(state: TabState, asset_value: ui.SvgAsset) ui.Color {
    const theme = @import("app_theme.zig").current();
    return switch (state) {
        .failed => theme.danger_ink,
        .connecting => theme.fg_3,
        .normal => if (@import("host_os_assets.zig").index(asset_value.icon_id.?) != null) ui.Color.WHITE else if (asset_value.icon_id == resolve(.local).icon_id) ui.Color.hex(0xa1a1aa) else theme.fg_2,
    };
}

pub fn forOs(kind: Os) ?ui.SvgAsset {
    const os = @import("host_os_assets.zig");
    return switch (kind) {
        .unknown => null,
        .macos => @import("assets_generated.zig").local_apple,
        .windows => os.windows,
        .ubuntu => os.ubuntu,
        .rocky => os.rocky,
        .linux => os.linux,
        .debian => os.debian,
        .fedora => os.fedora,
        .arch => os.archlinux,
        .alpine => os.alpine,
        .freebsd => os.freebsd,
        .kylin, .neokylin, .openkylin, .ubuntukylin, .uos, .deepin, .openeuler, .euleros, .anolis, .opencloudos, .tencentos, .alinux, .loongnix, .aosc, .bclinux, .kylinsec, .nfs, .linx, .isoft, .redflag => domesticAsset(kind),
        inline .rhel, .centos, .almalinux, .oraclelinux, .sles, .opensuse, .amazonlinux, .nixos, .gentoo, .kali, .linuxmint, .manjaro, .openbsd, .netbsd => |value| @field(os, @tagName(value)),
    };
}
pub fn forConnection(source: @import("../host/plugin_registry.zig").Registry, protocol_id: []const u8, kind: Os, archived: bool) ui.SvgAsset {
    return forOs(kind) orelse forPlugin(source, protocol_id, archived);
}
pub fn setNode(node: *ui.Node, kind: Os) void {
    const selected = forOs(kind) orelse return;
    const tint = if (node.getIcon()) |old| old.tint else ui.Color.WHITE;
    node.setImage(null);
    node.setIcon(.{ .icon_id = selected.icon_id.?, .rep = selected.pickRep(14).?, .tint = tint });
    node.markRenderDirty();
}

test "OS icons take precedence over protocol and retain unknown fallback" {
    const std = @import("std");
    try std.testing.expectEqual(forOs(.ubuntu).?.icon_id, forConnection(.{}, "sftp", .ubuntu, false).icon_id);
    try std.testing.expectEqual(forOs(.windows).?.icon_id, forConnection(.{}, "ssh", .windows, false).icon_id);
    try std.testing.expectEqual(forPlugin(.{}, "ssh", false).icon_id, forConnection(.{}, "ssh", .unknown, false).icon_id);
}

/// Saved OS artwork uses source colours; protocol glyphs use theme ink.
/// Tab appearance is selected independently through tabTint.
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
        .kylin, .neokylin, .openkylin, .ubuntukylin, .uos, .deepin, .openeuler, .euleros, .anolis, .opencloudos, .tencentos, .alinux, .loongnix, .aosc, .bclinux, .kylinsec, .nfs, .linx, .isoft, .redflag => domesticAsset(kind),
        inline .rhel, .centos, .almalinux, .oraclelinux, .sles, .opensuse, .amazonlinux, .nixos, .gentoo, .kali, .linuxmint, .manjaro, .openbsd, .netbsd => |value| @field(os, @tagName(value)),
    };
}

fn domesticAsset(kind: Os) ui.SvgAsset {
    const os = @import("host_os_assets.zig");
    return switch (kind) {
        inline .kylin, .neokylin, .openkylin, .ubuntukylin, .uos, .deepin, .openeuler, .euleros, .anolis, .opencloudos, .tencentos, .alinux, .loongnix, .aosc, .bclinux, .kylinsec, .nfs, .linx, .isoft, .redflag => |value| @field(os, @tagName(value)),
        else => unreachable,
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
    const apple = if (node.getIcon()) |icon| icon.icon_id == resolve(.local).icon_id.? else false;
    const remote_screen = if (node.getIcon()) |icon| icon.icon_id == ui.icons.screen_share.icon_id.? else false;
    _ = node.setTint(if (artwork) ui.Color.WHITE else if (apple) tabTint(.normal, resolve(.local)) else if (remote_screen) @import("sidebar_styles.zig").kvmIconInk() else @import("app_theme.zig").current().fg_2);
}

test "saved host and tab OS artwork share source colours" {
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
    try std.testing.expectEqual(artwork.ubuntu.icon_id, forOs(.ubuntu).?.icon_id);
}

test "identified OS logos replace the Linux fallback in both host and tab artwork" {
    const std = @import("std");
    const artwork = @import("host_os_assets.zig");
    const kinds = [_]Os{ .kylin, .neokylin, .openkylin, .ubuntukylin, .uos, .deepin, .openeuler, .euleros, .anolis, .opencloudos, .tencentos, .alinux, .loongnix, .aosc, .bclinux, .kylinsec, .nfs, .linx, .isoft, .redflag, .rhel, .centos, .almalinux, .oraclelinux, .sles, .opensuse, .amazonlinux, .nixos, .gentoo, .kali, .linuxmint, .manjaro, .openbsd, .netbsd };
    for (kinds) |kind| {
        const host = forHost(.{}, "ssh", kind);
        try std.testing.expectEqual(host.icon_id, forOs(kind).?.icon_id);
        try std.testing.expectEqual(host.icon_id, forHost(.{}, "sftp", kind).icon_id);
        const pixels = artwork.pixels[artwork.index(host.icon_id.?).?];
        try std.testing.expectEqual(@as(usize, 72 * 72 * 4), pixels.len);
        try std.testing.expect(!std.mem.eql(u8, artwork.pixels[artwork.index(artwork.linux.icon_id.?).?], pixels));
    }
}

test "tab OS colour uses original artwork except connecting and failed states" {
    const std = @import("std");
    const theme = @import("app_theme.zig");
    const previous = theme.currentName();
    defer theme.select(previous);
    for ([_]theme.Name{ .dark, .light, .sauber }) |name| {
        theme.select(name);
        for ([_]Os{ .linux, .ubuntu, .kylin, .uos, .rhel, .centos, .almalinux, .oraclelinux, .sles, .opensuse, .amazonlinux, .nixos, .gentoo, .kali, .linuxmint, .manjaro, .openbsd, .netbsd }) |kind| {
            const logo = forOs(kind).?;
            try std.testing.expectEqual(ui.Color.WHITE, tabTint(.normal, logo));
            try std.testing.expectEqual(theme.current().danger_ink, tabTint(.failed, logo));
            try std.testing.expectEqual(theme.current().fg_3, tabTint(.connecting, logo));
            try std.testing.expectEqual(forHost(.{}, "ssh", kind).icon_id, logo.icon_id);
        }
    }
}
