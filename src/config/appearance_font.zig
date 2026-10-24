//! Appearance font preparation using the host's existing registry. Resolving
//! does not publish settings or mutate any window. Use the returned family id,
//! size and weight with this same registry when painting the terminal.
const std = @import("std");
const builtin = @import("builtin");
const FontRegistry = @import("zenit_app").FontRegistry;

pub const Weight = enum(u16) { light = 300, regular = 400, medium = 500, bold = 700 };
pub const FallbackReason = enum { family_not_installed };

pub const Request = struct {
    family: []const u8,
    size: f32,
    weight: []const u8 = "regular",
};

/// Strings are owned by this value; the face remains owned by the supplied
/// FontRegistry. Metrics are logical pixels from that exact, verified face.
pub const Resolved = struct {
    requested_family: []u8,
    requested_size: f32,
    requested_weight: Weight,
    actual_family: []u8,
    actual_weight: Weight,
    family_id: u16,
    cell_width: f32,
    ascent: f32,
    descent: f32,
    fallback_reason: ?FallbackReason,

    pub fn deinit(self: *Resolved, allocator: std.mem.Allocator) void {
        allocator.free(self.requested_family);
        allocator.free(self.actual_family);
        self.* = undefined;
    }
};

pub const ResolveError = std.mem.Allocator.Error || error{
    InvalidFamily,
    InvalidSize,
    InvalidWeight,
    UnsupportedWeight,
    FontUnavailable,
    InvalidMetrics,
};

const fallback_family = "Menlo";
// FontRegistry.intern currently stores at most 64 UTF-8 bytes. Refuse a name
// it would truncate rather than report that a different family was selected.
const family_name_capacity = 64;

/// Validates before looking up a face. An absent family uses explicit Menlo
/// fallback without overwriting the requested family. A weight absent from the
/// selected family, or one CoreText actually substituted, is a typed error.
/// Main/controller thread only, like the supplied FontRegistry.
pub fn resolve(allocator: std.mem.Allocator, registry: *FontRegistry, request: Request) ResolveError!Resolved {
    if (request.family.len == 0 or request.family.len > family_name_capacity or
        std.mem.trim(u8, request.family, " \t\r\n").len == 0 or
        !std.unicode.utf8ValidateSlice(request.family)) return error.InvalidFamily;
    for (request.family) |byte| if (byte < 0x20 or byte == 0x7f) return error.InvalidFamily;
    if (!std.math.isFinite(request.size) or request.size < 8 or request.size > 48) return error.InvalidSize;
    const weight = std.meta.stringToEnum(Weight, request.weight) orelse return error.InvalidWeight;
    if (builtin.os.tag != .macos or registry.font_system == null) return error.FontUnavailable;

    const requested_z = try allocator.dupeSentinel(u8, request.family, 0);
    defer allocator.free(requested_z);
    const missing = platform.coretext_family_exists(requested_z.ptr) == 0;
    const selected: [:0]const u8 = if (missing) fallback_family else requested_z;
    if (missing and platform.coretext_family_exists(selected.ptr) == 0) return error.FontUnavailable;

    // This is the same native family service used by text.font_catalog. Checking
    // it first prevents CoreText's silent Menlo Light / Monaco Bold downgrade.
    var available: [16]c_int = undefined;
    const count = platform.coretext_family_weights(selected.ptr, &available, available.len);
    if (count <= 0 or count > available.len) return error.FontUnavailable;
    var supported = false;
    for (available[0..@intCast(count)]) |value| {
        if (value == @backingInt(weight)) supported = true;
    }
    if (!supported) return error.UnsupportedWeight;

    const family_id = try registry.intern(selected);
    const font = registry.resolve(family_id, request.size, @backingInt(weight), false) orelse return error.FontUnavailable;
    // Font.weight contains the requested number. Query the actual native face
    // instead; no second font system, face creation, or debug-name parsing.
    const actual_family = try nativeFamily(allocator, font.ct_font);
    errdefer allocator.free(actual_family);
    if (!std.mem.eql(u8, actual_family, selected)) return error.FontUnavailable;
    const actual_weight = try nativeWeight(font.ct_font);
    if (actual_weight != weight) return error.UnsupportedWeight;

    const width = font.measureWidth("M");
    const ascent = font.getAscent();
    const descent = font.getDescent();
    if (!std.math.isFinite(width) or width <= 0 or !std.math.isFinite(ascent) or ascent <= 0 or
        !std.math.isFinite(descent) or descent < 0) return error.InvalidMetrics;
    const requested_family = try allocator.dupe(u8, request.family);
    return .{
        .requested_family = requested_family,
        .requested_size = request.size,
        .requested_weight = weight,
        .actual_family = actual_family,
        .actual_weight = actual_weight,
        .family_id = @backingInt(family_id),
        .cell_width = width,
        .ascent = ascent,
        .descent = descent,
        .fallback_reason = if (missing) .family_not_installed else null,
    };
}

