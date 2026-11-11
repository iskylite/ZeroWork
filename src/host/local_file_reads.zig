//! Bounded, cancellable text paging over a frozen host-local target. Each
//! page checks the complete file version, even when only a few bytes return.
const std = @import("std");
const builtin = @import("builtin");
const paths = @import("local_path.zig");
const CancelToken = @import("../ai/provider.zig").CancelToken;
const Sha256 = std.crypto.hash.sha2.Sha256;

const version_prefix = "zw1:";
pub const Version = [version_prefix.len + 64]u8;
pub const max_page_bytes = 8 * 1024;
pub const max_version_bytes = 64 * 1024 * 1024;
pub const version_time_ms = 3_000;
const chunk_size = 32 * 1024;

pub const FileState = struct {
    identity: paths.Identity,
    stat: std.Io.File.Stat,
    uid: u32,
    gid: u32,
    flags: u32,
    birth_ns: i96,

    pub fn unchanged(self: FileState, other: FileState) bool {
        return std.meta.eql(self.identity, other.identity) and self.stat.size == other.stat.size and
            self.stat.permissions == other.stat.permissions and self.stat.nlink == other.stat.nlink and
            self.stat.mtime.nanoseconds == other.stat.mtime.nanoseconds and
            self.stat.ctime.nanoseconds == other.stat.ctime.nanoseconds and
            self.uid == other.uid and self.gid == other.gid and self.flags == other.flags and self.birth_ns == other.birth_ns;
    }
};

fn timeNs(ts: std.c.timespec) i96 {
    return @as(i96, ts.sec) * std.time.ns_per_s + ts.nsec;
}

pub fn fileState(file: std.Io.File, _: std.Io) !FileState {
    var raw: std.c.Stat = undefined;
    while (true) {
        switch (std.c.errno(std.c.fstat(file.handle, &raw))) {
            .SUCCESS => break,
            .INTR => continue,
            else => return error.FileStatFailed,
        }
    }
    if (raw.mode & std.c.S.IFMT != std.c.S.IFREG or raw.size < 0) return error.NotRegularFile;
    return .{
        .identity = paths.Identity.fromStat(raw),
        .stat = std.Io.Threaded.statFromPosix(&raw),
        .uid = raw.uid,
        .gid = raw.gid,
        .flags = if (builtin.os.tag == .macos) raw.flags else 0,
        .birth_ns = if (builtin.os.tag == .macos) timeNs(raw.birthtimespec) else 0,
    };
}

fn hashInteger(hasher: *Sha256, value: anytype) void {
    const T = @TypeOf(value);
    var bytes: [@divExact(@bitSizeOf(T), 8)]u8 = undefined;
    std.mem.writeInt(T, &bytes, value, .little);
    hasher.update(&bytes);
}

fn beginVersion(state: FileState) Sha256 {
    var hash = Sha256.init(.{});
    hash.update("ZeroWork host local file version 1\x00");
    hashInteger(&hash, state.identity.device);
    hashInteger(&hash, state.identity.inode);
    hashInteger(&hash, state.stat.size);
    hashInteger(&hash, @as(u32, @intCast(@backingInt(state.stat.permissions))));
    hashInteger(&hash, @as(u64, @intCast(state.stat.nlink)));
    hashInteger(&hash, state.stat.mtime.nanoseconds);
    hashInteger(&hash, state.uid);
    hashInteger(&hash, state.gid);
    hashInteger(&hash, state.flags);
    hashInteger(&hash, state.birth_ns);
    // A filesystem rename can change ctime without changing the file.
    // ctime remains part of in-flight change detection (FileState.unchanged).
    return hash;
}

fn finishVersion(hasher: *Sha256) Version {
    return version_prefix.* ++ std.fmt.bytesToHex(hasher.finalResult(), .lower);
}

/// Same version for buffered writers and the streaming read path.
pub fn version(state: FileState, bytes: []const u8) Version {
    var hash = beginVersion(state);
    hash.update(bytes);
    return finishVersion(&hash);
}

pub fn validateVersion(token: []const u8) !void {
    if (token.len != @sizeOf(Version) or !std.mem.startsWith(u8, token, version_prefix))
        return error.VersionFormatUnsupported;
    for (token[version_prefix.len..]) |ch| {
        if (!std.ascii.isDigit(ch) and !(ch >= 'a' and ch <= 'f')) return error.VersionFormatUnsupported;
    }
}

