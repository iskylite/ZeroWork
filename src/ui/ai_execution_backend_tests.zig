const std = @import("std");
const ui = @import("ui");
const backend = @import("ai_execution_backend.zig");
const host = @import("../ai/host_tools.zig");
const approvals = @import("../ai/host_approval.zig");
const identity = @import("../host/identity.zig");
const terminal = @import("../host/terminal_service.zig");
const execution = terminal.execution;
const config = @import("../config/config.zig");
const Application = @import("application_host.zig").ApplicationHost;
const Workspace = @import("workspace.zig").Workspace;
const Bridge = @import("ai_tools.zig").Bridge;
const Controller = @import("ai_lifecycle_controller.zig").Controller;
const assistants = @import("../ai/assistant_store.zig");
const groups = @import("group_model.zig");
const a = std.testing.allocator;

const Call = struct {
    raw: []u8,
    parsed: std.json.Parsed(std.json.Value),
    value: host.Invocation,
    fn init(context: host.Context, target: identity.SessionHandle, command: []const u8, operation: u64) !Call {
        const reference = try @import("../ai/host_queries.zig").sessionRef(a, context, target);
        defer a.free(reference);
        var request_key: [32]u8 = undefined;
        const raw = try std.json.Stringify.valueAlloc(a, .{ .session_ref = reference, .command = command, .request_key = try std.fmt.bufPrint(&request_key, "backend-{d}", .{operation}) }, .{});
        errdefer a.free(raw);
        const parsed = try std.json.parseFromSlice(std.json.Value, a, raw, .{});
        errdefer parsed.deinit();
        return .{ .raw = raw, .parsed = parsed, .value = .{ .context = context, .authority = .execution_control, .operation_id = operation, .turn_id = 1, .call_id = "real-provider-call", .tool_id = "host.run_in_terminal", .arguments = parsed.value, .arguments_json = raw, .arguments_hash = execution.digest(raw), .canonical_arguments_hash = try @import("../ai/canonical_arguments.zig").digest(a, parsed.value) } };
    }
    fn deinit(self: *Call) void {
        self.parsed.deinit();
        a.free(self.raw);
    }
};
fn authority() host.Context {
    return .{ .conversation_id = .{ .bytes = @splat(1) }, .task_id = .{ .bytes = @splat(2) }, .binding = .{ .session = 9 }, .binding_revision = 1, .grant_revision = 1 };
}

test "execution backend prepare freezes normalized command and original wire identity" {
    var call = try Call.init(authority(), .{ .session_id = @fromBackingInt(9) }, "printf 中文\r\ntrue", 1);
    defer call.deinit();
    var prepared = try backend.prepare(call.value, a);
    defer prepared.deinit();
    try std.testing.expectEqualStrings("printf 中文\ntrue", prepared.command);
    try std.testing.expectEqualStrings(call.raw, prepared.invocation.arguments_json);
    try std.testing.expectEqualSlices(u8, &call.value.arguments_hash, &prepared.invocation.arguments_hash);
    try std.testing.expect(!std.mem.eql(u8, &call.value.canonical_arguments_hash, &prepared.invocation.canonical_arguments_hash));
    try std.testing.expectEqualStrings(prepared.command, prepared.subject.detail);
    var broker: approvals.Broker = .{};
    try broker.configure(prepared.invocation.context, 1);
    const permit = try broker.beginSubject(prepared.invocation, prepared.subject, 1, a);
    defer broker.finish(permit);
    try broker.decide(permit.sequence, permit.arguments_hash, true);
    try std.testing.expectEqual(@import("../ai/fetch_url.zig").Decision.allow, broker.authorizeSubject(permit, prepared.invocation, prepared.subject, 1));
    var tampered = call.value;
    tampered.arguments_hash[0] ^= 1;
    try std.testing.expectError(error.InvalidArguments, backend.prepare(tampered, a));
    var invalid = try Call.init(authority(), .{ .session_id = @fromBackingInt(9) }, "printf x\x1b", 2);
    defer invalid.deinit();
    try std.testing.expectError(error.InvalidCommand, backend.prepare(invalid.value, a));
}

