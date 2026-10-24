//! Local quick creation payload. It never creates or mutates an AssetStore record.
const std = @import("std");
const sessions = @import("../../host/session_host.zig");
pub const Quick = struct { initial_cwd: ?[]const u8 = null };
pub fn decode(allocator: std.mem.Allocator, payload: []const u8) !Quick {
    const value = try std.json.parseFromSliceLeaky(Quick, allocator, payload, .{ .allocate = .alloc_always });
    try (sessions.SessionCreateSpec{ .local = .{ .initial_cwd = value.initial_cwd } }).validate();
    return value;
}
pub fn validate(payload: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    _ = try decode(arena.allocator(), payload);
}

/// New sessions deliberately start in the account home, independent of the
/// original process' launch or current directory.
pub fn newSessionPayload(allocator: std.mem.Allocator, original_payload: []const u8) ![]u8 {
    _ = original_payload;
    const home = try initialDirectory(allocator, null);
    defer allocator.free(home);
    return std.json.Stringify.valueAlloc(allocator, Quick{ .initial_cwd = home }, .{});
}
pub fn initialDirectory(allocator: std.mem.Allocator, requested: ?[]const u8) ![]u8 {
    if (requested) |cwd| {
        try (sessions.SessionCreateSpec{ .local = .{ .initial_cwd = cwd } }).validate();
        return allocator.dupe(u8, cwd);
    }
    const home = try @import("../../platform/account.zig").home(allocator);
    errdefer allocator.free(home);
    try (sessions.SessionCreateSpec{ .local = .{ .initial_cwd = home } }).validate();
    return home;
}
test "Local new session payload freezes account home instead of original cwd" {
    const allocator = std.testing.allocator;
    const payload = try newSessionPayload(allocator, "{\"initial_cwd\":\"/tmp\"}");
    defer allocator.free(payload);
    const home = try initialDirectory(allocator, null);
    defer allocator.free(home);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const value = try decode(arena.allocator(), payload);
    try std.testing.expectEqualStrings(home, value.initial_cwd.?);
}

pub fn encodeCreationPayload(allocator: std.mem.Allocator, requested: ?[]const u8) ![]u8 {
    const cwd = try initialDirectory(allocator, requested);
    defer allocator.free(cwd);
    return std.json.Stringify.valueAlloc(allocator, Quick{ .initial_cwd = cwd }, .{});
}

test "Local initial directory freezes an absolute requested path or account home" {
    const allocator = std.testing.allocator;
    var requested = [_]u8{ '/', 't', 'm', 'p' };
    const explicit = try initialDirectory(allocator, &requested);
    defer allocator.free(explicit);
    requested[1] = 'x';
    try std.testing.expectEqualStrings("/tmp", explicit);
    try std.testing.expectError(error.InvalidDirectory, initialDirectory(allocator, "relative"));
    try std.testing.expectError(error.InvalidDirectory, initialDirectory(allocator, "/bad\x00path"));
    const home = try initialDirectory(allocator, null);
    defer allocator.free(home);
    try std.testing.expect(home.len > 0 and home[0] == '/');
    try (sessions.SessionCreateSpec{ .local = .{ .initial_cwd = home } }).validate();
}
