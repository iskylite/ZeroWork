const std = @import("std");
const http = @import("provider_http.zig");
const provider = @import("provider.zig");
const provider_config = @import("provider_config.zig");
const registry = @import("registry.zig");

pub const max_response_bytes: usize = 8 * 1024 * 1024;
/// An owned transport response. `send` allocates `body` with the allocator it
/// receives; the caller must call `deinit` exactly once, including on errors
/// encountered after `send` returns.
pub const Response = struct {
    status: u16,
    body: []u8,
    retry_after_ms: ?u32 = null,
    owned: bool = true,

    /// Transfers body ownership to the caller and leaves this response inert.
    pub fn takeBody(self: *Response) []u8 {
        const body = self.body;
        self.body = &.{};
        self.owned = false;
        return body;
    }

    pub fn deinit(self: *Response, allocator: std.mem.Allocator) void {
        if (self.owned) allocator.free(self.body);
        self.* = undefined;
    }
};
pub const ResponseMeta = struct {
    status: u16,
    retry_after_ms: ?u32 = null,
};
/// Bytes are borrowed only for this call. Returning an error stops the read.
pub const ChunkSink = *const fn (*anyopaque, []const u8) anyerror!void;
pub const StreamSend = *const fn (*anyopaque, http.RequestPlan, []const u8, std.mem.Allocator, ChunkSink, *anyopaque) anyerror!ResponseMeta;
pub const Transport = struct {
    ctx: *anyopaque,
    send: *const fn (*anyopaque, http.RequestPlan, []const u8, std.mem.Allocator) anyerror!Response,
    /// Serial callbacks occur during this call, only for successful HTTP
    /// responses. No callback may outlive the call, including cancellation.
    send_stream: ?StreamSend = null,
};

/// Production HTTPS transport backed by Zig's TLS-enabled std.http client.
/// The caller owns the Io and keeps it alive for the duration of the request.
pub const NativeContext = struct { io: std.Io, diagnostic: http.Diagnostic = .{} };

pub fn native(ctx: *NativeContext) Transport {
    return .{ .ctx = ctx, .send = nativeSend, .send_stream = nativeSendStream };
}

fn nativeSend(raw: *anyopaque, plan: http.RequestPlan, body: []const u8, allocator: std.mem.Allocator) !Response {
    const context: *NativeContext = @ptrCast(@alignCast(raw));
    context.diagnostic = .{};
    return sendBounded(context.io, raw, nativeSendUnbounded, plan, body, allocator);
}

fn nativeSendStream(raw: *anyopaque, plan: http.RequestPlan, body: []const u8, allocator: std.mem.Allocator, sink: ChunkSink, sink_ctx: *anyopaque) !ResponseMeta {
    const context: *NativeContext = @ptrCast(@alignCast(raw));
    context.diagnostic = .{};
    return sendStreamBounded(context.io, raw, nativeSendStreamUnbounded, plan, body, allocator, sink, sink_ctx);
}

const SendJob = struct {
    raw: *anyopaque,
    send: @FieldType(Transport, "send"),
    plan: http.RequestPlan,
    body: []const u8,
    allocator: std.mem.Allocator,
    done: std.atomic.Value(bool) = .init(false),

    fn run(self: *@This()) anyerror!Response {
        const result = self.send(self.raw, self.plan, self.body, self.allocator);
        self.done.store(true, .release);
        return result;
    }
};

/// Keep the request, response head and response body under the same deadline.
/// Future.cancel interrupts blocked Io operations and joins before borrowed
/// request buffers leave scope. A cancelled operation can still return an
/// owned response if completion raced with Stop; release it in that case.
fn sendBounded(io: std.Io, raw: *anyopaque, send: @FieldType(Transport, "send"), plan: http.RequestPlan, body: []const u8, allocator: std.mem.Allocator) !Response {
    if (plan.cancel) |token| if (token.isCancelled()) return error.Cancelled;
    if (plan.timeout_ms == 0) return error.Timeout;
    var job: SendJob = .{ .raw = raw, .send = send, .plan = plan, .body = body, .allocator = allocator };
    var future = try std.Io.concurrent(io, SendJob.run, .{&job});
    const started = std.Io.Clock.Timestamp.now(io, .awake);
    while (!job.done.load(.acquire)) {
        const cancelled = if (plan.cancel) |token| token.isCancelled() else false;
        const elapsed = started.durationTo(std.Io.Clock.Timestamp.now(io, .awake)).raw.toMilliseconds();
        if (cancelled or elapsed >= plan.timeout_ms) {
            if (future.cancel(io)) |completed| {
                var response = completed;
                response.deinit(allocator);
            } else |_| {}
            return if (cancelled) error.Cancelled else error.Timeout;
        }
        @import("retry.zig").wait(10, null) catch unreachable;
    }
    return future.await(io);
}

