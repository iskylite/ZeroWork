//! Background archive loading. The document owns the immutable catalogue fact,
//! decoded original renderer data and the entire recording group read lease.
const std = @import("std");
const Archive = @import("../vt/session_archive.zig");
const Timeline = @import("history_replay.zig").Timeline;
const wake = @import("../platform/presentation_wakeup.zig");
pub const decoded_budget = 256 * 1024 * 1024;
var decoded_bytes: std.atomic.Value(usize) = .init(0);
var active_decodes: std.atomic.Value(usize) = .init(0);
pub const decode_concurrency = 2;
pub const Document = struct {
    allocator: std.mem.Allocator,
    version: u32 = 1,
    record: Archive.ResolvedRecord,
    lease: Archive.RecordGroupLease,
    timeline: Timeline,
    accounted_bytes: usize = 0,
    reading: ?@import("history_reading.zig").Model = null,
    pub fn deinit(self: *Document) void {
        self.timeline.deinit();
        if (self.reading) |*reading| reading.deinit();
        self.lease.deinit();
        self.record.deinit();
        if (self.accounted_bytes > 0) _ = decoded_bytes.fetchSub(self.accounted_bytes, .acq_rel);
    }
    pub fn destroy(self: *Document) void {
        const allocator = self.allocator;
        self.deinit();
        allocator.destroy(self);
    }
};
pub const Job = struct {
    allocator: std.mem.Allocator,
    archive: Archive.Archive,
    key: []u8,
    revision: u64,
    generation: u64,
    thread: ?std.Thread = null,
    done: std.atomic.Value(bool) = .init(false),
    cancel: std.atomic.Value(bool) = .init(false),
    failure: ?anyerror = null,
    document: ?*Document = null,
    pub fn start(archive: Archive.Archive, key: []const u8, revision: u64, generation: u64) !*Job {
        const allocator = std.heap.c_allocator;
        const self = try allocator.create(Job);
        errdefer allocator.destroy(self);
        const copy = try allocator.dupe(u8, key);
        errdefer allocator.free(copy);
        self.* = .{ .allocator = allocator, .archive = archive, .key = copy, .revision = revision, .generation = generation };
        self.archive.allocator = allocator;
        self.thread = try std.Thread.spawn(.{}, run, .{self});
        return self;
    }
    pub fn deinit(self: *Job) void {
        self.cancel.store(true, .release);
        if (self.thread) |thread| thread.join();
        if (self.document) |document| document.destroy();
        self.allocator.free(self.key);
        self.allocator.destroy(self);
    }
    fn run(self: *Job) void {
        self.execute() catch |err| {
            self.failure = err;
        };
        self.done.store(true, .release);
        wake.notify();
    }
    fn execute(self: *Job) !void {
        const active = active_decodes.fetchAdd(1, .acq_rel);
        defer _ = active_decodes.fetchSub(1, .acq_rel);
        if (active >= decode_concurrency) return error.HistoryLoadBusy;
        if (self.cancel.load(.acquire)) return error.Cancelled;
        var record = self.archive.resolveRecord(self.allocator, .{ .archive_key = self.key }) catch |err| return if (err == error.StreamTooLong) error.HistoryIndexTooLarge else err;
        errdefer record.deinit();
        if (record.descriptor.manifest_revision != self.revision) return error.StaleArchiveRevision;
        if (!record.descriptor.can_open) return error.RecordingUnavailable;
        var lease = try self.archive.acquireRecord(self.allocator, record.descriptor);
        errdefer lease.deinit();
        const cast = try lease.cast().readAll(self.allocator, 128 * 1024 * 1024);
        defer self.allocator.free(cast);
        if (self.cancel.load(.acquire)) return error.Cancelled;
        var timeline = try @import("history_cast.zig").loadCancelable(self.allocator, cast, &self.cancel);
        errdefer timeline.deinit();
        if (self.cancel.load(.acquire)) return error.Cancelled;
        var reading = try @import("history_reading.zig").Model.init(self.allocator, &timeline);
        errdefer reading.deinit();
        const document_bytes = timeline.bytes + reading.storageBytes();
        const previous = decoded_bytes.fetchAdd(document_bytes, .acq_rel);
        if (document_bytes > decoded_budget -| previous) {
            _ = decoded_bytes.fetchSub(document_bytes, .acq_rel);
            return error.HistoryDecodedBudgetExceeded;
        }
        errdefer _ = decoded_bytes.fetchSub(document_bytes, .acq_rel);
        const document = try self.allocator.create(Document);
        document.* = .{ .allocator = self.allocator, .record = record, .lease = lease, .timeline = timeline, .accounted_bytes = document_bytes, .reading = reading };
        self.document = document;
    }
};
pub const CatalogJob = struct {
    archive: Archive.Archive,
    generation: u64,
    thread: ?std.Thread = null,
    done: std.atomic.Value(bool) = .init(false),
    cancel: std.atomic.Value(bool) = .init(false),
    failure: ?anyerror = null,
    catalog: ?Archive.Catalog = null,
    pub fn start(archive: Archive.Archive, generation: u64) !*CatalogJob {
        const self = try std.heap.c_allocator.create(CatalogJob);
        errdefer std.heap.c_allocator.destroy(self);
        self.* = .{ .archive = archive, .generation = generation };
        self.archive.allocator = std.heap.c_allocator;
        self.thread = try std.Thread.spawn(.{}, run, .{self});
        return self;
    }
    fn run(self: *CatalogJob) void {
        if (!self.cancel.load(.acquire)) self.catalog = self.archive.loadCatalog(std.heap.c_allocator) catch |err| blk: {
            self.failure = if (err == error.StreamTooLong) error.HistoryIndexTooLarge else err;
            break :blk null;
        };
        self.done.store(true, .release);
        wake.notify();
    }
    pub fn deinit(self: *CatalogJob) void {
        self.cancel.store(true, .release);
        if (self.thread) |thread| thread.join();
        if (self.catalog) |*catalog| catalog.deinit();
        std.heap.c_allocator.destroy(self);
    }
};
pub fn errorText(err: anyerror) []const u8 {
    return switch (err) {
        error.Cancelled => "已取消加载",
        error.HistoryLoadBusy => "正在加载其他历史记录，请稍后重试",
        error.FileNotFound, error.RecordNotFound => "历史录制文件不存在",
        error.RecordRemoved => "该历史记录已被清除",
        error.StaleArchiveRevision => "历史记录已变化，请重新读取后再打开",
        error.RecordingBaselineUnavailable => "记录起始状态已淘汰，无法准确回放；仍可导出保留内容",
        error.UnsupportedRecordingBaseline => "记录起始状态版本不受支持",
        error.RecordingUnavailable => "该会话的录制内容不可用",
        error.HistoryRecordingTooLarge, error.RecordingTooLarge, error.StreamTooLong => "历史记录超过 128 MiB 读取或解码上限",
        error.HistoryIndexTooLarge => "历史索引超过 16 MiB 上限，无法读取",
        error.RecordingChanged, error.CatalogChanged => "历史记录在读取期间发生变化，请重新读取",
        error.RecordingChecksumMismatch, error.RecordingTruncated => "历史记录不完整或校验失败，无法回看",
        error.HistoryDecodedBudgetExceeded => "已打开记录达到 256 MiB 预算，请先关闭一条历史记录",
        error.EmptyRecording => "录制内容为空，没有可回看的真实帧",
        error.InvalidCast, error.InvalidFrame, error.SyntaxError, error.UnexpectedToken, error.InvalidCharacter, error.MissingField => "录制内容损坏，无法回看",
        error.CatalogLimit => "历史目录元信息超过 16 MiB 或 16384 条上限",
        else => @errorName(err),
    };
}

