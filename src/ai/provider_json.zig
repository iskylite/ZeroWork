const std = @import("std");
const provider = @import("provider.zig");
const sse = @import("provider_sse.zig");

pub const JsonDeltaSink = *const fn (*anyopaque, provider.Delta) void;
pub const StreamKind = enum { openai_compat, anthropic, ollama };

/// 将常见 OpenAI-compatible SSE JSON 帧转换为统一 Provider.Delta。
pub const Adapter = struct {
    allocator: std.mem.Allocator,
    sink: JsonDeltaSink,
    sink_ctx: *anyopaque,
    stats: ?*provider.ChatStats = null,
    usage_seen: bool = false,
    failed: bool = false,
    terminal: bool = false,
    openai_text_deltas: usize = 0,
    openai_tool_call_deltas: usize = 0,
    openai_tool_plan_deltas: usize = 0,
    anthropic_stop: bool = false,
    anthropic_tools: [provider.max_tool_calls]AnthropicTool = @splat(.{}),
    anthropic_tool_count: usize = 0,
    const AnthropicTool = struct { block_index: u32 = 0, active: bool = false, arguments_seen: bool = false };

    fn complete(self: *Adapter) void {
        if (self.failed or self.terminal) return;
        self.terminal = true;
        self.sink(self.sink_ctx, .done);
    }

    fn fail(self: *Adapter, message: []const u8) void {
        if (self.failed) return;
        self.failed = true;
        self.sink(self.sink_ctx, .{ .err = message });
    }

    pub fn init(allocator: std.mem.Allocator, sink: JsonDeltaSink, sink_ctx: *anyopaque) Adapter {
        return .{ .allocator = allocator, .sink = sink, .sink_ctx = sink_ctx };
    }

    pub fn receiveFrame(ctx: *anyopaque, frame: sse.Frame) void {
        const self: *Adapter = @ptrCast(@alignCast(ctx));
        self.receive(frame.data) catch |err| {
            std.log.warn("[ai-json] frame parse failed: {s}", .{@errorName(err)});
            self.emitError(err);
        };
    }

    pub fn receive(self: *Adapter, data: []const u8) !void {
        if (std.mem.eql(u8, data, "[DONE]")) {
            @import("tool_trace.zig").emit(.{ .event = "provider_response_done", .protocol = "openai_compat", .text_deltas = self.openai_text_deltas, .tool_call_deltas = self.openai_tool_call_deltas, .tool_plan_deltas = self.openai_tool_plan_deltas });
            self.complete();
            return;
        }
        const Payload = struct {
            choices: ?[]const struct {
                delta: ?struct {
                    content: ?[]const u8 = null,
                    reasoning_content: ?[]const u8 = null,
                    tool_calls: ?[]const struct { id: ?[]const u8 = null, index: u32 = 0, function: ?struct { name: ?[]const u8 = null, arguments: ?[]const u8 = null } = null } = null,
                } = null,
                finish_reason: ?[]const u8 = null,
            } = null,
            @"error": ?struct { message: ?[]const u8 = null } = null,
            usage: ?struct { prompt_tokens: ?u32 = null, completion_tokens: ?u32 = null } = null,
        };
        var parsed = std.json.parseFromSlice(Payload, self.allocator, data, .{ .ignore_unknown_fields = true }) catch |err| {
            @import("tool_trace.zig").emit(.{ .event = "provider_parse_error", .protocol = "openai_compat", .reason = @errorName(err) });
            return err;
        };
        defer parsed.deinit();
        if (parsed.value.usage) |u| if (self.stats) |stats| {
            self.usage_seen = true;
            if (u.prompt_tokens) |v| stats.input_tokens = v;
            if (u.completion_tokens) |v| stats.output_tokens = v;
        };
        if (parsed.value.@"error") |failure| {
            self.fail(failure.message orelse "provider error");
            return;
        }
        const choices = parsed.value.choices orelse return;
        if (choices.len == 0) return;
        const item = choices[0];
        if (item.delta) |delta| {
            if (delta.content) |text| {
                if (text.len != 0) self.openai_text_deltas += 1;
                self.sink(self.sink_ctx, .{ .text = text });
            }
            if (delta.reasoning_content) |thinking| self.sink(self.sink_ctx, .{ .thinking = thinking });
            if (delta.tool_calls) |calls| {
                self.openai_tool_call_deltas += calls.len;
                for (calls) |call| if (call.function) |function| {
                    self.openai_tool_plan_deltas += 1;
                    self.sink(self.sink_ctx, .{ .tool_plan = .{ .call_id = call.id, .index = call.index, .name = function.name, .arguments = function.arguments orelse "" } });
                };
            }
        }
        if (item.finish_reason) |reason| {
            const known = std.mem.eql(u8, reason, "stop") or std.mem.eql(u8, reason, "tool_calls") or std.mem.eql(u8, reason, "function_call") or std.mem.eql(u8, reason, "length") or std.mem.eql(u8, reason, "content_filter");
            @import("tool_trace.zig").emit(.{ .event = "provider_response_finish", .protocol = "openai_compat", .finish_reason = if (known) reason else "other", .text_deltas = self.openai_text_deltas, .tool_call_deltas = self.openai_tool_call_deltas, .tool_plan_deltas = self.openai_tool_plan_deltas });
            if (std.mem.eql(u8, reason, "stop") or std.mem.eql(u8, reason, "tool_calls") or std.mem.eql(u8, reason, "function_call")) self.complete() else self.fail("provider stopped before a complete response");
        }
    }

    pub fn receiveAnthropic(self: *Adapter, data: []const u8) !void {
        if (self.failed or self.terminal) return;
        const Payload = struct {
            type: ?[]const u8 = null,
            index: u32 = 0,
            content_block: ?struct { type: ?[]const u8 = null, id: ?[]const u8 = null, name: ?[]const u8 = null, input: ?std.json.Value = null, text: ?[]const u8 = null } = null,
            delta: ?struct { type: ?[]const u8 = null, text: ?[]const u8 = null, thinking: ?[]const u8 = null, partial_json: ?[]const u8 = null, stop_reason: ?[]const u8 = null } = null,
            @"error": ?struct { message: ?[]const u8 = null } = null,
            usage: ?struct { input_tokens: ?u32 = null, output_tokens: ?u32 = null } = null,
            message: ?struct { usage: ?struct { input_tokens: ?u32 = null, output_tokens: ?u32 = null } = null } = null,
        };
        var parsed = try std.json.parseFromSlice(Payload, self.allocator, data, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();
        const value = parsed.value;
        if (value.message) |message| if (message.usage) |u| if (self.stats) |stats| {
            self.usage_seen = true;
            if (u.input_tokens) |v| stats.input_tokens = v;
            if (u.output_tokens) |v| stats.output_tokens = v;
        };
        if (value.usage) |u| if (self.stats) |stats| {
            self.usage_seen = true;
            if (u.input_tokens) |v| stats.input_tokens = v;
            if (u.output_tokens) |v| stats.output_tokens = v;
        };
        if (value.@"error") |failure| return self.fail(failure.message orelse "provider error");
        const event = value.type orelse return error.MissingEventType;
        if (std.mem.eql(u8, event, "content_block_start")) {
            const block = value.content_block orelse return error.MissingContentBlock;
            if (std.mem.eql(u8, block.type orelse "", "tool_use")) {
                if (self.anthropic_tool_count == provider.max_tool_calls) return error.TooManyTools;
                for (self.anthropic_tools[0..self.anthropic_tool_count]) |previous| if (previous.block_index == value.index) return error.DuplicateToolBlock;
                const slot = self.anthropic_tool_count;
                self.anthropic_tool_count += 1;
                self.anthropic_tools[slot] = .{ .block_index = value.index, .active = true };
                const id = block.id orelse return error.MissingToolCallId;
                const name = block.name orelse return error.MissingToolName;
                self.sink(self.sink_ctx, .{ .tool_plan = .{ .call_id = id, .name = name, .index = @intCast(slot), .arguments = "" } });
                if (block.input) |input| {
                    if (input != .object) return error.InvalidToolArguments;
                    if (input.object.count() != 0) {
                        const encoded = try std.json.Stringify.valueAlloc(self.allocator, input, .{});
                        defer self.allocator.free(encoded);
                        self.anthropic_tools[slot].arguments_seen = true;
                        self.sink(self.sink_ctx, .{ .tool_plan = .{ .call_id = null, .index = @intCast(slot), .arguments = encoded } });
                    }
                }
            } else if (block.text) |text| if (text.len != 0) self.sink(self.sink_ctx, .{ .text = text });
        } else if (std.mem.eql(u8, event, "content_block_delta")) {
            if (value.delta) |delta| {
                if (delta.text) |text| self.sink(self.sink_ctx, .{ .text = text });
                if (delta.thinking) |thinking| self.sink(self.sink_ctx, .{ .thinking = thinking });
                if (delta.partial_json) |partial| {
                    var found = false;
                    for (self.anthropic_tools[0..self.anthropic_tool_count], 0..) |*tool, index| {
                        if (tool.block_index != value.index or !tool.active) continue;
                        tool.arguments_seen = true;
                        self.sink(self.sink_ctx, .{ .tool_plan = .{ .call_id = null, .index = @intCast(index), .arguments = partial } });
                        found = true;
                        break;
                    }
                    if (!found) return error.OrphanToolArguments;
                }
            }
        } else if (std.mem.eql(u8, event, "content_block_stop")) {
            for (self.anthropic_tools[0..self.anthropic_tool_count], 0..) |*tool, index| {
                if (tool.block_index != value.index) continue;
                if (!tool.active) return error.DuplicateToolBlockStop;
                tool.active = false;
                if (!tool.arguments_seen) self.sink(self.sink_ctx, .{ .tool_plan = .{ .call_id = null, .index = @intCast(index), .arguments = "{}" } });
                break;
            }
        } else if (std.mem.eql(u8, event, "message_delta")) {
            if (value.delta) |delta| if (delta.stop_reason) |reason| {
                if (std.mem.eql(u8, reason, "end_turn") or std.mem.eql(u8, reason, "tool_use") or std.mem.eql(u8, reason, "stop_sequence")) {
                    self.anthropic_stop = true;
                } else self.fail("anthropic stopped before a complete response");
            };
        } else if (std.mem.eql(u8, event, "message_stop")) {
            for (self.anthropic_tools[0..self.anthropic_tool_count]) |tool| if (tool.active) return error.IncompleteToolBlock;
            if (!self.anthropic_stop) return error.MissingStopReason;
            self.complete();
        }
    }

    fn emitError(self: *Adapter, err: anyerror) void {
        _ = @errorName(err);
        self.fail("invalid provider JSON");
    }
};

/// 组合 SSE 分帧与 JSON delta 解码，供 HTTP body reader 逐块喂入。
pub const Stream = struct {
    decoder: sse.Decoder,
    adapter: Adapter,
    kind: StreamKind = .openai_compat,
    line_buffer: std.ArrayListUnmanaged(u8),
    ollama_done: bool = false,
    stats: provider.ChatStats = .{},
    ollama_call_count: u32 = 0,
    ollama_request_id: u64 = 0,
    var next_ollama_request: std.atomic.Value(u64) = .init(1);

    pub fn init(allocator: std.mem.Allocator, sink: JsonDeltaSink, sink_ctx: *anyopaque) Stream {
        return initWithKind(allocator, .openai_compat, sink, sink_ctx);
    }

    pub fn initWithKind(allocator: std.mem.Allocator, kind: StreamKind, sink: JsonDeltaSink, sink_ctx: *anyopaque) Stream {
        var stream: Stream = undefined;
        stream.decoder = sse.Decoder.init(allocator);
        stream.adapter = Adapter.init(allocator, sink, sink_ctx);
        stream.kind = kind;
        stream.line_buffer = .empty;
        stream.stats = .{};
        stream.ollama_done = false;
        stream.ollama_call_count = 0;
        stream.ollama_request_id = next_ollama_request.fetchAdd(1, .monotonic);
        return stream;
    }

    pub fn deinit(self: *Stream) void {
        self.decoder.deinit();
        self.line_buffer.deinit(self.adapter.allocator);
        self.* = undefined;
    }

    pub fn feed(self: *Stream, bytes: []const u8) !void {
        if (self.kind == .ollama) return self.feedOllama(bytes);
        self.adapter.stats = &self.stats;
        try self.decoder.feed(bytes, Stream.receiveFrame, self);
    }

    pub fn finish(self: *Stream) !void {
        if (self.kind == .ollama) {
            if (self.line_buffer.items.len != 0) try self.receiveOllama(self.line_buffer.items);
            self.line_buffer.clearRetainingCapacity();
            if (!self.ollama_done and !self.adapter.failed) self.adapter.fail("ollama stream ended without done");
            return;
        }
        self.adapter.stats = &self.stats;
        try self.decoder.finish(Stream.receiveFrame, self);
        if (!self.adapter.terminal and !self.adapter.failed) self.adapter.fail("provider stream ended without completion");
    }

    fn feedOllama(self: *Stream, bytes: []const u8) !void {
        var remaining = bytes;
        while (remaining.len != 0) {
            const index = std.mem.indexOfScalar(u8, remaining, '\n');
            const count = index orelse remaining.len;
            if (self.line_buffer.items.len + count > 1024 * 1024) return error.ProviderLineTooLarge;
            try self.line_buffer.appendSlice(self.adapter.allocator, remaining[0..count]);
            if (index == null) break;
            const trimmed = std.mem.trim(u8, self.line_buffer.items, " \t\r");
            if (trimmed.len != 0) try self.receiveOllama(trimmed);
            self.line_buffer.clearRetainingCapacity();
            remaining = remaining[count + 1 ..];
        }
    }

    fn receiveOllama(self: *Stream, data: []const u8) !void {
        if (self.adapter.failed or self.adapter.terminal) return;
        const Payload = struct {
            message: ?struct {
                content: ?[]const u8 = null,
                thinking: ?[]const u8 = null,
                tool_calls: ?[]const struct { id: ?[]const u8 = null, function: struct { index: ?u32 = null, name: []const u8, arguments: std.json.Value } } = null,
            } = null,
            done_reason: ?[]const u8 = null,
            done: bool = false,
            error_message: ?[]const u8 = null,
            @"error": ?[]const u8 = null,
            eval_count: ?u32 = null,
            prompt_eval_count: ?u32 = null,
        };
        var parsed = std.json.parseFromSlice(Payload, self.adapter.allocator, data, .{ .ignore_unknown_fields = true }) catch |err| {
            self.ollama_done = true;
            self.adapter.emitError(err);
            return;
        };
        defer parsed.deinit();
        if (parsed.value.prompt_eval_count) |v| {
            self.stats.input_tokens = v;
            self.adapter.usage_seen = true;
        }
        if (parsed.value.eval_count) |v| {
            self.stats.output_tokens = v;
            self.adapter.usage_seen = true;
        }
        if (parsed.value.@"error" orelse parsed.value.error_message) |message| {
            self.ollama_done = true;
            self.adapter.fail(message);
            return;
        }
        if (parsed.value.message) |message| {
            if (message.content) |text| if (text.len != 0) self.adapter.sink(self.adapter.sink_ctx, .{ .text = text });
            if (message.thinking) |thinking| if (thinking.len != 0) self.adapter.sink(self.adapter.sink_ctx, .{ .thinking = thinking });
            if (message.tool_calls) |calls| for (calls) |call| {
                if (call.function.arguments != .object) return error.InvalidToolArguments;
                if (self.ollama_call_count >= provider.max_tool_calls) return error.TooManyTools;
                const index = call.function.index orelse self.ollama_call_count;
                if (index >= provider.max_tool_calls) return error.TooManyTools;
                var id_buffer: [96]u8 = undefined;
                // Native Ollama usually has no ID. Use a per-request host
                // correlation ID; preserve an actual provider ID verbatim.
                const id = call.id orelse try std.fmt.bufPrint(&id_buffer, "ollama-{d}-{d}", .{ self.ollama_request_id, index });
                const arguments = try std.json.Stringify.valueAlloc(self.adapter.allocator, call.function.arguments, .{});
                defer self.adapter.allocator.free(arguments);
                self.adapter.sink(self.adapter.sink_ctx, .{ .tool_plan = .{ .call_id = id, .name = call.function.name, .index = index, .arguments = arguments } });
                self.ollama_call_count += 1;
            };
        }
        if (parsed.value.done and !self.ollama_done) {
            self.ollama_done = true;
            if (parsed.value.done_reason) |reason| {
                if (!std.mem.eql(u8, reason, "stop")) return self.adapter.fail("ollama stopped before a complete response");
            }
            self.adapter.complete();
        }
    }

    fn receiveFrame(ctx: *anyopaque, frame: sse.Frame) void {
        const self: *Stream = @ptrCast(@alignCast(ctx));
        if (self.kind == .anthropic) {
            self.adapter.receiveAnthropic(frame.data) catch |err| self.adapter.emitError(err);
        } else {
            self.adapter.receive(frame.data) catch |err| self.adapter.emitError(err);
        }
    }
};

test "json delta adapter parses real mimo stream frames" {
    // Regression fixture: frames captured verbatim from the mimo-v2.6-flash
    // live stream (round-6 diagnostics). If one of these fails to parse,
    // the AI turn fails with StreamCallbackFailed("invalid provider JSON").
    const Capture = struct {
        text: usize = 0,
        thinking: usize = 0,
        done: bool = false,
        fn receive(ctx: *anyopaque, delta: provider.Delta) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            switch (delta) {
                .text => self.text += 1,
                .thinking => self.thinking += 1,
                .done => self.done = true,
                else => {},
            }
        }
    };
    var capture: Capture = .{};
    var adapter = Adapter.init(std.testing.allocator, Capture.receive, &capture);
    // First frame: empty content, role set, everything null.
    try adapter.receive("{\"id\":\"9ec57133-0712\",\"choices\":[{\"delta\":{\"content\":\"\",\"role\":\"assistant\",\"tool_calls\":null,\"reasoning_content\":null},\"finish_reason\":null,\"index\":0}],\"created\":1791744564,\"model\":\"mimo-v2.6-flash\",\"object\":\"chat.completion.chunk\"}");
    // Reasoning frame: content null, reasoning_content set.
    try adapter.receive("{\"id\":\"9ec57133\",\"choices\":[{\"delta\":{\"content\":null,\"role\":null,\"tool_calls\":null,\"reasoning_content\":\",\"},\"finish_reason\":null,\"index\":0}],\"created\":1791744564,\"model\":\"mimo-v2.6-flash\",\"object\":\"chat.completion.chunk\"}");
    // Content frame.
    try adapter.receive("{\"id\":\"9ec57133\",\"choices\":[{\"delta\":{\"content\":\"Hello!\",\"role\":null,\"tool_calls\":null,\"reasoning_content\":null},\"finish_reason\":null,\"index\":0}],\"created\":1791744564,\"model\":\"mimo-v2.6-flash\",\"object\":\"chat.completion.chunk\"}");
    // Stop frame with usage null.
    try adapter.receive("{\"id\":\"9ec57133\",\"choices\":[{\"delta\":{\"content\":null,\"role\":null,\"tool_calls\":null,\"reasoning_content\":null},\"finish_reason\":\"stop\",\"index\":0}],\"created\":1791744677,\"model\":\"mimo-v2.6-flash\",\"object\":\"chat.completion.chunk\",\"usage\":null}");
    // Usage frame with nested objects and empty choices.
    try adapter.receive("{\"id\":\"9ec57133\",\"choices\":[],\"created\":1791744677,\"model\":\"mimo-v2.6-flash\",\"object\":\"chat.completion.chunk\",\"usage\":{\"completion_tokens\":202,\"prompt_tokens\":8,\"total_tokens\":210,\"completion_tokens_details\":{\"reasoning_tokens\":167},\"prompt_tokens_details\":{\"cached_tokens\":0}}}");
    try adapter.receive("[DONE]");
    try std.testing.expect(capture.done);
    try std.testing.expect(capture.text >= 1);
    try std.testing.expect(capture.thinking >= 1);
}

