//! Versioned connection data. A decoded repair draft cannot start a session.
const std = @import("std");
const bookmarks = @import("bookmarks.zig");
const urls = @import("urls.zig");

pub const protocol_id = "web";
pub const payload_version: u32 = 1;
pub const max_hops = 8;

pub const UrlMode = enum { preset, manual };
pub const RouteMode = enum { direct, ssh };
pub const Route = struct {
    mode: RouteMode = .direct,
    hop_asset_ids: []const u64 = &.{},

    fn canonical(self: Route) !Route {
        if (self.mode == .direct) return .{};
        if (self.hop_asset_ids.len == 0) return error.MissingSshReference;
        if (self.hop_asset_ids.len > max_hops) return error.TooManyJumps;
        for (self.hop_asset_ids, 0..) |id, i| {
            if (id == 0) return error.InvalidSshReference;
            for (self.hop_asset_ids[0..i]) |prior| if (prior == id) return error.DuplicateRoute;
        }
        return self;
    }
};

pub const Payload = struct {
    url_mode: UrlMode,
    start_url: ?[]const u8 = null,
    route: Route = .{},
    bookmarks: []const bookmarks.Bookmark = &.{},

    fn canonicalSettings(self: Payload, arena: std.mem.Allocator) !Payload {
        var result = self;
        result.route = try self.route.canonical();
        result.start_url = switch (self.url_mode) {
            .preset => (try urls.normalize(arena, self.start_url orelse return error.MissingUrl)).text,
            .manual => null,
        };
        return result;
    }
};

pub const Repair = struct {
    base: Payload,
    rows: []const bookmarks.RepairRow,

    /// Produce an editor draft only. The caller must save it against the
    /// original asset revision to replace the persisted broken payload.
    pub fn apply(self: Repair, arena: std.mem.Allocator, rows: []const bookmarks.RepairInput) !Payload {
        var result = self.base;
        if (result.start_url) |value| result.start_url = try arena.dupe(u8, value);
        result.route.hop_asset_ids = try arena.dupe(u64, result.route.hop_asset_ids);
        result.bookmarks = try bookmarks.applyRepair(arena, rows);
        return result;
    }
};