const Fixture = struct {
    cx: *ui.Cx,
    scope_: *ui.Scope,
    app: *Application,
    workspace: *Workspace,
    config_: config.Config = .{},
    tmp: std.testing.TmpDir,
    path: [:0]u8,
    directory: [:0]u8,
    previous: ?[:0]u8 = null,
    diagnostic_withdrawal: ?Withdrawal = null,
    diagnostic_handle: ?identity.SessionHandle = null,
    diagnostic_execution_id: ?identity.ExecutionId = null,
    diagnostic_service: ?terminal.Service = null,
    diagnostic_last_execution: ?execution.Snapshot = null,
    extern "c" fn setenv([*:0]const u8, [*:0]const u8, c_int) c_int;
    extern "c" fn unsetenv([*:0]const u8) c_int;
    fn init(self: *@This()) !void {
        self.* = .{ .cx = try ui.Cx.init(a, std.testing.io), .scope_ = undefined, .app = undefined, .workspace = undefined, .tmp = std.testing.tmpDir(.{}), .path = undefined, .directory = undefined };
        self.cx.setViewport(1100, 720);
        self.cx.root = try ui.box(self.cx, .{ .width = .fill(), .height = .fill(), .direction = .column }, .{});
        self.scope_ = try ui.Scope.init(a, null, self.cx.owner);
        var nodes: [4]*ui.Node = undefined;
        for (&nodes) |*node| {
            node.* = try ui.box(self.cx, .{ .width = .fill(), .height = .{ .px = 100 } }, .{});
            try self.cx.root.?.appendChild(a, node.*);
        }
        try self.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "hosts.toml", .data = "" });
        try self.tmp.dir.writeFile(std.testing.io, .{ .sub_path = ".zshenv", .data = "PROMPT=''\nRPROMPT=''\n" });
        try self.tmp.dir.writeFile(std.testing.io, .{ .sub_path = ".zshrc", .data = "bindkey -e\n" });
        self.path = try self.tmp.dir.realPathFileAlloc(std.testing.io, "hosts.toml", a);
        self.directory = try self.tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
        self.previous = if (std.c.getenv("ZDOTDIR")) |value| try a.dupeSentinel(u8, std.mem.span(value), 0) else null;
        if (setenv("ZDOTDIR", self.directory.ptr, 1) != 0) return error.EnvironmentFailed;
        self.workspace = try Workspace.init(a, self.cx, self.scope_, std.testing.io, &self.config_, self.path, nodes[0], nodes[1], nodes[2], nodes[3]);
        self.app = try Application.init(a, self.workspace);
        try self.app.local_adapter.configureRecording(.{ .io = std.testing.io, .directory = self.directory, .log = .{ .ring_mb = 2, .checkpoint_sec = 1 } });
        try self.scope_.onCleanup(Application, self.app, Application.deinit);
        self.app.install();
    }
    fn tick(self: *@This()) !void {
        _ = try self.app.safeTick();
        self.cx.advanceFrameClock();
        self.cx.layout();
        _ = self.cx.render();
        var empty: [1]std.c.pollfd = undefined;
        _ = std.c.poll(&empty, 0, 2);
    }
    fn local(self: *@This()) !identity.SessionHandle {
        const source = try self.app.createLocal(self.directory);
        const deadline = @import("../platform/realtime.zig").monotonicNs() + 8 * std.time.ns_per_s;
        while (true) {
            try self.tick();
            if (self.app.legacyForHandle(source.handle)) |legacy| if (self.workspace.sessionTab(legacy)) |tab| if (tab.terminal) |view| if (view.terminal_surface) |surface| {
                const snapshot = surface.service.executionSnapshot() catch |err| {
                    if (err == error.WorkerBusy) continue;
                    return err;
                };
                if (snapshot.interactive_execution and snapshot.input_ready) return source.handle;
            };
            if (@import("../platform/realtime.zig").monotonicNs() >= deadline) return error.ExecutionIntegrationNotReady;
        }
    }
    fn deinit(self: *@This()) void {
        for (self.app.mappings.items) |mapping| _ = self.app.requestCloseLegacy(mapping.legacy_id) catch |err| {
            std.debug.print("backend cleanup close request id={d} error={s}\n", .{ mapping.legacy_id, @errorName(err) });
        };
        const deadline = @import("../platform/realtime.zig").monotonicNs() + 8 * std.time.ns_per_s;
        while (self.workspace.tabs.items.len != 0 or self.app.local_adapter.shutdownStep() != .released) {
            for (self.workspace.tabs.items) |tab| if (tab.archived and tab.content_owner == .history) {
                _ = self.app.closeForInput(self.app.dispatcher.issue() catch @panic("fixture command identity exhausted"), tab.tab_id, tab.content_owner) catch {};
            };
            self.tick() catch |err| std.debug.panic("backend fixture cleanup: {s}", .{@errorName(err)});
            if (@import("../platform/realtime.zig").monotonicNs() >= deadline) {
                self.dumpCleanup();
                @panic("backend fixture cleanup timed out");
            }
        }
        self.cx.clearFocus();
        self.scope_.dispose();
        self.cx.deinit();
        if (self.previous) |previous| {
            if (setenv("ZDOTDIR", previous.ptr, 1) != 0) @panic("cannot restore ZDOTDIR");
            a.free(previous);
        } else if (unsetenv("ZDOTDIR") != 0) @panic("cannot restore ZDOTDIR");
        a.free(self.path);
        a.free(self.directory);
        self.tmp.cleanup();
    }
    fn dumpCleanup(self: *@This()) void {
        std.debug.print("backend cleanup timeout withdrawal={s} tabs={d} mappings={d}\n", .{ if (self.diagnostic_withdrawal) |kind| @tagName(kind) else "none", self.workspace.tabs.items.len, self.app.mappings.items.len });
        for (self.app.mappings.items) |mapping| {
            if (self.app.sessions.queryState(mapping.handle)) |state| {
                std.debug.print("backend cleanup handle={d}/{d} original={any} lifecycle={s} close_operation={any} create_cleanup={s} waiting_step={s} waiting_unknown={any} content_pending={any}\n", .{ @backingInt(mapping.handle.session_id), mapping.handle.generation, if (self.diagnostic_handle) |expected| expected.eql(mapping.handle) else false, @tagName(state.lifecycle), state.close_operation != null, @tagName(state.create_cleanup), if (mapping.waiting) |waiting| @tagName(waiting.step) else "none", if (mapping.waiting) |waiting| waiting.unknown else false, mapping.content_pending });
            } else std.debug.print("backend cleanup session state unavailable id={d}/{d}\n", .{ @backingInt(mapping.handle.session_id), mapping.handle.generation });
        }
        if (self.diagnostic_handle) |handle| {
            if (self.app.sessions.queryState(handle)) |state| {
                std.debug.print("backend cleanup original session id={d}/{d} lifecycle={s} close_operation={any} create_cleanup={s}\n", .{ @backingInt(handle.session_id), handle.generation, @tagName(state.lifecycle), state.close_operation != null, @tagName(state.create_cleanup) });
            } else std.debug.print("backend cleanup original session state unavailable id={d}/{d}\n", .{ @backingInt(handle.session_id), handle.generation });
            if (self.app.local_adapter.processSnapshot(handle)) |process| {
                std.debug.print("backend cleanup original process id={d}/{d} state={s} cleanup={s} pid={any} exit={any} eof={any}\n", .{ @backingInt(handle.session_id), handle.generation, @tagName(process.state), @tagName(process.cleanup), process.pid, process.exit, process.eof_seen });
            } else |err| std.debug.print("backend cleanup original process error={s}\n", .{@errorName(err)});
            // Read the existing native observation receipt while the owning
            // entry guard pins its original (possibly unknown) process.
            const local_adapter: *@import("../local/adapter.zig").LocalAdapter = @ptrCast(@alignCast(self.app.local_adapter.context));
            for (local_adapter.entries.items) |entry| if (entry.handle.eql(handle)) {
                if (!entry.mutex.state.tryLock()) break;
                defer entry.mutex.state.unlock();
                if (entry.process) |process| if (process.process) |native_process| {
                    var observation: @import("../local/native.zig").ObservationFailure = undefined;
                    if (@import("../local/native.zig").zw_local_observation_failure(native_process, &observation) == 1) std.debug.print("backend cleanup native observation stage={d} errno={d} pid={d} worker_done={}\n", .{ observation.stage, observation.error_number, observation.pid, entry.worker_done });
                };
                break;
            };
        }
        if (self.diagnostic_last_execution) |snapshot| self.dumpExecution("last_observed", snapshot);
        if (self.diagnostic_service) |service| {
            if (service.executionSnapshot()) |snapshot| self.dumpExecution("at_timeout", snapshot) else |err| std.debug.print("backend cleanup original execution error={s}\n", .{@errorName(err)});
        }
    }
    fn dumpExecution(self: *@This(), label: []const u8, snapshot: execution.Snapshot) void {
        const original = if (self.diagnostic_execution_id) |expected| if (snapshot.execution_id) |observed| expected.eql(observed) else false else false;
        std.debug.print("backend cleanup execution {s} original={any} state={s} failure={?s} accepted={any} submitted={any} has_grant={any} input_ready={any} local_released={any} handed_off={any} process={any} recording_settled={any} recording_failed={any} remote_unknown={any}\n", .{ label, original, @tagName(snapshot.state), snapshot.failure, snapshot.command_accepted, snapshot.submit_sent, snapshot.grant != null, snapshot.input_ready, snapshot.local_released, snapshot.input_handed_off, snapshot.process, snapshot.recording_settled, snapshot.recording_failed, snapshot.remote_effect_unknown });
    }
};
const Lookup = struct {
    controller: *Controller,
    fn find(raw: *anyopaque, conversation: identity.ConversationId, task: identity.TaskId) ?*Controller {
        const self: *@This() = @ptrCast(@alignCast(raw));
        return if (self.controller.authority.conversation_id.eql(conversation) and self.controller.authority.task_id.eql(task)) self.controller else null;
    }
};
fn unavailable(_: *anyopaque, _: host.Invocation, _: std.mem.Allocator) !host.Result {
    return error.ToolNotAvailable;
}
fn bind(bridge: *Bridge, context: host.Context) void {
    bridge.host_binding = .{ .context = context, .handler_context = bridge, .invoke = unavailable, .contributions = &.{} };
}
fn makeController(fixture: *Fixture, store: *assistants.Store, roster: *groups.Roster, bridge: *Bridge, target: identity.SessionHandle, mode: config.ExecutionMode) !Controller {
    const state = try store.create(.{ .session = @backingInt(target.session_id) });
    const context: host.Context = .{ .conversation_id = state.conversation_id, .task_id = identity.TaskId.generate(), .binding = state.owner, .binding_revision = state.binding_revision, .grant_revision = 1 };
    bind(bridge, context);
    return Controller.init(.{ .allocator = a, .app = fixture.app, .roster = roster, .store = store, .bridge = bridge, .authority = context, .execution_policy = .{ .execution_mode = mode, .session_retention = .auto_idle } });
}
fn approve(ctx: *backend.Context, broker: *approvals.Broker, prepared: *backend.Prepared) !approvals.Permit {
    var evidence = try ctx.preflight(prepared.invocation, prepared.command, prepared.command_hash);
    prepared.subject.impact = evidence.text();
    try broker.configure(prepared.invocation.context, 1);
    const permit = try broker.beginSubject(prepared.invocation, prepared.subject, 1, a);
    errdefer broker.finish(permit);
    try broker.decide(permit.sequence, permit.arguments_hash, true);
    prepared.invocation.approval_sequence = permit.sequence;
    return permit;
}
fn authorize(ctx: *backend.Context, prepared: backend.Prepared) !@import("../ai/host_execution.zig").Target {
    const api = ctx.backend();
    return api.authorize(api.context, prepared.invocation, prepared.invocation.arguments.object.get("session_ref").?.string, prepared.command, prepared.command_hash);
}
fn handoff(fixture: *Fixture, store: *assistants.Store, roster: *groups.Roster, controller: *Controller, bridge: *Bridge, target: identity.SessionHandle) !host.Context {
    const original = controller.authority;
    const legacy = fixture.app.legacyForHandle(target).?;
    var group = try roster.prepareNew("backend-handoff", 0xff818cf8, legacy);
    defer group.deinit();
    const plan = try store.prepareHandoff(original.conversation_id, original.binding, original.binding_revision, group.id);
    var view = try fixture.workspace.prepareGroupView(group.id, "backend-handoff", legacy);
    defer view.deinit();
    _ = try group.commit();
    try store.commitHandoff(plan);
    try view.commit(roster);
    var current = original;
    current.binding = plan.to;
    current.binding_revision = plan.next_revision;
    try controller.refreshAuthority(current);
    bind(bridge, current);
    return current;
}

