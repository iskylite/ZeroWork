//! Actual Manager + actual Mux with controlled no-IO engine endpoints. Domain
//! bindings are SessionHost-issued; no native transfer readiness is claimed.
const std = @import("std");
const transfer = @import("transfer/manager.zig");
const module = @import("transfer/engine_dispatch.zig");
const routing = @import("transfer/engine_mux.zig");
const sessions = @import("host/session_host.zig");
const plugins = @import("host/plugin_registry.zig");
const a = std.testing.allocator;
const Adapter = struct {
    fn create(_: *anyopaque, _: sessions.CreateRequest) !void {}
    fn cancel(_: *anyopaque, _: sessions.OperationKey) sessions.CloseReceipt {
        return .released;
    }
    fn close(_: *anyopaque, _: sessions.SessionHandle, _: sessions.OperationKey) !sessions.CloseReceipt {
        return .released;
    }
    fn stale(_: *anyopaque, _: sessions.SessionHandle, _: sessions.OperationKey) void {}
    fn interface(self: *Adapter) sessions.Adapter {
        return .{ .registration = .{ .plugin_id = .sftp, .workspace_kind = .file, .services = plugins.requiredServices(.sftp) }, .context = self, .vtable = &.{ .create = create, .cancel = cancel, .close = close, .release_stale = stale } };
    }
};
fn live(raw: *anyopaque, binding: sessions.ServiceHandle) bool {
    const domain: *sessions.SessionHost = @ptrCast(@alignCast(raw));
    return domain.bindingIsLive(binding);
}
const Backend = struct {
    conflict_seen: ?u64 = null,
    conflict_decision: ?u64 = null,
    conflict_bad_id: bool = false,
    next_id: u64 = 1,
    attempts: usize = 0,
    reject: bool = false,
    last: ?transfer.JobSpec = null,
    events: std.ArrayList(transfer.EngineProgress) = .empty,
    cancellations: std.ArrayList(u64) = .empty,
    pauses: std.ArrayList(u64) = .empty,
    pause_error: ?anyerror = null,
    resumes: std.ArrayList(u64) = .empty,
    resume_attempts: usize = 0,
    resume_error: ?anyerror = null,
    resume_available: bool = true,
    forced_resume_id: ?u64 = null,
    fn interface(self: *Backend) transfer.TransferEngine {
        return .{ .ctx = self, .open = open, .cancel = cancel, .pause = pause, .resume_job = resumeJob, .can_resume = canResume, .conflict_snapshot = conflictSnapshot, .resolve_conflict = resolveConflict, .poll = poll };
    }
    fn open(raw: *anyopaque, spec_: transfer.JobSpec) !u64 {
        const self: *Backend = @ptrCast(@alignCast(raw));
        self.attempts += 1;
        if (self.reject) return error.ControlledOpenRejected;
        self.last = spec_;
        const id = self.next_id;
        self.next_id += 1;
        return id;
    }
    fn cancel(raw: *anyopaque, id: u64) void {
        const self: *Backend = @ptrCast(@alignCast(raw));
        self.cancellations.append(a, id) catch unreachable;
    }
    fn pause(raw: *anyopaque, id: u64) !void {
        const self: *Backend = @ptrCast(@alignCast(raw));
        if (self.pause_error) |err| return err;
        try self.pauses.append(a, id);
    }
    fn resumeJob(raw: *anyopaque, id: u64) !u64 {
        const self: *Backend = @ptrCast(@alignCast(raw));
        self.resume_attempts += 1;
        if (self.resume_error) |err| return err;
        try self.resumes.append(a, id);
        const next = self.forced_resume_id orelse self.next_id;
        self.next_id += 1;
        return next;
    }
    fn canResume(raw: *anyopaque, id: u64) bool {
        const self: *Backend = @ptrCast(@alignCast(raw));
        return self.resume_available and id > 0 and id < self.next_id;
    }
    fn conflictSnapshot(raw: *anyopaque, allocator: std.mem.Allocator, id: u64) !?transfer.Conflict.OwnedSnapshot {
        const self: *Backend = @ptrCast(@alignCast(raw));
        self.conflict_seen = id;
        return try transfer.Conflict.OwnedSnapshot.clone(allocator, .{
            .engine_job = if (self.conflict_bad_id) id + 1 else id,
            .context = if (self.last) |request| request.conflict_context else null,
            .pending = .{ .context_required = .{ .entry = 0, .revision = 1, .source_path = "/source", .target_path = "/target", .source_metadata = .{ .kind = .file }, .target = .absent } },
        });
    }
    fn resolveConflict(raw: *anyopaque, id: u64, _: transfer.Conflict.Request) !void {
        const self: *Backend = @ptrCast(@alignCast(raw));
        self.conflict_decision = id;
    }
    fn poll(raw: *anyopaque) ?transfer.EngineProgress {
        const self: *Backend = @ptrCast(@alignCast(raw));
        return if (self.events.items.len == 0) null else self.events.orderedRemove(0);
    }
    fn push(self: *Backend, id: u64, state: transfer.EngineState, done: u64) !void {
        try self.events.append(a, .{ .job = id, .done_bytes = done, .total_bytes = 100, .state = state, .failure = if (state == .failed) .io else null, .job_cleanup = if (state == .running) .awaiting else .released });
    }
    fn deinit(self: *Backend) void {
        self.events.deinit(a);
        self.cancellations.deinit(a);
        self.pauses.deinit(a);
        self.resumes.deinit(a);
    }
    fn receipt(_: *anyopaque, _: sessions.ServiceHandle) routing.ReleaseReceipt {
        return .released;
    }
};

