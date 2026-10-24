//! Explicit application-diagnostic export. Session/AI/terminal content never
//! enters the archive. Capture runs before the caller opens its native picker.
const std = @import("std");

pub const redaction_revision: u32 = 1;
pub const max_files: usize = 128;
pub const max_file_bytes: usize = 16 * 1024 * 1024;
pub const max_total_bytes: usize = 128 * 1024 * 1024;
pub const Stage = enum { capture, redact, write, publish };
pub const Failure = struct {
    stage: Stage = .capture,
    source: [64]u8 = @splat(0),
    source_len: usize = 0,
    code: ?anyerror = null,

    pub fn sourceName(self: *const Failure) []const u8 {
        return self.source[0..self.source_len];
    }
    fn set(self: *Failure, stage: Stage, source: []const u8, code: ?anyerror) void {
        self.stage = stage;
        self.source_len = @min(source.len, self.source.len);
        @memcpy(self.source[0..self.source_len], source[0..self.source_len]);
        self.code = code;
    }
};
/// A worker may supply its thread-safe cancellation flag. The callback must
/// not mutate UI or the Plan. Checks bracket bounded reads and atomic publish.
pub const Cancellation = struct {
    context: ?*anyopaque = null,
    is_cancelled: ?*const fn (?*anyopaque) bool = null,
    fn check(self: Cancellation) !void {
        if (self.is_cancelled) |read| if (read(self.context)) return error.Cancelled;
    }
};
pub const CaptureOptions = struct {
    operation_id: u64,
    cancel: Cancellation = .{},
    failure: ?*Failure = null,
    /// Resolved Library/Logs directory; null preserves legacy callers.
    diagnostic_directory: ?[]const u8 = null,
};
const Source = struct {
    name: []u8,
    handle: std.Io.File,
    identity: std.Io.File.Stat,
    frozen_bytes: u64,
    /// Only the immutable, already-redacted snapshot survives capture. No
    /// borrowed pathname, future file version or raw free-form body is read
    /// after the native dialog returns.
    content: []u8,
    structured_records: usize,
    removed_spans: usize,
};