test "execution backend real Local service requires precise approval and runs the normalized bytes" {
    var fixture: Fixture = undefined;
    try fixture.init();
    var roster = groups.Roster.init(a);
    defer roster.deinit();
    defer fixture.deinit();
    const target = try fixture.local();
    var store = assistants.Store.init(a);
    defer store.deinit();
    var bridge = Bridge.init(a);
    defer bridge.deinit();
    var controller = try makeController(&fixture, &store, &roster, &bridge, target, .auto);
    defer controller.deinitAfterWorker();
    var lookup: Lookup = .{ .controller = &controller };
    var broker: approvals.Broker = .{};
    var ctx = try backend.Context.init(.{ .app = fixture.app, .roster = &roster, .store = &store, .lookup_context = &lookup, .lookup_task = Lookup.find, .approval = &broker });
    try ctx.captureTask(&controller);
    var call = try Call.init(controller.authority, target, "printf 'backend-real-中文\\n'\r\ntrue", 11);
    defer call.deinit();
    var prepared = try backend.prepare(call.value, a);
    defer prepared.deinit();
    try std.testing.expectError(error.ApprovalRequired, authorize(&ctx, prepared));
    const permit = try approve(&ctx, &broker, &prepared);
    defer broker.finish(permit);
    const accepted = try authorize(&ctx, prepared);
    const api = ctx.backend();
    const snapshot = try accepted.service.executionSnapshot();
    const execution_id = identity.ExecutionId.generate();
    const request: execution.Request = .{ .execution_id = execution_id, .task_id = controller.authority.task_id, .expected_input_epoch = snapshot.input_epoch, .ownership_revision = accepted.ownership_revision, .command = prepared.command, .command_hash = prepared.command_hash };
    var submitted = false;
    const until = @import("../platform/realtime.zig").monotonicNs() + 8 * std.time.ns_per_s;
    while (!submitted) {
        _ = api.terminal_call.?(api.context, accepted.service, .{ .request = request }) catch |err| {
            if (err != error.WorkerBusy) return err;
            try fixture.tick();
            continue;
        };
        submitted = true;
    }
    while (true) {
        try fixture.tick();
        const current = accepted.service.executionSnapshot() catch |err| {
            if (err == error.WorkerBusy) continue;
            return err;
        };
        if (current.state == .interval_recorded) {
            try std.testing.expect(current.process.?.foreground_finished);
            try std.testing.expect(current.output_scope == .session_interval and current.interval_saved and current.recording_settled and !current.recording_failed);
            try std.testing.expect(current.command_accepted and current.submit_sent and !current.remote_effect_unknown);
            try std.testing.expect(current.start != null and current.end != null and current.manifest_revision != 0);
            try std.testing.expect(!execution.PublicReceipt.fromSnapshot(current).?.sealed);
            try std.testing.expectEqual(@as(?u8, 0), current.process.?.exit_code);
            break;
        }
        if (@import("../platform/realtime.zig").monotonicNs() >= until) return error.ExecutionNotFinished;
    }
    var output = try accepted.service.executionOutput(execution_id, a, 0, 8192);
    defer output.deinit(a);
    try std.testing.expect(std.mem.indexOf(u8, output.bytes, "backend-real-中文") != null);
    var other = controller.authority;
    other.task_id = identity.TaskId.generate();
    try std.testing.expectError(error.TargetNotAuthorized, api.resolve(api.context, other, target));
    var stale = target;
    stale.generation += 1;
    var stale_call = try Call.init(controller.authority, stale, "true", 12);
    defer stale_call.deinit();
    var stale_prepared = try backend.prepare(stale_call.value, a);
    defer stale_prepared.deinit();
    try std.testing.expectError(error.StaleReference, ctx.preflight(stale_prepared.invocation, stale_prepared.command, stale_prepared.command_hash));
    fixture.config_.config_revision += 1;
    _ = try api.resolve(api.context, controller.authority, target);
    try std.testing.expectError(error.ScopeChanged, authorize(&ctx, prepared));
    fixture.config_.config_revision -= 1;
    var close_contexts: [128]host.Context = undefined;
    try std.testing.expectEqual(@as(usize, 1), try ctx.beginClose(target, &close_contexts));
    try std.testing.expect(close_contexts[0].eql(controller.authority));
    fixture.workspace.shutting_down = true;
    _ = try api.resolve(api.context, controller.authority, target);
    try std.testing.expectError(error.WorkspaceClosed, ctx.preflight(prepared.invocation, prepared.command, prepared.command_hash));
    const old_grant: execution.Grant = .{ .execution_id = execution_id, .task_id = controller.authority.task_id, .fence = 1, .input_epoch = request.expected_input_epoch, .ownership_revision = request.ownership_revision };
    try std.testing.expectError(error.WorkspaceClosed, api.terminal_call.?(api.context, accepted.service, .{ .renew = old_grant }));
    fixture.workspace.shutting_down = false;
    const state = store.findConversation(controller.authority.conversation_id).?;
    state.closed = true;
    fixture.config_.config_revision += 1;
    const cleanup_service = try api.resolve(api.context, controller.authority, target);
    try std.testing.expect((try cleanup_service.executionSnapshot()).local_released);
    try std.testing.expectError(error.WorkspaceClosed, api.terminal_call.?(api.context, accepted.service, .{ .renew = old_grant }));
    state.closed = false;
    fixture.config_.config_revision -= 1;
}

