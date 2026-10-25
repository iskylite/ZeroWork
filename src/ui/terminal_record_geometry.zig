//! Pixel layout shared by live projection, replay, drawing and pointer mapping.
//! These values come from workspace/styles.css; they never enter VT text.
pub const margin: f32 = 13;
pub const padding_top: f32 = 9;
pub const padding_bottom: f32 = 10;
pub const result_gap: f32 = 5;
pub const radius: f32 = 8;
pub const padding_inline: f32 = 14;
// Natural system-font marker width measured in the final DOM (10px, 5px sides).
pub const marker_width: f32 = 56.5390625;
pub const command_inset: f32 = marker_width + 10;
pub const result_inset: f32 = 19;
pub const Layout = struct {
    y: ?f32 = null,
    before: f32 = 0,
    after: f32 = 0,
    shift_x: f32 = 0,
    article_y: f32 = 0,
    article_height: f32 = 0,
};
pub fn rowY(layout: Layout, index: usize, height: f32) f32 {
    return layout.y orelse @as(f32, @floatFromInt(index)) * height;
}
