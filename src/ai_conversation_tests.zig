const std = @import("std");

test "conversation interrupted restored turn never resumes its clock or reports completion" {
    const status = @import("ui/ai_turn_status_view.zig");
    var turn: turns.Turn = .{ .sent_at_ms = 1000, .started_mono_ms = 100, .elapsed_ms = 24000, .restored_interrupted = true };
    defer turn.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("已中断", status.turnLabel(&turn).text);
    try std.testing.expect(!status.turnLabel(&turn).animated);
    try std.testing.expectEqual(@as(u64, 24000), status.elapsedMs(&turn, 100000000, 100000000));
    try std.testing.expectEqual(@as(u64, 24000), status.elapsedMs(&turn, 200000000, 200000000));
    try std.testing.expect(turn.ended_at_ms == null);
}
const ui = @import("ui");
const a = std.testing.allocator;
const turns = @import("ai/conversation_turn.zig");
const wire = @import("ai/wire_history.zig");
const steps = @import("ai/step_events.zig");
test {
    _ = @import("ai/conversation_turn.zig");
    _ = @import("host/terminal_execution.zig");
}
fn find(root: *ui.Node, id: []const u8) ?*ui.Node {
    if (std.mem.eql(u8, root.meta.ownership.meta.test_id orelse "", id)) return root;
    for (root.children.items) |child| if (find(child, id)) |node| return node;
    return null;
}
fn collectHeadings(node: *ui.Node, sizes: *[6]f32, count: *usize) void {
    if (node.getText()) |text| if (text.font_weight == 600 and count.* < sizes.len) {
        sizes[count.*] = text.font_size;
        count.* += 1;
    };
    for (node.children.items) |child| collectHeadings(child, sizes, count);
}
test "AI conversation renders six distinct compact Markdown heading levels" {
    const S = @import("ui/ai_assistant_styles.zig");
    const cx = try ui.Cx.init(a, std.testing.io);
    defer cx.deinit();
    const scope = try ui.Scope.init(a, null, cx.owner);
    defer scope.dispose();
    cx.setViewport(600, 900);
    const root = try ui.box(cx, .{ .width = .{ .px = 540 }, .height = .fill(), .direction = .column }, .{});
    cx.root = root;
    const message = try @import("ui/ai_message_view.zig").mountWithWidth(cx, scope, "# 一级\n\n## 二级\n\n### 三级\n\n#### 四级\n\n##### 五级\n\n###### 六级\n\n正文", 540);
    try root.appendChild(a, message);
    var sizes: [6]f32 = undefined;
    var count: usize = 0;
    collectHeadings(message, &sizes, &count);
    try std.testing.expectEqual(@as(usize, 6), count);
    for (sizes[0..5], 0..) |size, i| try std.testing.expect(size > sizes[i + 1]);
    try std.testing.expect(sizes[5] > S.body_font_size);
    try std.testing.expectApproxEqAbs(S.heading_max_font_size, sizes[0], 0.01);
}
fn findMarkdownText(node: *ui.Node, expected: []const u8) ?*ui.Node {
    if (node.getText()) |text| if (std.mem.eql(u8, text.content, expected)) return node;
    for (node.children.items) |child| if (findMarkdownText(child, expected)) |found| return found;
    return null;
}

test "AI conversation nested Markdown preserves inherited code styles across streaming and resize" {
    const cx = try ui.Cx.init(a, std.testing.io);
    defer cx.deinit();
    const scope = try ui.Scope.init(a, null, cx.owner);
    defer scope.dispose();
    cx.setViewport(600, 900);
    const root = try ui.box(cx, .{ .width = .{ .px = 540 }, .height = .fill(), .direction = .column }, .{});
    cx.root = root;
    const retained = try @import("ui/ai_message_view.zig").Retained.mount(cx, scope);
    try root.appendChild(a, retained.root);
    // This goes through the production mutable-tail path, including a source
    // with an unmatched bold opener before the final delimiter arrives.
    try retained.update("**1. `tuned` 已改为 `hpc-compute`", 540, null);
    try std.testing.expect(findMarkdownText(retained.root, "**1. tuned 已改为 hpc-compute") != null);
    const source = "**1. `tuned` 已改为 `hpc-compute`**\n\n" ++
        "[*说明 **`sysctl_config`** 已更新*](https://example.com)\n\n" ++
        "```sh\n**literal** `code`\n```";
    for ([_]f32{ 540, 180, 540 }) |width| {
        root.setStyleInline(a, .{ .width = .{ .px = width } });
        try retained.update(source, width, null);
        for (0..3) |_| {
            cx.advanceFrameClock();
            cx.layout();
            _ = cx.render();
        }
        const paragraph = findMarkdownText(retained.root, "1. tuned 已改为 hpc-compute").?;
        const text = paragraph.getText().?;
        try std.testing.expectEqual(@as(usize, 4), text.spans.len);
        var previous_end: u32 = 0;
        var code_count: usize = 0;
        for (text.spans) |span| {
            try std.testing.expect(span.start >= previous_end and span.end > span.start);
            try std.testing.expectEqual(@as(?u16, 700), span.font_weight);
            if (span.use_monospace_font) {
                code_count += 1;
                try std.testing.expect(span.bg_color != null);
                try std.testing.expect(span.inline_box_padding_left > 0 and span.inline_box_padding_right > 0);
                try std.testing.expect(span.inline_box_corner_radius > 0);
            }
            previous_end = span.end;
        }
        try std.testing.expectEqual(@as(usize, 2), code_count);
        const linked = findMarkdownText(retained.root, "说明 sysctl_config 已更新").?.getText().?;
        var found_nested_code = false;
        for (linked.spans) |span| {
            try std.testing.expect(span.underline and span.use_italic_font);
            if (span.use_monospace_font) {
                found_nested_code = true;
                try std.testing.expectEqualStrings("sysctl_config", linked.content[span.start..span.end]);
                try std.testing.expectEqual(@as(?u16, 700), span.font_weight);
                try std.testing.expect(span.bg_color != null);
            }
        }
        try std.testing.expect(found_nested_code);
        try std.testing.expect(findMarkdownText(retained.root, "**literal** `code`") != null);
        const layout = paragraph.getLayoutOutput().artifacts.text_layout.?;
        try std.testing.expect(layout.total_height > 0);
        try std.testing.expect(layout.total_height <= paragraph.globalRect().h + 0.1);
    }
}

