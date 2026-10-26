const std = @import("std");
const sidebar = @import("sidebar_model.zig");
const ConnectionId = @import("../host/identity.zig").ConnectionId;

pub const Model = struct {
    sidebar: sidebar.Model,
    query: []const u8 = "",
    quick_connect_open: bool = false,

    pub fn init(allocator: std.mem.Allocator) Model {
        return .{ .sidebar = sidebar.Model.init(allocator) };
    }
    pub fn deinit(self: *Model) void {
        self.sidebar.deinit();
        self.* = undefined;
    }
    pub fn toggleQuickConnect(self: *Model) void {
        self.quick_connect_open = !self.quick_connect_open;
    }
    pub fn toggleSidebar(self: *Model) void {
        self.sidebar.toggleCollapsed();
    }
    pub fn setQuery(self: *Model, query: []const u8) ![]const usize {
        self.query = query;
        return self.sidebar.search(query);
    }
};

/// One structured 「即兴直连」 target. A successful parse always supplies
/// `user`; IPv6 `host` borrows the address without its input brackets.
pub const ParsedTarget = struct {
    user: ?[]const u8,
    host: []const u8,
    port: u16,
};

/// Parses a quick-connect target without allocating: the returned slices
/// borrow from `input`.
///
/// Grammar: `[ssh ]user@host[:port]` or `[ssh ]user@[IPv6][:port]`.
/// The explicit user is required and the port defaults to 22. Plain hosts
/// retain their letters/digits/`.`/`-`/`_` grammar; IPv6 literals are checked
/// without DNS or interface lookup. Ports contain 1..5 decimal digits with
/// value 1..65535. No shell options, trailing commands or controls are accepted.
pub fn parseQuickTarget(input: []const u8) ?ParsedTarget {
    const target = if (std.mem.startsWith(u8, input, "ssh ")) input[4..] else input;
    if (target.len == 0) return null;
    for (target) |c| {
        if (c <= ' ' or c == 0x7f) return null;
    }

    const at = std.mem.indexOfScalar(u8, target, '@') orelse return null;
    const user = target[0..at];
    const rest = target[at + 1 ..];
    if (user.len == 0 or rest.len == 0) return null;
    for (user) |c| {
        switch (c) {
            '@', ':', '/', '\\' => return null,
            else => {},
        }
    }

    var host = rest;
    var port: u16 = 22;
    if (rest[0] == '[') {
        const close = std.mem.indexOfScalar(u8, rest, ']') orelse return null;
        host = rest[1..close];
        _ = std.Io.net.Ip6Address.parse(host, 0) catch return null;
        const suffix = rest[close + 1 ..];
        if (suffix.len != 0) {
            if (suffix[0] != ':') return null;
            port = parseQuickPort(suffix[1..]) orelse return null;
        }
    } else {
        if (std.mem.indexOfScalar(u8, rest, ':')) |colon| {
            host = rest[0..colon];
            port = parseQuickPort(rest[colon + 1 ..]) orelse return null;
        }
        if (!isPlainHost(host)) return null;
    }
    return .{ .user = user, .host = host, .port = port };
}

fn parseQuickPort(text: []const u8) ?u16 {
    if (text.len == 0 or text.len > 5) return null;
    for (text) |c| if (c < '0' or c > '9') return null;
    const port = std.fmt.parseInt(u16, text, 10) catch return null;
    return if (port == 0) null else port;
}

fn isPlainHost(host: []const u8) bool {
    if (host.len == 0 or host.len > 255) return false;
    for (host, 0..) |c, index| {
        switch (c) {
            'a'...'z', 'A'...'Z', '0'...'9' => {},
            '.', '-', '_' => if (index == 0 or index == host.len - 1) return false,
            else => return false,
        }
    }
    return true;
}

/// Formats the relative age of `then_ms` against `now_ms` for the
/// 最近连接 rows (mockup `.rt`: "2 分钟前"). Units: 刚刚 / N 分钟前 /
/// N 小时前 / N 天前. Never fails: a future/defective `then_ms` reads as
/// "刚刚", and a too-small buffer falls back to the same short form.
pub fn relativeTime(buffer: []u8, now_ms: u64, then_ms: u64) []const u8 {
    const elapsed_ms: u64 = if (now_ms > then_ms) now_ms - then_ms else 0;
    const minutes = elapsed_ms / (60 * std.time.ms_per_s);
    var writer = std.Io.Writer.fixed(buffer);
    if (minutes < 1) {
        return "刚刚";
    } else if (minutes < 60) {
        writer.print("{d} 分钟前", .{minutes}) catch return "刚刚";
    } else if (minutes < 60 * 24) {
        writer.print("{d} 小时前", .{minutes / 60}) catch return "刚刚";
    } else {
        writer.print("{d} 天前", .{minutes / (60 * 24)}) catch return "刚刚";
    }
    return writer.buffered();
}

