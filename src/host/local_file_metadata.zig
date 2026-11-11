//! Metadata that a managed Local replacement promises to preserve.
const std = @import("std");
const Sha256 = std.crypto.hash.sha2.Sha256;
extern "c" fn flistxattr(c_int, ?[*]u8, usize, c_int) isize;
extern "c" fn fgetxattr(c_int, [*:0]const u8, ?[*]u8, usize, u32, c_int) isize;
const Acl = *opaque {};
extern "c" fn acl_get_fd_np(c_int, c_int) ?Acl;
extern "c" fn acl_size(Acl) isize;
extern "c" fn acl_get_entry(Acl, c_int, *?*anyopaque) c_int;
extern "c" fn acl_copy_ext([*]u8, Acl, isize) isize;
extern "c" fn acl_free(*anyopaque) c_int;
const max_bytes = 512 * 1024;

/// A parent may pass an inherited ACL even when mkdir requests 0700.
/// Check the directory before creating any recovery material in it.
pub fn requirePrivateDirectory(dir: std.Io.Dir) !void {
    const acl = acl_get_fd_np(dir.handle, 0x100) orelse switch (std.c.errno(-1)) {
        .NOENT, .NOATTR, .OPNOTSUPP => return,
        else => return error.FileAclUnavailable,
    };
    defer _ = acl_free(acl);
    var entry: ?*anyopaque = null;
    if (acl_get_entry(acl, 0, &entry) == 0) return error.RecoveryDirectoryAclUnsupported;
    if (std.c.errno(-1) != .NOENT) return error.FileAclUnavailable;
}

pub fn fingerprint(a: std.mem.Allocator, file: std.Io.File) ![Sha256.digest_length]u8 {
    var stat: std.c.Stat = undefined;
    if (std.c.fstat(file.handle, &stat) != 0) return error.FileStatFailed;
    var hash = Sha256.init(.{});
    hash.update(std.mem.asBytes(&stat.mode));
    hash.update(std.mem.asBytes(&stat.uid));
    hash.update(std.mem.asBytes(&stat.gid));
    hash.update(std.mem.asBytes(&stat.flags));
    try appendAcl(a, &hash, file.handle);
    try appendAttributes(a, &hash, file.handle);
    return hash.finalResult();
}

fn appendAcl(a: std.mem.Allocator, hash: *Sha256, fd: c_int) !void {
    const acl = acl_get_fd_np(fd, 0x100) orelse switch (std.c.errno(-1)) {
        .NOENT, .NOATTR, .OPNOTSUPP => {
            hash.update(&.{0});
            return;
        },
        else => return error.FileAclUnavailable,
    };
    defer _ = acl_free(acl);
    const len = acl_size(acl);
    if (len < 0 or len > max_bytes) return error.FileAclUnavailable;
    const bytes = try a.alloc(u8, @intCast(len));
    defer a.free(bytes);
    const n = acl_copy_ext(bytes.ptr, acl, len);
    if (n < 0 or n > len) return error.FileAclUnavailable;
    hash.update(&.{1});
    appendBytes(hash, bytes[0..@intCast(n)]);
}

fn less(_: void, lhs: [:0]const u8, rhs: [:0]const u8) bool {
    return std.mem.order(u8, lhs, rhs) == .lt;
}

fn appendAttributes(a: std.mem.Allocator, hash: *Sha256, fd: c_int) !void {
    const len = flistxattr(fd, null, 0, 0);
    if (len < 0) switch (std.c.errno(len)) {
        .OPNOTSUPP => return,
        else => return error.FileAttributesUnavailable,
    };
    if (len > max_bytes) return error.FileAttributesTooLarge;
    if (len == 0) return;
    const names = try a.alloc(u8, @intCast(len));
    defer a.free(names);
    if (flistxattr(fd, names.ptr, names.len, 0) != len) return error.SourceChanged;
    var ordered: std.ArrayList([:0]const u8) = .empty;
    defer ordered.deinit(a);
    var start: usize = 0;
    while (start < names.len) {
        const end = std.mem.indexOfScalarPos(u8, names, start, 0) orelse return error.FileAttributesUnavailable;
        try ordered.append(a, names[start..end :0]);
        start = end + 1;
    }
    std.mem.sort([:0]const u8, ordered.items, {}, less);
    var budget: usize = max_bytes;
    for (ordered.items) |name| {
        const count = fgetxattr(fd, name.ptr, null, 0, 0, 0);
        if (count < 0) return error.FileAttributesUnavailable;
        if (count > budget) return error.FileAttributesTooLarge;
        const value = try a.alloc(u8, @intCast(count));
        defer a.free(value);
        if (fgetxattr(fd, name.ptr, value.ptr, value.len, 0, 0) != count) return error.SourceChanged;
        appendBytes(hash, name);
        appendBytes(hash, value);
        budget -= value.len;
    }
}

fn appendBytes(hash: *Sha256, bytes: []const u8) void {
    const count: u64 = bytes.len;
    hash.update(std.mem.asBytes(&count));
    hash.update(bytes);
}