const StreamJob = struct {
    raw: *anyopaque,
    send: StreamSend,
    plan: http.RequestPlan,
    body: []const u8,
    allocator: std.mem.Allocator,
    sink: ChunkSink,
    sink_ctx: *anyopaque,
    done: std.atomic.Value(bool) = .init(false),
    io: std.Io,
    started: std.Io.Clock.Timestamp,
    last_activity_ms: std.atomic.Value(u64) = .init(0),
    fn receive(raw: *anyopaque, bytes: []const u8) !void {
        const self: *@This() = @ptrCast(@alignCast(raw));
        if (bytes.len > 0) self.last_activity_ms.store(@intCast(self.started.durationTo(std.Io.Clock.Timestamp.now(self.io, .awake)).raw.toMilliseconds()), .release);
        try self.sink(self.sink_ctx, bytes);
    }

    fn run(self: *@This()) anyerror!ResponseMeta {
        const result = self.send(self.raw, self.plan, self.body, self.allocator, receive, self);
        self.done.store(true, .release);
        return result;
    }
};

/// Cancellation joins the reader before the parser and callback state leave
/// scope. The sink runs serially on this operation's Io worker.
fn sendStreamBounded(io: std.Io, raw: *anyopaque, send: StreamSend, plan: http.RequestPlan, body: []const u8, allocator: std.mem.Allocator, sink: ChunkSink, sink_ctx: *anyopaque) !ResponseMeta {
    if (plan.cancel) |token| if (token.isCancelled()) return error.Cancelled;
    if (plan.timeout_ms == 0) return error.Timeout;
    const started = std.Io.Clock.Timestamp.now(io, .awake);
    var job: StreamJob = .{ .io = io, .started = started, .raw = raw, .send = send, .plan = plan, .body = body, .allocator = allocator, .sink = sink, .sink_ctx = sink_ctx };
    var future = try std.Io.concurrent(io, StreamJob.run, .{&job});
    while (!job.done.load(.acquire)) {
        const cancelled = if (plan.cancel) |token| token.isCancelled() else false;
        const elapsed = started.durationTo(std.Io.Clock.Timestamp.now(io, .awake)).raw.toMilliseconds();
        const idle_ms = @as(u64, @intCast(@max(0, elapsed))) -| job.last_activity_ms.load(.acquire);
        if (cancelled or elapsed >= plan.timeout_ms or (plan.idle_timeout_ms != null and idle_ms >= plan.idle_timeout_ms.?)) {
            if (future.cancel(io)) |_| {} else |_| {}
            return if (cancelled) error.Cancelled else error.Timeout;
        }
        @import("retry.zig").wait(10, null) catch unreachable;
    }
    const result = future.await(io);
    if (plan.cancel) |token| if (token.isCancelled()) return error.Cancelled;
    return result;
}

fn nativeSendUnbounded(raw: *anyopaque, plan: http.RequestPlan, body: []const u8, allocator: std.mem.Allocator) anyerror!Response {
    const Collector = struct {
        allocator: std.mem.Allocator,
        bytes: std.ArrayList(u8) = .empty,
        fn receive(ctx: *anyopaque, bytes: []const u8) !void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            try self.bytes.appendSlice(self.allocator, bytes);
        }
    };
    var collector: Collector = .{ .allocator = allocator };
    defer collector.bytes.deinit(allocator);
    const meta = try nativeSendStreamUnbounded(raw, plan, body, allocator, Collector.receive, &collector);
    return .{ .status = meta.status, .retry_after_ms = meta.retry_after_ms, .body = try collector.bytes.toOwnedSlice(allocator) };
}

