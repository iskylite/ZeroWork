const std = @import("std");
const InputQueue = @import("input_queue.zig").InputQueue;
const OperationKey = @import("../host/operation.zig").OperationKey;
const Modes = @import("engine.zig").Modes;

pub const Source = enum { ordinary, application, history, paste, broadcast };
/// Only modes that affect the meaning/encoding of input participate. Cosmetic
/// cursor/color changes do not make an otherwise identical key unsafe.
pub const InputMode = struct {
    application_cursor: bool = false,
    application_keypad: bool = false,
    backarrow_key: bool = false,
    alt_esc_prefix: bool = false,
    bracketed_paste: bool = false,
    alternate_screen: bool = false,
    keyboard_disabled: bool = false,
    kitty_keyboard_flags: u8 = 0,
    pub fn from(modes: Modes) InputMode {
        return .{ .application_cursor = modes.application_cursor, .application_keypad = modes.application_keypad, .backarrow_key = modes.backarrow_key, .alt_esc_prefix = modes.alt_esc_prefix, .bracketed_paste = modes.bracketed_paste, .alternate_screen = modes.alternate_screen, .keyboard_disabled = modes.keyboard_disabled, .kitty_keyboard_flags = modes.kitty_keyboard_flags };
    }
};

/// Event metadata accompanies the existing byte queue. All producers (UI,
/// startup and one-time handoff) use this gate; the sole IO consumer still owns
/// InputQueue.consume. Native writes are observed through its actual read index.
pub const Replay = struct {
    const Phase = enum { awaiting_attach, active, disconnected, ended, closed };
    const Event = struct { start: usize, len: usize, written: usize = 0, source: Source, mode: InputMode, origin: ?OperationKey, delivery: ?OperationKey, id: u64 };
    const Cached = struct { offset: usize, len: usize, mode: InputMode, origin: ?OperationKey, id: u64 };
    pub const Snapshot = struct {
        key: ?OperationKey,
        queued: usize,
        sent: usize,
        acknowledged: ?usize = null,
        uncertain: usize,
        rejected: usize,
        handed_off: usize,
    };
    allocator: std.mem.Allocator,
    bytes: std.ArrayList(u8) = .empty,
    cached: std.ArrayList(Cached) = .empty,
    events: std.ArrayList(Event) = .empty,
    limit: usize,
    max_events: usize,
    mutex: std.atomic.Mutex = .unlocked,
    phase: Phase = .awaiting_attach,
    key: ?OperationKey = null,
    enabled: bool = true,
    next_event: u64 = 1,
    sent: usize = 0,
    attempt_sent: usize = 0,
    uncertain: usize = 0,
    rejected: usize = 0,
    handed_off: usize = 0,

    pub fn init(allocator: std.mem.Allocator, limit: usize) !Replay {
        if (limit == 0 or limit > 8192) return error.InvalidLimit;
        var self: Replay = .{ .allocator = allocator, .limit = limit, .max_events = limit + 64 };
        errdefer self.bytes.deinit(allocator);
        errdefer self.cached.deinit(allocator);
        errdefer self.events.deinit(allocator);
        try self.bytes.ensureTotalCapacity(allocator, limit);
        try self.cached.ensureTotalCapacity(allocator, limit);
        try self.events.ensureTotalCapacity(allocator, self.max_events);
        return self;
    }
    pub fn configure(self: *Replay, key: ?OperationKey, enabled: bool, attached_now: bool) void {
        self.key = key;
        self.enabled = enabled;
        self.phase = if (attached_now) .active else .awaiting_attach;
    }
    pub fn deinit(self: *Replay) void {
        @memset(self.bytes.items, 0);
        self.bytes.deinit(self.allocator);
        self.cached.deinit(self.allocator);
        self.events.deinit(self.allocator);
        self.* = undefined;
    }
    fn lock(self: *Replay) void {
        while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
    }
    fn unlock(self: *Replay) void {
        self.mutex.unlock();
    }
    fn clearCached(self: *Replay) void {
        @memset(self.bytes.items, 0);
        self.bytes.clearRetainingCapacity();
        self.cached.clearRetainingCapacity();
    }
    pub fn setEnabled(self: *Replay, enabled: bool) void {
        self.lock();
        defer self.unlock();
        self.enabled = enabled;
        if (!enabled) self.clearCached();
    }
    pub fn discardBuffered(self: *Replay) void {
        self.lock();
        defer self.unlock();
        self.clearCached();
    }
    pub fn invalidate(self: *Replay) void {
        self.lock();
        defer self.unlock();
        self.phase = .closed;
        self.clearCached();
    }
    /// Read operation ownership under the same gate as reconnect and close.
    /// Final output remains observable after EOF, until the owner is released.
    pub fn notificationKey(self: *Replay) !OperationKey {
        self.lock();
        defer self.unlock();
        if (self.phase == .closed) return error.TerminalClosed;
        return self.key orelse error.MissingOperation;
    }
    pub fn allowsOrdinary(self: *Replay) bool {
        self.lock();
        defer self.unlock();
        return self.phase != .closed and self.phase != .ended and (self.phase == .active or self.enabled);
    }

    fn observeLocked(self: *Replay, queue: *const InputQueue) void {
        const read = queue.read_index.load(.acquire);
        var retired: usize = 0;
        for (self.events.items) |*event| {
            const distance = read -% event.start;
            // A not-yet-written event begins ahead of read within capacity.
            const written = if (distance <= queue.capacity() * 2) @min(distance, event.len) else 0;
            if (written > event.written) {
                const accepted = written - event.written;
                self.sent +|= accepted;
                self.attempt_sent +|= accepted;
                event.written = written;
            }
            if (event.written != event.len) break;
            retired += 1;
        }
        if (retired != 0) {
            std.mem.copyForwards(Event, self.events.items[0 .. self.events.items.len - retired], self.events.items[retired..]);
            self.events.items.len -= retired;
        }
    }
    fn enqueueLocked(self: *Replay, queue: *InputQueue, input: []const u8, source: Source, mode: InputMode, origin: ?OperationKey, id: u64) !void {
        if (self.events.items.len == self.max_events) return error.InputEventsFull;
        const start = queue.write_index.load(.acquire);
        try queue.push(input);
        self.events.appendAssumeCapacity(.{ .start = start, .len = input.len, .source = source, .mode = mode, .origin = origin, .delivery = self.key, .id = id });
    }
    fn cacheLocked(self: *Replay, input: []const u8, mode: InputMode, origin: ?OperationKey, id: u64) !void {
        if (input.len > self.limit - self.bytes.items.len or self.cached.items.len == self.limit) return error.ReplayFull;
        const offset = self.bytes.items.len;
        self.bytes.appendSliceAssumeCapacity(input);
        self.cached.appendAssumeCapacity(.{ .offset = offset, .len = input.len, .mode = mode, .origin = origin, .id = id });
    }
    pub fn submit(self: *Replay, queue: *InputQueue, input: []const u8, source: Source, mode: InputMode) !void {
        if (input.len == 0) return;
        if (source == .ordinary and !std.unicode.utf8ValidateSlice(input)) return error.InvalidInputEvent;
        self.lock();
        defer self.unlock();
        self.observeLocked(queue);
        if (self.phase == .closed or self.phase == .ended) return error.SessionClosed;
        if (self.next_event == std.math.maxInt(u64)) return error.InputSequenceExhausted;
        const id = self.next_event;
        if (self.phase != .active) {
            if (source != .ordinary) return error.DisconnectedApplicationInput;
            if (!self.enabled) return error.DisconnectedInputDisabled;
            self.cacheLocked(input, mode, self.key, id) catch |err| {
                self.rejected +|= input.len;
                return err;
            };
        } else self.enqueueLocked(queue, input, source, mode, self.key, id) catch |err| {
            self.rejected +|= input.len;
            return err;
        };
        self.next_event += 1;
    }
    /// Sole worker producer, while the UI still sees awaiting_attach. Startup
    /// is never ordinary and is discarded if this attempt loses its transport.
    pub fn startup(self: *Replay, queue: *InputQueue, input: []const u8) !void {
        if (input.len == 0) return;
        self.lock();
        defer self.unlock();
        if (self.phase == .closed or self.phase == .ended or self.phase == .disconnected) return error.SessionClosed;
        self.observeLocked(queue);
        if (self.next_event == std.math.maxInt(u64)) return error.InputSequenceExhausted;
        try self.enqueueLocked(queue, input, .application, .{}, self.key, self.next_event);
        self.next_event += 1;
    }
    /// IO owner, immediately after a fault. A partially accepted event has an
    /// uncertain outcome; its remaining suffix must never be replayed.
    pub fn disconnected(self: *Replay, queue: *InputQueue) void {
        self.lock();
        defer self.unlock();
        self.observeLocked(queue);
        self.uncertain +|= self.attempt_sent;
        self.attempt_sent = 0;
        const read = queue.read_index.load(.acquire);
        for (self.events.items) |event| {
            if (event.written != 0) continue;
            if (self.phase == .closed or !self.enabled or event.source != .ordinary) continue;
            if (event.len > self.limit - self.bytes.items.len or self.cached.items.len == self.limit) {
                self.rejected +|= event.len;
                continue;
            }
            const offset = event.start -% read;
            if (offset > queue.pending() or event.len > queue.pending() - offset) {
                self.rejected +|= event.len;
                continue;
            }
            const start = self.bytes.items.len;
            for (0..event.len) |i| self.bytes.appendAssumeCapacity(queue.buffer[(event.start +% i) % queue.capacity()]);
            self.cached.appendAssumeCapacity(.{ .offset = start, .len = event.len, .mode = event.mode, .origin = event.origin, .id = event.id });
        }
        self.events.clearRetainingCapacity();
        queue.consume(queue.pending()) catch unreachable;
        if (self.phase != .closed) self.phase = .disconnected;
    }
    pub fn authorize(self: *Replay, previous: OperationKey, next: OperationKey) !void {
        self.lock();
        defer self.unlock();
        if ((self.phase != .disconnected and self.phase != .ended) or self.key == null or !self.key.?.eql(previous)) return error.StaleOperation;
        if (previous.owner != .session or next.owner != .session or previous.owner.session.session_id != next.owner.session.session_id or next.owner.session.generation <= previous.owner.session.generation) return error.InvalidOperation;
        self.key = next;
        self.phase = .awaiting_attach;
    }
    /// A normally ended shell is read-only even when disconnect buffering is
    /// enabled. Explicit rebuilding may authorize a successor, with no cache.
    pub fn ended(self: *Replay, queue: *InputQueue) void {
        self.disconnected(queue);
        self.lock();
        defer self.unlock();
        self.clearCached();
        self.phase = .ended;
    }
    /// Exactly one handoff per attachment, under the same producer gate as UI
    /// submission. Duplicate ready/attached deliveries cannot enqueue it twice.
    pub fn attached(self: *Replay, queue: *InputQueue, key: ?OperationKey, mode: InputMode) !bool {
        self.lock();
        defer self.unlock();
        if (!std.meta.eql(self.key, key)) return error.StaleOperation;
        if (self.phase != .awaiting_attach) return false;
        self.observeLocked(queue);
        if (self.bytes.items.len > queue.freeCapacity() or self.cached.items.len > self.max_events - self.events.items.len) return error.Full;
        for (self.cached.items) |event| {
            if (!std.meta.eql(event.mode, mode) or mode.keyboard_disabled) {
                self.rejected +|= event.len;
                continue;
            }
            if (event.origin) |origin| {
                if (key == null or key.?.owner != .session or origin.owner != .session or origin.owner.session.session_id != key.?.owner.session.session_id) {
                    self.rejected +|= event.len;
                    continue;
                }
            }
            try self.enqueueLocked(queue, self.bytes.items[event.offset..][0..event.len], .ordinary, event.mode, event.origin, event.id);
            self.handed_off +|= event.len;
        }
        self.clearCached();
        self.phase = .active;
        return true;
    }
    pub fn snapshot(self: *Replay, queue: *const InputQueue) Snapshot {
        self.lock();
        defer self.unlock();
        self.observeLocked(queue);
        var queued = self.bytes.items.len;
        for (self.events.items) |event| queued +|= event.len - event.written;
        return .{ .key = self.key, .queued = queued, .sent = self.sent, .uncertain = self.uncertain, .rejected = self.rejected, .handed_off = self.handed_off };
    }
};

