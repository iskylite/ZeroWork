const std = @import("std");
const driver_mod = @import("host_execution_driver.zig");
const controller = @import("host_execution.zig");
const host = @import("host_tools.zig");
const runtime = @import("lifecycle_runtime.zig");
const identity = @import("../host/identity.zig");
const terminal = @import("../host/terminal_service.zig");
const execution = terminal.execution;
const a = std.testing.allocator;
fn pause() void {
    const delay: std.c.timespec = .{ .sec = 0, .nsec = std.time.ns_per_ms };
    _ = std.c.nanosleep(&delay, null);
}
const Pump = struct {
    const Call = struct { context: *anyopaque, function: *const fn (*anyopaque) anyerror!void, done: std.atomic.Value(bool) = .init(false), failure: ?anyerror = null };
    mutex: std.atomic.Mutex = .unlocked,
    pending: ?*Call = null,
    fn lock(self: *Pump) void {
        while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
    }
    fn schedule(raw: *anyopaque, context: *anyopaque, function: *const fn (*anyopaque) anyerror!void, cancel: ?*@import("provider.zig").CancelToken) !void {
        const self: *Pump = @ptrCast(@alignCast(raw));
        var call: Call = .{ .context = context, .function = function };
        self.lock();
        if (self.pending != null) {
            self.mutex.unlock();
            return error.WorkerBusy;
        }
        self.pending = &call;
        self.mutex.unlock();
        while (!call.done.load(.acquire)) {
            if (cancel) |token| if (token.isCancelled()) {
                self.lock();
                if (self.pending == &call) {
                    self.pending = null;
                    self.mutex.unlock();
                    return error.CancelledBeforeDispatch;
                }
                self.mutex.unlock();
            };
            pause();
        }
        if (call.failure) |failure| return failure;
    }
    fn pump(self: *Pump) void {
        self.lock();
        const call = self.pending;
        self.pending = null;
        self.mutex.unlock();
        if (call) |value| {
            value.function(value.context) catch |err| {
                value.failure = err;
            };
            value.done.store(true, .release);
        }
    }
};
/// Deterministic terminal mailbox receipts isolate Driver routing from native
/// guard readiness. This test does not claim a new PTY/foreground-exit proof.
const Backend = struct {
    const Target = struct {
        snapshot: execution.Snapshot,
        handed: bool = false,
        revoked: bool = false,
        revoke_calls: usize = 0,
        revoke_attempts: usize = 0,
        interrupt_calls: usize = 0,
        revoke_busy: bool = false,
        request_count: usize = 0,
    };
    ui_thread: std.Thread.Id,
    targets: [5]Target,
    handoff_busy: bool = true,
    handoff_busy_seen: bool = false,
    permit_drain: bool = false,
    output_scope: execution.OutputScope = .exact,
    fn check(self: *Backend) !void {
        if (std.Thread.getCurrentId() != self.ui_thread) return error.ControllerThreadViolated;
    }
    fn service(target: *Target) terminal.Service {
        // terminal_call below is the only allowed facade operation in this
        // deterministic backend; no native vtable is dereferenced.
        return .{ .context = target, .binding = undefined, .vtable = undefined };
    }
    fn authorize(raw: *anyopaque, _: host.Invocation, reference: []const u8, _: []const u8, _: [32]u8) !controller.Target {
        const self: *Backend = @ptrCast(@alignCast(raw));
        try self.check();
        const index = try std.fmt.parseInt(usize, reference, 10);
        if (index >= self.targets.len) return error.NotAuthorized;
        const target = &self.targets[index];
        return .{ .handle = target.snapshot.owner, .service = service(target), .ownership_revision = 1 };
    }
    fn resolve(raw: *anyopaque, _: host.Context, owner: identity.SessionHandle) !terminal.Service {
        const self: *Backend = @ptrCast(@alignCast(raw));
        try self.check();
        for (&self.targets) |*target| if (target.snapshot.owner.eql(owner)) return service(target);
        return error.StaleGeneration;
    }
    fn handoff(raw: *anyopaque, owner: identity.SessionHandle) !void {
        const self: *Backend = @ptrCast(@alignCast(raw));
        try self.check();
        if (self.handoff_busy) {
            self.handoff_busy_seen = true;
            return error.WorkerBusy;
        }
        for (&self.targets) |*target| if (target.snapshot.owner.eql(owner)) {
            target.handed = true;
            return;
        };
        return error.StaleGeneration;
    }
    fn call(raw: *anyopaque, facade: terminal.Service, action: controller.TerminalAction) !controller.TerminalResult {
        const self: *Backend = @ptrCast(@alignCast(raw));
        try self.check();
        const target: *Target = @ptrCast(@alignCast(facade.context));
        switch (action) {
            .snapshot => {
                if (target.revoked and self.permit_drain and !target.snapshot.local_released) {
                    target.snapshot.local_released = true;
                    target.snapshot.input_ready = true;
                    target.snapshot.revision += 1;
                }
                return .{ .snapshot = target.snapshot };
            },
            .request => |request| {
                const fence = target.snapshot.execution_fence + 1;
                target.request_count += 1;
                target.snapshot = .{ .owner = target.snapshot.owner, .execution_id = request.execution_id, .command_hash = request.command_hash, .execution_fence = fence, .execution_input_epoch = request.expected_input_epoch, .input_epoch = request.expected_input_epoch, .grant = .{ .execution_id = request.execution_id, .task_id = request.task_id, .fence = fence, .input_epoch = request.expected_input_epoch, .ownership_revision = request.ownership_revision }, .state = .running, .interactive_execution = true, .local_released = false, .input_ready = false, .revision = target.snapshot.revision + 1, .output_scope = self.output_scope };
                target.revoked = false;
                target.handed = false;
            },
            .revoke => |value| {
                target.revoke_attempts += 1;
                if (target.revoke_busy) return error.WorkerBusy;
                if (!value.takeover) target.interrupt_calls += 1;
                target.revoke_calls += 1;
                target.revoked = true;
                target.snapshot.input_handed_off = value.takeover;
                if (!value.takeover) target.snapshot.state = .outcome_unknown;
                target.snapshot.grant = null;
                target.snapshot.remote_effect_unknown = !value.takeover;
                target.snapshot.revision += 1;
            },
            .renew => {},
            .output => |value| return .{ .output = .{ .bytes = try value.allocator.alloc(u8, 0), .start_cursor = 0, .next_cursor = 0, .gap = false, .truncated = false } },
        }
        return .done;
    }
};
const Tool = struct {
    driver: *driver_mod.Driver,
    invocation: host.Invocation,
    result: ?host.Result = null,
    failure: ?anyerror = null,
    done: std.atomic.Value(bool) = .init(false),
    fn run(self: *Tool) void {
        self.result = self.driver.execute(self.invocation, null) catch |err| {
            self.failure = err;
            self.done.store(true, .release);
            return;
        };
        self.done.store(true, .release);
    }
    fn execute(driver: *driver_mod.Driver, pump: *Pump, invocation: host.Invocation) !host.Result {
        var tool: Tool = .{ .driver = driver, .invocation = invocation };
        const thread = try std.Thread.spawn(.{}, Tool.run, .{&tool});
        const until = now() + 3000;
        while (!tool.done.load(.acquire)) {
            pump.pump();
            if (now() >= until) driver.requestShutdown();
            pause();
        }
        thread.join();
        if (tool.failure) |failure| return failure;
        return tool.result.?;
    }
};

