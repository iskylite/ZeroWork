//! Shared-journal worker regressions. No endpoint or user data is opened.
const std = @import("std");
const ledger = @import("plugins/bmc_ikvm/management_journal.zig");
const svc = @import("plugins/bmc_ikvm/services.zig");
const T = std.testing;
const a = T.allocator;
const owner: svc.identity.SessionHandle = .{ .session_id = @fromBackingInt(91), .generation = 3 };
const anchor = "2026-10-31T01:00:00Z";
const target = "https://bmc.invalid:443/redfish/v1/Systems/one";

fn execution(id: u64) svc.Execution {
    return .{ .call = .{ .owner = owner, .binding_generation = 1 }, .operation = .{ .owner = .{ .session = owner }, .operation_id = id }, .nonce = @splat(@intCast(id)), .system_uri = "/redfish/v1/Systems/one", .capability_revision = 1, .grant_revision = 1 };
}
const Start = struct {
    ready: std.atomic.Value(usize) = .init(0),
    run: std.atomic.Value(bool) = .init(false),
    reader_observed: std.atomic.Value(bool) = .init(false),
    done: std.atomic.Value(usize) = .init(0),
    fn wait(self: *Start) void {
        _ = self.ready.fetchAdd(1, .release);
        while (!self.run.load(.acquire)) std.atomic.spinLoopHint();
    }
    fn begin(self: *Start, count: usize) void {
        while (self.ready.load(.acquire) != count) std.atomic.spinLoopHint();
        self.run.store(true, .release);
    }
};
const ParallelWorker = struct {
    const iterations = 8;
    journal: *ledger.Journal,
    start: *Start,
    number: usize,
    failure: ?anyerror = null,
    fn run(self: *ParallelWorker) void {
        self.start.wait();
        defer _ = self.start.done.fetchAdd(1, .release);
        self.exercise() catch |err| {
            self.failure = err;
        };
    }
    fn exercise(self: *ParallelWorker) !void {
        for (0..iterations) |iteration| {
            const id: u64 = @intCast(self.number * iterations + iteration + 1);
            const ex = execution(id);
            var target_buffer: [128]u8 = undefined;
            const resource = try std.fmt.bufPrint(&target_buffer, "https://bmc.invalid:443/redfish/v1/Systems/{d}", .{id});
            var identity_buffer: [32]u8 = undefined;
            const system = try std.fmt.bufPrint(&identity_buffer, "system-{d}", .{id});
            var task_buffer: [64]u8 = undefined;
            const task = try std.fmt.bufPrint(&task_buffer, "/redfish/v1/TaskService/Tasks/{d}", .{id});
            const baseline: svc.BootState = .{ .enabled = "Disabled", .target = "Hdd", .mode = "UEFI" };
            const changed: svc.BootState = .{ .enabled = "Once", .target = "Pxe", .mode = "UEFI" };
            const reservation = try self.journal.reserve(ex, resource, system, .{ .boot = changed }, .{ .boot = baseline, .etag = "\"baseline\"" });
            try T.expect(!reservation.existing);
            var prepared = try self.journal.snapshot(a, reservation.index);
            defer prepared.deinit();
            if (iteration == 0) while (!self.start.reader_observed.load(.acquire)) std.atomic.spinLoopHint();
            try self.journal.collectLastResetBaseline(reservation.index, anchor);
            try self.journal.beginDispatch(reservation.index);
            try self.journal.setResult(reservation.index, .{ .operation = ex.operation, .phase = .tracking_task, .dispatched = true, .http_status = 202, .task_uri = task, .current_boot = baseline, .pending_boot = changed });
            var tracking = (try self.journal.snapshotOperationOrNonce(a, ex.operation, ex.nonce)).?;
            defer tracking.deinit();
            var tracking_result = (try self.journal.snapshotResult(a, ex.operation)).?;
            defer tracking_result.deinit();
            try self.journal.setResult(reservation.index, .{ .operation = ex.operation, .phase = .succeeded, .dispatched = true, .http_status = 200, .current_boot = changed });

            // Every snapshot survives this worker's subsequent arena swaps and
            // the other workers' independently persisted management operations.
            try T.expectEqual(svc.Phase.queued, prepared.value.phase);
            try T.expect(!prepared.value.dispatch_started);
            try T.expect(prepared.value.baseline.last_reset_time == null);
            try T.expectEqualStrings(resource, prepared.value.canonical_target);
            try T.expectEqualStrings(system, prepared.value.system_identity);
            try T.expectEqualStrings("\"baseline\"", prepared.value.baseline.etag.?);
            try T.expectEqualStrings("Hdd", prepared.value.baseline.boot.?.target.?);
            try T.expectEqualStrings("Pxe", prepared.value.parameters.boot.target.?);
            try T.expectEqual(reservation.index, tracking.index);
            try T.expectEqualStrings(anchor, tracking.entry.value.baseline.last_reset_time.?);
            try T.expectEqual(svc.Phase.tracking_task, tracking.entry.value.phase);
            try T.expectEqualStrings(task, tracking.entry.value.task_uri.?);
            try T.expectEqual(svc.Phase.tracking_task, tracking_result.value.phase);
            try T.expectEqualStrings(task, tracking_result.value.task_uri.?);
            try T.expectEqualStrings("Hdd", tracking_result.value.current_boot.?.target.?);
            try T.expectEqualStrings("Pxe", tracking_result.value.pending_boot.?.target.?);
        }
    }
};