fn testKey(generation: u64) OperationKey {
    return .{ .owner = .{ .session = .{ .session_id = @fromBackingInt(7), .generation = generation } }, .operation_id = generation, .attempt_id = generation };
}

test "ordinary cache has exact 8KiB complete UTF8 event boundary" {
    var replay = try Replay.init(std.testing.allocator, 8192);
    defer replay.deinit();
    replay.configure(testKey(1), true, false);
    var queue = try InputQueue.init(std.testing.allocator, 16384);
    defer queue.deinit(std.testing.allocator);
    const prefix: [8189]u8 = @splat('a');
    try replay.submit(&queue, &prefix, .ordinary, .{});
    try replay.submit(&queue, "中", .ordinary, .{});
    try std.testing.expectError(error.ReplayFull, replay.submit(&queue, "文", .ordinary, .{}));
    try std.testing.expectEqual(@as(usize, 8192), replay.snapshot(&queue).queued);
    try std.testing.expect(try replay.attached(&queue, testKey(1), .{}));
    try std.testing.expect(!try replay.attached(&queue, testKey(1), .{}));
    var bytes: [8192]u8 = undefined;
    const sent = queue.drain(&bytes);
    try std.testing.expect(std.unicode.utf8ValidateSlice(sent));
    try std.testing.expectEqualStrings("中", sent[8189..]);
    try std.testing.expectEqual(@as(usize, 8192), replay.snapshot(&queue).handed_off);
}

