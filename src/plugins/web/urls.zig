//! Offline normalization shared by the web editor, address bar, and bookmarks.
const std = @import("std");

pub const Error = error{ MissingUrl, UnsupportedScheme, InvalidUrl, InvalidHost, InvalidPort, OutOfMemory };

pub const Url = struct {
    text: []const u8,
    host_start: usize,
    host_end: usize,
    origin_end: usize,

    pub fn deinit(self: Url, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
    }

    /// The display host includes brackets for IPv6.
    pub fn host(self: Url) []const u8 {
        return self.text[self.host_start..self.host_end];
    }

    /// Suitable for diagnostics. Path, query and fragment may contain secrets.
    pub fn origin(self: Url) []const u8 {
        return self.text[0..self.origin_end];
    }
};

const Scheme = enum {
    http,
    https,

    fn defaultPort(self: Scheme) u16 {
        return switch (self) {
            .http => 80,
            .https => 443,
        };
    }
};

pub fn normalize(allocator: std.mem.Allocator, input: []const u8) Error!Url {
    const value = std.mem.trim(u8, input, " \t\r\n");
    if (value.len == 0) return error.MissingUrl;
    try validateCharacters(value);

    var scheme: Scheme = .https;
    var rest = value;
    const first_delimiter = std.mem.indexOfAny(u8, value, "/?#") orelse value.len;
    const separator = std.mem.indexOf(u8, value, "://") orelse value.len;
    if (separator < first_delimiter) {
        const name = value[0..separator];
        scheme = if (std.ascii.eqlIgnoreCase(name, "https"))
            .https
        else if (std.ascii.eqlIgnoreCase(name, "http"))
            .http
        else
            return error.UnsupportedScheme;
        rest = value[separator + 3 ..];
    } else if (std.mem.indexOfScalar(u8, value[0..first_delimiter], ':')) |colon| {
        const name = value[0..colon];
        if (std.ascii.eqlIgnoreCase(name, "http") or std.ascii.eqlIgnoreCase(name, "https")) return error.InvalidUrl;
        for ([_][]const u8{ "about", "blob", "data", "file", "ftp", "javascript", "mailto", "ws", "wss" }) |other| {
            if (std.ascii.eqlIgnoreCase(name, other)) return error.UnsupportedScheme;
        }
    }

    const authority_end = std.mem.indexOfAny(u8, rest, "/?#") orelse rest.len;
    const authority = rest[0..authority_end];
    const suffix = rest[authority_end..];
    if (authority.len == 0) return error.InvalidHost;
    if (std.mem.indexOfScalar(u8, authority, '@') != null) return error.InvalidUrl;

    var host_buf: [255]u8 = undefined;
    const endpoint = try parseAuthority(authority, &host_buf);
    const prefix = switch (scheme) {
        .http => "http://",
        .https => "https://",
    };
    var port_buf: [6]u8 = undefined;
    const port_text = if (endpoint.port) |port|
        if (port == scheme.defaultPort()) "" else std.fmt.bufPrint(&port_buf, ":{d}", .{port}) catch unreachable
    else
        "";
    const host_end = prefix.len + endpoint.host.len;
    const origin_end = host_end + port_text.len;
    // The canonical HTTP(S) empty path is "/", including before a query or fragment.
    const path_prefix = if (suffix.len == 0 or suffix[0] != '/') "/" else "";
    const text = try std.mem.concat(allocator, u8, &.{ prefix, endpoint.host, port_text, path_prefix, suffix });
    return .{ .text = text, .host_start = prefix.len, .host_end = host_end, .origin_end = origin_end };
}

fn validateCharacters(value: []const u8) Error!void {
    const view = std.unicode.Utf8View.init(value) catch return error.InvalidUrl;
    var it = view.iterator();
    while (it.nextCodepoint()) |codepoint| switch (codepoint) {
        0...0x20, 0x7f...0x9f, 0x2028, 0x2029, '\\' => return error.InvalidUrl,
        else => {},
    };
    for (value, 0..) |byte, i| {
        if (byte != '%') continue;
        if (value.len - i < 3 or !std.ascii.isHex(value[i + 1]) or !std.ascii.isHex(value[i + 2])) return error.InvalidUrl;
    }
}

const Authority = struct { host: []const u8, port: ?u16 };