test "AI conversation context snapshots and steps clone independently with real tool roles" {
    var turn: turns.Turn = .{ .id = 7, .sent_at_ms = 1793060229000 };
    defer turn.deinit(a);
    turn.before = try wire.History.copy(a, &.{.{ .content = "prior question" }}, "prior answer");
    turn.after = try wire.History.copy(a, &.{
        .{ .content = "prior question" },                                                                                      .{ .role = .assistant, .content = "prior answer" },                     .{ .content = "this question" },
        .{ .role = .assistant, .content = "", .tool_calls = &.{.{ .id = "call", .name = "run_command", .arguments = "{}" }} }, .{ .role = .tool, .tool_call_id = "call", .content = "actual result" },
    }, "formal answer");
    turn.answer = try a.dupe(u8, "formal answer");
    try turn.thinking.appendSlice(a, "provider thinking");
    turn.thinking_scroll = try turns.ThinkingScroll.create(a);
    turn.thinking_scroll.?.offset = 80;
    turn.thinking_scroll.?.following = false;
    try steps.apply(a, &turn.steps, .{ .call_id = "call", .name = "run_command", .command = "date", .phase = .running, .at_ms = 10 });
    try steps.apply(a, &turn.steps, .{ .call_id = "call", .phase = .succeeded, .detail = "actual result", .at_ms = 50 });
    var fork = try turn.clone(a);
    defer fork.deinit(a);
    try std.testing.expect(turn.thinking_scroll.? != fork.thinking_scroll.?);
    turn.deinit(a);
    try std.testing.expectEqual(@as(f32, 80), fork.thinking_scroll.?.offset);
    try std.testing.expect(!fork.thinking_scroll.?.following);
    try std.testing.expectEqual(@as(usize, 2), fork.before.messages.len);
    try std.testing.expectEqual(@as(usize, 6), fork.after.messages.len);
    try std.testing.expectEqualStrings("call", fork.after.messages[4].tool_call_id.?);
    try std.testing.expectEqualStrings("actual result", fork.steps.items[0].detail);
    try std.testing.expectEqualStrings("formal answer", fork.answer);
    try std.testing.expectEqualStrings("provider thinking", fork.thinking.items);
}
test "AI conversation renders Markdown tables and live thought disclosure at native bounds" {
    const cx = try ui.Cx.init(a, std.testing.io);
    defer cx.deinit();
    const scope = try ui.Scope.init(a, null, cx.owner);
    defer scope.dispose();
    cx.reduced_motion = true;
    cx.setViewport(600, 500);
    const root = try ui.box(cx, .{ .width = .{ .px = 572 }, .height = .fill(), .direction = .column }, .{});
    cx.root = root;
    const markdown = try @import("ui/ai_message_view.zig").mountWithWidth(cx, scope, "## 系统时间\n\n| 项目 | 值 |\n| --- | --- |\n| 时间 | **16:17** |\n\n```sh\ndate\n```", 572);
    try root.appendChild(a, markdown);
    var expanded = false;
    const card = try @import("ui/ai_step_view.zig").mount(cx, scope, .{ .title = "思考", .projection = "核对当前时间", .detail = "provider thinking", .copy_detail = false, .phase = .running, .elapsed_ms = 1200, .expanded = &expanded, .test_id = "ai.thinking" });
    try root.appendChild(a, card);
    for (0..3) |_| {
        cx.advanceFrameClock();
        cx.layout();
        _ = cx.render();
    }
    try std.testing.expect(find(root, "ai.message.table") != null);
    try std.testing.expectApproxEqAbs(@as(f32, 32), card.globalRect().h, 0.1);
    const header = card.children.items[0];
    header.behavior.events.on_click.?.invoke();
    for (0..3) |_| {
        cx.advanceFrameClock();
        cx.layout();
        _ = cx.render();
    }
    try std.testing.expect(expanded);
    try std.testing.expectApproxEqAbs(@as(f32, 58), card.globalRect().h, 0.1);
    try std.testing.expect(find(card, "ai.step.copy") == null);
    try std.testing.expectEqualStrings("进行中 · 核对当前时间", find(card, "ai.step.projection").?.getText().?.content);
    const detail = find(card, "ai.step.detail").?;
    try detail.setTextContent(a, "first line\nsecond line\nthird line");
    cx.layout();
    _ = cx.render();
    try std.testing.expectApproxEqAbs(@as(f32, 90), card.globalRect().h, 0.1);
    const wrapped = try std.mem.join(a, " ", &@as([16][]const u8, @splat("wrapped thinking")));
    defer a.free(wrapped);
    try detail.setTextContent(a, wrapped);
    root.setStyleInline(a, .{ .width = .{ .px = 180 } });
    cx.layout();
    _ = cx.render();
    const narrow_height = card.globalRect().h;
    try std.testing.expect(narrow_height > 90 and narrow_height <= 182);
    root.setStyleInline(a, .{ .width = .{ .px = 572 } });
    cx.layout();
    _ = cx.render();
    try std.testing.expect(card.globalRect().h < narrow_height);
    const long_thinking = try std.mem.join(a, "\n", &@as([30][]const u8, @splat("long thinking line")));
    defer a.free(long_thinking);
    try detail.setTextContent(a, long_thinking);
    cx.layout();
    _ = cx.render();
    const viewport = find(card, "ai.step.details").?;
    try std.testing.expectApproxEqAbs(@as(f32, 150), viewport.globalRect().h, 0.1);
    try std.testing.expect(detail.globalRect().h > viewport.globalRect().h);
    header.behavior.events.on_click.?.invoke();
    cx.layout();
    _ = cx.render();
    try std.testing.expectApproxEqAbs(@as(f32, 32), card.globalRect().h, 0.1);
    header.behavior.events.on_click.?.invoke();
    try detail.setTextContent(a, "");
    cx.layout();
    _ = cx.render();
    try std.testing.expect(card.globalRect().h < 70);
}
test "AI conversation table rows contain wrapped inline code at narrow widths" {
    const cx = try ui.Cx.init(a, std.testing.io);
    defer cx.deinit();
    const scope = try ui.Scope.init(a, null, cx.owner);
    defer scope.dispose();
    cx.setViewport(600, 1200);
    const root = try ui.box(cx, .{ .width = .{ .px = 572 }, .height = .fill(), .direction = .column }, .{});
    cx.root = root;
    const message = try @import("ui/ai_message_view.zig").mountWithWidth(cx, scope, "| 文件 | 看起来是什么 |\n| --- | --- |\n" ++
        "| `clusconf-4.5.2-11.20260915+git9751ee03.x86_64.rpm`、`clusconf.yaml` | 集群配置工具及其配置 |\n" ++
        "| `clusbench-4.5.1-1120.x86_64.rpm`、`clusbench.yaml` | 集群基准测试包及其配置 |\n" ++
        "| `cluskit-0.6.2-1...run`、`cluskit-0.6.2-3...run` | 两个版本的 cluskit 安装脚本 |\n\n后续正文", 572);
    try root.appendChild(a, message);
    for ([_]f32{ 572, 1000, 400, 180, 572 }) |width| {
        root.setStyleInline(a, .{ .width = .{ .px = width } });
        for (0..3) |_| {
            cx.advanceFrameClock();
            cx.layout();
            _ = cx.render();
        }
        const table = find(root, "ai.message.table").?;
        const content = table.children.items[0];
        try std.testing.expectApproxEqAbs(@max(240, width), content.globalRect().w, 0.1);
        const first_row = content.children.items[0];
        if (width > 240) try std.testing.expect(first_row.children.items[0].globalRect().w > first_row.children.items[1].globalRect().w);
        for (content.children.items) |row| {
            for (row.children.items, 0..) |cell, column| {
                const bounds = cell.globalRect();
                try std.testing.expect(bounds.w >= 120 - 0.1);
                try std.testing.expectApproxEqAbs(first_row.children.items[column].globalRect().w, bounds.w, 0.1);
                try std.testing.expectApproxEqAbs(row.globalRect().h, bounds.h, 0.1);
                const markdown = cell.children.items[0];
                for (markdown.children.items) |paragraph| {
                    const rect = paragraph.globalRect();
                    const layout = paragraph.getLayoutOutput().artifacts.text_layout.?;
                    try std.testing.expect(rect.y + layout.total_height <= bounds.y + bounds.h - 6 + 0.1);
                }
            }
        }
        try std.testing.expectApproxEqAbs(content.globalRect().h, table.globalRect().h, 0.1);
        const following = message.children.items[message.children.items.len - 1];
        try std.testing.expect(following.globalRect().y >= table.globalRect().y + table.globalRect().h);
        if (width == 180) {
            const bounds = table.globalRect();
            const before = content.globalRect().x;
            cx.handleScroll(.{ .x = bounds.x + 20, .y = bounds.y + 20, .dx = -80, .dy = 0 });
            cx.layout();
            _ = cx.render();
            try std.testing.expect(content.globalRect().x < before);
        }
    }
}

test "AI conversation retained Markdown reflows prose tables and wrapped code after resize" {
    const cx = try ui.Cx.init(a, std.testing.io);
    defer cx.deinit();
    const scope = try ui.Scope.init(a, null, cx.owner);
    defer scope.dispose();
    cx.setViewport(1000, 2000);
    const root = try ui.box(cx, .{ .width = .{ .px = 360 }, .height = .fill(), .direction = .column }, .{});
    cx.root = root;
    const prose = try std.mem.join(a, " ", &@as([8][]const u8, @splat("普通正文包含 **加粗**、`inline_code` 与链接，调整窗口后应重新换行。")));
    defer a.free(prose);
    const command = try std.mem.join(a, "", &@as([12][]const u8, @splat("long_command_argument_")));
    defer a.free(command);
    const value = try std.mem.concat(a, u8, &.{ "## 检查结果\n\n", prose, "\n\n- 列表内容也应跟随实际宽度重新布局。\n\n> 引用内容保持正常换行。\n\n" ++
        "| # | 动作 | 回执 | 结论 |\n| --- | --- | --- | --- |\n" ++
        "| 1 | 检查主机网络与资源 | `status=outcome_unknown,error_code=TargetNotAuthorized` | 结果需要核对，保留完整回执 |\n\n" ++
        "```sh\nprintf '", command, "'\n```\n\n后续正文" });
    defer a.free(value);
    const message_scope = try scope.childScope();
    const message = try @import("ui/ai_message_view.zig").mountWithWidth(cx, message_scope, value, 540);
    try root.appendChild(a, message);
    const table = find(message, "ai.message.table").?;
    const content = table.children.items[0];
    const code = find(message, "ai.message.code.text").?;
    const code_scroll = find(message, "ai.message.code.scroll").?;
    find(message, "ai.message.code.wrap").?.behavior.events.on_click.?.invoke();
    var narrow_height: f32 = 0;
    for ([_]f32{ 360, 1000, 540, 360 }) |width| {
        root.setStyleInline(a, .{ .width = .{ .px = width } });
        for (0..3) |_| {
            cx.layout();
            _ = cx.render();
        }
        try std.testing.expectApproxEqAbs(@max(400, width), content.globalRect().w, 0.1);
        const cells = content.children.items[0].children.items;
        try std.testing.expectApproxEqAbs(@as(f32, 40), cells[0].globalRect().w, 0.1);
        if (width > 400) try std.testing.expect(cells[2].globalRect().w > cells[1].globalRect().w);
        try std.testing.expectApproxEqAbs(width - 20, code.globalRect().w, 0.1);
        try std.testing.expect(code_scroll.globalRect().h <= 136);
        if (width == 360) {
            if (narrow_height == 0) narrow_height = message.globalRect().h else try std.testing.expectApproxEqAbs(narrow_height, message.globalRect().h, 0.1);
        } else try std.testing.expect(message.globalRect().h < narrow_height);
        const following = message.children.items[message.children.items.len - 1];
        try std.testing.expect(following.globalRect().y >= code_scroll.globalRect().y + code_scroll.globalRect().h);
        // A pure resize retains the original nodes and wrap toggle state.
        try std.testing.expect(table == find(message, "ai.message.table").?);
        try std.testing.expect(code.getText().?.wrap == .char);
    }
    // Disposing the message releases all geometry hooks before a later frame.
    message_scope.dispose();
    root.removeChild(message);
    cx.destroyDetached(message);
    cx.layout();
    _ = cx.render();
}

