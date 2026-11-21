//! Shared segmented three-step progress track for connection editors.
//! Providers retain navigation, validation and draft ownership.
const std = @import("std");
const ui = @import("ui");
const S = @import("wizard_styles.zig");

pub const default_labels = [3][]const u8{ "连接与认证", "连接路径", "核对与测试" };
pub const step_ids = [3][]const u8{ "wizard.step.identity", "wizard.step.route", "wizard.step.review" };
pub const check_ids = [3][]const u8{ "wizard.step.identity.check", "wizard.step.route.check", "wizard.step.review.check" };

pub const Entry = struct {
    button: *ui.Node,
    badge: *ui.Node,
    digit: *ui.Node,
    check: *ui.Node,
    title: *ui.Node,
    style: *ui.Signal(ui.BoxStyle),
};

pub fn rowStyle(compact: bool) ui.BoxStyle {
    return S.reviewStepTrack(compact);
}

pub fn row(cx: *ui.Cx) !*ui.Node {
    const root = try ui.box(cx, rowStyle(false), .{});
    root.meta.ownership.meta.test_id = "wizard.steps";
    return root;
}

pub fn layout(cx: *ui.Cx, root: *ui.Node, compact: bool) void {
    root.setStyleInline(cx.allocator, rowStyle(compact));
}

pub fn paintTrack(root: *ui.Node) void {
    root.setBackground(S.theme.popupInset());
}

pub fn append(cx: *ui.Cx, scope: *ui.Scope, root: *ui.Node, index: usize, id: []const u8, disabled: *ui.Signal(bool), style: *ui.Signal(ui.BoxStyle), clicked: ui.Handler(void)) !Entry {
    return appendLabeled(cx, scope, root, index, default_labels[index], id, disabled, style, clicked);
}

pub fn appendLabeled(cx: *ui.Cx, scope: *ui.Scope, root: *ui.Node, index: usize, label: []const u8, id: []const u8, disabled: *ui.Signal(bool), style: *ui.Signal(ui.BoxStyle), clicked: ui.Handler(void)) !Entry {
    const button = try ui.widgets.Button(.{ .variant = .ghost, .a11y_label = label, .base_style = style, .disabled = disabled, .on_click = clicked }).mount(scope, cx);
    for (button.children.items) |child| child.setDisplay(.none);
    button.meta.ownership.meta.test_id = id;
    const badge = try ui.box(cx, S.remoteStepNumber(index == 0), .{});
    const digit = try ui.text(cx, ([_][]const u8{ "1", "2", "3" })[index], S.stepNumber());
    try badge.appendChild(cx.allocator, digit);
    const check = try ui.iconTint(cx, ui.icons.check, S.theme.current().accent_ink, S.icon(13));
    check.meta.ownership.meta.test_id = check_ids[index];
    check.setDisplay(.none);
    try badge.appendChild(cx.allocator, check);
    try button.appendChild(cx.allocator, badge);
    const title = try ui.text(cx, label, S.stepTitle(index == 0));
    const measured_width = @ceil(cx.text.measureTextWidth(label, 12, 400, false)) + 4;
    const min_title_width: f32 = if (index == 1) 52 else 66;
    title.setStyleInline(cx.allocator, .{ .width = .{ .px = @max(min_title_width, measured_width) }, .flex_shrink = 0 });
    try button.appendChild(cx.allocator, title);
    try root.appendChild(cx.allocator, button);
    return .{ .button = button, .badge = badge, .digit = digit, .check = check, .title = title, .style = style };
}

pub fn paint(cx: *ui.Cx, entry: Entry, current: bool, completed: bool, invalid: bool) void {
    const step_style = S.reviewStep(current);
    entry.style.set(step_style);
    entry.button.setStyleInline(cx.allocator, step_style);
    entry.button.setOpacity(1);
    entry.badge.setStyleInline(cx.allocator, S.remoteStepNumber(current));
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
