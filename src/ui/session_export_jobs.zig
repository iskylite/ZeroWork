//! Export workers own frozen data/recording leases and paths, never widgets or
//! session registries. Completion is consumed on the owning window's thread.
const std = @import("std");
const ui = @import("ui");
const Export = @import("session_export.zig");
const Timeline = @import("../vt/timeline.zig").Timeline;
const RecordLease = @import("../vt/session_archive.zig").RecordLease;
const wake = @import("../platform/presentation_wakeup.zig");

/// A small immutable export request. Actual catalogue/manifest/checksum reads
/// happen in Job.execute after the native destination dialog has returned.
pub const ArchiveRecord = struct {
    allocator: std.mem.Allocator,
    archive: @import("../vt/session_archive.zig").Archive,
    key: []u8,
    revision: u64,
    pub fn capture(allocator: std.mem.Allocator, archive: @import("../vt/session_archive.zig").Archive, key: []const u8, revision: u64) !ArchiveRecord {
        const copy = try allocator.dupe(u8, key);
        errdefer allocator.free(copy);
        const directory = try archive.dir.openDir(archive.io, ".", .{});
        var owned = archive;
        owned.allocator = allocator;
        owned.dir = directory;
        return .{ .allocator = allocator, .archive = owned, .key = copy, .revision = revision };
    }
    pub fn deinit(self: *ArchiveRecord) void {
        self.archive.dir.close(self.archive.io);
        self.allocator.free(self.key);
    }
};

pub const Source = union(enum) {
    live: Timeline.ExportLease,
    frozen: Timeline.ExportSnapshot,
    archive: RecordLease,
    archive_group: @import("../vt/session_archive.zig").RecordGroupLease,
    archive_record: ArchiveRecord,
    none,
    pub fn deinit(self: *Source) void {
        switch (self.*) {
            .live => |lease| lease.release(lease.context),
            .frozen => |*frozen| frozen.timeline.deinit(),
            .archive => |*lease| lease.deinit(),
            .archive_group => |*lease| lease.deinit(),
            .archive_record => |*record| record.deinit(),
            .none => {},
        }
        self.* = .none;
    }
};

pub const Job = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    source: Source,
    format: Export.Format,
    path: []u8,
    thread: ?std.Thread = null,
    done: std.atomic.Value(bool) = .init(false),
    cancel: std.atomic.Value(bool) = .init(false),
    failure: ?anyerror = null,

    /// Always consumes source, including on allocation/spawn failure.
    pub fn start(allocator: std.mem.Allocator, io: std.Io, source: Source, format: Export.Format, path: []const u8) !*Job {
        var owned = source;
        errdefer owned.deinit();
        const copy = try allocator.dupe(u8, path);
        errdefer allocator.free(copy);
        const self = try allocator.create(Job);
        errdefer allocator.destroy(self);
        self.* = .{ .allocator = allocator, .io = io, .source = owned, .format = format, .path = copy };
        self.thread = try std.Thread.spawn(.{}, run, .{self});
        return self;
    }
    pub fn deinit(self: *Job) void {
        if (self.thread) |thread| thread.join();
        self.source.deinit();
        self.allocator.free(self.path);
        self.allocator.destroy(self);
    }
    fn run(self: *Job) void {
        self.execute() catch |err| {
            self.failure = err;
        };
        self.source.deinit();
        self.done.store(true, .release);
        wake.notify();
    }
    fn execute(self: *Job) !void {
        if (self.cancel.load(.acquire)) return error.Cancelled;
        switch (self.source) {
            .live => |lease| {
                var frozen = try lease.capture(lease.context, self.allocator);
                defer frozen.deinit();
                self.source.deinit();
                try self.writeTimeline(&frozen, lease.cols, lease.rows);
            },
            .frozen => |*frozen| try self.writeTimeline(&frozen.timeline, frozen.cols, frozen.rows),
            .archive => |*lease| try self.writeArchive(lease),
            .archive_group => |*lease| try self.writeArchive(lease.cast()),
            .archive_record => |*request| {
                var record = try request.archive.resolveRecord(self.allocator, .{ .archive_key = request.key });
                defer record.deinit();
                if (record.descriptor.manifest_revision != request.revision) return error.StaleArchiveRevision;
                if (record.descriptor.replayability == .baseline_unavailable and self.format != .cast) return error.RecordingBaselineUnavailable;
                if (self.cancel.load(.acquire)) return error.Cancelled;
                var lease = try request.archive.acquireRecordForExport(self.allocator, record.descriptor);
                defer lease.deinit();
                try self.writeArchive(lease.cast());
            },
            .none => return error.RecordingUnavailable,
        }
    }
    fn writeArchive(self: *Job, lease: *const RecordLease) !void {
        const bytes = try lease.readAll(self.allocator, 128 * 1024 * 1024);
        defer self.allocator.free(bytes);
        const Sink = struct {
            job: *Job,
            bytes: []const u8,
            pub fn validate(s: @This()) !void {
                if (s.job.cancel.load(.acquire)) return error.Cancelled;
            }
            pub fn write(s: @This(), kind: Export.Kind, path: []const u8) !void {
                try Export.writeArchive(s.job.allocator, s.job.io, .cwd(), kind, path, s.bytes);
            }
        };
        _ = try Export.run(self.allocator, self.format, self.path, Sink{ .job = self, .bytes = bytes });
    }
    fn writeTimeline(self: *Job, timeline: *const Timeline, cols: u16, rows: u16) !void {
        const Sink = struct {
            job: *Job,
            timeline: *const Timeline,
            cols: u16,
            rows: u16,
            pub fn validate(s: @This()) !void {
                if (s.job.cancel.load(.acquire)) return error.Cancelled;
            }
            pub fn write(s: @This(), kind: Export.Kind, path: []const u8) !void {
                var atomic = try std.Io.Dir.cwd().createFileAtomic(s.job.io, path, .{ .permissions = @fromBackingInt(0o600), .make_path = true, .replace = true });
                defer atomic.deinit(s.job.io);
                var buffer: [16 * 1024]u8 = undefined;
                var writer = atomic.file.writer(s.job.io, &buffer);
                switch (kind) {
                    .txt => try s.timeline.exportTextUnlocked(&writer.interface),
                    .cast => try s.timeline.exportCastUnlocked(&writer.interface, s.cols, s.rows),
                }
                try writer.flush();
                try s.validate();
                try atomic.replace(s.job.io);
            }
        };
        _ = try Export.run(self.allocator, self.format, self.path, Sink{ .job = self, .timeline = timeline, .cols = cols, .rows = rows });
    }
};