pub const ReadOptions = struct {
    offset: ?u64 = null,
    start_line: ?u64 = null,
    max_lines: ?u32 = null,
    max_bytes: usize = 4096,
    expected_version: ?[]const u8 = null,
    /// Host-side limit, never a model parameter.
    version_byte_budget: u64 = max_version_bytes,
};

pub const Page = struct {
    bytes: []const u8,
    start_offset: u64,
    end_offset: u64,
    start_line: ?u64 = null,
    end_line: ?u64 = null,
    next_offset: ?u64 = null,
    next_line: ?u64 = null,
    /// A byte cap split a logical line. Continue at next_offset.
    line_fragment: bool = false,
    truncated: bool,
    total_bytes: u64,
    version: Version,
    /// Borrowed from the resolved target. Only the host may mint its tool ID.
    file_ref: ?paths.Reference = null,
};

const Range = union(enum) {
    bytes: u64,
    lines: struct { start: u64, count: u32 },

    fn fromOptions(options: ReadOptions) !Range {
        if (options.max_bytes < 4 or options.max_bytes > max_page_bytes) return error.InvalidReadRange;
        const ranged_by_line = options.start_line != null or options.max_lines != null;
        if (options.offset != null and ranged_by_line) return error.InvalidReadRange;
        const range: Range = if (ranged_by_line) .{ .lines = .{
            .start = options.start_line orelse 1,
            .count = options.max_lines orelse 100,
        } } else .{ .bytes = options.offset orelse 0 };
        const continuation = switch (range) {
            .bytes => |start| start != 0,
            .lines => |lines| blk: {
                if (lines.start == 0 or lines.count == 0 or lines.count > 1_000) return error.InvalidReadRange;
                break :blk lines.start != 1;
            },
        };
        if (options.expected_version) |token| {
            try validateVersion(token);
        } else if (continuation) return error.ExpectedVersionRequired;
        return range;
    }
};

fn continuationByte(ch: u8) bool {
    return ch & 0b1100_0000 == 0b1000_0000;
}

/// Accept only a trailing *incomplete* code point, never malformed UTF-8.
fn completePrefix(bytes: []const u8) !usize {
    if (bytes.len == 0 or bytes[bytes.len - 1] < 0x80) return bytes.len;
    var last = bytes.len - 1;
    while (continuationByte(bytes[last])) {
        if (last == 0 or bytes.len - last >= 4) return error.UnsupportedTextEncoding;
        last -= 1;
    }
    const len = std.unicode.utf8ByteSequenceLength(bytes[last]) catch return error.UnsupportedTextEncoding;
    return if (bytes.len - last < len) last else bytes.len;
}

const Capture = struct {
    buffer: []u8,
    used: usize = 0,
    first_offset: ?u64 = null,
    line: u64 = 1,
    newlines: u32 = 0,
    done: bool = false,
    invalid_boundary: bool = false,

    fn add(self: *Capture, offset: u64, chunk: []const u8, range: Range) void {
        if (self.done) return;
        switch (range) {
            .bytes => |start| {
                if (start >= offset + chunk.len) return;
                const index: usize = @intCast(start -| offset);
                if (self.first_offset == null) {
                    self.first_offset = start;
                    self.invalid_boundary = continuationByte(chunk[index]);
                }
                self.append(chunk[index..]);
            },
            .lines => |lines| {
                var index: usize = 0;
                while (index < chunk.len and !self.done) {
                    const end = if (std.mem.indexOfScalar(u8, chunk[index..], '\n')) |match| index + match + 1 else chunk.len;
                    const line = chunk[index..end];
                    const newline = line[line.len - 1] == '\n';
                    if (self.line >= lines.start) {
                        if (self.first_offset == null) self.first_offset = offset + index;
                        self.append(line);
                        if (newline) {
                            self.newlines += 1;
                            if (self.newlines == lines.count) self.done = true;
                        }
                    }
                    if (newline) self.line += 1;
                    index = end;
                }
            },
        }
    }

    fn append(self: *Capture, bytes: []const u8) void {
        const count = @min(bytes.len, self.buffer.len - self.used);
        @memcpy(self.buffer[self.used..][0..count], bytes[0..count]);
        self.used += count;
        self.done = self.used == self.buffer.len;
    }
};

const Streamed = struct { size: u64, version: Version };

