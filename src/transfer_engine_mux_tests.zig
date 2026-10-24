const std = @import("std");
const transfer = @import("transfer/manager.zig");
const routing = @import("transfer/engine_mux.zig");
const sessions = @import("host/session_host.zig");
const plugins = @import("host/plugin_registry.zig");
const sftp = @import("transfer/sftp_engine.zig");
const ssh = @import("proto/ssh/session.zig");
const clock = @import("platform/realtime.zig");
comptime {
    _ = @import("transfer/manager_test.zig");
}
// Real SessionHost-issued test identities. This controlled adapter is never
// installed in ApplicationHost and does not claim production transfer readiness.
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
        return .{ .registration = .{ .plugin_id = .sftp, .workspace_kind = .file, .services = plugins.requiredServices(.sftp) }, .context = self, .vtable = &.{ .create = Adapter.create, .cancel = cancel, .close = close, .release_stale = stale } };
    }
};
fn create(domain: *sessions.SessionHost) !sessions.Accepted {
    const accepted = try domain.create(.{ .saved = .{ .connection_id = @fromBackingInt(19), .config_revision = 4, .protocol = .sftp, .immutable_config = .{ .endpoint = .{ .host = "test.invalid", .user = "test" } } } }, .{ .window_id = @fromBackingInt(1), .workspace_id = @fromBackingInt(1) });
    try std.testing.expect(try domain.ready(accepted.handle, accepted.operation, plugins.requiredServices(.sftp)));
    return accepted;
}
fn live(raw: *anyopaque, binding: sessions.ServiceHandle) bool {
    const domain: *sessions.SessionHost = @ptrCast(@alignCast(raw));
    return domain.bindingIsLive(binding);
}
fn authority(domain: *sessions.SessionHost) routing.Authority {
    return .{ .context = domain, .is_live = live };
}
fn spec(binding: sessions.ServiceHandle) transfer.JobSpec {
    return .{ .transfer_binding = binding, .direction = .download, .sources = &.{"/original"}, .remote_dir = "/", .local_dir = "/test-only-destination" };
}
const Backend = struct {
    next: u64 = 1,
    opens: usize = 0,
    cancellations: std.ArrayList(u64) = .empty,
    pauses: std.ArrayList(u64) = .empty,
    pause_error: ?anyerror = null,
    resumes: std.ArrayList(u64) = .empty,
    resume_attempts: usize = 0,
    resume_error: ?anyerror = null,
    resume_available: bool = true,
    forced_resume_id: ?u64 = null,
    events: std.ArrayList(transfer.EngineProgress) = .empty,
    release: routing.ReleaseReceipt = .awaiting,
    guard_calls: usize = 0,
    last_binding: ?sessions.ServiceHandle = null,
    source: [128]u8 = undefined,
    source_len: usize = 0,
    fn interface(self: *Backend) transfer.TransferEngine {
        return .{ .ctx = self, .open = open, .cancel = cancel, .pause = pause, .resume_job = resumeJob, .can_resume = canResume, .poll = poll };
    }
    fn guard(self: *Backend) routing.CleanupGuard {
        return .{ .context = self, .receipt = receipt };
    }
    fn open(raw: *anyopaque, request: transfer.JobSpec) !u64 {
        const self: *Backend = @ptrCast(@alignCast(raw));
        self.opens += 1;
        self.last_binding = request.transfer_binding;
        self.source_len = request.sources[0].len;
        @memcpy(self.source[0..self.source_len], request.sources[0]);
        const id = self.next;
        self.next += 1;
        return id;
    }
    fn cancel(raw: *anyopaque, id: u64) void {
        const self: *Backend = @ptrCast(@alignCast(raw));
        self.cancellations.append(std.testing.allocator, id) catch unreachable;
    }
    fn pause(raw: *anyopaque, id: u64) !void {
        const self: *Backend = @ptrCast(@alignCast(raw));
        if (self.pause_error) |err| return err;
        try self.pauses.append(std.testing.allocator, id);
    }
    fn resumeJob(raw: *anyopaque, id: u64) !u64 {
        const self: *Backend = @ptrCast(@alignCast(raw));
        self.resume_attempts += 1;
        if (self.resume_error) |err| return err;
        try self.resumes.append(std.testing.allocator, id);
        const next = self.forced_resume_id orelse self.next;
        self.next += 1;
        return next;
    }
    fn canResume(raw: *anyopaque, id: u64) bool {
        const self: *Backend = @ptrCast(@alignCast(raw));
        return self.resume_available and id > 0 and id < self.next;
    }
    fn poll(raw: *anyopaque) ?transfer.EngineProgress {
        const self: *Backend = @ptrCast(@alignCast(raw));
        if (self.events.items.len == 0) return null;
        return self.events.orderedRemove(0);
    }
    fn push(self: *Backend, id: u64, state: transfer.EngineState, done: u64) !void {
        try self.events.append(std.testing.allocator, .{ .job = id, .state = state, .done_bytes = done, .total_bytes = 100, .failure = if (state == .failed) .io else null, .job_cleanup = if (state == .running) .awaiting else .released });
    }
    fn receipt(raw: *anyopaque, binding: sessions.ServiceHandle) routing.ReleaseReceipt {
        const self: *Backend = @ptrCast(@alignCast(raw));
        std.debug.assert(binding.kind == .transfer);
        self.guard_calls += 1;
        return self.release;
    }
    fn deinit(self: *Backend) void {
        self.cancellations.deinit(std.testing.allocator);
        self.pauses.deinit(std.testing.allocator);
        self.resumes.deinit(std.testing.allocator);
        self.events.deinit(std.testing.allocator);
    }
};

