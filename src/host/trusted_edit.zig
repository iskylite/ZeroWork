//! Private editor data, separate from terminal output and UI predictions.
const std = @import("std");
const identity = @import("identity.zig");
pub const max_buffer = 64 * 1024;
pub const max_frame = 128 * 1024;
pub const Kind = enum { replace, begin, end };
pub const Request = struct { operation: u64, token: u64, revision: u64, kind: Kind = .replace, replacement: []const u8 = "", lease: u64 = 0 };
pub const Outcome = struct { operation: u64, applied: bool, revision: u64 = 0, lease: u64 = 0, reason: enum { none, rejected, timeout, integration_lost } = .none };
pub const Snapshot = struct {
    owner: identity.SessionHandle,
    token: u64,
    revision: u64,
    buffer: []u8,
    cursor: u64,
    mark: u64,
    region: u64,
    keymap: []u8,
    context: []u8,
    prebuffer: []u8,
    lease: u64,
    pub fn editable(self: Snapshot) bool {
        const chars = std.unicode.utf8CountCodepoints(self.buffer) catch return false;
        return self.token > 0 and self.cursor == chars and self.region == 0 and self.prebuffer.len == 0 and
            std.mem.eql(u8, self.context, "start") and (std.mem.eql(u8, self.keymap, "main") or std.mem.eql(u8, self.keymap, "emacs") or std.mem.eql(u8, self.keymap, "viins"));
    }
    pub fn clone(self: Snapshot, allocator: std.mem.Allocator) !Snapshot {
        var copy = self;
        copy.buffer = try allocator.dupe(u8, self.buffer);
        errdefer allocator.free(copy.buffer);
        copy.keymap = try allocator.dupe(u8, self.keymap);
        errdefer allocator.free(copy.keymap);
        copy.context = try allocator.dupe(u8, self.context);
        errdefer allocator.free(copy.context);
        copy.prebuffer = try allocator.dupe(u8, self.prebuffer);
        return copy;
    }
    pub fn deinit(self: *Snapshot, allocator: std.mem.Allocator) void {
        allocator.free(self.buffer);
        allocator.free(self.keymap);
        allocator.free(self.context);
        allocator.free(self.prebuffer);
    }
};
/// Every field is a netstring. The outer eight ASCII hex digits are the byte
/// length; embedded newlines, quotes, NULs and UTF-8 never become shell code.
pub fn encode(allocator: std.mem.Allocator, fields: []const []const u8) ![]u8 {
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(allocator);
    for (fields) |field| {
        var count: [32]u8 = undefined;
        try body.appendSlice(allocator, try std.fmt.bufPrint(&count, "{d}:", .{field.len}));
        try body.appendSlice(allocator, field);
        try body.append(allocator, ',');
    }
    if (body.items.len > max_frame) return error.FrameTooLarge;
    const result = try allocator.alloc(u8, body.items.len + 8);
    _ = std.fmt.bufPrint(result[0..8], "{x:0>8}", .{body.items.len}) catch unreachable;
    @memcpy(result[8..], body.items);
    return result;
}
pub fn decode(body: []const u8, fields: [][]const u8) ![][]const u8 {
    var offset: usize = 0;
    var count: usize = 0;
    while (offset < body.len) {
        if (count == fields.len) return error.TooManyFields;
        const end = std.mem.indexOfScalarPos(u8, body, offset, ':') orelse return error.InvalidFrame;
        const size = try std.fmt.parseInt(usize, body[offset..end], 10);
        offset = end + 1;
        if (size >= body.len - offset or body[offset + size] != ',') return error.InvalidFrame;
        fields[count] = body[offset..][0..size];
        count += 1;
        offset += size + 1;
    }
    return fields[0..count];
}
test "length frames preserve shell metacharacters and unicode as data" {
    const a = std.testing.allocator;
    const frame = try encode(a, &.{ "1", "echo '中文'\n$(false)\x00👩‍💻" });
    defer a.free(frame);
    var scratch: [4][]const u8 = undefined;
    const fields = try decode(frame[8..], &scratch);
    try std.testing.expectEqualStrings("echo '中文'\n$(false)\x00👩‍💻", fields[1]);
    try std.testing.expectError(error.InvalidFrame, decode("3:ab,", &scratch));
}
