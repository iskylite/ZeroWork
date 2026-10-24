//! Frozen probe facts for the review step. No worker, session or active tab.
const std = @import("std");
pub const progress = @import("../proto/ssh/connection_progress.zig");
pub const operations = @import("../host/operation.zig");
const ssh = @import("../proto/ssh/session.zig");
const presentation = @import("connection_progress_view.zig");

pub const Hop = struct { name: []const u8, host: []const u8, user: []const u8, port: u16 };
pub const Snapshot = struct {
    protocol: @import("../config/hosts.zig").Protocol = .ssh,
    key: operations.OperationKey,
    generation: u64,
    draft_id: u64,
    draft_revision: u64,
    hops: []const Hop,
    journal: progress.Journal.Snapshot,
    resources: ssh.ResourceLedger.Snapshot,
    finished: bool,
    cancelled: bool,
    failure: ?anyerror,
    cleanup: operations.Cleanup,

    pub fn valid(self: *const Snapshot) bool {
        const attempt = self.key.attempt_id orelse return false;
        if (self.key.owner != .app or self.key.operation_id == 0 or attempt == 0 or self.generation == 0 or self.draft_id == 0 or self.draft_revision == 0) return false;
        if (self.hops.len == 0 or self.hops.len > 9 or self.journal.attempt != attempt or self.journal.count > progress.Journal.capacity) return false;
        if (self.resources.key == null or !self.resources.key.?.eql(self.key) or self.resources.hop_count != self.hops.len) return false;
        if (self.cleanup == .released and !self.resources.released()) return false;
        if (self.finished and self.cleanup != .released) return false;
        if (self.finished and self.failure == null and !self.cancelled and !self.journal.completed) return false;
        for (self.journal.entries[0..self.journal.count]) |entry| if (entry.hop >= self.hops.len or entry.hop_count != self.hops.len) return false;
        if (self.journal.failure) |entry| if (entry.hop >= self.hops.len or entry.hop_count != self.hops.len) return false;
        return true;
    }

    pub fn latest(self: *const Snapshot, hop: usize) ?progress.Journal.Entry {
        var result: ?progress.Journal.Entry = null;
        for (self.journal.entries[0..self.journal.count]) |entry| if (entry.hop == hop) {
            result = entry;
        };
        return result;
    }

    pub fn node(self: *const Snapshot, hop: usize, buffer: []u8) []const u8 {
        const last = self.latest(hop);
        if (last) |entry| if (entry.status == .failed) return std.fmt.bufPrint(buffer, "{s}失败", .{shortPhase(entry.phase)}) catch "失败";
        if (self.cleanup == .unknown) return if (last != null) "释放待核实" else "未尝试";
        if (self.cleanup == .releasing) return if (last != null) "正在释放" else "等待上游";
        if (self.cancelled) return if (last != null) (if (self.cleanup == .released) @as([]const u8, "已取消 · 已释放") else "正在取消") else "未尝试";
        if (self.finished and self.failure == null) return "验证通过 · 已释放";
        if (last) |entry| {
            if (entry.status == .succeeded) return if (entry.phase == .authentication or entry.phase == .ready) (if (self.cleanup == .released) @as([]const u8, "已认证 · 已释放") else "已认证") else std.fmt.bufPrint(buffer, "{s}完成", .{shortPhase(entry.phase)}) catch "完成";
            if (entry.status == .cancelled) return "已取消";
            return std.fmt.bufPrint(buffer, "{s}中", .{presentation.phaseName(entry.phase)}) catch "检测中";
        }
        if (self.cleanup == .released) return "未尝试";
        return if (hop == 0) "等待检测" else "等待上游";
    }

    pub fn summary(self: *const Snapshot, buffer: []u8) []const u8 {
        if (self.cleanup == .unknown) return "测试资源释放待核实 · 暂不可重新测试";
        if (self.cleanup == .releasing) return "正在释放本次测试资源";
        if (self.cancelled) return if (self.cleanup == .released) "测试已取消 · 测试资源已释放" else "正在取消测试";
        if (self.failure) |failure| {
            if (self.protocol == .sftp and failure == error.SftpSubsystemDenied) return if (self.cleanup == .released) "SSH 认证通过 · SFTP 子系统拒绝 · 已释放" else "SSH 认证通过 · SFTP 子系统拒绝";
            const failed = self.journal.failure;
            return if (failed) |entry| std.fmt.bufPrint(buffer, "{s} {s}失败 · {s}{s}", .{ self.hops[entry.hop].name, shortPhase(entry.phase), presentation.failureText(failure), if (self.cleanup == .released) @as([]const u8, " · 已释放") else "" }) catch "验证失败" else std.fmt.bufPrint(buffer, "{s}{s}", .{ presentation.failureText(failure), if (self.cleanup == .released) @as([]const u8, " · 已释放") else "" }) catch "验证失败";
        }
        if (self.finished and self.cleanup == .released) return if (self.protocol == .sftp) "SFTP 可用 · 目录只读验证通过 · 已释放" else "验证通过 · 测试资源已释放";
        if (self.protocol == .sftp and self.journal.completed) return "SSH 已认证 · 正在验证 SFTP 目录";
        if (self.journal.count != 0) {
            const entry = self.journal.entries[self.journal.count - 1];
            return std.fmt.bufPrint(buffer, "第{d}跳 {s}{s}{s}", .{ entry.hop + 1, presentation.phaseName(entry.phase), if (entry.status == .started) @as([]const u8, "中") else "完成", if (entry.hop + 1 < self.hops.len) @as([]const u8, " · 后续等待上游") else "" }) catch "正在测试连接";
        }
        return "正在测试连接";
    }
};

