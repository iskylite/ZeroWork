//! UI-independent connection diagnostics. Each event identifies the attempt,
//! destination hop and exact phase. Callbacks never expose authentication data.
const std = @import("std");

pub const Phase = enum { transport, tunnel, handshake, host_key, authentication, shell, ready };
pub const Status = enum { started, succeeded, failed, cancelled };
/// Owned, bounded pre-authentication native diagnostics; never authentication data.
pub const Diagnostic = struct {
    bytes: [2048]u8 = @splat(0),
    len: usize = 0,
    pub fn slice(self: *const Diagnostic) []const u8 {
        return self.bytes[0..self.len];
    }
    pub fn format(self: *Diagnostic, comptime fmt: []const u8, args: anytype) void {
        var writer: std.Io.Writer = .fixed(&self.bytes);
        writer.print(fmt, args) catch {
            const suffix = "\n[truncated]";
            const kept = @min(writer.buffered().len, self.bytes.len - suffix.len);
            @memcpy(self.bytes[kept..][0..suffix.len], suffix);
            self.len = kept + suffix.len;
            return;
        };
        self.len = writer.buffered().len;
    }
};
pub const Event = struct {
    /// A fresh identity per attempt, including retries; never reuse while an
    /// older worker can still deliver callbacks.
    attempt: u64,
    /// Monotonic nanoseconds for ordering/duration, not a wall-clock date.
    timestamp_ns: i128 = 0,
    timestamp_ms: i64 = 0,
    hop: usize,
    hop_count: usize,
    host: []const u8, // Borrowed for this callback only; Journal copies it.
    port: u16,
    phase: Phase,
    status: Status,
    failure: ?anyerror = null,
    diagnostic: []const u8 = "", // Borrowed for this callback only.
};
pub const Observer = struct {
    context: *anyopaque,
    callback: *const fn (*anyopaque, Event) void,
};