test "transfer mux resume requires original released pause capability and failed handoff keeps cancellable entity" {
    var adapter: Adapter = .{};
    var domain = try sessions.SessionHost.init(std.testing.allocator, &.{adapter.interface()});
    defer domain.deinit();
    const accepted = try create(&domain);
    const binding = domain.queryService(accepted.handle, .transfer).available;
    var backend: Backend = .{};
    defer backend.deinit();
    var mux = routing.Mux.init(std.testing.allocator, authority(&domain));
    defer stop(&mux);
    try mux.register(binding, backend.interface());
    var changed_capability = backend.interface();
    changed_capability.can_resume = null;
    try std.testing.expectError(error.BindingAlreadyRegistered, mux.register(binding, changed_capability));
    changed_capability = backend.interface();
    changed_capability.resume_job = null;
    try std.testing.expectError(error.BindingAlreadyRegistered, mux.register(binding, changed_capability));
    const id = try mux.open(spec(binding));
    const engine = mux.engine();
    try std.testing.expect(!engine.can_resume.?(engine.ctx, id));
    try std.testing.expectError(error.CleanupPending, engine.resume_job.?(engine.ctx, id));
    for ([_]transfer.JobCleanup{ .awaiting, .unknown }) |cleanup| {
        try backend.events.append(std.testing.allocator, .{ .job = 1, .state = .paused, .done_bytes = 35, .total_bytes = 100, .job_cleanup = cleanup });
        _ = engine.poll(engine.ctx).?;
        try std.testing.expect(!engine.can_resume.?(engine.ctx, id));
        try std.testing.expectError(error.CleanupPending, engine.resume_job.?(engine.ctx, id));
    }
    try std.testing.expectEqual(@as(usize, 0), backend.resume_attempts);
    try backend.push(1, .paused, 35);
    _ = engine.poll(engine.ctx).?;
    backend.resume_available = false;
    try std.testing.expect(!engine.can_resume.?(engine.ctx, id));
    try std.testing.expectError(error.UnsupportedResume, engine.resume_job.?(engine.ctx, id));
    backend.resume_available = true;
    try std.testing.expect(engine.can_resume.?(engine.ctx, id));
    backend.resume_error = error.SourceChanged;
    const next_id = mux.next_id;
    try std.testing.expectError(error.SourceChanged, engine.resume_job.?(engine.ctx, id));
    try std.testing.expectEqual(next_id, mux.next_id);
    try std.testing.expectEqual(@as(usize, 1), mux.jobs.items.len);
    try std.testing.expect(!mux.jobs.items[0].terminal and mux.jobs.items[0].paused_released);
    try std.testing.expectEqual(@as(usize, 1), backend.opens);
    engine.cancel(engine.ctx, id);
    try std.testing.expectEqualSlices(u64, &.{1}, backend.cancellations.items);
    try std.testing.expect(!engine.can_resume.?(engine.ctx, id));
    try std.testing.expectError(error.CancellationPending, engine.resume_job.?(engine.ctx, id));
}

test "transfer mux resume callback without native capability query remains unsupported" {
    var adapter: Adapter = .{};
    var domain = try sessions.SessionHost.init(std.testing.allocator, &.{adapter.interface()});
    defer domain.deinit();
    const accepted = try create(&domain);
    const binding = domain.queryService(accepted.handle, .transfer).available;
    var backend: Backend = .{};
    defer backend.deinit();
    var mux = routing.Mux.init(std.testing.allocator, authority(&domain));
    defer stop(&mux);
    var incomplete = backend.interface();
    incomplete.can_resume = null;
    try mux.register(binding, incomplete);
    const id = try mux.open(spec(binding));
    try backend.push(1, .paused, 35);
    _ = mux.poll().?;
    try std.testing.expect(!mux.canResume(id));
    try std.testing.expectError(error.UnsupportedResume, mux.resumeJob(id));
    try std.testing.expectEqual(@as(usize, 0), backend.resume_attempts);
    mux.cancel(id);
    try std.testing.expectEqualSlices(u64, &.{1}, backend.cancellations.items);
}

test "transfer mux resume transfers original binding to different IDs and ignores old events" {
    var adapter: Adapter = .{};
    var domain = try sessions.SessionHost.init(std.testing.allocator, &.{adapter.interface()});
    defer domain.deinit();
    const accepted = try create(&domain);
    const binding = domain.queryService(accepted.handle, .transfer).available;
    var backend: Backend = .{};
    defer backend.deinit();
    var mux = routing.Mux.init(std.testing.allocator, authority(&domain));
    defer stop(&mux);
    try mux.register(binding, backend.interface());
    const original = try mux.open(spec(binding));
    try backend.push(1, .paused, 35);
    _ = mux.poll().?;
    const resumed = try mux.resumeJob(original);
    try std.testing.expect(resumed != original);
    try std.testing.expectEqual(@as(u64, 2), mux.jobs.items[1].local_id);
    try std.testing.expect(mux.jobs.items[1].binding.eql(binding));
    try std.testing.expect(mux.jobs.items[0].terminal and !mux.jobs.items[1].terminal);
    try std.testing.expectEqualSlices(u64, &.{1}, backend.resumes.items);
    try std.testing.expectEqual(@as(usize, 1), backend.opens);
    try backend.push(1, .cancelled, 35);
    try backend.push(2, .running, 60);
    try std.testing.expect(mux.poll() == null); // Old event only, no retarget.
    const progress = mux.poll().?;
    try std.testing.expectEqual(resumed, progress.job);
    try std.testing.expectEqual(@as(u64, 60), progress.done_bytes);
    mux.cancel(original);
    try std.testing.expectEqual(@as(usize, 0), backend.cancellations.items.len);
    mux.cancel(resumed);
    try std.testing.expectEqualSlices(u64, &.{2}, backend.cancellations.items);
}

