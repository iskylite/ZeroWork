const std = @import("std");
const ui = @import("ui");
const M = @import("ui/ai_message_view.zig");
const links = @import("ui/ai_markdown_links.zig");
const a = std.testing.allocator;
const Fixture = struct {
    cx: *ui.Cx,
    scope: *ui.Scope,
    fn init() !Fixture {
        const cx = try ui.Cx.init(a, std.testing.io);
        cx.setViewport(900, 4000);
        cx.root = try ui.box(cx, .{ .width = .{ .px = 540 }, .height = .{ .fit = .{} }, .direction = .column }, .{});
        return .{ .cx = cx, .scope = try ui.Scope.init(a, null, cx.owner) };
    }
    fn deinit(self: Fixture) void {
        self.scope.dispose();
        self.cx.deinit();
    }
    fn mount(self: Fixture, source: []const u8) !*ui.Node {
        const node = try M.mountWithWidth(self.cx, self.scope, source, 540);
        try self.cx.root.?.appendChild(a, node);
        self.settle();
        return node;
    }
    fn settle(self: Fixture) void {
        for (0..3) |_| {
            self.cx.advanceFrameClock();
            self.cx.layout();
            _ = self.cx.render();
        }
    }
};
fn textNode(root: *ui.Node, expected: []const u8) ?*ui.Node {
    if (root.getText()) |t| if (std.mem.eql(u8, t.content, expected)) return root;
    for (root.children.items) |child| if (textNode(child, expected)) |node| return node;
    return null;
}
fn idNode(root: *ui.Node, id: []const u8) ?*ui.Node {
    if (std.mem.eql(u8, root.meta.ownership.meta.test_id orelse "", id)) return root;
    for (root.children.items) |child| if (idNode(child, id)) |node| return node;
    return null;
}
fn appendText(root: *ui.Node, result: *std.ArrayList(u8)) !void {
    if (root.getText()) |t| {
        try result.appendSlice(a, t.content);
        try result.append(a, '\n');
    }
    for (root.children.items) |child| try appendText(child, result);
}
test "Markdown rendering keeps escaped pipes and following table columns" {
    const f = try Fixture.init();
    defer f.deinit();
    const node = try f.mount("| A\\|B | C |\n| --- | --- |\n| a\\|b | **保留** |\n| `x\\|y` | 最后一列 |\n| \\| | 完整 |");
    for ([_][]const u8{ "A|B", "a|b", "保留", "x|y", "最后一列", "|", "完整" }) |value| try std.testing.expect(textNode(node, value) != null);
    const table = idNode(node, "ai.message.table").?;
    try std.testing.expectEqual(@as(usize, 2), table.children.items[0].children.items[0].children.items.len);
}

