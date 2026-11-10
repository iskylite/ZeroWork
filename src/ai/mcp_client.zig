//! MCP 2026-07-28 client with legacy handshake compatibility. One protocol/process session per task domain.
const std = @import("std");
const config = @import("../config/ai_extensions.zig");
const Provider = @import("provider.zig");
const Clock = @import("retry.zig").Clock;
pub const version = "2026-07-28";
pub const legacy_version = "2025-11-25";
pub const supported_versions = [_][]const u8{ version, legacy_version, "2025-06-18", "2025-03-26", "2024-11-05" };
pub fn serverRequest(method: []const u8) bool {
    inline for (.{ "roots/list", "sampling/createMessage", "elicitation/create" }) |name| if (std.mem.eql(u8, method, name)) return true;
    return false;
}
pub fn requestMethod(method: []const u8) bool {
    inline for (.{ "ping", "server/discover", "resources/list", "resources/templates/list", "resources/read", "resources/subscribe", "resources/unsubscribe", "prompts/list", "prompts/get", "completion/complete", "logging/setLevel", "tasks/list", "tasks/get", "tasks/result", "tasks/cancel", "notifications/poll", "subscriptions/listen", "tasks/update" }) |name| if (std.mem.eql(u8, method, name)) return true;
    return false;
}
pub const max_response_bytes = 32 * 1024 * 1024;
const Cancel = *const fn (?*anyopaque) callconv(.c) c_int;
extern fn zw_mcp_start([*:0]const u8, [*:null]const ?[*:0]const u8, [*:null]const ?[*:0]const u8, [*:0]const u8) ?*anyopaque;
extern fn zw_mcp_write(*anyopaque, [*]const u8, usize, c_uint, Cancel, ?*anyopaque) c_int;
extern fn zw_mcp_read(*anyopaque, [*]u8, usize, c_uint, Cancel, ?*anyopaque) c_int;
extern fn zw_mcp_close(*anyopaque) void;
const Sink = *const fn (?*anyopaque, [*]const u8, usize) callconv(.c) c_int;
extern fn zw_mcp_http([*:0]const u8, [*:0]const u8, [*]const [*:0]const u8, usize, [*]const u8, usize, c_uint, Sink, ?*anyopaque, Cancel, ?*anyopaque, [*]u8, [*]u8, [*]u8, *c_uint, ?Sink, ?*anyopaque, ?[*]u8, ?[*]const u8, usize) c_int;
extern fn zw_mcp_subscription_start([*:0]const u8, [*]const [*:0]const u8, usize, [*]const u8, usize, c_uint) ?*anyopaque;
extern fn zw_mcp_subscription_read(*anyopaque, [*]u8, usize, c_uint, Cancel, ?*anyopaque) c_int;
extern fn zw_mcp_subscription_close(*anyopaque) void;
fn cancelled(raw: ?*anyopaque) callconv(.c) c_int {
    const token: *Provider.CancelToken = @ptrCast(@alignCast(raw orelse return 0));
    return @intFromBool(token.isCancelled());
}
pub const Tool = struct { name: []const u8, description: []const u8, schema: []const u8, hash: [32]u8, available: bool, reason: []const u8, output_schema: ?[]const u8 = null, title: []const u8 = "", annotations: ?[]const u8 = null };
/// Borrowed only for the duration of one foreground request. Replies are owned
/// by the supplied allocator; the host applies its own user/scope checks.
pub const Handler = struct {
    context: *anyopaque,
    request: *const fn (*anyopaque, std.mem.Allocator, []const u8, std.json.Value, ?*Provider.CancelToken) anyerror![]u8,
};
pub const Client = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    catalog_arena: std.heap.ArenaAllocator,
    server: config.Server,
    process: ?*anyopaque = null,
    session_id: [512]u8 = @splat(0),
    sequence: u64 = 1,
    negotiated_version: []const u8 = version,
    modern: bool = true,
    probing: bool = false,
    rpc_error_code: ?i64 = null,
    log_level: []const u8 = "info",
    subscription_filter: []const u8 = "{}",
    subscription_accepted: []const u8 = "{}",
    subscription: ?*anyopaque = null,
    subscription_input: std.ArrayList(u8) = .empty,
    subscription_event: std.ArrayList(u8) = .empty,
    subscription_id: ?u64 = null,
    subscription_acknowledged: bool = false,
    subscription_started: bool = false,
    subscriptions_selected: bool = false,
    validator: @import("mcp_schema.zig").Validator = .{},
    has_tools: bool = false,
    server_info: []const u8 = "{}",
    server_capabilities: []const u8 = "{}",
    instructions: []const u8 = "",
    handler: ?Handler = null,
    resources_changed: bool = false,
    prompts_changed: bool = false,
    resource_updated: []const u8 = "",
    rpc_error: []const u8 = "",
    remote_error_received: bool = false,
    elicitation_result: []const u8 = "[]",
    elicitation_completed: []const u8 = "",
    handler_elapsed: i128 = 0,
    access_token: []const u8 = "",
    http_status: u32 = 0,
    auth_challenge: []const u8 = "",
    progress: f64 = 0,
    progress_total: ?f64 = null,
    progress_message: []const u8 = "",
    log_message: []const u8 = "",
    ready: bool = false,
    changed: bool = false,
    closed: bool = false,
    tools: std.ArrayList(Tool) = .empty,
    input: std.ArrayList(u8) = .empty,
    pub fn init(a: std.mem.Allocator, server: config.Server) !Client {
        try (config.Extensions{ .servers = @constCast((&[_]config.Server{server})[0..]) }).validate();
        var arena = std.heap.ArenaAllocator.init(a);
        errdefer arena.deinit();
        const copy = try (config.Extensions{ .servers = @constCast((&[_]config.Server{server})[0..]) }).clone(arena.allocator());
        return .{ .allocator = a, .arena = arena, .server = copy.servers[0], .catalog_arena = .init(a) };
    }
    pub fn deinit(self: *Client) void {
        self.close();
        self.input.deinit(self.allocator);
        self.subscription_input.deinit(self.allocator);
        self.subscription_event.deinit(self.allocator);
        self.tools.deinit(self.allocator);
        self.catalog_arena.deinit();
        self.validator.deinit();
        for ([_][]config.Value{ self.server.environment, self.server.headers }) |values| for (values) |value| if (value.secret) {
            std.crypto.secureZero(u8, @constCast(value.value));
        };
        if (self.access_token.len != 0) std.crypto.secureZero(u8, @constCast(self.access_token));
        self.arena.deinit();
    }
    pub fn close(self: *Client) void {
        if (self.closed) return;
        if (self.subscription) |stream| {
            zw_mcp_subscription_close(stream);
            self.subscription = null;
        }
        if (self.process) |process| {
            zw_mcp_close(process);
            self.process = null;
        }
        if (!self.modern and self.server.transport == .http and self.session_id[0] != 0) {
            const reply = self.http("DELETE", "", null, null, 500) catch null;
            if (reply) |bytes| self.allocator.free(bytes);
        }
        self.closed = true;
        self.ready = false;
    }
    fn start(self: *Client) !void {
        if (self.closed) return error.McpSessionClosed;
        if (self.process != null or self.server.transport == .http) return;
        const a = self.arena.allocator();
        const args = try a.allocSentinel(?[*:0]const u8, self.server.args.len + 1, null);
        args[0] = (try a.dupeSentinel(u8, self.server.program, 0)).ptr;
        for (self.server.args, 1..) |arg, i| args[i] = (try a.dupeSentinel(u8, arg, 0)).ptr;
        const environment = try a.allocSentinel(?[*:0]const u8, self.server.environment.len + 2, null);
        var used: usize = 0;
        inline for (.{ "PATH=/usr/bin:/bin:/usr/sbin:/sbin", "LANG=en_US.UTF-8" }) |fallback| {
            const name = fallback[0..std.mem.indexOfScalar(u8, fallback, '=').?];
            const configured = for (self.server.environment) |entry| {
                if (std.mem.eql(u8, entry.name, name)) break true;
            } else false;
            if (!configured) {
                environment[used] = fallback;
                used += 1;
            }
        }
        for (self.server.environment) |entry| {
            environment[used] = (try std.fmt.allocPrintSentinel(a, "{s}={s}", .{ entry.name, entry.value }, 0)).ptr;
            used += 1;
        }
        environment[used] = null;
        self.process = zw_mcp_start((try a.dupeSentinel(u8, self.server.program, 0)), args, environment, try a.dupeSentinel(u8, self.server.cwd, 0)) orelse return error.McpProcessStartFailed;
    }
    fn notify(self: *Client, value: anytype, cancel: ?*Provider.CancelToken) !void {
        const encoded = try std.json.Stringify.valueAlloc(self.allocator, value, .{});
        defer self.allocator.free(encoded);
        if (self.server.transport == .http) {
            const response = try self.http("POST", encoded, null, cancel, @min(self.server.timeout_ms, 1000));
            self.allocator.free(response);
        } else {
            const line = try std.fmt.allocPrint(self.allocator, "{s}\n", .{encoded});
            defer self.allocator.free(line);
            try code(zw_mcp_write(self.process.?, line.ptr, line.len, 1000, cancelled, cancel));
        }
    }
    fn code(result: c_int) !void {
        if (result == -3) return error.Cancelled;
        if (result == -2) return error.McpTimeout;
        if (result < 0) return error.McpTransportFailure;
    }
    const Capture = struct {
        a: std.mem.Allocator,
        client: *Client,
        cancel: ?*Provider.CancelToken,
        kind: *[128]u8,
        session: *[512]u8,
        bytes: std.ArrayList(u8) = .empty,
        data: std.ArrayList(u8) = .empty,
        offset: usize = 0,
        request_id: ?u64,
        response: ?[]u8 = null,
        subscription_stream: bool = false,
        problem: ?anyerror = null,
        fn consume(self: *@This()) !bool {
            if (!std.mem.startsWith(u8, std.mem.sliceTo(self.kind, 0), "text/event-stream")) return false;
            while (std.mem.indexOfScalarPos(u8, self.bytes.items, self.offset, '\n')) |end| {
                const line = std.mem.trimEnd(u8, self.bytes.items[self.offset..end], "\r");
                self.offset = end + 1;
                if (line.len == 0) {
                    if (self.data.items.len == 0) continue;
                    if (self.session[0] != 0) {
                        if (self.client.session_id[0] != 0 and !std.mem.eql(u8, std.mem.sliceTo(&self.client.session_id, 0), std.mem.sliceTo(self.session, 0))) return error.McpSessionChanged;
                        self.client.session_id = self.session.*;
                    }
                    const parsed = try self.client.message(self.data.items, self.request_id orelse return error.InvalidMcpResponse, self.cancel);
                    if (parsed) |value| {
                        defer value.deinit();
                        self.response = try self.a.dupe(u8, self.data.items);
                        return true;
                    }
                    self.data.clearRetainingCapacity();
                } else if (std.mem.startsWith(u8, line, "data:")) {
                    if (self.data.items.len != 0) try self.data.append(self.a, '\n');
                    const field = line[5..];
                    try self.data.appendSlice(self.a, if (std.mem.startsWith(u8, field, " ")) field[1..] else field);
                }
            }
            return false;
        }
        fn sink(raw: ?*anyopaque, bytes: [*]const u8, len: usize) callconv(.c) c_int {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            if (len > max_response_bytes -| self.bytes.items.len) {
                self.problem = error.McpResponseLimit;
                return -1;
            }
            self.bytes.appendSlice(self.a, bytes[0..len]) catch |err| {
                self.problem = err;
                return -1;
            };
            const done = self.consume() catch |err| {
                self.problem = err;
                return -1;
            };
            return if (done) 1 else if (self.subscription_stream and self.client.subscription_acknowledged) 2 else 0;
        }
    };
    fn http(self: *Client, method: [:0]const u8, body: []const u8, request_id: ?u64, cancel: ?*Provider.CancelToken, timeout: u32) ![]u8 {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var headers: std.ArrayList([*:0]const u8) = .empty;
        try headers.append(a, "Content-Type: application/json");
        try headers.append(a, "Accept: application/json, text/event-stream");
        if (self.ready or self.modern) try headers.append(a, (try std.fmt.allocPrintSentinel(a, "MCP-Protocol-Version: {s}", .{self.negotiated_version}, 0)).ptr);
        if (self.modern and body.len != 0) {
            const wire = try std.json.parseFromSlice(std.json.Value, a, body, .{});
            const name = @import("mcp_interaction.zig").string(wire.value, "method") orelse "";
            try config.text(name, 256, true);
            try headers.append(a, (try std.fmt.allocPrintSentinel(a, "Mcp-Method: {s}", .{name}, 0)).ptr);
            if (wire.value.object.get("params")) |params| if (@import("mcp_interaction.zig").string(params, "name")) |target| {
                if (std.mem.indexOfAny(u8, target, "\r\n") != null) return error.InvalidMcpValue;
                try headers.append(a, (try std.fmt.allocPrintSentinel(a, "Mcp-Name: {s}", .{target}, 0)).ptr);
                if (std.mem.eql(u8, name, "tools/call")) try self.parameterHeaders(a, target, params, &headers);
            };
        }
        if (self.session_id[0] != 0) try headers.append(a, (try std.fmt.allocPrintSentinel(a, "Mcp-Session-Id: {s}", .{std.mem.sliceTo(&self.session_id, 0)}, 0)).ptr);
        const access_token = if (std.mem.eql(u8, method, "DELETE")) (if (self.access_token.len == 0) null else try a.dupe(u8, self.access_token)) else try @import("mcp_oauth.zig").accessToken(a, self.server, cancel);
        if (access_token) |token| {
            if (self.access_token.len != 0) std.crypto.secureZero(u8, @constCast(self.access_token));
            self.access_token = try self.arena.allocator().dupe(u8, token);
            try headers.append(a, (try std.fmt.allocPrintSentinel(a, "Authorization: Bearer {s}", .{token}, 0)).ptr);
        }
        for (self.server.headers) |header| try headers.append(a, (try std.fmt.allocPrintSentinel(a, "{s}: {s}", .{ header.name, header.value }, 0)).ptr);
        var new_session: [512]u8 = @splat(0);
        var content_type: [128]u8 = @splat(0);
        var capture: Capture = .{ .a = self.allocator, .client = self, .cancel = cancel, .kind = &content_type, .session = &new_session, .request_id = request_id };
        defer capture.bytes.deinit(self.allocator);
        defer capture.data.deinit(self.allocator);
        errdefer if (capture.response) |response| self.allocator.free(response);
        var status: c_uint = 0;
        var challenge: [8192]u8 = @splat(0);
        var listener_kind: [128]u8 = @splat(0);
        var listener_session: [512]u8 = @splat(0);
        var listener: Capture = .{ .a = self.allocator, .client = self, .cancel = cancel, .kind = &listener_kind, .session = &listener_session, .request_id = request_id };
        defer listener.bytes.deinit(self.allocator);
        defer listener.data.deinit(self.allocator);
        defer if (listener.response) |response| self.allocator.free(response);
        const is_subscription = self.modern and request_id != null and self.subscription_id != null and request_id.? == self.subscription_id.?;
        capture.subscription_stream = is_subscription;
        if (self.modern and self.ready and self.subscriptions_selected and !is_subscription and request_id != null) try self.ensureHttpSubscription(a, headers.items, cancel);
        const duplex = !self.modern and self.ready and request_id != null and self.session_id[0] != 0 and std.mem.eql(u8, method, "POST");
        const transport_result = zw_mcp_http(try a.dupeSentinel(u8, self.server.endpoint, 0), method, headers.items.ptr, headers.items.len, body.ptr, body.len, timeout, Capture.sink, &capture, cancelled, cancel, &new_session, &content_type, &challenge, &status, if (duplex) Capture.sink else null, if (duplex) &listener else null, if (duplex) &listener_kind else null, null, 0);
        self.http_status = status;
        self.auth_challenge = try self.arena.allocator().dupe(u8, std.mem.sliceTo(&challenge, 0));
        if (status == 401) return error.McpAuthorizationRequired;
        if (status == 403) return error.McpInsufficientScope;
        if (capture.problem) |problem| return problem;
        if (listener.problem) |problem| return problem;
        try code(transport_result);
        if (std.mem.eql(u8, method, "DELETE") and (status == 404 or status == 405)) return self.allocator.dupe(u8, "");
        if (status != 200 and status != 202 and status != 204) {
            if ((self.probing or self.modern) and status >= 400 and status < 500) return capture.bytes.toOwnedSlice(self.allocator);
            return error.McpHttpStatus;
        }
        if (request_id != null and status != 200) return error.InvalidMcpResponse;
        if (request_id == null and std.mem.eql(u8, method, "POST") and status != 202) return error.InvalidMcpResponse;
        if (new_session[0] != 0) {
            if (self.session_id[0] != 0 and !std.mem.eql(u8, std.mem.sliceTo(&self.session_id, 0), std.mem.sliceTo(&new_session, 0))) return error.McpSessionChanged;
            self.session_id = new_session;
        }
        const kind = std.mem.sliceTo(&content_type, 0);
        if (request_id != null and !std.mem.startsWith(u8, kind, "application/json") and !std.mem.startsWith(u8, kind, "text/event-stream")) return error.InvalidMcpContentType;
        if (self.modern and self.subscription != null) try self.drainSubscription(0, cancel);
        if (capture.response) |response| return response;
        return capture.bytes.toOwnedSlice(self.allocator);
    }
    fn ensureHttpSubscription(self: *Client, a: std.mem.Allocator, headers: []const [*:0]const u8, cancel: ?*Provider.CancelToken) !void {
        if (self.subscription == null) {
            const body = try self.subscriptionBody(a);
            self.subscription = zw_mcp_subscription_start(try a.dupeSentinel(u8, self.server.endpoint, 0), headers.ptr, headers.len, body.ptr, body.len, self.server.timeout_ms) orelse return error.McpTransportFailure;
        }
        const deadline = (Clock{}).now() + @as(i128, self.server.timeout_ms) * std.time.ns_per_ms;
        while (!self.subscription_acknowledged) {
            if ((Clock{}).now() >= deadline) return error.McpTimeout;
            try self.drainSubscription(10, cancel);
        }
    }
    fn drainSubscription(self: *Client, timeout: u32, cancel: ?*Provider.CancelToken) anyerror!void {
        const stream = self.subscription orelse return;
        var remaining = timeout;
        while (true) {
            var buffer: [4096]u8 = undefined;
            const n = zw_mcp_subscription_read(stream, &buffer, buffer.len, remaining, cancelled, cancel);
            if (n == -2) return;
            if (n == -1) return error.McpSubscriptionDisconnected;
            try code(n);
            try self.subscription_input.appendSlice(self.allocator, buffer[0..@intCast(n)]);
            if (self.subscription_input.items.len > max_response_bytes) return error.McpResponseLimit;
            var offset: usize = 0;
            while (std.mem.indexOfScalarPos(u8, self.subscription_input.items, offset, '\n')) |end| {
                const line = std.mem.trimEnd(u8, self.subscription_input.items[offset..end], "\r");
                offset = end + 1;
                if (line.len == 0 and self.subscription_event.items.len != 0) {
                    const envelope = try std.json.parseFromSlice(std.json.Value, self.allocator, self.subscription_event.items, .{});
                    defer envelope.deinit();
                    const params = if (envelope.value == .object) envelope.value.object.get("params") else null;
                    const meta = if (params != null and params.? == .object) params.?.object.get("_meta") else null;
                    const id = if (meta != null and meta.? == .object) meta.?.object.get("io.modelcontextprotocol/subscriptionId") else null;
                    if (id == null or id.? != .integer or id.?.integer < 0 or @as(u64, @intCast(id.?.integer)) != self.subscription_id.?) return error.InvalidMcpSubscription;
                    const response = try self.message(self.subscription_event.items, self.subscription_id.?, cancel);
                    if (response) |value| {
                        value.deinit();
                        return error.McpSubscriptionDisconnected;
                    }
                    self.subscription_event.clearRetainingCapacity();
                } else if (std.mem.startsWith(u8, line, "data:")) {
                    if (self.subscription_event.items.len != 0) try self.subscription_event.append(self.allocator, '\n');
                    try self.subscription_event.appendSlice(self.allocator, std.mem.trimStart(u8, line[5..], " "));
                    if (self.subscription_event.items.len > max_response_bytes) return error.McpResponseLimit;
                }
            }
            std.mem.copyForwards(u8, self.subscription_input.items, self.subscription_input.items[offset..]);
            self.subscription_input.shrinkRetainingCapacity(self.subscription_input.items.len - offset);
            remaining = 0;
        }
    }
    fn subscriptionBody(self: *Client, a: std.mem.Allocator) ![]const u8 {
        const id = self.sequence;
        self.sequence += 1;
        self.subscription_id = id;
        self.subscription_acknowledged = false;
        self.subscription_accepted = "{}";
        const filter = try std.json.parseFromSlice(std.json.Value, a, self.subscription_filter, .{});
        return std.json.Stringify.valueAlloc(a, .{ .jsonrpc = "2.0", .id = id, .method = "subscriptions/listen", .params = try self.parameters(a, .{ .notifications = filter.value }, id) }, .{});
    }
    fn startSubscription(self: *Client, cancel: ?*Provider.CancelToken) !void {
        if (self.subscription_started or self.server.transport != .stdio) return;
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const body = try self.subscriptionBody(arena.allocator());
        const line = try std.fmt.allocPrint(arena.allocator(), "{s}\n", .{body});
        try code(zw_mcp_write(self.process.?, line.ptr, line.len, self.server.timeout_ms, cancelled, cancel));
        self.subscription_started = true;
    }
    fn restartSubscription(self: *Client, cancel: ?*Provider.CancelToken) !void {
        if (self.subscription) |stream| {
            zw_mcp_subscription_close(stream);
            self.subscription = null;
            self.subscription_input.clearRetainingCapacity();
            self.subscription_event.clearRetainingCapacity();
        }
        if (self.subscription_started) if (self.subscription_id) |id| {
            try self.notify(.{ .jsonrpc = "2.0", .method = "notifications/cancelled", .params = .{ .requestId = id } }, cancel);
        };
        self.subscription_started = false;
        self.subscription_acknowledged = false;
    }
    fn selectResource(self: *Client, uri: []const u8, selected: bool, cancel: ?*Provider.CancelToken) !void {
        const a = self.arena.allocator();
        var filter = (try std.json.parseFromSlice(std.json.Value, a, self.subscription_filter, .{ .allocate = .alloc_always })).value;
        const old = filter.object.get("resourceSubscriptions");
        var list: std.array_list.Managed(std.json.Value) = .init(a);
        if (old) |values| if (values == .array) for (values.array.items) |item| {
            if (item == .string and !std.mem.eql(u8, item.string, uri)) try list.append(item);
        };
        if (selected) try list.append(.{ .string = try a.dupe(u8, uri) });
        try filter.object.put(a, "resourceSubscriptions", .{ .array = list });
        self.subscription_filter = try std.json.Stringify.valueAlloc(a, filter, .{});
        self.subscriptions_selected = true;
        try self.restartSubscription(cancel);
    }
    fn validateSubscriptionNotification(self: *Client, method: []const u8, obj: std.json.Value) !void {
        const ack = std.mem.eql(u8, method, "notifications/subscriptions/acknowledged");
        const key: ?[]const u8 = if (std.mem.eql(u8, method, "notifications/tools/list_changed")) "toolsListChanged" else if (std.mem.eql(u8, method, "notifications/resources/list_changed")) "resourcesListChanged" else if (std.mem.eql(u8, method, "notifications/prompts/list_changed")) "promptsListChanged" else if (std.mem.eql(u8, method, "notifications/resources/updated")) "resourceSubscriptions" else null;
        if (!ack and key == null) return;
        const params = obj.object.get("params") orelse return error.InvalidMcpSubscription;
        if (params != .object) return error.InvalidMcpSubscription;
        const meta = params.object.get("_meta") orelse return error.InvalidMcpSubscription;
        if (meta != .object or !meta.object.contains("io.modelcontextprotocol/subscriptionId")) return error.InvalidMcpSubscription;
        const a = self.arena.allocator();
        if (ack) {
            if (self.subscription_id == null or self.subscription_acknowledged) return error.InvalidMcpSubscription;
            const accepted = params.object.get("notifications") orelse return error.InvalidMcpSubscription;
            const requested = (try std.json.parseFromSlice(std.json.Value, a, self.subscription_filter, .{})).value;
            try validateFilter(accepted, requested);
            self.subscription_accepted = try std.json.Stringify.valueAlloc(a, accepted, .{});
        } else {
            if (!self.subscription_acknowledged) return error.InvalidMcpSubscription;
            const accepted = (try std.json.parseFromSlice(std.json.Value, a, self.subscription_accepted, .{})).value;
            const selected = accepted.object.get(key.?) orelse return error.InvalidMcpSubscription;
            if (std.mem.eql(u8, key.?, "resourceSubscriptions")) {
                const uri = @import("mcp_interaction.zig").string(params, "uri") orelse return error.InvalidMcpSubscription;
                if (selected != .array) return error.InvalidMcpSubscription;
                for (selected.array.items) |item| if (item == .string and std.mem.eql(u8, item.string, uri)) return;
                return error.InvalidMcpSubscription;
            }
            if (selected != .bool or !selected.bool) return error.InvalidMcpSubscription;
        }
    }
    fn validateFilter(filter: std.json.Value, requested: ?std.json.Value) !void {
        if (filter != .object) return error.InvalidMcpSubscription;
        var it = filter.object.iterator();
        while (it.next()) |entry| {
            const name = entry.key_ptr.*;
            const value = entry.value_ptr.*;
            const allowed = if (requested) |r| r.object.get(name) else null;
            if (std.mem.eql(u8, name, "resourceSubscriptions")) {
                if (value != .array) return error.InvalidMcpSubscription;
                for (value.array.items) |uri| {
                    if (uri != .string) return error.InvalidMcpSubscription;
                    if (requested != null) {
                        if (allowed == null or allowed.? != .array) return error.InvalidMcpSubscription;
                        const contains = for (allowed.?.array.items) |item| {
                            if (item == .string and std.mem.eql(u8, item.string, uri.string)) break true;
                        } else false;
                        if (!contains) return error.InvalidMcpSubscription;
                    }
                }
            } else if (std.mem.eql(u8, name, "toolsListChanged") or std.mem.eql(u8, name, "promptsListChanged") or std.mem.eql(u8, name, "resourcesListChanged")) {
                if (value != .bool) return error.InvalidMcpSubscription;
                if (requested != null and value.bool and (allowed == null or allowed.? != .bool or !allowed.?.bool)) return error.InvalidMcpSubscription;
            } else return error.InvalidMcpSubscription;
        }
    }
    fn parameterHeaders(self: *Client, a: std.mem.Allocator, name: []const u8, params: std.json.Value, headers: *std.ArrayList([*:0]const u8)) !void {
        const arguments = params.object.get("arguments") orelse return;
        if (arguments != .object) return error.InvalidToolArguments;
        for (self.tools.items) |tool| {
            if (!std.mem.eql(u8, tool.name, name)) continue;
            const schema = try std.json.parseFromSlice(std.json.Value, a, tool.schema, .{});
            try @import("mcp_headers.zig").append(a, schema.value, arguments, headers);
            return;
        }
    }
    fn matches(value: std.json.Value, expected: u64) bool {
        if (value != .object) return false;
        const rid = value.object.get("id") orelse return false;
        return rid == .integer and rid.integer >= 0 and @as(u64, @intCast(rid.integer)) == expected;
    }
    fn message(self: *Client, bytes: []const u8, expected: u64, cancel: ?*Provider.CancelToken) !?std.json.Parsed(std.json.Value) {
        var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, bytes, .{});
        errdefer parsed.deinit();
        const obj = parsed.value;
        if (obj != .object) return error.InvalidMcpResponse;
        const protocol = obj.object.get("jsonrpc") orelse return error.InvalidMcpResponse;
        if (protocol != .string or !std.mem.eql(u8, protocol.string, "2.0")) return error.InvalidMcpResponse;
        if (self.modern) {
            if (obj.object.get("params")) |params| if (params == .object) if (params.object.get("_meta")) |meta| if (meta == .object) if (meta.object.get("io.modelcontextprotocol/subscriptionId")) |id| {
                if (id != .integer or self.subscription_id == null or id.integer < 0 or @as(u64, @intCast(id.integer)) != self.subscription_id.?) {
                    parsed.deinit();
                    return null;
                }
            };
        }
        if (obj.object.get("method")) |method| {
            if (method != .string) return error.InvalidMcpResponse;
            if (self.modern) try self.validateSubscriptionNotification(method.string, obj);
            if (obj.object.get("id")) |request_id| {
                if (request_id != .string and request_id != .integer) return error.InvalidMcpResponse;
                if (self.modern) return error.InvalidMcpServerRequest;
                if (std.mem.eql(u8, method.string, "ping")) {
                    try self.notify(.{ .jsonrpc = "2.0", .id = request_id, .result = struct {}{} }, cancel);
                } else if (self.handler != null and serverRequest(method.string)) {
                    const params = obj.object.get("params") orelse std.json.Value{ .object = .empty };
                    try self.checkSecrets(params);
                    const began = (Clock{}).now();
                    defer self.handler_elapsed += (Clock{}).now() - began;
                    const bytes_reply = self.handler.?.request(self.handler.?.context, self.allocator, method.string, params, cancel) catch |err| {
                        try self.notify(.{ .jsonrpc = "2.0", .id = request_id, .@"error" = .{ .code = @as(i32, if (err == error.Cancelled or err == error.CancelledBeforeDispatch) -32800 else -32603), .message = @errorName(err) } }, cancel);
                        parsed.deinit();
                        return null;
                    };
                    defer self.allocator.free(bytes_reply);
                    const reply = try std.json.parseFromSlice(std.json.Value, self.allocator, bytes_reply, .{});
                    defer reply.deinit();
                    try self.notify(.{ .jsonrpc = "2.0", .id = request_id, .result = reply.value }, cancel);
                } else try self.notify(.{ .jsonrpc = "2.0", .id = request_id, .@"error" = .{ .code = @as(i32, -32601), .message = "Client capability not negotiated" } }, cancel);
            } else if (std.mem.eql(u8, method.string, "notifications/subscriptions/acknowledged")) {
                self.subscription_acknowledged = true;
            } else if (std.mem.eql(u8, method.string, "notifications/tools/list_changed")) {
                self.changed = true;
            } else if (std.mem.eql(u8, method.string, "notifications/resources/list_changed")) {
                self.resources_changed = true;
            } else if (std.mem.eql(u8, method.string, "notifications/prompts/list_changed")) {
                self.prompts_changed = true;
            } else if (obj.object.get("params")) |params| {
                if (params == .object) {
                    try self.checkSecrets(params);
                    if (std.mem.eql(u8, method.string, "notifications/elicitation/complete")) {
                        if (params.object.get("elicitationId")) |id| if (id == .string) {
                            self.elicitation_completed = try self.arena.allocator().dupe(u8, id.string);
                        };
                    }
                    if (std.mem.eql(u8, method.string, "notifications/resources/updated")) {
                        if (params.object.get("uri")) |uri| if (uri == .string) {
                            self.resource_updated = try self.arena.allocator().dupe(u8, uri.string);
                        };
                    }
                    if (std.mem.eql(u8, method.string, "notifications/progress")) {
                        const token = params.object.get("progressToken") orelse return error.InvalidMcpResponse;
                        if (token != .integer or token.integer < 0 or @as(u64, @intCast(token.integer)) != expected) {
                            parsed.deinit();
                            return null;
                        }
                        if (params.object.get("progress")) |progress| self.progress = jsonNumber(progress) orelse return error.InvalidMcpResponse;
                        if (params.object.get("total")) |total| self.progress_total = jsonNumber(total) orelse return error.InvalidMcpResponse;
                        if (params.object.get("message")) |text| if (text == .string) {
                            self.progress_message = try self.arena.allocator().dupe(u8, boundedText(text.string, 512));
                        };
                    } else if (std.mem.eql(u8, method.string, "notifications/message")) {
                        const encoded_log = try std.json.Stringify.valueAlloc(self.arena.allocator(), params, .{});
                        self.log_message = boundedText(encoded_log, 512);
                    }
                }
            }
            parsed.deinit();
            return null;
        }
        if (!matches(obj, expected)) {
            if (self.modern and self.subscription_id != null and matches(obj, self.subscription_id.?)) {
                self.subscription_started = false;
                parsed.deinit();
                return null;
            }
            return error.McpResponseIdMismatch;
        }
        if (obj.object.get("error")) |err| {
            try self.checkSecrets(err);
            self.remote_error_received = true;
            self.rpc_error = try std.json.Stringify.valueAlloc(self.arena.allocator(), err, .{});
            const error_code = if (err == .object) err.object.get("code") else null;
            self.rpc_error_code = if (error_code != null and error_code.? == .integer) error_code.?.integer else null;
            if (error_code != null and error_code.? == .integer and error_code.?.integer == -32042 and self.handler != null) {
                const data = err.object.get("data") orelse return error.InvalidMcpResponse;
                const elicitations = if (data == .object) data.object.get("elicitations") orelse return error.InvalidMcpResponse else return error.InvalidMcpResponse;
                if (elicitations != .array or elicitations.array.items.len == 0 or elicitations.array.items.len > 16) return error.InvalidMcpResponse;
                var answers: std.ArrayList(std.json.Value) = .empty;
                defer answers.deinit(self.allocator);
                for (elicitations.array.items) |elicitation| {
                    const mode = @import("mcp_interaction.zig").string(elicitation, "mode") orelse return error.InvalidMcpResponse;
                    if (!std.mem.eql(u8, mode, "url")) return error.InvalidMcpResponse;
                    const body = try self.handler.?.request(self.handler.?.context, self.allocator, "elicitation/create", elicitation, cancel);
                    defer self.allocator.free(body);
                    const answer = try std.json.parseFromSlice(std.json.Value, self.arena.allocator(), body, .{ .allocate = .alloc_always });
                    try answers.append(self.allocator, answer.value);
                }
                self.elicitation_result = try std.json.Stringify.valueAlloc(self.arena.allocator(), answers.items, .{});
                return error.McpElicitationRequired;
            }
            return error.McpRpcError;
        }
        if (obj.object.get("result") == null) return error.InvalidMcpResponse;
        return parsed;
    }
    fn clientCapabilities(self: *Client, a: std.mem.Allocator) !std.json.Value {
        return (try std.json.parseFromSlice(std.json.Value, a, if (self.handler != null) "{\"roots\":{},\"sampling\":{},\"elicitation\":{\"form\":{},\"url\":{}}}" else "{}", .{ .allocate = .alloc_always })).value;
    }
    fn parameters(self: *Client, a: std.mem.Allocator, params: anytype, id: u64) !std.json.Value {
        const encoded = try std.json.Stringify.valueAlloc(a, params, .{});
        var value = (try std.json.parseFromSlice(std.json.Value, a, encoded, .{ .allocate = .alloc_always })).value;
        if (value != .object) return error.InvalidToolArguments;
        var meta = value.object.get("_meta") orelse std.json.Value{ .object = .empty };
        if (meta != .object) return error.InvalidToolArguments;
        try meta.object.put(a, "progressToken", .{ .integer = @intCast(id) });
        if (self.modern) {
            try meta.object.put(a, "io.modelcontextprotocol/protocolVersion", .{ .string = self.negotiated_version });
            try meta.object.put(a, "io.modelcontextprotocol/clientCapabilities", try self.clientCapabilities(a));
            const info = try std.json.parseFromSlice(std.json.Value, a, "{\"name\":\"ZeroWork\",\"version\":\"0.4.0\"}", .{ .allocate = .alloc_always });
            try meta.object.put(a, "io.modelcontextprotocol/clientInfo", info.value);
            try meta.object.put(a, "io.modelcontextprotocol/logLevel", .{ .string = self.log_level });
        }
        try value.object.put(a, "_meta", meta);
        return value;
    }
    pub fn rpc(self: *Client, method: []const u8, params: anytype, cancel: ?*Provider.CancelToken) !std.json.Parsed(std.json.Value) {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const original = try self.parameters(a, params, self.sequence);
        var current = original;
        while (true) {
            if (cancel) |token| if (token.isCancelled()) return error.Cancelled;
            const response = try self.rpcOnce(method, current, cancel);
            var release_response = true;
            defer if (release_response) response.deinit();
            if (!self.modern) {
                release_response = false;
                return response;
            }
            const value = response.value.object.get("result") orelse return error.InvalidMcpResponse;
            const kind = @import("mcp_interaction.zig").string(value, "resultType") orelse return error.InvalidMcpResponse;
            if (std.mem.eql(u8, kind, "complete")) {
                release_response = false;
                return response;
            }
            if (!std.mem.eql(u8, kind, "input_required") or (!std.mem.eql(u8, method, "tools/call") and !std.mem.eql(u8, method, "prompts/get") and !std.mem.eql(u8, method, "resources/read"))) return error.InvalidMcpResponse;
            const handler = self.handler orelse return error.McpInteractionRequired;
            const state = value.object.get("requestState");
            const requests = value.object.get("inputRequests");
            if (state == null and requests == null) return error.InvalidMcpResponse;
            if (state) |state_value| if (state_value != .string) return error.InvalidMcpResponse;
            var answers: std.json.ObjectMap = .empty;
            var url_interaction = false;
            if (requests) |items| {
                if (items != .object) return error.InvalidMcpResponse;
                var it = items.object.iterator();
                while (it.next()) |entry| {
                    const embedded_request = entry.value_ptr.*;
                    const requested_method = @import("mcp_interaction.zig").string(embedded_request, "method") orelse return error.InvalidMcpResponse;
                    if (!serverRequest(requested_method)) return error.McpMethodNotAllowed;
                    const requested_params = embedded_request.object.get("params") orelse std.json.Value{ .object = .empty };
                    if (@import("mcp_interaction.zig").string(requested_params, "mode")) |mode| if (std.mem.eql(u8, mode, "url")) {
                        url_interaction = true;
                    };
                    try self.checkSecrets(requested_params);
                    const reply = try handler.request(handler.context, self.allocator, requested_method, requested_params, cancel);
                    defer self.allocator.free(reply);
                    const parsed_reply = try std.json.parseFromSlice(std.json.Value, a, reply, .{ .allocate = .alloc_always });
                    try answers.put(a, try a.dupe(u8, entry.key_ptr.*), parsed_reply.value);
                }
            }
            // Only the original method/arguments are resumed. Opaque state and
            // answers belong to this call and never become model tool arguments.
            current = (try std.json.parseFromSlice(std.json.Value, a, try std.json.Stringify.valueAlloc(a, original, .{}), .{ .allocate = .alloc_always })).value;
            if (state) |state_value| try current.object.put(a, "requestState", .{ .string = try a.dupe(u8, state_value.string) });
            if (requests != null) try current.object.put(a, "inputResponses", .{ .object = answers });
            if (self.changed and std.mem.eql(u8, method, "tools/call")) return error.McpSchemaChanged;
            const review = try handler.request(handler.context, self.allocator, if (url_interaction) "host/mcp_continue_url" else "host/mcp_continue", current, cancel);
            self.allocator.free(review);
        }
    }
    fn rpcOnce(self: *Client, method: []const u8, params: anytype, cancel: ?*Provider.CancelToken) !std.json.Parsed(std.json.Value) {
        try self.start();
        if (cancel) |token| if (token.isCancelled()) return error.Cancelled;
        self.remote_error_received = false;
        self.rpc_error_code = null;
        self.rpc_error = "";
        const number = self.sequence;
        self.sequence += 1;
        var params_arena = std.heap.ArenaAllocator.init(self.allocator);
        defer params_arena.deinit();
        const params_value = try self.parameters(params_arena.allocator(), params, number);
        const timeout: u32 = if (self.probing) @min(self.server.timeout_ms, 3000) else self.server.timeout_ms;
        const body = try std.json.Stringify.valueAlloc(self.allocator, .{ .jsonrpc = "2.0", .id = number, .method = method, .params = params_value }, .{});
        defer self.allocator.free(body);
        var deadline = (Clock{}).now() + @as(i128, timeout) * std.time.ns_per_ms;
        errdefer {
            if (!self.remote_error_received and !self.probing) {
                self.notify(.{ .jsonrpc = "2.0", .method = "notifications/cancelled", .params = .{ .requestId = number } }, null) catch {};
                self.close();
            }
        }
        if (self.server.transport == .http) {
            const response = try self.http("POST", body, number, cancel, timeout);
            defer self.allocator.free(response);
            if (std.mem.startsWith(u8, std.mem.trimStart(u8, response, " \r\n"), "{")) return (try self.message(response, number, cancel)) orelse error.InvalidMcpResponse;
            var data: std.ArrayList(u8) = .empty;
            defer data.deinit(self.allocator);
            var lines = std.mem.splitScalar(u8, response, '\n');
            while (lines.next()) |line| {
                if (std.mem.startsWith(u8, line, "data:")) {
                    if (data.items.len != 0) try data.append(self.allocator, '\n');
                    try data.appendSlice(self.allocator, std.mem.trimStart(u8, std.mem.trimEnd(u8, line, "\r")[5..], " "));
                } else if (std.mem.trim(u8, line, "\r").len == 0 and data.items.len != 0) {
                    if (try self.message(data.items, number, cancel)) |result| return result;
                    data.clearRetainingCapacity();
                }
            }
            if (data.items.len != 0) if (try self.message(data.items, number, cancel)) |result| return result;
            return error.InvalidMcpResponse;
        }
        if (self.modern and self.subscriptions_selected and !self.probing) try self.startSubscription(cancel);
        const line = try std.fmt.allocPrint(self.allocator, "{s}\n", .{body});
        defer self.allocator.free(line);
        try code(zw_mcp_write(self.process.?, line.ptr, line.len, timeout, cancelled, cancel));
        while (true) {
            if (cancel) |token| if (token.isCancelled()) return error.Cancelled;
            if ((Clock{}).now() >= deadline) return error.McpTimeout;
            while (std.mem.indexOfScalar(u8, self.input.items, '\n') == null) {
                if (self.input.items.len > max_response_bytes) return error.McpResponseLimit;
                const remaining = deadline - (Clock{}).now();
                if (remaining <= 0) return error.McpTimeout;
                var buffer: [4096]u8 = undefined;
                const n = zw_mcp_read(self.process.?, &buffer, buffer.len, @intCast(@min(@divTrunc(remaining, std.time.ns_per_ms) + 1, timeout)), cancelled, cancel);
                try code(n);
                try self.input.appendSlice(self.allocator, buffer[0..@intCast(n)]);
            }
            const end = std.mem.indexOfScalar(u8, self.input.items, '\n').?;
            const elapsed = self.handler_elapsed;
            const result = try self.message(self.input.items[0..end], number, cancel);
            deadline += self.handler_elapsed - elapsed;
            std.mem.copyForwards(u8, self.input.items, self.input.items[end + 1 ..]);
            self.input.shrinkRetainingCapacity(self.input.items.len - end - 1);
            if (result) |response| return response;
        }
    }
    pub fn initialize(self: *Client, cancel: ?*Provider.CancelToken) !void {
        if (self.ready) return;
        self.probing = true;
        const discovered: ?std.json.Parsed(std.json.Value) = self.rpc("server/discover", struct {}{}, cancel) catch |err| fallback: {
            self.probing = false;
            if (err == error.Cancelled or err == error.McpAuthorizationRequired or err == error.McpInsufficientScope) return err;
            if (self.rpc_error_code) |code_value| if (code_value == -32020 or code_value == -32021 or code_value == -32022) return error.UnsupportedMcpVersion;
            if (self.process != null and (err == error.McpTransportFailure or err == error.McpTimeout)) {
                zw_mcp_close(self.process.?);
                self.process = null;
                self.input.clearRetainingCapacity();
            }
            self.modern = false;
            self.negotiated_version = legacy_version;
            break :fallback @as(?std.json.Parsed(std.json.Value), null);
        };
        self.probing = false;
        if (discovered) |reply| {
            defer reply.deinit();
            const value = reply.value.object.get("result").?;
            const versions = value.object.get("supportedVersions") orelse return error.UnsupportedMcpVersion;
            const accepted = supported: {
                if (versions == .array) for (versions.array.items) |v| {
                    if (v == .string and std.mem.eql(u8, v.string, version)) break :supported true;
                };
                break :supported false;
            };
            if (!accepted) return error.UnsupportedMcpVersion;
            try self.acceptDiscovery(value);
            self.ready = true;
            return;
        }
        const a = self.arena.allocator();
        const reply = try self.rpc("initialize", .{ .protocolVersion = legacy_version, .capabilities = try self.clientCapabilities(a), .clientInfo = .{ .name = "ZeroWork", .version = "0.4.0" } }, cancel);
        defer reply.deinit();
        const value = reply.value.object.get("result").?;
        const negotiated = @import("mcp_interaction.zig").string(value, "protocolVersion") orelse return error.UnsupportedMcpVersion;
        self.negotiated_version = for (supported_versions[1..]) |supported| {
            if (std.mem.eql(u8, negotiated, supported)) break supported;
        } else return error.UnsupportedMcpVersion;
        try self.acceptDiscovery(value);
        self.ready = true;
        try self.notify(.{ .jsonrpc = "2.0", .method = "notifications/initialized" }, cancel);
    }
    fn acceptDiscovery(self: *Client, value: std.json.Value) !void {
        if (value != .object) return error.InvalidMcpResponse;
        const capabilities = value.object.get("capabilities") orelse return error.InvalidMcpResponse;
        if (capabilities != .object) return error.InvalidMcpResponse;
        self.has_tools = capabilities.object.get("tools") != null;
        try self.checkSecrets(value);
        self.server_capabilities = try std.json.Stringify.valueAlloc(self.arena.allocator(), capabilities, .{});
        if (value.object.get("serverInfo")) |info| self.server_info = try std.json.Stringify.valueAlloc(self.arena.allocator(), info, .{});
        if (value.object.get("_meta")) |meta| if (meta == .object) if (meta.object.get("io.modelcontextprotocol/serverInfo")) |info| {
            self.server_info = try std.json.Stringify.valueAlloc(self.arena.allocator(), info, .{});
        };
        if (@import("mcp_interaction.zig").string(value, "instructions")) |instructions| self.instructions = try self.arena.allocator().dupe(u8, instructions);
    }
    pub fn request(self: *Client, method: []const u8, params: std.json.Value, cancel: ?*Provider.CancelToken) ![]u8 {
        if (!requestMethod(method)) return error.McpMethodNotAllowed;
        if (params != .object) return error.InvalidToolArguments;
        try self.initialize(cancel);
        if (self.modern) {
            if (std.mem.eql(u8, method, "resources/subscribe") or std.mem.eql(u8, method, "resources/unsubscribe")) {
                const uri = @import("mcp_interaction.zig").string(params, "uri") orelse return error.InvalidToolArguments;
                try self.selectResource(uri, std.mem.eql(u8, method, "resources/subscribe"), cancel);
                return self.allocator.dupe(u8, "{\"resultType\":\"complete\"}");
            }
            if (std.mem.eql(u8, method, "logging/setLevel")) {
                const level = @import("mcp_interaction.zig").string(params, "level") orelse return error.InvalidToolArguments;
                const valid = for ([_][]const u8{ "debug", "info", "notice", "warning", "error", "critical", "alert", "emergency" }) |item| {
                    if (std.mem.eql(u8, level, item)) break true;
                } else false;
                if (!valid) return error.InvalidToolArguments;
                self.log_level = try self.arena.allocator().dupe(u8, level);
                return self.allocator.dupe(u8, "{\"resultType\":\"complete\"}");
            }
            if (std.mem.eql(u8, method, "ping")) return self.request("server/discover", params, cancel);
            if (std.mem.eql(u8, method, "tasks/list") or std.mem.eql(u8, method, "tasks/result")) return error.McpMethodUnavailable;
        }
        if (std.mem.eql(u8, method, "subscriptions/listen")) {
            if (!self.modern) return error.McpMethodUnavailable;
            const filter = params.object.get("notifications") orelse return error.InvalidToolArguments;
            try validateFilter(filter, null);
            self.subscription_filter = try std.json.Stringify.valueAlloc(self.arena.allocator(), filter, .{});
            self.subscriptions_selected = true;
            try self.restartSubscription(cancel);
        }
        if (std.mem.eql(u8, method, "notifications/poll") or std.mem.eql(u8, method, "subscriptions/listen")) {
            const duration = params.object.get("timeout_ms") orelse std.json.Value{ .integer = 1000 };
            if (duration != .integer or duration.integer < 100 or duration.integer > 30000) return error.InvalidToolArguments;
            const timeout: u32 = @intCast(duration.integer);
            if (self.server.transport == .http) {
                if (self.modern) {
                    if (self.subscription == null) {
                        // Open via a harmless discovery request, retaining the
                        // notification stream independently of that response.
                        const opened = try self.rpc("server/discover", struct {}{}, cancel);
                        opened.deinit();
                    }
                    try self.drainSubscription(timeout, cancel);
                } else {
                    const bytes = self.http("GET", "", 0, cancel, timeout) catch |err| switch (err) {
                        error.McpTimeout => null,
                        else => return err,
                    };
                    if (bytes) |received| self.allocator.free(received);
                }
            } else {
                if (self.modern) try self.startSubscription(cancel);
                const end = (Clock{}).now() + @as(i128, timeout) * std.time.ns_per_ms;
                while ((Clock{}).now() < end) {
                    while (std.mem.indexOfScalar(u8, self.input.items, '\n')) |line_end| {
                        if (try self.message(self.input.items[0..line_end], 0, cancel)) |reply| reply.deinit();
                        std.mem.copyForwards(u8, self.input.items, self.input.items[line_end + 1 ..]);
                        self.input.shrinkRetainingCapacity(self.input.items.len - line_end - 1);
                    }
                    var buffer: [4096]u8 = undefined;
                    const n = zw_mcp_read(self.process.?, &buffer, buffer.len, @intCast(@min(@divTrunc(end - (Clock{}).now(), std.time.ns_per_ms) + 1, timeout)), cancelled, cancel);
                    if (n == -2) break;
                    try code(n);
                    if (self.input.items.len + @as(usize, @intCast(n)) > max_response_bytes) return error.McpResponseLimit;
                    try self.input.appendSlice(self.allocator, buffer[0..@intCast(n)]);
                }
            }
            return std.json.Stringify.valueAlloc(self.allocator, .{ .subscription_notifications = self.subscription_accepted, .resources_changed = self.resources_changed, .prompts_changed = self.prompts_changed, .resource_updated = self.resource_updated, .log_message = self.log_message, .elicitation_completed = self.elicitation_completed }, .{});
        }
        const reply = try self.rpc(method, params, cancel);
        defer reply.deinit();
        const value = reply.value.object.get("result").?;
        if (value != .object) return error.InvalidMcpResponse;
        try self.checkSecrets(value);
        return std.json.Stringify.valueAlloc(self.allocator, value, .{});
    }
    pub fn discover(self: *Client, cancel: ?*Provider.CancelToken) !void {
        try self.initialize(cancel);
        self.tools.clearRetainingCapacity();
        if (!self.has_tools) return;
        _ = self.catalog_arena.reset(.free_all);
        var catalog_bytes: usize = 0;
        var cursor: ?[]const u8 = null;
        const a = self.catalog_arena.allocator();
        const catalog_deadline = (Clock{}).now() + @as(i128, self.server.timeout_ms) * std.time.ns_per_ms;
        var cursors: std.StringHashMap(void) = .init(a);
        while ((Clock{}).now() < catalog_deadline) {
            const response = if (cursor) |c| try self.rpc("tools/list", .{ .cursor = c }, cancel) else try self.rpc("tools/list", struct {}{}, cancel);
            defer response.deinit();
            const result = response.value.object.get("result").?;
            if (result != .object) return error.InvalidMcpResponse;
            try self.checkSecrets(result);
            const tools = result.object.get("tools") orelse return error.InvalidMcpResponse;
            if (tools != .array) return error.InvalidMcpResponse;
            for (tools.array.items) |tool| {
                if (tool != .object) return error.McpCatalogLimit;
                const name = tool.object.get("name") orelse return error.InvalidMcpResponse;
                const schema = tool.object.get("inputSchema") orelse return error.InvalidMcpResponse;
                if (name != .string) return error.InvalidMcpResponse;
                try config.text(name.string, 256, false);
                for (self.tools.items) |prior| if (std.mem.eql(u8, prior.name, name.string)) return error.DuplicateMcpTool;
                const schema_text = try std.json.Stringify.valueAlloc(a, schema, .{});
                catalog_bytes += schema_text.len + name.string.len;
                if (schema_text.len > 256 * 1024 or catalog_bytes > 4 * 1024 * 1024) return error.McpSchemaLimit;
                var hash: [32]u8 = undefined;
                std.crypto.hash.sha2.Sha256.hash(schema_text, &hash, .{});
                const binding = for (self.server.bindings) |binding| {
                    if (std.mem.eql(u8, binding.name, name.string)) break true;
                } else false;
                const output_schema = if (tool.object.get("outputSchema")) |value| try std.json.Stringify.valueAlloc(a, value, .{}) else null;
                if (output_schema) |output| {
                    catalog_bytes += output.len;
                    if (output.len > 256 * 1024 or catalog_bytes > 4 * 1024 * 1024) return error.McpSchemaLimit;
                    var combined = std.crypto.hash.sha2.Sha256.init(.{});
                    combined.update(&hash);
                    combined.update(output);
                    combined.final(&hash);
                }
                const valid_schema = valid: {
                    if (self.modern) _ = @import("mcp_headers.zig").declarations(a, schema) catch break :valid false;
                    self.validator.validate(self.allocator, schema_text, null) catch break :valid false;
                    if (output_schema) |output| self.validator.validate(self.allocator, output, null) catch break :valid false;
                    break :valid true;
                };
                const allowed = binding and valid_schema;
                const title = tool.object.get("title");
                const annotations = if (tool.object.get("annotations")) |value| try std.json.Stringify.valueAlloc(a, value, .{}) else null;
                const description = tool.object.get("description");
                catalog_bytes += if (title != null and title.? == .string) title.?.string.len else 0;
                catalog_bytes += if (annotations) |text| text.len else 0;
                if (catalog_bytes > 4 * 1024 * 1024) return error.McpSchemaLimit;
                try self.tools.append(self.allocator, .{ .name = try a.dupe(u8, name.string), .description = if (description != null and description.? == .string and description.?.string.len <= 2048) try a.dupe(u8, description.?.string) else "", .schema = schema_text, .hash = hash, .available = allowed, .reason = if (allowed) "" else if (!binding) "未授权此工具" else "工具参数 schema 无效或引用无法解析", .output_schema = output_schema, .annotations = annotations, .title = if (title != null and title.? == .string) try a.dupe(u8, title.?.string) else "" });
            }
            const next = result.object.get("nextCursor") orelse {
                self.changed = false;
                return;
            };
            if (next == .null) {
                self.changed = false;
                return;
            }
            if (next != .string or next.string.len == 0 or next.string.len > 1024 or (cursor != null and std.mem.eql(u8, cursor.?, next.string))) return error.InvalidMcpCursor;
            if (cursors.contains(next.string)) return error.InvalidMcpCursor;
            cursor = try a.dupe(u8, next.string);
            try cursors.put(cursor.?, {});
        }
        return error.McpTimeout;
    }
    fn checkSecrets(self: *Client, value: std.json.Value) !void {
        return self.checkSecretsInner(value, 0);
    }
    fn checkSecretsInner(self: *Client, value: std.json.Value, depth: usize) !void {
        if (depth > 32) return error.McpResponseDepth;
        switch (value) {
            .string => |text| {
                if (self.access_token.len != 0 and std.mem.indexOf(u8, text, self.access_token) != null) return error.McpSecretReflected;
                inline for (.{ self.server.environment, self.server.headers }) |entries| for (entries) |entry| if (entry.secret and entry.value.len != 0 and std.mem.indexOf(u8, text, entry.value) != null) return error.McpSecretReflected;
            },
            .array => |items| for (items.items) |item| try self.checkSecretsInner(item, depth + 1),
            .object => |object| {
                var it = object.iterator();
                while (it.next()) |entry| {
                    try self.checkSecretsInner(.{ .string = entry.key_ptr.* }, depth + 1);
                    try self.checkSecretsInner(entry.value_ptr.*, depth + 1);
                }
            },
            else => {},
        }
    }
    pub fn refreshTool(self: *Client, selected: Tool, cancel: ?*Provider.CancelToken) !Tool {
        const name = try self.allocator.dupe(u8, selected.name);
        defer self.allocator.free(name);
        const hash = selected.hash;
        try self.discover(cancel);
        for (self.tools.items) |current| if (std.mem.eql(u8, current.name, name) and std.mem.eql(u8, &current.hash, &hash) and current.available) return current;
        return error.McpSchemaChanged;
    }
    // Compatibility helper for callers of the original text tool API.
    pub fn validateCall(self: *Client, tool: Tool, text: []const u8) !void {
        const encoded = try std.json.Stringify.valueAlloc(self.allocator, .{ .text = text }, .{});
        defer self.allocator.free(encoded);
        const args = try std.json.parseFromSlice(std.json.Value, self.allocator, encoded, .{});
        defer args.deinit();
        try self.validateCallArguments(tool, args.value);
    }
    pub fn validateCallArguments(self: *Client, tool: Tool, arguments: std.json.Value) !void {
        if (!self.ready or self.closed or self.changed or !tool.available) return error.McpCapabilityUnavailable;
        if (arguments != .object) return error.InvalidToolArguments;
        const encoded = try std.json.Stringify.valueAlloc(self.allocator, arguments, .{});
        defer self.allocator.free(encoded);
        if (encoded.len > 32 * 1024) return error.McpArgumentsLimit;
        try self.validator.validate(self.allocator, tool.schema, arguments);
    }
    pub fn call(self: *Client, tool: Tool, text: []const u8, cancel: ?*Provider.CancelToken) ![]u8 {
        const encoded = try std.json.Stringify.valueAlloc(self.allocator, .{ .text = text }, .{});
        defer self.allocator.free(encoded);
        const args = try std.json.parseFromSlice(std.json.Value, self.allocator, encoded, .{});
        defer args.deinit();
        return self.callArguments(tool, args.value, cancel);
    }
    pub fn callArguments(self: *Client, tool: Tool, arguments: std.json.Value, cancel: ?*Provider.CancelToken) ![]u8 {
        try self.validateCallArguments(tool, arguments);
        const response = try self.rpc("tools/call", .{ .name = tool.name, .arguments = arguments }, cancel);
        defer response.deinit();
        const result = response.value.object.get("result").?;
        if (result != .object or result.object.get("content") == null) return error.InvalidMcpResult;
        try self.checkSecrets(result);
        const content = result.object.get("content").?;
        if (content != .array) return error.InvalidMcpResult;
        for (content.array.items) |block| try validateContent(block);
        if (!self.modern) if (result.object.get("structuredContent")) |structured| if (structured != .object) return error.InvalidMcpResult;
        const failed = if (result.object.get("isError")) |value| value == .bool and value.bool else false;
        if (!failed) if (tool.output_schema) |output| {
            const structured = result.object.get("structuredContent") orelse return error.InvalidMcpOutput;
            self.validator.validate(self.allocator, output, structured) catch return error.InvalidMcpOutput;
        };
        if (result.object.get("isError")) |flag| if (flag != .bool) return error.InvalidMcpResult;
        const encoded = try std.json.Stringify.valueAlloc(self.allocator, result, .{});
        errdefer self.allocator.free(encoded);
        if (encoded.len > max_response_bytes) return error.McpResultLimit;
        return encoded;
    }
};
fn jsonNumber(value: std.json.Value) ?f64 {
    return switch (value) {
        .integer => @floatFromInt(value.integer),
        .float => value.float,
        else => null,
    };
}
fn stringField(object: std.json.Value, name: []const u8) ![]const u8 {
    const value = object.object.get(name) orelse return error.InvalidMcpResult;
    if (value != .string) return error.InvalidMcpResult;
    return value.string;
}
fn validateContent(block: std.json.Value) !void {
    if (block != .object) return error.InvalidMcpResult;
    const kind = try stringField(block, "type");
    if (std.mem.eql(u8, kind, "text")) {
        _ = try stringField(block, "text");
    } else if (std.mem.eql(u8, kind, "image") or std.mem.eql(u8, kind, "audio")) {
        _ = try stringField(block, "data");
        _ = try stringField(block, "mimeType");
    } else if (std.mem.eql(u8, kind, "resource_link")) {
        _ = try stringField(block, "uri");
        _ = try stringField(block, "name");
    } else if (std.mem.eql(u8, kind, "resource")) {
        const resource = block.object.get("resource") orelse return error.InvalidMcpResult;
        if (resource != .object) return error.InvalidMcpResult;
        _ = try stringField(resource, "uri");
        if (resource.object.get("text") != null) {
            _ = try stringField(resource, "text");
        } else {
            _ = try stringField(resource, "blob");
            _ = try stringField(resource, "mimeType");
        }
    } else return error.McpContentUnsupported;
}