test "json delta adapter maps content and finish" {
    const Capture = struct {
        count: usize = 0,
        done: bool = false,
        fn receive(ctx: *anyopaque, delta: provider.Delta) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            switch (delta) {
                .text => self.count += 1,
                .done => self.done = true,
                else => {},
            }
        }
    };
    var capture: Capture = .{};
    var adapter = Adapter.init(std.testing.allocator, Capture.receive, &capture);
    try adapter.receive("{\"choices\":[{\"delta\":{\"content\":\"hi\"},\"finish_reason\":null}]}");
    try adapter.receive("{\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}");
    try std.testing.expectEqual(@as(usize, 1), capture.count);
    try std.testing.expect(capture.done);
}

test "anthropic delta adapter maps message stream" {
    const Capture = struct {
        text_count: usize = 0,
        done: bool = false,
        fn receive(ctx: *anyopaque, delta: provider.Delta) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            switch (delta) {
                .text => self.text_count += 1,
                .done => self.done = true,
                else => {},
            }
        }
    };
    var capture: Capture = .{};
    var adapter = Adapter.init(std.testing.allocator, Capture.receive, &capture);
    try adapter.receiveAnthropic("{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"hi\"}}");
    try adapter.receiveAnthropic("{\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"}}");
    try adapter.receiveAnthropic("{\"type\":\"message_stop\"}");
    try std.testing.expectEqual(@as(usize, 1), capture.text_count);
    try std.testing.expect(capture.done);
}