pub const Plan = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    operation_id: u64,
    diagnostic_directory: [:0]u8,
    files: std.ArrayList(Source) = .empty,
    failure: Failure = .{},

    /// Enumerate only this application's current/rotated diagnostic names.
    /// Keeping descriptors AND an immutable redacted prefix makes append,
    /// rename, rotation and same-name replacement after capture irrelevant.
    pub fn capture(allocator: std.mem.Allocator, io: std.Io, data_directory: []const u8, options: CaptureOptions) !Plan {
        return captureInner(allocator, io, data_directory, options) catch |err| {
            if (options.failure) |issue| issue.code = err;
            return err;
        };
    }
    fn captureInner(allocator: std.mem.Allocator, io: std.Io, data_directory: []const u8, options: CaptureOptions) !Plan {
        if (options.failure) |issue| issue.* = .{};
        if (options.operation_id == 0) return error.InvalidDiagnosticOperation;
        if (!std.fs.path.isAbsolute(data_directory)) return error.InvalidDiagnosticDirectory;
        try options.cancel.check();
        var root = try std.Io.Dir.openDirAbsolute(io, data_directory, .{});
        defer root.close(io);
        var logs = root.openDir(io, options.diagnostic_directory orelse "logs", .{ .iterate = true, .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound => return error.NoDiagnosticLogs,
            else => return err,
        };
        defer logs.close(io);
        const actual_directory = try logs.realPathFileAlloc(io, ".", allocator);
        var self: Plan = .{ .allocator = allocator, .io = io, .operation_id = options.operation_id, .diagnostic_directory = actual_directory };
        errdefer self.deinit();
        var total: u64 = 0;
        var iterator = logs.iterate();
        while (true) {
            if (options.failure) |issue| issue.set(.capture, "", null);
            const entry = (try iterator.next(io)) orelse break;
            if (!isDiagnosticName(entry.name) or entry.kind != .file) continue;
            if (options.failure) |issue| issue.set(.capture, entry.name, null);
            try options.cancel.check();
            if (self.files.items.len == max_files) return error.TooManyDiagnosticFiles;
            const file = try logs.openFile(io, entry.name, .{ .follow_symlinks = false, .allow_directory = false });
            errdefer file.close(io);
            const before = try file.stat(io);
            if (before.kind != .file) return error.DiagnosticSourceNotRegular;
            if (before.size > max_file_bytes or total + before.size > max_total_bytes) return error.DiagnosticBudgetExceeded;
            const raw = try allocator.alloc(u8, @intCast(before.size));
            defer allocator.free(raw);
            var used: usize = 0;
            while (used < raw.len) {
                try options.cancel.check();
                const count = try file.readPositional(io, &.{raw[used..][0..@min(raw.len - used, 4096)]}, used);
                if (count == 0) return error.DiagnosticSourceTruncated;
                used += count;
            }
            const after = try file.stat(io);
            if (after.inode != before.inode or after.kind != .file or after.size < before.size) return error.DiagnosticSourceChanged;
            // Appending is permitted, but a same-length in-place rewrite is
            // not passed off as the version whose metadata we captured.
            if (after.size == before.size and (!std.meta.eql(before.mtime, after.mtime) or !std.meta.eql(before.ctime, after.ctime))) return error.DiagnosticSourceChanged;
            if (options.failure) |issue| issue.stage = .redact;
            const safe = try redact(allocator, raw, options.cancel);
            errdefer allocator.free(safe.content);
            const name = try allocator.dupe(u8, entry.name);
            errdefer allocator.free(name);
            try self.files.append(allocator, .{ .name = name, .handle = file, .identity = before, .frozen_bytes = before.size, .content = safe.content, .structured_records = safe.records, .removed_spans = safe.removed_spans });
            total += before.size;
        }
        if (self.files.items.len == 0) return error.NoDiagnosticLogs;
        std.mem.sort(Source, self.files.items, {}, struct {
            fn less(_: void, a: Source, b: Source) bool {
                return std.mem.lessThan(u8, a.name, b.name);
            }
        }.less);
        return self;
    }

    pub fn deinit(self: *Plan) void {
        for (self.files.items) |source| {
            source.handle.close(self.io);
            self.allocator.free(source.name);
            self.allocator.free(source.content);
        }
        self.files.deinit(self.allocator);
        self.allocator.free(self.diagnostic_directory);
        self.* = undefined;
    }

    /// No target or temporary file exists on picker Cancel. A failing/cancelled
    /// write removes only its own temporary file and preserves an old target.
    pub fn write(self: *Plan, target_absolute_path: []const u8, cancel: Cancellation) !void {
        self.writeInner(target_absolute_path, cancel) catch |err| {
            self.failure.code = err;
            return err;
        };
    }
    fn writeInner(self: *Plan, target_absolute_path: []const u8, cancel: Cancellation) !void {
        self.failure = .{};
        self.failure.stage = .write;
        try cancel.check();
        if (!std.fs.path.isAbsolute(target_absolute_path) or std.mem.indexOfScalar(u8, target_absolute_path, 0) != null) return error.InvalidDiagnosticTarget;
        const parent = std.fs.path.dirname(target_absolute_path) orelse return error.InvalidDiagnosticTarget;
        const actual_parent = try std.Io.Dir.realPathFileAbsoluteAlloc(self.io, parent, self.allocator);
        defer self.allocator.free(actual_parent);
        if (std.mem.eql(u8, actual_parent, self.diagnostic_directory)) return error.DiagnosticTargetInsideSource;
        const existing = std.Io.Dir.cwd().statFile(self.io, target_absolute_path, .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
        if (existing) |value| {
            if (value.kind != .file) return error.DiagnosticTargetNotRegular;
            for (self.files.items) |source| if (source.identity.inode == value.inode) return error.DiagnosticTargetIsSource;
        }
        var atomic = try std.Io.Dir.cwd().createFileAtomic(self.io, target_absolute_path, .{ .replace = true, .permissions = @fromBackingInt(@intCast(0o600)) });
        defer atomic.deinit(self.io);
        var output_buffer: [8192]u8 = undefined;
        var output = atomic.file.writer(self.io, &output_buffer);
        var compression_buffer: [std.compress.flate.max_window_len]u8 = undefined;
        var gzip = try std.compress.flate.Compress.init(&output.interface, &compression_buffer, .gzip, .fastest);
        var tar: std.tar.Writer = .{ .underlying_writer = &gzip.writer };
        const manifest_bytes = try self.manifest();
        defer self.allocator.free(manifest_bytes);
        try tar.writeFileBytes("manifest.json", manifest_bytes, .{ .mode = 0o600 });
        for (self.files.items) |source| {
            self.failure.set(.write, source.name, null);
            try cancel.check();
            const path = try std.fmt.allocPrint(self.allocator, "diagnostics/{s}", .{source.name});
            defer self.allocator.free(path);
            try tar.writeFileBytes(path, source.content, .{ .mode = 0o600 });
        }
        self.failure.set(.write, "", null);
        try tar.finishPedantically();
        try gzip.finish();
        try output.interface.flush();
        try atomic.file.sync(self.io);
        self.failure.stage = .publish;
        try cancel.check();
        try atomic.replace(self.io);
    }

    fn manifest(self: *const Plan) ![]u8 {
        const Item = struct { path: []const u8, inode: u64, frozen_source_bytes: u64, exported_bytes: usize, structured_records: usize, removed_spans: usize };
        const items = try self.allocator.alloc(Item, self.files.items.len);
        defer self.allocator.free(items);
        for (self.files.items, items) |source, *item| item.* = .{ .path = source.name, .inode = @intCast(source.identity.inode), .frozen_source_bytes = source.frozen_bytes, .exported_bytes = source.content.len, .structured_records = source.structured_records, .removed_spans = source.removed_spans };
        return std.json.Stringify.valueAlloc(self.allocator, .{
            .format = "zerowork-application-diagnostics-v1",
            .operation_id = self.operation_id,
            .redaction_policy_revision = redaction_revision,
            .redaction = "Only validated timestamp/elapsed/level/module and allowlisted error codes are retained. Free-form messages and unstructured content are removed. Original files are unchanged.",
            .source_boundary = "Immutable redacted snapshots captured before the native destination picker. Later appends, rotation and replacement are excluded.",
            .files = items,
        }, .{ .whitespace = .indent_2 });
    }
};

pub fn isDiagnosticName(name: []const u8) bool {
    const base = if (std.mem.endsWith(u8, name, ".1")) name[0 .. name.len - 2] else name;
    if (std.mem.eql(u8, base, "app-unknown.log")) return true;
    if (base.len != "app-YYYYMMDD-HHMMSS.log".len or !std.mem.startsWith(u8, base, "app-") or base[12] != '-' or !std.mem.endsWith(u8, base, ".log")) return false;
    for (base[4..12]) |byte| if (!std.ascii.isDigit(byte)) return false;
    for (base[13..19]) |byte| if (!std.ascii.isDigit(byte)) return false;
    return true;
}

const Redacted = struct { content: []u8, records: usize = 0, removed_spans: usize = 0 };
fn redact(allocator: std.mem.Allocator, raw: []const u8, cancel: Cancellation) !Redacted {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    var result: Redacted = .{ .content = undefined };
    var previous_removed = false;
    var lines = std.mem.splitScalar(u8, raw, '\n');
    while (lines.next()) |line| {
        try cancel.check();
        if (line.len == 0) continue;
        if (header(line)) |value| {
            if (output.items.len + 160 > max_file_bytes) return error.DiagnosticRedactionBudgetExceeded;
            try output.appendSlice(allocator, value.prefix);
            if (errorCode(value.message)) |code| {
                try output.appendSlice(allocator, " error_code=");
                try output.appendSlice(allocator, code);
            }
            try output.appendSlice(allocator, " [free-form diagnostic message removed]\n");
            result.records += 1;
            previous_removed = false;
        } else if (!previous_removed) {
            if (output.items.len + 64 > max_file_bytes) return error.DiagnosticRedactionBudgetExceeded;
            try output.appendSlice(allocator, "[unstructured diagnostic content removed]\n");
            result.removed_spans += 1;
            previous_removed = true;
        }
    }
    result.content = try output.toOwnedSlice(allocator);
    return result;
}
const Header = struct { prefix: []const u8, message: []const u8 };
fn header(line: []const u8) ?Header {
    const end = std.mem.indexOfScalar(u8, line, ']') orelse return null;
    if (end > 80) return null;
    var tokens = std.mem.tokenizeAny(u8, line[0..end], " ");
    const time = tokens.next() orelse return null;
    const elapsed = tokens.next() orelse return null;
    const level = tokens.next() orelse return null;
    const module = tokens.next() orelse return null;
    if (tokens.next() != null or time.len != 12 or time[2] != ':' or time[5] != ':' or time[8] != '.') return null;
    for (time, 0..) |byte, index| if (index != 2 and index != 5 and index != 8 and !std.ascii.isDigit(byte)) return null;
    if (elapsed.len < 4 or elapsed.len > 24 or elapsed[0] != '+' or !std.mem.endsWith(u8, elapsed, "ms")) return null;
    for (elapsed[1 .. elapsed.len - 2]) |byte| if (!std.ascii.isDigit(byte)) return null;
    if (!oneOf(level, &.{ "DEBUG", "INFO", "WARN", "ERROR" }) or !oneOf(module, &.{ "app", "ui", "workspace", "ssh", "vt", "transfer", "ai", "config" })) return null;
    return .{ .prefix = line[0 .. end + 1], .message = line[end + 1 ..] };
}
fn errorCode(message: []const u8) ?[]const u8 {
    for ([_][]const u8{ "OutOfMemory", "AccessDenied", "PermissionDenied", "InputOutput", "NoSpaceLeft", "SystemResources", "ConnectionClosed", "ConnectionReset", "ConnectionRefused", "NetworkUnreachable", "AuthenticationFailed", "HostKeyMismatch", "KeyExchangeFailed", "Timeout", "Cancelled", "FileNotFound", "BrokenPipe", "StaleOwner", "TerminalClosed", "NativeDialogUnavailable" }) |code| {
        var cursor: usize = 0;
        while (std.mem.indexOfPos(u8, message, cursor, code)) |index| {
            const end = index + code.len;
            if ((index == 0 or !identifier(message[index - 1])) and (end == message.len or !identifier(message[end]))) return code;
            cursor = end;
        }
    }
    return null;
}
fn identifier(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_';
}
fn oneOf(value: []const u8, choices: []const []const u8) bool {
    for (choices) |choice| if (std.mem.eql(u8, value, choice)) return true;
    return false;
}