test "engine dispatch resume actual Manager keeps JobId and binding while assigning a new attempt and both proxy IDs" {
    var f: Fixture = undefined;
    try f.init();
    defer f.stop();
    const sibling = try f.manager.enqueue(f.spec(false));
    const job = try f.manager.enqueue(f.spec(true));
    f.manager.tick(0);
    const old_dispatch = f.dispatch.jobs.items[1].proxy_id;
    const old_mux = f.mux.jobs.items[0].id;
    try f.manager.pause(job);
    try f.bound.push(1, .paused, 35);
    f.manager.tick(1);
    try std.testing.expect(f.manager.canResume(job));
    try f.manager.resumeJob(job);
    f.manager.tick(2);
    try std.testing.expectEqual(transfer.State.running, f.manager.progress(job).?.state);
    try std.testing.expectEqual(@as(u8, 2), f.manager.progress(job).?.attempt);
    try std.testing.expectEqual(job, f.manager.progress(job).?.job);
    try std.testing.expect(f.manager.transferBinding(job).?.eql(f.binding));
    try std.testing.expectEqualSlices(u64, &.{1}, f.bound.resumes.items);
    try std.testing.expectEqual(@as(usize, 1), f.bound.attempts);
    const new_dispatch = f.dispatch.jobs.items[2].proxy_id;
    const new_mux = f.mux.jobs.items[1].id;
    try std.testing.expect(new_dispatch != old_dispatch and new_mux != old_mux);
    try std.testing.expectEqual(@as(u64, 2), f.mux.jobs.items[1].local_id);
    try std.testing.expect(f.mux.jobs.items[1].binding.eql(f.binding));
    try std.testing.expect(f.dispatch.jobs.items[1].terminal and f.mux.jobs.items[0].terminal);
    try f.bound.push(1, .cancelled, 35);
    try f.bound.push(2, .running, 60);
    try f.legacy.push(1, .running, 15);
    f.manager.tick(3);
    f.manager.tick(3); // A stale-only Mux poll may defer its next event.
    try std.testing.expectEqual(transfer.State.running, f.manager.progress(job).?.state);
    try std.testing.expectEqual(@as(u64, 60), f.manager.progress(job).?.done_bytes);
    try std.testing.expectEqual(@as(u64, 15), f.manager.progress(sibling).?.done_bytes);
    f.dispatch.cancel(old_dispatch);
    f.mux.cancel(old_mux);
    try std.testing.expectEqual(@as(usize, 0), f.bound.cancellations.items.len);
    try f.manager.cancel(job);
    try std.testing.expectEqualSlices(u64, &.{2}, f.bound.cancellations.items);
    try f.bound.push(2, .cancelled, 60);
    f.manager.tick(4);
    try std.testing.expectEqual(transfer.State.cancelled, f.manager.progress(job).?.state);
    try std.testing.expectEqual(transfer.State.running, f.manager.progress(sibling).?.state);
}

test "engine dispatch resume missing capability and backend error keep old route cancellable without opening" {
    var f: Fixture = undefined;
    try f.init();
    defer f.stop();
    f.dispatch.backends[0].resume_job = null;
    const old_legacy = try f.dispatch.open(f.spec(false));
    const old_bound = try f.dispatch.open(f.spec(true));
    try f.legacy.push(1, .paused, 30);
    try f.bound.push(1, .paused, 35);
    _ = f.dispatch.poll().?;
    _ = f.dispatch.poll().?;
    const engine = f.dispatch.engine();
    try std.testing.expect(!engine.can_resume.?(engine.ctx, old_legacy));
    try std.testing.expectError(error.UnsupportedResume, engine.resume_job.?(engine.ctx, old_legacy));
    f.bound.resume_available = false;
    try std.testing.expect(!engine.can_resume.?(engine.ctx, old_bound));
    try std.testing.expectError(error.UnsupportedResume, engine.resume_job.?(engine.ctx, old_bound));
    f.bound.resume_available = true;
    f.bound.resume_error = error.TargetChanged;
    try std.testing.expect(engine.can_resume.?(engine.ctx, old_bound));
    const next_id = f.dispatch.next_id;
    try std.testing.expectError(error.TargetChanged, engine.resume_job.?(engine.ctx, old_bound));
    try std.testing.expectEqual(next_id, f.dispatch.next_id);
    try std.testing.expectEqual(@as(usize, 2), f.dispatch.jobs.items.len);
    try std.testing.expect(!f.dispatch.jobs.items[1].terminal and f.dispatch.jobs.items[1].paused_released);
    try std.testing.expectEqual(@as(usize, 1), f.legacy.attempts);
    try std.testing.expectEqual(@as(usize, 1), f.bound.attempts);
    engine.cancel(engine.ctx, old_bound);
    try std.testing.expectEqualSlices(u64, &.{1}, f.bound.cancellations.items);
    try std.testing.expectEqual(@as(usize, 0), f.legacy.cancellations.items.len);
}