test "transfer mux resume reserves memory and proxy identity before native acceptance and rejects stale binding" {
    var adapter: Adapter = .{};
    var domain = try sessions.SessionHost.init(std.testing.allocator, &.{adapter.interface()});
    defer domain.deinit();
    const accepted = try create(&domain);
    const binding = domain.queryService(accepted.handle, .transfer).available;
    var backend: Backend = .{};
    defer backend.deinit();
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var mux = routing.Mux.init(failing.allocator(), authority(&domain));
    defer stop(&mux);
    try mux.register(binding, backend.interface());
    const original = try mux.open(spec(binding));
    try backend.push(1, .paused, 35);
    _ = mux.poll().?;
    mux.next_id = std.math.maxInt(u64);
    try std.testing.expectError(error.JobIdExhausted, mux.resumeJob(original));
    try std.testing.expectEqual(@as(usize, 0), backend.resume_attempts);
    mux.next_id = original + 1;
    try mux.jobs.shrinkAndFreePrecise(failing.allocator(), mux.jobs.items.len);
    failing.fail_index = failing.alloc_index;
    failing.resize_fail_index = failing.resize_index;
    try std.testing.expectError(error.OutOfMemory, mux.resumeJob(original));
    try std.testing.expectEqual(@as(usize, 0), backend.resume_attempts);
    try std.testing.expect(!mux.jobs.items[0].terminal and mux.jobs.items[0].paused_released);
    failing.fail_index = std.math.maxInt(usize);
    failing.resize_fail_index = std.math.maxInt(usize);
    _ = try domain.requestClose(accepted.handle, .{});
    try std.testing.expect(!mux.canResume(original));
    try std.testing.expectError(error.StaleBinding, mux.resumeJob(original));
    mux.cancel(original);
    try std.testing.expectEqualSlices(u64, &.{1}, backend.cancellations.items);
}

test "transfer mux resume illegal backend IDs quarantine both ownership records without false retirement" {
    for ([_]u64{ 0, 1 }) |bad_id| {
        var adapter: Adapter = .{};
        var domain = try sessions.SessionHost.init(std.testing.allocator, &.{adapter.interface()});
        defer domain.deinit();
        const accepted = try create(&domain);
        const binding = domain.queryService(accepted.handle, .transfer).available;
        var backend: Backend = .{ .forced_resume_id = bad_id };
        defer backend.deinit();
        // No native resources exist in this controlled invalid-backend case.
        // Arena reclamation releases test memory, not a production IO receipt.
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var mux = routing.Mux.init(arena.allocator(), authority(&domain));
        try mux.register(binding, backend.interface());
        const original = try mux.open(spec(binding));
        try backend.push(1, .paused, 35);
        _ = mux.poll().?;
        try std.testing.expectError(error.EngineProtocolFault, mux.resumeJob(original));
        try std.testing.expectEqual(@as(usize, 2), mux.jobs.items.len);
        try std.testing.expect(!mux.jobs.items[0].terminal and !mux.jobs.items[1].terminal);
        try std.testing.expect(mux.registrations.items[0].protocol_fault);
        try std.testing.expect(!mux.canResume(original));
        try std.testing.expectError(error.EngineProtocolFault, mux.detach(binding));
        try std.testing.expectError(error.Busy, mux.deinit());
        try std.testing.expectEqualSlices(u64, &.{bad_id}, backend.cancellations.items);
    }
}

test "transfer mux P0 business terminal retains original route until explicit job cleanup release" {
    var adapter: Adapter = .{};
    var domain = try sessions.SessionHost.init(std.testing.allocator, &.{adapter.interface()});
    defer domain.deinit();
    const original = try create(&domain);
    const binding = domain.queryService(original.handle, .transfer).available;
    var backend: Backend = .{ .release = .released };
    defer backend.deinit();
    var mux = routing.Mux.init(std.testing.allocator, authority(&domain));
    defer stop(&mux);
    try mux.register(binding, backend.interface());
    try mux.setCleanupGuard(binding, backend.guard());
    const id = try mux.open(spec(binding));
    try backend.events.append(std.testing.allocator, .{ .job = 1, .state = .succeeded, .done_bytes = 100, .total_bytes = 100, .job_cleanup = .awaiting });
    const awaiting = mux.poll().?;
    try std.testing.expectEqual(id, awaiting.job);
    try std.testing.expectEqual(transfer.JobCleanup.awaiting, awaiting.job_cleanup);
    try std.testing.expectError(error.JobsActive, mux.detach(binding));
    try std.testing.expectError(error.Busy, mux.deinit());
    try std.testing.expectEqual(@as(usize, 0), backend.guard_calls);
    try backend.events.append(std.testing.allocator, .{ .job = 1, .state = .succeeded, .done_bytes = 100, .total_bytes = 100, .job_cleanup = .unknown });
    const unknown = mux.poll().?;
    try std.testing.expectEqual(id, unknown.job);
    try std.testing.expectEqual(transfer.JobCleanup.unknown, unknown.job_cleanup);
    try std.testing.expectError(error.JobsActive, mux.detach(binding));
    try backend.push(1, .succeeded, 100);
    const released = mux.poll().?;
    try std.testing.expectEqual(id, released.job);
    try std.testing.expectEqual(transfer.JobCleanup.released, released.job_cleanup);
    backend.release = .unknown;
    try std.testing.expectError(error.CleanupUnknown, mux.detach(binding));
    backend.release = .released;
    try mux.detach(binding);
}

