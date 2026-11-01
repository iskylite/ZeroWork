//! Bounded HTTP/1.1 for the BMC management and WebSocket upgrade channels.
//! RFC 9112 framing; one response at a time. feed() leaves upgrade/pipelined
//! bytes unconsumed. This module never follows a redirect or logs wire data.
const std = @import("std");

pub const max_header_bytes = 64 * 1024;
pub const max_rest_body_bytes = 4 * 1024 * 1024;
pub const Header = struct { name: []const u8, value: []const u8 };
pub const Limits = struct { header_bytes: usize = max_header_bytes, body_bytes: usize = max_rest_body_bytes, request_is_head: bool = false };

pub const Origin = struct {
    /// Original BMC identity, without brackets; never the forwarding address.
    host: []const u8,
    port: u16 = 443,

    pub fn validate(self: Origin) !void {
        if (self.host.len == 0 or self.host.len > 253 or self.port == 0) return error.InvalidAuthority;
        for (self.host) |ch| switch (ch) {
            'a'...'z', 'A'...'Z', '0'...'9', '-', '.', ':' => {},
            else => return error.InvalidAuthority,
        };
        if (self.host[0] == '.' or self.host[self.host.len - 1] == '.') return error.InvalidAuthority;
    }

    pub fn authority(self: Origin, allocator: std.mem.Allocator) ![]u8 {
        try self.validate();
        const ipv6 = std.mem.indexOfScalar(u8, self.host, ':') != null;
        if (ipv6) return if (self.port == 443) std.fmt.allocPrint(allocator, "[{s}]", .{self.host}) else std.fmt.allocPrint(allocator, "[{s}]:{d}", .{ self.host, self.port });
        return if (self.port == 443) allocator.dupe(u8, self.host) else std.fmt.allocPrint(allocator, "{s}:{d}", .{ self.host, self.port });
    }

    /// Only same HTTPS origin and origin-form resource references are accepted.
    /// Returned slice borrows uri (or is the literal "/"). No network access.
    pub fn validateReference(self: Origin, uri: []const u8) ![]const u8 {
        try self.validate();
        if (std.mem.startsWith(u8, uri, "/")) {
            try validatePath(uri);
            return uri;
        }
        if (uri.len < 8 or !std.ascii.eqlIgnoreCase(uri[0..8], "https://")) return error.CrossOriginReference;
        const tail = uri[8..];
        const end = std.mem.indexOfAny(u8, tail, "/?#") orelse tail.len;
        const authority_part = tail[0..end];
        var host: []const u8 = undefined;
        var port: u16 = 443;
        if (authority_part.len == 0) return error.InvalidAuthority;
        if (authority_part[0] == '[') {
            const close = std.mem.indexOfScalar(u8, authority_part, ']') orelse return error.InvalidAuthority;
            host = authority_part[1..close];
            if (close + 1 < authority_part.len) {
                if (authority_part[close + 1] != ':') return error.InvalidAuthority;
                port = try parsePort(authority_part[close + 2 ..]);
            }
        } else {
            if (std.mem.indexOfScalar(u8, authority_part, ':')) |colon| {
                host = authority_part[0..colon];
                port = try parsePort(authority_part[colon + 1 ..]);
            } else host = authority_part;
        }
        try (Origin{ .host = host, .port = port }).validate();
        if (!std.ascii.eqlIgnoreCase(host, self.host) or port != self.port) return error.CrossOriginReference;
        if (end == tail.len) return "/";
        const path = tail[end..];
        try validatePath(path);
        return path;
    }
};

fn parsePort(bytes: []const u8) !u16 {
    if (bytes.len == 0) return error.InvalidAuthority;
    for (bytes) |ch| if (!std.ascii.isDigit(ch)) return error.InvalidAuthority;
    const port = std.fmt.parseInt(u16, bytes, 10) catch return error.InvalidAuthority;
    if (port == 0) return error.InvalidAuthority;
    return port;
}

pub fn isToken(bytes: []const u8) bool {
    if (bytes.len == 0) return false;
    for (bytes) |ch| switch (ch) {
        'a'...'z', 'A'...'Z', '0'...'9', '!', '#', '$', '%', '&', '\'', '*', '+', '-', '.', '^', '_', '`', '|', '~' => {},
        else => return false,
    };
    return true;
}

