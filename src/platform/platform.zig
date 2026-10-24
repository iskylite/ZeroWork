const builtin = @import("builtin");

pub const minimum_macos_major = 14;
pub const supported_arch = .aarch64;

pub fn isSupportedBuildHost() bool {
    return builtin.os.tag == .macos and builtin.cpu.arch == supported_arch;
}

test "the supported production platform is Apple Silicon macOS" {
    const std = @import("std");
    try std.testing.expectEqual(@as(u8, 14), minimum_macos_major);
    try std.testing.expectEqual(std.Target.Cpu.Arch.aarch64, supported_arch);
}