test "execution backend fixed modes deny borrowed new PTY and forbid rules precede approval" {
    var fixture: Fixture = undefined;
    try fixture.init();
    var roster = groups.Roster.init(a);
    defer roster.deinit();
    defer fixture.deinit();
    const target = try fixture.local();
    var store = assistants.Store.init(a);
    defer store.deinit();
    var bridge = Bridge.init(a);
    defer bridge.deinit();
    var controller = try makeController(&fixture, &store, &roster, &bridge, target, .new_pty);
    defer controller.deinitAfterWorker();
    var lookup: Lookup = .{ .controller = &controller };
    var broker: approvals.Broker = .{};
    var ctx = try backend.Context.init(.{ .app = fixture.app, .roster = &roster, .store = &store, .lookup_context = &lookup, .lookup_task = Lookup.find, .approval = &broker });
    try ctx.captureTask(&controller);
    var call = try Call.init(controller.authority, target, "ls", 21);
    defer call.deinit();
    var prepared = try backend.prepare(call.value, a);
    defer prepared.deinit();
    try std.testing.expectError(error.ModeConflict, ctx.preflight(prepared.invocation, prepared.command, prepared.command_hash));
    controller.execution_policy.execution_mode = .isolated_exec;
    var isolated = try backend.Context.init(.{ .app = fixture.app, .roster = &roster, .store = &store, .lookup_context = &lookup, .lookup_task = Lookup.find, .approval = &broker });
    try isolated.captureTask(&controller);
    try std.testing.expectError(error.ModeConflict, isolated.preflight(prepared.invocation, prepared.command, prepared.command_hash));
    controller.execution_policy.execution_mode = .auto;
    var allowed = try backend.Context.init(.{ .app = fixture.app, .roster = &roster, .store = &store, .lookup_context = &lookup, .lookup_task = Lookup.find, .approval = &broker });
    try allowed.captureTask(&controller);
    var forbidden = try Call.init(controller.authority, target, "printf safe; rm -rf /", 22);
    defer forbidden.deinit();
    var blocked = try backend.prepare(forbidden.value, a);
    defer blocked.deinit();
    try std.testing.expectError(error.PermissionDenied, allowed.preflight(blocked.invocation, blocked.command, blocked.command_hash));
    try std.testing.expect(broker.snapshot() == null);
}

