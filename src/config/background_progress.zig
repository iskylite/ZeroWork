//! Durable cursor for committed directory backgrounds, separate from settings.
const std = @import("std");
const Playlist = @import("background_playlist.zig").Playlist;

pub const filename = "background-rotation.json";
const max_bytes = 4 * 1024 * 1024;
const Snapshot = struct {
    version: u8 = 1,
    directory: []const u8,
    random: bool,
    index: usize,
    paths: []const []const u8,
};

pub fn save(io: std.Io, dir: std.Io.Dir, allocator: std.mem.Allocator, directory: []const u8, list: *const Playlist) !void {
    if (list.paths.items.len == 0 or list.index >= list.paths.items.len) return error.InvalidBackgroundProgress;
    const bytes = try std.json.Stringify.valueAlloc(allocator, Snapshot{ .directory = directory, .random = list.random, .index = list.index, .paths = list.paths.items }, .{});
    defer allocator.free(bytes);
    if (bytes.len > max_bytes) return error.BackgroundProgressTooLarge;
    var atomic = try dir.createFileAtomic(io, filename, .{ .permissions = @fromBackingInt(0o600), .replace = true });
    defer atomic.deinit(io);
    var buffer: [4096]u8 = undefined;
    var writer = atomic.file.writer(io, &buffer);
    try writer.interface.writeAll(bytes);
    try writer.interface.flush();
    try atomic.file.sync(io);
    try atomic.replace(io);
}

/// Reconcile against the freshly scanned paths. Never open paths supplied by
/// the state file. Missing entries are skipped; new files join the current round.
pub fn restore(io: std.Io, dir: std.Io.Dir, allocator: std.mem.Allocator, directory: []const u8, list: *Playlist) !void {
    const bytes = try dir.readFileAlloc(io, filename, allocator, .limited(max_bytes));
    defer allocator.free(bytes);
    const parsed = try std.json.parseFromSlice(Snapshot, allocator, bytes, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    const saved = parsed.value;
    if (saved.version != 1 or saved.index >= saved.paths.len or saved.random != list.random or !std.mem.eql(u8, directory, saved.directory)) return;
    var remaining: std.StringHashMap(void) = .init(allocator);
    defer remaining.deinit();
    for (list.paths.items) |path| try remaining.put(path, {});
    var resumed: Playlist = .{ .random = list.random, .prng = list.prng };
    defer resumed.deinit(allocator);
    for (saved.paths, 0..) |path, i| {
        if (i == saved.index) resumed.index = resumed.paths.items.len;
        if (remaining.fetchRemove(path)) |entry| try resumed.append(allocator, entry.key);
    }
    for (list.paths.items) |path| if (remaining.contains(path)) try resumed.append(allocator, path);
    if (resumed.paths.items.len == 0) return;
    if (resumed.index >= resumed.paths.items.len) resumed.index = 0;
    if (!resumed.random) {
        const current = resumed.paths.items[resumed.index];
        resumed.sort();
        for (resumed.paths.items, 0..) |path, i| if (path.ptr == current.ptr) {
            resumed.index = i;
            break;
        };
    }
    std.mem.swap(Playlist, list, &resumed);
}
