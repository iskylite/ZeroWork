const std = @import("std");
const transfer = @import("manager.zig");

const FakeEngine = struct {
    allocator: std.mem.Allocator,
    next_id: transfer.EngineJobId = 100,
    opens: std.ArrayList(transfer.EngineJobId) = .empty,
    cancelled: std.ArrayList(transfer.EngineJobId) = .empty,
    paused: std.ArrayList(transfer.EngineJobId) = .empty,
    resumed_from: std.ArrayList(transfer.EngineJobId) = .empty,
    events: std.ArrayList(transfer.EngineProgress) = .empty,
    fail_opens: u8 = 0,
    last_notify_complete: ?bool = null,
    reject_pauses: bool = false,
    resume_capable: bool = false,
    resume_reject: ?anyerror = null,
    resume_same_id: bool = false,

    fn deinit(self: *FakeEngine) void {
        self.opens.deinit(self.allocator);
        self.cancelled.deinit(self.allocator);
        self.paused.deinit(self.allocator);
        self.resumed_from.deinit(self.allocator);
        self.events.deinit(self.allocator);
    }

    fn interface(self: *FakeEngine) transfer.TransferEngine {
        return .{ .ctx = self, .open = open, .cancel = cancel, .pause = pause, .resume_job = resumeJob, .can_resume = canResume, .poll = poll };
    }

    fn push(self: *FakeEngine, event: transfer.EngineProgress) !void {
        try self.events.append(self.allocator, event);
    }

    fn open(ctx: *anyopaque, request: transfer.JobSpec) !transfer.EngineJobId {
        const self: *FakeEngine = @ptrCast(@alignCast(ctx));
        self.last_notify_complete = request.notify_complete;
        if (self.fail_opens > 0) {
            self.fail_opens -= 1;
            return error.Transient;
        }
        const id = self.next_id;
        self.next_id += 1;
        try self.opens.append(self.allocator, id);
        return id;
    }

    fn cancel(ctx: *anyopaque, id: transfer.EngineJobId) void {
        const self: *FakeEngine = @ptrCast(@alignCast(ctx));
        self.cancelled.append(self.allocator, id) catch unreachable;
    }

    fn pause(ctx: *anyopaque, id: transfer.EngineJobId) !void {
        const self: *FakeEngine = @ptrCast(@alignCast(ctx));
        if (self.reject_pauses) return error.UnsupportedPause;
        try self.paused.append(self.allocator, id);
    }

    fn canResume(ctx: *anyopaque, _: transfer.EngineJobId) bool {
        const self: *FakeEngine = @ptrCast(@alignCast(ctx));
        return self.resume_capable;
    }

    fn resumeJob(ctx: *anyopaque, original: transfer.EngineJobId) !transfer.EngineJobId {
        const self: *FakeEngine = @ptrCast(@alignCast(ctx));
        if (!self.resume_capable) return error.UnsupportedResume;
        if (self.resume_reject) |err| return err;
        try self.resumed_from.ensureUnusedCapacity(self.allocator, 1);
        try self.opens.ensureUnusedCapacity(self.allocator, 1);
        const accepted = if (self.resume_same_id) original else self.next_id;
        self.resumed_from.appendAssumeCapacity(original);
        self.opens.appendAssumeCapacity(accepted);
        if (!self.resume_same_id) self.next_id += 1;
        return accepted;
    }

    fn poll(ctx: *anyopaque) ?transfer.EngineProgress {
        const self: *FakeEngine = @ptrCast(@alignCast(ctx));
        if (self.events.items.len == 0) return null;
        return self.events.orderedRemove(0);
    }
};

threadlocal var source_slot: [1][]const u8 = undefined;

test "identical paths on different sessions stay separate and retry cannot retarget" {
    var fake = FakeEngine{ .allocator = std.testing.allocator };
    defer fake.deinit();
    var manager = try transfer.Manager.init(std.testing.allocator, fake.interface(), 1, .{});
    defer manager.deinit();
    var request = spec("same");
    request.session_id = 1;
    const first = try manager.enqueue(request);
    request.session_id = (@as(u64, 1) << 32) + 1;
    const second = try manager.enqueue(request);
    try std.testing.expect(first != second);
    try std.testing.expectEqual(second, try manager.enqueue(request));
    try std.testing.expectError(error.TransferSessionMismatch, manager.validateSession(first, request.session_id));
    try manager.validateSession(second, request.session_id);
    try std.testing.expectError(error.UnknownJob, manager.validateSession(9999, request.session_id));
}
fn spec(source: []const u8) transfer.JobSpec {
    source_slot[0] = source;
    return .{ .direction = .upload, .sources = &source_slot, .remote_dir = "/srv", .local_dir = "/tmp" };
}

test "manager enforces FIFO concurrency and starts next completion" {
    var fake: FakeEngine = .{ .allocator = std.testing.allocator };
    defer fake.deinit();
    var manager = try transfer.Manager.init(std.testing.allocator, fake.interface(), 2, .{});
    defer manager.deinit();

    const first = try manager.enqueue(spec("a"));
    const second = try manager.enqueue(spec("b"));
    const third = try manager.enqueue(spec("c"));
    manager.tick(0);
    try std.testing.expectEqual(@as(usize, 2), fake.opens.items.len);
    try std.testing.expectEqual(transfer.State.running, manager.progress(first).?.state);
    try std.testing.expectEqual(transfer.State.running, manager.progress(second).?.state);
    try std.testing.expectEqual(transfer.State.queued, manager.progress(third).?.state);

    try fake.push(.{ .job = fake.opens.items[0], .done_bytes = 8, .total_bytes = 8, .state = .succeeded, .job_cleanup = .released });
    manager.tick(1);
    try std.testing.expectEqual(@as(usize, 3), fake.opens.items.len);
    try std.testing.expectEqual(transfer.State.succeeded, manager.progress(first).?.state);
    try std.testing.expectEqual(transfer.State.running, manager.progress(third).?.state);
}

test "manager deduplicates active specs but permits terminal reenqueues" {
    var fake: FakeEngine = .{ .allocator = std.testing.allocator };
    defer fake.deinit();
    var manager = try transfer.Manager.init(std.testing.allocator, fake.interface(), 1, .{});
    defer manager.deinit();

    const first = try manager.enqueue(spec("same"));
    try std.testing.expectEqual(first, try manager.enqueue(spec("same")));
    try std.testing.expectEqual(@as(usize, 1), manager.count());
    manager.tick(0);
    try fake.push(.{ .job = fake.opens.items[0], .done_bytes = 1, .total_bytes = 1, .state = .succeeded, .job_cleanup = .released });
    manager.tick(1);
    const replacement = try manager.enqueue(spec("same"));
    try std.testing.expect(replacement != first);
}

test "manager retries only at deterministic deadlines and stops at max attempts" {
    var fake: FakeEngine = .{ .allocator = std.testing.allocator, .fail_opens = 3 };
    defer fake.deinit();
    var manager = try transfer.Manager.init(std.testing.allocator, fake.interface(), 1, .{ .max_attempts = 3, .base_delay_ms = 10, .max_delay_ms = 20 });
    defer manager.deinit();

    const id = try manager.enqueue(spec("retry"));
    manager.tick(100);
    try std.testing.expectEqual(transfer.State.retry_wait, manager.progress(id).?.state);
    try std.testing.expectEqual(@as(u8, 1), manager.progress(id).?.attempt);
    manager.tick(109);
    try std.testing.expectEqual(@as(u8, 1), manager.progress(id).?.attempt);
    manager.tick(110);
    try std.testing.expectEqual(@as(u8, 2), manager.progress(id).?.attempt);
    manager.tick(129);
    try std.testing.expectEqual(@as(u8, 2), manager.progress(id).?.attempt);
    manager.tick(130);
    try std.testing.expectEqual(transfer.State.failed, manager.progress(id).?.state);
    try std.testing.expectEqual(@as(u8, 3), manager.progress(id).?.attempt);
}