test "execution driver precise input takeover preserves Task and read-only observation without interruption" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    defer a.free(path);
    const journal = try runtime.ProcessJournal.acquire(.{ .data_root = path, .path = "takeover-driver.json", .dir = tmp.dir, .io = std.testing.io });
    defer journal.release();
    var pump: Pump = .{};
    var backend: Backend = .{ .ui_thread = std.Thread.getCurrentId(), .targets = undefined };
    for (&backend.targets, 0..) |*target, index| target.* = .{ .snapshot = .{ .owner = .{ .session_id = @fromBackingInt(index + 1), .generation = 1 }, .state = .idle, .interactive_execution = true, .input_epoch = 1 } };
    const driver = try driver_mod.Driver.start(a, journal, .{ .context = &pump, .call = Pump.schedule }, .{ .context = &backend, .authorize = Backend.authorize, .resolve = Backend.resolve, .handed_to_user = Backend.handoff, .terminal_call = Backend.call });
    defer {
        driver.requestShutdown();
        while (!driver.shutdownReady()) {
            pump.pump();
            pause();
        }
        driver.finish() catch unreachable;
    }
    const context: host.Context = .{ .conversation_id = .generate(), .task_id = .generate(), .binding = .{ .group = 1 }, .binding_revision = 1, .grant_revision = 1 };
    var other_task = context;
    other_task.task_id = .generate();
    var other_conversation = context;
    other_conversation.conversation_id = .generate();
    const contexts = [_]host.Context{ context, context, other_task, other_conversation };
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    for (contexts, 0..) |ctx, index| {
        const aa = arena.allocator();
        const arguments_json = try std.fmt.allocPrint(aa, "{{\"session_ref\":\"{d}\",\"command\":\"true\",\"request_key\":\"target-{d}\"}}", .{ index, index });
        const arguments = try std.json.parseFromSliceLeaky(std.json.Value, aa, arguments_json, .{});
        var tool: Tool = .{ .driver = driver, .invocation = .{ .context = ctx, .authority = .execution_control, .operation_id = index + 1, .turn_id = 1, .call_id = "driver-takeover-fixture", .tool_id = "host.run_in_terminal", .arguments = arguments, .arguments_json = arguments_json, .arguments_hash = @splat(1), .canonical_arguments_hash = @splat(2) } };
        const thread = try std.Thread.spawn(.{}, Tool.run, .{&tool});
        const until = now() + 3000;
        while (!tool.done.load(.acquire)) {
            pump.pump();
            if (now() >= until) driver.requestShutdown();
            pause();
        }
        thread.join();
        if (tool.failure) |failure| return failure;
        var result = tool.result.?;
        defer result.deinit(a);
        try std.testing.expect(backend.targets[index].snapshot.state == .running);
    }
    // Queue admission must return while the UI scheduler is deliberately not
    // being pumped. The owner will retry a busy ownership transfer later.
    var reference: [35]u8 = undefined;
    _ = try std.fmt.bufPrint(&reference, "x1:{s}", .{std.fmt.bytesToHex(backend.targets[0].snapshot.execution_id.?.bytes, .lower)});
    try driver.requestTakeover(context, &reference);
    try std.testing.expect(!backend.targets[0].handed and !backend.targets[1].handed);
    const busy_until = now() + 3000;
    while (!backend.handoff_busy_seen and now() < busy_until) {
        pump.pump();
        pause();
    }
    try std.testing.expect(backend.handoff_busy_seen);
    try std.testing.expect(!backend.targets[0].revoked and !backend.targets[1].revoked);
    backend.handoff_busy = false;
    backend.targets[0].revoke_busy = true;
    const handoff_until = now() + 3000;
    while (!backend.targets[0].handed and now() < handoff_until) {
        pump.pump();
        pause();
    }
    try std.testing.expect(backend.targets[0].handed and !backend.targets[1].handed);
    try std.testing.expect(!backend.targets[0].revoked);
    backend.targets[0].revoke_busy = false;
    const revoke_until = now() + 3000;
    while (!backend.targets[0].revoked and now() < revoke_until) {
        pump.pump();
        pause();
    }
    try std.testing.expect(backend.targets[0].revoked);
    const release_until = now() + 3000;
    var observed_unreleased = false;
    while (now() < release_until) {
        pump.pump();
        if (driver.taskEvidenceFor(context)) |fact| if (fact.handed_off_observers == 1 and fact.execution_count == 2) {
            try std.testing.expect(!fact.model_done and !fact.remote_effect_unknown and !fact.input_grants_released and !fact.executions_settled and !fact.controlled_executions_settled);
            observed_unreleased = true;
            break;
        };
        pause();
    }
    try std.testing.expect(observed_unreleased);
    backend.permit_drain = true;
    const settled_until = now() + 3000;
    var released = false;
    while (now() < settled_until) {
        pump.pump();
        if (driver.targetEvidence(backend.targets[0].snapshot.owner)) |fact| if (fact.input_grants_released) {
            released = true;
            break;
        };
        pause();
    }
    try std.testing.expect(released);
    try std.testing.expect(backend.targets[0].handed and backend.targets[0].revoke_calls > 0 and backend.targets[0].interrupt_calls == 0 and backend.targets[0].snapshot.process == null);
    for (backend.targets[1..4]) |target| try std.testing.expect(!target.handed and target.revoke_calls == 0 and target.interrupt_calls == 0 and target.snapshot.state == .running and target.snapshot.grant != null);
    // A separate explicit target choice returns the second session's input.
    // It does not finish the Task or pretend either foreground/record has ended.
    _ = try std.fmt.bufPrint(&reference, "x1:{s}", .{std.fmt.bytesToHex(backend.targets[1].snapshot.execution_id.?.bytes, .lower)});
    try driver.requestTakeover(context, &reference);
    const both_until = now() + 3000;
    var only_observers = false;
    while (now() < both_until) {
        pump.pump();
        if (driver.taskEvidenceFor(context)) |fact| if (fact.controlled_executions_settled and fact.handed_off_observers == 2) {
            try std.testing.expect(!fact.model_done and !fact.remote_effect_unknown and fact.active_executions == 2 and !fact.executions_settled and !fact.recordings_settled);
            only_observers = true;
            break;
        };
        pause();
    }
    try std.testing.expect(only_observers);
    // Input-only takeover must also be durable while the original foreground
    // and recording are still active, including same-stage running updates.
    const handoff_source = try tmp.dir.readFileAlloc(std.testing.io, "takeover-driver.json", a, .limited(@import("lifecycle_journal.zig").max_file_bytes));
    defer a.free(handoff_source);
    const handoff_disk = try std.json.parseFromSlice(std.json.Value, a, handoff_source, .{});
    defer handoff_disk.deinit();
    const handoff_receipt = handoff_disk.value.object.get("records").?.array.items[0].object.get("execution_receipt").?.object;
    try std.testing.expect(handoff_receipt.get("input_handed_off").?.bool and handoff_receipt.get("local_released").?.bool);
    try std.testing.expect(!handoff_receipt.get("sealed").?.bool and !handoff_receipt.get("recording_settled").?.bool and handoff_receipt.get("process").? == .null);
    // The still-live Task may obtain a separate freshly authorized terminal.
    const fresh_arguments = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), "{\"session_ref\":\"4\",\"command\":\"true\",\"request_key\":\"fresh-pty-after-handoff\"}", .{});
    var fresh_tool: Tool = .{ .driver = driver, .invocation = .{ .context = context, .authority = .execution_control, .operation_id = 9, .turn_id = 1, .call_id = "new-pty-after-handoff", .tool_id = "host.run_in_terminal", .arguments = fresh_arguments, .arguments_json = "", .arguments_hash = @splat(1), .canonical_arguments_hash = @splat(2) } };
    const fresh_thread = try std.Thread.spawn(.{}, Tool.run, .{&fresh_tool});
    const fresh_until = now() + 3000;
    while (!fresh_tool.done.load(.acquire)) {
        pump.pump();
        if (now() >= fresh_until) driver.requestShutdown();
        pause();
    }
    fresh_thread.join();
    if (fresh_tool.failure) |failure| return failure;
    var fresh_result = fresh_tool.result.?;
    defer fresh_result.deinit(a);
    try std.testing.expect(backend.targets[4].snapshot.state == .running and backend.targets[4].snapshot.grant.?.task_id.eql(context.task_id));
    try std.testing.expect(!driver.taskEvidenceFor(other_task).?.model_done);
}
fn now() i64 {
    return @intCast(@divTrunc(@import("../platform/realtime.zig").monotonicNs(), std.time.ns_per_ms));
}

