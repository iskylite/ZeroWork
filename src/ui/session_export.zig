//! Saved log-format policy shared by live-session and archived-session exports.
//! The native dialog is caller-owned; a cancelled choice never invokes a sink.
const std = @import("std");
const identity = @import("../host/identity.zig");
const Entry = @import("../vt/session_archive.zig").Entry;
const Adapter = @import("../vt/ghostty_adapter.zig").Adapter;
const atomic_text = @import("terminal_export.zig");

pub const Kind = enum { txt, cast };
pub const Format = enum {
    txt,
    cast,
    txt_cast,

    pub fn parse(saved: []const u8) !Format {
        inline for (std.meta.tags(Format)) |format| if (std.mem.eql(u8, saved, @tagName(format))) return format;
        return error.InvalidExportFormat;
    }
    pub fn defaultFilename(self: Format) []const u8 {
        return switch (self) {
            .txt => "session.txt",
            .cast => "session.cast",
            .txt_cast => "session",
        };
    }
};

pub const SessionCapture = struct {
    tab_id: identity.TabId,
    owner: identity.ContentOwner,
    pub fn matches(self: SessionCapture, tab_id: identity.TabId, owner: identity.ContentOwner) bool {
        return self.tab_id == tab_id and self.owner.eql(owner);
    }
};

/// cast_path must remain owned by the caller while a native dialog is open.
pub const ArchiveCapture = struct {
    id: u64,
    cast_path: []const u8,
    pub fn matches(self: ArchiveCapture, entry: Entry) bool {
        return self.id == entry.id and std.mem.eql(u8, self.cast_path, entry.cast_path);
    }
};

/// Each sink validates the originally captured owner before every file. A
/// paired export returns success only when both atomic file writes succeed.
pub fn run(allocator: std.mem.Allocator, format: Format, chosen_path: ?[]const u8, sink: anytype) !bool {
    const chosen = chosen_path orelse return false;
    if (chosen.len == 0) return error.EmptyPath;
    var stem = chosen;
    for ([_][]const u8{ ".txt", ".cast" }) |suffix| {
        if (stem.len >= suffix.len and std.ascii.eqlIgnoreCase(stem[stem.len - suffix.len ..], suffix)) {
            stem = stem[0 .. stem.len - suffix.len];
            break;
        }
    }
    if (std.fs.path.basename(stem).len == 0) return error.EmptyPath;
    const kinds: []const Kind = switch (format) {
        .txt => &.{.txt},
        .cast => &.{.cast},
        .txt_cast => &.{ .txt, .cast },
    };
    for (kinds) |kind| {
        try sink.validate();
        const path = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ stem, @tagName(kind) });
        defer allocator.free(path);
        try sink.write(kind, path);
    }
    return true;
}

pub fn writeArchive(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, kind: Kind, path: []const u8, cast: []const u8) !void {
    switch (kind) {
        .cast => try atomic_text.writeSnapshot(io, dir, path, cast),
        .txt => {
            const text = try castText(allocator, cast);
            defer allocator.free(text);
            try atomic_text.writeSnapshot(io, dir, path, text);
        },
    }
}

/// As with history_cast.load, output events pass through the actual Ghostty
/// VT. Its plain formatter includes retained scrollback, UTF-8 graphemes and
/// cursor edits, while interpreting ANSI/OSC controls instead of copying them.
pub fn castText(allocator: std.mem.Allocator, cast: []const u8) ![]u8 {
    var lines = std.mem.splitScalar(u8, cast, '\n');
    const header = try std.json.parseFromSlice(std.json.Value, allocator, lines.next() orelse return error.InvalidCast, .{});
    defer header.deinit();
    if (header.value != .object) return error.InvalidCast;
    const version = header.value.object.get("version") orelse return error.InvalidCast;
    if (version != .integer or version.integer != 2) return error.InvalidCast;
    const cols = try dimension(header.value.object.get("width") orelse return error.InvalidCast);
    const rows = try dimension(header.value.object.get("height") orelse return error.InvalidCast);
    var adapter = try Adapter.init(allocator, rows, cols);
    defer adapter.destroy();
    var previous_ms: i64 = 0;
    var has_output = false;
    while (lines.next()) |line| {
        if (std.mem.trim(u8, line, " \r\t").len == 0) continue;
        const event = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
        defer event.deinit();
        if (event.value != .array or event.value.array.items.len != 3) return error.InvalidCast;
        const items = event.value.array.items;
        const seconds: f64 = switch (items[0]) {
            .integer => |v| @floatFromInt(v),
            .float => |v| v,
            else => return error.InvalidCast,
        };
        if (!std.math.isFinite(seconds) or seconds < 0 or seconds > 1e12) return error.InvalidCast;
        const ms: i64 = @intFromFloat(seconds * 1000);
        if (ms < previous_ms) return error.InvalidCast;
        previous_ms = ms;
        if (items[1] != .string or items[2] != .string) return error.InvalidCast;
        if (!std.mem.eql(u8, items[1].string, "o")) continue;
        _ = try adapter.feed(items[2].string);
        has_output = true;
    }
    if (!has_output) return error.EmptyRecording;
    return adapter.searchText(allocator);
}

fn dimension(value: std.json.Value) !u16 {
    if (value != .integer or value.integer < 1 or value.integer > 1000) return error.InvalidCast;
    return @intCast(value.integer);
}
