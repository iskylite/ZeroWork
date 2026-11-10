//! OAuth 2.1 for HTTP MCP: protected-resource/AS discovery, public clients,
//! PKCE S256, loopback callback, state, resource binding and refresh. Tokens
//! belong to this application process; they never enter settings or transcripts.
const std = @import("std");
const config = @import("../config/ai_extensions.zig");
const provider = @import("provider.zig");
const Clock = @import("retry.zig").Clock;
const str = @import("mcp_interaction.zig").string;
const Cancel = *const fn (?*anyopaque) callconv(.c) c_int;
const Sink = *const fn (?*anyopaque, [*]const u8, usize) callconv(.c) c_int;
extern fn zw_mcp_http([*:0]const u8, [*:0]const u8, [*]const [*:0]const u8, usize, [*]const u8, usize, c_uint, Sink, ?*anyopaque, Cancel, ?*anyopaque, [*]u8, [*]u8, [*]u8, *c_uint, ?Sink, ?*anyopaque, ?[*]u8, ?[*]const u8, usize) c_int;
extern fn zw_mcp_callback_start(*c_uint) c_int;
extern fn zw_mcp_callback_wait(c_int, [*]u8, usize, c_uint, Cancel, ?*anyopaque) c_int;
extern fn zw_mcp_callback_close(c_int) void;
const a = std.heap.page_allocator;
const Entry = struct { key: [32]u8, bytes: []u8 };
var cache: std.ArrayList(?Entry) = .empty;
var mutex: std.atomic.Mutex = .unlocked;
var refresh_mutex: std.atomic.Mutex = .unlocked;
fn lock(cancel: ?*provider.CancelToken) !void {
    if (cancel) |token| if (token.isCancelled()) return error.Cancelled;
    while (!mutex.tryLock()) {
        if (cancel) |token| if (token.isCancelled()) return error.Cancelled;
        std.atomic.spinLoopHint();
    }
}
fn key(server: config.Server) [32]u8 {
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    inline for (.{ server.endpoint, server.oauth_client_id, server.oauth_scope }) |part| {
        h.update(part);
        h.update(&.{0});
    }
    var digest: [32]u8 = undefined;
    h.final(&digest);
    return digest;
}
fn clear(entry: *?Entry) void {
    if (entry.*) |old| {
        std.crypto.secureZero(u8, old.bytes);
        a.free(old.bytes);
    }
    entry.* = null;
}
pub fn logout(server: config.Server) void {
    lock(null) catch unreachable;
    defer mutex.unlock();
    const wanted = key(server);
    for (cache.items) |*entry| if (entry.*) |old| {
        if (std.mem.eql(u8, &old.key, &wanted)) clear(entry);
    };
}
pub fn authorized(server: config.Server) bool {
    lock(null) catch unreachable;
    defer mutex.unlock();
    const wanted = key(server);
    for (cache.items) |entry| if (entry) |old| {
        if (std.mem.eql(u8, &old.key, &wanted)) return true;
    };
    return false;
}
fn cancelled(raw: ?*anyopaque) callconv(.c) c_int {
    const token: *provider.CancelToken = @ptrCast(@alignCast(raw orelse return 0));
    return @intFromBool(token.isCancelled());
}
fn code(result: c_int) !void {
    if (result == -3) return error.Cancelled;
    if (result == -2) return error.McpAuthorizationTimeout;
    if (result < 0) return error.McpTransportFailure;
}
pub fn validateUrl(url: []const u8) !void {
    try config.text(url, 8192, false);
    const uri = std.Uri.parse(url) catch return error.InvalidMcpOAuthMetadata;
    if (uri.user != null or uri.password != null or uri.fragment != null or uri.host == null) return error.InvalidMcpOAuthMetadata;
    if (!std.mem.eql(u8, uri.scheme, "https") and !(std.mem.eql(u8, uri.scheme, "http") and (std.mem.eql(u8, uri.host.?.percent_encoded, "localhost") or std.mem.eql(u8, uri.host.?.percent_encoded, "127.0.0.1") or std.mem.eql(u8, uri.host.?.percent_encoded, "[::1]")))) return error.InvalidMcpOAuthMetadata;
}
const Response = struct { status: u32, value: std.json.Value, challenge: []const u8 };
fn web(owned: std.mem.Allocator, url: []const u8, method: [:0]const u8, body: []const u8, mime: [:0]const u8, cancel: ?*provider.CancelToken) !Response {
    try validateUrl(url);
    const Capture = struct {
        owned: std.mem.Allocator,
        bytes: std.ArrayList(u8) = .empty,
        problem: ?anyerror = null,
        fn sink(raw: ?*anyopaque, bytes: [*]const u8, len: usize) callconv(.c) c_int {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            if (self.bytes.items.len + len > 2 * 1024 * 1024) {
                self.problem = error.McpOAuthResponseLimit;
                return -1;
            }
            self.bytes.appendSlice(self.owned, bytes[0..len]) catch {
                self.problem = error.OutOfMemory;
                return -1;
            };
            return 0;
        }
    };
    var capture: Capture = .{ .owned = owned };
    const headers = [_][*:0]const u8{ mime, "Accept: application/json" };
    var session: [512]u8 = @splat(0);
    var kind: [128]u8 = @splat(0);
    var challenge: [8192]u8 = @splat(0);
    var status: c_uint = 0;
    const rc = zw_mcp_http(try owned.dupeSentinel(u8, url, 0), method, &headers, headers.len, body.ptr, body.len, 30000, Capture.sink, &capture, cancelled, cancel, &session, &kind, &challenge, &status, null, null, null, null, 0);
    if (capture.problem) |problem| return problem;
    try code(rc);
    const parsed = std.json.parseFromSlice(std.json.Value, owned, capture.bytes.items, .{ .allocate = .alloc_always }) catch null;
    return .{ .status = status, .value = if (parsed) |value| value.value else .null, .challenge = try owned.dupe(u8, std.mem.sliceTo(&challenge, 0)) };
}
fn encode(owned: std.mem.Allocator, value: []const u8) ![]const u8 {
    var bytes: std.ArrayList(u8) = .empty;
    const hex = "0123456789ABCDEF";
    for (value) |c| {
        if (std.ascii.isAlphanumeric(c) or std.mem.indexOfScalar(u8, "-._~", c) != null) try bytes.append(owned, c) else try bytes.appendSlice(owned, &.{ '%', hex[c >> 4], hex[c & 15] });
    }
    return bytes.items;
}
pub fn parameter(value: []const u8, name: []const u8) ?[]const u8 {
    var rest = value;
    while (std.mem.indexOf(u8, rest, name)) |offset| {
        const next = rest[offset + name.len ..];
        if ((offset == 0 or rest[offset - 1] == ' ' or rest[offset - 1] == ',' or rest[offset - 1] == '\t') and next.len > 1 and next[0] == '=') {
            if (next[1] == '"') return next[2 .. std.mem.indexOfScalarPos(u8, next, 2, '"') orelse return null];
            return next[1 .. std.mem.indexOfAnyPos(u8, next, 1, ", ") orelse next.len];
        }
        rest = next;
    }
    return null;
}
fn origin(owned: std.mem.Allocator, url: []const u8) ![]const u8 {
    const scheme = std.mem.indexOf(u8, url, "://") orelse return error.InvalidMcpOAuthMetadata;
    const end = std.mem.indexOfScalarPos(u8, url, scheme + 3, '/') orelse url.len;
    return owned.dupe(u8, url[0..end]);
}
fn metadata(owned: std.mem.Allocator, server: config.Server, cancel: ?*provider.CancelToken) !struct { resource: []const u8, issuer: []const u8, metadata: std.json.Value, scope: []const u8 } {
    const endpoint = server.endpoint[0 .. std.mem.indexOfScalar(u8, server.endpoint, '?') orelse server.endpoint.len];
    const probe = try web(owned, endpoint, "GET", "", "Content-Type: application/json", cancel);
    const base = try origin(owned, endpoint);
    var resource_response: Response = undefined;
    if (parameter(probe.challenge, "resource_metadata")) |url| {
        resource_response = try web(owned, url, "GET", "", "Content-Type: application/json", cancel);
    } else {
        resource_response = try web(owned, try std.fmt.allocPrint(owned, "{s}/.well-known/oauth-protected-resource{s}", .{ base, endpoint[base.len..] }), "GET", "", "Content-Type: application/json", cancel);
        if (resource_response.status == 404) resource_response = try web(owned, try std.fmt.allocPrint(owned, "{s}/.well-known/oauth-protected-resource", .{base}), "GET", "", "Content-Type: application/json", cancel);
    }
    if (resource_response.status != 200) return error.McpOAuthDiscoveryFailed;
    const resource = str(resource_response.value, "resource") orelse return error.InvalidMcpOAuthMetadata;
    if (!std.mem.eql(u8, resource, endpoint)) return error.McpOAuthResourceMismatch;
    const issuers = if (resource_response.value == .object) resource_response.value.object.get("authorization_servers") orelse return error.InvalidMcpOAuthMetadata else return error.InvalidMcpOAuthMetadata;
    if (issuers != .array or issuers.array.items.len == 0 or issuers.array.items[0] != .string) return error.InvalidMcpOAuthMetadata;
    const issuer = std.mem.trimEnd(u8, issuers.array.items[0].string, "/");
    try validateUrl(issuer);
    const issuer_base = try origin(owned, issuer);
    const path = issuer[issuer_base.len..];
    const paths = [_][]const u8{
        try std.fmt.allocPrint(owned, "{s}/.well-known/oauth-authorization-server{s}", .{ issuer_base, path }),
        try std.fmt.allocPrint(owned, "{s}/.well-known/openid-configuration{s}", .{ issuer_base, path }),
        try std.fmt.allocPrint(owned, "{s}/.well-known/openid-configuration", .{issuer}),
    };
    for (paths) |url| {
        const reply = try web(owned, url, "GET", "", "Content-Type: application/json", cancel);
        if (reply.status != 200) continue;
        const actual = str(reply.value, "issuer") orelse return error.InvalidMcpOAuthMetadata;
        if (!std.mem.eql(u8, std.mem.trimEnd(u8, actual, "/"), issuer)) return error.McpOAuthIssuerMismatch;
        const methods = reply.value.object.get("code_challenge_methods_supported") orelse return error.McpOAuthPkceRequired;
        const s256 = supported: {
            if (methods == .array) for (methods.array.items) |item| {
                if (item == .string and std.mem.eql(u8, item.string, "S256")) break :supported true;
            };
            break :supported false;
        };
        if (!s256) return error.McpOAuthPkceRequired;
        var scope: []const u8 = server.oauth_scope;
        if (scope.len == 0) scope = parameter(probe.challenge, "scope") orelse "";
        if (scope.len == 0) if (resource_response.value.object.get("scopes_supported")) |scopes| {
            if (scopes == .array) {
                var names: std.ArrayList([]const u8) = .empty;
                for (scopes.array.items) |item| if (item == .string) {
                    try names.append(owned, item.string);
                };
                scope = try std.mem.join(owned, " ", names.items);
            }
        };
        return .{ .resource = resource, .issuer = actual, .metadata = reply.value, .scope = scope };
    }
    return error.McpOAuthDiscoveryFailed;
}
const Tokens = struct { issuer: []const u8 = "", access_token: []const u8, refresh_token: ?[]const u8 = null, client_id: []const u8, token_endpoint: []const u8, resource: []const u8, expires_at_ms: i128 = 0 };
fn tokens(owned: std.mem.Allocator, response: Response, client_id: []const u8, endpoint: []const u8, resource: []const u8, previous_refresh: ?[]const u8) !Tokens {
    if (response.status != 200 or response.value != .object) return error.McpOAuthTokenFailed;
    const token = str(response.value, "access_token") orelse return error.McpOAuthTokenFailed;
    const kind = str(response.value, "token_type") orelse return error.McpOAuthTokenFailed;
    if (!std.ascii.eqlIgnoreCase(kind, "bearer") or token.len == 0 or std.mem.indexOfAny(u8, token, "\r\n\x00") != null) return error.McpOAuthTokenFailed;
    const expires = if (response.value.object.get("expires_in")) |v| if (v == .integer and v.integer > 0) v.integer else return error.McpOAuthTokenFailed else 0;
    return .{ .access_token = try owned.dupe(u8, token), .refresh_token = str(response.value, "refresh_token") orelse previous_refresh, .client_id = client_id, .token_endpoint = endpoint, .resource = resource, .expires_at_ms = if (expires == 0) 0 else @divTrunc((Clock{}).now(), std.time.ns_per_ms) + @as(i128, expires) * 1000 };
}
fn store(server: config.Server, value: Tokens) !void {
    const wanted = key(server);
    const bytes = try std.json.Stringify.valueAlloc(a, value, .{});
    errdefer a.free(bytes);
    for (cache.items) |*entry| if (entry.*) |old| {
        if (std.mem.eql(u8, &old.key, &wanted)) {
            clear(entry);
            entry.* = .{ .key = wanted, .bytes = bytes };
            return;
        }
    };
    for (cache.items) |*entry| if (entry.* == null) {
        entry.* = .{ .key = wanted, .bytes = bytes };
        return;
    };
    try cache.append(a, .{ .key = wanted, .bytes = bytes });
}
pub fn accessToken(owned: std.mem.Allocator, server: config.Server, cancel: ?*provider.CancelToken) !?[]const u8 {
    for (server.headers) |header| if (std.ascii.eqlIgnoreCase(header.name, "Authorization")) return null;
    while (!refresh_mutex.tryLock()) {
        if (cancel) |token| if (token.isCancelled()) return error.Cancelled;
        (Clock{}).sleep(std.time.ns_per_ms);
    }
    defer refresh_mutex.unlock();
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const scratch = arena.allocator();
    const wanted = key(server);
    try lock(cancel);
    const snapshot = snapshot: {
        defer mutex.unlock();
        for (cache.items) |entry| if (entry) |old| {
            if (std.mem.eql(u8, &old.key, &wanted)) break :snapshot try scratch.dupe(u8, old.bytes);
        };
        return null;
    };
    defer std.crypto.secureZero(u8, snapshot);
    const parsed = try std.json.parseFromSlice(Tokens, scratch, snapshot, .{ .allocate = .alloc_always });
    const current = parsed.value;
    if (current.expires_at_ms == 0 or current.expires_at_ms > @divTrunc((Clock{}).now(), std.time.ns_per_ms) + 30000) return try owned.dupe(u8, current.access_token);
    const refresh = current.refresh_token orelse return error.McpAuthorizationRequired;
    const body = try std.fmt.allocPrint(scratch, "grant_type=refresh_token&refresh_token={s}&client_id={s}&resource={s}", .{ try encode(scratch, refresh), try encode(scratch, current.client_id), try encode(scratch, current.resource) });
    const response = try web(scratch, current.token_endpoint, "POST", body, "Content-Type: application/x-www-form-urlencoded", cancel);
    var next = try tokens(scratch, response, current.client_id, current.token_endpoint, current.resource, refresh);
    next.issuer = current.issuer;
    try lock(cancel);
    defer mutex.unlock();
    // Logout or a new authorization while HTTP was in flight wins over refresh.
    const unchanged = for (cache.items) |entry| {
        if (entry) |old| if (std.mem.eql(u8, &old.key, &wanted) and std.mem.eql(u8, old.bytes, snapshot)) break true;
    } else false;
    if (!unchanged) return error.McpAuthorizationRequired;
    try store(server, next);
    return try owned.dupe(u8, next.access_token);
}
pub const Browser = struct { context: *anyopaque, open: *const fn (*anyopaque, []const u8) anyerror!void };
pub fn login(owned: std.mem.Allocator, io: std.Io, server: config.Server, browser: Browser, cancel: ?*provider.CancelToken) !void {
    if (server.transport != .http) return error.InvalidMcpConfig;
    const discovered = try metadata(owned, server, cancel);
    const authorization_endpoint = str(discovered.metadata, "authorization_endpoint") orelse return error.InvalidMcpOAuthMetadata;
    const token_endpoint = str(discovered.metadata, "token_endpoint") orelse return error.InvalidMcpOAuthMetadata;
    try validateUrl(authorization_endpoint);
    try validateUrl(token_endpoint);
    var port: c_uint = 0;
    const socket = zw_mcp_callback_start(&port);
    if (socket < 0) return error.McpOAuthCallbackFailed;
    defer zw_mcp_callback_close(socket);
    const redirect = try std.fmt.allocPrint(owned, "http://127.0.0.1:{d}/callback", .{port});
    var client_id = server.oauth_client_id;
    if (client_id.len == 0) {
        const registration = str(discovered.metadata, "registration_endpoint") orelse return error.McpOAuthClientIdRequired;
        const body = try std.json.Stringify.valueAlloc(owned, .{ .client_name = "ZeroWork", .application_type = "native", .redirect_uris = [_][]const u8{redirect}, .grant_types = [_][]const u8{ "authorization_code", "refresh_token" }, .response_types = [_][]const u8{"code"}, .token_endpoint_auth_method = "none" }, .{});
        const registered = try web(owned, registration, "POST", body, "Content-Type: application/json", cancel);
        if (registered.status != 200 and registered.status != 201) return error.McpOAuthRegistrationFailed;
        client_id = str(registered.value, "client_id") orelse return error.McpOAuthRegistrationFailed;
        if (str(registered.value, "token_endpoint_auth_method")) |method| if (!std.mem.eql(u8, method, "none")) return error.McpOAuthPublicClientRequired;
    }
    var random: [64]u8 = undefined;
    try io.randomSecure(&random);
    const verifier = try owned.dupe(u8, &std.fmt.bytesToHex(random[0..32].*, .lower));
    defer std.crypto.secureZero(u8, @constCast(verifier));
    const state = &std.fmt.bytesToHex(random[32..64].*, .lower);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(verifier, &digest, .{});
    var challenge: [43]u8 = undefined;
    _ = std.base64.url_safe_no_pad.Encoder.encode(&challenge, &digest);
    const url = try std.fmt.allocPrint(owned, "{s}{s}response_type=code&client_id={s}&redirect_uri={s}&code_challenge={s}&code_challenge_method=S256&state={s}&resource={s}&scope={s}", .{ authorization_endpoint, if (std.mem.indexOfScalar(u8, authorization_endpoint, '?') != null) "&" else "?", try encode(owned, client_id), try encode(owned, redirect), &challenge, state, try encode(owned, discovered.resource), try encode(owned, discovered.scope) });
    const waiting = provider.CancelToken.beginUserWait(cancel);
    defer waiting.end();
    try browser.open(browser.context, url);
    var callback: [8192]u8 = @splat(0);
    try code(zw_mcp_callback_wait(socket, &callback, callback.len, 10 * 60 * 1000, cancelled, cancel));
    const query = std.mem.sliceTo(&callback, 0);
    try validateCallbackIssuer(owned, query, discovered.issuer);
    const authorization_code = try authorizationCode(owned, query, state);
    const body = try std.fmt.allocPrint(owned, "grant_type=authorization_code&code={s}&client_id={s}&redirect_uri={s}&code_verifier={s}&resource={s}", .{ try encode(owned, authorization_code), try encode(owned, client_id), try encode(owned, redirect), try encode(owned, verifier), try encode(owned, discovered.resource) });
    const response = try web(owned, token_endpoint, "POST", body, "Content-Type: application/x-www-form-urlencoded", cancel);
    var current = try tokens(owned, response, client_id, token_endpoint, discovered.resource, null);
    current.issuer = discovered.issuer;
    try lock(cancel);
    defer mutex.unlock();
    try store(server, current);
}
fn validateCallbackIssuer(owned: std.mem.Allocator, query: []const u8, issuer: []const u8) !void {
    if (try queryParameter(owned, query, "iss")) |returned| if (!std.mem.eql(u8, returned, issuer)) return error.McpOAuthIssuerMismatch;
}
fn authorizationCode(owned: std.mem.Allocator, query: []const u8, state: []const u8) ![]const u8 {
    const returned_state = try queryParameter(owned, query, "state") orelse return error.McpOAuthStateMismatch;
    if (!std.mem.eql(u8, returned_state, state)) return error.McpOAuthStateMismatch;
    if (try queryParameter(owned, query, "error") != null) return error.McpAuthorizationDenied;
    const value = try queryParameter(owned, query, "code") orelse return error.McpOAuthCallbackFailed;
    if (value.len == 0) return error.McpOAuthCallbackFailed;
    return value;
}
fn queryParameter(owned: std.mem.Allocator, target: []const u8, name: []const u8) !?[]const u8 {
    const start = std.mem.indexOfScalar(u8, target, '?') orelse return null;
    var fields = std.mem.splitScalar(u8, target[start + 1 ..], '&');
    var result: ?[]const u8 = null;
    while (fields.next()) |field| {
        const equal = std.mem.indexOfScalar(u8, field, '=') orelse continue;
        if (!std.mem.eql(u8, field[0..equal], name)) continue;
        if (result != null) return error.InvalidMcpOAuthCallback;
        const raw = field[equal + 1 ..];
        var decoded: std.ArrayList(u8) = .empty;
        var i: usize = 0;
        while (i < raw.len) : (i += 1) {
            if (raw[i] == '%') {
                if (i + 2 >= raw.len) return error.InvalidMcpOAuthCallback;
                const byte = std.fmt.parseInt(u8, raw[i + 1 .. i + 3], 16) catch return error.InvalidMcpOAuthCallback;
                try decoded.append(owned, byte);
                i += 2;
            } else try decoded.append(owned, if (raw[i] == '+') ' ' else raw[i]);
        }
        result = decoded.items;
    }
    return result;
}

