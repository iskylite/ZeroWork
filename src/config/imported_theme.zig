//! iTerm2 .itermcolors importer.  The format is an XML plist where each
//! colour is a dict containing Red/Green/Blue CGFloat values in the 0..1
//! range.  We intentionally retain a small, dependency-free parser because
//! theme import is a local settings action and must not execute XML code.
const std = @import("std");

pub const Theme = struct {
    name: []const u8,
    bg: u32,
    fg: u32,
    cursor: u32,
    selection: ?u32 = null,
    ansi: [16]u32,

    pub fn deinit(self: *Theme, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        self.* = undefined;
    }
};

pub const max_source_bytes = 2 * 1024 * 1024;
pub const ParseError = error{ InvalidPlist, MissingColors, InvalidComponent, ThemeTooLarge, OutOfMemory };

/// Canonical identities retain all previously accepted built-in references.
pub fn builtinId(name: []const u8) ?[]const u8 {
    for (@import("theme_presets.zig").ids ++ [_][]const u8{ "catppuccin-mocha", "dracula", "dark-pro", "solarized-dark", "nord" }) |id|
        if (std.ascii.eqlIgnoreCase(name, id)) return id;
    if (std.ascii.eqlIgnoreCase(name, "sauber-light")) return "sauber";
    if (std.ascii.eqlIgnoreCase(name, "catppuccin_mocha")) return "catppuccin-mocha";
    if (std.ascii.eqlIgnoreCase(name, "dark_pro")) return "dark-pro";
    if (std.ascii.eqlIgnoreCase(name, "solarized_dark")) return "solarized-dark";
    return null;
}

pub fn managedPath(id: []const u8, buffer: *[80]u8) ![]const u8 {
    if (id.len != 71 or !std.mem.startsWith(u8, id, "import:")) return error.UnknownTheme;
    for (id[7..]) |c| if (!std.ascii.isDigit(c) and !(c >= 'a' and c <= 'f')) return error.UnknownTheme;
    return std.fmt.bufPrint(buffer, "themes/{s}.json", .{id[7..]});
}

pub const Managed = struct { name: []const u8, source: []const u8 };
pub const max_managed_bytes = max_source_bytes * 6 + 4096;

/// The envelope preserves display identity and source bytes independently of
/// its content-addressed filename. No user-selected original is modified.
pub fn loadManaged(io: std.Io, dir: std.Io.Dir, allocator: std.mem.Allocator, id: []const u8) !Theme {
    var path_buffer: [80]u8 = undefined;
    const path = try managedPath(id, &path_buffer);
    const bytes = try dir.readFileAlloc(io, path, allocator, .limited(max_managed_bytes));
    defer allocator.free(bytes);
    const parsed = try std.json.parseFromSlice(Managed, allocator, bytes, .{});
    defer parsed.deinit();
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(parsed.value.source, &digest, .{});
    if (!std.mem.eql(u8, id[7..], &std.fmt.bytesToHex(digest, .lower))) return error.ThemeIdentityMismatch;
    return parse(allocator, parsed.value.source, parsed.value.name);
}

/// Retain the validated original plist under a stable local path.  Callers
/// store this absolute path in ui.theme; load() returns owned name + colors.
pub fn save(io: std.Io, dir: std.Io.Dir, path: []const u8, source: []const u8) !void {
    var theme = try parse(std.heap.page_allocator, source, std.fs.path.basename(path));
    defer theme.deinit(std.heap.page_allocator);
    var atomic = try dir.createFileAtomic(io, path, .{ .make_path = true, .replace = true });
    defer atomic.deinit(io);
    try atomic.file.writePositionalAll(io, source, 0);
    try atomic.replace(io);
}

pub fn load(io: std.Io, dir: std.Io.Dir, allocator: std.mem.Allocator, path: []const u8) !Theme {
    const source = try dir.readFileAlloc(io, path, allocator, .limited(2 * 1024 * 1024));
    defer allocator.free(source);
    return parse(allocator, source, std.fs.path.basename(path));
}

