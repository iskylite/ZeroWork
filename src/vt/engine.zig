const std = @import("std");
const Cell = @import("cell.zig").Cell;
pub const Projection = @import("snapshot.zig").Projection;
pub const Modes = @import("snapshot.zig").Modes;
pub const SemanticEvent = @import("snapshot.zig").Event;
pub const KeyEvent = @import("input_event.zig").KeyEvent;
pub const MouseEvent = @import("input_event.zig").MouseEvent;
pub const Viewport = @import("viewport.zig");
pub const Theme = @import("theme.zig").Theme;

pub const Cursor = struct { row: u32 = 0, col: u16 = 0, visible: bool = true, blinking: bool = true, wide_tail: bool = false, shape: enum { block, bar, underline, hollow } = .block };
pub const Selection = struct { start_row: u64, start_col: u16, end_row: u64, end_col: u16 };
pub const CopyMode = enum { plain, with_attributes };
pub const OscEvent = union(enum) { cwd: []const u8, command_boundary, semantic: SemanticEvent, notification: []const u8 };
pub const OscCallback = *const fn (event: OscEvent) void;

pub const FeedResult = struct {
    dirty_pages: []const u32,
    cursor_moved: bool,
    bell: bool,
};

pub const Snapshot = struct {
    version: u64 = 0,
    style_version: u64 = 0,
    /// Parsed nonempty output batches and actual VT BEL events. Presentation
    /// refreshes must not advance either notification fact.
    output_sequence: u64 = 0,
    bell_count: u64 = 0,
    mode_revision: u64 = 1,
    modes: Modes = .{},
    cols: u16,
    rows: u16,
    cursor: Cursor,
    page_versions: []const u64,
    scroll_offset: u32,
};

pub const LineView = struct {
    abs_row: u64,
    cells: []const Cell,
    received_at_ms: i64,
};