/// Bounded, owned event journal for worker-to-controller polling. The observer
/// may run on the SSH worker; snapshots and retries can run on another thread.
/// Call begin with a fresh attempt id before retrying. Late events from an old
/// attempt are rejected, so a cancelled attempt cannot close a new dialog.
pub const Journal = struct {
    pub const capacity = 128;
    pub const Entry = struct {
        sequence: u64 = 0,
        timestamp_ns: i128 = 0,
        timestamp_ms: i64 = 0,
        elapsed_us: ?u64 = null,
        hop: usize = 0,
        hop_count: usize = 0,
        host: [256]u8 = @splat(0),
        host_len: usize = 0,
        port: u16 = 0,
        phase: Phase = .transport,
        status: Status = .started,
        failure: ?anyerror = null,
        diagnostic: Diagnostic = .{},
        /// Shared by the live view, retained logs, raw bubble and clipboard.
        pub fn writeLine(self: *const Entry, writer: *std.Io.Writer, comptime fmt: []const u8, args: anytype) !void {
            var timestamp_buffer: [32]u8 = undefined;
            const timestamp = if (self.timestamp_ms > 0) @import("forward_diagnostics.zig").formatTimestamp(&timestamp_buffer, self.timestamp_ms) else "时间未知";
            try writer.print("{s} - ", .{timestamp});
            try writer.print(fmt, args);
            if (self.elapsed_us) |us| try writer.print(" - {d}.{d:0>3} ms\n", .{ us / 1000, us % 1000 }) else try writer.writeAll(" - —\n");
        }
        pub fn writeDiagnostic(self: *const Entry, writer: *std.Io.Writer) !void {
            var lines = std.mem.splitScalar(u8, self.diagnostic.slice(), '\n');
            while (lines.next()) |line| if (line.len != 0) try self.writeLine(writer, "{s}", .{line});
        }
        pub fn hostSlice(self: *const Entry) []const u8 {
            return self.host[0..self.host_len];
        }
    };
    pub const Snapshot = struct {
        attempt: u64,
        entries: [capacity]Entry,
        count: usize,
        dropped: usize,
        completed: bool,
        failure: ?Entry,
    };
    lock_flag: std.atomic.Value(bool) = .init(false),
    attempt: u64 = 0,
    entries: [capacity]Entry = @splat(.{}),
    count: usize = 0,
    dropped: usize = 0,
    sequence: u64 = 0,
    completed: bool = false,
    failure: ?Entry = null,
    fn lock(self: *Journal) void {
        while (self.lock_flag.swap(true, .acquire)) std.atomic.spinLoopHint();
    }
    fn unlock(self: *Journal) void {
        self.lock_flag.store(false, .release);
    }
    pub fn begin(self: *Journal, attempt: u64) void {
        self.lock();
        defer self.unlock();
        self.attempt = attempt;
        self.count = 0;
        self.dropped = 0;
        self.sequence = 0;
        self.completed = false;
        self.failure = null;
    }
    pub fn observer(self: *Journal) Observer {
        return .{ .context = self, .callback = receive };
    }
    /// Serial pre-auth transport retry under the same create operation. Its
    /// previous worker is joined; keep sequence monotonic across saved logs.
    pub fn restartTransport(self: *Journal) void {
        self.lock();
        defer self.unlock();
        self.count = 0;
        self.dropped = 0;
        self.completed = false;
        self.failure = null;
    }
    fn receive(raw: *anyopaque, event: Event) void {
        const self: *Journal = @ptrCast(@alignCast(raw));
        self.record(event);
    }
    pub fn record(self: *Journal, event: Event) void {
        self.lock();
        defer self.unlock();
        if (event.attempt != self.attempt or event.hop_count == 0 or event.hop >= event.hop_count or self.completed or self.failure != null) return;
        var entry: Entry = .{ .sequence = self.sequence, .timestamp_ns = event.timestamp_ns, .timestamp_ms = event.timestamp_ms, .hop = event.hop, .hop_count = event.hop_count, .port = event.port, .phase = event.phase, .status = event.status, .failure = event.failure };
        entry.host_len = @min(entry.host.len, event.host.len);
        @memcpy(entry.host[0..entry.host_len], event.host[0..entry.host_len]);
        entry.diagnostic.len = @min(entry.diagnostic.bytes.len, event.diagnostic.len);
        @memcpy(entry.diagnostic.bytes[0..entry.diagnostic.len], event.diagnostic[0..entry.diagnostic.len]);
        if (event.status != .started) {
            var index = self.count;
            while (index > 0) {
                index -= 1;
                const start = &self.entries[index];
                if (start.hop != event.hop or start.phase != event.phase) continue;
                if (start.status == .started and event.timestamp_ns >= start.timestamp_ns)
                    entry.elapsed_us = @intCast(@divTrunc(event.timestamp_ns - start.timestamp_ns, std.time.ns_per_us));
                break;
            }
        }
        self.sequence += 1;
        if (self.count == capacity) {
            std.mem.copyForwards(Entry, self.entries[0 .. capacity - 1], self.entries[1..capacity]);
            self.count -= 1;
            self.dropped += 1;
        }
        self.entries[self.count] = entry;
        self.count += 1;
        if (event.status == .failed or event.status == .cancelled) self.failure = entry;
        // Protocol readiness is not proof that controller attachment or failure
        // cleanup has finished. The controller also waits for the worker result.
        if (event.phase == .ready and event.status == .succeeded and event.hop + 1 == event.hop_count) self.completed = true;
    }
    pub fn snapshot(self: *Journal) Snapshot {
        self.lock();
        defer self.unlock();
        return .{ .attempt = self.attempt, .entries = self.entries, .count = self.count, .dropped = self.dropped, .completed = self.completed, .failure = self.failure };
    }
};

