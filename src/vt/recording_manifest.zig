//! The single durable authority for new terminal recordings. TSV is discovery
//! compatibility only; raw offsets always refer to received PTY bytes.
const std = @import("std");
pub const execution = @import("../host/terminal_execution.zig");
pub const SourceKind = enum { local, ssh };
pub const Coverage = enum { complete, retained, gapped, partial, unavailable };
pub const Replayability = enum { verified, legacy_unverified, baseline_unavailable, unsupported };
pub const Position = struct { raw_offset: u64 = 0, event_sequence: u64 = 0 };
pub const Gap = struct { start: Position, end: Position, reason: []const u8, known_dropped_bytes: u64 = 0 };
pub const File = struct { path: []const u8, kind: enum { cast, raw, checkpoint }, committed_length: u64, checksum: []const u8 };
pub const Event = struct { sequence: u64, raw_offset: u64, raw_length: u64, cast_line: u64, kind: enum { output, resize, application, boundary } };
pub const Baseline = struct { event_sequence: u64, raw_offset: u64, kind: enum { initial_empty, checkpoint }, file_ref: ?[]const u8 = null };
pub const Generation = struct {
    recording_generation: u64 = 1,
    raw_offset_start: u64 = 0,
    event_sequence_start: u64 = 0,
    session_id: u64,
    session_generation: u64,
    source_ref_hash: ?[]const u8 = null,
    initial_cols: u16,
    initial_rows: u16,
    receive_time_origin: i64,
    segments: []const Segment = &.{},
    baselines: []const Baseline = &.{},
};
pub const Segment = struct { id: u64 = 1, start: Position, end: Position, data_file_ref: []const u8, committed_length: u64, checksum: []const u8 };
pub const Evidence = enum { pending, exit_confirmed, foreground_finished, interrupted, cancelled_unsent, unknown };
pub const ExecutionRange = struct {
    execution_id: []const u8,
    recording_generation: u64,
    start: Position,
    end: ?Position = null,
    start_boundary_sequence: ?u64 = null,
    end_boundary_sequence: ?u64 = null,
    completion_evidence: Evidence = .pending,
    sealed: bool = false,
    output_scope: execution.OutputScope = .exact,
    output_attribution: execution.OutputAttribution = .unverified,
    output_attribution_reason: ?[]const u8 = null,
    process_receipt: ?execution.ProcessReceipt = null,
    interval_saved: bool = false,
    failure: ?[]const u8 = null,
    gaps: []const Gap = &.{},
};
pub const Display = struct {
    title: []const u8 = "",
    host: []const u8 = "",
    user: []const u8 = "",
    endpoint: []const u8 = "",
    cwd: ?[]const u8 = null,
    final_cols: u16 = 0,
    final_rows: u16 = 0,
    timestamps: bool = false,
    layout_version: u32 = 1,
    grouped: bool = false,
    font_family: ?[]const u8 = null,
    font_size_px: ?f32 = null,
    line_height: ?f32 = null,
    theme_reference: ?[]const u8 = null,
    colors: ?struct { foreground: u32, background: u32, cursor: u32, selection: u32, ansi: [16]u32 } = null,
};
pub const Manifest = struct {
    schema_version: u32 = 1,
    archive_key: []const u8,
    recording_id: []const u8,
    manifest_revision: u64 = 1,
    source_kind: SourceKind,
    connection_id: ?u64 = null,
    config_revision: ?u64 = null,
    started_ms: i64,
    ended_ms: ?i64 = null,
    exit_code: ?i32 = null,
    end_reason: ?[]const u8 = null,
    state: enum { active, closed, unavailable, tombstone } = .active,
    display: Display = .{},
    recording: struct { version: u32 = 1, generations: []const Generation },
    execution_ranges: []const ExecutionRange = &.{},
    files: []const File = &.{},
    events: []const Event = &.{},
    coverage: Coverage = .partial,
    replayability: Replayability = .verified,
    retained_range: struct { start: Position = .{}, end: Position = .{} } = .{},
    total_received: u64 = 0,
    gaps: []const Gap = &.{},
    failure: ?[]const u8 = null,
    commit: struct { state: enum { recording, pending_index, indexed, metadata_only, removed } = .recording, committed_length: u64 = 0 } = .{},
};

