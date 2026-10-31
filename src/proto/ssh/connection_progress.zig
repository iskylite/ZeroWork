//! UI-independent connection diagnostics. Each event identifies the attempt,
//! destination hop and exact phase. Callbacks never expose authentication data.
const std = @import("std");

pub const Phase = enum { transport, tunnel, handshake, host_key, authentication, shell, ready };
pub const Status = enum { started, succeeded, failed, cancelled };
pub const Event = struct {
    /// A fresh identity per attempt, including retries; never reuse while an
    /// older worker can still deliver callbacks.
    attempt: u64,
    /// Monotonic nanoseconds for ordering/duration, not a wall-clock date.
    timestamp_ns: i128 = 0,
    hop: usize,
    hop_count: usize,
    host: []const u8, // Borrowed for this callback only; Journal copies it.
    port: u16,
    phase: Phase,
    status: Status,
    failure: ?anyerror = null,
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
        hop: usize = 0,
        hop_count: usize = 0,
        host: [256]u8 = @splat(0),
        host_len: usize = 0,
        port: u16 = 0,
        phase: Phase = .transport,
        status: Status = .started,
        failure: ?anyerror = null,
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
        var entry: Entry = .{ .sequence = self.sequence, .timestamp_ns = event.timestamp_ns, .hop = event.hop, .hop_count = event.hop_count, .port = event.port, .phase = event.phase, .status = event.status, .failure = event.failure };
        entry.host_len = @min(entry.host.len, event.host.len);
        @memcpy(entry.host[0..entry.host_len], event.host[0..entry.host_len]);
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