test "connection journal owns host labels and locates the failed hop and phase" {
    var journal: Journal = .{};
    journal.begin(7);
    var host = [_]u8{ 'h', 'o', 'p', '2' };
    journal.record(.{ .attempt = 7, .hop = 1, .hop_count = 3, .host = &host, .port = 22, .phase = .authentication, .status = .failed, .failure = error.AuthenticationFailed });
    @memset(&host, 'x');
    const snapshot = journal.snapshot();
    try std.testing.expectEqualStrings("hop2", snapshot.failure.?.hostSlice());
    try std.testing.expectEqual(@as(usize, 1), snapshot.failure.?.hop);
    try std.testing.expectEqual(Phase.authentication, snapshot.failure.?.phase);
    try std.testing.expect(!snapshot.completed);
    journal.begin(8);
    journal.record(.{ .attempt = 7, .hop = 2, .hop_count = 3, .host = "target", .port = 22, .phase = .ready, .status = .succeeded });
    try std.testing.expectEqual(@as(usize, 0), journal.snapshot().count);
}

test "only final hop completion succeeds and diagnostic storage stays bounded" {
    var journal: Journal = .{};
    journal.begin(9);
    var event: Event = .{ .attempt = 9, .hop = 0, .hop_count = 2, .host = "edge", .port = 22, .phase = .ready, .status = .succeeded };
    for (0..Journal.capacity + 5) |_| journal.record(event);
    const pending = journal.snapshot();
    try std.testing.expect(!pending.completed);
    try std.testing.expectEqual(Journal.capacity, pending.count);
    try std.testing.expectEqual(@as(usize, 5), pending.dropped);
    event.hop = 1;
    journal.record(event);
    try std.testing.expect(journal.snapshot().completed);
}

test "connection journal owns bounded native diagnostics across worker teardown and retry" {
    var journal: Journal = .{};
    journal.begin(1);
    var raw: [4096]u8 = @splat('x');
    journal.record(.{ .attempt = 1, .hop = 0, .hop_count = 1, .host = "loopback", .port = 22, .phase = .handshake, .status = .failed, .diagnostic = &raw });
    @memset(&raw, 'y');
    const captured = journal.snapshot();
    try std.testing.expectEqual(@as(usize, 2048), captured.failure.?.diagnostic.len);
    try std.testing.expectEqual(@as(u8, 'x'), captured.failure.?.diagnostic.slice()[0]);
    journal.begin(2);
    try std.testing.expect(journal.snapshot().failure == null);
    var diagnostic: Diagnostic = .{};
    diagnostic.format("{s}", .{&raw});
    try std.testing.expect(std.mem.endsWith(u8, diagnostic.slice(), "[truncated]"));
}

test "connection log format uses wall timestamp and phase duration independently" {
    var journal: Journal = .{};
    journal.begin(1);
    journal.record(.{ .attempt = 1, .hop = 0, .hop_count = 1, .host = "loopback", .port = 22, .phase = .handshake, .status = .started, .timestamp_ns = 1000000, .timestamp_ms = 1793600000000 });
    journal.record(.{ .attempt = 1, .hop = 0, .hop_count = 1, .host = "loopback", .port = 22, .phase = .handshake, .status = .failed, .timestamp_ns = 2456000, .timestamp_ms = 1793599999990 });
    const captured = journal.snapshot();
    try std.testing.expectEqual(@as(?u64, 1456), captured.failure.?.elapsed_us);
    var buffer: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try captured.failure.?.writeLine(&writer, "{s}", .{"handshake failed"});
    var stamp: [32]u8 = undefined;
    const expected_stamp = @import("forward_diagnostics.zig").formatTimestamp(&stamp, 1793599999990);
    try std.testing.expectEqual(@as(usize, 12), expected_stamp.len);
    try std.testing.expect(std.mem.indexOfScalar(u8, expected_stamp, '+') == null);
    try std.testing.expect(std.mem.startsWith(u8, writer.buffered(), expected_stamp));
    try std.testing.expect(std.mem.endsWith(u8, writer.buffered(), " - handshake failed - 1.456 ms\n"));
    try std.testing.expect(captured.entries[0].elapsed_us == null);
}
