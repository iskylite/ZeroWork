//! Compare retained production paint with a freshly mounted view in the same palette.
const std = @import("std");
const ui = @import("ui");
pub fn expectPaintEqual(retained: *ui.Node, fresh: *ui.Node) !void {
    errdefer std.debug.print("\nTheme paint mismatch: tag={s}, test_id={s}\n", .{ @tagName(retained.tag), retained.meta.ownership.meta.test_id orelse "(unlabelled)" });
    if (!ui.Color.eql(fresh.getBackground(), retained.getBackground())) std.debug.print("bg fresh={any} retained={any}\n", .{ fresh.getBackground(), retained.getBackground() });
    try std.testing.expectEqual(fresh.getBackground(), retained.getBackground());
    if (fresh.getText()) |text| try std.testing.expectEqual(text.color, retained.getText().?.color);
    if (fresh.getIcon()) |icon| try std.testing.expectEqual(icon.tint, retained.getIcon().?.tint);
    try std.testing.expectEqual(fresh.style.border.color, retained.style.border.color);
    try std.testing.expectEqual(fresh.style.border.width, retained.style.border.width);
    try std.testing.expectEqual(fresh.children.items.len, retained.children.items.len);
    for (retained.children.items, fresh.children.items) |a, b| try expectPaintEqual(a, b);
}
pub fn publish(cx: *ui.Cx, scope: *ui.Scope) !void {
    const publication = try scope.createState(@import("ui/shell_styles.zig").ThemePublication, .{});
    publication.publish(cx, @import("ui/app_theme.zig").widgetTheme(@import("ui/app_theme.zig").currentName()));
}
