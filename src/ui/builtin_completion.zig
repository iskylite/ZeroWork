//! Context-aware builtin parameter completion. No bytes are sent to the interactive PTY.
const std = @import("std");
const exec = @import("../ai/execbridge.zig");
pub const Call = struct { bridge: exec.ExecBridge, handle: exec.ExecHandle };

pub fn quote(a: std.mem.Allocator, value: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    try out.append(a, '\'');
    for (value) |ch| if (ch == '\'') {
        try out.appendSlice(a, "'\\''");
    } else try out.append(a, ch);
    try out.append(a, '\'');
    return out.toOwnedSlice(a);
}

/// Globs are syntax supplied by us; every byte from the user remains quoted.
pub fn command(a: std.mem.Allocator, cwd: []const u8, path: []const u8) ![]u8 {
    const directory = try quote(a, cwd);
    defer a.free(directory);
    const home = std.mem.startsWith(u8, path, "~/");
    const prefix = try quote(a, if (home) path[2..] else path);
    defer a.free(prefix);
    return std.fmt.allocPrint(a, "cd {s} || exit; zw_p={s}{s}; for zw_f in \"$zw_p\"*; do " ++
        "[ -e \"$zw_f\" ] || [ -L \"$zw_f\" ] || continue; " ++
        "if [ -d \"$zw_f\" ]; then printf '%s/\\000' \"$zw_f\"; else printf '%s\\000' \"$zw_f\"; fi; done", .{ directory, if (home) "\"$HOME/\"" else "", prefix });
}

pub fn localPaths(a: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    const slash = std.mem.lastIndexOfScalar(u8, path, '/');
    const parent = if (slash) |at| path[0 .. at + 1] else "";
    const prefix = path[parent.len..];
    const home = try @import("../platform/account.zig").home(a);
    defer a.free(home);
    const directory = if (std.mem.startsWith(u8, parent, "~/")) try std.fs.path.join(a, &.{ home, parent[2..] }) else try a.dupe(u8, if (parent.len == 0) "." else parent);
    defer a.free(directory);
    var dir = try std.Io.Dir.cwd().openDir(io, directory, .{ .iterate = true });
    defer dir.close(io);
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(a);
    var iterator = dir.iterate();
    var count: usize = 0;
    while (try iterator.next(io)) |entry| {
        if (!std.mem.startsWith(u8, entry.name, prefix) or (prefix.len == 0 and entry.name[0] == '.')) continue;
        if (count >= 4096 or list.items.len + parent.len + entry.name.len + 2 > 64 * 1024) return error.TooManyCandidates;
        try list.appendSlice(a, parent);
        try list.appendSlice(a, entry.name);
        if (entry.kind == .directory) try list.append(a, '/');
        try list.append(a, 0);
        count += 1;
    }
    return list.toOwnedSlice(a);
}

pub const State = struct {
    call: ?Call = null,
    draft: ?[]u8 = null,
    candidates: ?[]u8 = null,
    applied: ?[]u8 = null,
    index: usize = 0,
    consumed: bool = false,
    waiting_cwd: bool = false,
    started_ms: i64 = 0,
    reverse: bool = false,
    prefix_only: bool = false,

    pub fn deinit(self: *State, a: std.mem.Allocator) void {
        if (self.call) |call| {
            call.bridge.abort(call.handle);
            // The provider owns unfinished calls until its IO owner releases them.
            _ = call.bridge.closeCall(call.handle) catch {};
        }
        if (self.draft) |value| a.free(value);
        if (self.candidates) |value| a.free(value);
        if (self.applied) |value| a.free(value);
        self.* = .{};
    }
    pub fn path(text: []const u8) ?[]const u8 {
        const separator = std.mem.indexOfAny(u8, text, " \t") orelse return null;
        if (text.len == 0 or text[0] != '@') return null;
        var value = std.mem.trimStart(u8, text[separator..], " \t");
        if (value.len > 0 and (value[0] == '"' or value[0] == '\'')) {
            const delimiter = value[0];
            value = value[1..];
            if (value.len > 0 and value[value.len - 1] == delimiter) value = value[0 .. value.len - 1];
            if (std.mem.indexOfScalar(u8, value, delimiter) != null) return null;
        } else if (std.mem.indexOfAny(u8, value, " \t") != null) return null;
        if (std.mem.indexOfAny(u8, value, "\r\n\x00") != null) return null;
        return value;
    }
    pub fn next(self: *State, a: std.mem.Allocator, reverse: bool, common: bool) !?[]u8 {
        const bytes = self.candidates orelse return null;
        var names = std.mem.tokenizeScalar(u8, bytes, 0);
        const first = names.next() orelse return null;
        var prefix = first;
        var count: usize = 1;
        while (names.next()) |name| {
            var length: usize = 0;
            while (length < @min(prefix.len, name.len) and prefix[length] == name[length]) length += 1;
            while (!std.unicode.utf8ValidateSlice(prefix[0..length])) length -= 1;
            prefix = prefix[0..length];
            count += 1;
        }
        const original = path(self.draft.?) orelse return null;
        var selected = first;
        if (common and prefix.len > original.len) {
            selected = prefix;
            self.index = if (reverse) count - 1 else 0;
            self.prefix_only = count > 1;
        } else {
            if (common and reverse) self.index = count - 1;
            if (!common) self.index = if (self.prefix_only) (if (reverse) count - 1 else 0) else if (reverse) (self.index + count - 1) % count else (self.index + 1) % count;
            self.prefix_only = false;
            names.reset();
            for (0..self.index + 1) |_| selected = names.next().?;
        }
        // The local builtin parser accepts either enclosing quote character.
        const delimiter: u8 = if (std.mem.indexOfScalar(u8, selected, '"') == null) '"' else '\'';
        if (std.mem.indexOfScalar(u8, selected, delimiter) != null) return error.UnsupportedPathQuotes;
        const end = std.mem.indexOfAny(u8, self.draft.?, " \t").?;
        const name = self.draft.?[0..end];
        const quoted = std.mem.eql(u8, name, "@dl") or std.mem.eql(u8, name, "@up") or std.mem.indexOfAny(u8, selected, " \t") != null;
        const result = if (quoted) try std.fmt.allocPrint(a, "{s} {c}{s}{c}", .{ name, delimiter, selected, delimiter }) else try std.fmt.allocPrint(a, "{s} {s}", .{ name, selected });
        if (self.applied) |previous| a.free(previous);
        self.applied = try a.dupe(u8, result);
        return result;
    }
};

test "builtin completion quotes metacharacters and completes Unicode names" {
    const a = std.testing.allocator;
    const script = try command(a, "/tmp/a 'b", "$(touch bad);");
    defer a.free(script);
    try std.testing.expect(std.mem.indexOf(u8, script, "zw_p='$(touch bad);'") != null);
    var state: State = .{ .draft = try a.dupe(u8, "@dl 日"), .candidates = try a.dupe(u8, "日志一.txt\x00日志二.txt\x00") };
    defer state.deinit(a);
    const completed = (try state.next(a, false, true)).?;
    defer a.free(completed);
    try std.testing.expectEqualStrings("@dl \"日志\"", completed);
    const cycled = (try state.next(a, false, false)).?;
    defer a.free(cycled);
    try std.testing.expectEqualStrings("@dl \"日志一.txt\"", cycled);
}
