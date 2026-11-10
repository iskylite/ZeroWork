//! Shared return-key handling for the production AI composer and its tests.
const ui = @import("ui");
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
