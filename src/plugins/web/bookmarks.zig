//! Bookmark validation and mutations over the latest saved or temporary payload.
//! Callers own the revision transaction and pass an arena for candidate values.
const std = @import("std");
const urls = @import("urls.zig");

pub const max_count = 16;

pub const Id = struct {
    bytes: [16]u8,

    pub fn parse(text: []const u8) !Id {
        var result: Id = undefined;
        if (text.len != result.bytes.len * 2) return error.InvalidBookmarkId;
        _ = std.fmt.hexToBytes(&result.bytes, text) catch return error.InvalidBookmarkId;
        if (!result.valid()) return error.InvalidBookmarkId;
        return result;
    }

    pub fn valid(self: Id) bool {
        return !std.mem.allEqual(u8, &self.bytes, 0);
    }

    pub fn eql(self: Id, other: Id) bool {
        return std.mem.eql(u8, &self.bytes, &other.bytes);
    }

    pub fn jsonStringify(self: Id, writer: anytype) !void {
        const text = std.fmt.bytesToHex(self.bytes, .lower);
        try writer.write(@as([]const u8, &text));
    }
};

pub const Bookmark = struct { id: Id, title: []const u8, url: []const u8 };

pub const Issues = struct {
    invalid_record: bool = false,
    invalid_id: bool = false,
    invalid_title: bool = false,
    invalid_url: bool = false,
    duplicate_id: bool = false,
    duplicate_url: bool = false,
};

pub const RepairRow = struct {
    row_id: usize,
    raw: std.json.Value,
    issues: Issues = .{},

    pub fn originalString(self: RepairRow, key: []const u8) ?[]const u8 {
        if (self.raw != .object) return null;
        const field = self.raw.object.get(key) orelse return null;
        return if (field == .string) field.string else null;
    }
};

pub const Decoded = union(enum) {
    ready: []const Bookmark,
    repair: []const RepairRow,
};

/// The known payload is parseable, but bookmark items may have arbitrary JSON
/// shapes. Keep their complete JSON values and stable draft row IDs for repair.
pub fn decode(allocator: std.mem.Allocator, raw: std.json.Value) !Decoded {
    if (raw != .array) {
        const row = try allocator.alloc(RepairRow, 1);
        row[0] = .{ .row_id = 0, .raw = raw, .issues = .{ .invalid_record = true } };
        return .{ .repair = row };
    }
    const values = raw.array.items;
    if (values.len == 0) return .{ .ready = &.{} };
    const rows = try allocator.alloc(RepairRow, values.len);
    const bookmarks = try allocator.alloc(Bookmark, values.len);
    var ids: std.AutoHashMapUnmanaged(Id, usize) = .empty;
    defer ids.deinit(allocator);
    var addresses: std.StringHashMapUnmanaged(usize) = .empty;
    defer addresses.deinit(allocator);
    var needs_repair = values.len > max_count;
    for (values, rows, bookmarks, 0..) |value, *row, *bookmark, i| {
        row.* = .{ .row_id = i, .raw = value };
        row.issues.invalid_record = value != .object or value.object.count() != 3;
        const id = if (row.originalString("id")) |text| Id.parse(text) catch null else null;
        const title = if (row.originalString("title")) |text| validTitle(text) catch null else null;
        const url = if (row.originalString("url")) |text| urls.normalize(allocator, text) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => null,
        } else null;

        row.issues.invalid_id = id == null;
        row.issues.invalid_title = title == null;
        row.issues.invalid_url = url == null;
        if (id) |key| {
            const entry = try ids.getOrPut(allocator, key);
            if (entry.found_existing) {
                row.issues.duplicate_id = true;
                rows[entry.value_ptr.*].issues.duplicate_id = true;
            } else entry.value_ptr.* = i;
        }
        if (url) |address| {
            const entry = try addresses.getOrPut(allocator, address.text);
            if (entry.found_existing) {
                row.issues.duplicate_url = true;
                rows[entry.value_ptr.*].issues.duplicate_url = true;
            } else entry.value_ptr.* = i;
        }
        if (!std.meta.eql(row.issues, Issues{})) needs_repair = true;
        if (id != null and title != null and url != null) bookmark.* = .{ .id = id.?, .title = title.?, .url = url.?.text };
    }
    return if (needs_repair) .{ .repair = rows } else .{ .ready = bookmarks };
}

