//! Controller-thread host execution supervisor. Backend resolves and authorizes
//! exact live targets; workers retain every PTY/SSH/native input operation.
const std = @import("std");
const identity = @import("../host/identity.zig");
const terminal = @import("../host/terminal_service.zig");
const execution = terminal.execution;
const host = @import("host_tools.zig");
const journal_mod = @import("lifecycle_journal.zig");
const max_executions = 128;
const ref_field = "\"execution_ref\":{\"type\":\"string\",\"minLength\":1,\"maxLength\":128}";
const key_field = "\"request_key\":{\"type\":\"string\",\"minLength\":1,\"maxLength\":128}";
const output_fields = "\"output_cursor\":{\"type\":\"string\",\"maxLength\":128},\"max_bytes\":{\"type\":\"integer\",\"minimum\":1,\"maximum\":65536}";
pub const contributions = [_]host.Contribution{
    tool("run_in_terminal", "Execute the exact approved command in an authorized, ready terminal using its private shell protocol. Saves the same-PTY START/END observation interval; output_scope=session_interval and output_attribution describe its limits, never complete exclusive command output. Requires a durable recording barrier and empty trusted input boundary. Fixed modes and write approvals still apply. Returns an execution_ref and current asynchronous state; use get_execution/wait_execution. IntegrationUnavailable writes no command. Never replay an unknown outcome with a new request_key.", "{\"type\":\"object\",\"additionalProperties\":false,\"properties\":{\"session_ref\":{\"type\":\"string\",\"minLength\":1,\"maxLength\":128},\"command\":{\"type\":\"string\",\"minLength\":1,\"maxLength\":65534}," ++ key_field ++ "},\"required\":[\"session_ref\",\"command\",\"request_key\"]}"),
    tool("get_execution", "Read one execution in this conversation/task, its true process/output/recording stages, recording range and bounded incremental output. An ordinary prompt or printed marker never proves completion.", "{\"type\":\"object\",\"additionalProperties\":false,\"properties\":{" ++ ref_field ++ "," ++ output_fields ++ "},\"required\":[\"execution_ref\"]}"),
    tool("wait_execution", "Wait up to wait_ms for this authorized execution revision to change, then return the same bounded snapshot/output as get_execution. Timeout is not completion and never replays a command.", "{\"type\":\"object\",\"additionalProperties\":false,\"properties\":{" ++ ref_field ++ "," ++ output_fields ++ ",\"after_revision\":{\"type\":\"integer\",\"minimum\":0},\"wait_ms\":{\"type\":\"integer\",\"minimum\":0,\"maximum\":30000}},\"required\":[\"execution_ref\"]}"),
    tool("send_execution_input", "Send only an explicitly supported foreground interaction, with a current fence and fresh permission check. Text is single line UTF-8, at most 4096 bytes; Enter is a separate key request. Passwords/OTP use host_secret_request, never text. Unknown readline/raw/TUI interaction returns UnsupportedInteraction and offers user takeover.", "{\"type\":\"object\",\"additionalProperties\":false,\"properties\":{" ++ ref_field ++ "," ++ key_field ++ ",\"text\":{\"type\":\"string\",\"minLength\":1,\"maxLength\":4096},\"key\":{\"type\":\"string\",\"enum\":[\"enter\"]},\"host_secret_request\":{\"type\":\"boolean\"}},\"required\":[\"execution_ref\",\"request_key\"]}"),
    tool("stop_execution", "Revoke future AI input for this exact execution and request only its supported foreground interrupt. Release is distinct from process exit; unknown effects stay unknown. This never aborts a shared SSH transport or closes a borrowed terminal.", "{\"type\":\"object\",\"additionalProperties\":false,\"properties\":{" ++ ref_field ++ "," ++ key_field ++ "},\"required\":[\"execution_ref\",\"request_key\"]}"),
};
fn tool(comptime name: []const u8, description: []const u8, schema: []const u8) host.Contribution {
    const observing = std.mem.eql(u8, name, "get_execution") or std.mem.eql(u8, name, "wait_execution");
    return .{ .authority = .execution_control, .definition = .{ .id = "host." ++ name, .description = description, .schema = schema, .effect = if (observing) .read_state else .remote_input, .approval_policy = if (observing) .read_only else .always_confirm } };
}
pub fn supports(name: []const u8) bool {
    for (contributions) |item| if (std.mem.eql(u8, item.definition.id, name)) return true;
    return false;
}
/// These callbacks keep disk IO behind a shared process journal owner. The
/// direct Journal adapter remains useful for isolated controller tests.
pub const JournalAccess = struct {
    context: *anyopaque,
    begin_fn: *const fn (*anyopaque, journal_mod.Request) anyerror!journal_mod.Handle,
    snapshot_fn: *const fn (*anyopaque, std.mem.Allocator, journal_mod.Handle) anyerror!journal_mod.Record,
    update_fn: *const fn (*anyopaque, journal_mod.Handle, u64, journal_mod.Update) anyerror!void,
    pub fn from(comptime T: type, value: *T) JournalAccess {
        const Adapter = struct {
            fn begin(raw: *anyopaque, request: journal_mod.Request) !journal_mod.Handle {
                return (@as(*T, @ptrCast(@alignCast(raw)))).begin(request);
            }
            fn snapshot(raw: *anyopaque, a: std.mem.Allocator, handle: journal_mod.Handle) !journal_mod.Record {
                return (@as(*T, @ptrCast(@alignCast(raw)))).snapshot(a, handle);
            }
            fn update(raw: *anyopaque, handle: journal_mod.Handle, revision: u64, change: journal_mod.Update) !void {
                return (@as(*T, @ptrCast(@alignCast(raw)))).update(handle, revision, change);
            }
        };
        return .{ .context = value, .begin_fn = Adapter.begin, .snapshot_fn = Adapter.snapshot, .update_fn = Adapter.update };
    }
    pub fn begin(self: JournalAccess, request: journal_mod.Request) !journal_mod.Handle {
        return self.begin_fn(self.context, request);
    }
    pub fn snapshot(self: JournalAccess, a: std.mem.Allocator, handle: journal_mod.Handle) !journal_mod.Record {
        return self.snapshot_fn(self.context, a, handle);
    }
    pub fn update(self: JournalAccess, handle: journal_mod.Handle, revision: u64, change: journal_mod.Update) !void {
        return self.update_fn(self.context, handle, revision, change);
    }
};
pub const TerminalAction = union(enum) { snapshot, request: execution.Request, renew: execution.Grant, revoke: struct { grant: execution.Grant, takeover: bool }, output: struct { id: identity.ExecutionId, allocator: std.mem.Allocator, cursor: u64, max_bytes: usize } };
pub const TerminalResult = union(enum) { done, snapshot: execution.Snapshot, output: execution.Output };
pub fn performTerminal(service: terminal.Service, action: TerminalAction) !TerminalResult {
    return switch (action) {
        .snapshot => .{ .snapshot = try service.executionSnapshot() },
        .request => |request| blk: {
            try service.executionRequest(request);
            break :blk .done;
        },
        .renew => |grant| blk: {
            try service.executionRenew(grant);
            break :blk .done;
        },
        .revoke => |value| blk: {
            try service.executionRevoke(value.grant, value.takeover);
            break :blk .done;
        },
        .output => |value| .{ .output = try service.executionOutput(value.id, value.allocator, value.cursor, value.max_bytes) },
    };
}
pub const Target = struct { handle: identity.SessionHandle, service: terminal.Service, ownership_revision: u64 };
pub const Backend = struct {
    context: *anyopaque,
    /// Must revalidate binding/scope/generation, effective execution mode,
    /// exact normalized hash, forbid rules and any necessary approval.
    authorize: *const fn (*anyopaque, host.Invocation, []const u8, []const u8, [32]u8) anyerror!Target,
    /// Revalidate the original task/grant, binding/membership/generation and
    /// permission/mode/capability revisions at every dispatch/renewal. Returning
    /// a terminal by ID alone is insufficient authority.
    resolve: *const fn (*anyopaque, host.Context, identity.SessionHandle) anyerror!terminal.Service,
    should_cancel: ?*const fn (*anyopaque) bool = null,
    terminal_call: ?*const fn (*anyopaque, terminal.Service, TerminalAction) anyerror!TerminalResult = null,
    handed_to_user: ?*const fn (*anyopaque, identity.SessionHandle) anyerror!void = null,
};
const Entry = struct {
    context: host.Context,
    id: identity.ExecutionId,
    target: identity.SessionHandle,
    journal: journal_mod.Handle,
    journal_revision: u64,
    journal_stage: journal_mod.Stage,
    snapshot: execution.Snapshot,
    next_renew_at: i64,
    final_output: ?execution.Output = null,
    dispatch_pending: ?execution.Request = null,
    stop_intent: enum { none, stop, takeover } = .none,
};
/// Wait owns only copied metadata, never an invocation's JSON arena or strings.
pub const Wait = struct { context: host.Context, operation_id: u64, index: usize, after_revision: u64, deadline: i64, output_cursor: u64, max_bytes: usize };
pub const Response = union(enum) { result: host.Result, wait: Wait };
pub const Controller = struct {
    allocator: std.mem.Allocator,
    journal: JournalAccess,
    backend: Backend,
    entries: std.ArrayList(Entry) = .empty,
    finished_tasks: [128]?host.Context = @splat(null),
    pub fn init(allocator: std.mem.Allocator, journal: *journal_mod.Journal, backend: Backend) Controller {
        return initWithJournal(allocator, JournalAccess.from(journal_mod.Journal, journal), backend);
    }
    pub fn initWithJournal(allocator: std.mem.Allocator, journal: JournalAccess, backend: Backend) Controller {
        return .{ .allocator = allocator, .journal = journal, .backend = backend };
    }
    fn terminalCall(self: *Controller, service: terminal.Service, action: TerminalAction) !TerminalResult {
        if (self.backend.terminal_call) |call| return call(self.backend.context, service, action);
        return performTerminal(service, action);
    }
    fn terminalSnapshot(self: *Controller, service: terminal.Service) !execution.Snapshot {
        const receipt = try self.terminalCall(service, .snapshot);
        return if (receipt == .snapshot) receipt.snapshot else error.InvalidControllerReceipt;
    }
    fn terminalOutput(self: *Controller, service: terminal.Service, id: identity.ExecutionId, cursor_value: u64, max_bytes: usize) !execution.Output {
        const receipt = try self.terminalCall(service, .{ .output = .{ .id = id, .allocator = self.allocator, .cursor = cursor_value, .max_bytes = max_bytes } });
        return if (receipt == .output) receipt.output else error.InvalidControllerReceipt;
    }
    fn terminalRevoke(self: *Controller, service: terminal.Service, grant: execution.Grant, takeover_value: bool) !void {
        _ = try self.terminalCall(service, .{ .revoke = .{ .grant = grant, .takeover = takeover_value } });
    }
    pub fn deinit(self: *Controller) void {
        for (self.entries.items) |*entry| {
            if (entry.final_output) |*output| output.deinit(self.allocator);
            if (entry.dispatch_pending) |request| self.allocator.free(request.command) else {
                if (self.backend.resolve(self.backend.context, entry.context, entry.target)) |service| {
                    if (self.terminalSnapshot(service)) |current| {
                        if (current.grant) |grant| if (grant.execution_id.eql(entry.id)) self.terminalRevoke(service, grant, false) catch {};
                    } else |_| {}
                } else |_| {}
            }
        }
        self.entries.deinit(self.allocator);
    }
    pub fn execute(self: *Controller, invocation: host.Invocation, now: i64) !Response {
        try invocation.context.validate();
        if (invocation.authority != .execution_control or !supports(invocation.tool_id) or invocation.arguments != .object) return error.InvalidArguments;
        if (std.mem.eql(u8, invocation.tool_id, "host.run_in_terminal")) return .{ .result = try self.run(invocation, now) };
        const reference = try string(invocation.arguments, "execution_ref");
        const index = try self.find(invocation.context, reference);
        const is_stop = std.mem.eql(u8, invocation.tool_id, "host.stop_execution");
        if (!is_stop) try self.refresh(index, now);
        if (is_stop) {
            _ = try string(invocation.arguments, "request_key");
            const operation = try self.beginJournal(invocation);
            if (!operation.reused) {
                const record = try self.journal.snapshot(self.allocator, operation);
                defer {
                    var owned = record;
                    owned.deinit(self.allocator);
                }
                // Persist before the interrupt can reach the worker.
                try self.journal.update(operation, record.revision, .{ .stage = .dispatch_started, .execution = self.entries.items[index].id });
                self.requestStop(index, false, now);
                try self.journal.update(operation, record.revision + 1, .{ .stage = .succeeded, .execution = self.entries.items[index].id });
                try self.refresh(index, now);
            }
        } else if (std.mem.eql(u8, invocation.tool_id, "host.send_execution_input")) {
            _ = try string(invocation.arguments, "request_key");
            const text = invocation.arguments.object.get("text");
            const key = invocation.arguments.object.get("key");
            const secret = invocation.arguments.object.get("host_secret_request");
            if (@as(u8, @intFromBool(text != null)) + @as(u8, @intFromBool(key != null)) + @as(u8, @intFromBool(secret != null)) != 1) return error.InvalidArguments;
            if (text) |value| {
                if (value != .string) return error.InvalidArguments;
                try execution.validateInput(value.string);
            }
            if (key) |value| if (value != .string or !std.mem.eql(u8, value.string, "enter")) return error.InvalidArguments;
            if (secret) |value| {
                if (value != .bool or !value.bool) return error.InvalidArguments;
                return error.HostSecretUnavailable;
            }
            // Shell hooks prove execution association, but do not attest an
            // arbitrary child's readline identity or echo mode. No guessing.
            return error.UnsupportedInteraction;
        }
        const output_cursor = try cursor(invocation.arguments, "output_cursor");
        const max_bytes: usize = @intCast(try integer(invocation.arguments, "max_bytes", 8192, 1, 65536));
        if (std.mem.eql(u8, invocation.tool_id, "host.wait_execution")) {
            const after = try integer(invocation.arguments, "after_revision", self.entries.items[index].snapshot.revision, 0, std.math.maxInt(u64));
            const wait_ms = try integer(invocation.arguments, "wait_ms", 1000, 0, 30000);
            if (self.entries.items[index].snapshot.revision <= after and wait_ms > 0) return .{ .wait = .{ .context = invocation.context, .operation_id = invocation.operation_id, .index = index, .after_revision = after, .deadline = now + @as(i64, @intCast(wait_ms)), .output_cursor = output_cursor, .max_bytes = max_bytes } };
        }
        return .{ .result = try self.result(invocation.context, invocation.operation_id, index, output_cursor, max_bytes, false) };
    }
    pub fn pollWait(self: *Controller, wait: Wait, now: i64) !?host.Result {
        if (wait.index >= self.entries.items.len or !sameAuthority(self.entries.items[wait.index].context, wait.context)) return error.ExecutionNotFound;
        try self.refresh(wait.index, now);
        const changed = self.entries.items[wait.index].snapshot.revision > wait.after_revision;
        if (!changed and now < wait.deadline) return null;
        return try self.result(wait.context, wait.operation_id, wait.index, wait.output_cursor, wait.max_bytes, !changed);
    }
    /// Host control loop calls this independently of model polling; an abandoned
    /// tool worker therefore stops renewing and the terminal watchdog releases.
    pub fn finishTask(self: *Controller, context: host.Context) !void {
        var slot: ?usize = null;
        for (self.finished_tasks, 0..) |value, index| {
            if (value) |prior| {
                if (sameAuthority(prior, context)) return;
            } else if (slot == null) slot = index;
        }
        self.finished_tasks[slot orelse return error.ExecutionLimit] = context;
        // A known-unsent mailbox operation cannot become a new effect after
        // model_done. Already accepted/running commands keep their lease.
        for (self.entries.items, 0..) |entry, index| if (sameAuthority(entry.context, context) and entry.dispatch_pending != null) try self.cancelPending(index, "TaskFinishing");
    }
    fn taskFinishing(self: *const Controller, context: host.Context) bool {
        for (self.finished_tasks) |value| if (value) |prior| if (sameAuthority(prior, context)) return true;
        return false;
    }
    fn requestStop(self: *Controller, index: usize, takeover_value: bool, now: i64) void {
        const entry = &self.entries.items[index];
        if (takeover_value or entry.stop_intent == .none) entry.stop_intent = if (takeover_value) .takeover else .stop;
        self.refresh(index, now) catch {};
    }
    pub fn stopTarget(self: *Controller, context: host.Context, target: identity.SessionHandle) void {
        const now: i64 = @intCast(@divTrunc(@import("../platform/realtime.zig").monotonicNs(), std.time.ns_per_ms));
        for (self.entries.items, 0..) |entry, index| if (sameAuthority(entry.context, context) and entry.target.eql(target)) self.requestStop(index, false, now);
    }
    pub fn stopTask(self: *Controller, context: host.Context) void {
        self.finishTask(context) catch {};
        const now: i64 = @intCast(@divTrunc(@import("../platform/realtime.zig").monotonicNs(), std.time.ns_per_ms));
        for (self.entries.items, 0..) |entry, index| if (sameAuthority(entry.context, context)) self.requestStop(index, false, now);
    }
    pub fn tick(self: *Controller, now: i64) void {
        for (0..self.entries.items.len) |index| self.refresh(index, now) catch {};
    }
    pub fn takeover(self: *Controller, context: host.Context, reference: []const u8, now: i64) !execution.Snapshot {
        const index = try self.find(context, reference);
        const entry = &self.entries.items[index];
        // An old card cannot hand off a later execution in the same terminal.
        // Only this execution's current lease grants an input-transfer action.
        if (entry.dispatch_pending != null) return error.ExecutionNotControllable;
        const service = try self.backend.resolve(self.backend.context, entry.context, entry.target);
        const current = try self.terminalSnapshot(service);
        const observed = current.execution_id orelse return error.ExecutionNotControllable;
        if (!observed.eql(entry.id)) return error.StaleGeneration;
        if (current.input_handed_off and current.grant == null) return current;
        const grant = current.grant orelse return error.ExecutionNotControllable;
        if (!grant.execution_id.eql(entry.id) or !grant.task_id.eql(context.task_id) or !current.owner.eql(entry.target)) return error.StaleGeneration;
        // Ownership changes at acceptance, before waiting for native drain.
        if (self.backend.handed_to_user) |handoff| try handoff(self.backend.context, entry.target);
        self.requestStop(index, true, now);
        return entry.snapshot;
    }
    pub fn stopExecution(self: *Controller, context: host.Context, reference: []const u8, now: i64) !execution.Snapshot {
        const index = try self.find(context, reference);
        const entry = &self.entries.items[index];
        if (entry.dispatch_pending != null) {
            self.requestStop(index, false, now);
            return entry.snapshot;
        }
        const service = try self.backend.resolve(self.backend.context, entry.context, entry.target);
        const current = try self.terminalSnapshot(service);
        const observed = current.execution_id orelse return error.ExecutionNotControllable;
        if (!observed.eql(entry.id)) return error.StaleGeneration;
        const grant = current.grant orelse return error.ExecutionNotControllable;
        if (current.input_handed_off or !grant.execution_id.eql(entry.id) or !grant.task_id.eql(context.task_id) or !current.owner.eql(entry.target)) return error.ExecutionNotControllable;
        self.requestStop(index, false, now);
        return entry.snapshot;
    }
    pub fn takeoverTask(self: *Controller, context: host.Context, now: i64) !void {
        // Compatibility entry point for a single live target only. A human
        // taking one terminal never finishes the model or other terminals.
        var target: ?identity.ExecutionId = null;
        for (self.entries.items) |entry| {
            if (!sameAuthority(entry.context, context)) continue;
            if (entry.snapshot.grant == null or entry.snapshot.input_handed_off) continue;
            if (target != null) return error.TargetSelectionRequired;
            target = entry.id;
        }
        var reference: [35]u8 = undefined;
        const id = target orelse return error.ExecutionNotControllable;
        _ = try self.takeover(context, try std.fmt.bufPrint(&reference, "x1:{s}", .{std.fmt.bytesToHex(id.bytes, .lower)}), now);
    }
    fn run(self: *Controller, invocation: host.Invocation, now: i64) !host.Result {
        if (self.backend.should_cancel) |check| if (check(self.backend.context)) return error.CancelledBeforeDispatch;
        const ref = try string(invocation.arguments, "session_ref");
        const command = try execution.normalizeCommand(self.allocator, try string(invocation.arguments, "command"));
        defer self.allocator.free(command);
        const hash = execution.digest(command);
        var normalized_invocation = invocation;
        var args_copy: std.json.ObjectMap = .empty;
        defer args_copy.deinit(self.allocator);
        var iterator = invocation.arguments.object.iterator();
        while (iterator.next()) |item| try args_copy.put(self.allocator, item.key_ptr.*, if (std.mem.eql(u8, item.key_ptr.*, "command")) .{ .string = command } else item.value_ptr.*);
        normalized_invocation.canonical_arguments_hash = try @import("canonical_arguments.zig").digest(self.allocator, .{ .object = args_copy });
        const operation = try self.beginJournal(normalized_invocation);
        var record = try self.journal.snapshot(self.allocator, operation);
        defer record.deinit(self.allocator);
        if (operation.reused) {
            for (self.entries.items, 0..) |entry, index| if (entry.journal.operation_ref.eql(operation.operation_ref)) return self.result(invocation.context, invocation.operation_id, index, 0, 8192, false);
            // An in-process preflight may yield WorkerBusy before a dispatch
            // permit exists. Crash recovery converts that stage to cancelled.
            // A dispatch/terminal receipt is never reattached or replayed.
            if (record.stage != .prepared) return self.recoveredResult(invocation, record);
        }
        if (self.taskFinishing(invocation.context)) {
            try self.journal.update(operation, record.revision, .{ .stage = .cancelled_unsent });
            return error.TaskFinishing;
        }
        if (self.entries.items.len >= max_executions) return error.ExecutionLimit;
        try self.entries.ensureUnusedCapacity(self.allocator, 1);
        const target = self.backend.authorize(self.backend.context, invocation, ref, command, hash) catch |err| {
            if (err == error.WorkerBusy or err == error.ApprovalRequired) return err;
            try self.journal.update(operation, record.revision, .{ .stage = .rejected });
            return err;
        };
        self.tick(now);
        const snapshot = try self.terminalSnapshot(target.service);
        if (!snapshot.interactive_execution) {
            try self.journal.update(operation, record.revision, .{ .stage = .failed });
            return error.IntegrationUnavailable;
        }
        if (self.backend.should_cancel) |check| if (check(self.backend.context)) {
            try self.journal.update(operation, record.revision, .{ .stage = .cancelled_unsent });
            return error.CancelledBeforeDispatch;
        };
        const id = identity.ExecutionId.generate();
        const frozen_command = try self.allocator.dupe(u8, command);
        self.journal.update(operation, record.revision, .{ .stage = .dispatch_started, .execution = id }) catch |err| {
            self.allocator.free(frozen_command);
            return err;
        };
        self.entries.appendAssumeCapacity(.{ .context = invocation.context, .id = id, .target = target.handle, .journal = operation, .journal_revision = record.revision + 1, .journal_stage = .dispatch_started, .snapshot = .{ .owner = target.handle, .state = .preparing, .interactive_execution = true, .input_ready = true, .local_released = true, .output_scope = .session_interval }, .next_renew_at = now + execution.renew_ms, .dispatch_pending = .{ .execution_id = id, .task_id = invocation.context.task_id, .expected_input_epoch = snapshot.input_epoch, .ownership_revision = target.ownership_revision, .command = frozen_command, .command_hash = hash } });
        // Retry only a mailbox's explicit WorkerBusy/zero-admission response.
        // Any accepted, partial or unknown dispatch permanently clears pending.
        self.dispatchPending(self.entries.items.len - 1) catch {};
        return self.result(invocation.context, invocation.operation_id, self.entries.items.len - 1, 0, 8192, false);
    }
    fn beginJournal(self: *Controller, invocation: host.Invocation) !journal_mod.Handle {
        return self.journal.begin(.{ .context = invocation.context, .tool_id = invocation.tool_id, .request_key = try string(invocation.arguments, "request_key"), .canonical_hash = invocation.canonical_arguments_hash, .turn_id = invocation.turn_id, .call_id = invocation.call_id });
    }
    fn cancelPending(self: *Controller, index: usize, reason: []const u8) !void {
        const entry = &self.entries.items[index];
        const request = entry.dispatch_pending orelse return;
        try self.journal.update(entry.journal, entry.journal_revision, .{ .stage = .failed, .execution = entry.id });
        entry.journal_revision += 1;
        entry.journal_stage = .failed;
        self.allocator.free(request.command);
        entry.dispatch_pending = null;
        entry.stop_intent = .none;
        entry.snapshot.state = .cancelled_unsent;
        entry.snapshot.failure = reason;
        entry.snapshot.recording_settled = true;
        entry.snapshot.local_released = true;
        entry.snapshot.input_ready = true;
        entry.snapshot.revision +|= 1;
    }
    fn dispatchPending(self: *Controller, index: usize) !void {
        const entry = &self.entries.items[index];
        const request = entry.dispatch_pending orelse return;
        if (self.backend.should_cancel) |check| if (check(self.backend.context)) {
            try self.cancelPending(index, "CancelledBeforeDispatch");
            return;
        };
        const service = self.backend.resolve(self.backend.context, entry.context, entry.target) catch |err| {
            if (err == error.WorkerBusy) return;
            try self.cancelPending(index, @errorName(err));
            return;
        };
        _ = self.terminalCall(service, .{ .request = request }) catch |err| {
            if (err == error.WorkerBusy) return;
            try self.cancelPending(index, @errorName(err));
            return;
        };
        self.allocator.free(request.command);
        entry.dispatch_pending = null;
    }
    fn refresh(self: *Controller, index: usize, now: i64) !void {
        const entry = &self.entries.items[index];
        if (entry.dispatch_pending != null) {
            if (entry.stop_intent != .none) {
                try self.cancelPending(index, "CancelledBeforeDispatch");
                return;
            }
            try self.dispatchPending(index);
            if (entry.dispatch_pending != null) return;
        }
        // A later execution in the same shell must not overwrite an old card.
        if (terminalState(entry.snapshot.state) and entry.snapshot.recording_settled and entry.snapshot.local_released) {
            entry.stop_intent = .none;
            return;
        }
        const service = self.backend.resolve(self.backend.context, entry.context, entry.target) catch |err| {
            if (err == error.WorkerBusy) return err;
            var unavailable = entry.snapshot;
            unavailable.state = .outcome_unknown;
            unavailable.remote_effect_unknown = true;
            unavailable.failure = "TargetUnavailable";
            unavailable.revision +|= 1;
            if (entry.journal_stage != .outcome_unknown) {
                try self.journal.update(entry.journal, entry.journal_revision, .{ .stage = .outcome_unknown, .execution = entry.id, .execution_receipt = execution.PublicReceipt.fromSnapshot(unavailable), .local_released = false, .remote_effect_unknown = true });
                entry.journal_revision += 1;
                entry.journal_stage = .outcome_unknown;
            }
            entry.snapshot = unavailable;
            return;
        };
        var current = try self.terminalSnapshot(service);
        if (current.execution_id) |observed| if (!observed.eql(entry.id)) {
            // A missed finish cannot be supplied by a later command. The
            // worker's next begin proves the old local grant/record settled,
            // but supplies no completion or output range for this old card.
            var superseded = entry.snapshot;
            superseded.state = .outcome_unknown;
            superseded.grant = null;
            superseded.input_ready = true;
            superseded.local_released = true;
            superseded.remote_effect_unknown = true;
            superseded.recording_settled = true;
            superseded.recording_failed = true;
            superseded.failure = "ExecutionSuperseded";
            superseded.revision +|= 1;
            try self.journal.update(entry.journal, entry.journal_revision, .{ .stage = .outcome_unknown, .execution = entry.id, .execution_receipt = execution.PublicReceipt.fromSnapshot(superseded), .local_released = true, .remote_effect_unknown = true });
            entry.journal_revision += 1;
            entry.journal_stage = .outcome_unknown;
            entry.snapshot = superseded;
            entry.stop_intent = .none;
            return;
        };
        if (current.grant) |grant| if (!grant.execution_id.eql(entry.id)) return error.StaleGeneration;
        if (entry.stop_intent != .none) {
            if (current.grant) |grant| {
                try self.terminalRevoke(service, grant, entry.stop_intent == .takeover);
                current = try self.terminalSnapshot(service);
            }
            if (current.grant == null and current.local_released and current.input_ready) entry.stop_intent = .none;
        }
        const previous = entry.snapshot;
        if (terminalState(current.state) and entry.final_output == null) entry.final_output = self.terminalOutput(service, entry.id, 0, 65536) catch null;
        if (current.grant) |grant| if (entry.stop_intent == .none and now >= entry.next_renew_at) {
            _ = try self.terminalCall(service, .{ .renew = grant });
            entry.next_renew_at = now + execution.renew_ms;
        };
        const next: journal_mod.Stage = switch (current.state) {
            .running, .awaiting_submit, .process_finished, .output_draining, .recording_sealing => .running,
            // The journal stage describes the real foreground outcome. A
            // saved interval remains distinct from an exact sealed receipt.
            .sealed, .interval_recorded => if (current.process != null and current.process.?.exit_code != null and current.process.?.exit_code.? == 0) .succeeded else .failed,
            .cancelled_unsent => .failed,
            .outcome_unknown, .handed_off, .recording_degraded => .outcome_unknown,
            else => entry.journal_stage,
        };
        if (next != entry.journal_stage or !sameReceipt(execution.PublicReceipt.fromSnapshot(previous), execution.PublicReceipt.fromSnapshot(current))) {
            try self.journal.update(entry.journal, entry.journal_revision, .{ .stage = next, .execution = entry.id, .execution_receipt = execution.PublicReceipt.fromSnapshot(current), .local_released = current.local_released, .remote_effect_unknown = current.remote_effect_unknown });
            entry.journal_revision += 1;
            entry.journal_stage = next;
        }
        // Driver evidence may release the retained Service only after these
        // exact process/record/input facts are durable. Keep the prior snapshot
        // on publication failure so the next refresh retries the transaction.
        entry.snapshot = current;
    }
    fn find(self: *Controller, context: host.Context, reference: []const u8) !usize {
        if (!std.mem.startsWith(u8, reference, "x1:")) return error.ExecutionNotFound;
        const id = identity.ExecutionId.parse(reference[3..]) catch return error.ExecutionNotFound;
        for (self.entries.items, 0..) |entry, index| if (entry.id.eql(id) and sameAuthority(entry.context, context)) return index;
        return error.ExecutionNotFound;
    }
    fn result(self: *Controller, context: host.Context, operation_id: u64, index: usize, output_cursor: u64, max_bytes: usize, timed_out: bool) !host.Result {
        const entry = self.entries.items[index];
        const ref = try std.fmt.allocPrint(self.allocator, "x1:{s}", .{std.fmt.bytesToHex(entry.id.bytes, .lower)});
        defer self.allocator.free(ref);
        var output: ?execution.Output = null;
        defer if (output) |*value| value.deinit(self.allocator);
        if (entry.final_output) |cached| {
            if (output_cursor > cached.next_cursor) return error.InvalidCursor;
            const start = @max(output_cursor, cached.start_cursor);
            const offset: usize = @intCast(start - cached.start_cursor);
            const count = @min(@min(max_bytes, 8192), cached.bytes.len - offset);
            output = .{ .bytes = try self.allocator.dupe(u8, cached.bytes[offset..][0..count]), .start_cursor = start, .next_cursor = start + count, .gap = output_cursor < cached.start_cursor or cached.gap, .truncated = offset + count < cached.bytes.len };
        } else if (self.backend.resolve(self.backend.context, context, entry.target)) |service| {
            output = self.terminalOutput(service, entry.id, output_cursor, @min(max_bytes, 8192)) catch null;
        } else |_| {}
        const safe = if (output) |value| try sanitized(self.allocator, value.bytes) else try self.allocator.dupe(u8, "");
        defer self.allocator.free(safe);
        const next_cursor = try std.fmt.allocPrint(self.allocator, "{d}", .{if (output) |value| value.next_cursor else output_cursor});
        defer self.allocator.free(next_cursor);
        const body = try std.json.Stringify.valueAlloc(self.allocator, .{ .execution_ref = ref, .path = "interactive", .observed_at = @import("../platform/realtime.zig").milliseconds(undefined), .state = entry.snapshot.state, .source_revision = entry.snapshot.revision, .snapshot = entry.snapshot, .stop_requested = entry.stop_intent != .none, .output_available = output != null, .recording_ref = if (entry.snapshot.recording_id) |*value| @as([]const u8, value) else null, .output = safe, .output_cursor = if (output) |value| value.start_cursor else output_cursor, .next_cursor = next_cursor, .gap = if (output) |value| value.gap else false, .truncated = if (output) |value| value.truncated else false, .timed_out = timed_out }, .{});
        errdefer self.allocator.free(body);
        if (body.len > 65536) return error.ResultLimit;
        return ownedResult(self.allocator, context, operation_id, body, entry.snapshot.submit_sent or entry.snapshot.submit_native_bytes != 0, entry.snapshot.remote_effect_unknown or entry.snapshot.state == .outcome_unknown);
    }
    fn recoveredResult(self: *Controller, invocation: host.Invocation, record: journal_mod.Record) !host.Result {
        const body = try std.json.Stringify.valueAlloc(self.allocator, .{ .operation_ref = record.operation_ref, .execution_id = record.execution, .state = record.stage, .execution_receipt = record.execution_receipt, .local_released = record.local_released, .remote_effect_unknown = record.remote_effect_unknown, .replayed = false, .recovery_hint = "Inspect the persisted recording; reconnect/replay requires new explicit user intent." }, .{});
        errdefer self.allocator.free(body);
        return ownedResult(self.allocator, invocation.context, invocation.operation_id, body, record.dispatch_started, record.remote_effect_unknown or record.stage == .outcome_unknown);
    }
};
fn sameReceipt(a: ?execution.PublicReceipt, b: ?execution.PublicReceipt) bool {
    var left = a orelse return b == null;
    var right = b orelse return false;
    if (left.output_attribution_reason) |reason| {
        if (right.output_attribution_reason == null or !std.mem.eql(u8, reason, right.output_attribution_reason.?)) return false;
    } else if (right.output_attribution_reason != null) return false;
    left.output_attribution_reason = null;
    right.output_attribution_reason = null;
    return std.meta.eql(left, right);
}
fn terminalState(state: execution.State) bool {
    return switch (state) {
        .sealed, .interval_recorded, .cancelled_unsent, .handed_off, .outcome_unknown, .recording_degraded => true,
        else => false,
    };
}
fn sameAuthority(a: host.Context, b: host.Context) bool {
    return a.conversation_id.eql(b.conversation_id) and a.task_id.eql(b.task_id);
}
fn string(args: std.json.Value, name: []const u8) ![]const u8 {
    const value = args.object.get(name) orelse return error.InvalidArguments;
    if (value != .string) return error.InvalidArguments;
    return value.string;
}
fn integer(args: std.json.Value, name: []const u8, default: u64, min: u64, max: u64) !u64 {
    const value = args.object.get(name) orelse return default;
    if (value != .integer or value.integer < 0) return error.InvalidArguments;
    const result: u64 = @intCast(value.integer);
    if (result < min or result > max) return error.InvalidArguments;
    return result;
}
fn cursor(args: std.json.Value, name: []const u8) !u64 {
    const value = args.object.get(name) orelse return 0;
    if (value != .string) return error.InvalidArguments;
    return std.fmt.parseInt(u64, value.string, 10) catch error.InvalidCursor;
}
fn ownedResult(a: std.mem.Allocator, context: host.Context, operation_id: u64, body: []const u8, started: bool, unknown: bool) !host.Result {
    const blocks = try a.alloc(host.Block, 1);
    blocks[0] = .{ .structured = body };
    return .{ .status = if (unknown) .outcome_unknown else .succeeded, .blocks = blocks, .receipt = .{ .conversation_id = context.conversation_id, .task_id = context.task_id, .operation_id = operation_id, .binding_revision = context.binding_revision, .side_effect_started = started, .remote_effect_unknown = unknown } };
}

