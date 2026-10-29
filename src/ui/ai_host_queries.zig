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
const inventory = @import("../ai/inventory_grants.zig");
const inventory_context = @import("ai_inventory_context.zig");

pub const Options = struct {
    /// Policies captured when this Task was prepared, independent of defaults
    /// or composer selections made while its worker is still running.
    execution_policy: config.ExecutionPolicy,
    permission_mode: config.PermissionMode,
    host_contributions: []const host.Contribution,
    /// Re-read from the live main-thread grant controller for each query.
    inventory_grant: ?inventory.Grant = null,
};

pub fn execute(app: *Application, roster: ?*@import("group_model.zig").Roster, initial: @import("../ai/tool_scope.zig").Owner, options: Options, cursor_key: [32]u8, invocation: host.Invocation, allocator: std.mem.Allocator) !host.Result {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const now = @import("../platform/realtime.zig").milliseconds(app);
    var effective = options;
    if (queries.isInventoryList(invocation.tool_id)) {
        if (!try queries.wantsWorkspace(invocation)) effective.inventory_grant = null else if (effective.inventory_grant == null and try needsWorkspaceApproval(app, roster, invocation)) return error.InventoryGrantRequired;
    }
    if (effective.inventory_grant) |grant| if (!grant.validForInvocation(invocation, try inventory_context.capture(arena.allocator(), app.workspace, roster), now)) return error.InventoryGrantRequired;
    const snapshot = try captureSnapshot(app, roster, initial, effective, cursor_key, invocation.context, now, arena.allocator());
    return queries.execute(snapshot, invocation, allocator);
}

/// Cheap UI-thread preflight. It examines only host-owned basic metadata;
/// manifests, terminal services, source registries and content are untouched.
pub fn needsWorkspaceApproval(app: *Application, roster: ?*@import("group_model.zig").Roster, invocation: host.Invocation) !bool {
    if (!try queries.wantsWorkspace(invocation)) return false;
    const binding = invocation.context.binding;
    const bound_group = if (binding == .group) (roster orelse return error.ContextUnavailable).findById(std.math.cast(u32, binding.group) orelse return error.ContextUnavailable) orelse return error.ContextUnavailable else null;
    if (std.mem.eql(u8, invocation.tool_id, "host.list_groups")) {
        if (roster) |value| for (value.groups.items) |group| {
            if (binding != .group or group.id != binding.group) return true;
        };
        return false;
    }
    var narrowed_group: ?*const @import("group_model.zig").GroupEntry = null;
    if (invocation.arguments.object.get("group_ref")) |value| {
        if (value != .string) return error.InvalidArguments;
        const id = try queries.groupReferenceId(invocation.context, value.string);
        const group = (roster orelse return error.TargetOutsideScope).findById(std.math.cast(u32, id) orelse return error.TargetOutsideScope) orelse return error.TargetOutsideScope;
        if (binding != .group or binding.group != id) return true;
        narrowed_group = group;
    }
    const state_filter = if (invocation.arguments.object.get("state_filter")) |value| if (value == .string) value.string else return error.InvalidArguments else "all";
    if (!std.mem.eql(u8, state_filter, "all") and !std.mem.eql(u8, state_filter, "ready") and !std.mem.eql(u8, state_filter, "opening") and !std.mem.eql(u8, state_filter, "closed")) return error.InvalidArguments;
    for (app.workspace.tabs.items) |tab| {
        if (tab.content_owner != .session) continue;
        if (narrowed_group) |group| {
            const member = for (group.members.items) |item| {
                if (item.active and item.pane_id == tab.id) break true;
            } else false;
            if (!member) continue;
        }
        const in_binding = if (bound_group) |group| for (group.members.items) |item| {
            if (item.active and item.pane_id == tab.id) break true;
        } else false else @backingInt(tab.content_owner.session.session_id) == binding.session;
        if (in_binding) continue;
        const basic = basicMetadata(app, tab);
        if (std.mem.eql(u8, state_filter, "ready") and !basic.ready) continue;
        if (std.mem.eql(u8, state_filter, "opening") and !std.mem.eql(u8, basic.state, "creating")) continue;
        if (std.mem.eql(u8, state_filter, "closed") and !std.mem.eql(u8, basic.state, "closed")) continue;
        return true;
    }
    return false;
}

