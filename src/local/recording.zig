//! Received Local PTY output uses the existing bounded Timeline / raw tap /
//! closed-session archive. The transport owner never writes files while feeding
//! output: a bounded mailbox owns recording IO, and failures leave VT alive.
const std = @import("std");
const c = @import("generated_ghostty_vt");
const identity = @import("../host/identity.zig");
const Config = @import("../config/config.zig");
const Paths = @import("../config/paths.zig").Paths;
const Timeline = @import("../vt/timeline.zig").Timeline;
const Checkpoint = @import("../vt/checkpoint_controller.zig").Controller;
const archive_mod = @import("../vt/session_archive.zig");
const manifest = archive_mod.manifest;
const Wakeup = @import("../platform/wakeup.zig").Wakeup;
var test_init_failure_after_manifest: bool = false;

pub const Options = @import("../host/process_service.zig").RecordingOptions;

pub const Kind = enum { txt, cast };
pub const Snapshot = struct {
    owner: identity.SessionHandle,
    max_bytes: usize,
    checkpoint_sec: u16,
    output_bytes: u64,
    dropped_bytes: u64,
    checkpoint_count: u64,
    closed: bool,
    archived: bool,
    failure: ?[]const u8,
    storage_failed: bool = false,
};
pub const BoundaryKind = enum { start, end };
pub const StartBarrier = struct { recording_id: [32]u8, archive_key: [32]u8, recording_generation: u64, raw_offset: u64, event_sequence: u64, manifest_revision: u64, barrier_id: u64 };
pub const BoundaryReceipt = struct { position: manifest.Position, boundary_sequence: u64, manifest_revision: u64 };
pub const SealReceipt = struct { recording_id: [32]u8, recording_generation: u64, start: manifest.Position, end: manifest.Position, manifest_revision: u64, committed_length: u64, coverage: manifest.Coverage, replayability: manifest.Replayability, sealed: bool, interval_saved: bool = false };
pub const Observation = struct { output_scope: manifest.execution.OutputScope = .exact, attribution: manifest.execution.OutputAttribution = .unverified, reason: ?[]const u8 = null, process: ?manifest.execution.ProcessReceipt = null };
const Request = struct {
    kind: enum { barrier, boundary, seal, interval, abandon },
    execution_id: [32]u8,
    boundary_kind: BoundaryKind = .start,
    raw_offset: u64 = 0,
    fence_sequence: u64 = 0,
    evidence: manifest.Evidence = .pending,
    reason: []const u8 = "",
    output_scope: manifest.execution.OutputScope = .exact,
    observation: Observation = .{},
    completion: Wakeup,
    done: std.atomic.Value(bool) = .init(false),
    failure: ?anyerror = null,
    barrier: ?StartBarrier = null,
    boundary: ?BoundaryReceipt = null,
    seal: ?SealReceipt = null,
};
const Range = struct {
    id: [32]u8,
    start: manifest.Position,
    end: ?manifest.Position = null,
    start_fence: ?u64 = null,
    end_fence: ?u64 = null,
    evidence: manifest.Evidence = .pending,
    sealed: bool = false,
    interval_saved: bool = false,
    output_scope: manifest.execution.OutputScope = .exact,
    output_attribution: manifest.execution.OutputAttribution = .unverified,
    attribution_reason: [128]u8 = undefined,
    attribution_reason_len: u8 = 0,
    process: ?manifest.execution.ProcessReceipt = null,
    reason: [128]u8 = undefined,
    reason_len: u8 = 0,
    fn observe(self: *Range, observation: Observation) void {
        self.output_attribution = observation.attribution;
        const reason = observation.reason orelse "";
        @memcpy(self.attribution_reason[0..reason.len], reason);
        self.attribution_reason_len = @intCast(reason.len);
        self.process = observation.process;
    }
};
const Segment = struct { bytes: []u8, timestamp_ms: i64, raw_offset: u64 = 0, sequence: u64 = 0, request: ?*Request = null, application: bool = false, boundary_marker: bool = false, geometry: ?struct { cols: u16, rows: u16 } = null, theme: ?@import("../vt/engine.zig").Theme = null };