fn streamText(
    io: std.Io,
    resolved: *const paths.Resolved,
    expected_version: ?[]const u8,
    byte_budget: u64,
    deadline: std.Io.Timestamp,
    cancel: *const CancelToken,
    context: anytype,
    comptime observe: fn (@TypeOf(context), u64, []const u8) anyerror!void,
) !Streamed {
    if (cancel.isCancelled()) return error.Cancelled;
    const file = try resolved.openFile(io);
    defer file.close(io);
    const before = try fileState(file, io);
    if (before.stat.size > @min(max_version_bytes, byte_budget)) return error.VersionBudgetExceeded;

    var hash = beginVersion(before);
    var chunk: [chunk_size + 3]u8 = undefined;
    var carry: usize = 0;
    var valid_utf8 = true;
    var offset: u64 = 0;
    while (offset < before.stat.size) {
        if (cancel.isCancelled()) return error.Cancelled;
        if (std.Io.Clock.awake.now(io).compare(.gte, deadline)) return error.VersionBudgetExceeded;
        const remaining: usize = @intCast(@min(before.stat.size - offset, chunk_size));
        const n = try file.readPositional(io, &.{chunk[carry..][0..remaining]}, offset);
        if (n == 0) return error.SourceChanged;
        const fresh = chunk[carry..][0..n];
        hash.update(fresh);
        // Every raw byte enters the hash exactly once. Keep at most three
        // incomplete UTF-8 bytes for validation on the following read.
        const bytes = chunk[0 .. carry + n];
        if (valid_utf8) {
            const prefix = completePrefix(bytes) catch blk: {
                valid_utf8 = false;
                break :blk bytes.len;
            };
            valid_utf8 = valid_utf8 and std.unicode.utf8ValidateSlice(bytes[0..prefix]) and
                std.mem.indexOfScalar(u8, bytes, 0) == null;
            if (valid_utf8) try observe(context, offset, fresh);
            carry = if (valid_utf8) bytes.len - prefix else 0;
            @memmove(chunk[0..carry], bytes[prefix..][0..carry]);
        }
        offset += n;
    }

    if (cancel.isCancelled()) return error.Cancelled;
    if (!before.unchanged(try fileState(file, io))) return error.SourceChanged;
    try resolved.revalidate(io);
    const token = finishVersion(&hash);
    if (expected_version) |expected| {
        if (!std.mem.eql(u8, &token, expected)) return error.SourceChanged;
    }
    if (!valid_utf8 or carry != 0) return error.UnsupportedTextEncoding;
    return .{ .size = before.stat.size, .version = token };
}

pub fn deadlineFromNow(io: std.Io) std.Io.Timestamp {
    return std.Io.Clock.awake.now(io).addDuration(std.Io.Duration.fromMilliseconds(version_time_ms));
}

pub fn readText(
    allocator: std.mem.Allocator,
    io: std.Io,
    resolved: *const paths.Resolved,
    options: ReadOptions,
    cancel: *const CancelToken,
) !Page {
    const range = try Range.fromOptions(options);
    var preview: [max_page_bytes]u8 = undefined;
    var capture: Capture = .{ .buffer = preview[0..options.max_bytes] };
    const PageCapture = struct {
        capture: *Capture,
        range: Range,
        fn add(self: @This(), offset: u64, chunk: []const u8) !void {
            self.capture.add(offset, chunk, self.range);
        }
    };
    const streamed = try streamText(io, resolved, options.expected_version, options.version_byte_budget, deadlineFromNow(io), cancel, PageCapture{
        .capture = &capture,
        .range = range,
    }, PageCapture.add);
    if (capture.invalid_boundary) return error.InvalidUtf8Boundary;
    const size = streamed.size;
    const start = capture.first_offset orelse switch (range) {
        .bytes => |requested| if (requested == size) size else return error.InvalidReadRange,
        .lines => |lines| if (lines.start == capture.line) size else return error.InvalidReadRange,
    };
    // The original file was checked. Only the cap can have split this tail.
    const text = preview[0..try completePrefix(preview[0..capture.used])];
    const end = start + text.len;
    var page: Page = .{
        .bytes = try allocator.dupe(u8, text),
        .start_offset = start,
        .end_offset = end,
        .next_offset = if (end < size) end else null,
        .truncated = end < size,
        .total_bytes = size,
        .version = streamed.version,
        .file_ref = resolved.reference() catch null,
    };
    switch (range) {
        .bytes => {},
        .lines => |lines| {
            page.start_line = lines.start;
            if (text.len != 0) {
                const newlines = std.mem.count(u8, text, "\n");
                const ends_at_newline = text[text.len - 1] == '\n';
                page.end_line = lines.start + newlines - @intFromBool(ends_at_newline);
                if (page.truncated) {
                    page.line_fragment = !ends_at_newline;
                    if (ends_at_newline) page.next_line = lines.start + newlines;
                }
            }
        },
    }
    return page;
}

