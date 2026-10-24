//! Explicitly opt-in production-client acceptance. All model content is a
//! synthetic geometric image; authentication remains exclusively in headers.
const std = @import("std");
const tools = @import("plugin_tools.zig");
const provider = @import("provider.zig");
const transport = @import("provider_transport.zig");
const http = @import("provider_http.zig");
const trace = @import("tool_trace.zig");
const scope = @import("tool_scope.zig");
const Loop = @import("tool_loop.zig");
const png = "\x89\x50\x4e\x47\x0d\x0a\x1a\x0a\x00\x00\x00\x0d\x49\x48\x44\x52\x00\x00\x00\x80\x00\x00\x00\x60\x08\x06\x00\x00\x00\xd5\x7a\x7a" ++
    "\x49\x00\x00\x01\x87\x49\x44\x41\x54\x78\x9c\xed\xd2\xc1\x09\x00\x21\x10\x04\xc1\xcd\x3f\x69\x0d\xe2\x90\x52\xae\x69\xfc\xcb\x4e" ++
    "\xcd\x9a\x59\x7f\x7e\x75\xc1\x08\x01\xa0\xf9\x11\x02\x40\xf3\x23\x04\x80\xe6\x47\x08\x00\xcd\x8f\x10\x00\x9a\x1f\x21\x00\x34\x3f" ++
    "\x42\x00\x68\x7e\x84\x00\xd0\xfc\x08\x01\xa0\xf9\x11\x02\x40\xf3\x23\x04\x80\xe6\x47\x08\x00\xcd\x8f\x10\x00\x9a\x1f\x21\x00\x34" ++
    "\x3f\x42\x00\x68\x7e\x84\x00\xd0\xfc\x08\x01\xa0\xf9\x11\x02\x40\xf3\x23\x04\x80\xe6\x47\x08\x00\xcd\x8f\x10\x00\x9a\x1f\x21\x00" ++
    "\x34\x3f\x42\x00\x68\x7e\x84\x00\xd0\xfc\x08\x01\xa0\xf9\x11\x02\x40\xf3\x23\x04\x80\xe6\x47\x08\x00\xcd\x8f\x10\x00\x9a\x1f\x21" ++
    "\x00\x34\x3f\x42\x00\x68\x7e\x84\x4f\x03\xea\x2f\xbc\x9f\xbe\x60\x00\x02\x10\x80\x00\x04\x20\x00\x01\x08\x40\x00\x02\x10\x80\x00" ++
    "\x04\x20\x00\x01\x08\x40\x00\x02\x10\x80\x00\x04\x20\x00\x01\x08\x40\x00\x02\x10\x80\x00\x04\x20\x00\x01\x08\x40\x00\x02\x10\x80" ++
    "\x00\x04\x20\x00\x01\x08\xc0\x05\xdf\x7f\x3f\x7d\xc1\x00\x04\x20\x00\x01\x08\x40\x00\x02\x10\x80\x00\x04\x20\x00\x01\x08\x40\x00" ++
    "\x02\x10\x80\x00\x04\x20\x00\x01\x38\x0e\xa8\xfc\x08\x01\xa0\xf9\x11\x02\x40\xf3\x23\x04\x80\xe6\x47\x08\x00\xcd\x8f\x10\x00\x9a" ++
    "\x1f\x21\x00\x34\x3f\x42\x00\x68\x7e\x84\x00\xd0\xfc\x08\x01\xa0\xf9\x11\x02\x40\xf3\x23\x04\x80\xe6\x47\x08\x00\xcd\x8f\x10\x00" ++
    "\x9a\x1f\x21\x00\x34\x3f\x42\x00\x68\x7e\x84\x00\xd0\xfc\x08\x01\xa0\xf9\x11\x02\x40\xf3\x23\x04\x80\xe6\x47\x08\x00\xcd\x8f\x10" ++
    "\x00\x9a\x1f\x21\x00\x34\x3f\x42\x00\x68\x7e\x84\x00\xd0\xfc\x08\x01\xa0\xf9\x11\x02\x40\xf3\x23\x04\x80\xe6\x47\x08\x00\xcd\x8f" ++
    "\x10\x00\x9a\x1f\x21\x00\x34\x3f\x42\x00\x5c\x1b\xed\x25\xa5\x92\x9a\x03\x15\x44\x00\x00\x00\x00\x49\x45\x4e\x44\xae\x42\x60\x82";
