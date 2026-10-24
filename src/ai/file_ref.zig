const std = @import("std");
pub const Ref = struct { path: []const u8, head: []const u8, truncated: bool = false };
pub fn clampHead(bytes: []const u8, max_bytes: usize) Ref {
    return .{ .path = "", .head = bytes[0..@min(bytes.len, max_bytes)], .truncated = bytes.len > max_bytes };
}
test "file reference clamps remote header only" {
    const ref = clampHead("abcdef", 4);
    try std.testing.expectEqualStrings("abcd", ref.head);
    try std.testing.expect(ref.truncated);
}
