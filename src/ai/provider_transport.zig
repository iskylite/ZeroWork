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

fn SendJob(comptime Timing: type) type {
    return struct {
        raw: *anyopaque,
        send: @FieldType(Transport, "send"),
        plan: http.RequestPlan,
        body: []const u8,
        allocator: std.mem.Allocator,
        done: std.atomic.Value(bool) = .init(false),
        timing: Timing,

        fn deadlineError(self: *const @This()) ?anyerror {
            if (self.plan.cancel) |token| if (token.isCancelled()) return error.Cancelled;
            if (self.timing.elapsedMs() >= self.plan.timeout_ms) return error.Timeout;
            return null;
        }
        fn run(self: *@This()) anyerror!Response {
            defer self.done.store(true, .release);
            // Queue/startup time is part of the request. Do not dispatch a
            // request that has already expired or been stopped while queued.
            if (self.deadlineError()) |reason| return reason;
            const result = self.send(self.raw, self.plan, self.body, self.allocator);
            if (self.deadlineError()) |err| {
                // A completed send owns its body even if Stop or the deadline
                // wins before publication. Reclaim it before publishing done.
                discardResponse(result, self.allocator);
                return err;
            }
            return result;
        }
    };
}

/// Keep the request, response head and response body under the same deadline.
/// Future.cancel interrupts blocked Io operations and joins before borrowed
/// request buffers leave scope. A cancelled operation can still return an
/// owned response if completion raced with Stop; release it in that case.
fn sendBounded(io: std.Io, raw: *anyopaque, send: @FieldType(Transport, "send"), plan: http.RequestPlan, body: []const u8, allocator: std.mem.Allocator) !Response {
    if (plan.cancel) |token| if (token.isCancelled()) return error.Cancelled;
    if (plan.timeout_ms == 0) return error.Timeout;
    const started = std.Io.Clock.Timestamp.now(io, .awake);
    var job: SendJob(RequestTiming) = .{ .timing = .{ .io = io, .started = started }, .raw = raw, .send = send, .plan = plan, .body = body, .allocator = allocator };
    var future = try std.Io.concurrent(io, SendJob(RequestTiming).run, .{&job});
    return awaitSend(io, &job, &future);
}
fn awaitSend(io: std.Io, job: anytype, future: anytype) !Response {
    const plan = job.plan;
    while (!job.done.load(.acquire)) {
        const cancelled = if (plan.cancel) |token| token.isCancelled() else false;
        const elapsed = job.timing.elapsedMs();
        if (cancelled) {
            discardResponse(future.cancel(io), job.allocator);
            return error.Cancelled;
        }
        if (job.done.load(.acquire)) break;
        if (elapsed >= plan.timeout_ms) return finishSendWait(job, future.cancel(io), true);
        job.timing.wait();
    }
    return finishSendWait(job, future.await(io), false);
}
fn discardResponse(result: anyerror!Response, allocator: std.mem.Allocator) void {
    if (result) |completed| {
        var response = completed;
        response.deinit(allocator);
    } else |_| {}
}
fn finishSendWait(job: anytype, result: anyerror!Response, deadline_cancel: bool) !Response {
    // Joining can race with Stop, including when the worker had already
    // classified a valid response. Never leave that owned body behind.
    if (job.plan.cancel) |token| if (token.isCancelled()) {
        discardResponse(result, job.allocator);
        return error.Cancelled;
    };
    return result catch |err| return if (deadline_cancel and err == error.Canceled) error.Timeout else err;
}

const RequestTiming = struct {
    io: std.Io,
    started: std.Io.Clock.Timestamp,
    fn elapsedMs(self: @This()) u64 {
        return @intCast(@max(0, self.started.durationTo(std.Io.Clock.Timestamp.now(self.io, .awake)).raw.toMilliseconds()));
    }
    fn wait(_: @This()) void {
        @import("retry.zig").wait(10, null) catch unreachable;
    }
};
fn StreamJob(comptime Timing: type) type {
    return struct {
        raw: *anyopaque,
        send: StreamSend,
        plan: http.RequestPlan,
        body: []const u8,
        allocator: std.mem.Allocator,
        sink: ChunkSink,
        sink_ctx: *anyopaque,
        done: std.atomic.Value(bool) = .init(false),
        timing: Timing,
        last_activity_ms: std.atomic.Value(u64) = .init(0),
        fn timedOut(self: *const @This(), elapsed_ms: u64) bool {
            return elapsed_ms >= self.plan.timeout_ms or if (self.plan.idle_timeout_ms) |idle|
                elapsed_ms -| self.last_activity_ms.load(.acquire) >= idle
            else
                false;
        }
        fn receive(raw: *anyopaque, bytes: []const u8) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            if (self.plan.cancel) |token| if (token.isCancelled()) return error.Cancelled;
            const elapsed = self.timing.elapsedMs();
            // The monitor may be descheduled. A late chunk must not revive an
            // expired idle period or reach a borrowed parser after its budget.
            if (self.timedOut(elapsed)) return error.Timeout;
            if (bytes.len > 0) self.last_activity_ms.store(elapsed, .release);
            try self.sink(self.sink_ctx, bytes);
        }

        fn run(self: *@This()) anyerror!ResponseMeta {
            defer self.done.store(true, .release);
            const result = self.send(self.raw, self.plan, self.body, self.allocator, receive, self);
            if (self.plan.cancel) |token| if (token.isCancelled()) return error.Cancelled;
            // Classify at completion, rather than at the monitor's next wake.
            if (self.timedOut(self.timing.elapsedMs())) return error.Timeout;
            return result;
        }
    };
}

