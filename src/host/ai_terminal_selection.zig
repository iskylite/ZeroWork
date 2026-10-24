//! Explicit original-session VT selection capture. No PTY read, file IO,
//! clipboard mutation, selection clearing, provider call, or active-tab lookup.
const std = @import("std");
const terminal = @import("terminal_service.zig");
const identity = @import("identity.zig");
pub const max_service_bytes: usize = 1024 * 1024;

pub const Captured = struct {
    allocator: std.mem.Allocator,
    owner: identity.SessionHandle,
    selection: terminal.Selection,
    bytes: []u8,
    source_version: u64,
    selected_rows: u32,

    pub fn deinit(self: *Captured) void {
        self.allocator.free(self.bytes);
        self.bytes = &.{};
    }
};

/// The caller freezes the selected anchors and complete SessionHandle before
/// opening the assistant. A busy or changing source is rejected, never retried
/// against a later active terminal. max_bytes is an explicit host budget.
pub fn capture(allocator: std.mem.Allocator, service: terminal.Service, owner: identity.SessionHandle, selected: terminal.Selection, max_bytes: usize) !Captured {
    if (max_bytes == 0 or max_bytes > max_service_bytes) return error.InvalidSelectionLimit;
    if (service.binding.kind != .terminal or service.binding.resource_owner != .session or
        !service.binding.resource_owner.session.eql(owner) or !selected.start.owner.eql(owner) or !selected.end.owner.eql(owner)) return error.StaleOwner;
    const status = try service.status();
    if (!status.owner.eql(owner)) return error.StaleOwner;
    const start = (try service.resolveAnchor(selected.start)) orelse return error.StaleSelection;
    const end = (try service.resolveAnchor(selected.end)) orelse return error.StaleSelection;
    if (start.alternate_screen != end.alternate_screen or start.source_version != end.source_version) return error.StaleSelection;
    var first = start;
    var last = end;
    if (last.row < first.row or (last.row == first.row and last.col < first.col)) std.mem.swap(terminal.AnchorPosition, &first, &last);
    if ((selected.rectangle and start.col == end.col) or
        (!selected.rectangle and first.row == last.row and first.col == last.col)) return error.NoSelection;
    const bytes = try service.selectionText(selected, allocator, max_bytes);
    errdefer allocator.free(bytes);
    if (bytes.len > max_bytes) return error.SelectionTooLarge;
    if (bytes.len == 0) return error.NoSelection;
    const after_start = (try service.resolveAnchor(selected.start)) orelse return error.StaleSelection;
    const after_end = (try service.resolveAnchor(selected.end)) orelse return error.StaleSelection;
    if (!std.meta.eql(start, after_start) or !std.meta.eql(end, after_end)) return error.StaleSelection;
    const final_status = try service.status();
    if (!final_status.owner.eql(owner)) return error.StaleOwner;
    const rows = last.row - first.row + if (selected.rectangle or last.col != 0 or first.row == last.row) @as(u32, 1) else @as(u32, 0);
    return .{ .allocator = allocator, .owner = owner, .selection = selected, .bytes = bytes, .source_version = start.source_version, .selected_rows = rows };
}