test "partial real write progress makes whole event uncertain and only untouched ordinary survives" {
    var replay = try Replay.init(std.testing.allocator, 32);
    defer replay.deinit();
    replay.configure(testKey(1), true, true);
    var queue = try InputQueue.init(std.testing.allocator, 128);
    defer queue.deinit(std.testing.allocator);
    try replay.submit(&queue, "中文", .ordinary, .{});
    try replay.submit(&queue, "safe", .ordinary, .{});
    try replay.submit(&queue, "APP", .application, .{});
    try replay.submit(&queue, "OLD_APPROVED_PASTE", .paste, .{});
    const sockets = try @import("../proto/ssh/session.zig").SocketRelay.Pair.create();
    defer _ = std.c.close(sockets.target_fd);
    defer _ = std.c.close(sockets.relay_fd);
    const Writer = struct {
        fd: c_int,
        written: bool = false,
        fn write(raw: *anyopaque, bytes: []const u8) !usize {
            const self: *@This() = @ptrCast(@alignCast(raw));
            if (self.written) return error.FixtureDisconnected;
            const n = std.c.write(self.fd, bytes.ptr, 1);
            if (n != 1) return error.SocketWriteFailed;
            self.written = true;
            return 1;
        }
    };
    var writer: Writer = .{ .fd = sockets.target_fd };
    var scratch: [128]u8 = undefined;
    try std.testing.expectError(error.FixtureDisconnected, @import("channel_pump.zig").pumpInputBatch(&queue, .{ .ctx = &writer, .write_fn = Writer.write }, &scratch, 4));
    var received: [1]u8 = undefined;
    try std.testing.expectEqual(@as(isize, 1), std.c.read(sockets.relay_fd, &received, 1));
    try std.testing.expectEqual(@as(u8, 0xe4), received[0]);
    replay.disconnected(&queue);
    const failed = replay.snapshot(&queue);
    try std.testing.expectEqual(@as(usize, 1), failed.sent);
    try std.testing.expectEqual(@as(usize, 1), failed.uncertain);
    try std.testing.expect(failed.acknowledged == null);
    try std.testing.expectEqual(@as(usize, 4), failed.queued);
    try replay.authorize(testKey(1), testKey(2));
    try std.testing.expectError(error.StaleOperation, replay.attached(&queue, testKey(1), .{}));
    try std.testing.expect(try replay.attached(&queue, testKey(2), .{}));
    var bytes: [128]u8 = undefined;
    try std.testing.expectEqualStrings("safe", queue.drain(&bytes));
}