/// Cancellation joins the reader before the parser and callback state leave
/// scope. The sink runs serially on this operation's Io worker.
fn sendStreamBounded(io: std.Io, raw: *anyopaque, send: StreamSend, plan: http.RequestPlan, body: []const u8, allocator: std.mem.Allocator, sink: ChunkSink, sink_ctx: *anyopaque) !ResponseMeta {
    if (plan.cancel) |token| if (token.isCancelled()) return error.Cancelled;
    if (plan.timeout_ms == 0) return error.Timeout;
    const started = std.Io.Clock.Timestamp.now(io, .awake);
    var job: StreamJob(RequestTiming) = .{ .timing = .{ .io = io, .started = started }, .raw = raw, .send = send, .plan = plan, .body = body, .allocator = allocator, .sink = sink, .sink_ctx = sink_ctx };
    var future = try std.Io.concurrent(io, StreamJob(RequestTiming).run, .{&job});
    return awaitStream(io, &job, &future);
}

fn awaitStream(io: std.Io, job: anytype, future: anytype) !ResponseMeta {
    const plan = job.plan;
    while (!job.done.load(.acquire)) {
        const cancelled = if (plan.cancel) |token| token.isCancelled() else false;
        const elapsed = job.timing.elapsedMs();
        if (cancelled) {
            if (future.cancel(io)) |_| {} else |_| {}
            return error.Cancelled;
        }
        if (job.done.load(.acquire)) break;
        if (job.timedOut(elapsed)) {
            // cancel joins and may return a result that already completed
            // within its deadline. The worker has classified its own finish;
            // do not overwrite that result merely because we resumed late.
            const completed = future.cancel(io);
            if (plan.cancel) |token| if (token.isCancelled()) return error.Cancelled;
            return completed catch |err| return if (err == error.Canceled) error.Timeout else err;
        }
        job.timing.wait();
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
    var http_request = try client.request(plan.method, uri, .{ .extra_headers = headers[0..header_count], .redirect_behavior = .unhandled });
    defer http_request.deinit();
    if (plan.method == .GET) try http_request.sendBodiless() else try http_request.sendBodyComplete(@constCast(body));
    var response = try http_request.receiveHead(&.{});
    const status: u16 = @backingInt(response.head.status);
    @import("tool_trace.zig").emit(.{ .event = "provider_http_response", .status = status });
    // Never let the HTTP client turn an authenticated POST into a GET or
    // forward its credentials to a redirected endpoint.
    if (status >= 300 and status < 400) {
        context.diagnostic.captureRedirect(status, response.head.location, plan.api_key);
        if (http_request.connection) |connection| connection.closing = true;
        return error.EndpointRedirect;
    }
    var retry_after_ms: ?u32 = null;
    var html_content_type = false;
    var header_iterator = response.head.iterateHeaders();
    while (header_iterator.next()) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, "retry-after")) {
            retry_after_ms = http.parseRetryAfter(header.value);
        }
        if (std.ascii.eqlIgnoreCase(header.name, "content-type")) {
            const media_type = std.mem.trim(u8, header.value[0 .. std.mem.indexOfScalar(u8, header.value, ';') orelse header.value.len], " \t");
            html_content_type = std.ascii.eqlIgnoreCase(media_type, "text/html") or std.ascii.eqlIgnoreCase(media_type, "application/xhtml+xml");
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
    if (html_content_type) {
        context.diagnostic.captureMessage(status, "", plan.api_key);
        if (http_request.connection) |connection| connection.closing = true;
        return error.HtmlResponse;
    }
    const reader = response.reader(&.{});
    var total: usize = 0;
    var html: http.HtmlGuard = .{};
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
        if (html.feed(bytes)) {
            context.diagnostic.captureMessage(status, "", plan.api_key);
            if (http_request.connection) |connection| connection.closing = true;
            return error.HtmlResponse;
        }
        if (bytes.len != 0) try sink(sink_ctx, bytes);
    }
    return .{ .status = status, .retry_after_ms = retry_after_ms };
}

pub const Error = error{ ResponseTooLarge, RequestRejected, ProviderFailure, Cancelled, Timeout };