pub const max_pattern_bytes = 256;
const search_history_bytes = max_pattern_bytes + 64;
const search_snippet_bytes = search_history_bytes + 128;
const context_line_bytes = 128;
pub const max_context_lines = 2;

pub const ContextLine = struct {
    line: u64,
    text: []const u8,
    truncated: bool,
};

pub const LineMatch = struct {
    line: u64,
    column: u64,
    snippet: []const u8,
    snippet_offset: u64,
    snippet_truncated: bool,
    before: []const ContextLine = &.{},
    after: []ContextLine = &.{},
};

pub const FileMatches = struct {
    matches: []const LineMatch,
    more: bool,
    version: Version,
    total_bytes: u64,
};

const ContextPreview = struct {
    line: u64 = 0,
    bytes: [context_line_bytes]u8 = undefined,
    len: usize = 0,
    truncated: bool = false,

    fn clone(self: *const ContextPreview, allocator: std.mem.Allocator) !ContextLine {
        const text = self.bytes[0..self.len];
        const end = try completePrefix(text);
        return .{
            .line = self.line,
            .text = try allocator.dupe(u8, text[0..end]),
            .truncated = self.truncated or end < self.len,
        };
    }
};

const MatchCollector = struct {
    allocator: std.mem.Allocator,
    pattern: []const u8,
    prefix: [max_pattern_bytes]u16 = @splat(0),
    matched_prefix: u16 = 0,
    skip: u32,
    results: []LineMatch,
    used: usize = 0,
    more: bool = false,
    line: u64 = 1,
    line_bytes: u64 = 0,
    match_column: ?u64 = null,
    history: [search_history_bytes]u8 = undefined,
    snippet: [search_snippet_bytes]u8 = undefined,
    snippet_len: usize = 0,
    snippet_offset: u64 = 0,
    context_lines: u8,
    current: ContextPreview = .{},
    recent: [max_context_lines]ContextPreview = @splat(.{}),
    after_counts: [128]u8 = @splat(0),

    fn init(a: std.mem.Allocator, pattern: []const u8, skip: u32, results: []LineMatch, context_lines: u8) MatchCollector {
        var result: MatchCollector = .{
            .allocator = a,
            .pattern = pattern,
            .skip = skip,
            .results = results,
            .context_lines = context_lines,
        };
        var matched: u16 = 0;
        for (pattern[1..], 1..) |ch, i| {
            matched = result.advance(matched, ch);
            result.prefix[i] = matched;
        }
        return result;
    }

    fn advance(self: *const MatchCollector, previous: u16, ch: u8) u16 {
        var matched = previous;
        while (matched > 0 and self.pattern[matched] != ch) matched = self.prefix[matched - 1];
        if (self.pattern[matched] == ch) matched += 1;
        return matched;
    }

    fn add(self: *MatchCollector, _: u64, chunk: []const u8) !void {
        for (chunk) |ch| {
            if (self.more and !self.needsContext()) return;
            if (ch == '\n') {
                try self.finishLine();
                self.line += 1;
                continue;
            }
            if (self.context_lines != 0 and self.current.len < self.current.bytes.len) {
                self.current.bytes[self.current.len] = ch;
                self.current.len += 1;
            }
            if (self.more) {
                self.line_bytes += 1;
                continue;
            }
            if (self.match_column != null) {
                if (self.snippet_len < self.snippet.len) {
                    self.snippet[self.snippet_len] = ch;
                    self.snippet_len += 1;
                }
            } else {
                self.history[self.line_bytes % self.history.len] = ch;
                self.matched_prefix = self.advance(self.matched_prefix, ch);
                if (self.matched_prefix == self.pattern.len) {
                    const end = self.line_bytes + 1;
                    self.match_column = end - self.pattern.len + 1;
                    self.snippet_offset = end -| self.history.len;
                    self.snippet_len = @intCast(end - self.snippet_offset);
                    const start = self.snippet_offset % self.history.len;
                    const first = @min(self.snippet_len, self.history.len - start);
                    @memcpy(self.snippet[0..first], self.history[start..][0..first]);
                    @memcpy(self.snippet[first..self.snippet_len], self.history[0 .. self.snippet_len - first]);
                }
            }
            self.line_bytes += 1;
        }
    }

    fn needsContext(self: *const MatchCollector) bool {
        if (self.context_lines == 0 or self.used == 0) return false;
        return self.line - self.results[self.used - 1].line <= self.context_lines;
    }

    fn previousLines(self: *const MatchCollector) ![]const ContextLine {
        const count = @min(self.context_lines, self.line - 1);
        if (count == 0) return &.{};
        const result = try self.allocator.alloc(ContextLine, @intCast(count));
        for (result, self.line - count..) |*item, line| item.* = try self.recent[line % self.recent.len].clone(self.allocator);
        return result;
    }

    fn finishLine(self: *MatchCollector) !void {
        if (self.context_lines != 0) {
            self.current.line = self.line;
            self.current.truncated = self.line_bytes > self.current.len;
            var i = self.used;
            while (i > 0) {
                i -= 1;
                const accepted = &self.results[i];
                if (self.line - accepted.line > self.context_lines) break;
                accepted.after[self.after_counts[i]] = try self.current.clone(self.allocator);
                self.after_counts[i] += 1;
            }
        }
        if (self.match_column) |column| {
            if (self.skip > 0) {
                self.skip -= 1;
            } else if (self.used == self.results.len) {
                self.more = true;
            } else {
                var start: usize = 0;
                while (start < self.snippet_len and continuationByte(self.snippet[start])) start += 1;
                const bytes = self.snippet[start..self.snippet_len];
                const end = try completePrefix(bytes);
                self.results[self.used] = .{
                    .line = self.line,
                    .column = column,
                    .snippet = try self.allocator.dupe(u8, bytes[0..end]),
                    .snippet_offset = self.snippet_offset + start,
                    .snippet_truncated = self.snippet_offset + start != 0 or self.snippet_offset + start + end < self.line_bytes,
                    .before = try self.previousLines(),
                    .after = try self.allocator.alloc(ContextLine, self.context_lines),
                };
                self.used += 1;
            }
        }
        if (self.context_lines != 0) {
            self.recent[self.line % self.recent.len] = self.current;
            self.current.len = 0;
        }
        self.line_bytes = 0;
        self.matched_prefix = 0;
        self.match_column = null;
        self.snippet_len = 0;
    }
};

