//! Bounded CPU work shared by SSH panes. Neither queue jobs nor results contain
//! a Cx/Node/Signal. The Runtime's background release calls Owner.finish before
//! freeing its Provider and VT; interactive close only cancels.
const std = @import("std");
const work = @import("search_task.zig");
const Adapter = @import("ghostty_adapter.zig").Adapter;
const OwnerId = @import("../host/identity.zig").SessionHandle;
const worker_count = 2;
const queue_capacity = 16;

fn lock(m: *std.c.pthread_mutex_t) void {
    std.debug.assert(std.c.pthread_mutex_lock(m) == .SUCCESS);
}
fn unlock(m: *std.c.pthread_mutex_t) void {
    std.debug.assert(std.c.pthread_mutex_unlock(m) == .SUCCESS);
}

pub const Owner = struct {
    mutex: std.c.pthread_mutex_t = .{},
    condition: std.c.pthread_cond_t = .{},
    active: bool = false,
    closed: bool = false,
    registered: bool = false,
    finished: bool = false,
    task: ?*work.Task = null, // independent owner reference, never borrowed from UI

    pub fn begin(self: *Owner, adapter: *Adapter, id: OwnerId) !*work.Task {
        lock(&self.mutex);
        defer unlock(&self.mutex);
        if (self.closed) return error.SessionClosed;
        if (self.active) return error.WorkerBusy;
        if (self.task) |old| old.release();
        self.task = null;
        if (!self.registered) {
            try pool.acquire();
            self.registered = true;
        }
        const task = try work.Task.create(id);
        task.retain();
        self.task = task;
        self.active = true;
        pool.submit(.{ .owner = self, .adapter = adapter, .task = task }) catch |err| {
            self.active = false;
            self.task = null;
            task.release();
            task.release();
            task.release();
            return err;
        };
        return task;
    }
    /// Main-thread cancellation is bounded and never joins a CPU worker.
    pub fn cancel(self: *Owner) void {
        lock(&self.mutex);
        defer unlock(&self.mutex);
        self.closed = true;
        self.cancelLocked();
    }
    /// Reconnect changes the service generation, not this owner's address.
    /// The old task retains its original handle and must drain before begin.
    pub fn cancelCurrent(self: *Owner) void {
        lock(&self.mutex);
        defer unlock(&self.mutex);
        self.cancelLocked();
    }
    fn cancelLocked(self: *Owner) void {
        if (self.task) |task| {
            task.cancelled.store(true, .release);
            task.release();
            self.task = null;
        }
    }
    /// Background teardown only, after UI admission is withdrawn. All borrowed
    /// Adapter/Owner addresses stay alive until the final worker unlocks here.
    pub fn finish(self: *Owner) void {
        lock(&self.mutex);
        if (self.finished) {
            unlock(&self.mutex);
            return;
        }
        self.closed = true;
        self.cancelLocked();
        while (self.active) std.debug.assert(std.c.pthread_cond_wait(&self.condition, &self.mutex) == .SUCCESS);
        const registered = self.registered;
        self.registered = false;
        self.finished = true;
        unlock(&self.mutex);
        if (registered) pool.release();
    }
    /// Final struct disposal after Runtime's release receipt, when UI admission
    /// and background finish have both ended. cancel/finish may race before
    /// that receipt; neither destroys synchronization objects.
    pub fn deinit(self: *Owner) void {
        lock(&self.mutex);
        std.debug.assert(self.finished and !self.active);
        unlock(&self.mutex);
        std.debug.assert(std.c.pthread_cond_destroy(&self.condition) == .SUCCESS);
        std.debug.assert(std.c.pthread_mutex_destroy(&self.mutex) == .SUCCESS);
    }
};

const Job = struct {
    owner: *Owner,
    adapter: *Adapter,
    task: *work.Task,
    fn run(self: Job) bool {
        var result: ?work.Result = null;
        var failure: ?anyerror = null;
        capture: {
            if (self.task.cancelled.load(.acquire)) {
                failure = error.Cancelled;
                break :capture;
            }
            var prepared = self.adapter.prepareSearchCancelable(&self.task.cancelled) catch |err| {
                failure = err;
                break :capture;
            };
            defer prepared.deinit();
            // No VT lock is held during end_update or UTF-8/style expansion.
            const document = prepared.finish(work.allocator, &self.task.cancelled) catch |err| {
                failure = err;
                break :capture;
            };
            result = .{ .owner = self.task.owner, .document = document, .shape = prepared.shape };
        }
        if (self.task.cancelled.load(.acquire)) {
            if (result) |*value| value.document.deinit(work.allocator);
            result = null;
            failure = error.Cancelled;
        }
        const cancelled = self.task.cancelled.load(.acquire);
        self.task.finish(result, failure);
        self.task.release();
        lock(&self.owner.mutex);
        self.owner.active = false;
        std.debug.assert(std.c.pthread_cond_broadcast(&self.owner.condition) == .SUCCESS);
        unlock(&self.owner.mutex);
        // Owner/Adapter may be freed after unlock; use neither again.
        @import("../platform/presentation_wakeup.zig").notify();
        return cancelled;
    }
};