test "native HTTP rejects gateway redirects and HTML for model lists and chat streams" {
    const Fixture = struct {
        status: u16,
        content_type: []const u8,
        payload: []const u8,
        io: std.Io,
        server: std.Io.net.Server,
        method: std.http.Method,
        fn serve(self: *@This()) !void {
            const connection = try self.server.accept(self.io);
            defer connection.close(self.io);
            var buffer: [8192]u8 = undefined;
            var reader = connection.reader(self.io, &buffer);
            const request_line = try reader.interface.takeDelimiterInclusive('\n');
            try std.testing.expect(std.mem.startsWith(u8, request_line, if (self.method == .GET) "GET /api/gw/v1/models " else "POST /api/gw/v1/chat/completions "));
            var length: usize = 0;
            while (true) {
                const line = try reader.interface.takeDelimiterInclusive('\n');
                if (std.ascii.startsWithIgnoreCase(line, "content-length:")) length = try std.fmt.parseInt(usize, std.mem.trim(u8, line[15..], " \r\n"), 10);
                if (std.mem.eql(u8, line, "\r\n")) break;
            }
            try reader.interface.discardAll(length);
            var writer = connection.writer(self.io, &.{});
            // A large declared redirect body ensures rejection uses the head
            // immediately instead of waiting for or replaying the request.
            try writer.interface.print("HTTP/1.1 {d} Fixture\r\nLocation: /management/?key=fixture-key\r\n{s}Content-Length: {d}\r\nConnection: close\r\n\r\n{s}", .{ self.status, self.content_type, if (self.status >= 300) @as(usize, 9999) else self.payload.len, self.payload });
            try writer.interface.flush();
        }
        fn receive(_: *anyopaque, _: []const u8) !void {}
    };
    for ([_]std.http.Method{ .GET, .POST }) |method| {
        for ([_]struct { status: u16 = 200, content_type: []const u8 = "", payload: []const u8 = "", failure: anyerror }{
            .{ .status = 301, .failure = error.EndpointRedirect },
            .{ .status = 302, .failure = error.EndpointRedirect },
            .{ .status = 303, .failure = error.EndpointRedirect },
            .{ .status = 307, .failure = error.EndpointRedirect },
            .{ .status = 308, .failure = error.EndpointRedirect },
            .{ .content_type = "Content-Type: text/html; charset=utf-8\r\n", .payload = "management", .failure = error.HtmlResponse },
            .{ .content_type = "Content-Type: application/xhtml+xml\r\n", .payload = "management", .failure = error.HtmlResponse },
            .{ .payload = " \r\n<!DOCTYPE html><html>management</html>", .failure = error.HtmlResponse },
        }) |item| {
            const address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
            var fixture: Fixture = .{ .status = item.status, .content_type = item.content_type, .payload = item.payload, .io = std.testing.io, .server = try address.listen(std.testing.io, .{}), .method = method };
            defer fixture.server.deinit(std.testing.io);
            var serving = try std.Io.concurrent(std.testing.io, Fixture.serve, .{&fixture});
            defer _ = serving.cancel(std.testing.io) catch {};
            var endpoint_buffer: [128]u8 = undefined;
            const endpoint = try std.fmt.bufPrint(&endpoint_buffer, "http://127.0.0.1:{d}/api/gw/v1/{s}", .{ fixture.server.socket.address.getPort(), if (method == .GET) "models" else "chat/completions" });
            var context: NativeContext = .{ .io = std.testing.io };
            const t = native(&context);
            const plan: http.RequestPlan = .{ .method = method, .endpoint = endpoint, .auth_style = .bearer, .api_key = "fixture-key", .timeout_ms = 3000 };
            if (method == .GET) {
                try std.testing.expectError(item.failure, t.send(t.ctx, plan, "", std.testing.allocator));
            } else {
                try std.testing.expectError(item.failure, t.send_stream.?(t.ctx, plan, "{}", std.testing.allocator, Fixture.receive, undefined));
            }
            try serving.await(std.testing.io);
            try std.testing.expectEqual(item.status, context.diagnostic.status);
            try std.testing.expect(std.mem.indexOf(u8, context.diagnostic.message[0..context.diagnostic.len], "fixture-key") == null);
            if (item.failure == error.EndpointRedirect) try std.testing.expectEqualStrings("/management/", context.diagnostic.message[0..context.diagnostic.len]);
        }
    }
}

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
    var html: http.HtmlGuard = .{};
    if (html.feed(response.body)) return error.HtmlResponse;
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
        html: http.HtmlGuard = .{},
        fn receive(raw: *anyopaque, bytes: []const u8) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            if (self.cancel) |token| if (token.isCancelled()) return error.Cancelled;
            if (bytes.len > max_response_bytes - self.total) return error.ResponseTooLarge;
            self.total += bytes.len;
            if (self.html.feed(bytes)) return error.HtmlResponse;
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

