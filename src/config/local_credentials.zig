const std = @import("std");
const Io = std.Io;

pub const dirname = "credentials";
const selected_marker = ".local-storage";
const private_dir: Io.File.Permissions = @fromBackingInt(0o700);
const private_file: Io.File.Permissions = @fromBackingInt(0o600);
const max_bytes = 8 * 1024 * 1024;
const permission_bits = 0o7777;

io: Io,
directory: []const u8,

const Store = @This();

fn open(self: Store, create: bool) !Io.Dir {
    var data = try Io.Dir.openDirAbsolute(self.io, self.directory, .{ .follow_symlinks = false });
    defer data.close(self.io);
    if (create) data.createDir(self.io, dirname, private_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    var dir = try data.openDir(self.io, dirname, .{ .iterate = true, .follow_symlinks = false });
    errdefer dir.close(self.io);
    if (@backingInt((try dir.stat(self.io)).permissions) & permission_bits != 0o700) return error.CredentialDenied;
    return dir;
}

pub fn get(self: Store, allocator: std.mem.Allocator, reference: []const u8) ![]u8 {
    var dir = self.open(false) catch |err| switch (err) {
        error.FileNotFound => return error.CredentialMissing,
        else => return err,
    };
    defer dir.close(self.io);
    const entry = dir.statFile(self.io, reference, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return error.CredentialMissing,
        else => return err,
    };
    if (entry.kind != .file or entry.nlink != 1 or @backingInt(entry.permissions) & permission_bits != 0o600) return error.CredentialDenied;
    const file = dir.openFile(self.io, reference, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return error.CredentialMissing,
        else => return err,
    };
    defer file.close(self.io);
    const stat = try file.stat(self.io);
    if (stat.inode != entry.inode or stat.kind != .file or stat.nlink != 1 or @backingInt(stat.permissions) & permission_bits != 0o600) return error.CredentialDenied;
    if (stat.size > max_bytes) return error.CredentialLimitExceeded;
    const bytes = try allocator.alloc(u8, @intCast(stat.size));
    errdefer {
        std.crypto.secureZero(u8, bytes);
        allocator.free(bytes);
    }
    if (try file.readPositionalAll(self.io, bytes, 0) != bytes.len) return error.CredentialStorageFailure;
    return bytes;
}

pub fn isSelected(self: Store) !bool {
    const marker = self.get(std.heap.page_allocator, selected_marker) catch |err| switch (err) {
        error.CredentialMissing => return false,
        else => return err,
    };
    defer std.heap.page_allocator.free(marker);
    if (!std.mem.eql(u8, marker, "1")) return error.CredentialStorageFailure;
    return true;
}

pub fn select(self: Store) !void {
    try self.add(selected_marker, "1");
}

/// Once the marker is removed the active store is Keychain. Local data may
/// only be deleted after the directory entry has been synced.
pub fn deselect(self: Store) !bool {
    var dir = try self.open(false);
    defer dir.close(self.io);
    try dir.deleteFile(self.io, selected_marker);
    return std.c.fsync(dir.handle) == 0;
}

pub fn references(self: Store, allocator: std.mem.Allocator, comptime valid: fn ([]const u8) bool) ![][68]u8 {
    var dir = try self.open(false);
    defer dir.close(self.io);
    var refs: std.ArrayList([68]u8) = .empty;
    errdefer refs.deinit(allocator);
    var entries = dir.iterate();
    while (try entries.next(self.io)) |entry| {
        if (!valid(entry.name)) continue;
        if (refs.items.len == 16384) return error.CredentialLimitExceeded;
        try refs.append(allocator, entry.name[0..68].*);
    }
    return refs.toOwnedSlice(allocator);
}

pub fn importValue(self: Store, reference: []const u8, value: []const u8) !void {
    self.add(reference, value) catch |err| switch (err) {
        error.CredentialAlreadyExists => {
            const existing = try self.get(std.heap.page_allocator, reference);
            defer {
                std.crypto.secureZero(u8, existing);
                std.heap.page_allocator.free(existing);
            }
            if (!std.mem.eql(u8, existing, value)) return error.CredentialStorageFailure;
        },
        else => return err,
    };
}

pub fn add(self: Store, reference: []const u8, value: []const u8) !void {
    if (value.len > max_bytes) return error.CredentialLimitExceeded;
    var dir = try self.open(true);
    defer dir.close(self.io);
    var pending = try dir.createFileAtomic(self.io, reference, .{ .permissions = private_file });
    defer pending.deinit(self.io);
    try pending.file.writeStreamingAll(self.io, value);
    try pending.file.sync(self.io);
    pending.link(self.io) catch |err| switch (err) {
        error.PathAlreadyExists => return error.CredentialAlreadyExists,
        else => return err,
    };
}

pub fn remove(self: Store, reference: []const u8) !void {
    var dir = self.open(false) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer dir.close(self.io);
    try delete(dir, self.io, reference);
}

pub fn collect(self: Store, keep: []const []const u8, comptime validReference: fn ([]const u8) bool) !void {
    var dir = self.open(false) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer dir.close(self.io);
    var entries = dir.iterate();
    while (try entries.next(self.io)) |entry| {
        if (!validReference(entry.name)) continue;
        for (keep) |reference| {
            if (std.mem.eql(u8, reference, entry.name)) break;
        } else try delete(dir, self.io, entry.name);
    }
}

fn delete(dir: Io.Dir, io: Io, reference: []const u8) !void {
    dir.deleteFile(io, reference) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}

test "local credentials persist across opens and reject non-private storage" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(path);
    const store: Store = .{ .io = io, .directory = path };
    try std.testing.expect(!try store.isSelected());
    try std.testing.expectError(error.CredentialMissing, store.get(allocator, "first"));
    try store.add("first", "fixture value");
    try std.testing.expectError(error.CredentialAlreadyExists, store.add("first", "replacement"));
    try store.importValue("first", "fixture value");
    try std.testing.expectError(error.CredentialStorageFailure, store.importValue("first", "different"));
    try std.testing.expect(!try store.isSelected());
    try store.select();
    try std.testing.expect(try store.isSelected());
    try std.testing.expect(try store.deselect());
    try std.testing.expect(!try store.isSelected());
    const secret = try store.get(allocator, "first");
    defer allocator.free(secret);
    try std.testing.expectEqualStrings("fixture value", secret);
    var dir = try store.open(false);
    defer dir.close(io);
    try std.testing.expectEqual(@as(u32, 0o600), @backingInt((try dir.statFile(io, "first", .{})).permissions) & permission_bits);
    try dir.symLink(io, "first", "alias", .{});
    try std.testing.expectError(error.CredentialDenied, store.get(allocator, "alias"));
    try dir.setFilePermissions(io, "first", @fromBackingInt(0o644), .{});
    try std.testing.expectError(error.CredentialDenied, store.get(allocator, "first"));
    try store.remove("first");
    try store.remove("first");
    try std.testing.expectError(error.CredentialMissing, store.get(allocator, "first"));
}
