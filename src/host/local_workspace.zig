//! Conversation preference and local directory identity. This is not a grant.
const std = @import("std");

pub const Identity = struct {
    device: u64,
    inode: u64,

    pub fn fromStat(stat: std.c.Stat) Identity {
        const DeviceBits = @Int(.unsigned, @bitSizeOf(@TypeOf(stat.dev)));
        const device: DeviceBits = @bitCast(stat.dev);
        return .{ .device = device, .inode = @intCast(stat.ino) };
    }

    pub fn of(dir: std.Io.Dir) !Identity {
        var stat: std.c.Stat = undefined;
        while (true) {
            switch (std.c.errno(std.c.fstat(dir.handle, &stat))) {
                .SUCCESS => return fromStat(stat),
                .INTR => continue,
                else => return error.DirectoryIdentityUnavailable,
            }
        }
    }
};

pub const Availability = enum { none, ready, unavailable };

pub const Snapshot = struct {
    revision: u64 = 1,
    directory: ?[]const u8 = null,
    resolved_directory: ?[]const u8 = null,
    directory_identity: ?Identity = null,
    availability: Availability = .none,
    reason: ?[]const u8 = null,

    pub fn clone(self: Snapshot, allocator: std.mem.Allocator) !Snapshot {
        var owned = self;
        owned.directory = if (self.directory) |path| try allocator.dupe(u8, path) else null;
        errdefer if (owned.directory) |path| allocator.free(path);
        owned.resolved_directory = if (self.resolved_directory) |path| try allocator.dupe(u8, path) else null;
        errdefer if (owned.resolved_directory) |path| allocator.free(path);
        owned.reason = if (self.reason) |reason| try allocator.dupe(u8, reason) else null;
        return owned;
    }

    pub fn deinit(self: *Snapshot, allocator: std.mem.Allocator) void {
        if (self.directory) |path| allocator.free(path);
        if (self.resolved_directory) |path| allocator.free(path);
        if (self.reason) |reason| allocator.free(reason);
        self.* = .{};
    }

    pub fn validate(self: Snapshot) !void {
        if (self.revision == 0) return error.InvalidWorkspaceSnapshot;
        if (self.directory) |path| try validatePath(path);
        if (self.resolved_directory) |path| try validatePath(path);
        switch (self.availability) {
            .none => if (self.directory != null or self.resolved_directory != null or self.directory_identity != null or self.reason != null) return error.InvalidWorkspaceSnapshot,
            .ready => if (self.directory == null or self.resolved_directory == null or self.directory_identity == null or self.reason != null) return error.InvalidWorkspaceSnapshot,
            .unavailable => if (self.directory == null or self.resolved_directory != null or self.directory_identity == null or self.reason == null or self.reason.?.len == 0 or self.reason.?.len > 128 or !std.unicode.utf8ValidateSlice(self.reason.?)) return error.InvalidWorkspaceSnapshot,
        }
    }

    /// Selected aliases of the same accessible directory are a no-op. For
    /// revalidation, a changed canonical pathname affects the resolved base.
    pub fn sameTarget(self: Snapshot, other: Snapshot) bool {
        return self.availability == other.availability and std.meta.eql(self.directory_identity, other.directory_identity);
    }

    pub fn sameState(self: Snapshot, other: Snapshot) bool {
        return self.sameTarget(other) and sameString(self.directory, other.directory) and sameString(self.resolved_directory, other.resolved_directory) and sameString(self.reason, other.reason);
    }
};

fn sameString(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null or b == null) return a == null and b == null;
    return std.mem.eql(u8, a.?, b.?);
}

fn validatePath(path: []const u8) !void {
    if (path.len >= std.Io.Dir.max_path_bytes or !std.fs.path.isAbsolute(path) or std.mem.indexOfScalar(u8, path, 0) != null or !std.unicode.utf8ValidateSlice(path)) return error.InvalidWorkspaceDirectory;
}

/// The caller owns the returned paths. Directory handles are used only to
/// verify the choice and do not grant subsequent access.
pub fn inspect(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !Snapshot {
    try validatePath(path);
    const opened = try std.Io.Dir.openDirAbsolute(io, path, .{ .iterate = true });
    defer opened.close(io);
    const identity = try Identity.of(opened);
    const canonical = try std.Io.Dir.realPathFileAbsoluteAlloc(io, path, allocator);
    defer allocator.free(canonical);
    try validatePath(canonical);
    const resolved = try std.Io.Dir.openDirAbsolute(io, canonical, .{ .follow_symlinks = false, .iterate = true });
    defer resolved.close(io);
    // Reopening through the held descriptor also checks search permission.
    const accessible = try opened.openDir(io, ".", .{});
    defer accessible.close(io);
    if (!std.meta.eql(identity, try Identity.of(resolved)) or !std.meta.eql(identity, try Identity.of(accessible))) return error.DirectoryIdentityChanged;
    return (Snapshot{
        .directory = path,
        .resolved_directory = canonical,
        .directory_identity = identity,
        .availability = .ready,
    }).clone(allocator);
}

/// A reappearing path must identify the previously selected directory. An
/// explicit selection can adopt a different directory at that pathname.
pub fn recheck(allocator: std.mem.Allocator, io: std.Io, stored: Snapshot) !Snapshot {
    const path = stored.directory orelse return stored.clone(allocator);
    var checked = inspect(allocator, io, path) catch |err| switch (err) {
        error.OutOfMemory, error.Canceled => return err,
        else => return unavailable(allocator, stored, @errorName(err)),
    };
    if (!std.meta.eql(stored.directory_identity, checked.directory_identity)) {
        checked.deinit(allocator);
        return unavailable(allocator, stored, "DirectoryIdentityChanged");
    }
    checked.revision = stored.revision;
    return checked;
}

fn unavailable(allocator: std.mem.Allocator, stored: Snapshot, reason: []const u8) !Snapshot {
    return (Snapshot{
        .revision = stored.revision,
        .directory = stored.directory,
        .directory_identity = stored.directory_identity,
        .availability = .unavailable,
        .reason = reason,
    }).clone(allocator);
}