pub const Recording = struct {
    allocator: std.mem.Allocator,
    owner: identity.SessionHandle,
    io: std.Io,
    dir: std.Io.Dir,
    started_ms: i64,
    receive_time_origin: i64,
    display_arena: std.heap.ArenaAllocator,
    display: manifest.Display = .{ .title = "本地终端", .host = "本地", .user = "zsh" },
    timeline: Timeline,
    checkpoint: Checkpoint,
    terminal: c.GhosttyTerminal,
    checkpoint_valid: bool = true,
    raw_path: []u8,
    checkpoint_path: []u8,
    cast_path: []u8,
    manifest_path: []u8,
    recording_id: [32]u8,
    archive_key: [32]u8,
    recording_generation: u64 = 1,
    manifest_revision: u64 = 0,
    raw_position: u64 = 0,
    next_event_sequence: u64 = 1,
    committed_position: manifest.Position = .{},
    committed_length: u64 = 0,
    committed_cast_path: ?[]u8 = null,
    ranges: std.ArrayList(Range) = .empty,
    mappings: std.ArrayList(manifest.Event) = .empty,
    evicted_through_sequence: u64 = 0,
    ordered_boundaries: [64]manifest.Position = undefined,
    boundary_count: usize = 0,
    coverage: manifest.Coverage = .partial,
    replayability: manifest.Replayability = .verified,
    checkpoint_sec: u16,
    initial_cols: u16,
    initial_rows: u16,
    cols: u16,
    rows: u16,
    retention_days: std.atomic.Value(u16),
    mutex: std.atomic.Mutex = .unlocked,
    queue: std.ArrayList(Segment) = .empty,
    queued_bytes: usize = 0,
    queue_capacity: usize,
    output_bytes: u64 = 0,
    dropped_bytes: u64 = 0,
    gaps: [64]manifest.Gap = undefined,
    gap_count: usize = 0,
    checkpoint_count: u64 = 0,
    failure: ?[]const u8 = null,
    storage_failed: bool = false,
    stop: bool = false,
    closed: bool = false,
    archived: bool = false,
    writer: ?std.Thread = null,
    references: std.atomic.Value(usize) = .init(1),
    wakeup: @import("../platform/wakeup.zig").Wakeup,

    pub fn init(allocator: std.mem.Allocator, owner: identity.SessionHandle, options: Options, cols: u16, rows: u16, now_ms: i64) !*Recording {
        return initWithIdentity(allocator, owner, options, cols, rows, now_ms, archive_mod.MetadataIdentity.generate());
    }
    pub fn initWithIdentity(allocator: std.mem.Allocator, owner: identity.SessionHandle, options: Options, cols: u16, rows: u16, now_ms: i64, ids: archive_mod.MetadataIdentity) !*Recording {
        if (!ids.recording_id.valid() or !ids.archive_key.valid()) return error.InvalidRecordingIdentity;
        if (options.log.ring_mb == 0 or options.log.checkpoint_sec == 0 or cols == 0 or rows == 0) return error.InvalidRecordingOptions;
        const capacity = try std.math.mul(usize, options.log.ring_mb, 1024 * 1024);
        var paths = if (options.directory) |directory| try Paths.fromDirectory(allocator, directory) else try Paths.forApplication(allocator);
        defer paths.deinit();
        const dir = try std.Io.Dir.cwd().createDirPathOpen(options.io, paths.directory, .{});
        errdefer dir.close(options.io);
        const started_wall_ms = @import("../platform/realtime.zig").milliseconds(undefined);
        const stem = try std.fmt.allocPrint(allocator, "session-local-{d}-{d}-{d}-{d}", .{ std.c.getpid(), started_wall_ms, @backingInt(owner.session_id), owner.generation });
        defer allocator.free(stem);
        const raw_path = try std.fmt.allocPrint(allocator, "logs/{s}.raw", .{stem});
        errdefer allocator.free(raw_path);
        const checkpoint_path = try std.fmt.allocPrint(allocator, "logs/{s}.checkpoint", .{stem});
        errdefer allocator.free(checkpoint_path);
        const cast_path = try std.fmt.allocPrint(allocator, "logs/history/{s}.cast", .{stem});
        errdefer allocator.free(cast_path);
        const manifest_path = try manifest.pathForCast(allocator, cast_path);
        errdefer allocator.free(manifest_path);
        var timeline = try Timeline.init(allocator, 65536, capacity);
        errdefer timeline.deinit();
        var checkpoint = try Checkpoint.init(allocator, capacity, options.log.checkpoint_sec, now_ms, options.io, dir, checkpoint_path);
        errdefer checkpoint.deinit();
        try checkpoint.enableRawFile(raw_path);
        // This file was created exclusively by this attempt. Until init has
        // returned no output can have been accepted, so failed initialization
        // rolls back its own artifacts before metadata-only failure publication.
        errdefer dir.deleteFile(options.io, raw_path) catch {};
        var terminal: c.GhosttyTerminal = null;
        if (c.ghostty_terminal_new(null, &terminal, cols, rows) != c.GHOSTTY_SUCCESS) return error.RecordingVtInitFailed;
        errdefer c.ghostty_terminal_free(terminal);
        const continuation_limit: usize = capacity;
        if (c.ghostty_terminal_set(terminal, c.GHOSTTY_TERMINAL_OPT_CONTINUATION_MAX_BYTES, &continuation_limit) != c.GHOSTTY_SUCCESS) return error.RecordingContinuationFailed;
        const grapheme_mode: c.GhosttyTerminalModeConfig = .{ .mode = c.ghostty_mode_new(2027, false), .value = true };
        if (c.ghostty_terminal_set(terminal, c.GHOSTTY_TERMINAL_OPT_MODE_DEFAULT, &grapheme_mode) != c.GHOSTTY_SUCCESS or c.ghostty_terminal_set(terminal, c.GHOSTTY_TERMINAL_OPT_MODE, &grapheme_mode) != c.GHOSTTY_SUCCESS) return error.RecordingVtInitFailed;
        var wakeup = try @import("../platform/wakeup.zig").Wakeup.init();
        errdefer wakeup.deinit();
        const self = try allocator.create(Recording);
        errdefer allocator.destroy(self);
        self.* = .{
            .wakeup = wakeup,
            .allocator = allocator,
            .owner = owner,
            .io = options.io,
            .dir = dir,
            .started_ms = started_wall_ms,
            .receive_time_origin = now_ms,
            .display_arena = std.heap.ArenaAllocator.init(allocator),
            .timeline = timeline,
            .checkpoint = checkpoint,
            .terminal = terminal,
            .raw_path = raw_path,
            .checkpoint_path = checkpoint_path,
            .cast_path = cast_path,
            .manifest_path = manifest_path,
            .recording_id = std.fmt.bytesToHex(ids.recording_id.bytes, .lower),
            .archive_key = std.fmt.bytesToHex(ids.archive_key.bytes, .lower),
            .checkpoint_sec = options.log.checkpoint_sec,
            .initial_cols = cols,
            .initial_rows = rows,
            .cols = cols,
            .rows = rows,
            .retention_days = .init(options.log.retention_days),
            .queue_capacity = @min(capacity, 1024 * 1024),
        };
        errdefer self.display_arena.deinit();
        errdefer if (self.committed_cast_path) |path| allocator.free(path);
        errdefer {
            if (self.manifest_revision > 0) dir.deleteFile(options.io, manifest_path) catch {};
            if (self.committed_cast_path) |path| dir.deleteFile(options.io, path) catch {};
            if (self.checkpoint_count > 0) dir.deleteFile(options.io, checkpoint_path) catch {};
        }
        try archive_mod.setActiveRecord(&self.archive_key, true);
        errdefer archive_mod.setActiveRecord(&self.archive_key, false) catch {};
        try self.saveCheckpoint(now_ms);
        try self.commitManifest(.active, null, null, .recording);
        if (@import("builtin").is_test and test_init_failure_after_manifest) return error.InjectedRecordingInitFailure;
        self.writer = try std.Thread.spawn(.{}, writeLoop, .{self});
        return self;
    }

    pub fn deinit(self: *Recording) void {
        self.stopWriter();
        archive_mod.setActiveRecord(&self.archive_key, false) catch {};
        self.releaseExport();
    }
    fn releaseExport(self: *Recording) void {
        if (self.references.fetchSub(1, .acq_rel) != 1) return;
        self.wakeup.deinit();
        for (self.queue.items) |segment| self.allocator.free(segment.bytes);
        self.queue.deinit(self.allocator);
        self.ranges.deinit(self.allocator);
        self.display_arena.deinit();
        self.mappings.deinit(self.allocator);
        c.ghostty_terminal_free(self.terminal);
        self.checkpoint.deinit();
        self.timeline.deinit();
        self.dir.close(self.io);
        self.allocator.free(self.raw_path);
        self.allocator.free(self.checkpoint_path);
        self.allocator.free(self.cast_path);
        self.allocator.free(self.manifest_path);
        if (self.committed_cast_path) |path| self.allocator.free(path);
        self.allocator.destroy(self);
    }
    pub fn exportLease(self: *Recording) Timeline.ExportLease {
        _ = self.references.fetchAdd(1, .monotonic);
        return .{ .context = self, .capture = captureExport, .release = releaseLease, .cols = self.initial_cols, .rows = self.initial_rows };
    }
    fn captureExport(raw: *anyopaque, allocator: std.mem.Allocator) !Timeline {
        const self: *Recording = @ptrCast(@alignCast(raw));
        return self.timeline.snapshotWithAllocator(allocator);
    }
    fn releaseLease(raw: *anyopaque) void {
        const self: *Recording = @ptrCast(@alignCast(raw));
        self.releaseExport();
    }
    fn lock(self: *Recording) void {
        while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
    }
    fn fail(self: *Recording, err: anyerror) void {
        self.lock();
        defer self.mutex.unlock();
        self.failLocked(err);
    }
    /// The first failure is a presentation fact even when the writer is the
    /// only active thread and the PTY has produced no new text frame.
    fn failLocked(self: *Recording, err: anyerror) void {
        // A bounded mailbox gap can precede a later complete interval. Real
        // writer/storage failures remain sticky and never enable recovery.
        const new_storage_failure = !self.storage_failed and err != error.RecordingQueueFull;
        if (err != error.RecordingQueueFull) self.storage_failed = true;
        if (self.failure != null) {
            if (new_storage_failure) @import("../platform/presentation_wakeup.zig").notify();
            return;
        }
        self.failure = @errorName(err);
        @import("../platform/presentation_wakeup.zig").notify();
    }

    /// Called only at the original PTY / VT worker boundary. Output offsets
    /// count received bytes, never input mailbox submissions or painted frames.
    pub fn appendOutput(self: *Recording, owner: identity.SessionHandle, bytes: []const u8, now_ms: i64) void {
        self.lock();
        const offset = self.raw_position;
        self.mutex.unlock();
        self.appendOutputAt(owner, bytes, now_ms, offset);
    }
    pub fn observeRawPosition(self: *Recording, owner: identity.SessionHandle, raw_end: u64) void {
        if (!self.owner.eql(owner)) return;
        self.lock();
        defer self.mutex.unlock();
        self.raw_position = @max(self.raw_position, raw_end);
    }
    pub fn appendOutputAt(self: *Recording, owner: identity.SessionHandle, bytes: []const u8, now_ms: i64, raw_start: u64) void {
        if (!self.owner.eql(owner)) return;
        self.lock();
        defer self.mutex.unlock();
        self.output_bytes +|= bytes.len;
        self.raw_position = @max(self.raw_position, raw_start +| bytes.len);
        const sequence = self.next_event_sequence;
        self.next_event_sequence +|= 1;
        if (self.closed or self.stop or bytes.len > self.queue_capacity -| self.queued_bytes) {
            self.checkpoint_valid = false;
            self.dropped_bytes +|= bytes.len;
            self.noteGapLocked(raw_start, raw_start +| bytes.len, sequence, "RecordingQueueFull", bytes.len);
            self.failLocked(error.RecordingQueueFull);
            return;
        }
        const owned = self.allocator.dupe(u8, bytes) catch {
            self.checkpoint_valid = false;
            self.dropped_bytes +|= bytes.len;
            self.noteGapLocked(raw_start, raw_start +| bytes.len, sequence, "OutOfMemory", bytes.len);
            self.failLocked(error.OutOfMemory);
            return;
        };
        self.queue.append(self.allocator, .{ .bytes = owned, .timestamp_ms = now_ms, .raw_offset = raw_start, .sequence = sequence }) catch {
            self.allocator.free(owned);
            self.checkpoint_valid = false;
            self.dropped_bytes +|= bytes.len;
            self.noteGapLocked(raw_start, raw_start +| bytes.len, sequence, "OutOfMemory", bytes.len);
            self.failLocked(error.OutOfMemory);
            return;
        };
        self.queued_bytes += bytes.len;
        self.wakeup.notify();
    }

    fn noteGapLocked(self: *Recording, raw_start: u64, raw_end: u64, sequence: u64, reason: []const u8, dropped: u64) void {
        const gap: manifest.Gap = .{ .start = .{ .raw_offset = raw_start, .event_sequence = sequence }, .end = .{ .raw_offset = raw_end, .event_sequence = sequence }, .reason = reason, .known_dropped_bytes = dropped };
        if (self.gap_count < self.gaps.len) {
            self.gaps[self.gap_count] = gap;
            self.gap_count += 1;
        } else {
            const tail = &self.gaps[self.gaps.len - 1];
            tail.end = gap.end;
            tail.known_dropped_bytes +|= dropped;
            tail.reason = "MultipleRecordingGaps";
        }
    }
    pub fn appendApplication(self: *Recording, record: @import("../host/terminal_service.zig").ApplicationRecord) !void {
        if (!self.owner.eql(record.owner)) return error.StaleOwner;
        const bytes = try std.json.Stringify.valueAlloc(self.allocator, record, .{});
        errdefer self.allocator.free(bytes);
        self.lock();
        defer self.mutex.unlock();
        if (self.stop or self.closed) return error.RecordingClosed;
        if (bytes.len > self.queue_capacity -| self.queued_bytes) return error.RecordingQueueFull;
        try self.queue.append(self.allocator, .{ .bytes = bytes, .timestamp_ms = @intCast(@import("native.zig").zw_local_monotonic_ms()), .raw_offset = self.raw_position, .sequence = self.next_event_sequence, .application = true });
        self.next_event_sequence +|= 1;
        self.queued_bytes += bytes.len;
        self.wakeup.notify();
    }
    pub fn resizeApplied(self: *Recording, owner: identity.SessionHandle, cols: u16, rows: u16, now_ms: i64) void {
        if (!self.owner.eql(owner)) return;
        defer self.wakeup.notify();
        self.lock();
        self.cols = cols;
        self.rows = rows;
        defer self.mutex.unlock();
        if (self.stop or self.queue.items.len >= 65536) {
            self.checkpoint_valid = false;
            self.failLocked(error.RecordingQueueFull);
            return;
        }
        const bytes = self.allocator.alloc(u8, 0) catch unreachable;
        self.queue.append(self.allocator, .{ .bytes = bytes, .timestamp_ms = now_ms, .raw_offset = self.raw_position, .sequence = self.next_event_sequence, .geometry = .{ .cols = cols, .rows = rows } }) catch {
            self.allocator.free(bytes);
            self.checkpoint_valid = false;
            self.failLocked(error.OutOfMemory);
        };
        self.next_event_sequence +|= 1;
    }

    pub fn themeApplied(self: *Recording, owner: identity.SessionHandle, theme: @import("../vt/engine.zig").Theme, now_ms: i64) void {
        defer self.wakeup.notify();
        if (!self.owner.eql(owner)) return;
        self.lock();
        defer self.mutex.unlock();
        if (self.stop or self.queue.items.len >= 65536) {
            self.checkpoint_valid = false;
            self.failLocked(error.RecordingQueueFull);
            return;
        }
        const bytes = self.allocator.alloc(u8, 0) catch unreachable;
        self.queue.append(self.allocator, .{ .bytes = bytes, .timestamp_ms = now_ms, .theme = theme }) catch {
            self.allocator.free(bytes);
            self.checkpoint_valid = false;
            self.failLocked(error.OutOfMemory);
        };
    }
    fn applyTheme(self: *Recording, theme: @import("../vt/engine.zig").Theme) !void {
        var palette: [256]c.GhosttyColorRgb = undefined;
        if (c.ghostty_terminal_get(self.terminal, c.GHOSTTY_TERMINAL_DATA_COLOR_PALETTE_DEFAULT, &palette) != c.GHOSTTY_SUCCESS) return error.RecordingThemeFailed;
        for (theme.ansi, 0..) |value, index| palette[index] = rgb(value);
        const foreground = rgb(theme.foreground);
        const background = rgb(theme.background);
        const cursor = rgb(theme.cursor);
        if (c.ghostty_terminal_set(self.terminal, c.GHOSTTY_TERMINAL_OPT_COLOR_PALETTE, &palette) != c.GHOSTTY_SUCCESS or c.ghostty_terminal_set(self.terminal, c.GHOSTTY_TERMINAL_OPT_COLOR_FOREGROUND, &foreground) != c.GHOSTTY_SUCCESS or c.ghostty_terminal_set(self.terminal, c.GHOSTTY_TERMINAL_OPT_COLOR_BACKGROUND, &background) != c.GHOSTTY_SUCCESS or c.ghostty_terminal_set(self.terminal, c.GHOSTTY_TERMINAL_OPT_COLOR_CURSOR, &cursor) != c.GHOSTTY_SUCCESS) return error.RecordingThemeFailed;
    }
    fn rgb(value: u32) c.GhosttyColorRgb {
        return .{ .r = @truncate(value >> 24), .g = @truncate(value >> 16), .b = @truncate(value >> 8) };
    }

    /// The caller captures actual presentation state before destroying its UI.
    /// Strings are retained for the recording lifetime, so the writer never
    /// follows pointers into a closing tab or a changing configuration model.
    pub fn setDisplay(self: *Recording, owner: identity.SessionHandle, display: manifest.Display) !void {
        if (!self.owner.eql(owner)) return error.StaleSession;
        self.lock();
        defer self.mutex.unlock();
        if (self.closed) return error.RecordingClosed;
        const allocator = self.display_arena.allocator();
        var display_copy = display;
        display_copy.title = try allocator.dupe(u8, display.title);
        display_copy.host = try allocator.dupe(u8, display.host);
        display_copy.user = try allocator.dupe(u8, display.user);
        display_copy.endpoint = try allocator.dupe(u8, display.endpoint);
        display_copy.cwd = if (display.cwd) |value| try allocator.dupe(u8, value) else null;
        display_copy.font_family = if (display.font_family) |value| try allocator.dupe(u8, value) else null;
        display_copy.theme_reference = if (display.theme_reference) |value| try allocator.dupe(u8, value) else null;
        self.display = display_copy;
    }

    pub fn snapshot(self: *Recording) Snapshot {
        self.lock();
        defer self.mutex.unlock();
        return .{
            .owner = self.owner,
            .max_bytes = self.timeline.max_bytes,
            .checkpoint_sec = self.checkpoint_sec,
            .output_bytes = self.output_bytes,
            .dropped_bytes = self.dropped_bytes,
            .checkpoint_count = self.checkpoint_count,
            .closed = self.closed,
            .archived = self.archived,
            .failure = self.failure,
            .storage_failed = self.storage_failed,
        };
    }

    pub fn exportTo(self: *Recording, owner: identity.SessionHandle, kind: Kind, io: std.Io, dir: std.Io.Dir, path: []const u8) !void {
        if (!self.owner.eql(owner)) return error.StaleSession;
        switch (kind) {
            .txt => try self.timeline.save(io, dir, path),
            .cast => try self.timeline.saveCast(io, dir, path, self.initial_cols, self.initial_rows),
        }
    }

    /// Called after the actual child/exec close receipts. Recording failure is
    /// reported separately and can never turn a released PTY into a live one.
    pub fn close(self: *Recording, owner: identity.SessionHandle, ended_ms: i64, exit_code: ?i32) void {
        if (!self.owner.eql(owner) or self.closed) return;
        self.stopWriter();
        self.closed = true;
        archive_mod.setActiveRecord(&self.archive_key, false) catch {};
        self.commitManifest(if (self.failure == null) .closed else .closed, ended_ms, exit_code, .pending_index) catch |err| {
            self.fail(err);
            return;
        };
        var archive: archive_mod.Archive = .{ .allocator = self.allocator, .io = self.io, .dir = self.dir };
        archive.appendOnce(.{
            .id = @backingInt(owner.session_id),
            .started_ms = self.started_ms,
            .ended_ms = ended_ms,
            .host = "本地",
            .user = "zsh",
            .cast_path = self.cast_path,
            .source_kind = .local,
            .duration_ms = @intCast(@max(0, ended_ms - self.started_ms)),
            .exit_code = exit_code,
        }) catch |err| {
            self.fail(err);
            return;
        };
        self.commitManifest(.closed, ended_ms, exit_code, .indexed) catch |err| {
            self.fail(err);
            return;
        };
        self.archived = true;
        _ = archive.prune(self.retention_days.load(.acquire), ended_ms) catch |err| self.fail(err);
    }

    /// Encode the actual terminal, including both screens, history, modes and
    /// unfinished parser continuation. Never publish a raw-ring metadata frame
    /// as a VT snapshot, or a snapshot after any dropped recording event.
    fn saveCheckpoint(self: *Recording, timestamp_ms: i64) !void {
        self.lock();
        const valid = self.checkpoint_valid;
        self.mutex.unlock();
        if (!valid) return error.IncompleteRecording;
        var length: usize = 0;
        const result = c.ghostty_snapshot_encode_buf(self.terminal, null, 0, &length);
        if (result != c.GHOSTTY_OUT_OF_SPACE and result != c.GHOSTTY_SUCCESS) return error.RecordingSnapshotFailed;
        const bytes = try self.allocator.alloc(u8, length);
        defer self.allocator.free(bytes);
        if (c.ghostty_snapshot_encode_buf(self.terminal, bytes.ptr, bytes.len, &length) != c.GHOSTTY_SUCCESS) return error.RecordingSnapshotFailed;
        if (self.checkpoint.raw_file) |file| try file.sync(self.io);
        var atomic = try self.dir.createFileAtomic(self.io, self.checkpoint_path, .{ .permissions = @as(std.Io.File.Permissions, @fromBackingInt(0o600)), .make_path = true, .replace = true });
        defer atomic.deinit(self.io);
        try atomic.file.writePositionalAll(self.io, bytes[0..length], 0);
        try atomic.file.sync(self.io);
        try atomic.replace(self.io);
        self.checkpoint.scheduler.checkpointed(timestamp_ms);
        self.lock();
        self.checkpoint_count += 1;
        self.mutex.unlock();
    }

    /// A caller-owned terminal, restored only after the real codec validates
    /// FINISH. The lease excludes retention/cleanup for the full read/decode.
    pub fn restore(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, path: []const u8, max_bytes: usize) !c.GhosttyTerminal {
        var lease = try archive_mod.acquireLease(allocator, io, dir, path);
        defer lease.deinit();
        const bytes = try lease.readAll(allocator, max_bytes);
        defer allocator.free(bytes);
        var decoder: c.GhosttySnapshotDecoder = null;
        if (c.ghostty_snapshot_decoder_new_buf(null, &decoder, bytes.ptr, bytes.len) != c.GHOSTTY_SUCCESS) return error.InvalidRecordingSnapshot;
        defer c.ghostty_snapshot_decoder_free(decoder);
        const retain = true;
        if (c.ghostty_snapshot_decoder_set(decoder, c.GHOSTTY_SNAPSHOT_DECODER_OPT_RETAIN_CONTINUATION, &retain) != c.GHOSTTY_SUCCESS) return error.InvalidRecordingSnapshot;
        var terminal: c.GhosttyTerminal = null;
        if (c.ghostty_snapshot_decoder_decode(decoder, &terminal) != c.GHOSTTY_SUCCESS) return error.InvalidRecordingSnapshot;
        return terminal;
    }

    fn submitRequest(self: *Recording, owner: identity.SessionHandle, request: *Request) !void {
        if (!self.owner.eql(owner)) return error.StaleSession;
        _ = try identity.ExecutionId.parse(&request.execution_id);
        self.lock();
        if (self.stop or self.closed or self.writer == null) {
            self.mutex.unlock();
            return error.RecordingClosed;
        }
        if (self.failure != null and (request.output_scope != .session_interval or self.storage_failed)) {
            self.mutex.unlock();
            return error.RecordingDegraded;
        }
        const bytes = self.allocator.alloc(u8, 0) catch unreachable;
        self.queue.append(self.allocator, .{ .bytes = bytes, .timestamp_ms = @intCast(@import("native.zig").zw_local_monotonic_ms()), .request = request, .raw_offset = self.raw_position, .sequence = self.next_event_sequence }) catch |err| {
            self.mutex.unlock();
            return err;
        };
        if (request.kind == .barrier) request.raw_offset = self.raw_position;
        self.next_event_sequence +|= 1;
        self.mutex.unlock();
        self.wakeup.notify();
        while (!request.done.load(.acquire)) request.completion.wait(-1, false, -1);
        if (request.failure) |err| return err;
    }
    pub fn startBarrier(self: *Recording, owner: identity.SessionHandle, execution_id: []const u8) !StartBarrier {
        return self.startExecutionBarrier(owner, execution_id, .exact);
    }
    pub fn startExecutionBarrier(self: *Recording, owner: identity.SessionHandle, execution_id: []const u8, output_scope: manifest.execution.OutputScope) !StartBarrier {
        if (execution_id.len != 32) return error.InvalidExecutionId;
        var request: Request = .{ .kind = .barrier, .execution_id = execution_id[0..32].*, .completion = try Wakeup.init(), .output_scope = output_scope };
        defer request.completion.deinit();
        try self.submitRequest(owner, &request);
        return request.barrier.?;
    }
    /// Captures only the PTY stream order, before later text in the same read
    /// is queued. The trusted private-channel match still authenticates it via
    /// noteBoundary; a marker alone never seals or starts an execution.
    pub fn markBoundary(self: *Recording, owner: identity.SessionHandle, raw_offset: u64) !manifest.Position {
        if (!self.owner.eql(owner)) return error.StaleSession;
        self.lock();
        defer self.mutex.unlock();
        if (self.stop or self.closed) return error.RecordingClosed;
        const position: manifest.Position = .{ .raw_offset = raw_offset, .event_sequence = self.next_event_sequence };
        const bytes = self.allocator.alloc(u8, 0) catch unreachable;
        try self.queue.append(self.allocator, .{ .bytes = bytes, .timestamp_ms = @intCast(@import("native.zig").zw_local_monotonic_ms()), .raw_offset = raw_offset, .sequence = position.event_sequence, .boundary_marker = true });
        self.next_event_sequence +|= 1;
        self.wakeup.notify();
        return position;
    }
    pub fn noteBoundary(self: *Recording, owner: identity.SessionHandle, execution_id: []const u8, kind: BoundaryKind, raw_offset: u64, fence_sequence: u64) !BoundaryReceipt {
        return self.noteExecutionBoundary(owner, execution_id, kind, raw_offset, fence_sequence, .exact);
    }
    pub fn noteExecutionBoundary(self: *Recording, owner: identity.SessionHandle, execution_id: []const u8, kind: BoundaryKind, raw_offset: u64, fence_sequence: u64, output_scope: manifest.execution.OutputScope) !BoundaryReceipt {
        if (execution_id.len != 32 or fence_sequence == 0) return error.InvalidExecutionBoundary;
        var request: Request = .{ .kind = .boundary, .execution_id = execution_id[0..32].*, .completion = try Wakeup.init(), .boundary_kind = kind, .raw_offset = raw_offset, .fence_sequence = fence_sequence, .output_scope = output_scope };
        defer request.completion.deinit();
        try self.submitRequest(owner, &request);
        return request.boundary.?;
    }
    pub fn sealExecution(self: *Recording, owner: identity.SessionHandle, execution_id: []const u8, evidence: manifest.Evidence) !SealReceipt {
        if (execution_id.len != 32 or evidence == .pending or evidence == .cancelled_unsent or evidence == .foreground_finished) return error.InvalidExecutionEvidence;
        var request: Request = .{ .kind = .seal, .execution_id = execution_id[0..32].*, .completion = try Wakeup.init(), .evidence = evidence };
        defer request.completion.deinit();
        try self.submitRequest(owner, &request);
        return request.seal.?;
    }
    pub fn saveInterval(self: *Recording, owner: identity.SessionHandle, execution_id: []const u8, observation: Observation) !SealReceipt {
        if (execution_id.len != 32 or observation.process == null or !observation.process.?.foreground_finished) return error.InvalidExecutionEvidence;
        if (observation.reason) |reason| if (reason.len == 0 or reason.len > 96 or !std.unicode.utf8ValidateSlice(reason)) return error.InvalidExecutionEvidence;
        var request: Request = .{ .kind = .interval, .execution_id = execution_id[0..32].*, .completion = try Wakeup.init(), .evidence = .foreground_finished, .observation = observation, .output_scope = .session_interval };
        defer request.completion.deinit();
        try self.submitRequest(owner, &request);
        return request.seal.?;
    }
    pub fn abandonExecution(self: *Recording, owner: identity.SessionHandle, execution_id: []const u8, evidence: manifest.Evidence, reason: []const u8) !SealReceipt {
        return self.abandonObservedExecution(owner, execution_id, evidence, reason, .{});
    }
    pub fn abandonObservedExecution(self: *Recording, owner: identity.SessionHandle, execution_id: []const u8, evidence: manifest.Evidence, reason: []const u8, observation: Observation) !SealReceipt {
        if (execution_id.len != 32 or (evidence != .unknown and evidence != .cancelled_unsent) or reason.len == 0 or reason.len > 127) return error.InvalidExecutionEvidence;
        if (observation.reason) |attribution_reason| if (attribution_reason.len == 0 or attribution_reason.len > 96 or !std.unicode.utf8ValidateSlice(attribution_reason)) return error.InvalidExecutionEvidence;
        var request: Request = .{ .kind = .abandon, .execution_id = execution_id[0..32].*, .completion = try Wakeup.init(), .evidence = evidence, .reason = reason, .observation = observation, .output_scope = observation.output_scope };
        defer request.completion.deinit();
        try self.submitRequest(owner, &request);
        return request.seal.?;
    }
    fn processRequest(self: *Recording, request: *Request) !void {
        var range: ?*Range = null;
        for (self.ranges.items) |*candidate| if (std.mem.eql(u8, &candidate.id, &request.execution_id)) {
            range = candidate;
            break;
        };
        if (request.kind == .barrier and range == null) {
            if (self.ranges.items.len >= 4096) return error.RecordingRangeLimit;
            try self.ranges.append(self.allocator, .{ .id = request.execution_id, .start = .{ .raw_offset = request.raw_offset, .event_sequence = self.committed_position.event_sequence }, .output_scope = request.output_scope });
            range = &self.ranges.items[self.ranges.items.len - 1];
        }
        const current = range orelse return error.ExecutionRangeNotFound;
        switch (request.kind) {
            .barrier => {
                if (current.output_scope != request.output_scope or current.sealed or current.interval_saved or current.start_fence != null or current.evidence != .pending) return error.ExecutionAlreadyStarted;
                try self.commitManifest(.active, null, null, .recording);
                request.barrier = .{ .recording_id = self.recording_id, .archive_key = self.archive_key, .recording_generation = self.recording_generation, .raw_offset = request.raw_offset, .event_sequence = current.start.event_sequence, .manifest_revision = self.manifest_revision, .barrier_id = self.manifest_revision };
            },
            .boundary => {
                if (current.sealed or current.evidence != .pending or request.raw_offset < current.start.raw_offset) return error.InvalidExecutionBoundary;
                var position: manifest.Position = .{ .raw_offset = request.raw_offset, .event_sequence = self.committed_position.event_sequence + 1 };
                var ordered_marker = false;
                for (self.ordered_boundaries[0..self.boundary_count]) |candidate| if (candidate.raw_offset == request.raw_offset and (request.boundary_kind == .start or candidate.event_sequence > current.start.event_sequence)) {
                    position = candidate;
                    ordered_marker = true;
                    break;
                };
                if (!ordered_marker and request.raw_offset < self.committed_position.raw_offset) return error.InvalidExecutionBoundary;
                switch (request.boundary_kind) {
                    .start => {
                        if (current.start_fence != null) return error.ExecutionAlreadyStarted;
                        current.start = position;
                        current.start_fence = request.fence_sequence;
                    },
                    .end => {
                        if (current.start_fence == null or current.end != null or request.fence_sequence <= current.start_fence.?) return error.InvalidExecutionBoundary;
                        current.end = position;
                        current.end_fence = request.fence_sequence;
                    },
                }
                if (position.event_sequence > self.committed_position.event_sequence) self.committed_position = position;
                try self.commitManifest(.active, null, null, .recording);
                request.boundary = .{ .position = position, .boundary_sequence = request.fence_sequence, .manifest_revision = self.manifest_revision };
            },
            .abandon => {
                if (current.sealed or current.interval_saved) return error.ExecutionAlreadyStarted;
                current.evidence = request.evidence;
                current.observe(request.observation);
                @memcpy(current.reason[0..request.reason.len], request.reason);
                current.reason_len = @intCast(request.reason.len);
                try self.commitManifest(.active, null, null, .recording);
                request.seal = .{ .recording_id = self.recording_id, .recording_generation = self.recording_generation, .start = current.start, .end = current.end orelse self.committed_position, .manifest_revision = self.manifest_revision, .committed_length = self.committed_length, .coverage = .partial, .replayability = self.replayability, .sealed = false };
            },
            .seal, .interval => {
                if (current.sealed or current.interval_saved or current.evidence != .pending) return error.ExecutionAlreadyStarted;
                if (current.end == null or current.start_fence == null or current.end_fence == null) return error.OutputBoundaryPending;
                if ((request.kind == .interval) != (current.output_scope == .session_interval)) return error.InvalidExecutionEvidence;
                current.evidence = request.evidence;
                current.sealed = request.kind == .seal and request.evidence != .unknown;
                if (request.kind == .interval) {
                    current.observe(request.observation);
                    current.interval_saved = self.intervalDataRetained(current);
                }
                self.commitManifest(.active, null, null, .recording) catch |err| {
                    current.interval_saved = false;
                    return err;
                };
                request.seal = .{ .recording_id = self.recording_id, .recording_generation = self.recording_generation, .start = current.start, .end = current.end.?, .manifest_revision = self.manifest_revision, .committed_length = self.committed_length, .coverage = self.coverage, .replayability = self.replayability, .sealed = current.sealed and self.coverage != .gapped and self.replayability == .verified, .interval_saved = current.interval_saved };
            },
        }
    }
    fn intervalDataRetained(self: *Recording, range: *const Range) bool {
        // The sole writer tracks actual evicted data events; protocol/request
        // sequence numbers between them are not treated as missing output.
        if (self.evicted_through_sequence > range.start.event_sequence) return false;
        const end = range.end orelse return false;
        self.lock();
        defer self.mutex.unlock();
        if (self.storage_failed) return false;
        for (self.gaps[0..self.gap_count]) |gap| {
            if (gap.end.event_sequence > range.start.event_sequence and gap.start.event_sequence < end.event_sequence) return false;
        }
        return true;
    }
    fn appendTimeline(self: *Recording, segment: Segment) !void {
        var geometry_buffer: [32]u8 = undefined;
        const bytes = if (segment.geometry) |geometry| try std.fmt.bufPrint(&geometry_buffer, "{d}x{d}", .{ geometry.cols, geometry.rows }) else segment.bytes;
        const kind: @FieldType(Timeline.Event, "kind") = if (segment.geometry != null) .resize else if (segment.application) .application else .output;
        try self.timeline.appendOrdered(segment.timestamp_ms, segment.raw_offset, bytes, kind, segment.sequence);
        try self.mappings.append(self.allocator, .{ .sequence = segment.sequence, .raw_offset = segment.raw_offset, .raw_length = if (kind == .output) bytes.len else 0, .cast_line = self.timeline.evicted_events + self.timeline.events.items.len, .kind = switch (kind) {
            .output => .output,
            .resize => .resize,
            .application => .application,
        } });
        while (self.mappings.items.len > self.timeline.events.items.len) self.evicted_through_sequence = @max(self.evicted_through_sequence, self.mappings.orderedRemove(0).sequence);
    }
    fn commitManifest(self: *Recording, state: @FieldType(manifest.Manifest, "state"), ended_ms: ?i64, exit_code: ?i32, commit_state: @FieldType(@FieldType(manifest.Manifest, "commit"), "state")) !void {
        // This is called by the sole writer, or after it has been joined.
        if (self.checkpoint.raw_file) |file| try file.sync(self.io);
        const revision = try std.math.add(u64, self.manifest_revision, 1);
        const data_path = if (state == .active) try std.fmt.allocPrint(self.allocator, "{s}.commit-{d}.cast", .{ self.cast_path[0 .. self.cast_path.len - 5], revision }) else try self.allocator.dupe(u8, self.cast_path);
        errdefer self.allocator.free(data_path);
        try self.timeline.saveCast(self.io, self.dir, data_path, self.initial_cols, self.initial_rows);
        errdefer self.dir.deleteFile(self.io, data_path) catch {};
        var file_checksums: [3][64]u8 = undefined;
        var files: [3]manifest.File = undefined;
        var count: usize = 0;
        const paths = [_][]const u8{ data_path, self.raw_path, self.checkpoint_path };
        const kinds = [_]@FieldType(manifest.File, "kind"){ .cast, .raw, .checkpoint };
        for (paths, kinds) |path, kind| {
            if (state == .active and kind != .cast) continue;
            const file = manifest.openManaged(self.io, self.dir, path) catch |err| {
                if (kind == .checkpoint and err == error.FileNotFound) continue;
                return err;
            };
            defer file.close(self.io);
            const stat = try file.stat(self.io);
            file_checksums[count] = try manifest.fingerprint(self.io, file, stat.size);
            files[count] = .{ .path = path, .kind = kind, .committed_length = stat.size, .checksum = &file_checksums[count] };
            count += 1;
        }
        const ranges = try self.allocator.alloc(manifest.ExecutionRange, self.ranges.items.len);
        defer self.allocator.free(ranges);
        for (self.ranges.items, ranges) |*range, *target| target.* = .{ .execution_id = &range.id, .recording_generation = self.recording_generation, .start = range.start, .end = range.end, .start_boundary_sequence = range.start_fence, .end_boundary_sequence = range.end_fence, .completion_evidence = range.evidence, .sealed = range.sealed, .output_scope = range.output_scope, .output_attribution = range.output_attribution, .output_attribution_reason = if (range.attribution_reason_len > 0) range.attribution_reason[0..range.attribution_reason_len] else null, .process_receipt = range.process, .interval_saved = range.interval_saved, .failure = if (range.reason_len > 0) range.reason[0..range.reason_len] else null };
        self.lock();
        const total_received = self.raw_position;
        const dropped = self.dropped_bytes;
        const failure = self.failure;
        var display = self.display;
        display.final_cols = self.cols;
        display.final_rows = self.rows;
        const last_sequence = self.next_event_sequence - 1;
        var frozen_gaps: [65]manifest.Gap = undefined;
        @memcpy(frozen_gaps[0..self.gap_count], self.gaps[0..self.gap_count]);
        var gap_count = self.gap_count;
        self.mutex.unlock();
        self.coverage = if (failure != null) .partial else if (dropped > 0) .gapped else if (self.timeline.evicted_events > 0) .retained else .complete;
        self.replayability = if (self.timeline.evicted_events > 0 or dropped > 0) .baseline_unavailable else .verified;
        const start: manifest.Position = if (self.timeline.events.items.len == 0) .{} else .{ .raw_offset = self.timeline.events.items[0].stream_offset, .event_sequence = self.timeline.events.items[0].event_sequence };
        const baseline: manifest.Baseline = .{ .event_sequence = 0, .raw_offset = 0, .kind = .initial_empty };
        const gap: manifest.Gap = .{ .start = self.committed_position, .end = .{ .raw_offset = total_received, .event_sequence = last_sequence }, .reason = failure orelse "RecordingQueueFull", .known_dropped_bytes = dropped };
        if (failure != null and gap_count == 0) {
            frozen_gaps[gap_count] = gap;
            gap_count += 1;
        }
        for (self.mappings.items, 0..) |*mapping, index| mapping.cast_line = index + 1;
        const segment: manifest.Segment = .{ .start = start, .end = self.committed_position, .data_file_ref = data_path, .committed_length = files[0].committed_length, .checksum = files[0].checksum };
        const generation: manifest.Generation = .{ .recording_generation = self.recording_generation, .session_id = @backingInt(self.owner.session_id), .session_generation = self.owner.generation, .initial_cols = self.initial_cols, .initial_rows = self.initial_rows, .receive_time_origin = self.receive_time_origin, .segments = &.{segment}, .baselines = if (self.replayability == .verified) &.{baseline} else &.{} };
        try manifest.save(self.allocator, self.io, self.dir, self.manifest_path, .{ .archive_key = &self.archive_key, .recording_id = &self.recording_id, .manifest_revision = revision, .source_kind = .local, .started_ms = self.started_ms, .ended_ms = ended_ms, .exit_code = exit_code, .end_reason = if (state == .closed) "process_closed" else null, .state = state, .recording = .{ .generations = &.{generation} }, .execution_ranges = ranges, .files = files[0..count], .events = self.mappings.items, .display = display, .coverage = self.coverage, .replayability = self.replayability, .total_received = total_received, .retained_range = .{ .start = start, .end = self.committed_position }, .gaps = frozen_gaps[0..gap_count], .failure = failure, .commit = .{ .state = commit_state, .committed_length = files[0].committed_length } });
        if (self.committed_cast_path) |previous| {
            if (!std.mem.eql(u8, previous, self.cast_path)) self.dir.deleteFile(self.io, previous) catch {};
            self.allocator.free(previous);
        }
        self.committed_cast_path = data_path;
        self.manifest_revision = revision;
        self.committed_length = files[0].committed_length;
    }

    fn stopWriter(self: *Recording) void {
        self.lock();
        self.stop = true;
        self.mutex.unlock();
        self.wakeup.notify();
        if (self.writer) |thread| thread.join();
        self.writer = null;
    }
    fn writeLoop(self: *Recording) void {
        while (true) {
            self.lock();
            const segment = if (self.queue.items.len > 0) self.queue.orderedRemove(0) else null;
            if (segment) |value| self.queued_bytes -= value.bytes.len;
            const done = self.stop and segment == null;
            self.mutex.unlock();
            if (done) {
                self.saveCheckpoint(@intCast(@import("native.zig").zw_local_monotonic_ms())) catch |err| self.fail(err);
                return;
            }
            if (segment) |value| {
                defer self.allocator.free(value.bytes);
                if (value.request) |request| {
                    self.processRequest(request) catch |err| {
                        request.failure = err;
                        switch (err) {
                            error.OutputBoundaryPending, error.InvalidExecutionBoundary, error.InvalidExecutionEvidence, error.ExecutionAlreadyStarted, error.ExecutionRangeNotFound, error.RecordingRangeLimit => {},
                            else => self.fail(err),
                        }
                    };
                    request.done.store(true, .release);
                    request.completion.notify();
                    continue;
                }
                if (value.boundary_marker) {
                    if (self.boundary_count == self.ordered_boundaries.len) {
                        std.mem.copyForwards(manifest.Position, &self.ordered_boundaries, self.ordered_boundaries[1..]);
                        self.boundary_count -= 1;
                    }
                    const position: manifest.Position = .{ .raw_offset = value.raw_offset, .event_sequence = value.sequence };
                    self.ordered_boundaries[self.boundary_count] = position;
                    self.boundary_count += 1;
                    self.committed_position = position;
                    continue;
                }
                if (value.sequence != 0) {
                    self.appendTimeline(value) catch |err| self.fail(err);
                    self.committed_position = .{ .raw_offset = value.raw_offset +| (if (value.application or value.geometry != null) @as(u64, 0) else value.bytes.len), .event_sequence = value.sequence };
                }
                if (value.application) {
                    // Application records are saved as cast application events.
                } else if (value.theme) |theme| {
                    self.applyTheme(theme) catch |err| {
                        self.fail(err);
                        self.lock();
                        self.checkpoint_valid = false;
                        self.mutex.unlock();
                    };
                } else if (value.geometry) |geometry| {
                    if (c.ghostty_terminal_resize(self.terminal, geometry.cols, geometry.rows, 0, 0) != c.GHOSTTY_SUCCESS) {
                        self.fail(error.RecordingResizeFailed);
                        self.lock();
                        self.checkpoint_valid = false;
                        self.mutex.unlock();
                    }
                } else {
                    c.ghostty_terminal_vt_write(self.terminal, value.bytes.ptr, value.bytes.len);
                    self.checkpoint.appendRaw(value.bytes) catch |err| self.fail(err);
                }
                if (self.checkpoint.scheduler.due(value.timestamp_ms)) self.saveCheckpoint(value.timestamp_ms) catch |err| self.fail(err);
            } else {
                self.wakeup.wait(-1, false, -1);
            }
        }
    }
};

