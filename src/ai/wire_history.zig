//! Conversation context only: original tool calls/results confer no execution
//! authority. Own the provider transcript independently of display cards and
//! the per-turn Loop, retaining image references until replacement or close.
const std = @import("std");
const provider = @import("provider.zig");
const images = @import("image_attachments.zig");

pub const History = struct {
    arena: ?std.heap.ArenaAllocator = null,
    messages: []const provider.Message = &.{},
    failure: ?anyerror = null,
    pub const max_messages = 512;
    pub const max_text_bytes = 512 * 1024;
    // Aggregate retained image memory is finite across the conversation, in
    // addition to each image's existing decode and request/context limits.
    pub const max_image_bytes = images.max_bytes * images.max_count;
    pub const max_image_pixels = 64 * 1024 * 1024;

    pub fn deinit(self: *History) void {
        for (self.messages) |message| for (message.images) |reference| {
            var owned = reference;
            owned.release();
        };
        if (self.arena) |*arena| arena.deinit();
        self.* = .{};
    }

    /// Atomic replacement: failure retains the prior owned transcript. Callers
    /// must surface capture failures instead of silently dropping a tool turn.
    pub fn copy(allocator: std.mem.Allocator, source: []const provider.Message, final_text: []const u8) !History {
        const count = source.len + @as(usize, if (final_text.len != 0) 1 else 0);
        if (count > max_messages) return error.ToolTranscriptLimit;
        // Stop and errors may interrupt result allocation. Never persist a
        // dangling assistant call as reusable context or invent its result.
        try @import("provider_http.zig").validateToolMessages(.{ .model = "", .system = "", .messages = source });
        var text_bytes: usize = final_text.len;
        var image_bytes: usize = 0;
        var image_pixels: usize = 0;
        for (source) |message| {
            text_bytes = std.math.add(usize, text_bytes, message.content.len + 32) catch return error.ToolTranscriptLimit;
            if (message.tool_call_id) |id| text_bytes = std.math.add(usize, text_bytes, id.len) catch return error.ToolTranscriptLimit;
            for (message.tool_calls) |call| text_bytes = std.math.add(usize, text_bytes, call.id.len + call.name.len + call.arguments.len + 64) catch return error.ToolTranscriptLimit;
            for (message.images) |reference| {
                const image = reference.content() orelse return error.EmptyAttachmentResult;
                image_bytes = std.math.add(usize, image_bytes, image.bytes.len) catch return error.ToolTranscriptLimit;
                image_pixels = std.math.add(usize, image_pixels, @as(usize, image.width) * image.height) catch return error.ToolTranscriptLimit;
            }
        }
        if (text_bytes > max_text_bytes or image_bytes > max_image_bytes or image_pixels > max_image_pixels) return error.ToolTranscriptLimit;
        var result: History = .{ .arena = std.heap.ArenaAllocator.init(allocator) };
        errdefer result.deinit();
        const a = result.arena.?.allocator();
        const messages = try a.alloc(provider.Message, count);
        for (source, 0..) |message, index| {
            var owned = message;
            owned.content = try a.dupe(u8, message.content);
            if (message.tool_call_id) |id| owned.tool_call_id = try a.dupe(u8, id);
            const calls = try a.alloc(provider.ToolCall, message.tool_calls.len);
            for (message.tool_calls, calls) |call, *clone| clone.* = .{ .id = try a.dupe(u8, call.id), .name = try a.dupe(u8, call.name), .arguments = try a.dupe(u8, call.arguments) };
            owned.tool_calls = calls;
            owned.images = try a.dupe(images.ContentRef, message.images);
            for (owned.images) |reference| _ = reference.retain();
            messages[index] = owned;
            result.messages = messages[0 .. index + 1];
        }
        if (final_text.len != 0) messages[source.len] = .{ .role = .assistant, .content = try a.dupe(u8, final_text) };
        result.messages = messages;
        return result;
    }
};

