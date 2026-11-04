//! Fixed Alipay donation QR, decoded from the supplied payment code and
//! regenerated with error correction M. No network or runtime encoder needed.
const std = @import("std");
pub const hint = "支付宝扫码 · 捐献支持开发";
pub const modules = 33;
pub const quiet_zone = 4;
pub const extent = modules + 2 * quiet_zone;
pub const matrix = @embedFile("assets/donation-qr.txt");
pub const Slice = struct { offset: f32, scale: f32 };

pub fn dark(x: usize, y: usize) bool {
    return matrix[y * (modules + 1) + x] == '1';
}

pub fn scaleForWidth(width: f32) f32 {
    return std.math.clamp(@floor(width / extent), 1, 5);
}

pub fn isCommand(command: []const u8) bool {
    return std.ascii.eqlIgnoreCase(std.mem.trim(u8, command, " \t\r\n"), "@dots");
}