fn nativeFamily(allocator: std.mem.Allocator, font: *anyopaque) ResolveError![]u8 {
    const family = platform.CTFontCopyFamilyName(font) orelse return error.FontUnavailable;
    defer platform.CFRelease(family);
    const maximum = platform.CFStringGetMaximumSizeForEncoding(platform.CFStringGetLength(family), platform.utf8);
    if (maximum < 0 or maximum == std.math.maxInt(isize)) return error.FontUnavailable;
    const buffer = try allocator.alloc(u8, @as(usize, @intCast(maximum)) + 1);
    defer allocator.free(buffer);
    if (platform.CFStringGetCString(family, buffer.ptr, @intCast(buffer.len), platform.utf8) == 0) return error.FontUnavailable;
    const length = std.mem.indexOfScalar(u8, buffer, 0) orelse return error.FontUnavailable;
    if (length == 0) return error.FontUnavailable;
    return allocator.dupe(u8, buffer[0..length]);
}

fn nativeWeight(font: *anyopaque) ResolveError!Weight {
    const traits = platform.CTFontCopyTraits(font) orelse return error.FontUnavailable;
    defer platform.CFRelease(traits);
    const number = platform.CFDictionaryGetValue(traits, platform.kCTFontWeightTrait) orelse return error.FontUnavailable;
    var native: f64 = undefined;
    if (platform.CFNumberGetValue(number, platform.number_double, &native) == 0 or !std.math.isFinite(native)) return error.FontUnavailable;
    // Match the existing font_catalog/CoreText bridge's CSS trait anchors. Read
    // the real trait, then reject a substituted tier; never echo Font.weight.
    const anchors = [_]struct { native: f64, css: u16 }{
        .{ .native = -0.80, .css = 100 }, .{ .native = -0.60, .css = 200 },
        .{ .native = -0.40, .css = 300 }, .{ .native = 0.00, .css = 400 },
        .{ .native = 0.23, .css = 500 },  .{ .native = 0.30, .css = 600 },
        .{ .native = 0.40, .css = 700 },  .{ .native = 0.56, .css = 800 },
        .{ .native = 0.62, .css = 900 },
    };
    var best: u16 = 0;
    var distance = std.math.inf(f64);
    for (anchors) |anchor| {
        const next = @abs(native - anchor.native);
        if (next < distance) {
            best = anchor.css;
            distance = next;
        }
    }
    return switch (best) {
        300 => .light,
        400 => .regular,
        500 => .medium,
        700 => .bold,
        else => error.UnsupportedWeight,
    };
}

// Read-only CoreText/CoreFoundation metadata on the FontRegistry-owned native
// face. Declarations follow the current macOS SDK headers. The family helpers
// are the existing Zenit CoreText bridge used by its public font_catalog.
const platform = struct {
    const utf8: u32 = 0x08000100; // kCFStringEncodingUTF8
    const number_double: c_int = 13; // kCFNumberDoubleType
    extern fn coretext_family_exists(family: [*:0]const u8) c_int;
    extern fn coretext_family_weights(family: [*:0]const u8, out: [*]c_int, capacity: c_int) c_int;
    extern "CoreText" fn CTFontCopyFamilyName(font: *const anyopaque) ?*const anyopaque;
    extern "CoreText" fn CTFontCopyTraits(font: *const anyopaque) ?*const anyopaque;
    extern "CoreText" const kCTFontWeightTrait: *const anyopaque;
    extern "CoreFoundation" fn CFStringGetLength(string: *const anyopaque) isize;
    extern "CoreFoundation" fn CFStringGetMaximumSizeForEncoding(length: isize, encoding: u32) isize;
    extern "CoreFoundation" fn CFStringGetCString(string: *const anyopaque, buffer: [*]u8, capacity: isize, encoding: u32) u8;
    extern "CoreFoundation" fn CFDictionaryGetValue(dictionary: *const anyopaque, key: *const anyopaque) ?*const anyopaque;
    extern "CoreFoundation" fn CFNumberGetValue(number: *const anyopaque, kind: c_int, value: *f64) u8;
    extern "CoreFoundation" fn CFRelease(value: *const anyopaque) void;
};

