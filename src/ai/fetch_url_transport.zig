//! Public-network HTTP reader built on the same std.http/std.Io as providers.
//! Its dedicated Io view filters actual dial addresses and replaces Darwin's
//! blocking getaddrinfo with the small cancellable platform resolver bridge.
const std = @import("std");
const Io = std.Io;
const provider = @import("provider.zig");
const darwin = @import("../platform/darwin_url_network.zig");
pub const Code = enum(c_int) { ok, invalid, not_allowed, capability, denied, approval, scope_changed, dns, connect, tls, timeout, redirect, too_large, unsupported, http, cancelled, network, memory };
pub const receive_limit = 2 * 1024 * 1024;
pub const decode_limit = 4 * 1024 * 1024;
pub const total_ms = 15_000;
pub const Result = struct {
    code: Code = .ok,
    stage: c_int = 0,
    http_status: c_int = 0,
    request_sent: bool = false,
    cancelled: bool = false,
    local_released: bool = true,
    elapsed_ms: u64 = 0,
    observed_at: i64 = 0,
    body: std.ArrayList(u8) = .empty,
    received_bytes: usize = 0,
    final_url: ?[]const u8 = null,
    content_type: ?[]const u8 = null,
    pub fn deinit(self: *Result, a: std.mem.Allocator) void {
        self.body.deinit(a);
        if (self.final_url) |value| a.free(value);
        if (self.content_type) |value| a.free(value);
    }
};
pub const Policy = struct { context: *anyopaque, authorize: *const fn (*anyopaque, []const u8) Code };

