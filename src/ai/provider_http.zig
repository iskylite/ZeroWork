const std = @import("std");
const provider = @import("provider.zig");
const provider_config = @import("provider_config.zig");
const registry = @import("registry.zig");

/// Bounded, credential-free provider failure shared by tests and chat UI.
pub const Diagnostic = struct {
    status: u16 = 0,
    message: [1024]u8 = @splat(0),
    len: usize = 0,
    pub fn capture(self: *Diagnostic, status: u16, body: []const u8, key: ?[]const u8) void {
        self.* = .{ .status = status };
        const parsed = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, body, .{}) catch return;
        defer parsed.deinit();
        if (parsed.value != .object) return;
        const problem = parsed.value.object.get("error") orelse parsed.value;
        const value = if (problem == .object) problem.object.get("message") orelse return else problem;
        if (value != .string) return;
        // Do not show a response that reflects the request credential.
        if (key) |secret| if (secret.len != 0 and std.mem.indexOf(u8, value.string, secret) != null) return;
        const text = value.string[0..@min(value.string.len, self.message.len)];
        for (text) |byte| if (byte >= 32 or byte == '\n' or byte == '\t') {
            self.message[self.len] = byte;
            self.len += 1;
        };
        while (self.len > 0 and !std.unicode.utf8ValidateSlice(self.message[0..self.len])) self.len -= 1;
    }
    pub fn format(self: *const Diagnostic, buffer: []u8, err: anyerror) []const u8 {
        const summary: []const u8 = switch (self.status) {
            400, 422 => "服务端拒绝请求参数",
            401 => "鉴权失败，请检查 API Key",
            403 => "当前凭据无访问权限",
            404 => "接口或模型不存在",
            408, 504 => "服务端请求超时",
            429 => "请求被限流，请稍后重试",
            500...503, 505...599 => "模型服务暂不可用",
            else => "请求失败",
        };
        return if (self.status != 0) std.fmt.bufPrint(buffer, "HTTP {d} · {s}（{s}）{s}{s}", .{ self.status, summary, @errorName(err), if (self.len > 0) "\n" else "", self.message[0..self.len] }) catch @errorName(err) else std.fmt.bufPrint(buffer, "请求失败 · {s}", .{@errorName(err)}) catch @errorName(err);
    }
};

pub const AuthStyle = enum { bearer, anthropic_key, none };
pub const RequestPlan = struct {
    method: std.http.Method = .POST,
    endpoint: []const u8,
    content_type: []const u8 = "application/json",
    accept: []const u8 = "text/event-stream",
    auth_style: AuthStyle,
    api_key: ?[]const u8 = null,
    timeout_ms: u32 = 60_000,
    cancel: ?*provider.CancelToken = null,
};

pub fn plan(config: provider_config.ProviderConfig) !RequestPlan {
    try config.validate();
    if (!std.mem.startsWith(u8, config.endpoint, "https://") and !isLoopbackHttp(config.endpoint)) return error.InsecureEndpoint;
    var result: RequestPlan = switch (config.auth) {
        .anthropic_memory => |key| .{ .endpoint = config.endpoint, .auth_style = .anthropic_key, .api_key = key },
        .bearer_memory => |key| .{ .endpoint = config.endpoint, .auth_style = .bearer, .api_key = key },
        .none => .{ .endpoint = config.endpoint, .auth_style = .none },
    };
    if (config.kind == .ollama) result.accept = "application/x-ndjson";
    return result;
}

/// Parse the authority rather than accepting localhost.evil or 127.0.0.10 prefixes.
pub fn isLoopbackHttp(endpoint: []const u8) bool {
    const uri = std.Uri.parse(endpoint) catch return false;
    if (!std.mem.eql(u8, uri.scheme, "http") or uri.user != null or uri.password != null or uri.fragment != null) return false;
    const host = uri.host orelse return false;
    const value = switch (host) {
        .raw => |v| v,
        .percent_encoded => |v| v,
    };
    return std.mem.eql(u8, value, "localhost") or std.mem.eql(u8, value, "127.0.0.1") or std.mem.eql(u8, value, "[::1]") or std.mem.eql(u8, value, "::1");
}

/// Accept a provider base URL as well as an explicit protocol endpoint.
/// Custom paths and query strings remain explicit and are never rewritten.
pub fn chatEndpoint(allocator: std.mem.Allocator, kind: registry.Kind, endpoint: []const u8) ![]u8 {
    const uri = try std.Uri.parse(endpoint);
    const path = switch (uri.path) {
        .raw => |v| v,
        .percent_encoded => |v| v,
    };
    const base = std.mem.trimEnd(u8, endpoint, "/");
    if (uri.query != null or uri.fragment != null) return allocator.dupe(u8, endpoint);
    const suffix: []const u8 = switch (kind) {
        .openai_compat => if (path.len == 0 or std.mem.eql(u8, path, "/")) "/v1/chat/completions" else if (std.mem.eql(u8, std.mem.trimEnd(u8, path, "/"), "/v1")) "/chat/completions" else "",
        .anthropic => if (path.len == 0 or std.mem.eql(u8, path, "/")) "/v1/messages" else if (std.mem.eql(u8, std.mem.trimEnd(u8, path, "/"), "/v1")) "/messages" else "",
        .ollama => if (path.len == 0 or std.mem.eql(u8, path, "/")) "/api/chat" else if (std.mem.eql(u8, std.mem.trimEnd(u8, path, "/"), "/api")) "/chat" else "",
    };
    return if (suffix.len == 0) allocator.dupe(u8, endpoint) else std.mem.concat(allocator, u8, &.{ base, suffix });
}

test "chat endpoint supports base URLs and preserves explicit gateway paths" {
    const a = std.testing.allocator;
    for ([_][2][]const u8{ .{ "https://gateway.test", "https://gateway.test/v1/chat/completions" }, .{ "https://gateway.test/v1/", "https://gateway.test/v1/chat/completions" }, .{ "https://gateway.test/custom/chat?x=1", "https://gateway.test/custom/chat?x=1" } }) |pair| {
        const actual = try chatEndpoint(a, .openai_compat, pair[0]);
        defer a.free(actual);
        try std.testing.expectEqualStrings(pair[1], actual);
    }
}
test "provider diagnostic shows structured failures without credentials" {
    var diagnostic: Diagnostic = .{};
    diagnostic.capture(400, "{\"error\":{\"message\":\"unsupported model\"}}", "key");
    var buffer: [1400]u8 = undefined;
    try std.testing.expect(std.mem.indexOf(u8, diagnostic.format(&buffer, error.ProviderFailure), "HTTP 400") != null);
    try std.testing.expectEqualStrings("unsupported model", diagnostic.message[0..diagnostic.len]);
    diagnostic.capture(401, "{\"error\":{\"message\":\"invalid key secret-value\"}}", "secret-value");
    try std.testing.expectEqual(@as(usize, 0), diagnostic.len);
}

