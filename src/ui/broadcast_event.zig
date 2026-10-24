const terminal = @import("../host/terminal_service.zig");
pub const Payload = union(enum) { bytes: []const u8, key: terminal.KeyEvent, paste: []const u8 };