test "complete Local checkpoint restores both screens modes and unfinished parser" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(path);
    const owner: identity.SessionHandle = .{ .session_id = @fromBackingInt(41), .generation = 1 };
    const recording = try Recording.init(std.testing.allocator, owner, .{ .io = std.testing.io, .directory = path, .log = .{ .ring_mb = 1, .checkpoint_sec = 1 } }, 80, 24, 0);
    defer recording.deinit();
    try std.testing.expectEqual(@as(usize, 0), recording.checkpoint.tap.buffer.len);
    try std.testing.expectEqual(@as(usize, 1024 * 1024), recording.checkpoint.tap.capacity());
    recording.appendOutput(owner, "primary\r\n\x1b[?1049halternate\x1b[?2004h\x1b[38;2;10;20;", 1000);
    recording.resizeApplied(owner, 100, 30, 1100);
    recording.stopWriter();
    const bytes = try tmp.dir.readFileAlloc(std.testing.io, recording.checkpoint_path, std.testing.allocator, .limited(4 * 1024 * 1024));
    defer std.testing.allocator.free(bytes);
    try std.testing.expect(std.mem.startsWith(u8, bytes, "GHOSTSNP"));
    const restored = try Recording.restore(std.testing.allocator, std.testing.io, tmp.dir, recording.checkpoint_path, 4 * 1024 * 1024);
    defer c.ghostty_terminal_free(restored);
    const suffix = "30mZ\x1b[?1049l!";
    c.ghostty_terminal_vt_write(recording.terminal, suffix.ptr, suffix.len);
    c.ghostty_terminal_vt_write(restored, suffix.ptr, suffix.len);
    var original_length: usize = 0;
    var restored_length: usize = 0;
    try std.testing.expectEqual(c.GHOSTTY_OUT_OF_SPACE, c.ghostty_snapshot_encode_buf(recording.terminal, null, 0, &original_length));
    try std.testing.expectEqual(c.GHOSTTY_OUT_OF_SPACE, c.ghostty_snapshot_encode_buf(restored, null, 0, &restored_length));
    try std.testing.expectEqual(original_length, restored_length);
    const original_bytes = try std.testing.allocator.alloc(u8, original_length);
    defer std.testing.allocator.free(original_bytes);
    const restored_bytes = try std.testing.allocator.alloc(u8, restored_length);
    defer std.testing.allocator.free(restored_bytes);
    try std.testing.expectEqual(c.GHOSTTY_SUCCESS, c.ghostty_snapshot_encode_buf(recording.terminal, original_bytes.ptr, original_bytes.len, &original_length));
    try std.testing.expectEqual(c.GHOSTTY_SUCCESS, c.ghostty_snapshot_encode_buf(restored, restored_bytes.ptr, restored_bytes.len, &restored_length));
    try std.testing.expectEqualSlices(u8, original_bytes, restored_bytes);
}