pub const ResponseKind = enum { success, retryable, provider_error, malformed };
pub const Response = struct { status: u16, kind: ResponseKind, retry_after_ms: ?u32 = null };
/// The complete encoded JSON body, for every adapter. A legitimate 64 KiB
/// local text or tool result may expand sixfold when JSON-escaped. This wire
/// ceiling is separate from the model's context/token budget.
pub const max_request_bytes: usize = 64 * 1024 * 1024;
pub const max_text_request_bytes: usize = 1024 * 1024;
pub const max_tool_request_bytes: usize = max_request_bytes;

pub fn parseRetryAfter(value: []const u8) ?u32 {
    const trimmed = std.mem.trim(u8, value, " \t");
    const seconds = std.fmt.parseInt(u32, trimmed, 10) catch return null;
    return std.math.mul(u32, seconds, 1000) catch std.math.maxInt(u32);
}

pub fn response(status: u16, retry_after_ms: ?u32) Response {
    const kind: ResponseKind = switch (status) {
        200...299 => .success,
        408, 425, 429, 500...599 => .retryable,
        400...407, 409...424, 426...428, 430...499 => .provider_error,
        else => .malformed,
    };
    return .{ .status = status, .kind = kind, .retry_after_ms = retry_after_ms };
}

/// Allocation-free preflight of the exact serializer. The host calls this
/// before accepting a frozen submission/consuming its draft attachments.
pub fn requestBodySize(kind: registry.Kind, request: provider.ChatRequest, context_window: u32) !usize {
    if (request.thinking != null and (request.reasoning_wire == .none or (kind != .openai_compat and kind != .ollama and request.reasoning_wire != .anthropic_adaptive))) return error.UnsupportedThinking;
    if (kind != .openai_compat and !request.native_effort and request.effort != null) return error.UnsupportedEffort;
    _ = try @import("image_budget.zig").validate(request);
    const image_fields = hasImages(request);
    if (image_fields and kind != .openai_compat and !request.tool_images) return error.UnsupportedImageProtocol;
    const tool_fields = hasToolFields(request);
    if (tool_fields) try validateToolMessages(request);
    var buffer: [128]u8 = undefined;
    var counter: BodyCounter = .{ .writer = .{ .buffer = &buffer, .vtable = &.{ .drain = BodyCounter.drain } } };
    writeRequestBody(&counter.writer, kind, request, context_window) catch |err| {
        if (err == error.WriteFailed) return if (tool_fields) error.ToolRequestTooLarge else error.RequestTooLarge;
        return err;
    };
    if (counter.writer.end > max_request_bytes - counter.count) return if (tool_fields) error.ToolRequestTooLarge else error.RequestTooLarge;
    const size = counter.count + counter.writer.end;
    if (!image_fields and size > max_text_request_bytes) return if (tool_fields) error.ToolRequestTooLarge else error.RequestTooLarge;
    return size;
}

pub fn requestBody(allocator: std.mem.Allocator, kind: registry.Kind, request: provider.ChatRequest, context_window: u32) ![]u8 {
    const size = try requestBodySize(kind, request, context_window);
    const body = try allocator.alloc(u8, size);
    errdefer allocator.free(body);
    var writer = std.Io.Writer.fixed(body);
    try writeRequestBody(&writer, kind, request, context_window);
    std.debug.assert(writer.end == size);
    @import("tool_trace.zig").wire(body);
    return body;
}

const BodyCounter = struct {
    writer: std.Io.Writer,
    count: usize = 0,

    fn drain(writer: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *BodyCounter = @alignCast(@fieldParentPtr("writer", writer));
        var size = std.math.mul(usize, data[data.len - 1].len, splat) catch return error.WriteFailed;
        for (data[0 .. data.len - 1]) |part| size = std.math.add(usize, size, part.len) catch return error.WriteFailed;
        const with_buffer = std.math.add(usize, writer.end, size) catch return error.WriteFailed;
        if (with_buffer > max_request_bytes - self.count) return error.WriteFailed;
        self.count += with_buffer;
        writer.end = 0;
        return size;
    }
};

