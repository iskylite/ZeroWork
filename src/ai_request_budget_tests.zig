const std = @import("std");
const http = @import("ai/provider_http.zig");
const provider = @import("ai/provider.zig");
const registry = @import("ai/registry.zig");

test "AI request budget retains a complete escaped 64 KiB local text for every plain adapter" {
    const a = std.testing.allocator;
    const content = try a.alloc(u8, 64 * 1024);
    defer a.free(content);
    @memset(content, 0x1b);
    for ([_]registry.Kind{ .openai_compat, .anthropic, .ollama }) |kind| {
        const body = try http.requestBody(a, kind, .{ .model = "m", .system = "scope", .messages = &.{.{ .content = content }} }, 200_000);
        defer a.free(body);
        const parsed = try std.json.parseFromSlice(std.json.Value, a, body, .{});
        defer parsed.deinit();
        const messages = parsed.value.object.get("messages").?.array.items;
        const encoded = messages[messages.len - 1].object.get("content").?;
        const decoded = if (kind == .anthropic) blk: {
            try std.testing.expectEqual(@as(usize, 1), encoded.array.items.len);
            const block = encoded.array.items[0].object;
            try std.testing.expectEqualStrings("text", block.get("type").?.string);
            break :blk block.get("text").?.string;
        } else encoded.string;
        try std.testing.expectEqual(@as(usize, 64 * 1024), decoded.len);
        try std.testing.expectEqualStrings(content, decoded);
        try std.testing.expect(body.len >= 6 * content.len);
        try std.testing.expectEqual(body.len, try http.requestBodySize(kind, .{ .model = "m", .system = "scope", .messages = &.{.{ .content = content }} }, 200_000));
    }
}

test "AI request budget measures exact complete JSON boundaries for every adapter" {
    const a = std.testing.allocator;
    // Keep the numeric output field width fixed while varying only input bytes.
    const empty: provider.ChatRequest = .{ .model = "m", .system = "scope", .messages = &.{.{ .content = "" }}, .max_output = 1 };
    for ([_]registry.Kind{ .openai_compat, .anthropic, .ollama }) |kind| {
        const overhead = try http.requestBodySize(kind, empty, 200_000);
        const content = try a.alloc(u8, http.max_text_request_bytes - overhead + 1);
        defer a.free(content);
        @memset(content, 'x');
        var messages = [_]provider.Message{.{ .content = content[0 .. content.len - 1] }};
        var request = empty;
        request.messages = &messages;
        try std.testing.expectEqual(http.max_text_request_bytes, try http.requestBodySize(kind, request, 200_000));
        const body = try http.requestBody(a, kind, request, 200_000);
        defer a.free(body);
        try std.testing.expectEqual(http.max_text_request_bytes, body.len);
        messages[0].content = content;
        try std.testing.expectError(error.RequestTooLarge, http.requestBodySize(kind, request, 200_000));
        try std.testing.expectError(error.RequestTooLarge, http.requestBody(a, kind, request, 200_000));
    }
}

test "AI request budget includes escaping model history system and tool declarations in the same preflight" {
    const a = std.testing.allocator;
    const tools = [_]provider.ToolDefinition{.{ .tool = .run_command, .session_ids = &.{101} }};
    const calls = [_]provider.ToolCall{.{ .id = "c", .name = "run_command", .arguments = "{\"command\":\"echo hi\"}" }};
    const messages = [_]provider.Message{
        .{ .content = "quoted \"input\"\n" },
        .{ .role = .assistant, .content = "", .tool_calls = &calls },
        .{ .role = .tool, .content = "\x00\x1b\n\r\t", .tool_call_id = "c" },
    };
    const request: provider.ChatRequest = .{ .model = "m\"", .effort = .high, .system = "complete\ncontext", .messages = &messages, .tools = &tools };
    const body = try http.requestBody(a, .openai_compat, request, 200_000);
    defer a.free(body);
    try std.testing.expectEqual(body.len, try http.requestBodySize(.openai_compat, request, 200_000));
    const huge = try a.alloc(u8, http.max_request_bytes);
    defer a.free(huge);
    @memset(huge, 'x');
    var too_large = request;
    too_large.model = huge;
    try std.testing.expectError(error.ToolRequestTooLarge, http.requestBodySize(.openai_compat, too_large, 200_000));
    try std.testing.expectError(error.ToolRequestTooLarge, http.requestBody(a, .openai_compat, too_large, 200_000));
    try std.testing.expect(!@import("ai/retry.zig").isRetryable(error.RequestTooLarge));
    try std.testing.expect(!@import("ai/retry.zig").isRetryable(error.ToolRequestTooLarge));
}

test "AI request budget rejects without consuming original owner draft text or immutable attachments" {
    const attachments = @import("ai/local_text_attachments.zig");
    const store_mod = @import("ai/assistant_store.zig");
    const a = std.testing.allocator;
    var store = store_mod.Store.init(a);
    defer store.deinit();
    const owner: attachments.Owner = .{ .session = 71 };
    const state = try store.get(owner);
    state.draft = try a.dupe(u8, "original prompt");
    const draft = try store.attachmentDraft(owner);
    const ticket = try draft.begin();
    var reference = try attachments.ContentRef.create(a, "/selected.txt", "keep the captured attachment", 1);
    _ = try draft.complete(ticket, &reference);
    var bundle = try draft.freeze();
    defer bundle.deinit();
    const huge_history = try a.alloc(u8, http.max_request_bytes);
    defer a.free(huge_history);
    @memset(huge_history, 'h');
    const request: provider.ChatRequest = .{ .model = "m", .system = "", .messages = &.{ .{ .role = .assistant, .content = huge_history }, .{ .content = state.draft.? }, .{ .content = bundle.items[0].reference.content().?.bytes } } };
    try std.testing.expectError(error.RequestTooLarge, http.requestBodySize(.openai_compat, request, 200_000));
    try std.testing.expectEqualStrings("original prompt", state.draft.?);
    try std.testing.expectEqual(@as(usize, 1), draft.items.items.len);
    try std.testing.expectEqualStrings("keep the captured attachment", draft.items.items[0].reference.content().?.bytes);
}