test "execution backend keeps admitted handoff lineage but rejects old binding new calls and removed members" {
    var fixture: Fixture = undefined;
    try fixture.init();
    var roster = groups.Roster.init(a);
    defer roster.deinit();
    defer fixture.deinit();
    const target = try fixture.local();
    var store = assistants.Store.init(a);
    defer store.deinit();
    var bridge = Bridge.init(a);
    defer bridge.deinit();
    var controller = try makeController(&fixture, &store, &roster, &bridge, target, .attached_pty);
    defer controller.deinitAfterWorker();
    var lookup: Lookup = .{ .controller = &controller };
    var broker: approvals.Broker = .{};
    var ctx = try backend.Context.init(.{ .app = fixture.app, .roster = &roster, .store = &store, .lookup_context = &lookup, .lookup_task = Lookup.find, .approval = &broker });
    try ctx.captureTask(&controller);
    const original = controller.authority;
    var call = try Call.init(original, target, "true", 31);
    defer call.deinit();
    var prepared = try backend.prepare(call.value, a);
    defer prepared.deinit();
    const permit = try approve(&ctx, &broker, &prepared);
    defer broker.finish(permit);
    _ = try authorize(&ctx, prepared);
    const legacy = fixture.app.legacyForHandle(target).?;
    const current = try handoff(&fixture, &store, &roster, &controller, &bridge, target);
    const api = ctx.backend();
    _ = try api.resolve(api.context, original, target);
    _ = try api.resolve(api.context, current, target);
    try std.testing.expectError(error.ScopeChanged, ctx.preflight(prepared.invocation, prepared.command, prepared.command_hash));
    try std.testing.expectError(error.ScopeChanged, authorize(&ctx, prepared));
    try roster.leave("backend-handoff", legacy);
    _ = try api.resolve(api.context, original, target);
}

test "execution backend new PTY accepts only this Task actual owned creation and revokes on user takeover" {
    var fixture: Fixture = undefined;
    try fixture.init();
    var roster = groups.Roster.init(a);
    defer roster.deinit();
    defer fixture.deinit();
    const source = try fixture.local();
    var store = assistants.Store.init(a);
    defer store.deinit();
    var bridge = Bridge.init(a);
    defer bridge.deinit();
    var controller = try makeController(&fixture, &store, &roster, &bridge, source, .new_pty);
    defer controller.deinitAfterWorker();
    var lookup: Lookup = .{ .controller = &controller };
    var broker: approvals.Broker = .{};
    var ctx = try backend.Context.init(.{ .app = fixture.app, .roster = &roster, .store = &store, .lookup_context = &lookup, .lookup_task = Lookup.find, .approval = &broker });
    try ctx.captureTask(&controller);
    const current = try handoff(&fixture, &store, &roster, &controller, &bridge, source);
    const operation = identity.HostOperationId.generate();
    _ = try fixture.app.queueOwnedSession(.{ .operation_ref = operation, .context = current, .group = .{ .id = @fromBackingInt(current.binding.group) }, .source = source, .connection_policy = .new_only, .retention = .keep });
    const until = @import("../platform/realtime.zig").monotonicNs() + 8 * std.time.ns_per_s;
    var target: identity.SessionHandle = undefined;
    while (true) {
        try fixture.tick();
        const created = try fixture.app.queryOwnedSession(operation, current);
        if (created.state == .prepared) _ = try fixture.app.authorizeOwnedSessionDispatch(operation, current, created.revision, created.session.?);
        if (created.state == .ready) {
            target = created.session.?;
            const legacy = fixture.app.legacyForHandle(target).?;
            const surface = fixture.workspace.sessionTab(legacy).?.terminal.?.terminal_surface.?;
            const snapshot = surface.service.executionSnapshot() catch |err| {
                if (err == error.WorkerBusy) continue;
                return err;
            };
            if (snapshot.interactive_execution and snapshot.input_ready) break;
        }
        if (@import("../platform/realtime.zig").monotonicNs() >= until) return error.OwnedExecutionNotReady;
    }
    try std.testing.expect(!source.eql(target));
    var call = try Call.init(current, target, "true", 41);
    defer call.deinit();
    var prepared = try backend.prepare(call.value, a);
    defer prepared.deinit();
    const permit = try approve(&ctx, &broker, &prepared);
    defer broker.finish(permit);
    const accepted = try authorize(&ctx, prepared);
    try std.testing.expect(accepted.handle.eql(target));
    const api = ctx.backend();
    try api.handed_to_user.?(api.context, target);
    try std.testing.expectEqual(@import("../host/lifecycle_supervisor.zig").Ownership.handed_to_user, fixture.app.lifecycle_supervisor.resource(target).?.snapshot.ownership);
    _ = try api.resolve(api.context, current, target);
    try std.testing.expectError(error.OwnershipChanged, authorize(&ctx, prepared));
    var next_call = try Call.init(current, target, "true", 42);
    defer next_call.deinit();
    var next_prepared = try backend.prepare(next_call.value, a);
    defer next_prepared.deinit();
    try std.testing.expectError(error.ModeConflict, ctx.preflight(next_prepared.invocation, next_prepared.command, next_prepared.command_hash));
}