fn writeRequestBody(fw: *std.Io.Writer, kind: registry.Kind, request: provider.ChatRequest, context_window: u32) !void {
    if (kind != .openai_compat) return writeNativeRequestBody(fw, kind, request, context_window);
    const max_tokens = @min(request.max_output, @max(context_window / 4, 1));
    try fw.writeAll("{\"model\":\"");
    try writeJsonString(fw, request.model);
    try fw.writeAll("\",\"messages\":[");
    var message_index: usize = 0;
    if (kind == .openai_compat and request.system.len != 0) {
        try fw.writeAll("{\"role\":\"system\",\"content\":\"");
        try writeJsonString(fw, request.system);
        try fw.writeAll("\"}");
        message_index = 1;
    }
    for (request.messages, 0..) |message, source_index| {
        if (message_index != 0) try fw.writeByte(',');
        try fw.writeAll("{\"role\":\"");
        try writeJsonString(fw, @tagName(message.role));
        try fw.writeAll("\",\"content\":");
        if (message.images.len == 0 or message.role == .tool) {
            try fw.writeByte('"');
            try writeJsonString(fw, message.content);
            try fw.writeByte('"');
        } else {
            try fw.writeAll("[{\"type\":\"text\",\"text\":\"");
            try writeJsonString(fw, message.content);
            try fw.writeAll("\"}");
            for (message.images) |reference| {
                const image = reference.content() orelse return error.EmptyAttachmentResult;
                try fw.print(",{{\"type\":\"image_url\",\"image_url\":{{\"url\":\"data:{s};base64,", .{image.mime.name()});
                try writeBase64(fw, image.bytes);
                try fw.writeAll("\",\"detail\":\"high\"}}");
            }
            try fw.writeByte(']');
        }
        if (message.tool_call_id) |id| {
            try fw.writeAll(",\"tool_call_id\":\"");
            try writeJsonString(fw, id);
            try fw.writeByte('"');
        }
        if (message.tool_calls.len != 0) {
            try fw.writeAll(",\"tool_calls\":[");
            for (message.tool_calls, 0..) |call, index| {
                if (index != 0) try fw.writeByte(',');
                try fw.writeAll("{\"id\":\"");
                try writeJsonString(fw, call.id);
                try fw.writeAll("\",\"type\":\"function\",\"function\":{\"name\":\"");
                try writeJsonString(fw, call.name);
                try fw.writeAll("\",\"arguments\":\"");
                try writeJsonString(fw, call.arguments);
                try fw.writeAll("\"}}");
            }
            try fw.writeByte(']');
        }
        try fw.writeByte('}');
        message_index += 1;
        // Tool results remain correlated by call ID. Image observations use the
        // provider's native user image blocks, never base64 inside result text.
        if (message.role == .tool and (source_index + 1 == request.messages.len or request.messages[source_index + 1].role != .tool)) {
            var observation_start = source_index;
            while (observation_start > 0 and request.messages[observation_start - 1].role == .tool) observation_start -= 1;
            for (request.messages[observation_start .. source_index + 1]) |observed| {
                if (observed.images.len == 0) continue;
                try fw.writeAll(",{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"Image observation from tool result ");
                try writeJsonString(fw, observed.tool_call_id.?);
                try fw.writeAll("\"}");
                for (observed.images) |reference| {
                    const image = reference.content() orelse return error.EmptyAttachmentResult;
                    try fw.print(",{{\"type\":\"image_url\",\"image_url\":{{\"url\":\"data:{s};base64,", .{image.mime.name()});
                    try writeBase64(fw, image.bytes);
                    try fw.writeAll("\",\"detail\":\"high\"}}");
                }
                try fw.writeAll("]}");
                message_index += 1;
            }
        }
    }
    try fw.writeAll("],\"max_tokens\":");
    try fw.print("{d}", .{max_tokens});
    try fw.writeAll(",\"stream\":true");
    if (systemAllowed(kind)) {
        try fw.writeAll(",\"system\":\"");
        try writeJsonString(fw, request.system);
        try fw.writeByte('"');
    }
    if (request.reasoning_wire == .openrouter and (request.effort != null or request.thinking != null)) {
        try fw.writeAll(",\"reasoning\":{");
        if (request.effort) |effort| {
            try fw.print("\"effort\":\"{s}\"", .{@tagName(effort)});
        }
        if (request.thinking) |enabled| {
            if (request.effort != null) try fw.writeByte(',');
            try fw.print("\"enabled\":{s}", .{if (enabled) "true" else "false"});
        }
        try fw.writeByte('}');
    } else {
        if (request.effort) |effort| try fw.print(",\"reasoning_effort\":\"{s}\"", .{@tagName(effort)});
        if (request.thinking) |enabled| switch (request.reasoning_wire) {
            .thinking_type => try fw.print(",\"thinking\":{{\"type\":\"{s}\"}}", .{if (enabled) "enabled" else "disabled"}),
            else => return error.UnsupportedThinking,
        };
    }
    if (request.tools.len != 0) {
        try fw.writeAll(",\"tools\":[");
        for (request.tools, 0..) |definition, index| {
            if (index != 0) try fw.writeByte(',');
            try writeToolDefinition(fw, definition, kind);
        }
        try fw.writeByte(']');
    }
    try fw.writeByte('}');
}

/// Anthropic and Ollama share the host transcript, never their wire envelopes.
fn writeNativeRequestBody(writer: *std.Io.Writer, kind: registry.Kind, request: provider.ChatRequest, context_window: u32) !void {
    try writer.writeAll("{\"model\":\"");
    try writeJsonString(writer, request.model);
    try writer.writeAll("\",\"stream\":true,");
    if (request.native_effort) if (request.effort) |effort| {
        if (kind == .anthropic) try writer.print("\"output_config\":{{\"effort\":\"{s}\"}},", .{@tagName(effort)}) else if (kind == .ollama) try writer.print("\"think\":\"{s}\",", .{@tagName(effort)});
    };
    if (kind == .anthropic and request.reasoning_wire == .anthropic_adaptive) if (request.thinking) |enabled| try writer.print("\"thinking\":{{\"type\":\"{s}\"}},", .{if (enabled) "adaptive" else "disabled"});
    if (kind == .ollama and request.effort == null) if (request.thinking) |enabled| try writer.print("\"think\":{s},", .{if (enabled) "true" else "false"});
    const limit = @min(request.max_output, @max(context_window / 4, 1));
    if (kind == .anthropic) {
        try writer.print("\"max_tokens\":{d},\"system\":\"", .{limit});
        try writeJsonString(writer, request.system);
        try writer.writeAll("\",");
    } else try writer.print("\"options\":{{\"num_predict\":{d},\"num_ctx\":{d}}},", .{ limit, context_window });
    try writer.writeAll("\"messages\":[");
    var comma = false;
    if (kind == .ollama and request.system.len != 0) {
        try writer.writeAll("{\"role\":\"system\",\"content\":\"");
        try writeJsonString(writer, request.system);
        try writer.writeAll("\"}");
        comma = true;
    }
    var i: usize = 0;
    while (i < request.messages.len) : (i += 1) {
        if (comma) try writer.writeByte(',');
        comma = true;
        const message = request.messages[i];
        if (kind == .anthropic) {
            try writer.print("{{\"role\":\"{s}\",\"content\":[", .{if (message.role == .tool) "user" else @tagName(message.role)});
            if (message.role == .tool) {
                var result_index: usize = 0;
                while (i < request.messages.len and request.messages[i].role == .tool) : (i += 1) {
                    const result = request.messages[i];
                    if (result_index != 0) try writer.writeByte(',');
                    try writer.writeAll("{\"type\":\"tool_result\",\"tool_use_id\":\"");
                    try writeJsonString(writer, result.tool_call_id.?);
                    try writer.writeAll("\",\"content\":[{\"type\":\"text\",\"text\":\"");
                    try writeJsonString(writer, result.content);
                    try writer.writeAll("\"}");
                    for (result.images) |reference| {
                        try writer.writeByte(',');
                        try writeAnthropicImage(writer, reference);
                    }
                    try writer.print("],\"is_error\":{s}}}", .{if (toolResultIsError(result.content)) "true" else "false"});
                    result_index += 1;
                }
                i -= 1;
            } else {
                var block_comma = false;
                if (message.content.len != 0 or message.tool_calls.len == 0) {
                    try writer.writeAll("{\"type\":\"text\",\"text\":\"");
                    try writeJsonString(writer, message.content);
                    try writer.writeAll("\"}");
                    block_comma = true;
                }
                for (message.images) |reference| {
                    if (block_comma) try writer.writeByte(',');
                    block_comma = true;
                    try writeAnthropicImage(writer, reference);
                }
                for (message.tool_calls) |call| {
                    if (block_comma) try writer.writeByte(',');
                    block_comma = true;
                    try writer.writeAll("{\"type\":\"tool_use\",\"id\":\"");
                    try writeJsonString(writer, call.id);
                    try writer.writeAll("\",\"name\":\"");
                    try writeJsonString(writer, call.name);
                    try writer.writeAll("\",\"input\":");
                    try writeArgumentObject(writer, call.arguments);
                    try writer.writeByte('}');
                }
            }
            try writer.writeAll("]}");
        } else {
            try writer.print("{{\"role\":\"{s}\",\"content\":\"", .{@tagName(message.role)});
            try writeJsonString(writer, message.content);
            try writer.writeByte('"');
            if (message.images.len != 0) {
                try writer.writeAll(",\"images\":[");
                for (message.images, 0..) |reference, image_index| {
                    if (image_index != 0) try writer.writeByte(',');
                    try writer.writeByte('"');
                    try writeBase64(writer, (reference.content() orelse return error.EmptyAttachmentResult).bytes);
                    try writer.writeByte('"');
                }
                try writer.writeByte(']');
            }
            if (message.role == .tool) {
                const call = correlatedCall(request.messages[0..i], message.tool_call_id.?) orelse return error.InvalidToolMessage;
                try writer.writeAll(",\"tool_name\":\"");
                try writeJsonString(writer, call.name);
                try writer.writeAll("\",\"tool_call_id\":\"");
                try writeJsonString(writer, call.id);
                try writer.writeByte('"');
            }
            if (message.tool_calls.len != 0) {
                try writer.writeAll(",\"tool_calls\":[");
                for (message.tool_calls, 0..) |call, index| {
                    if (index != 0) try writer.writeByte(',');
                    try writer.writeAll("{\"id\":\"");
                    try writeJsonString(writer, call.id);
                    try writer.writeAll("\",\"type\":\"function\",\"function\":{");
                    try writer.print("\"index\":{d},\"name\":\"", .{index});
                    try writeJsonString(writer, call.name);
                    try writer.writeAll("\",\"arguments\":");
                    try writeArgumentObject(writer, call.arguments);
                    try writer.writeAll("}}");
                }
                try writer.writeByte(']');
            }
            try writer.writeByte('}');
        }
    }
    try writer.writeByte(']');
    if (request.tools.len != 0) {
        try writer.writeAll(",\"tools\":[");
        for (request.tools, 0..) |definition, index| {
            if (index != 0) try writer.writeByte(',');
            try writeToolDefinition(writer, definition, kind);
        }
        try writer.writeByte(']');
    }
    try writer.writeByte('}');
}

fn correlatedCall(messages: []const provider.Message, id: []const u8) ?provider.ToolCall {
    var i = messages.len;
    while (i != 0) {
        i -= 1;
        for (messages[i].tool_calls) |call| if (std.mem.eql(u8, call.id, id)) return call;
    }
    return null;
}

fn writeArgumentObject(writer: *std.Io.Writer, arguments: []const u8) !void {
    const trimmed = std.mem.trim(u8, arguments, " \t\r\n");
    var storage: [4096]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&storage);
    if (trimmed.len == 0 or trimmed[0] != '{' or !(std.json.validate(fixed.allocator(), trimmed) catch false)) return error.InvalidToolArguments;
    try writer.writeAll(trimmed);
}