/// Recent saved assets are identified by persistent ID, never registry position.
/// Resolve the ID against the live registry when painting; a deleted asset is
/// absent rather than silently selecting the next occupant of its old slot.
pub const RecentList = struct {
    pub const capacity = 8;

    const Entry = struct {
        active: bool = false,
        connection_id: ConnectionId = @fromBackingInt(0),
        /// Monotonic sequence: position in recency order (larger = newer).
        seq: u64 = 0,
    };

    ring: [capacity]Entry = @splat(.{}),
    head: usize = 0, // next slot to overwrite (oldest once full)
    len: usize = 0,
    seq_last: u64 = 0,

    /// Records a connect against `connection_id`. Re-recording an already
    /// tracked host just bumps its recency instead of duplicating the row.
    /// Full-ring eviction takes the least-recently-used slot (lowest seq),
    /// NOT the oldest insertion — a re-bumped entry must survive. `now_ms`
    /// is currently informational; recency is fully sequenced.
    pub fn record(self: *RecentList, connection_id: ConnectionId, now_ms: u64) void {
        _ = now_ms;
        if (@backingInt(connection_id) == 0) return;
        for (self.ring[0..self.len]) |*entry| {
            if (entry.active and entry.connection_id == connection_id) {
                self.seq_last += 1;
                entry.seq = self.seq_last;
                return;
            }
        }
        self.seq_last += 1;
        if (self.len < self.ring.len) {
            self.ring[self.head] = .{ .active = true, .connection_id = connection_id, .seq = self.seq_last };
            self.head = (self.head + 1) % self.ring.len;
            self.len += 1;
            return;
        }
        // Full: overwrite the least-recently-used entry (lowest seq).
        var lru_slot: usize = 0;
        for (self.ring[1..], 1..) |entry, slot| {
            if (entry.seq < self.ring[lru_slot].seq) lru_slot = slot;
        }
        self.ring[lru_slot] = .{ .active = true, .connection_id = connection_id, .seq = self.seq_last };
    }

    /// Persistent ID of the `rank`-th most recent entry, or null.
    pub fn at(self: *const RecentList, rank: usize) ?ConnectionId {
        if (rank >= self.len) return null;
        // Round 0 takes the global max; each later round only considers
        // entries strictly below the previous pick's seq.
        var lower_bound: ?u64 = null;
        var picked_index: ConnectionId = @fromBackingInt(0);
        var skipped: usize = 0;
        while (skipped <= rank) : (skipped += 1) {
            var best_seq: ?u64 = null;
            for (self.ring[0..self.len]) |entry| {
                if (!entry.active) continue;
                if (lower_bound) |bound| {
                    if (entry.seq >= bound) continue;
                }
                if (best_seq == null or entry.seq > best_seq.?) {
                    best_seq = entry.seq;
                    picked_index = entry.connection_id;
                }
            }
            const seq = best_seq orelse return null;
            lower_bound = seq;
        }
        return picked_index;
    }

    /// Most recent entry for `connection_id`, if tracked.
    pub fn seqOf(self: *const RecentList, connection_id: ConnectionId) ?u64 {
        for (self.ring[0..self.len]) |entry| {
            if (entry.active and entry.connection_id == connection_id) return entry.seq;
        }
        return null;
    }

    pub fn resolve(self: *const RecentList, rank: usize, registry: *const @import("../config/hosts.zig").Registry) ?@import("../host/identity.zig").AssetOwner {
        const id = self.at(rank) orelse return null;
        const index = registry.indexOf(id) orelse return null;
        return .{ .id = id, .revision = registry.hosts[index].revision };
    }
};

test "recent saved identity survives registry reorder and cannot reconnect a deleted slot occupant" {
    const hosts = @import("../config/hosts.zig");
    var registry: hosts.Registry = .{ .arena = .init(std.testing.allocator), .hosts = &.{} };
    defer registry.deinit();
    var entries = [_]hosts.HostConfig{
        .{ .connection_id = @fromBackingInt(41), .name = "same", .host = "first", .user = "u" },
        .{ .connection_id = @fromBackingInt(73), .name = "same", .host = "second", .user = "u" },
    };
    registry.hosts = &entries;
    var recent: RecentList = .{};
    recent.record(@fromBackingInt(0), 0);
    try std.testing.expectEqual(@as(usize, 0), recent.len);
    recent.record(entries[1].connection_id, 0);
    const captured = recent.resolve(0, &registry).?;
    std.mem.swap(hosts.HostConfig, &entries[0], &entries[1]);
    try std.testing.expectEqualStrings("second", (try registry.get(captured)).host);
    entries[0].revision += 1;
    try std.testing.expectError(error.RevisionConflict, registry.get(captured));
    try std.testing.expectEqual(@as(u64, 2), recent.resolve(0, &registry).?.revision);
    registry.hosts = entries[1..];
    try std.testing.expect(recent.resolve(0, &registry) == null);
    try std.testing.expectError(error.ConnectionNotFound, registry.get(captured));
}