test "native protocol base URLs resolve buffered chat streaming chat and model lists consistently" {
    const Fixture = struct {
        io: std.Io,
        server: std.Io.net.Server,
        kind: registry.Kind,
        fn serve(self: *@This()) !void {
            for (0..3) |index| {
                const connection = try self.server.accept(self.io);
                defer connection.close(self.io);
                var buffer: [8192]u8 = undefined;
                var reader = connection.reader(self.io, &buffer);
                const line = try reader.interface.takeDelimiterInclusive('\n');
                const path: []const u8 = if (index == 2) switch (self.kind) {
                    .openai_compat => "/tenant/proxy/models?route=blue",
                    .anthropic => "/tenant/proxy/v1/models?route=blue",
                    .ollama => "/tenant/proxy/api/tags?route=blue",
                } else switch (self.kind) {
                    .openai_compat => "/tenant/proxy/chat/completions?route=blue",
                    .anthropic => "/tenant/proxy/v1/messages?route=blue",
                    .ollama => "/tenant/proxy/api/chat?route=blue",
                };
                var expected: [256]u8 = undefined;
                try std.testing.expectEqualStrings(try std.fmt.bufPrint(&expected, "{s} {s} HTTP/1.1\r\n", .{ if (index == 2) "GET" else "POST", path }), line);
                var length: usize = 0;
                var authenticated = false;
                while (true) {
                    const header = try reader.interface.takeDelimiterInclusive('\n');
                    if (std.ascii.startsWithIgnoreCase(header, "content-length:")) length = try std.fmt.parseInt(usize, std.mem.trim(u8, header[15..], " \r\n"), 10);
                    if (std.mem.eql(u8, header, if (self.kind == .anthropic) "x-api-key: fixture-key\r\n" else "authorization: Bearer fixture-key\r\n")) authenticated = true;
                    if (std.mem.eql(u8, header, "\r\n")) break;
                }
                try std.testing.expect(authenticated);
                try std.testing.expect(if (index == 2) length == 0 else length > 0);
                try reader.interface.discardAll(length);
                const payload = if (index != 2) "fixture reply" else if (self.kind == .ollama) "{\"models\":[{\"name\":\"fixture\"}]}" else "{\"data\":[{\"id\":\"fixture\"}]}";
                var writer = connection.writer(self.io, &.{});
                try writer.interface.print("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}", .{ payload.len, payload });
                try writer.interface.flush();
            }
        }
    };
    const Capture = struct {
        text: std.ArrayList(u8) = .empty,
        fn receive(raw: *anyopaque, bytes: []const u8) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            try self.text.appendSlice(std.testing.allocator, bytes);
        }
    };
    const a = std.testing.allocator;
    for (std.enums.values(registry.Kind)) |kind| {
        const address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
        var fixture: Fixture = .{ .io = std.testing.io, .server = try address.listen(std.testing.io, .{}), .kind = kind };
        defer fixture.server.deinit(std.testing.io);
        var serving = try std.Io.concurrent(std.testing.io, Fixture.serve, .{&fixture});
        defer _ = serving.cancel(std.testing.io) catch {};
        var endpoint_buffer: [128]u8 = undefined;
        var config = provider_config.defaults(kind);
        config.endpoint = try std.fmt.bufPrint(&endpoint_buffer, "http://127.0.0.1:{d}/tenant/proxy/?route=blue", .{fixture.server.socket.address.getPort()});
        config.auth = if (kind == .anthropic) .{ .anthropic_memory = "fixture-key" } else .{ .bearer_memory = "fixture-key" };
        var context: NativeContext = .{ .io = std.testing.io };
        const t = native(&context);
        const chat: provider.ChatRequest = .{ .model = "fixture", .system = "", .messages = &.{.{ .content = "hello" }}, .timeout_ms = 3000 };
        var response = try request(a, t, config, chat);
        defer response.deinit(a);
        try std.testing.expectEqualStrings("fixture reply", response.body);
        var capture: Capture = .{};
        defer capture.text.deinit(a);
        const streamed = try requestStream(a, t, config, chat, Capture.receive, &capture);
        try std.testing.expectEqual(@as(u16, 200), streamed.status);
        try std.testing.expectEqualStrings("fixture reply", capture.text.items);
        const catalog = @import("model_catalog.zig");
        const models_url = try catalog.endpoint(a, config.endpoint, kind);
        defer a.free(models_url);
        var plan = try http.plan(config);
        plan.method = .GET;
        plan.endpoint = models_url;
        plan.accept = "application/json";
        plan.timeout_ms = 3000;
        var listed = try t.send(t.ctx, plan, "", a);
        defer listed.deinit(a);
        var models = try catalog.Catalog.parse(a, listed.body, if (kind == .ollama) .ollama else .endpoint);
        defer models.deinit();
        try std.testing.expectEqual(@as(usize, 1), models.entries.len);
        try std.testing.expectEqualStrings("fixture", models.entries[0].id);
        try serving.await(std.testing.io);
    }
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
        clock: *TestSendClock,
        exited: bool = false,
        fn send(raw: *anyopaque, _: http.RequestPlan, _: []const u8, _: std.mem.Allocator) !Response {
            const self: *@This() = @ptrCast(@alignCast(raw));
            defer self.exited = true;
            self.clock.ms.store(20, .release);
            try std.Io.sleep(self.io, .fromMilliseconds(60_000), .awake);
            return error.UnexpectedCompletion;
        }
    };
    var clock: TestSendClock = .{};
    var stalled: Stalled = .{ .io = std.testing.io, .clock = &clock };
    var plan = try http.plan(provider_config.defaults(.openai_compat));
    plan.timeout_ms = 20;
    // Advance the unchanged 20ms deadline only after the operation starts;
    // slow thread scheduling must not turn this into a queued-request test.
    var job: SendJob(*TestSendClock) = .{ .timing = &clock, .raw = &stalled, .send = Stalled.send, .plan = plan, .body = "{}", .allocator = std.testing.allocator };
    var future = try std.Io.concurrent(std.testing.io, SendJob(*TestSendClock).run, .{&job});
    defer _ = future.cancel(std.testing.io) catch {};
    try std.testing.expectError(error.Timeout, awaitSend(std.testing.io, &job, &future));
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

test "native HTTP gateway stream resolves its base URL and retains incremental UTF8 and usage" {
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
            const request_line = try reader.interface.takeDelimiterInclusive('\n');
            try std.testing.expectEqualStrings("POST /api/gw/chat/completions HTTP/1.1\r\n", request_line);
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
    config.endpoint = try std.fmt.bufPrint(&endpoint_buf, "http://127.0.0.1:{d}/api/gw", .{fixture.server.socket.address.getPort()});
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
    var clock: TestStreamClock = .{};
    var steps: [8]TestStreamScript.Step = undefined;
    for (&steps, 0..) |*step, index| step.* = .{ .ms = (index + 1) * 15, .bytes = "reasoning chunk" };
    var script: TestStreamScript = .{ .clock = &clock, .steps = &steps, .finish_ms = 120 };
    const plan: http.RequestPlan = .{ .endpoint = "fixture", .auth_style = .none, .timeout_ms = 1000, .idle_timeout_ms = 70 };
    var job = testStreamJob(&script, plan);
    _ = try job.run();
    try std.testing.expectEqual(@as(usize, 8), script.chunks);

    clock.ms = 0;
    script.chunks = 0;
    script.finish_ms = 320;
    job = testStreamJob(&script, plan);
    try std.testing.expectError(error.Timeout, job.run());
    try std.testing.expectEqual(@as(usize, 8), script.chunks);

    clock.ms = 0;
    script.chunks = 0;
    script.finish_ms = 120;
    var capped = plan;
    capped.timeout_ms = 70;
    job = testStreamJob(&script, capped);
    try std.testing.expectError(error.Timeout, job.run());
    try std.testing.expectEqual(@as(usize, 4), script.chunks);
}