test "recording allocation failure cannot prevent close or publish a false archive" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(path);
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const owner: identity.SessionHandle = .{ .session_id = @fromBackingInt(42), .generation = 1 };
    const recording = try Recording.init(failing.allocator(), owner, .{ .io = std.testing.io, .directory = path, .log = .{ .ring_mb = 1, .checkpoint_sec = 1 } }, 80, 24, 0);
    defer recording.deinit();
    failing.fail_index = failing.alloc_index;
    recording.appendOutput(owner, "cannot allocate", 2000);
    recording.close(owner, recording.started_ms + 1, 0);
    const state = recording.snapshot();
    try std.testing.expect(state.closed and !state.archived);
    try std.testing.expectEqualStrings("OutOfMemory", state.failure.?);
}

test "idle recording writer wakes for output theme resize and drains its final queue on close" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(path);
    const owner: identity.SessionHandle = .{ .session_id = @fromBackingInt(43), .generation = 1 };
    const recording = try Recording.init(std.testing.allocator, owner, .{ .io = std.testing.io, .directory = path, .log = .{ .ring_mb = 1, .checkpoint_sec = 1 } }, 80, 24, 0);
    defer recording.deinit();
    const Harness = struct {
        fn idle() void {
            const delay: std.c.timespec = .{ .sec = 0, .nsec = 10 * std.time.ns_per_ms };
            _ = std.c.nanosleep(&delay, null);
        }
        fn checkpoint(value: *Recording, count: u64) !void {
            const deadline = @import("native.zig").zw_local_monotonic_ms() + 2000;
            while (value.snapshot().checkpoint_count < count) {
                if (@import("native.zig").zw_local_monotonic_ms() >= deadline) return error.WriterDidNotWake;
                idle();
            }
            // Let the consumer return to its blocking wait before each kind
            // of producer is exercised. There is no timed writer fallback.
            idle();
        }
    };
    Harness.idle();
    recording.appendOutput(owner, "中文\x1b[31mfirst\x1b[0m", 1000);
    try Harness.checkpoint(recording, 1);
    recording.themeApplied(owner, .{ .revision = 1, .foreground = 0xeeeeeeff, .background = 0x121212ff, .cursor = 0xffffffff, .selection = 0x444444ff, .ansi = @splat(0x123456ff) }, 2000);
    try Harness.checkpoint(recording, 2);
    recording.resizeApplied(owner, 100, 30, 3000);
    try Harness.checkpoint(recording, 3);
    for (0..128) |_| recording.appendOutput(owner, "tail\n", 3100);
    recording.close(owner, recording.started_ms + 4000, 0);
    const state = recording.snapshot();
    try std.testing.expect(state.closed and state.archived);
    try std.testing.expect(state.failure == null);
    try std.testing.expectEqual(@as(u64, 0), state.dropped_bytes);
    const raw = try Checkpoint.loadRaw(std.testing.allocator, std.testing.io, tmp.dir, recording.raw_path, 1024 * 1024);
    defer std.testing.allocator.free(raw);
    try std.testing.expect(std.mem.startsWith(u8, raw, "中文\x1b[31mfirst\x1b[0m"));
    try std.testing.expectEqual(@as(usize, 128), std.mem.count(u8, raw, "tail\n"));
    const cast = try tmp.dir.readFileAlloc(std.testing.io, recording.cast_path, std.testing.allocator, .limited(16 * 1024));
    defer std.testing.allocator.free(cast);
    try std.testing.expect(std.mem.indexOf(u8, cast, "中文") != null);
    try std.testing.expect(std.mem.indexOf(u8, cast, "\"r\",\"100x30\"") != null);
    try std.testing.expectEqual(@as(usize, 128), std.mem.count(u8, cast, "tail\\n"));
}

