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

test "pagination file projection returns exact byte continuation after UTF8 and wire-budget trimming" {
    const a = std.testing.allocator;
    const bytes = try a.alloc(u8, 60000);
    defer a.free(bytes);
    for (0..10000) |index| @memcpy(bytes[index * 6 ..][0..6], "你\n\"\\");
    const value: capture.Value = .{ .metadata = metadata(), .body = .{ .text = .{ .bytes = bytes, .offset = 123, .source_version = 0xabcd, .original_size = 100000, .read_bytes = bytes.len + 1, .returned_bytes = bytes.len, .read_limit = 60000, .truncated = true } } };
    const result = try projection.project(a, value, 65536);
    defer result.deinit(a);
    const encoded = try std.json.Stringify.valueAlloc(a, .{ .stdout = result.stdout, .stderr = result.stderr }, .{});
    defer a.free(encoded);
    try std.testing.expect(encoded.len < 65536);
    const parsed = try std.json.parseFromSlice(std.json.Value, a, result.stderr, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("000000000000abcd", parsed.value.object.get("source_version").?.string);
    try std.testing.expectEqual(@as(i64, @intCast(123 + result.stdout.len)), parsed.value.object.get("next_offset").?.integer);
    try std.testing.expect(result.stdout.len > 0 and std.unicode.utf8ValidateSlice(result.stdout));
}

test "pagination directory projection advances only by entries actually returned" {
    const a = std.testing.allocator;
    const Entry = @import("proto/ssh/sftp_readonly.zig").Entry;
    const long_name = try a.alloc(u8, 3000);
    defer a.free(long_name);
    @memset(long_name, 'x');
    var entries: [128]Entry = undefined;
    for (&entries) |*entry| entry.* = .{ .raw_name = long_name, .display_name = long_name, .absolute_path = long_name, .attributes = .{ .kind = .file } };
    const value: capture.Value = .{ .metadata = metadata(), .body = .{ .listing = .{ .entries = &entries, .offset = 4096, .source_version = 0xabcd, .next_offset = 4224, .page_count = 1, .entry_limit = 128, .truncated = true } } };
    const result = try projection.project(a, value, 65536);
    defer result.deinit(a);
    const encoded = try std.json.Stringify.valueAlloc(a, .{ .stdout = result.stdout, .stderr = result.stderr }, .{});
    defer a.free(encoded);
    try std.testing.expect(encoded.len < 65536);
    const parsed = try std.json.parseFromSlice(std.json.Value, a, result.stdout, .{});
    defer parsed.deinit();
    const count = parsed.value.object.get("entries").?.array.items.len;
    try std.testing.expect(count > 0 and count < entries.len);
    try std.testing.expectEqual(@as(i64, @intCast(4096 + count)), parsed.value.object.get("next_offset").?.integer);
    try std.testing.expectEqualStrings("000000000000abcd", parsed.value.object.get("source_version").?.string);
}
