//! A standalone slash opens the remote-file picker; paths and URLs stay text.
const std = @import("std");

pub fn triggers(text: []const u8, cursor: usize, inserted: []const u8, composing: bool, selection: bool) bool {
    if (composing or selection or !std.mem.eql(u8, inserted, "/") or cursor > text.len) return false;
    return (cursor == 0 or std.ascii.isWhitespace(text[cursor - 1])) and
        (cursor == text.len or std.ascii.isWhitespace(text[cursor]));
}

test "AI remote slash opens at a token boundary without hijacking paths URLs paste or IME" {
    try std.testing.expect(triggers("", 0, "/", false, false));
    try std.testing.expect(triggers("检查 ", "检查 ".len, "/", false, false));
    try std.testing.expect(triggers("检查  日志", "检查 ".len, "/", false, false));
    try std.testing.expect(!triggers("https:", 6, "/", false, false));
    try std.testing.expect(!triggers("/var", 4, "/", false, false));
    try std.testing.expect(!triggers("", 0, "/var/log", false, false));
    try std.testing.expect(!triggers("", 0, "/", true, false));
    try std.testing.expect(!triggers("abc", 0, "/", false, true));
}
