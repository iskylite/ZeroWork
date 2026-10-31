//! Saved connection configuration is a separate authority domain from live
//! sessions. This module accepts only Registry values, never a session roster
//! or transport, and projects an explicit non-sensitive field allowlist.
const std = @import("std");
const host = @import("host_tools.zig");
const hosts = @import("../config/hosts.zig");
const store = @import("../config/store.zig");
const references = @import("host_lifecycle.zig");
const approval = @import("host_approval.zig");
const identity = hosts.identity;

pub const Kind = enum { list_hosts, get_host, create_host };
pub const Request = struct {
    kind: Kind,
    offset: usize = 0,
    limit: usize = 20,
    source: ?identity.AssetOwner = null,
    value: ?hosts.HostConfig = null,
    request_key: []const u8 = "",
};
pub const contributions = [_]host.Contribution{
    .{ .authority = .conversation_context, .definition = .{
        .id = "host.list_hosts",
        .description = "List saved host configurations only: name, protocol, host, port, user and revision-bound source_ref. Contains no credentials, private key data, credential references or information about existing sessions/groups. A saved source permits a new work session in the current group, never access to an already-open session. Follow next_offset to read more saved hosts.",
        .schema = "{\"type\":\"object\",\"additionalProperties\":false,\"properties\":{\"offset\":{\"type\":\"integer\",\"minimum\":0},\"limit\":{\"type\":\"integer\",\"minimum\":1,\"maximum\":50}}}",
    } },
    .{ .authority = .conversation_context, .definition = .{
        .id = "host.get_host",
        .description = "Read the static non-sensitive configuration of an exact saved source_ref. Validates conversation and saved asset revision; does not inspect, reuse, connect to or disclose any live session.",
        .schema = "{\"type\":\"object\",\"additionalProperties\":false,\"properties\":{\"source_ref\":{\"type\":\"string\",\"minLength\":1,\"maxLength\":128}},\"required\":[\"source_ref\"]}",
    } },
    .{ .authority = .lifecycle, .definition = .{
        .id = "host.create_host",
        .effect = .resource_write,
        .approval_policy = .always_confirm,
        .description = "After an exact host confirmation, save a new SSH host in the saved host list and return its source_ref and stable operation_ref. The required request_key is scoped to this conversation/task/tool: the same key and canonical arguments return the original operation and saved asset, changed arguments return IdempotencyConflict. Saving does not connect or execute commands. Then use open_session with new_only in the current group; a single-session conversation must first create_group. Supply only static configuration. Passwords, private key contents, passphrases and credential references are forbidden; authentication secrets must be entered in the host's secure connection UI. Existing hosts cannot be edited, deleted or overwritten. After an unknown outcome inspect the original operation and saved catalog; never replay the save or use a new key/name to recover the reply.",
        .schema = "{\"type\":\"object\",\"additionalProperties\":false,\"properties\":{\"request_key\":{\"type\":\"string\",\"minLength\":1,\"maxLength\":128},\"name\":{\"type\":\"string\",\"minLength\":1,\"maxLength\":120},\"protocol\":{\"type\":\"string\",\"enum\":[\"ssh\"]},\"host\":{\"type\":\"string\",\"minLength\":1,\"maxLength\":255},\"port\":{\"type\":\"integer\",\"minimum\":1,\"maximum\":65535},\"user\":{\"type\":\"string\",\"minLength\":1,\"maxLength\":128},\"auth_mode\":{\"type\":\"string\",\"enum\":[\"agent\",\"password\",\"private_key\"]},\"identity_file\":{\"type\":\"string\",\"minLength\":1,\"maxLength\":4096}},\"required\":[\"name\",\"host\",\"user\",\"request_key\"]}",
    } },
};

