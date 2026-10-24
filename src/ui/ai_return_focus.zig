//! A dismissed assistant may return focus once to its original live terminal.
//! The host resolves the current tab/service; this helper never looks up an
//! active session or steals focus from another control.
const ui = @import("ui");
const identity = @import("../host/identity.zig");

pub const Ticket = struct {
    tab: identity.TabId,
    owner: identity.ContentOwner,
    group: ?u32 = null,

    pub fn matches(self: Ticket, current: Ticket) bool {
        return self.tab == current.tab and self.owner.eql(current.owner) and self.group == current.group;
    }
};

pub fn restore(cx: *ui.Cx, captured: Ticket, current: Ticket, terminal_input: *ui.Node, ai_panel: *ui.Node, allowed_toolbar_trigger: ?*ui.Node, ime_composing: bool) bool {
    if (ime_composing or !captured.matches(current) or captured.owner != .session) return false;
    const root = cx.root orelse return false;
    if (!within(terminal_input, root) or !visible(terminal_input) or
        !terminal_input.behavior.interaction.focusable or terminal_input.behavior.interaction.text_input_client == null) return false;
    if (cx.focus_manager.getFocused()) |focused| {
        if (focused == terminal_input) return true;
        if (!within(focused, ai_panel) and !if (allowed_toolbar_trigger) |trigger| within(focused, trigger) else false) return false;
    }
    cx.setFocus(terminal_input);
    return cx.focus_manager.getFocused() == terminal_input;
}

fn within(node: *ui.Node, ancestor: *ui.Node) bool {
    return node == ancestor or node.isDescendantOf(ancestor);
}

fn visible(node: *ui.Node) bool {
    if (!node.isDisplayedInTree()) return false;
    var current: ?*ui.Node = node;
    while (current) |value| : (current = value.parent) if (value.getOpacity() <= 0) return false;
    return true;
}