test "engine dispatch resume reserves proxy memory and ID before any backend handoff" {
    var first: Backend = .{};
    defer first.deinit();
    var second: Backend = .{};
    defer second.deinit();
    var failing = std.testing.FailingAllocator.init(a, .{});
    var dispatch = module.Dispatch.init(failing.allocator(), first.interface(), second.interface());
    const old = try dispatch.open(.{ .direction = .download, .sources = &.{"/source"}, .remote_dir = "/", .local_dir = "/destination" });
    defer {
        for (1..first.next_id) |id| first.push(@intCast(id), .failed, 0) catch unreachable;
        while (dispatch.poll() != null) {}
        dispatch.deinit() catch unreachable;
    }
    try first.push(1, .paused, 35);
    _ = dispatch.poll().?;
    dispatch.next_id = std.math.maxInt(u64);
    try std.testing.expectError(error.JobIdExhausted, dispatch.resumeJob(old));
    try std.testing.expectEqual(@as(usize, 0), first.resume_attempts);
    dispatch.next_id = old + 1;
    try dispatch.jobs.shrinkAndFreePrecise(failing.allocator(), dispatch.jobs.items.len);
    failing.fail_index = failing.alloc_index;
    failing.resize_fail_index = failing.resize_index;
    try std.testing.expectError(error.OutOfMemory, dispatch.resumeJob(old));
    try std.testing.expectEqual(@as(usize, 0), first.resume_attempts);
    try std.testing.expect(!dispatch.jobs.items[0].terminal and dispatch.jobs.items[0].paused_released);
    failing.fail_index = std.math.maxInt(usize);
    failing.resize_fail_index = std.math.maxInt(usize);
    dispatch.cancel(old);
    try std.testing.expectEqualSlices(u64, &.{1}, first.cancellations.items);
}

test "engine dispatch resume invalid native identity quarantines the original backend only" {
    for ([_]u64{ 0, 1 }) |bad_id| {
        var first: Backend = .{ .forced_resume_id = bad_id };
        defer first.deinit();
        var second: Backend = .{};
        defer second.deinit();
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit(); // Controlled endpoints hold no native resources.
        var dispatch = module.Dispatch.init(arena.allocator(), first.interface(), second.interface());
        const old = try dispatch.open(.{ .direction = .download, .sources = &.{"/source"}, .remote_dir = "/", .local_dir = "/destination" });
        try first.push(1, .paused, 35);
        _ = dispatch.poll().?;
        try std.testing.expectError(error.EngineProtocolFault, dispatch.resumeJob(old));
        try std.testing.expect(dispatch.protocol_fault[0] and !dispatch.protocol_fault[1]);
        try std.testing.expectEqual(@as(usize, 2), dispatch.jobs.items.len);
        try std.testing.expect(!dispatch.jobs.items[0].terminal and !dispatch.jobs.items[1].terminal);
        try std.testing.expect(!dispatch.canResume(old));
        try std.testing.expectError(error.Busy, dispatch.deinit());
        try std.testing.expectEqualSlices(u64, &.{bad_id}, first.cancellations.items);
        try std.testing.expectEqual(@as(usize, 0), second.cancellations.items.len);
    }
}