fn captureSnapshot(app: *Application, roster: ?*@import("group_model.zig").Roster, initial: @import("../ai/tool_scope.zig").Owner, options: Options, cursor_key: [32]u8, context: host.Context, now: i64, a: std.mem.Allocator) !queries.Snapshot {
    try context.validate();
    if (options.inventory_grant) |grant| {
        const fresh = try inventory_context.capture(a, app.workspace, roster);
        if (!grant.valid(context, fresh, now)) return error.InventoryGrantRequired;
    }
    const expanded = options.inventory_grant != null;
    var sessions: std.ArrayList(queries.Session) = .empty;
    const binding = context.binding;
    const group = if (binding == .group) (roster orelse return error.ContextUnavailable).findById(std.math.cast(u32, binding.group) orelse return error.ContextUnavailable) orelse return error.ContextUnavailable else null;
    var lifecycle_management = false;
    const execution_control = executionToolsAvailable(options.host_contributions);
    for (options.host_contributions) |contribution| {
        if (contribution.authority == .lifecycle) lifecycle_management = true;
    }
    for (app.workspace.tabs.items) |tab| {
        if (tab.content_owner != .session) continue;
        const handle = tab.content_owner.session;
        const in_binding = if (group) |value| blk: {
            for (value.members.items) |member| if (member.active and member.pane_id == tab.id) break :blk true;
            break :blk false;
        } else @backingInt(handle.session_id) == binding.session;
        if (!in_binding and !expanded) continue;
        const basic = basicMetadata(app, tab);
        // This branch deliberately precedes manifest, capability, resource,
        // service and saved-source access. Inventory never prepares content.
        if (!in_binding) {
            try sessions.append(a, inventory_context.metadataOnly(basic));
            continue;
        }
        const state = app.sessions.queryState(handle) orelse {
            try sessions.append(a, basic);
            continue;
        };
        const manifest = app.sessions.manifestFor(handle) orelse {
            try sessions.append(a, basic);
            continue;
        };
        var read_terminal = false;
        var batch_execution = false;
        for (manifest.tools) |tool| {
            if (std.mem.eql(u8, tool.definition_id, "read_terminal")) read_terminal = true;
            if (std.mem.eql(u8, tool.definition_id, "run_command")) batch_execution = true;
        }
        const ready = basic.ready;
        read_terminal = read_terminal and manifest.integration.ai and ready and app.sessions.queryService(handle, .terminal) == .available;
        batch_execution = batch_execution and manifest.integration.ai and ready and app.sessions.queryService(handle, .exec) == .available;
        const pty = if (execution_control and ready) trustedPtyInfo(app, tab, handle) else PtyInfo{};
        const resource = app.lifecycle_supervisor.resource(handle);
        const facts = if (ready) serviceMetadata(app, tab, handle) else ServiceMetadata{};
        const owned = if (resource) |entry| entry.request.context.conversation_id.eql(context.conversation_id) and entry.request.context.task_id.eql(context.task_id) and entry.snapshot.ownership == .created_task else false;
        try sessions.append(a, .{ .handle = handle, .title = basic.title, .protocol = state.protocol_id, .state = basic.state, .ready = ready, .connected = basic.connected, .closing = tab.closing, .read_terminal = read_terminal, .batch_execution = batch_execution, .trusted_pty_execution = pty.ready, .trusted_pty_state = pty.state, .trusted_pty_failure = pty.failure, .saved_source = associatedAsset(app, handle), .task_owned = owned, .ownership = if (resource) |entry| entry.snapshot.ownership else .borrowed_user, .ownership_revision = if (resource) |entry| entry.snapshot.ownership_revision else 0, .retention = if (resource) |entry| entry.snapshot.retention else null, .recording_id = facts.recording_id, .recording_generation = facts.recording_generation, .recording_unavailable_reason = facts.recording_unavailable_reason, .control_state = facts.control_state, .has_control_lease = facts.has_control_lease, .input_ready = facts.input_ready, .local_released = facts.local_released, .capability_revision = app.sessions.capabilityRevisionFor(handle) orelse 0 });
    }
    // Closed objects are a bounded projection of host receipts in this exact
    // Task/context. The workspace inventory grant never populates this path.
    for (app.lifecycle_supervisor.entries.items) |*entry| {
        if (!entry.request.context.eql(context) or entry.snapshot.state != .closed) continue;
        const handle = entry.snapshot.session orelse continue;
        const state = app.sessions.queryState(handle) orelse continue;
        if (state.lifecycle != .closed) continue;
        const metadata = if (entry.retained_metadata) |*value| value else continue;
        try appendClosed(a, &sessions, app, context, handle, metadata, entry.snapshot.ownership, entry.snapshot.ownership_revision, entry.snapshot.retention);
    }
    for (app.deferred_closes.items) |*close| {
        if (!close.context.eql(context) or close.snapshot.state != .closed) continue;
        const state = app.sessions.queryState(close.handle) orelse continue;
        if (state.lifecycle != .closed) continue;
        const resource = app.lifecycle_supervisor.resource(close.handle);
        try appendClosed(a, &sessions, app, context, close.handle, &close.retained_metadata, if (resource) |entry| entry.snapshot.ownership else .borrowed_user, if (resource) |entry| entry.snapshot.ownership_revision else 0, if (resource) |entry| entry.snapshot.retention else null);
    }
    var groups: std.ArrayList(queries.Group) = .empty;
    if (roster) |value| {
        for (value.groups.items) |entry| {
            if (!expanded and (group == null or entry.id != group.?.id)) continue;
            var members: std.ArrayList(identity.SessionHandle) = .empty;
            for (entry.members.items) |member| {
                if (!member.active) continue;
                for (app.workspace.tabs.items) |tab| {
                    if (tab.id == member.pane_id and tab.content_owner == .session) {
                        try members.append(a, tab.content_owner.session);
                        break;
                    }
                }
            }
            try groups.append(a, .{ .id = entry.id, .name = if (app.workspace.app_config.ai.redact_ip) "<redacted>" else entry.name, .membership_revision = entry.membership_revision, .members = members.items });
        }
    }
    const revision_source = try std.json.Stringify.valueAlloc(a, .{ sessions.items, groups.items, context, options.inventory_grant, options.execution_policy, options.permission_mode, lifecycle_management, execution_control, app.workspace.app_config.config_revision }, .{});
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(revision_source, &digest, .{});
    const revision = std.mem.readInt(u64, digest[0..8], .little);
    return .{ .context = context, .initial_binding = initial, .execution_policy = options.execution_policy, .permission_mode = options.permission_mode, .lifecycle_management = lifecycle_management, .observed_at = now, .source_revision = if (revision == 0) 1 else revision, .cursor_key = cursor_key, .sessions = sessions.items, .groups = groups.items, .inventory_grant = options.inventory_grant };
}

