//! Worker-side background preparation and draft ownership. No window or GPU is
//! required; the renderer uploads a prepared RGBA image at its commit boundary.
const std = @import("std");

pub const Fit = enum { fill, fit, center, tile };
pub const Horizontal = enum { left, center, right };
pub const Vertical = enum { top, center, bottom };
pub const Background = struct {
    enabled: bool = false,
    path: []const u8 = "",
    fit: Fit = .fill,
    alignment_x: Horizontal = .center,
    alignment_y: Vertical = .center,
    transparency: f32 = 0,

    pub fn alpha(self: Background) f32 {
        return 1 - self.transparency / 100;
    }
};
pub const Materials = struct {
    background: Background = .{},
    blur_px: u8 = 0,

    pub fn validate(self: Materials) error{ OutOfRange, InvalidValue }!void {
        if (!std.math.isFinite(self.background.transparency) or self.background.transparency < 0 or self.background.transparency > 100 or self.blur_px > 96) return error.OutOfRange;
        if (std.mem.indexOfScalar(u8, self.background.path, 0) != null or !std.unicode.utf8ValidateSlice(self.background.path)) return error.InvalidValue;
        if (self.background.enabled and self.background.path.len == 0) return error.InvalidValue;
    }
};

pub const Limits = struct {
    source_bytes: usize = 32 * 1024 * 1024,
    pixels: usize = 64 * 1024 * 1024,
    dimension: usize = 16 * 1024,
};
pub const DecodeState = enum { empty, loading, ready, missing, denied, invalid, failed };
pub const Request = struct { draft_id: u64, asset_revision: u64, path: []const u8 };
/// The worker owns its path independently of Input and ConfigSnapshot buffers.
pub const OwnedRequest = struct {
    allocator: std.mem.Allocator,
    request: Request,
    pub fn deinit(self: *OwnedRequest) void {
        self.allocator.free(self.request.path);
        self.* = undefined;
    }
};
pub const Image = struct {
    pixels: []u8,
    width: u32,
    height: u32,

    pub fn deinit(self: *Image, allocator: std.mem.Allocator) void {
        allocator.free(self.pixels);
        self.* = undefined;
    }
};
pub const Prepared = struct {
    draft_id: u64,
    asset_revision: u64,
    path: []u8,
    image: Image,

    pub fn deinit(self: *Prepared, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        self.image.deinit(allocator);
        self.* = undefined;
    }
};

/// The caller owns this value until a worker returns. Successful preparation
/// never changes a draft; stale completions can always be released by callers.
pub fn prepare(io: std.Io, dir: std.Io.Dir, allocator: std.mem.Allocator, request: Request, limits: Limits) !Prepared {
    if (request.path.len == 0 or !std.fs.path.isAbsolute(request.path)) return error.InvalidImagePath;
    const bytes = try dir.readFileAlloc(io, request.path, allocator, .limited(limits.source_bytes));
    defer allocator.free(bytes);
    var image = try decode(allocator, bytes, limits);
    errdefer image.deinit(allocator);
    return .{ .draft_id = request.draft_id, .asset_revision = request.asset_revision, .path = try allocator.dupe(u8, request.path), .image = image };
}

pub fn failureState(err: anyerror) DecodeState {
    return switch (err) {
        error.FileNotFound => .missing,
        error.AccessDenied, error.PermissionDenied => .denied,
        error.InvalidImage, error.UnsupportedImage, error.ImageTooLarge, error.StreamTooLong, error.InvalidImagePath => .invalid,
        else => .failed,
    };
}

