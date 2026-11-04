//! Resolve the route for each URL using environment overrides or macOS proxy
//! settings (including bypass rules and cancellable PAC evaluation).
const std = @import("std");
const Ref = *const anyopaque;
const utf8: u32 = 0x08000100;
const Context = extern struct { version: isize = 0, info: ?*anyopaque, retain: ?Ref = null, release: ?Ref = null, describe: ?Ref = null };
extern "c" fn CFRelease(Ref) void;
extern "c" fn CFStringCreateWithCString(?Ref, [*:0]const u8, u32) ?Ref;
extern "c" fn CFDictionaryCreate(?Ref, [*]const Ref, [*]const Ref, isize, ?Ref, ?Ref) ?Ref;
extern "c" fn CFArrayCreate(?Ref, [*]const Ref, isize, ?Ref) ?Ref;
extern "c" fn CFRetain(Ref) Ref;
extern "c" fn CFEqual(Ref, Ref) u8;
extern "c" fn CFURLCreateWithBytes(?Ref, [*]const u8, isize, u32, ?Ref) ?Ref;
extern "c" fn CFArrayGetCount(Ref) isize;
extern "c" fn CFArrayGetValueAtIndex(Ref, isize) ?Ref;
extern "c" fn CFDictionaryGetValue(Ref, Ref) ?Ref;
extern "c" fn CFStringGetLength(Ref) isize;
extern "c" fn CFStringGetMaximumSizeForEncoding(isize, u32) isize;
extern "c" fn CFStringGetCString(Ref, [*]u8, isize, u32) u8;
extern "c" fn CFNumberGetValue(Ref, c_int, *i32) u8;
extern "c" fn CFNetworkCopySystemProxySettings() ?Ref;
extern "c" fn CFNetworkCopyProxiesForURL(Ref, Ref) ?Ref;
extern "c" const kCFProxyTypeKey: Ref;
extern "c" const kCFProxyTypeNone: Ref;
extern "c" const kCFProxyTypeHTTP: Ref;
extern "c" const kCFProxyTypeHTTPS: Ref;
extern "c" const kCFProxyTypeSOCKS: Ref;
extern "c" const kCFProxyTypeAutoConfigurationURL: Ref;
extern "c" const kCFProxyTypeAutoConfigurationJavaScript: Ref;
extern "c" const kCFProxyHostNameKey: Ref;
extern "c" const kCFProxyPortNumberKey: Ref;
extern "c" const kCFProxyUsernameKey: Ref;
extern "c" const kCFProxyPasswordKey: Ref;
extern "c" const kCFProxyAutoConfigurationURLKey: Ref;
extern "c" const kCFProxyAutoConfigurationJavaScriptKey: Ref;
const Callback = *const fn (?*anyopaque, ?Ref, ?Ref) callconv(.c) void;
extern "c" fn CFNetworkExecuteProxyAutoConfigurationURL(Ref, Ref, Callback, *Context) ?Ref;
extern "c" fn CFNetworkExecuteProxyAutoConfigurationScript(Ref, Ref, Callback, *Context) ?Ref;
extern "c" fn CFRunLoopGetCurrent() Ref;
extern "c" const kCFRunLoopDefaultMode: Ref;
extern "c" fn CFRunLoopAddSource(Ref, Ref, Ref) void;
extern "c" fn CFRunLoopRemoveSource(Ref, Ref, Ref) void;
extern "c" fn CFRunLoopSourceInvalidate(Ref) void;
extern "c" fn CFRunLoopRunInMode(Ref, f64, u8) c_int;

pub const Proxy = struct {
    kind: enum { http, socks5 },
    host: []const u8,
    port: u16,
    username: []const u8 = "",
    password: []const u8 = "",
};
pub const Error = error{ OutOfMemory, Canceled, ProxyConfigurationUnavailable, UnsupportedProxy, InvalidProxy };