fn validValue(bytes: []const u8) bool {
    for (bytes) |ch| if ((ch < 32 and ch != '\t') or ch == 127) return false;
    return true;
}

pub fn validatePath(path: []const u8) !void {
    if (path.len == 0 or path[0] != '/' or std.mem.startsWith(u8, path, "//")) return error.InvalidPath;
    var i: usize = 0;
    while (i < path.len) : (i += 1) {
        const ch = path[i];
        if (ch <= 32 or ch >= 127 or ch == '\\' or ch == '#') return error.InvalidPath;
        if (ch == '%') {
            if (i + 2 >= path.len or !std.ascii.isHex(path[i + 1]) or !std.ascii.isHex(path[i + 2])) return error.InvalidPath;
            const decoded = std.fmt.parseInt(u8, path[i + 1 .. i + 3], 16) catch return error.InvalidPath;
            if (decoded == '\r' or decoded == '\n' or decoded == 0 or decoded == '\\') return error.InvalidPath;
            i += 2;
        }
    }
}

/// Owns the framing and Host headers; caller cannot override them. The result
/// can contain credentials and must be wiped by the caller after transmission.
pub fn buildRequest(allocator: std.mem.Allocator, method: []const u8, origin: Origin, path: []const u8, headers: []const Header, body: []const u8) ![]u8 {
    if (!isToken(method)) return error.InvalidMethod;
    try validatePath(path);
    if (body.len > max_rest_body_bytes) return error.BodyTooLarge;
    const authority = try origin.authority(allocator);
    defer allocator.free(authority);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, method);
    try out.appendSlice(allocator, " ");
    try out.appendSlice(allocator, path);
    try out.appendSlice(allocator, " HTTP/1.1\r\nHost: ");
    try out.appendSlice(allocator, authority);
    try out.appendSlice(allocator, "\r\n");
    for (headers) |header| {
        if (!isToken(header.name) or !validValue(header.value)) return error.InvalidHeader;
        if (std.ascii.eqlIgnoreCase(header.name, "Host") or std.ascii.eqlIgnoreCase(header.name, "Content-Length") or std.ascii.eqlIgnoreCase(header.name, "Transfer-Encoding")) return error.ReservedHeader;
        try out.appendSlice(allocator, header.name);
        try out.appendSlice(allocator, ": ");
        try out.appendSlice(allocator, header.value);
        try out.appendSlice(allocator, "\r\n");
        if (out.items.len > max_header_bytes) return error.HeadersTooLarge;
    }
    const length = try std.fmt.allocPrint(allocator, "Content-Length: {d}\r\n\r\n", .{body.len});
    defer allocator.free(length);
    try out.appendSlice(allocator, length);
    if (out.items.len > max_header_bytes) return error.HeadersTooLarge;
    try out.appendSlice(allocator, body);
    return out.toOwnedSlice(allocator);
}

pub const WriteCursor = struct {
    bytes: []const u8,
    offset: usize = 0,
    pub fn remaining(self: WriteCursor) []const u8 {
        return self.bytes[self.offset..];
    }
    pub fn advance(self: *WriteCursor, written: usize) !void {
        if (written > self.bytes.len - self.offset) return error.InvalidWriteCount;
        self.offset += written;
    }
    pub fn done(self: WriteCursor) bool {
        return self.offset == self.bytes.len;
    }
};