pub const Draft = struct {
    draft_id: u64,
    asset_revision: u64 = 0,
    state: DecodeState = .empty,
    last_good: ?Prepared = null,
    problem: ?anyerror = null,

    pub fn deinit(self: *Draft, allocator: std.mem.Allocator) void {
        if (self.last_good) |*good| good.deinit(allocator);
        self.* = undefined;
    }

    /// Cancelling a picker makes no call here, so it has no side effects.
    pub fn select(self: *Draft, path: []const u8) !Request {
        if (self.asset_revision == std.math.maxInt(u64)) return error.AssetRevisionExhausted;
        self.asset_revision += 1;
        self.state = if (path.len == 0) .empty else .loading;
        self.problem = null;
        return .{ .draft_id = self.draft_id, .asset_revision = self.asset_revision, .path = path };
    }

    /// Always consumes the returned resource, including an obsolete response.
    pub fn complete(self: *Draft, allocator: std.mem.Allocator, prepared: *Prepared) bool {
        if (self.state != .loading or prepared.draft_id != self.draft_id or prepared.asset_revision != self.asset_revision) {
            prepared.deinit(allocator);
            return false;
        }
        if (self.last_good) |*good| good.deinit(allocator);
        self.last_good = prepared.*;
        prepared.* = undefined;
        self.state = .ready;
        self.problem = null;
        return true;
    }

    pub fn fail(self: *Draft, request: Request, problem: anyerror) bool {
        if (self.state != .loading or request.draft_id != self.draft_id or request.asset_revision != self.asset_revision) return false;
        self.state = failureState(problem);
        self.problem = problem;
        return true;
    }

    pub fn canSave(self: Draft, background: Background) bool {
        if (!background.enabled) return true;
        const good = self.last_good orelse return false;
        return self.state == .ready and good.asset_revision == self.asset_revision and std.mem.eql(u8, good.path, background.path);
    }
};

// ImageIO reads bounded bytes, inspects dimensions before requesting pixels,
// and decodes into a bounded CPU bitmap. It does not use NSImage, a window,
// external URLs, or application rendering state.
const Ref = *const anyopaque;
extern "c" fn CFDataCreate(?Ref, [*]const u8, isize) ?Ref;
extern "c" fn CFRelease(Ref) void;
extern "c" fn CFDictionaryGetValue(Ref, Ref) ?Ref;
extern "c" fn CFDictionaryCreate(?Ref, [*]const Ref, [*]const Ref, isize, ?Ref, ?Ref) ?Ref;
extern "c" fn CFNumberGetValue(Ref, isize, *i64) bool;
extern "c" fn CGImageSourceCreateWithData(Ref, ?Ref) ?Ref;
extern "c" fn CGImageSourceCopyPropertiesAtIndex(Ref, usize, ?Ref) ?Ref;
extern "c" fn CGImageSourceCreateImageAtIndex(Ref, usize, ?Ref) ?Ref;
extern "c" fn CGImageSourceGetStatus(Ref) i32;
extern "c" fn CGImageSourceGetStatusAtIndex(Ref, usize) i32;
extern "c" fn CGImageGetWidth(Ref) usize;
extern "c" fn CGImageGetHeight(Ref) usize;
extern "c" fn CGImageGetDataProvider(Ref) ?Ref;
extern "c" fn CGDataProviderCopyData(Ref) ?Ref;
extern "c" fn CFDataGetLength(Ref) isize;
extern "c" fn CGColorSpaceCreateDeviceRGB() ?Ref;
extern "c" fn CGBitmapContextCreate([*]u8, usize, usize, usize, usize, Ref, u32) ?Ref;
const Point = extern struct { x: f64, y: f64 };
const Size = extern struct { width: f64, height: f64 };
const Rect = extern struct { origin: Point, size: Size };
extern "c" fn CGContextDrawImage(Ref, Rect, Ref) void;
extern "c" var kCGImagePropertyPixelWidth: Ref;
extern "c" var kCGImagePropertyPixelHeight: Ref;
extern "c" var kCGImageSourceShouldCache: Ref;
extern "c" var kCGImageSourceShouldCacheImmediately: Ref;
extern "c" var kCFBooleanFalse: Ref;
extern "c" var kCFBooleanTrue: Ref;

