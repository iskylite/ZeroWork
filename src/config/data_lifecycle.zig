//! Application-owned filesystem lifecycle. Call prepare before opening stores
//! or logs. Stop writers, beginReset, erase Keychain, then eraseOwned.
const std = @import("std");
const Paths = @import("paths.zig").Paths;
const Dir = std.Io.Dir;
const private_dir: std.Io.File.Permissions = @fromBackingInt(0o700);
const private_file: std.Io.File.Permissions = @fromBackingInt(0o600);

pub const PrepareReport = struct {
    migrated_legacy: bool = false,
    moved_diagnostic_files: usize = 0,
};

pub const Area = enum { data, cache, diagnostic, legacy };
pub const EraseItem = struct { area: Area, failure: ?anyerror = null };
pub const EraseReport = struct {
    items: [4]EraseItem = undefined,
    count: usize = 0,

    pub fn succeeded(self: EraseReport) bool {
        for (self.items[0..self.count]) |item| if (item.failure != null) return false;
        return true;
    }
};

/// Validate every deletion target against its Paths constructor and protect
/// the live account root, rather than accepting arbitrary injected fields.
pub fn validate(paths: *const Paths) !void {
    if (paths.is_override) {
        const account = try @import("../platform/account.zig").home(paths.allocator);
        defer paths.allocator.free(account);
        {
            if (std.mem.eql(u8, paths.directory, account) or (std.mem.startsWith(u8, account, paths.directory) and account.len > paths.directory.len and account[paths.directory.len] == '/')) return error.InvalidOwnedPaths;
            if (std.mem.startsWith(u8, paths.directory, account)) {
                const tail = paths.directory[account.len..];
                for ([_][]const u8{ "/Library", "/Library/Application Support", "/Library/Caches", "/Library/Logs", "/Desktop", "/Documents", "/Downloads", "/Pictures", "/Music", "/Movies", "/Public" }) |protected| {
                    if (std.mem.eql(u8, tail, protected)) return error.InvalidOwnedPaths;
                }
            }
        }
    }
    var expected = if (paths.is_override)
        try Paths.fromDirectory(paths.allocator, paths.directory)
    else
        try Paths.fromHome(paths.allocator, paths.home_directory orelse return error.InvalidOwnedPaths);
    defer expected.deinit();
    inline for (.{ "directory", "config", "hosts", "known_hosts", "cache_directory", "diagnostic_directory" }) |field| {
        if (!std.mem.eql(u8, @field(paths, field), @field(expected, field))) return error.InvalidOwnedPaths;
    }
    if (!optionalEqual(paths.legacy_directory, expected.legacy_directory)) return error.InvalidOwnedPaths;
    if (paths.is_override and paths.home_directory != null) return error.InvalidOwnedPaths;
}

fn optionalEqual(a: ?[]const u8, b: ?[]const u8) bool {
    if (a) |value| return b != null and std.mem.eql(u8, value, b.?);
    return b == null;
}

/// Directory handles anchor every component; a symlink in a parent or at the
/// owned root is rejected. Newly created ancestors use ordinary directory
/// permissions; only our own root/tree is tightened to 0700/0600.
fn openAbsolute(io: std.Io, path: []const u8, create: bool) !Dir {
    var current = try Dir.openDirAbsolute(io, "/", .{ .iterate = true, .follow_symlinks = false });
    errdefer current.close(io);
    var parts = std.mem.tokenizeScalar(u8, path, '/');
    while (parts.next()) |part| {
        const stat = current.statFile(io, part, .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound => blk: {
                if (!create) return err;
                current.createDir(io, part, .default_dir) catch |mkdir_err| switch (mkdir_err) {
                    error.PathAlreadyExists => {},
                    else => return mkdir_err,
                };
                break :blk try current.statFile(io, part, .{ .follow_symlinks = false });
            },
            else => return err,
        };
        if (stat.kind == .sym_link) return error.UnsafeSymlink;
        if (stat.kind != .directory) return error.NotDir;
        const next = try current.openDir(io, part, .{ .iterate = true, .follow_symlinks = false });
        current.close(io);
        current = next;
    }
    return current;
}