test "AI conversation table distributes rendered content independent of column names and order" {
    const cx = try ui.Cx.init(a, std.testing.io);
    defer cx.deinit();
    const scope = try ui.Scope.init(a, null, cx.owner);
    defer scope.dispose();
    cx.setViewport(1000, 1000);
    const root = try ui.box(cx, .{ .width = .{ .px = 360 }, .height = .fill(), .direction = .column }, .{});
    cx.root = root;
    const message = try @import("ui/ai_message_view.zig").mount(cx, scope, "| 内容 | 结果 | ID |\n| --- | --- | --- |\n" ++
        "| 自动分配较长的中文说明和 `inline_code`，保留完整内容并在窗口变化后重新换行。 | **完成** | 12345 |\n" ++
        "| 第二行同样使用对齐的列边界。 | 正常 | 2 |");
    try root.appendChild(a, message);
    var compact: [2]f32 = @splat(0);
    for ([_]f32{ 360, 900, 480, 360 }) |width| {
        root.setStyleInline(a, .{ .width = .{ .px = width } });
        for (0..3) |_| {
            cx.layout();
            _ = cx.render();
        }
        const table = find(message, "ai.message.table").?;
        const content = table.children.items[0];
        const cells = content.children.items[0].children.items;
        try std.testing.expectApproxEqAbs(width, content.globalRect().w, 0.1);
        for (cells[1..], 0..) |cell, i| {
            const actual = cell.globalRect().w;
            try std.testing.expect(actual >= 40 and actual < 80);
            if (compact[i] == 0) compact[i] = actual else try std.testing.expectApproxEqAbs(compact[i], actual, 0.1);
        }
        try std.testing.expect(cells[0].globalRect().w > width * 0.6);
    }
}

test "AI conversation transcript image follows actual card width and preserves aspect ratio after resize" {
    const cx = try ui.Cx.init(a, std.testing.io);
    defer cx.deinit();
    const preview = @import("ui/ai_transcript_images.zig");
    var store: preview.Store = .{ .allocator = a };
    defer store.deinit();
    const scope = try ui.Scope.init(a, null, cx.owner);
    defer scope.dispose();
    const source: @import("ai/terminal_file_source.zig").Source = .{ .owner = .{ .session_id = @fromBackingInt(1) }, .cwd = "/" };
    const entry = try store.entry(source, 1, 1, "/preview.png");
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "assets/macos/AppIcon.png", a, .limited(10_000_000));
    defer a.free(bytes);
    entry.image = try @import("ai/image_attachments.zig").ContentRef.create(a, "/preview.png", bytes, 1, .{});
    entry.phase = .ready;
    const Callback = struct {
        fn open(_: *anyopaque, _: @import("ai/image_attachments.zig").ContentRef) !void {}
    };
    cx.setViewport(1000, 1500);
    const root = try ui.box(cx, .{ .width = .{ .px = 600 }, .height = .fill(), .direction = .column }, .{});
    cx.root = root;
    const message = try @import("ui/ai_message_view.zig").mountWithImages(cx, scope, "![预览](/preview.png)\n\n后续正文", 540, .{ .store = &store, .source = source, .conversation = 1, .turn = 1, .app = null, .preview_context = &store, .preview = Callback.open });
    try root.appendChild(a, message);
    const raster = find(message, "ai.transcript.image.raster").?;
    for ([_]f32{ 600, 180, 360, 120, 600 }) |width| {
        root.setStyleInline(a, .{ .width = .{ .px = width } });
        for (0..3) |_| {
            cx.layout();
            _ = cx.render();
        }
        const bounds = raster.globalRect();
        const image = entry.image.content().?;
        const scale = @min(@as(f32, 1), @min((width - 20) / @as(f32, @floatFromInt(image.width)), 240 / @as(f32, @floatFromInt(image.height))));
        try std.testing.expectApproxEqAbs(@as(f32, @floatFromInt(image.width)) * scale, bounds.w, 0.1);
        try std.testing.expectApproxEqAbs(@as(f32, @floatFromInt(image.height)) * scale, bounds.h, 0.1);
        try std.testing.expect(bounds.w <= width - 20 + 0.1);
        try std.testing.expect(raster == find(message, "ai.transcript.image.raster").?);
    }
}

const ThinkingFixture = struct {
    cx: *ui.Cx,
    scope: *ui.Scope,
    content: *ui.Node = undefined,
    card_scope: ?*ui.Scope = null,
    card: ?*ui.Node = null,
    turn: turns.Turn = .{},
    fn init(self: *ThinkingFixture) !void {
        const cx = try ui.Cx.init(a, std.testing.io);
        self.* = .{ .cx = cx, .scope = try ui.Scope.init(a, null, cx.owner) };
        cx.reduced_motion = true;
        cx.setViewport(600, 400);
        cx.root = try ui.box(cx, .{ .width = .fill(), .height = .fill(), .direction = .column }, .{});
        const outer = try ui.widgets.ScrollArea(.{ .height = 300 }).mount(self.scope, cx);
        try cx.root.?.appendChild(a, outer.container);
        self.content = outer.content;
        self.turn.thinking_scroll = try turns.ThinkingScroll.create(a);
    }
    fn rebuild(self: *ThinkingFixture, lines: usize, phase: steps.Phase) !void {
        try self.mount(lines, phase);
        self.settle();
    }
    fn mount(self: *ThinkingFixture, lines: usize, phase: steps.Phase) !void {
        if (self.card_scope) |scope| scope.dispose();
        if (self.card) |card| {
            self.cx.detachChild(self.content, card);
            self.cx.destroyDetached(card);
        }
        const text = try std.mem.join(a, "\n", @as([60][]const u8, @splat("thinking line"))[0..lines]);
        defer a.free(text);
        self.card_scope = try self.scope.childScope();
        self.card = try @import("ui/ai_step_view.zig").mount(self.cx, self.card_scope.?, .{ .title = "思考", .projection = "latest thought", .detail = text, .copy_detail = false, .phase = phase, .elapsed_ms = 100, .expanded = &self.turn.thinking_expanded, .scroll_position = self.turn.thinking_scroll, .test_id = "ai.thinking" });
        try self.content.appendChild(a, self.card.?);
    }
    fn settle(self: *ThinkingFixture) void {
        for (0..3) |_| {
            self.cx.advanceFrameClock();
            self.cx.layout();
            _ = self.cx.render();
        }
    }
    fn wheel(self: *ThinkingFixture, delta: f32) void {
        const r = find(self.card.?, "ai.step.details").?.globalRect();
        self.cx.handleScroll(.{ .x = r.x + 30, .y = r.y + r.h / 2, .dy = delta, .dx = 0 });
    }
    fn expectTail(self: *ThinkingFixture) !void {
        const viewport = find(self.card.?, "ai.step.details").?.globalRect();
        const text = find(self.card.?, "ai.step.detail").?.globalRect();
        try std.testing.expect(self.turn.thinking_scroll.?.following);
        try std.testing.expect(self.turn.thinking_scroll.?.offset > 0);
        try std.testing.expect(text.y + text.h <= viewport.y + viewport.h + 0.5);
        try std.testing.expect(text.y + text.h >= viewport.y + viewport.h - 12);
    }
    fn deinit(self: *ThinkingFixture) void {
        self.scope.dispose();
        self.turn.deinit(a);
        self.cx.deinit();
    }
};
test "AI conversation expanded thinking follows streamed remounts and preserves reader scroll" {
    var f: ThinkingFixture = undefined;
    try f.init();
    defer f.deinit();
    try f.rebuild(30, .running);
    try std.testing.expectEqual(@as(f32, 0), f.turn.thinking_scroll.?.offset);
    f.card.?.children.items[0].behavior.events.on_click.?.invoke();
    f.settle();
    try f.expectTail();
    try f.rebuild(40, .running);
    try f.expectTail();
    // Rebuild immediately after input, before another layout hook can run.
    f.wheel(80);
    try f.rebuild(45, .running);
    const held = f.turn.thinking_scroll.?.offset;
    try std.testing.expect(!f.turn.thinking_scroll.?.following);
    try std.testing.expect(held > 0);
    const Remount = struct {
        fixture: *ThinkingFixture,
        failed: bool = false,
        fn run(raw: *anyopaque, _: u8, _: bool) ui.AfterLayoutResult {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.fixture.cx.removeAfterLayoutHook(self);
            self.fixture.mount(50, .running) catch {
                self.failed = true;
            };
            return .needs_layout;
        }
    };
    var remount: Remount = .{ .fixture = &f };
    try f.cx.addAfterLayoutHook(&remount, Remount.run);
    f.settle();
    try std.testing.expect(!remount.failed);
    try std.testing.expectApproxEqAbs(held, f.turn.thinking_scroll.?.offset, 0.1);
    f.wheel(-10000);
    try f.rebuild(55, .running);
    try f.expectTail();
    f.wheel(10000);
    f.settle();
    try std.testing.expect(!f.turn.thinking_scroll.?.following);
    try std.testing.expectEqual(@as(f32, 0), f.turn.thinking_scroll.?.offset);
    f.wheel(-10000);
    f.settle();
    try f.expectTail();
    try f.rebuild(60, .succeeded);
    try f.expectTail();
    f.card.?.children.items[0].behavior.events.on_click.?.invoke();
    f.settle();
    try f.rebuild(60, .succeeded);
    try std.testing.expect(!f.turn.thinking_expanded);
    f.card.?.children.items[0].behavior.events.on_click.?.invoke();
    f.settle();
    try f.expectTail();
}
test "AI conversation attachment restore retains captured content after old turn is released" {
    const files = @import("ai/local_text_attachments.zig");
    var original = try files.Draft.init(a, .{ .session = 1 });
    defer original.deinit();
    const ticket = try original.begin();
    var ref = try files.ContentRef.create(a, "/tmp/source.txt", "original snapshot", 123);
    defer ref.release();
    _ = try original.complete(ticket, &ref);
    var bundle = try original.freeze();
    defer bundle.deinit();
    var restored = try files.Draft.init(a, .{ .session = 1 });
    defer restored.deinit();
    const stale = try restored.begin();
    try restored.restore(&bundle);
    bundle.deinit();
    try std.testing.expect(!restored.contains(stale));
    try std.testing.expectEqualStrings("original snapshot", restored.items.items[0].reference.content().?.bytes);
}
test {
    _ = steps;
}