pub fn publicIp(address: Io.net.IpAddress) bool {
    return switch (address) {
        .ip4 => |ip| blk: {
            const p = ip.bytes;
            if (p[0] == 0 or p[0] == 10 or p[0] == 127 or p[0] >= 224) break :blk false;
            if (p[0] == 100 and p[1] & 192 == 64) break :blk false;
            if (p[0] == 169 and p[1] == 254) break :blk false;
            if (p[0] == 172 and p[1] & 240 == 16) break :blk false;
            if (p[0] == 192 and ((p[1] == 0 and (p[2] == 0 or p[2] == 2)) or (p[1] == 88 and p[2] == 99) or p[1] == 168)) break :blk false;
            if (p[0] == 198 and ((p[1] & 254) == 18 or (p[1] == 51 and p[2] == 100))) break :blk false;
            if (p[0] == 203 and p[1] == 0 and p[2] == 113) break :blk false;
            break :blk true;
        },
        .ip6 => |ip| blk: {
            const p = ip.bytes;
            if (p[0] & 224 != 32) break :blk false;
            if (p[0] == 0x20 and p[1] == 0x01 and p[2] < 2) break :blk false;
            if (p[0] == 0x20 and p[1] == 0x01 and p[2] == 0x0d and p[3] == 0xb8) break :blk false;
            if (p[0] == 0x20 and p[1] == 0x02) break :blk false;
            if (p[0] == 0x3f and p[1] == 0xff and p[2] & 0xf0 == 0) break :blk false;
            break :blk true;
        },
    };
}
fn hostBytes(uri: std.Uri) ![]const u8 {
    const component = uri.host orelse return error.InvalidUrl;
    const value = switch (component) {
        .raw, .percent_encoded => |text| text,
    };
    if (value.len == 0 or std.mem.indexOfScalar(u8, value, '%') != null) return error.InvalidUrl;
    return if (value[0] == '[' and value[value.len - 1] == ']') value[1 .. value.len - 1] else value;
}
pub fn normalizeUrl(a: std.mem.Allocator, url: []const u8) ![]const u8 {
    if (url.len == 0 or url.len > 8192 or !std.unicode.utf8ValidateSlice(url)) return error.InvalidUrl;
    for (url) |byte| if (byte <= 32 or byte == 127 or byte == '\\') return error.InvalidUrl;
    var uri = std.Uri.parse(url) catch return error.InvalidUrl;
    if (!std.ascii.eqlIgnoreCase(uri.scheme, "https") and !std.ascii.eqlIgnoreCase(uri.scheme, "http")) return error.InvalidUrl;
    if (uri.user != null or uri.password != null) return error.UrlNotAllowed;
    if (uri.port != null and uri.port.? == 0) return error.InvalidUrl;
    const name = try hostBytes(uri);
    if (std.mem.indexOfScalar(u8, name, ':') != null) {
        if (!publicIp(Io.net.IpAddress.parseIp6(name, 0) catch return error.InvalidUrl)) return error.UrlNotAllowed;
    } else if (Io.net.IpAddress.parseIp4(name, 0)) |ip| {
        var parts = std.mem.splitScalar(u8, name, '.');
        while (parts.next()) |part| if (part.len > 1 and part[0] == '0') return error.UrlNotAllowed;
        if (!publicIp(ip)) return error.UrlNotAllowed;
    } else |_| {
        // Alternate numeric spelling must never be reinterpreted by a resolver.
        if (std.ascii.startsWithIgnoreCase(name, "0x")) return error.UrlNotAllowed;
        const numeric = for (name) |byte| {
            if (!std.ascii.isDigit(byte) and byte != '.') break false;
        } else true;
        if (numeric) return error.UrlNotAllowed;
        Io.net.HostName.validate(name) catch return error.InvalidUrl;
        const trimmed = std.mem.trimEnd(u8, name, ".");
        if (std.ascii.eqlIgnoreCase(trimmed, "localhost") or std.ascii.endsWithIgnoreCase(trimmed, ".localhost") or std.ascii.endsWithIgnoreCase(trimmed, ".local") or std.ascii.endsWithIgnoreCase(trimmed, ".internal")) return error.UrlNotAllowed;
    }
    uri.scheme = if (std.ascii.eqlIgnoreCase(uri.scheme, "https")) "https" else "http";
    uri.fragment = null;
    const normalized = try std.fmt.allocPrint(a, "{f}", .{uri.fmt(.{ .scheme = true, .authority = true, .path = true, .query = true })});
    if (normalized.len > 8192) {
        a.free(normalized);
        return error.InvalidUrl;
    }
    return normalized;
}
pub fn resolveRedirect(a: std.mem.Allocator, base: []const u8, location: []const u8) ![]const u8 {
    if (location.len == 0 or location.len > 8192) return error.InvalidUrl;
    for (location) |byte| if (byte <= 32 or byte == 127 or byte == '\\') return error.InvalidUrl;
    var buffer: [32768]u8 = undefined;
    @memcpy(buffer[0..location.len], location);
    var rest: []u8 = &buffer;
    const resolved = std.Uri.resolveInPlace(try std.Uri.parse(base), location.len, &rest) catch return error.InvalidUrl;
    const text = try std.fmt.allocPrint(a, "{f}", .{resolved.fmt(.all)});
    defer a.free(text);
    const normalized = try normalizeUrl(a, text);
    errdefer a.free(normalized);
    if (std.mem.startsWith(u8, base, "https:") and std.mem.startsWith(u8, normalized, "http:")) return error.UrlNotAllowed;
    return normalized;
}
fn fromRaw(raw: ?*anyopaque) *NetworkIo {
    return @ptrCast(@alignCast(raw.?));
}
/// Forward the public Io ABI unchanged except the three network gates below.
/// This avoids assuming that an arbitrary supplied Io.userdata is Threaded.
fn Forward(comptime name: []const u8) type {
    const info = @typeInfo(@typeInfo(@FieldType(Io.VTable, name)).pointer.child).@"fn";
    const R = info.return_type.?;
    return struct {
        fn P(comptime index: usize) type {
            return if (index < info.param_types.len) info.param_types[index].? else void;
        }
        fn one(raw: ?*anyopaque) R {
            const base = fromRaw(raw).base;
            return @field(base.vtable, name)(base.userdata);
        }
        fn two(raw: ?*anyopaque, b: P(1)) R {
            const base = fromRaw(raw).base;
            return @field(base.vtable, name)(base.userdata, b);
        }
        fn three(raw: ?*anyopaque, b: P(1), c: P(2)) R {
            const base = fromRaw(raw).base;
            return @field(base.vtable, name)(base.userdata, b, c);
        }
        fn four(raw: ?*anyopaque, b: P(1), c: P(2), d: P(3)) R {
            const base = fromRaw(raw).base;
            return @field(base.vtable, name)(base.userdata, b, c, d);
        }
        fn five(raw: ?*anyopaque, b: P(1), c: P(2), d: P(3), e: P(4)) R {
            const base = fromRaw(raw).base;
            return @field(base.vtable, name)(base.userdata, b, c, d, e);
        }
        fn six(raw: ?*anyopaque, b: P(1), c: P(2), d: P(3), e: P(4), f: P(5)) R {
            const base = fromRaw(raw).base;
            return @field(base.vtable, name)(base.userdata, b, c, d, e, f);
        }
        const function = switch (info.param_types.len) {
            1 => one,
            2 => two,
            3 => three,
            4 => four,
            5 => five,
            6 => six,
            else => @compileError("New std.Io ABI needs an explicit forwarder"),
        };
    };
}
pub const NetworkIo = struct {
    base: Io,
    blocked: std.atomic.Value(bool) = .init(false),
    sent: std.atomic.Value(bool) = .init(false),
    track_request: std.atomic.Value(bool) = .init(false),
    stage: std.atomic.Value(c_int) = .init(2),
    const table: Io.VTable = block: {
        @setEvalBranchQuota(10000);
        var value: Io.VTable = undefined;
        for (@typeInfo(Io.VTable).@"struct".field_names) |name| @field(value, name) = if (std.mem.eql(u8, name, "netLookup")) lookup else if (std.mem.eql(u8, name, "netConnectIp")) connect else if (std.mem.eql(u8, name, "operate")) operate else Forward(name).function;
        break :block value;
    };
    pub fn io(self: *NetworkIo) Io {
        return .{ .userdata = self, .vtable = &table };
    }
    fn cancelled(raw: ?*anyopaque) callconv(.c) c_int {
        fromRaw(raw).base.checkCancel() catch return 1;
        return 0;
    }
    fn lookup(raw: ?*anyopaque, name: Io.net.HostName, queue: *Io.Queue(Io.net.HostName.LookupResult), options: Io.net.HostName.LookupOptions) Io.net.HostName.LookupError!void {
        const self = fromRaw(raw);
        const wrapped = self.io();
        defer queue.close(wrapped);
        self.stage.store(2, .release);
        var addresses: [32]Io.net.IpAddress = undefined;
        var count: usize = 0;
        if (Io.net.IpAddress.parseIp4(name.bytes, options.port)) |address| {
            addresses[0] = address;
            count = 1;
        } else |_| if (Io.net.IpAddress.parseIp6(name.bytes, options.port)) |address| {
            addresses[0] = address;
            count = 1;
        } else |_| {
            var text: [Io.net.HostName.max_len + 1]u8 = @splat(0);
            @memcpy(text[0..name.bytes.len], name.bytes);
            const found = try darwin.resolve(text[0..name.bytes.len :0], cancelled, self);
            for (found.values[0..found.count]) |item| {
                var address = item;
                address.setPort(options.port);
                if (options.family) |family| if (std.meta.activeTag(address) != family) continue;
                addresses[count] = address;
                count += 1;
            }
        }
        for (addresses[0..count]) |address| if (!publicIp(address)) {
            self.blocked.store(true, .release);
            return error.AccessDenied;
        };
        for (addresses[0..count]) |address| queue.putOne(wrapped, .{ .address = address }) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            error.Closed => unreachable,
        };
    }
    fn connect(raw: ?*anyopaque, address: *const Io.net.IpAddress, options: Io.net.IpAddress.ConnectOptions) Io.net.IpAddress.ConnectError!Io.net.Socket {
        const self = fromRaw(raw);
        if (!publicIp(address.*)) {
            self.blocked.store(true, .release);
            return error.AccessDenied;
        }
        self.stage.store(3, .release);
        const socket = try self.base.vtable.netConnectIp(self.base.userdata, address, options);
        errdefer self.base.vtable.netClose(self.base.userdata, &.{socket});
        if (!darwin.peerMatches(socket.handle, address.*)) {
            self.blocked.store(true, .release);
            return error.AccessDenied;
        }
        return socket;
    }
    fn operate(raw: ?*anyopaque, operation: Io.Operation) Io.Cancelable!Io.Operation.Result {
        const self = fromRaw(raw);
        const value = try self.base.vtable.operate(self.base.userdata, operation);
        if (value == .net_write and self.track_request.load(.acquire)) {
            if (value.net_write) |written| {
                if (written != 0) self.sent.store(true, .release);
            } else |_| {}
        }
        return value;
    }
};