test "v0.4 extensions OAuth validates callback state duplicates errors and secure endpoints" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const owned = arena.allocator();
    try std.testing.expectEqualStrings("a+b", try authorizationCode(owned, "/callback?code=a%2Bb&state=expected", "expected"));
    try std.testing.expectError(error.McpOAuthStateMismatch, authorizationCode(owned, "/callback?code=stolen&state=wrong", "expected"));
    try std.testing.expectError(error.McpOAuthStateMismatch, authorizationCode(owned, "/callback?code=stolen", "expected"));
    try std.testing.expectError(error.InvalidMcpOAuthCallback, authorizationCode(owned, "/callback?state=expected&state=expected&code=code", "expected"));
    try std.testing.expectError(error.McpAuthorizationDenied, authorizationCode(owned, "/callback?state=expected&error=access_denied", "expected"));
    try std.testing.expectError(error.McpOAuthCallbackFailed, authorizationCode(owned, "/callback?state=expected&code=", "expected"));
    try std.testing.expectError(error.InvalidMcpOAuthCallback, authorizationCode(owned, "/callback?state=expected&code=%ZZ", "expected"));
    try validateCallbackIssuer(owned, "/callback?iss=https%3A%2F%2Flogin.example.com", "https://login.example.com");
    try validateCallbackIssuer(owned, "/callback?code=ok", "https://login.example.com");
    try std.testing.expectError(error.McpOAuthIssuerMismatch, validateCallbackIssuer(owned, "/callback?iss=https%3A%2F%2Fevil.example.com", "https://login.example.com"));
    try std.testing.expectError(error.InvalidMcpOAuthCallback, validateCallbackIssuer(owned, "/callback?iss=a&iss=a", "a"));
    try validateUrl("https://login.example.com/authorize");
    try validateUrl("http://127.0.0.1:4321/callback");
    try std.testing.expectError(error.InvalidMcpOAuthMetadata, validateUrl("http://login.example.com/authorize"));
    try std.testing.expectError(error.InvalidMcpOAuthMetadata, validateUrl("https://user:password@example.com/token"));
    try std.testing.expectError(error.InvalidMcpOAuthMetadata, validateUrl("file:///tmp/token"));
    try std.testing.expect(parameter("Bearer bad_resource_metadata=wrong", "resource_metadata") == null);
    try std.testing.expectEqualStrings("https://example.com/resource", parameter("Bearer resource_metadata=\"https://example.com/resource\", scope=\"read write\"", "resource_metadata").?);
}
test "v0.4 extensions OAuth cache binds tokens to resource client scope and logout" {
    const server: config.Server = .{ .id = "oauth-unit", .name = "OAuth", .transport = .http, .endpoint = "https://mcp.example.test/mcp", .oauth_client_id = "client-one", .oauth_scope = "read" };
    defer logout(server);
    try lock(null);
    store(server, .{ .access_token = "private-test-token", .client_id = "client-one", .token_endpoint = "https://auth.example.test/token", .resource = server.endpoint }) catch |err| {
        mutex.unlock();
        return err;
    };
    mutex.unlock();
    const token = (try accessToken(std.testing.allocator, server, null)).?;
    defer std.testing.allocator.free(token);
    try std.testing.expectEqualStrings("private-test-token", token);
    var other = server;
    other.endpoint = "https://other.example.test/mcp";
    try std.testing.expect(try accessToken(std.testing.allocator, other, null) == null);
    other = server;
    other.oauth_client_id = "client-two";
    try std.testing.expect(try accessToken(std.testing.allocator, other, null) == null);
    other = server;
    other.oauth_scope = "write";
    try std.testing.expect(try accessToken(std.testing.allocator, other, null) == null);
    logout(server);
    try std.testing.expect(try accessToken(std.testing.allocator, server, null) == null);
}