test "AI conversation inline edit preserves actual call results and clone truncation" {
    var history = try wire.History.copy(a, &.{
        .{ .content = "first" },                                                                                                        .{ .role = .assistant, .content = "answer" },                                  .{ .content = "old request" },
        .{ .role = .assistant, .content = "", .tool_calls = &.{.{ .id = "actual-call", .name = "read_terminal", .arguments = "{}" }} }, .{ .role = .tool, .tool_call_id = "actual-call", .content = "actual stdout" },
    }, "formal answer");
    defer history.deinit();
    var edited = (try history.editedUser(a, 2, "old request", "new request")).?;
    defer edited.deinit();
    try std.testing.expectEqualStrings("old request", history.messages[2].content);
    try std.testing.expectEqualStrings("new request", edited.messages[2].content);
    try std.testing.expectEqualStrings("actual-call", edited.messages[4].tool_call_id.?);
    try std.testing.expectEqualStrings("actual stdout", edited.messages[4].content);
    try std.testing.expect((try history.editedUser(a, 0, "old request", "wrong target")) == null);
    const facts = @import("ai/tool_results.zig");
    const loop = @import("ai/tool_loop.zig");
    var ledger = loop.Loop.init(a, .{ .owner = .{ .session = 1 }, .members = .{} }, 7, .{});
    defer ledger.deinit();
    try ledger.records.append(ledger.arena.allocator(), .{ .key = .{ .owner = .{ .session = 1 }, .turn_id = 7, .call_id = "actual-call" }, .name = "read_terminal", .arguments = "{}", .arguments_hash = @splat(0), .dispatched = true, .outcome = try loop.Outcome.copy(a, &.{.{ .session_id = 1, .status = .succeeded, .stdout = "actual stdout" }}) });
    var store = facts.Store.init(a);
    defer store.deinit();
    _ = try store.capture(&ledger, &.{});
    const messages = [_]@import("ai/assistant_store.zig").Message{.{ .user = true, .text = @constCast("request"), .turn = .{ .id = 7 } }};
    store.retained_bytes = 16 * 1024 * 1024; // Discarded turns must not consume the fork budget.
    var fork = try store.cloneTurns(&messages);
    defer fork.deinit();
    store.keepTurns(&.{});
    try std.testing.expectEqual(@as(usize, 0), store.records.items.len);
    try std.testing.expectEqualStrings("actual stdout", fork.records.items[0].targets[0].result.stdout);
    try std.testing.expect(fork.retained_bytes < 16 * 1024 * 1024);
}

test "AI conversation rollback clears manager transcript while preserving prepared next request" {
    const Manager = @import("ai/turn_manager.zig").Manager;
    var manager = Manager.init(a);
    defer manager.deinit();
    manager.turn_id = 9;
    manager.scope = .{ .owner = .{ .session = 1 }, .members = .{} };
    _ = try manager.cards.append(.{ .text = "discarded response" });
    try manager.reasoning.appendSlice(a, "discarded thinking");
    try manager.round_text.appendSlice(a, "discarded context");
    manager.discardTranscript();
    try std.testing.expectEqual(@as(u64, 9), manager.turn_id);
    try std.testing.expect(manager.scope.?.owner.eql(.{ .session = 1 }));
    try std.testing.expectEqual(@as(usize, 0), manager.cards.count());
    try std.testing.expectEqual(@as(usize, 0), manager.reasoning.items.len);
    try std.testing.expectEqual(@as(usize, 0), manager.round_text.items.len);
}

test "AI conversation lifecycle row formats elapsed time and actual token usage without borders" {
    const Status = @import("ui/ai_turn_status_view.zig");
    var buffer: [96]u8 = undefined;
    try std.testing.expectEqualStrings("处理用时3分钟20秒", try Status.elapsedLabel(&buffer, 200000));
    try std.testing.expectEqualStrings("处理用时30分钟20秒", try Status.elapsedLabel(&buffer, 1820000));
    var turn: turns.Turn = .{ .sent_at_ms = 1000, .started_mono_ms = 50 };
    try std.testing.expectEqual(@as(u64, 200000), Status.elapsedMs(&turn, 999999, 200050));
    try std.testing.expectEqualStrings("本回合用量未返回", try Status.usageLabel(&buffer, &turn));
    turn.ended_at_ms = 400000;
    turn.elapsed_ms = 1820000;
    turn.input_tokens = 2400;
    turn.output_tokens = 160;
    turn.request_count = 2;
    var detail_buffer: [320]u8 = undefined;
    try std.testing.expect(std.mem.indexOf(u8, try Status.usageDetails(&detail_buffer, &turn), "请求次数 2") != null);
    try std.testing.expectEqual(@as(u64, 1820000), Status.elapsedMs(&turn, 9999999, 9999999));
    try std.testing.expectEqualStrings("本回合用量 2.6K", try Status.usageLabel(&buffer, &turn));
    const cx = try ui.Cx.init(a, std.testing.io);
    defer cx.deinit();
    const scope = try ui.Scope.init(a, null, cx.owner);
    defer scope.dispose();
    cx.setViewport(600, 200);
    cx.root = try ui.box(cx, .{ .width = .fill(), .height = .fill(), .direction = .column }, .{});
    const row = try Status.mount(cx, scope, &turn, null);
    try cx.root.?.appendChild(a, row);
    cx.layout();
    try std.testing.expectEqualStrings("～回合结束～", find(row, "ai.turn.label").?.getText().?.content);
    try std.testing.expect(find(row, "ai.turn.logo") != null);
    try std.testing.expectEqual(@as(f32, 0), @import("ui/ai_tool_results_styles.zig").card(cx.tokens).border.?.width);
}

test "AI conversation planned step updates parameters before execution with the same identity" {
    var list: std.ArrayList(steps.Step) = .empty;
    defer {
        for (list.items) |*step| step.deinit(a);
        list.deinit(a);
    }
    try steps.apply(a, &list, .{ .call_id = "stream-call", .name = "run_command", .command = "{\"command\":", .phase = .assembling, .at_ms = 1 });
    try steps.apply(a, &list, .{ .call_id = "stream-call", .name = "run_command", .command = "date", .phase = .assembling, .at_ms = 5 });
    try std.testing.expectEqualStrings("date", list.items[0].command);
    try std.testing.expectEqual(steps.Phase.assembling, list.items[0].phase);
    try steps.apply(a, &list, .{ .call_id = "stream-call", .phase = .running, .at_ms = 10 });
    try std.testing.expectEqual(@as(usize, 1), list.items.len);
    try std.testing.expectEqual(@as(u64, 1), list.items[0].started_ms);
    try std.testing.expectEqual(steps.Phase.running, list.items[0].phase);
}

test "AI conversation wave is subtle phased and disabled by reduced motion" {
    const Status = @import("ui/ai_turn_status_view.zig");
    try std.testing.expectApproxEqAbs(@as(f32, 1.5), Status.waveOffset(350, 0, false), 0.001);
    try std.testing.expect(@abs(Status.waveOffset(350, 0, false) - Status.waveOffset(350, 2, false)) > 0.5);
    for (0..7) |index| {
        try std.testing.expectEqual(@as(f32, 0), Status.waveOffset(350, index, true));
        try std.testing.expect(@abs(Status.waveOffset(1000, index, false)) <= 1.5);
    }
}

test "AI conversation activity label follows tool phases and prioritizes pending decisions" {
    const Status = @import("ui/ai_turn_status_view.zig");
    var turn: turns.Turn = .{};
    defer turn.deinit(a);
    try std.testing.expectEqualStrings("～大浪淘金中～", Status.turnLabel(&turn).text);
    try steps.apply(a, &turn.steps, .{ .call_id = "command", .name = "run_command", .phase = .assembling, .at_ms = 1 });
    try std.testing.expectEqualStrings("～准备操作中～", Status.turnLabel(&turn).text);
    try steps.apply(a, &turn.steps, .{ .call_id = "command", .phase = .approval, .at_ms = 2 });
    try std.testing.expectEqualStrings("等待确认 · 流程暂停", Status.turnLabel(&turn).text);
    try std.testing.expect(!Status.turnLabel(&turn).animated);
    try steps.apply(a, &turn.steps, .{ .call_id = "command", .phase = .approved, .at_ms = 3 });
    try std.testing.expectEqualStrings("～准备操作中～", Status.turnLabel(&turn).text);
    try steps.apply(a, &turn.steps, .{ .call_id = "command", .phase = .running, .at_ms = 4 });
    try std.testing.expectEqualStrings("～执行命令中～", Status.turnLabel(&turn).text);
    // A planned next call must not hide a currently executing command.
    try steps.apply(a, &turn.steps, .{ .call_id = "next", .name = "read_terminal", .phase = .assembling, .at_ms = 5 });
    try std.testing.expectEqualStrings("～执行命令中～", Status.turnLabel(&turn).text);
    try steps.apply(a, &turn.steps, .{ .call_id = "next", .phase = .approval, .at_ms = 6 });
    try std.testing.expectEqualStrings("等待确认 · 流程暂停", Status.turnLabel(&turn).text);
    try steps.apply(a, &turn.steps, .{ .call_id = "next", .phase = .rejected, .at_ms = 7 });
    try steps.apply(a, &turn.steps, .{ .call_id = "command", .phase = .failed, .at_ms = 8 });
    try std.testing.expectEqualStrings("～大浪淘金中～", Status.turnLabel(&turn).text);
    try std.testing.expect(Status.turnLabel(&turn).animated);
    turn.ended_at_ms = 9;
    try std.testing.expectEqualStrings("～回合结束～", Status.turnLabel(&turn).text);
    try std.testing.expect(!Status.turnLabel(&turn).animated);

    for ([_]struct { name: []const u8, label: []const u8 }{
        .{ .name = "run_command", .label = "～执行命令中～" },
        .{ .name = "read_terminal", .label = "～读取终端中～" },
        .{ .name = "read_remote_file", .label = "～读取文件中～" },
        .{ .name = "list_remote_files", .label = "～查看目录中～" },
        .{ .name = "plugin.custom_tool", .label = "～执行操作中～" },
    }) |case| {
        var tool_turn: turns.Turn = .{};
        defer tool_turn.deinit(a);
        try steps.apply(a, &tool_turn.steps, .{ .call_id = "tool", .name = case.name, .phase = .running, .at_ms = 1 });
        try std.testing.expectEqualStrings(case.label, Status.turnLabel(&tool_turn).text);
        for ([_]steps.Phase{ .succeeded, .failed, .cancelled, .rejected }) |phase| {
            tool_turn.steps.items[0].phase = phase;
            try std.testing.expectEqualStrings("～大浪淘金中～", Status.turnLabel(&tool_turn).text);
        }
    }
}

