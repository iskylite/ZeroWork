const std = @import("std");
const Tap = @import("raw_stream_tap.zig").Tap;
const Scheduler = @import("checkpoint_scheduler.zig").Scheduler;

/// Owns periodic checkpoint policy for one raw stream.
pub const Controller = struct {
    tap: Tap,
    scheduler: Scheduler,
    io: std.Io,
    dir: std.Io.Dir,
    checkpoint_path: []const u8,
    raw_file: ?std.Io.File = null,
    raw_failure: ?anyerror = null,

    pub fn init(allocator: std.mem.Allocator, capacity: usize, interval_sec: u16, now_ms: i64, io: std.Io, dir: std.Io.Dir, checkpoint_path: []const u8) !Controller {
        try validatePath(checkpoint_path);
        const scheduler = try Scheduler.init(interval_sec, now_ms);
        return .{
            .tap = try Tap.init(allocator, capacity),
            .scheduler = scheduler,
            .io = io,
            .dir = dir,
            .checkpoint_path = checkpoint_path,
        };
    }

    pub fn deinit(self: *Controller) void {
        if (self.raw_file) |file| {
            file.sync(self.io) catch {};
            file.close(self.io);
        }
        self.tap.deinit();
        self.* = undefined;
    }

    /// Records bytes and persists at most one checkpoint per interval.
    pub fn append(self: *Controller, bytes: []const u8, timestamp_ms: i64) !bool {
        try self.appendRaw(bytes);
        if (!self.scheduler.due(timestamp_ms)) return false;
        self.tap.markCheckpoint(timestamp_ms);
        try self.tap.saveCheckpoint(self.io, self.dir, self.checkpoint_path);
        if (self.raw_file) |file| try file.sync(self.io);
        self.scheduler.checkpointed(timestamp_ms);
        return true;
    }
    /// Raw persistence without the legacy metadata-only checkpoint. Complete VT
    /// snapshots are encoded separately by Local's recording writer.
    pub fn appendRaw(self: *Controller, bytes: []const u8) !void {
        // A failed write may have partially overwritten the disk ring. Keep
        // that failure sticky: a later successful append must not commit a
        // header or checkpoint that presents the missing segment as history.
        if (self.raw_failure) |err| return err;
        const before = self.tap;
        const start = self.tap.sequence;
        self.tap.append(bytes);
        if (self.raw_file) |file| self.writeRing(file, start, bytes) catch |err| {
            self.tap = before;
            self.raw_failure = err;
            return err;
        };
    }

    /// Bounded on-disk ring. The 32-byte header records committed chronology;
    /// no credentials or user input are recorded, only received PTY bytes.
    pub fn enableRawFile(self: *Controller, path: []const u8) !void {
        try validatePath(path);
        if (self.raw_file != null) return error.AlreadyRecording;
        if (std.fs.path.dirname(path)) |parent| try self.dir.createDirPath(self.io, parent);
        const file = try self.dir.createFile(self.io, path, .{
            .permissions = @as(std.Io.File.Permissions, @fromBackingInt(0o600)),
            .exclusive = true,
        });
        errdefer file.close(self.io);
        try self.writeHeader(file);
        if (self.tap.len > 0) {
            const retained = try self.tap.allocator.alloc(u8, self.tap.len);
            defer self.tap.allocator.free(retained);
            _ = try self.tap.snapshot(retained);
            try self.writeRing(file, self.tap.sequence - self.tap.len, retained);
        }
        self.raw_file = file;
        self.tap.useDiskStorage();
    }

    fn writeHeader(self: *Controller, file: std.Io.File) !void {
        var header: [32]u8 = undefined;
        @memcpy(header[0..8], "ZWRAW001");
        std.mem.writeInt(u64, header[8..16], self.tap.capacity(), .little);
        std.mem.writeInt(u64, header[16..24], self.tap.sequence, .little);
        std.mem.writeInt(u64, header[24..32], self.tap.len, .little);
        try file.writePositionalAll(self.io, &header, 0);
    }

    fn writeRing(self: *Controller, file: std.Io.File, start: u64, bytes: []const u8) !void {
        const capacity = self.tap.capacity();
        const skipped = bytes.len - @min(bytes.len, capacity);
        const retained = bytes[skipped..];
        const position: usize = @intCast((start + skipped) % capacity);
        const first = @min(capacity - position, retained.len);
        try file.writePositionalAll(self.io, retained[0..first], 32 + position);
        if (first < retained.len) try file.writePositionalAll(self.io, retained[first..], 32);
        try self.writeHeader(file);
    }

    /// Returns the retained stream in chronological order after tab close.
    pub fn loadRaw(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, path: []const u8, max_bytes: usize) ![]u8 {
        const stored = try dir.readFileAlloc(io, path, allocator, .limited(max_bytes + 33));
        defer allocator.free(stored);
        if (stored.len < 32 or !std.mem.eql(u8, stored[0..8], "ZWRAW001")) return error.InvalidRawStream;
        const capacity = std.mem.readInt(u64, stored[8..16], .little);
        const sequence = std.mem.readInt(u64, stored[16..24], .little);
        const length = std.mem.readInt(u64, stored[24..32], .little);
        if (capacity == 0 or capacity > max_bytes or length > capacity or length > sequence or stored.len != 32 + @min(sequence, capacity)) return error.InvalidRawStream;
        const output = try allocator.alloc(u8, @intCast(length));
        const position: usize = @intCast((sequence - length) % capacity);
        const first = @min(output.len, @as(usize, @intCast(capacity)) - position);
        @memcpy(output[0..first], stored[32 + position ..][0..first]);
        @memcpy(output[first..], stored[32..][0 .. output.len - first]);
        return output;
    }
};