test "manager retries retryable engine failures with retained progress" {
    var fake: FakeEngine = .{ .allocator = std.testing.allocator };
    defer fake.deinit();
    var manager = try transfer.Manager.init(std.testing.allocator, fake.interface(), 1, .{ .max_attempts = 2, .base_delay_ms = 5, .max_delay_ms = 5 });
    defer manager.deinit();

    const id = try manager.enqueue(spec("resume"));
    manager.tick(0);
    try fake.push(.{ .job = 100, .done_bytes = 40, .total_bytes = 100, .speed_bps = 20, .state = .running });
    try fake.push(.{ .job = 100, .done_bytes = 40, .total_bytes = 100, .state = .failed, .retryable = true, .job_cleanup = .released });
    manager.tick(1);
    const waiting = manager.progress(id).?;
    try std.testing.expectEqual(transfer.State.retry_wait, waiting.state);
    try std.testing.expectEqual(@as(u64, 40), waiting.done_bytes);
    manager.tick(6);
    try std.testing.expectEqual(transfer.State.running, manager.progress(id).?.state);
    try std.testing.expectEqual(@as(u8, 2), manager.progress(id).?.attempt);
}

test "manager pause and later cancel retain the original quiescent attempt and its data owner" {
    var fake: FakeEngine = .{ .allocator = std.testing.allocator };
    defer fake.deinit();
    var manager = try transfer.Manager.init(std.testing.allocator, fake.interface(), 1, .{});
    defer manager.deinit();

    const id = try manager.enqueue(spec("controls"));
    manager.tick(0);
    try manager.pause(id);
    try manager.pause(id);
    try std.testing.expectEqualSlices(transfer.EngineJobId, &.{100}, fake.paused.items);
    try std.testing.expectEqual(@as(usize, 0), fake.cancelled.items.len);
    try std.testing.expectEqual(transfer.State.pausing, manager.progress(id).?.state);
    try std.testing.expectError(error.CleanupPending, manager.resumeJob(id));
    try std.testing.expectError(error.CleanupPending, manager.retry(id));
    const next = try manager.enqueue(spec("waiting"));
    try fake.push(.{ .job = 100, .done_bytes = 9, .total_bytes = 10, .state = .running });
    manager.tick(1);
    try std.testing.expectEqual(transfer.State.pausing, manager.progress(id).?.state);
    try std.testing.expectEqual(@as(u64, 9), manager.progress(id).?.done_bytes);
    try fake.push(.{ .job = 100, .done_bytes = 9, .total_bytes = 10, .state = .paused, .job_cleanup = .released });
    manager.tick(2);
    try std.testing.expectEqual(transfer.State.paused, manager.progress(id).?.state);
    try std.testing.expect(!manager.canResume(id));
    try std.testing.expectEqual(transfer.State.running, manager.progress(next).?.state);
    try std.testing.expectEqual(@as(usize, 2), fake.opens.items.len);
    try std.testing.expectError(error.UnsupportedResume, manager.resumeJob(id));
    try std.testing.expectEqual(@as(u8, 1), manager.progress(id).?.attempt);
    try manager.cancel(id);
    try manager.cancel(id);
    try std.testing.expectEqualSlices(transfer.EngineJobId, &.{100}, fake.cancelled.items);
    try std.testing.expectEqual(transfer.State.cancelling, manager.progress(id).?.state);
    try std.testing.expectEqual(transfer.JobCleanup.awaiting, manager.progress(id).?.job_cleanup);
    try std.testing.expectError(error.CleanupPending, manager.resumeJob(id));
    try fake.push(.{ .job = 100, .done_bytes = 9, .total_bytes = 10, .state = .cancelled, .job_cleanup = .released });
    manager.tick(3);
    try std.testing.expectEqual(transfer.State.cancelled, manager.progress(id).?.state);
    try std.testing.expectEqual(transfer.JobCleanup.released, manager.progress(id).?.job_cleanup);
    try std.testing.expectError(error.InvalidState, manager.resumeJob(id));
    try std.testing.expectError(error.InvalidState, manager.retry(id));
    try fake.push(.{ .job = 100, .done_bytes = 10, .total_bytes = 10, .state = .succeeded, .job_cleanup = .released });
    manager.tick(4);
    try std.testing.expectEqual(transfer.State.running, manager.progress(next).?.state);
    try std.testing.expectEqual(@as(u64, 0), manager.progress(next).?.done_bytes);
}

test "manager rejects non-monotonic and impossible engine progress" {
    var fake: FakeEngine = .{ .allocator = std.testing.allocator };
    defer fake.deinit();
    var manager = try transfer.Manager.init(std.testing.allocator, fake.interface(), 1, .{});
    defer manager.deinit();

    const id = try manager.enqueue(spec("progress"));
    manager.tick(0);
    try fake.push(.{ .job = 100, .done_bytes = 7, .total_bytes = 10, .state = .running });
    try fake.push(.{ .job = 100, .done_bytes = 6, .total_bytes = 10, .state = .running });
    manager.tick(1);
    try std.testing.expectEqual(transfer.State.cancelling, manager.progress(id).?.state);
    try std.testing.expectEqual(@as(u64, 7), manager.progress(id).?.done_bytes);
    try std.testing.expectEqualSlices(transfer.EngineJobId, &.{100}, fake.cancelled.items);
    try std.testing.expectError(error.CleanupPending, manager.retry(id));
    try fake.push(.{ .job = 100, .done_bytes = 7, .total_bytes = 10, .state = .paused, .job_cleanup = .released });
    manager.tick(2);
    try std.testing.expectEqual(transfer.State.cancelling, manager.progress(id).?.state);
    try std.testing.expectError(error.CleanupPending, manager.retry(id));
    try fake.push(.{ .job = 100, .done_bytes = 7, .total_bytes = 10, .state = .cancelled, .job_cleanup = .released });
    manager.tick(3);
    try std.testing.expectEqual(transfer.State.failed, manager.progress(id).?.state);
    try std.testing.expectEqual(transfer.Failure.protocol, manager.progress(id).?.failure.?);
}

test "manager enqueue releases copied spec if queue allocation fails" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, enqueueWithAllocator, .{});
}

fn enqueueWithAllocator(allocator: std.mem.Allocator) !void {
    var fake: FakeEngine = .{ .allocator = allocator };
    defer fake.deinit();
    var manager = try transfer.Manager.init(allocator, fake.interface(), 1, .{});
    defer manager.deinit();
    _ = try manager.enqueue(spec("owned"));
}

test "manager exposes retry metadata and supports manual retry" {
    var fake: FakeEngine = .{ .allocator = std.testing.allocator };
    defer fake.deinit();
    var manager = try transfer.Manager.init(std.testing.allocator, fake.interface(), 1, .{ .max_attempts = 1 });
    defer manager.deinit();

    const id = try manager.enqueue(spec("manual"));
    manager.tick(0);
    try fake.push(.{ .job = 100, .done_bytes = 2, .total_bytes = 10, .state = .failed, .failure = .timeout, .job_cleanup = .released });
    manager.tick(1);
    try std.testing.expectEqual(transfer.Failure.timeout, manager.progress(id).?.failure.?);
    try manager.retry(id);
    manager.tick(2);
    try std.testing.expectEqual(transfer.State.running, manager.progress(id).?.state);
    try std.testing.expectEqual(@as(u8, 2), manager.progress(id).?.attempt);
}

test "manager validates protocol job specs" {
    var fake: FakeEngine = .{ .allocator = std.testing.allocator };
    defer fake.deinit();
    var manager = try transfer.Manager.init(std.testing.allocator, fake.interface(), 1, .{});
    defer manager.deinit();

    try std.testing.expectError(error.EmptySource, manager.enqueue(spec("")));
    var two = [_][]const u8{ "a", "b" };
    try std.testing.expectError(error.InvalidRename, manager.enqueue(.{
        .direction = .upload,
        .sources = &two,
        .remote_dir = "/srv",
        .local_dir = "/tmp",
        .rename = "one",
    }));
}

test "manager owns enqueued strings" {
    var fake: FakeEngine = .{ .allocator = std.testing.allocator };
    defer fake.deinit();
    var manager = try transfer.Manager.init(std.testing.allocator, fake.interface(), 1, .{});
    defer manager.deinit();

    var path = [_]u8{ 'a', 'b', 'c' };
    const id = try manager.enqueue(spec(path[0..]));
    path[0] = 'z';
    try std.testing.expectEqual(id, try manager.enqueue(spec("abc")));
}