/// Read structural status tokens; output text containing the word "failed"
/// must not turn a successful command into a protocol error.
fn toolResultIsError(content: []const u8) bool {
    var storage: [4096]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&storage);
    var scanner = std.json.Scanner.initCompleteInput(fixed.allocator(), content);
    defer scanner.deinit();
    const Object = struct { is_object: bool, key: bool = true, status: bool = false, err: bool = false };
    var stack: [128]Object = undefined;
    var depth: usize = 0;
    while (true) {
        const token = scanner.next() catch return false;
        switch (token) {
            .end_of_document => return false,
            .object_begin, .array_begin => {
                if (depth != 0 and stack[depth - 1].is_object) {
                    if (stack[depth - 1].err) return true;
                    stack[depth - 1].key = true;
                }
                if (depth == stack.len) return false;
                stack[depth] = .{ .is_object = token == .object_begin };
                depth += 1;
            },
            .object_end, .array_end => if (depth != 0) {
                depth -= 1;
            },
            .string => |value| {
                if (depth == 0 or !stack[depth - 1].is_object) continue;
                const object = &stack[depth - 1];
                if (object.key) {
                    object.status = std.mem.eql(u8, value, "status");
                    object.err = std.mem.eql(u8, value, "error");
                    object.key = false;
                } else {
                    if (object.err and value.len != 0) return true;
                    if (object.status and (std.mem.eql(u8, value, "failed") or std.mem.eql(u8, value, "rejected") or std.mem.eql(u8, value, "cancelled") or std.mem.eql(u8, value, "timed_out") or std.mem.eql(u8, value, "unknown") or std.mem.eql(u8, value, "skipped"))) return true;
                    object.key = true;
                }
            },
            .partial_string, .partial_string_escaped_1, .partial_string_escaped_2, .partial_string_escaped_3, .partial_string_escaped_4 => {},
            else => if (depth != 0 and stack[depth - 1].is_object) {
                stack[depth - 1].key = true;
            },
        }
    }
}

fn hasToolFields(request: provider.ChatRequest) bool {
    if (request.tools.len != 0) return true;
    for (request.messages) |message| if (message.role == .tool or message.tool_calls.len != 0 or message.tool_call_id != null) return true;
    return false;
}

fn validCallId(value: []const u8) bool {
    return value.len != 0 and value.len <= provider.max_tool_call_id_bytes and std.mem.indexOfScalar(u8, value, 0) == null;
}

pub fn validateToolMessages(request: provider.ChatRequest) !void {
    if (request.tools.len > provider.max_tool_definitions) return error.InvalidToolDefinition;
    for (request.tools, 0..) |definition, definition_index| {
        if (definition.session_ids.len == 0 or definition.session_ids.len > @import("tool_scope.zig").max_targets) return error.InvalidToolDefinition;
        for (request.tools[0..definition_index]) |previous| if (std.mem.eql(u8, previous.name(), definition.name())) return error.InvalidToolDefinition;
        if (definition.dynamic) |dynamic| {
            var encoded: [64]u8 = undefined;
            if (!std.mem.eql(u8, try @import("plugin_tools.zig").encodeName(&encoded, dynamic.id), dynamic.name)) return error.InvalidToolDefinition;
            try @import("plugin_tools.zig").validateDefinition(.{ .id = dynamic.id, .description = dynamic.description, .schema = dynamic.schema });
        }
        for (definition.session_ids, 0..) |id, index| {
            if (id == 0 or std.mem.indexOfScalar(u64, definition.session_ids[0..index], id) != null) return error.InvalidToolDefinition;
        }
    }
    var pending: [provider.max_tool_calls][]const u8 = undefined;
    var received: [provider.max_tool_calls]bool = @splat(false);
    var count: usize = 0;
    var remaining: usize = 0;
    for (request.messages) |message| {
        if (message.tool_calls.len > provider.max_tool_calls) return error.InvalidToolCall;
        if (message.role != .assistant and message.tool_calls.len != 0) return error.InvalidToolMessage;
        if (message.role == .tool) {
            const id = message.tool_call_id orelse return error.InvalidToolMessage;
            if (!validCallId(id) or remaining == 0) return error.InvalidToolMessage;
            var found = false;
            for (pending[0..count], 0..) |original, index| {
                if (!std.mem.eql(u8, id, original)) continue;
                if (received[index]) return error.InvalidToolMessage;
                received[index] = true;
                remaining -= 1;
                found = true;
                break;
            }
            if (!found) return error.InvalidToolMessage;
            continue;
        }
        if (message.tool_call_id != null or remaining != 0) return error.InvalidToolMessage;
        count = message.tool_calls.len;
        remaining = count;
        received = @splat(false);
        for (message.tool_calls, 0..) |call, index| {
            if (!validCallId(call.id) or call.name.len == 0 or call.name.len > provider.max_tool_name_bytes or call.arguments.len > provider.max_tool_arguments_bytes) return error.InvalidToolCall;
            for (call.name) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '_' and byte != '-') return error.InvalidToolCall;
            for (pending[0..index]) |earlier| if (std.mem.eql(u8, earlier, call.id)) return error.InvalidToolCall;
            pending[index] = call.id;
        }
    }
    if (remaining != 0) return error.InvalidToolMessage;
}

