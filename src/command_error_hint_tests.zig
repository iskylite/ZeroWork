const std = @import("std");
const ui = @import("ui");
const policy = @import("ai/command_error_hint.zig");
const View = @import("ui/command_error_hint_view.zig").View;
const Adapter = @import("vt/ghostty_adapter.zig").Adapter;
const theme = @import("ui/app_theme.zig");
const identity = @import("host/identity.zig");
const a = std.testing.allocator;
const owner: identity.SessionHandle = .{ .session_id = @fromBackingInt(7), .generation = 2 };

fn observe(model: *policy.Model, adapter: *Adapter) !bool {
    var projection = try adapter.copyProjection(a);
    defer projection.deinit(a);
    return model.observe(owner, &projection);
}
fn baseline(model: *policy.Model, adapter: *Adapter, enabled: bool) !void {
    model.configure(owner, enabled);
    try std.testing.expect(!try observe(model, adapter));
}
const failure = "\x1b]133;A\x07% \x1b]133;B\x07false\r\n\x1b]133;C;cmdline_url=false\x07\x1b[31m失败 output\x1b[0m\r\n\x1b]133;D;7\x07";

test "AI error hint real OSC parser provides one original command nonzero exit and plain frozen context" {
    var adapter = try Adapter.init(a, 6, 80);
    defer adapter.destroy();
    var model = policy.Model.init(a);
    defer model.deinit();
    try baseline(&model, &adapter, true);
    _ = try adapter.feed(failure[0..25]);
    try std.testing.expect(!try observe(&model, &adapter));
    _ = try adapter.feed(failure[25..]);
    try std.testing.expect(try observe(&model, &adapter));
    const hint = model.pending.?;
    try std.testing.expect(hint.owner.eql(owner));
    try std.testing.expect(hint.command_id != 0 and hint.end_sequence > hint.command_id);
    try std.testing.expectEqualStrings("false", hint.command);
    try std.testing.expectEqual(@as(i32, 7), hint.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, hint.output, "失败 output") != null);
    try std.testing.expect(std.mem.indexOfScalar(u8, hint.output, 0x1b) == null);
    try std.testing.expect(!try observe(&model, &adapter));
    _ = try adapter.feed("\x1b[2J\x1b[Hnew unrelated output");
    try std.testing.expect(!try observe(&model, &adapter));
    try std.testing.expect(std.mem.indexOf(u8, hint.output, "失败 output") != null);
    try std.testing.expect(model.current(owner, hint.command_id) != null);
    try std.testing.expect(model.current(try owner.nextGeneration(), hint.command_id) == null);
    try std.testing.expect(model.current(owner, hint.command_id + 1) == null);
    model.dismiss();
    try std.testing.expect(!try observe(&model, &adapter));
    try std.testing.expect(model.pending == null);
}

test "AI error hint ignores ERROR words success unknown exit orphan end and redraw" {
    var adapter = try Adapter.init(a, 4, 80);
    defer adapter.destroy();
    var model = policy.Model.init(a);
    defer model.deinit();
    try baseline(&model, &adapter, true);
    for ([_][]const u8{
        "ERROR fatal failure exit=1\r\n",
        "\x1b]133;D;2\x07",
        "\x1b]133;C;cmdline=true\x07ERROR\x1b]133;D;0\x07",
        "\x1b]133;C;cmdline=unknown\x07\x1b]133;D\x07",
        "\x1b]133;A\x07\x1b]133;A\x07",
    }) |bytes| {
        _ = try adapter.feed(bytes);
        try std.testing.expect(!try observe(&model, &adapter));
        try std.testing.expect(model.pending == null);
    }
}

test "AI error hint saved switch consumes disabled facts and enabling never replays them" {
    var adapter = try Adapter.init(a, 4, 80);
    defer adapter.destroy();
    var model = policy.Model.init(a);
    defer model.deinit();
    try baseline(&model, &adapter, false);
    _ = try adapter.feed(failure);
    try std.testing.expect(!try observe(&model, &adapter));
    try baseline(&model, &adapter, true);
    try std.testing.expect(!try observe(&model, &adapter));
    _ = try adapter.feed(failure);
    try std.testing.expect(try observe(&model, &adapter));
    model.configure(owner, false);
    try std.testing.expect(model.pending == null);
    try baseline(&model, &adapter, true);
    try std.testing.expect(model.pending == null);
}

test "AI error hint original generation cannot attach an old projection or command to replacement owner" {
    var adapter = try Adapter.init(a, 4, 80);
    defer adapter.destroy();
    var model = policy.Model.init(a);
    defer model.deinit();
    try baseline(&model, &adapter, true);
    _ = try adapter.feed(failure);
    try std.testing.expect(try observe(&model, &adapter));
    const original_command = model.pending.?.command_id;
    const replacement = try owner.nextGeneration();
    model.configure(replacement, true);
    try std.testing.expect(model.pending == null);
    var projection = try adapter.copyProjection(a);
    defer projection.deinit(a);
    try std.testing.expectError(error.StaleOwner, model.observe(owner, &projection));
    try std.testing.expect(model.current(replacement, original_command) == null);
    try std.testing.expect(!try model.observe(replacement, &projection));
    try std.testing.expect(model.pending == null);
}