test "quick connect model toggles overlay and sidebar" {
    var model = Model.init(std.testing.allocator);
    defer model.deinit();
    try model.sidebar.add(.{ .id = 1, .name = "prod", .host = "db.local" });
    model.toggleQuickConnect();
    try std.testing.expect(model.quick_connect_open);
    try std.testing.expectEqual(@as(usize, 1), (try model.setQuery("db")).len);
    model.toggleSidebar();
    try std.testing.expectEqual(@as(f32, 0), model.sidebar.width());
}

test "parseQuickTarget requires a user and accepts the optional ssh prefix" {
    const cases = [_]struct { input: []const u8, user: []const u8, host: []const u8, port: u16 }{
        .{ .input = "ops@10.200.1.18:2222", .user = "ops", .host = "10.200.1.18", .port = 2222 },
        .{ .input = "root@db.internal.example", .user = "root", .host = "db.internal.example", .port = 22 },
        .{ .input = "ssh deploy_user@my-host_name-1", .user = "deploy_user", .host = "my-host_name-1", .port = 22 },
        .{ .input = "ssh ops@localhost:2200", .user = "ops", .host = "localhost", .port = 2200 },
        .{ .input = "u@host:1", .user = "u", .host = "host", .port = 1 },
        .{ .input = "u@host:65535", .user = "u", .host = "host", .port = 65535 },
        .{ .input = "u@host:00022", .user = "u", .host = "host", .port = 22 },
    };
    for (cases) |case| {
        const parsed = parseQuickTarget(case.input) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqualStrings(case.user, parsed.user.?);
        try std.testing.expectEqualStrings(case.host, parsed.host);
        try std.testing.expectEqual(case.port, parsed.port);
    }
}

test "parseQuickTarget returns borrowed unbracketed IPv6 addresses" {
    const cases = [_]struct { input: []const u8, host: []const u8, port: u16 }{
        .{ .input = "ops@[::1]", .host = "::1", .port = 22 },
        .{ .input = "ssh ops@[2001:db8::1]:2222", .host = "2001:db8::1", .port = 2222 },
        .{ .input = "ops@[::]:1", .host = "::", .port = 1 },
        .{ .input = "ops@[2001:DB8:0:1:2:3:4:5]:65535", .host = "2001:DB8:0:1:2:3:4:5", .port = 65535 },
        .{ .input = "ops@[::ffff:192.0.2.1]", .host = "::ffff:192.0.2.1", .port = 22 },
    };
    for (cases) |case| {
        const parsed = parseQuickTarget(case.input) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqualStrings("ops", parsed.user.?);
        try std.testing.expectEqualStrings(case.host, parsed.host);
        try std.testing.expectEqual(case.port, parsed.port);
        const bracket = std.mem.indexOfScalar(u8, case.input, '[').?;
        try std.testing.expect(parsed.host.ptr == case.input[bracket + 1 ..].ptr);
    }
}

test "parseQuickTarget rejects missing users options and trailing commands" {
    const invalid = [_][]const u8{
        "",                    "  ",                    "user host",      "host",
        "localhost:2200",      "10.0.0.8",              "[::1]:22",       "ssh host",
        "ssh ",                "ssh  user@host",        " ssh user@host", "ssh\tuser@host",
        "ssh -p 22 user@host", "ssh://user@host",       "user@",          "@host",
        "ssh @host",           "user@@host",            "a@b@c",          "user:name@host",
        "user/name@host",      "user\\name@host",       "user@-",         "user@host/extra",
        "user@host ls",        "ssh user@host echo hi", "user@host;id",   "user@host&&id",
        "user@host`id`",       "user@host$(id)",        "user@[::1]ls",   "user@[::1]:22/extra",
    };
    for (invalid) |input| try std.testing.expect(parseQuickTarget(input) == null);
}

test "parseQuickTarget rejects non decimal and out of range ports for both host forms" {
    const invalid = [_][]const u8{
        "user@host:",      "user@host:abc",    "user@host:0",      "user@host:65536",
        "user@host:99999", "user@host:123456", "user@host:22x",    "user@host:2 2",
        "user@host:+22",   "user@host:-1",     "user@host:1_000",  "user@host:0x16",
        "user@[::1]:",     "user@[::1]:0",     "user@[::1]:65536", "user@[::1]:123456",
        "user@[::1]:+22",  "user@[::1]:-1",    "user@[::1]:1_000", "user@[::1]:22:23",
    };
    for (invalid) |input| try std.testing.expect(parseQuickTarget(input) == null);
}

