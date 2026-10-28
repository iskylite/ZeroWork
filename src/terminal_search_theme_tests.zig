//! Real retained search input: global paint does not replace editable state.
const std = @import("std");
const ui = @import("ui");
const Search = @import("ui/terminal_search.zig");
const theme = @import("ui/app_theme.zig");
const Publication = @import("ui/shell_styles.zig").ThemePublication;

fn frames(cx: *ui.Cx) void {
    for (0..6) |_| {
        cx.frame_count += 1;
        cx.frame_time_ms += 16;
        _ = cx.render();
    }
}

fn expectIconTint(node: *ui.Node, color: ui.Color) !usize {
    var found: usize = 0;
    if (node.getIcon()) |value| {
        try std.testing.expectEqual(color, value.tint);
        found += 1;
    }
    if (node.getImage()) |value| {
        try std.testing.expectEqual(color, value.tint);
        found += 1;
    }
    for (node.children.items) |child| found += try expectIconTint(child, color);
    return found;
}

const Receipt = struct {
    cx: *ui.Cx,
    model: *Search.Model,
    terminal: *ui.Node,
    view: ?*Search.View = null,
    next_calls: usize = 0,
    previous_calls: usize = 0,
    close_calls: usize = 0,
    fn next(raw: ?*anyopaque) void {
        const self: *Receipt = @ptrCast(@alignCast(raw.?));
        self.next_calls += 1;
        self.model.next();
        if (self.view) |view| view.refresh();
    }
    fn previous(raw: ?*anyopaque) void {
        const self: *Receipt = @ptrCast(@alignCast(raw.?));
        self.previous_calls += 1;
        self.model.previous();
        if (self.view) |view| view.refresh();
    }
    fn close(raw: ?*anyopaque) void {
        const self: *Receipt = @ptrCast(@alignCast(raw.?));
        self.close_calls += 1;
        self.model.close();
        if (self.view) |view| view.root.setDisplay(.none);
        self.cx.setFocus(self.terminal);
    }
};

test "terminal search global publication repaints hidden and visible view without losing query selection or owner focus" {
    const old_name = theme.currentName();
    const old_material = theme.materialVisible();
    defer {
        theme.select(old_name);
        _ = theme.setMaterialVisible(old_material);
    }
    theme.select(.dark);
    _ = theme.setMaterialVisible(false);
    const cx = try ui.Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(800, 450);
    const scope = try ui.Scope.init(std.testing.allocator, null, cx.owner);
    defer scope.dispose();
    cx.root = try ui.box(cx, .{ .width = .fill(), .height = .fill() }, .{});
    const publication = try cx.bindState(Publication, .{});
    publication.publish(cx, theme.widgetTheme(.dark));
    const terminal = try ui.box(cx, .{ .width = .fill(), .height = .fill() }, .{});
    terminal.behavior.interaction.focusable = true;
    try cx.root.?.appendChild(cx.allocator, terminal);
    var model = Search.Model.init(std.testing.allocator);
    defer model.deinit();
    try model.setSource("red red red");
    try model.setQuery("red");
    model.current = 1;
    model.open = true;
    var receipt: Receipt = .{ .cx = cx, .model = &model, .terminal = terminal };
    var view = try Search.mount(cx, scope, &model, .{ .context = &receipt, .on_next = Receipt.next, .on_previous = Receipt.previous, .on_close = Receipt.close });
    receipt.view = &view;
    try cx.root.?.appendChild(cx.allocator, view.root);
    frames(cx);
    view.focus();
    frames(cx);
    const focused = cx.focus_manager.getFocused().?;
    const input_state: *ui.widgets.input.TextInputState = @ptrCast(@alignCast(focused.behavior.events.event_context.?));
    try std.testing.expect(input_state.setAccessibilitySelection(0, 2));
    frames(cx);
    const cursor = input_state.cursor_pos;
    const anchor = input_state.selection_anchor;
    const input_id = view.input.id;
    const count_id = view.count.id;
    const panel_id = view.root.id;
    const geometry = view.root.globalRect();
    view.root.setDisplay(.none);
    theme.select(.light);
    publication.publish(cx, theme.widgetTheme(.light));
    // Same narrow call the owning TerminalView makes for global appearance.
    view.retheme();
    frames(cx);
    try std.testing.expectEqual(theme.current().overlay, view.root.getBackground());
    try std.testing.expectEqual(theme.current().fg_2, view.count.getText().?.color);
    try std.testing.expect(view.root.style.display == .none);
    view.root.setDisplay(.flex);
    view.focus();
    frames(cx);
    for ([_]theme.Name{ .sauber, .dark }) |name| {
        theme.select(name);
        _ = theme.setMaterialVisible(name == .sauber);
        publication.publish(cx, theme.widgetTheme(name));
        view.retheme();
        frames(cx);
        try std.testing.expectEqual(theme.current().overlay, view.root.getBackground());
        try std.testing.expectEqual(theme.current().fg_2, view.count.getText().?.color);
        try std.testing.expectEqual(theme.current().fg_2, input_state.placeholder_color.?);
        try std.testing.expectEqual(theme.popupSelection(), view.input_result.input_container.getBackground());
        try std.testing.expectEqual(theme.current().fg_1, input_state.text_display_node.?.getText().?.color);
        for (view.actions) |action| {
            try std.testing.expectEqual(ui.Color.TRANSPARENT, action.getBackground());
            try std.testing.expect(try expectIconTint(action, theme.current().fg_2) > 0);
        }
        try std.testing.expectEqualStrings("red", input_state.getText());
        try std.testing.expectEqualStrings("red", model.query.items);
        try std.testing.expectEqualStrings("2/3", view.count.getText().?.content);
        try std.testing.expectEqual(@as(usize, 1), model.current);
        try std.testing.expectEqual(cursor, input_state.cursor_pos);
        try std.testing.expectEqual(anchor, input_state.selection_anchor);
        try std.testing.expectEqual(input_id, view.input.id);
        try std.testing.expectEqual(count_id, view.count.id);
        try std.testing.expectEqual(panel_id, view.root.id);
        try std.testing.expectEqual(focused, cx.focus_manager.getFocused().?);
        try std.testing.expectEqual(input_state, view.input_result.state);
        try std.testing.expectEqualDeep(geometry, view.root.globalRect());
        try std.testing.expectEqual(@as(usize, 0), receipt.next_calls + receipt.previous_calls + receipt.close_calls);
    }
    cx.handleKeyDown(.@"return", .{});
    frames(cx);
    try std.testing.expectEqual(@as(usize, 1), receipt.next_calls);
    try std.testing.expectEqualStrings("3/3", view.count.getText().?.content);
    cx.handleKeyDown(.@"return", .{ .shift = true });
    frames(cx);
    try std.testing.expectEqual(@as(usize, 1), receipt.previous_calls);
    try std.testing.expectEqualStrings("2/3", view.count.getText().?.content);
    cx.handleKeyDown(.escape, .{});
    frames(cx);
    try std.testing.expectEqual(@as(usize, 1), receipt.close_calls);
    try std.testing.expectEqual(terminal, cx.focus_manager.getFocused().?);
    try std.testing.expect(!model.open);
    try std.testing.expectEqualStrings("red", model.query.items);
}
