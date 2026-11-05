//! Owned, non-recursive directory playlist. No UI or filesystem work here.
const std = @import("std");

pub fn imageName(name: []const u8) bool {
    const extension = std.fs.path.extension(name);
    for ([_][]const u8{ ".png", ".jpg", ".jpeg", ".webp", ".heic", ".heif", ".tif", ".tiff", ".bmp", ".gif" }) |supported| {
        if (std.ascii.eqlIgnoreCase(extension, supported)) return true;
    }
    return false;
}

pub const Playlist = struct {
    paths: std.ArrayList([]u8) = .empty,
    index: usize = 0,
    random: bool = false,
    prng: std.Random.DefaultPrng = .init(0),

    pub fn deinit(self: *Playlist, allocator: std.mem.Allocator) void {
        for (self.paths.items) |path| allocator.free(path);
        self.paths.deinit(allocator);
        self.* = .{};
    }
    pub fn append(self: *Playlist, allocator: std.mem.Allocator, path: []const u8) !void {
        const owned = try allocator.dupe(u8, path);
        errdefer allocator.free(owned);
        try self.paths.append(allocator, owned);
    }
    pub fn clone(self: Playlist, allocator: std.mem.Allocator) !Playlist {
        var result: Playlist = .{ .index = self.index, .random = self.random, .prng = self.prng };
        errdefer result.deinit(allocator);
        for (self.paths.items) |path| try result.append(allocator, path);
        return result;
    }
    pub fn sort(self: *Playlist) void {
        std.mem.sort([]u8, self.paths.items, {}, naturalLess);
    }
    pub fn setOrder(self: *Playlist, random: bool, seed: u64) void {
        self.random = random;
        self.prng = .init(seed);
        self.index = 0;
        if (random) self.prng.random().shuffle([]u8, self.paths.items) else self.sort();
    }
    pub fn changeOrder(self: *Playlist, random: bool) void {
        if (self.random == random or self.paths.items.len == 0) return;
        const current = self.paths.items[self.index];
        self.random = random;
        if (random) self.prng.random().shuffle([]u8, self.paths.items) else self.sort();
        for (self.paths.items, 0..) |path, i| if (path.ptr == current.ptr) {
            if (random) {
                std.mem.swap([]u8, &self.paths.items[0], &self.paths.items[i]);
                self.index = 0;
            } else self.index = i;
            break;
        };
    }
    pub fn advance(self: *Playlist) void {
        if (self.paths.items.len < 2) return;
        if (self.index + 1 < self.paths.items.len) {
            self.index += 1;
            return;
        }
        const previous = self.paths.items[self.index];
        self.index = 0;
        if (self.random) {
            self.prng.random().shuffle([]u8, self.paths.items);
            if (self.paths.items[0].ptr == previous.ptr) {
                const other = self.prng.random().intRangeLessThan(usize, 1, self.paths.items.len);
                std.mem.swap([]u8, &self.paths.items[0], &self.paths.items[other]);
            }
        }
    }
};

/// Numeric runs are compared without integer parsing (arbitrarily long names).
pub fn naturalLess(_: void, a: []u8, b: []u8) bool {
    var i: usize = 0;
    var j: usize = 0;
    while (i < a.len and j < b.len) {
        if (std.ascii.isDigit(a[i]) and std.ascii.isDigit(b[j])) {
            const start_i = i;
            const start_j = j;
            while (i < a.len and std.ascii.isDigit(a[i])) : (i += 1) {}
            while (j < b.len and std.ascii.isDigit(b[j])) : (j += 1) {}
            var nz_i = start_i;
            var nz_j = start_j;
            while (nz_i < i and a[nz_i] == '0') : (nz_i += 1) {}
            while (nz_j < j and b[nz_j] == '0') : (nz_j += 1) {}
            if (i - nz_i != j - nz_j) return i - nz_i < j - nz_j;
            const order = std.mem.order(u8, a[nz_i..i], b[nz_j..j]);
            if (order != .eq) return order == .lt;
            if (i - start_i != j - start_j) return i - start_i < j - start_j;
        } else {
            const left = std.ascii.toLower(a[i]);
            const right = std.ascii.toLower(b[j]);
            if (left != right) return left < right;
            i += 1;
            j += 1;
        }
    }
    if (a.len != b.len) return i == a.len;
    return std.mem.lessThan(u8, a, b);
}