test "v0.4 extensions OAuth refresh rotates tokens without replaying a business request" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const owned = arena.allocator();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", owned);
    const port_file = try std.fs.path.join(owned, &.{ root, "port" });
    const trace_file = try std.fs.path.join(owned, &.{ root, "trace" });
    var child = try std.process.spawn(std.testing.io, .{ .argv = &.{ "/usr/bin/python3", "-c", @embedFile("test_fixtures/mcp_http.py"), port_file, trace_file, "oauth-refresh" }, .stderr = .ignore });
    defer child.kill(std.testing.io);
    const port = port: {
        for (0..250) |_| {
            const bytes = tmp.dir.readFileAlloc(std.testing.io, "port", owned, .limited(32)) catch {
                (Clock{}).sleep(10 * std.time.ns_per_ms);
                continue;
            };
            break :port std.fmt.parseInt(u16, bytes, 10) catch {
                (Clock{}).sleep(10 * std.time.ns_per_ms);
                continue;
            };
        }
        return error.FixtureTimeout;
    };
    const endpoint = try std.fmt.allocPrint(owned, "http://127.0.0.1:{d}/mcp", .{port});
    const token_endpoint = try std.fmt.allocPrint(owned, "http://127.0.0.1:{d}/token", .{port});
    const server: config.Server = .{ .id = "refresh-test", .name = "Refresh", .transport = .http, .endpoint = endpoint };
    defer logout(server);
    try lock(null);
    store(server, .{ .access_token = "expired-token", .refresh_token = "refresh-one", .client_id = "refresh-client", .token_endpoint = token_endpoint, .resource = endpoint, .expires_at_ms = 1 }) catch |err| {
        mutex.unlock();
        return err;
    };
    mutex.unlock();
    try std.testing.expectEqualStrings("fresh-access-token", (try accessToken(owned, server, null)).?);
    try std.testing.expectEqualStrings("fresh-access-token", (try accessToken(owned, server, null)).?);
    const trace = try tmp.dir.readFileAlloc(std.testing.io, "trace", owned, .limited(4096));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, trace, "\n"));
    try std.testing.expect(std.mem.indexOf(u8, trace, "tools/call") == null);
}

test "v0.4 extensions OAuth token cache supports more than sixteen servers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var servers: [24]config.Server = undefined;
    for (&servers, 0..) |*server, index| server.* = .{ .id = "cache-fixture", .name = "Fixture", .transport = .http, .endpoint = try std.fmt.allocPrint(arena.allocator(), "https://cache-{d}.example.test/mcp", .{index}) };
    defer for (servers) |server| logout(server);
    try lock(null);
    defer mutex.unlock();
    for (servers) |server| try store(server, .{ .access_token = "private-fixture-token", .client_id = "client", .token_endpoint = "https://auth.example.test/token", .resource = server.endpoint });
    for (servers) |server| {
        const wanted = key(server);
        const present = for (cache.items) |entry| {
            if (entry) |value| if (std.mem.eql(u8, &value.key, &wanted)) break true;
        } else false;
        try std.testing.expect(present);
    }
}