pub const ResponseParser = struct {
    allocator: std.mem.Allocator,
    limits: Limits,
    header_buffer: std.ArrayList(u8) = .empty,
    body_buffer: std.ArrayList(u8) = .empty,
    headers: std.ArrayList(Header) = .empty,
    status: u16 = 0,
    state: State = .headers,
    remaining: usize = 0,
    line_buffer: std.ArrayList(u8) = .empty,
    framing_bytes: usize = 0,
    interim_count: u8 = 0,
    crlf_index: u2 = 0,
    pub const State = enum { headers, fixed, until_eof, chunk_size, chunk_data, chunk_crlf, trailers, done, failed };

    pub fn init(allocator: std.mem.Allocator, limits: Limits) ResponseParser {
        return .{ .allocator = allocator, .limits = limits };
    }
    pub fn deinit(self: *ResponseParser) void {
        std.crypto.secureZero(u8, self.header_buffer.items);
        std.crypto.secureZero(u8, self.body_buffer.items);
        self.header_buffer.deinit(self.allocator);
        self.body_buffer.deinit(self.allocator);
        self.headers.deinit(self.allocator);
        self.line_buffer.deinit(self.allocator);
        self.* = undefined;
    }
    pub fn isDone(self: *const ResponseParser) bool {
        return self.state == .done;
    }
    pub fn body(self: *const ResponseParser) []const u8 {
        return self.body_buffer.items;
    }
    pub fn header(self: *const ResponseParser, name: []const u8) ?[]const u8 {
        for (self.headers.items) |h| if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
        return null;
    }
    pub fn headerCount(self: *const ResponseParser, name: []const u8) usize {
        var count: usize = 0;
        for (self.headers.items) |h| if (std.ascii.eqlIgnoreCase(h.name, name)) {
            count += 1;
        };
        return count;
    }
    pub fn hasToken(self: *const ResponseParser, name: []const u8, token: []const u8) bool {
        for (self.headers.items) |h| {
            if (!std.ascii.eqlIgnoreCase(h.name, name)) continue;
            var values = std.mem.splitScalar(u8, h.value, ',');
            while (values.next()) |value| if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, value, " \t"), token)) return true;
        }
        return false;
    }
    pub fn feed(self: *ResponseParser, bytes: []const u8) !usize {
        errdefer self.state = .failed;
        if (self.state == .failed) return error.ParserFailed;
        var offset: usize = 0;
        while (offset < bytes.len and self.state != .done) {
            switch (self.state) {
                .headers => {
                    try self.countFraming();
                    try self.header_buffer.append(self.allocator, bytes[offset]);
                    offset += 1;
                    if (std.mem.endsWith(u8, self.header_buffer.items, "\r\n\r\n")) try self.parseHeaders();
                },
                .fixed, .chunk_data => {
                    const n = @min(self.remaining, bytes.len - offset);
                    try self.appendBody(bytes[offset..][0..n]);
                    offset += n;
                    self.remaining -= n;
                    if (self.remaining == 0) self.state = if (self.state == .fixed) .done else .chunk_crlf;
                },
                .until_eof => {
                    try self.appendBody(bytes[offset..]);
                    offset = bytes.len;
                },
                .chunk_size, .trailers => {
                    try self.countFraming();
                    if (self.line_buffer.items.len >= 8192) return error.InvalidChunkFraming;
                    try self.line_buffer.append(self.allocator, bytes[offset]);
                    offset += 1;
                    if (std.mem.endsWith(u8, self.line_buffer.items, "\r\n")) {
                        const line = self.line_buffer.items[0 .. self.line_buffer.items.len - 2];
                        if (self.state == .chunk_size) {
                            const ext = std.mem.indexOfScalar(u8, line, ';') orelse line.len;
                            const size = line[0..ext];
                            if (size.len == 0 or size.len > 16 or !validValue(line)) return error.InvalidChunkFraming;
                            for (size) |ch| if (!std.ascii.isHex(ch)) return error.InvalidChunkFraming;
                            self.remaining = std.fmt.parseInt(usize, size, 16) catch return error.BodyTooLarge;
                            if (self.remaining > self.limits.body_bytes - self.body_buffer.items.len) return error.BodyTooLarge;
                            self.state = if (self.remaining == 0) .trailers else .chunk_data;
                        } else if (line.len == 0) {
                            self.state = .done;
                        } else {
                            const h = try parseHeaderLine(line);
                            if (std.ascii.eqlIgnoreCase(h.name, "Content-Length") or std.ascii.eqlIgnoreCase(h.name, "Transfer-Encoding") or std.ascii.eqlIgnoreCase(h.name, "Host")) return error.ConflictingFraming;
                        }
                        self.line_buffer.clearRetainingCapacity();
                    }
                },
                .chunk_crlf => {
                    if (bytes[offset] != (if (self.crlf_index == 0) @as(u8, '\r') else @as(u8, '\n'))) return error.InvalidChunkFraming;
                    offset += 1;
                    self.crlf_index += 1;
                    if (self.crlf_index == 2) {
                        self.crlf_index = 0;
                        self.state = .chunk_size;
                    }
                },
                .done => unreachable,
                .failed => return error.ParserFailed,
            }
        }
        return offset;
    }
    pub fn finishEof(self: *ResponseParser) !void {
        if (self.state == .until_eof) self.state = .done;
        if (self.state != .done) {
            self.state = .failed;
            return error.TruncatedResponse;
        }
    }
    fn countFraming(self: *ResponseParser) !void {
        if (self.framing_bytes >= self.limits.header_bytes) return error.HeadersTooLarge;
        self.framing_bytes += 1;
    }
    fn appendBody(self: *ResponseParser, bytes: []const u8) !void {
        if (bytes.len > self.limits.body_bytes - self.body_buffer.items.len) return error.BodyTooLarge;
        try self.body_buffer.appendSlice(self.allocator, bytes);
    }
    fn parseHeaders(self: *ResponseParser) !void {
        var lines = std.mem.splitSequence(u8, self.header_buffer.items, "\r\n");
        const first = lines.next() orelse return error.InvalidStatusLine;
        if (first.len < 12 or (!std.mem.startsWith(u8, first, "HTTP/1.1 ") and !std.mem.startsWith(u8, first, "HTTP/1.0 ")) or !validValue(first)) return error.InvalidStatusLine;
        if (first.len > 12 and first[12] != ' ') return error.InvalidStatusLine;
        for (first[9..12]) |ch| if (!std.ascii.isDigit(ch)) return error.InvalidStatusLine;
        self.status = try std.fmt.parseInt(u16, first[9..12], 10);
        if (self.status < 100 or self.status > 599) return error.InvalidStatusLine;
        var length: ?usize = null;
        var chunked = false;
        while (lines.next()) |line| {
            if (line.len == 0) break;
            if (self.headers.items.len >= 256) return error.TooManyHeaders;
            const h = try parseHeaderLine(line);
            try self.headers.append(self.allocator, h);
            if (std.ascii.eqlIgnoreCase(h.name, "Content-Length")) {
                if (length != null or h.value.len == 0) return error.ConflictingFraming;
                for (h.value) |ch| if (!std.ascii.isDigit(ch)) return error.ConflictingFraming;
                length = std.fmt.parseInt(usize, h.value, 10) catch return error.BodyTooLarge;
            } else if (std.ascii.eqlIgnoreCase(h.name, "Transfer-Encoding")) {
                if (chunked or !std.ascii.eqlIgnoreCase(h.value, "chunked")) return error.UnsupportedTransferEncoding;
                chunked = true;
            }
        }
        if (chunked and length != null) return error.ConflictingFraming;
        if (self.status < 200 and self.status != 101) {
            if (chunked or length != null) return error.ConflictingFraming;
            self.interim_count += 1;
            if (self.interim_count > 8) return error.TooManyInterimResponses;
            self.header_buffer.clearRetainingCapacity();
            self.headers.clearRetainingCapacity();
            return;
        }
        if (self.status == 101 or self.status == 204) {
            if (chunked or (length != null and length.? != 0)) return error.ConflictingFraming;
            self.state = .done;
        } else if (self.limits.request_is_head or self.status == 304) {
            self.state = .done;
        } else if (chunked) {
            self.state = .chunk_size;
        } else if (length) |n| {
            if (n > self.limits.body_bytes) return error.BodyTooLarge;
            self.remaining = n;
            self.state = if (n == 0) .done else .fixed;
        } else self.state = .until_eof;
    }
};

fn parseHeaderLine(line: []const u8) !Header {
    const colon = std.mem.indexOfScalar(u8, line, ':') orelse return error.InvalidHeader;
    const name = line[0..colon];
    const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
    if (!isToken(name) or !validValue(value)) return error.InvalidHeader;
    return .{ .name = name, .value = value };
}