/// Type-erased VT contract shared by ghostty-vt and the fallback adapter.
/// Construction stays adapter-specific so allocators and ownership are explicit.
pub const VtEngine = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        destroy: *const fn (*anyopaque) void,
        feed: *const fn (*anyopaque, []const u8) anyerror!FeedResult,
        resize: *const fn (*anyopaque, u16, u16) anyerror!void,
        snapshot: *const fn (*anyopaque) Snapshot,
        line_at: *const fn (*anyopaque, u64) ?LineView,
        selection_text: *const fn (*anyopaque, Selection, CopyMode, std.mem.Allocator) anyerror![]u8,
        set_osc_callback: *const fn (*anyopaque, ?OscCallback) void,
        copy_projection: *const fn (*anyopaque, std.mem.Allocator) anyerror!Projection,
        read_reply: *const fn (*anyopaque, []u8) anyerror!usize,
        encode_key: *const fn (*anyopaque, KeyEvent, std.mem.Allocator) anyerror![]u8,
        encode_mouse: *const fn (*anyopaque, MouseEvent, std.mem.Allocator) anyerror![]u8,
        create_anchor: *const fn (*anyopaque, Viewport.Point) anyerror!Viewport.AnchorId,
        resolve_anchor: *const fn (*anyopaque, Viewport.AnchorId) anyerror!?Viewport.AnchorPosition,
        release_anchor: *const fn (*anyopaque, Viewport.AnchorId) anyerror!void,
        selection_from_anchors: *const fn (*anyopaque, Viewport.Selection, std.mem.Allocator, usize) anyerror![]u8,
        scroll: *const fn (*anyopaque, Viewport.Scroll) anyerror!void,
        read_lines: *const fn (*anyopaque, Viewport.LineLimits, std.mem.Allocator) anyerror!Viewport.Lines,
        record_submission: *const fn (*anyopaque) void,
        set_theme: *const fn (*anyopaque, Theme) anyerror!void,
        search_snapshot: ?*const fn (*anyopaque, std.mem.Allocator) anyerror!@import("search_snapshot.zig").Document = null,
    };

    pub fn destroy(self: VtEngine) void {
        self.vtable.destroy(self.ptr);
    }
    pub fn feed(self: VtEngine, bytes: []const u8) !FeedResult {
        return self.vtable.feed(self.ptr, bytes);
    }
    pub fn resize(self: VtEngine, cols: u16, rows: u16) !void {
        return self.vtable.resize(self.ptr, cols, rows);
    }
    pub fn snapshot(self: VtEngine) Snapshot {
        return self.vtable.snapshot(self.ptr);
    }
    pub fn lineAt(self: VtEngine, abs_row: u64) ?LineView {
        return self.vtable.line_at(self.ptr, abs_row);
    }
    pub fn selectionText(self: VtEngine, selection: Selection, mode: CopyMode, allocator: std.mem.Allocator) ![]u8 {
        return self.vtable.selection_text(self.ptr, selection, mode, allocator);
    }
    pub fn setOscCallback(self: VtEngine, callback: ?OscCallback) void {
        self.vtable.set_osc_callback(self.ptr, callback);
    }
    pub fn copyProjection(self: VtEngine, allocator: std.mem.Allocator) !Projection {
        return self.vtable.copy_projection(self.ptr, allocator);
    }
    /// Parser replies are copied, then written by the existing transport owner.
    pub fn readReply(self: VtEngine, buffer: []u8) !usize {
        return self.vtable.read_reply(self.ptr, buffer);
    }
    pub fn encodeKey(self: VtEngine, event: KeyEvent, allocator: std.mem.Allocator) ![]u8 {
        return self.vtable.encode_key(self.ptr, event, allocator);
    }
    pub fn encodeMouse(self: VtEngine, event: MouseEvent, allocator: std.mem.Allocator) ![]u8 {
        return self.vtable.encode_mouse(self.ptr, event, allocator);
    }
    pub fn createAnchor(self: VtEngine, point: Viewport.Point) !Viewport.AnchorId {
        return self.vtable.create_anchor(self.ptr, point);
    }
    pub fn resolveAnchor(self: VtEngine, anchor: Viewport.AnchorId) !?Viewport.AnchorPosition {
        return self.vtable.resolve_anchor(self.ptr, anchor);
    }
    pub fn releaseAnchor(self: VtEngine, anchor: Viewport.AnchorId) !void {
        return self.vtable.release_anchor(self.ptr, anchor);
    }
    pub fn selectionFromAnchors(self: VtEngine, selected: Viewport.Selection, allocator: std.mem.Allocator, max_bytes: usize) ![]u8 {
        return self.vtable.selection_from_anchors(self.ptr, selected, allocator, max_bytes);
    }
    pub fn scroll(self: VtEngine, request: Viewport.Scroll) !void {
        return self.vtable.scroll(self.ptr, request);
    }
    pub fn readLines(self: VtEngine, limits: Viewport.LineLimits, allocator: std.mem.Allocator) !Viewport.Lines {
        return self.vtable.read_lines(self.ptr, limits, allocator);
    }
    pub fn searchSnapshot(self: VtEngine, allocator: std.mem.Allocator) !@import("search_snapshot.zig").Document {
        const capture = self.vtable.search_snapshot orelse return error.SearchUnavailable;
        return capture(self.ptr, allocator);
    }
    pub fn recordSubmission(self: VtEngine) void {
        self.vtable.record_submission(self.ptr);
    }
    pub fn setTheme(self: VtEngine, theme: Theme) !void {
        return self.vtable.set_theme(self.ptr, theme);
    }

    pub fn from(comptime T: type, instance: *T) VtEngine {
        const Adapter = struct {
            fn cast(ptr: *anyopaque) *T {
                return @ptrCast(@alignCast(ptr));
            }
            fn callDestroy(ptr: *anyopaque) void {
                cast(ptr).destroy();
            }
            fn callFeed(ptr: *anyopaque, bytes: []const u8) anyerror!FeedResult {
                return cast(ptr).feed(bytes);
            }
            fn callResize(ptr: *anyopaque, cols: u16, rows: u16) anyerror!void {
                return cast(ptr).resize(cols, rows);
            }
            fn callSnapshot(ptr: *anyopaque) Snapshot {
                return cast(ptr).snapshot();
            }
            fn callLineAt(ptr: *anyopaque, row: u64) ?LineView {
                return cast(ptr).lineAt(row);
            }
            fn callSelectionText(ptr: *anyopaque, selection: Selection, mode: CopyMode, allocator: std.mem.Allocator) anyerror![]u8 {
                return cast(ptr).selectionText(selection, mode, allocator);
            }
            fn callSetOscCallback(ptr: *anyopaque, callback: ?OscCallback) void {
                cast(ptr).setOscCallback(callback);
            }
            fn callCopyProjection(ptr: *anyopaque, allocator: std.mem.Allocator) anyerror!Projection {
                if (@hasDecl(T, "copyProjection")) return cast(ptr).copyProjection(allocator);
                return error.ProjectionUnavailable;
            }
            fn callReadReply(ptr: *anyopaque, buffer: []u8) anyerror!usize {
                if (@hasDecl(T, "readReply")) return cast(ptr).readReply(buffer);
                return 0;
            }
            fn callEncodeKey(ptr: *anyopaque, event: KeyEvent, allocator: std.mem.Allocator) anyerror![]u8 {
                if (@hasDecl(T, "encodeKey")) return cast(ptr).encodeKey(event, allocator);
                return error.InputEncodingUnavailable;
            }
            fn callEncodeMouse(ptr: *anyopaque, event: MouseEvent, allocator: std.mem.Allocator) anyerror![]u8 {
                if (@hasDecl(T, "encodeMouse")) return cast(ptr).encodeMouse(event, allocator);
                return error.InputEncodingUnavailable;
            }
            fn callCreateAnchor(ptr: *anyopaque, point: Viewport.Point) anyerror!Viewport.AnchorId {
                if (@hasDecl(T, "createAnchor")) return cast(ptr).createAnchor(point);
                return error.AnchorsUnavailable;
            }
            fn callResolveAnchor(ptr: *anyopaque, anchor: Viewport.AnchorId) anyerror!?Viewport.AnchorPosition {
                if (@hasDecl(T, "resolveAnchor")) return cast(ptr).resolveAnchor(anchor);
                return error.AnchorsUnavailable;
            }
            fn callReleaseAnchor(ptr: *anyopaque, anchor: Viewport.AnchorId) anyerror!void {
                if (@hasDecl(T, "releaseAnchor")) return cast(ptr).releaseAnchor(anchor);
                return error.AnchorsUnavailable;
            }
            fn callSelectionFromAnchors(ptr: *anyopaque, selected: Viewport.Selection, allocator: std.mem.Allocator, max_bytes: usize) anyerror![]u8 {
                if (@hasDecl(T, "selectionFromAnchors")) return cast(ptr).selectionFromAnchors(selected, allocator, max_bytes);
                return error.SelectionUnavailable;
            }
            fn callScroll(ptr: *anyopaque, request: Viewport.Scroll) anyerror!void {
                if (@hasDecl(T, "scroll")) return cast(ptr).scroll(request);
                return error.ScrollingUnavailable;
            }
            fn callReadLines(ptr: *anyopaque, limits: Viewport.LineLimits, allocator: std.mem.Allocator) anyerror!Viewport.Lines {
                if (@hasDecl(T, "readLines")) return cast(ptr).readLines(limits, allocator);
                return error.ContextUnavailable;
            }
            fn callRecordSubmission(ptr: *anyopaque) void {
                if (@hasDecl(T, "recordSubmission")) cast(ptr).recordSubmission();
            }
            fn callSetTheme(ptr: *anyopaque, theme: Theme) !void {
                if (@hasDecl(T, "setTheme")) return cast(ptr).setTheme(theme);
                return error.ThemeUnavailable;
            }
            fn callSearchSnapshot(ptr: *anyopaque, allocator: std.mem.Allocator) !@import("search_snapshot.zig").Document {
                if (@hasDecl(T, "searchSnapshot")) return cast(ptr).searchSnapshot(allocator);
                return error.SearchUnavailable;
            }
            const vtable: VTable = .{ .destroy = callDestroy, .feed = callFeed, .resize = callResize, .snapshot = callSnapshot, .line_at = callLineAt, .selection_text = callSelectionText, .set_osc_callback = callSetOscCallback, .copy_projection = callCopyProjection, .read_reply = callReadReply, .encode_key = callEncodeKey, .encode_mouse = callEncodeMouse, .create_anchor = callCreateAnchor, .resolve_anchor = callResolveAnchor, .release_anchor = callReleaseAnchor, .selection_from_anchors = callSelectionFromAnchors, .scroll = callScroll, .read_lines = callReadLines, .record_submission = callRecordSubmission, .set_theme = callSetTheme, .search_snapshot = callSearchSnapshot };
        };
        return .{ .ptr = instance, .vtable = &Adapter.vtable };
    }
};