const FontSystem = @typeInfo(@typeInfo(@TypeOf(@as(FontRegistry, undefined).font_system)).optional.child).pointer.child;

test "appearance font rejects invalid requests before resolving a face" {
    var registry = FontRegistry.init(std.testing.allocator);
    defer registry.deinit();
    for ([_]f32{ 7, 49, std.math.nan(f32), std.math.inf(f32) }) |size| {
        try std.testing.expectError(error.InvalidSize, resolve(std.testing.allocator, &registry, .{ .family = "Menlo", .size = size }));
    }
    for ([_][]const u8{ "", "   ", "Menlo\x00Other", "bad\xff" }) |family| {
        try std.testing.expectError(error.InvalidFamily, resolve(std.testing.allocator, &registry, .{ .family = family, .size = 14 }));
    }
    try std.testing.expectError(error.InvalidWeight, resolve(std.testing.allocator, &registry, .{ .family = "Menlo", .size = 14, .weight = "semibold" }));
    try std.testing.expectError(error.FontUnavailable, resolve(std.testing.allocator, &registry, .{ .family = "Menlo", .size = 14 }));
}

test "appearance font Menlo uses the same registry face for actual metrics and weight" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var system = try FontSystem.init(std.testing.allocator, std.testing.io);
    defer system.deinit();
    var registry = FontRegistry.init(std.testing.allocator);
    defer registry.deinit();
    registry.setFontSystem(&system);
    for ([_]f32{ 8, 14, 48 }) |size| {
        for ([_][]const u8{ "regular", "bold" }) |weight| {
            var value = try resolve(std.testing.allocator, &registry, .{ .family = "Menlo", .size = size, .weight = weight });
            defer value.deinit(std.testing.allocator);
            try std.testing.expectEqualStrings("Menlo", value.actual_family);
            try std.testing.expectEqual(std.meta.stringToEnum(Weight, weight).?, value.actual_weight);
            try std.testing.expect(value.fallback_reason == null);
            const face = registry.resolve(@fromBackingInt(value.family_id), size, @backingInt(value.actual_weight), false).?;
            try std.testing.expectEqual(face.measureWidth("M"), value.cell_width);
            try std.testing.expectEqual(face.getAscent(), value.ascent);
            try std.testing.expectEqual(face.getDescent(), value.descent);
        }
    }
    try std.testing.expectError(error.UnsupportedWeight, resolve(std.testing.allocator, &registry, .{ .family = "Menlo", .size = 14, .weight = "light" }));
    try std.testing.expectError(error.UnsupportedWeight, resolve(std.testing.allocator, &registry, .{ .family = "Menlo", .size = 14, .weight = "medium" }));
}

test "appearance font Monaco regular resolves and unsupported bold is explicit" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var system = try FontSystem.init(std.testing.allocator, std.testing.io);
    defer system.deinit();
    var registry = FontRegistry.init(std.testing.allocator);
    defer registry.deinit();
    registry.setFontSystem(&system);
    var value = try resolve(std.testing.allocator, &registry, .{ .family = "Monaco", .size = 18 });
    defer value.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("Monaco", value.requested_family);
    try std.testing.expectEqualStrings("Monaco", value.actual_family);
    try std.testing.expectEqual(Weight.regular, value.actual_weight);
    try std.testing.expect(value.fallback_reason == null);
    try std.testing.expect(value.cell_width > 0 and value.ascent > 0 and value.descent >= 0);
    try std.testing.expectError(error.UnsupportedWeight, resolve(std.testing.allocator, &registry, .{ .family = "Monaco", .size = 18, .weight = "bold" }));
}

test "appearance font missing family preserves request and reports actual fallback" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var system = try FontSystem.init(std.testing.allocator, std.testing.io);
    defer system.deinit();
    var registry = FontRegistry.init(std.testing.allocator);
    defer registry.deinit();
    registry.setFontSystem(&system);
    const missing = "ZeroWorkDefinitelyUninstalledFont_20261018";
    var value = try resolve(std.testing.allocator, &registry, .{ .family = missing, .size = 14 });
    defer value.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(missing, value.requested_family);
    try std.testing.expectEqualStrings("Menlo", value.actual_family);
    try std.testing.expectEqual(Weight.regular, value.actual_weight);
    try std.testing.expectEqual(FallbackReason.family_not_installed, value.fallback_reason.?);
    const same_face = registry.resolve(try registry.intern("Menlo"), 14, 400, false).?;
    try std.testing.expectEqual(same_face.measureWidth("M"), value.cell_width);
}