fn validatePath(path: []const u8) !void {
    if (path.len == 0 or path[0] == '/') return error.InvalidCheckpointPath;
    var components = std.mem.splitScalar(u8, path, '/');
    while (components.next()) |component| {
        if (component.len == 0 or std.mem.eql(u8, component, ".") or std.mem.eql(u8, component, "..")) return error.InvalidCheckpointPath;
    }
}

test "checkpoint controller persists only when interval is due" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var controller = try Controller.init(std.testing.allocator, 32, 10, 1_000, std.testing.io, tmp.dir, "state/checkpoint.bin");
    defer controller.deinit();
    try std.testing.expect(!try controller.append("a", 10_999));
    try std.testing.expect(try controller.append("b", 11_000));
    const checkpoint = try Tap.loadCheckpoint(std.testing.io, tmp.dir, std.testing.allocator, "state/checkpoint.bin");
    try std.testing.expectEqual(@as(u64, 2), checkpoint.sequence);
    try std.testing.expectEqual(@as(i64, 11_000), checkpoint.timestamp_ms);
    try std.testing.expectError(error.InvalidCheckpointPath, Controller.init(std.testing.allocator, 32, 10, 1_000, std.testing.io, tmp.dir, "../escape.bin"));
}

test "raw disk ring stays bounded and recovers chronology after wrap" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var controller = try Controller.init(std.testing.allocator, 4, 10, 0, std.testing.io, tmp.dir, "a/checkpoint.bin");
    defer controller.deinit();
    try controller.enableRawFile("a/output.raw");
    try std.testing.expectEqual(@as(usize, 0), controller.tap.buffer.len);
    try std.testing.expectEqual(@as(usize, 4), controller.tap.capacity());
    _ = try controller.append("abc", 1);
    _ = try controller.append("defghi", 2);
    try std.testing.expectEqual(@as(usize, 0), controller.tap.buffer.len);
    try std.testing.expectEqual(@as(usize, 4), controller.tap.capacity());
    const output = try Controller.loadRaw(std.testing.allocator, std.testing.io, tmp.dir, "a/output.raw", 4);
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualStrings("fghi", output);
    var file = try tmp.dir.openFile(std.testing.io, "a/output.raw", .{});
    defer file.close(std.testing.io);
    const stat = try file.stat(std.testing.io);
    try std.testing.expectEqual(@as(u64, 36), stat.size);
    try std.testing.expectEqual(@as(std.posix.mode_t, 0o600), stat.permissions.toMode() & 0o777);
}

