//! Runtime-only rotation. Jobs own their playlist and never edit settings or disk.
const std = @import("std");
const asset = @import("background_asset.zig");

pub const Rotation = struct {
    key: u64 = 0,
    deadline_ms: ?u64 = null,
    job: ?*Job = null,

    pub fn identity(background: asset.Background, revision: u64) u64 {
        var hash = std.hash.Wyhash.init(revision);
        hash.update(background.path);
        std.hash.autoHash(&hash, .{ background.enabled, background.source, background.order, background.interval_minutes });
        return hash.final();
    }
    pub fn sync(self: *Rotation, key: u64, now: u64, minutes: u16, active: bool) void {
        if (key != self.key) {
            self.key = key;
            self.deadline_ms = null;
        }
        if (!active) self.deadline_ms = null else if (self.deadline_ms == null) self.reset(now, minutes);
    }
    pub fn reset(self: *Rotation, now: u64, minutes: u16) void {
        self.deadline_ms = now + @as(u64, minutes) * 60_000;
    }
    pub fn due(self: *const Rotation, now: u64) bool {
        return self.job == null and if (self.deadline_ms) |deadline| now >= deadline else false;
    }
    pub fn start(self: *Rotation, allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, current: *const asset.Prepared, random: bool) !void {
        if (self.job != null) return error.AppearanceBusy;
        const path = try allocator.dupe(u8, current.path);
        const job = allocator.create(Job) catch |err| {
            allocator.free(path);
            return err;
        };
        job.* = .{ .allocator = allocator, .io = io, .dir = dir, .key = self.key, .path = path, .draft_id = current.draft_id, .asset_revision = current.asset_revision };
        errdefer job.destroy();
        job.list = try current.playlist.?.clone(allocator);
        job.list.changeOrder(random);
        job.thread = try std.Thread.spawn(.{}, Job.run, .{job});
        self.job = job;
    }
    pub fn ready(self: *const Rotation) bool {
        return if (self.job) |job| job.done.load(.acquire) else false;
    }
    /// Caller destroys this completion, whether current or obsolete.
    pub fn take(self: *Rotation) ?*Job {
        if (!self.ready()) return null;
        const job = self.job.?;
        job.thread.?.join();
        job.thread = null;
        self.job = null;
        return job;
    }
    pub fn deinit(self: *Rotation) void {
        if (self.job) |job| {
            job.thread.?.join();
            job.destroy();
        }
        self.* = .{};
    }
};

pub const Job = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    key: u64,
    path: []u8,
    draft_id: u64,
    asset_revision: u64,
    list: asset.Playlist = .{},
    thread: ?std.Thread = null,
    done: std.atomic.Value(bool) = .init(false),
    result: ?asset.Prepared = null,
    problem: ?anyerror = null,

    fn run(self: *Job) void {
        self.result = asset.prepareNext(self.io, self.dir, self.allocator, self.path, &self.list) catch |err| failed: {
            self.problem = err;
            break :failed null;
        };
        if (self.result) |*result| {
            result.draft_id = self.draft_id;
            result.asset_revision = self.asset_revision;
        }
        self.done.store(true, .release);
    }
    pub fn destroy(self: *Job) void {
        self.allocator.free(self.path);
        self.list.deinit(self.allocator);
        if (self.result) |*value| value.deinit(self.allocator);
        self.allocator.destroy(self);
    }
};
