const std = @import("std");
const ui = @import("ui");
const S = @import("ui/ai_assistant_styles.zig");
const theme = @import("ui/app_theme.zig");
const a = std.testing.allocator;

const Fixture = struct {
    cx: *ui.Cx,
    scope: *ui.Scope,
    input: ui.widgets.input.TextareaResult,
    value: *ui.Signal([]const u8),
    disabled: *ui.Signal(bool),
    error_message: *ui.Signal([]const u8),
    outside: *ui.Node,

    fn init(self: *Fixture, borderless: bool) !void {
        const cx = try ui.Cx.init(a, std.testing.io);
        const scope = try ui.Scope.init(a, null, cx.owner);
        cx.setViewport(800, 400);
        cx.root = try ui.box(cx, .{ .width = .fill(), .height = .fill(), .direction = .column }, .{});
        const composer = try ui.box(cx, S.composer(cx.tokens), .{});
        composer.setStyleInline(a, .{ .width = .{ .px = 600 } });
        try cx.root.?.appendChild(a, composer);
        const value = try scope.createText("", .{});
        const disabled = try scope.createSignal(bool, false);
        const error_message = try scope.createText("", .{});
        const input = try ui.widgets.Textarea(.{ .rows = 2, .value = value, .disabled = disabled, .error_msg = error_message, .placeholder = "继续提问", .borderless = borderless }).mountResult(scope, cx);
        if (borderless) {
            input.wrapper.setStyleInline(a, S.input());
            input.input.setStyleInline(a, S.input());
        }
        try composer.appendChild(a, input.wrapper);
        const outside = try ui.widgets.Button(.{ .label = "外部控件" }).mount(scope, cx);
        try cx.root.?.appendChild(a, outside);
        self.* = .{ .cx = cx, .scope = scope, .input = input, .value = value, .disabled = disabled, .error_message = error_message, .outside = outside };
        self.settle();
    }
    fn deinit(self: *Fixture) void {
        self.cx.clearFocus();
        self.scope.dispose();
        self.cx.deinit();
    }
    fn settle(self: *Fixture) void {
        self.cx.setTestFrameStep(16) catch unreachable;
        for (0..4) |_| {
            self.cx.advanceFrameClock();
            self.cx.layout();
            _ = self.cx.render();
        }
    }
    fn expectBorderless(self: *Fixture) !void {
        try std.testing.expectEqual(@as(f32, 0), self.input.input.style.border.width);
        try std.testing.expect(ui.Color.eql(ui.Color.TRANSPARENT, self.input.input.getBackground()));
        try std.testing.expect(self.input.input.style.outline() == null);
        try std.testing.expect(self.input.input.parent.?.style.outline() == null);
        try std.testing.expect(self.input.state.focus_ring_host == null);
    }
};

test "AI composer borderless Textarea preserves exact transparent Figma field through hover focus and blur" {
    var f: Fixture = undefined;
    try f.init(true);
    defer f.deinit();
    try std.testing.expectEqual(@as(f32, 572), f.input.input.globalRect().w);
    try std.testing.expectEqual(@as(f32, 46), f.input.input.globalRect().h);
    try f.expectBorderless();
    f.input.state.hover_signal.?.set(true);
    f.settle();
    try f.expectBorderless();
    f.cx.setFocus(f.input.input);
    f.settle();
    try std.testing.expect(f.input.state.focused);
    try std.testing.expect(f.cx.focus_manager.current_focus == f.input.input);
    try f.expectBorderless();
    f.cx.setFocus(f.outside);
    f.settle();
    try std.testing.expect(!f.input.state.focused);
    try f.expectBorderless();
    f.input.state.hover_signal.?.set(false);
    f.settle();
    try f.expectBorderless();
}