// The same worker/monitor use a scripted monotonic clock in deadline tests.
// No test assumes a sleeping OS thread is rescheduled at the requested instant.
const TestStreamClock = struct {
    ms: u64 = 0,
    complete_on_sample: ?*std.atomic.Value(bool) = null,
    fn elapsedMs(self: *@This()) u64 {
        if (self.complete_on_sample) |done| {
            done.store(true, .release);
            self.complete_on_sample = null;
        }
        return self.ms;
    }
    fn wait(self: *@This()) void {
        self.ms += 10;
    }
};
const TestStreamScript = struct {
    const Step = struct { ms: u64, bytes: []const u8 };
    clock: *TestStreamClock,
    steps: []const Step = &.{},
    finish_ms: u64,
    chunks: usize = 0,
    fn send(raw: *anyopaque, _: http.RequestPlan, _: []const u8, _: std.mem.Allocator, sink: ChunkSink, ctx: *anyopaque) !ResponseMeta {
        const self: *@This() = @ptrCast(@alignCast(raw));
        for (self.steps) |step| {
            self.clock.ms = step.ms;
            try sink(ctx, step.bytes);
        }
        self.clock.ms = self.finish_ms;
        return .{ .status = 200 };
    }
    fn receive(raw: *anyopaque, _: []const u8) !void {
        const self: *@This() = @ptrCast(@alignCast(raw));
        self.chunks += 1;
    }
};
fn testStreamJob(script: *TestStreamScript, plan: http.RequestPlan) StreamJob(*TestStreamClock) {
    return .{ .timing = script.clock, .raw = script, .send = TestStreamScript.send, .plan = plan, .body = "{}", .allocator = std.testing.allocator, .sink = TestStreamScript.receive, .sink_ctx = script };
}
const TestStreamFuture = struct {
    result: anyerror!ResponseMeta = .{ .status = 200 },
    cancellations: usize = 0,
    done: ?*std.atomic.Value(bool) = null,
    stop_during_join: ?*provider.CancelToken = null,
    fn cancel(self: *@This(), _: std.Io) anyerror!ResponseMeta {
        self.cancellations += 1;
        if (self.done) |done| done.store(true, .release);
        if (self.stop_during_join) |token| token.cancel();
        return self.result;
    }
    fn await(self: *@This(), _: std.Io) anyerror!ResponseMeta {
        return self.result;
    }
};
test "timing regression stream late completion is classified without a monitor" {
    var clock: TestStreamClock = .{};
    var script: TestStreamScript = .{ .clock = &clock, .finish_ms = 70 };
    var job = testStreamJob(&script, .{ .endpoint = "fixture", .auth_style = .none, .timeout_ms = 70 });
    try std.testing.expectError(error.Timeout, job.run());
    try std.testing.expect(job.done.load(.acquire));
}
test "timing regression stream late chunks cannot revive expired idle" {
    var clock: TestStreamClock = .{};
    const steps = [_]TestStreamScript.Step{ .{ .ms = 15, .bytes = "first" }, .{ .ms = 85, .bytes = "late" } };
    var script: TestStreamScript = .{ .clock = &clock, .steps = &steps, .finish_ms = 85 };
    var job = testStreamJob(&script, .{ .endpoint = "fixture", .auth_style = .none, .timeout_ms = 1000, .idle_timeout_ms = 70 });
    try std.testing.expectError(error.Timeout, job.run());
    try std.testing.expectEqual(@as(usize, 1), script.chunks);
    try std.testing.expectEqual(@as(u64, 15), job.last_activity_ms.load(.acquire));
}
test "timing regression stream monitor preserves an already completed result" {
    var clock: TestStreamClock = .{ .ms = 200 };
    var script: TestStreamScript = .{ .clock = &clock, .finish_ms = 50 };
    var job = testStreamJob(&script, .{ .endpoint = "fixture", .auth_style = .none, .timeout_ms = 70 });
    clock.complete_on_sample = &job.done; // completion between done and clock samples
    var future: TestStreamFuture = .{};
    try std.testing.expectEqual(@as(u16, 200), (try awaitStream(std.testing.io, &job, &future)).status);
    try std.testing.expectEqual(@as(usize, 0), future.cancellations);
}
test "timing regression stream completion racing cancellation preserves its result" {
    var clock: TestStreamClock = .{ .ms = 200 };
    var script: TestStreamScript = .{ .clock = &clock, .finish_ms = 50 };
    var job = testStreamJob(&script, .{ .endpoint = "fixture", .auth_style = .none, .timeout_ms = 70 });
    var future: TestStreamFuture = .{ .done = &job.done };
    try std.testing.expectEqual(@as(u16, 200), (try awaitStream(std.testing.io, &job, &future)).status);
    try std.testing.expectEqual(@as(usize, 1), future.cancellations);
}