fn string(a: std.mem.Allocator, value: Ref) Error![]const u8 {
    const max = CFStringGetMaximumSizeForEncoding(CFStringGetLength(value), utf8);
    if (max < 0 or max > 8192) return error.InvalidProxy;
    const buffer = try a.alloc(u8, @intCast(max + 1));
    if (CFStringGetCString(value, buffer.ptr, @intCast(buffer.len), utf8) == 0) return error.InvalidProxy;
    return buffer[0..std.mem.indexOfScalar(u8, buffer, 0).?];
}
fn env(key: [:0]const u8) ?[]const u8 {
    const value = std.c.getenv(key) orelse return null;
    const text = std.mem.sliceTo(value, 0);
    return if (text.len == 0) null else text;
}
fn host(uri: std.Uri) Error![]const u8 {
    const component = uri.host orelse return error.InvalidProxy;
    const value = switch (component) {
        .raw, .percent_encoded => |text| text,
    };
    if (value.len == 0 or value.len > 255 or std.mem.indexOfAny(u8, value, "%\r\n") != null) return error.InvalidProxy;
    return if (value[0] == '[' and value[value.len - 1] == ']') value[1 .. value.len - 1] else value;
}
pub fn parse(a: std.mem.Allocator, raw: []const u8) Error!Proxy {
    const url = if (std.mem.indexOf(u8, raw, "://") == null) try std.fmt.allocPrint(a, "http://{s}", .{raw}) else raw;
    const uri = std.Uri.parse(url) catch return error.InvalidProxy;
    const kind: @FieldType(Proxy, "kind") = if (std.ascii.eqlIgnoreCase(uri.scheme, "http")) .http else if (std.ascii.eqlIgnoreCase(uri.scheme, "socks5") or std.ascii.eqlIgnoreCase(uri.scheme, "socks5h")) .socks5 else return error.UnsupportedProxy;
    const port = uri.port orelse @as(u16, if (kind == .http) 80 else 1080);
    if (port == 0) return error.InvalidProxy;
    return .{ .kind = kind, .host = try a.dupe(u8, try host(uri)), .port = port, .username = if (uri.user) |user| try user.toRawMaybeAlloc(a) else "", .password = if (uri.password) |password| try password.toRawMaybeAlloc(a) else "" };
}
pub fn bypass(uri: std.Uri, rules: []const u8) bool {
    const name = host(uri) catch return false;
    const port = uri.port orelse @as(u16, if (std.ascii.eqlIgnoreCase(uri.scheme, "https")) 443 else 80);
    var items = std.mem.splitScalar(u8, rules, ',');
    while (items.next()) |raw| {
        var rule = std.mem.trim(u8, raw, " \t");
        if (std.mem.eql(u8, rule, "*")) return true;
        if (std.mem.lastIndexOfScalar(u8, rule, ':')) |colon| {
            // An unbracketed IPv6 literal is matched as a host, not host:port.
            if (std.mem.indexOfScalar(u8, rule[0..colon], ':') == null or (rule.len > 0 and rule[0] == '[')) {
                const only_port = std.fmt.parseInt(u16, rule[colon + 1 ..], 10) catch continue;
                if (only_port != port) continue;
                rule = rule[0..colon];
            }
        }
        if (rule.len > 1 and rule[0] == '[' and rule[rule.len - 1] == ']') rule = rule[1 .. rule.len - 1];
        if (rule.len > 0 and rule[0] == '.') rule = rule[1..];
        if (rule.len == 0) continue;
        if (std.ascii.eqlIgnoreCase(name, rule)) return true;
        if (name.len > rule.len and name[name.len - rule.len - 1] == '.' and std.ascii.endsWithIgnoreCase(name, rule)) return true;
    }
    return false;
}
const Pac = struct {
    done: bool = false,
    proxies: ?Ref = null,
    fn complete(raw: ?*anyopaque, proxies: ?Ref, failure: ?Ref) callconv(.c) void {
        const self: *Pac = @ptrCast(@alignCast(raw.?));
        if (failure == null) {
            if (proxies) |value| self.proxies = CFRetain(value);
        }
        self.done = true;
    }
};
fn select(a: std.mem.Allocator, proxies: Ref, url: Ref, cancelled: *const fn (?*anyopaque) callconv(.c) c_int, userdata: ?*anyopaque, depth: u8) Error!?Proxy {
    if (depth > 2 or CFArrayGetCount(proxies) == 0) return error.ProxyConfigurationUnavailable;
    // Respect the system's preferred route; never silently fall back to DIRECT.
    const item = CFArrayGetValueAtIndex(proxies, 0) orelse return error.InvalidProxy;
    const kind = CFDictionaryGetValue(item, kCFProxyTypeKey) orelse return error.InvalidProxy;
    if (CFEqual(kind, kCFProxyTypeNone) != 0) return null;
    if (CFEqual(kind, kCFProxyTypeAutoConfigurationURL) != 0 or CFEqual(kind, kCFProxyTypeAutoConfigurationJavaScript) != 0) {
        const is_url = CFEqual(kind, kCFProxyTypeAutoConfigurationURL) != 0;
        const value = CFDictionaryGetValue(item, if (is_url) kCFProxyAutoConfigurationURLKey else kCFProxyAutoConfigurationJavaScriptKey) orelse return error.InvalidProxy;
        var pac: Pac = .{};
        defer if (pac.proxies) |list| CFRelease(list);
        var context: Context = .{ .info = &pac };
        const source = (if (is_url) CFNetworkExecuteProxyAutoConfigurationURL(value, url, Pac.complete, &context) else CFNetworkExecuteProxyAutoConfigurationScript(value, url, Pac.complete, &context)) orelse return error.ProxyConfigurationUnavailable;
        defer CFRelease(source);
        defer CFRunLoopSourceInvalidate(source);
        const loop = CFRunLoopGetCurrent();
        CFRunLoopAddSource(loop, source, kCFRunLoopDefaultMode);
        defer CFRunLoopRemoveSource(loop, source, kCFRunLoopDefaultMode);
        while (!pac.done) {
            if (cancelled(userdata) != 0) return error.Canceled;
            _ = CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.01, 1);
        }
        return select(a, pac.proxies orelse return error.ProxyConfigurationUnavailable, url, cancelled, userdata, depth + 1);
    }
    // CF's HTTPS type is the HTTP tunneling proxy configured for HTTPS URLs,
    // not a TLS-encrypted connection to the proxy endpoint.
    const proxy_kind: @FieldType(Proxy, "kind") = if (CFEqual(kind, kCFProxyTypeHTTP) != 0 or CFEqual(kind, kCFProxyTypeHTTPS) != 0) .http else if (CFEqual(kind, kCFProxyTypeSOCKS) != 0) .socks5 else return error.UnsupportedProxy;
    const hostname = CFDictionaryGetValue(item, kCFProxyHostNameKey) orelse return error.InvalidProxy;
    const number = CFDictionaryGetValue(item, kCFProxyPortNumberKey) orelse return error.InvalidProxy;
    var port: i32 = 0;
    if (CFNumberGetValue(number, 3, &port) == 0 or port < 1 or port > 65535) return error.InvalidProxy;
    return .{ .kind = proxy_kind, .host = try string(a, hostname), .port = @intCast(port), .username = if (CFDictionaryGetValue(item, kCFProxyUsernameKey)) |value| try string(a, value) else "", .password = if (CFDictionaryGetValue(item, kCFProxyPasswordKey)) |value| try string(a, value) else "" };
}
pub fn route(a: std.mem.Allocator, url: []const u8, cancelled: *const fn (?*anyopaque) callconv(.c) c_int, userdata: ?*anyopaque) Error!?Proxy {
    if (cancelled(userdata) != 0) return error.Canceled;
    const uri = std.Uri.parse(url) catch return error.InvalidProxy;
    const override = if (std.ascii.eqlIgnoreCase(uri.scheme, "https")) env("https_proxy") orelse env("HTTPS_PROXY") else env("http_proxy") orelse env("HTTP_PROXY");
    if (override orelse env("all_proxy") orelse env("ALL_PROXY")) |value| {
        if (bypass(uri, env("no_proxy") orelse env("NO_PROXY") orelse "")) return null;
        return try parse(a, value);
    }
    const settings = CFNetworkCopySystemProxySettings() orelse return error.ProxyConfigurationUnavailable;
    defer CFRelease(settings);
    const target = CFURLCreateWithBytes(null, url.ptr, @intCast(url.len), utf8, null) orelse return error.OutOfMemory;
    defer CFRelease(target);
    const proxies = CFNetworkCopyProxiesForURL(target, settings) orelse return error.ProxyConfigurationUnavailable;
    defer CFRelease(proxies);
    return select(a, proxies, target, cancelled, userdata, 0);
}

