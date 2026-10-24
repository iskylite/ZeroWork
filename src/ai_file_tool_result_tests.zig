const std = @import("std");
const projection = @import("ui/ai_file_tool_result.zig");
const capture = @import("host/ai_remote_file_snapshot.zig");
fn metadata() capture.Metadata {
    const session: @import("host/identity.zig").SessionHandle = .{ .session_id = @fromBackingInt(101), .generation = 7 };
    return .{ .owner = .{ .session = 101 }, .source = session, .source_revision = 3, .operation = .{ .owner = .{ .session = session }, .operation_id = 4 }, .requested_path = "/log/file with 'quotes' $()", .actual_path = "/log/actual", .captured_at_ms = 1234 };
}
test "file tool results retain source metadata while bounding text at a UTF8 boundary" {
    const allocator = std.testing.allocator;
    const bytes = try allocator.alloc(u8, 65536);
    defer allocator.free(bytes);
    for (0..21845) |index| @memcpy(bytes[index * 3 ..][0..3], "中");
    bytes[65535] = 'x';
    const value: capture.Value = .{ .metadata = metadata(), .body = .{ .text = .{ .bytes = bytes, .original_size = 65536, .read_bytes = 65536, .returned_bytes = 65536, .read_limit = 65536, .truncated = false } } };
    const result = try projection.project(allocator, value, 65536);
    defer result.deinit(allocator);
    try std.testing.expect(result.stdout.len + result.stderr.len <= 65536);
    try std.testing.expect(result.truncated and std.unicode.utf8ValidateSlice(result.stdout));
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, result.stderr, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(i64, @intCast(result.stdout.len)), parsed.value.object.get("returned_bytes").?.integer);
    try std.testing.expectEqual(@as(i64, 7), parsed.value.object.get("source").?.object.get("source").?.object.get("generation").?.integer);
    try std.testing.expectEqualStrings(value.metadata.requested_path, parsed.value.object.get("source").?.object.get("requested_path").?.string);
}
test "file tool result capacity errors never manufacture successful empty text" {
    const allocator = std.testing.allocator;
    const value: capture.Value = .{ .metadata = metadata(), .body = .{ .text = .{ .bytes = "hello", .original_size = 5, .read_bytes = 5, .returned_bytes = 5, .read_limit = 4096, .truncated = false } } };
    try std.testing.expectError(error.ToolOutputTooLarge, projection.project(allocator, value, 1));
    const result = try projection.project(allocator, value, 65536);
    defer result.deinit(allocator);
    try std.testing.expectEqualStrings("hello", result.stdout);
    try std.testing.expect(!result.truncated);
    var failed = value;
    failed.body = .{ .failure = .{ .remote = .permission_denied } };
    try std.testing.expectError(error.RemoteFileCaptureFailed, projection.project(allocator, failed, 65536));
}
