//! Semantic JSON digest for lifecycle idempotency, separate from the raw wire
//! correlation hash. Object order/whitespace/escapes cannot create new effects.
const std = @import("std");
const Sha = std.crypto.hash.sha2.Sha256;

pub fn digest(allocator: std.mem.Allocator, value: std.json.Value) ![32]u8 {
    var hash = Sha.init(.{});
    try update(allocator, &hash, value, 0);
    return hash.finalResult();
}
fn bytes(hash: *Sha, tag: u8, text: []const u8) void {
    hash.update(&.{tag});
    var size: [8]u8 = undefined;
    std.mem.writeInt(u64, &size, text.len, .little);
    hash.update(&size);
    hash.update(text);
}
fn update(a: std.mem.Allocator, hash: *Sha, value: std.json.Value, depth: usize) !void {
    if (depth > 32) return error.ArgumentsTooDeep;
    switch (value) {
        .null => hash.update("n"),
        .bool => |v| hash.update(if (v) "t" else "f"),
        .string => |v| {
            if (!std.unicode.utf8ValidateSlice(v)) return error.InvalidUtf8;
            bytes(hash, 's', v);
        },
        .integer => |v| {
            var data: [8]u8 = undefined;
            std.mem.writeInt(i64, &data, v, .little);
            bytes(hash, 'i', &data);
        },
        .float => |v| {
            if (!std.math.isFinite(v)) return error.InvalidNumber;
            if (@trunc(v) == v and v >= -9223372036854775808.0 and v < 9223372036854775808.0) {
                try update(a, hash, .{ .integer = @intFromFloat(v) }, depth);
            } else {
                var data: [8]u8 = undefined;
                std.mem.writeInt(u64, &data, @bitCast(v), .little);
                bytes(hash, 'd', &data);
            }
        },
        // Do not round an out-of-range integer through f64 and accidentally
        // alias two distinct identities. Current lifecycle schemas bound numbers.
        .number_string => return error.UnsupportedJSONNumber,
        .array => |array| {
            var count: [8]u8 = undefined;
            std.mem.writeInt(u64, &count, array.items.len, .little);
            bytes(hash, 'a', &count);
            for (array.items) |item| try update(a, hash, item, depth + 1);
        },
        .object => |object| {
            if (object.count() > 4096) return error.TooManyArgumentFields;
            const keys = try a.dupe([]const u8, object.keys());
            defer a.free(keys);
            std.mem.sort([]const u8, keys, {}, struct {
                fn less(_: void, left: []const u8, right: []const u8) bool {
                    return std.mem.order(u8, left, right) == .lt;
                }
            }.less);
            var count: [8]u8 = undefined;
            std.mem.writeInt(u64, &count, keys.len, .little);
            bytes(hash, 'o', &count);
            for (keys) |key| {
                bytes(hash, 'k', key);
                try update(a, hash, object.get(key).?, depth + 1);
            }
        },
    }
}

test "canonical lifecycle arguments ignore object formatting but preserve actual effects" {
    const a = std.testing.allocator;
    const variants = [_][]const u8{ "{\"source\":\"s_1\",\"options\":{\"keep\":true,\"count\":1}}", " { \"options\": {\"count\":1.0,\"keep\":true},\"source\":\"s_\\u0031\" }" };
    var hashes: [2][32]u8 = undefined;
    for (variants, &hashes) |text, *hash| {
        const parsed = try std.json.parseFromSlice(std.json.Value, a, text, .{});
        defer parsed.deinit();
        hash.* = try digest(a, parsed.value);
    }
    try std.testing.expectEqualSlices(u8, &hashes[0], &hashes[1]);
    for ([_][]const u8{ "{\"source\":\"s_2\",\"options\":{\"keep\":true,\"count\":1}}", "{\"source\":\"s_1\",\"options\":{\"keep\":false,\"count\":1}}", "[1,2]", "[2,1]" }) |text| {
        const parsed = try std.json.parseFromSlice(std.json.Value, a, text, .{});
        defer parsed.deinit();
        const changed = try digest(a, parsed.value);
        try std.testing.expect(!std.mem.eql(u8, &changed, &hashes[0]));
    }
    try std.testing.expectError(error.InvalidNumber, digest(a, .{ .float = std.math.inf(f64) }));
    try std.testing.expectError(error.UnsupportedJSONNumber, digest(a, .{ .number_string = "184467440737095516160" }));
    const left = try std.json.parseFromSlice(std.json.Value, a, "[1,2]", .{});
    defer left.deinit();
    const right = try std.json.parseFromSlice(std.json.Value, a, "[2,1]", .{});
    defer right.deinit();
    const left_hash = try digest(a, left.value);
    const right_hash = try digest(a, right.value);
    try std.testing.expect(!std.mem.eql(u8, &left_hash, &right_hash));
}