test "anthropic stream routes SSE frames to Anthropic decoder" {
    const Capture = struct {
        text_count: usize = 0,
        done: bool = false,
        fn receive(ctx: *anyopaque, delta: provider.Delta) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            switch (delta) {
                .text => self.text_count += 1,
                .done => self.done = true,
                else => {},
            }
        }
    };
    var capture: Capture = .{};
    var stream = Stream.initWithKind(std.testing.allocator, .anthropic, Capture.receive, &capture);
    defer stream.deinit();
    try stream.feed("data: {\"type\":\"content_block_delta\",\"delta\":{\"text\":\"hi\"}}\n\n");
    try stream.feed("data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"}}\n\n");
    try stream.feed("data: {\"type\":\"message_stop\"}\n\n");
    try std.testing.expectEqual(@as(usize, 1), capture.text_count);
    try std.testing.expect(capture.done);
}

test "json stream combines fragmented SSE frames" {
    const Capture = struct {
        text_count: usize = 0,
        done: bool = false,
        fn receive(ctx: *anyopaque, delta: provider.Delta) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            switch (delta) {
                .text => self.text_count += 1,
                .done => self.done = true,
                else => {},
            }
        }
    };
    var capture: Capture = .{};
    var stream = Stream.init(std.testing.allocator, Capture.receive, &capture);
    defer stream.deinit();
    try stream.feed("data: {\"choices\":[{\"delta\":{\"content\":\"hi\"},\"finish_reason\":null}]}\n\n");
    try stream.feed("data: [DONE]\n\n");
    try stream.finish();
    try std.testing.expectEqual(@as(usize, 1), capture.text_count);
    try std.testing.expect(capture.done);
}