test "execution unknown receipt retains its uncertainty and never becomes a successful RPC" {
    const a = std.testing.allocator;
    const context: host.Context = .{ .conversation_id = identity.ConversationId.generate(), .task_id = identity.TaskId.generate(), .binding = .{ .session = 1 }, .binding_revision = 1, .grant_revision = 1 };
    var result = try ownedResult(a, context, 7, try a.dupe(u8, "{\"state\":\"outcome_unknown\"}"), true, true);
    defer result.deinit(a);
    try result.validate(context, 7);
    try std.testing.expectEqual(.outcome_unknown, result.status);
    try std.testing.expect(result.receipt.side_effect_started and result.receipt.remote_effect_unknown and result.receipt.local_released);
}
fn sanitized(a: std.mem.Allocator, bytes: []const u8) ![]u8 {
    if (std.unicode.utf8ValidateSlice(bytes)) return a.dupe(u8, bytes);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    var index: usize = 0;
    while (index < bytes.len) {
        const length = std.unicode.utf8ByteSequenceLength(bytes[index]) catch 0;
        if (length != 0 and length <= bytes.len - index and std.unicode.utf8ValidateSlice(bytes[index..][0..length])) {
            try out.appendSlice(a, bytes[index..][0..length]);
            index += length;
        } else {
            try out.appendSlice(a, "�");
            index += 1;
        }
    }
    return out.toOwnedSlice(a);
}

