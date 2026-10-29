//! Controller-only projection. It reads metadata and never resolves an exec,
//! network, terminal-content or credential service.
const std = @import("std");
const queries = @import("../ai/host_queries.zig");
const host = @import("../ai/host_tools.zig");
const identity = @import("../host/identity.zig");
const config = @import("../config/config.zig");
const terminal = @import("../host/terminal_service.zig");
const Application = @import("application_host.zig").ApplicationHost;
const SessionTab = @import("workspace.zig").SessionTab;

pub const Options = struct {
    /// Policies captured when this Task was prepared, independent of defaults
    /// or composer selections made while its worker is still running.
    execution_policy: config.ExecutionPolicy,
    permission_mode: config.PermissionMode,
    host_contributions: []const host.Contribution,
};

pub fn execute(app: *Application, roster: ?*@import("group_model.zig").Roster, initial: @import("../ai/tool_scope.zig").Owner, options: Options, cursor_key: [32]u8, invocation: host.Invocation, allocator: std.mem.Allocator) !host.Result {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var sessions: std.ArrayList(queries.Session) = .empty;
    var members: std.ArrayList(identity.SessionHandle) = .empty;
    const binding = invocation.context.binding;
    const group = if (binding == .group) (roster orelse return error.ContextUnavailable).findById(std.math.cast(u32, binding.group) orelse return error.ContextUnavailable) orelse return error.ContextUnavailable else null;
    var lifecycle_management = false;
    const execution_control = executionToolsAvailable(options.host_contributions);
    for (options.host_contributions) |contribution| {
        if (contribution.authority == .lifecycle) lifecycle_management = true;
    }
    for (app.workspace.tabs.items) |tab| {
        if (tab.content_owner != .session) continue;
        const handle = tab.content_owner.session;
        const visible = if (group) |value| blk: {
            for (value.members.items) |member| if (member.pane_id == tab.id) break :blk true;
            break :blk false;
        } else @backingInt(handle.session_id) == binding.session;
        if (!visible) continue;
        const state = app.sessions.queryState(handle) orelse continue;
        const manifest = app.sessions.manifestFor(handle) orelse continue;
        var read_terminal = false;
        var batch_execution = false;
        for (manifest.tools) |tool| {
            if (std.mem.eql(u8, tool.definition_id, "read_terminal")) read_terminal = true;
            if (std.mem.eql(u8, tool.definition_id, "run_command")) batch_execution = true;
        }
        try members.append(a, handle);
        const ready = !tab.closing and !tab.archived and !tab.failed and !tab.owned_pending and (state.lifecycle == .ready or state.lifecycle == .attached);
        const pty = if (execution_control and ready) trustedPtyInfo(app, tab, handle) else PtyInfo{};
        const owned = if (app.lifecycle_supervisor.resource(handle)) |entry| entry.request.context.conversation_id.eql(invocation.context.conversation_id) and entry.request.context.task_id.eql(invocation.context.task_id) and entry.snapshot.ownership == .created_task else false;
        try sessions.append(a, .{ .handle = handle, .title = if (app.workspace.app_config.ai.redact_ip) "<redacted>" else tab.titleSlice(), .protocol = state.protocol_id, .state = @tagName(state.lifecycle), .ready = ready, .read_terminal = read_terminal, .batch_execution = batch_execution, .trusted_pty_execution = pty.ready, .trusted_pty_state = pty.state, .trusted_pty_failure = pty.failure, .saved_source = associatedAsset(app, handle), .task_owned = owned, .capability_revision = app.sessions.capabilityRevisionFor(handle) orelse 0 });
    }
    var groups: [1]queries.Group = undefined;
    if (group) |value| groups[0] = .{ .id = value.id, .name = if (app.workspace.app_config.ai.redact_ip) "<redacted>" else value.name, .membership_revision = value.membership_revision, .members = members.items };
    const visible_groups = groups[0..@intFromBool(group != null)];
    const revision_source = try std.json.Stringify.valueAlloc(a, .{ sessions.items, visible_groups, invocation.context, options.execution_policy, options.permission_mode, lifecycle_management, execution_control, app.workspace.app_config.config_revision }, .{});
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(revision_source, &digest, .{});
    const revision = std.mem.readInt(u64, digest[0..8], .little);
    return queries.execute(.{ .context = invocation.context, .initial_binding = initial, .execution_policy = options.execution_policy, .permission_mode = options.permission_mode, .lifecycle_management = lifecycle_management, .observed_at = @import("../platform/realtime.zig").milliseconds(app), .source_revision = if (revision == 0) 1 else revision, .cursor_key = cursor_key, .sessions = sessions.items, .groups = visible_groups }, invocation, allocator);
}

fn executionToolsAvailable(contributions: []const host.Contribution) bool {
    for (contributions) |contribution| if (contribution.authority == .execution_control and std.mem.eql(u8, contribution.definition.id, "host.run_in_terminal")) return true;
    return false;
}

test "host query PTY discovery uses the registered execution catalog identity" {
    try std.testing.expect(executionToolsAvailable(&@import("../ai/host_execution.zig").contributions));
    try std.testing.expect(!executionToolsAvailable(&queries.contributions));
}

