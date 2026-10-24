const std = @import("std");

/// API key 只在内存中短暂持有；释放时覆盖原缓冲区。
pub const Secret = struct {
    allocator: std.mem.Allocator,
    bytes: []u8,

    pub fn init(allocator: std.mem.Allocator, secret_bytes: []const u8) !Secret {
        if (secret_bytes.len == 0) return error.EmptySecret;
        return .{ .allocator = allocator, .bytes = try allocator.dupe(u8, secret_bytes) };
    }

    pub fn deinit(self: *Secret) void {
        @memset(self.bytes, 0);
        self.allocator.free(self.bytes);
        self.* = undefined;
    }

    pub fn value(self: Secret) []const u8 {
        return self.bytes;
    }
};

pub const Header = struct { name: []const u8, value: []const u8 };

pub fn authorization(style: @import("provider_http.zig").AuthStyle, secret: ?*const Secret, buffer: []u8) !?Header {
    return switch (style) {
        .none => null,
        .anthropic_key => .{ .name = "x-api-key", .value = (secret orelse return error.MissingApiKey).value() },
        .bearer => blk: {
            const key = (secret orelse return error.MissingApiKey).value();
            const rendered = try std.fmt.bufPrint(buffer, "Bearer {s}", .{key});
            break :blk .{ .name = "Authorization", .value = rendered };
        },
    };
}

test "authorization builds provider-specific headers" {
    var secret = try Secret.init(std.testing.allocator, "token");
    defer secret.deinit();
    var buffer: [64]u8 = undefined;
    const bearer = (try authorization(.bearer, &secret, &buffer)).?;
    try std.testing.expectEqualStrings("Authorization", bearer.name);
    try std.testing.expectEqualStrings("Bearer token", bearer.value);
    const anthropic = (try authorization(.anthropic_key, &secret, &buffer)).?;
    try std.testing.expectEqualStrings("x-api-key", anthropic.name);
}

test "authorization rejects missing keys" {
    var buffer: [16]u8 = undefined;
    try std.testing.expectError(error.MissingApiKey, authorization(.bearer, null, &buffer));
    try std.testing.expect((try authorization(.none, null, &buffer)) == null);
}