test "AI request budget exact allocation and failure cleanup do not grow beyond the measured request" {
    const Scenario = struct {
        fn run(allocator: std.mem.Allocator) !void {
            const request: provider.ChatRequest = .{ .model = "m", .system = "context", .messages = &.{.{ .content = "full \"escaped\" content" }} };
            const body = try http.requestBody(allocator, .openai_compat, request, 200_000);
            defer allocator.free(body);
            try std.testing.expectEqual(try http.requestBodySize(.openai_compat, request, 200_000), body.len);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Scenario.run, .{});
}

test "AI request budget local text composition keeps every captured byte and rejects without truncation" {
    const A = @import("ai/local_text_attachments.zig");
    const R = @import("ai/local_text_request.zig");
    const a = std.testing.allocator;
    var draft = try A.Draft.init(a, .{ .session = 1 });
    defer draft.deinit();
    const ticket = try draft.begin();
    var reference = try A.ContentRef.create(a, "/chosen.txt", "\xef\xbb\xbf中文\nlast byte!", 1);
    _ = try draft.complete(ticket, &reference);
    var bundle = try draft.freeze();
    defer bundle.deinit();
    const prompt = try R.compose(a, "question", &bundle, http.max_request_bytes);
    defer a.free(prompt);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "\xef\xbb\xbf中文\nlast byte!") != null);
    try std.testing.expectError(error.RequestTooLarge, R.compose(a, "question", &bundle, prompt.len - 1));
    const messages = [_]provider.Message{.{ .content = prompt }};
    const request: provider.ChatRequest = .{ .model = "m", .system = "scope", .messages = &messages, .max_output = 4096 };
    try R.checkContext(request, 200_000);
    try std.testing.expectError(error.ContextBudgetExceeded, R.checkContext(request, 10));
    try std.testing.expectError(error.InvalidContextWindow, R.checkContext(request, 0));
    try std.testing.expectEqual(@as(usize, 1), draft.items.items.len);
}

test "AI context budget counts complete dynamic and legacy tool declarations without per-tool padding" {
    const budget = @import("ai/local_text_request.zig");
    const definitions = [_]provider.ToolDefinition{
        .{ .tool = .run_command, .session_ids = &.{101} },
        .{ .session_ids = &.{}, .authority = .conversation_context, .dynamic = .{ .id = "host.context", .name = "host__context", .description = "Read \"context\"", .schema = "{\"type\":\"object\"}" } },
    };
    const request: provider.ChatRequest = .{ .model = "fixture", .system = "rules", .messages = &.{.{ .content = "question" }}, .tools = &definitions };
    const body = try http.requestBody(std.testing.allocator, .openai_compat, request, 200_000);
    defer std.testing.allocator.free(body);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, body, .{});
    defer parsed.deinit();
    const catalog = try std.json.Stringify.valueAlloc(std.testing.allocator, parsed.value.object.get("tools").?, .{});
    defer std.testing.allocator.free(catalog);
    try std.testing.expectEqual(catalog.len, try http.toolCatalogBytes(&definitions));
    try std.testing.expectEqual((catalog.len + 3) / 4, try budget.toolTokens(&definitions));
    try std.testing.expectEqual(try budget.fixedTokens(request) + budget.draftTokens("question"), try budget.inputTokens(request));
    try std.testing.expectEqual(@as(usize, 0), try budget.toolTokens(&.{}));
    // Removing the declarations changes admission by exactly their measured cost.
    var plain = request;
    plain.tools = &.{};
    try std.testing.expectEqual(try budget.toolTokens(&definitions), (try budget.inputTokens(request)) - (try budget.inputTokens(plain)));
}

test "AI context budget fixed overhead rejects before compaction and preserves history" {
    const compaction = @import("ai/context_compaction.zig");
    const History = @import("ai/wire_history.zig").History;
    const budget = @import("ai/local_text_request.zig");
    var history = try History.copy(std.testing.allocator, &.{.{ .content = "keep original history" }}, "");
    defer history.deinit();
    const original = compaction.fingerprint(history.messages);
    var service: compaction.Service = .{};
    defer service.deinit();
    const config: @import("ai/provider_config.zig").ProviderConfig = .{ .kind = .openai_compat, .endpoint = "http://127.0.0.1:1/v1", .model = "fixture", .auth = .none, .context_window = 8192 };
    const identity: compaction.Identity = .{ .owner = .{ .session = 101 }, .conversation = 1, .revision = 1 };
    // Fixed input alone exceeds the window, including with automatic output.
    try std.testing.expectError(error.ContextFixedOverhead, service.startReserved(config, identity, &history, 8193));
    try std.testing.expect(service.job == null);
    try std.testing.expectEqual(compaction.Status.idle, service.status);
    try std.testing.expectEqual(original, compaction.fingerprint(history.messages));
    try budget.checkFixedBudget(6144, budget.outputTokens(4096, 8192), 8192);
}
