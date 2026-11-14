//! Publication adapter for the existing SSH Timeline. It owns no worker, VT,
//! socket, or second recording stream. Call only after that owner has stopped.
const std = @import("std");
const archive = @import("session_archive.zig");
const manifest = archive.manifest;
const identity = @import("../host/identity.zig");
const Timeline = @import("timeline.zig").Timeline;

pub const Options = struct {
    recording_id: identity.RecordingId,
    archive_key: identity.ArchiveKey,
    generations: []const manifest.Generation,
    cast_path: []const u8,
    started_ms: i64,
    ended_ms: ?i64 = null,
    display: manifest.Display,
    timeline: ?*Timeline = null,
    total_received: u64 = 0,
    connection_id: ?u64 = null,
    config_revision: ?u64 = null,
    exit_code: ?i32 = null,
    retention_days: u16 = 0,
    failure: ?[]const u8 = null,
    execution_ranges: []const manifest.ExecutionRange = &.{},
    extra_files: []const struct { path: []const u8, kind: @FieldType(manifest.File, "kind") } = &.{},
};
pub const Receipt = struct { manifest_revision: u64, coverage: manifest.Coverage, replayability: manifest.Replayability };

pub fn reserve(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, options: Options) !void {
    const key = std.fmt.bytesToHex(options.archive_key.bytes, .lower);
    const id = std.fmt.bytesToHex(options.recording_id.bytes, .lower);
    const path = try manifest.pathForCast(allocator, options.cast_path);
    defer allocator.free(path);
    const revision = try previousRevision(allocator, io, dir, path, &key, &id);
    if (revision != 0) return error.RecordingAlreadyReserved;
    try manifest.save(allocator, io, dir, path, .{ .archive_key = &key, .recording_id = &id, .source_kind = .ssh, .connection_id = options.connection_id, .config_revision = options.config_revision, .started_ms = options.started_ms, .display = options.display, .recording = .{ .generations = options.generations }, .coverage = .partial });
    errdefer dir.deleteFile(io, path) catch {};
    try archive.setActiveRecord(&key, true);
}

