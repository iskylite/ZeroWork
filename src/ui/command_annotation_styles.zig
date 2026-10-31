//! Compact first-line AI origin tag. Matches terminal-enhancement.css .meta-ai;
//! its existing metadata parent still owns visibility, hover and copy exclusion.
const ui = @import("ui");
const theme = @import("app_theme.zig");

pub const ai_height: f32 = 16;
pub const ai_padding: f32 = 4;
pub const ai_radius: f32 = 4;
pub const ai_font_size: f32 = 10;
pub const metadata_gap: f32 = 10;
/// The two narrower gaps compensate the tag's 8px horizontal padding, keeping
/// the first-row group as compact as its preceding plain-text AI treatment.
pub const ai_metadata_gap: f32 = 6;

pub fn aiTag(row_height: f32) ui.BoxStyle {
    return .{ .width = .{ .fit = .{} }, .height = .{ .px = @min(ai_height, row_height) }, .padding = .{ .left = ai_padding, .right = ai_padding }, .corner_radius = ai_radius, .align_items = .center, .justify = .center, .background = theme.popupSelection(), .flex_shrink = 0, .hit_behavior = .pass_through };
}
/// The library Badge fixes its solid status palette and capsule recipe during
/// theme application. This presentation-only tag uses the application's existing
/// soft badge surface, so a noninteractive text primitive owns this small style.
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