test "execution target stop keeps other members running and preserves revocation across a busy mailbox" {
    const Mock = struct {
        fn authorize(_: *anyopaque, _: host.Invocation, _: []const u8, _: []const u8, _: [32]u8) !Target {
            return error.NotAuthorized;
        }
        fn resolve(_: *anyopaque, _: host.Context, _: identity.SessionHandle) !terminal.Service {
            return error.WorkerBusy;
        }
    };
    const a = std.testing.allocator;
    var marker: u8 = 0;
    var controller = Controller.initWithJournal(a, undefined, .{ .context = &marker, .authorize = Mock.authorize, .resolve = Mock.resolve });
    defer controller.deinit();
    const context: host.Context = .{ .conversation_id = .generate(), .task_id = .generate(), .binding = .{ .group = 9 }, .binding_revision = 1, .grant_revision = 1 };
    const first: identity.SessionHandle = .{ .session_id = @fromBackingInt(1), .generation = 1 };
    const second: identity.SessionHandle = .{ .session_id = @fromBackingInt(2), .generation = 1 };
    for ([_]identity.SessionHandle{ first, second }) |target| {
        const id = identity.ExecutionId.generate();
        try controller.entries.append(a, .{ .context = context, .id = id, .target = target, .journal = .{ .index = 0, .operation_ref = .generate() }, .journal_revision = 1, .journal_stage = .running, .snapshot = .{ .owner = target, .execution_id = id, .state = .running }, .next_renew_at = 0 });
    }
    controller.stopTarget(context, first);
    try std.testing.expect(controller.entries.items[0].stop_intent == .stop);
    try std.testing.expect(controller.entries.items[1].stop_intent == .none);
    controller.tick(10);
    try std.testing.expect(controller.entries.items[0].stop_intent == .stop);
    try std.testing.expect(controller.entries.items[1].stop_intent == .none);
    try std.testing.expect(!controller.taskFinishing(context));
}