test "timing regression stream deadline cancellation joins and preserves Stop priority" {
    var clock: TestStreamClock = .{ .ms = 200 };
    var script: TestStreamScript = .{ .clock = &clock, .finish_ms = 50 };
    var token: provider.CancelToken = .{};
    var job = testStreamJob(&script, .{ .endpoint = "fixture", .auth_style = .none, .timeout_ms = 70, .cancel = &token });
    var future: TestStreamFuture = .{ .result = error.Canceled, .done = &job.done };
    try std.testing.expectError(error.Timeout, awaitStream(std.testing.io, &job, &future));
    try std.testing.expect(job.done.load(.acquire));
    try std.testing.expectEqual(@as(usize, 1), future.cancellations);

    job.done.store(false, .release);
    future = .{ .result = error.Timeout, .done = &job.done, .stop_during_join = &token };
    try std.testing.expectError(error.Cancelled, awaitStream(std.testing.io, &job, &future));
    try std.testing.expect(job.done.load(.acquire));
    try std.testing.expectEqual(@as(usize, 1), future.cancellations);

    const stopped_steps = [_]TestStreamScript.Step{.{ .ms = 15, .bytes = "after Stop" }};
    clock.ms = 0;
    script.steps = &stopped_steps;
    job = testStreamJob(&script, .{ .endpoint = "fixture", .auth_style = .none, .timeout_ms = 70, .cancel = &token });
    try std.testing.expectError(error.Cancelled, job.run());
    try std.testing.expectEqual(@as(usize, 0), script.chunks);
}
test "timing regression stream empty chunks do not reset the 70ms idle budget" {
    var clock: TestStreamClock = .{};
    const steps = [_]TestStreamScript.Step{ .{ .ms = 15, .bytes = "first" }, .{ .ms = 84, .bytes = "" } };
    var script: TestStreamScript = .{ .clock = &clock, .steps = &steps, .finish_ms = 85 };
    var job = testStreamJob(&script, .{ .endpoint = "fixture", .auth_style = .none, .timeout_ms = 1000, .idle_timeout_ms = 70 });
    try std.testing.expectError(error.Timeout, job.run());
    try std.testing.expectEqual(@as(u64, 15), job.last_activity_ms.load(.acquire));
}
test "timing regression stream a predeadline chunk resets idle but not the overall budget" {
    var clock: TestStreamClock = .{};
    const steps = [_]TestStreamScript.Step{ .{ .ms = 69, .bytes = "first" }, .{ .ms = 138, .bytes = "second" } };
    var script: TestStreamScript = .{ .clock = &clock, .steps = &steps, .finish_ms = 138 };
    var job = testStreamJob(&script, .{ .endpoint = "fixture", .auth_style = .none, .timeout_ms = 1000, .idle_timeout_ms = 70 });
    _ = try job.run();
    try std.testing.expectEqual(@as(usize, 2), script.chunks);
    clock.ms = 0;
    script.chunks = 0;
    job = testStreamJob(&script, .{ .endpoint = "fixture", .auth_style = .none, .timeout_ms = 70, .idle_timeout_ms = 70 });
    try std.testing.expectError(error.Timeout, job.run());
    try std.testing.expectEqual(@as(usize, 1), script.chunks);
}

