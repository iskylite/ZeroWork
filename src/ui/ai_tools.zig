//! The assistant consumes registered tool contributions and captured typed
//! services. Builtin engines are opaque provider-contributed bridge instances.
const std = @import("std");
const Application = @import("application_host.zig");
const identity = @import("../host/identity.zig");
const loop = @import("../ai/tool_loop.zig");
const provider = @import("../ai/provider.zig");
const scope = @import("../ai/tool_scope.zig");
const tools = @import("../ai/plugin_tools.zig");
const legacy = @import("../ai/legacy_adapter.zig");
const typed = @import("../host/plugin_services.zig");
const operations = @import("../host/operation_store.zig");
pub const Approval = legacy.Approval;
const Child = struct {
    owner: identity.SessionHandle,
    adapter: ?legacy.Adapter = null,
    invocation_context: legacy.InvocationContext = undefined,
    member: tools.Member,
    live_services: std.ArrayList(typed.Binding) = .empty,
};
const ApprovalExchange = struct { invocation: tools.DynamicInvocation, ticket: *tools.ApprovalTicket, sequence: u64, decision: enum { pending, approved, rejected } = .pending };
const ControllerExchange = struct {
    target: tools.TargetBinding,
    invocation: tools.Invocation,
    allocator: std.mem.Allocator,
    ready: std.atomic.Value(bool) = .init(false),
    result: ?tools.ToolResult = null,
    failure: ?anyerror = null,
    cancel: ?*provider.CancelToken,
};
pub const Bridge = struct {
    allocator: std.mem.Allocator,
    events: ?*@import("../ai/step_events.zig").Mailbox = null,
    children: std.ArrayList(*Child) = .empty,
    captured_scope: ?scope.Scope = null,
    table: ?tools.RequestTable = null,
    wire: []provider.ToolDefinition = &.{},
    files: ?*@import("file_application_host.zig").Host = null,
    policy: tools.Policy = .{},
    policy_revision: u64 = 1,
    roster: ?*@import("group_model.zig").Roster = null,
    roster_revision: u64 = 0,
    mutex: std.atomic.Mutex = .unlocked,
    pending: ?*ApprovalExchange = null,
    controller: ?*ControllerExchange = null,
    running: ?tools.DynamicInvocation = null,
    sequence: u64 = 0,
    approval_target: [4096]u8 = undefined,
    stopped: std.atomic.Value(bool) = .init(false),
    owned_history: operations.Store,
    shared_history: ?*operations.Store = null,
    validation_arena: std.heap.ArenaAllocator,

    pub fn init(allocator: std.mem.Allocator) Bridge {
        return .{ .allocator = allocator, .owned_history = operations.Store.init(allocator), .validation_arena = .init(allocator) };
    }
    pub fn operationHistory(self: *Bridge) *operations.Store {
        return self.shared_history orelse &self.owned_history;
    }
    pub fn queryOperation(self: *Bridge, allocator: std.mem.Allocator, owner: identity.SessionHandle, operation_id: u64) !?operations.Snapshot {
        return self.operationHistory().snapshot(allocator, owner, operation_id);
    }
    fn lock(self: *Bridge) void {
        while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
    }
    pub fn configurePolicy(self: *Bridge, engine: @import("../ai/permission.zig").Engine, revision: u64) void {
        self.policy = .{ .engine = engine, .full_control = engine.mode == .auto };
        self.policy_revision = revision;
    }
    pub fn configureFiles(self: *Bridge, files: ?*@import("file_application_host.zig").Host) void {
        self.files = files;
    }
    pub fn prepare(self: *Bridge, app: *Application.ApplicationHost, owner: identity.SessionHandle) !void {
        var captured: scope.Scope = .{ .owner = .{ .session = @backingInt(owner.session_id) }, .members = .{} };
        captured.members.ids[0] = @backingInt(owner.session_id);
        captured.members.len = 1;
        try self.prepareScope(app, captured);
    }
    pub fn prepareGroup(self: *Bridge, app: *Application.ApplicationHost, roster: *@import("group_model.zig").Roster, captured: scope.Scope) !void {
        if (captured.owner != .group) return error.InvalidGroupOwner;
        const group = roster.findById(std.math.cast(u32, captured.owner.group) orelse return error.UnknownGroup) orelse return error.UnknownGroup;
        self.roster = roster;
        self.roster_revision = group.membership_revision;
        try self.prepareScope(app, captured);
    }
    fn prepareScope(self: *Bridge, app: *Application.ApplicationHost, captured: scope.Scope) !void {
        if (self.captured_scope != null or self.pending != null or self.controller != null) return error.ToolCleanupPending;
        self.shared_history = &app.domain.operation_history;
        self.captured_scope = captured;
        self.stopped.store(false, .release);
        errdefer self.clear() catch {};
        var definitions: std.ArrayList(tools.ToolDefinition) = .empty;
        defer definitions.deinit(self.allocator);
        var members: std.ArrayList(tools.Member) = .empty;
        defer members.deinit(self.allocator);
        for (captured.members.slice()) |id| {
            const owner = for (app.workspace.tabs.items) |tab| {
                if (tab.content_owner == .session and @backingInt(tab.content_owner.session.session_id) == id) break tab.content_owner.session;
            } else return error.StaleSession;
            const manifest = app.sessions.manifestFor(owner) orelse return error.AdapterNotConnected;
            if (!manifest.integration.ai) continue;
            const child = try self.allocator.create(Child);
            const bindings = app.sessions.typedBindingsFor(owner) orelse return error.ServiceUnavailable;
            child.* = .{ .owner = owner, .member = .{ .owner = owner, .plugin_id = manifest.id, .context = manifest.session_factory.?.context, .bindings = manifest.tools, .services = bindings, .capability_revision = app.sessions.capabilityRevisionFor(owner) orelse 0, .policy_revision = self.policy_revision } };
            self.children.append(self.allocator, child) catch |err| {
                self.allocator.destroy(child);
                return err;
            };
            try child.live_services.appendSlice(self.allocator, bindings);
            child.member.services = child.live_services.items;
            if (manifest.ai_adapter_factory) |factory| {
                child.adapter = try factory(self.allocator);
                const adapter = child.adapter.?;
                adapter.vtable.delegate(adapter.context, if (captured.owner == .group) captured.owner else null);
                adapter.vtable.files(adapter.context, if (self.files) |files| files else null);
                try adapter.vtable.prepare(adapter.context, app, owner);
                child.invocation_context = .{ .host = adapter.vtable.interface(adapter.context), .captured_scope = captured, .policy_revision = self.policy_revision };
                child.member.context = &child.invocation_context;
            }
            for (manifest.tool_definitions) |definition| {
                var found = false;
                for (definitions.items) |existing| if (std.mem.eql(u8, existing.id, definition.id)) {
                    if (!tools.sameDefinition(existing, definition)) return error.ToolDefinitionConflict;
                    found = true;
                    break;
                };
                if (!found) try definitions.append(self.allocator, definition);
            }
            try members.append(self.allocator, child.member);
        }
        self.table = try tools.RequestTable.init(self.allocator, captured, definitions.items, members.items);
        self.wire = try tools.providerDefinitions(&self.table.?, self.table.?.arena.allocator());
    }
    pub fn requestTable(self: *Bridge) ?*const tools.RequestTable {
        return if (self.table) |*table| table else null;
    }
    pub fn fill(self: *Bridge, out: []provider.ToolDefinition) !usize {
        if (out.len < self.wire.len) return error.ToolDefinitionCapacity;
        @memcpy(out[0..self.wire.len], self.wire);
        return self.wire.len;
    }
    pub fn toolIds(self: *Bridge, tool: scope.Tool) scope.Targets {
        var ids: scope.Targets = .{};
        const table = self.requestTable() orelse return ids;
        const entry = table.lookup(@tagName(tool)) orelse return ids;
        for (entry.targets) |target| {
            ids.ids[ids.len] = @backingInt(target.owner.session_id);
            ids.len += 1;
        }
        return ids;
    }
    pub fn remoteFilesAvailable(self: *Bridge) bool {
        return self.toolIds(.read_remote_file).len != 0;
    }
    pub fn interface(self: *Bridge) loop.Host {
        return .{ .context = self, .execute = unsupportedLegacy, .execute_dynamic = executeDynamic };
    }
    fn unsupportedLegacy(_: *anyopaque, _: loop.Invocation, _: std.mem.Allocator, _: ?*provider.CancelToken) !loop.Outcome {
        return error.ToolNotInRequest;
    }
    fn executeDynamic(raw: *anyopaque, invocation: tools.DynamicInvocation, allocator: std.mem.Allocator, cancel: ?*provider.CancelToken) ![]tools.ToolResult {
        const self: *Bridge = @ptrCast(@alignCast(raw));
        _ = self.validation_arena.reset(.retain_capacity);
        self.lock();
        self.running = invocation;
        self.mutex.unlock();
        defer {
            self.lock();
            self.running = null;
            self.mutex.unlock();
        }
        for (self.children.items) |child| child.invocation_context.cancel = cancel;
        self.emitStep(invocation, .running, "");
        const runtime: tools.Runtime = .{ .context = self, .live_scope = liveScope, .live_members = liveMembers, .current_policy = currentPolicy, .now_ms = timeNow, .approval = askApproval, .operations = self.operationHistory(), .invoke = invoke };
        const results = runtime.execute(invocation, allocator, cancel) catch |err| {
            self.emitStep(invocation, if (err == error.CancelledBeforeDispatch or (if (cancel) |token| token.isCancelled() else false)) .cancelled else .failed, @errorName(err));
            return err;
        };
        var detail: std.ArrayList(u8) = .empty;
        defer detail.deinit(allocator);
        var phase: @import("../ai/step_events.zig").Phase = .succeeded;
        for (results) |result| {
            if (result.status != .succeeded) phase = if (result.status == .rejected) .rejected else if (result.status == .cancelled_unsent) .cancelled else .failed;
            const label = std.fmt.allocPrint(allocator, "#{d} · {s}\n", .{ @backingInt(result.receipt.owner.session_id), @tagName(result.status) }) catch "";
            defer if (label.len != 0) allocator.free(label);
            detail.appendSlice(allocator, label) catch {};
            for (result.blocks) |block| switch (block) {
                .text, .structured => |bytes| {
                    detail.appendSlice(allocator, bytes) catch {};
                    detail.append(allocator, '\n') catch {};
                },
                else => {},
            };
        }
        self.emitStep(invocation, phase, detail.items);
        return results;
    }
    fn emitStep(self: *Bridge, invocation: tools.DynamicInvocation, phase: @import("../ai/step_events.zig").Phase, detail: []const u8) void {
        const events = self.events orelse return;
        const name = invocation.parsed.entry.definition.id;
        const args = invocation.parsed.json.value;
        const command = if (args == .object) blk: {
            for ([_][]const u8{ "command", "path" }) |key| if (args.object.get(key)) |value| if (value == .string) break :blk value.string;
            break :blk invocation.arguments;
        } else invocation.arguments;
        events.push(.{ .call_id = invocation.call_id, .name = name, .command = command, .detail = detail, .phase = phase, .at_ms = @intCast(timeNow(self)) }) catch {};
    }
    fn liveScope(raw: *anyopaque) !scope.Scope {
        const self: *Bridge = @ptrCast(@alignCast(raw));
        if (self.stopped.load(.acquire)) return error.CancelledBeforeDispatch;
        return self.captured_scope orelse error.AssistantOwnerChanged;
    }
    fn liveMembers(raw: *anyopaque) ![]const tools.Member {
        const self: *Bridge = @ptrCast(@alignCast(raw));
        self.lock();
        defer self.mutex.unlock();
        const a = self.validation_arena.allocator();
        const members = try a.alloc(tools.Member, self.children.items.len);
        for (self.children.items, members) |child, *member| {
            member.* = child.member;
            member.services = try a.dupe(typed.Binding, child.member.services);
        }
        return members;
    }
    fn currentPolicy(raw: *anyopaque) tools.Policy {
        return @as(*Bridge, @ptrCast(@alignCast(raw))).policy;
    }
    fn timeNow(_: *anyopaque) i64 {
        return @intCast(@divTrunc(@import("../platform/realtime.zig").monotonicNs(), std.time.ns_per_ms));
    }
    fn askApproval(raw: *anyopaque, invocation: tools.DynamicInvocation, ticket: *tools.ApprovalTicket, cancel: ?*provider.CancelToken) !bool {
        const self: *Bridge = @ptrCast(@alignCast(raw));
        self.lock();
        if (self.pending != null or self.stopped.load(.acquire)) {
            self.mutex.unlock();
            return error.CancelledBeforeDispatch;
        }
        self.sequence = try identity.advance(self.sequence +| @intFromBool(self.sequence == 0));
        var exchange: ApprovalExchange = .{ .invocation = invocation, .ticket = ticket, .sequence = self.sequence };
        self.pending = &exchange;
        self.emitStep(invocation, .approval, "等待用户确认");
        @import("../ai/tool_trace.zig").emit(.{ .event = "dynamic_approval_pending", .call_id = invocation.call_id, .tool_id = invocation.parsed.entry.definition.id, .owner = invocation.table.captured_scope.owner, .sequence = exchange.sequence, .arguments_hash = std.fmt.bytesToHex(ticket.arguments_hash, .lower), .expires_at_ms = ticket.expires_at_ms });
        self.mutex.unlock();
        defer {
            self.lock();
            self.pending = null;
            self.mutex.unlock();
        }
        while (true) {
            self.lock();
            const decision = exchange.decision;
            self.mutex.unlock();
            if (self.stopped.load(.acquire) or (if (cancel) |token| token.isCancelled() else false)) return error.CancelledBeforeDispatch;
            if (timeNow(self) >= ticket.expires_at_ms) return error.ToolApprovalExpired;
            switch (decision) {
                .approved => return true,
                .rejected => return false,
                .pending => pause(),
            }
        }
    }
    pub fn pendingApproval(self: *Bridge) ?Approval {
        self.lock();
        defer self.mutex.unlock();
        const current = self.pending orelse return null;
        if (current.decision != .pending or self.stopped.load(.acquire)) return null;
        const group = current.invocation.table.captured_scope.owner == .group;
        var target_writer: std.Io.Writer = .fixed(&self.approval_target);
        for (current.ticket.targets[0..current.ticket.len], 0..) |target, index| {
            var label: []const u8 = "会话";
            for (self.children.items) |child| if (child.owner.eql(target.owner)) {
                label = if (child.adapter) |adapter| adapter.vtable.label(adapter.context) else child.member.plugin_id;
                break;
            };
            if (index != 0) target_writer.writeAll("、") catch {};
            target_writer.writeAll(label) catch {};
            if (group) target_writer.print(" · #{d}", .{@backingInt(target.owner.session_id)}) catch {};
        }
        const tool_id = current.invocation.parsed.entry.definition.id;
        const arguments = current.invocation.parsed.json.value;
        const command = if (std.mem.eql(u8, tool_id, "run_command") and arguments == .object) blk: {
            const value = arguments.object.get("command") orelse break :blk current.invocation.arguments;
            break :blk if (value == .string) value.string else current.invocation.arguments;
        } else current.invocation.arguments;
        return .{ .group = group, .target = target_writer.buffered(), .tool_id = tool_id, .owner = current.ticket.targets[0].owner, .cwd = null, .sequence = current.sequence, .arguments_hash = current.invocation.parsed.arguments_hash, .command = command, .call_id = current.invocation.call_id };
    }
    pub fn decide(self: *Bridge, sequence: u64, hash: [32]u8, approved: bool) !void {
        self.lock();
        defer self.mutex.unlock();
        const current = self.pending orelse return error.StaleApproval;
        if (current.sequence != sequence or current.decision != .pending or !std.mem.eql(u8, &hash, &current.ticket.arguments_hash) or timeNow(self) >= current.ticket.expires_at_ms or self.stopped.load(.acquire)) return error.StaleApproval;
        current.decision = if (approved) .approved else .rejected;
        self.emitStep(current.invocation, if (approved) .approved else .rejected, if (approved) "用户已批准" else "用户已拒绝");
        @import("../ai/tool_trace.zig").emit(.{ .event = "dynamic_approval_decision", .call_id = current.invocation.call_id, .tool_id = current.invocation.parsed.entry.definition.id, .sequence = sequence, .approved = approved, .arguments_hash = std.fmt.bytesToHex(hash, .lower) });
    }
    fn invoke(raw: *anyopaque, target: tools.TargetBinding, request: tools.Invocation, allocator: std.mem.Allocator, cancel: ?*provider.CancelToken) !tools.ToolResult {
        const self: *Bridge = @ptrCast(@alignCast(raw));
        if (target.binding.execution == .worker) {
            if (self.stopped.load(.acquire) or (if (cancel) |token| token.isCancelled() else false)) return error.CancelledBeforeDispatch;
            try tools.markSent(self.operationHistory(), request.owner, request.operation_id, request.call_id, request.tool_id, request.arguments_hash);
            if (self.stopped.load(.acquire) or (if (cancel) |token| token.isCancelled() else false)) return error.CancelledBeforeDispatch;
            return target.binding.handler(target.context, request, allocator);
        }
        var exchange: ControllerExchange = .{ .target = target, .invocation = request, .allocator = allocator, .cancel = cancel };
        self.lock();
        if (self.controller != null or self.stopped.load(.acquire)) {
            self.mutex.unlock();
            return error.CancelledBeforeDispatch;
        }
        self.controller = &exchange;
        self.mutex.unlock();
        defer {
            self.lock();
            self.controller = null;
            self.mutex.unlock();
        }
        while (!exchange.ready.load(.acquire)) pause();
        if (exchange.failure) |err| return err;
        return exchange.result orelse error.ToolOutcomeUnknown;
    }
    pub fn pump(self: *Bridge, app: *Application.ApplicationHost) void {
        self.lock();
        var roster_valid = true;
        if (self.roster) |roster| if (self.captured_scope) |captured| {
            const group = roster.findById(@intCast(captured.owner.group));
            roster_valid = if (group) |value| value.membership_revision == self.roster_revision else false;
        };
        for (self.children.items) |child| {
            const current = app.sessions.typedBindingsFor(child.owner);
            child.member.authorized = roster_valid and current != null and app.legacyForHandle(child.owner) != null;
            child.member.capability_revision = app.sessions.capabilityRevisionFor(child.owner) orelse 0;
            child.member.policy_revision = app.workspace.app_config.config_revision;
            child.live_services.clearRetainingCapacity();
            if (current) |bindings| child.live_services.appendSlice(self.allocator, bindings) catch {
                child.member.authorized = false;
            };
            child.member.services = child.live_services.items;
        }
        if (self.controller) |current| if (!current.ready.load(.acquire)) {
            if (self.stopped.load(.acquire) or (if (current.cancel) |token| token.isCancelled() else false)) current.failure = error.CancelledBeforeDispatch else {
                // Controller effects recheck the current owner and full group
                // authority in the immediately preceding runtime preflight.
                var live_members: [scope.max_targets]tools.Member = undefined;
                for (self.children.items, 0..) |child, index| live_members[index] = child.member;
                const running = self.running orelse {
                    current.failure = error.ToolOperationAlreadyRecorded;
                    current.ready.store(true, .release);
                    self.mutex.unlock();
                    return;
                };
                tools.preflight(running.table, running.parsed, self.captured_scope.?, live_members[0..self.children.items.len]) catch |err| {
                    current.failure = err;
                    current.ready.store(true, .release);
                    self.mutex.unlock();
                    return;
                };
                if (current.invocation.effect == .remote_input) {
                    @import("plugin_window_host.zig").Host.authorizeInput(app, current.invocation.owner, true, self.policy_revision) catch |err| {
                        current.failure = err;
                        current.ready.store(true, .release);
                        self.mutex.unlock();
                        return;
                    };
                }
                defer if (current.invocation.effect == .remote_input) {
                    @import("plugin_window_host.zig").Host.authorizeInput(app, current.invocation.owner, false, self.policy_revision) catch {};
                };
                tools.markSent(self.operationHistory(), current.invocation.owner, current.invocation.operation_id, current.invocation.call_id, current.invocation.tool_id, current.invocation.arguments_hash) catch |err| {
                    current.failure = err;
                    current.ready.store(true, .release);
                    self.mutex.unlock();
                    return;
                };
                current.result = current.target.binding.handler(current.target.context, current.invocation, current.allocator) catch |err| blk: {
                    current.failure = err;
                    break :blk null;
                };
            }
            current.ready.store(true, .release);
        };
        self.mutex.unlock();
        for (self.children.items) |child| if (child.adapter) |adapter| {
            if (self.stopped.load(.acquire) or !child.member.authorized or child.member.policy_revision != self.policy_revision) _ = adapter.vtable.stop(adapter.context, child.owner);
            adapter.vtable.pump(adapter.context, app);
        };
    }
    pub fn sourceOwner(self: *Bridge, id: u64) ?identity.SessionHandle {
        for (self.children.items) |child| if (@backingInt(child.owner.session_id) == id) return child.owner;
        return null;
    }
    pub fn resultSources(self: *Bridge, out: *[16]@import("../ai/tool_results.zig").Source) []const @import("../ai/tool_results.zig").Source {
        for (self.children.items, 0..) |child, i| out[i] = .{ .owner = child.owner, .label = if (child.adapter) |adapter| adapter.vtable.label(adapter.context) else child.member.plugin_id };
        return out[0..self.children.items.len];
    }
    pub fn writeRisk(self: *Bridge, owner: identity.SessionHandle) bool {
        for (self.children.items) |child| if (child.owner.eql(owner)) if (child.adapter) |adapter| if (adapter.vtable.risk(adapter.context, owner)) return true;
        self.lock();
        defer self.mutex.unlock();
        if (self.pending) |pending| for (pending.invocation.parsed.targets.slice()) |id| if (id == @backingInt(owner.session_id)) return true;
        return false;
    }
    pub fn closeImpact(self: *Bridge, owner: identity.SessionHandle) @import("group_close_controller.zig").Impact {
        for (self.children.items) |child| if (child.owner.eql(owner)) if (child.adapter) |adapter| return adapter.vtable.impact(adapter.context, owner);
        return .{ .ai = @intFromBool(self.writeRisk(owner)) };
    }
    pub fn stopOwner(self: *Bridge, owner: identity.SessionHandle) Application.CloseReceipt {
        var receipt: Application.CloseReceipt = .released;
        for (self.children.items) |child| if (child.owner.eql(owner)) {
            self.stopped.store(true, .release);
            self.cancelOwnHistory(owner);
            if (child.adapter) |adapter| receipt = adapter.vtable.stop(adapter.context, owner);
        };
        return receipt;
    }
    pub fn stopGroup(self: *Bridge, group_id: u64) Application.CloseReceipt {
        if (self.captured_scope) |captured| if (captured.owner == .group and captured.owner.group == group_id) {
            self.stopped.store(true, .release);
            var receipt: Application.CloseReceipt = .released;
            for (self.children.items) |child| {
                const current = self.stopOwner(child.owner);
                if (current == .unknown or current == .awaiting and receipt == .released) receipt = current;
            }
            return receipt;
        };
        return .released;
    }
    pub fn shutdown(self: *Bridge, app: ?*Application.ApplicationHost) void {
        self.stopped.store(true, .release);
        for (self.children.items) |child| {
            self.cancelOwnHistory(child.owner);
            if (child.adapter) |adapter| adapter.vtable.shutdown(adapter.context, if (app) |host| host else null);
        }
    }
    fn cancelOwnHistory(self: *Bridge, owner: identity.SessionHandle) void {
        self.lock();
        const operation_id: ?u64 = if (self.running) |current| blk: {
            for (current.parsed.entry.targets) |target| if (target.owner.eql(owner)) break :blk current.operation_id;
            break :blk null;
        } else null;
        self.mutex.unlock();
        // A window/Bridge stop cancels only its own in-flight operation. The
        // owner may be alive in another window; never mark it globally closed.
        if (operation_id) |id| self.operationHistory().cancel(owner, id) catch {};
    }
    pub fn clear(self: *Bridge) !void {
        if (self.pending != null or self.controller != null) return error.ToolCleanupPending;
        for (self.children.items) |child| if (child.adapter) |adapter| try adapter.vtable.clear(adapter.context);
        if (self.table) |*table| table.deinit();
        self.table = null;
        self.wire = &.{};
        for (self.children.items) |child| {
            if (child.adapter) |adapter| adapter.vtable.destroy(adapter.context, self.allocator);
            child.live_services.deinit(self.allocator);
            self.allocator.destroy(child);
        }
        self.children.clearRetainingCapacity();
        self.captured_scope = null;
        self.roster = null;
    }
    pub fn deinit(self: *Bridge) void {
        self.clear() catch unreachable;
        self.children.deinit(self.allocator);
        self.owned_history.deinit();
        self.validation_arena.deinit();
        self.* = undefined;
    }
};
fn pause() void {
    var duration: std.c.timespec = .{ .sec = 0, .nsec = 5 * std.time.ns_per_ms };
    _ = std.c.nanosleep(&duration, null);
}