pub const Owned = struct {
    arena: std.heap.ArenaAllocator,
    value: Snapshot,
    pub fn init(allocator: std.mem.Allocator, source: Snapshot) !Owned {
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const owned = arena.allocator();
        var value = source;
        const hops = try owned.alloc(Hop, source.hops.len);
        for (source.hops, hops) |hop, *copy| copy.* = .{ .name = try owned.dupe(u8, hop.name), .host = try owned.dupe(u8, hop.host), .user = try owned.dupe(u8, hop.user), .port = hop.port };
        value.hops = hops;
        return .{ .arena = arena, .value = value };
    }
    pub fn deinit(self: *Owned) void {
        self.arena.deinit();
    }
};

pub const Record = struct { key: operations.OperationKey, entry: progress.Journal.Entry, origin_ns: i128 };
pub const History = struct {
    records: [progress.Journal.capacity]Record = undefined,
    count: usize = 0,
    dropped: usize = 0,
    last_key: ?operations.OperationKey = null,
    last_sequence: ?u64 = null,
    origin_ns: i128 = 0,

    pub fn ingest(self: *History, source: *const Snapshot) usize {
        if (self.last_key == null or !self.last_key.?.eql(source.key)) {
            self.last_key = source.key;
            self.last_sequence = null;
            self.origin_ns = if (source.journal.count != 0) source.journal.entries[0].timestamp_ns else 0;
        }
        var appended: usize = 0;
        for (source.journal.entries[0..source.journal.count]) |entry| {
            if (self.last_sequence) |sequence| if (entry.sequence <= sequence) continue;
            const expected = if (self.last_sequence) |sequence| sequence +| 1 else 0;
            if (entry.sequence > expected) self.dropped += @intCast(entry.sequence - expected);
            if (self.count == self.records.len) {
                std.mem.copyForwards(Record, self.records[0 .. self.count - 1], self.records[1..self.count]);
                self.count -= 1;
                self.dropped += 1;
            }
            if (self.last_sequence == null and self.origin_ns == 0) self.origin_ns = entry.timestamp_ns;
            self.records[self.count] = .{ .key = source.key, .entry = entry, .origin_ns = self.origin_ns };
            self.count += 1;
            self.last_sequence = entry.sequence;
            appended += 1;
        }
        return appended;
    }
};

pub fn shortPhase(phase: progress.Phase) []const u8 {
    return switch (phase) {
        .transport => "TCP",
        .tunnel => "隧道",
        .handshake => "握手",
        .host_key => "主机密钥",
        .authentication => "认证",
        .shell => "终端",
        .ready => "就绪",
    };
}
pub fn eventResult(entry: progress.Journal.Entry) []const u8 {
    return switch (entry.status) {
        .started => "进行中",
        .succeeded => "完成",
        .cancelled => "已取消",
        .failed => presentation.failureText(entry.failure),
    };
}
