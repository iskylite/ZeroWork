//! Roll back a mount using the same silent teardown and identity retirement as unmount.
const ui = @import("ui");

pub fn rollback(cx: *ui.Cx, detached_portal: *ui.Node, detached_user: ?*ui.Node) void {
    // Scope cleanup may retire callback contexts. Suppress blur before retiring
    // identities, as normal unmount does, while the trees are still alive.
    cx.focus_manager.current_focus = null;
    cx.focus_manager.current_focus_handle = null;
    if (detached_portal.parent == null) cx.invalidateReferencesToEx(detached_portal, true);
    if (detached_user) |node| cx.invalidateReferencesToEx(node, true);
    cx.unmount();
    if (detached_user) |node| cx.freeDetachedNodeAfterScopeDispose(node);
}