fn nativeSendStreamUnbounded(raw: *anyopaque, plan: http.RequestPlan, body: []const u8, allocator: std.mem.Allocator, sink: ChunkSink, sink_ctx: *anyopaque) anyerror!ResponseMeta {
    const context: *NativeContext = @ptrCast(@alignCast(raw));
    var client: std.http.Client = .{ .allocator = allocator, .io = context.io };
    defer client.deinit();
    const uri = try std.Uri.parse(plan.endpoint);
    var auth_buf: [4096]u8 = undefined;
    var headers: [4]std.http.Header = undefined;
    var header_count: usize = 0;
    headers[header_count] = .{ .name = "content-type", .value = plan.content_type };
    header_count += 1;
    headers[header_count] = .{ .name = "accept", .value = plan.accept };
    header_count += 1;
    if (plan.auth_style != .none) {
        const key_slice = plan.api_key orelse return error.MissingApiKey;
        if (key_slice.len == 0) return error.MissingApiKey;
        const value = switch (plan.auth_style) {
            .bearer => try std.fmt.bufPrint(&auth_buf, "Bearer {s}", .{key_slice}),
            .anthropic_key => try std.fmt.bufPrint(&auth_buf, "{s}", .{key_slice}),
            .none => unreachable,
        };
        headers[header_count] = .{ .name = if (plan.auth_style == .bearer) "authorization" else "x-api-key", .value = value };
        header_count += 1;
    }
    if (plan.auth_style == .anthropic_key) {
        headers[header_count] = .{ .name = "anthropic-version", .value = "2023-06-01" };
        header_count += 1;
    }
    var http_request = try client.request(plan.method, uri, .{ .extra_headers = headers[0..header_count] });
    defer http_request.deinit();
    if (plan.method == .GET) try http_request.sendBodiless() else try http_request.sendBodyComplete(@constCast(body));
    var response = try http_request.receiveHead(&.{});
    const status: u16 = @backingInt(response.head.status);
    @import("tool_trace.zig").emit(.{ .event = "provider_http_response", .status = status });
    var retry_after_ms: ?u32 = null;
    var header_iterator = response.head.iterateHeaders();
    while (header_iterator.next()) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, "retry-after")) {
            retry_after_ms = http.parseRetryAfter(header.value);
            break;
        }
    }
    // A rate-limit response is already fully classified from its head. Do
    // not wait for an error body on a persistent or stalled provider stream.
    if (http.response(status, retry_after_ms).kind != .success) {
        context.diagnostic.capture(status, "", plan.api_key);
        // Error bodies may be chunked. Retain bounded JSON details under the
        // same request deadline; rate limiting remains immediate.
        if (status != 429) {
            var error_buffer: [8192]u8 = undefined;
            const error_reader = response.reader(&.{});
            var writer: std.Io.Writer = .fixed(&error_buffer);
            while (writer.end < error_buffer.len) {
                const before = writer.end;
                _ = error_reader.stream(&writer, .limited(error_buffer.len - writer.end)) catch break;
                if (writer.end == before) break;
            }
            context.diagnostic.capture(status, writer.buffered(), plan.api_key);
        }
        if (http_request.connection) |connection| connection.closing = true;
        return .{ .status = status, .retry_after_ms = retry_after_ms };
    }
    const reader = response.reader(&.{});
    var total: usize = 0;
    var chunk: [4096]u8 = undefined;
    while (true) {
        if (plan.cancel) |token| if (token.isCancelled()) return error.Cancelled;
        var writer: std.Io.Writer = .fixed(&chunk);
        // stream() delivers the next available bytes. readSliceShort would
        // wait to fill the entire buffer and delay small provider deltas.
        _ = reader.stream(&writer, .limited(chunk.len)) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        const bytes = writer.buffered();
        if (bytes.len > max_response_bytes - total) return error.ResponseTooLarge;
        total += bytes.len;
        if (bytes.len != 0) try sink(sink_ctx, bytes);
    }
    return .{ .status = status, .retry_after_ms = retry_after_ms };
}

pub const Error = error{ ResponseTooLarge, RequestRejected, ProviderFailure, Cancelled, Timeout };

test "native HTTP authentication requires an explicit key before opening a connection" {
    var context: NativeContext = .{ .io = std.testing.io };
    const client = native(&context);
    for ([_]?[]const u8{ null, "" }) |key| {
        try std.testing.expectError(error.MissingApiKey, client.send(client.ctx, .{
            .endpoint = "http://127.0.0.1:1/v1/chat/completions",
            .auth_style = .bearer,
            .api_key = key,
        }, "{}", std.testing.allocator));
    }
}

