//! Trusted lifecycle catalog and strict typed arguments. References carry the
//! conversation/task identity; resolving one never creates an authorization.
const std = @import("std");
const host = @import("host_tools.zig");
const identity = @import("../host/identity.zig");
pub const lifecycle = @import("../host/lifecycle_supervisor.zig");
pub const Kind = enum { create_group, open_session, rename_group, add_group_member, remove_group_member, close_session, disconnect_session, reconnect_session, set_session_retention, wait_session_ready };
pub const Request = struct {
    kind: Kind,
    request_key: []const u8 = "",
    session: ?identity.SessionHandle = null,
    group: ?identity.GroupOwner = null,
    source: ?identity.SessionHandle = null,
    saved_source: ?identity.AssetOwner = null,
    name: ?[]const u8 = null,
    connection_policy: ?lifecycle.ConnectionPolicy = null,
    retention: ?lifecycle.Retention = null,
    operation: ?identity.HostOperationId = null,
    after_revision: ?u64 = null,
    wait_ms: u32 = 1000,
    interactive_execution: bool = false,
};
const session = "\"session_ref\":{\"type\":\"string\",\"minLength\":1,\"maxLength\":128}";
const group = "\"group_ref\":{\"type\":\"string\",\"minLength\":1,\"maxLength\":128}";
const key = "\"request_key\":{\"type\":\"string\",\"minLength\":1,\"maxLength\":128}";
const name = "\"name\":{\"type\":\"string\",\"minLength\":1,\"maxLength\":120}";
const policy = "\"connection_policy\":{\"type\":\"string\",\"enum\":[\"reuse_only\",\"new_only\",\"prefer_reuse\"]}";
const retention = "\"retention\":{\"type\":\"string\",\"enum\":[\"auto_idle\",\"ask\",\"keep\"]}";
fn contribution(comptime id: []const u8, description: []const u8, comptime fields: []const u8, comptime required: []const u8) host.Contribution {
    return .{ .authority = .lifecycle, .definition = .{ .id = "host." ++ id, .effect = if (std.mem.eql(u8, id, "wait_session_ready")) .read_state else .resource_write, .description = description, .schema = "{\"type\":\"object\",\"additionalProperties\":false,\"properties\":{" ++ fields ++ "},\"required\":[" ++ required ++ "]}" } };
}
pub const contributions = [_]host.Contribution{
    contribution("create_group", "Create a real group from this conversation's exact initial_session_ref and move this same conversation to it. Requires a precise host grant/approval. Refresh context after success before opening a work session. Same request_key returns the original receipt; never retry unknown effects with another key.", "\"initial_session_ref\":{\"type\":\"string\",\"minLength\":1,\"maxLength\":128}," ++ name ++ "," ++ key, "\"initial_session_ref\",\"request_key\""),
    contribution("open_session", "Create one task-owned work session in the current group without executing a command. Use an authorized source_ref; single sessions must first create_group and refresh context. reuse_only never opens a new connection; prefer_reuse needs explicit fallback authorization. Returns opening/ready and stable refs; use wait_session_ready. Set interactive_execution=true when this new SSH terminal must support trusted PTY execution: only a validated existing SSH source with reuse_only is currently supported; a separate concrete temporary-helper approval is mandatory. Same request_key never creates twice.", group ++ ",\"source_ref\":{\"type\":\"string\",\"minLength\":1,\"maxLength\":128}," ++ policy ++ "," ++ retention ++ ",\"interactive_execution\":{\"type\":\"boolean\"}," ++ key, "\"group_ref\",\"source_ref\",\"connection_policy\",\"request_key\""),
    contribution("rename_group", "Rename this conversation's exact group after host authorization. Identity and membership remain stable. Same request_key returns the original operation receipt.", group ++ "," ++ name ++ "," ++ key, "\"group_ref\",\"name\",\"request_key\""),
    contribution("add_group_member", "Add an exact authorized session to the current group. Discovery alone does not grant membership mutation. Does not connect or send input. Same request_key reuses the original relation receipt.", group ++ "," ++ session ++ "," ++ key, "\"group_ref\",\"session_ref\",\"request_key\""),
    contribution("remove_group_member", "Remove only the exact group membership after host dependency checks. Never closes the session or converts a small group back to a single-session conversation. Active executions require explicit resolution.", group ++ "," ++ session ++ "," ++ key, "\"group_ref\",\"session_ref\",\"request_key\""),
    contribution("close_session", "Request a two-phase close of an exact authorized session after impact preflight/approval. Borrowed/user resources require explicit user close authorization. Returns closing/cleanup_pending; unknown outcomes must be inspected, never replayed against a newer generation.", session ++ "," ++ key, "\"session_ref\",\"request_key\""),
    contribution("disconnect_session", "Disconnect only an exact supported session after explicit user approval and impact preflight. Returns pending/disconnected/outcome_unknown from the original IO owner; preserves its tab, context and records, disables automatic reconnect, and revokes old execution/input grants. Active execution/transfer/forward references block it. Same request_key queries the original receipt and never redispatches; Local sessions return NotSupported.", session ++ "," ++ key, "\"session_ref\",\"request_key\""),
    contribution("reconnect_session", "Explicitly request a new connection generation for an authorized session using the specified connection policy. Old execution/session refs do not revive. Requires user connection authorization; no automatic replay after unknown outcomes.", session ++ "," ++ policy ++ "," ++ key, "\"session_ref\",\"connection_policy\",\"request_key\""),
    contribution("set_session_retention", "Set retention only for this task's owned session or a host-authorized selection. Cannot acquire borrowed resources or undo user takeover. keep revokes old automatic cleanup plans. Same request_key returns the original decision receipt.", session ++ "," ++ retention ++ "," ++ key, "\"session_ref\",\"retention\",\"request_key\""),
    contribution("wait_session_ready", "Observe only this task's owned opening operation or session. Exactly one of operation_ref/session_ref is required. Bounded wait returns the current state and timed_out, never reconnects, creates, dispatches a command, or treats timeout as completion.", session ++ ",\"operation_ref\":{\"type\":\"string\",\"minLength\":1,\"maxLength\":128},\"after_revision\":{\"type\":\"integer\",\"minimum\":1},\"wait_ms\":{\"type\":\"integer\",\"minimum\":0,\"maximum\":30000}", ""),
};
pub fn supports(tool: []const u8) bool {
    return kind(tool) != null;
}
pub fn kind(tool: []const u8) ?Kind {
    if (!std.mem.startsWith(u8, tool, "host.")) return null;
    return std.meta.stringToEnum(Kind, tool[5..]);
}
fn text(args: std.json.Value, field: []const u8) ![]const u8 {
    const value = args.object.get(field) orelse return error.InvalidArguments;
    if (value != .string or value.string.len == 0 or !std.unicode.utf8ValidateSlice(value.string) or std.mem.indexOfScalar(u8, value.string, 0) != null) return error.InvalidArguments;
    return value.string;
}
fn decimal(part: []const u8) !u64 {
    if (part.len == 0 or (part.len > 1 and part[0] == '0')) return error.StaleReference;
    for (part) |byte| if (!std.ascii.isDigit(byte)) return error.StaleReference;
    const value = std.fmt.parseInt(u64, part, 10) catch return error.StaleReference;
    return if (value > 0) value else error.StaleReference;
}
pub fn sessionHandle(context: host.Context, reference: []const u8) !identity.SessionHandle {
    if (reference.len > 128) return error.StaleReference;
    var parts = std.mem.splitScalar(u8, reference, ':');
    if (!std.mem.eql(u8, parts.next() orelse "", "s1") or !std.mem.eql(u8, parts.next() orelse "", &std.fmt.bytesToHex(context.conversation_id.bytes, .lower))) return error.StaleReference;
    const id = try decimal(parts.next() orelse "");
    const generation = try decimal(parts.next() orelse "");
    if (parts.next() != null) return error.StaleReference;
    return .{ .session_id = @fromBackingInt(id), .generation = generation };
}
pub fn groupOwner(context: host.Context, reference: []const u8) !identity.GroupOwner {
    if (reference.len > 128) return error.StaleReference;
    var parts = std.mem.splitScalar(u8, reference, ':');
    if (!std.mem.eql(u8, parts.next() orelse "", "g1") or !std.mem.eql(u8, parts.next() orelse "", &std.fmt.bytesToHex(context.conversation_id.bytes, .lower))) return error.StaleReference;
    const id = try decimal(parts.next() orelse "");
    if (parts.next() != null) return error.StaleReference;
    return .{ .id = @fromBackingInt(id) };
}
pub fn connectionRef(a: std.mem.Allocator, context: host.Context, source: identity.AssetOwner) ![]const u8 {
    if (@backingInt(source.id) == 0 or source.revision == 0) return error.StaleReference;
    return std.fmt.allocPrint(a, "c1:{s}:{d}:{d}", .{ std.fmt.bytesToHex(context.conversation_id.bytes, .lower), @backingInt(source.id), source.revision });
}
pub fn connectionOwner(context: host.Context, reference: []const u8) !identity.AssetOwner {
    if (reference.len > 128) return error.StaleReference;
    var parts = std.mem.splitScalar(u8, reference, ':');
    if (!std.mem.eql(u8, parts.next() orelse "", "c1") or !std.mem.eql(u8, parts.next() orelse "", &std.fmt.bytesToHex(context.conversation_id.bytes, .lower))) return error.StaleReference;
    const id = try decimal(parts.next() orelse "");
    const revision = try decimal(parts.next() orelse "");
    if (parts.next() != null) return error.StaleReference;
    return .{ .id = @fromBackingInt(id), .revision = revision };
}
pub fn operationRef(a: std.mem.Allocator, context: host.Context, operation: identity.HostOperationId) ![]const u8 {
    return std.fmt.allocPrint(a, "o1:{s}:{s}:{s}", .{ std.fmt.bytesToHex(context.conversation_id.bytes, .lower), std.fmt.bytesToHex(context.task_id.bytes, .lower), std.fmt.bytesToHex(operation.bytes, .lower) });
}
pub fn operationId(context: host.Context, reference: []const u8) !identity.HostOperationId {
    var parts = std.mem.splitScalar(u8, reference, ':');
    if (!std.mem.eql(u8, parts.next() orelse "", "o1") or !std.mem.eql(u8, parts.next() orelse "", &std.fmt.bytesToHex(context.conversation_id.bytes, .lower)) or !std.mem.eql(u8, parts.next() orelse "", &std.fmt.bytesToHex(context.task_id.bytes, .lower))) return error.StaleReference;
    const id = identity.HostOperationId.parse(parts.next() orelse "") catch return error.StaleReference;
    if (parts.next() != null) return error.StaleReference;
    return id;
}
pub fn parse(invocation: host.Invocation) !Request {
    try invocation.context.validate();
    if (invocation.authority != .lifecycle) return error.PermissionDenied;
    const operation = kind(invocation.tool_id) orelse return error.ToolNotAvailable;
    const args = invocation.arguments;
    if (args != .object) return error.InvalidArguments;
    var request: Request = .{ .kind = operation };
    var allowed: []const []const u8 = undefined;
    switch (operation) {
        .create_group => allowed = &.{ "initial_session_ref", "name", "request_key" },
        .open_session => allowed = &.{ "group_ref", "source_ref", "connection_policy", "retention", "interactive_execution", "request_key" },
        .rename_group => allowed = &.{ "group_ref", "name", "request_key" },
        .add_group_member, .remove_group_member => allowed = &.{ "group_ref", "session_ref", "request_key" },
        .close_session, .disconnect_session => allowed = &.{ "session_ref", "request_key" },
        .reconnect_session => allowed = &.{ "session_ref", "connection_policy", "request_key" },
        .set_session_retention => allowed = &.{ "session_ref", "retention", "request_key" },
        .wait_session_ready => allowed = &.{ "operation_ref", "session_ref", "after_revision", "wait_ms" },
    }
    for (args.object.keys()) |field| {
        for (allowed) |candidate| if (std.mem.eql(u8, field, candidate)) break else {} else return error.InvalidArguments;
    }
    if (operation != .wait_session_ready) {
        request.request_key = try text(args, "request_key");
        if (request.request_key.len > 128) return error.InvalidArguments;
        for (request.request_key) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '-' and byte != '_' and byte != '.' and byte != ':') return error.InvalidArguments;
    }
    if (operation == .create_group) {
        request.session = try sessionHandle(invocation.context, try text(args, "initial_session_ref"));
    }
    if (operation == .open_session or operation == .rename_group or operation == .add_group_member or operation == .remove_group_member) {
        request.group = try groupOwner(invocation.context, try text(args, "group_ref"));
        if (invocation.context.binding != .group or invocation.context.binding.group != @backingInt(request.group.?.id)) return error.TargetOutsideScope;
    }
    if (operation == .open_session) {
        if (args.object.get("interactive_execution")) |value| {
            if (value != .bool) return error.InvalidArguments;
            request.interactive_execution = value.bool;
        }
        const reference = try text(args, "source_ref");
        if (std.mem.startsWith(u8, reference, "s1:")) request.source = try sessionHandle(invocation.context, reference) else if (std.mem.startsWith(u8, reference, "c1:")) request.saved_source = try connectionOwner(invocation.context, reference) else return error.UnsupportedSource;
    }
    if (operation == .rename_group or args.object.get("name") != null) {
        request.name = try text(args, "name");
        if (request.name.?.len > 120 or std.mem.trim(u8, request.name.?, " \t\r\n").len == 0) return error.InvalidName;
        for (request.name.?) |byte| if (byte < 0x20 or byte == 0x7f) return error.InvalidName;
    }
    if (operation != .create_group and operation != .open_session and operation != .rename_group and operation != .wait_session_ready) request.session = try sessionHandle(invocation.context, try text(args, "session_ref"));
    if (operation == .open_session or operation == .reconnect_session) request.connection_policy = std.meta.stringToEnum(lifecycle.ConnectionPolicy, try text(args, "connection_policy")) orelse return error.InvalidArguments;
    if (operation == .set_session_retention or args.object.get("retention") != null) request.retention = std.meta.stringToEnum(lifecycle.Retention, try text(args, "retention")) orelse return error.InvalidArguments;
    if (operation == .wait_session_ready) {
        const op = args.object.get("operation_ref") != null;
        const sess = args.object.get("session_ref") != null;
        if (op == sess) return error.InvalidArguments;
        if (op) request.operation = try operationId(invocation.context, try text(args, "operation_ref"));
        if (sess) request.session = try sessionHandle(invocation.context, try text(args, "session_ref"));
        if (args.object.get("wait_ms")) |value| {
            if (value != .integer or value.integer < 0 or value.integer > 30000) return error.InvalidArguments;
            request.wait_ms = @intCast(value.integer);
        }
        if (args.object.get("after_revision")) |value| {
            if (value != .integer or value.integer < 1) return error.InvalidArguments;
            request.after_revision = @intCast(value.integer);
        }
    }
    return request;
}