const Withdrawal = enum { membership, config_revision, closed_conversation };
fn revokeWithdrawnAuthority(kind: Withdrawal) !void {
    var fixture: Fixture = undefined;
    try fixture.init();
    fixture.diagnostic_withdrawal = kind;
    std.debug.print("backend withdrawal begin kind={s}\n", .{@tagName(kind)});
    var roster = groups.Roster.init(a);
    defer roster.deinit();
    defer fixture.deinit();
    revokeWithdrawnAuthorityBody(&fixture, &roster, kind) catch |err| {
        std.debug.print("backend withdrawal original body error kind={s} error={s}\n", .{ @tagName(kind), @errorName(err) });
        return err;
    };
    std.debug.print("backend withdrawal body complete kind={s}\n", .{@tagName(kind)});
}
fn revokeWithdrawnAuthorityBody(fixture: *Fixture, roster: *groups.Roster, kind: Withdrawal) !void {
    const target = try fixture.local();
    fixture.diagnostic_handle = target;
    var store = assistants.Store.init(a);
    defer store.deinit();
    var bridge = Bridge.init(a);
    defer bridge.deinit();
    var controller = try makeController(fixture, &store, roster, &bridge, target, .attached_pty);
    defer controller.deinitAfterWorker();
    var lookup: Lookup = .{ .controller = &controller };
    var broker: approvals.Broker = .{};
    var ctx = try backend.Context.init(.{ .app = fixture.app, .roster = roster, .store = &store, .lookup_context = &lookup, .lookup_task = Lookup.find, .approval = &broker });
    try ctx.captureTask(&controller);
    if (kind == .membership) _ = try handoff(fixture, &store, roster, &controller, &bridge, target);
    const owner = controller.authority;
    var call = try Call.init(owner, target, "printf 'authority-live\\n'; sleep 3", 61);
    defer call.deinit();
    var prepared = try backend.prepare(call.value, a);
    defer prepared.deinit();
    const permit = try approve(&ctx, &broker, &prepared);
    defer broker.finish(permit);
    const accepted = try authorize(&ctx, prepared);
    fixture.diagnostic_service = accepted.service;
    const api = ctx.backend();
    const initial = try accepted.service.executionSnapshot();
    fixture.diagnostic_last_execution = initial;
    const id = identity.ExecutionId.generate();
    fixture.diagnostic_execution_id = id;
    const request: execution.Request = .{ .execution_id = id, .task_id = owner.task_id, .expected_input_epoch = initial.input_epoch, .ownership_revision = accepted.ownership_revision, .command = prepared.command, .command_hash = prepared.command_hash };
    const deadline = @import("../platform/realtime.zig").monotonicNs() + 8 * std.time.ns_per_s;
    while (true) {
        _ = api.terminal_call.?(api.context, accepted.service, .{ .request = request }) catch |err| {
            if (err != error.WorkerBusy) return err;
            try fixture.tick();
            continue;
        };
        break;
    }
    var grant: execution.Grant = undefined;
    while (true) {
        try fixture.tick();
        const observed = accepted.service.executionSnapshot() catch |err| {
            if (err == error.WorkerBusy) continue;
            return err;
        };
        fixture.diagnostic_last_execution = observed;
        if (observed.state == .running and observed.grant != null) {
            grant = observed.grant.?;
            break;
        }
        if (@import("../platform/realtime.zig").monotonicNs() >= deadline) return error.ExecutionNotRunning;
    }
    switch (kind) {
        .membership => try roster.leave("backend-handoff", fixture.app.legacyForHandle(target).?),
        .config_revision => fixture.config_.config_revision += 1,
        .closed_conversation => store.findConversation(owner.conversation_id).?.closed = true,
    }
    // This call must survive revoked model authority only for the exact old
    // admitted target. It also changes that admission permanently to cleanup.
    const cleanup_service = try api.resolve(api.context, owner, target);
    try std.testing.expect(cleanup_service.binding.eql(accepted.service.binding));
    try std.testing.expectError(error.WorkspaceClosed, api.terminal_call.?(api.context, cleanup_service, .{ .renew = grant }));
    switch (kind) {
        .membership => try std.testing.expectError(error.TargetNotAuthorized, ctx.preflight(prepared.invocation, prepared.command, prepared.command_hash)),
        .config_revision => try std.testing.expectError(error.ScopeChanged, ctx.preflight(prepared.invocation, prepared.command, prepared.command_hash)),
        .closed_conversation => try std.testing.expectError(error.BindingConflict, ctx.preflight(prepared.invocation, prepared.command, prepared.command_hash)),
    }
    var unrelated = owner;
    unrelated.task_id = identity.TaskId.generate();
    try std.testing.expectError(error.TargetNotAuthorized, api.resolve(api.context, unrelated, target));
    while (true) {
        _ = api.terminal_call.?(api.context, cleanup_service, .{ .revoke = .{ .grant = grant, .takeover = false } }) catch |err| {
            if (err != error.WorkerBusy) return err;
            try fixture.tick();
            continue;
        };
        break;
    }
    while (true) {
        try fixture.tick();
        const service = try api.resolve(api.context, owner, target);
        const result = api.terminal_call.?(api.context, service, .snapshot) catch |err| {
            if (err == error.WorkerBusy) continue;
            return err;
        };
        const observed = result.snapshot;
        fixture.diagnostic_last_execution = observed;
        if (observed.grant == null and observed.input_ready and observed.local_released and observed.recording_settled) break;
        if (@import("../platform/realtime.zig").monotonicNs() >= deadline) return error.InputGrantNotReleased;
    }
    // Releasing AI input/recording is distinct from the interrupted child
    // returning to the shell. This authority test does not exercise force
    // closing a foreground process: wait for a fresh, typed observation of
    // this original shell before the fixture requests ordinary close.
    const observe_after = @import("../local/native.zig").zw_local_monotonic_ms();
    while (true) {
        try fixture.tick();
        var risk = fixture.app.local_adapter.closeRiskSnapshot(target, a) catch |err| {
            if (err == error.WorkerBusy and @import("../platform/realtime.zig").monotonicNs() < deadline) continue;
            return err;
        };
        defer risk.deinit(a);
        if (risk.owner.eql(target) and !risk.unknown and risk.foreground_state == .idle_shell and risk.observed_monotonic_ms >= observe_after and risk.shell_pid != null and risk.foreground != null and risk.foreground.?.pid == risk.shell_pid.? and risk.foreground.?.process_group == risk.shell_pid.?) break;
        if (@import("../platform/realtime.zig").monotonicNs() >= deadline) return error.OriginalShellNotObservedIdle;
    }
    // Restoring UI/config metadata never revives the old input grant.
    fixture.config_.config_revision = 1;
    store.findConversation(owner.conversation_id).?.closed = false;
    try std.testing.expectError(error.WorkspaceClosed, api.terminal_call.?(api.context, cleanup_service, .{ .renew = grant }));
}

test "execution backend revoked member config and conversation still settle their exact real Local execution" {
    inline for (std.meta.tags(Withdrawal)) |kind| try revokeWithdrawnAuthority(kind);
}

