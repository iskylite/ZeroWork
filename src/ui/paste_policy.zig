const std = @import("std");

pub const Policy = struct {
    confirm_multiline: bool = true,
    max_bytes: usize = 1024 * 1024,

    pub fn inspect(self: Policy, text: []const u8) Decision {
        if (text.len > self.max_bytes) return .{ .reject = .too_large };
        if (!std.unicode.utf8ValidateSlice(text)) return .{ .reject = .invalid_utf8 };
        if (std.mem.indexOf(u8, text, "\x1b[200~") != null or std.mem.indexOf(u8, text, "\x1b[201~") != null) return .{ .reject = .control_sequence };
        if (std.mem.indexOf(u8, text, "\x9b200~") != null or std.mem.indexOf(u8, text, "\x9b201~") != null or std.mem.indexOf(u8, text, "\xc2\x9b200~") != null or std.mem.indexOf(u8, text, "\xc2\x9b201~") != null) return .{ .reject = .control_sequence };
        if (std.mem.indexOfAny(u8, text, "\r\n") != null and self.confirm_multiline) return .{ .confirm = .multiline };
        return .safe;
    }
};

pub const Decision = union(enum) { safe, confirm: Reason, reject: Reason };
pub const Reason = enum { multiline, too_large, control_sequence, invalid_utf8 };

test "paste policy confirms multiline and rejects control injection" {
    const policy: Policy = .{};
    switch (policy.inspect("echo one\necho two")) {
        .confirm => |reason| try std.testing.expectEqual(Reason.multiline, reason),
        else => return error.UnexpectedDecision,
    }
    switch (policy.inspect("x\x1b[200~evil")) {
        .reject => |reason| try std.testing.expectEqual(Reason.control_sequence, reason),
        else => return error.UnexpectedDecision,
    }
    try std.testing.expectEqual(@as(Decision, .safe), policy.inspect("echo one"));
}

test "paste policy validates bytes and boundaries before multiline confirmation" {
    const policy: Policy = .{};
    try std.testing.expectEqual(Decision{ .reject = .control_sequence }, policy.inspect("one\n\x1b[201~two"));
    try std.testing.expectEqual(Decision{ .reject = .invalid_utf8 }, policy.inspect("one\n\xff"));
    try std.testing.expectEqual(Decision{ .reject = .control_sequence }, policy.inspect("one\n\xc2\x9b200~two"));
}