test "AI conversation activity label renders matching accessible text and pauses approval motion" {
    const Status = @import("ui/ai_turn_status_view.zig");
    for ([_]steps.Phase{ .assembling, .approval, .approved, .running, .succeeded }) |phase| {
        var turn: turns.Turn = .{};
        defer turn.deinit(a);
        try steps.apply(a, &turn.steps, .{ .call_id = "command", .name = "run_command", .phase = phase, .at_ms = 1 });
        const cx = try ui.Cx.init(a, std.testing.io);
        defer cx.deinit();
        const scope = try ui.Scope.init(a, null, cx.owner);
        defer scope.dispose();
        cx.setViewport(320, 80);
        cx.root = try ui.box(cx, .{ .width = .fill(), .height = .fill(), .direction = .column }, .{});
        const row = try Status.mount(cx, scope, &turn, null);
        try cx.root.?.appendChild(a, row);
        cx.layout();
        const label = find(row, "ai.turn.label").?;
        const expected = Status.turnLabel(&turn);
        try std.testing.expectEqualStrings(expected.text, label.behavior.interaction.a11y.?.label.?);
        var text: std.ArrayList(u8) = .empty;
        defer text.deinit(a);
        for (label.children.items) |glyph| try text.appendSlice(a, glyph.getText().?.content);
        try std.testing.expectEqualStrings(expected.text, text.items);
        try std.testing.expectEqual(try std.unicode.utf8CountCodepoints(expected.text), label.children.items.len);
        try std.testing.expectEqual(@as(usize, if (expected.animated) 2 else 1), cx.after_layout_hooks.items.len);
        const bounds = label.globalRect();
        const elapsed = find(row, "ai.turn.elapsed").?.globalRect();
        try std.testing.expect(bounds.x + bounds.w + 7.5 <= elapsed.x);
        try std.testing.expect(elapsed.x + elapsed.w <= 320);
    }
}

test "AI conversation activity label recovers when tool arguments fail before host execution" {
    const provider = @import("ai/provider.zig");
    const Manager = @import("ai/turn_manager.zig").Manager;
    const Loop = @import("ai/tool_loop.zig");
    const Status = @import("ui/ai_turn_status_view.zig");
    const Fixture = struct {
        turn: turns.Turn = .{},
        rounds: usize = 0,
        rejected: usize = 0,
        fn chat(raw: *anyopaque, request: provider.ChatRequest, sink: *const fn (*anyopaque, provider.Delta) void, context: *anyopaque) !provider.ChatStats {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.rounds += 1;
            if (self.rounds == 1) {
                sink(context, .{ .tool_plan = .{ .call_id = "invalid-arguments", .name = "run_command", .arguments = "{}" } });
                try std.testing.expectEqualStrings("～准备操作中～", Status.turnLabel(&self.turn).text);
            } else {
                try std.testing.expectEqual(@as(usize, 1), self.rejected);
                try std.testing.expectEqual(provider.Role.tool, request.messages[2].role);
                try std.testing.expectEqualStrings("～大浪淘金中～", Status.turnLabel(&self.turn).text);
                sink(context, .{ .text = "继续处理参数错误" });
            }
            sink(context, .done);
            return .{};
        }
        fn models(_: *anyopaque, allocator: std.mem.Allocator) ![]provider.ModelInfo {
            return allocator.alloc(provider.ModelInfo, 0);
        }
        fn execute(_: *anyopaque, _: Loop.Invocation, _: std.mem.Allocator, _: ?*provider.CancelToken) !Loop.Outcome {
            return error.InvalidToolMustNotExecute;
        }
        fn reset(_: *anyopaque) void {}
        fn delta(raw: *anyopaque, value: provider.Delta) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            if (value == .tool_plan) try steps.apply(a, &self.turn.steps, .{ .call_id = value.tool_plan.call_id.?, .name = value.tool_plan.name.?, .phase = .assembling, .at_ms = 1 });
        }
        fn reject(raw: *anyopaque, call: provider.ToolCall, detail: []const u8) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.rejected += 1;
            try std.testing.expect(detail.len > 0);
            try steps.apply(a, &self.turn.steps, .{ .call_id = call.id, .name = call.name, .detail = detail, .phase = .failed, .at_ms = 2 });
        }
    };
    var fixture: Fixture = .{};
    defer fixture.turn.deinit(a);
    var manager = Manager.init(a);
    defer manager.deinit();
    manager.scope = .{ .owner = .{ .session = 101 }, .members = .{ .ids = .{101} ++ @as([15]u64, @splat(0)), .len = 1 } };
    manager.tool_host = .{ .context = &fixture, .execute = Fixture.execute };
    manager.observer = .{ .context = &fixture, .reset = Fixture.reset, .delta = Fixture.delta, .tool_rejected = Fixture.reject };
    _ = try manager.run(.{ .ctx = &fixture, .chat = Fixture.chat, .models = Fixture.models }, .{ .model = "invalid-tool-fixture", .system = "", .messages = &.{.{ .content = "检查参数错误后的状态" }}, .tools = &.{.{ .tool = .run_command, .session_ids = &.{101} }} });
    try std.testing.expectEqual(@as(usize, 2), fixture.rounds);
    try std.testing.expectEqual(steps.Phase.failed, fixture.turn.steps.items[0].phase);
}

test "AI conversation processing time freezes through indefinite approval wait and preserves message boundaries" {
    const events = @import("ai/step_events.zig");
    const Status = @import("ui/ai_turn_status_view.zig");
    var turn: @import("ai/conversation_turn.zig").Turn = .{ .started_mono_ms = 1000 };
    defer turn.deinit(a);
    try turn.prose.appendSlice(a, "先确认命令，再执行。");
    try events.apply(a, &turn.steps, .{ .call_id = "one", .name = "host.run_in_terminal", .phase = .assembling, .text_offset = turn.prose.items.len, .at_ms = 1200 });
    try events.apply(a, &turn.steps, .{ .call_id = "one", .phase = .approval, .at_ms = 2000 });
    try std.testing.expectEqual(@as(u64, 1000), Status.elapsedMs(&turn, 0, 122000));
    try std.testing.expectEqualStrings("等待确认 · 流程暂停", Status.turnLabel(&turn).text);
    try std.testing.expectEqual(@as(u64, 1000), Status.elapsedMs(&turn, 0, 242000));
    try std.testing.expectEqual(@as(u64, 0), turn.steps.items[0].elapsedAt(242000));
    try events.apply(a, &turn.steps, .{ .call_id = "one", .phase = .approved, .at_ms = 242000 });
    try events.apply(a, &turn.steps, .{ .call_id = "one", .phase = .running, .at_ms = 242010 });
    try events.apply(a, &turn.steps, .{ .call_id = "one", .phase = .succeeded, .at_ms = 242100 });
    try turn.prose.appendSlice(a, "命令完成。");
    var copy = try turn.clone(a);
    defer copy.deinit(a);
    try std.testing.expectEqualStrings(turn.prose.items, copy.prose.items);
    try std.testing.expectEqual(@as(usize, "先确认命令，再执行。".len), copy.steps.items[0].text_offset);
    try std.testing.expectEqual(@as(u64, 100), copy.steps.items[0].elapsedAt(300000));
    try std.testing.expectEqual(@as(u64, 1100), Status.elapsedMs(&copy, 0, 242100));
}