pub const Decoded = struct {
    arena: std.heap.ArenaAllocator,
    content: union(enum) {
        ready: Payload,
        repair: Repair,
    },

    pub fn deinit(self: *Decoded) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

const Wire = struct {
    url_mode: ?UrlMode = null,
    start_url: ?[]const u8 = null,
    route: Route = .{},
    bookmarks: std.json.Value = .null,
    url: ?[]const u8 = null,
};

pub fn decode(allocator: std.mem.Allocator, version: u32, bytes: []const u8) !Decoded {
    if (version != payload_version) return error.UnsupportedPayloadVersion;
    var result: Decoded = .{ .arena = .init(allocator), .content = undefined };
    errdefer result.arena.deinit();
    const a = result.arena.allocator();

    const document = try std.json.parseFromSliceLeaky(std.json.Value, a, bytes, .{
        .allocate = .alloc_always,
        .parse_numbers = false,
    });
    if (document != .object) return error.InvalidPayload;
    const wire = try std.json.parseFromValueLeaky(Wire, a, document, .{});
    var base: Payload = if (wire.url_mode) |mode| blk: {
        if (document.object.contains("url")) return error.InvalidPayload;
        break :blk .{ .url_mode = mode, .start_url = wire.start_url, .route = wire.route };
    } else blk: {
        if (!document.object.contains("url") or document.object.contains("start_url")) return error.InvalidPayload;
        const old_url = wire.url orelse "";
        const mode: UrlMode = if (std.mem.trim(u8, old_url, " \t\r\n").len == 0) .manual else .preset;
        break :blk .{ .url_mode = mode, .start_url = wire.url, .route = wire.route };
    };
    base = try base.canonicalSettings(a);
    result.content = .{ .ready = base };
    if (document.object.contains("bookmarks")) switch (try bookmarks.decode(a, wire.bookmarks)) {
        .ready => |items| result.content.ready.bookmarks = items,
        .repair => |rows| result.content = .{ .repair = .{ .base = base, .rows = rows } },
    };
    return result;
}

pub fn encode(allocator: std.mem.Allocator, value: Payload) ![]u8 {
    var scratch: std.heap.ArenaAllocator = .init(allocator);
    defer scratch.deinit();
    const a = scratch.allocator();
    var payload = try value.canonicalSettings(a);
    payload.bookmarks = try bookmarks.normalizeList(a, payload.bookmarks);
    return std.json.Stringify.valueAlloc(allocator, payload, .{ .emit_null_optional_fields = false });
}

test "web payload normalizes hidden fields and round trips the ordered SSH route" {
    const allocator = std.testing.allocator;
    const manual = try encode(allocator, .{ .url_mode = .manual, .start_url = "ignored", .route = .{ .hop_asset_ids = &.{ 6, 3 } } });
    defer allocator.free(manual);
    try std.testing.expect(std.mem.indexOf(u8, manual, "start_url") == null);
    var empty = try decode(allocator, payload_version, manual);
    defer empty.deinit();
    try std.testing.expectEqual(UrlMode.manual, empty.content.ready.url_mode);
    try std.testing.expectEqual(@as(usize, 0), empty.content.ready.route.hop_asset_ids.len);
    try std.testing.expectEqual(@as(usize, 0), empty.content.ready.bookmarks.len);

    const encoded = try encode(allocator, .{
        .url_mode = .preset,
        .start_url = "BÜCHER.example:443/Console?q=1#top",
        .route = .{ .mode = .ssh, .hop_asset_ids = &.{ 9, 3, 27, 10, 8, 6, 18, 2 } },
        .bookmarks = &.{.{ .id = .{ .bytes = @splat(4) }, .title = "控制台", .url = "https://web.test:443/" }},
    });
    defer allocator.free(encoded);
    var decoded = try decode(allocator, payload_version, encoded);
    defer decoded.deinit();
    const value = decoded.content.ready;
    try std.testing.expectEqualStrings("https://xn--bcher-kva.example/Console?q=1#top", value.start_url.?);
    try std.testing.expectEqualSlices(u64, &.{ 9, 3, 27, 10, 8, 6, 18, 2 }, value.route.hop_asset_ids);
    try std.testing.expectEqualStrings("https://web.test/", value.bookmarks[0].url);
    try std.testing.expect(value.bookmarks[0].id.eql(.{ .bytes = @splat(4) }));
}

test "web payload migration and offline route validation are explicit" {
    const allocator = std.testing.allocator;
    for ([_]struct { legacy: []const u8, mode: UrlMode, expected: ?[]const u8 }{
        .{ .legacy = "{\"url\":\"\"}", .mode = .manual, .expected = null },
        .{ .legacy = "{\"url\":null}", .mode = .manual, .expected = null },
        .{ .legacy = "{\"url\":\"example.com/Device\"}", .mode = .preset, .expected = "https://example.com/Device" },
    }) |case| {
        var decoded = try decode(allocator, payload_version, case.legacy);
        defer decoded.deinit();
        try std.testing.expectEqual(case.mode, decoded.content.ready.url_mode);
        if (case.expected) |value| {
            try std.testing.expectEqualStrings(value, decoded.content.ready.start_url.?);
        } else try std.testing.expect(decoded.content.ready.start_url == null);
    }
    try std.testing.expectError(error.UnsupportedPayloadVersion, decode(allocator, payload_version + 1, "opaque future data"));
    try std.testing.expectError(error.MissingUrl, encode(allocator, .{ .url_mode = .preset }));
    try std.testing.expectError(error.MissingSshReference, encode(allocator, .{ .url_mode = .manual, .route = .{ .mode = .ssh } }));
    try std.testing.expectError(error.InvalidSshReference, encode(allocator, .{ .url_mode = .manual, .route = .{ .mode = .ssh, .hop_asset_ids = &.{0} } }));
    try std.testing.expectError(error.DuplicateRoute, encode(allocator, .{ .url_mode = .manual, .route = .{ .mode = .ssh, .hop_asset_ids = &.{ 6, 6 } } }));
    try std.testing.expectError(error.TooManyJumps, encode(allocator, .{ .url_mode = .manual, .route = .{ .mode = .ssh, .hop_asset_ids = &.{ 1, 2, 3, 4, 5, 6, 7, 8, 9 } } }));
}

test "corrupt bookmark values and all over-cap rows survive decode for repair" {
    const allocator = std.testing.allocator;
    var a: std.heap.ArenaAllocator = .init(allocator);
    defer a.deinit();
    const draft = a.allocator();

    var entries: [17]bookmarks.Bookmark = undefined;
    for (&entries, 0..) |*entry, i| entry.* = .{
        .id = .{ .bytes = @splat(@intCast(i + 1)) },
        .title = try std.fmt.allocPrint(draft, "Item {d}", .{i + 1}),
        .url = try std.fmt.allocPrint(draft, "web.test/{d}", .{i + 1}),
    };
    const bytes = try std.json.Stringify.valueAlloc(draft, .{ .url_mode = "manual", .bookmarks = &entries }, .{});
    var over = try decode(allocator, payload_version, bytes);
    defer over.deinit();
    try std.testing.expectEqual(@as(usize, 17), over.content.repair.rows.len);
    try std.testing.expectEqualStrings("Item 17", over.content.repair.rows[16].originalString("title").?);

    const corrupted =
        \\{"url_mode":"manual","bookmarks":[
        \\ {"id":"01010101010101010101010101010101","title":"One","url":"https://web.test/a"},
        \\ {"id":"01010101010101010101010101010101","title":"Two","url":"HTTPS://WEB.TEST:443/a"},
        \\ {"title":"","url":"ftp://invalid.test"},
        \\ 184467440737095516160]}
    ;
    var broken = try decode(allocator, payload_version, corrupted);
    defer broken.deinit();
    const repair = broken.content.repair;
    try std.testing.expectEqual(@as(usize, 4), repair.rows.len);
    for (repair.rows[0..2]) |row| try std.testing.expect(row.issues.duplicate_id and row.issues.duplicate_url);
    try std.testing.expect(repair.rows[2].issues.invalid_id and repair.rows[2].issues.invalid_title and repair.rows[2].issues.invalid_url);
    try std.testing.expectEqualStrings("ftp://invalid.test", repair.rows[2].originalString("url").?);
    try std.testing.expect(repair.rows[3].issues.invalid_record);
    try std.testing.expectEqualStrings("184467440737095516160", repair.rows[3].raw.number_string);
    try std.testing.expectEqual(@as(usize, 3), repair.rows[3].row_id);

    var invalid_container = try decode(allocator, payload_version, "{\"url_mode\":\"manual\",\"bookmarks\":null}");
    defer invalid_container.deinit();
    const invalid_row = invalid_container.content.repair.rows[0];
    try std.testing.expect(invalid_row.issues.invalid_record and invalid_row.raw == .null);

    const original_id = entries[0].id;
    var inputs = [_]bookmarks.RepairInput{
        .{ .id = original_id, .title = "One", .url = "web.test/a" },
        .{ .id = original_id, .title = "Two", .url = "web.test/a" },
        .{ .id = null, .title = "Three", .url = "web.test/c" },
    };
    try std.testing.expectError(error.DuplicateBookmarkUrl, repair.apply(draft, &inputs));
    inputs[1].url = "web.test/b";
    const repaired = try repair.apply(draft, &inputs);
    try std.testing.expect(repaired.bookmarks[0].id.eql(original_id));
    try std.testing.expect(!repaired.bookmarks[1].id.eql(original_id));
    try std.testing.expect(!repaired.bookmarks[1].id.eql(repaired.bookmarks[2].id));
    const fixed_bytes = try encode(draft, repaired);
    var fixed = try decode(allocator, payload_version, fixed_bytes);
    defer fixed.deinit();
    try std.testing.expectEqual(@as(usize, 3), fixed.content.ready.bookmarks.len);
}
