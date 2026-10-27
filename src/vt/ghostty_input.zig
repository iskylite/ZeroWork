const std = @import("std");
const c = @import("generated_ghostty_vt");
const input = @import("input_event.zig");

pub fn key(terminal: c.GhosttyTerminal, event: input.KeyEvent, allocator: std.mem.Allocator) ![]u8 {
    return keyForType(terminal, event, allocator, .xterm_256color);
}
pub fn keyForType(terminal: c.GhosttyTerminal, event: input.KeyEvent, allocator: std.mem.Allocator, terminal_type: @import("terminal_type.zig").Type) ![]u8 {
    @setEvalBranchQuota(10000);
    if (event.utf8.len > 4096 or !std.unicode.utf8ValidateSlice(event.utf8)) return error.InvalidInput;
    var encoder: c.GhosttyKeyEncoder = null;
    if (c.ghostty_key_encoder_new(null, &encoder) != c.GHOSTTY_SUCCESS) return error.InputEncodingFailed;
    defer c.ghostty_key_encoder_free(encoder);
    c.ghostty_key_encoder_setopt_from_terminal(encoder, terminal);
    var option_as_alt: c.GhosttyOptionAsAlt = c.GHOSTTY_OPTION_AS_ALT_TRUE;
    c.ghostty_key_encoder_setopt(encoder, c.GHOSTTY_KEY_ENCODER_OPT_MACOS_OPTION_AS_ALT, @ptrCast(&option_as_alt));
    var native: c.GhosttyKeyEvent = null;
    if (c.ghostty_key_event_new(null, &native) != c.GHOSTTY_SUCCESS) return error.InputEncodingFailed;
    defer c.ghostty_key_event_free(native);
    c.ghostty_key_event_set_action(native, switch (event.action) {
        .press => c.GHOSTTY_KEY_ACTION_PRESS,
        .repeat => c.GHOSTTY_KEY_ACTION_REPEAT,
        .release => c.GHOSTTY_KEY_ACTION_RELEASE,
    });
    const key_code: c.GhosttyKey = switch (event.key) {
        inline else => |value| @field(c, "GHOSTTY_KEY_" ++ upper(@tagName(value))),
    };
    c.ghostty_key_event_set_key(native, key_code);
    c.ghostty_key_event_set_mods(native, @bitCast(event.modifiers));
    c.ghostty_key_event_set_consumed_mods(native, @bitCast(event.consumed_modifiers));
    c.ghostty_key_event_set_utf8(native, event.utf8.ptr, event.utf8.len);
    c.ghostty_key_event_set_unshifted_codepoint(native, event.unshifted_codepoint);
    c.ghostty_key_event_set_composing(native, event.composing);
    // One bounded encode avoids a second call that could advance encoder state.
    const buffer = try allocator.alloc(u8, event.utf8.len + 128);
    errdefer allocator.free(buffer);
    var count: usize = 0;
    if (c.ghostty_key_encoder_encode(encoder, native, buffer.ptr, buffer.len, &count) != c.GHOSTTY_SUCCESS) return error.InputEncodingFailed;
    var kitty_flags: u8 = 0;
    _ = c.ghostty_terminal_get(terminal, c.GHOSTTY_TERMINAL_DATA_KITTY_KEYBOARD_FLAGS, @ptrCast(&kitty_flags));
    if (count > 0 and kitty_flags == 0) if (@import("terminal_type.zig").legacyFunctionKey(terminal_type, event)) |bytes| {
        @memcpy(buffer[0..bytes.len], bytes);
        count = bytes.len;
    };
    // xterm-256color kf15/kf27/kf39/kf51/kf63 use modified SS3 F3
    // (CSI 1;modifier R). Ghostty's legacy encoder emits CSI 13;modifier~.
    // Keep negotiated Kitty protocol untouched.
    if (event.key == .f3 and count >= 7 and std.mem.startsWith(u8, buffer[0..count], "\x1b[13;") and buffer[count - 1] == '~') {
        @memcpy(buffer[0..4], "\x1b[1;");
        std.mem.copyForwards(u8, buffer[4 .. count - 2], buffer[5 .. count - 1]);
        buffer[count - 2] = 'R';
        count -= 1;
    }
    return allocator.realloc(buffer, count);
}
fn upper(comptime text: []const u8) [text.len]u8 {
    var result: [text.len]u8 = undefined;
    for (text, 0..) |value, i| result[i] = std.ascii.toUpper(value);
    return result;
}
pub fn mouse(terminal: c.GhosttyTerminal, event: input.MouseEvent, allocator: std.mem.Allocator) ![]u8 {
    if (!std.math.isFinite(event.x) or !std.math.isFinite(event.y) or event.screen_width == 0 or event.screen_height == 0 or event.cell_width == 0 or event.cell_height == 0) return error.InvalidGeometry;
    var encoder: c.GhosttyMouseEncoder = null;
    if (c.ghostty_mouse_encoder_new(null, &encoder) != c.GHOSTTY_SUCCESS) return error.InputEncodingFailed;
    defer c.ghostty_mouse_encoder_free(encoder);
    c.ghostty_mouse_encoder_setopt_from_terminal(encoder, terminal);
    const size: c.GhosttyMouseEncoderSize = .{ .size = @sizeOf(c.GhosttyMouseEncoderSize), .screen_width = event.screen_width, .screen_height = event.screen_height, .cell_width = event.cell_width, .cell_height = event.cell_height };
    c.ghostty_mouse_encoder_setopt(encoder, c.GHOSTTY_MOUSE_ENCODER_OPT_SIZE, @ptrCast(&size));
    c.ghostty_mouse_encoder_setopt(encoder, c.GHOSTTY_MOUSE_ENCODER_OPT_ANY_BUTTON_PRESSED, @ptrCast(&event.any_button_pressed));
    var native: c.GhosttyMouseEvent = null;
    if (c.ghostty_mouse_event_new(null, &native) != c.GHOSTTY_SUCCESS) return error.InputEncodingFailed;
    defer c.ghostty_mouse_event_free(native);
    c.ghostty_mouse_event_set_action(native, switch (event.action) {
        .press => c.GHOSTTY_MOUSE_ACTION_PRESS,
        .release => c.GHOSTTY_MOUSE_ACTION_RELEASE,
        .motion => c.GHOSTTY_MOUSE_ACTION_MOTION,
    });
    if (event.button != .none) c.ghostty_mouse_event_set_button(native, switch (event.button) {
        .none => unreachable,
        inline else => |value| @field(c, "GHOSTTY_MOUSE_BUTTON_" ++ upper(@tagName(value))),
    });
    c.ghostty_mouse_event_set_mods(native, @bitCast(event.modifiers));
    c.ghostty_mouse_event_set_position(native, .{ .x = event.x, .y = event.y });
    var buffer: [128]u8 = undefined;
    var count: usize = 0;
    if (c.ghostty_mouse_encoder_encode(encoder, native, &buffer, buffer.len, &count) != c.GHOSTTY_SUCCESS) return error.InputEncodingFailed;
    return allocator.dupe(u8, buffer[0..count]);
}
