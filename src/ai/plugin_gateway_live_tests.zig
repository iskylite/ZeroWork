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
// Generated outside the process so expected labels never enter provider text.
const ImageCell = struct { color: []const u8, text: []const u8 };
const ImageAnswer = struct { top_left: ImageCell, top_right: ImageCell, bottom_left: ImageCell, bottom_right: ImageCell };
const ImageChallenge = struct { image_sha256: []const u8, expected: ImageAnswer };
const image_prompt = "Inspect the attached image pixels. Return only a JSON object with keys top_left, top_right, bottom_left, bottom_right, each containing color (one of red, green, blue, yellow) and text (the exact six visible characters). Do not guess; if the image is unavailable say IMAGE_UNAVAILABLE.";
const schema = "{\"type\":\"object\",\"additionalProperties\":false,\"properties\":{\"session_ids\":{\"type\":\"array\",\"minItems\":1,\"maxItems\":1,\"uniqueItems\":true,\"items\":{\"type\":\"integer\",\"enum\":[101]}}},\"required\":[\"session_ids\"]}";
const Host = struct {
    image_bytes: []const u8,
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
        blocks[0] = .{ .image_ref = try @import("image_attachments.zig").ContentRef.create(a, "synthetic-canvas", self.image_bytes, 0, .{}) };
        output[0] = .{ .status = .succeeded, .blocks = blocks, .receipt = .{ .operation_id = call.operation_id, .owner = call.parsed.entry.targets[0].owner } };
        return output;
    }
    fn binding(_: *anyopaque, _: tools.Invocation, _: std.mem.Allocator) !tools.ToolResult {
        return error.UseCapturedToolHost;
    }
};
const ObservedTransport = struct {
    actual: transport.Transport,
    challenge: ?ImageAnswer = null,
    expected_text_leaked: bool = false,
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
        if (self.challenge) |expected| {
            if (decoded.value.object.get("messages")) |messages| for (messages.array.items) |message| {
                const content = message.object.get("content") orelse continue;
                if (content == .string) {
                    self.expected_text_leaked = self.expected_text_leaked or containsImageLabel(content.string, expected);
                } else if (content == .array) for (content.array.items) |block| {
                    if (block.object.get("text")) |text| if (text == .string) {
                        self.expected_text_leaked = self.expected_text_leaked or containsImageLabel(text.string, expected);
                    };
                };
            };
        }
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
const Evidence = struct { expected: ImageAnswer, expected_text_leaked: bool, semantics_match: bool, image_hash_match: bool, model: []const u8, protocol: []const u8 = "openai_compat", tool_dispatches: usize, requests: usize, image_requests: usize, wire_image_count: usize, image_sha256: [64]u8, http_statuses: [8]u16, success: bool, error_code: ?[]const u8, answer: []const u8 };

test "API2 LIVE gateway verifies unpredictable text tool result through production native client" {
    const env = testEnvironment();
    if (!std.mem.eql(u8, env.get(env.ctx, "ZEROWORK_AI_GATEWAY_TEXT_LIVE") orelse return error.SkipZigTest, "1")) return error.SkipZigTest;
    const a = std.testing.allocator;
    const host_authority = std.mem.eql(u8, env.get(env.ctx, "ZEROWORK_AI_GATEWAY_HOST_LIVE") orelse "0", "1");
    const TokenHost = struct {
        nonce: [32]u8,
        dispatches: usize = 0,
        fn invokeHost(raw: *anyopaque, call: tools.host.Invocation, allocator: std.mem.Allocator, _: ?*provider.CancelToken) !tools.host.Result {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.dispatches += 1;
            if (self.dispatches != 1) return error.RepeatedToolCall;
            const blocks = try allocator.alloc(tools.host.Block, 1);
            errdefer allocator.free(blocks);
            blocks[0] = .{ .structured = try std.json.Stringify.valueAlloc(allocator, .{ .verification_nonce = self.nonce, .measured_value = @as(u32, 314159) }, .{ .emit_strings_as_arrays = false }) };
            return .{ .status = .succeeded, .blocks = blocks, .receipt = .{ .conversation_id = call.context.conversation_id, .task_id = call.context.task_id, .operation_id = call.operation_id, .binding_revision = call.context.binding_revision } };
        }
        fn invoke(raw: *anyopaque, call: tools.DynamicInvocation, allocator: std.mem.Allocator, _: ?*provider.CancelToken) ![]tools.ToolResult {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.dispatches += 1;
            if (self.dispatches != 1) return error.RepeatedToolCall;
            const result = try allocator.alloc(tools.ToolResult, 1);
            errdefer allocator.free(result);
            const blocks = try allocator.alloc(tools.ContentBlock, 1);
            errdefer allocator.free(blocks);
            blocks[0] = .{ .structured = try std.json.Stringify.valueAlloc(allocator, .{ .verification_nonce = self.nonce, .measured_value = @as(u32, 314159) }, .{ .emit_strings_as_arrays = false }) };
            result[0] = .{ .status = .succeeded, .blocks = blocks, .receipt = .{ .operation_id = call.operation_id, .owner = call.parsed.entry.targets[0].owner } };
            return result;
        }
    };
    var random: [16]u8 = undefined;
    try std.testing.io.randomSecure(&random);
    var host: TokenHost = .{ .nonce = std.fmt.bytesToHex(random, .lower) };
    const captured: scope.Scope = if (host_authority) .{ .owner = .{ .group = 7 }, .members = .{} } else .{ .owner = .{ .session = 101 }, .members = .{ .ids = .{101} ++ @as([15]u64, @splat(0)), .len = 1 } };
    const definition: tools.ToolDefinition = .{ .id = "synthetic.measure", .schema = schema, .description = "Read the current synthetic measurement and its unpredictable verification nonce." };
    const member: tools.Member = .{ .owner = .{ .session_id = @fromBackingInt(101) }, .plugin_id = "synthetic", .context = &host, .bindings = &.{.{ .plugin_id = "synthetic", .definition_id = definition.id, .handler = Host.binding }} };
    const host_definition: tools.ToolDefinition = .{ .id = "host.measure", .schema = "{\"type\":\"object\",\"properties\":{},\"additionalProperties\":false}", .description = definition.description };
    var table = if (host_authority) try tools.RequestTable.initWithHost(a, captured, &.{}, &.{}, .{ .conversation_id = @import("../host/identity.zig").ConversationId.generate(), .task_id = @import("../host/identity.zig").TaskId.generate(), .binding = captured.owner, .binding_revision = 1, .grant_revision = 1 }, &.{.{ .definition = host_definition, .authority = .conversation_context }}) else try tools.RequestTable.init(a, captured, &.{definition}, &.{member});
    defer table.deinit();
    const wire = try tools.providerDefinitions(&table, table.arena.allocator());
    var native_context: transport.NativeContext = .{ .io = std.testing.io };
    var observed: ObservedTransport = .{ .actual = transport.native(&native_context) };
    var client = @import("provider_client.zig").Client.init(a, observed.interface(), .openai_compat);
    var config = @import("provider_config.zig").defaults(.openai_compat);
    config.endpoint = env.get(env.ctx, "ZEROWORK_AI_GATEWAY_CHAT_ENDPOINT") orelse return error.MissingEndpoint;
    config.model = env.get(env.ctx, "ZEROWORK_AI_GATEWAY_MODEL") orelse return error.MissingModel;
    config.auth = .{ .bearer_memory = env.get(env.ctx, "ZEROWORK_AI_GATEWAY_KEY") orelse return error.MissingApiKey };
    config.context_window = 100_000;
    var binding: @import("provider_client.zig").Client.Binding = .{ .client = &client, .config = config };
    var manager = @import("turn_manager.zig").Manager.init(a);
    defer manager.deinit();
    manager.scope = captured;
    manager.turn_id = 1;
    manager.tool_limits.context_window = config.context_window;
    manager.tool_limits.max_rounds = 3;
    manager.retry_policy.max_attempts = 0;
    manager.tool_host = .{ .context = &host, .execute = Host.old, .execute_dynamic = TokenHost.invoke, .execute_host = TokenHost.invokeHost };
    var failure: ?[]const u8 = null;
    const instructions = if (host_authority) "Call host__measure exactly once with {}. Read the actual result, then reply with its exact verification_nonce and measured_value. Never invent either value and do not repeat the call." else "Call synthetic__measure exactly once with session_ids [101]. Read the actual result, then reply with its exact verification_nonce and measured_value. Never invent either value and do not repeat the call.";
    _ = manager.run(binding.asProvider(), config.chatRequest(.{ .model = config.model, .system = instructions, .messages = &.{.{ .content = "Read the synthetic measurement and report both fields from its result." }}, .tools = wire, .tool_table = &table, .max_output = 256, .timeout_ms = 60_000 })) catch |err| blk: {
        failure = @errorName(err);
        break :blk .{};
    };
    var answer: std.ArrayList(u8) = .empty;
    defer answer.deinit(a);
    for (manager.cards.cards.items) |card| if (card == .text) try answer.appendSlice(a, card.text);
    const success = failure == null and host.dispatches == 1 and observed.requests == 2 and observed.statuses[0] == 200 and observed.statuses[1] == 200 and std.mem.indexOf(u8, answer.items, &host.nonce) != null and std.mem.indexOf(u8, answer.items, "314159") != null;
    const evidence = try std.json.Stringify.valueAlloc(a, .{ .model = config.model, .host_authority = host_authority, .tool_dispatches = host.dispatches, .requests = observed.requests, .http_statuses = observed.statuses, .result_nonce = host.nonce, .answer = answer.items, .success = success, .error_code = failure }, .{ .whitespace = .indent_2, .emit_strings_as_arrays = false });
    defer a.free(evidence);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = env.get(env.ctx, "ZEROWORK_AI_GATEWAY_TEXT_EVIDENCE") orelse "/tmp/zerowork-ai-text-gateway-evidence.json", .data = evidence });
    try std.testing.expect(success);
}