test "manager stopping jobs retain concurrency and cancellation supersedes a queued paused receipt" {
    var fake: FakeEngine = .{ .allocator = std.testing.allocator };
    defer fake.deinit();
    var manager = try transfer.Manager.init(std.testing.allocator, fake.interface(), 1, .{});
    defer manager.deinit();
    const first = try manager.enqueue(spec("first"));
    const second = try manager.enqueue(spec("second"));
    manager.tick(0);
    try manager.pause(first);
    manager.tick(1);
    try std.testing.expectEqual(@as(usize, 1), fake.opens.items.len);
    try std.testing.expectEqual(transfer.State.queued, manager.progress(second).?.state);
    try fake.push(.{ .job = 100, .done_bytes = 4, .total_bytes = 10, .state = .paused, .job_cleanup = .unknown });
    manager.tick(2);
    try std.testing.expectEqual(transfer.State.pausing, manager.progress(first).?.state);
    try std.testing.expectEqual(transfer.JobCleanup.unknown, manager.progress(first).?.job_cleanup);
    try std.testing.expect(!manager.canResume(first));
    try std.testing.expectError(error.CleanupUnknown, manager.resumeJob(first));
    try std.testing.expectError(error.CleanupUnknown, manager.retry(first));
    try manager.cancel(first);
    try manager.cancel(first);
    try std.testing.expectEqualSlices(transfer.EngineJobId, &.{100}, fake.cancelled.items);
    try fake.push(.{ .job = 100, .done_bytes = 4, .total_bytes = 10, .state = .paused, .job_cleanup = .released });
    manager.tick(3);
    try std.testing.expectEqual(transfer.State.cancelling, manager.progress(first).?.state);
    try std.testing.expectEqual(@as(usize, 1), fake.opens.items.len);
    try std.testing.expectError(error.CleanupPending, manager.resumeJob(first));
    try fake.push(.{ .job = 100, .done_bytes = 4, .total_bytes = 10, .state = .cancelled, .job_cleanup = .released });
    manager.tick(4);
    try std.testing.expectEqual(transfer.State.cancelled, manager.progress(first).?.state);
    try std.testing.expectEqual(transfer.State.running, manager.progress(second).?.state);
    try std.testing.expectEqual(@as(usize, 2), fake.opens.items.len);
    try fake.push(.{ .job = 100, .done_bytes = 10, .total_bytes = 10, .state = .succeeded, .job_cleanup = .released });
    manager.tick(5);
    try std.testing.expectEqual(transfer.State.running, manager.progress(second).?.state);
    try std.testing.expectEqual(@as(u64, 0), manager.progress(second).?.done_bytes);
}

test "manager unsupported native pause leaves the original running job untouched" {
    var fake: FakeEngine = .{ .allocator = std.testing.allocator };
    defer fake.deinit();
    var engine = fake.interface();
    engine.pause = null;
    var manager = try transfer.Manager.init(std.testing.allocator, engine, 1, .{});
    defer manager.deinit();
    const running = try manager.enqueue(spec("running"));
    const queued = try manager.enqueue(spec("queued"));
    manager.tick(0);
    try std.testing.expectError(error.UnsupportedPause, manager.pause(running));
    // A routing engine may reject only this backend's original job.
    manager.engine.pause = FakeEngine.pause;
    fake.reject_pauses = true;
    try std.testing.expectError(error.UnsupportedPause, manager.pause(running));
    try std.testing.expectEqual(transfer.State.running, manager.progress(running).?.state);
    try std.testing.expectEqual(transfer.JobCleanup.awaiting, manager.progress(running).?.job_cleanup);
    try std.testing.expectEqual(@as(usize, 0), fake.cancelled.items.len);
    try std.testing.expectEqual(@as(usize, 0), fake.paused.items.len);
    // No engine resources exist for a queued job, so pausing it needs no API.
    try manager.pause(queued);
    try std.testing.expectEqual(transfer.State.paused, manager.progress(queued).?.state);
    try std.testing.expectEqual(transfer.JobCleanup.released, manager.progress(queued).?.job_cleanup);
    try std.testing.expect(manager.canResume(queued));
    try std.testing.expect(!manager.canResume(running));
    try std.testing.expect(!manager.canResume(9999));
    try manager.resumeJob(queued);
    try std.testing.expectEqual(transfer.State.queued, manager.progress(queued).?.state);
}

test "manager unknown failed cleanup prevents retry dedup replacement and budget release" {
    var fake: FakeEngine = .{ .allocator = std.testing.allocator };
    defer fake.deinit();
    var manager = try transfer.Manager.init(std.testing.allocator, fake.interface(), 1, .{ .base_delay_ms = 5 });
    defer manager.deinit();
    const first = try manager.enqueue(spec("failed"));
    const second = try manager.enqueue(spec("next"));
    manager.tick(0);
    try fake.push(.{ .job = 100, .done_bytes = 4, .total_bytes = 10, .state = .failed, .failure = .timeout, .retryable = true, .job_cleanup = .unknown });
    manager.tick(1);
    manager.tick(100);
    try std.testing.expectEqual(transfer.State.failed, manager.progress(first).?.state);
    try std.testing.expectEqual(transfer.JobCleanup.unknown, manager.progress(first).?.job_cleanup);
    try std.testing.expectEqual(@as(usize, 1), fake.opens.items.len);
    try std.testing.expectError(error.CleanupUnknown, manager.retry(first));
    try std.testing.expectEqual(first, try manager.enqueue(spec("failed")));
    try fake.push(.{ .job = 100, .done_bytes = 4, .total_bytes = 10, .state = .failed, .failure = .timeout, .job_cleanup = .released });
    manager.tick(101);
    try std.testing.expectEqual(transfer.JobCleanup.released, manager.progress(first).?.job_cleanup);
    try std.testing.expectEqual(transfer.State.running, manager.progress(second).?.state);
    try manager.retry(first);
    manager.tick(102);
    try std.testing.expectEqual(@as(usize, 2), fake.opens.items.len);
    try fake.push(.{ .job = 101, .done_bytes = 1, .total_bytes = 1, .state = .succeeded, .job_cleanup = .released });
    manager.tick(103);
    try std.testing.expectEqual(transfer.State.running, manager.progress(first).?.state);
    try std.testing.expectEqual(@as(u8, 2), manager.progress(first).?.attempt);
    try fake.push(.{ .job = 102, .done_bytes = 0, .total_bytes = 10, .state = .running });
    manager.tick(104);
    try std.testing.expectEqual(transfer.State.running, manager.progress(first).?.state);
    try std.testing.expectEqual(@as(u64, 0), manager.progress(first).?.done_bytes);
}

test "manager native completion without a release receipt cannot finish or free its slot" {
    var fake: FakeEngine = .{ .allocator = std.testing.allocator };
    defer fake.deinit();
    var manager = try transfer.Manager.init(std.testing.allocator, fake.interface(), 1, .{});
    defer manager.deinit();
    const first = try manager.enqueue(spec("complete"));
    const second = try manager.enqueue(spec("waiting"));
    manager.tick(0);
    // The default is deliberately awaiting, including a business terminal.
    try fake.push(.{ .job = 100, .done_bytes = 10, .total_bytes = 10, .state = .succeeded });
    manager.tick(1);
    try std.testing.expectEqual(transfer.State.running, manager.progress(first).?.state);
    try std.testing.expectEqual(@as(usize, 1), fake.opens.items.len);
    try fake.push(.{ .job = 100, .done_bytes = 10, .total_bytes = 10, .state = .succeeded, .job_cleanup = .unknown });
    manager.tick(2);
    try std.testing.expectError(error.CleanupUnknown, manager.retry(first));
    try std.testing.expectEqual(transfer.State.queued, manager.progress(second).?.state);
    try fake.push(.{ .job = 100, .done_bytes = 10, .total_bytes = 10, .state = .succeeded, .job_cleanup = .released });
    manager.tick(3);
    try std.testing.expectEqual(transfer.State.succeeded, manager.progress(first).?.state);
    try std.testing.expectEqual(transfer.State.running, manager.progress(second).?.state);
}

