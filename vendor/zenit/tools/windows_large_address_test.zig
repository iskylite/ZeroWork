const std = @import("std");
const enable = @import("windows_large_address.zig").enableLargeAddressAware;
fn image() [1024]u8 {
    var bytes: [1024]u8 = @splat(0);
    bytes[0..2].* = .{ 'M', 'Z' };
    std.mem.writeInt(u32, bytes[0x3c..0x40], 128, .little);
    bytes[128..132].* = .{ 'P', 'E', 0, 0 };
    std.mem.writeInt(u16, bytes[132..134], 0x14c, .little);
    std.mem.writeInt(u16, bytes[134..136], 1, .little);
    std.mem.writeInt(u16, bytes[148..150], 224, .little);
    std.mem.writeInt(u16, bytes[150..152], 0x102, .little);
    std.mem.writeInt(u16, bytes[152..154], 0x10b, .little);
    std.mem.writeInt(u32, bytes[244..248], 16, .little);
    std.mem.writeInt(u32, bytes[392..396], 128, .little);
    std.mem.writeInt(u32, bytes[396..400], 512, .little);
    @memset(bytes[512..640], 0xa5);
    return bytes;
}
test "large address flag preserves machine, image, sections and unrelated characteristics" {
    var bytes = image();
    const original = bytes;
    try enable(&bytes);
    for (bytes, original, 0..) |actual, expected, i| try std.testing.expectEqual(if (i == 150) expected | 0x20 else expected, actual);
    const once = bytes;
    try enable(&bytes);
    try std.testing.expectEqualSlices(u8, &once, &bytes);
}
test "invalid and signed images are rejected without mutation" {
    var wrong = image();
    std.mem.writeInt(u16, wrong[132..134], 0x8664, .little);
    const original = wrong;
    try std.testing.expectError(error.NotX86Executable, enable(&wrong));
    try std.testing.expectEqualSlices(u8, &original, &wrong);
    var signed = image();
    std.mem.writeInt(u32, signed[280..284], 700, .little);
    std.mem.writeInt(u32, signed[284..288], 100, .little);
    const saved = signed;
    try std.testing.expectError(error.SignedExecutable, enable(&signed));
    try std.testing.expectEqualSlices(u8, &saved, &signed);
    var dll = image();
    std.mem.writeInt(u16, dll[150..152], 0x2102, .little);
    try std.testing.expectError(error.DllNotSupported, enable(&dll));
}
test "truncated headers, directories and section data are refused" {
    var bytes = image();
    try std.testing.expectError(error.TruncatedExecutable, enable(bytes[0..63]));
    try std.testing.expectError(error.TruncatedExecutable, enable(bytes[0..160]));
    try std.testing.expectError(error.TruncatedExecutable, enable(bytes[0..600]));
    std.mem.writeInt(u32, bytes[244..248], 17, .little);
    try std.testing.expectError(error.TruncatedDataDirectories, enable(&bytes));
}