test "fetch_url proxy URLs and NO_PROXY preserve scheme host and port boundaries" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const proxy = try parse(a, "http://user:p%40ss@127.0.0.1:7890");
    try std.testing.expectEqualStrings("p@ss", proxy.password);
    try std.testing.expectEqual(@as(u16, 7890), proxy.port);
    try std.testing.expectEqual(.socks5, (try parse(a, "socks5://[::1]:1080")).kind);
    try std.testing.expectError(error.UnsupportedProxy, parse(a, "https://proxy.example:443"));
    const uri = try std.Uri.parse("https://docs.example.com/");
    try std.testing.expect(bypass(uri, ".example.com:443"));
    try std.testing.expect(!bypass(uri, "example.com:80,ample.com"));
    try std.testing.expect(!bypass(try std.Uri.parse("https://notexample.com/"), "example.com"));
}

test "fetch_url macOS PAC resolves configured routes and cancels without changing system settings" {
    const Cancel = struct {
        fn never(_: ?*anyopaque) callconv(.c) c_int {
            return 0;
        }
        fn always(_: ?*anyopaque) callconv(.c) c_int {
            return 1;
        }
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const text = "https://example.com/";
    const url = CFURLCreateWithBytes(null, text.ptr, text.len, utf8, null).?;
    defer CFRelease(url);
    for ([_][:0]const u8{ "function FindProxyForURL(url, host) { return 'PROXY 127.0.0.1:9080'; }", "function FindProxyForURL(url, host) { return 'DIRECT'; }" }, 0..) |script, index| {
        const source = CFStringCreateWithCString(null, script.ptr, utf8).?;
        defer CFRelease(source);
        const dictionary = CFDictionaryCreate(null, &.{ kCFProxyTypeKey, kCFProxyAutoConfigurationJavaScriptKey }, &.{ kCFProxyTypeAutoConfigurationJavaScript, source }, 2, null, null).?;
        defer CFRelease(dictionary);
        const list = CFArrayCreate(null, &.{dictionary}, 1, null).?;
        defer CFRelease(list);
        const proxy = try select(arena.allocator(), list, url, Cancel.never, null, 0);
        if (index == 0) {
            try std.testing.expectEqualStrings("127.0.0.1", proxy.?.host);
            try std.testing.expectEqual(@as(u16, 9080), proxy.?.port);
            try std.testing.expectEqual(.http, proxy.?.kind);
        } else try std.testing.expect(proxy == null);
        try std.testing.expectError(error.Canceled, select(arena.allocator(), list, url, Cancel.always, null, 0));
    }
}
