//! Bounded wire projection of the same immutable captures used by attachments.
const std = @import("std");
const remote = @import("../host/ai_remote_file_snapshot.zig");
pub const Projection = struct {
    stdout: []u8,
    stderr: []u8,
    truncated: bool,
    pub fn deinit(self: Projection, allocator: std.mem.Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
    }
};
pub fn project(allocator: std.mem.Allocator, value: remote.Value, cap: usize) !Projection {
    if (value.body == .failure) return error.RemoteFileCaptureFailed;
    if (value.body == .text) {
        const text = value.body.text;
        // Metadata and content share the existing tool-result 64 KiB budget.
        var keep = @min(text.bytes.len, cap);
        while (true) {
            while (keep > 0 and !std.unicode.utf8ValidateSlice(text.bytes[0..keep])) keep -= 1;
            const truncated = text.truncated or keep < text.bytes.len;
            var version_buffer: [16]u8 = undefined;
            const metadata = try std.json.Stringify.valueAlloc(allocator, .{ .source = value.metadata, .offset = text.offset, .source_version = try std.fmt.bufPrint(&version_buffer, "{x:0>16}", .{text.source_version}), .next_offset = if (truncated and keep > 0) @as(?u64, text.offset + keep) else null, .original_size = text.original_size, .read_bytes = text.read_bytes, .returned_bytes = keep, .read_limit = text.read_limit, .encoding = "utf8", .truncated = truncated }, .{});
            if (metadata.len > cap) {
                allocator.free(metadata);
                return error.ToolOutputTooLarge;
            }
            const encoded_metadata = try std.json.Stringify.valueAlloc(allocator, metadata, .{});
            defer allocator.free(encoded_metadata);
            const encoded_text = try std.json.Stringify.valueAlloc(allocator, text.bytes[0..keep], .{});
            defer allocator.free(encoded_text);
            if (metadata.len + keep <= cap and encoded_metadata.len + encoded_text.len + 2048 <= cap) {
                errdefer allocator.free(metadata);
                return .{ .stdout = try allocator.dupe(u8, text.bytes[0..keep]), .stderr = metadata, .truncated = truncated };
            }
            if (keep == 0) {
                allocator.free(metadata);
                return error.ToolOutputTooLarge;
            }
            keep = @min(keep - 1, @min(cap - metadata.len, keep / 2));
            allocator.free(metadata);
        }
    }
    const listing = value.body.listing;
    var count = listing.entries.len;
    while (true) {
        var version_buffer: [16]u8 = undefined;
        const bytes = try std.json.Stringify.valueAlloc(allocator, .{ .source = value.metadata, .offset = listing.offset, .source_version = try std.fmt.bufPrint(&version_buffer, "{x:0>16}", .{listing.source_version}), .next_offset = if (count < listing.entries.len) @as(?u64, listing.offset + count) else listing.next_offset, .entries = listing.entries[0..count], .page_count = listing.page_count, .entry_limit = listing.entry_limit, .truncated = listing.truncated or count < listing.entries.len }, .{});
        const encoded = try std.json.Stringify.valueAlloc(allocator, bytes, .{});
        defer allocator.free(encoded);
        if (bytes.len <= cap and encoded.len + 2048 <= cap) {
            if (count == 0 and listing.entries.len != 0) {
                allocator.free(bytes);
                return error.ToolOutputTooLarge;
            }
            errdefer allocator.free(bytes);
            return .{ .stdout = bytes, .stderr = try allocator.dupe(u8, ""), .truncated = listing.truncated or count < listing.entries.len };
        }
        allocator.free(bytes);
        if (count == 0) return error.ToolOutputTooLarge;
        count /= 2;
    }
}
pub fn failureCode(value: remote.Failure) []const u8 {
    return switch (value) {
        .remote => |failure| @tagName(failure),
        else => @tagName(value),
    };
}