pub const RepairInput = struct {
    id: ?Id,
    title: []const u8,
    url: []const u8,
};

/// Only rows the user chose to keep are submitted. A missing, malformed or
/// repeated ID gets a fresh ID, while a unique valid ID is kept.
pub fn applyRepair(allocator: std.mem.Allocator, inputs: []const RepairInput) ![]const Bookmark {
    if (inputs.len > max_count) return error.BookmarkCapacity;
    const result = try allocator.alloc(Bookmark, inputs.len);
    for (inputs, result, 0..) |input, *entry, i| {
        const title = try allocator.dupe(u8, try validTitle(input.title));
        const url = try urls.normalize(allocator, input.url);
        if (findUrl(result[0..i], url.text) != null) return error.DuplicateBookmarkUrl;
        const id = if (input.id) |id|
            if (id.valid() and findId(result[0..i], id) == null) id else freshId(result[0..i], inputs)
        else
            freshId(result[0..i], inputs);
        entry.* = .{ .id = id, .title = title, .url = url.text };
    }
    return result;
}

pub fn normalizeList(allocator: std.mem.Allocator, items: []const Bookmark) ![]const Bookmark {
    if (items.len > max_count) return error.BookmarkCapacity;
    const result = try allocator.alloc(Bookmark, items.len);
    for (items, result, 0..) |item, *entry, i| {
        if (!item.id.valid()) return error.InvalidBookmarkId;
        if (findId(result[0..i], item.id) != null) return error.DuplicateBookmarkId;
        const title = try allocator.dupe(u8, try validTitle(item.title));
        const url = try urls.normalize(allocator, item.url);
        if (findUrl(result[0..i], url.text) != null) return error.DuplicateBookmarkUrl;
        entry.* = .{ .id = item.id, .title = title, .url = url.text };
    }
    return result;
}

pub const Mutation = union(enum) {
    add: struct { url: []const u8, page_title: ?[]const u8 = null },
    edit: struct { expected: Bookmark, title: []const u8, url: []const u8 },
    remove: Id,
};

pub const Result = union(enum) {
    unchanged: Id,
    updated: struct { items: []const Bookmark, id: Id },
};

/// Apply within an asset owner's latest-revision write, never to a stale
/// toolbar snapshot. `current` is a validated, canonical bookmark list.
/// Only publish `updated` after a saved asset's commit succeeds.
pub fn apply(allocator: std.mem.Allocator, current: []const Bookmark, mutation: Mutation) !Result {
    switch (mutation) {
        .add => |add| {
            const url = try urls.normalize(allocator, add.url);
            errdefer url.deinit(allocator);
            if (findUrl(current, url.text)) |index| {
                url.deinit(allocator);
                return .{ .unchanged = current[index].id };
            }
            if (current.len >= max_count) return error.BookmarkCapacity;
            const title = if (add.page_title) |title| validTitle(title) catch url.host() else url.host();
            const id = freshId(current, &.{});
            const next = try allocator.alloc(Bookmark, current.len + 1);
            for (current, next[0..current.len]) |entry, *out| out.* = try clone(allocator, entry);
            next[current.len] = .{ .id = id, .title = try allocator.dupe(u8, title), .url = url.text };
            return .{ .updated = .{ .id = id, .items = next } };
        },
        .edit => |edit| {
            const index = findId(current, edit.expected.id) orelse return error.BookmarkNotFound;
            const existing = current[index];
            if (!sameText(existing, edit.expected)) return error.BookmarkConflict;
            const title = try validTitle(edit.title);
            const url = try urls.normalize(allocator, edit.url);
            defer url.deinit(allocator);
            if (findUrl(current, url.text)) |other| {
                if (other != index) return error.DuplicateBookmarkUrl;
            }
            const updated: Bookmark = .{ .id = existing.id, .title = title, .url = url.text };
            if (sameText(existing, updated)) return .{ .unchanged = existing.id };
            const next = try allocator.alloc(Bookmark, current.len);
            for (current, next, 0..) |entry, *out, i| {
                out.* = try clone(allocator, if (i == index) updated else entry);
            }
            return .{ .updated = .{ .id = existing.id, .items = next } };
        },
        .remove => |id| {
            const index = findId(current, id) orelse return error.BookmarkNotFound;
            const next = try allocator.alloc(Bookmark, current.len - 1);
            for (current[0..index], next[0..index]) |entry, *out| out.* = try clone(allocator, entry);
            for (current[index + 1 ..], next[index..]) |entry, *out| out.* = try clone(allocator, entry);
            return .{ .updated = .{ .id = id, .items = next } };
        },
    }
}