const PtyInfo = struct { ready: bool = false, state: []const u8 = "unavailable", failure: ?[]const u8 = null };
fn trustedPtyInfo(app: *Application, tab: *const SessionTab, handle: identity.SessionHandle) PtyInfo {
    const service = if (tab.terminal) |view| if (view.terminal_surface) |surface| blk: {
        if (!surface.owner.eql(handle)) return .{};
        break :blk surface.service;
    } else if (tab.runtime) |runtime| runtime.terminalService() catch return .{} else return .{} else if (tab.runtime) |runtime| runtime.terminalService() catch return .{} else return .{};
    if (service.binding.kind != .terminal or service.binding.resource_owner != .session or !service.binding.resource_owner.session.eql(handle) or !app.sessions.bindingIsLive(service.binding)) return .{};
    return serviceExecutionInfo(service, handle);
}

fn serviceExecutionAvailable(service: terminal.Service, handle: identity.SessionHandle) bool {
    return serviceExecutionInfo(service, handle).ready;
}
fn serviceExecutionInfo(service: terminal.Service, handle: identity.SessionHandle) PtyInfo {
    if (service.vtable.execution_request == null or service.vtable.execution_renew == null or service.vtable.execution_revoke == null or service.vtable.execution_output == null) return .{ .failure = "IntegrationUnavailable" };
    const snapshot = service.executionSnapshot() catch |err| return .{ .state = if (err == error.WorkerBusy) "busy" else "failed", .failure = @errorName(err) };
    if (!snapshot.owner.eql(handle)) return .{ .failure = "StaleSession" };
    if (snapshot.interactive_execution) return .{ .ready = true, .state = "ready" };
    return .{ .state = if (snapshot.failure == null) "initializing" else "failed", .failure = snapshot.failure };
}

fn associatedAsset(app: *Application, handle: identity.SessionHandle) ?identity.AssetOwner {
    // Resolve only the immutable identity on this visible session. Reading the
    // registry at that exact ID validates freshness without exposing inventory
    // or resolving credential/connection payloads.
    const mapping = app.findHandle(handle) orelse return null;
    const source: identity.AssetOwner = if (mapping.source) |value| .{ .id = value.value.host.connection_id, .revision = value.value.host.revision } else if (app.sessions.connectionEnvelope(handle)) |value| .{ .id = value.id, .revision = value.revision } else return null;
    if (@backingInt(source.id) == 0 or source.revision == 0) return null;
    const index = app.workspace.registry.indexOf(source.id) orelse return null;
    const saved = app.workspace.registry.hosts[index];
    if (saved.revision != source.revision or !std.mem.eql(u8, saved.protocolId(), "ssh")) return null;
    return source;
}

test "host discovery PTY requires live private execution facts and a complete terminal service" {
    const Session = @import("../host/session_host.zig");
    const Stub = struct {
        facts: terminal.execution.Snapshot,
        fn snapshot(raw: *anyopaque, _: Session.ServiceHandle) !terminal.execution.Snapshot {
            return (@as(*@This(), @ptrCast(@alignCast(raw)))).facts;
        }
        fn request(_: *anyopaque, _: Session.ServiceHandle, _: terminal.execution.Request) !void {
            return error.UnexpectedEffect;
        }
        fn renew(_: *anyopaque, _: Session.ServiceHandle, _: terminal.execution.Grant) !void {
            return error.UnexpectedEffect;
        }
        fn revoke(_: *anyopaque, _: Session.ServiceHandle, _: terminal.execution.Grant, _: bool) !void {
            return error.UnexpectedEffect;
        }
        fn output(_: *anyopaque, _: Session.ServiceHandle, _: identity.ExecutionId, _: std.mem.Allocator, _: u64, _: usize) !terminal.execution.Output {
            return error.UnexpectedContentRead;
        }
    };
    const handle: identity.SessionHandle = .{ .session_id = @fromBackingInt(5), .generation = 2 };
    var stub: Stub = .{ .facts = .{ .owner = handle, .state = .idle, .interactive_execution = true } };
    // Only these bounded metadata/execution fields are consulted. A discovery
    // query must never call terminal content or effect entry points.
    var vtable: terminal.Service.VTable = undefined;
    vtable.execution_snapshot = Stub.snapshot;
    vtable.execution_request = Stub.request;
    vtable.execution_renew = Stub.renew;
    vtable.execution_revoke = Stub.revoke;
    vtable.execution_output = Stub.output;
    const service: terminal.Service = .{ .binding = .{ .resource_owner = .{ .session = handle }, .kind = .terminal, .binding_id = 1, .binding_generation = 1 }, .context = &stub, .vtable = &vtable };
    try std.testing.expect(serviceExecutionAvailable(service, handle));
    // Ordinary shell readiness does not install SSH's unavailable private
    // execution integration, nor one disabled by missing recording.
    stub.facts.interactive_execution = false;
    stub.facts.state = .unavailable;
    try std.testing.expect(!serviceExecutionAvailable(service, handle));
    try std.testing.expectEqualStrings("initializing", serviceExecutionInfo(service, handle).state);
    stub.facts.failure = "RecordingDisabled";
    try std.testing.expectEqualStrings("failed", serviceExecutionInfo(service, handle).state);
    try std.testing.expectEqualStrings("RecordingDisabled", serviceExecutionInfo(service, handle).failure.?);
    stub.facts.failure = null;
    stub.facts.interactive_execution = true;
    vtable.execution_renew = null;
    try std.testing.expect(!serviceExecutionAvailable(service, handle));
    vtable.execution_renew = Stub.renew;
    stub.facts.owner.generation += 1;
    try std.testing.expect(!serviceExecutionAvailable(service, handle));
}