test "manager manual retries never reuse or overflow an attempt number" {
    var fake: FakeEngine = .{ .allocator = std.testing.allocator };
    defer fake.deinit();
    var manager = try transfer.Manager.init(std.testing.allocator, fake.interface(), 1, .{ .max_attempts = 1 });
    defer manager.deinit();
    const id = try manager.enqueue(spec("bounded-attempts"));
    for (0..std.math.maxInt(u8)) |index| {
        manager.tick(index);
        try std.testing.expectEqual(@as(u8, @intCast(index + 1)), manager.progress(id).?.attempt);
        try fake.push(.{ .job = fake.opens.items[index], .done_bytes = 0, .total_bytes = 0, .state = .failed, .job_cleanup = .released });
        manager.tick(index);
        if (index + 1 < std.math.maxInt(u8)) try manager.retry(id);
    }
    try std.testing.expectError(error.AttemptExhausted, manager.retry(id));
    try std.testing.expectEqual(@as(u8, 255), manager.progress(id).?.attempt);
}

test "manager native resume is queued within FIFO budget and queued pause cancel keep the old entity" {
    var fake: FakeEngine = .{ .allocator = std.testing.allocator, .resume_capable = true };
    defer fake.deinit();
    var manager = try transfer.Manager.init(std.testing.allocator, fake.interface(), 1, .{});
    defer manager.deinit();
    const first = try manager.enqueue(spec("retained"));
    const second = try manager.enqueue(spec("running"));
    manager.tick(0);
    try manager.pause(first);
    try fake.push(.{ .job = 100, .done_bytes = 4, .total_bytes = 10, .state = .paused, .job_cleanup = .released });
    manager.tick(1);
    try std.testing.expect(manager.canResume(first));
    try std.testing.expectEqual(transfer.State.running, manager.progress(second).?.state);
    try manager.resumeJob(first);
    manager.tick(2);
    try std.testing.expectEqual(transfer.State.queued, manager.progress(first).?.state);
    try std.testing.expectEqual(@as(u8, 1), manager.progress(first).?.attempt);
    try std.testing.expectEqual(@as(usize, 2), fake.opens.items.len);
    try std.testing.expectEqual(@as(usize, 0), fake.resumed_from.items.len);
    // Duplicate old receipts cannot revoke the original queued intention.
    try fake.push(.{ .job = 100, .done_bytes = 4, .total_bytes = 10, .state = .paused, .job_cleanup = .released });
    manager.tick(3);
    try std.testing.expectEqual(transfer.State.queued, manager.progress(first).?.state);
    // Unknown ownership blocks that intention until a new explicit action.
    try fake.push(.{ .job = 100, .done_bytes = 4, .total_bytes = 10, .state = .paused, .job_cleanup = .unknown });
    manager.tick(4);
    try std.testing.expect(!manager.canResume(first));
    try std.testing.expectEqual(@as(usize, 0), fake.resumed_from.items.len);
    try fake.push(.{ .job = 100, .done_bytes = 4, .total_bytes = 10, .state = .paused, .job_cleanup = .released });
    manager.tick(5);
    try std.testing.expectEqual(transfer.State.paused, manager.progress(first).?.state);
    try manager.resumeJob(first);
    try manager.pause(first);
    try std.testing.expectEqual(transfer.State.paused, manager.progress(first).?.state);
    try std.testing.expectEqualSlices(transfer.EngineJobId, &.{100}, fake.paused.items);
    try manager.resumeJob(first);
    try manager.cancel(first);
    try std.testing.expectEqualSlices(transfer.EngineJobId, &.{100}, fake.cancelled.items);
    try fake.push(.{ .job = 100, .done_bytes = 4, .total_bytes = 10, .state = .cancelled, .job_cleanup = .released });
    manager.tick(6);
    try std.testing.expectEqual(transfer.State.cancelled, manager.progress(first).?.state);
    try std.testing.expectEqual(@as(usize, 0), fake.resumed_from.items.len);
    try std.testing.expectEqual(transfer.State.running, manager.progress(second).?.state);
}

test "manager accepted resume hands off exact old ID and ignores retired attempt events" {
    var fake: FakeEngine = .{ .allocator = std.testing.allocator, .resume_capable = true };
    defer fake.deinit();
    var manager = try transfer.Manager.init(std.testing.allocator, fake.interface(), 1, .{});
    defer manager.deinit();
    const id = try manager.enqueue(spec("handoff"));
    manager.tick(0);
    try manager.pause(id);
    try fake.push(.{ .job = 100, .done_bytes = 4, .total_bytes = 10, .state = .paused, .job_cleanup = .released });
    manager.tick(1);
    try manager.resumeJob(id);
    try std.testing.expectEqual(@as(usize, 1), fake.opens.items.len);
    try std.testing.expectEqual(@as(u8, 1), manager.progress(id).?.attempt);
    manager.tick(2);
    try std.testing.expectEqual(@as(usize, 1), manager.count());
    try std.testing.expectEqualSlices(transfer.EngineJobId, &.{100}, fake.resumed_from.items);
    try std.testing.expectEqual(@as(u8, 2), manager.progress(id).?.attempt);
    try std.testing.expectEqual(transfer.State.running, manager.progress(id).?.state);
    try std.testing.expectEqual(transfer.JobCleanup.awaiting, manager.progress(id).?.job_cleanup);
    try fake.push(.{ .job = 100, .done_bytes = 10, .total_bytes = 10, .state = .succeeded, .job_cleanup = .released });
    try fake.push(.{ .job = 101, .done_bytes = 4, .total_bytes = 10, .state = .running });
    manager.tick(3);
    try std.testing.expectEqual(transfer.State.running, manager.progress(id).?.state);
    try std.testing.expectEqual(@as(u64, 4), manager.progress(id).?.done_bytes);
    try fake.push(.{ .job = 101, .done_bytes = 4, .total_bytes = 10, .state = .paused, .failure = .conflict, .job_cleanup = .released });
    manager.tick(4);
    try std.testing.expectEqual(transfer.State.paused, manager.progress(id).?.state);
    try std.testing.expectEqual(transfer.Failure.conflict, manager.progress(id).?.failure.?);
    try manager.cancel(id);
    try std.testing.expectEqualSlices(transfer.EngineJobId, &.{101}, fake.cancelled.items);
    try fake.push(.{ .job = 101, .done_bytes = 4, .total_bytes = 10, .state = .cancelled, .job_cleanup = .released });
    manager.tick(5);
    try std.testing.expectEqual(transfer.State.cancelled, manager.progress(id).?.state);
}

test "manager native resume capability and synchronous refusal retain original paused ownership" {
    var fake: FakeEngine = .{ .allocator = std.testing.allocator, .resume_capable = true };
    defer fake.deinit();
    var manager = try transfer.Manager.init(std.testing.allocator, fake.interface(), 1, .{});
    defer manager.deinit();
    const id = try manager.enqueue(spec("refused"));
    manager.tick(0);
    try manager.pause(id);
    try fake.push(.{ .job = 100, .done_bytes = 4, .total_bytes = 10, .state = .paused, .job_cleanup = .released });
    manager.tick(1);
    manager.engine.resume_job = null;
    try std.testing.expect(!manager.canResume(id));
    try std.testing.expectError(error.UnsupportedResume, manager.resumeJob(id));
    manager.engine.resume_job = FakeEngine.resumeJob;
    manager.engine.can_resume = null;
    try std.testing.expect(!manager.canResume(id));
    try std.testing.expectError(error.UnsupportedResume, manager.resumeJob(id));
    manager.engine.can_resume = FakeEngine.canResume;
    fake.resume_capable = false;
    try std.testing.expectError(error.UnsupportedResume, manager.resumeJob(id));
    fake.resume_capable = true;
    try manager.resumeJob(id);
    // The captured proxy may lose capability after it was queued.
    fake.resume_reject = error.UnsupportedResume;
    manager.tick(2);
    try std.testing.expectEqual(transfer.State.paused, manager.progress(id).?.state);
    try std.testing.expectEqual(transfer.Failure.invalid_request, manager.progress(id).?.failure.?);
    try std.testing.expectEqual(@as(u8, 1), manager.progress(id).?.attempt);
    try std.testing.expectEqual(@as(usize, 1), fake.opens.items.len);
    try std.testing.expectEqual(@as(usize, 0), fake.resumed_from.items.len);
    fake.resume_reject = error.OutOfMemory;
    try manager.resumeJob(id);
    manager.tick(3);
    try std.testing.expectEqual(transfer.State.paused, manager.progress(id).?.state);
    try std.testing.expectEqual(@as(u8, 1), manager.progress(id).?.attempt);
    try std.testing.expectEqual(@as(usize, 1), fake.opens.items.len);
    try manager.cancel(id);
    try std.testing.expectEqualSlices(transfer.EngineJobId, &.{100}, fake.cancelled.items);
    try fake.push(.{ .job = 100, .done_bytes = 4, .total_bytes = 10, .state = .cancelled, .job_cleanup = .released });
    manager.tick(4);
    try std.testing.expectEqual(transfer.State.cancelled, manager.progress(id).?.state);
}

