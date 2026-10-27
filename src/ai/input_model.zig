const std = @import("std");

pub const max_bytes: usize = 4096;
pub const max_lines: usize = 2;

pub const Input = struct {
    buffer: [max_bytes]u8 = undefined,
    len: usize = 0,

    pub fn clear(self: *Input) void {
        self.len = 0;
    }
    pub fn text(self: *const Input) []const u8 {
        return self.buffer[0..self.len];
    }
    pub fn lineCount(self: Input) usize {
        if (self.len == 0) return 0;
        var count: usize = 1;
        for (self.text()) |byte| {
            if (byte == '\n') count += 1;
        }
        return count;
    }
    pub fn append(self: *Input, bytes: []const u8) error{ InputTooLong, TooManyLines }!void {
        var lines = self.lineCount();
        for (bytes) |byte| {
            if (byte == '\n') {
                lines += 1;
                if (lines > max_lines) return error.TooManyLines;
            }
        }
        if (self.len + bytes.len > max_bytes) return error.InputTooLong;
        @memcpy(self.buffer[self.len .. self.len + bytes.len], bytes);
        self.len += bytes.len;
    }
    pub fn backspace(self: *Input) void {
        if (self.len == 0) return;
        self.len -= 1;
        while (self.len > 0 and (self.buffer[self.len] & 0xc0) == 0x80) self.len -= 1;
    }
    pub fn submit(self: *Input) ?[]const u8 {
        if (std.mem.trim(u8, self.text(), " \t\r\n").len == 0) return null;
        return self.text();
    }
};

test "AI input enforces two lines and UTF-8 backspace" {
    var input: Input = .{};
    try input.append("检查 ");
    try input.append("输出");
    try std.testing.expectEqual(@as(usize, 1), input.lineCount());
    input.backspace();
    try std.testing.expectEqualStrings("检查 ", input.text());
    try input.append("\n第二行");
    try std.testing.expectEqual(@as(usize, 2), input.lineCount());
    try std.testing.expectError(error.TooManyLines, input.append("\n第三行"));
    try std.testing.expect(input.submit() != null);
}

test "AI input rejects empty submit and oversized input" {
    var input: Input = .{};
    try std.testing.expect(input.submit() == null);
    var bytes: [max_bytes + 1]u8 = undefined;
    @memset(&bytes, 'x');
    try std.testing.expectError(error.InputTooLong, input.append(&bytes));
}