test "engine dispatch P0 awaiting and unknown terminals retain their route until released" {
    var f: Fixture = undefined;
    try f.init();
    defer f.stop();
    const legacy = try f.dispatch.open(f.spec(false));
    const bound = try f.dispatch.open(f.spec(true));
    try f.legacy.events.append(a, .{ .job = 1, .state = .succeeded, .done_bytes = 100, .total_bytes = 100, .job_cleanup = .awaiting });
    try std.testing.expectEqual(legacy, f.dispatch.poll().?.job);
    try std.testing.expect(!f.dispatch.jobs.items[0].terminal);
    try std.testing.expectError(error.Busy, f.dispatch.deinit());
    try f.legacy.events.append(a, .{ .job = 1, .state = .succeeded, .done_bytes = 100, .total_bytes = 100, .job_cleanup = .unknown });
    try f.bound.push(1, .running, 40);
    try std.testing.expectEqual(bound, f.dispatch.poll().?.job);
    const unknown = f.dispatch.poll().?;
    try std.testing.expectEqual(legacy, unknown.job);
    try std.testing.expectEqual(transfer.JobCleanup.unknown, unknown.job_cleanup);
    try std.testing.expectError(error.Busy, f.dispatch.deinit());
    try f.legacy.push(1, .succeeded, 100);
    const released = f.dispatch.poll().?;
    try std.testing.expectEqual(legacy, released.job);
    try std.testing.expectEqual(transfer.JobCleanup.released, released.job_cleanup);
    try std.testing.expect(f.dispatch.jobs.items[0].terminal);
    try std.testing.expect(!f.dispatch.jobs.items[1].terminal);
    try f.bound.push(1, .cancelled, 40);
    try std.testing.expectEqual(bound, f.dispatch.poll().?.job);
    try std.testing.expect(f.dispatch.jobs.items[1].terminal);
}

test "engine dispatch P0 actual Manager pause cancel upgrade traverses Dispatch Mux to original job" {
    var f: Fixture = undefined;
    try f.init();
    defer f.stop();
    const one = try f.manager.enqueue(f.spec(false));
    const two = try f.manager.enqueue(f.spec(true));
    f.manager.tick(0);
    try f.manager.pause(two);
    try f.manager.pause(two);
    try std.testing.expectEqualSlices(u64, &.{1}, f.bound.pauses.items);
    try std.testing.expectEqual(@as(usize, 0), f.legacy.pauses.items.len);
    try std.testing.expectEqual(@as(usize, 0), f.bound.cancellations.items.len);
    try std.testing.expectEqual(transfer.State.pausing, f.manager.progress(two).?.state);
    try f.manager.cancel(two);
    try f.manager.cancel(two);
    try std.testing.expectEqualSlices(u64, &.{1}, f.bound.cancellations.items);
    try std.testing.expectEqual(@as(usize, 0), f.legacy.cancellations.items.len);
    try std.testing.expectEqual(transfer.State.cancelling, f.manager.progress(two).?.state);
    try f.bound.push(1, .paused, 40);
    f.manager.tick(1);
    try std.testing.expectEqual(transfer.State.cancelling, f.manager.progress(two).?.state);
    try std.testing.expect(!f.dispatch.jobs.items[1].terminal and !f.mux.jobs.items[0].terminal);
    try std.testing.expectError(error.JobsActive, f.mux.detach(f.binding));
    try f.bound.events.append(a, .{ .job = 1, .state = .cancelled, .done_bytes = 40, .total_bytes = 100, .job_cleanup = .unknown });
    f.manager.tick(2);
    try std.testing.expectEqual(transfer.JobCleanup.unknown, f.manager.progress(two).?.job_cleanup);
    try std.testing.expect(!f.dispatch.jobs.items[1].terminal and !f.mux.jobs.items[0].terminal);
    try f.bound.push(1, .cancelled, 40);
    f.manager.tick(3);
    try std.testing.expectEqual(transfer.State.cancelled, f.manager.progress(two).?.state);
    try std.testing.expectEqual(transfer.JobCleanup.released, f.manager.progress(two).?.job_cleanup);
    try std.testing.expect(f.dispatch.jobs.items[1].terminal and f.mux.jobs.items[0].terminal);
    try std.testing.expectEqual(transfer.State.running, f.manager.progress(one).?.state);
}