const Pool = struct {
    mutex: std.c.pthread_mutex_t = .{},
    condition: std.c.pthread_cond_t = .{},
    threads: [worker_count]?std.Thread = @splat(null),
    users: usize = 0,
    stopping: bool = false,
    queue: [queue_capacity]Job = undefined,
    head: usize = 0,
    len: usize = 0,
    running: usize = 0,
    completed: u64 = 0,
    cancelled: u64 = 0,
    fn acquire(self: *Pool) !void {
        lock(&self.mutex);
        if (self.stopping) {
            unlock(&self.mutex);
            return error.WorkerBusy;
        }
        if (self.users == 0) {
            for (&self.threads) |*slot| {
                slot.* = std.Thread.spawn(.{}, loop, .{self}) catch |err| {
                    self.stopping = true;
                    _ = std.c.pthread_cond_broadcast(&self.condition);
                    unlock(&self.mutex);
                    for (&self.threads) |*started| if (started.*) |thread| {
                        thread.join();
                        started.* = null;
                    };
                    lock(&self.mutex);
                    self.stopping = false;
                    unlock(&self.mutex);
                    return err;
                };
            }
        }
        self.users += 1;
        unlock(&self.mutex);
    }
    fn submit(self: *Pool, job: Job) !void {
        lock(&self.mutex);
        defer unlock(&self.mutex);
        if (self.stopping or self.len == queue_capacity) return error.WorkerBusy;
        self.queue[(self.head + self.len) % queue_capacity] = job;
        self.len += 1;
        _ = std.c.pthread_cond_signal(&self.condition);
    }
    fn release(self: *Pool) void {
        lock(&self.mutex);
        self.users -= 1;
        if (self.users != 0) {
            unlock(&self.mutex);
            return;
        }
        std.debug.assert(self.len == 0);
        self.stopping = true;
        _ = std.c.pthread_cond_broadcast(&self.condition);
        unlock(&self.mutex);
        for (&self.threads) |*slot| if (slot.*) |thread| {
            thread.join();
            slot.* = null;
        };
        lock(&self.mutex);
        self.stopping = false;
        self.head = 0;
        unlock(&self.mutex);
    }
    fn loop(self: *Pool) void {
        while (true) {
            lock(&self.mutex);
            while (self.len == 0 and !self.stopping) _ = std.c.pthread_cond_wait(&self.condition, &self.mutex);
            if (self.stopping and self.len == 0) {
                unlock(&self.mutex);
                return;
            }
            const job = self.queue[self.head];
            self.head = (self.head + 1) % queue_capacity;
            self.len -= 1;
            self.running += 1;
            unlock(&self.mutex);
            const cancelled = job.run();
            lock(&self.mutex);
            self.running -= 1;
            self.completed += 1;
            if (cancelled) self.cancelled += 1;
            unlock(&self.mutex);
        }
    }
};
var pool: Pool = .{};

pub const Stats = struct { owners: usize, workers: usize, queued: usize, running: usize, completed: u64, cancelled: u64 };
pub fn stats() Stats {
    lock(&pool.mutex);
    defer unlock(&pool.mutex);
    return .{ .owners = pool.users, .workers = if (pool.users > 0 or pool.stopping) worker_count else 0, .queued = pool.len, .running = pool.running, .completed = pool.completed, .cancelled = pool.cancelled };
}
fn waitDone(task: *work.Task) !void {
    var remaining: usize = 10000;
    while (!task.done.load(.acquire) and remaining > 0) : (remaining -= 1) {
        var delay: std.c.timespec = .{ .sec = 0, .nsec = 100_000 };
        _ = std.c.nanosleep(&delay, null);
    }
    try std.testing.expect(task.done.load(.acquire));
}

test "SSH search executor snapshots own cells graphemes styles and row identity after VT destruction" {
    const a = std.testing.allocator;
    var adapter = try Adapter.init(a, 4, 18);
    _ = try adapter.feed("first \x1b[31m汉🙂é\x1b[0m\r\nsecond\r\nthird");
    var expected = try adapter.searchSnapshot(a);
    defer expected.deinit(a);
    var capture = try adapter.prepareSearch();
    defer capture.deinit();
    _ = try adapter.feed("\x1b[2J\x1b[Hreplacement \x1b[34mblue\x1b[0m\r\nnew");
    try adapter.resize(7, 2);
    try adapter.setScrollbackLimit(1);
    adapter.destroy();
    const cancelled: std.atomic.Value(bool) = .init(false);
    var result = try capture.finish(a, &cancelled);
    defer result.deinit(a);
    try std.testing.expectEqualStrings(expected.text, result.text);
    try std.testing.expectEqual(expected.source_version, result.source_version);
    try std.testing.expectEqualDeep(expected.rows, result.rows);
    try std.testing.expectEqualDeep(expected.spans, result.spans);
}