test "Markdown rendering separates topics with space while preserving rules in code and table separators" {
    const f = try Fixture.init();
    defer f.deinit();
    const source = "第一段\n\n---\n\n## 第二节\n\n```text\n---\n```\n\n| A | B |\n| --- | --- |\n| 一 | 二 |";
    const node = try f.mount(source);
    const gap = idNode(node, "ai.message.section_gap").?;
    try std.testing.expectApproxEqAbs(@as(f32, 8), gap.globalRect().h, 0.1);
    try std.testing.expectEqual(ui.Color.TRANSPARENT, gap.getBackground());
    try std.testing.expect(textNode(node, "第二节").?.globalRect().y > textNode(node, "第一段").?.globalRect().y);
    try std.testing.expect(textNode(node, "---") != null);
    try std.testing.expect(idNode(node, "ai.message.table") != null);
    const streamed = try M.Retained.mount(f.cx, f.scope);
    try f.cx.root.?.appendChild(a, streamed.root);
    try streamed.update("第一段\n\n---\n\n", 540, null);
    try streamed.update(source, 540, null);
    f.settle();
    try std.testing.expect(idNode(streamed.root, "ai.message.section_gap") != null);
    try std.testing.expect(textNode(streamed.root, "---") != null);
    try std.testing.expect(idNode(streamed.root, "ai.message.table") != null);
}
test "Markdown rendering nests list quote code and table containers" {
    const f = try Fixture.init();
    defer f.deinit();
    const node = try f.mount("正文\n1. 父项\n   - 子项\n     - 孙项\n\n   ```sh\n   echo hello\n   ```\n\n   | A | B |\n   | --- | --- |\n   | 内容 | 完整 |\n\n> ## 引用标题\n>\n> - 引用列表\n>\n> ```sh\n> echo quote\n> ```\n\n后续正文");
    const parent = textNode(node, "父项").?.globalRect();
    const child = textNode(node, "子项").?.globalRect();
    const grandchild = textNode(node, "孙项").?.globalRect();
    try std.testing.expect(child.x > parent.x and grandchild.x > child.x);
    const code = textNode(node, "echo hello").?.globalRect();
    try std.testing.expect(code.x > parent.x);
    const heading = textNode(node, "引用标题").?.getText().?;
    try std.testing.expect(heading.font_weight == 600 and heading.font_size > 13);
    try std.testing.expect(textNode(node, "引用列表") != null);
    try std.testing.expect(textNode(node, "echo quote") != null);
    try std.testing.expect(textNode(node, "完整") != null);
    try std.testing.expect(textNode(node, "后续正文") != null);
}
test "Markdown rendering retained containers match completed blocks across blank lines and resize" {
    const f = try Fixture.init();
    defer f.deinit();
    const source = "# 标题\n\n- 父项\n  - 子项\n\n  ```sh\n  echo hello\n  ```\n\n  后续说明\n\n> ## 引用\n>\n> 内容\n\n最后正文";
    const retained = try M.Retained.mount(f.cx, f.scope);
    try f.cx.root.?.appendChild(a, retained.root);
    for ([_]usize{ 12, 28, 51, 68, source.len }) |end| try retained.update(source[0..@min(end, source.len)], 540, null);
    const complete = try f.mount(source);
    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(a);
    try appendText(complete, &expected);
    for ([_]f32{ 540, 180, 540 }) |width| {
        f.cx.root.?.setStyleInline(a, .{ .width = .{ .px = width } });
        try retained.update(source, width, null);
        f.settle();
        var actual: std.ArrayList(u8) = .empty;
        defer actual.deinit(a);
        try appendText(retained.root, &actual);
        try std.testing.expectEqualStrings(expected.items, actual.items);
        try std.testing.expect(textNode(retained.root, "子项").?.globalRect().x > textNode(retained.root, "父项").?.globalRect().x);
        try std.testing.expect(textNode(retained.root, "echo hello") != null);
    }
}
test "Markdown rendering maps adjacent duplicate link labels to their own URLs" {
    const f = try Fixture.init();
    defer f.deinit();
    const node = try f.mount("`[same](https://wrong.example)` [same](https://one.example/a_(b))[same](https://two.example) [**组合 `code`**](https://three.example)");
    const text = textNode(node, "[same](https://wrong.example) samesame 组合 code").?;
    const content = text.getText().?.content;
    const first = std.mem.indexOf(u8, content, "samesame").?;
    try std.testing.expectEqualStrings("https://one.example/a_(b)", links.destination(text, first).?);
    try std.testing.expectEqualStrings("https://two.example", links.destination(text, first + 4).?);
    try std.testing.expectEqualStrings("https://three.example", links.destination(text, std.mem.indexOf(u8, content, "code").?).?);
    try std.testing.expect(links.destination(text, 1) == null);
    const bracket_code = try f.mount("[`a]b`](https://bracket.example)");
    try std.testing.expectEqualStrings("https://bracket.example", links.destination(textNode(bracket_code, "a]b").?, 0).?);
    const unsafe = try f.mount("[bad](javascript:alert(1))");
    try std.testing.expect(links.destination(textNode(unsafe, "bad").?, 0) == null);
}
test "Markdown rendering clicking links opens once and dragging keeps text selection" {
    const FontSystem = @typeInfo(@typeInfo(@TypeOf(@as(ui.Cx, undefined).text.font_system)).optional.child).pointer.child;
    var fonts = try FontSystem.init(a, std.testing.io);
    defer fonts.deinit();
    const f = try Fixture.init();
    defer f.deinit();
    f.cx.text.setFontSystem(&fonts);
    const node = try f.mount("[Link text](https://example.com/a_(b)) after");
    const Probe = struct {
        count: usize = 0,
        valid: bool = false,
        fn open(self: *@This(), url: []const u8) void {
            self.count += 1;
            self.valid = std.mem.eql(u8, url, "https://example.com/a_(b)");
        }
    };
    var probe: Probe = .{};
    links.setOpener(node, ui.Handler([]const u8).from(Probe, &probe, Probe.open));
    const text = textNode(node, "Link text after").?;
    const rect = text.globalRect();
    const x = rect.x + 8;
    const y = rect.y + rect.h / 2;
    f.cx.handleMouseDown(x, y, .{});
    f.cx.handleMouseUp(x, y);
    f.settle();
    try std.testing.expectEqual(@as(usize, 1), probe.count);
    try std.testing.expect(probe.valid);
    f.cx.handleMouseDown(x, y, .{});
    f.cx.handleMouseMove(x + 35, y);
    f.cx.handleMouseUp(x + 35, y);
    f.settle();
    try std.testing.expectEqual(@as(usize, 1), probe.count);
    try std.testing.expect(idNode(node, "ai.message.selection") != null);
    // Returning to the original point still completes a drag, not a link click.
    f.cx.handleMouseDown(x, y, .{});
    f.cx.handleMouseMove(x + 35, y);
    f.cx.handleMouseMove(x, y);
    f.cx.handleMouseUp(x, y);
    f.settle();
    try std.testing.expectEqual(@as(usize, 1), probe.count);
}
test "Markdown rendering long headings reflow without overlapping following text" {
    const f = try Fixture.init();
    defer f.deinit();
    const node = try f.mount("# 一级标题很长需要多行显示多个中文字符 abcdefghijklmnopqrstuvwxyz\n\n###### 六级\n\n后续正文");
    const heading = textNode(node, "一级标题很长需要多行显示多个中文字符 abcdefghijklmnopqrstuvwxyz").?;
    var narrow: f32 = 0;
    for ([_]f32{ 180, 540 }) |width| {
        f.cx.root.?.setStyleInline(a, .{ .width = .{ .px = width } });
        f.settle();
        const rect = heading.globalRect();
        if (width == 180) narrow = rect.h else try std.testing.expect(rect.h < narrow);
        try std.testing.expectApproxEqAbs(@as(f32, 15.5), heading.getText().?.font_size, 0.01);
        try std.testing.expect(textNode(node, "六级").?.globalRect().y >= rect.y + rect.h);
        try std.testing.expect(heading.getLayoutOutput().artifacts.text_layout.?.total_height <= rect.h + 0.1);
    }
}
