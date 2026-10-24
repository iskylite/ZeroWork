//! Linux platform window adapter over the real xdg-shell surface. Input and
//! desktop-service hooks below remain explicit integration work; they are not
//! part of the completed GPU/window lifecycle gate yet.
const std = @import("std");
const wl = @import("wayland/window.zig");
const common = @import("../unsupported/window.zig").UnsupportedWindow;
var next_window_id: u32 = 1;
var live_windows: u32 = 0;
pub const LinuxWindow = struct {
    native: wl.Window,
    surface: wl.NativeSurface,
    id: u32,
    closed: bool = false,
    redraw: bool = true,
    display_link_running: bool = false,
    render_callback: ?*const fn (?*anyopaque) callconv(.c) void = null,
    render_context: ?*anyopaque = null,
    pub const WindowRecordingState = common.WindowRecordingState;
    pub const MouseButton = common.MouseButton;
    pub const Modifiers = common.Modifiers;
    pub const KeyEvent = struct { keycode: u16, modifiers: Modifiers, character: ?u8 = null, pressed: bool = true };
    pub const KeyCode = struct {
        pub const RETURN: u16 = 28;
        pub const TAB: u16 = 15;
        pub const SPACE: u16 = 57;
        pub const DELETE: u16 = 14;
        pub const ESCAPE: u16 = 1;
        pub const LEFT: u16 = 105;
        pub const RIGHT: u16 = 106;
        pub const DOWN: u16 = 108;
        pub const UP: u16 = 103;
        pub const FORWARD_DELETE: u16 = 111;
        pub const HOME: u16 = 102;
        pub const END: u16 = 107;
        pub const PAGE_UP: u16 = 104;
        pub const PAGE_DOWN: u16 = 109;
        pub const A: u16 = 30;
        pub const C: u16 = 46;
        pub const V: u16 = 47;
        pub const X: u16 = 45;
        pub const Z: u16 = 44;
    };
    pub const ScrollEvent = common.ScrollEvent;
    pub const TextInputEvent = common.TextInputEvent;
    pub const ImePreeditEvent = common.ImePreeditEvent;
    pub const ImeCommitEvent = common.ImeCommitEvent;
    pub const MouseButtonEvent = struct { x: f32, y: f32, button: MouseButton, pressed: bool, cancelled: bool = false };
    pub const MouseMoveEvent = common.MouseMoveEvent;
    pub const InputQueueMetrics = common.InputQueueMetrics;
    pub const MenuAction = common.MenuAction;
    pub const MenuActionEvent = common.MenuActionEvent;
    pub const ime_no_replacement = common.ime_no_replacement;

    pub fn initAppWithDelegate() void {}
    pub fn init(width: u32, height: u32, title: [:0]const u8) !LinuxWindow {
        var native = try wl.Window.init(title, width, height);
        errdefer native.deinit();
        native.enableOrderedInput();
        const surface = try native.nativeSurface();
        const id = next_window_id;
        next_window_id += 1;
        live_windows += 1;
        return .{ .native = native, .surface = surface, .id = id };
    }
    pub fn deinit(self: *LinuxWindow) void {
        if (self.native.handle == null) return;
        self.native.deinit();
        self.closed = true;
        live_windows -= 1;
    }
    pub fn beginClose(self: *LinuxWindow) bool {
        self.closed = true;
        return true;
    }
    pub fn closeCompleted(self: *const LinuxWindow) bool {
        return self.closed;
    }
    pub fn liveWindowCount() u32 {
        return live_windows;
    }
    pub fn nativeSurface(self: *LinuxWindow) !wl.NativeSurface {
        self.surface = try self.native.nativeSurface();
        return self.surface;
    }
    fn refreshMetrics(self: *LinuxWindow) void {
        const metrics = self.native.nativeSurface() catch {
            self.closed = true;
            return;
        };
        if (metrics.pixel_width != self.surface.pixel_width or metrics.pixel_height != self.surface.pixel_height) self.redraw = true;
        self.surface = metrics;
    }
    pub fn pollEvents(self: *LinuxWindow) bool {
        return self.pollEventsWithTimeout(0);
    }
    pub fn poll(self: *LinuxWindow, timeout_ms: u31) !bool {
        const alive = try self.native.poll(timeout_ms);
        if (!alive) self.closed = true;
        self.refreshMetrics();
        if (self.display_link_running) _ = self.native.requestFrameClock() catch {
            self.closed = true;
        };
        return !self.closed;
    }
    pub fn requestFrame(self: *LinuxWindow) !bool {
        return self.native.requestFrame();
    }
    pub fn cancelFrame(self: *LinuxWindow) void {
        self.native.cancelFrame();
    }
    pub fn pollEventsWithTimeout(self: *LinuxWindow, timeout_ms: u32) bool {
        if (self.closed) return false;
        const alive = self.native.poll(@intCast(@min(timeout_ms, std.math.maxInt(u31)))) catch false;
        if (!alive) self.closed = true;
        self.refreshMetrics();
        if (self.display_link_running) _ = self.native.requestFrameClock() catch {
            self.closed = true;
        };
        return !self.closed;
    }
    pub fn getSize(self: *LinuxWindow) [2]u32 {
        self.refreshMetrics();
        return .{ self.surface.logical_width, self.surface.logical_height };
    }
    pub fn getDrawableSize(self: *LinuxWindow) [2]u32 {
        self.refreshMetrics();
        return .{ self.surface.pixel_width, self.surface.pixel_height };
    }
    pub fn getScaleFactor(self: *LinuxWindow) f32 {
        self.refreshMetrics();
        return self.surface.scale;
    }
    pub fn getNativeSurfaceHandle(self: *LinuxWindow) *anyopaque {
        self.refreshMetrics();
        return @ptrCast(&self.surface);
    }
    pub fn getNativeDeviceHandle(self: *LinuxWindow) *anyopaque {
        return self.surface.display;
    }
    pub fn getWindowId(self: *LinuxWindow) u32 {
        return self.id;
    }
    pub fn getDisplayRefreshRate(self: *LinuxWindow) f32 {
        return self.native.refreshRate();
    }
    pub fn setMaximized(self: *LinuxWindow, value: bool) !void {
        try self.native.setMaximized(value);
    }
    pub fn minimize(self: *LinuxWindow) !void {
        try self.native.minimize();
    }
    pub fn closeNative(self: *LinuxWindow) !void {
        try self.native.close();
    }
    pub fn setSize(self: *LinuxWindow, width: u32, height: u32) void {
        self.native.setSize(width, height) catch |err| std.log.warn("Wayland size request failed: {s}", .{@errorName(err)});
    }
    pub fn shouldClose(self: *LinuxWindow) bool {
        return self.closed or self.native.closeRequested();
    }
    pub fn checkShouldClose(self: *LinuxWindow) bool {
        return self.native.closeRequested();
    }
    pub fn resetShouldClose(self: *LinuxWindow) void {
        self.native.resetCloseRequested();
    }
    pub fn requestRedraw(self: *LinuxWindow) void {
        self.redraw = true;
    }
    pub fn shouldRender(self: *LinuxWindow) bool {
        return !self.closed and self.redraw;
    }
    pub fn setRenderCallback(self: *LinuxWindow, callback: ?*const fn (?*anyopaque) callconv(.c) void, context: ?*anyopaque) void {
        self.render_callback = callback;
        self.render_context = context;
    }
    pub fn isInLiveResize(self: *LinuxWindow) bool {
        _ = self;
        return false;
    }
    // Share the runtime's tick gate using compositor callbacks. Requests are
    // committed immediately so restarting after idle cannot starve the tick gate.
    pub fn getDisplayTick(self: *const LinuxWindow) u64 {
        return self.native.frameTick();
    }
    pub fn startDisplayLink(self: *LinuxWindow) void {
        self.display_link_running = true;
        _ = self.native.requestFrameClock() catch {
            self.closed = true;
        };
    }
    pub fn stopDisplayLink(self: *LinuxWindow) void {
        self.display_link_running = false;
        self.native.cancelFrame();
    }
    pub fn pumpAppEvents() void {}
    pub fn postEmptyEvent() void {}
    pub fn appShouldQuit() bool {
        return false;
    }
    pub fn cancelAppQuit() void {}
    pub fn activate(self: *LinuxWindow) void {
        _ = self;
    }
    // Owned windows are not wired to xdg_toplevel.set_parent yet; Wayland also
    // forbids client positioning, so placement stays with the compositor.
    pub fn setOwner(self: *LinuxWindow, owner: *LinuxWindow) bool {
        _ = self;
        _ = owner;
        return false;
    }
    pub fn clearOwner(self: *LinuxWindow, owner: *LinuxWindow) void {
        _ = self;
        _ = owner;
    }
    pub fn centerOnOwner(self: *LinuxWindow, owner: *LinuxWindow) bool {
        _ = self;
        _ = owner;
        return false;
    }
    pub fn armFocusLossReporting(self: *LinuxWindow) void {
        _ = self;
    }
    pub fn takeFocusLoss(self: *LinuxWindow) ?@import("../owned_window.zig").FocusLoss {
        _ = self;
        return null;
    }
    pub fn setTrafficLightsInset(self: *LinuxWindow, x: f32, y: f32) void {
        _ = self;
        _ = x;
        _ = y;
    }
    /// Change the window title after creation (libdecor frame title).
    pub fn setTitle(self: *LinuxWindow, title: [:0]const u8) void {
        self.native.setTitle(title);
    }

    pub fn setTitlebarDragHeight(self: *LinuxWindow, height: f32) void {
        _ = self;
        _ = height;
    }
    pub fn setTitlebarDragRightInset(self: *LinuxWindow, inset: f32) void {
        _ = self;
        _ = inset;
    }
    pub fn getTitlebarHeight(self: *LinuxWindow) f32 {
        _ = self;
        return 0;
    }
    pub fn showBlockingAlert(title: [:0]const u8, message: [:0]const u8) void {
        std.log.err("{s}: {s}", .{ title, message });
    }
    pub fn clipboardAvailable(self: *const LinuxWindow) bool {
        return self.native.clipboardAvailable();
    }
    pub fn clipboardSetText(self: *LinuxWindow, text: []const u8) c_int {
        return self.native.clipboardSetText(text);
    }
    pub fn clipboardGetTextLen(self: *LinuxWindow) c_int {
        return self.native.clipboardGetTextLen();
    }
    pub fn clipboardGetText(self: *LinuxWindow, buffer: []u8) c_int {
        return self.native.clipboardGetText(buffer);
    }
    pub fn clipboardSetImagePng(self: *LinuxWindow, bytes: []const u8) c_int {
        return self.native.clipboardSetImagePng(bytes);
    }
    pub fn clipboardProbe(self: *LinuxWindow) u32 {
        return self.native.clipboardProbe();
    }
    pub fn clipboardWriteReady(self: *const LinuxWindow) bool {
        return self.native.clipboardWriteReady();
    }
    pub fn clipboardGetImagePngLen(self: *LinuxWindow) c_int {
        return self.native.clipboardGetImagePngLen();
    }
    pub fn clipboardGetImagePng(self: *LinuxWindow, bytes: []u8) c_int {
        return self.native.clipboardGetImagePng(bytes);
    }
    pub fn getMousePosition(self: *LinuxWindow) [2]f32 {
        const state = self.native.inputState();
        return .{ state.x, state.y };
    }
    pub fn peekInputKind(self: *const LinuxWindow) u32 {
        return self.native.peekInputKind();
    }
    pub fn peekInputEvent(self: *LinuxWindow) ?wl.InputEvent {
        return self.native.peekInputEvent();
    }
    pub fn popInputEvent(self: *LinuxWindow) ?wl.InputEvent {
        return self.native.popInputEvent();
    }
    fn modifiers(raw: u32) Modifiers {
        return .{ .shift = raw & 1 != 0, .ctrl = raw & 2 != 0, .alt = raw & 4 != 0, .cmd = raw & 8 != 0 };
    }
    pub fn getMouseMoveEvent(self: *LinuxWindow) ?MouseMoveEvent {
        if (self.peekInputKind() != 4) return null;
        const event = self.popInputEvent() orelse return null;
        return .{ .sequence = 0, .x = event.x, .y = event.y, .dx = event.dx, .dy = event.dy, .modifiers = modifiers(event.modifiers) };
    }
    pub fn isMouseButtonPressed(self: *LinuxWindow, button: MouseButton) bool {
        return self.native.inputState().buttons & (@as(u32, 1) << @intCast(@backingInt(button))) != 0;
    }
    pub fn getKeyEvent(self: *LinuxWindow) ?KeyEvent {
        if (self.peekInputKind() != 2) return null;
        const event = self.popInputEvent() orelse return null;
        return .{ .keycode = @intCast(event.keycode), .pressed = event.pressed != 0, .modifiers = modifiers(event.modifiers) };
    }
    pub fn getScrollDelta(self: *LinuxWindow) ?ScrollEvent {
        if (self.peekInputKind() != 5) return null;
        const event = self.popInputEvent() orelse return null;
        return .{ .x = event.x, .y = event.y, .dx = event.dx, .dy = event.dy, .phase = 0, .momentum = 0 };
    }
    pub fn getMouseButtonEvent(self: *LinuxWindow) ?MouseButtonEvent {
        if (self.peekInputKind() != 1) return null;
        const event = self.popInputEvent() orelse return null;
        return .{ .x = event.x, .y = event.y, .button = @fromBackingInt(@intCast(event.button)), .pressed = event.pressed != 0, .cancelled = event.cancelled != 0 };
    }
    pub fn getInputText(self: *LinuxWindow, buffer: []u8) ?TextInputEvent {
        if (self.peekInputKind() != 3) return null;
        const event = self.peekInputEvent() orelse return null;
        if (buffer.len < event.text_length) return null;
        @memcpy(buffer[0..event.text_length], event.text[0..event.text_length]);
        _ = self.popInputEvent();
        return .{ .text = buffer[0..event.text_length] };
    }
    pub fn getImePreedit(self: *LinuxWindow, buffer: []u8) ?ImePreeditEvent {
        _ = self;
        _ = buffer;
        return null;
    }
    pub fn getImeCommit(self: *LinuxWindow, buffer: []u8) ?ImeCommitEvent {
        _ = self;
        _ = buffer;
        return null;
    }
    pub fn setImeCursorRect(self: *LinuxWindow, x: f32, y: f32, w: f32, h: f32) void {
        _ = self;
        _ = x;
        _ = y;
        _ = w;
        _ = h;
    }
    pub fn imeAvailable(self: *LinuxWindow) bool {
        return self.native.imeAvailable();
    }
    pub fn imeSetEnabled(self: *LinuxWindow, enabled: bool) c_int {
        return self.native.imeSetEnabled(enabled);
    }
    pub fn imeDiscard(self: *LinuxWindow) c_int {
        return self.native.imeDiscard();
    }
    pub fn imeSetSurrounding(self: *LinuxWindow, text: []const u8, cursor: u32, anchor: u32, secure: bool) c_int {
        return self.native.imeSetSurrounding(text, cursor, anchor, secure);
    }
    pub fn imeSetCursorRect(self: *LinuxWindow, x: f32, y: f32, w: f32, h: f32) c_int {
        const values = [_]f32{ x, y, w, h };
        for (values) |v| if (!std.math.isFinite(v) or v < -2147483648.0 or v >= 2147483648.0) return -6;
        if (w < 0 or h < 0) return -6;
        return self.native.imeSetCursorRect(@intFromFloat(@floor(x)), @intFromFloat(@floor(y)), @intFromFloat(@ceil(w)), @intFromFloat(@ceil(h)));
    }
    pub fn cursorAvailable(self: *LinuxWindow) bool {
        return self.native.cursorAvailable();
    }
    pub fn setCursorShapeChecked(self: *LinuxWindow, shape: u8) bool {
        return self.native.setCursorShape(shape);
    }
    pub fn cursorState(self: *LinuxWindow) wl.CursorState {
        return self.native.cursorState();
    }
    pub fn setCursorShape(self: *LinuxWindow, shape: u8) void {
        _ = self.setCursorShapeChecked(shape);
    }
    pub fn updateMousePosition(self: *LinuxWindow) void {
        _ = self;
    }
    pub fn updateWindowMouse(self: *LinuxWindow) void {
        _ = self;
    }
    pub fn setAcceptsMouseWhileInactive(self: *LinuxWindow, accepts: bool) void {
        _ = self;
        _ = accepts;
    }
    pub fn isFocused(self: *LinuxWindow) bool {
        return self.native.inputState().focused != 0;
    }
    pub fn inputQueueMetrics() InputQueueMetrics {
        return .{ .mouse_move_coalesced = 0, .ime_preedit_coalesced = 0 };
    }
    pub fn getMenuActionEvent() ?MenuActionEvent {
        return null;
    }
    pub fn getMenuAction() ?MenuAction {
        return null;
    }
    pub fn getPendingOpenFile(self: *LinuxWindow, buffer: []u8) error{BufferTooSmall}!?[]const u8 {
        _ = self;
        _ = buffer;
        return null;
    }
    pub fn pendingOpenFileRequiredSize(self: *LinuxWindow) ?usize {
        _ = self;
        return null;
    }
    fn unsupportedRecording() WindowRecordingState {
        var state: WindowRecordingState = .{};
        const message = "Linux window recording is not implemented";
        @memcpy(state.error_message[0..message.len], message);
        return state;
    }
    pub fn startWindowRecording(self: *LinuxWindow, path: []const u8, fps: u32) WindowRecordingState {
        _ = self;
        _ = path;
        _ = fps;
        return unsupportedRecording();
    }
    pub fn windowRecordingStatus(self: *LinuxWindow) WindowRecordingState {
        _ = self;
        return unsupportedRecording();
    }
    pub fn appendWindowRecordingFrame(self: *LinuxWindow, texture: *anyopaque) bool {
        _ = self;
        _ = texture;
        return false;
    }
    pub fn stopWindowRecording(self: *LinuxWindow) WindowRecordingState {
        _ = self;
        return unsupportedRecording();
    }
};