pub fn kind(tool: []const u8) ?Kind {
    if (!std.mem.startsWith(u8, tool, "host.")) return null;
    return std.meta.stringToEnum(Kind, tool[5..]);
}
pub fn supports(tool: []const u8) bool {
    return kind(tool) != null;
}
pub fn isMutation(tool: []const u8) bool {
    return kind(tool) == .create_host;
}
fn text(args: std.json.Value, field: []const u8, max: usize) ![]const u8 {
    const value = args.object.get(field) orelse return error.InvalidArguments;
    if (value != .string or value.string.len == 0 or value.string.len > max or !std.unicode.utf8ValidateSlice(value.string)) return error.InvalidArguments;
    for (value.string) |byte| if (byte < 0x20 or byte == 0x7f) return error.InvalidArguments;
    if (std.mem.trim(u8, value.string, " ").len != value.string.len) return error.InvalidArguments;
    return value.string;
}
/// Returned strings borrow the invocation. Unknown fields are rejected before
/// confirmation; there is no secret-bearing draft or hidden credential channel.
pub fn parse(invocation: host.Invocation) !Request {
    try invocation.context.validate();
    const operation = kind(invocation.tool_id) orelse return error.ToolNotAvailable;
    if (invocation.authority != (if (operation == .create_host) @import("provider.zig").ToolAuthority.lifecycle else .conversation_context)) return error.PermissionDenied;
    const args = invocation.arguments;
    if (args != .object) return error.InvalidArguments;
    const allowed: []const []const u8 = switch (operation) {
        .list_hosts => &.{ "offset", "limit" },
        .get_host => &.{"source_ref"},
        .create_host => &.{ "name", "protocol", "host", "port", "user", "auth_mode", "identity_file", "request_key" },
    };
    for (args.object.keys()) |field| {
        for (allowed) |candidate| if (std.mem.eql(u8, candidate, field)) break else {} else return error.InvalidArguments;
    }
    var request: Request = .{ .kind = operation };
    switch (operation) {
        .list_hosts => {
            if (args.object.get("offset")) |value| {
                if (value != .integer or value.integer < 0) return error.InvalidArguments;
                request.offset = std.math.cast(usize, value.integer) orelse return error.InvalidArguments;
            }
            if (args.object.get("limit")) |value| {
                if (value != .integer or value.integer < 1 or value.integer > 50) return error.InvalidArguments;
                request.limit = @intCast(value.integer);
            }
        },
        .get_host => request.source = try references.connectionOwner(invocation.context, try text(args, "source_ref", 128)),
        .create_host => {
            request.request_key = try text(args, "request_key", 128);
            for (request.request_key) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '-' and byte != '_' and byte != '.' and byte != ':') return error.InvalidArguments;
            var value: hosts.HostConfig = .{ .name = try text(args, "name", 120), .host = try text(args, "host", 255), .user = try text(args, "user", 128) };
            for (value.host) |byte| if (std.ascii.isWhitespace(byte)) return error.InvalidArguments;
            for (value.user) |byte| if (std.ascii.isWhitespace(byte)) return error.InvalidArguments;
            if (args.object.get("protocol") != null) if (!std.mem.eql(u8, try text(args, "protocol", 16), "ssh")) return error.UnsupportedSource;
            if (args.object.get("port")) |port| {
                if (port != .integer or port.integer < 1 or port.integer > 65535) return error.InvalidArguments;
                value.port = @intCast(port.integer);
            }
            if (args.object.get("auth_mode") != null) value.auth_mode = std.meta.stringToEnum(hosts.AuthMode, try text(args, "auth_mode", 32)) orelse return error.InvalidArguments;
            if (args.object.get("identity_file") != null) {
                value.identity_file = try text(args, "identity_file", 4096);
                if (!std.fs.path.isAbsolute(value.identity_file.?) and !std.mem.startsWith(u8, value.identity_file.?, "~/")) return error.InvalidArguments;
            }
            if ((value.auth_mode == .private_key) != (value.identity_file != null)) return error.InvalidArguments;
            try value.validate();
            request.value = value;
        },
    }
    return request;
}

/// Owns the exact validated confirmation display. It contains only permitted
/// static fields and can be prepared on a worker without touching application UI.
pub const Prepared = struct {
    detail: []const u8,
    pub fn subject(self: Prepared) approval.Subject {
        return .{ .kind = .lifecycle, .target = "host.create_host", .detail = self.detail, .impact = "将此 SSH 主机保存到主机列表；密码和私钥口令由宿主安全界面输入。保存后可在当前绑定组中新建工作会话。" };
    }
    pub fn deinit(self: *Prepared, allocator: std.mem.Allocator) void {
        allocator.free(self.detail);
        self.* = undefined;
    }
};
pub fn prepare(invocation: host.Invocation, allocator: std.mem.Allocator) !Prepared {
    const request = try parse(invocation);
    if (request.kind != .create_host) return error.ToolNotAvailable;
    const value = request.value.?;
    return .{ .detail = try std.json.Stringify.valueAlloc(allocator, .{ .name = value.name, .protocol = "ssh", .host = value.host, .port = value.port, .user = value.user, .auth_mode = value.auth_mode, .identity_file = value.identity_file }, .{}) };
}

