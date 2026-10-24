//! Immutable original-session VT snapshots. The host supplies already checked
//! selection/command bytes; this domain never reads a terminal, file or focus.
const std = @import("std");
const attachments = @import("local_text_attachments.zig");
const SessionHandle = @import("../host/identity.zig").SessionHandle;
const viewport = @import("../vt/viewport.zig");
pub const max_capture_bytes = attachments.max_terminal_bytes;
pub const Selection = struct {
    owner: SessionHandle,
    source_name: []const u8,
    source_version: u64,
    selected_rows: u32,
    selection: viewport.OwnedSelection,
    legacy_range: ?@import("../vt/engine.zig").Selection = null,
};

pub fn createSelection(allocator: std.mem.Allocator, selected: Selection, bytes: []const u8, captured_at_ms: i64) !attachments.ContentRef {
    return attachments.ContentRef.createTerminal(allocator, .{ .owner = selected.owner, .source_name = selected.source_name, .line_count = selected.selected_rows, .origin = .{ .selection = .{ .selection = selected.selection, .source_version = selected.source_version, .legacy_range = selected.legacy_range } } }, bytes, captured_at_ms);
}
pub fn createCommand(allocator: std.mem.Allocator, hint: @import("command_error_hint.zig").Hint, source_name: []const u8, captured_at_ms: i64) !attachments.ContentRef {
    return attachments.ContentRef.createTerminal(allocator, .{ .owner = hint.owner, .source_name = source_name, .line_count = lineCount(hint.output), .origin = .{ .command = .{ .command_id = hint.command_id, .end_sequence = hint.end_sequence, .exit_code = hint.exit_code, .command = hint.command } } }, hint.output, captured_at_ms);
}
pub fn lineCount(bytes: []const u8) u32 {
    if (bytes.len == 0) return 0;
    const count = std.mem.count(u8, bytes, "\n") + @as(usize, if (bytes[bytes.len - 1] == '\n') 0 else 1);
    return @intCast(@min(count, std.math.maxInt(u32)));
}