test "engine dispatch P0 missing pause capability and rejected pause preserve running without cancel fallback" {
    var f: Fixture = undefined;
    try f.init();
    defer f.stop();
    // The immutable legacy interface intentionally has no pause, while the
    // bound route still supports it through its actual Mux registration.
    f.dispatch.backends[0].pause = null;
    const one = try f.manager.enqueue(f.spec(false));
    const two = try f.manager.enqueue(f.spec(true));
    f.manager.tick(0);
    try std.testing.expectError(error.UnsupportedPause, f.manager.pause(one));
    try std.testing.expectEqual(transfer.State.running, f.manager.progress(one).?.state);
    try std.testing.expectEqual(@as(usize, 0), f.legacy.cancellations.items.len);
    try std.testing.expect(!f.dispatch.jobs.items[0].pause_requested);
    f.bound.pause_error = error.ControlledPauseRejected;
    try std.testing.expectError(error.ControlledPauseRejected, f.manager.pause(two));
    try std.testing.expectEqual(transfer.State.running, f.manager.progress(two).?.state);
    try std.testing.expect(!f.dispatch.jobs.items[1].pause_requested and !f.mux.jobs.items[0].pause_requested);
    try std.testing.expectEqual(@as(usize, 0), f.bound.cancellations.items.len);
    f.bound.pause_error = null;
    try f.manager.pause(two);
    try std.testing.expectEqualSlices(u64, &.{1}, f.bound.pauses.items);
    try f.bound.push(1, .paused, 35);
    f.manager.tick(1);
    try std.testing.expectEqual(transfer.State.paused, f.manager.progress(two).?.state);
    try std.testing.expectEqual(transfer.JobCleanup.released, f.manager.progress(two).?.job_cleanup);
    try std.testing.expect(!f.dispatch.jobs.items[1].terminal and !f.mux.jobs.items[0].terminal);
    try std.testing.expectError(error.JobsActive, f.mux.detach(f.binding));
    try std.testing.expectError(error.Busy, f.dispatch.deinit());
    try f.manager.cancel(two);
    try std.testing.expectEqualSlices(u64, &.{1}, f.bound.cancellations.items);
    try std.testing.expectEqual(transfer.State.cancelling, f.manager.progress(two).?.state);
    try f.bound.push(1, .cancelled, 35);
    f.manager.tick(2);
    try std.testing.expectEqual(transfer.State.cancelled, f.manager.progress(two).?.state);
    try std.testing.expect(f.dispatch.jobs.items[1].terminal and f.mux.jobs.items[0].terminal);
}
const Fixture = struct {
    adapter: Adapter,
    domain: sessions.SessionHost,
    binding: sessions.ServiceHandle,
    mux: routing.Mux,
    legacy: Backend,
    bound: Backend,
    dispatch: module.Dispatch,
    manager: transfer.Manager,
    fn init(self: *Fixture) !void {
        self.adapter = .{};
        self.domain = try sessions.SessionHost.init(a, &.{self.adapter.interface()});
        const accepted = try self.domain.create(.{ .saved = .{ .connection_id = @fromBackingInt(71), .config_revision = 3, .protocol = .sftp, .immutable_config = .{ .endpoint = .{ .host = "dispatch-unit.invalid", .user = "fixture" } } } }, .{ .window_id = @fromBackingInt(1), .workspace_id = @fromBackingInt(1) });
        try std.testing.expect(try self.domain.ready(accepted.handle, accepted.operation, plugins.requiredServices(.sftp)));
        self.binding = self.domain.queryService(accepted.handle, .transfer).available;
        self.mux = routing.Mux.init(a, .{ .context = &self.domain, .is_live = live });
        self.legacy = .{};
        self.bound = .{};
        try self.mux.register(self.binding, self.bound.interface());
        try self.mux.setCleanupGuard(self.binding, .{ .context = &self.bound, .receipt = Backend.receipt });
        self.dispatch = module.Dispatch.init(a, self.legacy.interface(), self.mux.engine());
        self.manager = try transfer.Manager.init(a, self.dispatch.engine(), 2, .{ .max_attempts = 2, .base_delay_ms = 5, .max_delay_ms = 5 });
    }
    fn stop(self: *Fixture) void {
        self.manager.deinit();
        // Controlled endpoints explicitly finish each accepted no-IO call.
        // Dispatch cannot manufacture release from a cancellation request.
        for (1..self.legacy.next_id) |id| self.legacy.push(@intCast(id), .failed, 0) catch unreachable;
        for (1..self.bound.next_id) |id| self.bound.push(@intCast(id), .failed, 0) catch unreachable;
        while (self.legacy.events.items.len != 0 or self.bound.events.items.len != 0) _ = self.dispatch.poll();
        self.dispatch.deinit() catch unreachable;
        self.mux.detach(self.binding) catch unreachable;
        self.mux.deinit() catch unreachable;
        self.bound.deinit();
        self.legacy.deinit();
        self.domain.deinit();
    }
    fn spec(self: *Fixture, bound: bool) transfer.JobSpec {
        return .{ .session_id = if (bound) @backingInt(self.binding.resource_owner.session.session_id) else 19, .transfer_binding = if (bound) self.binding else null, .direction = .download, .sources = &.{"/source"}, .remote_dir = "/remote", .local_dir = "/local", .rename = "renamed", .resume_transfer = false, .md5_check = true };
    }
};