fn parseAuthority(authority: []const u8, buffer: *[255]u8) Error!Authority {
    if (authority[0] == '[') {
        const close = std.mem.indexOfScalar(u8, authority, ']') orelse return error.InvalidHost;
        const address = std.Io.net.Ip6Address.parse(authority[1..close], 0) catch return error.InvalidHost;
        const unresolved: std.Io.net.Ip6Address.Unresolved = .{ .bytes = address.bytes, .interface_name = null };
        return .{
            .host = std.fmt.bufPrint(buffer, "[{f}]", .{unresolved}) catch unreachable,
            .port = try parsePortSuffix(authority[close + 1 ..]),
        };
    }
    const host_end = std.mem.indexOfScalar(u8, authority, ':') orelse authority.len;
    if (host_end < authority.len and std.mem.indexOfScalar(u8, authority[host_end + 1 ..], ':') != null) return error.InvalidHost;
    return .{
        .host = try asciiHost(authority[0..host_end], buffer),
        .port = try parsePortSuffix(authority[host_end..]),
    };
}

fn parsePortSuffix(suffix: []const u8) Error!?u16 {
    if (suffix.len == 0) return null;
    if (suffix.len < 2 or suffix[0] != ':') return error.InvalidPort;
    const digits = suffix[1..];
    for (digits) |byte| if (!std.ascii.isDigit(byte)) return error.InvalidPort;
    const port = std.fmt.parseInt(u16, digits, 10) catch return error.InvalidPort;
    if (port == 0) return error.InvalidPort;
    return port;
}

fn asciiHost(input: []const u8, buffer: *[255]u8) Error![]const u8 {
    if (input.len == 0 or input.len > std.math.maxInt(i32) or
        std.mem.indexOfAny(u8, input, "[]%") != null) return error.InvalidHost;

    var status: i32 = 0;
    // STD3, Bidi, ContextJ and ContextO checks. Non-transitional UTS #46
    // keeps IDNA2008 characters such as ß distinct from their older mappings.
    const options = UIDNA_USE_STD3_RULES | UIDNA_CHECK_BIDI | UIDNA_CHECK_CONTEXTJ |
        UIDNA_NONTRANSITIONAL_TO_ASCII | UIDNA_CHECK_CONTEXTO;
    const idna = uidna_openUTS46(options, &status) orelse
        return if (status == U_MEMORY_ALLOCATION_ERROR) error.OutOfMemory else error.InvalidHost;
    defer uidna_close(idna);
    var info: UIDNAInfo = .{};
    const length = uidna_nameToASCII_UTF8(idna, input.ptr, @intCast(input.len), buffer, buffer.len, &info, &status);
    if (status == U_MEMORY_ALLOCATION_ERROR) return error.OutOfMemory;
    if (status > 0 or info.errors != 0 or length <= 0 or length > 254) return error.InvalidHost;
    const canonical = buffer[0..@intCast(length)];
    const dns = if (canonical[canonical.len - 1] == '.') canonical[0 .. canonical.len - 1] else canonical;
    if (dns.len == 0 or dns.len > 253) return error.InvalidHost;

    // WebKit interprets hostnames ending in a number as potential IPv4. Only
    // accept standard dotted-decimal so the shown origin matches the request.
    const last_dot = std.mem.lastIndexOfScalar(u8, dns, '.');
    const last_label = if (last_dot) |i| dns[i + 1 ..] else dns;
    if (numericLabel(last_label)) {
        _ = std.Io.net.Ip4Address.parse(dns, 0) catch return error.InvalidHost;
        return dns;
    }
    return canonical;
}

fn numericLabel(value: []const u8) bool {
    if (std.mem.startsWith(u8, value, "0x")) {
        for (value[2..]) |byte| if (!std.ascii.isHex(byte)) return false;
        return true;
    }
    if (value.len == 0) return false;
    for (value) |byte| if (!std.ascii.isDigit(byte)) return false;
    return true;
}

// Public ICU UIDNA ABI from the macOS SDK's unicode/uidna.h. UBool is int8_t.
// The symbols are provided by the OS libicucore, with no bundled ICU data.
const UIDNA = opaque {};
const UIDNAInfo = extern struct {
    size: i16 = @sizeOf(UIDNAInfo),
    is_transitional_different: i8 = 0,
    reserved_b3: i8 = 0,
    errors: u32 = 0,
    reserved_i2: i32 = 0,
    reserved_i3: i32 = 0,
};
const UIDNA_USE_STD3_RULES = 2;
const UIDNA_CHECK_BIDI = 4;
const UIDNA_CHECK_CONTEXTJ = 8;
const UIDNA_NONTRANSITIONAL_TO_ASCII = 0x10;
const UIDNA_CHECK_CONTEXTO = 0x40;
const U_MEMORY_ALLOCATION_ERROR = 7;
extern "c" fn uidna_openUTS46(u32, *i32) ?*UIDNA;
extern "c" fn uidna_close(*UIDNA) void;
extern "c" fn uidna_nameToASCII_UTF8(*const UIDNA, [*]const u8, i32, [*]u8, i32, *UIDNAInfo, *i32) i32;