test "wire history keeps actual tool identities and final answer after source release" {
    const a = std.testing.allocator;
    var source = try History.copy(a, &.{
        .{ .content = "observe" },
        .{ .role = .assistant, .content = "", .tool_calls = &.{.{ .id = "original-call", .name = "synthetic__observe", .arguments = "{\"session_ids\":[2]}" }} },
        .{ .role = .tool, .content = "actual result", .tool_call_id = "original-call" },
    }, "actual final answer");
    var next = try History.copy(a, source.messages, "");
    defer next.deinit();
    source.deinit();
    try std.testing.expectEqual(@as(usize, 4), next.messages.len);
    try std.testing.expectEqual(provider.Role.tool, next.messages[2].role);
    try std.testing.expectEqualStrings("original-call", next.messages[1].tool_calls[0].id);
    try std.testing.expectEqualStrings("original-call", next.messages[2].tool_call_id.?);
    try std.testing.expectEqualStrings("actual final answer", next.messages[3].content);
    try std.testing.expectEqual(@as(usize, 0), next.messages[3].tool_calls.len);
}

test "wire history is bounded and failure never mutates existing context" {
    const a = std.testing.allocator;
    var history = try History.copy(a, &.{.{ .content = "retained" }}, "");
    defer history.deinit();
    const oversized = try a.alloc(u8, History.max_text_bytes + 1);
    defer a.free(oversized);
    @memset(oversized, 'x');
    try std.testing.expectError(error.ToolTranscriptLimit, History.copy(a, &.{}, oversized));
    const too_many = try a.alloc(provider.Message, History.max_messages + 1);
    defer a.free(too_many);
    @memset(too_many, .{ .content = "" });
    try std.testing.expectError(error.ToolTranscriptLimit, History.copy(a, too_many, ""));
    try std.testing.expectEqualStrings("retained", history.messages[0].content);
}

test "wire history retains observation pixels and IDs after original and intermediate release" {
    const a = std.testing.allocator;
    const png = "\x89PNG\r\n\x1a\n\x00\x00\x00\x0dIHDR" ++
        "\x00\x00\x00\x01\x00\x00\x00\x01\x08\x06\x00\x00\x00\x1f\x15\xc4\x89" ++
        "\x00\x00\x00\x0dIDAT\x78\x9c\x63\xf8\xcf\xc0\xf0\x1f\x00\x05\x00\x01\xff\x89\x99\x3d\x1d" ++
        "\x00\x00\x00\x00IEND\xae\x42\x60\x82";
    var original = try images.ContentRef.create(a, "observation", png, 0, .{});
    defer original.release();
    var first = try History.copy(a, &.{
        .{ .role = .assistant, .content = "", .tool_calls = &.{.{ .id = "pixel-call", .name = "synthetic__observe", .arguments = "{}" }} },
        .{ .role = .tool, .content = "actual pixels", .tool_call_id = "pixel-call", .images = &.{original} },
    }, "red pixel");
    defer first.deinit();
    var second = try History.copy(a, first.messages, "");
    defer second.deinit();
    original.release();
    first.deinit();
    const retained = second.messages[1].images[0].content().?;
    try std.testing.expectEqualStrings("pixel-call", second.messages[1].tool_call_id.?);
    try std.testing.expectEqualSlices(u8, png, retained.bytes);
    try std.testing.expectEqual(@as(u32, 1), retained.width);
    const body = try @import("provider_http.zig").requestBody(a, .openai_compat, .{ .model = "gpt-4o", .system = "", .vision = true, .tool_images = true, .messages = second.messages }, 8192);
    defer a.free(body);
    const parsed = try std.json.parseFromSlice(std.json.Value, a, body, .{});
    defer parsed.deinit();
    const wire = @import("tool_trace.zig").summarize(parsed.value);
    try std.testing.expectEqual(@as(usize, 1), wire.image_count);
    try std.testing.expectEqualStrings("pixel-call", wire.result_ids[0]);
    try std.testing.expectEqualStrings("pixel-call", wire.use_ids[0]);
}

