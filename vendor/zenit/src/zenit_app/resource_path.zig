const std = @import("std");

/// Bundle resource path resolution
///
/// Detects at runtime whether the executable is in .app/Contents/MacOS/:
/// - Bundle mode: resources in .app/Contents/Resources/
/// - Dev mode: resources in CWD's assets/ directory
pub const ResourcePath = struct {
    /// Resource root directory (ends with '/')
    /// Bundle mode: "/path/to/MyApp.app/Contents/Resources/"
    /// Dev mode: prefer resolve to .../assets/ in executable's parent directory
    /// null means fallback to relative path "assets/"
    base_path: ?[]const u8,

    var static_buf: [std.fs.max_path_bytes]u8 = undefined;
    var static_len: usize = 0;

    pub fn init(io: std.Io) ResourcePath {
        static_len = 0;
        var self_path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const self_len = std.process.executablePath(io, &self_path_buf) catch {
            return .{ .base_path = null };
        };
        const self_path = self_path_buf[0..self_len];

        const marker = "/Contents/MacOS/";
        if (std.mem.indexOf(u8, self_path, marker)) |pos| {
            const contents_end = pos + "/Contents/".len;
            const resources_suffix = "Resources/";
            const total_len = contents_end + resources_suffix.len;
            if (total_len <= static_buf.len) {
                @memcpy(static_buf[0..contents_end], self_path[0..contents_end]);
                @memcpy(static_buf[contents_end..total_len], resources_suffix);
                static_len = total_len;
                return .{ .base_path = static_buf[0..total_len] };
            }
        }

        if (std.fs.path.dirname(self_path)) |self_dir| {
            if (findAssetsBase(io, self_dir)) |base_path| {
                return .{ .base_path = base_path };
            }
        }

        return .{ .base_path = null };
    }

    /// Write resource relative path into caller-provided buffer, return sentinel-terminated slice
    ///
    /// Input: "fonts/Roboto.ttf"
    /// Bundle mode: "/path/to/MyApp.app/Contents/Resources/fonts/Roboto.ttf"
    /// Dev mode: "/abs/path/to/assets/fonts/Roboto.ttf" or fallback to "assets/fonts/..."
    pub fn resolve(self: *const ResourcePath, buf: []u8, rel_path: []const u8) [:0]const u8 {
        if (self.base_path) |base| {
            const total = base.len + rel_path.len;
            if (total < buf.len) {
                @memcpy(buf[0..base.len], base);
                @memcpy(buf[base.len..total], rel_path);
                buf[total] = 0;
                return buf[0..total :0];
            }
        }

        const prefix = "assets/";
        const total = prefix.len + rel_path.len;
        if (total < buf.len) {
            @memcpy(buf[0..prefix.len], prefix);
            @memcpy(buf[prefix.len..total], rel_path);
            buf[total] = 0;
            return buf[0..total :0];
        }

        buf[0] = 0;
        return buf[0..0 :0];
    }

    fn findAssetsBase(io: std.Io, start_dir: []const u8) ?[]const u8 {
        var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
        if (start_dir.len == 0 or start_dir.len >= dir_buf.len) return null;
        @memcpy(dir_buf[0..start_dir.len], start_dir);

        var current: []const u8 = dir_buf[0..start_dir.len];
        while (true) {
            var candidate_buf: [std.fs.max_path_bytes]u8 = undefined;
            const candidate = joinPath(&candidate_buf, current, "assets", false) orelse return null;
            if (std.Io.Dir.openDirAbsolute(io, candidate, .{})) |opened_dir| {
                opened_dir.close(io);
                return storeBasePath(current, "assets");
            } else |_| {}

            // dirname returns null at the filesystem root (`/`, `C:\`).
            current = std.fs.path.dirname(current) orelse break;
        }
        return null;
    }

    fn storeBasePath(dir_path: []const u8, child: []const u8) ?[]const u8 {
        const base = joinPath(&static_buf, dir_path, child, true) orelse return null;
        static_len = base.len;
        return static_buf[0..static_len];
    }

    /// Native separators: `resolve` appends `/`-separated relative paths,
    /// which every supported platform accepts after a native prefix.
    fn joinPath(buf: []u8, dir_path: []const u8, child: []const u8, trailing_slash: bool) ?[]u8 {
        const sep = std.fs.path.sep_str;
        const at_root = dir_path.len > 0 and std.fs.path.isSep(dir_path[dir_path.len - 1]);
        const mid = if (at_root) "" else sep;
        if (trailing_slash) {
            return std.fmt.bufPrint(buf, "{s}{s}{s}" ++ sep, .{ dir_path, mid, child }) catch null;
        }
        return std.fmt.bufPrint(buf, "{s}{s}{s}", .{ dir_path, mid, child }) catch null;
    }
};

test "joinPath uses native separators and never doubles the root separator" {
    var buf: [64]u8 = undefined;
    const sep = std.fs.path.sep_str;
    try std.testing.expectEqualStrings("app" ++ sep ++ "assets" ++ sep, ResourcePath.joinPath(&buf, "app", "assets", true).?);
    try std.testing.expectEqualStrings(sep ++ "assets", ResourcePath.joinPath(&buf, sep, "assets", false).?);
}

test "init resolves from the running executable and resolve always yields a path" {
    const paths = ResourcePath.init(std.testing.io);
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const font = paths.resolve(&buf, "fonts/x.ttf");
    try std.testing.expect(std.mem.endsWith(u8, font, "fonts/x.ttf"));
    if (paths.base_path) |base| try std.testing.expect(std.fs.path.isAbsolute(base));
}