fn writeToolDefinition(writer: *std.Io.Writer, definition: provider.ToolDefinition, kind: registry.Kind) !void {
    if (definition.dynamic) |dynamic| {
        if (kind == .anthropic) try writer.writeAll("{\"name\":\"") else try writer.writeAll("{\"type\":\"function\",\"function\":{\"name\":\"");
        try writeJsonString(writer, dynamic.name);
        try writer.writeAll("\",\"description\":\"");
        try writeJsonString(writer, dynamic.description);
        try writer.writeAll(if (kind == .anthropic) "\",\"input_schema\":" else "\",\"parameters\":");
        try writer.writeAll(dynamic.schema);
        try writer.writeAll(if (kind == .anthropic) "}" else "}}");
        return;
    }
    if (kind == .anthropic) {
        try writer.print("{{\"name\":\"{s}\",\"description\":\"", .{@tagName(definition.tool)});
    } else try writer.print("{{\"type\":\"function\",\"function\":{{\"name\":\"{s}\",\"description\":\"", .{@tagName(definition.tool)});
    try writeJsonString(writer, switch (definition.tool) {
        .run_command => "Execute an explicit command through each session's independent exec service. The host validates permissions, captured identity and limits; never type into the interactive terminal.",
        .read_terminal => "Read bounded recent plain terminal output from the specified sessions. Does not execute a command.",
        .list_remote_files => "List a bounded, nonrecursive remote directory through the session's remote file service. Local filesystem paths are not supported.",
        .read_remote_file => "Read a bounded text prefix from a remote file through the session's remote file service. Local filesystem paths are not supported.",
    });
    try writer.writeAll(if (kind == .anthropic) "\",\"input_schema\":" else "\",\"parameters\":");
    try writer.writeAll("{\"type\":\"object\",\"additionalProperties\":false,\"properties\":{\"session_ids\":{\"type\":\"array\",\"minItems\":1,\"maxItems\":");
    try writer.print("{d}", .{definition.session_ids.len});
    try writer.writeAll(",\"uniqueItems\":true,\"items\":{\"type\":\"integer\",\"enum\":[");
    for (definition.session_ids, 0..) |id, index| {
        if (index != 0) try writer.writeByte(',');
        try writer.print("{d}", .{id});
    }
    try writer.writeAll("]}}");
    switch (definition.tool) {
        .run_command => try writer.writeAll(",\"command\":{\"type\":\"string\",\"minLength\":1}"),
        .read_terminal => {},
        .list_remote_files, .read_remote_file => try writer.writeAll(",\"path\":{\"type\":\"string\",\"minLength\":1,\"pattern\":\"^/\"}"),
    }
    if (definition.tool == .read_remote_file) try writer.writeAll(",\"max_bytes\":{\"type\":\"integer\",\"minimum\":1,\"maximum\":65536,\"default\":4096}");
    try writer.writeAll("},\"required\":[\"session_ids\"");
    switch (definition.tool) {
        .run_command => try writer.writeAll(",\"command\""),
        .read_terminal => {},
        .list_remote_files, .read_remote_file => try writer.writeAll(",\"path\""),
    }
    try writer.writeAll(if (kind == .anthropic) "]}}" else "]}}}");
}

fn systemAllowed(kind: registry.Kind) bool {
    return kind == .ollama;
}
fn writeJsonString(writer: *std.Io.Writer, value: []const u8) !void {
    if (!std.unicode.utf8ValidateSlice(value)) return error.InvalidUtf8;
    for (value) |byte| switch (byte) {
        '"' => try writer.writeAll("\\\""),
        '\\' => try writer.writeAll("\\\\"),
        '\n' => try writer.writeAll("\\n"),
        '\r' => try writer.writeAll("\\r"),
        '\t' => try writer.writeAll("\\t"),
        else => if (byte < 0x20) try writer.print("\\u{X:0>4}", .{@as(u16, byte)}) else try writer.writeByte(byte),
    };
}

test "request plan requires TLS except explicit loopback gateway" {
    const openai = try plan(provider_config.defaults(.openai_compat));
    try std.testing.expectEqual(AuthStyle.bearer, openai.auth_style);
    try std.testing.expectEqualStrings("", openai.api_key.?);
    const ollama = try plan(provider_config.defaults(.ollama));
    try std.testing.expectEqual(AuthStyle.none, ollama.auth_style);
    var insecure = provider_config.defaults(.openai_compat);
    insecure.endpoint = "http://example.test/v1/chat";
    try std.testing.expectError(error.InsecureEndpoint, plan(insecure));
}

test "request body clamps output and escapes JSON" {
    const messages = [_]provider.Message{.{ .content = "say \"hi\"" }};
    const body = try requestBody(std.testing.allocator, .openai_compat, .{ .model = "m", .effort = .high, .system = "sys", .messages = &messages, .max_output = 9000 }, 4096);
    defer std.testing.allocator.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "\\\"hi\\\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"max_tokens\":1024") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"reasoning_effort\":\"high\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"role\":\"system\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\",\"system\":") == null);
    const ollama_body = try requestBody(std.testing.allocator, .ollama, .{ .model = "m", .system = "sys", .messages = &messages }, 4096);
    defer std.testing.allocator.free(ollama_body);
    try std.testing.expect(std.mem.indexOf(u8, ollama_body, "\"role\":\"system\",\"content\":\"sys\"") != null);
}

test "request body omits unspecified effort and encodes explicit high" {
    const allocator = std.testing.allocator;
    const unspecified = try requestBody(allocator, .openai_compat, .{ .model = "quiet", .system = "", .messages = &.{} }, 8192);
    defer allocator.free(unspecified);
    const without_effort = try std.json.parseFromSlice(std.json.Value, allocator, unspecified, .{});
    defer without_effort.deinit();
    try std.testing.expect(without_effort.value.object.get("reasoning_effort") == null);
    try std.testing.expectEqualStrings("quiet", without_effort.value.object.get("model").?.string);
    const explicit = try requestBody(allocator, .openai_compat, .{ .model = "reasoner", .effort = .high, .system = "", .messages = &.{} }, 8192);
    defer allocator.free(explicit);
    const with_effort = try std.json.parseFromSlice(std.json.Value, allocator, explicit, .{});
    defer with_effort.deinit();
    try std.testing.expectEqualStrings("high", with_effort.value.object.get("reasoning_effort").?.string);
    try std.testing.expectEqualStrings("reasoner", with_effort.value.object.get("model").?.string);
}

test "retry-after parses seconds with overflow protection" {
    try std.testing.expectEqual(@as(?u32, 1000), parseRetryAfter(" 1 "));
    try std.testing.expectEqual(@as(?u32, null), parseRetryAfter("invalid"));
    try std.testing.expectEqual(@as(?u32, std.math.maxInt(u32)), parseRetryAfter("4294967295"));
}

