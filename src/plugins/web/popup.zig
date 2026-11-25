//! Pure helpers shared by the web runtime, native popup bridge and renderer.
//! Native window ownership stays in macos_web_surface.m.
const std = @import("std");
const config = @import("config.zig");

/// Mirror of zw_max_popups_per_session in macos_web_surface.m.
pub const max_popups: usize = 8;

/// Badge text shown in the native popup top bar. The connection name is the
/// user-facing asset name (or "Manual web" for ad-hoc connections).
pub fn ownerLabel(allocator: std.mem.Allocator, name: []const u8, mode: config.RouteMode, hop_count: usize) ![]u8 {
    const path: []const u8 = switch (mode) {
        .direct => "直接连接",
        .ssh => if (hop_count > 1) "SSH 代理 · 跳板链路" else "SSH 代理",
    };
    return std.fmt.allocPrint(allocator, "关联自: {s} · {s}", .{ name, path });
}

test "popup owner label names the parent route" {
    const a = std.testing.allocator;
    const direct = try ownerLabel(a, "BMC 控制台", .direct, 0);
    defer a.free(direct);
    try std.testing.expectEqualStrings("关联自: BMC 控制台 · 直接连接", direct);

    const proxied = try ownerLabel(a, "BMC 控制台", .ssh, 1);
    defer a.free(proxied);
    try std.testing.expectEqualStrings("关联自: BMC 控制台 · SSH 代理", proxied);

    const multi = try ownerLabel(a, "BMC 控制台", .ssh, 2);
    defer a.free(multi);
    try std.testing.expectEqualStrings("关联自: BMC 控制台 · SSH 代理 · 跳板链路", multi);
}

test "popup limit is bounded and matches the native contract" {
    try std.testing.expectEqual(@as(usize, 8), max_popups);
}