pub fn decode(allocator: std.mem.Allocator, bytes: []const u8, limits: Limits) !Image {
    if (@import("builtin").os.tag != .macos) return error.UnsupportedImage;
    if (bytes.len == 0) return error.InvalidImage;
    if (bytes.len > limits.source_bytes) return error.ImageTooLarge;
    const data = CFDataCreate(null, bytes.ptr, @intCast(bytes.len)) orelse return error.OutOfMemory;
    defer CFRelease(data);
    const keys = [_]Ref{kCGImageSourceShouldCache};
    const values = [_]Ref{kCFBooleanFalse};
    const options = CFDictionaryCreate(null, &keys, &values, 1, null, null) orelse return error.OutOfMemory;
    defer CFRelease(options);
    const source = CGImageSourceCreateWithData(data, options) orelse return error.InvalidImage;
    defer CFRelease(source);
    if (CGImageSourceGetStatus(source) != 0) return error.InvalidImage;
    const properties = CGImageSourceCopyPropertiesAtIndex(source, 0, null) orelse return error.InvalidImage;
    defer CFRelease(properties);
    var width: i64 = 0;
    var height: i64 = 0;
    const width_ref = CFDictionaryGetValue(properties, kCGImagePropertyPixelWidth) orelse return error.InvalidImage;
    const height_ref = CFDictionaryGetValue(properties, kCGImagePropertyPixelHeight) orelse return error.InvalidImage;
    if (!CFNumberGetValue(width_ref, 4, &width) or !CFNumberGetValue(height_ref, 4, &height) or width <= 0 or height <= 0) return error.InvalidImage;
    const w: usize = @intCast(width);
    const h: usize = @intCast(height);
    if (w > limits.dimension or h > limits.dimension or w > limits.pixels / h) return error.ImageTooLarge;
    const decode_keys = [_]Ref{ kCGImageSourceShouldCache, kCGImageSourceShouldCacheImmediately };
    const decode_values = [_]Ref{ kCFBooleanTrue, kCFBooleanTrue };
    const decode_options = CFDictionaryCreate(null, &decode_keys, &decode_values, 2, null, null) orelse return error.OutOfMemory;
    defer CFRelease(decode_options);
    const image = CGImageSourceCreateImageAtIndex(source, 0, decode_options) orelse return error.InvalidImage;
    defer CFRelease(image);
    if (CGImageGetWidth(image) != w or CGImageGetHeight(image) != h) return error.InvalidImage;
    // Force the public provider's lazy pixel read. ImageIO can report complete
    // metadata and return a CGImage even when its raster cannot be decoded;
    // CGContextDrawImage itself has no error return and otherwise paints blank.
    const provider = CGImageGetDataProvider(image) orelse return error.InvalidImage;
    const raster = CGDataProviderCopyData(provider) orelse return error.InvalidImage;
    defer CFRelease(raster);
    if (CFDataGetLength(raster) <= 0) return error.InvalidImage;
    const pixels = try allocator.alloc(u8, try std.math.mul(usize, try std.math.mul(usize, w, h), 4));
    errdefer allocator.free(pixels);
    const space = CGColorSpaceCreateDeviceRGB() orelse return error.OutOfMemory;
    defer CFRelease(space);
    // Premultiplied-last RGBA8, byte-order32Big.
    const context = CGBitmapContextCreate(pixels.ptr, w, h, 8, w * 4, space, 1 | (4 << 12)) orelse return error.InvalidImage;
    defer CFRelease(context);
    @memset(pixels, 0);
    CGContextDrawImage(context, .{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .width = @floatFromInt(w), .height = @floatFromInt(h) } }, image);
    if (CGImageSourceGetStatus(source) != 0 or CGImageSourceGetStatusAtIndex(source, 0) != 0) return error.InvalidImage;
    return .{ .pixels = pixels, .width = @intCast(w), .height = @intCast(h) };
}