test "engine dispatch actual Manager keeps legacy ID1 and bound Mux ID1 separate and forwards frozen specs" {
    var f: Fixture = undefined;
    try f.init();
    defer f.stop();
    var source = "/before".*;
    var remote = "/remote".*;
    var local = "/local".*;
    var renamed = "new.bin".*;
    const sources = [_][]const u8{&source};
    var input = f.spec(false);
    input.sources = &sources;
    input.remote_dir = &remote;
    input.local_dir = &local;
    input.rename = &renamed;
    const one = try f.manager.enqueue(input);
    input.session_id = @backingInt(f.binding.resource_owner.session.session_id);
    input.transfer_binding = f.binding;
    const two = try f.manager.enqueue(input);
    try std.testing.expect(f.manager.transferBinding(one) == null);
    try std.testing.expect(f.manager.transferBinding(two).?.eql(f.binding));
    @memset(&source, 'x');
    @memset(&remote, 'x');
    @memset(&local, 'x');
    @memset(&renamed, 'x');
    f.manager.tick(0);
    try std.testing.expectEqual(@as(usize, 2), f.dispatch.jobs.items.len);
    try std.testing.expectEqual(@as(u64, 1), f.dispatch.jobs.items[0].backend_id);
    try std.testing.expectEqual(@as(u64, 1), f.dispatch.jobs.items[1].backend_id);
    try std.testing.expect(f.dispatch.jobs.items[0].proxy_id != f.dispatch.jobs.items[1].proxy_id);
    try std.testing.expect(f.legacy.last.?.transfer_binding == null);
    try std.testing.expect(f.bound.last.?.transfer_binding.?.eql(f.binding));
    for ([_]transfer.JobSpec{ f.legacy.last.?, f.bound.last.? }) |forwarded| {
        try std.testing.expectEqualStrings("/before", forwarded.sources[0]);
        try std.testing.expectEqualStrings("/remote", forwarded.remote_dir);
        try std.testing.expectEqualStrings("/local", forwarded.local_dir);
        try std.testing.expectEqualStrings("new.bin", forwarded.rename.?);
        try std.testing.expect(forwarded.direction == .download and !forwarded.resume_transfer and forwarded.md5_check);
    }
    try f.legacy.push(1, .running, 10);
    try f.bound.push(1, .running, 70);
    f.manager.tick(1);
    try std.testing.expectEqual(@as(u64, 10), f.manager.progress(one).?.done_bytes);
    try std.testing.expectEqual(@as(u64, 70), f.manager.progress(two).?.done_bytes);
    try f.manager.cancel(one);
    try std.testing.expectEqualSlices(u64, &.{1}, f.legacy.cancellations.items);
    try std.testing.expectEqual(@as(usize, 0), f.bound.cancellations.items.len);
    try std.testing.expectEqual(transfer.State.running, f.manager.progress(two).?.state);
    try std.testing.expectError(error.Busy, f.dispatch.deinit());
    try f.legacy.push(1, .cancelled, 10);
    try f.bound.push(1, .succeeded, 100);
    f.manager.tick(2);
    try std.testing.expectEqual(transfer.State.cancelled, f.manager.progress(one).?.state);
    try std.testing.expectEqual(transfer.State.succeeded, f.manager.progress(two).?.state);
    try std.testing.expect(f.dispatch.jobs.items[0].terminal and f.dispatch.jobs.items[1].terminal);
}

test "engine dispatch alternates noisy backend polls and suppresses duplicate terminals" {
    var f: Fixture = undefined;
    try f.init();
    defer f.stop();
    const one = try f.dispatch.open(f.spec(false));
    const two = try f.dispatch.open(f.spec(true));
    try f.legacy.push(1, .running, 10);
    try f.legacy.push(1, .running, 20);
    try f.legacy.push(1, .succeeded, 100);
    try f.bound.push(1, .running, 5);
    try f.bound.push(1, .succeeded, 100);
    try std.testing.expectEqual(one, f.dispatch.poll().?.job);
    try std.testing.expectEqual(two, f.dispatch.poll().?.job);
    try std.testing.expectEqual(one, f.dispatch.poll().?.job);
    try std.testing.expectEqual(two, f.dispatch.poll().?.job);
    try std.testing.expectEqual(one, f.dispatch.poll().?.job);
    try std.testing.expect(f.dispatch.poll() == null);
    try f.legacy.push(1, .succeeded, 100);
    try f.bound.push(1, .failed, 100);
    try std.testing.expect(f.dispatch.poll() == null);
    f.dispatch.cancel(one);
    f.dispatch.cancel(two);
    try std.testing.expectEqual(@as(usize, 0), f.legacy.cancellations.items.len);
    try std.testing.expectEqual(@as(usize, 0), f.bound.cancellations.items.len);
}

test "engine dispatch fixed cancellation cannot target a sibling or a retry proxy" {
    var f: Fixture = undefined;
    try f.init();
    defer f.stop();
    const one = try f.manager.enqueue(f.spec(false));
    const two = try f.manager.enqueue(f.spec(true));
    f.manager.tick(0);
    const original = f.dispatch.jobs.items[1].proxy_id;
    try f.bound.events.append(a, .{ .job = 1, .done_bytes = 30, .total_bytes = 100, .state = .failed, .failure = .connection, .retryable = true, .job_cleanup = .released });
    f.manager.tick(1);
    try std.testing.expectEqual(transfer.State.retry_wait, f.manager.progress(two).?.state);
    f.manager.tick(6);
    try std.testing.expectEqual(transfer.State.running, f.manager.progress(two).?.state);
    try std.testing.expectEqual(@as(u8, 2), f.manager.progress(two).?.attempt);
    try std.testing.expectEqual(@as(usize, 3), f.dispatch.jobs.items.len);
    try std.testing.expect(f.dispatch.jobs.items[2].proxy_id != original);
    f.dispatch.cancel(original);
    try std.testing.expectEqual(@as(usize, 0), f.bound.cancellations.items.len);
    const retry = f.dispatch.jobs.items[2].proxy_id;
    f.dispatch.cancel(retry);
    f.dispatch.cancel(retry);
    try std.testing.expectEqualSlices(u64, &.{2}, f.bound.cancellations.items);
    try std.testing.expectEqual(@as(usize, 0), f.legacy.cancellations.items.len);
    try std.testing.expectEqual(transfer.State.running, f.manager.progress(one).?.state);
    try std.testing.expect(f.bound.last.?.transfer_binding.?.eql(f.binding));
    f.dispatch.cancel(99999);
    try std.testing.expectEqualSlices(u64, &.{2}, f.bound.cancellations.items);
}