const Mock = struct {
    destroyed: bool = false,
    cols: u16 = 80,
    rows: u16 = 24,
    callback: ?OscCallback = null,
    versions: [1]u64 = .{1},
    dirty: [1]u32 = .{0},

    fn destroy(self: *Mock) void {
        self.destroyed = true;
    }
    fn feed(self: *Mock, bytes: []const u8) !FeedResult {
        return .{ .dirty_pages = if (bytes.len == 0) &.{} else &self.dirty, .cursor_moved = bytes.len != 0, .bell = std.mem.indexOfScalar(u8, bytes, 7) != null };
    }
    fn resize(self: *Mock, cols: u16, rows: u16) !void {
        if (cols == 0 or rows == 0) return error.InvalidDimensions;
        self.cols = cols;
        self.rows = rows;
    }
    fn snapshot(self: *Mock) Snapshot {
        return .{ .cols = self.cols, .rows = self.rows, .cursor = .{}, .page_versions = &self.versions, .scroll_offset = 0 };
    }
    fn lineAt(self: *Mock, row: u64) ?LineView {
        _ = self;
        _ = row;
        return null;
    }
    fn selectionText(self: *Mock, selection: Selection, mode: CopyMode, allocator: std.mem.Allocator) ![]u8 {
        _ = self;
        _ = selection;
        _ = mode;
        return allocator.dupe(u8, "mock");
    }
    fn setOscCallback(self: *Mock, callback: ?OscCallback) void {
        self.callback = callback;
    }
};

test "type erased engine forwards its complete contract" {
    var mock: Mock = .{};
    const engine = VtEngine.from(Mock, &mock);
    try engine.resize(120, 40);
    try std.testing.expectEqual(@as(u16, 120), engine.snapshot().cols);
    const result = try engine.feed("hello\x07");
    try std.testing.expect(result.cursor_moved and result.bell);
    const text = try engine.selectionText(.{ .start_row = 0, .start_col = 0, .end_row = 0, .end_col = 4 }, .plain, std.testing.allocator);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("mock", text);
    engine.destroy();
    try std.testing.expect(mock.destroyed);
}
