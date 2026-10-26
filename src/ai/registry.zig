const std = @import("std");
const provider = @import("provider.zig");

pub const Kind = enum { anthropic, openai_compat, ollama };
pub const Config = struct { kind: Kind, endpoint: []const u8, model: []const u8, context_window: u32 = 8192 };
pub const Registry = struct {
    configs: []const Config,
    pub fn find(self: Registry, kind: Kind) ?Config {
        for (self.configs) |config| if (config.kind == kind) return config;
        return null;
    }
    pub fn maxOutput(self: Registry, kind: Kind, requested: u32) u32 {
        const config = self.find(kind) orelse return requested;
        return @min(requested, @max(config.context_window / 4, 1));
    }
};

pub fn effortName(kind: Kind, effort: provider.Effort) []const u8 {
    return switch (kind) {
        .anthropic => switch (effort) {
            .low => "0",
            .none => "none",
            .medium => "2000",
            .high => "8000",
            .xhigh, .max => "32000",
            .ultra => "ultra",
        },
        .openai_compat => switch (effort) {
            .low => "low",
            .medium => "medium",
            .high, .xhigh, .max => "high",
            .none => "none",
            .ultra => "ultra",
        },
        .ollama => "prompt-only",
    };
}

test "provider registry maps effort and output limits" {
    const configs = [_]Config{.{ .kind = .ollama, .endpoint = "local", .model = "llama" }};
    const registry = Registry{ .configs = &configs };
    try std.testing.expectEqualStrings("prompt-only", effortName(.ollama, .high));
    try std.testing.expectEqual(@as(u32, 2048), registry.maxOutput(.ollama, 4096));
}