fn boundedText(value: []const u8, limit: usize) []const u8 {
    var end = @min(value.len, limit);
    while (end < value.len and value[end] & 0xc0 == 0x80) end -= 1;
    return value[0..end];
}

test "v0.4 extensions modern subscriptions enforce acknowledgement correlation and selected resources" {
    var client = try Client.init(std.testing.allocator, .{ .id = "subscription-test", .name = "Subscriptions", .program = "/usr/bin/true" });
    defer client.deinit();
    client.subscription_id = 7;
    client.subscription_filter = "{\"resourceSubscriptions\":[\"test://selected\"]}";
    const ack = "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/subscriptions/acknowledged\",\"params\":{\"_meta\":{\"io.modelcontextprotocol/subscriptionId\":7},\"notifications\":{\"resourceSubscriptions\":[\"test://selected\"]}}}";
    try std.testing.expectEqual(@as(?std.json.Parsed(std.json.Value), null), try client.message(ack, 0, null));
    try std.testing.expect(client.subscription_acknowledged);
    const update = "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/resources/updated\",\"params\":{\"_meta\":{\"io.modelcontextprotocol/subscriptionId\":7},\"uri\":\"test://selected\"}}";
    try std.testing.expectEqual(@as(?std.json.Parsed(std.json.Value), null), try client.message(update, 0, null));
    try std.testing.expectEqualStrings("test://selected", client.resource_updated);
    try std.testing.expectError(error.InvalidMcpSubscription, client.message("{\"jsonrpc\":\"2.0\",\"method\":\"notifications/resources/updated\",\"params\":{\"uri\":\"test://unselected\"}}", 0, null));
    try std.testing.expectError(error.InvalidMcpSubscription, client.message("{\"jsonrpc\":\"2.0\",\"method\":\"notifications/resources/updated\",\"params\":{\"_meta\":{\"io.modelcontextprotocol/subscriptionId\":7},\"uri\":\"test://unselected\"}}", 0, null));
    try std.testing.expectError(error.InvalidMcpServerRequest, client.message("{\"jsonrpc\":\"2.0\",\"id\":99,\"method\":\"roots/list\"}", 0, null));
    try std.testing.expectError(error.InvalidMcpSubscription, client.message(ack, 0, null));
}