pub fn parse(allocator: std.mem.Allocator, source: []const u8, name: []const u8) ParseError!Theme {
    if (source.len > max_source_bytes) return error.ThemeTooLarge;
    if (std.mem.indexOfScalar(u8, source, 0) != null or !std.unicode.utf8ValidateSlice(source)) return error.InvalidPlist;
    var out = Theme{ .name = allocator.dupe(u8, name) catch return error.OutOfMemory, .bg = 0, .fg = 0, .cursor = 0, .ansi = std.mem.zeroes([16]u32) };
    errdefer out.deinit(allocator);
    var found: u16 = 0;
    var primaries: u8 = 0;
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, source, pos, "<key>")) |start| {
        const end = std.mem.indexOfPos(u8, source, start, "</key>") orelse return error.InvalidPlist;
        const key = source[start + 5 .. end];
        pos = end + 6;
        const index = ansiIndex(key);
        if (index == null and !std.mem.eql(u8, key, "Background Color") and !std.mem.eql(u8, key, "Foreground Color") and !std.mem.eql(u8, key, "Cursor Color") and !std.mem.eql(u8, key, "Selection Color")) continue;
        const dict_end = std.mem.indexOfPos(u8, source, pos, "</dict>") orelse return error.InvalidPlist;
        const rest = source[pos..dict_end];
        const r = component(rest, "Red Component") orelse return error.InvalidComponent;
        const g = component(rest, "Green Component") orelse return error.InvalidComponent;
        const b = component(rest, "Blue Component") orelse return error.InvalidComponent;
        if (!std.math.isFinite(r) or !std.math.isFinite(g) or !std.math.isFinite(b) or r < 0 or r > 1 or g < 0 or g > 1 or b < 0 or b > 1) return error.InvalidComponent;
        const color = rgba(r, g, b);
        if (std.mem.eql(u8, key, "Background Color")) {
            if (primaries & 1 != 0) return error.InvalidPlist;
            out.bg = color;
            primaries |= 1;
        } else if (std.mem.eql(u8, key, "Foreground Color")) {
            if (primaries & 2 != 0) return error.InvalidPlist;
            out.fg = color;
            primaries |= 2;
        } else if (std.mem.eql(u8, key, "Cursor Color")) {
            if (primaries & 4 != 0) return error.InvalidPlist;
            out.cursor = color;
            primaries |= 4;
        } else if (std.mem.eql(u8, key, "Selection Color")) {
            if (out.selection != null) return error.InvalidPlist;
            out.selection = color;
        } else if (index) |i| {
            if (i >= 16) return error.InvalidComponent;
            if (found & (@as(u16, 1) << @intCast(i)) != 0) return error.InvalidPlist;
            out.ansi[i] = color;
            found |= @as(u16, 1) << @intCast(i);
        }
        pos = dict_end + 7;
    }
    if (found != 0xffff or primaries != 7) return error.MissingColors;
    return out;
}

fn component(text: []const u8, label: []const u8) ?f64 {
    const needle = std.fmt.allocPrint(std.heap.page_allocator, "<key>{s}</key>", .{label}) catch return null;
    defer std.heap.page_allocator.free(needle);
    const at = std.mem.indexOf(u8, text, needle) orelse return null;
    const body = text[at + needle.len ..];
    const trimmed = std.mem.trimStart(u8, body, " \t\r\n");
    const opening: []const u8 = if (std.mem.startsWith(u8, trimmed, "<real>")) "<real>" else if (std.mem.startsWith(u8, trimmed, "<integer>")) "<integer>" else return null;
    const closing: []const u8 = if (opening.len == 6) "</real>" else "</integer>";
    const end = std.mem.indexOf(u8, trimmed[opening.len..], closing) orelse return null;
    return std.fmt.parseFloat(f64, std.mem.trim(u8, trimmed[opening.len .. opening.len + end], " \t\r\n")) catch null;
}
fn rgba(r: f64, g: f64, b: f64) u32 {
    const c = struct {
        fn q(v: f64) u32 {
            return @intFromFloat(@round(std.math.clamp(v, 0, 1) * 255));
        }
    };
    return (c.q(r) << 24) | (c.q(g) << 16) | (c.q(b) << 8) | 0xff;
}
fn ansiIndex(key: []const u8) ?usize {
    if (std.mem.startsWith(u8, key, "Ansi ") and std.mem.endsWith(u8, key, " Color")) {
        const middle = key[5 .. key.len - 6];
        return std.fmt.parseInt(usize, middle, 10) catch null;
    }
    const names = [_][]const u8{ "Black", "Red", "Green", "Yellow", "Blue", "Magenta", "Cyan", "White", "Bright Black", "Bright Red", "Bright Green", "Bright Yellow", "Bright Blue", "Bright Magenta", "Bright Cyan", "Bright White" };
    for (names, 0..) |name, i| if (std.mem.eql(u8, key, name)) return i;
    return null;
}