test "transfer mux P0 pause is original backend capability and cancel upgrade retains late paused acknowledgement" {
    var adapter: Adapter = .{};
    var domain = try sessions.SessionHost.init(std.testing.allocator, &.{adapter.interface()});
    defer domain.deinit();
    const owner_a = try create(&domain);
    const owner_b = try create(&domain);
    const a = domain.queryService(owner_a.handle, .transfer).available;
    const b = domain.queryService(owner_b.handle, .transfer).available;
    var first: Backend = .{};
    defer first.deinit();
    var second: Backend = .{};
    defer second.deinit();
    var mux = routing.Mux.init(std.testing.allocator, authority(&domain));
    defer stop(&mux);
    // Manager may retain the router before bindings/capabilities exist.
    const engine = mux.engine();
    var unsupported = first.interface();
    unsupported.pause = null;
    try mux.register(a, unsupported);
    try mux.register(b, second.interface());
    try mux.setCleanupGuard(a, first.guard());
    try mux.setCleanupGuard(b, second.guard());
    const one = try mux.open(spec(a));
    const two = try mux.open(spec(b));
    try std.testing.expectError(error.BindingAlreadyRegistered, mux.register(a, first.interface()));
    try std.testing.expectError(error.UnsupportedPause, engine.pause.?(engine.ctx, one));
    try std.testing.expectEqual(@as(usize, 0), first.cancellations.items.len);
    try std.testing.expectEqual(@as(usize, 0), first.pauses.items.len);
    second.pause_error = error.ControlledPauseRejected;
    try std.testing.expectError(error.ControlledPauseRejected, engine.pause.?(engine.ctx, two));
    try std.testing.expect(!mux.jobs.items[1].pause_requested);
    second.pause_error = null;
    try engine.pause.?(engine.ctx, two);
    try engine.pause.?(engine.ctx, two);
    try std.testing.expectEqualSlices(u64, &.{1}, second.pauses.items);
    try std.testing.expectEqual(@as(usize, 0), second.cancellations.items.len);
    engine.cancel(engine.ctx, two);
    engine.cancel(engine.ctx, two);
    try std.testing.expectEqualSlices(u64, &.{1}, second.cancellations.items);
    try std.testing.expectError(error.CancellationPending, engine.pause.?(engine.ctx, two));
    try second.push(1, .paused, 40);
    const stale_pause = engine.poll(engine.ctx).?;
    try std.testing.expectEqual(two, stale_pause.job);
    try std.testing.expect(stale_pause.state == .paused and stale_pause.job_cleanup == .released);
    try std.testing.expect(!mux.jobs.items[1].terminal);
    try std.testing.expectError(error.JobsActive, mux.detach(b));
    try second.events.append(std.testing.allocator, .{ .job = 1, .state = .cancelled, .done_bytes = 40, .total_bytes = 100, .job_cleanup = .unknown });
    try std.testing.expectEqual(two, engine.poll(engine.ctx).?.job);
    try std.testing.expect(!mux.jobs.items[1].terminal);
    try second.push(1, .cancelled, 40);
    const actual_cancel = engine.poll(engine.ctx).?;
    try std.testing.expectEqual(two, actual_cancel.job);
    try std.testing.expect(actual_cancel.state == .cancelled and actual_cancel.job_cleanup == .released);
    try std.testing.expect(mux.jobs.items[1].terminal);
    try std.testing.expect(!mux.jobs.items[0].terminal);
    try std.testing.expectError(error.JobTerminal, engine.pause.?(engine.ctx, two));
    try std.testing.expectError(error.UnknownJob, engine.pause.?(engine.ctx, 99999));
}
fn stop(mux: *routing.Mux) void {
    // Complete each controlled backend through its actual interface, then
    // supply its no-native-resource cleanup receipt; never mutate Mux state.
    for (mux.jobs.items) |job| if (!job.terminal) {
        const backend: *Backend = @ptrCast(@alignCast(job.engine.ctx));
        backend.push(job.local_id, .failed, 0) catch unreachable;
    };
    while (mux.poll() != null) {}
    while (mux.registrations.items.len > 0) {
        const registered = mux.registrations.items[0];
        const backend: *Backend = @ptrCast(@alignCast(registered.engine.ctx));
        backend.release = .released;
        mux.setCleanupGuard(registered.binding, backend.guard()) catch unreachable;
        mux.detach(registered.binding) catch unreachable;
    }
    mux.deinit() catch unreachable;
}