test "SSH search executor is asynchronous bounded cancelable and drains all owner references" {
    const a = std.testing.allocator;
    const id: OwnerId = .{ .session_id = @fromBackingInt(93), .generation = 7 };
    const live_before = work.live_count.load(.acquire);
    var adapter = try Adapter.init(a, 3, 30);
    defer adapter.destroy();
    _ = try adapter.feed("old hit\r\nsecond hit");
    var owners: [queue_capacity + worker_count + 1]Owner = @splat(.{});
    var tasks: [queue_capacity + worker_count]?*work.Task = @splat(null);
    // With the VT held, begin must still return; CPU workers alone wait for it.
    adapter.mutex.lock();
    var locked = true;
    defer if (locked) adapter.mutex.unlock();
    for (0..worker_count) |i| tasks[i] = try owners[i].begin(&adapter, id);
    var tries: usize = 10000;
    while (stats().running != worker_count and tries > 0) : (tries -= 1) {
        var delay: std.c.timespec = .{ .sec = 0, .nsec = 100_000 };
        _ = std.c.nanosleep(&delay, null);
    }
    try std.testing.expectEqual(worker_count, stats().running);
    try std.testing.expectError(error.WorkerBusy, owners[0].begin(&adapter, id));
    for (worker_count..tasks.len) |i| tasks[i] = try owners[i].begin(&adapter, id);
    try std.testing.expectEqual(queue_capacity, stats().queued);
    try std.testing.expectError(error.WorkerBusy, owners[owners.len - 1].begin(&adapter, id));
    for (&owners) |*owner| owner.cancel();
    adapter.mutex.unlock();
    locked = false;
    for (tasks) |task| if (task) |value| {
        try waitDone(value);
        try std.testing.expect(value.cancelled.load(.acquire));
        value.release();
    };
    for (&owners) |*owner| {
        owner.finish();
        owner.cancel();
        owner.finish();
        owner.deinit();
    }
    const final = stats();
    try std.testing.expectEqual(@as(usize, 0), final.owners);
    try std.testing.expectEqual(@as(usize, 0), final.workers);
    try std.testing.expectEqual(@as(usize, 0), final.queued);
    try std.testing.expectEqual(@as(usize, 0), final.running);
    try std.testing.expectEqual(live_before, work.live_count.load(.acquire));
}

test "SSH search executor completion preserves a coherent older version during new output" {
    const a = std.testing.allocator;
    const id: OwnerId = .{ .session_id = @fromBackingInt(94), .generation = 9 };
    var adapter = try Adapter.init(a, 3, 30);
    defer adapter.destroy();
    _ = try adapter.feed("old hit\r\nsecond");
    var owner: Owner = .{};
    defer {
        owner.finish();
        owner.deinit();
    }
    const task = try owner.begin(&adapter, id);
    defer task.release();
    try waitDone(task);
    _ = try adapter.feed("\r\nlate output");
    var result = task.take() orelse return error.MissingSearchResult;
    defer result.document.deinit(work.allocator);
    try std.testing.expect(result.owner.eql(id));
    try std.testing.expect(std.mem.indexOf(u8, result.document.text, "old hit") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.document.text, "late output") == null);
    try std.testing.expect(result.document.source_version < adapter.snapshot().version);
}

test "SSH search executor cancel and background finish can race before final disposal" {
    const a = std.testing.allocator;
    const id: OwnerId = .{ .session_id = @fromBackingInt(95), .generation = 2 };
    var adapter = try Adapter.init(a, 3, 20);
    defer adapter.destroy();
    var owner: Owner = .{};
    adapter.mutex.lock();
    const task = try owner.begin(&adapter, id);
    defer task.release();
    const Context = struct {
        owner: *Owner,
        entered: std.atomic.Value(bool) = .init(false),
        fn finish(c: *@This()) void {
            c.entered.store(true, .release);
            c.owner.finish();
        }
        fn cancel(c: *@This()) void {
            c.entered.store(true, .release);
            for (0..1000) |_| c.owner.cancel();
        }
    };
    var finish: Context = .{ .owner = &owner };
    var cancel: Context = .{ .owner = &owner };
    const finishing = try std.Thread.spawn(.{}, Context.finish, .{&finish});
    const cancelling = try std.Thread.spawn(.{}, Context.cancel, .{&cancel});
    while (!finish.entered.load(.acquire) or !cancel.entered.load(.acquire)) std.atomic.spinLoopHint();
    adapter.mutex.unlock();
    finishing.join();
    cancelling.join();
    try waitDone(task);
    try std.testing.expect(task.cancelled.load(.acquire));
    owner.cancel();
    owner.finish();
    owner.deinit();
    try std.testing.expectEqual(@as(usize, 0), stats().workers);
}

test "SSH search executor owned capture allocation failures release every allocation" {
    const Case = struct {
        fn capture(a: std.mem.Allocator) !void {
            var adapter = try Adapter.init(std.testing.allocator, 4, 20);
            defer adapter.destroy();
            _ = try adapter.feed("old\r\n汉🙂é\r\nnew");
            adapter.mutex.lock();
            var value = @import("ghostty_search.zig").Prepared.captureWithAllocator(&adapter, a) catch |err| {
                adapter.mutex.unlock();
                return err;
            };
            adapter.mutex.unlock();
            value.deinit();
            var current = try adapter.copyProjection(std.testing.allocator);
            defer current.deinit(std.testing.allocator);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Case.capture, .{});
}
