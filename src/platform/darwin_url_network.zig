//! System CFHost/CFNetwork interop for the native Zig URL reader. HTTP/TLS,
//! URLs, IP policy, decompression and budgets remain in fetch_url_transport.
const std = @import("std");
const IpAddress = std.Io.net.IpAddress;
const Ref = *const anyopaque;
const Host = *anyopaque;
const utf8: u32 = 0x08000100;
const StreamError = extern struct { domain: isize = 0, code: c_int = 0 };
const Context = extern struct { version: isize = 0, info: ?*anyopaque, retain: ?Ref = null, release: ?Ref = null, describe: ?Ref = null };
extern "c" fn CFStringCreateWithCString(?Ref, [*:0]const u8, u32) ?Ref;
extern "c" fn CFRelease(Ref) void;
extern "c" fn CFEqual(Ref, Ref) u8;
extern "c" fn CFURLCreateWithBytes(?Ref, [*]const u8, isize, u32, ?Ref) ?Ref;
extern "c" fn CFArrayGetCount(Ref) isize;
extern "c" fn CFArrayGetValueAtIndex(Ref, isize) ?Ref;
extern "c" fn CFDictionaryGetValue(Ref, Ref) ?Ref;
extern "c" fn CFDataGetLength(Ref) isize;
extern "c" fn CFDataGetBytePtr(Ref) ?[*]const u8;
extern "c" fn CFNetworkCopySystemProxySettings() ?Ref;
extern "c" fn CFNetworkCopyProxiesForURL(Ref, Ref) ?Ref;
extern "c" const kCFProxyTypeKey: Ref;
extern "c" const kCFProxyTypeNone: Ref;
extern "c" fn CFHostCreateWithName(?Ref, Ref) ?Host;
extern "c" fn CFHostSetClient(Host, ?*const fn (Host, c_int, ?*const StreamError, ?*anyopaque) callconv(.c) void, ?*Context) u8;
extern "c" fn CFHostScheduleWithRunLoop(Host, Ref, Ref) void;
extern "c" fn CFHostUnscheduleFromRunLoop(Host, Ref, Ref) void;
extern "c" fn CFHostStartInfoResolution(Host, c_int, *StreamError) u8;
extern "c" fn CFHostCancelInfoResolution(Host, c_int) void;
extern "c" fn CFHostGetAddressing(Host, *u8) ?Ref;
extern "c" fn CFRunLoopGetCurrent() Ref;
extern "c" fn CFRunLoopRunInMode(Ref, f64, u8) c_int;