const schema = "{\"type\":\"object\",\"additionalProperties\":false,\"properties\":{\"session_ids\":{\"type\":\"array\",\"minItems\":1,\"maxItems\":1,\"uniqueItems\":true,\"items\":{\"type\":\"integer\",\"enum\":[101]}}},\"required\":[\"session_ids\"]}";
const Host = struct {
    dispatches: usize = 0,
    fn old(_: *anyopaque, _: Loop.Invocation, _: std.mem.Allocator, _: ?*provider.CancelToken) !Loop.Outcome {
        return error.UnexpectedLegacyDispatch;
    }
    fn invoke(raw: *anyopaque, call: tools.DynamicInvocation, a: std.mem.Allocator, _: ?*provider.CancelToken) ![]tools.ToolResult {
        const self: *Host = @ptrCast(@alignCast(raw));
        self.dispatches += 1;
        if (self.dispatches > 1) return error.UnexpectedRepeatedObservation;
        const output = try a.alloc(tools.ToolResult, 1);
        errdefer a.free(output);
        const blocks = try a.alloc(tools.ContentBlock, 1);
        errdefer a.free(blocks);
        blocks[0] = .{ .image_ref = try @import("image_attachments.zig").ContentRef.create(a, "synthetic-canvas", png, 0, .{}) };
        output[0] = .{ .status = .succeeded, .blocks = blocks, .receipt = .{ .operation_id = call.operation_id, .owner = call.parsed.entry.targets[0].owner } };
        return output;
    }
    fn binding(_: *anyopaque, _: tools.Invocation, _: std.mem.Allocator) !tools.ToolResult {
        return error.UseCapturedToolHost;
    }
};
const ObservedTransport = struct {
    actual: transport.Transport,
    requests: usize = 0,
    image_requests: usize = 0,
    image_count: usize = 0,
    image_sha256: [64]u8 = @splat('0'),
    statuses: [8]u16 = @splat(0),
    fn send(raw: *anyopaque, plan: http.RequestPlan, body: []const u8, a: std.mem.Allocator) !transport.Response {
        const self: *@This() = @ptrCast(@alignCast(raw));
        return self.actual.send(self.actual.ctx, plan, body, a);
    }
    fn stream(raw: *anyopaque, plan: http.RequestPlan, body: []const u8, a: std.mem.Allocator, sink: transport.ChunkSink, ctx: *anyopaque) !transport.ResponseMeta {
        const self: *@This() = @ptrCast(@alignCast(raw));
        const decoded = try std.json.parseFromSlice(std.json.Value, a, body, .{});
        defer decoded.deinit();
        const summary = trace.summarize(decoded.value);
        self.requests += 1;
        if (summary.image_count != 0) {
            self.image_requests += 1;
            self.image_count += summary.image_count;
            self.image_sha256 = summary.images[0].sha256;
        }
        const result = try self.actual.send_stream.?(self.actual.ctx, plan, body, a, sink, ctx);
        self.statuses[@min(self.requests - 1, self.statuses.len - 1)] = result.status;
        return result;
    }
    fn interface(self: *@This()) transport.Transport {
        return .{ .ctx = self, .send = send, .send_stream = stream };
    }
};
const Evidence = struct { model: []const u8, protocol: []const u8 = "openai_compat", tool_dispatches: usize, requests: usize, image_requests: usize, wire_image_count: usize, image_sha256: [64]u8, http_statuses: [8]u16, success: bool, error_code: ?[]const u8, answer: []const u8 };