test "API2 LIVE gateway model discovery tool image roundtrip through production native client" {
    const env = testEnvironment();
    const enabled = env.get(env.ctx, "ZEROWORK_AI_GATEWAY_LIVE") orelse return error.SkipZigTest;
    if (!std.mem.eql(u8, enabled, "1")) return error.SkipZigTest;
    if (env.get(env.ctx, "ZEROWORK_AI_GATEWAY_KEY") == null) return error.MissingApiKey;
    const chat_endpoint = env.get(env.ctx, "ZEROWORK_AI_GATEWAY_CHAT_ENDPOINT") orelse return error.MissingEndpoint;
    const models_endpoint = env.get(env.ctx, "ZEROWORK_AI_GATEWAY_MODELS_ENDPOINT") orelse return error.MissingModelsEndpoint;
    const selected_model = env.get(env.ctx, "ZEROWORK_AI_GATEWAY_MODEL") orelse return error.MissingModel;
    const a = std.testing.allocator;
    const fixture_path = env.get(env.ctx, "ZEROWORK_AI_GATEWAY_IMAGE_FIXTURE") orelse return error.MissingImageFixture;
    const manifest_path = env.get(env.ctx, "ZEROWORK_AI_GATEWAY_IMAGE_MANIFEST") orelse return error.MissingImageManifest;
    const image_bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, fixture_path, a, .limited(@import("image_attachments.zig").max_bytes));
    defer a.free(image_bytes);
    const manifest_bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, manifest_path, a, .limited(4096));
    defer a.free(manifest_bytes);
    const challenge = try std.json.parseFromSlice(ImageChallenge, a, manifest_bytes, .{});
    defer challenge.deinit();
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(image_bytes, &digest, .{});
    const expected_hash = std.fmt.bytesToHex(digest, .lower);
    try std.testing.expectEqualStrings(challenge.value.image_sha256, &expected_hash);
    var native_context: transport.NativeContext = .{ .io = std.testing.io };
    const native = transport.native(&native_context);
    var models_response = try native.send(native.ctx, .{ .method = .GET, .endpoint = models_endpoint, .auth_style = .bearer, .api_key = env.get(env.ctx, "ZEROWORK_AI_GATEWAY_KEY").?, .accept = "application/json", .timeout_ms = 10_000 }, "", a);
    defer models_response.deinit(a);
    try std.testing.expectEqual(@as(u16, 200), models_response.status);
    var models = try @import("model_catalog.zig").Catalog.parse(a, models_response.body, .endpoint);
    defer models.deinit();
    var evidence_arena = std.heap.ArenaAllocator.init(a);
    defer evidence_arena.deinit();
    const ea = evidence_arena.allocator();
    var evidence: std.ArrayList(Evidence) = .empty;
    var success_count: usize = 0;
    for ([_][]const u8{selected_model}) |requested_model| {
        const model_id = for (models.entries) |entry| {
            if (std.mem.eql(u8, entry.id, requested_model)) {
                if (!(entry.capability.vision orelse false)) return error.ModelDoesNotDeclareVision;
                break entry.id;
            }
        } else continue;
        var host: Host = .{ .image_bytes = image_bytes };
        const captured: scope.Scope = .{ .owner = .{ .session = 101 }, .members = .{ .ids = .{101} ++ @as([15]u64, @splat(0)), .len = 1 } };
        const definition: tools.ToolDefinition = .{ .id = "synthetic.observe", .schema = schema, .description = "Return the actual synthetic test image. Call once, then inspect its pixels.", .effect = .observe_image };
        const member: tools.Member = .{ .owner = .{ .session_id = @fromBackingInt(101) }, .plugin_id = "synthetic", .context = &host, .bindings = &.{.{ .plugin_id = "synthetic", .definition_id = definition.id, .handler = Host.binding }} };
        var table = try tools.RequestTable.init(a, captured, &.{definition}, &.{member});
        defer table.deinit();
        const wire = try tools.providerDefinitions(&table, table.arena.allocator());
        var observed: ObservedTransport = .{ .actual = native, .challenge = challenge.value.expected };
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
        _ = manager.run(binding.asProvider(), config.chatRequest(.{ .model = model_id, .system = "Use synthetic__observe once with session_ids [101]. After its image result is provided, inspect its pixels and follow the user output format. Do not call other tools and do not call the observation tool again.", .messages = &.{.{ .content = image_prompt }}, .tools = wire, .tool_table = &table, .tool_images = true, .max_output = 2048, .timeout_ms = 120_000 })) catch |err| blk: {
            failure = @errorName(err);
            break :blk .{};
        };
        var answer: std.ArrayList(u8) = .empty;
        defer answer.deinit(a);
        for (manager.cards.cards.items) |card| if (card == .text) try answer.appendSlice(a, card.text);
        const recognized = recognizesImageAnswer(a, answer.items, challenge.value.expected);
        const hash_match = std.mem.eql(u8, &expected_hash, &observed.image_sha256);
        const success = failure == null and host.dispatches == 1 and observed.requests == 2 and observed.image_requests == 1 and observed.image_count == 1 and observed.statuses[0] == 200 and observed.statuses[1] == 200 and hash_match and recognized and !observed.expected_text_leaked;
        success_count += @intFromBool(success);
        try evidence.append(ea, .{ .expected = challenge.value.expected, .expected_text_leaked = observed.expected_text_leaked, .semantics_match = recognized, .image_hash_match = hash_match, .model = try ea.dupe(u8, model_id), .tool_dispatches = host.dispatches, .requests = observed.requests, .image_requests = observed.image_requests, .wire_image_count = observed.image_count, .image_sha256 = observed.image_sha256, .http_statuses = observed.statuses, .success = success, .error_code = failure, .answer = try ea.dupe(u8, answer.items) });
    }
    const json = try std.json.Stringify.valueAlloc(a, .{ .models_endpoint_status = models_response.status, .models_count = models.entries.len, .synthetic_image = "random four-quadrant color layout with six-character labels visible only in image pixels", .results = evidence.items }, .{ .whitespace = .indent_2 });
    defer a.free(json);
    const evidence_path = env.get(env.ctx, "ZEROWORK_AI_GATEWAY_EVIDENCE") orelse "/tmp/zerowork-ai-gateway-image-evidence.json";
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = evidence_path, .data = json });
    try std.testing.expectEqual(@as(usize, 1), evidence.items.len);
    try std.testing.expect(success_count >= 1);
}

