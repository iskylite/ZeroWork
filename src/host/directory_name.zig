//! One literal child component, never a path or shell expression.
const std = @import("std");

pub fn validate(name: []const u8) error{InvalidName}!void {
    if (name.len == 0 or name.len > 4096 or std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..") or
        std.mem.indexOfAny(u8, name, "/\\\x00") != null) return error.InvalidName;
}
