//! Platform capability policy: Linux devices currently own one Wayland surface.
const std = @import("std");

pub fn enabled(os: std.Target.Os.Tag, requested: bool) bool {
    return requested and os != .linux;
}

test "Linux shared GPU requests fall back before binding a device to another surface" {
    try std.testing.expect(!enabled(.linux, true));
    try std.testing.expect(!enabled(.linux, false));
    try std.testing.expect(enabled(.macos, true));
    try std.testing.expect(enabled(.windows, true));
    try std.testing.expect(!enabled(.windows, false));
}