pub fn validatePattern(pattern: []const u8) !void {
    if (pattern.len == 0 or pattern.len > max_pattern_bytes or std.mem.indexOfAny(u8, pattern, "\x00\n") != null or
        !std.unicode.utf8ValidateSlice(pattern))
        return error.InvalidSearchPattern;
}

/// Literal text match, at most one result per line. Complete file contents
/// are hashed once regardless of how many lines matched. Page and scratch
/// allocations have the lifetime of the caller's arena.
pub fn searchText(
    allocator: std.mem.Allocator,
    io: std.Io,
    resolved: *const paths.Resolved,
    pattern: []const u8,
    skip: u32,
    limit: usize,
    context_lines: u8,
    byte_budget: u64,
    deadline: std.Io.Timestamp,
    cancel: *const CancelToken,
) !FileMatches {
    try validatePattern(pattern);
    if (limit == 0 or limit > 128) return error.InvalidSearchLimit;
    if (context_lines > max_context_lines) return error.InvalidContextLines;
    const matches = try allocator.alloc(LineMatch, limit);
    var collector = MatchCollector.init(allocator, pattern, skip, matches, context_lines);
    const streamed = try streamText(io, resolved, null, byte_budget, deadline, cancel, &collector, MatchCollector.add);
    if (collector.line_bytes != 0 and (!collector.more or collector.needsContext())) try collector.finishLine();
    for (matches[0..collector.used], collector.after_counts[0..collector.used]) |*match, count| {
        match.after = match.after[0..count];
    }
    return .{ .matches = matches[0..collector.used], .more = collector.more, .version = streamed.version, .total_bytes = streamed.size };
}

