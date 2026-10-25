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
};
const Segment = struct { bytes: []u8, timestamp_ms: i64, geometry: ?struct { cols: u16, rows: u16 } = null, theme: ?@import("../vt/engine.zig").Theme = null };

pub const Recording = struct {
    allocator: std.mem.Allocator,
    owner: identity.SessionHandle,
    io: std.Io,
    dir: std.Io.Dir,
    started_ms: i64,
    timeline: Timeline,
    checkpoint: Checkpoint,
    terminal: c.GhosttyTerminal,
    checkpoint_valid: bool = true,
    raw_path: []u8,
    checkpoint_path: []u8,
    cast_path: []u8,
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
    checkpoint_count: u64 = 0,
    failure: ?[]const u8 = null,
    stop: bool = false,
    closed: bool = false,
    archived: bool = false,
    writer: ?std.Thread = null,
    wakeup: @import("../platform/wakeup.zig").Wakeup,

    pub fn init(allocator: std.mem.Allocator, owner: identity.SessionHandle, options: Options, cols: u16, rows: u16, now_ms: i64) !*Recording {
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
        var timeline = try Timeline.init(allocator, 65536, capacity);
        errdefer timeline.deinit();
        var checkpoint = try Checkpoint.init(allocator, capacity, options.log.checkpoint_sec, now_ms, options.io, dir, checkpoint_path);
        errdefer checkpoint.deinit();
        try checkpoint.enableRawFile(raw_path);
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
            .timeline = timeline,
            .checkpoint = checkpoint,
            .terminal = terminal,
            .raw_path = raw_path,
            .checkpoint_path = checkpoint_path,
            .cast_path = cast_path,
            .checkpoint_sec = options.log.checkpoint_sec,
            .initial_cols = cols,
            .initial_rows = rows,
            .cols = cols,
            .rows = rows,
            .retention_days = .init(options.log.retention_days),
            .queue_capacity = @min(capacity, 1024 * 1024),
        };
        self.writer = try std.Thread.spawn(.{}, writeLoop, .{self});
        return self;
    }

    pub fn deinit(self: *Recording) void {
        self.stopWriter();
        self.wakeup.deinit();
        for (self.queue.items) |segment| self.allocator.free(segment.bytes);
        self.queue.deinit(self.allocator);
        c.ghostty_terminal_free(self.terminal);
        self.checkpoint.deinit();
        self.timeline.deinit();
        self.dir.close(self.io);
        self.allocator.free(self.raw_path);
        self.allocator.free(self.checkpoint_path);
        self.allocator.free(self.cast_path);
        self.allocator.destroy(self);
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
        if (self.failure != null) return;
        self.failure = @errorName(err);
        @import("../platform/presentation_wakeup.zig").notify();
    }

    /// Called only at the original PTY / VT worker boundary. Output offsets
    /// count received bytes, never input mailbox submissions or painted frames.
    pub fn appendOutput(self: *Recording, owner: identity.SessionHandle, bytes: []const u8, now_ms: i64) void {
        if (!self.owner.eql(owner)) return;
        self.timeline.append(now_ms, self.output_bytes, bytes) catch |err| self.fail(err);
        self.lock();
        defer self.mutex.unlock();
        self.output_bytes +|= bytes.len;
        if (self.closed or self.stop or bytes.len > self.queue_capacity -| self.queued_bytes) {
            self.checkpoint_valid = false;
            self.dropped_bytes +|= bytes.len;
            self.failLocked(error.RecordingQueueFull);
            return;
        }
        const owned = self.allocator.dupe(u8, bytes) catch {
            self.checkpoint_valid = false;
            self.dropped_bytes +|= bytes.len;
            self.failLocked(error.OutOfMemory);
            return;
        };
        self.queue.append(self.allocator, .{ .bytes = owned, .timestamp_ms = now_ms }) catch {
            self.allocator.free(owned);
            self.checkpoint_valid = false;
            self.dropped_bytes +|= bytes.len;
            self.failLocked(error.OutOfMemory);
            return;
        };
        self.queued_bytes += bytes.len;
        self.wakeup.notify();
    }

    pub fn appendApplication(self: *Recording, record: @import("../host/terminal_service.zig").ApplicationRecord) !void {
        if (!self.owner.eql(record.owner)) return error.StaleOwner;
        self.lock();
        const offset = self.output_bytes;
        const stopped = self.stop or self.closed;
        self.mutex.unlock();
        if (stopped) return error.RecordingClosed;
        try self.timeline.appendApplicationAt(record, offset, @intCast(@import("native.zig").zw_local_monotonic_ms()));
    }
    pub fn resizeApplied(self: *Recording, owner: identity.SessionHandle, cols: u16, rows: u16, now_ms: i64) void {
        if (!self.owner.eql(owner)) return;
        defer self.wakeup.notify();
        self.cols = cols;
        self.rows = rows;
        self.timeline.appendResize(now_ms, self.output_bytes, cols, rows) catch |err| self.fail(err);
        self.lock();
        defer self.mutex.unlock();
        if (self.stop or self.queue.items.len >= 65536) {
            self.checkpoint_valid = false;
            self.failLocked(error.RecordingQueueFull);
            return;
        }
        const bytes = self.allocator.alloc(u8, 0) catch unreachable;
        self.queue.append(self.allocator, .{ .bytes = bytes, .timestamp_ms = now_ms, .geometry = .{ .cols = cols, .rows = rows } }) catch {
            self.allocator.free(bytes);
            self.checkpoint_valid = false;
            self.failLocked(error.OutOfMemory);
        };
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
        self.timeline.saveCast(self.io, self.dir, self.cast_path, self.initial_cols, self.initial_rows) catch |err| {
            self.fail(err);
            return;
        };
        var archive: archive_mod.Archive = .{ .allocator = self.allocator, .io = self.io, .dir = self.dir };
        archive.append(.{
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
            self.dir.deleteFile(self.io, self.cast_path) catch {};
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
                if (value.theme) |theme| {
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
    recording.stopWriter();
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