const aggregation = @import("ai/step_groups.zig");
test {
    _ = @import("ai/step_failure.zig");
    _ = @import("host/terminal_execution.zig");
}
fn groupEvent(turn: *turns.Turn, event: steps.Event, expanded: bool) !void {
    try turn.applyEvent(a, event);
    try aggregation.sync(a, turn, expanded);
}
test "AI step aggregation groups one or more steps between prose, preserving defaults and manual state" {
    var turn: turns.Turn = .{};
    defer turn.deinit(a);
    try groupEvent(&turn, .{ .kind = .text, .detail = "before", .phase = .running, .at_ms = 1 }, false);
    try groupEvent(&turn, .{ .call_id = "read", .name = "read_terminal", .phase = .running, .at_ms = 2 }, false);
    try std.testing.expectEqual(@as(usize, 1), turn.step_groups.items.len);
    const first = turn.step_groups.items[0];
    try std.testing.expect(!first.expanded);
    first.expanded = true;
    try groupEvent(&turn, .{ .call_id = "read", .phase = .succeeded, .at_ms = 5 }, false);
    try groupEvent(&turn, .{ .kind = .round_start, .phase = .running, .at_ms = 6 }, false);
    try groupEvent(&turn, .{ .kind = .thinking, .detail = "thought", .phase = .running, .at_ms = 7 }, false);
    try groupEvent(&turn, .{ .kind = .thinking, .detail = " tail", .phase = .running, .at_ms = 8 }, false);
    try std.testing.expect(first.expanded);
    try std.testing.expectEqual(@as(usize, 1), turn.step_groups.items.len);
    var summary = aggregation.summarize(&turn, 1, turn.timeline.items.len, 10);
    try std.testing.expectEqual(@as(usize, 2), summary.count);
    try std.testing.expectEqual(steps.Phase.running, summary.phase);
    try std.testing.expectEqualStrings("thought tail", summary.latest.?.thinking.text.items);
    try std.testing.expectEqualStrings("thought tail", summary.thinking_projection.?);
    // Empty deltas do not end a group; a real model message does.
    try groupEvent(&turn, .{ .kind = .text, .detail = " \n", .phase = .running, .at_ms = 9 }, false);
    try std.testing.expectEqual(@as(usize, 1), turn.step_groups.items.len);
    try groupEvent(&turn, .{ .kind = .text, .detail = "between", .phase = .running, .at_ms = 10 }, false);
    try groupEvent(&turn, .{ .kind = .thinking, .detail = "second", .phase = .running, .at_ms = 11 }, true);
    try std.testing.expectEqual(@as(usize, 2), turn.step_groups.items.len);
    const second = turn.step_groups.items[1];
    try std.testing.expect(second.expanded);
    second.expanded = false;
    try groupEvent(&turn, .{ .call_id = "search", .name = "run_command", .phase = .running, .at_ms = 12 }, true);
    try groupEvent(&turn, .{ .call_id = "search", .phase = .succeeded, .at_ms = 14 }, true);
    turn.finishSegment(14);
    try aggregation.sync(a, &turn, true);
    try std.testing.expect(!second.expanded);
    try std.testing.expect(first.expanded);
    summary = aggregation.summarize(&turn, second.first, turn.timeline.items.len, 14);
    try std.testing.expectEqual(@as(usize, 2), summary.count);
    try std.testing.expectEqual(steps.Phase.succeeded, summary.phase);
    try std.testing.expectEqual(@as(u64, 3), summary.elapsed_ms);
    try std.testing.expectEqual(@as(?[]const u8, null), summary.thinking_projection);
}

test "AI step aggregation projects only the current live thinking line" {
    var turn: turns.Turn = .{ .sent_at_ms = 1 };
    defer turn.deinit(a);
    try groupEvent(&turn, .{ .kind = .thinking, .detail = "上一行\n正在核对最新错误\n\t ", .phase = .running, .at_ms = 2 }, false);
    var summary = aggregation.summarize(&turn, 0, turn.timeline.items.len, 3);
    try std.testing.expectEqualStrings("正在核对最新错误", summary.thinking_projection.?);
    try groupEvent(&turn, .{ .kind = .thinking, .detail = "\n已定位新的线索", .phase = .running, .at_ms = 4 }, false);
    summary = aggregation.summarize(&turn, 0, turn.timeline.items.len, 5);
    try std.testing.expectEqualStrings("已定位新的线索", summary.thinking_projection.?);
    try groupEvent(&turn, .{ .kind = .text, .detail = "继续执行检查。", .phase = .running, .at_ms = 6 }, false);
    summary = aggregation.summarize(&turn, 0, aggregation.rangeEnd(&turn, 0), 7);
    try std.testing.expectEqual(@as(?[]const u8, null), summary.thinking_projection);
    try std.testing.expectEqual(@as(usize, 1), summary.count);
}
test "AI step aggregation keeps cloned disclosure independent and resets only discarded groups" {
    var turn: turns.Turn = .{};
    defer turn.deinit(a);
    try groupEvent(&turn, .{ .kind = .thinking, .detail = "retained", .phase = .running, .at_ms = 1 }, true);
    try groupEvent(&turn, .{ .kind = .text, .detail = "retained message", .phase = .running, .at_ms = 2 }, true);
    try groupEvent(&turn, .{ .kind = .round_start, .phase = .running, .at_ms = 3 }, false);
    try groupEvent(&turn, .{ .kind = .thinking, .detail = "discarded", .phase = .running, .at_ms = 4 }, false);
    const discarded = turn.step_groups.items[1];
    discarded.retain();
    defer discarded.release();
    var clone = try turn.clone(a);
    defer clone.deinit(a);
    try std.testing.expect(clone.step_groups.items[0] != turn.step_groups.items[0]);
    clone.step_groups.items[0].expanded = false;
    try std.testing.expect(turn.step_groups.items[0].expanded);
    try groupEvent(&turn, .{ .kind = .reset, .phase = .running, .at_ms = 5 }, true);
    try std.testing.expectEqual(@as(usize, 1), turn.step_groups.items.len);
    try std.testing.expect(!discarded.expanded);
    try groupEvent(&turn, .{ .kind = .thinking, .detail = "retry", .phase = .running, .at_ms = 6 }, true);
    try std.testing.expectEqual(@as(usize, 2), turn.step_groups.items.len);
    try std.testing.expect(turn.step_groups.items[1] != discarded);
    try std.testing.expect(turn.step_groups.items[1].expanded);
}
test "AI step aggregation includes all settled outcomes and leaves only pending approvals outside" {
    var turn: turns.Turn = .{};
    defer turn.deinit(a);
    try groupEvent(&turn, .{ .call_id = "approval", .name = "run_command", .phase = .approval, .at_ms = 1 }, false);
    try std.testing.expectEqual(@as(usize, 0), turn.step_groups.items.len);
    try groupEvent(&turn, .{ .call_id = "approval", .phase = .rejected, .at_ms = 2 }, false);
    try std.testing.expectEqual(@as(usize, 1), turn.step_groups.items.len);
    try groupEvent(&turn, .{ .call_id = "run", .name = "run_command", .phase = .running, .at_ms = 3 }, false);
    try groupEvent(&turn, .{ .call_id = "run", .phase = .failed, .at_ms = 6 }, false);
    try groupEvent(&turn, .{ .kind = .thinking, .detail = "investigate", .phase = .running, .at_ms = 7 }, false);
    const summary = aggregation.summarize(&turn, 0, turn.timeline.items.len, 9);
    try std.testing.expectEqual(@as(usize, 3), summary.count);
    try std.testing.expectEqual(steps.Phase.failed, summary.phase);
    try std.testing.expect(summary.live);
    try groupEvent(&turn, .{ .call_id = "unsent", .name = "host.run_in_terminal", .phase = .failed, .at_ms = 10 }, false);
    try groupEvent(&turn, .{ .call_id = "cancelled", .name = "host.run_in_terminal", .phase = .cancelled, .at_ms = 11 }, false);
    try std.testing.expectEqual(@as(usize, 1), turn.step_groups.items.len);
    try std.testing.expectEqual(@as(usize, 5), aggregation.summarize(&turn, 0, turn.timeline.items.len, 12).count);
    try std.testing.expectEqual(steps.Phase.failed, aggregation.summarize(&turn, 0, turn.timeline.items.len, 12).phase);
    try groupEvent(&turn, .{ .kind = .text, .detail = "model message", .phase = .running, .at_ms = 13 }, false);
    try groupEvent(&turn, .{ .call_id = "next", .name = "read_terminal", .phase = .failed, .at_ms = 14 }, false);
    try std.testing.expectEqual(@as(usize, 2), turn.step_groups.items.len);
}
test "AI step aggregation native disclosure keeps existing step cards and adds only soft edges" {
    const cx = try ui.Cx.init(a, std.testing.io);
    defer cx.deinit();
    const scope = try ui.Scope.init(a, null, cx.owner);
    defer scope.dispose();
    cx.reduced_motion = true;
    cx.setViewport(600, 456);
    const root = try ui.box(cx, .{ .width = .{ .px = 570 }, .height = .fill(), .direction = .column }, .{});
    cx.root = root;
    const group = try aggregation.State.create(a, 0, false);
    defer group.release();
    const view = try @import("ui/ai_step_group_view.zig").mount(cx, scope, .{ .group = group, .title = "思考", .projection = "1 个步骤", .phase = .succeeded, .elapsed_ms = 40 });
    try root.appendChild(a, view.root);
    var step_expanded = false;
    const card = try @import("ui/ai_step_view.zig").mount(cx, scope, .{ .title = "思考", .projection = "original summary", .detail = "original thinking", .phase = .succeeded, .elapsed_ms = 40, .expanded = &step_expanded });
    try view.content.appendChild(a, card);
    for (0..3) |_| {
        cx.advanceFrameClock();
        cx.layout();
        _ = cx.render();
    }
    try std.testing.expectApproxEqAbs(@as(f32, 32), view.root.globalRect().h, 0.1);
    const header = find(view.root, "ai.step_group.header").?;
    header.behavior.events.on_click.?.invoke();
    for (0..3) |_| {
        cx.advanceFrameClock();
        cx.layout();
        _ = cx.render();
    }
    try std.testing.expect(group.expanded);
    try std.testing.expectApproxEqAbs(@as(f32, 32), card.globalRect().h, 0.1);
    try std.testing.expectApproxEqAbs(@as(f32, 76), view.root.globalRect().h, 0.1);
    try std.testing.expectApproxEqAbs(card.globalRect().w, header.globalRect().w, 0.1);
    try std.testing.expectEqualStrings("已完成 · original summary", find(card, "ai.step.projection").?.getText().?.content);
    try std.testing.expect(find(card, "ai.step.separator") != null);
    try std.testing.expectEqual(@as(f32, 0), view.root.style.border.width);
    try std.testing.expectEqual(@as(u8, 0), view.root.getBackground().a);
    try std.testing.expectApproxEqAbs(@as(f32, 6), find(view.root, "ai.step_group.edge.top").?.globalRect().h, 0.1);
    const bottom_edge = find(view.root, "ai.step_group.edge.bottom").?.globalRect();
    try std.testing.expect(bottom_edge.y >= card.globalRect().y + card.globalRect().h - 0.1);
    // Appending cards grows the disclosure; there is no step-count/height cap,
    // and the final card always ends above the soft bottom edge.
    var extra_expanded = [_]bool{ false, false, false };
    var last = card;
    for (&extra_expanded) |*expanded| {
        last = try @import("ui/ai_step_view.zig").mount(cx, scope, .{ .title = "搜索终端内容", .projection = "command not found", .detail = "unchanged result", .phase = .succeeded, .elapsed_ms = 10, .expanded = expanded });
        try view.content.appendChild(a, last);
    }
    for (0..3) |_| {
        cx.advanceFrameClock();
        cx.layout();
        _ = cx.render();
    }
    try std.testing.expectApproxEqAbs(@as(f32, 190), view.root.globalRect().h, 0.1);
    try std.testing.expectApproxEqAbs(@as(f32, 32), last.globalRect().h, 0.1);
    try std.testing.expect(find(view.root, "ai.step_group.edge.bottom").?.globalRect().y >= last.globalRect().y + last.globalRect().h - 0.1);
    find(card, "ai.step.header").?.behavior.events.on_click.?.invoke();
    for (0..3) |_| {
        cx.advanceFrameClock();
        cx.layout();
        _ = cx.render();
    }
    try std.testing.expect(step_expanded);
    header.behavior.events.on_click.?.invoke();
    try std.testing.expect(!group.expanded);
    try std.testing.expect(step_expanded);
}

