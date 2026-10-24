//! Wayland-native window bootstrap, independent of the GPU implementation.
//! This is not yet the full platform.Window / SystemSdk contract.
const Handle = opaque {};
pub const NativeSurface = extern struct {
    display: *anyopaque,
    surface: *anyopaque,
    logical_width: u32,
    logical_height: u32,
    pixel_width: u32,
    pixel_height: u32,
    scale: f32,
};
extern fn zenit_wayland_create([*:0]const u8, u32, u32) ?*Handle;
extern fn zenit_wayland_destroy(?*Handle) void;
extern fn zenit_wayland_set_title(?*Handle, [*:0]const u8) void;
extern fn zenit_wayland_clipboard_available(*Handle) c_int;
extern fn zenit_wayland_clipboard_set_text(*Handle, [*]const u8, usize) c_int;
extern fn zenit_wayland_clipboard_get_text_len(*Handle) c_int;
extern fn zenit_wayland_clipboard_get_text(*Handle, [*]u8, usize) c_int;
extern fn zenit_wayland_clipboard_set_png(*Handle, [*]const u8, usize) c_int;
extern fn zenit_wayland_clipboard_probe(*Handle) u32;
extern fn zenit_wayland_clipboard_write_ready(*Handle) c_int;
extern fn zenit_wayland_clipboard_get_png_len(*Handle) c_int;
extern fn zenit_wayland_clipboard_get_png(*Handle, [*]u8, usize) c_int;
extern fn zenit_wayland_ime_available(*Handle) c_int;
extern fn zenit_wayland_ime_set_enabled(*Handle, c_int) c_int;
extern fn zenit_wayland_ime_discard(*Handle) c_int;
extern fn zenit_wayland_ime_set_cursor_rect(*Handle, i32, i32, i32, i32) c_int;
extern fn zenit_wayland_ime_set_surrounding(*Handle, [*]const u8, usize, u32, u32) c_int;
extern fn zenit_wayland_ime_set_secure(*Handle, c_int) c_int;
extern fn zenit_wayland_poll(*Handle, c_int) c_int;
extern fn zenit_wayland_metrics(*Handle, *NativeSurface) c_int;
extern fn zenit_wayland_request_frame(*Handle) c_int;
extern fn zenit_wayland_request_frame_clock(*Handle) c_int;
extern fn zenit_wayland_frame_tick(*Handle) u64;
extern fn zenit_wayland_refresh_rate(*Handle) f32;
extern fn zenit_wayland_cancel_frame(*Handle) void;
extern fn zenit_wayland_set_maximized(*Handle, c_int) c_int;
extern fn zenit_wayland_set_minimized(*Handle) c_int;
extern fn zenit_wayland_close_requested(*Handle) c_int;
extern fn zenit_wayland_reset_close(*Handle) void;
extern fn zenit_wayland_close(*Handle) c_int;
extern fn zenit_wayland_decoration_height(*Handle) c_int;
extern fn zenit_wayland_window_state(*Handle) u32;
extern fn zenit_wayland_has_decorations(*Handle) c_int;
extern fn zenit_wayland_set_size(*Handle, u32, u32) c_int;
pub const CursorState = extern struct { desired_shape: u32 = 0, applied_shape: u32 = 0, apply_count: u32 = 0, pointer_focused: u32 = 0, compositor_theme: u32 = 0, theme_scale: u32 = 0 };
extern fn zenit_wayland_cursor_available(*Handle) c_int;
extern fn zenit_wayland_set_cursor(*Handle, u32) c_int;
extern fn zenit_wayland_cursor_state(*Handle, *CursorState) c_int;
pub const InputState = extern struct { x: f32 = 0, y: f32 = 0, buttons: u32 = 0, focused: u32 = 0 };
pub const ButtonEvent = extern struct { x: f32, y: f32, button: u32, pressed: u32, cancelled: u32 };
pub const ScrollEvent = extern struct { x: f32, y: f32, dx: f32, dy: f32 };
extern fn zenit_wayland_input_state(*Handle, *InputState) c_int;
extern fn zenit_wayland_pop_button(*Handle, *ButtonEvent) c_int;
extern fn zenit_wayland_pop_scroll(*Handle, *ScrollEvent) c_int;