test "engine dispatch bound rejection never falls back to legacy and open failure retains no proxy" {
    var f: Fixture = undefined;
    try f.init();
    defer f.stop();
    var bad = f.spec(true);
    bad.transfer_binding.?.binding_generation += 1;
    try std.testing.expectError(error.StaleBinding, f.dispatch.open(bad));
    bad = f.spec(true);
    bad.transfer_binding.?.binding_id += 100;
    try std.testing.expectError(error.StaleBinding, f.dispatch.open(bad));
    try std.testing.expectEqual(@as(usize, 0), f.legacy.attempts);
    try std.testing.expectEqual(@as(usize, 0), f.dispatch.jobs.items.len);
    f.legacy.reject = true;
    try std.testing.expectError(error.ControlledOpenRejected, f.dispatch.open(f.spec(false)));
    try std.testing.expectEqual(@as(u64, 1), f.dispatch.next_id);
    try std.testing.expectEqual(@as(usize, 0), f.dispatch.jobs.items.len);
    f.legacy.reject = false;
    f.dispatch.next_id = std.math.maxInt(u64);
    try std.testing.expectError(error.JobIdExhausted, f.dispatch.open(f.spec(false)));
    try std.testing.expectEqual(@as(usize, 1), f.legacy.attempts);
}

test "engine dispatch reserves proxy memory before invoking either backend" {
    var first: Backend = .{};
    defer first.deinit();
    var second: Backend = .{};
    defer second.deinit();
    var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = 0 });
    var dispatch = module.Dispatch.init(failing.allocator(), first.interface(), second.interface());
    defer dispatch.deinit() catch unreachable;
    try std.testing.expectError(error.OutOfMemory, dispatch.open(.{ .direction = .download, .sources = &.{"/source"}, .remote_dir = "/", .local_dir = "/destination" }));
    try std.testing.expectEqual(@as(usize, 0), first.attempts);
    try std.testing.expectEqual(@as(usize, 0), second.attempts);
}

test "engine dispatch conflict snapshots and decisions retain nested original route" {
    var f: Fixture = undefined;
    try f.init();
    defer f.stop();
    _ = try f.dispatch.open(f.spec(false));
    const bound_id = try f.dispatch.open(f.spec(true));
    const engine = f.dispatch.engine();
    var snapshot = (try engine.conflict_snapshot.?(engine.ctx, a, bound_id)).?;
    defer snapshot.deinit();
    try std.testing.expectEqual(bound_id, snapshot.value.engine_job);
    try std.testing.expectEqual(@as(?u64, 1), f.bound.conflict_seen);
    try std.testing.expect(f.legacy.conflict_seen == null);
    const request: transfer.Conflict.Request = .{ .select = .{
        .key = .{ .intent_id = 1, .owner = f.binding.resource_owner, .original_owner = f.binding.resource_owner.session, .entry = 0, .job = 99, .attempt = 1, .revision = 1 },
        .selection = .{ .choice = .skip },
    } };
    try engine.resolve_conflict.?(engine.ctx, bound_id, request);
    try std.testing.expectEqual(@as(?u64, 1), f.bound.conflict_decision);
    try std.testing.expect(f.legacy.conflict_decision == null);
    f.bound.conflict_bad_id = true;
    try std.testing.expectError(error.EngineProtocolFault, engine.conflict_snapshot.?(engine.ctx, a, bound_id));
    f.dispatch.cancel(bound_id);
    try std.testing.expectError(error.JobTerminal, engine.resolve_conflict.?(engine.ctx, bound_id, request));
    try std.testing.expectError(error.JobTerminal, engine.conflict_snapshot.?(engine.ctx, a, bound_id));
}

