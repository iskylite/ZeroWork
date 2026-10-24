//! Follow new assistant output until the reader deliberately scrolls away.
const ui = @import("ui");
pub const Follow = struct {
    scroll: ui.widgets.ScrollAreaResult,
    following: bool = true,
    input_serial: u64 = 0,

    pub fn reset(self: *Follow) void {
        self.following = true;
        self.input_serial = self.scroll.state.input_serial;
    }
    /// Run after layout; never infer reader intent from content growth.
    pub fn update(self: *Follow) void {
        const state = self.scroll.state;
        if (state.input_serial != self.input_serial) {
            self.following = state.scroll_y >= state.maxScrollY() - 1;
            self.input_serial = state.input_serial;
        }
        state.content_height = self.scroll.content.globalRect().h;
        state.viewport_height = self.scroll.container.globalRect().h;
        if (self.following and @abs(state.scroll_y - state.maxScrollY()) > 0.1) ui.widgets.setScrollY(state, self.scroll.content, state.maxScrollY());
    }
};