pub fn request(allocator: std.mem.Allocator, transport: Transport, config: provider_config.ProviderConfig, chat: provider.ChatRequest) !Response {
    if (chat.retry_after_ms) |hint| hint.* = null;
    if (chat.cancel) |token| if (token.isCancelled()) return error.Cancelled;
    var plan = try http.plan(config);
    const endpoint = try http.chatEndpoint(allocator, config.kind, config.endpoint);
    defer allocator.free(endpoint);
    plan.endpoint = endpoint;
    plan.timeout_ms = chat.timeout_ms;
    plan.cancel = chat.cancel;
    const body = try http.requestBody(allocator, config.kind, config.chatRequest(chat), config.context_window);
    defer allocator.free(body);
    var response = try transport.send(transport.ctx, plan, body, allocator);
    errdefer response.deinit(allocator);
    if (chat.cancel) |token| if (token.isCancelled()) return error.Cancelled;
    if (response.body.len > max_response_bytes) return error.ResponseTooLarge;
    const classification = http.response(response.status, response.retry_after_ms);
    if (classification.kind == .retryable) {
        if (chat.retry_after_ms) |hint| hint.* = classification.retry_after_ms;
        return error.RequestRejected;
    }
    if (classification.kind == .provider_error or classification.kind == .malformed) return error.ProviderFailure;
    return response;
}

/// Uses real incremental reads when the transport provides them. Legacy
/// injected `send` implementations retain their existing owned-body behavior.
pub fn requestStream(allocator: std.mem.Allocator, transport: Transport, config: provider_config.ProviderConfig, chat: provider.ChatRequest, sink: ChunkSink, sink_ctx: *anyopaque) !ResponseMeta {
    if (chat.retry_after_ms) |hint| hint.* = null;
    if (chat.cancel) |token| if (token.isCancelled()) return error.Cancelled;
    const send = transport.send_stream orelse {
        var response = try request(allocator, transport, config, chat);
        defer response.deinit(allocator);
        var offset: usize = 0;
        while (offset < response.body.len) {
            if (chat.cancel) |token| if (token.isCancelled()) return error.Cancelled;
            const end = @min(offset + 4096, response.body.len);
            try sink(sink_ctx, response.body[offset..end]);
            offset = end;
        }
        if (chat.cancel) |token| if (token.isCancelled()) return error.Cancelled;
        return .{ .status = response.status, .retry_after_ms = response.retry_after_ms };
    };
    var plan = try http.plan(config);
    const endpoint = try http.chatEndpoint(allocator, config.kind, config.endpoint);
    defer allocator.free(endpoint);
    plan.endpoint = endpoint;
    plan.timeout_ms = chat.timeout_ms;
    plan.idle_timeout_ms = chat.idle_timeout_ms;
    plan.cancel = chat.cancel;
    const body = try http.requestBody(allocator, config.kind, config.chatRequest(chat), config.context_window);
    defer allocator.free(body);
    const LimitedSink = struct {
        sink: ChunkSink,
        ctx: *anyopaque,
        cancel: ?*provider.CancelToken,
        total: usize = 0,
        fn receive(raw: *anyopaque, bytes: []const u8) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            if (self.cancel) |token| if (token.isCancelled()) return error.Cancelled;
            if (bytes.len > max_response_bytes - self.total) return error.ResponseTooLarge;
            self.total += bytes.len;
            try self.sink(self.ctx, bytes);
            if (self.cancel) |token| if (token.isCancelled()) return error.Cancelled;
        }
    };
    var limited: LimitedSink = .{ .sink = sink, .ctx = sink_ctx, .cancel = chat.cancel };
    const result = try send(transport.ctx, plan, body, allocator, LimitedSink.receive, &limited);
    if (chat.cancel) |token| if (token.isCancelled()) return error.Cancelled;
    const classification = http.response(result.status, result.retry_after_ms);
    if (classification.kind == .retryable) {
        if (chat.retry_after_ms) |hint| hint.* = classification.retry_after_ms;
        return error.RequestRejected;
    }
    if (classification.kind == .provider_error or classification.kind == .malformed) return error.ProviderFailure;
    return result;
}

const Mock = struct {
    status: u16,
    body: []const u8,
    calls: usize = 0,
    fn send(ctx: *anyopaque, plan: http.RequestPlan, body: []const u8, allocator: std.mem.Allocator) !Response {
        const self: *Mock = @ptrCast(@alignCast(ctx));
        self.calls += 1;
        if (!std.mem.startsWith(u8, plan.endpoint, "https://")) return error.BadPlan;
        if (body.len == 0) return error.EmptyRequest;
        return .{ .status = self.status, .body = try allocator.dupe(u8, self.body) };
    }
};

test "injected provider transport classifies successful response" {
    var mock: Mock = .{ .status = 200, .body = "data: ok" };
    const messages = [_]provider.Message{.{ .content = "hello" }};
    var config = provider_config.defaults(.openai_compat);
    config.endpoint = "https://api.example.test/v1/chat";
    var result = try request(std.testing.allocator, .{ .ctx = &mock, .send = Mock.send }, config, .{ .model = "m", .effort = .low, .system = "", .messages = &messages });
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("data: ok", result.body);
    try std.testing.expectEqual(@as(usize, 1), mock.calls);
}

