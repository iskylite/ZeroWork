const ui = @import("ui");
pub const Action = enum { replay, export_cast };
pub const Callback = *const fn (*anyopaque, usize, Action) void;
const Click = struct {
    context: *anyopaque,
    callback: Callback,
    index: usize,
    action: Action,
    fn clicked(raw: *anyopaque) void {
        const self: *Click = @ptrCast(@alignCast(raw));
        self.callback(self.context, self.index, self.action);
    }
};

/// Native buttons preserve keyboard focus, activation and the captured archive index.
pub fn mount(cx: *ui.Cx, scope: *ui.Scope, context: *anyopaque, callback: Callback, index: usize, action: Action) !*ui.Node {
    const click = try scope.createState(Click, .{ .context = context, .callback = callback, .index = index, .action = action });
    const node = try ui.widgets.Button(.{ .label = if (action == .replay) "回放" else "导出", .variant = @as(ui.widgets.button.ButtonVariant, if (action == .replay) .primary else .secondary), .size = .sm, .base_style = @import("history_styles.zig").button(), .on_click = .{ .callback = Click.clicked, .context = @as(*anyopaque, @ptrCast(click)) } }).mount(scope, cx);
    node.meta.ownership.meta.test_id = if (action == .replay) "history.record.replay" else "history.record.export";
    return node;
}

test "history row actions dispatch the exact indexed recording" {
    const std = @import("std");
    const cx = try ui.Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    const root = try ui.box(cx, .{}, .{});
    cx.root = root;
    const scope = try ui.Scope.init(std.testing.allocator, null, cx.owner);
    defer scope.dispose();
    const State = struct {
        index: usize = 0,
        action: ?Action = null,
        fn invoke(raw: *anyopaque, index: usize, action: Action) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.index = index;
            self.action = action;
        }
    };
    var state: State = .{};
    const replay = try mount(cx, scope, @ptrCast(&state), State.invoke, 7, .replay);
    const export_button = try mount(cx, scope, @ptrCast(&state), State.invoke, 7, .export_cast);
    try root.appendChild(cx.allocator, replay);
    try root.appendChild(cx.allocator, export_button);
    try std.testing.expectEqualStrings("Button", replay.meta.ownership.meta.component_name.?);
    const replay_click = replay.behavior.events.on_click.?;
    replay_click.callback(replay_click.context);
    try std.testing.expectEqual(@as(usize, 7), state.index);
    try std.testing.expectEqual(Action.replay, state.action.?);
    const export_click = export_button.behavior.events.on_click.?;
    export_click.callback(export_click.context);
    try std.testing.expectEqual(Action.export_cast, state.action.?);
}