test "imports iTerm sixteen ANSI colors and primary colors" {
    var xml: std.ArrayList(u8) = .empty;
    defer xml.deinit(std.testing.allocator);
    const names = [_][]const u8{ "Black", "Red", "Green", "Yellow", "Blue", "Magenta", "Cyan", "White", "Bright Black", "Bright Red", "Bright Green", "Bright Yellow", "Bright Blue", "Bright Magenta", "Bright Cyan", "Bright White" };
    for (names) |n| {
        const x = try std.fmt.allocPrint(std.testing.allocator, "<key>{s}</key><dict><key>Red Component</key><real>1</real><key>Green Component</key><real>0</real><key>Blue Component</key><real>0</real></dict>", .{n});
        defer std.testing.allocator.free(x);
        try xml.appendSlice(std.testing.allocator, x);
    }
    for ([_][]const u8{ "Background Color", "Foreground Color", "Cursor Color" }) |n| {
        const x = try std.fmt.allocPrint(std.testing.allocator, "<key>{s}</key><dict><key>Red Component</key><real>0</real><key>Green Component</key><real>0</real><key>Blue Component</key><real>0</real></dict>", .{n});
        defer std.testing.allocator.free(x);
        try xml.appendSlice(std.testing.allocator, x);
    }
    // Selection Color is optional but must survive when supplied by a theme.
    try xml.appendSlice(std.testing.allocator, "<key>Selection Color</key><dict><key>Red Component</key><real>0</real><key>Green Component</key><real>1</real><key>Blue Component</key><real>0</real></dict>");
    var theme = try parse(std.testing.allocator, xml.items, "Imported");
    defer theme.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 0xff0000ff), theme.ansi[0]);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try save(std.testing.io, tmp.dir, "themes/custom.itermcolors", xml.items);
    var loaded = try load(std.testing.io, tmp.dir, std.testing.allocator, "themes/custom.itermcolors");
    defer loaded.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(u32, &theme.ansi, &loaded.ansi);
    try std.testing.expectEqual(theme.bg, loaded.bg);
    try std.testing.expectEqual(@as(?u32, 0x00ff00ff), loaded.selection);
    try std.testing.expectEqualStrings("custom.itermcolors", loaded.name);
}

test "missing and invalid components are rejected before persistence" {
    try std.testing.expectError(error.MissingColors, parse(std.testing.allocator, "<plist><dict/></plist>", "bad"));
    try std.testing.expectError(error.InvalidComponent, parse(std.testing.allocator, "<key>Ansi 0 Color</key><dict><key>Red Component</key><real>2</real><key>Green Component</key><real>0</real><key>Blue Component</key><real>0</real></dict>", "bad"));
}

/// Validate persistence independently of UI mounting. Built-in IDs are stable;
/// imported references must resolve to a valid local plist before replacement.
pub fn validateReference(io: std.Io, dir: std.Io.Dir, allocator: std.mem.Allocator, name: []const u8) !void {
    if (builtinId(name) != null) return;
    if (std.mem.startsWith(u8, name, "import:")) {
        var theme = try loadManaged(io, dir, allocator, name);
        defer theme.deinit(allocator);
        return;
    }
    if (!std.mem.endsWith(u8, name, ".itermcolors")) return error.UnknownTheme;
    var theme = try load(io, dir, allocator, name);
    defer theme.deinit(allocator);
}
