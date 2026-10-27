const std = @import("std");
const transport = @import("provider_transport.zig");
const json = @import("provider_json.zig");
const provider = @import("provider.zig");
const provider_config = @import("provider_config.zig");
const registry = @import("registry.zig");

pub const Client = struct {
    allocator: std.mem.Allocator,
    transport: transport.Transport,
    stream_kind: json.StreamKind,

    pub const Binding = struct {
        client: *Client,
        config: provider_config.ProviderConfig,

        pub fn asProvider(self: *Binding) provider.Provider {
            return .{ .ctx = self, .chat = Binding.chat, .models = Binding.models };
        }

        fn chat(ctx: *anyopaque, request: provider.ChatRequest, sink: *const fn (*anyopaque, provider.Delta) void, sink_ctx: *anyopaque) !provider.ChatStats {
            const self: *Binding = @ptrCast(@alignCast(ctx));
            var capture = Capture{ .sink = sink, .ctx = sink_ctx, .stats = .{} };
            const actual = try self.client.chatWithStats(self.config, request, Capture.receive, &capture);
            // Providers without usage retain the legacy byte-count estimate.
            if (actual) |stats| return stats;
            capture.stats.usage_reported = false;
            return capture.stats;
        }

        fn models(ctx: *anyopaque, allocator: std.mem.Allocator) ![]provider.ModelInfo {
            const self: *Binding = @ptrCast(@alignCast(ctx));
            return self.client.models(self.config, allocator);
        }
    };

    const Capture = struct {
        sink: *const fn (*anyopaque, provider.Delta) void,
        ctx: *anyopaque,
        stats: provider.ChatStats,
        fn receive(ctx: *anyopaque, delta: provider.Delta) void {
            const self: *Capture = @ptrCast(@alignCast(ctx));
            switch (delta) {
                .text, .thinking => |value| self.stats.output_tokens += @intCast(value.len),
                else => {},
            }
            self.sink(self.ctx, delta);
        }
    };

    pub fn init(allocator: std.mem.Allocator, injected: transport.Transport, kind: json.StreamKind) Client {
        return .{ .allocator = allocator, .transport = injected, .stream_kind = kind };
    }

    /// Production client using the TLS-capable native transport. The context
    /// must outlive this client and its chat call.
    pub fn native(allocator: std.mem.Allocator, context: *transport.NativeContext, kind: json.StreamKind) Client {
        return init(allocator, transport.native(context), kind);
    }

    pub fn chat(self: *Client, config: provider_config.ProviderConfig, request: provider.ChatRequest, sink: json.JsonDeltaSink, sink_ctx: *anyopaque) !void {
        _ = try self.chatWithStats(config, request, sink, sink_ctx);
    }

    pub fn chatWithStats(self: *Client, config: provider_config.ProviderConfig, request: provider.ChatRequest, sink: json.JsonDeltaSink, sink_ctx: *anyopaque) !?provider.ChatStats {
        if (!std.mem.eql(u8, @tagName(config.kind), @tagName(self.stream_kind))) return error.ProviderProtocolMismatch;
        var stream = json.Stream.initWithKind(self.allocator, self.stream_kind, sink, sink_ctx);
        defer stream.deinit();
        _ = try transport.requestStream(self.allocator, self.transport, config, request, receiveChunk, &stream);
        try stream.finish();
        return if (stream.adapter.usage_seen) stream.stats else null;
    }

    fn receiveChunk(ctx: *anyopaque, bytes: []const u8) !void {
        const stream: *json.Stream = @ptrCast(@alignCast(ctx));
        try stream.feed(bytes);
    }

    pub fn models(self: *Client, config: provider_config.ProviderConfig, allocator: std.mem.Allocator) ![]provider.ModelInfo {
        _ = self;
        var result = try allocator.alloc(provider.ModelInfo, 1);
        result[0] = .{ .id = config.model, .context_window = config.context_window };
        return result;
    }
};