test "AI error hint missing semantic records cannot pair a later unrelated exit with old command" {
    var adapter = try Adapter.init(a, 4, 80);
    defer adapter.destroy();
    var model = policy.Model.init(a);
    defer model.deinit();
    try baseline(&model, &adapter, true);
    _ = try adapter.feed("\x1b]133;C;cmdline=old\x07");
    try std.testing.expect(!try observe(&model, &adapter));
    for (0..70) |_| _ = try adapter.feed("\x1b]133;A\x07");
    _ = try adapter.feed("\x1b]133;D;7\x07");
    try std.testing.expect(!try observe(&model, &adapter));
    try std.testing.expect(model.pending == null);
    _ = try adapter.feed(failure);
    try std.testing.expect(try observe(&model, &adapter));
    try std.testing.expectEqualStrings("false", model.pending.?.command);
}

const Sink = struct {
    calls: usize = 0,
    command_id: u64 = 0,
    fn open(raw: ?*anyopaque, hint: policy.Hint) !void {
        const self: *Sink = @ptrCast(@alignCast(raw.?));
        try std.testing.expect(hint.owner.eql(owner));
        try std.testing.expectEqualStrings("false", hint.command);
        try std.testing.expect(std.mem.indexOf(u8, hint.output, "失败 output") != null);
        self.calls += 1;
        self.command_id = hint.command_id;
    }
};

test "AI error hint real widgets preserve focus until click and only open original assistant once" {
    var cx = try ui.Cx.init(a, std.testing.io);
    defer cx.deinit();
    cx.setViewport(800, 600);
    cx.root = try ui.box(cx, .{ .width = .fill(), .height = .fill() }, .{});
    cx.root.?.behavior.interaction.focusable = true;
    cx.setFocus(cx.root.?);
    var sink: Sink = .{};
    const view = try View.create(cx, cx.root.?);
    defer view.destroy();
    view.configure(owner, true, .{ .context = &sink, .on_open = Sink.open });
    var adapter = try Adapter.init(a, 4, 80);
    defer adapter.destroy();
    var empty = try adapter.copyProjection(a);
    defer empty.deinit(a);
    try view.observe(owner, &empty);
    _ = try adapter.feed(failure);
    var failed = try adapter.copyProjection(a);
    defer failed.deinit(a);
    try view.observe(owner, &failed);
    cx.layout();
    view.retheme();
    cx.layout();
    try std.testing.expectEqual(cx.root.?, cx.focus_manager.getFocused().?);
    try std.testing.expectEqual(@as(usize, 0), sink.calls);
    try std.testing.expectEqual(@as(@TypeOf(view.root.style.display), .flex), view.root.style.display);
    try std.testing.expectEqual(@as(f32, 340), view.root.globalRect().w);
    try std.testing.expectEqual(@as(f32, 115), view.root.globalRect().h);
    try std.testing.expectEqualStrings("命令  false", view.command.getText().?.content);
    try std.testing.expectEqualStrings("输出  失败 output", view.output.getText().?.content);
    try std.testing.expect(view.detail.parent == view.exit_tag);
    try std.testing.expectEqual(@as(f32, 20), view.exit_tag.globalRect().h);
    try std.testing.expect(view.open.globalRect().w >= view.open_text.globalRect().w + 20);
    try std.testing.expectEqual(@as(f32, 24), view.open.globalRect().h);
    view.activate();
    view.activate();
    try std.testing.expectEqual(@as(usize, 1), sink.calls);
    try std.testing.expect(sink.command_id != 0);
    try std.testing.expectEqual(@as(@TypeOf(view.root.style.display), .none), view.root.style.display);
    try view.observe(owner, &failed);
    try std.testing.expectEqual(@as(@TypeOf(view.root.style.display), .none), view.root.style.display);
}

test "AI error hint actual mounted paint follows global themes and closing setting removes prompt" {
    const previous = theme.currentName();
    defer theme.select(previous);
    var cx = try ui.Cx.init(a, std.testing.io);
    defer cx.deinit();
    cx.setViewport(300, 400);
    cx.root = try ui.box(cx, .{ .width = .fill(), .height = .fill() }, .{});
    var sink: Sink = .{};
    const view = try View.create(cx, cx.root.?);
    defer view.destroy();
    view.configure(owner, true, .{ .context = &sink, .on_open = Sink.open });
    var adapter = try Adapter.init(a, 4, 80);
    defer adapter.destroy();
    var empty = try adapter.copyProjection(a);
    defer empty.deinit(a);
    try view.observe(owner, &empty);
    _ = try adapter.feed(failure);
    var failed = try adapter.copyProjection(a);
    defer failed.deinit(a);
    try view.observe(owner, &failed);
    for ([_]theme.Name{ .dark, .light, .sauber }) |name| {
        theme.select(name);
        cx.setTheme(theme.widgetTheme(name));
        cx.layout();
        view.retheme();
        cx.layout();
        try std.testing.expectEqual(@as(f32, 276), view.root.globalRect().w);
        try std.testing.expectEqual(theme.current().fg_1, view.title.getText().?.color);
        try std.testing.expectEqual(theme.current().danger_ink, view.detail.getText().?.color);
    }
    view.configure(owner, false, .{ .context = &sink, .on_open = Sink.open });
    view.activate();
    try std.testing.expectEqual(@as(usize, 0), sink.calls);
    try std.testing.expectEqual(@as(@TypeOf(view.root.style.display), .none), view.root.style.display);
}

