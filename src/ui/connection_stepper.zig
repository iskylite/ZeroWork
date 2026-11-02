//! Shared progress presentation for the SSH/SFTP and BMC connection editors.
//! Providers retain navigation, validation and draft ownership.
const ui = @import("ui");
const S = @import("wizard_styles.zig");

pub const Entry = struct {
    button: *ui.Node,
    badge: *ui.Node,
    digit: *ui.Node,
    check: *ui.Node,
    title: *ui.Node,
};

pub fn row(cx: *ui.Cx) !*ui.Node {
    var style = S.row(60);
    style.padding = ui.Padding.all(4);
    style.gap = 0;
    const root = try ui.box(cx, style, .{});
    root.meta.ownership.meta.test_id = "wizard.steps";
    return root;
}

pub fn append(cx: *ui.Cx, scope: *ui.Scope, root: *ui.Node, index: usize, id: []const u8, disabled: *ui.Signal(bool), style: *ui.Signal(ui.BoxStyle), clicked: ui.Handler(void)) !Entry {
    const labels = [_][]const u8{ "连接与认证", "连接路径", "核对与测试" };
    if (index != 0) {
        const line = try ui.box(cx, .{ .width = .fill(), .flex = 1, .height = .{ .px = 1 }, .background = S.theme.current().border, .flex_shrink = 0, .margin = .{ .left = 20, .right = 20 } }, .{});
        line.meta.ownership.meta.test_id = if (index == 1) "wizard.steps.connector.0" else "wizard.steps.connector.1";
        try root.appendChild(cx.allocator, line);
    }
    const button = try ui.widgets.Button(.{ .variant = .ghost, .a11y_label = labels[index], .base_style = style, .disabled = disabled, .on_click = clicked }).mount(scope, cx);
    for (button.children.items) |child| child.setDisplay(.none);
    button.meta.ownership.meta.test_id = id;
    const badge = try ui.box(cx, S.number(index == 0), .{});
    const digit = try ui.text(cx, ([_][]const u8{ "1", "2", "3" })[index], S.stepNumber());
    try badge.appendChild(cx.allocator, digit);
    const check = try ui.iconTint(cx, ui.icons.check, S.theme.current().accent_ink, S.icon(13));
    check.meta.ownership.meta.test_id = ([_][]const u8{ "wizard.step.identity.check", "wizard.step.route.check", "wizard.step.review.check" })[index];
    check.setDisplay(.none);
    try badge.appendChild(cx.allocator, check);
    try button.appendChild(cx.allocator, badge);
    const title = try ui.text(cx, labels[index], S.stepTitle(index == 0));
    try button.appendChild(cx.allocator, title);
    try root.appendChild(cx.allocator, button);
    return .{ .button = button, .badge = badge, .digit = digit, .check = check, .title = title };
}

pub fn paint(cx: *ui.Cx, entry: Entry, current: bool, completed: bool, invalid: bool) void {
    entry.button.setStyleInline(cx.allocator, S.step(current));
    entry.button.setOpacity(1);
    entry.badge.setStyleInline(cx.allocator, S.number(current));
    if (completed) entry.badge.setBackground(S.theme.popupSelection());
    const icon = if (invalid) ui.icons.circle_alert else ui.icons.check;
    const color = if (invalid) S.theme.current().danger_ink else S.theme.current().accent_ink;
    if (icon.icon_id) |id| if (icon.pickRep(13)) |rep| entry.check.setIcon(.{ .icon_id = id, .rep = rep, .tint = color });
    entry.check.setDisplay(if (completed or invalid) .flex else .none);
    entry.digit.setDisplay(if (completed or invalid) .none else .flex);
    entry.digit.setTextColor(if (current) S.action(true).color else S.theme.current().fg_2);
    entry.title.setTextColor(S.stepTitle(current).color);
    if (invalid) entry.badge.setBackground(S.theme.current().well);
}
