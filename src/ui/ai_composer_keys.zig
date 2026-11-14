//! Shared keyboard handling for the production AI composer and its tests.
const ui = @import("ui");

pub fn handleNavigation(key: ui.events.KeyEvent, textarea: *ui.widgets.input.TextareaState) bool {
    const mods = key.modifiers;
    if (ui.events.ShortcutPlatform.native != .mac or !mods.ctrl or mods.alt or mods.super or textarea.disabled) return false;
    const movement: ui.events.KeyCode = switch (key.key) {
        .a, .e => key.key,
        .b => .left,
        .f => .right,
        .p => .up,
        .n => .down,
        else => return false,
    };
    if (textarea.imeIsComposing()) return true;
    switch (movement) {
        .a, .e => {
            // AppKit's Ctrl+A/E move to the paragraph boundary across soft wraps.
            const line = textarea.doc.offsetToLineCol(textarea.cursor.offset).line;
            const target: u32 = @intCast(if (movement == .a) textarea.doc.getLineStart(line) else textarea.doc.getLineEnd(line));
            const anchor: u32 = if (mods.shift) @intCast(textarea.cursor.anchor orelse textarea.cursor.offset) else target;
            textarea.endImePendingCommit();
            return textarea.setAccessibilitySelection(anchor, target);
        },
        else => return ui.widgets.input.textareaEventHandler(.{ .key_down = .{ .key = movement, .modifiers = .{ .shift = mods.shift } } }, textarea) == .handled,
    }
}

pub const Action = enum { composing, newline, submit, alternate };
pub fn handleReturn(key: ui.events.KeyEvent, textarea: *ui.widgets.input.TextareaState) Action {
    if (textarea.imeIsComposing()) return .composing;
    if (key.modifiers.shift and (key.modifiers.super or key.modifiers.ctrl)) return .alternate;
    if (key.modifiers.shift or key.modifiers.super) {
        // Normalize modifiers: the editor inserts one newline at the current
        // selection, retaining its normal change callback, caret and undo path.
        _ = ui.widgets.input.textareaEventHandler(.{ .key_down = .{ .key = .@"return" } }, textarea);
        return .newline;
    }
    return .submit;
}
