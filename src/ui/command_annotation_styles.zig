//! One compact first-line metadata tag; AI is a plain origin label inside it.
//! Matches terminal-enhancement.css; the parent owns hover and copy exclusion.
const ui = @import("ui");
const theme = @import("app_theme.zig");

pub const metadata_height: f32 = 18;
pub const metadata_padding: f32 = 6;
pub const metadata_radius: f32 = 4;
pub const metadata_gap: f32 = 8;
pub const ai_font_size: f32 = 10;

pub fn metadataTop(row_height: f32) f32 {
    return @max(0, (row_height - metadata_height) / 2);
}
pub fn metadataTag(row_height: f32) ui.BoxStyle {
    const colors = theme.current();
    return .{ .position = .absolute, .inset = .{ .right = .{ .px = 0 }, .top = .{ .px = metadataTop(row_height) } }, .width = .{ .fit = .{} }, .height = .{ .px = @min(metadata_height, row_height) }, .direction = .row, .align_items = .center, .gap = metadata_gap, .padding = .{ .left = metadata_padding, .right = metadata_padding }, .corner_radius = metadata_radius, .background = colors.surface_2.withAlpha(255), .flex_shrink = 0, .hit_behavior = .pass_through, .z_index = 4 };
}
pub fn aiTag(row_height: f32) ui.BoxStyle {
    return .{ .width = .{ .fit = .{} }, .height = .{ .px = @min(14, row_height) }, .align_items = .center, .justify = .center, .background = ui.Color.TRANSPARENT, .flex_shrink = 0, .hit_behavior = .pass_through };
}
/// The presentation-only origin label shares its parent's tag surface.
pub fn mountAiTag(cx: *ui.Cx, family_id: u16, row_height: f32) !*ui.Node {
    const tag = try ui.text(cx, "AI", .{ .font_size = ai_font_size, .selectable = false });
    tag.meta.ownership.meta.component_name = "CommandAiTag";
    tag.meta.ownership.meta.test_id = "terminal.command.metadata.ai";
    applyAiTag(cx, tag, family_id, row_height);
    return tag;
}
pub fn applyAiTag(cx: *ui.Cx, tag: *ui.Node, family_id: u16, row_height: f32) void {
    tag.setStyleInline(cx.allocator, aiTag(row_height));
    var text = tag.getText().?;
    text.font_size = ai_font_size;
    text.line_height = 14.0 / ai_font_size;
    text.font_weight = 500;
    text.font_family = family_id;
    text.use_monospace_font = family_id == 0;
    text.selectable = false;
    text.color = theme.current().accent_ink;
    tag.setText(text);
}