test "Local export lease keeps the original recording alive after owner release" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(path);
    const owner: identity.SessionHandle = .{ .session_id = @fromBackingInt(919), .generation = 2 };
    const recording = try Recording.init(std.testing.allocator, owner, .{ .io = std.testing.io, .directory = path, .log = .{ .ring_mb = 1, .checkpoint_sec = 30 } }, 80, 24, 0);
    recording.appendOutput(owner, "owned before close", 100);
    const lease = recording.exportLease();
    defer lease.release(lease.context);
    recording.deinit();
    var captured = try lease.capture(lease.context, std.testing.allocator);
    defer captured.deinit();
    try std.testing.expectEqual(@as(usize, 1), captured.events.items.len);
    try std.testing.expectEqualStrings("owned before close", captured.events.items[0].payload);
}

test "recording durable barrier orders zero output boundaries and preserves exact identity after close" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(path);
    const owner: identity.SessionHandle = .{ .session_id = @fromBackingInt(512), .generation = 3 };
    const recording = try Recording.init(std.testing.allocator, owner, .{ .io = std.testing.io, .directory = path, .log = .{ .ring_mb = 1, .checkpoint_sec = 30 } }, 80, 24, 0);
    defer recording.deinit();
    const execution_id = "11111111111111111111111111111111";
    const barrier = try recording.startBarrier(owner, execution_id);
    try std.testing.expect(barrier.manifest_revision > 0);
    var live_archive: archive_mod.Archive = .{ .allocator = std.testing.allocator, .io = std.testing.io, .dir = tmp.dir };
    var live_record = try live_archive.resolveRecord(std.testing.allocator, .{ .recording_id = &barrier.recording_id, .execution_id = execution_id });
    defer live_record.deinit();
    try std.testing.expect(live_record.execution_range != null);
    var global_while_live = try live_archive.loadCatalog(std.testing.allocator);
    defer global_while_live.deinit();
    try std.testing.expectEqual(@as(usize, 0), global_while_live.entries.items.len);
    const persisted = try manifest.load(std.testing.allocator, std.testing.io, tmp.dir, recording.manifest_path);
    defer persisted.deinit();
    try std.testing.expectEqualStrings(&barrier.recording_id, persisted.value.recording_id);
    const start = try recording.noteBoundary(owner, execution_id, .start, 0, 1);
    try std.testing.expectError(error.OutputBoundaryPending, recording.sealExecution(owner, execution_id, .exit_confirmed));
    const end = try recording.noteBoundary(owner, execution_id, .end, 0, 2);
    const seal = try recording.sealExecution(owner, execution_id, .exit_confirmed);
    try std.testing.expect(seal.sealed);
    try std.testing.expectEqual(start.position.raw_offset, end.position.raw_offset);
    try std.testing.expect(end.position.event_sequence > start.position.event_sequence);
    recording.close(owner, recording.started_ms + 1, 0);
    try std.testing.expect(recording.snapshot().archived);
    var archive: archive_mod.Archive = .{ .allocator = std.testing.allocator, .io = std.testing.io, .dir = tmp.dir };
    var resolved = try archive.resolveRecord(std.testing.allocator, .{ .recording_id = &barrier.recording_id, .execution_id = execution_id });
    defer resolved.deinit();
    try std.testing.expectEqual(@as(u64, 3), resolved.descriptor.document.?.recording.generations[0].session_generation);
    try std.testing.expect(resolved.execution_range.?.sealed);
    var lease = try archive.acquireRecord(std.testing.allocator, resolved.descriptor);
    defer lease.deinit();
    try std.testing.expectEqual(@as(usize, 4), lease.leases.items.len);
}

