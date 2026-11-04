//! Controller-only metadata projection for the current binding and proven
//! closed receipts. Terminal snapshots expose metadata, never terminal content;
//! no exec, network or credential operations run here.
const std = @import("std");
const queries = @import("../ai/host_queries.zig");
const host = @import("../ai/host_tools.zig");
const identity = @import("../host/identity.zig");
const config = @import("../config/config.zig");
const terminal = @import("../host/terminal_service.zig");
const bmc_console = @import("../plugins/bmc_ikvm/console_service.zig");
const bmc_tools = @import("../plugins/bmc_ikvm/tools.zig");
const Application = @import("application_host.zig").ApplicationHost;
const SessionTab = @import("workspace.zig").SessionTab;
const inventory = @import("../ai/inventory_grants.zig");

pub const Options = struct {
    /// Policies captured when this Task was prepared, independent of defaults
    /// or composer selections made while its worker is still running.
    execution_policy: config.ExecutionPolicy,
    permission_mode: config.PermissionMode,
    host_contributions: []const host.Contribution,
    /// Legacy compatibility only; captureSnapshot ignores inventory grants.
    inventory_grant: ?inventory.Grant = null,
};

/// Bounded, non-secret facts captured with the same authority as discovery.
/// This is a planning hint; every later read/action still revalidates live state.
pub fn requestSummary(app: *Application, roster: ?*@import("group_model.zig").Roster, options: Options, cursor_key: [32]u8, context: host.Context, allocator: std.mem.Allocator) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const snapshot = try captureSnapshot(app, roster, context.binding, options, cursor_key, context, @import("../platform/realtime.zig").milliseconds(app), a);
    const Item = struct { session_ref: []const u8, session_id: u64, generation: u64, protocol: []const u8, ready: bool, connected: bool, read_terminal: bool, batch_execution: bool, interactive_execution: bool, interactive_state: []const u8, failure: ?[]const u8, completion_source: @import("../host/terminal_execution.zig").CompletionSource, shell_id: ?[]const u8, shell_revision: u64, prompt_ready: ?bool };
    var items: std.ArrayList(Item) = .empty;
    for (snapshot.sessions) |session| {
        if (items.items.len == 8) break;
        if (session.metadata_only) continue;
        try items.append(a, .{ .session_ref = try queries.sessionRef(a, context, session.handle), .session_id = @backingInt(session.handle.session_id), .generation = session.handle.generation, .protocol = session.protocol, .ready = session.ready, .connected = session.connected, .read_terminal = session.read_terminal, .batch_execution = session.batch_execution, .interactive_execution = session.trusted_pty_execution, .interactive_state = session.trusted_pty_state, .failure = session.trusted_pty_failure, .completion_source = session.completion_source, .shell_id = if (session.shell.id) |id| try a.dupe(u8, &id) else null, .shell_revision = session.shell.revision, .prompt_ready = session.shell.prompt_ready });
    }
    return std.json.Stringify.valueAlloc(allocator, .{ .binding = context.binding, .binding_revision = context.binding_revision, .observed_at = snapshot.observed_at, .execution_mode = options.execution_policy.execution_mode, .targets = items.items, .truncated = snapshot.sessions.len > items.items.len, .meaning = "Captured planning metadata only. Use exact advertised references directly when the target is unambiguous; discover only missing facts. Live gates remain authoritative." }, .{ .emit_null_optional_fields = false });
}

pub fn execute(app: *Application, roster: ?*@import("group_model.zig").Roster, initial: @import("../ai/tool_scope.zig").Owner, options: Options, cursor_key: [32]u8, invocation: host.Invocation, allocator: std.mem.Allocator) !host.Result {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    if (try queries.wantsWorkspace(invocation)) return error.TargetNotAuthorized;
    const now = @import("../platform/realtime.zig").milliseconds(app);
    const snapshot = try captureSnapshot(app, roster, initial, options, cursor_key, invocation.context, now, arena.allocator());
    return queries.execute(snapshot, invocation, allocator);
}