test "AI composer borderless Textarea retains native text IME caret and keyboard behavior" {
    var f: Fixture = undefined;
    try f.init(true);
    defer f.deinit();
    f.cx.setFocus(f.input.input);
    f.cx.handleTextInput("hello ");
    f.cx.handleImePreedit("nihao", 5);
    f.settle();
    try std.testing.expectEqualStrings("hello ", f.value.peek());
    try std.testing.expect(f.input.state.imeIsComposing());
    try std.testing.expectEqualStrings("nihao", f.input.state.preeditText());
    try std.testing.expect(f.input.input.behavior.interaction.text_input_client != null);
    try std.testing.expect(f.input.state.cursor_node != null);
    try f.expectBorderless();
    f.cx.handleImeCommit("你好");
    f.settle();
    try std.testing.expectEqualStrings("hello 你好", f.value.peek());
    f.cx.handleKeyDown(.left, .{});
    f.cx.handleTextInput("中");
    f.settle();
    try std.testing.expectEqualStrings("hello 你中好", f.value.peek());
    try std.testing.expect(f.input.input.behavior.interaction.a11y.?.editable_text != null);
    try f.expectBorderless();
}

test "AI composer borderless Textarea stays unframed across dynamic disabled error and global theme" {
    const previous = theme.currentName();
    defer theme.select(previous);
    var f: Fixture = undefined;
    try f.init(true);
    defer f.deinit();
    f.cx.setFocus(f.input.input);
    f.cx.handleImePreedit("ni", 2);
    f.disabled.set(true);
    f.settle();
    try std.testing.expect(!f.input.state.focused);
    try std.testing.expect(!f.input.state.imeIsComposing());
    try std.testing.expect(!f.input.input.behavior.interaction.focusable);
    try f.expectBorderless();
    f.error_message.set("请求失败");
    f.settle();
    try std.testing.expect(f.input.input.behavior.interaction.a11y.?.invalid);
    try f.expectBorderless();
    f.disabled.set(false);
    f.cx.setFocus(f.input.input);
    theme.select(.light);
    f.cx.setTheme(theme.widgetTheme(.light));
    f.settle();
    try f.expectBorderless();
    f.error_message.set("");
    f.cx.setFocus(f.outside);
    f.settle();
    try f.expectBorderless();
}

test "AI composer borderless prop defaults to existing normal and focused Textarea borders" {
    const cx = try ui.Cx.init(a, std.testing.io);
    defer cx.deinit();
    cx.setViewport(800, 400);
    cx.root = try ui.box(cx, .{ .width = .fill(), .height = .fill() }, .{});
    const scope = try ui.Scope.init(a, null, cx.owner);
    defer scope.dispose();
    const input = try ui.widgets.Textarea(.{ .rows = 2 }).mountResult(scope, cx);
    try cx.root.?.appendChild(a, input.wrapper);
    cx.layout();
    _ = cx.render();
    try std.testing.expectEqual(@as(f32, 1), input.input.style.border.width);
    try std.testing.expect(input.state.focus_ring_host != null);
    cx.setFocus(input.input);
    try std.testing.expect(input.state.focused);
    try std.testing.expectEqual(@as(f32, 1.5), input.input.style.border.width);
    cx.clearFocus();
    try std.testing.expectEqual(@as(f32, 1), input.input.style.border.width);
}

test "AI composer grows by wrapped display rows, caps five lines and preserves IME and compact approval" {
    const sizing = @import("ui/ai_composer_sizing.zig");
    var f: Fixture = undefined;
    try f.init(true);
    defer f.deinit();
    sizing.configure(f.input);
    f.value.set("一\n二\n三\n四\n五\n六\n七\n八");
    f.settle();
    const composer = f.input.wrapper.parent.?;
    try std.testing.expect(sizing.update(f.cx, f.input, composer, false, 0));
    f.settle();
    try std.testing.expectApproxEqAbs(@as(f32, 106), f.input.input.globalRect().h, 0.01);
    try std.testing.expectEqualStrings("一\n二\n三\n四\n五\n六\n七\n八", f.value.peek());
    f.cx.setFocus(f.input.input);
    f.cx.handleImePreedit("nihao", 5);
    f.settle();
    try std.testing.expect(f.input.state.imeIsComposing());
    try std.testing.expect(sizing.update(f.cx, f.input, composer, true, 0));
    f.settle();
    try std.testing.expectApproxEqAbs(@as(f32, 46), f.input.input.globalRect().h, 0.01);
    try std.testing.expect(f.input.state.imeIsComposing());
    f.cx.handleImeCommit("你好");
    f.settle();
    try std.testing.expect(std.mem.endsWith(u8, f.value.peek(), "你好"));
    f.value.set("短问题");
    f.settle();
    _ = sizing.update(f.cx, f.input, composer, false, 0);
    f.settle();
    try std.testing.expectApproxEqAbs(@as(f32, 46), f.input.input.globalRect().h, 0.01);
    try std.testing.expectEqual(@as(f32, 12), f.input.state.font_size);
}