test "response classifies retryable HTTP statuses" {
    try std.testing.expectEqual(ResponseKind.retryable, response(429, 1200).kind);
    try std.testing.expectEqual(@as(?u32, 1200), response(429, 1200).retry_after_ms);
    try std.testing.expectEqual(ResponseKind.provider_error, response(401, null).kind);
}

test "OpenAI tool declarations contain separate bounded capability and argument schemas" {
    const definitions = [_]provider.ToolDefinition{
        .{ .tool = .run_command, .session_ids = &.{101} },
        .{ .tool = .read_terminal, .session_ids = &.{ 101, 102 } },
        .{ .tool = .list_remote_files, .session_ids = &.{102} },
        .{ .tool = .read_remote_file, .session_ids = &.{102} },
    };
    const body = try requestBody(std.testing.allocator, .openai_compat, .{ .model = "m", .system = "", .messages = &.{}, .tools = &definitions }, 8192);
    defer std.testing.allocator.free(body);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, body, .{});
    defer parsed.deinit();
    const tools = parsed.value.object.get("tools").?.array.items;
    try std.testing.expectEqual(@as(usize, 4), tools.len);
    for (tools, definitions) |tool, definition| {
        try std.testing.expectEqualStrings("function", tool.object.get("type").?.string);
        const function = tool.object.get("function").?.object;
        try std.testing.expectEqualStrings(@tagName(definition.tool), function.get("name").?.string);
        const parameters = function.get("parameters").?.object;
        try std.testing.expectEqualStrings("object", parameters.get("type").?.string);
        try std.testing.expect(!parameters.get("additionalProperties").?.bool);
        const properties = parameters.get("properties").?.object;
        const targets = properties.get("session_ids").?.object;
        try std.testing.expectEqual(@as(i64, 1), targets.get("minItems").?.integer);
        try std.testing.expectEqual(@as(i64, @intCast(definition.session_ids.len)), targets.get("maxItems").?.integer);
        try std.testing.expect(targets.get("uniqueItems").?.bool);
        const ids = targets.get("items").?.object.get("enum").?.array.items;
        try std.testing.expectEqual(definition.session_ids.len, ids.len);
        for (ids, definition.session_ids) |encoded, id| try std.testing.expectEqual(@as(i64, @intCast(id)), encoded.integer);
        const required = parameters.get("required").?.array.items;
        try std.testing.expectEqualStrings("session_ids", required[0].string);
        switch (definition.tool) {
            .run_command => {
                try std.testing.expectEqual(@as(usize, 2), properties.count());
                try std.testing.expectEqualStrings("command", required[1].string);
                try std.testing.expect(properties.get("path") == null and properties.get("max_bytes") == null);
            },
            .read_terminal => {
                try std.testing.expectEqual(@as(usize, 1), properties.count());
                try std.testing.expectEqual(@as(usize, 1), required.len);
            },
            .list_remote_files, .read_remote_file => {
                try std.testing.expectEqualStrings("path", required[1].string);
                try std.testing.expectEqualStrings("^/", properties.get("path").?.object.get("pattern").?.string);
                if (definition.tool == .read_remote_file) {
                    const cap = properties.get("max_bytes").?.object;
                    try std.testing.expectEqual(@as(i64, 1), cap.get("minimum").?.integer);
                    try std.testing.expectEqual(@as(i64, 65536), cap.get("maximum").?.integer);
                    try std.testing.expectEqual(@as(i64, 4096), cap.get("default").?.integer);
                } else try std.testing.expect(properties.get("max_bytes") == null);
            },
        }
    }
}

test "OpenAI assistant calls and correlated tool results round trip exact wire strings" {
    const calls = [_]provider.ToolCall{
        .{ .id = "call-\"1", .name = "run_command", .arguments = "{\"session_ids\":[101],\"command\":\"printf \\\"你好\\\"\"}" },
        .{ .id = "call-2", .name = "read_terminal", .arguments = "{\"session_ids\":[101]}" },
    };
    const output = "stdout:\x00\x1b[31m\"你好\"\n\tstderr:\r\x08\x0c";
    const messages = [_]provider.Message{
        .{ .content = "Read the real result" },
        .{ .role = .assistant, .content = "", .tool_calls = &calls },
        .{ .role = .tool, .content = output, .tool_call_id = calls[0].id },
        .{ .role = .tool, .content = "terminal context", .tool_call_id = calls[1].id },
    };
    const body = try requestBody(std.testing.allocator, .openai_compat, .{ .model = "m", .system = "scope", .messages = &messages }, 8192);
    defer std.testing.allocator.free(body);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, body, .{});
    defer parsed.deinit();
    const encoded = parsed.value.object.get("messages").?.array.items;
    try std.testing.expectEqual(@as(usize, 5), encoded.len);
    try std.testing.expectEqualStrings("system", encoded[0].object.get("role").?.string);
    try std.testing.expectEqualStrings("assistant", encoded[2].object.get("role").?.string);
    const tool_calls = encoded[2].object.get("tool_calls").?.array.items;
    for (tool_calls, calls) |actual, original| {
        try std.testing.expectEqualStrings(original.id, actual.object.get("id").?.string);
        try std.testing.expectEqualStrings("function", actual.object.get("type").?.string);
        const function = actual.object.get("function").?.object;
        try std.testing.expectEqualStrings(original.name, function.get("name").?.string);
        try std.testing.expectEqualStrings(original.arguments, function.get("arguments").?.string);
    }
    try std.testing.expectEqualStrings("tool", encoded[3].object.get("role").?.string);
    try std.testing.expectEqualStrings(calls[0].id, encoded[3].object.get("tool_call_id").?.string);
    try std.testing.expectEqualStrings(output, encoded[3].object.get("content").?.string);
    try std.testing.expectEqualStrings(calls[1].id, encoded[4].object.get("tool_call_id").?.string);
}

test "unknown calls and invalid original argument JSON remain data for rejection feedback" {
    const calls = [_]provider.ToolCall{.{ .id = "original-id", .name = "spawn_agent", .arguments = "{broken JSON" }};
    const messages = [_]provider.Message{
        .{ .role = .assistant, .content = "", .tool_calls = &calls },
        .{ .role = .tool, .content = "{\"error\":\"UnsupportedTool\"}", .tool_call_id = "original-id" },
    };
    const body = try requestBody(std.testing.allocator, .openai_compat, .{ .model = "m", .system = "", .messages = &messages }, 8192);
    defer std.testing.allocator.free(body);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, body, .{});
    defer parsed.deinit();
    const encoded = parsed.value.object.get("messages").?.array.items;
    const call = encoded[0].object.get("tool_calls").?.array.items[0].object;
    try std.testing.expectEqualStrings("spawn_agent", call.get("function").?.object.get("name").?.string);
    try std.testing.expectEqualStrings("{broken JSON", call.get("function").?.object.get("arguments").?.string);
    try std.testing.expectEqualStrings("original-id", encoded[1].object.get("tool_call_id").?.string);
    try std.testing.expect(parsed.value.object.get("tools") == null);
}