fn openParent(io: std.Io, path: []const u8, create: bool) !Dir {
    return openAbsolute(io, std.fs.path.dirname(path) orelse return error.InvalidOwnedPaths, create);
}

fn kind(dir: Dir, io: std.Io, name: []const u8) !?std.Io.File.Kind {
    const result = dir.statFile(io, name, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    return result.kind;
}

/// Preflight the complete source before changing its location. Unknown regular
/// files are retained verbatim, including unknown TOML keys. Hardlinks are
/// rejected so chmod/migration cannot affect an external inode.
fn secureTree(io: std.Io, dir: Dir) anyerror!void {
    try dir.setPermissions(io, private_dir);
    var iterator = dir.iterate();
    while (try iterator.next(io)) |entry| {
        const stat = try dir.statFile(io, entry.name, .{ .follow_symlinks = false });
        switch (stat.kind) {
            .directory => {
                var child = try dir.openDir(io, entry.name, .{ .iterate = true, .follow_symlinks = false });
                defer child.close(io);
                try secureTree(io, child);
            },
            .file => {
                if (stat.nlink != 1) return error.UnsafeHardlink;
                const file = try dir.openFile(io, entry.name, .{ .follow_symlinks = false });
                defer file.close(io);
                const opened = try file.stat(io);
                if (opened.kind != .file or opened.nlink != 1 or opened.inode != stat.inode) return error.UnsafeFile;
                try file.setPermissions(io, private_file);
            },
            .sym_link => return error.UnsafeSymlink,
            else => return error.UnsupportedFileKind,
        }
    }
}

fn equalFiles(io: std.Io, source: Dir, target: Dir, name: []const u8) !bool {
    const a = try source.openFile(io, name, .{ .follow_symlinks = false });
    defer a.close(io);
    const b = try target.openFile(io, name, .{ .follow_symlinks = false });
    defer b.close(io);
    if ((try a.stat(io)).size != (try b.stat(io)).size) return false;
    var a_buffer: [16384]u8 = undefined;
    var b_buffer: [16384]u8 = undefined;
    var offset: u64 = 0;
    while (true) {
        const n = try a.readPositionalAll(io, &a_buffer, offset);
        const m = try b.readPositionalAll(io, &b_buffer, offset);
        if (n != m or !std.mem.eql(u8, a_buffer[0..n], b_buffer[0..m])) return false;
        if (n == 0) return true;
        offset += n;
    }
}

/// Each move uses the OS atomic non-replacing rename. A later failure leaves
/// earlier moves in the destination, and retries resume without duplicating
/// secrets or overwriting newer state. Conflicting originals remain recoverable.
fn merge(io: std.Io, source: Dir, target: Dir) anyerror!void {
    var iterator = source.iterate();
    while (try iterator.next(io)) |entry| {
        const source_kind = (try kind(source, io, entry.name)) orelse continue;
        const target_kind = try kind(target, io, entry.name);
        if (target_kind == null) {
            try source.renamePreserve(entry.name, target, entry.name, io);
        } else if (source_kind == .directory and target_kind.? == .directory) {
            var a = try source.openDir(io, entry.name, .{ .iterate = true, .follow_symlinks = false });
            defer a.close(io);
            var b = try target.openDir(io, entry.name, .{ .iterate = true, .follow_symlinks = false });
            defer b.close(io);
            try merge(io, a, b);
            try source.deleteDir(io, entry.name);
        } else if (source_kind == .file and target_kind.? == .file and try equalFiles(io, source, target, entry.name)) {
            try source.deleteFile(io, entry.name);
        } else return error.LegacyConflict;
    }
}

fn ensurePrivate(io: std.Io, path: []const u8) !Dir {
    var dir = try openAbsolute(io, path, true);
    errdefer dir.close(io);
    try dir.setPermissions(io, private_dir);
    return dir;
}

/// Establish the durable recovery gate before deleting any Keychain item.
/// Callers must not begin credential erasure unless this succeeds. Both the
/// default account and an isolated instance use the same startup gate.
pub fn beginReset(io: std.Io, paths: *const Paths) !void {
    try validate(paths);
    var data = try ensurePrivate(io, paths.directory);
    defer data.close(io);
    try persistResetMarker(io, data);
}

fn persistResetMarker(io: std.Io, data: Dir) !void {
    const name = ".reset-pending";
    if (try kind(data, io, name)) |marker_kind| {
        if (marker_kind == .sym_link) return error.UnsafeSymlink;
        if (marker_kind != .file) return error.UnsupportedFileKind;
        const marker = try data.openFile(io, name, .{ .mode = .read_write, .follow_symlinks = false });
        defer marker.close(io);
        const stat = try marker.stat(io);
        if (stat.kind != .file) return error.UnsafeFile;
        if (stat.nlink != 1) return error.UnsafeHardlink;
        try marker.setPermissions(io, private_file);
        try marker.sync(io);
    } else {
        const marker = try data.createFile(io, name, .{ .exclusive = true, .permissions = private_file });
        defer marker.close(io);
        try marker.sync(io);
    }
    try syncDirectory(data);
}

fn syncDirectory(dir: Dir) !void {
    while (true) switch (std.posix.errno(std.c.fsync(dir.handle))) {
        .SUCCESS => break,
        .INTR => continue,
        else => return error.ResetMarkerSyncFailed,
    };
}

pub fn prepare(io: std.Io, paths: *const Paths) !PrepareReport {
    try validate(paths);
    if (openAbsolute(io, paths.directory, false)) |existing| {
        var data = existing;
        defer data.close(io);
        if (try kind(data, io, ".reset-pending") != null) return error.ResetIncomplete;
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }
    var result: PrepareReport = .{};
    if (paths.legacy_directory) |legacy| {
        var old_parent = try openParent(io, legacy, false);
        defer old_parent.close(io);
        const old_name = std.fs.path.basename(legacy);
        if (try kind(old_parent, io, old_name)) |old_kind| {
            if (old_kind == .sym_link) return error.UnsafeSymlink;
            if (old_kind != .directory) return error.NotDir;
            var old = try old_parent.openDir(io, old_name, .{ .iterate = true, .follow_symlinks = false });
            defer old.close(io);
            try secureTree(io, old);
            var parent = try openParent(io, paths.directory, true);
            defer parent.close(io);
            const name = std.fs.path.basename(paths.directory);
            if (try kind(parent, io, name)) |target_kind| {
                if (target_kind == .sym_link) return error.UnsafeSymlink;
                if (target_kind != .directory) return error.NotDir;
                var target = try parent.openDir(io, name, .{ .iterate = true, .follow_symlinks = false });
                defer target.close(io);
                try secureTree(io, target);
                try merge(io, old, target);
                try old_parent.deleteDir(io, old_name);
            } else try old_parent.renamePreserve(old_name, parent, name, io);
            result.migrated_legacy = true;
        }
    }
    var data = try ensurePrivate(io, paths.directory);
    defer data.close(io);
    // All migrated content was secured above; check an existing destination as
    // well, before store readers can dereference its files.
    try secureTree(io, data);
    var cache = try ensurePrivate(io, paths.cache_directory);
    defer cache.close(io);
    var diagnostics = try ensurePrivate(io, paths.diagnostic_directory);
    defer diagnostics.close(io);
    if (!paths.is_override) {
        if (try kind(data, io, "logs")) |log_kind| {
            if (log_kind == .sym_link) return error.UnsafeSymlink;
            if (log_kind != .directory) return error.NotDir;
            var logs = try data.openDir(io, "logs", .{ .iterate = true, .follow_symlinks = false });
            defer logs.close(io);
            var iterator = logs.iterate();
            while (try iterator.next(io)) |entry| {
                if (!isDiagnosticName(entry.name)) continue;
                if ((try kind(logs, io, entry.name)) != .file) return error.UnsupportedFileKind;
                if (try kind(diagnostics, io, entry.name)) |_| {
                    if (!try equalFiles(io, logs, diagnostics, entry.name)) return error.LegacyConflict;
                    try logs.deleteFile(io, entry.name);
                } else try logs.renamePreserve(entry.name, diagnostics, entry.name, io);
                result.moved_diagnostic_files += 1;
            }
        }
    }
    return result;
}

fn isDiagnosticName(name: []const u8) bool {
    return std.mem.startsWith(u8, name, "app-") and
        (std.mem.endsWith(u8, name, ".log") or std.mem.endsWith(u8, name, ".log.1"));
}

fn erase(io: std.Io, path: []const u8) !void {
    var parent = openParent(io, path, false) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer parent.close(io);
    const name = std.fs.path.basename(path);
    if (try kind(parent, io, name)) |root_kind| {
        if (root_kind == .sym_link) return error.UnsafeSymlink;
        if (root_kind != .directory) return error.NotDir;
        // std.Io.Dir.deleteTree opens descendants with follow_symlinks=false;
        // embedded links are unlinked, never traversed.
        try parent.deleteTree(io, name);
    }
}

/// Keep the recovery gate outside recursive deletion. A failed child removal
/// cannot consume it; a failed final rmdir restores it through the still-open
/// directory handle before reporting the failure.
fn eraseData(io: std.Io, path: []const u8) !void {
    var parent = try openParent(io, path, false);
    defer parent.close(io);
    const name = std.fs.path.basename(path);
    const root_kind = (try kind(parent, io, name)) orelse return;
    if (root_kind == .sym_link) return error.UnsafeSymlink;
    if (root_kind != .directory) return error.NotDir;
    var data = try parent.openDir(io, name, .{ .iterate = true, .follow_symlinks = false });
    defer data.close(io);
    var iterator = data.iterate();
    while (try iterator.next(io)) |entry| {
        if (std.mem.eql(u8, entry.name, ".reset-pending")) continue;
        data.deleteTree(io, entry.name) catch |err| {
            try persistResetMarker(io, data);
            return err;
        };
    }
    // Make the removals durable while the pending gate is still present.
    try syncDirectory(data);
    try data.deleteFile(io, ".reset-pending");
    parent.deleteDir(io, name) catch |err| {
        try persistResetMarker(io, data);
        return err;
    };
}

/// Reports every owned root independently. beginReset and Keychain erasure
/// must already have succeeded. Retrying must preserve the recovery gate;
/// never recreate defaults or import residual legacy state during reset.
pub fn eraseOwned(io: std.Io, paths: *const Paths) !EraseReport {
    try validate(paths);
    var report: EraseReport = .{};
    const targets = [_]struct { area: Area, path: ?[]const u8 }{
        .{ .area = .data, .path = paths.directory },
        .{ .area = .cache, .path = if (paths.is_override) null else paths.cache_directory },
        .{ .area = .diagnostic, .path = if (paths.is_override) null else paths.diagnostic_directory },
        .{ .area = .legacy, .path = paths.legacy_directory },
    };
    // Check parent components first, before deleting any of the roots.
    for (targets) |target| if (target.path) |path| {
        var parent = openParent(io, path, false) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        parent.close(io);
    };
    try beginReset(io, paths);
    // Data is last: its pending marker blocks re-import if any earlier root
    // could not be removed. A retry of eraseOwned completes the same reset.
    const order = [_]usize{ 3, 1, 2, 0 };
    for (order) |index| {
        const target = targets[index];
        const path = target.path orelse continue;
        var item: EraseItem = .{ .area = target.area };
        if (target.area == .data and !paths.is_override and !report.succeeded()) {
            item.failure = error.ResetIncomplete;
        } else if (target.area == .data) {
            eraseData(io, path) catch |err| {
                item.failure = err;
            };
        } else erase(io, path) catch |err| {
            item.failure = err;
        };
        report.items[report.count] = item;
        report.count += 1;
    }
    return report;
}