test "ollama NDJSON handles fragmented utf8, thinking, usage and one finish" {
    const Capture = struct {
        text: usize = 0,
        thinking: usize = 0,
        done: usize = 0,
        fn receive(ctx: *anyopaque, delta: provider.Delta) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            switch (delta) {
                .text => self.text += 1,
                .thinking => self.thinking += 1,
                .done => self.done += 1,
                else => {},
            }
        }
    };
    var capture: Capture = .{};
    var stream = Stream.initWithKind(std.testing.allocator, .ollama, Capture.receive, &capture);
    defer stream.deinit();
    const payload = "{\"message\":{\"content\":\"世界\",\"thinking\":\"考\"},\"done\":false}\n{\"done\":true,\"eval_count\":3,\"prompt_eval_count\":2}\n";
    for (payload) |byte| try stream.feed(&.{byte});
    try stream.finish();
    try std.testing.expectEqual(@as(usize, 1), capture.text);
    try std.testing.expectEqual(@as(u32, 2), stream.stats.input_tokens);
    try std.testing.expectEqual(@as(u32, 3), stream.stats.output_tokens);
    try std.testing.expectEqual(@as(usize, 1), capture.thinking);
    try std.testing.expectEqual(@as(usize, 1), capture.done);
}

test "ollama NDJSON exposes provider error and missing done" {
    const Capture = struct {
        errors: usize = 0,
        fn receive(ctx: *anyopaque, delta: provider.Delta) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            if (delta == .err) self.errors += 1;
        }
    };
    var capture: Capture = .{};
    var stream = Stream.initWithKind(std.testing.allocator, .ollama, Capture.receive, &capture);
    defer stream.deinit();
    try stream.feed("{\"error\":\"bad model\"}\n");
    try stream.finish();
    try std.testing.expectEqual(@as(usize, 1), capture.errors);
}