pub fn pathForCast(allocator: std.mem.Allocator, cast_path: []const u8) ![]u8 {
    try validatePath(cast_path);
    if (!std.mem.endsWith(u8, cast_path, ".cast")) return error.InvalidRecordingPath;
    return std.fmt.allocPrint(allocator, "{s}.session.json", .{cast_path[0 .. cast_path.len - 5]});
}
pub fn validatePath(path: []const u8) !void {
    if (!std.mem.startsWith(u8, path, "logs/") or std.mem.indexOfScalar(u8, path, '\\') != null) return error.InvalidRecordingPath;
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return error.InvalidRecordingPath;
}
pub fn validate(value: Manifest) !void {
    if (value.schema_version != 1) return error.UnsupportedManifestVersion;
    if (value.archive_key.len != 32 or value.recording_id.len != 32 or value.manifest_revision == 0) return error.InvalidManifest;
    var id: [16]u8 = undefined;
    _ = std.fmt.hexToBytes(&id, value.archive_key) catch return error.InvalidManifest;
    if (std.mem.allEqual(u8, &id, 0)) return error.InvalidManifest;
    _ = std.fmt.hexToBytes(&id, value.recording_id) catch return error.InvalidManifest;
    if (std.mem.allEqual(u8, &id, 0)) return error.InvalidManifest;
    if (value.recording.generations.len == 0) return error.InvalidManifest;
    for (value.recording.generations) |generation| if (generation.recording_generation == 0 or generation.session_id == 0 or generation.session_generation == 0 or generation.initial_cols == 0 or generation.initial_rows == 0) return error.InvalidManifest;
    for (value.files, 0..) |file, index| {
        try validatePath(file.path);
        if (file.checksum.len != 64) return error.InvalidManifest;
        var digest: [32]u8 = undefined;
        _ = std.fmt.hexToBytes(&digest, file.checksum) catch return error.InvalidManifest;
        for (value.files[0..index]) |previous| if (std.mem.eql(u8, file.path, previous.path)) return error.InvalidManifest;
    }
    for (value.execution_ranges) |range| {
        if (range.execution_id.len != 32) return error.InvalidManifest;
        if (range.end) |end| if (end.raw_offset < range.start.raw_offset or end.event_sequence <= range.start.event_sequence) return error.InvalidManifest;
        if (range.sealed and (range.end == null or range.start_boundary_sequence == null or range.end_boundary_sequence == null)) return error.InvalidManifest;
        if (range.sealed and (range.output_scope != .exact or range.interval_saved)) return error.InvalidManifest;
        if (range.output_attribution_reason) |reason| if (reason.len == 0 or reason.len > 96 or !std.unicode.utf8ValidateSlice(reason)) return error.InvalidManifest;
        if (range.interval_saved and (range.output_scope != .session_interval or range.sealed or range.end == null or range.start_boundary_sequence == null or range.end_boundary_sequence == null or range.completion_evidence != .foreground_finished or range.process_receipt == null or !range.process_receipt.?.foreground_finished)) return error.InvalidManifest;
        if ((range.sealed or range.interval_saved) and range.end_boundary_sequence.? <= range.start_boundary_sequence.?) return error.InvalidManifest;
    }
}
pub fn save(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, path: []const u8, value: Manifest) !void {
    try validatePath(path);
    try validate(value);
    const bytes = try std.json.Stringify.valueAlloc(allocator, value, .{});
    defer allocator.free(bytes);
    if (bytes.len > 8 * 1024 * 1024) return error.ManifestTooLarge;
    // Resolve/create each managed directory without following symlinks, then
    // publish through that directory handle so a replaced parent cannot move
    // metadata writes outside the configured data root.
    var parent = dir;
    var owns_parent = false;
    defer if (owns_parent) parent.close(io);
    var parts = std.mem.splitScalar(u8, std.fs.path.dirname(path).?, '/');
    while (parts.next()) |part| {
        const child = parent.openDir(io, part, .{ .follow_symlinks = false }) catch |err| blk: {
            if (err != error.FileNotFound) return err;
            parent.createDir(io, part, @as(std.Io.Dir.Permissions, @fromBackingInt(0o700))) catch |mkdir_error| if (mkdir_error != error.PathAlreadyExists) return mkdir_error;
            break :blk try parent.openDir(io, part, .{ .follow_symlinks = false });
        };
        if (owns_parent) parent.close(io);
        parent = child;
        owns_parent = true;
    }
    var atomic = try parent.createFileAtomic(io, std.fs.path.basename(path), .{ .permissions = @as(std.Io.File.Permissions, @fromBackingInt(0o600)), .make_path = false, .replace = true });
    defer atomic.deinit(io);
    try atomic.file.writePositionalAll(io, bytes, 0);
    try atomic.file.sync(io);
    try atomic.replace(io);
}
pub const SizedManifest = struct { parsed: std.json.Parsed(Manifest), source_length: usize };
pub fn load(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, path: []const u8) !std.json.Parsed(Manifest) {
    return (try loadSized(allocator, io, dir, path)).parsed;
}
pub fn loadSized(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, path: []const u8) !SizedManifest {
    try validatePath(path);
    const file = try openManaged(io, dir, path);
    defer file.close(io);
    const stat = try file.stat(io);
    if (stat.size > 8 * 1024 * 1024) return error.ManifestTooLarge;
    const bytes = try allocator.alloc(u8, @intCast(stat.size));
    defer allocator.free(bytes);
    if (try file.readPositionalAll(io, bytes, 0) != bytes.len) return error.RecordingTruncated;
    const result = try std.json.parseFromSlice(Manifest, allocator, bytes, .{ .allocate = .alloc_always, .ignore_unknown_fields = true });
    errdefer result.deinit();
    try validate(result.value);
    return .{ .parsed = result, .source_length = bytes.len };
}
/// Refuse symlinks in every path component, not only the final filename.
pub fn openManaged(io: std.Io, dir: std.Io.Dir, path: []const u8) !std.Io.File {
    try validatePath(path);
    var current = dir;
    var close_current = false;
    defer if (close_current) current.close(io);
    var parts = std.mem.splitScalar(u8, path, '/');
    var part = parts.next().?;
    while (parts.next()) |next| {
        const child = try current.openDir(io, part, .{ .follow_symlinks = false });
        if (close_current) current.close(io);
        current = child;
        close_current = true;
        part = next;
    }
    const file = try current.openFile(io, part, .{ .follow_symlinks = false });
    errdefer file.close(io);
    if ((try file.stat(io)).kind != .file) return error.InvalidRecordingFile;
    return file;
}
pub fn fingerprint(io: std.Io, file: std.Io.File, length: u64) ![64]u8 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    var buffer: [32768]u8 = undefined;
    var offset: u64 = 0;
    while (offset < length) {
        const count: usize = @intCast(@min(buffer.len, length - offset));
        if (try file.readPositionalAll(io, buffer[0..count], offset) != count) return error.RecordingTruncated;
        hash.update(buffer[0..count]);
        offset += count;
    }
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    return std.fmt.bytesToHex(digest, .lower);
}
test "manifest rejects unmanaged paths and unsupported versions" {
    try std.testing.expectError(error.InvalidRecordingPath, validatePath("logs/../private"));
    try std.testing.expectError(error.InvalidRecordingPath, validatePath("/logs/a.cast"));
    const value: Manifest = .{ .schema_version = 2, .archive_key = "", .recording_id = "", .source_kind = .local, .started_ms = 0, .recording = .{ .generations = &.{} } };
    try std.testing.expectError(error.UnsupportedManifestVersion, validate(value));
}