const TestSendScript = struct {
    clock: *TestStreamClock,
    finish_ms: u64,
    calls: usize = 0,
    stop: ?*provider.CancelToken = null,
    failure: ?anyerror = null,
    borrowed: bool = false,
    fn send(raw: *anyopaque, _: http.RequestPlan, _: []const u8, allocator: std.mem.Allocator) !Response {
        const self: *@This() = @ptrCast(@alignCast(raw));
        self.calls += 1;
        self.clock.ms = self.finish_ms;
        if (self.stop) |token| token.cancel();
        if (self.failure) |err| return err;
        return .{ .status = 200, .retry_after_ms = 123, .body = if (self.borrowed) @constCast("borrowed payload") else try allocator.dupe(u8, "owned payload"), .owned = !self.borrowed };
    }
};
fn testSendJob(script: *TestSendScript, allocator: std.mem.Allocator, plan: http.RequestPlan) SendJob(*TestStreamClock) {
    return .{ .raw = script, .send = TestSendScript.send, .plan = plan, .body = "{}", .allocator = allocator, .timing = script.clock };
}
const TestSendFuture = struct {
    result: anyerror!Response,
    cancellations: usize = 0,
    awaits: usize = 0,
    done: ?*std.atomic.Value(bool) = null,
    stop_during_join: ?*provider.CancelToken = null,
    fn cancel(self: *@This(), _: std.Io) anyerror!Response {
        self.cancellations += 1;
        if (self.done) |done| done.store(true, .release);
        if (self.stop_during_join) |token| token.cancel();
        return self.result;
    }
    fn await(self: *@This(), _: std.Io) anyerror!Response {
        self.awaits += 1;
        if (self.stop_during_join) |token| token.cancel();
        return self.result;
    }
};
fn expectOwnedSendError(expected: anyerror, result: anyerror!Response, allocator: std.mem.Allocator) !void {
    if (result) |value| {
        var response = value;
        defer response.deinit(allocator);
        try std.testing.expectError(expected, result);
    } else |_| try std.testing.expectError(expected, result);
}
test "deadline regression send late completion rejects and frees its response once" {
    var counting = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var clock: TestStreamClock = .{};
    var script: TestSendScript = .{ .clock = &clock, .finish_ms = 70 };
    var job = testSendJob(&script, counting.allocator(), .{ .endpoint = "fixture", .auth_style = .none, .timeout_ms = 70 });
    try expectOwnedSendError(error.Timeout, job.run(), counting.allocator());
    try std.testing.expect(job.done.load(.acquire));
    try std.testing.expectEqual(@as(usize, 1), counting.allocations);
    try std.testing.expectEqual(@as(usize, 1), counting.deallocations);
    try std.testing.expectEqual(counting.allocated_bytes, counting.freed_bytes);
}
test "deadline regression send predeadline completion transfers ownership to its caller" {
    var counting = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var clock: TestStreamClock = .{};
    var script: TestSendScript = .{ .clock = &clock, .finish_ms = 69 };
    var job = testSendJob(&script, counting.allocator(), .{ .endpoint = "fixture", .auth_style = .none, .timeout_ms = 70 });
    var response = try job.run();
    try std.testing.expectEqualStrings("owned payload", response.body);
    try std.testing.expectEqual(@as(?u32, 123), response.retry_after_ms);
    try std.testing.expectEqual(@as(usize, 0), counting.deallocations);
    response.deinit(counting.allocator());
    try std.testing.expectEqual(@as(usize, 1), counting.deallocations);
}
test "deadline regression send Stop at completion releases the completed body" {
    var counting = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var clock: TestStreamClock = .{};
    var token: provider.CancelToken = .{};
    var script: TestSendScript = .{ .clock = &clock, .finish_ms = 50, .stop = &token };
    var job = testSendJob(&script, counting.allocator(), .{ .endpoint = "fixture", .auth_style = .none, .timeout_ms = 70, .cancel = &token });
    try expectOwnedSendError(error.Cancelled, job.run(), counting.allocator());
    try std.testing.expectEqual(@as(usize, 1), counting.deallocations);
}
test "deadline regression send monitor preserves a completed owned response" {
    var counting = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var clock: TestStreamClock = .{ .ms = 200 };
    var script: TestSendScript = .{ .clock = &clock, .finish_ms = 50 };
    var job = testSendJob(&script, counting.allocator(), .{ .endpoint = "fixture", .auth_style = .none, .timeout_ms = 70 });
    clock.complete_on_sample = &job.done;
    var future: TestSendFuture = .{ .result = .{ .status = 200, .body = try counting.allocator().dupe(u8, "ready") } };
    var response = try awaitSend(std.testing.io, &job, &future);
    try std.testing.expectEqualStrings("ready", response.body);
    try std.testing.expectEqual(@as(usize, 0), future.cancellations);
    try std.testing.expectEqual(@as(usize, 0), counting.deallocations);
    response.deinit(counting.allocator());
    try std.testing.expectEqual(@as(usize, 1), counting.deallocations);
}
test "deadline regression send completion racing a deadline keeps its owned response" {
    var counting = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var clock: TestStreamClock = .{ .ms = 200 };
    var script: TestSendScript = .{ .clock = &clock, .finish_ms = 50 };
    var job = testSendJob(&script, counting.allocator(), .{ .endpoint = "fixture", .auth_style = .none, .timeout_ms = 70 });
    var future: TestSendFuture = .{ .result = .{ .status = 200, .body = try counting.allocator().dupe(u8, "ready") }, .done = &job.done };
    var response = try awaitSend(std.testing.io, &job, &future);
    try std.testing.expectEqual(@as(usize, 1), future.cancellations);
    try std.testing.expectEqual(@as(usize, 0), counting.deallocations);
    response.deinit(counting.allocator());
    try std.testing.expectEqual(@as(usize, 1), counting.deallocations);
}
test "deadline regression send Stop during normal join frees the ready response" {
    var counting = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var clock: TestStreamClock = .{ .ms = 50 };
    var script: TestSendScript = .{ .clock = &clock, .finish_ms = 50 };
    var token: provider.CancelToken = .{};
    var job = testSendJob(&script, counting.allocator(), .{ .endpoint = "fixture", .auth_style = .none, .timeout_ms = 70, .cancel = &token });
    job.done.store(true, .release);
    var future: TestSendFuture = .{ .result = .{ .status = 200, .body = try counting.allocator().dupe(u8, "ready") }, .stop_during_join = &token };
    try expectOwnedSendError(error.Cancelled, awaitSend(std.testing.io, &job, &future), counting.allocator());
    try std.testing.expectEqual(@as(usize, 1), future.awaits);
    try std.testing.expectEqual(@as(usize, 1), counting.deallocations);
}
test "deadline regression send Stop during timeout join wins with and without a body" {
    for ([_]bool{ false, true }) |with_body| {
        var counting = std.testing.FailingAllocator.init(std.testing.allocator, .{});
        var clock: TestStreamClock = .{ .ms = 200 };
        var script: TestSendScript = .{ .clock = &clock, .finish_ms = 50 };
        var token: provider.CancelToken = .{};
        var job = testSendJob(&script, counting.allocator(), .{ .endpoint = "fixture", .auth_style = .none, .timeout_ms = 70, .cancel = &token });
        var future: TestSendFuture = .{ .result = if (with_body) .{ .status = 200, .body = try counting.allocator().dupe(u8, "ready") } else error.Timeout, .done = &job.done, .stop_during_join = &token };
        try expectOwnedSendError(error.Cancelled, awaitSend(std.testing.io, &job, &future), counting.allocator());
        try std.testing.expect(job.done.load(.acquire));
        try std.testing.expectEqual(@as(usize, 1), future.cancellations);
        try std.testing.expectEqual(counting.allocations, counting.deallocations);
    }
}
test "deadline regression send late borrowed responses are not freed" {
    var counting = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var clock: TestStreamClock = .{};
    var script: TestSendScript = .{ .clock = &clock, .finish_ms = 70, .borrowed = true };
    var job = testSendJob(&script, counting.allocator(), .{ .endpoint = "fixture", .auth_style = .none, .timeout_ms = 70 });
    try expectOwnedSendError(error.Timeout, job.run(), counting.allocator());
    try std.testing.expectEqual(@as(usize, 0), counting.allocations);
    try std.testing.expectEqual(@as(usize, 0), counting.deallocations);
}
test "deadline regression send preserves an early failure when its monitor wakes late" {
    var clock: TestStreamClock = .{ .ms = 200 };
    var script: TestSendScript = .{ .clock = &clock, .finish_ms = 20, .failure = error.ProviderFailure };
    var job = testSendJob(&script, std.testing.allocator, .{ .endpoint = "fixture", .auth_style = .none, .timeout_ms = 70 });
    clock.complete_on_sample = &job.done;
    var future: TestSendFuture = .{ .result = error.ProviderFailure };
    try expectOwnedSendError(error.ProviderFailure, awaitSend(std.testing.io, &job, &future), std.testing.allocator);
}