test "parseQuickTarget rejects malformed and unbracketed IPv6" {
    const invalid = [_][]const u8{
        "user@::1",              "user@2001:db8::1",     "user@2001:db8::1:22",
        "user@[",                "user@[::1",            "user@::1]",
        "user@[]",               "user@[127.0.0.1]",     "user@[localhost]",
        "user@[2001:db8::gggg]", "user@[1:2:3:4:5:6:7]", "user@[1:2:3:4:5:6:7:8:9]",
        "user@[1::2::3]",        "user@[:::]",           "user@[::ffff:999.0.0.1]",
        "user@[[::1]]",          "user@[::1]]",          "user@[::1]@host",
    };
    for (invalid) |input| try std.testing.expect(parseQuickTarget(input) == null);
}

test "parseQuickTarget rejects all ASCII controls and retains plain host length limits" {
    var input = "user@host".*;
    for (0..0x21) |control| {
        input[1] = @intCast(control);
        try std.testing.expect(parseQuickTarget(&input) == null);
    }
    input[1] = 0x7f;
    try std.testing.expect(parseQuickTarget(&input) == null);

    const hostname: [255]u8 = @splat('a');
    const longest = "user@" ++ hostname;
    const parsed = parseQuickTarget(longest) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 255), parsed.host.len);
    try std.testing.expect(parseQuickTarget(longest ++ "a") == null);
}

test "relativeTime buckets by minute hour and day" {
    var buffer: [64]u8 = undefined;
    const now: u64 = 1_700_000_000 * std.time.ms_per_s;
    try std.testing.expectEqualStrings("刚刚", relativeTime(&buffer, now, now - 30 * std.time.ms_per_s));
    try std.testing.expectEqualStrings("刚刚", relativeTime(&buffer, now, now - 59 * std.time.ms_per_s));
    try std.testing.expectEqualStrings("刚刚", relativeTime(&buffer, now, now + std.time.ms_per_s));
    try std.testing.expectEqualStrings("2 分钟前", relativeTime(&buffer, now, now - 2 * 60 * std.time.ms_per_s));
    try std.testing.expectEqualStrings("59 分钟前", relativeTime(&buffer, now, now - 59 * 60 * std.time.ms_per_s));
    try std.testing.expectEqualStrings("1 小时前", relativeTime(&buffer, now, now - 60 * 60 * std.time.ms_per_s));
    try std.testing.expectEqualStrings("3 小时前", relativeTime(&buffer, now, now - 3 * 3600 * std.time.ms_per_s));
    try std.testing.expectEqualStrings("23 小时前", relativeTime(&buffer, now, now - 23 * 3600 * std.time.ms_per_s));
    try std.testing.expectEqualStrings("1 天前", relativeTime(&buffer, now, now - 24 * 3600 * std.time.ms_per_s));
    try std.testing.expectEqualStrings("9 天前", relativeTime(&buffer, now, now - 9 * 86400 * std.time.ms_per_s));
}

test "RecentList keeps recency order without duplicates and evicts oldest" {
    var recent: RecentList = .{};
    try std.testing.expect(recent.at(0) == null);

    recent.record(@fromBackingInt(3), 1000);
    recent.record(@fromBackingInt(5), 2000);
    recent.record(@fromBackingInt(3), 3000); // duplicate: recency bump, no dup row
    recent.record(@fromBackingInt(7), 4000);
    try std.testing.expectEqual(@as(usize, 3), recent.len);
    try std.testing.expectEqual(@as(?ConnectionId, @fromBackingInt(7)), recent.at(0));
    try std.testing.expectEqual(@as(?ConnectionId, @fromBackingInt(3)), recent.at(1));
    try std.testing.expectEqual(@as(?ConnectionId, @fromBackingInt(5)), recent.at(2));
    try std.testing.expectEqual(@as(?ConnectionId, null), recent.at(3));
    try std.testing.expectEqual(@as(?u64, null), recent.seqOf(@fromBackingInt(9)));
    try std.testing.expect(recent.seqOf(@fromBackingInt(3)) != null);

    // Ring eviction: the oldest (5) falls out after 8 distinct hosts.
    var index: usize = 10;
    while (index < 16) : (index += 1) recent.record(@fromBackingInt(index), 0);
    try std.testing.expectEqual(@as(usize, RecentList.capacity), recent.len);
    try std.testing.expectEqual(@as(?ConnectionId, null), recent.at(RecentList.capacity - 1 + 1));
    // Oldest surviving set no longer contains 5 or its eviction slot peers.
    var found_five = false;
    var rank: usize = 0;
    while (recent.at(rank)) |_| : (rank += 1) {
        if (@backingInt(recent.at(rank).?) == 5) found_five = true;
    }
    try std.testing.expect(!found_five);
}
