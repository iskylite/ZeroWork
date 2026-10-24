//! Plain UTF-8 terminal exports. The caller captures the selected/retained VT
//! text before opening a modal dialog, so later terminal output cannot change it.
const std = @import("std");

/// Replace only after the entire snapshot is written successfully. A failed
/// write leaves an existing export untouched; no ANSI or HTML conversion is
/// applied to the already formatted VT text.
pub fn writeSnapshot(io: std.Io, dir: std.Io.Dir, path: []const u8, text: []const u8) !void {
    if (path.len == 0) return error.EmptyPath;
    var atomic = try dir.createFileAtomic(io, path, .{
        .permissions = @as(std.Io.File.Permissions, @fromBackingInt(@intCast(0o600))),
        .replace = true,
    });
    defer atomic.deinit(io);
    var buffer: [4096]u8 = undefined;
    var writer = atomic.file.writer(io, &buffer);
    try writer.interface.writeAll(text);
    try writer.interface.flush();
    try atomic.replace(io);
}

test "terminal export writes exact UTF-8 snapshot and replaces previous file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const text = "服务器日志\nspace  preserved\n\t└─测试\n";
    try writeSnapshot(std.testing.io, tmp.dir, "session.txt", "old");
    try writeSnapshot(std.testing.io, tmp.dir, "session.txt", text);
    const actual = try tmp.dir.readFileAlloc(std.testing.io, "session.txt", std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(actual);
    try std.testing.expectEqualStrings(text, actual);
}

test "failed export does not replace existing destination or create missing directories" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeSnapshot(std.testing.io, tmp.dir, "existing.txt", "keep");
    try std.testing.expectError(error.FileNotFound, writeSnapshot(std.testing.io, tmp.dir, "absent/session.txt", "new"));
    try std.testing.expectError(error.EmptyPath, writeSnapshot(std.testing.io, tmp.dir, "", "new"));
    const actual = try tmp.dir.readFileAlloc(std.testing.io, "existing.txt", std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(actual);
    try std.testing.expectEqualStrings("keep", actual);
}