test "manager ambiguous resumed ID quarantines ownership without replacement opens" {
    var fake: FakeEngine = .{ .allocator = std.testing.allocator, .resume_capable = true, .resume_same_id = true };
    defer fake.deinit();
    var manager = try transfer.Manager.init(std.testing.allocator, fake.interface(), 1, .{});
    defer manager.deinit();
    const id = try manager.enqueue(spec("ambiguous"));
    manager.tick(0);
    try manager.pause(id);
    try fake.push(.{ .job = 100, .done_bytes = 4, .total_bytes = 10, .state = .paused, .job_cleanup = .released });
    manager.tick(1);
    try manager.resumeJob(id);
    manager.tick(2);
    try std.testing.expectEqual(transfer.State.cancelling, manager.progress(id).?.state);
    try std.testing.expectEqual(transfer.JobCleanup.unknown, manager.progress(id).?.job_cleanup);
    try std.testing.expectEqual(transfer.Failure.protocol, manager.progress(id).?.failure.?);
    try std.testing.expectEqual(@as(u8, 1), manager.progress(id).?.attempt);
    try std.testing.expectEqualSlices(transfer.EngineJobId, &.{100}, fake.cancelled.items);
    try std.testing.expectEqual(id, try manager.enqueue(spec("ambiguous")));
    try std.testing.expectError(error.CleanupUnknown, manager.retry(id));
    manager.tick(3);
    try std.testing.expectEqual(@as(usize, 2), fake.opens.items.len);
    try std.testing.expectEqual(@as(usize, 1), fake.resumed_from.items.len);
    try fake.push(.{ .job = 100, .done_bytes = 4, .total_bytes = 10, .state = .cancelled, .job_cleanup = .released });
    manager.tick(4);
    try std.testing.expectEqual(transfer.State.failed, manager.progress(id).?.state);
}

test "checksum diagnostics belong to current attempt and reset only on accepted new attempt" {
    var fake: FakeEngine = .{ .allocator = std.testing.allocator };
    defer fake.deinit();
    var manager = try transfer.Manager.init(std.testing.allocator, fake.interface(), 1, .{});
    defer manager.deinit();
    const id = try manager.enqueue(spec("verified-source"));
    manager.tick(0);
    const first = fake.opens.items[0];
    const evidence: transfer.Verification = .{ .state = .repairing, .source_md5 = @splat(1), .target_md5 = @splat(2), .repair_count = 1, .repair_start = 32768, .repair_end = 40000 };
    try fake.push(.{ .job = first, .state = .running, .done_bytes = 40000, .total_bytes = 40000, .verification = evidence });
    manager.tick(1);
    try std.testing.expectEqualDeep(evidence, manager.progress(id).?.verification.?);
    try fake.push(.{ .job = first, .state = .failed, .done_bytes = 40000, .total_bytes = 40000, .failure = .connection, .job_cleanup = .released, .verification = evidence });
    manager.tick(2);
    try manager.retry(id);
    try std.testing.expectEqualDeep(evidence, manager.progress(id).?.verification.?);
    manager.tick(3);
    try std.testing.expect(manager.progress(id).?.verification == null);
    try fake.push(.{ .job = first, .state = .succeeded, .done_bytes = 40000, .total_bytes = 40000, .job_cleanup = .released, .verification = .{ .state = .passed } });
    manager.tick(4);
    try std.testing.expect(manager.progress(id).?.verification == null);
    try std.testing.expectEqual(transfer.State.running, manager.progress(id).?.state);
}

test "checksum failure cannot bypass a new review through ordinary retry" {
    var fake: FakeEngine = .{ .allocator = std.testing.allocator };
    defer fake.deinit();
    var manager = try transfer.Manager.init(std.testing.allocator, fake.interface(), 1, .{});
    defer manager.deinit();
    const id = try manager.enqueue(spec("checksum-source"));
    manager.tick(0);
    try fake.push(.{ .job = fake.opens.items[0], .state = .failed, .done_bytes = 10, .total_bytes = 10, .failure = .checksum, .job_cleanup = .released, .verification = .{ .state = .failed, .repair_count = 1 } });
    manager.tick(1);
    try std.testing.expectError(error.ReviewRequired, manager.retry(id));
    manager.tick(2);
    try std.testing.expectEqual(@as(usize, 1), fake.opens.items.len);
    try std.testing.expectEqual(transfer.State.failed, manager.progress(id).?.state);
    try std.testing.expectEqual(@as(u8, 1), manager.progress(id).?.verification.?.repair_count);
}

test "skipped bytes complete a batch without becoming transferred bytes" {
    var fake: FakeEngine = .{ .allocator = std.testing.allocator };
    defer fake.deinit();
    var manager = try transfer.Manager.init(std.testing.allocator, fake.interface(), 1, .{});
    defer manager.deinit();
    const id = try manager.enqueue(spec("mixed-batch"));
    manager.tick(0);
    const engine_id = fake.opens.items[0];
    try fake.push(.{ .job = engine_id, .state = .running, .done_bytes = 3, .total_bytes = 10, .conflict_waiting = true });
    manager.tick(1);
    try std.testing.expect(manager.progress(id).?.conflict_waiting);
    try fake.push(.{ .job = engine_id, .state = .succeeded, .done_bytes = 3, .total_bytes = 10, .skipped_bytes = 7, .skipped_files = 1, .job_cleanup = .released });
    manager.tick(2);
    const result = manager.progress(id).?;
    try std.testing.expectEqual(transfer.State.succeeded, result.state);
    try std.testing.expectEqual(@as(u64, 3), result.done_bytes);
    try std.testing.expectEqual(@as(u64, 7), result.skipped_bytes);
    try std.testing.expectEqual(@as(u32, 1), result.skipped_files);
    try std.testing.expect(!result.conflict_waiting);
}

test "invalid skip accounting and unresolved success quarantine the engine job" {
    const cases = [_]transfer.EngineProgress{
        .{ .job = 100, .state = .succeeded, .done_bytes = 9, .total_bytes = 10, .skipped_bytes = 2 },
        .{ .job = 100, .state = .succeeded, .done_bytes = std.math.maxInt(u64), .total_bytes = std.math.maxInt(u64), .skipped_bytes = 1 },
        .{ .job = 100, .state = .succeeded, .done_bytes = 10, .total_bytes = 10, .conflict_waiting = true },
    };
    for (cases) |event| {
        var fake: FakeEngine = .{ .allocator = std.testing.allocator };
        defer fake.deinit();
        var manager = try transfer.Manager.init(std.testing.allocator, fake.interface(), 1, .{});
        defer manager.deinit();
        const id = try manager.enqueue(spec("invalid-skip"));
        manager.tick(0);
        try fake.push(event);
        manager.tick(1);
        try std.testing.expectEqual(transfer.State.cancelling, manager.progress(id).?.state);
        try std.testing.expectEqual(transfer.Failure.protocol, manager.progress(id).?.failure.?);
        try std.testing.expectEqualSlices(transfer.EngineJobId, &.{100}, fake.cancelled.items);
    }
}

