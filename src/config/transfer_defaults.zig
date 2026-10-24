//! Apply saved defaults once when creating a transfer confirmation intent.
//! Existing open panels own their user's selections and do not reapply this.
const std = @import("std");
const config = @import("config.zig");
const confirmation_view = @import("../ui/transfer_panel.zig");

pub fn confirmation(policy: config.Transfer, data: confirmation_view.Data) confirmation_view.Data {
    var result = data;
    result.md5 = policy.verify_md5;
    result.resume_transfer = policy.@"resume";
    return result;
}

/// A new download may suggest this owned path. It is not a picker receipt.
/// Explicit destination paths and retained drafts do not call this helper.
pub fn downloadDirectory(allocator: std.mem.Allocator, configured: []const u8, home: ?[]const u8) ![]u8 {
    if (configured.len == 0) return allocator.dupe(u8, "");
    if (!validPath(configured)) return error.InvalidDownloadDirectory;
    if (configured[0] != '~') {
        if (!std.fs.path.isAbsolute(configured)) return error.InvalidDownloadDirectory;
        return allocator.dupe(u8, configured);
    }
    if (configured.len > 1 and configured[1] != '/') return error.InvalidDownloadDirectory;
    const base = home orelse return error.MissingHomeDirectory;
    if (!validPath(base) or !std.fs.path.isAbsolute(base)) return error.InvalidDownloadDirectory;
    if (configured.len <= 2) return allocator.dupe(u8, base);
    return std.fs.path.join(allocator, &.{ base, configured[2..] });
}

fn validPath(path: []const u8) bool {
    return std.unicode.utf8ValidateSlice(path) and std.mem.indexOfAny(u8, path, "\x00\r\n") == null;
}
