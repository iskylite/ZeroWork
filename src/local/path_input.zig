//! zsh path words for insertion into an existing terminal input, never a
//! command to execute. The caller retains the original session/generation and
//! dispatches through the terminal's actual input/paste mode after revalidation.
const std = @import("std");

pub const OwnedPaths = struct {
    allocator: std.mem.Allocator,
    paths: []const []const u8,

    pub fn deinit(self: *OwnedPaths) void {
        for (self.paths) |path| self.allocator.free(path);
        self.allocator.free(self.paths);
        self.paths = &.{};
    }
};

/// Decodes the native file_or_url payload before shell quoting. Split the
/// native list first: percent-encoded newlines remain inside one owned path.
/// No filesystem resolution, shell evaluation or transport side effects.
pub fn decodeDropPaths(allocator: std.mem.Allocator, payload: []const u8) !OwnedPaths {
    if (payload.len > 1024 * 1024) return error.DropTooLarge;
    if (!std.unicode.utf8ValidateSlice(payload) or std.mem.indexOfScalar(u8, payload, 0) != null) return error.InvalidPath;
    var paths: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (paths.items) |path| allocator.free(path);
        paths.deinit(allocator);
    }
    if (payload.len != 0) {
        var entries = std.mem.splitScalar(u8, payload, '\n');
        while (entries.next()) |entry| {
            if (paths.items.len == 1024) return error.TooManyPaths;
            const path = try decodeDropPath(allocator, entry);
            errdefer allocator.free(path);
            try paths.append(allocator, path);
        }
    }
    return .{ .allocator = allocator, .paths = try paths.toOwnedSlice(allocator) };
}

fn decodeDropPath(allocator: std.mem.Allocator, entry: []const u8) ![]u8 {
    if (entry.len == 0) return error.InvalidPath;
    if (entry[0] == '/') return allocator.dupe(u8, entry);
    if (entry.len < 7 or !std.ascii.eqlIgnoreCase(entry[0..7], "file://")) return error.NonLocalURL;
    const remainder = entry[7..];
    const slash = std.mem.indexOfScalar(u8, remainder, '/') orelse return error.InvalidFileURL;
    const authority = remainder[0..slash];
    if (authority.len != 0 and !std.ascii.eqlIgnoreCase(authority, "localhost")) return error.NonLocalURL;
    const encoded = remainder[slash..];
    // Query/fragment delimiters are not path bytes in a URL. Literal filename
    // '?' and '#' must be percent encoded (raw absolute paths remain literal).
    if (std.mem.indexOfAny(u8, encoded, "?#") != null) return error.InvalidFileURL;
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);
    try result.ensureTotalCapacity(allocator, encoded.len);
    var index: usize = 0;
    while (index < encoded.len) : (index += 1) {
        var byte = encoded[index];
        if (byte == '%') {
            if (encoded.len - index < 3) return error.InvalidPercentEncoding;
            const hi = std.fmt.charToDigit(encoded[index + 1], 16) catch return error.InvalidPercentEncoding;
            const lo = std.fmt.charToDigit(encoded[index + 2], 16) catch return error.InvalidPercentEncoding;
            byte = hi * 16 + lo;
            index += 2;
        }
        if (byte == 0) return error.InvalidPath;
        result.appendAssumeCapacity(byte);
    }
    if (!std.unicode.utf8ValidateSlice(result.items)) return error.InvalidPath;
    return result.toOwnedSlice(allocator);
}