test "conflict requests cannot reach an inactive or unrelated job" {
    var fake: FakeEngine = .{ .allocator = std.testing.allocator };
    defer fake.deinit();
    var manager = try transfer.Manager.init(std.testing.allocator, fake.interface(), 1, .{});
    defer manager.deinit();
    try std.testing.expectError(error.UnknownJob, manager.conflictSnapshot(std.testing.allocator, 77));
    const id = try manager.enqueue(spec("conflict-guard"));
    try std.testing.expect(try manager.conflictSnapshot(std.testing.allocator, id) == null);
    manager.tick(0);
    const request: transfer.Conflict.Request = .{ .select = .{
        .key = .{ .intent_id = 1, .owner = .{ .session = .{ .session_id = @fromBackingInt(@intCast(1)), .generation = 1 } }, .original_owner = .{ .session_id = @fromBackingInt(@intCast(1)), .generation = 1 }, .entry = 0, .job = id, .attempt = 1, .revision = 1 },
        .selection = .{ .choice = .skip },
    } };
    try std.testing.expectError(error.StaleConflict, manager.resolveConflict(id, request));
}

test "retained checkpoint waits for explicit authentication and budget without falling back to open" {
    var fake: FakeEngine = .{ .allocator = std.testing.allocator };
    defer fake.deinit();
    var manager = try transfer.Manager.init(std.testing.allocator, fake.interface(), 1, .{});
    defer manager.deinit();
    const request: transfer.JobSpec = .{ .session_id = 101, .direction = .download, .sources = &.{"/srv/retained"}, .remote_dir = "/srv", .local_dir = "/tmp", .notify_complete = false };
    const id = try manager.enqueue(request);
    manager.tick(0);
    try manager.pause(id);
    try fake.push(.{ .job = 100, .state = .paused, .done_bytes = 4, .total_bytes = 10, .job_cleanup = .released });
    manager.tick(1);
    const owner: @import("../host/identity.zig").TransferOwner = .{ .id = @fromBackingInt(7), .original_handle = .{ .session_id = @fromBackingInt(101), .generation = 2 } };
    try manager.retainPaused(id, 1, 100, owner);
    try std.testing.expect(manager.engineJob(id) == null);
    try std.testing.expectEqualDeep(owner, manager.retainedOwner(id).?);
    try std.testing.expectError(error.RetainedAuthenticationRequired, manager.resumeJob(id));
    try manager.queueRetainedResume(id, 1, owner);
    manager.tick(2);
    // Failed/cancelled authentication never spends an attempt or opens IO.
    try manager.pause(id);
    try std.testing.expectEqual(transfer.State.paused, manager.progress(id).?.state);
    try std.testing.expectEqual(@as(u8, 1), manager.progress(id).?.attempt);
    try std.testing.expect(manager.engineJob(id) == null);
    try std.testing.expectEqualStrings(request.local_dir, manager.retainedSpec(id, 1).?.local_dir);
    try manager.queueRetainedResume(id, 1, owner);
    try std.testing.expectEqual(@as(usize, 1), fake.opens.items.len);
    try std.testing.expect(manager.canAcceptRetainedResume(id, 1));
    _ = try manager.enqueue(spec("sibling"));
    manager.tick(3);
    try std.testing.expect(!manager.canAcceptRetainedResume(id, 1));
    try fake.push(.{ .job = 101, .state = .succeeded, .done_bytes = 10, .total_bytes = 10, .job_cleanup = .released });
    manager.tick(4);
    try std.testing.expect(manager.canAcceptRetainedResume(id, 1));
    var imported = request;
    imported.transfer_binding = .{ .resource_owner = .{ .retained_transfer = owner.id }, .origin_session = owner.original_handle, .kind = .transfer, .binding_id = 77, .binding_generation = 1 };
    var wrong = imported;
    wrong.local_dir = "/other";
    try std.testing.expectError(error.RetainedSourceChanged, manager.validateRetainedResume(id, 1, wrong));
    wrong = imported;
    wrong.chunk_kb = 48;
    try std.testing.expectError(error.RetainedSourceChanged, manager.validateRetainedResume(id, 1, wrong));
    wrong = imported;
    wrong.window_chunks = 7;
    try std.testing.expectError(error.RetainedSourceChanged, manager.validateRetainedResume(id, 1, wrong));
    wrong = imported;
    wrong.notify_complete = true;
    try std.testing.expectError(error.RetainedSourceChanged, manager.validateRetainedResume(id, 1, wrong));
    try std.testing.expect(!manager.retainedSpec(id, 1).?.notify_complete);
    wrong = imported;
    wrong.local_dir = "/other";
    try manager.validateRetainedResume(id, 1, imported);
    try std.testing.expect(manager.engineJob(id) == null);
    try std.testing.expectEqual(@as(u8, 1), manager.progress(id).?.attempt);
    try std.testing.expectError(error.RetainedSourceChanged, manager.acceptRetainedResume(id, 1, wrong, 500));
    try std.testing.expectEqual(@as(u8, 1), manager.progress(id).?.attempt);
    try manager.acceptRetainedResume(id, 1, imported, 500);
    try std.testing.expectEqual(@as(u8, 2), manager.progress(id).?.attempt);
    try std.testing.expectEqual(transfer.State.running, manager.progress(id).?.state);
    try std.testing.expectEqual(@as(?u64, 500), manager.engineJob(id));
    try fake.push(.{ .job = 100, .state = .cancelled, .done_bytes = 4, .total_bytes = 10, .job_cleanup = .released });
    manager.tick(5);
    try std.testing.expectEqual(transfer.State.running, manager.progress(id).?.state);
    try std.testing.expectEqual(@as(usize, 2), fake.opens.items.len);
}

test "retained cancellation waits for its checkpoint cleanup receipt" {
    var fake: FakeEngine = .{ .allocator = std.testing.allocator };
    defer fake.deinit();
    var manager = try transfer.Manager.init(std.testing.allocator, fake.interface(), 1, .{});
    defer manager.deinit();
    var request = spec("retained-cancel");
    request.session_id = 101;
    const id = try manager.enqueue(request);
    manager.tick(0);
    const owner: @import("../host/identity.zig").TransferOwner = .{ .id = @fromBackingInt(8), .original_handle = .{ .session_id = @fromBackingInt(101) } };
    try std.testing.expectError(error.CheckpointNotReleased, manager.retainPaused(id, 1, 100, owner));
    try manager.pause(id);
    try fake.push(.{ .job = 100, .state = .paused, .done_bytes = 4, .total_bytes = 10, .job_cleanup = .released });
    manager.tick(1);
    try manager.retainPaused(id, 1, 100, owner);
    try std.testing.expectError(error.RetainedCleanupRequired, manager.cancel(id));
    try std.testing.expectEqual(@as(usize, 0), fake.cancelled.items.len);
    try manager.retainedCancelReceipt(id, 1, owner, .unknown);
    try manager.retainedCancelReceipt(id, 1, owner, .awaiting);
    try std.testing.expectEqual(transfer.JobCleanup.unknown, manager.progress(id).?.job_cleanup);
    try std.testing.expectEqual(transfer.State.cancelling, manager.progress(id).?.state);
    try manager.retainedCancelReceipt(id, 1, owner, .released);
    try std.testing.expectEqual(transfer.State.cancelled, manager.progress(id).?.state);
    try std.testing.expectError(error.StaleAttempt, manager.retainedCancelReceipt(id, 1, owner, .released));
}