test "deadline regression send native late and stalled HTTP bodies release their allocations" {
    const Fixture = struct {
        io: std.Io,
        server: std.Io.net.Server,
        clock: *TestSendClock,
        stall: bool,
        exited: bool = false,
        fn serve(self: *@This()) !void {
            defer self.exited = true;
            const connection = try self.server.accept(self.io);
            defer connection.close(self.io);
            var buffer: [4096]u8 = undefined;
            var reader = connection.reader(self.io, &buffer);
            var length: usize = 0;
            while (true) {
                const line = try reader.interface.takeDelimiterInclusive('\n');
                if (std.ascii.startsWithIgnoreCase(line, "content-length:")) length = try std.fmt.parseInt(usize, std.mem.trim(u8, line[15..], " \r\n"), 10);
                if (std.mem.eql(u8, line, "\r\n")) break;
            }
            try reader.interface.discardAll(length);
            const payload = "late-owned-body";
            var writer = connection.writer(self.io, &.{});
            try writer.interface.print("HTTP/1.1 200 OK\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{payload.len});
            try writer.interface.flush();
            if (self.stall) {
                try writer.interface.writeAll(payload[0..1]);
                try writer.interface.flush();
                self.clock.ms.store(70, .release);
                try std.Io.sleep(self.io, .fromMilliseconds(60_000), .awake);
                return error.UnexpectedCompletion;
            }
            // The actual body cannot complete until the exact request deadline.
            self.clock.ms.store(70, .release);
            try writer.interface.writeAll(payload);
            try writer.interface.flush();
        }
    };
    for ([_]bool{ false, true }) |stall| {
        var clock: TestSendClock = .{};
        const address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
        var fixture: Fixture = .{ .io = std.testing.io, .server = try address.listen(std.testing.io, .{}), .clock = &clock, .stall = stall };
        defer fixture.server.deinit(std.testing.io);
        var serving = try std.Io.concurrent(std.testing.io, Fixture.serve, .{&fixture});
        defer _ = serving.cancel(std.testing.io) catch {};
        var endpoint_buffer: [128]u8 = undefined;
        const endpoint = try std.fmt.bufPrint(&endpoint_buffer, "http://127.0.0.1:{d}/fixture", .{fixture.server.socket.address.getPort()});
        var counting = std.testing.FailingAllocator.init(std.testing.allocator, .{});
        var context: NativeContext = .{ .io = std.testing.io };
        var job: SendJob(*TestSendClock) = .{ .timing = &clock, .raw = &context, .send = nativeSendUnbounded, .plan = .{ .endpoint = endpoint, .auth_style = .none, .timeout_ms = 70 }, .body = "{}", .allocator = counting.allocator() };
        if (stall) {
            // The real monitor cancels a body read and joins its owner.
            var sending = try std.Io.concurrent(std.testing.io, SendJob(*TestSendClock).run, .{&job});
            defer _ = sending.cancel(std.testing.io) catch {};
            try expectOwnedSendError(error.Timeout, awaitSend(std.testing.io, &job, &sending), counting.allocator());
            try std.testing.expectError(error.Canceled, serving.cancel(std.testing.io));
        } else {
            // With no monitor, the worker must reject and reclaim a late body.
            try expectOwnedSendError(error.Timeout, job.run(), counting.allocator());
            try serving.await(std.testing.io);
        }
        try std.testing.expect(fixture.exited);
        try std.testing.expect(job.done.load(.acquire));
        try std.testing.expect(counting.allocations > 0);
        try std.testing.expectEqual(counting.allocated_bytes, counting.freed_bytes);
    }
}

const TestSendClock = struct {
    ms: std.atomic.Value(u64) = .init(0),
    fn elapsedMs(self: *@This()) u64 {
        return self.ms.load(.acquire);
    }
    fn wait(_: *@This()) void {
        @import("retry.zig").wait(10, null) catch unreachable;
    }
};
test "deadline regression send queued expiry and Stop cannot dispatch or allocate" {
    var counting = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var clock: TestStreamClock = .{ .ms = 70 };
    var script: TestSendScript = .{ .clock = &clock, .finish_ms = 70 };
    var job = testSendJob(&script, counting.allocator(), .{ .endpoint = "fixture", .auth_style = .none, .timeout_ms = 70 });
    try expectOwnedSendError(error.Timeout, job.run(), counting.allocator());
    try std.testing.expectEqual(@as(usize, 0), script.calls);
    try std.testing.expect(job.done.load(.acquire));
    var token: provider.CancelToken = .{};
    token.cancel();
    clock.ms = 0;
    job = testSendJob(&script, counting.allocator(), .{ .endpoint = "fixture", .auth_style = .none, .timeout_ms = 70, .cancel = &token });
    try expectOwnedSendError(error.Cancelled, job.run(), counting.allocator());
    try std.testing.expectEqual(@as(usize, 0), script.calls);
    try std.testing.expectEqual(@as(usize, 0), counting.allocations);
    try std.testing.expectEqual(@as(usize, 0), counting.deallocations);
}
