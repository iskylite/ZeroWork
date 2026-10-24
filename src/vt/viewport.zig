const std = @import("std");
const identity = @import("../host/identity.zig");
pub const Point = struct { space: enum { viewport, screen } = .viewport, row: u32, col: u16, source_version: ?u64 = null };
pub const AnchorId = u64;
pub const AnchorPosition = struct { row: u32, col: u16, alternate_screen: bool, source_version: u64 = 0 };
/// Linear endpoints are half-open. Rectangular columns are half-open and
/// rectangular endpoint rows are both included, matching a pointer drag.
pub const Selection = struct { start: AnchorId, end: AnchorId, rectangle: bool = false };
pub const Scroll = union(enum) { delta: i32, top, bottom, anchor: AnchorId };
pub const OwnedAnchor = struct { owner: identity.SessionHandle, id: AnchorId };
pub const OwnedSelection = struct { start: OwnedAnchor, end: OwnedAnchor, rectangle: bool = false };
pub const OwnedScroll = union(enum) { delta: i32, top, bottom, anchor: OwnedAnchor };
pub const LineLimits = struct { max_lines: u32 = 1024, max_bytes: usize = 64 * 1024 };
pub const Lines = struct {
    lines: [][]u8,
    truncated: bool,
    pub fn deinit(self: *Lines, allocator: std.mem.Allocator) void {
        for (self.lines) |line| allocator.free(line);
        allocator.free(self.lines);
    }
};