test "native tool protocols encode their actual request shapes" {
    const tools = [_]provider.ToolDefinition{.{ .tool = .run_command, .session_ids = &.{101} }};
    const calls = [_]provider.ToolCall{.{ .id = "original", .name = "run_command", .arguments = "{\"session_ids\":[101],\"command\":\"pwd\"}" }};
    const messages = [_]provider.Message{
        .{ .role = .assistant, .content = "checking", .tool_calls = &calls },
        .{ .role = .tool, .content = "{\"error\":\"Denied\"}", .tool_call_id = "original" },
    };
    for ([_]registry.Kind{ .anthropic, .ollama }) |kind| {
        const body = try requestBody(std.testing.allocator, kind, .{ .model = "m", .system = "scope", .messages = &messages, .tools = &tools }, 8192);
        defer std.testing.allocator.free(body);
        const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, body, .{});
        defer parsed.deinit();
        const root = parsed.value.object;
        const encoded = root.get("messages").?.array.items;
        const definition = root.get("tools").?.array.items[0].object;
        if (kind == .anthropic) {
            try std.testing.expectEqualStrings("scope", root.get("system").?.string);
            try std.testing.expect(definition.get("input_schema") != null and definition.get("function") == null);
            const call = encoded[0].object.get("content").?.array.items[1].object;
            try std.testing.expectEqualStrings("tool_use", call.get("type").?.string);
            try std.testing.expectEqualStrings("original", call.get("id").?.string);
            try std.testing.expect(call.get("input").? == .object);
            const result = encoded[1].object.get("content").?.array.items[0].object;
            try std.testing.expectEqualStrings("tool_result", result.get("type").?.string);
            try std.testing.expectEqualStrings("original", result.get("tool_use_id").?.string);
            try std.testing.expect(result.get("is_error").?.bool);
        } else {
            try std.testing.expect(root.get("max_tokens") == null and root.get("system") == null);
            try std.testing.expect(root.get("options").?.object.get("num_predict") != null);
            try std.testing.expectEqualStrings("system", encoded[0].object.get("role").?.string);
            const call = encoded[1].object.get("tool_calls").?.array.items[0].object;
            try std.testing.expectEqualStrings("original", call.get("id").?.string);
            try std.testing.expect(call.get("function").?.object.get("arguments").? == .object);
            try std.testing.expectEqualStrings("run_command", encoded[2].object.get("tool_name").?.string);
        }
    }
}

test "tool declaration validation rejects duplicate empty zero and excessive target scopes" {
    const invalid_ids = [_][]const u64{ &.{}, &.{0}, &.{ 101, 101 }, &@as([17]u64, @splat(101)) };
    for (invalid_ids) |ids| {
        const tools = [_]provider.ToolDefinition{.{ .tool = .run_command, .session_ids = ids }};
        try std.testing.expectError(error.InvalidToolDefinition, requestBody(std.testing.allocator, .openai_compat, .{ .model = "m", .system = "", .messages = &.{}, .tools = &tools }, 8192));
    }
    const duplicate = [_]provider.ToolDefinition{
        .{ .tool = .run_command, .session_ids = &.{101} },
        .{ .tool = .run_command, .session_ids = &.{102} },
    };
    try std.testing.expectError(error.InvalidToolDefinition, requestBody(std.testing.allocator, .openai_compat, .{ .model = "m", .system = "", .messages = &.{}, .tools = &duplicate }, 8192));
    const excessive: [5]provider.ToolDefinition = @splat(.{ .tool = .run_command, .session_ids = &.{101} });
    try std.testing.expectError(error.InvalidToolDefinition, requestBody(std.testing.allocator, .openai_compat, .{ .model = "m", .system = "", .messages = &.{}, .tools = &excessive }, 8192));
}

test "tool message correlation rejects orphan duplicate missing and interrupted result slots" {
    const calls = [_]provider.ToolCall{.{ .id = "c", .name = "run_command", .arguments = "{}" }};
    const assistant: provider.Message = .{ .role = .assistant, .content = "", .tool_calls = &calls };
    const result: provider.Message = .{ .role = .tool, .content = "result", .tool_call_id = "c" };
    const invalid = [_][]const provider.Message{
        &.{result},
        &.{assistant},
        &.{ assistant, .{ .content = "interrupt" } },
        &.{ assistant, .{ .role = .tool, .content = "missing ID" } },
        &.{ assistant, .{ .role = .tool, .content = "wrong ID", .tool_call_id = "other" } },
        &.{ assistant, result, result },
        &.{.{ .content = "user call", .tool_calls = &calls }},
        &.{.{ .role = .assistant, .content = "wrong role", .tool_call_id = "c" }},
    };
    for (invalid) |messages| try std.testing.expectError(error.InvalidToolMessage, requestBody(std.testing.allocator, .openai_compat, .{ .model = "m", .system = "", .messages = messages }, 8192));
}

test "tool calls enforce identity name argument and count bounds without truncation" {
    const long_id: [provider.max_tool_call_id_bytes + 1]u8 = @splat('i');
    const long_name: [provider.max_tool_name_bytes + 1]u8 = @splat('n');
    const long_args: [provider.max_tool_arguments_bytes + 1]u8 = @splat('a');
    const invalid_calls = [_]provider.ToolCall{
        .{ .id = "", .name = "run_command", .arguments = "{}" },
        .{ .id = "bad\x00id", .name = "run_command", .arguments = "{}" },
        .{ .id = &long_id, .name = "run_command", .arguments = "{}" },
        .{ .id = "c", .name = "", .arguments = "{}" },
        .{ .id = "c", .name = "bad name", .arguments = "{}" },
        .{ .id = "c", .name = &long_name, .arguments = "{}" },
        .{ .id = "c", .name = "run_command", .arguments = &long_args },
    };
    for (invalid_calls) |call| {
        const messages = [_]provider.Message{.{ .role = .assistant, .content = "", .tool_calls = &.{call} }};
        try std.testing.expectError(error.InvalidToolCall, requestBody(std.testing.allocator, .openai_compat, .{ .model = "m", .system = "", .messages = &messages }, 8192));
    }
    const call: provider.ToolCall = .{ .id = "c", .name = "run_command", .arguments = "{}" };
    for ([_]usize{ 2, 17 }) |count| {
        const calls: [17]provider.ToolCall = @splat(call);
        const messages = [_]provider.Message{.{ .role = .assistant, .content = "", .tool_calls = calls[0..count] }};
        try std.testing.expectError(error.InvalidToolCall, requestBody(std.testing.allocator, .openai_compat, .{ .model = "m", .system = "", .messages = &messages }, 8192));
    }
}

