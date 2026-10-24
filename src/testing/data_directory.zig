//! Only reachable from unit tests or the explicit test-mode executable.
const std = @import("std");
pub fn override() ?[]const u8 {
    if (!@import("../platform/runtime_mode.zig").automation) return null;
    const value = std.c.getenv("ZEROWORK_DATA_DIR") orelse return null;
    return std.mem.span(value);
}
