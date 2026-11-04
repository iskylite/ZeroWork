const std = @import("std");
const net = @import("fetch_url_transport.zig");
const Io = std.Io;

test "fetch_url std.http redirect resolution rejects credentials private targets and downgrade" {
    const a = std.testing.allocator;
    const next = try net.resolveRedirect(a, "https://example.com/docs/current?a=1", "../next?b=2#part");
    defer a.free(next);
    try std.testing.expectEqualStrings("https://example.com/next?b=2", next);
    try std.testing.expectError(error.UrlNotAllowed, net.resolveRedirect(a, "https://example.com/", "http://example.com/"));
    try std.testing.expectError(error.UrlNotAllowed, net.resolveRedirect(a, "https://example.com/", "https://127.0.0.1/"));
    try std.testing.expectError(error.UrlNotAllowed, net.resolveRedirect(a, "https://example.com/", "https://user:secret@example.com/"));
    try std.testing.expect(!net.textType("application/jsonp"));
    try std.testing.expect(!net.textType("application/pdf"));
}

test "fetch_url std.Io gate blocks the actual sockaddr before the underlying dial" {
    const Fake = struct {
        calls: usize = 0,
        fn connect(raw: ?*anyopaque, _: *const Io.net.IpAddress, _: Io.net.IpAddress.ConnectOptions) Io.net.IpAddress.ConnectError!Io.net.Socket {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.calls += 1;
            return error.ConnectionRefused;
        }
    };
    var fake: Fake = .{};
    var table: Io.VTable = undefined;
    table.netConnectIp = Fake.connect;
    var gateway: net.NetworkIo = .{ .base = .{ .userdata = &fake, .vtable = &table } };
    const filtered = gateway.io();
    const private = try Io.net.IpAddress.parseIp4("169.254.169.254", 80);
    try std.testing.expectError(error.AccessDenied, private.connect(filtered, .{ .mode = .stream }));
    try std.testing.expectEqual(@as(usize, 0), fake.calls);
    gateway.proxy = .{ .kind = .http, .host = "127.0.0.1", .port = 7890 };
    try std.testing.expectError(error.AccessDenied, private.connect(filtered, .{ .mode = .stream }));
    try std.testing.expectEqual(@as(usize, 0), fake.calls);
    gateway.proxy = null;
    const public = try Io.net.IpAddress.parseIp4("1.1.1.1", 443);
    try std.testing.expectError(error.ConnectionRefused, public.connect(filtered, .{ .mode = .stream }));
    try std.testing.expectEqual(@as(usize, 1), fake.calls);
}

fn compressed(a: std.mem.Allocator, text: []const u8, container: std.compress.flate.Container) ![]u8 {
    var output = try Io.Writer.Allocating.initCapacity(a, 8192);
    defer output.deinit();
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var zip = try std.compress.flate.Compress.init(&output.writer, &window, container, .fastest);
    try zip.writer.writeAll(text);
    try zip.finish();
    return output.toOwnedSlice();
}
test "fetch_url Zig streaming enforces 2MiB compressed and 4MiB decoded independently" {
    const a = std.testing.allocator;
    const large = try a.alloc(u8, net.decode_limit + 1);
    defer a.free(large);
    @memset(large, 'a');
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(a);
    var received: usize = 0;
    var raw = Io.Reader.fixed(large[0 .. net.receive_limit + 1]);
    try std.testing.expectError(error.ResponseTooLarge, net.readBody(a, &raw, .identity, &output, &received));
    try std.testing.expect(output.items.len <= net.receive_limit);
    output.clearRetainingCapacity();
    received = 0;
    const bomb = try compressed(a, large, .gzip);
    defer a.free(bomb);
    raw = Io.Reader.fixed(bomb);
    try std.testing.expectError(error.ResponseTooLarge, net.readBody(a, &raw, .gzip, &output, &received));
    try std.testing.expect(output.items.len <= net.decode_limit and received <= net.receive_limit);
    for ([_]struct { container: std.compress.flate.Container, encoding: std.http.ContentEncoding }{ .{ .container = .gzip, .encoding = .gzip }, .{ .container = .zlib, .encoding = .deflate } }) |format| {
        const encoded = try compressed(a, "actual bounded text\n", format.container);
        defer a.free(encoded);
        output.clearRetainingCapacity();
        received = 0;
        raw = Io.Reader.fixed(encoded);
        try net.readBody(a, &raw, format.encoding, &output, &received);
        try std.testing.expectEqualStrings("actual bounded text\n", output.items);
        try std.testing.expectEqual(encoded.len, received);
    }
}

test "fetch_url std.http production route fetches through the configured system proxy" {
    const Policy = struct {
        fn allow(_: *anyopaque, _: []const u8) net.Code {
            return .ok;
        }
    };
    var flag: u8 = 0;
    const override = if (std.c.getenv("ZEROWORK_FETCH_TEST_URL")) |value| std.mem.sliceTo(value, 0) else null;
    var result = net.fetch(std.testing.allocator, std.testing.io, .{ .context = &flag, .authorize = Policy.allow }, override orelse "https://example.com/", null);
    defer result.deinit(std.testing.allocator);
    if (result.code != .ok) std.debug.print("fetch result code={s} stage={d} status={d} sent={}\n", .{ @tagName(result.code), result.stage, result.http_status, result.request_sent });
    try std.testing.expect(result.code == .ok and result.request_sent and result.http_status == 200);
    try std.testing.expect(result.elapsed_ms < net.total_ms + 1000);
    try std.testing.expect(result.observed_at > 0);
    if (override != null) std.debug.print("HTTP {d}, {d} received bytes, request_sent={}\n", .{ result.http_status, result.received_bytes, result.request_sent });
}
