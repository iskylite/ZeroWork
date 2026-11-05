const std = @import("std");
const appearance = @import("config/appearance_font.zig");
const FontRegistry = @import("zenit_app").FontRegistry;
const FontSystem = @typeInfo(@typeInfo(@TypeOf(@as(FontRegistry, undefined).font_system)).optional.child).pointer.child;

test {
    _ = appearance;
}

test "bundled terminal faces resolve exact family and supported weight through the painting registry" {
    try @import("platform/ui_fonts.zig").register();
    try @import("platform/ui_fonts.zig").register(); // Native registration is idempotent.
    var system = try FontSystem.init(std.testing.allocator, std.testing.io);
    defer system.deinit();
    var registry = FontRegistry.init(std.testing.allocator);
    defer registry.deinit();
    registry.setFontSystem(&system);
    for ([_][]const u8{ "Fira Code", "Source Code Pro" }) |family| {
        try std.testing.expect(appearance.isInstalled(family));
        const supported = appearance.supportedWeights(family);
        try std.testing.expectEqual(@as(usize, 4), supported.len);
        for ([_]f32{ 8, 14, 48 }) |size| {
            for ([_][]const u8{ "light", "regular", "medium", "bold" }) |weight| {
                var resolved = try appearance.resolve(std.testing.allocator, &registry, .{ .family = family, .size = size, .weight = weight });
                defer resolved.deinit(std.testing.allocator);
                try std.testing.expect(supported.contains(weight));
                try std.testing.expectEqualStrings(family, resolved.actual_family);
                try std.testing.expectEqual(std.meta.stringToEnum(appearance.Weight, weight).?, resolved.actual_weight);
                try std.testing.expect(resolved.fallback_reason == null);
                const font = registry.resolve(@fromBackingInt(resolved.family_id), size, @backingInt(resolved.actual_weight), false).?;
                try std.testing.expectEqual(font.measureWidth("M"), resolved.cell_width);
                try std.testing.expectApproxEqAbs(font.measureWidth("M"), font.measureWidth("i"), 0.01);
                try std.testing.expectEqual(font.getAscent(), resolved.ascent);
                try std.testing.expectEqual(font.getDescent(), resolved.descent);
                try std.testing.expect(font.measureWidth("中文终端") > 0);
            }
        }
    }
}

test "terminal weight choices follow native family and missing-family fallback" {
    const menlo = appearance.supportedWeights("Menlo");
    try std.testing.expectEqualSlices(appearance.Weight, &.{ .regular, .bold }, menlo.slice());
    const monaco = appearance.supportedWeights("Monaco");
    try std.testing.expectEqualSlices(appearance.Weight, &.{.regular}, monaco.slice());
    const missing = appearance.supportedWeights("ZeroWorkMissingFontWeightTest");
    try std.testing.expectEqualSlices(appearance.Weight, menlo.slice(), missing.slice());
}

test "variable weight axes preserve intermediate values in native faces and glyph pixels" {
    try @import("platform/ui_fonts.zig").register();
    const supported = appearance.supportedWeights("Inter Variable");
    try std.testing.expectEqual(@as(u16, 100), supported.variable.?.min);
    try std.testing.expectEqual(@as(u16, 900), supported.variable.?.max);
    try std.testing.expect(!supported.contains("99"));
    try std.testing.expect(!supported.contains("901"));
    var system = try FontSystem.init(std.testing.allocator, std.testing.io);
    defer system.deinit();
    var registry = FontRegistry.init(std.testing.allocator);
    defer registry.deinit();
    registry.setFontSystem(&system);
    var hashes: [2]u64 = undefined;
    for ([_][]const u8{ "100", "420", "421", "550", "900" }) |value| {
        var resolved = try appearance.resolve(std.testing.allocator, &registry, .{ .family = "Inter Variable", .size = 48, .weight = value });
        defer resolved.deinit(std.testing.allocator);
        try std.testing.expectEqual(appearance.parseWeight(value).?, resolved.actual_weight);
        const font = registry.resolve(@fromBackingInt(resolved.family_id), 48, @backingInt(resolved.actual_weight), false).?;
        if (std.mem.eql(u8, value, "420") or std.mem.eql(u8, value, "421")) {
            const glyph = try font.rasterizeGlyph(font.glyphIndexForCodepoint('M'));
            defer glyph.deinit(std.testing.allocator);
            hashes[if (std.mem.eql(u8, value, "420")) @as(usize, 0) else 1] = std.hash.Wyhash.hash(0, glyph.pixels);
        }
    }
    try std.testing.expect(hashes[0] != hashes[1]);
    try std.testing.expectError(error.UnsupportedWeight, appearance.resolve(std.testing.allocator, &registry, .{ .family = "Inter Variable", .size = 14, .weight = "901" }));
    if (appearance.isInstalled("Skia")) {
        const legacy = appearance.supportedWeights("Skia");
        try std.testing.expect(legacy.variable != null);
        for ([_][]const u8{ "100", "400", "550", "900" }) |value| {
            var resolved = try appearance.resolve(std.testing.allocator, &registry, .{ .family = "Skia", .size = 14, .weight = value });
            defer resolved.deinit(std.testing.allocator);
            try std.testing.expectEqual(appearance.parseWeight(value).?, resolved.actual_weight);
        }
    }
}

test "numeric weights accept legacy names and reject malformed values" {
    for ([_][]const u8{ "light", "regular", "semibold", "1", "420", "1000" }) |value| try std.testing.expect(appearance.parseWeight(value) != null);
    for ([_][]const u8{ "", "0", "1001", "420.5", "NaN", "-1", " 420", "4e2" }) |value| try std.testing.expect(appearance.parseWeight(value) == null);
}