test "AI timeline retains existing messages across appends and disposes reset row callbacks" {
    const Retained = @import("ui/ai_timeline_view.zig");
    const Fixture = struct {
        count: usize = 2,
        released: usize = 0,
        fn toggled(_: *@This()) void {}
        fn release(self: *@This()) void {
            self.released += 1;
        }
        fn sync(raw: *anyopaque, view: *Retained.View) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            for (0..self.count) |index| {
                const row = try view.row(index, index, .message);
                if (row.root.children.items.len == 0) {
                    try row.scope.onCleanup(@This(), self, release);
                    try row.root.appendChild(a, try ui.text(view.cx, "retained message", .{}));
                }
            }
            view.truncate(self.count);
        }
    };
    const cx = try ui.Cx.init(a, std.testing.io);
    defer cx.deinit();
    const scope = try ui.Scope.init(a, null, cx.owner);
    defer scope.dispose();
    cx.setViewport(600, 456);
    cx.root = try ui.box(cx, .{ .width = .fill(), .height = .fill(), .direction = .column }, .{});
    var fixture: Fixture = .{};
    const view = try Retained.View.mount(cx, scope, cx.root.?, &fixture, Fixture.sync, cx.on(Fixture, &fixture, Fixture.toggled));
    for (0..3) |_| {
        cx.advanceFrameClock();
        cx.layout();
        _ = cx.render();
    }
    const first = view.rows.items[0].root.id;
    const discarded = view.rows.items[1].root.id;
    fixture.count = 6;
    view.invalidate();
    for (0..3) |_| {
        cx.advanceFrameClock();
        cx.layout();
        _ = cx.render();
    }
    try std.testing.expectEqual(first, view.rows.items[0].root.id);
    try std.testing.expectEqual(discarded, view.rows.items[1].root.id);
    fixture.count = 1;
    view.invalidate();
    for (0..3) |_| {
        cx.advanceFrameClock();
        cx.layout();
        _ = cx.render();
    }
    try std.testing.expectEqual(@as(usize, 5), fixture.released);
    fixture.count = 2;
    view.invalidate();
    for (0..3) |_| {
        cx.advanceFrameClock();
        cx.layout();
        _ = cx.render();
    }
    try std.testing.expectEqual(first, view.rows.items[0].root.id);
    try std.testing.expect(discarded != view.rows.items[1].root.id);
}

test "AI retained thinking updates preserve open detail nodes and own streamed bytes" {
    const cx = try ui.Cx.init(a, std.testing.io);
    defer cx.deinit();
    const scope = try ui.Scope.init(a, null, cx.owner);
    defer scope.dispose();
    cx.setViewport(600, 456);
    cx.root = try ui.box(cx, .{ .width = .fill(), .height = .fill(), .direction = .column }, .{});
    var expanded = false;
    const Step = @import("ui/ai_step_view.zig");
    var props: Step.Props = .{ .title = "思考", .projection = "initial", .detail = "long thinking before disclosure", .copy_detail = false, .phase = .running, .elapsed_ms = 0, .expanded = &expanded };
    const result = try Step.mountRetained(cx, scope, props);
    try cx.root.?.appendChild(a, result.root);
    const header = find(result.root, "ai.step.header").?;
    const detail = find(result.root, "ai.step.detail").?;
    try std.testing.expectEqualStrings("", detail.getText().?.content);
    header.behavior.events.on_click.?.invoke();
    try std.testing.expect(expanded);
    try std.testing.expectEqualStrings(props.detail, detail.getText().?.content);
    for (0..20) |index| {
        var buffer: [128]u8 = undefined;
        const text = try std.fmt.bufPrint(&buffer, "thinking fragment {d}", .{index});
        props.detail = text;
        props.projection = text;
        try result.update(props);
        @memset(&buffer, 'x');
        cx.advanceFrameClock();
        cx.layout();
        _ = cx.render();
        try std.testing.expect(find(result.root, "ai.step.header").? == header);
        try std.testing.expect(find(result.root, "ai.step.detail").? == detail);
        try std.testing.expect(expanded);
        try std.testing.expect(!std.mem.startsWith(u8, detail.getText().?.content, "xxx"));
    }
    header.behavior.events.on_click.?.invoke();
    props.detail = "new bytes while collapsed";
    props.projection = "new summary";
    try result.update(props);
    try std.testing.expect(!expanded);
    try std.testing.expect(!std.mem.eql(u8, props.detail, detail.getText().?.content));
    header.behavior.events.on_click.?.invoke();
    try std.testing.expectEqualStrings(props.detail, detail.getText().?.content);
}

test "AI transcript keyed sections reuse stable nodes when their fingerprint is unchanged" {
    const T = @import("ui/ai_transcript_view.zig");
    const cx = try ui.Cx.init(a, std.testing.io);
    defer cx.deinit();
    const scope = try ui.Scope.init(a, null, cx.owner);
    defer scope.dispose();
    cx.setViewport(600, 900);
    const conv = try ui.box(cx, .{ .width = .{ .px = 540 }, .height = .fill(), .direction = .column, .gap = 6 }, .{});
    cx.root = conv;

    const Counter = struct {
        calls: usize = 0,
        cx: *ui.Cx,
        fn render(raw: *anyopaque, arg: usize, s: *ui.Scope, root: *ui.Node) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.calls += 1;
            _ = arg;
            _ = s;
            try root.appendChild(self.cx.allocator, try ui.text(self.cx, "row", .{}));
        }
    };
    var counter: Counter = .{ .cx = cx };
    const view = try T.View.mount(cx, scope, conv);
    const base = T.Spec{ .key = 1, .kind = .history, .fingerprint = 100, .context = &counter, .render = Counter.render };
    const second = T.Spec{ .key = 2, .kind = .history, .fingerprint = 200, .context = &counter, .render = Counter.render };
    const specs = [_]T.Spec{ base, second };

    try std.testing.expect(try view.sync(&specs));
    try std.testing.expectEqual(@as(usize, 2), counter.calls);
    const root_a = view.rows.items[0].root;
    const root_b = view.rows.items[1].root;
    const scope_a = view.rows.items[0].scope;

    // A submit that only changes the live section leaves completed history
    // untouched: no render callback, same node and same widget scope.
    try std.testing.expect(!try view.sync(&specs));
    try std.testing.expectEqual(@as(usize, 2), counter.calls);
    try std.testing.expectEqual(root_a, view.rows.items[0].root);
    try std.testing.expectEqual(scope_a, view.rows.items[0].scope);

    // Changing one section re-renders only that section's body; the row node
    // itself (and every sibling) survives.
    var specs_changed = specs;
    specs_changed[1].fingerprint = 201;
    try std.testing.expect(try view.sync(&specs_changed));
    try std.testing.expectEqual(@as(usize, 3), counter.calls);
    try std.testing.expectEqual(root_a, view.rows.items[0].root);
    try std.testing.expectEqual(scope_a, view.rows.items[0].scope);
    try std.testing.expectEqual(root_b, view.rows.items[1].root);

    const specs_added = [_]T.Spec{ specs_changed[0], specs_changed[1], .{ .key = 3, .kind = .history, .fingerprint = 300, .context = &counter, .render = Counter.render } };
    try std.testing.expect(try view.sync(&specs_added));
    try std.testing.expectEqual(root_a, view.rows.items[0].root);
    try std.testing.expectEqual(root_b, view.rows.items[1].root);
    try std.testing.expectEqual(@as(usize, 3), view.rows.items.len);

    // Truncating the suffix keeps the retained prefix.
    try std.testing.expect(try view.sync(&specs_changed));
    try std.testing.expectEqual(@as(usize, 2), view.rows.items.len);
    try std.testing.expectEqual(root_a, view.rows.items[0].root);

    // A different stable key at the same slot replaces only that row.
    var specs_rekeyed = specs_changed;
    specs_rekeyed[0].key = 9;
    try std.testing.expect(try view.sync(&specs_rekeyed));
    try std.testing.expect(view.rows.items[0].root != root_a);
    try std.testing.expectEqual(root_b, view.rows.items[1].root);
    const rekeyed = view.rows.items[0].root;
    const inserted = [_]T.Spec{ .{ .key = 10, .kind = .history, .fingerprint = 400, .context = &counter, .render = Counter.render }, specs_rekeyed[0], specs_rekeyed[1] };
    try std.testing.expect(try view.sync(&inserted));
    try std.testing.expectEqual(rekeyed, view.rows.items[1].root);
    try std.testing.expectEqual(root_b, view.rows.items[2].root);
    try std.testing.expect(try view.sync(&specs_rekeyed));
    try std.testing.expectEqual(rekeyed, view.rows.items[0].root);
    try std.testing.expectEqual(root_b, view.rows.items[1].root);
}