pub fn proxyRequired(url: [:0]const u8) bool {
    // An environment proxy is part of the route too. NO_PROXY handling is
    // deliberately conservative until a constrained proxy route is supported.
    for ([_][:0]const u8{ "http_proxy", "https_proxy", "all_proxy", "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY" }) |key| {
        if (std.c.getenv(key)) |value| if (value[0] != 0) return true;
    }
    const settings = CFNetworkCopySystemProxySettings() orelse return true;
    defer CFRelease(settings);
    const target = CFURLCreateWithBytes(null, url.ptr, @intCast(url.len), utf8, null) orelse return true;
    defer CFRelease(target);
    const proxies = CFNetworkCopyProxiesForURL(target, settings) orelse return true;
    defer CFRelease(proxies);
    const count = CFArrayGetCount(proxies);
    if (count == 0) return true;
    var index: isize = 0;
    while (index < count) : (index += 1) {
        const item = CFArrayGetValueAtIndex(proxies, index) orelse return true;
        const kind = CFDictionaryGetValue(item, kCFProxyTypeKey) orelse return true;
        if (CFEqual(kind, kCFProxyTypeNone) == 0) return true;
    }
    return false;
}
fn fromSockaddr(bytes: []const u8) ?IpAddress {
    if (bytes.len < @sizeOf(std.c.sockaddr)) return null;
    const family = bytes[1];
    if (family == std.c.AF.INET and bytes.len >= @sizeOf(std.c.sockaddr.in)) {
        const ip = std.mem.bytesToValue(std.c.sockaddr.in, bytes[0..@sizeOf(std.c.sockaddr.in)]);
        return .{ .ip4 = .{ .bytes = std.mem.asBytes(&ip.addr)[0..4].*, .port = std.mem.bigToNative(u16, ip.port) } };
    }
    if (family == std.c.AF.INET6 and bytes.len >= @sizeOf(std.c.sockaddr.in6)) {
        const ip = std.mem.bytesToValue(std.c.sockaddr.in6, bytes[0..@sizeOf(std.c.sockaddr.in6)]);
        if (ip.scope_id != 0) return null;
        return .{ .ip6 = .{ .bytes = ip.addr, .port = std.mem.bigToNative(u16, ip.port) } };
    }
    return null;
}
pub fn peerMatches(fd: std.c.fd_t, expected: IpAddress) bool {
    var storage: std.c.sockaddr.storage = undefined;
    var length: std.c.socklen_t = @sizeOf(@TypeOf(storage));
    if (std.c.getpeername(fd, @ptrCast(&storage), &length) != 0) return false;
    const actual = fromSockaddr(std.mem.asBytes(&storage)[0..length]) orelse return false;
    if (std.meta.activeTag(actual) != std.meta.activeTag(expected) or actual.getPort() != expected.getPort()) return false;
    return switch (expected) {
        .ip4 => |ip| std.mem.eql(u8, &ip.bytes, &actual.ip4.bytes),
        .ip6 => |ip| std.mem.eql(u8, &ip.bytes, &actual.ip6.bytes),
    };
}
pub const Addresses = struct { values: [32]IpAddress = undefined, count: usize = 0 };
const Resolution = struct {
    done: bool = false,
    error_value: StreamError = .{},
    fn complete(_: Host, _: c_int, failure: ?*const StreamError, raw: ?*anyopaque) callconv(.c) void {
        const self: *Resolution = @ptrCast(@alignCast(raw.?));
        if (failure) |value| self.error_value = value.*;
        self.done = true;
    }
};
/// CFHost's callback is scheduled only on this worker's private run-loop mode.
/// Cancellation tears down scheduling before stack callback state expires.
/// This replaces std.Io.Threaded's currently synchronous Darwin getaddrinfo.
pub fn resolve(name: [:0]const u8, cancelled: *const fn (?*anyopaque) callconv(.c) c_int, userdata: ?*anyopaque) error{ Canceled, SystemResources, UnknownHostName }!Addresses {
    if (cancelled(userdata) != 0) return error.Canceled;
    const text = CFStringCreateWithCString(null, name, utf8) orelse return error.SystemResources;
    defer CFRelease(text);
    const host = CFHostCreateWithName(null, text) orelse return error.SystemResources;
    defer CFRelease(host);
    const mode = CFStringCreateWithCString(null, "ZeroWorkFetchDNS", utf8) orelse return error.SystemResources;
    defer CFRelease(mode);
    const loop = CFRunLoopGetCurrent();
    var state: Resolution = .{};
    var context: Context = .{ .info = &state };
    if (CFHostSetClient(host, Resolution.complete, &context) == 0) return error.SystemResources;
    defer _ = CFHostSetClient(host, null, null);
    CFHostScheduleWithRunLoop(host, loop, mode);
    defer CFHostUnscheduleFromRunLoop(host, loop, mode);
    defer CFHostCancelInfoResolution(host, 0);
    var failure: StreamError = .{};
    if (CFHostStartInfoResolution(host, 0, &failure) == 0) return error.UnknownHostName;
    while (!state.done) {
        if (cancelled(userdata) != 0) return error.Canceled;
        _ = CFRunLoopRunInMode(mode, 0.01, 0);
    }
    if (state.error_value.code != 0) return error.UnknownHostName;
    var available: u8 = 0;
    const addresses = CFHostGetAddressing(host, &available) orelse return error.UnknownHostName;
    if (available == 0) return error.UnknownHostName;
    var result: Addresses = .{};
    var index: isize = 0;
    while (index < CFArrayGetCount(addresses) and result.count < result.values.len) : (index += 1) {
        const data = CFArrayGetValueAtIndex(addresses, index) orelse continue;
        const length = CFDataGetLength(data);
        if (length <= 0 or length > 128) continue;
        const bytes = CFDataGetBytePtr(data) orelse continue;
        if (fromSockaddr(bytes[0..@intCast(length)])) |address| {
            result.values[result.count] = address;
            result.count += 1;
        }
    }
    if (result.count == 0) return error.UnknownHostName;
    return result;
}

test "fetch_url Darwin resolver performs DNS and cancels after asynchronous start" {
    const Cancel = struct {
        fn never(_: ?*anyopaque) callconv(.c) c_int {
            return 0;
        }
        fn afterStart(raw: ?*anyopaque) callconv(.c) c_int {
            const calls: *usize = @ptrCast(@alignCast(raw.?));
            calls.* += 1;
            return @intFromBool(calls.* >= 2);
        }
    };
    const localhost = try resolve("localhost", Cancel.never, null);
    try std.testing.expect(localhost.count > 0);
    var calls: usize = 0;
    try std.testing.expectError(error.Canceled, resolve("example.com", Cancel.afterStart, &calls));
    try std.testing.expectEqual(@as(usize, 2), calls);
}

test "fetch_url Darwin getpeername verifies the actual peer rather than local address" {
    const listener = std.c.socket(std.c.AF.INET, std.c.SOCK.STREAM, 0);
    try std.testing.expect(listener >= 0);
    defer _ = std.c.close(listener);
    var local: std.c.sockaddr.in = .{ .port = 0, .addr = @bitCast([4]u8{ 127, 0, 0, 1 }) };
    try std.testing.expectEqual(@as(c_int, 0), std.c.bind(listener, @ptrCast(&local), @sizeOf(@TypeOf(local))));
    try std.testing.expectEqual(@as(c_int, 0), std.c.listen(listener, 1));
    var length: std.c.socklen_t = @sizeOf(@TypeOf(local));
    try std.testing.expectEqual(@as(c_int, 0), std.c.getsockname(listener, @ptrCast(&local), &length));
    const client = std.c.socket(std.c.AF.INET, std.c.SOCK.STREAM, 0);
    try std.testing.expect(client >= 0);
    defer _ = std.c.close(client);
    try std.testing.expectEqual(@as(c_int, 0), std.c.connect(client, @ptrCast(&local), length));
    const accepted = std.c.accept(listener, null, null);
    try std.testing.expect(accepted >= 0);
    defer _ = std.c.close(accepted);
    var expected = try IpAddress.parseIp4("127.0.0.1", std.mem.bigToNative(u16, local.port));
    try std.testing.expect(peerMatches(client, expected));
    expected.ip4.bytes[3] = 2;
    try std.testing.expect(!peerMatches(client, expected));
}