test "lifecycle references bind the conversation and operation task" {
    const a = std.testing.allocator;
    const context: host.Context = .{ .conversation_id = identity.ConversationId.generate(), .task_id = identity.TaskId.generate(), .binding = .{ .session = 1 }, .binding_revision = 1, .grant_revision = 1 };
    const op = identity.HostOperationId.generate();
    const reference = try operationRef(a, context, op);
    defer a.free(reference);
    try std.testing.expect((try operationId(context, reference)).eql(op));
    var other = context;
    other.task_id = identity.TaskId.generate();
    try std.testing.expectError(error.StaleReference, operationId(other, reference));
}

test "lifecycle saved-source references fence asset revision and conversation" {
    const a = std.testing.allocator;
    const context: host.Context = .{ .conversation_id = identity.ConversationId.generate(), .task_id = identity.TaskId.generate(), .binding = .{ .group = 7 }, .binding_revision = 1, .grant_revision = 1 };
    const source: identity.AssetOwner = .{ .id = @fromBackingInt(9), .revision = 4 };
    const reference = try connectionRef(a, context, source);
    defer a.free(reference);
    try std.testing.expect(std.meta.eql(source, try connectionOwner(context, reference)));
    var other = context;
    other.conversation_id = identity.ConversationId.generate();
    try std.testing.expectError(error.StaleReference, connectionOwner(other, reference));
    const zero_revision = try std.fmt.allocPrint(a, "c1:{s}:9:0", .{std.fmt.bytesToHex(context.conversation_id.bytes, .lower)});
    defer a.free(zero_revision);
    try std.testing.expectError(error.StaleReference, connectionOwner(context, zero_revision));
}

test "lifecycle catalog validates through the host table and marks effects explicitly" {
    const context: host.Context = .{ .conversation_id = identity.ConversationId.generate(), .task_id = identity.TaskId.generate(), .binding = .{ .group = 7 }, .binding_revision = 1, .grant_revision = 1 };
    var table = try @import("plugin_tools.zig").RequestTable.initWithHost(std.testing.allocator, .{ .owner = context.binding, .members = .{} }, &.{}, &.{}, context, &contributions);
    defer table.deinit();
    try std.testing.expectEqual(@as(usize, 10), table.entries.len);
    for (contributions) |item| try std.testing.expectEqual(if (std.mem.eql(u8, item.definition.id, "host.wait_session_ready")) @import("plugin_tools.zig").Effect.read_state else .resource_write, item.definition.effect);
}