test "BMC journal concurrency independent resources persist complete transactions and retain owned snapshots" {
    var backend: ledger.MemoryBackend = .{ .allocator = a };
    defer backend.deinit();
    var journal = try ledger.Journal.init(a, backend.backend());
    defer journal.deinit();
    var start: Start = .{};
    const worker_count = 4;
    var workers: [worker_count]ParallelWorker = undefined;
    var threads: [worker_count]std.Thread = undefined;
    var spawned: usize = 0;
    defer {
        start.run.store(true, .release);
        start.reader_observed.store(true, .release);
        for (threads[0..spawned]) |thread| thread.join();
    }
    for (&workers, 0..) |*worker, number| {
        worker.* = .{ .journal = &journal, .start = &start, .number = number };
        threads[spawned] = try std.Thread.spawn(.{}, ParallelWorker.run, .{worker});
        spawned += 1;
    }
    start.begin(worker_count);
    var reads: usize = 0;
    var sampled = false;
    while (start.done.load(.acquire) != worker_count) {
        const ex = execution(@intCast(reads % (worker_count * ParallelWorker.iterations) + 1));
        if (try journal.snapshotOperation(a, ex.operation)) |snapshot| {
            var owned = snapshot;
            defer owned.deinit();
            try T.expect(owned.entry.value.key().eql(ex.operation));
            try T.expectEqualSlices(u8, &ex.nonce, &owned.entry.value.nonce);
            sampled = true;
            start.reader_observed.store(true, .release);
        }
        reads += 1;
    }
    for (workers) |worker| if (worker.failure) |err| return err;
    try T.expect(sampled);
    try T.expectEqual(@as(usize, worker_count * ParallelWorker.iterations), journal.entries.len);
    try T.expectEqual(@as(usize, worker_count * ParallelWorker.iterations * 5), backend.writes);
    for (journal.entries) |entry| {
        try T.expectEqual(svc.Phase.succeeded, entry.phase);
        try T.expect(entry.dispatch_started);
        var latest = (try journal.snapshotResult(a, entry.key())).?;
        defer latest.deinit();
        try T.expectEqualStrings("Pxe", latest.value.current_boot.?.target.?);
    }
    // Reopening durable bytes must retain every worker's terminal operation.
    var reopened = try ledger.Journal.init(a, backend.backend());
    defer reopened.deinit();
    try T.expectEqual(journal.entries.len, reopened.entries.len);
    for (reopened.entries) |entry| try T.expectEqual(svc.Phase.succeeded, entry.phase);
}

const DuplicateWorker = struct {
    journal: *ledger.Journal,
    start: *Start,
    reservation: ?ledger.Reservation = null,
    dispatched: bool = false,
    failure: ?anyerror = null,
    fn run(self: *DuplicateWorker) void {
        self.start.wait();
        defer _ = self.start.done.fetchAdd(1, .release);
        self.exercise() catch |err| {
            self.failure = err;
        };
    }
    fn exercise(self: *DuplicateWorker) !void {
        const ex = execution(91);
        self.reservation = try self.journal.reserve(ex, target, "same-system", .{ .power = .graceful_restart }, .{ .power = .on });
        self.journal.beginDispatch(self.reservation.?.index) catch |err| switch (err) {
            error.OperationAlreadyDispatched => return,
            else => return err,
        };
        self.dispatched = true;
    }
};

