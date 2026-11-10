const std = @import("std");
const a = std.testing.allocator;
const identity = @import("host/identity.zig");
const operations = @import("host/operation_store.zig");
const task = @import("ai/task_budget.zig");
const inputs = @import("ai/session_input.zig");
const wire = @import("ai/wire_history.zig");
const provider = @import("ai/provider.zig");

test "AI limits legacy counters decode retired quotas without restoring limits" {
    const source = "{\"requests\":128,\"calls\":256,\"pending_requests\":1,\"elapsed_ns\":42,\"timeout_ns\":600000000000,\"input_tokens\":23,\"output_tokens\":7,\"usage_complete\":false,\"max_requests\":16,\"max_calls\":64}";
    const parsed = try std.json.parseFromSlice(task.Counters, a, source, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(u64, 128), parsed.value.requests);
    try std.testing.expectEqual(@as(u64, 256), parsed.value.calls);
    try std.testing.expectEqual(@as(u64, 600000000000), parsed.value.timeout_ns);
    try std.testing.expect(!parsed.value.usage_complete);
    const value = try std.json.parseFromSlice(std.json.Value, a, source, .{});
    defer value.deinit();
    const from_value = try std.json.parseFromValue(task.Counters, a, value.value, .{});
    defer from_value.deinit();
    try std.testing.expectEqualDeep(parsed.value, from_value.value);
    const encoded = try std.json.Stringify.valueAlloc(a, parsed.value, .{});
    defer a.free(encoded);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "max_requests") == null);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "max_calls") == null);
    try std.testing.expectError(error.UnknownField, std.json.parseFromSlice(task.Counters, a, "{\"unexpected_authority\":true}", .{}));
    try std.testing.expectError(error.UnexpectedToken, std.json.parseFromSlice(task.Counters, a, "{\"max_calls\":false}", .{}));
}

test "AI limits completed operation history does not prevent new operations" {
    var store = operations.Store.init(a);
    defer store.deinit();
    const owner: identity.SessionHandle = .{ .session_id = @fromBackingInt(1) };
    for (0..128) |index| {
        _ = try store.begin(owner, index + 1, "read", @splat(0), 1);
        try store.markSent(owner, index + 1);
        try store.finish(owner, index + 1, true, "done");
        try store.resourcesReleased(owner, index + 1);
    }
    _ = try store.begin(owner, 129, "read", @splat(0), 1);
    try std.testing.expectEqual(@as(usize, 129), store.count());
}

test "AI limits manual answer recovery can outlive an explicit old task deadline" {
    var root = task.Root.init(a);
    defer root.deinit();
    const id = identity.TaskId.generate();
    try root.add(.{ .root = id, .task = id, .agent = .generate(), .conversation = .generate(), .generation = 1 });
    root.counters.timeout_ns = 1;
    root.counters.elapsed_ns = 2;
    try root.state(id, .failed, "timeout");
    try root.resumeAnswer(id);
    try root.check();
}

test "AI limits long transcript can be checkpointed with exact contents" {
    const messages: [513]provider.Message = @splat(.{ .role = .user, .content = "x" });
    var history = try wire.History.copy(a, &messages, "");
    defer history.deinit();
    try std.testing.expectEqual(@as(usize, 513), history.messages.len);
}

test "AI limits cancelled input receipts do not impose a conversation lifetime limit" {
    const fence: inputs.Fence = .{ .agent = .generate(), .conversation = .generate(), .binding = 1, .environment = 1 };
    var inbox = inputs.Inbox.init(a, fence);
    defer inbox.deinit();
    for (0..512) |_| {
        const receipt = try inbox.admit(fence, .generate(), .{ .content = "x" }, .queue);
        try inbox.cancelQueued(receipt.id, receipt.revision);
    }
    _ = try inbox.admit(fence, .generate(), .{ .content = "x" }, .queue);
}

test "AI limits large context model admits more than 512 KiB of text" {
    const loop = @import("ai/tool_loop.zig");
    const text = try a.alloc(u8, 512 * 1024 + 1);
    defer a.free(text);
    @memset(text, 'a');
    var run = loop.Loop.init(a, .{ .owner = .{ .session = 1 }, .members = .{} }, 1, .{ .context_window = 1_000_000 });
    defer run.deinit();
    try run.start(.{ .model = "large", .system = "", .messages = &.{.{ .content = text }} });
    try std.testing.expectEqual(text.len, run.messages.items[0].content.len);
}