fn appendClosed(a: std.mem.Allocator, sessions: *std.ArrayList(queries.Session), app: *Application, context: host.Context, handle: identity.SessionHandle, metadata: *const @import("../host/lifecycle_supervisor.zig").SessionMetadata, ownership: @import("../host/lifecycle_supervisor.zig").Ownership, ownership_revision: u64, retention: ?config.SessionRetention) !void {
    const item: queries.Session = .{ .handle = handle, .title = if (app.workspace.app_config.ai.redact_ip) "<redacted>" else metadata.title[0..metadata.title_len], .protocol = metadata.protocol[0..metadata.protocol_len], .state = "closed", .ready = false, .current_member = false, .task_owned = ownership == .created_task, .ownership = ownership, .ownership_revision = ownership_revision, .retention = retention, .recording_id = metadata.recording_id, .recording_generation = metadata.recording_generation, .recording_unavailable_reason = metadata.recording_unavailable_reason, .local_released = true, .metadata_only = true, .retained_context = context };
    for (sessions.items) |*existing| if (existing.handle.eql(handle)) {
        existing.* = item;
        return;
    };
    try sessions.append(a, item);
}

/// Only cheap host-owned identity/state metadata. No manifest or service read.
fn basicMetadata(app: *Application, tab: *const SessionTab) queries.Session {
    const state = app.sessions.queryState(tab.content_owner.session);
    const ready = if (state) |value| !tab.closing and !tab.archived and !tab.failed and !tab.owned_pending and (value.lifecycle == .ready or value.lifecycle == .attached) else false;
    return .{ .handle = tab.content_owner.session, .title = if (app.workspace.app_config.ai.redact_ip) "<redacted>" else tab.titleSlice(), .protocol = if (state) |value| value.protocol_id else if (tab.local) "local" else if (tab.plugin_protocol_id.len > 0) tab.plugin_protocol_id else "unknown", .state = if (state) |value| @tagName(value.lifecycle) else if (tab.failed) "failed" else if (tab.closing) "closing" else if (tab.archived) "closed" else "unknown", .ready = ready, .connected = if (state) |value| !tab.failed and (value.lifecycle == .ready or value.lifecycle == .attached) else false, .closing = tab.closing, .metadata_only = true };
}