var managers: [16]?*Manager = @splat(null);
pub const Manager = struct {
    cx: *ui.Cx,
    job: ?*Job = null,
    completed: u64 = 0,
    last_failure: ?anyerror = null,
    notice: struct { context: *anyopaque, publish: *const fn (*anyopaque, []const u8) void },
    pub fn mount(cx: *ui.Cx, scope: *ui.Scope, notice: @FieldType(Manager, "notice")) !*Manager {
        const self = try cx.allocator.create(Manager);
        errdefer cx.allocator.destroy(self);
        self.* = .{ .cx = cx, .notice = notice };
        const slot = for (&managers) |*entry| {
            if (entry.* == null) break entry;
        } else return error.TooManyWindows;
        try cx.addAfterLayoutHook(self, poll);
        errdefer cx.removeAfterLayoutHook(self);
        try scope.onCleanup(Manager, self, cleanup);
        slot.* = self;
        return self;
    }
    pub fn forCx(cx: *ui.Cx) ?*Manager {
        for (managers) |entry| if (entry) |manager| {
            if (manager.cx == cx) return manager;
        };
        return null;
    }
    /// Always consumes source. One export/window bounds memory and prevents
    /// duplicate writers racing to replace the same destination.
    pub fn start(self: *Manager, source: Source, format: Export.Format, path: []const u8) !void {
        if (self.job != null) {
            var rejected = source;
            rejected.deinit();
            return error.ExportInProgress;
        }
        self.last_failure = null;
        self.job = try Job.start(std.heap.c_allocator, self.cx.io, source, format, path);
        self.notice.publish(self.notice.context, "正在导出会话日志…");
    }
    fn poll(raw: *anyopaque, _: u8, _: bool) ui.AfterLayoutResult {
        const self: *Manager = @ptrCast(@alignCast(raw));
        if (self.job) |job| {
            if (job.done.load(.acquire)) {
                self.last_failure = job.failure;
                self.completed += 1;
                self.job = null;
                job.deinit();
                self.notice.publish(self.notice.context, if (self.last_failure) |err| @errorName(err) else "已导出会话日志");
            } else self.cx.scheduleRedrawAfterNs(33 * std.time.ns_per_ms);
        }
        return .done;
    }
    fn cleanup(self: *Manager) void {
        self.cx.removeAfterLayoutHook(self);
        for (&managers) |*entry| if (entry.* == self) {
            entry.* = null;
        };
        if (self.job) |job| {
            job.cancel.store(true, .release);
            job.deinit();
        }
        self.cx.allocator.destroy(self);
    }
};