test "SSE usage preserves OpenAI and Anthropic actual token counts" {
    const Sink = struct {
        fn receive(_: *anyopaque, _: provider.Delta) void {}
    };
    var openai = Stream.initWithKind(std.testing.allocator, .openai_compat, Sink.receive, undefined);
    defer openai.deinit();
    try openai.feed("data: {\"choices\":[],\"usage\":{\"prompt_tokens\":2,\"completion_tokens\":3}}\n\n");
    try std.testing.expectEqual(@as(u32, 2), openai.stats.input_tokens);
    try std.testing.expectEqual(@as(u32, 3), openai.stats.output_tokens);
    var anthropic = Stream.initWithKind(std.testing.allocator, .anthropic, Sink.receive, undefined);
    defer anthropic.deinit();
    try anthropic.feed("data: {\"type\":\"message_start\",\"message\":{\"usage\":{\"input_tokens\":2,\"output_tokens\":0}}}\n\n");
    try anthropic.feed("data: {\"type\":\"message_delta\",\"usage\":{\"output_tokens\":3}}\n\n");
    try std.testing.expectEqual(@as(u32, 2), anthropic.stats.input_tokens);
    try std.testing.expectEqual(@as(u32, 3), anthropic.stats.output_tokens);
}

test "Ollama missing termination and bounded lines" {
    const Sink = struct {
        errors: usize = 0,
        fn receive(ctx: *anyopaque, delta: provider.Delta) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            if (delta == .err) self.errors += 1;
        }
    };
    var sink: Sink = .{};
    var stream = Stream.initWithKind(std.testing.allocator, .ollama, Sink.receive, &sink);
    defer stream.deinit();
    try stream.feed("{\"message\":{\"content\":\"ok\"}}\n");
    try stream.finish();
    try std.testing.expectEqual(@as(usize, 1), sink.errors);
    const oversized = try std.testing.allocator.alloc(u8, 1024 * 1024 + 1);
    defer std.testing.allocator.free(oversized);
    @memset(oversized, 'x');
    try std.testing.expectError(error.ProviderLineTooLarge, stream.feed(oversized));
}