test "manifest display roundtrip preserves grouped pane and old display defaults" {
    const bytes = try std.json.Stringify.valueAlloc(std.testing.allocator, Display{ .title = "pane", .grouped = true }, .{});
    defer std.testing.allocator.free(bytes);
    const parsed = try std.json.parseFromSlice(Display, std.testing.allocator, bytes, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value.grouped);
    try std.testing.expectEqualStrings("pane", parsed.value.title);
    const old = try std.json.parseFromSlice(Display, std.testing.allocator, "{\"title\":\"old pane\"}", .{});
    defer old.deinit();
    try std.testing.expect(!old.value.grouped);
}

test "manifest metadata publication refuses a symlinked managed parent" {
    var root = std.testing.tmpDir(.{});
    defer root.cleanup();
    var outside = std.testing.tmpDir(.{});
    defer outside.cleanup();
    const outside_path = try outside.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(outside_path);
    try root.dir.symLink(std.testing.io, outside_path, "logs", .{ .is_directory = true });
    const generation: Generation = .{ .session_id = 1, .session_generation = 1, .initial_cols = 80, .initial_rows = 24, .receive_time_origin = 0 };
    const value: Manifest = .{ .archive_key = "11111111111111111111111111111111", .recording_id = "22222222222222222222222222222222", .source_kind = .local, .started_ms = 0, .state = .unavailable, .recording = .{ .generations = &.{generation} }, .coverage = .unavailable, .replayability = .unsupported };
    if (save(std.testing.allocator, std.testing.io, root.dir, "logs/history/metadata.session.json", value)) |_| return error.UnsafeWriteSucceeded else |_| {}
    try std.testing.expectError(error.FileNotFound, outside.dir.openDir(std.testing.io, "history", .{}));
}

test "manifest old execution range defaults to exact without interval evidence" {
    const parsed = try std.json.parseFromSlice(ExecutionRange, std.testing.allocator, "{\"execution_id\":\"11111111111111111111111111111111\",\"recording_generation\":1,\"start\":{}}", .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value.output_scope == .exact and parsed.value.output_attribution == .unverified);
    try std.testing.expect(parsed.value.output_attribution_reason == null and parsed.value.process_receipt == null and !parsed.value.interval_saved);
}