test "execution driver saved interval settles control without RPC uncertainty or idle authority and never replays" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    defer a.free(path);
    const journal = try runtime.ProcessJournal.acquire(.{ .data_root = path, .path = "interval-driver.json", .dir = tmp.dir, .io = std.testing.io });
    defer journal.release();
    var pump: Pump = .{};
    var backend: Backend = .{ .ui_thread = std.Thread.getCurrentId(), .targets = undefined, .output_scope = .session_interval };
    for (&backend.targets, 0..) |*target, index| target.* = .{ .snapshot = .{ .owner = .{ .session_id = @fromBackingInt(index + 1), .generation = 1 }, .state = .idle, .interactive_execution = true, .input_epoch = 1 } };
    const driver = try driver_mod.Driver.start(a, journal, .{ .context = &pump, .call = Pump.schedule }, .{ .context = &backend, .authorize = Backend.authorize, .resolve = Backend.resolve, .handed_to_user = Backend.handoff, .terminal_call = Backend.call });
    defer {
        driver.requestShutdown();
        while (!driver.shutdownReady()) {
            pump.pump();
            pause();
        }
        driver.finish() catch unreachable;
    }
    const context: host.Context = .{ .conversation_id = .generate(), .task_id = .generate(), .binding = .{ .group = 1 }, .binding_revision = 1, .grant_revision = 1 };
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const aa = arena.allocator();
    const run_json = "{\"session_ref\":\"0\",\"command\":\"true\",\"request_key\":\"saved-interval\"}";
    const invocation: host.Invocation = .{ .context = context, .authority = .execution_control, .operation_id = 1, .turn_id = 1, .call_id = "interval-driver", .tool_id = "host.run_in_terminal", .arguments = try std.json.parseFromSliceLeaky(std.json.Value, aa, run_json, .{}), .arguments_json = run_json, .arguments_hash = @splat(1), .canonical_arguments_hash = @splat(2) };
    var initial = try Tool.execute(driver, &pump, invocation);
    defer initial.deinit(a);
    const snapshot = &backend.targets[0].snapshot;
    const id = snapshot.execution_id.?;
    var reference: [35]u8 = undefined;
    _ = try std.fmt.bufPrint(&reference, "x1:{s}", .{std.fmt.bytesToHex(id.bytes, .lower)});
    snapshot.state = .interval_recorded;
    snapshot.command_accepted = true;
    snapshot.submit_sent = true;
    snapshot.accepted_sequence = 1;
    snapshot.submit_sequence = 2;
    snapshot.submit_ack_sequence = 3;
    snapshot.submit_native_bytes = 5;
    snapshot.native_wake_written = true;
    snapshot.output_attribution = .unverified;
    snapshot.output_attribution_reason = "OutputProcessIdentityUnknown";
    snapshot.start = .{ .raw_offset = 0, .sequence = 1, .event_sequence = 1 };
    snapshot.end = .{ .raw_offset = 20, .sequence = 2, .event_sequence = 2 };
    snapshot.recording_id = "0123456789abcdef0123456789abcdef".*;
    snapshot.recording_generation = 1;
    snapshot.manifest_revision = 2;
    snapshot.process = .{ .exit_code = 0, .foreground_finished = true, .background_jobs_unknown = true };
    snapshot.grant = null;
    snapshot.input_ready = true;
    snapshot.local_released = true;
    snapshot.recording_settled = true;
    snapshot.interval_saved = true;
    snapshot.revision += 1;
    var repeated = try Tool.execute(driver, &pump, invocation);
    defer repeated.deinit(a);
    try std.testing.expect(repeated.status == .succeeded and !repeated.receipt.remote_effect_unknown);
    try std.testing.expectEqual(@as(usize, 1), backend.targets[0].request_count);
    const query_json = try std.fmt.allocPrint(aa, "{{\"execution_ref\":\"{s}\"}}", .{reference});
    var query = invocation;
    query.tool_id = "host.get_execution";
    query.arguments_json = query_json;
    query.arguments = try std.json.parseFromSliceLeaky(std.json.Value, aa, query_json, .{});
    var result = try Tool.execute(driver, &pump, query);
    defer result.deinit(a);
    const body = try std.json.parseFromSlice(std.json.Value, a, result.blocks[0].structured, .{});
    defer body.deinit();
    const observed = body.value.object.get("snapshot").?.object;
    try std.testing.expectEqualStrings("interval_recorded", observed.get("state").?.string);
    try std.testing.expectEqualStrings("session_interval", observed.get("output_scope").?.string);
    try std.testing.expect(observed.get("interval_saved").?.bool and !observed.get("remote_effect_unknown").?.bool);
    try driver.finishTask(context);
    var settled = false;
    const until = now() + 3000;
    while (now() < until) {
        pump.pump();
        if (driver.taskEvidenceFor(context)) |fact| if (fact.model_done and fact.executions_settled) {
            try std.testing.expect(fact.input_grants_released and fact.recordings_settled and fact.controlled_executions_settled);
            try std.testing.expect(fact.active_executions == 0 and fact.active_references == 0);
            try std.testing.expect(fact.output_attribution_unverified and !fact.remote_effect_unknown and !fact.pending_external_jobs);
            const target_fact = driver.targetEvidence(snapshot.owner) orelse continue;
            try std.testing.expect(target_fact.output_attribution_unverified and !target_fact.remote_effect_unknown);
            settled = true;
            break;
        };
        pause();
    }
    try std.testing.expect(settled);
    const source = try tmp.dir.readFileAlloc(std.testing.io, "interval-driver.json", a, .limited(@import("lifecycle_journal.zig").max_file_bytes));
    defer a.free(source);
    const disk = try std.json.parseFromSlice(std.json.Value, a, source, .{});
    defer disk.deinit();
    const record = disk.value.object.get("records").?.array.items[0].object;
    const saved = record.get("execution_receipt").?.object;
    try std.testing.expectEqualStrings("succeeded", record.get("stage").?.string);
    try std.testing.expect(saved.get("interval_saved").?.bool and !saved.get("sealed").?.bool);
    try std.testing.expectEqualStrings("OutputProcessIdentityUnknown", saved.get("output_attribution_reason").?.string);
}