test "execution interval publication failure retains prior evidence and retries the exact durable receipt" {
    const Mock = struct {
        current: execution.Snapshot,
        fn authorize(_: *anyopaque, _: host.Invocation, _: []const u8, _: []const u8, _: [32]u8) !Target {
            return error.NotAuthorized;
        }
        fn resolve(raw: *anyopaque, _: host.Context, _: identity.SessionHandle) !terminal.Service {
            return .{ .context = raw, .binding = undefined, .vtable = undefined };
        }
        fn call(raw: *anyopaque, _: terminal.Service, action: TerminalAction) !TerminalResult {
            const self: *@This() = @ptrCast(@alignCast(raw));
            return switch (action) {
                .snapshot => .{ .snapshot = self.current },
                .output => |value| .{ .output = .{ .bytes = try value.allocator.alloc(u8, 0), .start_cursor = 0, .next_cursor = 0, .gap = false, .truncated = false } },
                else => error.UnexpectedTerminalAction,
            };
        }
    };
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var journal = try journal_mod.Journal.open(a, std.testing.io, tmp.dir, "publication.json");
    defer journal.deinit();
    const context: host.Context = .{ .conversation_id = .generate(), .task_id = .generate(), .binding = .{ .session = 1 }, .binding_revision = 1, .grant_revision = 1 };
    const target: identity.SessionHandle = .{ .session_id = @fromBackingInt(1), .generation = 1 };
    const id = identity.ExecutionId.generate();
    const operation = try journal.begin(.{ .context = context, .tool_id = "host.run_in_terminal", .request_key = "interval-publication", .canonical_hash = @splat(1), .turn_id = 1, .call_id = "publication-call" });
    try journal.update(operation, 1, .{ .stage = .dispatch_started, .execution = id, .local_released = false });
    const previous: execution.Snapshot = .{ .owner = target, .execution_id = id, .state = .running, .execution_fence = 1, .execution_input_epoch = 1, .input_ready = false, .local_released = false, .command_accepted = true, .submit_sent = true, .accepted_sequence = 1, .submit_sequence = 2, .submit_ack_sequence = 3, .submit_native_bytes = 5, .native_wake_written = true, .recording_id = "0123456789abcdef0123456789abcdef".*, .recording_generation = 1, .start = .{ .raw_offset = 0, .sequence = 1, .event_sequence = 1 }, .manifest_revision = 1, .output_scope = .session_interval, .output_attribution_reason = "OutputProcessIdentityUnknown" };
    try journal.update(operation, 2, .{ .stage = .running, .execution_receipt = execution.PublicReceipt.fromSnapshot(previous), .local_released = false });
    var mock: Mock = .{ .current = previous };
    mock.current.state = .interval_recorded;
    mock.current.end = .{ .raw_offset = 20, .sequence = 2, .event_sequence = 2 };
    mock.current.process = .{ .exit_code = 0, .foreground_finished = true };
    mock.current.input_ready = true;
    mock.current.local_released = true;
    mock.current.recording_settled = true;
    mock.current.interval_saved = true;
    mock.current.manifest_revision = 2;
    mock.current.revision += 1;
    var controller = Controller.init(a, &journal, .{ .context = &mock, .authorize = Mock.authorize, .resolve = Mock.resolve, .terminal_call = Mock.call });
    defer controller.deinit();
    try controller.entries.append(a, .{ .context = context, .id = id, .target = target, .journal = operation, .journal_revision = 3, .journal_stage = .running, .snapshot = previous, .next_renew_at = 0 });
    const durable = try tmp.dir.readFileAlloc(std.testing.io, "publication.json", a, .limited(journal_mod.max_file_bytes));
    defer a.free(durable);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "publication.json", .data = "external change" });
    try std.testing.expectError(error.JournalConflict, controller.refresh(0, 10));
    try std.testing.expect(controller.entries.items[0].snapshot.state == .running and !controller.entries.items[0].snapshot.recording_settled);
    try std.testing.expectEqual(@as(u64, 3), controller.entries.items[0].journal_revision);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "publication.json", .data = durable });
    try controller.refresh(0, 11);
    try std.testing.expect(controller.entries.items[0].snapshot.state == .interval_recorded and controller.entries.items[0].snapshot.interval_saved);
    var saved = try journal.snapshot(a, operation);
    defer saved.deinit(a);
    try std.testing.expect(saved.stage == .succeeded and saved.execution_receipt.?.interval_saved and !saved.execution_receipt.?.sealed);
}