test "enabling disk ring preserves already wrapped memory history without retaining its allocation" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var controller = try Controller.init(std.testing.allocator, 4, 10, 0, std.testing.io, tmp.dir, "checkpoint");
    defer controller.deinit();
    try controller.appendRaw("abcdef");
    try controller.enableRawFile("output.raw");
    try std.testing.expectEqual(@as(usize, 0), controller.tap.buffer.len);
    try std.testing.expectEqual(@as(usize, 4), controller.tap.capacity());
    const first = try Controller.loadRaw(std.testing.allocator, std.testing.io, tmp.dir, "output.raw", 4);
    defer std.testing.allocator.free(first);
    try std.testing.expectEqualStrings("cdef", first);
    try controller.appendRaw("gh");
    try std.testing.expectEqual(@as(usize, 0), controller.tap.buffer.len);
    try std.testing.expectEqual(@as(usize, 4), controller.tap.capacity());
    const next = try Controller.loadRaw(std.testing.allocator, std.testing.io, tmp.dir, "output.raw", 4);
    defer std.testing.allocator.free(next);
    try std.testing.expectEqualStrings("efgh", next);
}

test "enabling disk ring migrates an unwrapped prefix and keeps later appends off the memory buffer" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var controller = try Controller.init(std.testing.allocator, 8, 10, 0, std.testing.io, tmp.dir, "checkpoint");
    defer controller.deinit();
    try controller.appendRaw("abcd");
    try controller.enableRawFile("output.raw");
    try std.testing.expectEqual(@as(usize, 0), controller.tap.buffer.len);
    try std.testing.expectEqual(@as(usize, 8), controller.tap.capacity());
    const first = try Controller.loadRaw(std.testing.allocator, std.testing.io, tmp.dir, "output.raw", 8);
    defer std.testing.allocator.free(first);
    try std.testing.expectEqualStrings("abcd", first);
    try controller.appendRaw("efghijkl");
    try std.testing.expectEqual(@as(usize, 0), controller.tap.buffer.len);
    try std.testing.expectEqual(@as(usize, 8), controller.tap.capacity());
    const next = try Controller.loadRaw(std.testing.allocator, std.testing.io, tmp.dir, "output.raw", 8);
    defer std.testing.allocator.free(next);
    try std.testing.expectEqualStrings("efghijkl", next);
}

test "failed disk enable preserves the in memory ring fallback" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var controller = try Controller.init(std.testing.allocator, 4, 10, 0, std.testing.io, tmp.dir, "checkpoint");
    defer controller.deinit();
    try controller.appendRaw("abcdef");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "occupied", .data = "unrelated" });
    try std.testing.expectError(error.PathAlreadyExists, controller.enableRawFile("occupied"));
    try std.testing.expect(controller.raw_file == null);
    try controller.appendRaw("gh");
    var bytes: [4]u8 = undefined;
    try std.testing.expectEqualStrings("efgh", try controller.tap.snapshot(&bytes));
    const occupied = try tmp.dir.readFileAlloc(std.testing.io, "occupied", std.testing.allocator, .limited(16));
    defer std.testing.allocator.free(occupied);
    try std.testing.expectEqualStrings("unrelated", occupied);
}

test "failed raw append cannot later commit a stream containing a missing segment" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var controller = try Controller.init(std.testing.allocator, 8, 1, 0, std.testing.io, tmp.dir, "checkpoint");
    defer controller.deinit();
    try controller.enableRawFile("output.raw");
    try controller.appendRaw("abcd");
    // An actual unwritable descriptor fails without relying on disk quotas or
    // changing the process environment. Restore write access before retrying.
    controller.raw_file.?.close(std.testing.io);
    controller.raw_file = try tmp.dir.openFile(std.testing.io, "output.raw", .{});
    const failure = if (controller.appendRaw("ef")) |_| return error.ExpectedWriteFailure else |err| err;
    controller.raw_file.?.close(std.testing.io);
    controller.raw_file = try tmp.dir.openFile(std.testing.io, "output.raw", .{ .mode = .read_write });
    try std.testing.expectError(failure, controller.append("gh", 1000));
    try std.testing.expectEqual(@as(u64, 4), controller.tap.sequence);
    const retained = try Controller.loadRaw(std.testing.allocator, std.testing.io, tmp.dir, "output.raw", 8);
    defer std.testing.allocator.free(retained);
    try std.testing.expectEqualStrings("abcd", retained);
    try std.testing.expectError(error.FileNotFound, Tap.loadCheckpoint(std.testing.io, tmp.dir, std.testing.allocator, "checkpoint"));
}