test "connection wait preserves queued intent and budget until its exact binding is ready" {
    var fake: FakeEngine = .{ .allocator = std.testing.allocator };
    defer fake.deinit();
    var manager = try transfer.Manager.init(std.testing.allocator, fake.interface(), 1, .{});
    defer manager.deinit();
    var request = spec("waiting-auth");
    request.transfer_binding = .{ .resource_owner = .{ .session = .{ .session_id = @fromBackingInt(71), .generation = 1 } }, .kind = .transfer, .binding_id = 90, .binding_generation = 1 };
    const waiting = try manager.enqueueWaitingBinding(request);
    const sibling = try manager.enqueue(spec("ready-sibling"));
    manager.tick(0);
    try std.testing.expectEqual(transfer.State.queued, manager.progress(waiting).?.state);
    try std.testing.expectEqual(@as(u8, 0), manager.progress(waiting).?.attempt);
    try std.testing.expectEqual(transfer.State.running, manager.progress(sibling).?.state);
    try std.testing.expectEqual(@as(usize, 1), fake.opens.items.len);
    var stale = request.transfer_binding.?;
    stale.binding_generation += 1;
    try std.testing.expectError(error.StaleBinding, manager.releaseBindingWait(waiting, stale));
    try manager.pause(waiting);
    try manager.releaseBindingWait(waiting, request.transfer_binding.?);
    try fake.push(.{ .job = 100, .state = .succeeded, .done_bytes = 10, .total_bytes = 10, .job_cleanup = .released });
    manager.tick(1);
    try std.testing.expectEqual(transfer.State.paused, manager.progress(waiting).?.state);
    try std.testing.expectEqual(@as(usize, 1), fake.opens.items.len);
    try manager.resumeJob(waiting);
    manager.tick(2);
    try std.testing.expectEqual(transfer.State.running, manager.progress(waiting).?.state);
    try std.testing.expectEqual(@as(u8, 1), manager.progress(waiting).?.attempt);
    try std.testing.expectEqual(@as(usize, 2), fake.opens.items.len);
}

test "failed authentication rebinds only the unstarted original intent without spending an attempt" {
    var fake: FakeEngine = .{ .allocator = std.testing.allocator };
    defer fake.deinit();
    var manager = try transfer.Manager.init(std.testing.allocator, fake.interface(), 1, .{});
    defer manager.deinit();
    const owner: @import("../host/identity.zig").SessionHandle = .{ .session_id = @fromBackingInt(71), .generation = 1 };
    var request = spec("original-draft");
    request.session_id = 71;
    request.transfer_binding = .{ .resource_owner = .{ .session = owner }, .origin_session = owner, .kind = .transfer, .binding_id = 90, .binding_generation = 1 };
    const id = try manager.enqueueWaitingBinding(request);
    manager.tick(0);
    try manager.pause(id);
    var next = request.transfer_binding.?;
    next.binding_id = 91;
    next.binding_generation = 2;
    var foreign = next;
    foreign.resource_owner = .{ .session = .{ .session_id = @fromBackingInt(72), .generation = 1 } };
    try std.testing.expectError(error.TransferOwnerMismatch, manager.rebindWaitingDraft(id, foreign));
    try std.testing.expect(manager.transferBinding(id).?.eql(request.transfer_binding.?));
    // The old connection became ready while this draft remained paused.
    try manager.releaseBindingWait(id, request.transfer_binding.?);
    try manager.rebindWaitingDraft(id, next);
    manager.tick(1);
    try std.testing.expectEqual(transfer.State.queued, manager.progress(id).?.state);
    try std.testing.expectEqual(@as(u8, 0), manager.progress(id).?.attempt);
    try std.testing.expectEqual(@as(usize, 0), fake.opens.items.len);
    try std.testing.expectError(error.StaleBinding, manager.releaseBindingWait(id, request.transfer_binding.?));
    try manager.releaseBindingWait(id, next);
    manager.tick(2);
    try std.testing.expectEqual(transfer.State.running, manager.progress(id).?.state);
    try std.testing.expectEqual(@as(u8, 1), manager.progress(id).?.attempt);
    try std.testing.expectEqual(@as(usize, 1), fake.opens.items.len);
    try std.testing.expectError(error.InvalidState, manager.rebindWaitingDraft(id, next));
}

test "manager freezes logical window policy and does not deduplicate a different policy" {
    var fake: FakeEngine = .{ .allocator = std.testing.allocator };
    defer fake.deinit();
    var manager = try transfer.Manager.init(std.testing.allocator, fake.interface(), 3, .{});
    defer manager.deinit();
    var request = spec("policy");
    request.chunk_kb = 48;
    request.window_chunks = 7;
    request.pacing_kbps = 1024;
    const first = try manager.enqueue(request);
    const frozen = manager.jobs.items[0].spec;
    try std.testing.expectEqual(@as(u16, 48), frozen.chunk_kb);
    try std.testing.expectEqual(@as(u8, 7), frozen.window_chunks);
    try std.testing.expectEqual(@as(u32, 1024), frozen.pacing_kbps);
    try std.testing.expectEqual(first, try manager.enqueue(request));
    request.chunk_kb = 96;
    const second = try manager.enqueue(request);
    request.window_chunks = 1;
    const third = try manager.enqueue(request);
    request.pacing_kbps = 2048;
    const fourth = try manager.enqueue(request);
    try std.testing.expect(first != second and first != third and second != third);
    try std.testing.expect(fourth != first and fourth != second and fourth != third);
    try std.testing.expectEqual(@as(u32, 1024), manager.jobs.items[0].spec.pacing_kbps);
    try std.testing.expectEqual(@as(u16, 48), manager.jobs.items[0].spec.chunk_kb);
    try std.testing.expectEqual(@as(u8, 7), manager.jobs.items[0].spec.window_chunks);
}

test "manager window budget rejects a new intent before it consumes an ID or calls the engine" {
    var fake: FakeEngine = .{ .allocator = std.testing.allocator };
    defer fake.deinit();
    var manager = try transfer.Manager.init(std.testing.allocator, fake.interface(), 3, .{});
    defer manager.deinit();
    var request = spec("budget");
    request.chunk_kb = 2049;
    request.window_chunks = 1;
    try std.testing.expectError(error.TransferWindowBudgetExceeded, manager.enqueue(request));
    request.chunk_kb = 0;
    try std.testing.expectError(error.InvalidTransferChunk, manager.enqueue(request));
    request.chunk_kb = 64;
    request.window_chunks = 0;
    try std.testing.expectError(error.InvalidTransferWindow, manager.enqueue(request));
    request.window_chunks = 16;
    manager.concurrency = 7;
    try std.testing.expectError(error.TransferGlobalWindowBudgetExceeded, manager.enqueue(request));
    try std.testing.expectEqual(@as(u64, 1), manager.next_id);
    try std.testing.expectEqual(@as(usize, 0), manager.count());
    try std.testing.expectEqual(@as(usize, 0), fake.opens.items.len);
}

test "manager window budget uses frozen active policies after concurrency changes and holds unknown IO" {
    var fake: FakeEngine = .{ .allocator = std.testing.allocator };
    defer fake.deinit();
    var manager = try transfer.Manager.init(std.testing.allocator, fake.interface(), 3, .{});
    defer manager.deinit();
    var ids: [4]transfer.JobId = undefined;
    for ([_][]const u8{ "large-a", "large-b", "large-c", "large-d" }, 0..) |source, i| {
        var request = spec(source);
        request.chunk_kb = 2048;
        request.window_chunks = 1;
        ids[i] = try manager.enqueue(request);
    }
    manager.tick(0);
    try std.testing.expectEqual(@as(usize, 3), fake.opens.items.len);
    manager.concurrency = 6; // Current settings may now use 64 x 16 x 6.
    var small = spec("small-new-policy");
    small.chunk_kb = 1;
    small.window_chunks = 1;
    const small_id = try manager.enqueue(small);
    try fake.push(.{ .job = 100, .state = .failed, .done_bytes = 1, .total_bytes = 10, .job_cleanup = .unknown });
    manager.tick(1);
    try std.testing.expectEqual(@as(usize, 3), fake.opens.items.len);
    try std.testing.expectEqual(transfer.State.queued, manager.progress(ids[3]).?.state);
    try std.testing.expectEqual(@as(u8, 0), manager.progress(ids[3]).?.attempt);
    try std.testing.expectEqual(transfer.State.queued, manager.progress(small_id).?.state);
    try fake.push(.{ .job = 100, .state = .failed, .done_bytes = 1, .total_bytes = 10, .job_cleanup = .released });
    manager.tick(2);
    try std.testing.expectEqual(@as(usize, 4), fake.opens.items.len);
    try std.testing.expectEqual(transfer.State.running, manager.progress(ids[3]).?.state);
    try std.testing.expectEqual(transfer.State.queued, manager.progress(small_id).?.state);
    try fake.push(.{ .job = 101, .state = .succeeded, .done_bytes = 10, .total_bytes = 10, .job_cleanup = .released });
    manager.tick(3);
    try std.testing.expectEqual(@as(usize, 5), fake.opens.items.len);
    try std.testing.expectEqual(transfer.State.running, manager.progress(small_id).?.state);
    try std.testing.expectEqual(@as(u16, 2048), manager.jobs.items[3].spec.chunk_kb);
    try std.testing.expectEqual(@as(u8, 1), manager.jobs.items[3].spec.window_chunks);
}

