const std = @import("std");
pub const Kind = enum { provider_missing, network, timeout, unsupported_effort, context_truncated, session_disconnected, remote_command };
pub const Info = struct { kind: Kind, message: []const u8, retryable: bool = false, turn_id: u64 = 0 };
pub fn retryable(kind: Kind) bool {
    return switch (kind) {
        .network, .timeout => true,
        else => false,
    };
}
test "AI errors classify retryable provider failures" {
    try std.testing.expect(retryable(.network));
    try std.testing.expect(!retryable(.provider_missing));
}