test "execution backend retains adapter service through Surface removal and the content release barrier" {
    var fixture: Fixture = undefined;
    try fixture.init();
    var roster = groups.Roster.init(a);
    defer roster.deinit();
    defer fixture.deinit();
    const target = try fixture.local();
    var store = assistants.Store.init(a);
    defer store.deinit();
    var bridge = Bridge.init(a);
    defer bridge.deinit();
    var controller = try makeController(&fixture, &store, &roster, &bridge, target, .auto);
    defer controller.deinitAfterWorker();
    var lookup: Lookup = .{ .controller = &controller };
    var broker: approvals.Broker = .{};
    var ctx = try backend.Context.init(.{ .app = fixture.app, .roster = &roster, .store = &store, .lookup_context = &lookup, .lookup_task = Lookup.find, .approval = &broker });
    try ctx.captureTask(&controller);
    var call = try Call.init(controller.authority, target, "printf 'never-submitted'", 97);
    defer call.deinit();
    var prepared = try backend.prepare(call.value, a);
    defer prepared.deinit();
    const permit = try approve(&ctx, &broker, &prepared);
    defer broker.finish(permit);
    const accepted = try authorize(&ctx, prepared);
    const legacy = fixture.app.legacyForHandle(target).?;
    const surface = fixture.workspace.sessionTab(legacy).?.terminal.?.terminal_surface.?;
    try std.testing.expect(accepted.service.context == surface.composite.raw.context);
    try std.testing.expect(accepted.service.context != surface.service.context);
    var contexts: [1]host.Context = undefined;
    try std.testing.expectEqual(@as(usize, 1), try ctx.beginClose(target, &contexts));
    const Hold = struct {
        released: bool = false,
        fn wait(raw: *anyopaque, _: @import("application_host.zig").LegacySessionId, step: @import("application_host.zig").CloseStep) @import("application_host.zig").CloseReceipt {
            const self: *@This() = @ptrCast(@alignCast(raw));
            return if (step == .release_content and !self.released) .awaiting else .released;
        }
    };
    var hold: Hold = .{};
    defer hold.released = true;
    fixture.app.setCloseExtension(&hold, Hold.wait);
    _ = try fixture.app.requestCloseLegacy(legacy);
    fixture.workspace.unbindLocalTerminal(legacy, target);
    const api = ctx.backend();
    const retained = try api.resolve(api.context, controller.authority, target);
    try std.testing.expect(retained.context == accepted.service.context and retained.binding.eql(accepted.service.binding));
    const deadline = @import("../platform/realtime.zig").monotonicNs() + 3 * std.time.ns_per_s;
    while (true) {
        _ = retained.executionSnapshot() catch |err| {
            if (err != error.WorkerBusy or @import("../platform/realtime.zig").monotonicNs() >= deadline) return err;
            try fixture.tick();
            continue;
        };
        break;
    }
    try std.testing.expectError(error.TargetNotAuthorized, api.terminal_call.?(api.context, retained, .{ .request = .{ .execution_id = .generate(), .task_id = controller.authority.task_id, .expected_input_epoch = 0, .ownership_revision = 1, .command = prepared.command, .command_hash = prepared.command_hash } }));
    hold.released = true;
}

test "execution backend controlled input requires separate exact approval and rejects changed authority before private dispatch" {
    var fixture: Fixture = undefined;
    try fixture.init();
    var roster = groups.Roster.init(a);
    defer roster.deinit();
    defer fixture.deinit();
    const target = try fixture.local();
    var store = assistants.Store.init(a);
    defer store.deinit();
    var bridge = Bridge.init(a);
    defer bridge.deinit();
    var controller = try makeController(&fixture, &store, &roster, &bridge, target, .auto);
    defer controller.deinitAfterWorker();
    var lookup: Lookup = .{ .controller = &controller };
    var broker: approvals.Broker = .{};
    var ctx = try backend.Context.init(.{ .app = fixture.app, .roster = &roster, .store = &store, .lookup_context = &lookup, .lookup_task = Lookup.find, .approval = &broker });
    try ctx.captureTask(&controller);
    var call = try Call.init(controller.authority, target, "zerowork_read", 71);
    defer call.deinit();
    var prepared = try backend.prepare(call.value, a);
    defer prepared.deinit();
    const run_permit = try approve(&ctx, &broker, &prepared);
    const accepted = try authorize(&ctx, prepared);
    const api = ctx.backend();
    const initial = try accepted.service.executionSnapshot();
    const id = identity.ExecutionId.generate();
    const request: execution.Request = .{ .execution_id = id, .task_id = controller.authority.task_id, .expected_input_epoch = initial.input_epoch, .ownership_revision = accepted.ownership_revision, .command = prepared.command, .command_hash = prepared.command_hash };
    const deadline = @import("../platform/realtime.zig").monotonicNs() + 8 * std.time.ns_per_s;
    while (true) {
        _ = api.terminal_call.?(api.context, accepted.service, .{ .request = request }) catch |err| {
            if (err == error.WorkerBusy) {
                try fixture.tick();
                continue;
            }
            return err;
        };
        break;
    }
    broker.finish(run_permit);
    var waiting: execution.Snapshot = undefined;
    while (true) {
        try fixture.tick();
        waiting = accepted.service.executionSnapshot() catch |err| {
            if (err == error.WorkerBusy) continue;
            return err;
        };
        if (waiting.input_wait != null) break;
        if (waiting.failure != null or @import("../platform/realtime.zig").monotonicNs() >= deadline) return error.InputWaitTimeout;
    }
    const raw = try std.fmt.allocPrint(a, "{{\"execution_ref\":\"x1:{s}\",\"request_key\":\"backend-input\",\"text\":\"normal answer\"}}", .{std.fmt.bytesToHex(id.bytes, .lower)});
    defer a.free(raw);
    var args = try std.json.parseFromSlice(std.json.Value, a, raw, .{});
    defer args.deinit();
    var invocation: host.Invocation = .{ .context = controller.authority, .authority = .execution_control, .operation_id = 72, .turn_id = 1, .call_id = "backend-input", .tool_id = "host.send_execution_input", .arguments = args.value, .arguments_json = raw, .arguments_hash = execution.digest(raw), .canonical_arguments_hash = try @import("../ai/canonical_arguments.zig").digest(a, args.value) };
    const input: execution.InputRequest = .{ .grant = waiting.grant.?, .wait_sequence = waiting.input_wait.?.sequence, .input_sequence = 1, .kind = .text, .text = "normal answer" };
    var input_prepared = try ctx.preflightInput(invocation, a);
    defer input_prepared.deinit();
    try std.testing.expect(input_prepared.subject.route == null);
    try std.testing.expectError(error.ApprovalRequired, api.authorize_input.?(api.context, invocation, target, id, input));
    const permit = try broker.beginSubject(invocation, input_prepared.subject, 1, a);
    defer broker.finish(permit);
    try broker.decide(permit.sequence, permit.arguments_hash, true);
    invocation.approval_sequence = permit.sequence;
    try api.authorize_input.?(api.context, invocation, target, id, input);
    // A different wait cannot reuse the same approved bytes or terminal.
    var changed_wait = input;
    changed_wait.wait_sequence += 1;
    try std.testing.expectError(error.InputConflict, api.authorize_input.?(api.context, invocation, target, id, changed_wait));
    var intervening = input;
    intervening.input_sequence = 99;
    intervening.text = "another approved line";
    while (true) {
        _ = api.terminal_call.?(api.context, accepted.service, .{ .input = intervening }) catch |err| {
            if (err == error.WorkerBusy) {
                try fixture.tick();
                continue;
            }
            return err;
        };
        break;
    }
    // A new accepted line changes the input impact even though this is still
    // the same foreground helper and wait/fence. The earlier permit is stale.
    try expectBusyError(&fixture, api.authorize_input.?, .{ api.context, invocation, target, id, input }, error.ScopeChanged);
    var secret_observation = input;
    secret_observation.kind = .host_secret;
    secret_observation.text = "";
    const observed = observed: while (true) {
        break :observed ctx.observeSecret(invocation.context, target, secret_observation) catch |err| {
            if (err == error.WorkerBusy and @import("../platform/realtime.zig").monotonicNs() < deadline) {
                try fixture.tick();
                continue;
            }
            return err;
        };
    };
    try std.testing.expect(observed.execution_id.?.eql(id) and observed.execution_fence == input.grant.fence);
    var wrong_fence = secret_observation;
    wrong_fence.grant.fence += 1;
    try expectBusyError(&fixture, backend.Context.observeSecret, .{ &ctx, invocation.context, target, wrong_fence }, error.StaleFence);
    fixture.config_.config_revision += 1;
    try std.testing.expectError(error.ScopeChanged, ctx.observeSecret(invocation.context, target, secret_observation));
    try std.testing.expectError(error.ScopeChanged, api.authorize_input.?(api.context, invocation, target, id, input));
    try std.testing.expectError(error.PermissionDenied, api.terminal_call.?(api.context, accepted.service, .{ .input = input }));
    fixture.config_.config_revision -= 1;
}

