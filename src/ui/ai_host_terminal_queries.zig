//! Controller-only content-source authorization. Discovery visibility alone
//! never installs this grant or opens a historical recording.
const std = @import("std");
const queries = @import("../ai/host_terminal_queries.zig");
const host = @import("../ai/host_tools.zig");
const identity = @import("../host/identity.zig");
const scope = @import("../ai/tool_scope.zig");
const Application = @import("application_host.zig").ApplicationHost;
const terminal = @import("../host/terminal_service.zig");

pub const CommandProvider = struct {
    context: *anyopaque,
    capture: *const fn (*anyopaque, std.mem.Allocator, identity.ConversationId, identity.SessionHandle) anyerror!queries.CommandSnapshot,
    pub fn from(comptime T: type, value: *T) CommandProvider {
        const Wrapper = struct {
            fn capture(raw: *anyopaque, allocator: std.mem.Allocator, conversation: identity.ConversationId, target: identity.SessionHandle) !queries.CommandSnapshot {
                return (@as(*T, @ptrCast(@alignCast(raw)))).commandIndex(allocator, conversation, target);
            }
        };
        return .{ .context = value, .capture = Wrapper.capture };
    }
};

pub const RecordingProvider = struct {
    context: *anyopaque,
    execute: *const fn (*anyopaque, host.Invocation, std.mem.Allocator) anyerror!host.Result,
    pub fn from(comptime T: type, value: *T) RecordingProvider {
        const Wrapper = struct {
            fn execute(raw: *anyopaque, invocation: host.Invocation, allocator: std.mem.Allocator) !host.Result {
                return (@as(*T, @ptrCast(@alignCast(raw)))).execute(invocation, allocator);
            }
        };
        return .{ .context = value, .execute = Wrapper.execute };
    }
};

pub const Options = struct {
    captured_scope: scope.Scope,
    /// Frozen when the request's real terminal catalog is prepared. An ID
    /// surviving in inventory cannot authorize a replacement generation.
    captured_handles: []const identity.SessionHandle,
    commands: ?[]const queries.Command = null,
    command_revision: u64 = 0,
    command_provider: ?CommandProvider = null,
    recording_provider: ?RecordingProvider = null,
};
pub fn execute(app: *Application, roster: ?*@import("group_model.zig").Roster, options: Options, cursor_key: [32]u8, invocation: host.Invocation, allocator: std.mem.Allocator) !host.Result {
    const request = try queries.parse(invocation.tool_id, invocation.arguments);
    try invocation.context.validate();
    if (invocation.authority != .conversation_context or !options.captured_scope.owner.eql(invocation.context.binding)) return error.ScopeChanged;
    if (request.source == .recording) {
        _ = try queries.resolveRecording(invocation.context, request.source.recording);
        const provider = options.recording_provider orelse return error.RangeUnavailable;
        return provider.execute(provider.context, invocation, allocator);
    }
    const handle = try queries.resolveSession(invocation.context, request.source.session);
    _ = try options.captured_scope.validate(&.{@backingInt(handle.session_id)});
    const captured = for (options.captured_handles) |owner| {
        if (owner.eql(handle)) break true;
    } else false;
    if (!captured) return error.StaleReference;
    const tab = for (app.workspace.tabs.items) |item| {
        if (item.content_owner == .session and item.content_owner.session.eql(handle)) break item;
    } else return error.StaleReference;
    if (tab.closing or tab.failed or tab.archived or tab.owned_pending) return error.CapabilityUnavailable;
    if (invocation.context.binding == .group) {
        const group = (roster orelse return error.ScopeChanged).findById(std.math.cast(u32, invocation.context.binding.group) orelse return error.ScopeChanged) orelse return error.ScopeChanged;
        const member = currentMember(group.members.items, tab.id);
        if (!member or app.workspace.groupClosing(group.id)) return error.TargetOutsideScope;
    }
    const manifest = app.sessions.manifestFor(handle) orelse return error.CapabilityUnavailable;
    if (!manifest.integration.ai) return error.PermissionDenied;
    const allowed = for (manifest.tools) |tool| {
        if (std.mem.eql(u8, tool.definition_id, "read_terminal")) break true;
    } else false;
    if (!allowed) return error.PermissionDenied;
    const available = app.sessions.queryService(handle, .terminal);
    if (available != .available) return error.CapabilityUnavailable;
    const service: terminal.Service = if (tab.terminal) |view| if (view.terminal_surface) |surface| blk: {
        if (!surface.owner.eql(handle)) return error.StaleReference;
        break :blk surface.service;
    } else if (tab.runtime) |runtime| try runtime.terminalService() else return error.CapabilityUnavailable else if (tab.runtime) |runtime| try runtime.terminalService() else return error.CapabilityUnavailable;
    if (!service.binding.eql(available.available) or !app.sessions.bindingIsLive(service.binding) or service.binding.resource_owner != .session or !service.binding.resource_owner.session.eql(handle)) return error.StaleReference;
    const needs_commands = std.mem.eql(u8, invocation.tool_id, "host.list_terminal_commands") or request.range_kind == .command;
    var captured_commands: ?queries.CommandSnapshot = if (needs_commands) if (options.command_provider) |provider| try provider.capture(provider.context, allocator, invocation.context.conversation_id, handle) else null else null;
    defer if (captured_commands) |*index| index.deinit(allocator);
    return queries.execute(.{ .context = invocation.context, .source = .{ .owner = handle, .service = service, .recording_ref = if (request.source == .recording) request.source.recording else null }, .observed_at = @import("../platform/realtime.zig").milliseconds(app), .cursor_key = cursor_key }, invocation, if (captured_commands) |index| index.records else options.commands, if (captured_commands) |index| index.revision else options.command_revision, allocator);
}

fn currentMember(members: []const @import("group_model.zig").Member, pane_id: u64) bool {
    for (members) |member| if (member.active and member.pane_id == pane_id) return true;
    return false;
}
test "PATCH terminal current group membership rejects inactive or removed captured targets" {
    const members = [_]@import("group_model.zig").Member{ .{ .pane_id = 7, .active = false }, .{ .pane_id = 8 } };
    try std.testing.expect(!currentMember(&members, 7));
    try std.testing.expect(!currentMember(&members, 9));
    try std.testing.expect(currentMember(&members, 8));
}