test "API2 LIVE gateway model discovery tool image roundtrip through production native client" {
    const env = testEnvironment();
    const enabled = env.get(env.ctx, "ZEROWORK_AI_GATEWAY_LIVE") orelse return error.SkipZigTest;
    if (!std.mem.eql(u8, enabled, "1")) return error.SkipZigTest;
    if (env.get(env.ctx, "ZEROWORK_AI_GATEWAY_KEY") == null) return error.MissingApiKey;
    const chat_endpoint = env.get(env.ctx, "ZEROWORK_AI_GATEWAY_CHAT_ENDPOINT") orelse return error.MissingEndpoint;
    const models_endpoint = env.get(env.ctx, "ZEROWORK_AI_GATEWAY_MODELS_ENDPOINT") orelse return error.MissingModelsEndpoint;
    const selected_model = env.get(env.ctx, "ZEROWORK_AI_GATEWAY_MODEL") orelse return error.MissingModel;
    const a = std.testing.allocator;
    var native_context: transport.NativeContext = .{ .io = std.testing.io };
    const native = transport.native(&native_context);
    var models_response = try native.send(native.ctx, .{ .method = .GET, .endpoint = models_endpoint, .auth_style = .bearer, .api_key = env.get(env.ctx, "ZEROWORK_AI_GATEWAY_KEY").?, .accept = "application/json", .timeout_ms = 10_000 }, "", a);
    defer models_response.deinit(a);
    try std.testing.expectEqual(@as(u16, 200), models_response.status);
    const models = try std.json.parseFromSlice(struct { data: []const struct { id: []const u8 } }, a, models_response.body, .{ .ignore_unknown_fields = true });
    defer models.deinit();
    var evidence_arena = std.heap.ArenaAllocator.init(a);
    defer evidence_arena.deinit();
    const ea = evidence_arena.allocator();
    var evidence: std.ArrayList(Evidence) = .empty;
    var success_count: usize = 0;
    for ([_][]const u8{selected_model}) |requested_model| {
        const model_id = for (models.value.data) |entry| {
            if (std.mem.eql(u8, entry.id, requested_model)) break entry.id;
        } else continue;
        var host: Host = .{};
        const captured: scope.Scope = .{ .owner = .{ .session = 101 }, .members = .{ .ids = .{101} ++ @as([15]u64, @splat(0)), .len = 1 } };
        const definition: tools.ToolDefinition = .{ .id = "synthetic.observe", .schema = schema, .description = "Return the actual synthetic test image. Call once, then inspect its pixels.", .effect = .observe_image };
        const member: tools.Member = .{ .owner = .{ .session_id = @fromBackingInt(101) }, .plugin_id = "synthetic", .context = &host, .bindings = &.{.{ .plugin_id = "synthetic", .definition_id = definition.id, .handler = Host.binding }} };
        var table = try tools.RequestTable.init(a, captured, &.{definition}, &.{member});
        defer table.deinit();
        const wire = try tools.providerDefinitions(&table, table.arena.allocator());
        var observed: ObservedTransport = .{ .actual = native };
        var client = @import("provider_client.zig").Client.init(a, observed.interface(), .openai_compat);
        var config = @import("provider_config.zig").defaults(.openai_compat);
        config.endpoint = chat_endpoint;
        config.model = model_id;
        config.auth = .{ .bearer_memory = env.get(env.ctx, "ZEROWORK_AI_GATEWAY_KEY").? };
        config.context_window = 100_000;
        config.vision = true;
        config.image_token_reservation = 1024;
        var binding: @import("provider_client.zig").Client.Binding = .{ .client = &client, .config = config };
        var manager = @import("turn_manager.zig").Manager.init(a);
        defer manager.deinit();
        manager.scope = captured;
        manager.turn_id = 1;
        manager.policy_revision = 1;
        manager.tool_limits.context_window = 100_000;
        manager.tool_limits.max_rounds = 4;
        manager.retry_policy.max_attempts = 0;
        manager.tool_host = .{ .context = &host, .execute = Host.old, .execute_dynamic = Host.invoke };
        var failure: ?[]const u8 = null;
        _ = manager.run(binding.asProvider(), config.chatRequest(.{ .model = model_id, .system = "Use synthetic__observe once with session_ids [101]. After its image result is provided, describe the visible colors and their arrangement in one sentence. Do not call other tools and do not call the observation tool again.", .messages = &.{.{ .content = "Please inspect the actual synthetic tool image and report the colors and spatial arrangement you see." }}, .tools = wire, .tool_table = &table, .tool_images = true, .max_output = 512, .timeout_ms = 60_000 })) catch |err| blk: {
            failure = @errorName(err);
            break :blk .{};
        };
        var answer: std.ArrayList(u8) = .empty;
        defer answer.deinit(a);
        for (manager.cards.cards.items) |card| if (card == .text) try answer.appendSlice(a, card.text);
        const recognized = containsIgnoreCase(answer.items, "red") and containsIgnoreCase(answer.items, "green") and containsIgnoreCase(answer.items, "blue") and containsIgnoreCase(answer.items, "left") and containsIgnoreCase(answer.items, "right") and containsIgnoreCase(answer.items, "center");
        const success = failure == null and host.dispatches == 1 and observed.image_requests >= 1 and recognized;
        success_count += @intFromBool(success);
        try evidence.append(ea, .{ .model = try ea.dupe(u8, model_id), .tool_dispatches = host.dispatches, .requests = observed.requests, .image_requests = observed.image_requests, .wire_image_count = observed.image_count, .image_sha256 = observed.image_sha256, .http_statuses = observed.statuses, .success = success, .error_code = failure, .answer = try ea.dupe(u8, answer.items) });
    }
    const json = try std.json.Stringify.valueAlloc(a, .{ .models_endpoint_status = models_response.status, .models_count = models.value.data.len, .synthetic_image = "128x96 red-left green-right blue-center RGBA PNG", .results = evidence.items }, .{ .whitespace = .indent_2 });
    defer a.free(json);
    const evidence_path = env.get(env.ctx, "ZEROWORK_AI_GATEWAY_EVIDENCE") orelse "/tmp/zerowork-ai-gateway-128x96-evidence.json";
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = evidence_path, .data = json });
    try std.testing.expectEqual(@as(usize, 1), evidence.items.len);
    try std.testing.expect(success_count >= 1);
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    for (0..haystack.len - needle.len + 1) |index| if (std.ascii.eqlIgnoreCase(haystack[index .. index + needle.len], needle)) return true;
    return false;
}

fn testEnvironment() struct { ctx: *anyopaque, get: *const fn (*anyopaque, []const u8) ?[]const u8 } {
    return .{ .ctx = undefined, .get = struct {
        fn get(_: *anyopaque, name: []const u8) ?[]const u8 {
            var buffer: [128]u8 = undefined;
            if (name.len >= buffer.len) return null;
            @memcpy(buffer[0..name.len], name);
            buffer[name.len] = 0;
            const value = std.c.getenv(@ptrCast(buffer[0..name.len :0].ptr)) orelse return null;
            const text = std.mem.span(value);
            return if (text.len == 0) null else text;
        }
    }.get };
}