test "mode change policy off and close invalidate unsent input without caching application sources" {
    var replay = try Replay.init(std.testing.allocator, 32);
    defer replay.deinit();
    replay.configure(testKey(1), true, false);
    var queue = try InputQueue.init(std.testing.allocator, 128);
    defer queue.deinit(std.testing.allocator);
    for ([_]Source{ .application, .history, .paste, .broadcast }) |source| try std.testing.expectError(error.DisconnectedApplicationInput, replay.submit(&queue, "never", source, .{}));
    try replay.submit(&queue, "key", .ordinary, .{ .application_cursor = true });
    try std.testing.expect(try replay.attached(&queue, testKey(1), .{}));
    try std.testing.expectEqual(@as(usize, 0), queue.pending());
    replay.disconnected(&queue);
    try replay.submit(&queue, "pending", .ordinary, .{});
    replay.setEnabled(false);
    try std.testing.expectEqual(@as(usize, 0), replay.snapshot(&queue).queued);
    try std.testing.expectError(error.DisconnectedInputDisabled, replay.submit(&queue, "x", .ordinary, .{}));
    replay.invalidate();
    try std.testing.expectError(error.SessionClosed, replay.submit(&queue, "x", .ordinary, .{}));
}

test "normal shell end clears unsent input and prohibits caching until explicit successor" {
    var replay = try Replay.init(std.testing.allocator, 32);
    defer replay.deinit();
    replay.configure(testKey(1), true, true);
    var queue = try InputQueue.init(std.testing.allocator, 128);
    defer queue.deinit(std.testing.allocator);
    try replay.submit(&queue, "old", .ordinary, .{});
    replay.ended(&queue);
    try std.testing.expectEqual(@as(usize, 0), queue.pending());
    try std.testing.expectEqual(@as(usize, 0), replay.snapshot(&queue).queued);
    try std.testing.expect(!replay.allowsOrdinary());
    try std.testing.expectError(error.SessionClosed, replay.submit(&queue, "late", .ordinary, .{}));
    try std.testing.expectError(error.SessionClosed, replay.submit(&queue, "paste", .paste, .{}));
    try replay.authorize(testKey(1), testKey(2));
    try std.testing.expect(try replay.attached(&queue, testKey(2), .{}));
    try std.testing.expectEqual(@as(usize, 0), queue.pending());
    try replay.submit(&queue, "new", .ordinary, .{});
    var bytes: [8]u8 = undefined;
    try std.testing.expectEqualStrings("new", queue.drain(&bytes));
}
