//! MCP 2025-11-25 tools client. One protocol/process session per task domain.
const std = @import("std");
const config = @import("../config/ai_extensions.zig");
const Provider = @import("provider.zig");
const Clock = @import("retry.zig").Clock;
pub const version = "2025-11-25";
const Cancel = *const fn (?*anyopaque) callconv(.c) c_int;
extern fn zw_mcp_start([*:0]const u8, [*:null]const ?[*:0]const u8, [*:null]const ?[*:0]const u8, [*:0]const u8) ?*anyopaque;
extern fn zw_mcp_write(*anyopaque, [*]const u8, usize, c_uint, Cancel, ?*anyopaque) c_int;
extern fn zw_mcp_read(*anyopaque, [*]u8, usize, c_uint, Cancel, ?*anyopaque) c_int;
extern fn zw_mcp_close(*anyopaque) void;
const Sink = *const fn (?*anyopaque, [*]const u8, usize) callconv(.c) c_int;
extern fn zw_mcp_http([*:0]const u8, [*:0]const u8, [*]const [*:0]const u8, usize, [*]const u8, usize, c_uint, Sink, ?*anyopaque, Cancel, ?*anyopaque, [*]u8, [*]u8, *c_uint) c_int;
fn cancelled(raw: ?*anyopaque) callconv(.c) c_int {
    const token: *Provider.CancelToken = @ptrCast(@alignCast(raw orelse return 0));
    return @intFromBool(token.isCancelled());
}
pub const Tool = struct { name: []const u8, description: []const u8, schema: []const u8, hash: [32]u8, available: bool, reason: []const u8 };
pub const Client = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    catalog_arena: std.heap.ArenaAllocator,
    server: config.Server,
    process: ?*anyopaque = null,
    session_id: [512]u8 = @splat(0),
    sequence: u64 = 1,
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
        self.tools.deinit(self.allocator);
        self.catalog_arena.deinit();
        for ([_][]config.Value{ self.server.environment, self.server.headers }) |values| for (values) |value| if (value.secret) {
            std.crypto.secureZero(u8, @constCast(value.value));
        };
        self.arena.deinit();
    }
    pub fn close(self: *Client) void {
        if (self.closed) return;
        if (self.process) |process| {
            zw_mcp_close(process);
            self.process = null;
        }
        if (self.server.transport == .http and self.session_id[0] != 0) {
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
        events: usize = 0,
        request_id: ?u64,
        response: ?[]u8 = null,
        problem: ?anyerror = null,
        fn consume(self: *@This()) !bool {
            if (!std.mem.startsWith(u8, std.mem.sliceTo(self.kind, 0), "text/event-stream")) return false;
            while (std.mem.indexOfScalarPos(u8, self.bytes.items, self.offset, '\n')) |end| {
                const line = std.mem.trimEnd(u8, self.bytes.items[self.offset..end], "\r");
                self.offset = end + 1;
                if (line.len == 0) {
                    if (self.data.items.len == 0) continue;
                    self.events += 1;
                    if (self.events > 128) return error.McpMessageLimit;
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
            if (len > 1024 * 1024 -| self.bytes.items.len) {
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
            return if (done) 1 else 0;
        }
    };
    fn http(self: *Client, method: [:0]const u8, body: []const u8, request_id: ?u64, cancel: ?*Provider.CancelToken, timeout: u32) ![]u8 {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var headers: std.ArrayList([*:0]const u8) = .empty;
        try headers.append(a, "Content-Type: application/json");
        try headers.append(a, "Accept: application/json, text/event-stream");
        if (self.ready) try headers.append(a, "MCP-Protocol-Version: " ++ version);
        if (self.session_id[0] != 0) try headers.append(a, (try std.fmt.allocPrintSentinel(a, "Mcp-Session-Id: {s}", .{std.mem.sliceTo(&self.session_id, 0)}, 0)).ptr);
        for (self.server.headers) |header| try headers.append(a, (try std.fmt.allocPrintSentinel(a, "{s}: {s}", .{ header.name, header.value }, 0)).ptr);
        var new_session: [512]u8 = @splat(0);
        var content_type: [128]u8 = @splat(0);
        var capture: Capture = .{ .a = self.allocator, .client = self, .cancel = cancel, .kind = &content_type, .session = &new_session, .request_id = request_id };
        defer capture.bytes.deinit(self.allocator);
        defer capture.data.deinit(self.allocator);
        errdefer if (capture.response) |response| self.allocator.free(response);
        var status: c_uint = 0;
        const transport_result = zw_mcp_http(try a.dupeSentinel(u8, self.server.endpoint, 0), method, headers.items.ptr, headers.items.len, body.ptr, body.len, timeout, Capture.sink, &capture, cancelled, cancel, &new_session, &content_type, &status);
        if (capture.problem) |problem| return problem;
        try code(transport_result);
        if (std.mem.eql(u8, method, "DELETE") and (status == 404 or status == 405)) return self.allocator.dupe(u8, "");
        if (status != 200 and status != 202 and status != 204) return error.McpHttpStatus;
        if (request_id != null and status != 200) return error.InvalidMcpResponse;
        if (request_id == null and std.mem.eql(u8, method, "POST") and status != 202) return error.InvalidMcpResponse;
        if (new_session[0] != 0) {
            if (self.session_id[0] != 0 and !std.mem.eql(u8, std.mem.sliceTo(&self.session_id, 0), std.mem.sliceTo(&new_session, 0))) return error.McpSessionChanged;
            self.session_id = new_session;
        }
        const kind = std.mem.sliceTo(&content_type, 0);
        if (request_id != null and !std.mem.startsWith(u8, kind, "application/json") and !std.mem.startsWith(u8, kind, "text/event-stream")) return error.InvalidMcpContentType;
        if (capture.response) |response| return response;
        return capture.bytes.toOwnedSlice(self.allocator);
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
        if (obj.object.get("method")) |method| {
            if (method != .string) return error.InvalidMcpResponse;
            if (obj.object.get("id")) |request_id| try self.notify(.{ .jsonrpc = "2.0", .id = request_id, .@"error" = .{ .code = @as(i32, -32601), .message = "Client capability not supported" } }, cancel) else if (std.mem.eql(u8, method.string, "notifications/tools/list_changed")) self.changed = true;
            parsed.deinit();
            return null;
        }
        if (!matches(obj, expected)) return error.McpResponseIdMismatch;
        if (obj.object.get("error") != null) return error.McpRpcError;
        if (obj.object.get("result") == null) return error.InvalidMcpResponse;
        return parsed;
    }
    pub fn rpc(self: *Client, method: []const u8, params: anytype, cancel: ?*Provider.CancelToken) !std.json.Parsed(std.json.Value) {
        try self.start();
        if (cancel) |token| if (token.isCancelled()) return error.Cancelled;
        const number = self.sequence;
        self.sequence += 1;
        const body = try std.json.Stringify.valueAlloc(self.allocator, .{ .jsonrpc = "2.0", .id = number, .method = method, .params = params }, .{});
        defer self.allocator.free(body);
        const deadline = (Clock{}).now() + @as(i128, self.server.timeout_ms) * std.time.ns_per_ms;
        errdefer {
            self.notify(.{ .jsonrpc = "2.0", .method = "notifications/cancelled", .params = .{ .requestId = number } }, null) catch {};
            self.close();
        }
        if (self.server.transport == .http) {
            const response = try self.http("POST", body, number, cancel, self.server.timeout_ms);
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
        const line = try std.fmt.allocPrint(self.allocator, "{s}\n", .{body});
        defer self.allocator.free(line);
        try code(zw_mcp_write(self.process.?, line.ptr, line.len, self.server.timeout_ms, cancelled, cancel));
        for (0..128) |_| {
            while (std.mem.indexOfScalar(u8, self.input.items, '\n') == null) {
                if (self.input.items.len > 1024 * 1024) return error.McpResponseLimit;
                const remaining = deadline - (Clock{}).now();
                if (remaining <= 0) return error.McpTimeout;
                var buffer: [4096]u8 = undefined;
                const n = zw_mcp_read(self.process.?, &buffer, buffer.len, @intCast(@min(@divTrunc(remaining, std.time.ns_per_ms) + 1, self.server.timeout_ms)), cancelled, cancel);
                try code(n);
                try self.input.appendSlice(self.allocator, buffer[0..@intCast(n)]);
            }
            const end = std.mem.indexOfScalar(u8, self.input.items, '\n').?;
            const result = try self.message(self.input.items[0..end], number, cancel);
            std.mem.copyForwards(u8, self.input.items, self.input.items[end + 1 ..]);
            self.input.shrinkRetainingCapacity(self.input.items.len - end - 1);
            if (result) |response| return response;
        }
        return error.McpMessageLimit;
    }
    pub fn initialize(self: *Client, cancel: ?*Provider.CancelToken) !void {
        if (self.ready) return;
        const reply = try self.rpc("initialize", .{ .protocolVersion = version, .capabilities = struct {}{}, .clientInfo = .{ .name = "ZeroWork", .version = "0.4.0" } }, cancel);
        defer reply.deinit();
        const result = reply.value.object.get("result").?;
        if (result != .object) return error.InvalidMcpResponse;
        const negotiated = result.object.get("protocolVersion") orelse return error.UnsupportedMcpVersion;
        if (negotiated != .string or !std.mem.eql(u8, negotiated.string, version)) return error.UnsupportedMcpVersion;
        const capabilities = result.object.get("capabilities") orelse return error.McpToolsUnsupported;
        if (capabilities != .object or capabilities.object.get("tools") == null) return error.McpToolsUnsupported;
        self.ready = true;
        try self.notify(.{ .jsonrpc = "2.0", .method = "notifications/initialized" }, cancel);
    }
    pub fn discover(self: *Client, cancel: ?*Provider.CancelToken) !void {
        try self.initialize(cancel);
        self.tools.clearRetainingCapacity();
        _ = self.catalog_arena.reset(.free_all);
        var catalog_bytes: usize = 0;
        var cursor: ?[]const u8 = null;
        const a = self.catalog_arena.allocator();
        for (0..16) |_| {
            const response = if (cursor) |c| try self.rpc("tools/list", .{ .cursor = c }, cancel) else try self.rpc("tools/list", struct {}{}, cancel);
            defer response.deinit();
            const result = response.value.object.get("result").?;
            if (result != .object) return error.InvalidMcpResponse;
            try self.checkSecrets(result);
            const tools = result.object.get("tools") orelse return error.InvalidMcpResponse;
            if (tools != .array) return error.InvalidMcpResponse;
            for (tools.array.items) |tool| {
                if (self.tools.items.len >= 64 or tool != .object) return error.McpCatalogLimit;
                const name = tool.object.get("name") orelse return error.InvalidMcpResponse;
                const schema = tool.object.get("inputSchema") orelse return error.InvalidMcpResponse;
                if (name != .string) return error.InvalidMcpResponse;
                try config.text(name.string, 256, false);
                for (self.tools.items) |prior| if (std.mem.eql(u8, prior.name, name.string)) return error.DuplicateMcpTool;
                const schema_text = try std.json.Stringify.valueAlloc(a, schema, .{});
                catalog_bytes += schema_text.len + name.string.len;
                if (schema_text.len > 32 * 1024 or catalog_bytes > 96 * 1024) return error.McpSchemaLimit;
                var hash: [32]u8 = undefined;
                std.crypto.hash.sha2.Sha256.hash(schema_text, &hash, .{});
                const binding = for (self.server.bindings) |binding| {
                    if (std.mem.eql(u8, binding.name, name.string)) break true;
                } else false;
                const allowed = binding and materialSchema(schema);
                const description = tool.object.get("description");
                try self.tools.append(self.allocator, .{ .name = try a.dupe(u8, name.string), .description = if (description != null and description.? == .string and description.?.string.len <= 2048) try a.dupe(u8, description.?.string) else "", .schema = schema_text, .hash = hash, .available = allowed, .reason = if (allowed) "" else if (!binding) "未选择材料适配" else "工具输入无法验证为材料范围" });
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
            cursor = try a.dupe(u8, next.string);
        }
        return error.McpCatalogLimit;
    }
    fn checkSecrets(self: *Client, value: std.json.Value) !void {
        return self.checkSecretsInner(value, 0);
    }
    fn checkSecretsInner(self: *Client, value: std.json.Value, depth: usize) !void {
        if (depth > 32) return error.McpResponseDepth;
        switch (value) {
            .string => |text| inline for (.{ self.server.environment, self.server.headers }) |entries| {
                for (entries) |entry| if (entry.secret and entry.value.len != 0 and std.mem.indexOf(u8, text, entry.value) != null) return error.McpSecretReflected;
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
    pub fn validateCall(self: *Client, tool: Tool, text: []const u8) !void {
        if (!self.ready or self.closed or self.changed or !tool.available) return error.McpCapabilityUnavailable;
        try config.text(text, 16384, false);
        const schema = try std.json.parseFromSlice(std.json.Value, self.allocator, tool.schema, .{});
        defer schema.deinit();
        const args_text = try std.json.Stringify.valueAlloc(self.allocator, .{ .text = text }, .{});
        defer self.allocator.free(args_text);
        const args = try std.json.parseFromSlice(std.json.Value, self.allocator, args_text, .{});
        defer args.deinit();
        try @import("plugin_tools.zig").validateArguments(schema.value, args.value);
    }
    pub fn call(self: *Client, tool: Tool, text: []const u8, cancel: ?*Provider.CancelToken) ![]u8 {
        try self.validateCall(tool, text);
        const response = try self.rpc("tools/call", .{ .name = tool.name, .arguments = .{ .text = text } }, cancel);
        defer response.deinit();
        const result = response.value.object.get("result").?;
        if (result != .object or result.object.get("content") == null) return error.InvalidMcpResult;
        try self.checkSecrets(result);
        const content = result.object.get("content").?;
        if (content != .array or content.array.items.len > 32) return error.McpResultLimit;
        for (content.array.items) |block| {
            if (block != .object) return error.InvalidMcpResult;
            const kind = block.object.get("type") orelse return error.InvalidMcpResult;
            if (kind != .string or !std.mem.eql(u8, kind.string, "text")) return error.McpContentUnsupported;
            const value = block.object.get("text") orelse return error.InvalidMcpResult;
            if (value != .string or value.string.len > 48 * 1024) return error.McpResultLimit;
        }
        if (result.object.get("isError")) |flag| if (flag != .bool) return error.InvalidMcpResult;
        const encoded = try std.json.Stringify.valueAlloc(self.allocator, result, .{});
        errdefer self.allocator.free(encoded);
        if (encoded.len > 48 * 1024) return error.McpResultLimit;
        return encoded;
    }
};
pub fn materialSchema(schema: std.json.Value) bool {
    if (schema != .object) return false;
    const kind = schema.object.get("type") orelse return false;
    if (kind != .string or !std.mem.eql(u8, kind.string, "object")) return false;
    const additional = schema.object.get("additionalProperties") orelse return false;
    if (additional != .bool or additional.bool) return false;
    const properties = schema.object.get("properties") orelse return false;
    if (properties != .object or properties.object.count() != 1) return false;
    const text = properties.object.get("text") orelse return false;
    if (text != .object) return false;
    const text_type = text.object.get("type") orelse return false;
    if (text_type != .string or !std.mem.eql(u8, text_type.string, "string")) return false;
    const required = schema.object.get("required") orelse return false;
    if (required != .array or required.array.items.len != 1 or required.array.items[0] != .string or !std.mem.eql(u8, required.array.items[0].string, "text")) return false;
    // The existing strict schema validator rejects unsupported semantics.
    const encoded = std.json.Stringify.valueAlloc(std.heap.page_allocator, schema, .{}) catch return false;
    defer std.heap.page_allocator.free(encoded);
    @import("plugin_tools.zig").validateDefinition(.{ .id = "host.mcp_material", .schema = encoded }) catch return false;
    return true;
}