test "manager window budget gates native and retained resume until actual active IO releases" {
    for ([_]bool{ false, true }) |retain| {
        var fake: FakeEngine = .{ .allocator = std.testing.allocator, .resume_capable = true };
        defer fake.deinit();
        var manager = try transfer.Manager.init(std.testing.allocator, fake.interface(), 3, .{});
        defer manager.deinit();
        var ids: [4]transfer.JobId = undefined;
        for ([_][]const u8{ "resume-original", "running-b", "running-c", "queued-d" }, 0..) |source, i| {
            var request = spec(source);
            request.session_id = 101;
            request.chunk_kb = 2048;
            request.window_chunks = 1;
            ids[i] = try manager.enqueue(request);
        }
        manager.tick(0);
        try manager.pause(ids[0]);
        try fake.push(.{ .job = 100, .state = .paused, .done_bytes = 4, .total_bytes = 10, .job_cleanup = .released });
        manager.tick(1);
        try std.testing.expectEqual(@as(usize, 4), fake.opens.items.len);
        const owner: @import("../host/identity.zig").TransferOwner = .{ .id = @fromBackingInt(7), .original_handle = .{ .session_id = @fromBackingInt(101), .generation = 2 } };
        if (retain) {
            try manager.retainPaused(ids[0], 1, 100, owner);
            try manager.queueRetainedResume(ids[0], 1, owner);
        } else try manager.resumeJob(ids[0]);
        manager.concurrency = 6;
        manager.tick(2);
        try std.testing.expectEqual(@as(usize, 4), fake.opens.items.len);
        try std.testing.expectEqual(@as(u8, 1), manager.progress(ids[0]).?.attempt);
        try std.testing.expectEqual(transfer.State.queued, manager.progress(ids[0]).?.state);
        if (retain) try std.testing.expect(!manager.canAcceptRetainedResume(ids[0], 1));
        try fake.push(.{ .job = 101, .state = .succeeded, .done_bytes = 10, .total_bytes = 10, .job_cleanup = .released });
        manager.tick(3);
        if (retain) {
            try std.testing.expect(manager.canAcceptRetainedResume(ids[0], 1));
            var imported = manager.retainedSpec(ids[0], 1).?;
            imported.transfer_binding = .{ .resource_owner = .{ .retained_transfer = owner.id }, .origin_session = owner.original_handle, .kind = .transfer, .binding_id = 88, .binding_generation = 1 };
            try manager.validateRetainedResume(ids[0], 1, imported);
            try manager.acceptRetainedResume(ids[0], 1, imported, 500);
            try std.testing.expectEqual(@as(usize, 4), fake.opens.items.len);
        } else {
            try std.testing.expectEqual(@as(usize, 5), fake.opens.items.len);
            try std.testing.expectEqualSlices(u64, &.{100}, fake.resumed_from.items);
        }
        try std.testing.expectEqual(@as(u8, 2), manager.progress(ids[0]).?.attempt);
        try std.testing.expectEqual(transfer.State.running, manager.progress(ids[0]).?.state);
    }
}

test "transfer notification choice is held for deduplication and actual retry opens" {
    {
        var fake: FakeEngine = .{ .allocator = std.testing.allocator };
        defer fake.deinit();
        var manager = try transfer.Manager.init(std.testing.allocator, fake.interface(), 1, .{});
        defer manager.deinit();
        var request = spec("notify-dedup");
        request.notify_complete = false;
        const quiet = try manager.enqueue(request);
        try std.testing.expectEqual(quiet, try manager.enqueue(request));
        request.notify_complete = true;
        const audible = try manager.enqueue(request);
        try std.testing.expect(quiet != audible);
    }
    {
        var fake: FakeEngine = .{ .allocator = std.testing.allocator };
        defer fake.deinit();
        var manager = try transfer.Manager.init(std.testing.allocator, fake.interface(), 1, .{ .base_delay_ms = 10 });
        defer manager.deinit();
        var request = spec("notify-retry");
        request.notify_complete = false;
        const id = try manager.enqueue(request);
        request.notify_complete = true;
        manager.tick(0);
        try std.testing.expectEqual(@as(?bool, false), fake.last_notify_complete);
        try fake.push(.{ .job = 100, .state = .failed, .done_bytes = 0, .total_bytes = 10, .retryable = true, .failure = .connection, .job_cleanup = .released });
        manager.tick(1);
        try std.testing.expectEqual(transfer.State.retry_wait, manager.progress(id).?.state);
        manager.tick(11);
        try std.testing.expectEqual(@as(u8, 2), manager.progress(id).?.attempt);
        try std.testing.expectEqual(@as(?bool, false), fake.last_notify_complete);
    }
}

test "event history retains accepted states and ignores progress duplicates and retired attempts" {
    var fake = FakeEngine{ .allocator = std.testing.allocator };
    defer fake.deinit();
    var manager = try transfer.Manager.init(std.testing.allocator, fake.interface(), 1, .{ .base_delay_ms = 1 });
    defer manager.deinit();
    const id = try manager.enqueue(spec("events"));
    try std.testing.expectEqual(@as(usize, 1), manager.eventHistory(id).?.len);
    manager.tick(0);
    const old = fake.opens.items[0];
    try fake.push(.{ .job = old, .done_bytes = 10, .total_bytes = 100, .state = .running });
    try fake.push(.{ .job = old, .done_bytes = 20, .total_bytes = 100, .state = .running });
    manager.tick(1);
    try std.testing.expectEqual(@as(usize, 2), manager.eventHistory(id).?.len);
    try fake.push(.{ .job = old, .done_bytes = 20, .total_bytes = 100, .state = .failed, .failure = .connection, .retryable = true, .job_cleanup = .released });
    manager.tick(2);
    try std.testing.expectEqual(transfer.State.retry_wait, manager.eventHistory(id).?[2].state);
    manager.tick(3);
    const current = fake.opens.items[1];
    try fake.push(.{ .job = old, .done_bytes = 100, .total_bytes = 100, .state = .succeeded, .job_cleanup = .released });
    manager.tick(4);
    try std.testing.expectEqual(@as(usize, 4), manager.eventHistory(id).?.len);
    try fake.push(.{ .job = current, .done_bytes = 100, .total_bytes = 100, .state = .succeeded, .job_cleanup = .released });
    manager.tick(5);
    const last = manager.eventHistory(id).?[4];
    try std.testing.expectEqual(@as(u8, 2), last.attempt);
    try std.testing.expectEqual(transfer.State.succeeded, last.state);
    try std.testing.expectEqual(@as(u64, 100), last.done_bytes);
}

test "event history remains bounded and rejected actions do not invent receipts" {
    var fake = FakeEngine{ .allocator = std.testing.allocator };
    defer fake.deinit();
    var manager = try transfer.Manager.init(std.testing.allocator, fake.interface(), 1, .{});
    defer manager.deinit();
    const id = try manager.enqueue(spec("bounded"));
    for (0..40) |_| {
        try manager.pause(id);
        try manager.resumeJob(id);
    }
    const history = manager.eventHistory(id).?;
    try std.testing.expectEqual(transfer.event_capacity, history.len);
    try std.testing.expect(history[0].sequence > 1);
    const sequence = history[history.len - 1].sequence;
    try std.testing.expectError(error.InvalidState, manager.retry(id));
    try std.testing.expectEqual(sequence, manager.eventHistory(id).?[history.len - 1].sequence);
}