const HostView = struct { source_ref: []const u8, name: []const u8, protocol: []const u8, host: []const u8, port: u16, user: []const u8 };
fn bounded(value: []const u8, max: usize) []const u8 {
    var len = @min(value.len, max);
    while (len > 0 and !std.unicode.utf8ValidateSlice(value[0..len])) len -= 1;
    return value[0..len];
}
fn view(allocator: std.mem.Allocator, context: host.Context, value: hosts.HostConfig) !HostView {
    return .{ .source_ref = try references.connectionRef(allocator, context, value.owner()), .name = bounded(value.name, 120), .protocol = bounded(value.protocolId(), 64), .host = bounded(value.host, 255), .port = value.port, .user = bounded(value.user, 128) };
}
fn result(allocator: std.mem.Allocator, invocation: host.Invocation, json: []const u8, changed: bool) !host.Result {
    errdefer allocator.free(json);
    if (json.len > 64 * 1024) return error.ToolResultTooLarge;
    const blocks = try allocator.alloc(host.Block, 1);
    blocks[0] = .{ .structured = json };
    return .{ .status = .succeeded, .blocks = blocks, .receipt = .{ .conversation_id = invocation.context.conversation_id, .task_id = invocation.context.task_id, .operation_id = invocation.operation_id, .binding_revision = invocation.context.binding_revision, .side_effect_started = changed } };
}

pub fn executeRead(registry: *const hosts.Registry, invocation: host.Invocation, allocator: std.mem.Allocator) !host.Result {
    const request = try parse(invocation);
    if (request.kind == .create_host) return error.PermissionDenied;
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    switch (request.kind) {
        .get_host => {
            const value = registry.get(request.source.?) catch return error.StaleReference;
            return result(allocator, invocation, try std.json.Stringify.valueAlloc(allocator, try view(a, invocation.context, value), .{}), false);
        },
        .list_hosts => {
            const start = @min(registry.hosts.len, request.offset);
            var rows: std.ArrayList(HostView) = .empty;
            var encoded_bytes: usize = 0;
            var next = start;
            while (next < registry.hosts.len and rows.items.len < request.limit) : (next += 1) {
                const row = try view(a, invocation.context, registry.hosts[next]);
                const encoded = try std.json.Stringify.valueAlloc(a, row, .{});
                if (encoded_bytes + encoded.len > 48 * 1024) break;
                encoded_bytes += encoded.len;
                try rows.append(a, row);
            }
            return result(allocator, invocation, try std.json.Stringify.valueAlloc(allocator, .{ .hosts = rows.items, .registry_revision = registry.revision, .next_offset = if (next < registry.hosts.len) @as(?usize, next) else null }, .{}), false);
        },
        .create_host => unreachable,
    }
}

/// Main-thread mutation boundary, called only after the owner independently
/// validates current context and the exact Broker subject/permit. The sequence
/// is internal metadata, never a provider argument or a replacement for that
/// check. Allocate the complete success receipt before committing the file.
pub fn saveConfirmed(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, path: []const u8, registry: *hosts.Registry, invocation: host.Invocation) !host.Result {
    return saveConfirmedOperation(allocator, io, dir, path, registry, invocation, null);
}
pub fn savedResult(allocator: std.mem.Allocator, invocation: host.Invocation, value: hosts.HostConfig, operation: ?identity.HostOperationId, reused: bool) !host.Result {
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    const saved = try view(arena.allocator(), invocation.context, value);
    const operation_ref = if (operation) |id| try references.operationRef(arena.allocator(), invocation.context, id) else null;
    return result(allocator, invocation, try std.json.Stringify.valueAlloc(allocator, .{ .saved = true, .connection_started = false, .operation_ref = operation_ref, .idempotent_reuse = reused, .host = saved }, .{}), true);
}
pub fn saveConfirmedOperation(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, path: []const u8, registry: *hosts.Registry, invocation: host.Invocation, operation: ?identity.HostOperationId) !host.Result {
    const request = try parse(invocation);
    if (request.kind != .create_host) return error.ToolNotAvailable;
    if (invocation.approval_sequence == null or invocation.approval_sequence.? == 0) return error.HostApprovalRequired;
    // The published Registry outlives this invocation's result allocator.
    var transaction = try store.HostsTransaction.init(registry.arena.child_allocator, registry);
    defer transaction.deinit();
    const owner = try transaction.candidate.?.add(request.value.?);
    var receipt = try savedResult(allocator, invocation, try transaction.candidate.?.get(owner), operation, false);
    errdefer receipt.deinit(allocator);
    try transaction.commit(io, dir, path, registry);
    return receipt;
}