test "injected provider transport rejects retryable status" {
    var mock: Mock = .{ .status = 429, .body = "retry" };
    try std.testing.expectError(error.RequestRejected, request(std.testing.allocator, .{ .ctx = &mock, .send = Mock.send }, provider_config.defaults(.openai_compat), .{ .model = "m", .effort = .low, .system = "", .messages = &.{} }));
}

test "retry hint survives rejected response and resets before next attempt" {
    const Limited = struct {
        hint: ?u32 = 1200,
        fn send(raw: *anyopaque, _: http.RequestPlan, _: []const u8, allocator: std.mem.Allocator) !Response {
            const self: *@This() = @ptrCast(@alignCast(raw));
            return .{ .status = 429, .retry_after_ms = self.hint, .body = try allocator.dupe(u8, "limited") };
        }
    };
    var limited: Limited = .{};
    var hint: ?u32 = null;
    const chat: provider.ChatRequest = .{ .model = "m", .effort = .low, .system = "", .messages = &.{}, .retry_after_ms = &hint };
    const injected: Transport = .{ .ctx = &limited, .send = Limited.send };
    try std.testing.expectError(error.RequestRejected, request(std.testing.allocator, injected, provider_config.defaults(.openai_compat), chat));
    try std.testing.expectEqual(@as(?u32, 1200), hint);
    limited.hint = null;
    try std.testing.expectError(error.RequestRejected, request(std.testing.allocator, injected, provider_config.defaults(.openai_compat), chat));
    try std.testing.expectEqual(@as(?u32, null), hint);
}

test "blocked native operation times out and joins before releasing request state" {
    const Stalled = struct {
        io: std.Io,
        exited: bool = false,
        fn send(raw: *anyopaque, _: http.RequestPlan, _: []const u8, _: std.mem.Allocator) !Response {
            const self: *@This() = @ptrCast(@alignCast(raw));
            defer self.exited = true;
            try std.Io.sleep(self.io, .fromMilliseconds(60_000), .awake);
            return error.UnexpectedCompletion;
        }
    };
    var stalled: Stalled = .{ .io = std.testing.io };
    var plan = try http.plan(provider_config.defaults(.openai_compat));
    plan.timeout_ms = 20;
    try std.testing.expectError(error.Timeout, sendBounded(std.testing.io, &stalled, Stalled.send, plan, "{}", std.testing.allocator));
    try std.testing.expect(stalled.exited);
}

test "Stop interrupts an in-flight native operation" {
    const Stalled = struct {
        io: std.Io,
        token: *provider.CancelToken,
        exited: bool = false,
        fn send(raw: *anyopaque, _: http.RequestPlan, _: []const u8, _: std.mem.Allocator) !Response {
            const self: *@This() = @ptrCast(@alignCast(raw));
            defer self.exited = true;
            self.token.cancel();
            try std.Io.sleep(self.io, .fromMilliseconds(60_000), .awake);
            return error.UnexpectedCompletion;
        }
    };
    var token: provider.CancelToken = .{};
    var stalled: Stalled = .{ .io = std.testing.io, .token = &token };
    var plan = try http.plan(provider_config.defaults(.openai_compat));
    plan.cancel = &token;
    try std.testing.expectError(error.Cancelled, sendBounded(std.testing.io, &stalled, Stalled.send, plan, "{}", std.testing.allocator));
    try std.testing.expect(stalled.exited);
}

