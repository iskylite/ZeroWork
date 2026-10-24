const std = @import("std");
const m = @import("token_model");
const emit = @import("token_emitter");

test "empty provider output parses and includes fixed category types" {
    var doc: m.Document = .{ .arena = std.heap.ArenaAllocator.init(std.testing.allocator), .modes = &.{.{ .name = "light", .scheme = .light, .fallback = null, .values = &.{} }} };
    defer doc.deinit();
    const output = try emit.generate(std.testing.allocator, &doc);
    defer std.testing.allocator.free(output);
    const z = try std.testing.allocator.dupeSentinel(u8, output, 0);
    defer std.testing.allocator.free(z);
    var ast = try std.zig.Ast.parse(std.testing.allocator, z, .{});
    defer ast.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), ast.errors.len);
    try std.testing.expect(std.mem.indexOf(u8, output, "pub const refs = struct") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "_ = t;") != null);
}
test "invalid documents cannot generate" {
    var doc: m.Document = .{ .arena = std.heap.ArenaAllocator.init(std.testing.allocator), .diagnostic = .{ .offset = 0, .pointer = "", .message = "invalid" } };
    defer doc.deinit();
    try std.testing.expectError(error.InvalidDocument, emit.generate(std.testing.allocator, &doc));
}