fn containsImageLabel(text: []const u8, expected: ImageAnswer) bool {
    inline for (@typeInfo(ImageAnswer).@"struct".field_names) |field| {
        if (std.mem.indexOf(u8, text, @field(expected, field).text) != null) return true;
    }
    return false;
}

fn recognizesImageAnswer(a: std.mem.Allocator, answer: []const u8, expected: ImageAnswer) bool {
    // The manager also retains commentary emitted before the image tool call.
    // Only the final JSON describes the observed pixels; still parse it strictly.
    const start = std.mem.indexOfScalar(u8, answer, '{') orelse return false;
    const end = std.mem.lastIndexOfScalar(u8, answer, '}') orelse return false;
    if (start >= end) return false;
    const json = answer[start .. end + 1];
    const parsed = std.json.parseFromSlice(ImageAnswer, a, json, .{}) catch return false;
    defer parsed.deinit();
    inline for (@typeInfo(ImageAnswer).@"struct".field_names) |field| {
        const actual_cell = @field(parsed.value, field);
        const expected_cell = @field(expected, field);
        if (!std.ascii.eqlIgnoreCase(actual_cell.color, expected_cell.color) or !std.mem.eql(u8, actual_cell.text, expected_cell.text)) return false;
    }
    return true;
}

test "API2 LIVE visual acceptance requires exact color position and unpredictable image text" {
    const expected: ImageAnswer = .{ .top_left = .{ .color = "red", .text = "K4E2JR" }, .top_right = .{ .color = "green", .text = "8KSGM2" }, .bottom_left = .{ .color = "blue", .text = "W7QJ4R" }, .bottom_right = .{ .color = "yellow", .text = "N9VF6T" } };
    const correct = "{\"top_left\":{\"color\":\"red\",\"text\":\"K4E2JR\"},\"top_right\":{\"color\":\"green\",\"text\":\"8KSGM2\"},\"bottom_left\":{\"color\":\"blue\",\"text\":\"W7QJ4R\"},\"bottom_right\":{\"color\":\"yellow\",\"text\":\"N9VF6T\"}}";
    try std.testing.expect(recognizesImageAnswer(std.testing.allocator, correct, expected));
    const with_commentary = "I will inspect the pixels." ++ correct;
    try std.testing.expect(recognizesImageAnswer(std.testing.allocator, with_commentary, expected));
    try std.testing.expect(containsImageLabel("K4E2JR", expected));
    try std.testing.expect(!containsImageLabel(image_prompt, expected));
    var swapped = expected;
    swapped.top_left.color = "green";
    swapped.top_right.color = "red";
    try std.testing.expect(!recognizesImageAnswer(std.testing.allocator, correct, swapped));
    var wrong_text = expected;
    wrong_text.bottom_right.text = "N9VF6X";
    try std.testing.expect(!recognizesImageAnswer(std.testing.allocator, correct, wrong_text));
    try std.testing.expect(!recognizesImageAnswer(std.testing.allocator, "red left green right blue center yellow", expected));
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
