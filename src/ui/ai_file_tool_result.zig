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
            const metadata = try std.json.Stringify.valueAlloc(allocator, .{ .source = value.metadata, .original_size = text.original_size, .read_bytes = text.read_bytes, .returned_bytes = keep, .read_limit = text.read_limit, .encoding = "utf8", .truncated = truncated }, .{});
            if (metadata.len > cap) {
                allocator.free(metadata);
                return error.ToolOutputTooLarge;
            }
            if (metadata.len + keep <= cap) {
                errdefer allocator.free(metadata);
                return .{ .stdout = try allocator.dupe(u8, text.bytes[0..keep]), .stderr = metadata, .truncated = truncated };
            }
            keep = cap - metadata.len;
            allocator.free(metadata);
        }
    }
    const listing = value.body.listing;
    var count = listing.entries.len;
    while (true) {
        const bytes = try std.json.Stringify.valueAlloc(allocator, .{ .source = value.metadata, .entries = listing.entries[0..count], .page_count = listing.page_count, .entry_limit = listing.entry_limit, .truncated = listing.truncated or count < listing.entries.len }, .{});
        if (bytes.len <= cap) {
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