test "transfer mux two owners reuse backend job ID while polling and cancelling the original engine fairly" {
    var adapter: Adapter = .{};
    var domain = try sessions.SessionHost.init(std.testing.allocator, &.{adapter.interface()});
    defer domain.deinit();
    const owner_a = try create(&domain);
    const owner_b = try create(&domain);
    const a = domain.queryService(owner_a.handle, .transfer).available;
    const b = domain.queryService(owner_b.handle, .transfer).available;
    var first: Backend = .{};
    defer first.deinit();
    var second: Backend = .{};
    defer second.deinit();
    var mux = routing.Mux.init(std.testing.allocator, authority(&domain));
    defer stop(&mux);
    try mux.register(a, first.interface());
    try mux.register(b, second.interface());
    try mux.setCleanupGuard(a, first.guard());
    try mux.setCleanupGuard(b, second.guard());
    const one = try mux.open(spec(a));
    const two = try mux.open(spec(b));
    try std.testing.expect(one != two);
    try std.testing.expectEqual(@as(u64, 1), mux.jobs.items[0].local_id);
    try std.testing.expectEqual(@as(u64, 1), mux.jobs.items[1].local_id);
    for ([_]u64{ 10, 20, 30 }) |done| try first.push(1, .running, done);
    try second.push(1, .running, 5);
    try std.testing.expectEqual(one, mux.poll().?.job);
    try std.testing.expectEqual(two, mux.poll().?.job);
    try std.testing.expectEqual(one, mux.poll().?.job);
    mux.cancel(one);
    mux.cancel(one);
    try std.testing.expectEqualSlices(u64, &.{1}, first.cancellations.items);
    try std.testing.expectEqual(@as(usize, 0), second.cancellations.items.len);
    try std.testing.expectError(error.JobsActive, mux.detach(a));
    try std.testing.expectEqual(@as(usize, 0), first.guard_calls);
    // Domain liveness changing must not redirect old jobs to the other owner.
    _ = try domain.requestClose(owner_a.handle, .{});
    try first.push(1, .failed, 30);
    try second.push(1, .succeeded, 100);
    var terminals: usize = 0;
    while (mux.poll()) |event| if (event.state != .running) {
        try std.testing.expect(event.job == one or event.job == two);
        terminals += 1;
    };
    try std.testing.expectEqual(@as(usize, 2), terminals);
    first.release = .unknown;
    try std.testing.expectError(error.CleanupUnknown, mux.detach(a));
    try std.testing.expectError(error.Busy, mux.deinit());
    try std.testing.expectEqual(@as(usize, 2), mux.registrations.items.len);
    first.release = .awaiting;
    try std.testing.expectError(error.CleanupPending, mux.detach(a));
    first.release = .released;
    try mux.detach(a);
    mux.cancel(one);
    try std.testing.expectEqual(@as(usize, 0), second.cancellations.items.len);
    const three = try mux.open(spec(b));
    try std.testing.expect(three > two);
    try std.testing.expectEqual(@as(u64, 2), mux.jobs.items[mux.jobs.items.len - 1].local_id);
}

