//! Read-only import of layout preferences written by the earlier V0.8 build.
//! config.toml is the authoritative store after the first successful import.
const std = @import("std");

pub const filename = "workspace-layout.json";

pub const Preferences = struct {
    ai_dock_width: ?f32 = null,
    ai_dock_preferred: bool = false,
    mascot_anchor_x: ?f32 = null,
    mascot_anchor_y: ?f32 = null,

    fn validated(self: Preferences) Preferences {
        return .{
            .ai_dock_width = within(self.ai_dock_width, 360, 2400),
            .ai_dock_preferred = self.ai_dock_preferred,
            .mascot_anchor_x = within(self.mascot_anchor_x, 0, 1),
            .mascot_anchor_y = within(self.mascot_anchor_y, 0, 1),
        };
    }
};

fn within(value: ?f32, min: f32, max: f32) ?f32 {
    const number = value orelse return null;
    return if (std.math.isFinite(number) and number >= min and number <= max) number else null;
}

const Snapshot = struct {
    version: u8,
    preferences: Preferences,
};

pub fn load(io: std.Io, dir: std.Io.Dir, config_path: []const u8) !?Preferences {
    const path = try siblingPath(config_path);
    defer std.heap.page_allocator.free(path);
    const file = dir.openFile(io, path, .{ .follow_symlinks = false, .allow_directory = false }) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer file.close(io);
    if ((try file.stat(io)).kind != .file) return error.InvalidWorkspaceLayout;
    var reader = file.reader(io, &.{});
    const a = std.heap.page_allocator;
    const bytes = reader.interface.allocRemaining(a, .limited(4096)) catch |err| switch (err) {
        error.ReadFailed => return reader.err.?,
        error.StreamTooLong => return error.InvalidWorkspaceLayout,
        error.OutOfMemory => return err,
    };
    defer a.free(bytes);
    const decoded = std.json.parseFromSlice(Snapshot, a, bytes, .{ .ignore_unknown_fields = true }) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return error.InvalidWorkspaceLayout,
    };
    defer decoded.deinit();
    if (decoded.value.version != 1) return error.UnsupportedWorkspaceLayoutVersion;
    return decoded.value.preferences.validated();
}

pub fn syncParent(dir: std.Io.Dir) !void {
    while (true) switch (std.posix.errno(std.c.fsync(dir.handle))) {
        .SUCCESS => return,
        .INTR => continue,
        else => return error.WorkspaceLayoutSyncFailed,
    };
}

fn siblingPath(config_path: []const u8) ![]u8 {
    return std.fs.path.join(std.heap.page_allocator, &.{ std.fs.path.dirname(config_path) orelse ".", filename });
}