test "AI composer empty states mount real shortcuts and configuration actions without dispatch" {
    const Empty = @import("ui/ai_empty_view.zig");
    const Actions = struct {
        clicks: usize = 0,
        fn click(raw: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.clicks += 1;
        }
    };
    var f: Fixture = undefined;
    try f.init(true);
    defer f.deinit();
    var actions: Actions = .{};
    const hooks: Empty.Actions = .{ .context = &actions, .summarize = Actions.click, .logs = Actions.click, .settings = Actions.click, .ollama = Actions.click };
    const configured = try Empty.mount(f.cx, f.scope, true, hooks);
    configured.setStyleInline(a, .{ .width = .{ .px = 560 } });
    try f.cx.root.?.appendChild(a, configured);
    const unconfigured = try Empty.mount(f.cx, f.scope, false, hooks);
    unconfigured.setStyleInline(a, .{ .width = .{ .px = 560 } });
    try f.cx.root.?.appendChild(a, unconfigured);
    f.settle();
    try std.testing.expectEqual(@as(usize, 0), actions.clicks);
    const settings = unconfigured.children.items[3];
    try std.testing.expect(settings.globalRect().w > 80);
    try std.testing.expectApproxEqAbs(@as(f32, 34.5), settings.globalRect().h, 0.01);
    f.cx.setFocus(settings);
    f.cx.handleKeyDown(.@"return", .{});
    f.settle();
    try std.testing.expectEqual(@as(usize, 1), actions.clicks);
}

test "multiline input uses the same typography for painted rows caret wrapping and scrolling" {
    for ([_]bool{ false, true }) |borderless| {
        var f: Fixture = undefined;
        try f.init(borderless);
        defer f.deinit();
        // Reproduce a form supplying a different inherited font from the editor.
        f.input.input.setStyleInline(a, .{ .font_size = 28, .font_weight = 700 });
        f.input.state.font_size = 17;
        f.input.state.font_weight = 600;
        f.input.state.line_height = 25;
        f.input.state.char_width = 10;
        f.value.set("Wi中😀 abcdefghijklmnopqrstuvwxyz\nsecond line\nthird line");
        f.cx.setFocus(f.input.input);
        f.settle();
        const state = f.input.state;
        try std.testing.expectEqual(@as(f32, 17), state.wrap_map.font_size);
        try std.testing.expectEqual(@as(u16, 600), state.wrap_map.font_weight);
        try std.testing.expectEqual(@as(f32, 25), state.vl_state.?.props.item_height);
        var count: usize = 0;
        for (state.vl_state.?.pool_nodes) |row| {
            const text = row.getText() orelse continue;
            try std.testing.expectEqual(@as(f32, 17), row.resolveTextFontSize().?);
            try std.testing.expectEqual(@as(u16, 600), row.resolveTextFontWeight().?);
            try std.testing.expectApproxEqAbs(@as(f32, 25.0 / 17.0), text.line_height, 0.001);
            count += 1;
        }
        try std.testing.expect(count > 0);
        try std.testing.expectApproxEqAbs(@as(f32, 23), state.cursor_node.?.globalRect().h, 0.01);
        // A parent style change must not silently change the row's font.
        f.input.input.setStyleInline(a, .{ .font_size = 32, .font_weight = 300 });
        f.settle();
        for (state.vl_state.?.pool_nodes) |row| {
            if (row.getText() == null) continue;
            try std.testing.expectEqual(@as(f32, 17), row.resolveTextFontSize().?);
            try std.testing.expectEqual(@as(u16, 600), row.resolveTextFontWeight().?);
        }
    }
}