test "BMC journal concurrency matching nonce and operation reserve and dispatch exactly once" {
    var backend: ledger.MemoryBackend = .{ .allocator = a };
    defer backend.deinit();
    var journal = try ledger.Journal.init(a, backend.backend());
    defer journal.deinit();
    var start: Start = .{};
    const worker_count = 8;
    var workers: [worker_count]DuplicateWorker = undefined;
    var threads: [worker_count]std.Thread = undefined;
    var spawned: usize = 0;
    defer {
        start.run.store(true, .release);
        for (threads[0..spawned]) |thread| thread.join();
    }
    for (&workers) |*worker| {
        worker.* = .{ .journal = &journal, .start = &start };
        threads[spawned] = try std.Thread.spawn(.{}, DuplicateWorker.run, .{worker});
        spawned += 1;
    }
    start.begin(worker_count);
    while (start.done.load(.acquire) != worker_count) std.atomic.spinLoopHint();
    var prepared: usize = 0;
    var dispatched: usize = 0;
    for (workers) |worker| {
        if (worker.failure) |err| return err;
        try T.expectEqual(@as(usize, 0), worker.reservation.?.index);
        if (!worker.reservation.?.existing) prepared += 1;
        if (worker.dispatched) dispatched += 1;
    }
    try T.expectEqual(@as(usize, 1), prepared);
    try T.expectEqual(@as(usize, 1), dispatched);
    try T.expectEqual(@as(usize, 1), journal.entries.len);
    try T.expectEqual(@as(usize, 2), backend.writes);
    const ex = execution(91);
    var nonce_conflict = execution(92);
    nonce_conflict.nonce = ex.nonce;
    var operation_conflict = ex;
    operation_conflict.nonce = execution(92).nonce;
    try T.expectError(error.OperationConflict, journal.reserve(nonce_conflict, target, "same-system", .{ .power = .graceful_restart }, .{}));
    try T.expectError(error.OperationConflict, journal.reserve(operation_conflict, target, "same-system", .{ .power = .graceful_restart }, .{}));
    try T.expectError(error.OperationConflict, journal.reserve(ex, target, "same-system", .{ .power = .force_restart }, .{}));
    var by_operation = (try journal.snapshotOperation(a, ex.operation)).?;
    defer by_operation.deinit();
    var by_nonce = (try journal.snapshotOperationOrNonce(a, execution(92).operation, ex.nonce)).?;
    defer by_nonce.deinit();
    try T.expectEqual(by_operation.index, by_nonce.index);
    try T.expect(by_nonce.entry.value.key().eql(ex.operation));
    try T.expectEqualSlices(u8, &ex.nonce, &by_nonce.entry.value.nonce);
    try T.expectEqual(@as(usize, 2), backend.writes);
}

test "BMC journal concurrency failed durable replacement rolls back and retains unknown without redispatch" {
    var backend: ledger.MemoryBackend = .{ .allocator = a };
    defer backend.deinit();
    var journal = try ledger.Journal.init(a, backend.backend());
    defer journal.deinit();
    const ex = execution(51);
    const reserved = try journal.reserve(ex, target, "rollback-system", .{ .power = .graceful_restart }, .{ .power = .on });
    const prepared_disk = try a.dupe(u8, backend.bytes.?);
    defer a.free(prepared_disk);
    backend.fail_writes = true;
    try T.expectError(error.InjectedJournalFailure, journal.reserve(execution(52), target, "other-system", .{ .power = .on }, .{ .power = .off }));
    try T.expect(journal.find(execution(52).operation) == null);
    try T.expectError(error.InjectedJournalFailure, journal.collectLastResetBaseline(reserved.index, anchor));
    try T.expectError(error.InjectedJournalFailure, journal.beginDispatch(reserved.index));
    var prepared = try journal.snapshot(a, reserved.index);
    defer prepared.deinit();
    try T.expect(!prepared.value.dispatch_started);
    try T.expect(prepared.value.baseline.last_reset_time == null);
    try T.expectEqual(svc.Phase.queued, prepared.value.phase);
    try T.expectEqualSlices(u8, prepared_disk, backend.bytes.?);
    try T.expectEqual(@as(usize, 1), backend.writes);

    backend.fail_writes = false;
    try journal.collectLastResetBaseline(reserved.index, anchor);
    try journal.beginDispatch(reserved.index);
    try journal.setResult(reserved.index, .{ .operation = ex.operation, .phase = .outcome_unknown, .reason = .transport_lost, .dispatched = true, .task_uri = "/redfish/v1/TaskService/Tasks/51" });
    var unknown = (try journal.snapshotResult(a, ex.operation)).?;
    defer unknown.deinit();
    const unknown_disk = try a.dupe(u8, backend.bytes.?);
    defer a.free(unknown_disk);
    backend.fail_writes = true;
    try T.expectError(error.InjectedJournalFailure, journal.setResult(reserved.index, .{ .operation = ex.operation, .phase = .succeeded, .dispatched = true }));
    try T.expectError(error.OperationAlreadyDispatched, journal.beginDispatch(reserved.index));
    var after_failure = (try journal.snapshotResult(a, ex.operation)).?;
    defer after_failure.deinit();
    try T.expectEqual(svc.Phase.outcome_unknown, after_failure.value.phase);
    try T.expect(after_failure.value.dispatched);
    try T.expectEqualStrings(unknown.value.task_uri.?, after_failure.value.task_uri.?);
    try T.expectEqualSlices(u8, unknown_disk, backend.bytes.?);
    const duplicate = try journal.reserve(ex, target, "rollback-system", .{ .power = .graceful_restart }, .{});
    try T.expect(duplicate.existing);

    backend.fail_writes = false;
    _ = try journal.reserve(execution(52), target, "other-system", .{ .power = .on }, .{ .power = .off });
    try T.expectEqual(svc.Phase.outcome_unknown, unknown.value.phase);
    try T.expectEqualStrings("/redfish/v1/TaskService/Tasks/51", unknown.value.task_uri.?);
    var recovered = try ledger.Journal.init(a, backend.backend());
    defer recovered.deinit();
    var recovered_result = (try recovered.snapshotResult(a, ex.operation)).?;
    defer recovered_result.deinit();
    try T.expectEqual(svc.Phase.outcome_unknown, recovered_result.value.phase);
    try T.expectError(error.OperationAlreadyDispatched, recovered.beginDispatch(reserved.index));
}