test "execution backend keeps config policy revision distinct from exact metadata input grant" {
    var fixture: Fixture = undefined;
    try fixture.init();
    var roster = groups.Roster.init(a);
    defer roster.deinit();
    defer fixture.deinit();
    const target = try fixture.local();
    var store = assistants.Store.init(a);
    defer store.deinit();
    var bridge = Bridge.init(a);
    defer bridge.deinit();
    var controller = try makeController(&fixture, &store, &roster, &bridge, target, .auto);
    defer controller.deinitAfterWorker();
    controller.authority.grant_revision = 7;
    bind(&bridge, controller.authority);
    bridge.policy_revision = fixture.config_.config_revision;
    var lookup: Lookup = .{ .controller = &controller };
    var broker: approvals.Broker = .{};
    var ctx = try backend.Context.init(.{ .app = fixture.app, .roster = &roster, .store = &store, .lookup_context = &lookup, .lookup_task = Lookup.find, .approval = &broker });
    try ctx.captureTask(&controller);
    var call = try Call.init(controller.authority, target, "true", 81);
    defer call.deinit();
    var prepared = try backend.prepare(call.value, a);
    defer prepared.deinit();
    const permit = try approve(&ctx, &broker, &prepared);
    defer broker.finish(permit);
    _ = try authorize(&ctx, prepared);
    bridge.policy_revision += 1;
    try std.testing.expectError(error.ScopeChanged, authorize(&ctx, prepared));
    bridge.policy_revision -= 1;
    controller.authority.grant_revision += 1;
    try std.testing.expectError(error.ScopeChanged, authorize(&ctx, prepared));
    controller.authority.grant_revision -= 1;
}

fn expectBusyError(fixture: *Fixture, function: anytype, args: anytype, expected: anyerror) !void {
    const deadline = @import("../platform/realtime.zig").monotonicNs() + 3 * std.time.ns_per_s;
    while (true) {
        if (@call(.auto, function, args)) |_| return error.UnexpectedSuccess else |err| {
            if (err == error.WorkerBusy and @import("../platform/realtime.zig").monotonicNs() < deadline) {
                try fixture.tick();
                continue;
            }
            return std.testing.expectEqual(expected, err);
        }
    }
}

test "execution backend withdrawn member observes original idle shell before fixture close" {
    // The original failure appeared on the eighth isolated membership close.
    // Exercise that short sequence plus one, without changing close budgets.
    for (0..9) |iteration| {
        std.debug.print("withdrawal cleanup regression iteration={d}\n", .{iteration});
        try revokeWithdrawnAuthority(.membership);
    }
}

test "current-tab execution preflight rejects external existing and nonexistent session references" {
    var fixture: Fixture = undefined;
    try fixture.init();
    var roster = groups.Roster.init(a);
    defer roster.deinit();
    defer fixture.deinit();
    const current = try fixture.local();
    const external = try fixture.local();
    var store = assistants.Store.init(a);
    defer store.deinit();
    var bridge = Bridge.init(a);
    defer bridge.deinit();
    var controller = try makeController(&fixture, &store, &roster, &bridge, current, .attached_pty);
    defer controller.deinitAfterWorker();
    var lookup: Lookup = .{ .controller = &controller };
    var broker: approvals.Broker = .{};
    var ctx = try backend.Context.init(.{ .app = fixture.app, .roster = &roster, .store = &store, .lookup_context = &lookup, .lookup_task = Lookup.find, .approval = &broker });
    try ctx.captureTask(&controller);
    var own = try Call.init(controller.authority, current, "true", 70);
    defer own.deinit();
    try ctx.validateInvocationScope(own.value);
    for ([_]identity.SessionHandle{ external, .{ .session_id = @fromBackingInt(999999), .generation = 88 } }) |outside| {
        var call = try Call.init(controller.authority, outside, "true", 71);
        defer call.deinit();
        try std.testing.expectError(error.TargetNotAuthorized, ctx.validateInvocationScope(call.value));
        var prepared = try backend.prepare(call.value, a);
        defer prepared.deinit();
        try std.testing.expectError(error.TargetNotAuthorized, ctx.preflight(prepared.invocation, prepared.command, prepared.command_hash));
    }
    const next = try handoff(&fixture, &store, &roster, &controller, &bridge, current);
    var within = try Call.init(next, current, "true", 72);
    defer within.deinit();
    try ctx.validateInvocationScope(within.value);
    try roster.leave("backend-handoff", fixture.app.legacyForHandle(current).?);
    try std.testing.expectError(error.TargetNotAuthorized, ctx.validateInvocationScope(within.value));
}