test "native loopback 429 stalled error body resumes a real HTTP request" {
    const Fixture = struct {
        io: std.Io,
        server: std.Io.net.Server,
        calls: std.atomic.Value(usize) = .init(0),
        fn serve(self: *@This()) !void {
            // Retain the first connection without supplying its error body.
            // The client must classify 429 from the head and retry on a new one.
            var first: ?std.Io.net.Stream = null;
            defer if (first) |stream| stream.close(self.io);
            for (0..2) |index| {
                const stream = try self.server.accept(self.io);
                if (index == 0) first = stream;
                defer if (index != 0) stream.close(self.io);
                var read_buffer: [8192]u8 = undefined;
                var reader = stream.reader(self.io, &read_buffer);
                var content_length: usize = 0;
                while (true) {
                    const line = try reader.interface.takeDelimiterInclusive('\n');
                    if (std.ascii.startsWithIgnoreCase(line, "content-length:")) {
                        content_length = try std.fmt.parseInt(usize, std.mem.trim(u8, line[15..], " \r\n"), 10);
                    }
                    if (std.mem.eql(u8, line, "\r\n")) break;
                }
                try reader.interface.discardAll(content_length);
                _ = self.calls.fetchAdd(1, .release);
                var writer = stream.writer(self.io, &.{});
                if (index == 0) {
                    try writer.interface.writeAll("HTTP/1.1 429 Too Many Requests\r\nRetry-After: 0\r\nContent-Length: 9999\r\n\r\n");
                } else {
                    const payload = "{\"message\":{\"content\":\"recovered\"},\"done\":true}\n";
                    try writer.interface.print("HTTP/1.1 200 OK\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}", .{ payload.len, payload });
                }
                try writer.interface.flush();
            }
        }
    };
    const address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var fixture: Fixture = .{ .io = std.testing.io, .server = try address.listen(std.testing.io, .{}) };
    defer fixture.server.deinit(std.testing.io);
    var serving = try std.Io.concurrent(std.testing.io, Fixture.serve, .{&fixture});
    defer _ = serving.cancel(std.testing.io) catch {};
    var endpoint_buf: [128]u8 = undefined;
    const endpoint = try std.fmt.bufPrint(&endpoint_buf, "http://127.0.0.1:{d}/api/chat", .{fixture.server.socket.address.getPort()});
    var context: NativeContext = .{ .io = std.testing.io };
    var client = @import("provider_client.zig").Client.native(std.testing.allocator, &context, .ollama);
    var config = provider_config.defaults(.ollama);
    config.endpoint = endpoint;
    var binding: @import("provider_client.zig").Client.Binding = .{ .client = &client, .config = config };
    var manager = @import("turn_manager.zig").Manager.init(std.testing.allocator);
    defer manager.deinit();
    manager.retry_policy = .{ .delays_ms = .{ 0, 0, 0 } };
    _ = try manager.run(binding.asProvider(), .{ .model = "fixture", .system = "", .messages = &.{}, .timeout_ms = 3000 });
    try serving.await(std.testing.io);
    try std.testing.expectEqual(@as(usize, 2), fixture.calls.load(.acquire));
    try std.testing.expectEqualStrings("recovered", manager.cards.cards.items[0].text);
}