/// Quotes decoded filesystem path strings and joins them with one ASCII space.
/// Returns allocator-owned bytes; an empty drop returns an empty allocation.
/// No command prefix, trailing separator, newline, or transport side effect.
///
/// ANSI-C quoting keeps control characters represented by editable text rather
/// than raw PTY input bytes. In particular a newline inside a filename never
/// becomes an accept-line key. This does not resolve paths or decode file URLs.
pub fn quotePaths(allocator: std.mem.Allocator, paths: []const []const u8) ![]u8 {
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);
    for (paths, 0..) |path, index| {
        if (path.len == 0 or !std.unicode.utf8ValidateSlice(path) or std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidPath;
        if (index != 0) try result.append(allocator, ' ');
        try result.appendSlice(allocator, "$'");
        var offset: usize = 0;
        while (offset < path.len) : (offset += 1) {
            const byte = path[offset];
            switch (byte) {
                '\'' => try result.appendSlice(allocator, "\\'"),
                '\\' => try result.appendSlice(allocator, "\\\\"),
                '\n' => try result.appendSlice(allocator, "\\n"),
                '\r' => try result.appendSlice(allocator, "\\r"),
                '\t' => try result.appendSlice(allocator, "\\t"),
                else => if (byte < 0x20 or byte == 0x7f) {
                    try appendHex(&result, allocator, byte);
                } else if (byte == 0xc2 and offset + 1 < path.len and path[offset + 1] >= 0x80 and path[offset + 1] <= 0x9f) {
                    // UTF-8 C1 controls must not imitate a terminal paste
                    // boundary. Escape both bytes, preserving the actual path.
                    try appendHex(&result, allocator, byte);
                    offset += 1;
                    try appendHex(&result, allocator, path[offset]);
                } else try result.append(allocator, byte),
            }
        }
        try result.append(allocator, '\'');
    }
    return result.toOwnedSlice(allocator);
}

fn appendHex(result: *std.ArrayList(u8), allocator: std.mem.Allocator, byte: u8) !void {
    const digits = "0123456789abcdef";
    try result.appendSlice(allocator, &.{ '\\', 'x', digits[byte >> 4], digits[byte & 0x0f] });
}

test "drop decoder preserves local path bytes and decodes file URLs before quoting" {
    const allocator = std.testing.allocator;
    var decoded = try decodeDropPaths(allocator, "/tmp/a b\n/tmp/it's\\mine%20literal\nfile:///tmp/line%0Anext%0D%09tab\nfile://localhost/tmp/%E4%B8%AD%E6%96%87%20%27quote%27%5C%23%3F\nfile:///");
    defer decoded.deinit();
    try std.testing.expectEqual(@as(usize, 5), decoded.paths.len);
    try std.testing.expectEqualStrings("/tmp/a b", decoded.paths[0]);
    try std.testing.expectEqualStrings("/tmp/it's\\mine%20literal", decoded.paths[1]);
    try std.testing.expectEqualStrings("/tmp/line\nnext\r\ttab", decoded.paths[2]);
    try std.testing.expectEqualStrings("/tmp/中文 'quote'\\#?", decoded.paths[3]);
    try std.testing.expectEqualStrings("/", decoded.paths[4]);
    const quoted = try quotePaths(allocator, decoded.paths);
    defer allocator.free(quoted);
    try std.testing.expect(std.mem.indexOfScalar(u8, quoted, '\n') == null);
    try std.testing.expect(std.mem.indexOf(u8, quoted, "line\\nnext\\r\\ttab") != null);
}

test "drop decoder rejects nonlocal malformed and invalid paths atomically" {
    const allocator = std.testing.allocator;
    for ([_][]const u8{ "https://localhost/tmp/a", "file://server/tmp/a", "file://user@localhost/tmp/a", "file://localhost:80/tmp/a", "relative/path" }) |payload|
        try std.testing.expectError(error.NonLocalURL, decodeDropPaths(allocator, payload));
    for ([_][]const u8{ "file://localhost", "file:///tmp/a?query", "file:///tmp/a#fragment" }) |payload|
        try std.testing.expectError(error.InvalidFileURL, decodeDropPaths(allocator, payload));
    for ([_][]const u8{ "file:///tmp/%", "file:///tmp/%0", "file:///tmp/%gg" }) |payload|
        try std.testing.expectError(error.InvalidPercentEncoding, decodeDropPaths(allocator, payload));
    for ([_][]const u8{ "/valid\n", "/valid\n\n/last", "/tmp/\x00", "/tmp/\xff", "file:///tmp/%00", "file:///tmp/%ff" }) |payload|
        try std.testing.expectError(error.InvalidPath, decodeDropPaths(allocator, payload));
}