test "AI limits steering compacts old context before consuming the new input" {
    const loop = @import("ai/tool_loop.zig");
    const Fixture = struct {
        calls: usize = 0,
        fn chat(raw: *anyopaque, _: provider.ChatRequest, sink: *const fn (*anyopaque, provider.Delta) void, ctx: *anyopaque) !provider.ChatStats {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.calls += 1;
            sink(ctx, .{ .text = "Summary: original task is retained." });
            sink(ctx, .done);
            return .{};
        }
        fn models(_: *anyopaque, allocator: std.mem.Allocator) ![]provider.ModelInfo {
            return allocator.alloc(provider.ModelInfo, 0);
        }
    };
    var fixture: Fixture = .{};
    const old = try a.alloc(u8, 27000);
    defer a.free(old);
    @memset(old, 'a');
    const update = try a.alloc(u8, 6000);
    defer a.free(update);
    @memset(update, 'b');
    var run = loop.Loop.init(a, .{ .owner = .{ .session = 1 }, .members = .{} }, 1, .{ .context_window = 8192 });
    defer run.deinit();
    try run.start(.{ .model = "mock", .system = "", .messages = &.{.{ .content = old }}, .max_output = 512 });
    run.compaction_config = .{ .kind = .openai_compat, .endpoint = "http://127.0.0.1:1", .model = "mock", .auth = .none, .context_window = 8192 };
    run.compaction_provider = .{ .ctx = &fixture, .chat = Fixture.chat, .models = Fixture.models };
    const prepared = try run.prepareMessage(.{ .content = update });
    run.appendPrepared(prepared);
    try std.testing.expect(fixture.calls > 0);
    try std.testing.expectEqualStrings(update, run.messages.items[run.messages.items.len - 1].content);
    try @import("ai/local_text_request.zig").checkContext(run.request, 8192);
}

test "AI limits default output uses the provider default while preserving upstream truncation facts" {
    const http = @import("ai/provider_http.zig");
    const json = @import("ai/provider_json.zig");
    const body = try http.requestBody(a, .openai_compat, .{ .model = "large", .system = "", .messages = &.{} }, 1_000_000);
    defer a.free(body);
    const parsed = try std.json.parseFromSlice(std.json.Value, a, body, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value.object.get("max_tokens") == null);
    const Sink = struct {
        failed: bool = false,
        done: bool = false,
        fn receive(raw: *anyopaque, delta: provider.Delta) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            if (delta == .err) self.failed = true;
            if (delta == .done) self.done = true;
        }
    };
    var sink: Sink = .{};
    var adapter = json.Adapter.init(a, Sink.receive, &sink);
    defer adapter.deinit();
    try adapter.receive("{\"choices\":[{\"delta\":{\"content\":\"partial answer\"},\"finish_reason\":\"length\"}]}");
    try std.testing.expect(sink.failed and !sink.done);
}

test "AI limits completed child task history can grow past thirty two records" {
    var root = task.Root.init(a);
    defer root.deinit();
    const id = identity.TaskId.generate();
    try root.add(.{ .root = id, .task = id, .agent = .generate(), .conversation = .generate(), .generation = 1 });
    for (0..80) |_| {
        const child = identity.TaskId.generate();
        try root.add(.{ .root = id, .task = child, .parent = id, .agent = .generate(), .conversation = .generate(), .generation = 1 });
        try root.state(child, .succeeded, "done");
    }
    try std.testing.expectEqual(@as(usize, 81), root.count);
}

test "AI limits mandatory native output budget follows provider model metadata" {
    const catalog = @import("ai/model_catalog.zig");
    const parsed = try std.json.parseFromSlice(std.json.Value, a, "{\"max_input_tokens\":1000000,\"max_tokens\":128000}", .{});
    defer parsed.deinit();
    const metadata = catalog.metadata(parsed.value);
    try std.testing.expectEqual(@as(?u32, 128000), metadata.output);
    const config: @import("ai/provider_config.zig").ProviderConfig = .{ .kind = .anthropic, .model = "advertised-model", .endpoint = "https://gateway.invalid", .auth = .{ .anthropic_memory = "fixture" }, .context_window = 1_000_000, .output_limit = metadata.output };
    try std.testing.expectEqual(@as(u32, 128000), config.chatRequest(.{ .model = "", .system = "", .messages = &.{} }).max_output);
}

test "AI limits MCP sampling honors requested output without an unrelated 4096 token or 256 KiB cap" {
    const Fixture = struct {
        text: []const u8,
        fn chat(raw: *anyopaque, request: provider.ChatRequest, sink: *const fn (*anyopaque, provider.Delta) void, ctx: *anyopaque) !provider.ChatStats {
            const self: *@This() = @ptrCast(@alignCast(raw));
            try std.testing.expectEqual(@as(u32, 12000), request.max_output);
            sink(ctx, .{ .text = self.text });
            sink(ctx, .done);
            return .{};
        }
        fn models(_: *anyopaque, allocator: std.mem.Allocator) ![]provider.ModelInfo {
            return allocator.alloc(provider.ModelInfo, 0);
        }
    };
    const text = try a.alloc(u8, 256 * 1024 + 1);
    defer a.free(text);
    @memset(text, 'a');
    var fixture: Fixture = .{ .text = text };
    const params = try std.json.parseFromSlice(std.json.Value, a, "{\"messages\":[{\"role\":\"user\",\"content\":{\"type\":\"text\",\"text\":\"prompt\"}}],\"maxTokens\":12000}", .{});
    defer params.deinit();
    const result = try @import("ai/mcp_sampling.zig").generate(a, .{ .ctx = &fixture, .chat = Fixture.chat, .models = Fixture.models }, "fixture", 0, params.value, null);
    defer a.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, text) != null);
}
