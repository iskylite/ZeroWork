const std = @import("std");
const ssh = @import("proto/ssh/session.zig");

test "session native auth compiles actual connection flow without network" {
    const inactive: ssh.Library = .{ .active = false };
    try std.testing.expectError(error.LibraryNotInitialized, ssh.Session.connect(&inactive, .{
        .host = "unused",
        .user = "unused",
        .auth = .password_prompt,
        .source_owner = .{ .id = @fromBackingInt(1), .revision = 2 },
        .strict_host_key_checking = false,
    }));
}