test "export worker captures and writes paired logs after returning to the caller" {
    const Fixture = struct {
        ready: std.atomic.Value(bool) = .init(false),
        entered: std.atomic.Value(bool) = .init(false),
        released: std.atomic.Value(usize) = .init(0),
        fn capture(raw: *anyopaque, allocator: std.mem.Allocator) !Timeline {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.entered.store(true, .release);
            while (!self.ready.load(.acquire)) std.atomic.spinLoopHint();
            var timeline = try Timeline.init(allocator, 8, 1024);
            errdefer timeline.deinit();
            try timeline.append(100, 0, "背景导出\n");
            return timeline;
        }
        fn release(raw: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            _ = self.released.fetchAdd(1, .acq_rel);
        }
    };
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const directory = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    defer a.free(directory);
    const path = try std.fs.path.join(a, &.{ directory, "snapshot" });
    defer a.free(path);
    var fixture: Fixture = .{};
    const job = try Job.start(a, std.testing.io, .{ .live = .{ .context = &fixture, .capture = Fixture.capture, .release = Fixture.release, .cols = 80, .rows = 24 } }, .txt_cast, path);
    defer job.deinit();
    // The expensive capture has not been allowed to proceed; start still
    // returned, so callers can continue handling input and window events.
    try std.testing.expect(!job.done.load(.acquire));
    fixture.ready.store(true, .release);
    if (job.thread) |thread| thread.join();
    job.thread = null;
    try std.testing.expect(job.done.load(.acquire));
    try std.testing.expect(job.failure == null);
    try std.testing.expectEqual(@as(usize, 1), fixture.released.load(.acquire));
    const cast = try tmp.dir.readFileAlloc(std.testing.io, "snapshot.cast", a, .limited(4096));
    defer a.free(cast);
    try std.testing.expect(std.mem.indexOf(u8, cast, "背景导出") != null);
    const text = try tmp.dir.readFileAlloc(std.testing.io, "snapshot.txt", a, .limited(4096));
    defer a.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "offset=0") != null);
}

test "export worker reports write failures and consumes its owned snapshot" {
    const a = std.testing.allocator;
    var timeline = try Timeline.init(a, 8, 1024);
    try timeline.append(100, 0, "log");
    const job = try Job.start(a, std.testing.io, .{ .frozen = .{ .timeline = timeline, .cols = 80, .rows = 24 } }, .txt, "");
    defer job.deinit();
    if (job.thread) |thread| thread.join();
    job.thread = null;
    try std.testing.expectEqual(error.EmptyPath, job.failure.?);
    try std.testing.expect(job.source == .none);
}

test "history archive export resolves and reads the immutable recording on its worker" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "logs/history");
    const bytes = "{\"version\":2,\"width\":12,\"height\":2}\n[0,\"o\",\"真实保留内容\\r\\n\"]\n";
    const file = try tmp.dir.createFile(std.testing.io, "logs/history/retained.cast", .{});
    try file.writeStreamingAll(std.testing.io, bytes);
    file.close(std.testing.io);
    var archive: @import("../vt/session_archive.zig").Archive = .{ .allocator = a, .io = std.testing.io, .dir = tmp.dir };
    try archive.append(.{ .id = 1, .started_ms = 1, .ended_ms = 2, .duration_ms = 1, .host = "closed", .user = "u", .cast_path = "logs/history/retained.cast", .source_kind = .local });
    var catalog = try archive.loadCatalog(a);
    defer catalog.deinit();
    const descriptor = catalog.entries.items[0];
    const source = try ArchiveRecord.capture(a, archive, descriptor.archive_key, descriptor.manifest_revision);
    const directory = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    defer a.free(directory);
    const path = try std.fs.path.join(a, &.{ directory, "result.cast" });
    defer a.free(path);
    const job = try Job.start(a, std.testing.io, .{ .archive_record = source }, .cast, path);
    defer job.deinit();
    job.thread.?.join();
    job.thread = null;
    try std.testing.expect(job.done.load(.acquire));
    try std.testing.expect(job.failure == null);
    try std.testing.expect(job.source == .none);
    const result = try tmp.dir.readFileAlloc(std.testing.io, "result.cast", a, .limited(4096));
    defer a.free(result);
    try std.testing.expectEqualStrings(bytes, result);
}