test "transfer mux SSH auxiliary second generation is issued by SessionHost and forged generations stay stale" {
    var adapter: Adapter = .{};
    var ssh_adapter = adapter.interface();
    ssh_adapter.registration = .{ .plugin_id = .ssh, .workspace_kind = .terminal, .services = plugins.requiredServices(.ssh) };
    var domain = try sessions.SessionHost.init(std.testing.allocator, &.{ssh_adapter});
    defer domain.deinit();
    const target: sessions.AttachmentTarget = .{ .window_id = @fromBackingInt(1), .workspace_id = @fromBackingInt(1) };
    const accepted = try domain.create(.{ .saved = .{ .connection_id = @fromBackingInt(29), .config_revision = 4, .protocol = .ssh, .immutable_config = .{ .endpoint = .{ .host = "auxiliary-unit.invalid", .user = "fixture" } } } }, target);
    try std.testing.expect(try domain.ready(accepted.handle, accepted.operation, plugins.requiredServices(.ssh)));
    try std.testing.expect(try domain.attached(accepted.handle, .{ .target = target, .tab_id = @fromBackingInt(1) }));
    var backend: Backend = .{};
    defer backend.deinit();
    var mux = routing.Mux.init(std.testing.allocator, authority(&domain));
    defer stop(&mux);

    const first = try domain.beginAuxiliaryTransfer(accepted.handle);
    try std.testing.expectError(error.StaleBinding, mux.register(first.binding, backend.interface()));
    try std.testing.expectEqual(@as(usize, 0), backend.opens);
    try std.testing.expect(try domain.auxiliaryTransferReady(first.binding, first.key));
    try mux.register(first.binding, backend.interface());
    try std.testing.expect(!mux.isRegistered(first.binding));
    try mux.setCleanupGuard(first.binding, backend.guard());
    try std.testing.expect(mux.isRegistered(first.binding));
    var request = spec(first.binding);
    request.session_id = @backingInt(accepted.handle.session_id);
    _ = try mux.open(request);
    try std.testing.expectEqual(@as(usize, 1), backend.opens);
    try backend.push(1, .succeeded, 100);
    try std.testing.expectEqual(transfer.EngineState.succeeded, mux.poll().?.state);
    backend.release = .released;
    try std.testing.expect(try domain.auxiliaryTransferReleased(first.binding, first.key, .released));
    try mux.detach(first.binding);
    try std.testing.expect(!mux.isRegistered(first.binding));
    try std.testing.expectError(error.StaleBinding, mux.register(first.binding, backend.interface()));
    try std.testing.expectError(error.StaleBinding, mux.open(request));

    const second = try domain.beginAuxiliaryTransfer(accepted.handle);
    try std.testing.expect(second.binding.resource_owner.session.eql(accepted.handle));
    try std.testing.expect(second.binding.origin_session.?.eql(accepted.handle));
    try std.testing.expectEqual(@as(u64, 1), accepted.handle.generation);
    try std.testing.expectEqual(@as(u64, 2), second.binding.binding_generation);
    try std.testing.expect(second.binding.binding_id != first.binding.binding_id);
    try std.testing.expect(try domain.auxiliaryTransferReady(second.binding, second.key));
    try mux.register(second.binding, backend.interface());
    try std.testing.expect(!mux.isRegistered(second.binding));
    try mux.setCleanupGuard(second.binding, backend.guard());
    try std.testing.expect(mux.isRegistered(second.binding));

    var forged = second.binding;
    forged.binding_generation += 1;
    try std.testing.expectError(error.StaleBinding, mux.register(forged, backend.interface()));
    try std.testing.expectError(error.StaleBinding, mux.open(spec(forged)));
    try std.testing.expect(!mux.isRegistered(forged));
    try std.testing.expectError(error.StaleBinding, mux.register(first.binding, backend.interface()));
    try std.testing.expectError(error.StaleBinding, mux.open(spec(first.binding)));
    forged = second.binding;
    forged.origin_session.?.generation += 1;
    try std.testing.expectError(error.OwnerMismatch, mux.register(forged, backend.interface()));
    try std.testing.expectEqual(@as(usize, 1), backend.opens);

    request.transfer_binding = second.binding;
    _ = try mux.open(request);
    try std.testing.expectEqual(@as(usize, 2), backend.opens);
    try std.testing.expect(backend.last_binding.?.eql(second.binding));
    try std.testing.expect(domain.queryState(accepted.handle).?.handle.eql(accepted.handle));
    try backend.push(2, .succeeded, 100);
    try std.testing.expectEqual(transfer.EngineState.succeeded, mux.poll().?.state);
    try std.testing.expect(try domain.auxiliaryTransferReleased(second.binding, second.key, .released));
    try mux.detach(second.binding);
}

test "transfer mux rejects missing forged stale generation and shared engine binding without retargeting" {
    var adapter: Adapter = .{};
    var domain = try sessions.SessionHost.init(std.testing.allocator, &.{adapter.interface()});
    defer domain.deinit();
    const old = try create(&domain);
    const a = domain.queryService(old.handle, .transfer).available;
    const other = try create(&domain);
    const b = domain.queryService(other.handle, .transfer).available;
    var first: Backend = .{};
    defer first.deinit();
    var second: Backend = .{};
    defer second.deinit();
    var mux = routing.Mux.init(std.testing.allocator, authority(&domain));
    defer stop(&mux);
    try mux.register(a, first.interface());
    try mux.register(a, first.interface());
    try std.testing.expectEqual(@as(usize, 1), mux.registrations.items.len);
    try std.testing.expectError(error.EngineAlreadyRegistered, mux.register(b, first.interface()));
    try std.testing.expectError(error.BindingAlreadyRegistered, mux.register(a, second.interface()));
    var request = spec(a);
    request.transfer_binding = null;
    try std.testing.expectError(error.MissingTransferBinding, mux.open(request));
    request = spec(a);
    request.session_id = @backingInt(other.handle.session_id);
    try std.testing.expectError(error.OwnerMismatch, mux.open(request));
    request.transfer_binding = domain.queryService(old.handle, .directory).available;
    try std.testing.expectError(error.ServiceKindMismatch, mux.open(request));
    var forged = a;
    forged.binding_id += 1000;
    try std.testing.expectError(error.StaleBinding, mux.register(forged, second.interface()));
    request = spec(a);
    request.transfer_binding.?.binding_generation += 1;
    try std.testing.expectError(error.StaleBinding, mux.open(request));
    try std.testing.expectError(error.CleanupGuardMissing, mux.detach(a));
    try std.testing.expect(try domain.failed(old.handle, old.operation, .{ .domain = .plugin, .code = "fixture", .cleanup = .released, .safe_message = "fixture" }));
    const replacement = try domain.retry(old.handle);
    try std.testing.expect(try domain.ready(replacement.handle, replacement.operation, plugins.requiredServices(.sftp)));
    const fresh = domain.queryService(replacement.handle, .transfer).available;
    try std.testing.expectError(error.StaleBinding, mux.open(spec(a)));
    try std.testing.expectEqual(@as(usize, 0), first.opens);
    try std.testing.expectError(error.StaleBinding, mux.open(spec(fresh)));
    try mux.register(fresh, second.interface());
    _ = try mux.open(spec(fresh));
    try std.testing.expect(second.last_binding.?.resource_owner.session.eql(replacement.handle));
    try std.testing.expectEqual(@as(usize, 0), first.opens);
}