fn validTitle(title: []const u8) ![]const u8 {
    const trimmed = std.mem.trim(u8, title, " ");
    if (trimmed.len == 0) return error.InvalidBookmarkTitle;
    const view = std.unicode.Utf8View.init(trimmed) catch return error.InvalidBookmarkTitle;
    var it = view.iterator();
    while (it.nextCodepoint()) |codepoint| switch (codepoint) {
        0...0x1f, 0x7f...0x9f, 0x2028, 0x2029 => return error.InvalidBookmarkTitle,
        else => {},
    };
    return trimmed;
}

fn sameText(a: Bookmark, b: Bookmark) bool {
    return std.mem.eql(u8, a.title, b.title) and std.mem.eql(u8, a.url, b.url);
}

fn clone(allocator: std.mem.Allocator, bookmark: Bookmark) !Bookmark {
    return .{ .id = bookmark.id, .title = try allocator.dupe(u8, bookmark.title), .url = try allocator.dupe(u8, bookmark.url) };
}

fn findId(items: []const Bookmark, id: Id) ?usize {
    for (items, 0..) |entry, i| if (entry.id.eql(id)) return i;
    return null;
}

fn findUrl(items: []const Bookmark, canonical: []const u8) ?usize {
    for (items, 0..) |entry, i| if (std.mem.eql(u8, entry.url, canonical)) return i;
    return null;
}

fn freshId(items: []const Bookmark, reserved: []const RepairInput) Id {
    while (true) {
        var id: Id = undefined;
        std.c.arc4random_buf(&id.bytes, id.bytes.len);
        if (!id.valid() or findId(items, id) != null) continue;
        for (reserved) |row| {
            if (row.id) |existing| {
                if (id.eql(existing)) break;
            }
        } else return id;
    }
}

test "bookmark requests use the latest list at the 15/16/17 boundary" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var current: []const Bookmark = &.{};
    for (0..max_count - 1) |i| {
        const url = try std.fmt.allocPrint(a, "web.test/{d}", .{i});
        current = (try apply(a, current, .{ .add = .{ .url = url } })).updated.items;
    }
    const winner = try apply(a, current, .{ .add = .{ .url = "HTTPS://WEB.TEST:443/16", .page_title = "Page 16" } });
    current = winner.updated.items;
    try std.testing.expectEqual(max_count, current.len);
    const same = try apply(a, current, .{ .add = .{ .url = "web.test/16" } });
    try std.testing.expect(winner.updated.id.eql(same.unchanged));
    try std.testing.expectError(error.BookmarkCapacity, apply(a, current, .{ .add = .{ .url = "web.test/17" } }));
    try std.testing.expectEqualStrings("Page 16", current[15].title);
    current = (try apply(a, current, .{ .remove = current[0].id })).updated.items;
    current = (try apply(a, current, .{ .add = .{ .url = "web.test/17" } })).updated.items;
    try std.testing.expectEqual(max_count, current.len);
    try std.testing.expectEqualStrings("web.test", current[15].title);
}

test "stable IDs preserve edit target across removal and detect stale fields" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const first = try apply(a, &.{}, .{ .add = .{ .url = "bookmarks.test/one" } });
    const second = try apply(a, first.updated.items, .{ .add = .{ .url = "bookmarks.test/two" } });
    const snapshot = second.updated.items[1];
    const after_remove = try apply(a, second.updated.items, .{ .remove = first.updated.id });
    const edit: Mutation = .{ .edit = .{ .expected = snapshot, .title = "Second", .url = "bookmarks.test/two" } };
    const result = try apply(a, after_remove.updated.items, edit);
    try std.testing.expectEqualStrings("Second", result.updated.items[0].title);
    try std.testing.expect(snapshot.id.eql(result.updated.id));
    try std.testing.expectError(error.BookmarkConflict, apply(a, result.updated.items, edit));
    try std.testing.expectError(error.BookmarkNotFound, apply(a, &.{}, edit));

    var duplicate = edit;
    duplicate.edit.url = "HTTPS://BOOKMARKS.TEST:443/one";
    try std.testing.expectError(error.DuplicateBookmarkUrl, apply(a, second.updated.items, duplicate));
}