test "wire history allocation failure releases partially cloned messages" {
    const Scenario = struct {
        fn run(a: std.mem.Allocator) !void {
            var history = try History.copy(a, &.{
                .{ .role = .assistant, .content = "checking", .tool_calls = &.{.{ .id = "original-call", .name = "read_terminal", .arguments = "{\"session_ids\":[101]}" }} },
                .{ .role = .tool, .content = "actual output", .tool_call_id = "original-call" },
            }, "final answer");
            defer history.deinit();
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Scenario.run, .{});
}

test "wire history new turn keeps prior result without redispatching prior call" {
    const manager_mod = @import("turn_manager.zig");
    const Fixture = struct {
        requests: usize = 0,
        dispatches: usize = 0,
        fn chat(raw: *anyopaque, request: provider.ChatRequest, sink: *const fn (*anyopaque, provider.Delta) void, ctx: *anyopaque) !provider.ChatStats {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.requests += 1;
            if (self.requests == 1 or self.requests == 3) {
                if (self.requests == 3) {
                    try std.testing.expectEqual(@as(usize, 5), request.messages.len);
                    try std.testing.expectEqualStrings("first-call", request.messages[1].tool_calls[0].id);
                    try std.testing.expectEqualStrings("first-call", request.messages[2].tool_call_id.?);
                    try std.testing.expect(std.mem.indexOf(u8, request.messages[2].content, "actual host output") != null);
                    try std.testing.expectEqualStrings("final answer", request.messages[3].content);
                    try std.testing.expectEqualStrings("second question", request.messages[4].content);
                }
                sink(ctx, .{ .tool_plan = .{ .call_id = if (self.requests == 1) "first-call" else "second-call", .index = 0, .name = "read_terminal", .arguments = "{\"session_ids\":[101]}" } });
            } else sink(ctx, .{ .text = "final answer" });
            sink(ctx, .done);
            return .{};
        }
        fn models(_: *anyopaque, a: std.mem.Allocator) ![]provider.ModelInfo {
            return a.alloc(provider.ModelInfo, 0);
        }
        fn execute(raw: *anyopaque, call: manager_mod.tool_loop.Invocation, a: std.mem.Allocator, _: ?*provider.CancelToken) !manager_mod.tool_loop.Outcome {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.dispatches += 1;
            try std.testing.expectEqualStrings(if (self.dispatches == 1) "first-call" else "second-call", call.key.call_id);
            return manager_mod.tool_loop.Outcome.copy(a, &.{.{ .session_id = 101, .status = .succeeded, .stdout = "actual host output" }});
        }
    };
    const a = std.testing.allocator;
    var fixture: Fixture = .{};
    var manager = manager_mod.Manager.init(a);
    defer manager.deinit();
    manager.scope = .{ .owner = .{ .session = 101 }, .members = .{ .ids = .{101} ++ @as([15]u64, @splat(0)), .len = 1 } };
    manager.tool_host = .{ .context = &fixture, .execute = Fixture.execute };
    manager.turn_id = 1;
    const backend: provider.Provider = .{ .ctx = &fixture, .chat = Fixture.chat, .models = Fixture.models };
    const definitions = [_]provider.ToolDefinition{.{ .tool = .read_terminal, .session_ids = &.{101} }};
    _ = try manager.run(backend, .{ .model = "test", .system = "", .messages = &.{.{ .content = "first question" }}, .tools = &definitions, .max_output = 512 });
    var history = try History.copy(a, manager.tool_run.?.messages.items, manager.round_text.items);
    defer history.deinit();
    var next: std.ArrayList(provider.Message) = .empty;
    defer next.deinit(a);
    try next.appendSlice(a, history.messages);
    try next.append(a, .{ .content = "second question" });
    manager.turn_id = 2;
    _ = try manager.run(backend, .{ .model = "test", .system = "", .messages = next.items, .tools = &definitions, .max_output = 512 });
    try std.testing.expectEqual(@as(usize, 4), fixture.requests);
    try std.testing.expectEqual(@as(usize, 2), fixture.dispatches);
    try std.testing.expectEqual(@as(usize, 1), manager.tool_run.?.records.items.len);
    try std.testing.expectEqualStrings("second-call", manager.tool_run.?.records.items[0].key.call_id);
}

test "wire history cancellation keeps actual paired rejection and rejects incomplete calls" {
    const loop_mod = @import("tool_loop.zig");
    const Host = struct {
        fn execute(_: *anyopaque, _: loop_mod.Invocation, _: std.mem.Allocator, _: ?*provider.CancelToken) !loop_mod.Outcome {
            return error.UnexpectedDispatch;
        }
    };
    const a = std.testing.allocator;
    var token: provider.CancelToken = .{};
    token.cancel();
    const scope: @import("tool_scope.zig").Scope = .{ .owner = .{ .session = 101 }, .members = .{ .ids = .{101} ++ @as([15]u64, @splat(0)), .len = 1 } };
    var loop = loop_mod.Loop.init(a, scope, 1, .{});
    defer loop.deinit();
    try loop.start(.{ .model = "test", .system = "", .messages = &.{.{ .content = "cancelled question" }}, .tools = &.{.{ .tool = .read_terminal, .session_ids = &.{101} }} });
    const calls = [_]provider.ToolCall{.{ .id = "cancelled-call", .name = "read_terminal", .arguments = "{\"session_ids\":[101]}" }};
    try loop.complete("", &calls, .{ .context = undefined, .execute = Host.execute }, .{}, 1, &token);
    var history = try History.copy(a, loop.messages.items, "");
    defer history.deinit();
    try std.testing.expectEqual(@as(usize, 3), history.messages.len);
    try std.testing.expectEqualStrings("cancelled-call", history.messages[2].tool_call_id.?);
    try std.testing.expect(std.mem.indexOf(u8, history.messages[2].content, "CancelledBeforeDispatch") != null);
    try std.testing.expectError(error.InvalidToolMessage, History.copy(a, loop.messages.items[0..2], ""));
}

test "wire history ordinary text with no tools survives consecutive manager runs" {
    const manager_mod = @import("turn_manager.zig");
    const Backend = struct {
        fn chat(_: *anyopaque, _: provider.ChatRequest, sink: *const fn (*anyopaque, provider.Delta) void, ctx: *anyopaque) !provider.ChatStats {
            sink(ctx, .{ .text = "text answer" });
            sink(ctx, .done);
            return .{};
        }
        fn models(_: *anyopaque, a: std.mem.Allocator) ![]provider.ModelInfo {
            return a.alloc(provider.ModelInfo, 0);
        }
    };
    const a = std.testing.allocator;
    var manager = manager_mod.Manager.init(a);
    defer manager.deinit();
    manager.scope = .{ .owner = .{ .session = 101 }, .members = .{ .ids = .{101} ++ @as([15]u64, @splat(0)), .len = 1 } };
    manager.turn_id = 1;
    const backend: provider.Provider = .{ .ctx = undefined, .chat = Backend.chat, .models = Backend.models };
    _ = try manager.run(backend, .{ .model = "test", .system = "", .messages = &.{.{ .content = "text question" }} });
    var history = try History.copy(a, manager.tool_run.?.messages.items, manager.round_text.items);
    defer history.deinit();
    try std.testing.expectEqual(@as(usize, 2), history.messages.len);
    try std.testing.expectEqual(provider.Role.user, history.messages[0].role);
    try std.testing.expectEqual(provider.Role.assistant, history.messages[1].role);
    var next: std.ArrayList(provider.Message) = .empty;
    defer next.deinit(a);
    try next.appendSlice(a, history.messages);
    try next.append(a, .{ .content = "next text question" });
    manager.turn_id = 2;
    _ = try manager.run(backend, .{ .model = "test", .system = "", .messages = next.items });
    var completed = try History.copy(a, manager.tool_run.?.messages.items, manager.round_text.items);
    defer completed.deinit();
    try std.testing.expectEqual(@as(usize, 4), completed.messages.len);
    try std.testing.expectEqualStrings("text question", completed.messages[0].content);
    try std.testing.expectEqualStrings("next text question", completed.messages[2].content);
    try std.testing.expectEqualStrings("text answer", completed.messages[3].content);
}