test "BMC journal concurrency schema one missing LastResetTime is compatible and anchors freeze before dispatch" {
    for ([_]bool{ false, true }) |legacy| {
        var backend: ledger.MemoryBackend = .{ .allocator = a };
        defer backend.deinit();
        const ex = execution(71);
        {
            var journal = try ledger.Journal.init(a, backend.backend());
            defer journal.deinit();
            const reservation = try journal.reserve(ex, target, "anchor-system", .{ .power = .graceful_restart }, .{ .power = .on });
            for ([_][]const u8{ "2026-02-30T00:00:00Z", "2026-01-01T00:00:00-00:00", "2026-01-01T00:00:00" }) |invalid| try T.expectError(error.InvalidJournalEntry, journal.collectLastResetBaseline(reservation.index, invalid));
            try T.expectEqual(@as(usize, 1), backend.writes);
            try journal.collectLastResetBaseline(reservation.index, anchor);
            try T.expectError(error.OperationAlreadyDispatched, journal.collectLastResetBaseline(reservation.index, "2026-11-01T01:00:00Z"));
            try journal.beginDispatch(reservation.index);
            try T.expectError(error.OperationAlreadyDispatched, journal.collectLastResetBaseline(reservation.index, anchor));
            try journal.setResult(reservation.index, .{ .operation = ex.operation, .phase = .outcome_unknown, .reason = .transport_lost, .dispatched = true });
            const unsent = try journal.reserve(execution(72), target, "cancelled-system", .{ .power = .on }, .{ .power = .off });
            try journal.setResult(unsent.index, .{ .operation = execution(72).operation, .phase = .cancelled_unsent });
            try T.expectError(error.OperationAlreadyDispatched, journal.collectLastResetBaseline(unsent.index, anchor));
        }
        if (legacy) {
            var parsed = try std.json.parseFromSlice(std.json.Value, a, backend.bytes.?, .{ .allocate = .alloc_always });
            defer parsed.deinit();
            for (parsed.value.object.getPtr("entries").?.array.items) |*entry| try T.expect(entry.object.getPtr("baseline").?.object.swapRemove("last_reset_time"));
            const previous = backend.bytes.?;
            backend.bytes = try std.json.Stringify.valueAlloc(a, parsed.value, .{});
            a.free(previous);
        }
        var recovered = try ledger.Journal.init(a, backend.backend());
        defer recovered.deinit();
        var snapshot = (try recovered.snapshotOperation(a, ex.operation)).?;
        defer snapshot.deinit();
        try T.expectEqual(legacy, snapshot.entry.value.baseline.last_reset_time == null);
        if (!legacy) try T.expectEqualStrings(anchor, snapshot.entry.value.baseline.last_reset_time.?);
        try T.expectEqual(svc.Phase.outcome_unknown, snapshot.entry.value.phase);
        try T.expect(snapshot.entry.value.dispatch_started);
        try T.expectError(error.OperationAlreadyDispatched, recovered.beginDispatch(snapshot.index));
        try T.expectError(error.OperationAlreadyDispatched, recovered.collectLastResetBaseline(snapshot.index, anchor));
    }
}