test "transfer mux Manager owns full binding in dedup and queued dispatch while legacy remains optional" {
    var adapter: Adapter = .{};
    var domain = try sessions.SessionHost.init(std.testing.allocator, &.{adapter.interface()});
    defer domain.deinit();
    const owner_a = try create(&domain);
    const owner_b = try create(&domain);
    const a = domain.queryService(owner_a.handle, .transfer).available;
    const b = domain.queryService(owner_b.handle, .transfer).available;
    var first: Backend = .{};
    defer first.deinit();
    var second: Backend = .{};
    defer second.deinit();
    var mux = routing.Mux.init(std.testing.allocator, authority(&domain));
    defer stop(&mux);
    try mux.register(a, first.interface());
    try mux.register(b, second.interface());
    var manager = try transfer.Manager.init(std.testing.allocator, mux.engine(), 2, .{ .max_attempts = 1 });
    defer manager.deinit();
    const text = try std.testing.allocator.dupe(u8, "/original");
    var request = spec(a);
    request.sources = &.{text};
    const one = try manager.enqueue(request);
    request.transfer_binding = b;
    const two = try manager.enqueue(request);
    try std.testing.expect(one != two);
    try std.testing.expectEqual(two, try manager.enqueue(request));
    @memset(text, 'x');
    std.testing.allocator.free(text);
    manager.tick(0);
    try std.testing.expect(first.last_binding.?.eql(a));
    try std.testing.expect(second.last_binding.?.eql(b));
    try std.testing.expectEqualStrings("/original", first.source[0..first.source_len]);
    try std.testing.expectEqualStrings("/original", second.source[0..second.source_len]);
    try manager.cancel(one);
    try std.testing.expectEqualSlices(u64, &.{1}, first.cancellations.items);
    try std.testing.expectEqual(@as(usize, 0), second.cancellations.items.len);
    try first.push(1, .cancelled, 0);
    try second.push(1, .succeeded, 100);
    manager.tick(1);
    try std.testing.expectEqual(transfer.State.cancelled, manager.progress(one).?.state);
    try std.testing.expectEqual(transfer.State.succeeded, manager.progress(two).?.state);

    // The same existing Manager still supports a direct single engine with no
    // transfer_binding; only Mux requires the frozen route.
    var legacy: Backend = .{};
    defer legacy.deinit();
    var direct = try transfer.Manager.init(std.testing.allocator, legacy.interface(), 1, .{ .max_attempts = 1 });
    defer direct.deinit();
    var plain = spec(a);
    plain.transfer_binding = null;
    _ = try direct.enqueue(plain);
    direct.tick(0);
    try std.testing.expectEqual(@as(usize, 1), legacy.opens);
    try std.testing.expect(legacy.last_binding == null);
}

test "transfer mux SftpEngine acceptance keeps the exact original transfer ServiceHandle" {
    var adapter: Adapter = .{};
    var domain = try sessions.SessionHost.init(std.testing.allocator, &.{adapter.interface()});
    defer domain.deinit();
    const owner = try create(&domain);
    const binding = domain.queryService(owner.handle, .transfer).available;
    const engine = try sftp.SftpEngine.init(std.testing.allocator);
    // This copy-boundary test deliberately supplies an inactive Session; the
    // real worker fails before protocol IO. It is not a native transfer proof.
    var inactive: ssh.Session = .{};
    engine.attachSession(&inactive);
    defer engine.deinit();
    var request = spec(binding);
    _ = try engine.open(request);
    request.transfer_binding.?.binding_generation += 1;
    try std.testing.expect(engine.jobs.items[0].spec.transfer_binding.?.eql(binding));
    const deadline = clock.monotonicNs() + 5 * std.time.ns_per_s;
    while (!engine.jobs.items[0].worker_done.load(.acquire) or !engine.owner_done.load(.acquire)) {
        if (clock.monotonicNs() >= deadline) return error.TestTimeout;
        var unused: [1]std.c.pollfd = undefined;
        _ = std.c.poll(&unused, 0, 2);
    }
    try std.testing.expect(engine.detachIfIdle());
}

fn nativeReceipt(raw: *anyopaque, _: sessions.ServiceHandle) routing.ReleaseReceipt {
    const engine: *sftp.SftpEngine = @ptrCast(@alignCast(raw));
    return if (engine.detachIfIdle()) .released else .awaiting;
}
fn closeNativeMux(mux: *routing.Mux) void {
    for (mux.jobs.items) |job| mux.cancel(job.id);
    const deadline = clock.monotonicNs() + 20 * std.time.ns_per_s;
    while (mux.registrations.items.len != 0) {
        while (mux.poll() != null) {}
        mux.detach(mux.registrations.items[0].binding) catch {
            if (clock.monotonicNs() >= deadline) @panic("native Mux cleanup did not release");
            var unused: [1]std.c.pollfd = undefined;
            _ = std.c.poll(&unused, 0, 2);
        };
    }
    mux.deinit() catch unreachable;
}