const NativeToolCapture = struct {
    id: [256]u8 = undefined,
    id_len: usize = 0,
    name: [64]u8 = undefined,
    name_len: usize = 0,
    arguments: [2048]u8 = undefined,
    argument_len: usize = 0,
    tool_events: usize = 0,
    index: u32 = 999,
    done: usize = 0,
    errors: usize = 0,
    fn receive(raw: *anyopaque, delta: provider.Delta) void {
        const self: *@This() = @ptrCast(@alignCast(raw));
        switch (delta) {
            .tool_plan => |call| {
                self.tool_events += 1;
                self.index = call.index;
                if (call.call_id) |id| {
                    self.id_len = id.len;
                    @memcpy(self.id[0..id.len], id);
                }
                if (call.name) |name| {
                    self.name_len = name.len;
                    @memcpy(self.name[0..name.len], name);
                }
                @memcpy(self.arguments[self.argument_len..][0..call.arguments.len], call.arguments);
                self.argument_len += call.arguments.len;
            },
            .done => self.done += 1,
            .err => self.errors += 1,
            else => {},
        }
    }
};

test "Anthropic fragmented tool stream preserves original identity and waits for message_stop" {
    var capture: NativeToolCapture = .{};
    var stream = Stream.initWithKind(std.testing.allocator, .anthropic, NativeToolCapture.receive, &capture);
    defer stream.deinit();
    const start = "event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":42,\"content_block\":{\"type\":\"tool_use\",\"id\":\"toolu_original\",\"name\":\"unknown_tool\",\"input\":{}}}\n\n";
    for (start) |byte| try stream.feed(&.{byte});
    try stream.feed("data: {\"type\":\"content_block_delta\",\"index\":42,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"session_ids\\\":[101],\"}}\n\n");
    try stream.feed("data: {\"type\":\"content_block_delta\",\"index\":42,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"\\\"command\\\":\\\"pwd\\\"}\"}}\n\n");
    try stream.feed("data: {\"type\":\"content_block_stop\",\"index\":42}\n\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"}}\n\n");
    try std.testing.expectEqual(@as(usize, 0), capture.done);
    try stream.feed("data: {\"type\":\"message_stop\"}\n\n");
    try stream.finish();
    try std.testing.expectEqualStrings("toolu_original", capture.id[0..capture.id_len]);
    try std.testing.expectEqualStrings("unknown_tool", capture.name[0..capture.name_len]);
    try std.testing.expectEqualStrings("{\"session_ids\":[101],\"command\":\"pwd\"}", capture.arguments[0..capture.argument_len]);
    try std.testing.expectEqual(@as(u32, 0), capture.index);
    try std.testing.expectEqual(@as(usize, 1), capture.done);
    try std.testing.expectEqual(@as(usize, 0), capture.errors);
}