test "normalizes only the web authority and empty path" {
    const allocator = std.testing.allocator;
    for ([_]struct { input: []const u8, text: []const u8, origin: []const u8, host: []const u8 }{
        .{ .input = " \tHTTPS://ExAmPle.Org:443/Path/%2f?q=2&q=1#A\n", .text = "https://example.org/Path/%2f?q=2&q=1#A", .origin = "https://example.org", .host = "example.org" },
        .{ .input = "gateway:8080?q=https://example.org/#Frag", .text = "https://gateway:8080/?q=https://example.org/#Frag", .origin = "https://gateway:8080", .host = "gateway" },
        .{ .input = "http://127.0.0.1:080", .text = "http://127.0.0.1/", .origin = "http://127.0.0.1", .host = "127.0.0.1" },
        .{ .input = "[2001:0DB8:0:0:0:0:0:2]:8443/页面", .text = "https://[2001:db8::2]:8443/页面", .origin = "https://[2001:db8::2]:8443", .host = "[2001:db8::2]" },
        .{ .input = "BÜCHER。example#章节", .text = "https://xn--bcher-kva.example/#章节", .origin = "https://xn--bcher-kva.example", .host = "xn--bcher-kva.example" },
        .{ .input = "faß.example.", .text = "https://xn--fa-hia.example./", .origin = "https://xn--fa-hia.example.", .host = "xn--fa-hia.example." },
    }) |case| {
        const url = try normalize(allocator, case.input);
        defer url.deinit(allocator);
        try std.testing.expectEqualStrings(case.text, url.text);
        try std.testing.expectEqualStrings(case.origin, url.origin());
        try std.testing.expectEqualStrings(case.host, url.host());
    }
}

test "rejects invalid host, credentials, scheme, port and URL bytes" {
    const allocator = std.testing.allocator;
    for ([_]struct { input: []const u8, expected: Error }{
        .{ .input = " \r\n", .expected = error.MissingUrl },
        .{ .input = "ftp://example.org/a", .expected = error.UnsupportedScheme },
        .{ .input = "data:123", .expected = error.UnsupportedScheme },
        .{ .input = "javascript:1", .expected = error.UnsupportedScheme },
        .{ .input = "file:/path", .expected = error.UnsupportedScheme },
        .{ .input = "https:443", .expected = error.InvalidUrl },
        .{ .input = "https://host:65536", .expected = error.InvalidPort },
        .{ .input = "http://host:0", .expected = error.InvalidPort },
        .{ .input = "https://host:+42", .expected = error.InvalidPort },
        .{ .input = "https://host:", .expected = error.InvalidPort },
        .{ .input = "https://u:p@example.org", .expected = error.InvalidUrl },
        .{ .input = "https:///path", .expected = error.InvalidHost },
        .{ .input = "https://[invalid]/", .expected = error.InvalidHost },
        .{ .input = "https://2001:db8::1/", .expected = error.InvalidHost },
        .{ .input = "https://[fe80::1%25en0]/", .expected = error.InvalidHost },
        .{ .input = "https://a..b/", .expected = error.InvalidHost },
        .{ .input = "https://xn--invalid-/", .expected = error.InvalidHost },
        .{ .input = "https://a\u{200d}.test/", .expected = error.InvalidHost },
        .{ .input = "https://%41.test/", .expected = error.InvalidHost },
        .{ .input = "https://127.1/", .expected = error.InvalidHost },
        .{ .input = "https://0177.0.0.1/", .expected = error.InvalidHost },
        .{ .input = "https://0x7f000001/", .expected = error.InvalidHost },
        .{ .input = "https://example.org/\xff", .expected = error.InvalidUrl },
        .{ .input = "https://example.org/\u{85}", .expected = error.InvalidUrl },
        .{ .input = "https://example.org/\\a", .expected = error.InvalidUrl },
        .{ .input = "https://example.org/a b", .expected = error.InvalidUrl },
        .{ .input = "https://example.org/%a", .expected = error.InvalidUrl },
    }) |case| try std.testing.expectError(case.expected, normalize(allocator, case.input));
}