test "provider client reports malformed provider response" {
    const Mock = struct {
        fn send(_: *anyopaque, _: @import("provider_http.zig").RequestPlan, _: []const u8, allocator: std.mem.Allocator) !transport.Response {
            return .{ .status = 200, .body = try allocator.dupe(u8, "data: {bad-json}\n\n") };
        }
    };
    const Sink = struct {
        fn receive(_: *anyopaque, _: provider.Delta) void {}
    };
    var client = Client.init(std.testing.allocator, .{ .ctx = undefined, .send = Mock.send }, .openai_compat);
    var config = provider_config.defaults(.openai_compat);
    config.endpoint = "https://api.example.test/v1/chat";
    try client.chat(config, .{ .model = "m", .effort = .low, .system = "", .messages = &.{} }, Sink.receive, undefined);
}

test "provider client composes injected response with SSE JSON stream" {
    const Mock = struct {
        fn send(_: *anyopaque, _: @import("provider_http.zig").RequestPlan, _: []const u8, allocator: std.mem.Allocator) !transport.Response {
            return .{ .status = 200, .body = try allocator.dupe(u8, "data: {\"choices\":[{\"delta\":{\"content\":\"ok\"}}]}\n\ndata: [DONE]\n\n") };
        }
    };
    const Capture = struct {
        text: usize = 0,
        done: bool = false,
        fn receive(ctx: *anyopaque, delta: provider.Delta) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            switch (delta) {
                .text => self.text += 1,
                .done => self.done = true,
                else => {},
            }
        }
    };
    var capture: Capture = .{};
    var client = Client.init(std.testing.allocator, .{ .ctx = undefined, .send = Mock.send }, .openai_compat);
    var config = provider_config.defaults(.openai_compat);
    config.endpoint = "https://api.example.test/v1/chat";
    try client.chat(config, .{ .model = "m", .effort = .low, .system = "", .messages = &.{} }, Capture.receive, &capture);
    try std.testing.expectEqual(@as(usize, 1), capture.text);
    try std.testing.expect(capture.done);
}

test "Ollama binding returns actual usage instead of content length" {
    const Mock = struct {
        fn send(_: *anyopaque, _: @import("provider_http.zig").RequestPlan, _: []const u8, allocator: std.mem.Allocator) !transport.Response {
            return .{ .status = 200, .body = try allocator.dupe(u8, "{\"message\":{\"content\":\"long answer text\"},\"done\":true,\"prompt_eval_count\":2,\"eval_count\":3}\n") };
        }
    };
    const Sink = struct {
        fn receive(_: *anyopaque, _: provider.Delta) void {}
    };
    var client = Client.init(std.testing.allocator, .{ .ctx = undefined, .send = Mock.send }, .ollama);
    var binding = Client.Binding{ .client = &client, .config = provider_config.defaults(.ollama) };
    const p = binding.asProvider();
    const stats = try p.chat(p.ctx, .{ .model = "m", .system = "", .messages = &.{} }, Sink.receive, undefined);
    try std.testing.expectEqual(@as(u32, 2), stats.input_tokens);
    try std.testing.expectEqual(@as(u32, 3), stats.output_tokens);
    var cancel: provider.CancelToken = .{};
    cancel.cancel();
    try std.testing.expectError(error.Cancelled, p.chat(p.ctx, .{ .model = "m", .system = "", .messages = &.{}, .cancel = &cancel }, Sink.receive, undefined));
}

test "provider protocol selection cannot silently parse a different wire adapter" {
    const Mock = struct {
        fn send(_: *anyopaque, _: @import("provider_http.zig").RequestPlan, _: []const u8, _: std.mem.Allocator) !transport.Response {
            return error.MustNotRequest;
        }
        fn receive(_: *anyopaque, _: provider.Delta) void {}
    };
    var client = Client.init(std.testing.allocator, .{ .ctx = undefined, .send = Mock.send }, .openai_compat);
    try std.testing.expectError(error.ProviderProtocolMismatch, client.chat(provider_config.defaults(.anthropic), .{ .model = "m", .system = "", .messages = &.{} }, Mock.receive, undefined));
}