test "recording crash recovery exposes last committed snapshot and index failure retains one archive key" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(path);
    const owner: identity.SessionHandle = .{ .session_id = @fromBackingInt(513), .generation = 1 };
    const recording = try Recording.init(std.testing.allocator, owner, .{ .io = std.testing.io, .directory = path, .log = .{ .ring_mb = 1, .checkpoint_sec = 30 } }, 80, 24, 0);
    recording.appendOutput(owner, "committed", 1);
    const barrier = try recording.startBarrier(owner, "22222222222222222222222222222222");
    recording.appendOutput(owner, "uncommitted", 2);
    recording.deinit(); // Simulates loss of the live owner without a close receipt.
    var archive: archive_mod.Archive = .{ .allocator = std.testing.allocator, .io = std.testing.io, .dir = tmp.dir };
    var recovered = try archive.resolveRecord(std.testing.allocator, .{ .recording_id = &barrier.recording_id });
    defer recovered.deinit();
    try std.testing.expectEqualStrings("AbnormalTermination", recovered.descriptor.failure.?);
    try std.testing.expectEqual(manifest.Coverage.partial, recovered.descriptor.coverage);
    var lease = try archive.acquireRecord(std.testing.allocator, recovered.descriptor);
    defer lease.deinit();
    const bytes = try lease.cast().readAll(std.testing.allocator, 4096);
    defer std.testing.allocator.free(bytes);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "committed") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "uncommitted") == null);
    const second = try Recording.init(std.testing.allocator, .{ .session_id = @fromBackingInt(514), .generation = 1 }, .{ .io = std.testing.io, .directory = path, .log = .{ .ring_mb = 1, .checkpoint_sec = 30 } }, 80, 24, 0);
    defer second.deinit();
    const key = second.archive_key;
    try tmp.dir.createDir(std.testing.io, "logs/history/index.tsv", .default_dir);
    second.appendOutput(second.owner, "saved before index", 3);
    second.close(second.owner, second.started_ms + 1, 0);
    try std.testing.expect(!second.snapshot().archived);
    // Metadata loading may report the TSV error; the durable manifest remains
    // independently recoverable after that index fault is repaired.
    try tmp.dir.deleteDir(std.testing.io, "logs/history/index.tsv");
    var catalog = try archive.loadCatalog(std.testing.allocator);
    defer catalog.deinit();
    var matches: usize = 0;
    for (catalog.entries.items) |entry| if (std.mem.eql(u8, entry.archive_key, &key)) {
        matches += 1;
        try std.testing.expectEqualStrings("IndexPending", entry.failure.?);
    };
    try std.testing.expectEqual(@as(usize, 1), matches);
}

