//! Saved web bookmarks share the application registry across windows. Perform
//! each mutation against the latest asset on the registry's owning thread.
const std = @import("std");
const hosts = @import("../../config/hosts.zig");
const store = @import("../../config/store.zig");
const identity = hosts.identity;
const config = @import("config.zig");
const bookmarks = @import("bookmarks.zig");

pub const Result = struct {
    asset: identity.AssetOwner,
    bookmark: bookmarks.Id,
    changed: bool,
    cleanup: ?store.CleanupStatus = null,
};

pub fn apply(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    path: []const u8,
    live: *hosts.Registry,
    options: store.CredentialOptions,
    asset: identity.ConnectionId,
    mutation: bookmarks.Mutation,
) !Result {
    const index = live.indexOf(asset) orelse return error.ConnectionNotFound;
    var host = live.hosts[index];
    if (!std.mem.eql(u8, host.protocolId(), config.protocol_id)) return error.UnsupportedProtocol;

    var decoded = try config.decode(allocator, host.payload_version, host.plugin_payload orelse return error.InvalidPayload);
    defer decoded.deinit();
    var payload = switch (decoded.content) {
        .ready => |ready| ready,
        .repair => return error.BookmarkRepairRequired,
    };

    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    const update = switch (try bookmarks.apply(scratch.allocator(), payload.bookmarks, mutation)) {
        .unchanged => |id| return .{ .asset = host.owner(), .bookmark = id, .changed = false },
        .updated => |updated| updated,
    };
    payload.bookmarks = update.items;
    host.plugin_payload = try config.encode(scratch.allocator(), payload);

    var transaction = try store.HostsTransaction.init(allocator, live);
    defer transaction.deinit();
    const owner = try transaction.candidate.?.update(host.owner(), host);
    const cleanup = try transaction.commitWithOptions(io, dir, path, live, options);
    return .{ .asset = owner, .bookmark = update.id, .changed = true, .cleanup = cleanup };
}

const a = std.testing.allocator;
const test_io = std.testing.io;
const test_path = "hosts.toml";

fn fixture(dir: std.Io.Dir, payload: []const u8) !hosts.Registry {
    var seed = try hosts.Registry.parse(a, "");
    defer seed.deinit();
    _ = try seed.add(.{ .name = "Web", .host = "", .user = "", .protocol_id = config.protocol_id, .plugin_payload = payload });
    try store.saveHosts(test_io, dir, test_path, seed);
    return store.loadHosts(test_io, dir, a, test_path);
}

test "web saved bookmarks share revision and do not overwrite newer connection fields" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var live = try fixture(tmp.dir,
        \\{"url_mode":"preset","start_url":"https://initial.example","route":{"mode":"direct","hop_asset_ids":[]},"bookmarks":[]}
    );
    defer live.deinit();
    const original = live.hosts[0].owner();
    const added = try apply(a, test_io, tmp.dir, test_path, &live, .{}, original.id, .{ .add = .{ .url = "https://saved.example", .page_title = "First title" } });
    try std.testing.expect(added.changed);
    try std.testing.expectError(error.RevisionConflict, live.get(original));

    const duplicate = try apply(a, test_io, tmp.dir, test_path, &live, .{}, original.id, .{ .add = .{ .url = "HTTPS://SAVED.EXAMPLE:443/" } });
    try std.testing.expect(!duplicate.changed);
    try std.testing.expectEqual(added.bookmark, duplicate.bookmark);
    try std.testing.expectEqual(added.asset, duplicate.asset);

    var editor = try store.HostsTransaction.init(a, &live);
    defer editor.deinit();
    var renamed = try live.get(added.asset);
    renamed.name = "Renamed";
    _ = try editor.candidate.?.update(added.asset, renamed);
    try editor.commit(test_io, tmp.dir, test_path, &live);

    const edit = try apply(a, test_io, tmp.dir, test_path, &live, .{}, original.id, .{ .edit = .{
        .expected = .{ .id = added.bookmark, .title = "First title", .url = "https://saved.example/" },
        .title = "Updated title",
        .url = "https://different.example/",
    } });
    try std.testing.expectEqual(added.bookmark, edit.bookmark);
    var disk = try store.loadHosts(test_io, tmp.dir, a, test_path);
    defer disk.deinit();
    const host = try disk.get(edit.asset);
    try std.testing.expectEqualStrings("Renamed", host.name);
    var decoded = try config.decode(a, host.payload_version, host.plugin_payload.?);
    defer decoded.deinit();
    try std.testing.expectEqualStrings("https://initial.example/", decoded.content.ready.start_url.?);
    try std.testing.expectEqualStrings("Updated title", decoded.content.ready.bookmarks[0].title);
}

test "web bookmark writes at capacity reject competing stale snapshots without publishing them" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var seed_arena: std.heap.ArenaAllocator = .init(a);
    defer seed_arena.deinit();
    var seed: [bookmarks.max_count - 1]bookmarks.Bookmark = undefined;
    for (&seed, 0..) |*item, i| {
        item.* = .{
            .id = .{ .bytes = @splat(@intCast(i + 1)) },
            .title = "Saved page",
            .url = try std.fmt.allocPrint(seed_arena.allocator(), "https://saved.example/{d}", .{i}),
        };
    }
    const initial = try config.encode(seed_arena.allocator(), .{ .url_mode = .manual, .bookmarks = &seed });
    var live = try fixture(tmp.dir, initial);
    defer live.deinit();
    var stale = try live.clone(a);
    defer stale.deinit();

    const owner = live.hosts[0].owner();
    const original_hash = live.source_hash.?;
    const committed = try apply(a, test_io, tmp.dir, test_path, &live, .{}, owner.id, .{ .add = .{ .url = "https://first.example" } });
    try std.testing.expect(committed.changed);
    const second: bookmarks.Mutation = .{ .add = .{ .url = "https://second.example" } };
    try std.testing.expectError(error.BookmarkCapacity, apply(a, test_io, tmp.dir, test_path, &live, .{}, owner.id, second));
    try std.testing.expectError(error.FileConflict, apply(a, test_io, tmp.dir, test_path, &stale, .{}, owner.id, second));
    try std.testing.expectEqual(owner, stale.hosts[0].owner());
    try std.testing.expectEqual(original_hash, stale.source_hash.?);

    var disk = try store.loadHosts(test_io, tmp.dir, a, test_path);
    defer disk.deinit();
    const host = try disk.get(committed.asset);
    var decoded = try config.decode(a, host.payload_version, host.plugin_payload.?);
    defer decoded.deinit();
    try std.testing.expectEqual(@as(usize, bookmarks.max_count), decoded.content.ready.bookmarks.len);
    try std.testing.expectEqualStrings("https://first.example/", decoded.content.ready.bookmarks[bookmarks.max_count - 1].url);
}