pub const InputEvent = extern struct {
    kind: u32,
    keycode: u32,
    modifiers: u32,
    button: u32,
    pressed: u32,
    cancelled: u32,
    text_length: u32,
    x: f32,
    y: f32,
    dx: f32,
    dy: f32,
    text: [64]u8,
    owned_text: ?[*]const u8 = null,
    cursor_begin: i32 = 0,
    cursor_end: i32 = 0,
    delete_before: u32 = 0,
    delete_after: u32 = 0,
    scroll_phase: u32 = 0,
};
extern fn zenit_wayland_enable_ordered_input(*Handle) void;
extern fn zenit_wayland_peek_input(*Handle) c_int;
extern fn zenit_wayland_peek_input_event(*Handle, *InputEvent) c_int;
extern fn zenit_wayland_pop_input(*Handle, *InputEvent) c_int;

pub const Window = struct {
    handle: ?*Handle,
    pub fn imeAvailable(self: *Window) bool {
        return if (self.handle) |h| zenit_wayland_ime_available(h) == 1 else false;
    }
    pub fn imeSetEnabled(self: *Window, enabled: bool) c_int {
        return if (self.handle) |h| zenit_wayland_ime_set_enabled(h, @intFromBool(enabled)) else -3;
    }
    pub fn imeDiscard(self: *Window) c_int {
        return if (self.handle) |h| zenit_wayland_ime_discard(h) else -3;
    }
    pub fn imeSetCursorRect(self: *Window, x: i32, y: i32, w: i32, h: i32) c_int {
        return if (self.handle) |handle| zenit_wayland_ime_set_cursor_rect(handle, x, y, w, h) else -3;
    }
    pub fn imeSetSurrounding(self: *Window, text: []const u8, cursor: u32, anchor: u32, secure: bool) c_int {
        const h = self.handle orelse return -3;
        // Change purpose first: leaving a password client must permit the new
        // ordinary document, and entering one clears the old native context.
        const rc = zenit_wayland_ime_set_secure(h, @intFromBool(secure));
        if (rc != 0) return rc;
        // Never expose a password document, even to an incorrectly calling client.
        return zenit_wayland_ime_set_surrounding(h, if (secure) "" else text.ptr, if (secure) 0 else text.len, if (secure) 0 else cursor, if (secure) 0 else anchor);
    }
    pub fn cursorAvailable(self: *Window) bool {
        return if (self.handle) |handle| zenit_wayland_cursor_available(handle) == 1 else false;
    }
    pub fn setCursorShape(self: *Window, shape: u8) bool {
        return if (self.handle) |handle| zenit_wayland_set_cursor(handle, shape) == 1 else false;
    }
    pub fn cursorState(self: *Window) CursorState {
        var state: CursorState = .{};
        if (self.handle) |handle| _ = zenit_wayland_cursor_state(handle, &state);
        return state;
    }
    pub fn enableOrderedInput(self: *Window) void {
        if (self.handle) |handle| zenit_wayland_enable_ordered_input(handle);
    }
    pub fn peekInputKind(self: *const Window) u32 {
        return if (self.handle) |handle| @intCast(zenit_wayland_peek_input(handle)) else 0;
    }
    pub fn peekInputEvent(self: *Window) ?InputEvent {
        const handle = self.handle orelse return null;
        var event: InputEvent = undefined;
        return if (zenit_wayland_peek_input_event(handle, &event) == 1) event else null;
    }
    pub fn popInputEvent(self: *Window) ?InputEvent {
        const handle = self.handle orelse return null;
        var event: InputEvent = undefined;
        return if (zenit_wayland_pop_input(handle, &event) == 1) event else null;
    }
    pub fn frameTick(self: *const Window) u64 {
        return if (self.handle) |handle| zenit_wayland_frame_tick(handle) else 0;
    }
    pub fn refreshRate(self: *const Window) f32 {
        return if (self.handle) |handle| zenit_wayland_refresh_rate(handle) else 60;
    }
    pub fn inputState(self: *const Window) InputState {
        var state: InputState = .{};
        if (self.handle) |handle| _ = zenit_wayland_input_state(handle, &state);
        return state;
    }
    pub fn popButton(self: *Window) ?ButtonEvent {
        const handle = self.handle orelse return null;
        var event: ButtonEvent = undefined;
        return if (zenit_wayland_pop_button(handle, &event) == 1) event else null;
    }
    pub fn popScroll(self: *Window) ?ScrollEvent {
        const handle = self.handle orelse return null;
        var event: ScrollEvent = undefined;
        return if (zenit_wayland_pop_scroll(handle, &event) == 1) event else null;
    }
    pub fn clipboardAvailable(self: *const Window) bool {
        return if (self.handle) |h| zenit_wayland_clipboard_available(h) != 0 else false;
    }
    pub fn clipboardSetText(self: *Window, text: []const u8) c_int {
        return zenit_wayland_clipboard_set_text(self.handle orelse return -3, text.ptr, text.len);
    }
    pub fn clipboardGetTextLen(self: *Window) c_int {
        return zenit_wayland_clipboard_get_text_len(self.handle orelse return -3);
    }
    pub fn clipboardGetText(self: *Window, buffer: []u8) c_int {
        return zenit_wayland_clipboard_get_text(self.handle orelse return -3, buffer.ptr, buffer.len);
    }
    pub fn clipboardSetImagePng(self: *Window, bytes: []const u8) c_int {
        return zenit_wayland_clipboard_set_png(self.handle orelse return -3, bytes.ptr, bytes.len);
    }
    pub fn clipboardProbe(self: *Window) u32 {
        return zenit_wayland_clipboard_probe(self.handle orelse return 0);
    }
    pub fn clipboardWriteReady(self: *const Window) bool {
        return zenit_wayland_clipboard_write_ready(self.handle orelse return false) != 0;
    }
    pub fn clipboardGetImagePngLen(self: *Window) c_int {
        return zenit_wayland_clipboard_get_png_len(self.handle orelse return -3);
    }
    pub fn clipboardGetImagePng(self: *Window, buffer: []u8) c_int {
        return zenit_wayland_clipboard_get_png(self.handle orelse return -3, buffer.ptr, buffer.len);
    }
    pub fn init(title: [:0]const u8, width: u32, height: u32) !Window {
        return .{ .handle = zenit_wayland_create(title, width, height) orelse return error.WaylandWindowUnavailable };
    }
    pub fn setTitle(self: *Window, title: [:0]const u8) void {
        zenit_wayland_set_title(self.handle, title.ptr);
    }

    pub fn deinit(self: *Window) void {
        zenit_wayland_destroy(self.handle);
        self.handle = null;
    }
    pub fn poll(self: *Window, timeout_ms: u31) !bool {
        const handle = self.handle orelse return false;
        return switch (zenit_wayland_poll(handle, @intCast(timeout_ms))) {
            0 => false,
            1 => true,
            else => error.WaylandDisconnected,
        };
    }
    pub fn nativeSurface(self: *Window) !NativeSurface {
        const handle = self.handle orelse return error.WindowClosed;
        var result: NativeSurface = undefined;
        if (zenit_wayland_metrics(handle, &result) != 1) return error.WindowClosed;
        return result;
    }
    pub fn requestFrame(self: *Window) !bool {
        const handle = self.handle orelse return error.WindowClosed;
        return switch (zenit_wayland_request_frame(handle)) {
            0 => false,
            1 => true,
            else => error.WaylandDisconnected,
        };
    }
    pub fn requestFrameClock(self: *Window) !bool {
        const handle = self.handle orelse return error.WindowClosed;
        return switch (zenit_wayland_request_frame_clock(handle)) {
            0 => false,
            1 => true,
            else => error.WaylandDisconnected,
        };
    }
    pub fn cancelFrame(self: *Window) void {
        if (self.handle) |handle| zenit_wayland_cancel_frame(handle);
    }
    pub fn setMaximized(self: *Window, maximized: bool) !void {
        const handle = self.handle orelse return error.WindowClosed;
        if (zenit_wayland_set_maximized(handle, @intFromBool(maximized)) != 1) return error.WindowClosed;
    }
    pub fn minimize(self: *Window) !void {
        const handle = self.handle orelse return error.WindowClosed;
        if (zenit_wayland_set_minimized(handle) != 1) return error.WindowClosed;
    }
    pub fn close(self: *Window) !void {
        const handle = self.handle orelse return error.WindowClosed;
        if (zenit_wayland_close(handle) != 1) return error.WindowClosed;
    }
    pub fn closeRequested(self: *Window) bool {
        return if (self.handle) |h| zenit_wayland_close_requested(h) != 0 else false;
    }
    pub fn resetCloseRequested(self: *Window) void {
        if (self.handle) |h| zenit_wayland_reset_close(h);
    }
    pub fn decorationHeight(self: *Window) i32 {
        return if (self.handle) |handle| zenit_wayland_decoration_height(handle) else 0;
    }
    pub fn windowState(self: *Window) u32 {
        return if (self.handle) |handle| zenit_wayland_window_state(handle) else 0;
    }
    pub fn hasDecorations(self: *Window) bool {
        return if (self.handle) |handle| zenit_wayland_has_decorations(handle) == 1 else false;
    }
    pub fn setSize(self: *Window, width: u32, height: u32) !void {
        const handle = self.handle orelse return error.WindowClosed;
        if (zenit_wayland_set_size(handle, width, height) != 1) return error.InvalidWindowSize;
    }
};