test "transfer mux optional VM two independent SftpEngines download under different original owners" {
    const password_raw = std.c.getenv("ZEROWORK_VM_PASSWORD") orelse return error.SkipZigTest;
    const password = try std.testing.allocator.dupeSentinel(u8, std.mem.span(password_raw), 0);
    defer std.testing.allocator.free(password);
    var adapter: Adapter = .{};
    var domain = try sessions.SessionHost.init(std.testing.allocator, &.{adapter.interface()});
    defer domain.deinit();
    var handles: [2]sessions.ServiceHandle = undefined;
    var open_keys: [2]sessions.OperationKey = undefined;
    for (&handles, &open_keys) |*binding, *key| {
        const accepted = try domain.create(.{ .saved = .{ .connection_id = @fromBackingInt(19), .config_revision = 4, .protocol = .sftp, .immutable_config = .{ .endpoint = .{ .host = "192.0.2.10", .user = "root" }, .auth = .{ .password = password } } } }, .{ .window_id = @fromBackingInt(1), .workspace_id = @fromBackingInt(1) });
        try std.testing.expect(try domain.ready(accepted.handle, accepted.operation, plugins.requiredServices(.sftp)));
        binding.* = domain.queryService(accepted.handle, .transfer).available;
        key.* = try domain.journal.begin(.{ .session = accepted.handle }, 1);
    }
    var library = try ssh.Library.init();
    defer library.deinit();
    var first_session = try ssh.Session.connect(&library, .{ .host = "192.0.2.10", .user = "root", .auth = .{ .password = password }, .host_key_decision = .trust_once, .open_shell = false, .connect_timeout_ms = 5000, .operation_key = open_keys[0] });
    defer first_session.close();
    var second_session = try ssh.Session.connect(&library, .{ .host = "192.0.2.10", .user = "root", .auth = .{ .password = password }, .host_key_decision = .trust_once, .open_shell = false, .connect_timeout_ms = 5000, .operation_key = open_keys[1] });
    defer second_session.close();
    try std.testing.expect(first_session.socket_fd != second_session.socket_fd);
    try std.testing.expect(first_session.channel == null and second_session.channel == null);
    first_session.setBlocking();
    second_session.setBlocking();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const directory = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(directory);
    const first = try sftp.SftpEngine.init(std.testing.allocator);
    defer first.deinit();
    const second = try sftp.SftpEngine.init(std.testing.allocator);
    defer second.deinit();
    first.attachSession(&first_session);
    second.attachSession(&second_session);
    var mux = routing.Mux.init(std.testing.allocator, authority(&domain));
    defer closeNativeMux(&mux);
    try mux.register(handles[0], first.engine());
    try mux.register(handles[1], second.engine());
    try mux.setCleanupGuard(handles[0], .{ .context = first, .receipt = nativeReceipt });
    try mux.setCleanupGuard(handles[1], .{ .context = second, .receipt = nativeReceipt });
    var manager = try transfer.Manager.init(std.testing.allocator, mux.engine(), 2, .{ .max_attempts = 1 });
    defer manager.deinit();
    const names = [_][]const u8{ "owner-a", "owner-b" };
    var jobs: [2]transfer.JobId = undefined;
    for (&jobs, handles, names) |*job, binding, name| job.* = try manager.enqueue(.{ .session_id = @backingInt(binding.resource_owner.session.session_id), .transfer_binding = binding, .direction = .download, .sources = &.{"/etc/os-release"}, .remote_dir = "/etc", .local_dir = directory, .rename = name, .resume_transfer = false });
    manager.tick(0);
    try std.testing.expectEqual(@as(u64, 1), first.jobs.items[0].id);
    try std.testing.expectEqual(@as(u64, 1), second.jobs.items[0].id);
    try std.testing.expect(mux.jobs.items[0].id != mux.jobs.items[1].id);
    const deadline = clock.monotonicNs() + 20 * std.time.ns_per_s;
    while (manager.progress(jobs[0]).?.state != .succeeded or manager.progress(jobs[1]).?.state != .succeeded) {
        manager.tick(1);
        for (jobs) |job| try std.testing.expect(manager.progress(job).?.state != .failed);
        if (clock.monotonicNs() >= deadline) return error.VmTransferTimeout;
        var unused: [1]std.c.pollfd = undefined;
        _ = std.c.poll(&unused, 0, 2);
    }
    for (handles) |binding| while (true) {
        mux.detach(binding) catch |err| {
            if (err != error.CleanupPending or clock.monotonicNs() >= deadline) return err;
            var unused: [1]std.c.pollfd = undefined;
            _ = std.c.poll(&unused, 0, 2);
            continue;
        };
        break;
    };
    var bytes: [2][4096]u8 = undefined;
    var lengths: [2]usize = undefined;
    for (names, &bytes, &lengths) |name, *buffer, *length| {
        var file = try tmp.dir.openFile(std.testing.io, name, .{});
        defer file.close(std.testing.io);
        length.* = try file.readPositionalAll(std.testing.io, buffer, 0);
        try std.testing.expect(length.* > 0 and length.* < buffer.len);
    }
    try std.testing.expectEqualSlices(u8, bytes[0][0..lengths[0]], bytes[1][0..lengths[1]]);
    try std.testing.expect(std.mem.indexOf(u8, bytes[0][0..lengths[0]], "ID=") != null);
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(std.testing.io, "owner-a.part", .{}));
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(std.testing.io, "owner-b.part", .{}));
    std.debug.print("SFTP_MUX_VM_PASS owners=2 sessions=2 engines=2 backend_ids=1,1 mux_ids=unique bytes_each={d} same_content=true cleanup=released shell=false remote_mutation=false\n", .{lengths[0]});
}