test "history asynchronous load holds the recording lease through document teardown" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "logs/history");
    const bytes = "{\"version\":2,\"width\":12,\"height\":2}\n[0,\"o\",\"真实内容\\r\\n\"]\n";
    const file = try tmp.dir.createFile(std.testing.io, "logs/history/async.cast", .{});
    try file.writeStreamingAll(std.testing.io, bytes);
    file.close(std.testing.io);
    var archive: Archive.Archive = .{ .allocator = a, .io = std.testing.io, .dir = tmp.dir };
    try archive.append(.{ .id = 1, .started_ms = 1, .ended_ms = 2, .duration_ms = 1, .host = "closed", .user = "u", .cast_path = "logs/history/async.cast", .source_kind = .local });
    var entries = try archive.loadCatalog(a);
    defer entries.deinit();
    const descriptor = entries.entries.items[0];
    const job = try Job.start(archive, descriptor.archive_key, descriptor.manifest_revision, 7);
    defer job.deinit();
    job.thread.?.join();
    job.thread = null;
    try std.testing.expect(job.done.load(.acquire));
    try std.testing.expect(job.failure == null);
    const document = job.document orelse return error.MissingDocument;
    try std.testing.expect(document.timeline.frames.items.len > 0 and document.reading != null);
    try std.testing.expect(try Archive.isReferenced(archive.io, archive.dir, descriptor.entry.cast_path));
    document.destroy();
    job.document = null;
    try std.testing.expect(!try Archive.isReferenced(archive.io, archive.dir, descriptor.entry.cast_path));
}