pub fn textType(value: []const u8) bool {
    const mime = std.mem.trim(u8, value[0 .. std.mem.indexOfScalar(u8, value, ';') orelse value.len], " \t");
    return std.ascii.startsWithIgnoreCase(mime, "text/") or std.ascii.eqlIgnoreCase(mime, "application/json") or std.ascii.eqlIgnoreCase(mime, "application/xhtml+xml") or std.ascii.eqlIgnoreCase(mime, "application/xml") or (std.ascii.startsWithIgnoreCase(mime, "application/") and std.ascii.endsWithIgnoreCase(mime, "+json"));
}
pub fn readBody(a: std.mem.Allocator, raw: *Io.Reader, encoding: std.http.ContentEncoding, output: *std.ArrayList(u8), received: *usize) !void {
    const available = receive_limit -| received.*;
    var compressed_buffer: [8192]u8 = undefined;
    var limited = raw.limited(.limited(available + 1), &compressed_buffer);
    const window: usize = switch (encoding) {
        .identity => 0,
        .gzip, .deflate => std.compress.flate.max_window_len,
        else => return error.UnsupportedContentType,
    };
    const buffer = try a.alloc(u8, window);
    defer a.free(buffer);
    var decompress: std.http.Decompress = undefined;
    const reader = decompress.init(&limited.interface, buffer, encoding);
    defer received.* += available + 1 - limited.remaining.toInt().?;
    var chunk: [8192]u8 = undefined;
    while (true) {
        var writer: Io.Writer = .fixed(&chunk);
        _ = reader.stream(&writer, .limited(chunk.len)) catch |err| switch (err) {
            error.EndOfStream => break,
            else => {
                if (limited.remaining == .nothing) return error.ResponseTooLarge;
                return err;
            },
        };
        if (limited.remaining == .nothing or writer.end > decode_limit -| output.items.len) return error.ResponseTooLarge;
        try output.appendSlice(a, writer.buffered());
    }
    // A decoder may finish before consuming all transfer bytes. Reject trailing
    // members/data, and still detect a compressed body exceeding the wire cap.
    if (encoding != .identity) {
        var extra: [1]u8 = undefined;
        var writer: Io.Writer = .fixed(&extra);
        _ = limited.interface.stream(&writer, .limited(1)) catch |err| switch (err) {
            error.EndOfStream => return,
            else => return err,
        };
        if (writer.end != 0) return if (limited.remaining == .nothing) error.ResponseTooLarge else error.UnsupportedContentType;
    }
}
const Job = struct {
    a: std.mem.Allocator,
    network: NetworkIo,
    policy: Policy,
    result: *Result,
    done: std.atomic.Value(bool) = .init(false),
    fn run(self: *Job) void {
        defer self.done.store(true, .release);
        self.fetch() catch |err| {
            self.result.code = if (self.network.blocked.load(.acquire)) .not_allowed else switch (err) {
                error.OutOfMemory => .memory,
                error.Canceled => .cancelled,
                error.UrlNotAllowed => .not_allowed,
                error.InvalidUrl => .invalid,
                error.UnknownHostName, error.NoAddressReturned, error.NameServerFailure => .dns,
                error.TlsInitializationFailed, error.CertificateBundleLoadFailure => .tls,
                error.ConnectionRefused, error.HostUnreachable, error.NetworkUnreachable => .connect,
                error.ResponseTooLarge, error.HttpHeadersOversize => .too_large,
                error.UnsupportedContentType, error.HttpContentEncodingUnsupported => .unsupported,
                else => .network,
            };
            if (self.result.stage <= 3) self.result.stage = self.network.stage.load(.acquire);
        };
        self.result.request_sent = self.network.sent.load(.acquire);
        self.result.cancelled = self.result.code == .cancelled;
        self.result.local_released = true;
    }
    fn fetch(self: *Job) !void {
        const io = self.network.io();
        var client: std.http.Client = .{ .allocator = self.a, .io = io, .read_buffer_size = 32 * 1024 };
        defer client.deinit();
        for (0..4) |redirects| {
            try io.checkCancel();
            const current = self.result.final_url.?;
            self.result.stage = 1;
            self.result.code = self.policy.authorize(self.policy.context, current);
            if (self.result.code != .ok) return;
            const zero = try self.a.dupeSentinel(u8, current, 0);
            defer self.a.free(zero);
            if (darwin.proxyRequired(zero)) {
                self.result.code = .capability;
                return;
            }
            const uri = try std.Uri.parse(current);
            var redirected_from: ?[]const u8 = null;
            defer if (redirected_from) |old| self.a.free(old);
            self.result.stage = 2;
            // Explicit connection preserves IPv6 literals while keeping the
            // original URI Host and TLS SNI/certificate name. Both DNS results
            // and the exact addresses handed to connect pass the Io gates.
            const protocol: std.http.Client.Protocol = if (std.mem.eql(u8, uri.scheme, "https")) .tls else .plain;
            if (protocol == .tls and client.now == null) {
                client.now = Io.Clock.real.now(io);
                try client.ca_bundle.rescan(self.a, io, client.now.?);
            }
            const name: Io.net.HostName = .{ .bytes = try hostBytes(uri) };
            const connection = try client.connectTcp(name, uri.port orelse @as(u16, if (protocol == .tls) 443 else 80), protocol);
            var owned_connection = true;
            errdefer if (owned_connection) {
                connection.closing = true;
                client.connection_pool.release(connection, io);
            };
            self.result.stage = 4;
            self.result.code = self.policy.authorize(self.policy.context, current);
            if (self.result.code != .ok) {
                connection.closing = true;
                client.connection_pool.release(connection, io);
                return;
            }
            var request = try client.request(.GET, uri, .{ .connection = connection, .keep_alive = false, .redirect_behavior = .unhandled, .headers = .{ .authorization = .omit, .user_agent = .{ .override = "ZeroWork/0.2.6 (public text fetch)" } } });
            owned_connection = false;
            // Also close without draining when response parsing fails before
            // receiveHead has populated its keep-alive state.
            connection.closing = true;
            defer request.deinit();
            self.network.track_request.store(true, .release);
            defer self.network.track_request.store(false, .release);
            try request.sendBodiless();
            var response = try request.receiveHead(&.{});
            self.result.http_status = @backingInt(response.head.status);
            const content_type = response.head.content_type orelse "";
            if (content_type.len > 256) return error.ResponseTooLarge;
            const owned_type = try self.a.dupe(u8, content_type);
            if (self.result.content_type) |old| self.a.free(old);
            self.result.content_type = owned_type;
            const status = self.result.http_status;
            if (status == 301 or status == 302 or status == 303 or status == 307 or status == 308) {
                const location = response.head.location orelse {
                    self.result.code = .http;
                    return;
                };
                if (redirects == 3) {
                    self.result.code = .redirect;
                    return;
                }
                const next = try resolveRedirect(self.a, current, location);
                redirected_from = current;
                self.result.final_url = next;
                self.result.http_status = 0;
                self.a.free(self.result.content_type.?);
                self.result.content_type = null;
                continue;
            }
            if (status == 204) {
                self.result.code = .ok;
                return;
            }
            if (!textType(self.result.content_type.?) and status != 204) {
                self.result.code = if (status >= 400) .http else .unsupported;
                return;
            }
            self.result.stage = 5;
            if (response.head.content_length) |length| if (length > receive_limit -| self.result.received_bytes) return error.ResponseTooLarge;
            try readBody(self.a, response.reader(&.{}), response.head.content_encoding, &self.result.body, &self.result.received_bytes);
            self.result.code = if (status >= 200 and status < 300) .ok else .http;
            return;
        }
    }
};
pub fn fetch(a: std.mem.Allocator, supplied_io: ?Io, policy: Policy, url: []const u8, cancel: ?*provider.CancelToken) Result {
    const start = @import("../platform/realtime.zig").monotonicNs();
    var result = fetchInner(a, supplied_io, policy, url, cancel, start);
    result.elapsed_ms = @intCast(@max(0, @divTrunc(@import("../platform/realtime.zig").monotonicNs() - start, std.time.ns_per_ms)));
    result.observed_at = @import("../platform/realtime.zig").milliseconds(undefined);
    return result;
}
fn fetchInner(a: std.mem.Allocator, supplied_io: ?Io, policy: Policy, url: []const u8, cancel: ?*provider.CancelToken, start: i128) Result {
    var result: Result = .{};
    if (cancel) |token| if (token.isCancelled()) {
        result.code = .cancelled;
        result.cancelled = true;
        return result;
    };
    result.final_url = normalizeUrl(a, url) catch |err| {
        result.code = switch (err) {
            error.OutOfMemory => .memory,
            error.UrlNotAllowed => .not_allowed,
            else => .invalid,
        };
        return result;
    };
    result.stage = 1;
    result.code = policy.authorize(policy.context, result.final_url.?);
    if (result.code != .ok) return result;
    const io = supplied_io orelse {
        result.code = .capability;
        return result;
    };
    var job: Job = .{ .a = a, .network = .{ .base = io }, .policy = policy, .result = &result };
    var future = Io.concurrent(io, Job.run, .{&job}) catch {
        result.code = .capability;
        return result;
    };
    while (!job.done.load(.acquire)) {
        const stopped = if (cancel) |token| token.isCancelled() else false;
        const elapsed = @divTrunc(@import("../platform/realtime.zig").monotonicNs() - start, std.time.ns_per_ms);
        if (stopped or elapsed >= total_ms) {
            future.cancel(io);
            result.code = if (stopped) .cancelled else .timeout;
            result.cancelled = stopped;
            return result;
        }
        @import("retry.zig").wait(10, null) catch unreachable;
    }
    future.await(io);
    return result;
}
test {
    _ = @import("fetch_url_transport_tests.zig");
}