test "execution driver exact stop rejects stale handed-off and foreign cards without finishing Task" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    defer a.free(path);
    const journal = try runtime.ProcessJournal.acquire(.{ .data_root = path, .path = "exact-stop-driver.json", .dir = tmp.dir, .io = std.testing.io });
    defer journal.release();
    var pump: Pump = .{};
    var backend: Backend = .{ .ui_thread = std.Thread.getCurrentId(), .targets = undefined, .handoff_busy = false, .permit_drain = true };
    for (&backend.targets, 0..) |*target, index| target.* = .{ .snapshot = .{ .owner = .{ .session_id = @fromBackingInt(index + 1), .generation = 1 }, .state = .idle, .interactive_execution = true, .input_epoch = 1 } };
    const driver = try driver_mod.Driver.start(a, journal, .{ .context = &pump, .call = Pump.schedule }, .{ .context = &backend, .authorize = Backend.authorize, .resolve = Backend.resolve, .handed_to_user = Backend.handoff, .terminal_call = Backend.call });
    defer {
        driver.requestShutdown();
        while (!driver.shutdownReady()) {
            pump.pump();
            pause();
        }
        driver.finish() catch unreachable;
    }
    const context: host.Context = .{ .conversation_id = .generate(), .task_id = .generate(), .binding = .{ .group = 2 }, .binding_revision = 1, .grant_revision = 1 };
    var other_task = context;
    other_task.task_id = .generate();
    var other_conversation = context;
    other_conversation.conversation_id = .generate();
    const contexts = [_]host.Context{ context, context, other_task, other_conversation };
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const aa = arena.allocator();
    var references: [4][35]u8 = undefined;
    for (contexts, 0..) |ctx, index| {
        const json = try std.fmt.allocPrint(aa, "{{\"session_ref\":\"{d}\",\"command\":\"true\",\"request_key\":\"stop-target-{d}\"}}", .{ index, index });
        var result = try Tool.execute(driver, &pump, .{ .context = ctx, .authority = .execution_control, .operation_id = index + 1, .turn_id = 1, .call_id = "exact-stop-fixture", .tool_id = "host.run_in_terminal", .arguments = try std.json.parseFromSliceLeaky(std.json.Value, aa, json, .{}), .arguments_json = json, .arguments_hash = @splat(1), .canonical_arguments_hash = @splat(2) });
        defer result.deinit(a);
        _ = try std.fmt.bufPrint(&references[index], "x1:{s}", .{std.fmt.bytesToHex(backend.targets[index].snapshot.execution_id.?.bytes, .lower)});
    }
    try std.testing.expectError(error.InvalidArguments, driver.requestStopExecution(context, ""));
    try driver.requestTakeover(context, &references[0]);
    const handoff_until = now() + 3000;
    while (!backend.targets[0].snapshot.local_released and now() < handoff_until) {
        pump.pump();
        pause();
    }
    try std.testing.expect(backend.targets[0].snapshot.input_handed_off);
    // Finish the first generation of target 1 with controlled terminal
    // receipts, then admit a real second Controller Entry on that same handle.
    const completed = &backend.targets[1].snapshot;
    const completed_id = completed.execution_id.?;
    const completed_epoch = completed.input_epoch;
    completed.state = .sealed;
    completed.grant = null;
    completed.input_ready = true;
    completed.local_released = true;
    completed.recording_settled = true;
    completed.input_epoch += 1;
    completed.start = .{ .raw_offset = 0, .sequence = 1, .event_sequence = 1 };
    completed.end = .{ .raw_offset = 20, .sequence = 2, .event_sequence = 2 };
    completed.process = .{ .exit_code = 0, .foreground_finished = true };
    completed.revision += 1;
    const args = try std.json.parseFromSliceLeaky(std.json.Value, aa, "{\"session_ref\":\"1\",\"command\":\"true\",\"request_key\":\"same-terminal-next-execution\"}", .{});
    var fresh_result = try Tool.execute(driver, &pump, .{ .context = context, .authority = .execution_control, .operation_id = 10, .turn_id = 1, .call_id = "exact-stop-next-generation", .tool_id = "host.run_in_terminal", .arguments = args, .arguments_json = "", .arguments_hash = @splat(1), .canonical_arguments_hash = @splat(2) });
    defer fresh_result.deinit(a);
    var fresh_ref: [35]u8 = undefined;
    _ = try std.fmt.bufPrint(&fresh_ref, "x1:{s}", .{std.fmt.bytesToHex(backend.targets[1].snapshot.execution_id.?.bytes, .lower)});
    try std.testing.expect(!std.mem.eql(u8, &fresh_ref, &references[1]));
    try std.testing.expect(backend.targets[1].snapshot.input_epoch > completed_epoch and backend.targets[1].snapshot.grant != null);
    // A queued old takeover is rejected after the native execution changes.
    // Its release fact must come from the original Entry, not this new epoch.
    try driver.requestTakeover(context, &references[1]);
    try driver.requestStopExecution(context, &references[1]);
    try driver.requestStopExecution(context, &references[0]);
    try driver.requestStopExecution(other_task, &fresh_ref);
    try driver.requestStopExecution(other_conversation, &fresh_ref);
    // The query is an owner-queue barrier after all four negative requests.
    const query_json = try std.fmt.allocPrint(aa, "{{\"execution_ref\":\"{s}\"}}", .{fresh_ref});
    var query_result = try Tool.execute(driver, &pump, .{ .context = context, .authority = .execution_control, .operation_id = 11, .turn_id = 1, .call_id = "exact-stop-barrier", .tool_id = "host.get_execution", .arguments = try std.json.parseFromSliceLeaky(std.json.Value, aa, query_json, .{}), .arguments_json = query_json, .arguments_hash = @splat(1), .canonical_arguments_hash = @splat(2) });
    defer query_result.deinit(a);
    var natural: ?driver_mod.ExecutionInputEvidence = null;
    const natural_until = now() + 3000;
    while (now() < natural_until) {
        pump.pump();
        if (driver.executionInputEvidence(context, completed_id)) |fact| if (fact.terminal) {
            natural = fact;
            break;
        };
        pause();
    }
    const original = natural orelse return error.OriginalExecutionEvidenceMissing;
    try std.testing.expect(original.state == .sealed and !original.input_handed_off and original.local_released and original.input_ready and !original.has_grant);
    try std.testing.expect(original.target.eql(backend.targets[1].snapshot.owner));
    try std.testing.expect(driver.executionInputEvidence(other_task, completed_id) == null and driver.executionInputEvidence(other_conversation, completed_id) == null);
    while (!driver.evidence_mutex.tryLock()) pause();
    const busy_evidence = driver.executionInputEvidence(context, completed_id);
    driver.evidence_mutex.unlock();
    try std.testing.expect(busy_evidence == null);
    for (backend.targets[0..4]) |target| try std.testing.expect(target.interrupt_calls == 0);
    for (backend.targets[1..4]) |target| try std.testing.expect(target.revoke_calls == 0 and target.snapshot.grant != null);
    // A genuine old handoff remains a genuine handoff after its finish and a
    // separately authorized successor on the same native target.
    const handed_completed = &backend.targets[0].snapshot;
    const handed_id = handed_completed.execution_id.?;
    handed_completed.state = .sealed;
    handed_completed.recording_settled = true;
    handed_completed.start = .{ .raw_offset = 0, .sequence = 1, .event_sequence = 1 };
    handed_completed.end = .{ .raw_offset = 20, .sequence = 2, .event_sequence = 2 };
    handed_completed.process = .{ .exit_code = 0, .foreground_finished = true };
    handed_completed.input_epoch += 1;
    handed_completed.revision += 1;
    const handed_args = try std.json.parseFromSliceLeaky(std.json.Value, aa, "{\"session_ref\":\"0\",\"command\":\"true\",\"request_key\":\"after-real-input-handoff\"}", .{});
    var handed_result = try Tool.execute(driver, &pump, .{ .context = context, .authority = .execution_control, .operation_id = 12, .turn_id = 1, .call_id = "input-handoff-successor", .tool_id = "host.run_in_terminal", .arguments = handed_args, .arguments_json = "", .arguments_hash = @splat(1), .canonical_arguments_hash = @splat(2) });
    defer handed_result.deinit(a);
    try driver.requestTakeover(context, &references[0]);
    var handed_fact: ?driver_mod.ExecutionInputEvidence = null;
    const handed_until = now() + 3000;
    while (now() < handed_until) {
        pump.pump();
        if (driver.executionInputEvidence(context, handed_id)) |fact| if (fact.terminal) {
            handed_fact = fact;
            break;
        };
        pause();
    }
    const old_handoff = handed_fact orelse return error.OriginalHandoffEvidenceMissing;
    try std.testing.expect(old_handoff.input_handed_off and old_handoff.local_released and old_handoff.input_ready and !old_handoff.has_grant and old_handoff.state == .sealed);
    try std.testing.expect(!backend.targets[0].snapshot.input_handed_off and backend.targets[0].snapshot.grant != null and backend.targets[0].snapshot.state == .running);
    backend.targets[1].revoke_busy = true;
    try driver.requestStopExecution(context, &fresh_ref);
    const busy_until = now() + 3000;
    while (backend.targets[1].revoke_attempts == 0 and now() < busy_until) {
        pump.pump();
        pause();
    }
    try std.testing.expect(backend.targets[1].revoke_attempts > 0 and backend.targets[1].interrupt_calls == 0 and backend.targets[1].snapshot.grant != null);
    backend.targets[1].revoke_busy = false;
    var released = false;
    const release_until = now() + 3000;
    while (now() < release_until) {
        pump.pump();
        if (driver.targetEvidence(backend.targets[1].snapshot.owner)) |fact| if (fact.input_grants_released and fact.remote_effect_unknown) {
            released = true;
            break;
        };
        pause();
    }
    try std.testing.expect(released and backend.targets[1].interrupt_calls == 1 and backend.targets[1].snapshot.process == null);
    const preserved_natural = driver.executionInputEvidence(context, completed_id) orelse return error.OriginalExecutionEvidenceMissing;
    const preserved_handoff = driver.executionInputEvidence(context, handed_id) orelse return error.OriginalHandoffEvidenceMissing;
    try std.testing.expect(std.meta.eql(original, preserved_natural) and std.meta.eql(old_handoff, preserved_handoff));
    for ([_]usize{ 0, 2, 3 }) |index| try std.testing.expect(backend.targets[index].interrupt_calls == 0 and backend.targets[index].snapshot.state == .running);
    try std.testing.expect(!driver.taskEvidenceFor(context).?.model_done and !driver.taskEvidenceFor(other_task).?.model_done);
}