test "drop decoder bounds the native payload and item count" {
    const allocator = std.testing.allocator;
    const payload = try allocator.alloc(u8, 1024 * 1024 + 1);
    defer allocator.free(payload);
    @memset(payload, 'a');
    payload[0] = '/';
    var exact = try decodeDropPaths(allocator, payload[0 .. payload.len - 1]);
    defer exact.deinit();
    try std.testing.expectEqual(@as(usize, 1024 * 1024), exact.paths[0].len);
    try std.testing.expectError(error.DropTooLarge, decodeDropPaths(allocator, payload));
    var entries: std.ArrayList(u8) = .empty;
    defer entries.deinit(allocator);
    for (0..1024) |index| {
        if (index != 0) try entries.append(allocator, '\n');
        try entries.appendSlice(allocator, "/a");
    }
    var many = try decodeDropPaths(allocator, entries.items);
    defer many.deinit();
    try std.testing.expectEqual(@as(usize, 1024), many.paths.len);
    try entries.appendSlice(allocator, "\n/a");
    try std.testing.expectError(error.TooManyPaths, decodeDropPaths(allocator, entries.items));
    var empty = try decodeDropPaths(allocator, "");
    defer empty.deinit();
    try std.testing.expectEqual(@as(usize, 0), empty.paths.len);
}

test "drop decoder releases all owned paths on allocation failure" {
    const Check = struct {
        fn run(allocator: std.mem.Allocator) !void {
            var paths = try decodeDropPaths(allocator, "/first\nfile:///tmp/line%0Anext\nfile://localhost/tmp/last");
            defer paths.deinit();
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Check.run, .{});
}

test "path insertion is quoted words without line acceptance or trailing separator" {
    const allocator = std.testing.allocator;
    const text = try quotePaths(allocator, &.{ "/tmp/a b", "/tmp/it's\\mine", "/tmp/新文件🙂\nnext\r\ttab" });
    defer allocator.free(text);
    try std.testing.expectEqualStrings("$'/tmp/a b' $'/tmp/it\\'s\\\\mine' $'/tmp/新文件🙂\\nnext\\r\\ttab'", text);
    for (text) |byte| try std.testing.expect(byte >= 0x20 and byte != 0x7f);
    const empty = try quotePaths(allocator, &.{});
    defer allocator.free(empty);
    try std.testing.expectEqual(@as(usize, 0), empty.len);
}

test "path insertion rejects invalid path values without returning partial input" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.InvalidPath, quotePaths(allocator, &.{""}));
    try std.testing.expectError(error.InvalidPath, quotePaths(allocator, &.{ "/valid", "/bad\x00path" }));
    try std.testing.expectError(error.InvalidPath, quotePaths(allocator, &.{"/bad\xff"}));
}

test "isolated real zsh printf restores Unicode and control paths as separate literal arguments" {
    const allocator = std.testing.allocator;
    const paths: []const []const u8 = &.{
        "/tmp/simple",
        "/tmp/space in file",
        "/tmp/single'quote",
        "/tmp/back\\slash",
        "/tmp/line\nnext\rline\ttab",
        "/tmp/中文/组合e\xcc\x81🙂",
        "/tmp/$(printf substitution);`printf backtick`\"*?[]{}!~",
        "/tmp/esc\x1b[201~\x07\x7f",
        "/tmp/csi\xc2\x9b200~",
    };
    const quoted = try quotePaths(allocator, paths);
    defer allocator.free(quoted);
    // Only this fixed builtin command runs; no input path is command text.
    const command = try std.fmt.allocPrint(allocator, "builtin printf '%s\\0' {s}", .{quoted});
    defer allocator.free(command);
    var sandbox = std.testing.tmpDir(.{});
    defer sandbox.cleanup();
    const cwd = try sandbox.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(cwd);
    var environment = std.process.Environ.Map.init(allocator);
    defer environment.deinit();
    try environment.put("HOME", cwd);
    try environment.put("ZDOTDIR", cwd);
    try environment.put("LC_ALL", "C");
    const result = try std.process.run(allocator, std.testing.io, .{
        .argv = &.{ "/bin/zsh", "-f", "-c", command },
        .cwd = .{ .dir = sandbox.dir },
        .environ_map = &environment,
        .stdout_limit = .limited(16 * 1024),
        .stderr_limit = .limited(1024),
        .timeout = .{ .duration = .{ .raw = .fromSeconds(3), .clock = .awake } },
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    try std.testing.expect(result.term.success());
    try std.testing.expectEqualStrings("", result.stderr);
    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(allocator);
    for (paths) |path| {
        try expected.appendSlice(allocator, path);
        try expected.append(allocator, 0);
    }
    try std.testing.expectEqualSlices(u8, expected.items, result.stdout);
}