test "AI transcript invalidates borrowed widgets before disposing a failed or removed body" {
    const T = @import("ui/ai_transcript_view.zig");
    const cx = try ui.Cx.init(a, std.testing.io);
    defer cx.deinit();
    const scope = try ui.Scope.init(a, null, cx.owner);
    defer scope.dispose();
    cx.root = try ui.box(cx, .{ .direction = .column }, .{});
    const Context = struct {
        cx: *ui.Cx,
        borrowed: ?*ui.Scope = null,
        cleanups: usize = 0,
        fail: bool = false,
        fn invalidate(raw: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.borrowed = null;
        }
        fn cleanup(self: *@This()) void {
            std.debug.assert(self.borrowed == null);
            self.cleanups += 1;
        }
        fn render(raw: *anyopaque, _: usize, body: *ui.Scope, root: *ui.Node) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.borrowed = body;
            try body.onCleanup(@This(), self, cleanup);
            try root.appendChild(a, try ui.text(self.cx, "partial body", .{}));
            if (self.fail) return error.InjectedRenderFailure;
        }
    };
    var context: Context = .{ .cx = cx, .fail = true };
    const view = try T.View.mount(cx, scope, cx.root.?);
    var spec: T.Spec = .{ .key = 1, .kind = .cards, .fingerprint = 1, .context = &context, .render = Context.render, .invalidate = Context.invalidate };
    try std.testing.expectError(error.InjectedRenderFailure, view.sync(&.{spec}));
    try std.testing.expect(context.borrowed == null);
    try std.testing.expectEqual(@as(usize, 1), context.cleanups);
    try std.testing.expectEqual(@as(usize, 0), view.rows.items[0].root.children.items.len);
    context.fail = false;
    try std.testing.expect(try view.sync(&.{spec}));
    try std.testing.expect(!try view.sync(&.{spec}));
    try std.testing.expectEqual(@as(usize, 1), context.cleanups);
    spec.fingerprint += 1;
    try std.testing.expect(try view.sync(&.{spec}));
    try std.testing.expectEqual(@as(usize, 2), context.cleanups);
    spec.key += 1;
    try std.testing.expect(try view.sync(&.{spec}));
    try std.testing.expect(context.borrowed != null);
    try std.testing.expectEqual(@as(usize, 3), context.cleanups);
    try std.testing.expect(try view.sync(&.{}));
    try std.testing.expectEqual(@as(usize, 4), context.cleanups);
    try std.testing.expect(context.borrowed == null);
}

test "AI transcript completed disclosures survive turn archival and history allocation moves" {
    const T = @import("ui/ai_transcript_view.zig");
    const Message = @import("ai/assistant_store.zig").Message;
    const Summary = @import("ui/ai_turn_summary_view.zig").View;
    var current: turns.Turn = .{ .id = 17, .sent_at_ms = 1, .ended_at_ms = 2 };
    defer current.deinit(a);
    var history: std.ArrayList(Message) = .empty;
    defer {
        for (history.items) |*message| message.deinit(a);
        history.deinit(a);
    }
    const cx = try ui.Cx.init(a, std.testing.io);
    defer cx.deinit();
    const scope = try ui.Scope.init(a, null, cx.owner);
    defer scope.dispose();
    cx.root = try ui.box(cx, .{ .direction = .column }, .{});
    const Context = struct {
        turn: *turns.Turn,
        renders: usize = 0,
        fn toggle(_: *@This()) void {}
        fn render(raw: *anyopaque, _: *ui.Node, _: *ui.Scope) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            std.debug.assert(self.turn.id == 17);
            self.renders += 1;
        }
    };
    var context: Context = .{ .turn = &current };
    var bindings: T.TurnBindings = .{};
    const summary = try Summary.mount(cx, scope, cx.root.?, &current, &context, Context.render, cx.on(Context, &context, Context.toggle));
    try bindings.bind(scope, 0, &current, .{ .turn = &summary.turn });
    try bindings.bind(scope, 0, &current, .{ .turn = &context.turn });
    const thinking = try @import("ui/ai_step_view.zig").mountRetained(cx, scope, .{ .title = "思考", .projection = "思考", .detail = "detail", .phase = .succeeded, .elapsed_ms = 1, .expanded = &current.thinking_expanded });
    try cx.root.?.appendChild(a, thinking.root);
    try bindings.bind(scope, 0, &current, .{ .thinking = thinking });
    try history.append(a, .{ .user = true, .text = try a.dupe(u8, "question"), .turn = current });
    current = .{};
    bindings.rebind(history.items);
    try history.ensureTotalCapacity(a, history.capacity + 1);
    bindings.rebind(history.items);
    try std.testing.expectEqual(&history.items[0].turn.?, summary.turn);
    try std.testing.expectEqual(summary.turn, context.turn);
    find(summary.root, "ai.turn.process.toggle").?.behavior.events.on_click.?.invoke();
    try std.testing.expect(history.items[0].turn.?.process_expanded);
    try std.testing.expectEqual(@as(usize, 1), context.renders);
    find(thinking.root, "ai.step.header").?.behavior.events.on_click.?.invoke();
    try std.testing.expect(history.items[0].turn.?.thinking_expanded);
    try std.testing.expect(!current.process_expanded and !current.thinking_expanded);
    // Scope cleanup unregisters all borrowed addresses before their storage dies.
    const transient = try scope.childScope();
    var pointer = &history.items[0].turn.?;
    const previous_head = bindings.head;
    try bindings.bind(transient, 0, pointer, .{ .turn = &pointer });
    transient.dispose();
    try std.testing.expectEqual(previous_head, bindings.head);
}

test "AI transcript virtual history preserves unchanged visible bodies through data updates" {
    const History = @import("ui/ai_history_view.zig");
    const cx = try ui.Cx.init(a, std.testing.io);
    defer cx.deinit();
    const scope = try ui.Scope.init(a, null, cx.owner);
    defer scope.dispose();
    try cx.setTestFrameStep(16);
    cx.reduced_motion = true;
    cx.setViewport(700, 500);
    cx.root = try ui.box(cx, .{ .width = .fill(), .height = .fill(), .direction = .column }, .{});
    const outer = try ui.widgets.ScrollArea(.{ .height = 400, .rubber_band_y = false }).mount(scope, cx);
    try cx.root.?.appendChild(a, outer.container);
    var heights: History.Heights = .{};
    defer heights.deinit(a);
    var keys: [101]usize = undefined;
    var fingerprints: [101]u64 = @splat(1);
    for (&keys, 0..) |*key, i| key.* = i;
    const Context = struct {
        calls: [101]usize = @splat(0),
        fn render(raw: *anyopaque, index: usize, _: *ui.Scope, c: *ui.Cx) !*ui.Node {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.calls[index] += 1;
            return ui.box(c, .{ .width = .fill(), .height = .{ .px = 72 }, .flex_shrink = 0 }, .{});
        }
        fn frames(c: *ui.Cx) void {
            for (0..8) |_| {
                c.advanceFrameClock();
                _ = c.render();
            }
        }
    };
    var context: Context = .{};
    const view = try History.View.mount(cx, scope, outer, keys[0..100], &heights, &context, Context.render);
    try view.update(keys[0..100], fingerprints[0..100]);
    try outer.content.appendChild(a, view.root);
    Context.frames(cx);
    const first = view.state.pool_nodes[0].children.items[0];
    const calls = context.calls[0];
    const measured = view.state.itemHeight(0);
    try view.update(&keys, &fingerprints);
    Context.frames(cx);
    try std.testing.expectEqual(first, view.state.pool_nodes[0].children.items[0]);
    try std.testing.expectEqual(calls, context.calls[0]);
    try std.testing.expectEqual(measured, view.state.itemHeight(0));
    fingerprints[1] += 1;
    const second_calls = context.calls[1];
    try view.update(&keys, &fingerprints);
    Context.frames(cx);
    try std.testing.expectEqual(first, view.state.pool_nodes[0].children.items[0]);
    try std.testing.expectEqual(calls, context.calls[0]);
    try std.testing.expectEqual(second_calls + 1, context.calls[1]);
    try view.update(keys[0..99], fingerprints[0..99]);
    Context.frames(cx);
    try std.testing.expectEqual(first, view.state.pool_nodes[0].children.items[0]);
    try std.testing.expectEqual(calls, context.calls[0]);
    try std.testing.expectEqual(@as(usize, 99), view.state.item_count);
}