test "bounded tool body retains a full escaped 64 KiB result and rejects an excessive whole request" {
    const output = try std.testing.allocator.alloc(u8, 64 * 1024);
    defer std.testing.allocator.free(output);
    @memset(output, 0x1b);
    const calls = [_]provider.ToolCall{.{ .id = "c", .name = "run_command", .arguments = "{}" }};
    const messages = [_]provider.Message{
        .{ .role = .assistant, .content = "", .tool_calls = &calls },
        .{ .role = .tool, .content = output, .tool_call_id = "c" },
    };
    const body = try requestBody(std.testing.allocator, .openai_compat, .{ .model = "m", .system = "", .messages = &messages }, 32768);
    defer std.testing.allocator.free(body);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, body, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings(output, parsed.value.object.get("messages").?.array.items[1].object.get("content").?.string);
    const huge = try std.testing.allocator.alloc(u8, max_tool_request_bytes);
    defer std.testing.allocator.free(huge);
    @memset(huge, 'x');
    const tools = [_]provider.ToolDefinition{.{ .tool = .run_command, .session_ids = &.{101} }};
    try std.testing.expectError(error.ToolRequestTooLarge, requestBody(std.testing.allocator, .openai_compat, .{ .model = "m", .system = "", .messages = &.{.{ .content = huge }}, .tools = &tools }, 32768));
}

fn hasImages(request: provider.ChatRequest) bool {
    for (request.messages) |message| if (message.images.len != 0) return true;
    return false;
}
fn writeBase64(writer: *std.Io.Writer, bytes: []const u8) !void {
    // Fixed multiples of three preserve base64 grouping across chunks.
    var encoded: [4096]u8 = undefined;
    var remaining = bytes;
    while (remaining.len != 0) {
        const n = @min(remaining.len, 3072);
        try writer.writeAll(std.base64.standard.Encoder.encode(&encoded, remaining[0..n]));
        remaining = remaining[n..];
    }
}

test "loopback HTTP gateway retains its configured protocol and rejects authority prefix tricks" {
    for ([_]registry.Kind{ .anthropic, .openai_compat, .ollama }) |kind| {
        var config = provider_config.defaults(kind);
        for ([_][]const u8{ "http://127.0.0.1:8080/v1/messages", "http://localhost:8080/api/chat", "http://[::1]:8080/chat" }) |endpoint| {
            config.endpoint = endpoint;
            const actual = try plan(config);
            try std.testing.expectEqualStrings(endpoint, actual.endpoint);
            if (kind == .anthropic) try std.testing.expectEqual(AuthStyle.anthropic_key, actual.auth_style);
            if (kind == .ollama) try std.testing.expectEqualStrings("application/x-ndjson", actual.accept);
        }
        for ([_][]const u8{ "http://localhost.evil.test/chat", "http://127.0.0.10/chat", "http://localhost@evil.test/chat", "http://evil.test/chat" }) |endpoint| {
            config.endpoint = endpoint;
            try std.testing.expectError(error.InsecureEndpoint, plan(config));
        }
    }
}

test "native transcript refuses invalid JSON objects and reports structural failure status only" {
    const messages = [_]provider.Message{
        .{ .role = .assistant, .content = "", .tool_calls = &.{.{ .id = "bad", .name = "unknown_tool", .arguments = "{partial" }} },
        .{ .role = .tool, .content = "rejected", .tool_call_id = "bad" },
    };
    for ([_]registry.Kind{ .anthropic, .ollama }) |kind| try std.testing.expectError(error.InvalidToolArguments, requestBodySize(kind, .{ .model = "m", .system = "", .messages = &messages }, 8192));
    try std.testing.expect(toolResultIsError("{\"status\":\"rejected\",\"error_code\":\"Denied\"}"));
    try std.testing.expect(toolResultIsError("{\"targets\":[{\"stdout\":\"x\",\"status\":\"failed\"}]}"));
    try std.testing.expect(!toolResultIsError("{\"targets\":[{\"stdout\":\"status\",\"stderr\":\"error\",\"status\":\"succeeded\"}]}"));
    try std.testing.expect(!toolResultIsError("{\"targets\":[{\"status\":\"succeeded\",\"stdout\":\"failed\"}]}"));
}

test "native adapters reject effort rather than silently dropping an unsupported setting" {
    for ([_]registry.Kind{ .anthropic, .ollama }) |kind| for (std.enums.values(provider.Effort)) |effort| {
        try std.testing.expectError(error.UnsupportedEffort, requestBodySize(kind, .{ .model = "m", .system = "", .messages = &.{}, .effort = effort }, 8192));
    };
}

test "model reasoning controls serialize exact effort and provider toggle protocols" {
    const a = std.testing.allocator;
    const mi = try requestBody(a, .openai_compat, .{ .model = "mimo-v2.6-pro", .system = "", .messages = &.{}, .thinking = false, .reasoning_wire = .thinking_type }, 8192);
    defer a.free(mi);
    try std.testing.expect(std.mem.indexOf(u8, mi, "\"thinking\":{\"type\":\"disabled\"}") != null);
    const routed = try requestBody(a, .openai_compat, .{ .model = "xiaomi/mimo-v2.6-pro", .system = "", .messages = &.{}, .thinking = true, .reasoning_wire = .openrouter }, 8192);
    defer a.free(routed);
    try std.testing.expect(std.mem.indexOf(u8, routed, "\"reasoning\":{\"enabled\":true}") != null);
    const effort = try requestBody(a, .openai_compat, .{ .model = "m", .system = "", .messages = &.{}, .effort = .max }, 8192);
    defer a.free(effort);
    try std.testing.expect(std.mem.indexOf(u8, effort, "\"reasoning_effort\":\"max\"") != null);
    const local = try requestBody(a, .ollama, .{ .model = "m", .system = "", .messages = &.{}, .native_effort = true, .effort = .medium }, 8192);
    defer a.free(local);
    try std.testing.expect(std.mem.indexOf(u8, local, "\"think\":\"medium\"") != null);
    try std.testing.expectError(error.UnsupportedThinking, requestBody(a, .openai_compat, .{ .model = "m", .system = "", .messages = &.{}, .thinking = false }, 8192));
}

fn writeAnthropicImage(writer: *std.Io.Writer, reference: @import("image_attachments.zig").ContentRef) !void {
    const image = reference.content() orelse return error.EmptyAttachmentResult;
    try writer.print("{{\"type\":\"image\",\"source\":{{\"type\":\"base64\",\"media_type\":\"{s}\",\"data\":\"", .{image.mime.name()});
    try writeBase64(writer, image.bytes);
    try writer.writeAll("\"}}");
}

test "explicit gateway none and ultra effort names survive serialization" {
    const a = std.testing.allocator;
    for ([_]provider.Effort{ .none, .ultra }) |effort| {
        const body = try requestBody(a, .openai_compat, .{ .model = "declared-gateway-model", .system = "", .messages = &.{}, .native_effort = true, .effort = effort }, 8192);
        defer a.free(body);
        const parsed = try std.json.parseFromSlice(std.json.Value, a, body, .{});
        defer parsed.deinit();
        try std.testing.expectEqualStrings(@tagName(effort), parsed.value.object.get("reasoning_effort").?.string);
    }
}