test "AI error hint terminal host integration declarations compile" {
    _ = &@import("ui/terminal_view.zig").TerminalViewNode.configureErrorHint;
    _ = &@import("ui/terminal_view.zig").TerminalViewNode.consumeWorkerText;
    _ = &@import("ui/terminal_view.zig").TerminalViewNode.refreshTerminalService;
    _ = &@import("ui/workspace.zig").Workspace.init;
}

test "AI error hint question preserves existing draft and complete original command output without dispatch" {
    const hint: policy.Hint = .{ .owner = owner, .command_id = 4, .end_sequence = 5, .command = "printf '%s' 工作目录", .output = "失败\nline two\n", .exit_code = 7 };
    const text = try policy.question(a, "现有草稿\n保留", hint);
    defer a.free(text);
    try std.testing.expect(std.mem.startsWith(u8, text, "现有草稿\n保留\n\n"));
    try std.testing.expect(std.mem.indexOf(u8, text, hint.command) != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "退出码：7") != null);
    try std.testing.expect(std.mem.endsWith(u8, text, hint.output));
    const empty = try policy.question(a, "", hint);
    defer a.free(empty);
    try std.testing.expect(!std.mem.startsWith(u8, empty, "\n"));
}

test "AI error hint sequence cutoff and reconnect reset keep old running commands out" {
    var adapter = try Adapter.init(a, 4, 80);
    defer adapter.destroy();
    var model = policy.Model.init(a);
    defer model.deinit();
    model.configure(owner, true);
    try model.primeSequence(owner, adapter.semanticSequence());
    _ = try adapter.feed("\x1b]133;C;cmdline=old\x07");
    try std.testing.expect(!try observe(&model, &adapter));
    model.resetFacts();
    try model.primeSequence(owner, adapter.semanticSequence());
    _ = try adapter.feed("\x1b]133;D;7\x07");
    try std.testing.expect(!try observe(&model, &adapter));
    _ = try adapter.feed(failure);
    try std.testing.expect(try observe(&model, &adapter));
}

test "AI error hint output preview excludes previous output and shell prompts" {
    var adapter = try Adapter.init(a, 12, 80);
    defer adapter.destroy();
    _ = try adapter.feed("old unrelated output\r\n" ++ failure ++ "\x1b]133;A\x07next prompt % ");
    var projection = try adapter.copyProjection(a);
    defer projection.deinit(a);
    const preview = try policy.outputPreview(a, &projection);
    defer a.free(preview);
    try std.testing.expectEqualStrings("失败 output", preview);
}

test "AI error hint output preview handles empty output and bounded Unicode" {
    var adapter = try Adapter.init(a, 20, 80);
    defer adapter.destroy();
    _ = try adapter.feed("old output\r\n\x1b]133;A\x07% \x1b]133;B\x07false\r\n\x1b]133;C\x07\x1b]133;D;1\x07\x1b]133;A\x07% ");
    var empty = try adapter.copyProjection(a);
    defer empty.deinit(a);
    const no_output = try policy.outputPreview(a, &empty);
    defer a.free(no_output);
    try std.testing.expectEqualStrings("", no_output);
    _ = try adapter.feed("\x1b]133;B\x07test\r\n\x1b]133;C\x07");
    for (0..100) |_| _ = try adapter.feed("错误详情");
    _ = try adapter.feed("\r\n\x1b]133;D;1\x07");
    var long = try adapter.copyProjection(a);
    defer long.deinit(a);
    const preview = try policy.outputPreview(a, &long);
    defer a.free(preview);
    try std.testing.expect(preview.len <= 515);
    try std.testing.expect(std.unicode.utf8ValidateSlice(preview));
    try std.testing.expect(std.mem.endsWith(u8, preview, "…"));
}

test "AI error hint exit tag maps success interruption and failure across themes" {
    const styles = @import("ui/command_error_hint_styles.zig");
    const previous = theme.currentName();
    defer theme.select(previous);
    for ([_]theme.Name{ .dark, .light, .sauber }) |name| {
        theme.select(name);
        try std.testing.expectEqual(theme.current().ok_ink, styles.exitInk(0));
        for ([_]i32{ 130, 143 }) |code| {
            try std.testing.expectEqual(theme.current().warn_ink, styles.exitInk(code));
            try std.testing.expectEqual(theme.current().warn.withAlpha(23), styles.exitTagFor(code).background.?);
        }
        for ([_]i32{ 1, 2, 126, 127, 137, 255 }) |code| {
            try std.testing.expectEqual(theme.current().danger_ink, styles.exitInk(code));
            try std.testing.expectEqual(theme.current().danger.withAlpha(23), styles.exitTagFor(code).background.?);
        }
    }
}