test "recording retained ANSI tail refuses accurate replay without a matching baseline" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(path);
    const owner: identity.SessionHandle = .{ .session_id = @fromBackingInt(515), .generation = 1 };
    const recording = try Recording.init(std.testing.allocator, owner, .{ .io = std.testing.io, .directory = path, .log = .{ .ring_mb = 1, .checkpoint_sec = 30 } }, 80, 24, 0);
    defer recording.deinit();
    const bytes = try std.testing.allocator.alloc(u8, 512 * 1024);
    defer std.testing.allocator.free(bytes);
    @memset(bytes, 'x');
    @memcpy(bytes[0..8], "\x1b[?1049h");
    for ([_][]const u8{ "11111111111111111111111111111111", "22222222222222222222222222222222", "33333333333333333333333333333333" }) |id| {
        recording.appendOutput(owner, bytes, 1);
        _ = try recording.startBarrier(owner, id);
    }
    recording.close(owner, recording.started_ms + 1, 0);
    var archive: archive_mod.Archive = .{ .allocator = std.testing.allocator, .io = std.testing.io, .dir = tmp.dir };
    var resolved = try archive.resolveRecord(std.testing.allocator, .{ .recording_id = &recording.recording_id });
    defer resolved.deinit();
    try std.testing.expectEqual(manifest.Coverage.retained, resolved.descriptor.coverage);
    try std.testing.expectEqual(manifest.Replayability.baseline_unavailable, resolved.descriptor.replayability);
    try std.testing.expect(!resolved.descriptor.can_open);
    try std.testing.expectError(error.RecordingUnavailable, archive.acquireRecord(std.testing.allocator, resolved.descriptor));
}

test "recording late private evidence preserves ordered fences before subsequent prompt output" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(path);
    const owner: identity.SessionHandle = .{ .session_id = @fromBackingInt(516), .generation = 1 };
    const recording = try Recording.init(std.testing.allocator, owner, .{ .io = std.testing.io, .directory = path, .log = .{ .ring_mb = 1, .checkpoint_sec = 30 } }, 80, 24, 0);
    defer recording.deinit();
    const id = "55555555555555555555555555555555";
    _ = try recording.startBarrier(owner, id);
    const marked_start = try recording.markBoundary(owner, 10);
    recording.appendOutputAt(owner, "text", 1, 10);
    const marked_end = try recording.markBoundary(owner, 14);
    recording.appendOutputAt(owner, "prompt", 2, 30);
    // The private channel can arrive after the entire PTY read was consumed.
    const start = try recording.noteBoundary(owner, id, .start, 10, 1);
    const end = try recording.noteBoundary(owner, id, .end, 14, 2);
    const seal = try recording.sealExecution(owner, id, .exit_confirmed);
    try std.testing.expectEqual(marked_start.event_sequence, start.position.event_sequence);
    try std.testing.expectEqual(marked_end.event_sequence, end.position.event_sequence);
    try std.testing.expect(seal.sealed);
    const persisted = try manifest.load(std.testing.allocator, std.testing.io, tmp.dir, recording.manifest_path);
    defer persisted.deinit();
    const events = persisted.value.events;
    try std.testing.expectEqual(@as(usize, 2), events.len);
    try std.testing.expect(start.position.event_sequence < events[0].sequence and events[0].sequence < end.position.event_sequence);
    try std.testing.expect(end.position.event_sequence < events[1].sequence);
    try std.testing.expectEqual(@as(u64, 14), persisted.value.execution_ranges[0].end.?.raw_offset);
}

test "recording cancelled unsent range settles durably without inventing an END" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(path);
    const owner: identity.SessionHandle = .{ .session_id = @fromBackingInt(517), .generation = 1 };
    const recording = try Recording.init(std.testing.allocator, owner, .{ .io = std.testing.io, .directory = path, .log = .{ .ring_mb = 1, .checkpoint_sec = 30 } }, 80, 24, 0);
    defer recording.deinit();
    const cancelled = "66666666666666666666666666666666";
    _ = try recording.startBarrier(owner, cancelled);
    const receipt = try recording.abandonExecution(owner, cancelled, .cancelled_unsent, "CancelledBeforeSubmit");
    try std.testing.expect(!receipt.sealed);
    const next = "77777777777777777777777777777777";
    _ = try recording.startBarrier(owner, next);
    _ = try recording.noteBoundary(owner, next, .start, 0, 1);
    _ = try recording.noteBoundary(owner, next, .end, 0, 2);
    try std.testing.expect((try recording.sealExecution(owner, next, .exit_confirmed)).sealed);
    const persisted = try manifest.load(std.testing.allocator, std.testing.io, tmp.dir, recording.manifest_path);
    defer persisted.deinit();
    const range = persisted.value.execution_ranges[0];
    try std.testing.expectEqual(manifest.Evidence.cancelled_unsent, range.completion_evidence);
    try std.testing.expect(range.end == null and !range.sealed);
    try std.testing.expectEqualStrings("CancelledBeforeSubmit", range.failure.?);
}

