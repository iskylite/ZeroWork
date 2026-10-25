//! Host adaptation through the installed public TextareaResult/State fields.
//! Keep the native document, wrapping, IME and internal scrolling intact.
const ui = @import("ui");
pub const font_size: f32 = 12;
pub const line_height: f32 = 18;
pub fn configure(input: ui.widgets.input.TextareaResult) void {
    const state = input.state;
    state.font_size = font_size;
    state.padding_h = 10;
    state.padding_v = 8;
    // The public Textarea adds a dark edge fade even to a borderless editor.
    // Clear that decoration and match its list padding to the compact editor.
    if (state.vl_state) |list| {
        list.container_node.setStyleInline(state.allocator, .{ .padding = .{ .top = 8, .bottom = 8, .left = 10, .right = 10 }, .overflow_fade = .{ .size = 0, .color = ui.Color.TRANSPARENT } });
    }
    state.line_height = line_height;
    state.char_width = state.cx_ref.?.text.measureTextWidth("M", font_size, 400, false);
    state.wrap_map.font_size = font_size;
    state.wrap_map.char_width = state.char_width;
    if (state.vl_state) |list| list.props.item_height = line_height;
    state.dirty = true;
}
pub fn height(state: *const ui.widgets.input.TextareaState, compact_group_approval: bool) f32 {
    if (compact_group_approval) return 46;
    const lines = @min(5, @max(1, state.wrap_map.displayLineCount()));
    return @max(46, @as(f32, @floatFromInt(lines)) * line_height + state.padding_v * 2);
}
pub fn update(cx: *ui.Cx, input: ui.widgets.input.TextareaResult, composer: *ui.Node, compact: bool, attachment_height: f32) bool {
    const next = height(input.state, compact);
    if (input.input.style.height == .px and input.input.style.height.px == next and composer.style.height == .px and composer.style.height.px == next + 44 + attachment_height) return false;
    input.wrapper.setStyleInline(cx.allocator, .{ .height = .{ .px = next } });
    input.input.setStyleInline(cx.allocator, .{ .height = .{ .px = next } });
    composer.setStyleInline(cx.allocator, .{ .height = .{ .px = next + 44 + attachment_height } });
    input.state.dirty = true;
    return true;
}