test "engine dispatch conflict actual Manager stamps original job and rejects old attempt" {
    var f: Fixture = undefined;
    try f.init();
    defer f.stop();
    var request_spec = f.spec(true);
    const owner = f.binding.resource_owner.session;
    request_spec.conflict_context = .{
        .intent_id = 51,
        .job = 999,
        .attempt = 999,
        .original_owner = owner,
        .resource_owner = f.binding.resource_owner,
        .source_endpoint = .{ .sftp = .{ .binding_id = 41, .binding_generation = 1, .resource_owner = f.binding.resource_owner, .origin_session = owner } },
        .target_endpoint = .{ .local_fs = .{ .binding_id = 42, .binding_generation = 1 } },
    };
    const id = try f.manager.enqueue(request_spec);
    f.manager.tick(0);
    const accepted = f.bound.last.?.conflict_context.?;
    try std.testing.expectEqual(id, accepted.job);
    try std.testing.expectEqual(@as(u32, 1), accepted.attempt);
    try std.testing.expectEqualDeep(request_spec.conflict_context.?.source_endpoint, accepted.source_endpoint);
    try f.bound.events.append(a, .{ .job = 1, .done_bytes = 0, .total_bytes = 100, .state = .running, .conflict_waiting = true });
    f.manager.tick(1);
    var snapshot = (try f.manager.conflictSnapshot(a, id)).?;
    defer snapshot.deinit();
    try std.testing.expectEqualDeep(accepted, snapshot.value.context.?);
    var decision: transfer.Conflict.Request = .{ .select = .{
        .key = .{ .intent_id = 51, .owner = accepted.resource_owner, .original_owner = owner, .entry = 0, .job = id, .attempt = 1, .revision = 1 },
        .selection = .{ .choice = .skip },
    } };
    decision.select.key.attempt = 2;
    try std.testing.expectError(error.StaleConflict, f.manager.resolveConflict(id, decision));
    try std.testing.expect(f.bound.conflict_decision == null);
    decision.select.key.attempt = 1;
    try f.manager.resolveConflict(id, decision);
    try std.testing.expectEqual(@as(?u64, 1), f.bound.conflict_decision);
}

test "engine dispatch exported paused routes retire only exact released mapping and imports reserve both proxies" {
    var f: Fixture = undefined;
    try f.init();
    defer f.stop();
    const original = try f.dispatch.open(f.spec(true));
    try std.testing.expectError(error.CheckpointNotReleased, f.dispatch.pausedBoundRoute(original));
    try f.bound.push(1, .paused, 35);
    _ = f.dispatch.poll().?;
    const old_mux = try f.dispatch.pausedBoundRoute(original);
    try std.testing.expectEqual(@as(u64, 1), try f.mux.pausedNativeId(old_mux, f.binding));
    try std.testing.expectError(error.StaleAttempt, f.mux.retireExportedPaused(old_mux, f.binding, 2));
    try f.mux.retireExportedPaused(old_mux, f.binding, 1);
    try f.dispatch.retireExportedPaused(original, old_mux);
    f.dispatch.cancel(original);
    f.mux.cancel(old_mux);
    try std.testing.expectEqual(@as(usize, 0), f.bound.cancellations.items.len);
    const Import = struct {
        fixture: *Fixture,
        reject: bool = true,
        calls: usize = 0,
        fn fromMux(raw: *anyopaque) !u64 {
            const self: *@This() = @ptrCast(@alignCast(raw));
            return self.fixture.mux.importPaused(self.fixture.binding, raw, acceptNative);
        }
        fn acceptNative(raw: *anyopaque) !u64 {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.calls += 1;
            if (self.reject) return error.TransferNotReady;
            const next = self.fixture.bound.next_id;
            self.fixture.bound.next_id += 1;
            return next;
        }
    };
    var importer: Import = .{ .fixture = &f };
    const outer_next = f.dispatch.next_id;
    const inner_next = f.mux.next_id;
    try std.testing.expectError(error.TransferNotReady, f.dispatch.importBoundPaused(&importer, Import.fromMux));
    try std.testing.expectEqual(outer_next, f.dispatch.next_id);
    try std.testing.expectEqual(inner_next, f.mux.next_id);
    try std.testing.expectEqual(@as(usize, 1), f.dispatch.jobs.items.len);
    try std.testing.expectEqual(@as(usize, 1), f.mux.jobs.items.len);
    importer.reject = false;
    const imported = try f.dispatch.importBoundPaused(&importer, Import.fromMux);
    try std.testing.expect(imported != original);
    try std.testing.expectEqual(@as(u64, 2), f.mux.jobs.items[1].local_id);
    try std.testing.expect(f.mux.jobs.items[1].binding.eql(f.binding));
    try std.testing.expectEqual(@as(usize, 1), f.bound.attempts); // no fallback open
    try f.bound.push(1, .cancelled, 35);
    try f.bound.push(2, .running, 60);
    const event = f.dispatch.poll() orelse f.dispatch.poll().?;
    try std.testing.expectEqual(imported, event.job);
    try std.testing.expectEqual(@as(u64, 60), event.done_bytes);
    f.dispatch.cancel(imported);
    try std.testing.expectEqualSlices(u64, &.{2}, f.bound.cancellations.items);
}