test "recording failed initialization rolls back published identity before metadata-only failure" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(path);
    const owner: identity.SessionHandle = .{ .session_id = @fromBackingInt(518), .generation = 1 };
    const ids = archive_mod.MetadataIdentity.generate();
    test_init_failure_after_manifest = true;
    defer test_init_failure_after_manifest = false;
    try std.testing.expectError(error.InjectedRecordingInitFailure, Recording.initWithIdentity(std.testing.allocator, owner, .{ .io = std.testing.io, .directory = path, .log = .{ .ring_mb = 1, .checkpoint_sec = 30 } }, 80, 24, 0, ids));
    var history = try tmp.dir.openDir(std.testing.io, "logs/history", .{ .iterate = true });
    defer history.close(std.testing.io);
    var iterator = history.iterate();
    try std.testing.expect((try iterator.next(std.testing.io)) == null);
    var archive: archive_mod.Archive = .{ .allocator = std.testing.allocator, .io = std.testing.io, .dir = tmp.dir };
    _ = try archive.publishMetadata(.{ .identity = ids, .owner = owner, .source_kind = .local, .started_ms = 1, .ended_ms = 2, .initial_cols = 80, .initial_rows = 24, .display = .{ .title = "failed recording", .host = "local" }, .reason = .RecordingUnavailable, .failure = "InjectedRecordingInitFailure" });
    var catalog = try archive.loadCatalog(std.testing.allocator);
    defer catalog.deinit();
    try std.testing.expectEqual(@as(usize, 1), catalog.entries.items.len);
    const expected = std.fmt.bytesToHex(ids.recording_id.bytes, .lower);
    try std.testing.expectEqualStrings(&expected, catalog.entries.items[0].recording_id.?);
    try std.testing.expectEqualStrings("InjectedRecordingInitFailure", catalog.entries.items[0].failure.?);
    try std.testing.expect(!catalog.entries.items[0].can_open);
}

test "recording interval durably preserves zero output foreground and unknown attribution without exact seal" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(path);
    const owner: identity.SessionHandle = .{ .session_id = @fromBackingInt(518), .generation = 1 };
    const recording = try Recording.init(std.testing.allocator, owner, .{ .io = std.testing.io, .directory = path, .log = .{ .ring_mb = 1, .checkpoint_sec = 30 } }, 80, 24, 0);
    defer recording.deinit();
    const id = "66666666666666666666666666666666";
    _ = try recording.startExecutionBarrier(owner, id, .session_interval);
    const observation: Observation = .{ .attribution = .unverified, .reason = "OutputProcessIdentityUnknown", .process = .{ .exit_code = 7, .foreground_finished = true, .background_jobs_unknown = true } };
    _ = try recording.noteBoundary(owner, id, .start, 0, 1);
    try std.testing.expectError(error.OutputBoundaryPending, recording.saveInterval(owner, id, observation));
    const end = try recording.noteBoundary(owner, id, .end, 0, 2);
    const receipt = try recording.saveInterval(owner, id, observation);
    try std.testing.expect(receipt.interval_saved and !receipt.sealed and receipt.end.event_sequence == end.position.event_sequence);
    recording.close(owner, recording.started_ms + 1, 0);
    const persisted = try manifest.load(std.testing.allocator, std.testing.io, tmp.dir, recording.manifest_path);
    defer persisted.deinit();
    const range = persisted.value.execution_ranges[0];
    try std.testing.expect(range.interval_saved and !range.sealed and range.output_scope == .session_interval);
    try std.testing.expect(range.completion_evidence == .foreground_finished and range.output_attribution == .unverified);
    try std.testing.expectEqualStrings("OutputProcessIdentityUnknown", range.output_attribution_reason.?);
    try std.testing.expect(range.process_receipt.?.exit_code == 7 and range.process_receipt.?.background_jobs_unknown);
    try std.testing.expect(range.start.raw_offset == range.end.?.raw_offset and range.end.?.event_sequence > range.start.event_sequence);
}

test "recording interval failed manifest publication never reports a saved interval" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(path);
    const owner: identity.SessionHandle = .{ .session_id = @fromBackingInt(519), .generation = 1 };
    const recording = try Recording.init(std.testing.allocator, owner, .{ .io = std.testing.io, .directory = path, .log = .{ .ring_mb = 1, .checkpoint_sec = 30 } }, 80, 24, 0);
    defer recording.deinit();
    const id = "77777777777777777777777777777777";
    _ = try recording.startExecutionBarrier(owner, id, .session_interval);
    _ = try recording.noteBoundary(owner, id, .start, 0, 1);
    _ = try recording.noteBoundary(owner, id, .end, 0, 2);
    // Replacing the publication target with a directory deterministically fails
    // the atomic manifest replacement, after the interval bytes were written.
    try tmp.dir.deleteFile(std.testing.io, recording.manifest_path);
    try tmp.dir.createDir(std.testing.io, recording.manifest_path, .default_dir);
    if (recording.saveInterval(owner, id, .{ .process = .{ .exit_code = 0, .foreground_finished = true } })) |_| return error.UnexpectedSavedInterval else |_| {}
    try std.testing.expect(!recording.ranges.items[0].interval_saved and !recording.ranges.items[0].sealed);
    try std.testing.expect(recording.snapshot().failure != null and recording.snapshot().storage_failed);
    try std.testing.expectError(error.RecordingDegraded, recording.startExecutionBarrier(owner, "88888888888888888888888888888888", .session_interval));
}

test "recording interval retention ignores old eviction and gaps but refuses loss inside its own boundaries" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(path);
    const owner: identity.SessionHandle = .{ .session_id = @fromBackingInt(520), .generation = 1 };
    const recording = try Recording.init(std.testing.allocator, owner, .{ .io = std.testing.io, .directory = path, .log = .{ .ring_mb = 1, .checkpoint_sec = 30 } }, 80, 24, 0);
    defer recording.deinit();
    const bytes = try std.testing.allocator.alloc(u8, 512 * 1024);
    defer std.testing.allocator.free(bytes);
    @memset(bytes, 'x');
    const old_ids = [_][]const u8{ "11111111111111111111111111111111", "22222222222222222222222222222222", "33333333333333333333333333333333" };
    for (old_ids) |id| {
        recording.appendOutput(owner, bytes, 1);
        _ = try recording.startBarrier(owner, id);
    }
    try std.testing.expect(recording.evicted_through_sequence > 0);
    const dropped = try std.testing.allocator.alloc(u8, recording.queue_capacity + 1);
    defer std.testing.allocator.free(dropped);
    @memset(dropped, 'q');
    // A bounded queue rejection is a real, precisely located historical gap.
    recording.appendOutput(owner, dropped, 2);
    try std.testing.expect(recording.snapshot().failure != null and !recording.snapshot().storage_failed);
    const observation: Observation = .{ .process = .{ .exit_code = 0, .foreground_finished = true } };
    const kept_id = "44444444444444444444444444444444";
    _ = try recording.startExecutionBarrier(owner, kept_id, .session_interval);
    _ = try recording.markBoundary(owner, recording.raw_position);
    _ = try recording.noteExecutionBoundary(owner, kept_id, .start, recording.raw_position, 1, .session_interval);
    recording.appendOutput(owner, "new retained interval", 3);
    _ = try recording.markBoundary(owner, recording.raw_position);
    _ = try recording.noteExecutionBoundary(owner, kept_id, .end, recording.raw_position, 2, .session_interval);
    const kept = try recording.saveInterval(owner, kept_id, observation);
    try std.testing.expect(kept.interval_saved and !kept.sealed);
    try std.testing.expect(kept.coverage == .partial and kept.replayability == .baseline_unavailable);
    const kept_document = try manifest.load(std.testing.allocator, std.testing.io, tmp.dir, recording.manifest_path);
    defer kept_document.deinit();
    const kept_file = try tmp.dir.readFileAlloc(std.testing.io, kept_document.value.files[0].path, std.testing.allocator, .limited(4 * 1024 * 1024));
    defer std.testing.allocator.free(kept_file);
    try std.testing.expect(std.mem.indexOf(u8, kept_file, "new retained interval") != null);
    try std.testing.expect(kept_document.value.execution_ranges[3].interval_saved);

    const evicted_id = "55555555555555555555555555555555";
    _ = try recording.startExecutionBarrier(owner, evicted_id, .session_interval);
    _ = try recording.markBoundary(owner, recording.raw_position);
    _ = try recording.noteExecutionBoundary(owner, evicted_id, .start, recording.raw_position, 1, .session_interval);
    for ([_][]const u8{ "66666666666666666666666666666666", "77777777777777777777777777777777", "88888888888888888888888888888888" }) |id| {
        recording.appendOutput(owner, bytes, 4);
        _ = try recording.startExecutionBarrier(owner, id, .session_interval);
    }
    _ = try recording.markBoundary(owner, recording.raw_position);
    _ = try recording.noteExecutionBoundary(owner, evicted_id, .end, recording.raw_position, 2, .session_interval);
    const evicted = try recording.saveInterval(owner, evicted_id, observation);
    try std.testing.expect(!evicted.interval_saved and !evicted.sealed);

    const gapped_id = "99999999999999999999999999999999";
    _ = try recording.startExecutionBarrier(owner, gapped_id, .session_interval);
    _ = try recording.markBoundary(owner, recording.raw_position);
    _ = try recording.noteExecutionBoundary(owner, gapped_id, .start, recording.raw_position, 1, .session_interval);
    recording.appendOutput(owner, dropped, 5);
    _ = try recording.markBoundary(owner, recording.raw_position);
    _ = try recording.noteExecutionBoundary(owner, gapped_id, .end, recording.raw_position, 2, .session_interval);
    const gapped = try recording.saveInterval(owner, gapped_id, observation);
    try std.testing.expect(!gapped.interval_saved and !gapped.sealed);
}
