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
        for ([_]f32{ 8, 14, 48 }) |size| {
            for ([_][]const u8{ "light", "regular", "medium", "bold" }) |weight| {
                var resolved = try appearance.resolve(std.testing.allocator, &registry, .{ .family = family, .size = size, .weight = weight });
                defer resolved.deinit(std.testing.allocator);
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