test "native HTTP stream emits text before EOF and retains fragmented UTF8 and usage" {
    const Fixture = struct {
        io: std.Io,
        server: std.Io.net.Server,
        first_seen: std.atomic.Value(bool) = .init(false),
        tail_sent: std.atomic.Value(bool) = .init(false),
        early_delta: bool = false,
        text: std.ArrayList(u8) = .empty,
        thinking: std.ArrayList(u8) = .empty,
        callback_error: ?anyerror = null,
        fn receive(raw: *anyopaque, delta: provider.Delta) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            switch (delta) {
                .text => |value| {
                    self.text.appendSlice(std.testing.allocator, value) catch |err| {
                        self.callback_error = err;
                    };
                    if (!self.first_seen.load(.acquire)) {
                        self.early_delta = !self.tail_sent.load(.acquire);
                        self.first_seen.store(true, .release);
                    }
                },
                .thinking => |value| self.thinking.appendSlice(std.testing.allocator, value) catch |err| {
                    self.callback_error = err;
                },
                .err => self.callback_error = error.StreamCallbackFailed,
                else => {},
            }
        }
        fn chunk(writer: *std.Io.Writer, bytes: []const u8) !void {
            try writer.print("{x}\r\n{s}\r\n", .{ bytes.len, bytes });
            try writer.flush();
        }
        fn serve(self: *@This()) !void {
            const connection = try self.server.accept(self.io);
            defer connection.close(self.io);
            var buffer: [8192]u8 = undefined;
            var reader = connection.reader(self.io, &buffer);
            var content_length: usize = 0;
            while (true) {
                const line = try reader.interface.takeDelimiterInclusive('\n');
                if (std.ascii.startsWithIgnoreCase(line, "content-length:")) {
                    content_length = try std.fmt.parseInt(usize, std.mem.trim(u8, line[15..], " \r\n"), 10);
                }
                if (std.mem.eql(u8, line, "\r\n")) break;
            }
            try reader.interface.discardAll(content_length);
            var writer = connection.writer(self.io, &.{});
            try writer.interface.writeAll("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n");
            try chunk(&writer.interface, "data: {\"choices\":[{\"delta\":{\"content\":\"first\"}}]}\n\n");
            const start = std.Io.Clock.Timestamp.now(self.io, .awake);
            // The server withholds both the remaining chunks and EOF until
            // the real client's Delta callback observes the first frame.
            while (!self.first_seen.load(.acquire)) {
                if (start.durationTo(std.Io.Clock.Timestamp.now(self.io, .awake)).raw.toMilliseconds() > 2000) return error.NoDeltaBeforeEof;
                try std.Io.sleep(self.io, .fromMilliseconds(2), .awake);
            }
            self.tail_sent.store(true, .release);
            try chunk(&writer.interface, "data: {\"choices\":[{\"delta\":{\"content\":\"\xe4");
            try chunk(&writer.interface, "\xb8\x96\xe7\x95\x8c\",\"reasoning_content\":\"thought\"},\"finish_reason\":\"stop\"}]}\n\n");
            try chunk(&writer.interface, "data: {\"choices\":[],\"usage\":{\"prompt_tokens\":2,\"completion_tokens\":3}}\n\ndata: [DONE]\n\n");
            try writer.interface.writeAll("0\r\n\r\n");
            try writer.interface.flush();
        }
    };
    const address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var fixture: Fixture = .{ .io = std.testing.io, .server = try address.listen(std.testing.io, .{}) };
    defer fixture.server.deinit(std.testing.io);
    defer fixture.text.deinit(std.testing.allocator);
    defer fixture.thinking.deinit(std.testing.allocator);
    var serving = try std.Io.concurrent(std.testing.io, Fixture.serve, .{&fixture});
    defer _ = serving.cancel(std.testing.io) catch {};
    var endpoint_buf: [128]u8 = undefined;
    // Keep the configured wire protocol identical to the stream decoder.
    var config = provider_config.defaults(.openai_compat);
    config.auth = .{ .bearer_memory = "fixture-only-key" };
    config.endpoint = try std.fmt.bufPrint(&endpoint_buf, "http://127.0.0.1:{d}/v1/chat/completions", .{fixture.server.socket.address.getPort()});
    var context: NativeContext = .{ .io = std.testing.io };
    var client = @import("provider_client.zig").Client.native(std.testing.allocator, &context, .openai_compat);
    const stats = (try client.chatWithStats(config, .{ .model = "fixture", .system = "", .messages = &.{}, .timeout_ms = 3000 }, Fixture.receive, &fixture)).?;
    try serving.await(std.testing.io);
    try std.testing.expect(fixture.callback_error == null);
    try std.testing.expect(fixture.early_delta);
    try std.testing.expectEqualStrings("first世界", fixture.text.items);
    try std.testing.expectEqualStrings("thought", fixture.thinking.items);
    try std.testing.expectEqual(@as(u32, 2), stats.input_tokens);
    try std.testing.expectEqual(@as(u32, 3), stats.output_tokens);
}

test "streaming native deadline and Stop join before borrowed sink is released" {
    const Stalled = struct {
        io: std.Io,
        token: ?*provider.CancelToken = null,
        exited: bool = false,
        callbacks: usize = 0,
        fn send(raw: *anyopaque, _: http.RequestPlan, _: []const u8, _: std.mem.Allocator, sink: ChunkSink, sink_ctx: *anyopaque) !ResponseMeta {
            const self: *@This() = @ptrCast(@alignCast(raw));
            defer self.exited = true;
            try sink(sink_ctx, "first");
            if (self.token) |token| token.cancel();
            try std.Io.sleep(self.io, .fromMilliseconds(60_000), .awake);
            return error.UnexpectedCompletion;
        }
        fn receive(raw: *anyopaque, _: []const u8) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.callbacks += 1;
        }
    };
    var stalled: Stalled = .{ .io = std.testing.io };
    var plan = try http.plan(provider_config.defaults(.openai_compat));
    plan.timeout_ms = 20;
    try std.testing.expectError(error.Timeout, sendStreamBounded(std.testing.io, &stalled, Stalled.send, plan, "{}", std.testing.allocator, Stalled.receive, &stalled));
    try std.testing.expect(stalled.exited);
    try std.testing.expectEqual(@as(usize, 1), stalled.callbacks);
    var token: provider.CancelToken = .{};
    stalled = .{ .io = std.testing.io, .token = &token };
    plan.cancel = &token;
    plan.timeout_ms = 3000;
    try std.testing.expectError(error.Cancelled, sendStreamBounded(std.testing.io, &stalled, Stalled.send, plan, "{}", std.testing.allocator, Stalled.receive, &stalled));
    try std.testing.expect(stalled.exited);
    try std.testing.expectEqual(@as(usize, 1), stalled.callbacks);
}