const ServiceMetadata = struct {
    recording_id: ?[32]u8 = null,
    recording_generation: u64 = 0,
    recording_unavailable_reason: ?[]const u8 = null,
    control_state: ?[]const u8 = null,
    has_control_lease: bool = false,
    input_ready: ?bool = null,
    local_released: ?bool = null,
};
fn serviceMetadata(app: *Application, tab: *const SessionTab, handle: identity.SessionHandle) ServiceMetadata {
    const service = if (tab.terminal) |view| if (view.terminal_surface) |surface| blk: {
        if (!surface.owner.eql(handle)) return .{};
        break :blk surface.service;
    } else if (tab.runtime) |runtime| runtime.terminalService() catch return .{} else return .{} else if (tab.runtime) |runtime| runtime.terminalService() catch return .{} else return .{};
    if (service.binding.kind != .terminal or service.binding.resource_owner != .session or !service.binding.resource_owner.session.eql(handle) or !app.sessions.bindingIsLive(service.binding)) return .{};
    var metadata: ServiceMetadata = .{};
    if (service.vtable.recording_identity != null) {
        const recording = service.recordingIdentity() catch return .{ .recording_unavailable_reason = "SnapshotUnavailable" };
        metadata.recording_id = recording.recording_id;
        metadata.recording_generation = recording.recording_generation;
        metadata.recording_unavailable_reason = if (recording.available) null else recording.failure orelse "RecordingUnavailable";
    }
    if (service.vtable.execution_snapshot == null) return metadata;
    const facts = service.executionSnapshot() catch return metadata;
    if (!facts.owner.eql(handle)) return metadata;
    if (service.vtable.recording_identity == null) {
        metadata.recording_id = facts.recording_id;
        metadata.recording_generation = facts.recording_generation;
    }
    metadata.control_state = @tagName(facts.state);
    metadata.has_control_lease = facts.grant != null;
    metadata.input_ready = facts.input_ready;
    metadata.local_released = facts.local_released;
    return metadata;
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

test "host discovery inventory projection includes global failed metadata without service authority" {
    const a = std.testing.allocator;
    const Workspace = @import("workspace.zig").Workspace;
    var settings: config.Config = .{ .config_revision = 81 };
    var workspace: Workspace = undefined;
    workspace.app_config = &settings;
    workspace.tabs = .empty;
    defer workspace.tabs.deinit(a);
    var bound: SessionTab = .{ .id = 11, .tab_id = @fromBackingInt(11), .content_owner = .{ .session = .{ .session_id = @fromBackingInt(4), .generation = 2 } }, .host_id = 0, .host_index = 0, .host_snapshot = null, .root = undefined, .local = true };
    bound.setTitle("current fixture");
    var other: SessionTab = .{ .id = 12, .tab_id = @fromBackingInt(12), .content_owner = .{ .session = .{ .session_id = @fromBackingInt(8), .generation = 3 } }, .host_id = 0, .host_index = 0, .host_snapshot = null, .root = undefined, .failed = true, .plugin_protocol_id = "fixture.remote" };
    other.setTitle("failed fixture");
    try workspace.tabs.append(a, &bound);
    try workspace.tabs.append(a, &other);
    var sessions = try @import("../host/session_host.zig").SessionHost.init(a, &.{});
    defer sessions.deinit();
    var app: Application = undefined;
    app.workspace = &workspace;
    app.sessions = &sessions;
    app.lifecycle_supervisor = @import("../host/lifecycle_supervisor.zig").Supervisor.init(a);
    defer app.lifecycle_supervisor.deinit();
    app.deferred_closes = .empty;
    // Every other application/service field deliberately remains absent.
    var roster = @import("group_model.zig").Roster.init(a);
    defer roster.deinit();
    _ = try roster.join("other fixture group", other.id, 0);
    _ = try roster.createOrGet("empty fixture group", 0);
    const context: host.Context = .{ .conversation_id = .{ .bytes = @splat(1) }, .task_id = .{ .bytes = @splat(2) }, .binding = .{ .session = 4 }, .binding_revision = 1, .grant_revision = 7 };
    var options: Options = .{ .execution_policy = .{ .execution_mode = .auto, .session_retention = .ask }, .permission_mode = .confirm, .host_contributions = &queries.contributions };
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const scratch = arena.allocator();
    const limited = try captureSnapshot(&app, &roster, context.binding, options, @splat(3), context, 100, scratch);
    try std.testing.expectEqual(@as(usize, 1), limited.sessions.len);
    try std.testing.expectEqual(@as(usize, 0), limited.groups.len);
    const workspace_args = try std.json.parseFromSlice(std.json.Value, a, "{\"scope\":\"workspace\"}", .{});
    defer workspace_args.deinit();
    var preflight: host.Invocation = .{ .context = context, .authority = .conversation_context, .operation_id = 1, .turn_id = 1, .call_id = "preflight", .tool_id = "host.list_sessions", .arguments = workspace_args.value, .arguments_json = "{\"scope\":\"workspace\"}", .arguments_hash = @splat(0), .canonical_arguments_hash = @splat(0) };
    try std.testing.expect(try needsWorkspaceApproval(&app, &roster, preflight));
    preflight.tool_id = "host.list_groups";
    try std.testing.expect(try needsWorkspaceApproval(&app, &roster, preflight));
    preflight.tool_id = "host.get_session";
    try std.testing.expect(!try needsWorkspaceApproval(&app, &roster, preflight));
    preflight.tool_id = "host.list_sessions";
    const default_args = try std.json.parseFromSlice(std.json.Value, a, "{}", .{});
    defer default_args.deinit();
    preflight.arguments = default_args.value;
    try std.testing.expect(!try needsWorkspaceApproval(&app, &roster, preflight));
    preflight.arguments = workspace_args.value;
    // Workspace scope with only bound targets needs no additional decision.
    const external_tab = workspace.tabs.pop().?;
    try std.testing.expect(!try needsWorkspaceApproval(&app, &roster, preflight));
    try workspace.tabs.append(a, external_tab);
    const selection = try inventory_context.capture(a, &workspace, &roster);
    var controller: inventory.Controller = .{};
    const grant = try controller.allowFromUi(try controller.capture(context, selection, 99), context, selection, 100);
    options.inventory_grant = grant;
    const snapshot = try captureSnapshot(&app, &roster, context.binding, options, @splat(3), grant.context, 100, scratch);
    try std.testing.expectEqual(@as(usize, 2), snapshot.sessions.len);
    try std.testing.expectEqual(@as(usize, 2), snapshot.groups.len);
    const extra = snapshot.sessions[1];
    try std.testing.expect(extra.handle.eql(other.content_owner.session));
    try std.testing.expectEqualStrings("failed", extra.state);
    try std.testing.expectEqualStrings("fixture.remote", extra.protocol);
    try std.testing.expect(extra.metadata_only and !extra.current_member and !extra.read_terminal and !extra.batch_execution and !extra.trusted_pty_execution);
    try std.testing.expect(extra.saved_source == null and extra.recording_id == null and !extra.has_control_lease);
    try std.testing.expectEqual(@as(usize, 1), snapshot.groups[0].members.len);
    try std.testing.expect(snapshot.groups[0].members[0].eql(other.content_owner.session));
    // Projection and the query layer independently verify the same selection.
    const parsed = try std.json.parseFromSlice(std.json.Value, a, "{}", .{});
    defer parsed.deinit();
    for ([_][]const u8{ "host.get_current_context", "host.list_sessions", "host.list_groups" }) |tool| {
        const call: host.Invocation = .{ .context = grant.context, .authority = .conversation_context, .operation_id = 1, .turn_id = 1, .call_id = "metadata-fixture", .tool_id = tool, .arguments = parsed.value, .arguments_json = "{}", .arguments_hash = @splat(0), .canonical_arguments_hash = @splat(0) };
        var result = try queries.execute(snapshot, call, a);
        defer result.deinit(a);
        try result.validate(grant.context, 1);
    }
    try std.testing.expectError(error.InventoryGrantRequired, captureSnapshot(&app, &roster, context.binding, options, @splat(3), grant.context, grant.expires_at, scratch));
    var changed = grant.context;
    changed.task_id.bytes[0] += 1;
    try std.testing.expectError(error.InventoryGrantRequired, captureSnapshot(&app, &roster, context.binding, options, @splat(3), changed, 100, scratch));
    // Configuration and grant revisions are independent authorities.
    settings.config_revision += 1;
    _ = try captureSnapshot(&app, &roster, context.binding, options, @splat(3), grant.context, 100, scratch);
    roster.groups.items[0].membership_revision += 1;
    try std.testing.expectError(error.InventoryGrantRequired, captureSnapshot(&app, &roster, context.binding, options, @splat(3), grant.context, 100, scratch));
    options.inventory_grant = null;
    const revoked = try captureSnapshot(&app, &roster, context.binding, options, @splat(3), grant.context, 100, scratch);
    try std.testing.expectEqual(@as(usize, 1), revoked.sessions.len);
    try std.testing.expectEqual(@as(usize, 0), revoked.groups.len);
}