test "native incomplete tool responses fail without a completion event" {
    const cases = [_]struct { kind: StreamKind, wire: []const u8 }{
        .{ .kind = .anthropic, .wire = "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"call\",\"name\":\"run_command\",\"input\":{}}}\n\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"partial_json\":\"{partial\"}}\n\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"max_tokens\"}}\n\ndata: {\"type\":\"message_stop\"}\n\n" },
        .{ .kind = .anthropic, .wire = "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"}}\n\n" },
        .{ .kind = .ollama, .wire = "{\"message\":{\"tool_calls\":[{\"function\":{\"name\":\"run_command\",\"arguments\":{}}}]},\"done\":false}\n" },
        .{ .kind = .ollama, .wire = "{\"message\":{\"content\":\"partial\"},\"done\":true,\"done_reason\":\"length\"}\n" },
    };
    for (cases) |case| {
        var capture: NativeToolCapture = .{};
        var stream = Stream.initWithKind(std.testing.allocator, case.kind, NativeToolCapture.receive, &capture);
        defer stream.deinit();
        try stream.feed(case.wire);
        try stream.finish();
        try std.testing.expectEqual(@as(usize, 0), capture.done);
        try std.testing.expectEqual(@as(usize, 1), capture.errors);
    }
}

test "Ollama native object tools preserve supplied ID and use unique host IDs when absent" {
    var first: NativeToolCapture = .{};
    var second: NativeToolCapture = .{};
    for ([_]*NativeToolCapture{ &first, &second }) |capture| {
        var stream = Stream.initWithKind(std.testing.allocator, .ollama, NativeToolCapture.receive, capture);
        defer stream.deinit();
        const wire = "{\"message\":{\"tool_calls\":[{\"function\":{\"index\":0,\"name\":\"unknown_tool\",\"arguments\":{\"session_ids\":[101]}}}]},\"done\":false}\n{\"done\":true,\"done_reason\":\"stop\"}\n";
        for (wire) |byte| try stream.feed(&.{byte});
        try stream.finish();
        try std.testing.expectEqualStrings("{\"session_ids\":[101]}", capture.arguments[0..capture.argument_len]);
        try std.testing.expectEqualStrings("unknown_tool", capture.name[0..capture.name_len]);
        try std.testing.expectEqual(@as(usize, 1), capture.done);
        try std.testing.expectEqual(@as(usize, 0), capture.errors);
    }
    try std.testing.expect(!std.mem.eql(u8, first.id[0..first.id_len], second.id[0..second.id_len]));
    var actual: NativeToolCapture = .{};
    var stream = Stream.initWithKind(std.testing.allocator, .ollama, NativeToolCapture.receive, &actual);
    defer stream.deinit();
    try stream.feed("{\"message\":{\"tool_calls\":[{\"id\":\"provider-original\",\"function\":{\"name\":\"read_terminal\",\"arguments\":{}}}]},\"done\":true}\n");
    try stream.finish();
    try std.testing.expectEqualStrings("provider-original", actual.id[0..actual.id_len]);
}

test "json delta adapter response metadata counts text and original tool deltas" {
    const Sink = struct {
        fn receive(_: *anyopaque, _: provider.Delta) void {}
    };
    var adapter = Adapter.init(std.testing.allocator, Sink.receive, undefined);
    try adapter.receive("{\"choices\":[{\"delta\":{\"content\":\"checking\"}}]}");
    try adapter.receive("{\"choices\":[{\"delta\":{\"tool_calls\":[{\"id\":\"original\",\"function\":{\"name\":\"read_terminal\",\"arguments\":\"{}\"}}]},\"finish_reason\":\"tool_calls\"}]}");
    try std.testing.expectEqual(@as(usize, 1), adapter.openai_text_deltas);
    try std.testing.expectEqual(@as(usize, 1), adapter.openai_tool_call_deltas);
    try std.testing.expectEqual(@as(usize, 1), adapter.openai_tool_plan_deltas);
    try std.testing.expect(adapter.terminal);
}