test "stream hook caps bytes stops on sink error and keeps retry hints" {
    const Injected = struct {
        status: u16 = 200,
        hint: ?u32 = null,
        chunks: usize = 0,
        bytes_seen: usize = 0,
        fail_sink: bool = false,
        fn send(_: *anyopaque, _: http.RequestPlan, _: []const u8, _: std.mem.Allocator) !Response {
            return error.LegacySendMustNotBeUsed;
        }
        fn sendStream(raw: *anyopaque, _: http.RequestPlan, _: []const u8, _: std.mem.Allocator, sink: ChunkSink, sink_ctx: *anyopaque) !ResponseMeta {
            const self: *@This() = @ptrCast(@alignCast(raw));
            if (self.status == 200) {
                const bytes: [4096]u8 = @splat('x');
                for (0..max_response_bytes / bytes.len + 1) |_| {
                    self.chunks += 1;
                    try sink(sink_ctx, &bytes);
                }
            }
            return .{ .status = self.status, .retry_after_ms = self.hint };
        }
        fn receive(raw: *anyopaque, bytes: []const u8) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.bytes_seen += bytes.len;
            if (self.fail_sink) return error.SinkRejected;
        }
    };
    var injected: Injected = .{};
    const t: Transport = .{ .ctx = &injected, .send = Injected.send, .send_stream = Injected.sendStream };
    var hint: ?u32 = 999;
    const chat: provider.ChatRequest = .{ .model = "m", .system = "", .messages = &.{}, .retry_after_ms = &hint };
    const config = provider_config.defaults(.openai_compat);
    try std.testing.expectError(error.ResponseTooLarge, requestStream(std.testing.allocator, t, config, chat, Injected.receive, &injected));
    try std.testing.expectEqual(max_response_bytes, injected.bytes_seen);
    try std.testing.expectEqual(@as(?u32, null), hint);
    injected = .{ .fail_sink = true };
    try std.testing.expectError(error.SinkRejected, requestStream(std.testing.allocator, t, config, chat, Injected.receive, &injected));
    try std.testing.expectEqual(@as(usize, 1), injected.chunks);
    injected = .{ .status = 429, .hint = 1234 };
    try std.testing.expectError(error.RequestRejected, requestStream(std.testing.allocator, t, config, chat, Injected.receive, &injected));
    try std.testing.expectEqual(@as(?u32, 1234), hint);
    try std.testing.expectEqual(@as(usize, 0), injected.chunks);
    injected = .{ .status = 400 };
    try std.testing.expectError(error.ProviderFailure, requestStream(std.testing.allocator, t, config, chat, Injected.receive, &injected));
    try std.testing.expectEqual(@as(?u32, null), hint);
}

test "stream inactivity resets on chunks while the overall request stays bounded" {
    const Active = struct {
        chunks: usize = 0,
        stall: bool = false,
        fn send(raw: *anyopaque, _: http.RequestPlan, _: []const u8, _: std.mem.Allocator, sink: ChunkSink, ctx: *anyopaque) !ResponseMeta {
            const self: *@This() = @ptrCast(@alignCast(raw));
            for (0..8) |_| {
                try std.Io.sleep(std.testing.io, .fromMilliseconds(15), .awake);
                try sink(ctx, "reasoning chunk");
            }
            if (self.stall) try std.Io.sleep(std.testing.io, .fromMilliseconds(200), .awake);
            return .{ .status = 200 };
        }
        fn receive(raw: *anyopaque, _: []const u8) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.chunks += 1;
        }
    };
    var active: Active = .{};
    const plan: http.RequestPlan = .{ .endpoint = "http://127.0.0.1/fixture", .auth_style = .none, .timeout_ms = 1000, .idle_timeout_ms = 70 };
    _ = try sendStreamBounded(std.testing.io, &active, Active.send, plan, "{}", std.testing.allocator, Active.receive, &active);
    try std.testing.expectEqual(@as(usize, 8), active.chunks);
    active = .{ .stall = true };
    try std.testing.expectError(error.Timeout, sendStreamBounded(std.testing.io, &active, Active.send, plan, "{}", std.testing.allocator, Active.receive, &active));
    try std.testing.expectEqual(@as(usize, 8), active.chunks);
    active = .{};
    var capped = plan;
    capped.timeout_ms = 70;
    try std.testing.expectError(error.Timeout, sendStreamBounded(std.testing.io, &active, Active.send, capped, "{}", std.testing.allocator, Active.receive, &active));
}