pub fn publish(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, options: Options) !Receipt {
    const source_timeline = options.timeline orelse return error.RecordingUnavailable;
    source_timeline.applyPrivateEvidence(options.execution_ranges);
    var frozen = try source_timeline.snapshotWithAllocator(allocator);
    defer frozen.deinit();
    const timeline = &frozen;
    if (options.ended_ms != null) for (timeline.command_history.items) |*item| if (item.value.state == .running) {
        item.value.state = .unknown;
    };
    if (options.generations.len == 0) return error.InvalidRecordingMetadata;
    const key = std.fmt.bytesToHex(options.archive_key.bytes, .lower);
    const id = std.fmt.bytesToHex(options.recording_id.bytes, .lower);
    defer if (options.ended_ms != null) archive.setActiveRecord(&key, false) catch {};
    const path = try manifest.pathForCast(allocator, options.cast_path);
    defer allocator.free(path);
    const revision = try std.math.add(u64, try previousRevision(allocator, io, dir, path, &key, &id), 1);
    if (manifest.load(allocator, io, dir, path)) |previous| {
        defer previous.deinit();
        if (previous.value.state == .closed and previous.value.commit.state == .indexed) return .{ .manifest_revision = previous.value.manifest_revision, .coverage = previous.value.coverage, .replayability = previous.value.replayability };
    } else |err| if (err != error.FileNotFound) return err;
    for (timeline.command_history.items) |*item| manifest.applyPrivateCommandEvidence(&item.value, item.recording_generation, options.execution_ranges);
    const initial = options.generations[0];
    const data_path = if (options.ended_ms == null) try std.fmt.allocPrint(allocator, "{s}.commit-{d}.cast", .{ options.cast_path[0 .. options.cast_path.len - 5], revision }) else try allocator.dupe(u8, options.cast_path);
    defer allocator.free(data_path);
    errdefer if (options.ended_ms == null) dir.deleteFile(io, data_path) catch {};
    timeline.saveFrozenCast(io, dir, data_path, initial.initial_cols, initial.initial_rows) catch |err| {
        try manifest.save(allocator, io, dir, path, .{ .archive_key = &key, .recording_id = &id, .manifest_revision = revision, .source_kind = .ssh, .connection_id = options.connection_id, .config_revision = options.config_revision, .started_ms = options.started_ms, .ended_ms = options.ended_ms, .state = .unavailable, .display = options.display, .recording = .{ .generations = options.generations }, .coverage = .unavailable, .replayability = .unsupported, .failure = @errorName(err), .total_received = options.total_received });
        return err;
    };
    if (options.extra_files.len > 31) return error.RecordingFileLimit;
    const files = try allocator.alloc(manifest.File, 1 + options.extra_files.len);
    defer allocator.free(files);
    const hashes = try allocator.alloc([64]u8, files.len);
    defer allocator.free(hashes);
    for (files, 0..) |*file, index| {
        const file_path = if (index == 0) data_path else options.extra_files[index - 1].path;
        const opened = try manifest.openManaged(io, dir, file_path);
        defer opened.close(io);
        const stat = try opened.stat(io);
        hashes[index] = try manifest.fingerprint(io, opened, stat.size);
        file.* = .{ .path = file_path, .kind = if (index == 0) .cast else options.extra_files[index - 1].kind, .committed_length = stat.size, .checksum = &hashes[index] };
    }
    const events = try eventMappings(allocator, timeline);
    defer allocator.free(events);
    const end: manifest.Position = if (timeline.events.items.len == 0) .{ .raw_offset = options.total_received } else .{ .raw_offset = options.total_received, .event_sequence = timeline.events.items[timeline.events.items.len - 1].event_sequence };
    const start: manifest.Position = if (timeline.events.items.len == 0) .{} else .{ .raw_offset = timeline.events.items[0].stream_offset, .event_sequence = timeline.events.items[0].event_sequence };
    const generations = try allocator.dupe(manifest.Generation, options.generations);
    defer allocator.free(generations);
    const segments = try allocator.alloc(manifest.Segment, generations.len);
    defer allocator.free(segments);
    const initial_baseline: manifest.Baseline = .{ .event_sequence = 0, .raw_offset = 0, .kind = .initial_empty };
    for (generations, segments, 0..) |*generation, *segment, index| {
        const next = if (index + 1 < generations.len) generations[index + 1] else null;
        segment.* = .{ .id = index + 1, .start = .{ .raw_offset = generation.raw_offset_start, .event_sequence = generation.event_sequence_start }, .end = if (next) |boundary| .{ .raw_offset = boundary.raw_offset_start, .event_sequence = @max(generation.event_sequence_start, boundary.event_sequence_start -| 1) } else end, .data_file_ref = data_path, .committed_length = files[0].committed_length, .checksum = files[0].checksum };
        generation.segments = segment[0..1];
        if (index == 0 and timeline.evicted_events == 0 and generation.baselines.len == 0) generation.baselines = &.{initial_baseline};
    }
    const history_failure: ?[]const u8 = if (timeline.command_history_truncated) "CommandHistoryCapacity" else options.failure;
    const coverage: manifest.Coverage = if (history_failure != null) .partial else if (timeline.evicted_events > 0) .retained else .complete;
    const replayability: manifest.Replayability = if (timeline.evicted_events > 0 or options.failure != null) .baseline_unavailable else .verified;
    const gap: manifest.Gap = .{ .start = start, .end = end, .reason = history_failure orelse "RecordingDegraded" };
    var value: manifest.Manifest = .{ .archive_key = &key, .recording_id = &id, .manifest_revision = revision, .source_kind = .ssh, .connection_id = options.connection_id, .config_revision = options.config_revision, .started_ms = options.started_ms, .ended_ms = options.ended_ms, .exit_code = options.exit_code, .end_reason = if (options.ended_ms != null) "session_closed" else null, .state = if (options.ended_ms != null) .closed else .active, .display = options.display, .recording = .{ .generations = generations }, .execution_ranges = options.execution_ranges, .command_history = timeline.command_history.items, .files = files, .events = events, .coverage = coverage, .replayability = replayability, .retained_range = .{ .start = start, .end = end }, .total_received = options.total_received, .gaps = if (history_failure != null) &.{gap} else &.{}, .failure = history_failure, .commit = .{ .state = if (options.ended_ms != null) .pending_index else .recording, .committed_length = files[0].committed_length } };
    try manifest.save(allocator, io, dir, path, value);
    if (options.ended_ms == null) return .{ .manifest_revision = revision, .coverage = coverage, .replayability = replayability };
    var index: archive.Archive = .{ .allocator = allocator, .io = io, .dir = dir };
    try index.appendOnce(.{ .id = initial.session_id, .started_ms = options.started_ms, .ended_ms = options.ended_ms.?, .duration_ms = @intCast(@max(0, options.ended_ms.? - options.started_ms)), .host = if (options.display.host.len > 0) options.display.host else "SSH", .user = if (options.display.user.len > 0) options.display.user else "unknown", .cast_path = options.cast_path, .source_kind = .ssh, .saved_connection_id = options.connection_id, .exit_code = options.exit_code });
    value.manifest_revision = try std.math.add(u64, revision, 1);
    value.commit.state = .indexed;
    try manifest.save(allocator, io, dir, path, value);
    _ = try index.prune(options.retention_days, options.ended_ms.?);
    return .{ .manifest_revision = value.manifest_revision, .coverage = coverage, .replayability = replayability };
}