/// Kept for callers from older integrations: workspace expansion is no
/// longer available, regardless of whether any external objects exist.
pub fn needsWorkspaceApproval(_: *Application, _: ?*@import("group_model.zig").Roster, invocation: host.Invocation) !bool {
    if (try queries.wantsWorkspace(invocation)) return error.TargetNotAuthorized;
    return false;
}

fn captureSnapshot(app: *Application, roster: ?*@import("group_model.zig").Roster, initial: @import("../ai/tool_scope.zig").Owner, options: Options, cursor_key: [32]u8, context: host.Context, now: i64, a: std.mem.Allocator) !queries.Snapshot {
    try context.validate();
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
        if (!in_binding) continue;
        const basic = basicMetadata(app, tab, a);
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
        try sessions.append(a, .{ .handle = handle, .title = basic.title, .protocol = state.protocol_id, .state = basic.state, .ready = ready, .connected = basic.connected, .connection_state = basic.connection_state, .closing = tab.closing, .read_terminal = read_terminal, .batch_execution = batch_execution, .trusted_pty_execution = pty.ready, .trusted_pty_state = pty.state, .trusted_pty_failure = pty.failure, .completion_source = pty.completion_source, .saved_source = associatedAsset(app, handle), .task_owned = owned, .ownership = if (resource) |entry| entry.snapshot.ownership else .borrowed_user, .ownership_revision = if (resource) |entry| entry.snapshot.ownership_revision else 0, .retention = if (resource) |entry| entry.snapshot.retention else null, .recording_id = facts.recording_id, .recording_generation = facts.recording_generation, .recording_unavailable_reason = facts.recording_unavailable_reason, .control_state = facts.control_state, .has_control_lease = facts.has_control_lease, .shell = facts.shell, .shell_switch = facts.shell_switch, .input_epoch = facts.input_epoch, .output_sequence = facts.output_sequence, .input_ready = facts.input_ready, .local_released = facts.local_released, .capability_revision = app.sessions.capabilityRevisionFor(handle) orelse 0 });
    }
    // Completed host close receipts retain this conversation/binding's exact
    // historical metadata across Tasks, regardless of task-owned status.
    // A removed live member never enters this directory.
    for (app.deferred_closes.items) |*close| {
        if (!queries.sameHistoricalBinding(close.context, context) or close.snapshot.state != .closed) continue;
        const state = app.sessions.queryState(close.handle) orelse continue;
        if (state.lifecycle != .closed) continue;
        const resource = app.lifecycle_supervisor.resource(close.handle);
        try appendClosed(a, &sessions, app, context, close.handle, &close.retained_metadata, if (resource) |entry| entry.snapshot.ownership else .borrowed_user, if (resource) |entry| entry.snapshot.ownership_revision else 0, if (resource) |entry| entry.snapshot.retention else null, if (resource) |entry| entry.request.context.task_id.eql(context.task_id) else false);
    }
    var groups: std.ArrayList(queries.Group) = .empty;
    if (roster) |value| {
        for (value.groups.items) |entry| {
            if (group == null or entry.id != group.?.id) continue;
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
    const revision_source = try std.json.Stringify.valueAlloc(a, .{ sessions.items, groups.items, context, options.execution_policy, options.permission_mode, lifecycle_management, execution_control, app.workspace.app_config.config_revision }, .{});
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(revision_source, &digest, .{});
    const revision = std.mem.readInt(u64, digest[0..8], .little);
    return .{ .context = context, .initial_binding = initial, .execution_policy = options.execution_policy, .permission_mode = options.permission_mode, .lifecycle_management = lifecycle_management, .observed_at = now, .source_revision = if (revision == 0) 1 else revision, .cursor_key = cursor_key, .sessions = sessions.items, .groups = groups.items, .inventory_grant = null };
}

fn appendClosed(a: std.mem.Allocator, sessions: *std.ArrayList(queries.Session), app: *Application, context: host.Context, handle: identity.SessionHandle, metadata: *const @import("../host/lifecycle_supervisor.zig").SessionMetadata, ownership: @import("../host/lifecycle_supervisor.zig").Ownership, ownership_revision: u64, retention: ?config.SessionRetention, owned_by_task: bool) !void {
    const item: queries.Session = .{ .handle = handle, .title = if (app.workspace.app_config.ai.redact_ip) "<redacted>" else metadata.title[0..metadata.title_len], .protocol = metadata.protocol[0..metadata.protocol_len], .state = "closed", .ready = false, .connection_state = if (std.mem.eql(u8, metadata.protocol[0..metadata.protocol_len], "bmc_ikvm")) "closed" else null, .current_member = false, .task_owned = owned_by_task and ownership == .created_task, .ownership = ownership, .ownership_revision = ownership_revision, .retention = retention, .recording_id = metadata.recording_id, .recording_generation = metadata.recording_generation, .recording_unavailable_reason = metadata.recording_unavailable_reason, .local_released = true, .metadata_only = true, .retained_context = context };
    for (sessions.items) |*existing| if (existing.handle.eql(handle)) {
        existing.* = item;
        return;
    };
    try sessions.append(a, item);
}

/// Host attachment metadata plus the BMC's read-only typed video snapshot.
fn basicMetadata(app: *Application, tab: *const SessionTab, a: std.mem.Allocator) queries.Session {
    const state = app.sessions.queryState(tab.content_owner.session);
    const ready = if (state) |value| !tab.closing and !tab.archived and !tab.failed and !tab.owned_pending and (value.lifecycle == .ready or value.lifecycle == .attached) else false;
    var result: queries.Session = .{ .handle = tab.content_owner.session, .title = if (app.workspace.app_config.ai.redact_ip) "<redacted>" else tab.titleSlice(), .protocol = if (state) |value| value.protocol_id else if (tab.local) "local" else if (tab.plugin_protocol_id.len > 0) tab.plugin_protocol_id else "unknown", .state = if (state) |value| @tagName(value.lifecycle) else if (tab.failed) "failed" else if (tab.closing) "closing" else if (tab.archived) "closed" else "unknown", .ready = ready, .connected = if (state) |value| !tab.failed and (value.lifecycle == .ready or value.lifecycle == .attached) else false, .closing = tab.closing, .metadata_only = true };
    if (std.mem.eql(u8, result.protocol, "bmc_ikvm")) {
        const connection = bmcConnectionMetadata(app.sessions, result.handle, a);
        result.connection_state = if (tab.failed) "failed" else if (tab.closing or tab.archived) "closed" else if (state) |value| switch (value.lifecycle) {
            .failed => "failed",
            .closing, .closed, .ended, .cleanup_unknown => "closed",
            else => connection.state,
        } else connection.state;
        result.ready = ready and connection.ready;
        result.connected = ready and connection.connected;
    }
    return result;
}

fn bmcConnectionMetadata(sessions: *@import("../host/session_host.zig").SessionHost, owner: identity.SessionHandle, a: std.mem.Allocator) bmc_tools.ConnectionMetadata {
    const service = switch (sessions.queryTypedService(owner, bmc_console.Interface, bmc_console.key)) {
        .available => |value| value,
        else => return .{},
    };
    var snapshot = service.vtable.snapshot(service.context, service.binding, a) catch return .{};
    defer snapshot.deinit();
    if (!snapshot.value.owner.eql(owner)) return .{};
    return bmc_tools.connectionMetadata(snapshot.value);
}

test "BMC host metadata keeps attachment separate and fails closed on missing denied or stale console snapshots" {
    const a = std.testing.allocator;
    const Session = @import("../host/session_host.zig");
    const typed = @import("../host/plugin_services.zig");
    const Stub = struct {
        value: bmc_console.Snapshot = undefined,
        unavailable: bool = false,
        fn validate(_: []const u8) !void {}
        fn create(_: *anyopaque, _: Session.CreateRequest) !void {}
        fn cancel(_: *anyopaque, _: Session.OperationKey) Session.CloseReceipt {
            return .released;
        }
        fn close(_: *anyopaque, _: identity.SessionHandle, _: Session.OperationKey) !Session.CloseReceipt {
            return .released;
        }
        fn stale(_: *anyopaque, _: identity.SessionHandle, _: Session.OperationKey) void {}
        fn snapshot(raw: *anyopaque, _: typed.Binding, allocator: std.mem.Allocator) !bmc_console.OwnedSnapshot {
            const self: *@This() = @ptrCast(@alignCast(raw));
            if (self.unavailable) return error.SnapshotUnavailable;
            return bmc_console.OwnedSnapshot.init(allocator, self.value);
        }
    };
    var stub: Stub = .{};
    const factory: Session.Adapter.VTable = .{ .create = Stub.create, .cancel = Stub.cancel, .close = Stub.close, .release_stale = Stub.stale };
    var sessions = try Session.SessionHost.initPlugins(a, &.{.{ .id = "bmc_ikvm", .display_name = "BMC fixture", .workspace_kind = "metadata.fixture", .content_renderer = "metadata.fixture", .quick_create = .{ .validate_payload = Stub.validate }, .session_factory = .{ .context = &stub, .vtable = &factory }, .services = &.{bmc_console.definition}, .required_services = &.{bmc_console.definition} }}, &.{.{ .kind = "metadata.fixture", .shared_renderer = true }});
    defer sessions.deinit();
    const target: Session.AttachmentTarget = .{ .window_id = @fromBackingInt(1), .workspace_id = @fromBackingInt(1) };
    const accepted = try sessions.openQuick("bmc_ikvm", "{}", .{ .request_key = 1, .target = target });
    stub.value = .{ .owner = accepted.handle, .operation = accepted.operation, .route = .connecting, .video = .authenticating, .progress = .{ .stage = .public_script }, .input = .{ .input_epoch = 1, .control_generation = 1, .transport_generation = 1, .connected = false, .controlled = false, .focused = false, .capture_paused = true, .queued = 0, .remote_unconfirmed = false } };
    // No non-snapshot entry point may be used by host metadata discovery.
    var table: bmc_console.Interface = undefined;
    table.snapshot = Stub.snapshot;
    const binding = typed.Binding.init(bmc_console.Interface, bmc_console.key, &stub, &table, accepted.handle, 1);
    _ = try sessions.readyPlugin(accepted.handle, accepted.operation, &.{binding});
    _ = try sessions.attached(accepted.handle, .{ .target = target, .tab_id = @fromBackingInt(1) });
    var settings: config.Config = .{};
    var workspace: @import("workspace.zig").Workspace = undefined;
    workspace.app_config = &settings;
    var tab: SessionTab = .{ .id = 1, .tab_id = @fromBackingInt(1), .content_owner = .{ .session = accepted.handle }, .host_id = 0, .host_index = 0, .host_snapshot = null, .root = undefined, .plugin_protocol_id = "bmc_ikvm" };
    tab.setTitle("fixture");
    var app: Application = undefined;
    app.workspace = &workspace;
    app.sessions = &sessions;
    var result = basicMetadata(&app, &tab, a);
    try std.testing.expectEqualStrings("attached", result.state);
    try std.testing.expectEqualStrings("public_script", result.connection_state.?);
    try std.testing.expect(!result.ready and !result.connected);
    stub.value.route = .connected;
    stub.value.video = .streaming;
    stub.value.progress.stage = .streaming;
    stub.value.rfb_ready = true;
    stub.value.input.connected = true;
    stub.value.input.geometry_generation = 2;
    stub.value.width = 1;
    stub.value.height = 1;
    stub.value.stride = 4;
    stub.value.frame_sequence = 1;
    stub.value.frame_generation = 2;
    result = basicMetadata(&app, &tab, a);
    try std.testing.expectEqualStrings("attached", result.state);
    try std.testing.expectEqualStrings("streaming", result.connection_state.?);
    try std.testing.expect(result.ready and result.connected);
    stub.value.failure_code = "VideoClosed";
    result = basicMetadata(&app, &tab, a);
    try std.testing.expectEqualStrings("failed", result.connection_state.?);
    try std.testing.expect(!result.ready and !result.connected);
    stub.value.failure_code = null;
    stub.unavailable = true;
    result = basicMetadata(&app, &tab, a);
    try std.testing.expectEqualStrings("unavailable", result.connection_state.?);
    try std.testing.expect(!result.ready and !result.connected);
    stub.unavailable = false;
    stub.value.owner = try accepted.handle.nextGeneration();
    result = basicMetadata(&app, &tab, a);
    try std.testing.expectEqualStrings("unavailable", result.connection_state.?);
    try std.testing.expect(!result.ready and !result.connected);
    stub.value.owner = accepted.handle;
    try sessions.authorizeService(accepted.handle, bmc_console.key, false);
    result = basicMetadata(&app, &tab, a);
    try std.testing.expectEqualStrings("unavailable", result.connection_state.?);
    try std.testing.expect(!result.ready and !result.connected);
    try sessions.authorizeService(accepted.handle, bmc_console.key, true);
    try std.testing.expect(try sessions.revokeTypedService(accepted.handle, accepted.operation, bmc_console.key));
    result = basicMetadata(&app, &tab, a);
    try std.testing.expectEqualStrings("unavailable", result.connection_state.?);
    try std.testing.expect(!result.ready and !result.connected);
    _ = try sessions.shutdownOwner(accepted.handle);
    result = basicMetadata(&app, &tab, a);
    try std.testing.expectEqualStrings("ended", result.state);
    try std.testing.expectEqualStrings("closed", result.connection_state.?);
    try std.testing.expect(!result.ready and !result.connected);
}

const ServiceMetadata = struct {
    recording_id: ?[32]u8 = null,
    recording_generation: u64 = 0,
    recording_unavailable_reason: ?[]const u8 = null,
    control_state: ?[]const u8 = null,
    has_control_lease: bool = false,
    shell: @import("../host/terminal_execution.zig").ShellContext = .{},
    shell_switch: @import("../vt/shell_switch.zig").Notice = .{},
    input_epoch: ?u64 = null,
    output_sequence: ?u64 = null,
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
    metadata.shell = facts.shell;
    metadata.shell_switch = facts.shell_switch;
    metadata.input_epoch = facts.input_epoch;
    if (service.status()) |status| metadata.output_sequence = status.output_sequence else |_| {}
    metadata.input_ready = facts.input_ready and (facts.shell.prompt_ready orelse true);
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

pub const PtyInfo = struct { ready: bool = false, state: []const u8 = "unavailable", failure: ?[]const u8 = null, completion_source: terminal.execution.CompletionSource = .unknown };
pub fn trustedPtyInfo(app: *Application, tab: *const SessionTab, handle: identity.SessionHandle) PtyInfo {
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
    if (snapshot.interactive_execution) return .{ .ready = true, .state = "ready", .completion_source = snapshot.completion_source };
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

test "host discovery PTY requires live execution facts and a complete terminal service" {
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
    stub.facts.completion_source = .shell_reported;
    try std.testing.expectEqual(terminal.execution.CompletionSource.shell_reported, serviceExecutionInfo(service, handle).completion_source);
    // A connected shell alone does not establish command events or restore
    // execution integration disabled by missing recording.
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

test "current-tab projection rejects workspace probes before application metadata access" {
    const a = std.testing.allocator;
    const parsed = try std.json.parseFromSlice(std.json.Value, a, "{\"scope\":\"workspace\"}", .{});
    defer parsed.deinit();
    const context: host.Context = .{ .conversation_id = .{ .bytes = @splat(1) }, .task_id = .{ .bytes = @splat(2) }, .binding = .{ .session = 4 }, .binding_revision = 1, .grant_revision = 7 };
    var unavailable_app: Application = undefined;
    for ([_][]const u8{ "host.list_sessions", "host.list_groups" }) |tool| {
        const invocation: host.Invocation = .{ .context = context, .authority = .conversation_context, .operation_id = 1, .turn_id = 1, .call_id = "scope-preflight", .tool_id = tool, .arguments = parsed.value, .arguments_json = "{\"scope\":\"workspace\"}", .arguments_hash = @splat(0), .canonical_arguments_hash = @splat(0) };
        try std.testing.expectError(error.TargetNotAuthorized, needsWorkspaceApproval(&unavailable_app, null, invocation));
    }
}

test "current-tab projection ignores old inventory grants and external changes" {
    const a = std.testing.allocator;
    const Workspace = @import("workspace.zig").Workspace;
    var settings: config.Config = .{ .config_revision = 81 };
    var workspace: Workspace = undefined;
    workspace.app_config = &settings;
    workspace.tabs = .empty;
    defer workspace.tabs.deinit(a);
    var bound: SessionTab = .{ .id = 11, .tab_id = @fromBackingInt(11), .content_owner = .{ .session = .{ .session_id = @fromBackingInt(4), .generation = 2 } }, .host_id = 0, .host_index = 0, .host_snapshot = null, .root = undefined, .local = true };
    bound.setTitle("current fixture");
    var other: SessionTab = .{ .id = 12, .tab_id = @fromBackingInt(12), .content_owner = .{ .session = .{ .session_id = @fromBackingInt(8), .generation = 3 } }, .host_id = 0, .host_index = 0, .host_snapshot = null, .root = undefined, .failed = true, .plugin_protocol_id = "external-protocol" };
    other.setTitle("external-title");
    try workspace.tabs.append(a, &bound);
    try workspace.tabs.append(a, &other);
    var sessions = try @import("../host/session_host.zig").SessionHost.init(a, &.{});
    defer sessions.deinit();
    var app: Application = undefined;
    app.workspace = &workspace;
    app.sessions = &sessions;
    app.deferred_closes = .empty;
    var roster = @import("group_model.zig").Roster.init(a);
    defer roster.deinit();
    _ = try roster.join("external-group", other.id, 0);
    const context: host.Context = .{ .conversation_id = .{ .bytes = @splat(1) }, .task_id = .{ .bytes = @splat(2) }, .binding = .{ .session = 4 }, .binding_revision = 1, .grant_revision = 7 };
    const selection = try inventory.captureSelection(a, &.{ bound.content_owner.session, other.content_owner.session }, &.{});
    var old: inventory.Controller = .{};
    const grant = try old.allowFromUi(try old.capture(context, selection, 99), context, selection, 100);
    const options: Options = .{ .execution_policy = .{ .execution_mode = .auto, .session_retention = .ask }, .permission_mode = .confirm, .host_contributions = &queries.contributions, .inventory_grant = grant };
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const first = try captureSnapshot(&app, &roster, context.binding, options, @splat(3), context, 100, arena.allocator());
    try std.testing.expectEqual(@as(usize, 1), first.sessions.len);
    try std.testing.expectEqual(@as(usize, 0), first.groups.len);
    try std.testing.expect(first.inventory_grant == null);
    other.setTitle("changed external title");
    roster.groups.items[0].membership_revision += 1;
    const second = try captureSnapshot(&app, &roster, context.binding, options, @splat(3), context, 100, arena.allocator());
    try std.testing.expectEqual(first.source_revision, second.source_revision);
}