test "streamed pages are bounded, versioned, and stable across aliases" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const sample = try allocator.alloc(u8, 96 * 1024);
    @memset(sample, 'x');
    @memcpy(sample[0..6], "abc你");
    @memcpy(sample[chunk_size - 1 ..][0..4], "🌱");
    try tmp.dir.writeFile(io, .{ .sub_path = "original", .data = sample });
    try tmp.dir.symLink(io, "original", "alias", .{});
    const original = try tmp.dir.realPathFileAlloc(io, "original", allocator);
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    const alias = try std.fmt.allocPrint(allocator, "{s}/alias", .{root});
    const path = try paths.resolve(allocator, io, .{
        .path = original,
        .conversation = @import("identity.zig").ConversationId.generate(),
    }, .file);
    defer path.deinit(allocator, io);
    const alt = try paths.resolve(allocator, io, .{ .path = alias }, .file);
    defer alt.deinit(allocator, io);
    var cancel: CancelToken = .{};
    const first = try readText(allocator, io, &path, .{ .max_bytes = 4 }, &cancel);
    try std.testing.expectEqualStrings("abc", first.bytes);
    try std.testing.expectEqual(@as(u64, 3), first.next_offset.?);
    try std.testing.expectEqualStrings(original, first.file_ref.?.absolute);
    try std.testing.expect(first.truncated);
    const second = try readText(allocator, io, &alt, .{
        .offset = first.next_offset,
        .max_bytes = 4,
        .expected_version = &first.version,
    }, &cancel);
    try std.testing.expectEqualStrings("你x", second.bytes);
    try std.testing.expectEqual(first.version, second.version);
    const descriptor = try alt.openFile(io);
    defer descriptor.close(io);
    try std.testing.expectEqual(first.version, version(try fileState(descriptor, io), sample));
    try std.testing.expectError(error.ExpectedVersionRequired, readText(allocator, io, &alt, .{ .offset = 1 }, &cancel));
    try std.testing.expectError(error.InvalidUtf8Boundary, readText(allocator, io, &alt, .{ .offset = 4, .expected_version = &first.version }, &cancel));
    try std.testing.expectError(error.InvalidReadRange, readText(allocator, io, &alt, .{ .offset = 1, .start_line = 1 }, &cancel));
    try std.testing.expectError(error.VersionFormatUnsupported, readText(allocator, io, &alt, .{ .expected_version = &(@as([64]u8, @splat('0'))) }, &cancel));

    const lines = try readText(allocator, io, &path, .{ .start_line = 1, .max_bytes = 4 }, &cancel);
    try std.testing.expect(lines.line_fragment);
    try std.testing.expectEqual(@as(u64, 1), lines.end_line.?);
    try std.testing.expectEqual(@as(u64, 3), lines.next_offset.?);
    try std.testing.expectEqual(@as(?u64, null), lines.next_line);

    sample[sample.len - 1] = 0;
    try tmp.dir.writeFile(io, .{ .sub_path = "original", .data = sample });
    try std.testing.expectError(error.SourceChanged, readText(allocator, io, &path, .{
        .offset = first.next_offset,
        .expected_version = &first.version,
    }, &cancel));
    try std.testing.expectError(error.UnsupportedTextEncoding, readText(allocator, io, &path, .{}, &cancel));
    cancel.cancel();
    try std.testing.expectError(error.Cancelled, readText(allocator, io, &path, .{}, &cancel));
}

test "line ranges retain BOM and CRLF without conflating empty lines and EOF" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    try tmp.dir.writeFile(io, .{ .sub_path = "lines", .data = "\xef\xbb\xbfhello\r\n\r\nlast" });
    const path = try paths.resolve(allocator, io, .{
        .path = try tmp.dir.realPathFileAlloc(io, "lines", allocator),
    }, .file);
    defer path.deinit(allocator, io);
    const cancel: CancelToken = .{};
    const first = try readText(allocator, io, &path, .{ .start_line = 1, .max_lines = 1 }, &cancel);
    try std.testing.expectEqualStrings("\xef\xbb\xbfhello\r\n", first.bytes);
    try std.testing.expectEqual(@as(u64, 2), first.next_line.?);
    try std.testing.expectEqual(@as(u64, 1), first.end_line.?);
    const next = try readText(allocator, io, &path, .{ .start_line = first.next_line, .expected_version = &first.version }, &cancel);
    try std.testing.expectEqualStrings("\r\nlast", next.bytes);
    try std.testing.expectEqual(@as(u64, 3), next.end_line.?);
    try std.testing.expect(!next.truncated);
}