fn eventMappings(allocator: std.mem.Allocator, timeline: *const Timeline) ![]manifest.Event {
    const events = try allocator.alloc(manifest.Event, timeline.events.items.len);
    for (timeline.events.items, events, 1..) |event, *target, cast_line| {
        target.* = .{
            .sequence = event.event_sequence,
            .raw_offset = event.stream_offset,
            .raw_length = if (event.kind == .output) event.payload.len else 0,
            .cast_line = cast_line,
            .kind = switch (event.kind) {
                .output => .output,
                .resize => .resize,
                .application => .application,
                .boundary => .boundary,
            },
        };
    }
    return events;
}

/// Publish one immutable command interval before its slot can be reused.
/// The manifest is the commit point and the cast keeps the original offsets.
pub fn archiveExecution(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, options: Options, revision: u64, range: manifest.ExecutionRange, timeline: ?*const Timeline) !void {
    const parent = try manifest.pathForCast(allocator, options.cast_path);
    defer allocator.free(parent);
    const path = try manifest.executionSegmentPath(allocator, parent, range.execution_id, .metadata);
    defer allocator.free(path);
    const generation = for (options.generations) |entry| {
        if (entry.recording_generation == range.recording_generation) break entry;
    } else return error.InvalidRecordingGeneration;
    const key = std.fmt.bytesToHex(options.archive_key.bytes, .lower);
    const id = std.fmt.bytesToHex(options.recording_id.bytes, .lower);
    var value: manifest.Manifest = .{
        .archive_key = &key,
        .recording_id = &id,
        .manifest_revision = revision,
        .source_kind = .ssh,
        .started_ms = options.started_ms,
        .state = .closed,
        .recording = .{ .generations = &.{generation} },
        .execution_ranges = &.{range},
        .execution_segment = true,
        .coverage = .unavailable,
        .replayability = .unsupported,
        .failure = range.failure,
        .commit = .{ .state = .metadata_only },
    };
    const frozen = timeline orelse return manifest.save(allocator, io, dir, path, value);
    const cast_path = try manifest.executionSegmentPath(allocator, parent, range.execution_id, .cast);
    defer allocator.free(cast_path);
    const events = try eventMappings(allocator, frozen);
    defer allocator.free(events);
    // Create the managed parent with the manifest writer's no-symlink traversal.
    // The cast and final manifest are separate atomic commits.
    const segment_dir = try manifest.createParent(io, dir, path);
    defer segment_dir.close(io);
    const filename = std.fs.path.basename(cast_path);
    try frozen.saveFrozenCast(io, segment_dir, filename, generation.initial_cols, generation.initial_rows);
    errdefer segment_dir.deleteFile(io, filename) catch {};
    const cast = try segment_dir.openFile(io, filename, .{ .follow_symlinks = false });
    defer cast.close(io);
    const size = (try cast.stat(io)).size;
    const checksum = try manifest.fingerprint(io, cast, size);
    const file: manifest.File = .{ .path = cast_path, .kind = .cast, .committed_length = size, .checksum = &checksum };
    value.files = &.{file};
    value.events = events;
    value.command_history = frozen.command_history.items;
    value.coverage = .retained;
    value.replayability = .baseline_unavailable;
    value.retained_range = .{ .start = range.start, .end = range.end.? };
    value.total_received = range.end.?.raw_offset;
    value.commit = .{ .state = .indexed, .committed_length = size };
    try manifest.save(allocator, io, dir, path, value);
}
fn previousRevision(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, path: []const u8, key: []const u8, id: []const u8) !u64 {
    const previous = manifest.load(allocator, io, dir, path) catch |err| switch (err) {
        error.FileNotFound => return 0,
        else => return err,
    };
    defer previous.deinit();
    if (!std.mem.eql(u8, previous.value.archive_key, key) or !std.mem.eql(u8, previous.value.recording_id, id)) return error.RecordingIdentityChanged;
    return previous.value.manifest_revision;
}
