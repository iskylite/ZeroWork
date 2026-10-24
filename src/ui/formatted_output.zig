//! Display projection only. The tool ledger and clipboard keep original bytes.
const std = @import("std");
pub fn format(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    if (!std.unicode.utf8ValidateSlice(bytes)) {
        const encoder = std.base64.standard.Encoder;
        const text = try allocator.alloc(u8, 8 + encoder.calcSize(bytes.len));
        @memcpy(text[0..8], "base64: ");
        _ = encoder.encode(text[8..], bytes);
        return text;
    }
    const trimmed = std.mem.trim(u8, bytes, " \t\r\n");
    if (bytes.len <= 65536 and trimmed.len > 1 and (trimmed[0] == '{' or trimmed[0] == '[')) {
        if (std.json.parseFromSlice(std.json.Value, allocator, trimmed, .{})) |parsed| {
            defer parsed.deinit();
            return std.json.Stringify.valueAlloc(allocator, parsed.value, .{ .whitespace = .indent_2 });
        } else |_| {}
    }
    return allocator.dupe(u8, bytes);
}
