//! Cx layout and exact owned facts; no provider/remote IO is mocked as native evidence.
const std = @import("std");
const ui = @import("ui");
const facts = @import("ai/tool_results.zig");
const loop = @import("ai/tool_loop.zig");
const View = @import("ui/ai_tool_results_view.zig");
const a = std.testing.allocator;
test {
    _ = @import("ui/ai_card_scroll.zig");
}
fn find(node: *ui.Node, id: []const u8) ?*ui.Node {
    if (node.meta.ownership.meta.test_id) |test_id| if (std.mem.eql(u8, test_id, id)) return node;
    for (node.children.items) |child| if (find(child, id)) |result| return result;
    return null;
}
test "tool result view shows actual mixed target facts after source ledger destruction with bounded internal scrolling" {
    var store = facts.Store.init(a);
    defer store.deinit();
    var run = loop.Loop.init(a, .{ .owner = .{ .group = 7 }, .members = .{} }, 4, .{});
    const outcome = try loop.Outcome.copy(a, &.{
        .{ .session_id = 101, .status = .succeeded, .transport = .local, .stdout = "Error is ordinary stdout with exit zero", .exit = 0 },
        .{ .session_id = 102, .status = .cancelled, .transport = .ssh, .stdout = "actual partial output", .stderr = "actual stderr retained", .local_released = true, .remote_effect_unknown = true },
        .{ .session_id = 103, .status = .unknown, .transport = .local, .local_released = false, .remote_effect_unknown = false, .signal = 9 },
    });
    try run.records.append(run.arena.allocator(), .{ .key = .{ .owner = .{ .group = 7 }, .turn_id = 4, .call_id = "call-real-facts" }, .name = "run_command", .arguments = "{\"session_ids\":[101,102],\"command\":\"actual command\"}", .arguments_hash = @splat(7), .dispatched = true, .outcome = outcome });
    _ = try store.capture(&run, &.{ .{ .owner = .{ .session_id = @fromBackingInt(101), .generation = 2 }, .label = "本机 · zsh" }, .{ .owner = .{ .session_id = @fromBackingInt(102), .generation = 9 }, .label = "SSH · original@remote:22" } });
    run.deinit();
    const cx = try ui.Cx.init(a, std.testing.io);
    defer cx.deinit();
    cx.setViewport(860, 480);
    const scope = try ui.Scope.init(a, null, cx.owner);
    defer scope.dispose();
    const root = try ui.box(cx, .{ .width = .{ .px = 572 }, .height = .fill(), .direction = .column }, .{});
    cx.root = root;
    try View.appendForOwner(cx, scope, root, &store, .{ .session = 101 });
    try std.testing.expectEqual(@as(usize, 0), root.children.items.len);
    try View.appendForOwner(cx, scope, root, &store, .{ .group = 7 });
    const card = find(root, store.records.items[0].testId()).?;
    for (0..4) |_| {
        cx.frame_time_ms += 100;
        cx.layout();
        _ = cx.render();
    }
    try std.testing.expectEqual(@as(f32, 32), card.globalRect().h);
    try std.testing.expect(!store.records.items[0].expanded);
    find(card, "ai.tool.result.disclosure").?.parent.?.behavior.events.on_click.?.invoke();
    for (0..4) |_| {
        cx.frame_time_ms += 100;
        cx.layout();
        _ = cx.render();
    }
    try std.testing.expectEqual(@as(f32, 216), card.globalRect().h);
    const card_rect = card.globalRect();
    try std.testing.expectApproxEqAbs(@as(f32, 572), card_rect.w, 0.1);
    const title_rect = find(root, "ai.tool.result.title").?.globalRect();
    const summary_rect = find(root, "ai.tool.result.status").?.globalRect();
    const elapsed_rect = find(root, "ai.tool.result.elapsed").?.globalRect();
    try std.testing.expectApproxEqAbs(@as(f32, 38), title_rect.x - card_rect.x, 0.1);
    try std.testing.expectApproxEqAbs(@as(f32, 84), title_rect.w, 0.1);
    try std.testing.expectApproxEqAbs(@as(f32, 128), summary_rect.x - card_rect.x, 0.1);
    try std.testing.expectApproxEqAbs(@as(f32, 44), elapsed_rect.w, 0.1);
    try std.testing.expectApproxEqAbs(@as(f32, 12), card_rect.x + card_rect.w - elapsed_rect.x - elapsed_rect.w, 0.1);
    const target_button = find(root, "ai.tool.result.target.101").?;
    const target_row = target_button.children.items[target_button.children.items.len - 1];
    try std.testing.expectApproxEqAbs(target_button.globalRect().x, target_row.globalRect().x, 0.1);
    try std.testing.expectApproxEqAbs(@as(f32, 22), target_row.children.items[1].globalRect().x - target_row.globalRect().x, 0.1);
    try std.testing.expectApproxEqAbs(@as(f32, 186), target_row.children.items[1].globalRect().w, 0.1);
    try std.testing.expectApproxEqAbs(@as(f32, 226), target_row.children.items[3].globalRect().x - target_row.globalRect().x, 0.1);

    try std.testing.expectEqual(@as(f32, 150), find(root, "ai.tool.result.details").?.globalRect().h);
    try std.testing.expectEqual(@as(f32, 24), find(root, "ai.tool.result.stdout_scroll").?.globalRect().h);
    try std.testing.expectEqualStrings("Error is ordinary stdout with exit zero", find(root, "ai.tool.result.stdout").?.getText().?.content);
    const state = try View.State.mount(cx, scope, store.records.items[0]);
    // Attach before assertions so any failure still destroys the complete native tree.
    try root.appendChild(a, state.root);
    const disclosure = find(state.root, "ai.tool.result.disclosure").?;
    try std.testing.expectEqual(@as(f32, 1), state.status_icon.?.getOpacity());
    try std.testing.expectEqual(@as(f32, 0), state.disclosure_icon.?.getOpacity());
    disclosure.parent.?.behavior.events.on_hover.?.invoke();
    cx.layout();
    try std.testing.expectEqual(@as(f32, 0), state.status_icon.?.getOpacity());
    try std.testing.expectEqual(@as(f32, 1), state.disclosure_icon.?.getOpacity());
    disclosure.parent.?.behavior.events.on_leave.?.invoke();
    cx.layout();
    try std.testing.expectEqual(@as(f32, 1), state.status_icon.?.getOpacity());
    try std.testing.expectEqual(@as(f32, 0), state.disclosure_icon.?.getOpacity());

    try state.select(1);
    try std.testing.expectEqualStrings("actual partial output", state.stdout.getText().?.content);
    try std.testing.expectEqualStrings("actual stderr retained", state.stderr.getText().?.content);
    try std.testing.expectEqualStrings("目录 未知", state.identity.getText().?.content);
    try std.testing.expect(std.mem.indexOf(u8, state.metadata.getText().?.content, "本地句柄") == null);
    try std.testing.expectEqualStrings("远端执行结果待核实", state.feedback.getText().?.content);
    try std.testing.expect(std.mem.startsWith(u8, state.metadata.getText().?.content, "未获退出码"));
}

test "tool result view formatting preserves raw inputs and handles incomplete JSON and binary output" {
    const F = @import("ui/formatted_output.zig");
    const raw = "{\"items\":[{\"ok\":true,\"n\":2}],\"empty\":null}";
    const pretty = try F.format(a, raw);
    defer a.free(pretty);
    try std.testing.expect(std.mem.indexOf(u8, pretty, "\n  \"items\": [\n") != null);
    try std.testing.expectEqualStrings("{\"items\":[{\"ok\":true,\"n\":2}],\"empty\":null}", raw);
    const incomplete = "{\"items\":[1,";
    const partial = try F.format(a, incomplete);
    defer a.free(partial);
    try std.testing.expectEqualStrings(incomplete, partial);
    const binary = try F.format(a, &.{ 0xff, 0x00 });
    defer a.free(binary);
    try std.testing.expectEqualStrings("base64: /wA=", binary);
}

test "tool result view generic image and structured receipts never invent terminal metadata" {
    const tools = @import("ai/plugin_tools.zig");
    const Image = @import("ai/image_attachments.zig");
    const png = "\x89PNG\r\n\x1a\n\x00\x00\x00\x0dIHDR" ++
        "\x00\x00\x00\x01\x00\x00\x00\x01\x08\x06\x00\x00\x00\x1f\x15\xc4\x89" ++
        "\x00\x00\x00\x0dIDAT\x78\x9c\x63\xf8\xcf\xc0\xf0\x1f\x00\x05\x00\x01\xff\x89\x99\x3d\x1d" ++
        "\x00\x00\x00\x00IEND\xae\x42\x60\x82";
    var store = facts.Store.init(a);
    defer store.deinit();
    var run = loop.Loop.init(a, .{ .owner = .{ .session = 101 }, .members = .{} }, 8, .{});
    const blocks = try a.alloc(tools.ContentBlock, 2);
    blocks[0] = .{ .structured = try a.dupe(u8, "{\"pointer\":\"moved\"}") };
    blocks[1] = .{ .image_ref = try Image.ContentRef.create(a, "fixture-image", png, 0, .{}) };
    const results = try a.alloc(tools.ToolResult, 1);
    results[0] = .{ .status = .succeeded, .blocks = blocks, .receipt = .{ .owner = .{ .session_id = @fromBackingInt(101), .generation = 4 }, .operation_id = 42 } };
    try run.records.append(run.arena.allocator(), .{ .key = .{ .owner = .{ .session = 101 }, .turn_id = 8, .call_id = "generic-image" }, .name = "fixture_uprobe__observe", .arguments = "{\"session_ids\":[101],\"path\":\"synthetic\"}", .arguments_hash = @splat(1), .dispatched = true, .generic_results = results });
    _ = try store.capture(&run, &.{});
    run.deinit();
    try std.testing.expectEqual(@as(?u64, 42), store.records.items[0].targets[0].operation_id);
    try std.testing.expectEqual(@as(usize, 1), store.records.items[0].images.len);
    try std.testing.expectEqualStrings(store.records.items[0].arguments, store.records.items[0].command);
    const cx = try ui.Cx.init(a, std.testing.io);
    defer cx.deinit();
    const scope = try ui.Scope.init(a, null, cx.owner);
    defer scope.dispose();
    cx.root = try ui.box(cx, .{ .width = .{ .px = 572 }, .height = .fill(), .direction = .column }, .{});
    store.records.items[0].expanded = true;
    try View.appendForOwner(cx, scope, cx.root.?, &store, .{ .session = 101 });
    try std.testing.expectEqualStrings("工具调用", find(cx.root.?, "ai.tool.result.title").?.getText().?.content);
    const identity = find(cx.root.?, "ai.tool.result.identity").?;
    try std.testing.expectEqual(.none, identity.style.display);
    try std.testing.expectEqualStrings("", identity.getText().?.content);
    try std.testing.expectEqualStrings("操作 #42 · 本地资源已释放", find(cx.root.?, "ai.tool.result.metadata").?.getText().?.content);
    try std.testing.expectEqualStrings("结果内容", find(cx.root.?, "ai.tool.result.output_label").?.getText().?.content);
    try std.testing.expect(std.mem.indexOf(u8, find(cx.root.?, "ai.tool.result.stdout").?.getText().?.content, "moved") != null);
    try std.testing.expectEqualStrings("已完成", find(cx.root.?, "ai.tool.result.feedback").?.getText().?.content);
    try std.testing.expect(find(cx.root.?, "ai.tool.result.image") != null);
    try std.testing.expectEqual(.none, find(cx.root.?, "ai.tool.result.copy_stderr").?.style.display);
    store.records.items[0].targets[0].result.cwd = "/srv/actual";
    store.records.items[0].targets[0].result.exit = 0;
    const actual = try View.State.mount(cx, scope, store.records.items[0]);
    try cx.root.?.appendChild(a, actual.root);
    try std.testing.expectEqual(.flex, actual.identity.style.display);
    try std.testing.expectEqualStrings("目录 /srv/actual", actual.identity.getText().?.content);
    try std.testing.expect(std.mem.startsWith(u8, actual.metadata.getText().?.content, "退出码 0"));
}

test "tool result view companion Markdown preserves code blank lines without changing paragraph gaps" {
    const input = "before\n\n```sh\necho a\n\necho b\n```\n\nafter";
    const displayed = try @import("ui/ai_message_view.zig").preserveCodeLines(a, input);
    defer a.free(displayed);
    try std.testing.expectEqualStrings("before\n\n```sh\necho a\n \necho b\n```\n\nafter", displayed);
}

test "tool result view fits short and empty results and scrolls long output in one vertical viewport" {
    var store = facts.Store.init(a);
    defer store.deinit();
    var run = loop.Loop.init(a, .{ .owner = .{ .session = 101 }, .members = .{} }, 4, .{});
    defer run.deinit();
    const long_output = try std.mem.join(a, "\n", &@as([30][]const u8, @splat("long output line")));
    defer a.free(long_output);
    const outcome = try loop.Outcome.copy(a, &.{
        .{ .session_id = 101, .status = .succeeded, .stdout = "ok" },
        .{ .session_id = 102, .status = .succeeded, .stdout = long_output },
        .{ .session_id = 103, .status = .succeeded },
    });
    try run.records.append(run.arena.allocator(), .{ .key = .{ .owner = .{ .session = 101 }, .turn_id = 4, .call_id = "sizing" }, .name = "read_remote_file", .arguments = "{}", .arguments_hash = @splat(0), .dispatched = true, .outcome = outcome });
    _ = try store.capture(&run, &.{});
    const cx = try ui.Cx.init(a, std.testing.io);
    defer cx.deinit();
    cx.setViewport(600, 500);
    const scope = try ui.Scope.init(a, null, cx.owner);
    defer scope.dispose();
    cx.root = try ui.box(cx, .{ .width = .{ .px = 572 }, .height = .fill(), .direction = .column }, .{});
    const record = store.records.items[0];
    record.expanded = true;
    const state = try View.State.mount(cx, scope, record);
    try cx.root.?.appendChild(a, state.root);
    cx.layout();
    // A single selected target is displayed; target selectors still consume real space.
    try std.testing.expect(state.root.globalRect().h <= 216);
    try state.select(1);
    cx.layout();
    try std.testing.expectApproxEqAbs(@as(f32, 216), state.root.globalRect().h, 0.1);
    try std.testing.expect(state.stdout_viewport.?.globalRect().h > state.body.globalRect().h);
    try std.testing.expect(state.stdout.globalRect().h >= 30 * 16);
    try std.testing.expectApproxEqAbs(@as(f32, 0), state.stdout_scroll.content_height - state.stdout_scroll.viewport_height, 0.1);
    try state.select(2);
    cx.layout();
    try std.testing.expectEqual(.none, state.stdout_viewport.?.style.display);
    try std.testing.expectEqual(.none, state.copy_stdout_button.?.style.display);
    try std.testing.expectEqual(.none, state.copy_stderr_button.?.style.display);
    // Hide the extra target selectors to check the common single-target layout too.
    find(state.root, "ai.tool.result.target.102").?.setDisplay(.none);
    find(state.root, "ai.tool.result.target.103").?.setDisplay(.none);
    cx.layout();
    const empty_height = state.root.globalRect().h;
    try std.testing.expect(empty_height < 216);
    try state.select(0);
    cx.layout();
    try std.testing.expect(state.root.globalRect().h > empty_height);
    try std.testing.expect(state.root.globalRect().h < 216);
    find(state.root, "ai.tool.result.disclosure").?.parent.?.behavior.events.on_click.?.invoke();
    for (0..4) |_| {
        cx.frame_time_ms += 100;
        cx.layout();
        _ = cx.render();
    }
    try std.testing.expectApproxEqAbs(@as(f32, 32), state.root.globalRect().h, 0.1);
}

test "tool result headers preserve status title projection and elapsed across themes and sizes" {
    const theme = @import("ui/app_theme.zig");
    const previous = theme.currentName();
    defer theme.select(previous);
    inline for (.{ .dark, .light, .sauber }) |name| {
        theme.select(name);
        for ([_]f32{ 572, 332 }) |width| {
            inline for (.{ .succeeded, .failed, .rejected, .cancelled, .timed_out, .unknown }) |status| {
                var target = [_]facts.Target{.{ .result = .{ .session_id = 101, .status = status, .stdout = "first line\nlast output line", .cwd = "/srv/long/target/directory" }, .label = "original@long-production-target.example.net:2222" }};
                var record: facts.Record = .{ .arena = .init(a), .owner = .{ .session = 101 }, .turn_id = 1, .call_id = "header-status", .name = "host.run_in_terminal", .arguments = "{}", .command = "printf a-long-command-with-full-parameters", .arguments_hash = @splat(0), .targets = &target, .dispatched = true, .expanded = true };
                defer record.deinit();
                const cx = try ui.Cx.init(a, std.testing.io);
                defer cx.deinit();
                cx.setTheme(theme.widgetTheme(name));
                cx.setViewport(width, 480);
                const scope = try ui.Scope.init(a, null, cx.owner);
                defer scope.dispose();
                cx.root = try ui.box(cx, .{ .width = .{ .px = width }, .height = .fill(), .direction = .column }, .{});
                const state = try View.State.mount(cx, scope, &record);
                try cx.root.?.appendChild(a, state.root);
                for (0..4) |_| {
                    cx.layout();
                    _ = cx.render();
                }
                const title = find(state.root, "ai.tool.result.title").?.globalRect();
                const icon = find(state.root, "ai.tool.result.icon").?.globalRect();
                const projection = find(state.root, "ai.tool.result.status").?.globalRect();
                const elapsed = find(state.root, "ai.tool.result.elapsed").?.globalRect();
                try std.testing.expectEqualStrings("执行命令", find(state.root, "ai.tool.result.title").?.getText().?.content);
                try std.testing.expect(icon.x + icon.w <= title.x);
                try std.testing.expect(@abs(icon.y + icon.h / 2 - title.y - title.h / 2) < 1);
                try std.testing.expect(projection.w > 0 and projection.x >= title.x + title.w);
                try std.testing.expect(elapsed.x >= projection.x + projection.w and elapsed.x + elapsed.w <= width);
                try std.testing.expect(state.body.globalRect().h <= 150);
                try std.testing.expect(state.footer.globalRect().y >= state.body.globalRect().y + state.body.globalRect().h);
                if (status == .unknown) try std.testing.expectEqual(ui.icons.get("circle-help").?.icon_id.?, state.status_icon.?.getIcon().?.icon_id);
                if (status == .succeeded) try std.testing.expectEqual(ui.icons.check.icon_id.?, state.status_icon.?.getIcon().?.icon_id);
            }
        }
    }
}

test "tool result unknown cleanup takes precedence over a successful process icon" {
    var target = [_]facts.Target{.{ .result = .{ .session_id = 101, .status = .succeeded, .local_released = false } }};
    var record: facts.Record = .{ .arena = .init(a), .owner = .{ .session = 101 }, .turn_id = 1, .call_id = "cleanup-unknown", .name = "run_command", .arguments = "{}", .command = "true", .arguments_hash = @splat(0), .targets = &target, .dispatched = true };
    defer record.deinit();
    const cx = try ui.Cx.init(a, std.testing.io);
    defer cx.deinit();
    const scope = try ui.Scope.init(a, null, cx.owner);
    defer scope.dispose();
    const state = try View.State.mount(cx, scope, &record);
    cx.root = state.root;
    try std.testing.expectEqual(ui.icons.get("circle-help").?.icon_id.?, state.status_icon.?.getIcon().?.icon_id);
    try std.testing.expectEqualStrings("清理待核实", state.feedback.getText().?.content);
}

test "tool step phases keep icon and title on one header line at narrow width" {
    const Step = @import("ui/ai_step_view.zig");
    const theme = @import("ui/app_theme.zig");
    const previous = theme.currentName();
    defer theme.select(previous);
    inline for (.{ .dark, .light, .sauber }) |name| {
        theme.select(name);
        inline for (.{ .assembling, .running, .approval, .approved, .rejected, .succeeded, .failed, .cancelled }) |phase| {
            const cx = try ui.Cx.init(a, std.testing.io);
            defer cx.deinit();
            cx.setTheme(theme.widgetTheme(name));
            cx.setViewport(332, 480);
            const scope = try ui.Scope.init(a, null, cx.owner);
            defer scope.dispose();
            var expanded = false;
            cx.root = try Step.mount(cx, scope, .{ .title = "创建会话组", .projection = "生产环境 · long-target.example.net", .detail = "完整执行详情", .phase = phase, .elapsed_ms = 42, .expanded = &expanded });
            cx.root.?.setStyleInline(a, .{ .width = .{ .px = 332 } });
            for (0..4) |_| {
                cx.layout();
                _ = cx.render();
            }
            const title = find(cx.root.?, "ai.step.title").?.globalRect();
            const icon = (find(cx.root.?, "ai.step.status") orelse find(cx.root.?, "ai.step.spinner")).?.globalRect();
            const projection = find(cx.root.?, "ai.step.projection").?.globalRect();
            try std.testing.expect(icon.x + icon.w <= title.x);
            try std.testing.expect(@abs(icon.y + icon.h / 2 - title.y - title.h / 2) < 1);
            try std.testing.expect(projection.w > 0 and projection.x >= title.x + title.w);
            try std.testing.expectEqual(@as(f32, 32), cx.root.?.globalRect().h);
        }
    }
}

test "tool titles cover all registered host discovery lifecycle and execution actions" {
    const titles = @import("ui/ai_tool_titles.zig");
    for (@import("ai/host_queries.zig").contributions) |item| try std.testing.expect(titles.title(item.definition.id) != null);
    for (@import("ai/host_lifecycle.zig").contributions) |item| try std.testing.expect(titles.title(item.definition.id) != null);
    for (@import("ai/host_execution.zig").contributions) |item| try std.testing.expect(titles.title(item.definition.id) != null);
    try std.testing.expectEqualStrings("新建会话", titles.title("host.open_session").?);
    try std.testing.expectEqualStrings("停止执行", titles.title("host.stop_execution").?);
}

test "tool result multiline command remains reachable in the bounded details viewport" {
    var record: facts.Record = .{ .arena = .init(a), .owner = .{ .session = 101 }, .turn_id = 1, .call_id = "multiline-command", .name = "run_command", .arguments = "{}", .command = "printf first-line\nprintf second-line\nprintf final-line", .arguments_hash = @splat(0), .targets = &.{}, .dispatched = false, .expanded = true };
    defer record.deinit();
    const cx = try ui.Cx.init(a, std.testing.io);
    defer cx.deinit();
    const scope = try ui.Scope.init(a, null, cx.owner);
    defer scope.dispose();
    const state = try View.State.mount(cx, scope, &record);
    cx.root = state.root;
    state.root.setStyleInline(a, .{ .width = .{ .px = 332 } });
    for (0..4) |_| {
        cx.layout();
        _ = cx.render();
    }
    const command = find(state.root, "ai.tool.result.command").?;
    try std.testing.expectEqualStrings(record.command, command.getText().?.content);
    try std.testing.expect(command.globalRect().h >= 48);
    try std.testing.expect(command.parent.?.parent.?.globalRect().h >= command.globalRect().h);
    try std.testing.expect(state.body.globalRect().h <= 150);
    try std.testing.expect(state.footer.globalRect().y >= state.body.globalRect().y + state.body.globalRect().h);
}

test "tool result undispatched cancellation rejection and unknown never show success or generic execution feedback" {
    inline for (.{ .rejected, .cancelled, .unknown }) |status| {
        var record: facts.Record = .{ .arena = .init(a), .owner = .{ .session = 101 }, .turn_id = 1, .call_id = "no-dispatch", .name = "host.open_session", .arguments = "{}", .command = "request arguments", .arguments_hash = @splat(0), .targets = &.{}, .dispatched = false, .error_status = status };
        defer record.deinit();
        const cx = try ui.Cx.init(a, std.testing.io);
        defer cx.deinit();
        const scope = try ui.Scope.init(a, null, cx.owner);
        defer scope.dispose();
        const state = try View.State.mount(cx, scope, &record);
        cx.root = state.root;
        const label = switch (@as(loop.Status, status)) {
            .rejected => "已拒绝",
            .cancelled => "已取消",
            .unknown => "结果待核实",
            else => unreachable,
        };
        try std.testing.expectEqualStrings(label, state.feedback.getText().?.content);
        const icon = switch (@as(loop.Status, status)) {
            .rejected => ui.icons.get("circle-alert").?,
            .cancelled => ui.icons.get("square").?,
            .unknown => ui.icons.get("circle-help").?,
            else => unreachable,
        };
        try std.testing.expectEqual(icon.icon_id.?, state.status_icon.?.getIcon().?.icon_id);
    }
}

test "host notice keeps source icon and title together while long takeover text wraps across themes" {
    const Notice = @import("ui/ai_host_notice_view.zig");
    const theme = @import("ui/app_theme.zig");
    const previous = theme.currentName();
    defer theme.select(previous);
    inline for (.{ .dark, .light, .sauber }) |name| {
        theme.select(name);
        for ([_]f32{ 572, 332 }) |width| {
            const cx = try ui.Cx.init(a, std.testing.io);
            defer cx.deinit();
            cx.setTheme(theme.widgetTheme(name));
            cx.setViewport(width, 480);
            const scope = try ui.Scope.init(a, null, cx.owner);
            defer scope.dispose();
            cx.root = try ui.box(cx, .{ .width = .{ .px = width }, .height = .fill(), .direction = .column }, .{});
            const text = "已接管 original@production-long-target.example.net:2222 · " ++ Notice.takeover_text;
            const root = try Notice.mount(cx, cx.root.?, text);
            for (0..4) |_| {
                cx.layout();
                _ = cx.render();
            }
            const title = find(root, "ai.host_notice.title").?.globalRect();
            const icon = find(root, "ai.host_notice.icon").?.globalRect();
            const body = find(root, "ai.host_notice.body").?;
            try std.testing.expectEqual(@as(f32, 16), icon.w);
            try std.testing.expect(@abs(icon.y + icon.h / 2 - title.y - title.h / 2) < 0.1);
            try std.testing.expect(icon.x + icon.w < title.x);
            try std.testing.expectEqualStrings(text, body.getText().?.content);
            try std.testing.expect(body.globalRect().h > 18);
            try std.testing.expect(body.globalRect().x >= title.x);
            try std.testing.expect(body.globalRect().x + body.globalRect().w <= width + 0.1);
            try std.testing.expect(body.globalRect().y + body.globalRect().h <= root.globalRect().y + root.globalRect().h);
            try std.testing.expectEqual(@as(u8, 0), root.getBackground().a);
            try std.testing.expectEqual(@as(f32, 0), root.style.border.width);
        }
    }
}

const ExecutionRecorder = struct {
    calls: usize = 0,
    action: ?@import("ui/ai_execution_result_view.zig").Action = null,
    target: ?facts.ExecutionActionTarget = null,
    fn perform(raw: *anyopaque, action: @import("ui/ai_execution_result_view.zig").Action, target: facts.ExecutionActionTarget) !void {
        const self: *ExecutionRecorder = @ptrCast(@alignCast(raw));
        self.calls += 1;
        self.action = action;
        self.target = target;
    }
};
fn executionFixture(state: @import("host/terminal_execution.zig").State, output: []const u8) facts.Record {
    const identity = @import("host/identity.zig");
    return .{ .arena = .init(a), .owner = .{ .group = 7 }, .turn_id = 1, .call_id = "execution-card", .name = "host.run_in_terminal", .arguments = "{}", .command = "{}", .arguments_hash = @splat(0), .targets = &.{}, .dispatched = true, .expanded = true, .execution = .{ .conversation_id = .generate(), .task_id = .generate(), .call_status = .succeeded, .execution_id = .generate(), .target = .{ .session_id = @fromBackingInt(101), .generation = 9 }, .target_label = "original@long-production-target.example.net:2222", .command = "printf ACTUAL_EXECUTION_COMMAND", .state = state, .recording_id = identity.RecordingId.generate(), .terminal_output = output, .output_available = true, .has_input_grant = state == .running, .elapsed_ms = 1234 } };
}
fn labelNode(node: *ui.Node, label: []const u8) ?*ui.Node {
    if (node.getText()) |text| if (std.mem.eql(u8, text.content, label)) return node;
    for (node.children.items) |child| if (labelNode(child, label)) |found| return found;
    return null;
}

fn appendInputProjectionFixture(run: *loop.Loop, receipt: @import("ai/host_tools.zig").Receipt, call_id: []const u8, name: []const u8, arguments: []const u8, content: []const u8, status: @import("ai/plugin_tools.zig").Status) !void {
    const blocks = try run.allocator.alloc(@import("ai/host_tools.zig").Block, 1);
    blocks[0] = .{ .structured = try run.allocator.dupe(u8, content) };
    try run.records.append(run.arena.allocator(), .{ .key = .{ .owner = .{ .group = 7 }, .turn_id = 42, .call_id = call_id }, .name = name, .arguments = arguments, .arguments_hash = @splat(1), .dispatched = true, .host_result = .{ .status = status, .blocks = blocks, .receipt = receipt } });
}
fn expectNoInputSecret(node: *ui.Node) !void {
    if (node.getText()) |text| try std.testing.expect(std.mem.indexOf(u8, text.content, "PRIVATE_INPUT_SENTINEL") == null);
    for (node.children.items) |child| try expectNoInputSecret(child);
}

test "execution input Store to view keeps saved execution facts after later receipt without rewriting immutable calls" {
    const terminal = @import("host/terminal_execution.zig");
    const identity = @import("host/identity.zig");
    const receipt: @import("ai/host_tools.zig").Receipt = .{ .conversation_id = .generate(), .task_id = .generate(), .operation_id = 1, .binding_revision = 1 };
    const execution_id: identity.ExecutionId = .generate();
    const recording_id: identity.RecordingId = .generate();
    const target: identity.SessionHandle = .{ .session_id = @fromBackingInt(101), .generation = 9 };
    const reference = try std.fmt.allocPrint(a, "x1:{s}", .{std.fmt.bytesToHex(execution_id.bytes, .lower)});
    defer a.free(reference);
    var snapshot: terminal.Snapshot = .{ .owner = target, .execution_id = execution_id, .state = .running, .recording_id = std.fmt.bytesToHex(recording_id.bytes, .lower), .output_scope = .session_interval };
    const initial = try std.json.Stringify.valueAlloc(a, .{ .execution_ref = reference, .snapshot = snapshot, .output = "INITIAL_OUTPUT", .output_available = true }, .{});
    defer a.free(initial);
    snapshot.state = .interval_recorded;
    snapshot.process = .{ .exit_code = 0, .foreground_finished = true, .background_jobs_unknown = true };
    snapshot.recording_settled = true;
    snapshot.interval_saved = true;
    snapshot.output_attribution_reason = "OutputProcessIdentityUnknown";
    const complete = try std.json.Stringify.valueAlloc(a, .{ .execution_ref = reference, .snapshot = snapshot, .output = "RECORDED_EXECUTION_END\n", .output_available = true }, .{});
    defer a.free(complete);
    const input = try std.json.Stringify.valueAlloc(a, .{ .execution_ref = reference, .input_receipt = terminal.InputReceipt{ .input_sequence = 5, .wait_sequence = 3, .kind = .host_secret, .stage = .consumed }, .host_secret_status = "secret_submitted" }, .{});
    defer a.free(input);
    const theme = @import("ui/app_theme.zig");
    const previous = theme.currentName();
    defer theme.select(previous);
    inline for (.{ .dark, .light, .sauber }) |name| {
        theme.select(name);
        for ([_]f32{ 572, 332 }) |width| {
            var store = facts.Store.init(a);
            defer store.deinit();
            var run = loop.Loop.init(a, .{ .owner = .{ .group = 7 }, .members = .{} }, 42, .{});
            try appendInputProjectionFixture(&run, receipt, "input-original-run", "host.run_in_terminal", "{\"command\":\"printf original-command\"}", initial, .succeeded);
            try appendInputProjectionFixture(&run, receipt, "input-finished", "host.get_execution", "{}", complete, .succeeded);
            try appendInputProjectionFixture(&run, receipt, "input-same-key", "host__send_uexecution_uinput", "{\"text\":\"PRIVATE_INPUT_SENTINEL\"}", input, .succeeded);
            _ = try store.capture(&run, &.{.{ .owner = target, .label = "本机 · zsh" }});
            run.deinit();
            // A later receipt for a different task/execution must remain separate.
            var alien = receipt;
            alien.task_id = .generate();
            var later = loop.Loop.init(a, .{ .owner = .{ .group = 7 }, .members = .{} }, 42, .{});
            try appendInputProjectionFixture(&later, alien, "input-other-task", "host.get_execution", "{}", initial, .succeeded);
            _ = try store.capture(&later, &.{});
            later.deinit();
            store.records.items[2].expanded = true;
            const cx = try ui.Cx.init(a, std.testing.io);
            defer cx.deinit();
            cx.setTheme(theme.widgetTheme(name));
            cx.reduced_motion = true;
            cx.setViewport(width, 800);
            const scope = try ui.Scope.init(a, null, cx.owner);
            defer scope.dispose();
            cx.root = try ui.box(cx, .{ .width = .{ .px = width }, .height = .fill(), .direction = .column }, .{});
            try View.appendForOwner(cx, scope, cx.root.?, &store, .{ .group = 7 });
            settleCard(cx);
            const original = find(cx.root.?, store.records.items[0].testId()).?;
            try std.testing.expectEqualStrings("最近观测 · 前台已结束 · 观测片段已保存", find(original, "ai.execution.result.summary").?.getText().?.content);
            try std.testing.expectEqualStrings("前台已结束 · 退出码 0 · 后台任务仍需核实", find(original, "ai.execution.result.process").?.getText().?.content);
            try std.testing.expectEqualStrings("RECORDED_EXECUTION_END\n", find(original, "ai.execution.result.terminal_output").?.getText().?.content);
            try std.testing.expectEqualStrings("同一终端观测片段 · 已保存", find(original, "ai.execution.result.output_scope").?.getText().?.content);
            try std.testing.expectEqualStrings("printf original-command", find(original, "ai.execution.result.command").?.getText().?.content);
            try std.testing.expectEqualStrings(initial, store.records.items[0].host.?.content);
            try std.testing.expectEqualStrings(complete, store.records.items[1].host.?.content);
            try std.testing.expectEqualStrings("INITIAL_OUTPUT", store.records.items[0].execution.?.terminal_output);
            const input_card = find(cx.root.?, store.records.items[2].testId()).?;
            try std.testing.expectEqualStrings("输入结果 · 输入已消费", find(input_card, "ai.execution.result.summary").?.getText().?.content);
            try std.testing.expectEqualStrings("输入类型 · 宿主安全输入", find(input_card, "ai.execution.result.input_type").?.getText().?.content);
            try std.testing.expectEqualStrings("输入序号 5 · 等待序号 3", find(input_card, "ai.execution.result.input_sequence").?.getText().?.content);
            inline for (.{ "process", "terminal_output", "output_label", "copy_output", "copy_command", "stop", "takeover", "view_terminal" }) |suffix| try std.testing.expect(find(input_card, "ai.execution.result." ++ suffix) == null);
            const title = find(input_card, "ai.execution.result.title").?.globalRect();
            const icon = find(input_card, "ai.execution.result.icon").?.globalRect();
            try std.testing.expect(@abs(icon.y + icon.h / 2 - title.y - title.h / 2) < 0.1 and icon.x + icon.w < title.x);
            try std.testing.expectEqual(@as(f32, 0), input_card.style.border.width);
            try std.testing.expectEqual(@as(u8, 255), find(input_card, "ai.execution.result.summary").?.getText().?.color.a);
            try expectNoInputSecret(cx.root.?);
            var clone = try store.cloneTurns(&.{.{ .user = false, .text = @constCast(""), .turn = .{ .id = 42 } }});
            defer clone.deinit();
            try std.testing.expect(clone.executionProjection(clone.records.items[0]).?.intervalRecorded());
            try std.testing.expectEqualStrings("输入已消费", clone.executionProjection(clone.records.items[2]).?.statusLabel());
        }
    }
}

test "execution input Store to view preserves queued pending cancelled failed and unknown outcomes" {
    const terminal = @import("host/terminal_execution.zig");
    const Stage = @FieldType(terminal.InputReceipt, "stage");
    const Status = @import("ai/plugin_tools.zig").Status;
    for ([_]struct { stage: ?Stage, status: Status = .succeeded, label: []const u8, failure: bool = false }{
        .{ .stage = .queued, .label = "输入结果 · 输入已排队" },
        .{ .stage = .awaiting_host_secret, .label = "输入结果 · 等待宿主安全输入" },
        .{ .stage = .cancelled_unsent, .label = "输入结果 · 输入未提交 · 已取消" },
        .{ .stage = .outcome_unknown, .label = "输入结果 · 输入结果待核实", .failure = true },
        .{ .stage = .consumed, .status = .outcome_unknown, .label = "输入结果 · 输入结果待核实", .failure = true },
        .{ .stage = null, .status = .failed, .label = "输入结果 · 输入提交失败", .failure = true },
    }) |case| {
        var store = facts.Store.init(a);
        defer store.deinit();
        const input = try std.json.Stringify.valueAlloc(a, .{ .execution_ref = "x1:0123456789abcdef0123456789abcdef", .input_receipt = if (case.stage) |stage| terminal.InputReceipt{ .input_sequence = 5, .wait_sequence = 3, .kind = .host_secret, .stage = stage } else null, .error_code = if (case.failure) @as(?[]const u8, "InputAcknowledgementUnknown") else null, .text = "PRIVATE_INPUT_SENTINEL", .output = "PRIVATE_INPUT_SENTINEL" }, .{});
        defer a.free(input);
        const receipt: @import("ai/host_tools.zig").Receipt = .{ .conversation_id = .generate(), .task_id = .generate(), .operation_id = 1, .binding_revision = 1 };
        var run = loop.Loop.init(a, .{ .owner = .{ .group = 7 }, .members = .{} }, 42, .{});
        try appendInputProjectionFixture(&run, receipt, "input-outcome", "host.send_execution_input", "{\"text\":\"PRIVATE_INPUT_SENTINEL\"}", input, case.status);
        _ = try store.capture(&run, &.{});
        run.deinit();
        store.records.items[0].expanded = true;
        const cx = try ui.Cx.init(a, std.testing.io);
        defer cx.deinit();
        const scope = try ui.Scope.init(a, null, cx.owner);
        defer scope.dispose();
        cx.root = try @import("ui/ai_execution_result_view.zig").mount(cx, scope, &store, store.records.items[0], null, null);
        try std.testing.expectEqualStrings(case.label, find(cx.root.?, "ai.execution.result.summary").?.getText().?.content);
        try std.testing.expectEqual(case.failure, find(cx.root.?, "ai.execution.result.failure") != null);
        if (case.failure) try std.testing.expectEqualStrings("InputAcknowledgementUnknown", store.records.items[0].execution.?.failure.?);
        try std.testing.expect(find(cx.root.?, "ai.execution.result.output_label") == null);
        try expectNoInputSecret(cx.root.?);
    }
}

test "execution result native card preserves real target recording output and reachable actions across themes and sizes" {
    const Execution = @import("ui/ai_execution_result_view.zig");
    const theme = @import("ui/app_theme.zig");
    const previous = theme.currentName();
    defer theme.select(previous);
    const long_output = try std.mem.join(a, "\n", &@as([30][]const u8, @splat("ACTUAL_LONG_TERMINAL_OUTPUT with original spacing and a very long line for horizontal scrolling")));
    defer a.free(long_output);
    inline for (.{ .dark, .light, .sauber }) |name| {
        theme.select(name);
        for ([_]f32{ 572, 332 }) |width| {
            var record = executionFixture(.running, long_output);
            defer record.deinit();
            var store = facts.Store.init(a);
            defer store.records.deinit(a);
            try store.records.append(a, &record);
            var recorder: ExecutionRecorder = .{};
            const cx = try ui.Cx.init(a, std.testing.io);
            defer cx.deinit();
            cx.setTheme(theme.widgetTheme(name));
            cx.setViewport(width, 480);
            const scope = try ui.Scope.init(a, null, cx.owner);
            defer scope.dispose();
            cx.root = try ui.box(cx, .{ .width = .{ .px = width }, .height = .fill(), .direction = .column }, .{});
            const root = try Execution.mount(cx, scope, &store, &record, .{ .context = &recorder, .perform = ExecutionRecorder.perform }, null);
            try cx.root.?.appendChild(a, root);
            for (0..4) |_| {
                cx.layout();
                _ = cx.render();
            }
            const title = find(root, "ai.execution.result.title").?.globalRect();
            const icon = find(root, "ai.execution.result.icon").?.globalRect();
            const body = find(root, "ai.execution.result.details").?.globalRect();
            const footer = find(root, "ai.execution.result.footer").?.globalRect();
            try std.testing.expect(@abs(icon.y + icon.h / 2 - title.y - title.h / 2) < 0.1);
            try std.testing.expect(icon.x + icon.w < title.x);
            try std.testing.expectEqual(@as(f32, 150), body.h);
            try std.testing.expect(footer.y >= body.y + body.h and footer.y + footer.h <= 480);
            try std.testing.expectEqualStrings("最近观测 · 运行中", find(root, "ai.execution.result.summary").?.getText().?.content);
            try std.testing.expect(std.mem.indexOf(u8, find(root, "ai.execution.result.target").?.getText().?.content, record.execution.?.target_label) != null);
            try std.testing.expectEqualStrings(long_output, find(root, "ai.execution.result.terminal_output").?.getText().?.content);
            try std.testing.expect(find(root, "ai.execution.result.process") == null);
            inline for (.{ .{ "ai.execution.result.view_terminal", "查看终端" }, .{ "ai.execution.result.stop", "停止执行" }, .{ "ai.execution.result.takeover", "接管输入" } }) |action| {
                const button = find(root, action[0]).?;
                const rect = button.globalRect();
                const label = labelNode(button, action[1]).?.globalRect();
                try std.testing.expect(rect.x >= footer.x and rect.x + rect.w <= footer.x + footer.w + 0.1);
                try std.testing.expect(label.x >= rect.x and label.x + label.w <= rect.x + rect.w + 0.1);
            }
            const recording_before = find(root, "ai.execution.result.recording_id").?.globalRect();
            cx.handleScroll(.{ .x = body.x + body.w / 2, .y = body.y + body.h / 2, .dy = -100000, .dx = 0 });
            cx.layout();
            const recording = find(root, "ai.execution.result.recording_id").?.globalRect();
            try std.testing.expect(recording.y < recording_before.y);
            try std.testing.expect(recording.y >= body.y and recording.y + recording.h <= body.y + body.h + 0.1);
            try std.testing.expectEqual(footer, find(root, "ai.execution.result.footer").?.globalRect());
            find(root, "ai.execution.result.view_terminal").?.behavior.events.on_click.?.invoke();
            try std.testing.expectEqual(@as(usize, 1), recorder.calls);
            try std.testing.expect(recorder.target.?.session.eql(record.execution.?.target.?));
            try std.testing.expect(recorder.target.?.execution_id.eql(record.execution.?.execution_id.?));
            try std.testing.expect(recorder.target.?.conversation_id.eql(record.execution.?.conversation_id));
            try std.testing.expect(recorder.target.?.task_id.eql(record.execution.?.task_id));
        }
    }
}

test "execution result queued controls recheck same execution latest receipt and never stop a completed or handed off command" {
    const Execution = @import("ui/ai_execution_result_view.zig");
    var record = executionFixture(.running, "partial output");
    defer record.deinit();
    var store = facts.Store.init(a);
    defer store.records.deinit(a);
    try store.records.append(a, &record);
    var recorder: ExecutionRecorder = .{};
    const cx = try ui.Cx.init(a, std.testing.io);
    defer cx.deinit();
    const scope = try ui.Scope.init(a, null, cx.owner);
    defer scope.dispose();
    cx.root = try Execution.mount(cx, scope, &store, &record, .{ .context = &recorder, .perform = ExecutionRecorder.perform }, null);
    const old_stop = find(cx.root.?, "ai.execution.result.stop").?;
    const old_takeover = find(cx.root.?, "ai.execution.result.takeover").?;
    var latest = record;
    latest.execution.?.input_handed_off = true;
    latest.execution.?.has_input_grant = false;
    latest.execution.?.terminal_output = "continued after takeover";
    try store.records.append(a, &latest);
    old_stop.behavior.events.on_click.?.invoke();
    old_takeover.behavior.events.on_click.?.invoke();
    try std.testing.expectEqual(@as(usize, 0), recorder.calls);
    latest.execution.?.state = .sealed;
    latest.execution.?.process = .{ .exit_code = 3, .foreground_finished = true };
    latest.execution.?.recording_settled = true;
    old_stop.behavior.events.on_click.?.invoke();
    try std.testing.expectEqual(@as(usize, 0), recorder.calls);
    const completed = try Execution.mount(cx, scope, &store, &record, .{ .context = &recorder, .perform = ExecutionRecorder.perform }, null);
    try cx.root.?.appendChild(a, completed);
    try std.testing.expectEqualStrings("退出码 3", find(completed, "ai.execution.result.process").?.getText().?.content);
    try std.testing.expectEqualStrings("continued after takeover", find(completed, "ai.execution.result.terminal_output").?.getText().?.content);
    try std.testing.expect(find(completed, "ai.execution.result.stop") == null and find(completed, "ai.execution.result.takeover") == null);
}

test "execution result active stop and takeover callbacks receive original full authority without claiming success" {
    const Execution = @import("ui/ai_execution_result_view.zig");
    inline for (.{ .{ "ai.execution.result.stop", Execution.Action.stop }, .{ "ai.execution.result.takeover", Execution.Action.takeover } }) |action| {
        var record = executionFixture(.running, "actual output");
        defer record.deinit();
        var store = facts.Store.init(a);
        defer store.records.deinit(a);
        try store.records.append(a, &record);
        var recorder: ExecutionRecorder = .{};
        const cx = try ui.Cx.init(a, std.testing.io);
        defer cx.deinit();
        const scope = try ui.Scope.init(a, null, cx.owner);
        defer scope.dispose();
        cx.root = try Execution.mount(cx, scope, &store, &record, .{ .context = &recorder, .perform = ExecutionRecorder.perform }, null);
        find(cx.root.?, action[0]).?.behavior.events.on_click.?.invoke();
        try std.testing.expectEqual(@as(usize, 1), recorder.calls);
        try std.testing.expectEqual(action[1], recorder.action.?);
        try std.testing.expect(recorder.target.?.session.eql(record.execution.?.target.?));
        try std.testing.expect(recorder.target.?.execution_id.eql(record.execution.?.execution_id.?));
        try std.testing.expectEqual(.running, record.execution.?.state.?);
        try std.testing.expectEqual(.none, find(cx.root.?, "ai.execution.result.action_feedback").?.style.display);
        find(cx.root.?, action[0]).?.behavior.events.on_click.?.invoke();
        try std.testing.expectEqual(@as(usize, 1), recorder.calls);
    }
}

test "execution result preflight refusal shows user readable reason without raw host metadata or fabricated execution" {
    const Execution = @import("ui/ai_execution_result_view.zig");
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const receipt: @import("ai/host_tools.zig").Receipt = .{ .conversation_id = .generate(), .task_id = .generate(), .operation_id = 42, .binding_revision = 2 };
    var record = executionFixture(.running, "");
    defer record.deinit();
    record.execution = try facts.execution_projection.parse(arena.allocator(), "host.run_in_terminal", "{\"command\":\"not-sent\"}", .rejected, receipt, "{\"error_code\":\"IntegrationUnavailable\",\"side_effect_started\":false,\"local_released\":true,\"remote_effect_unknown\":false}");
    var store = facts.Store.init(a);
    defer store.records.deinit(a);
    try store.records.append(a, &record);
    const cx = try ui.Cx.init(a, std.testing.io);
    defer cx.deinit();
    cx.setViewport(332, 358);
    const scope = try ui.Scope.init(a, null, cx.owner);
    defer scope.dispose();
    cx.root = try Execution.mount(cx, scope, &store, &record, null, null);
    cx.root.?.setStyleInline(a, .{ .width = .{ .px = 332 } });
    for (0..4) |_| {
        cx.layout();
        _ = cx.render();
    }
    try std.testing.expectEqualStrings("最近观测 · 未执行 · 已拒绝", find(cx.root.?, "ai.execution.result.summary").?.getText().?.content);
    try std.testing.expectEqualStrings("当前终端的执行能力不可用。", find(cx.root.?, "ai.execution.result.failure").?.getText().?.content);
    try std.testing.expect(find(cx.root.?, "ai.execution.result.target").?.globalRect().w > 0);
    try std.testing.expect(find(cx.root.?, "ai.execution.result.execution_id") == null);
    try std.testing.expect(find(cx.root.?, "ai.execution.result.process") == null);
    try std.testing.expect(find(cx.root.?, "ai.execution.result.view_terminal") == null);
    try std.testing.expect(find(cx.root.?, "ai.execution.result.stop") == null);
    try std.testing.expect(find(cx.root.?, "ai.execution.result.takeover") == null);
}

test "execution interval native result separates saved observation foreground failure attribution and handed off running state" {
    const Execution = @import("ui/ai_execution_result_view.zig");
    const terminal = @import("host/terminal_execution.zig");
    const Case = struct { state: terminal.State = .interval_recorded, attribution: terminal.OutputAttribution, exit: ?u8 = 0, saved: bool = true, failed: bool = false, handed_off: bool = false };
    for ([_]Case{
        .{ .attribution = .unverified },
        .{ .attribution = .no_concurrent_owner_observed },
        .{ .attribution = .concurrent_observed },
        .{ .attribution = .unverified, .exit = 7 },
        .{ .state = .recording_degraded, .attribution = .unverified, .exit = 7, .saved = false, .failed = true },
        .{ .state = .running, .attribution = .unverified, .exit = null, .saved = false, .handed_off = true },
    }) |case| {
        var record = executionFixture(case.state, "ACTUAL_OBSERVED_BYTES\n");
        defer record.deinit();
        const projection = &record.execution.?;
        projection.output_scope = .session_interval;
        projection.output_attribution = case.attribution;
        projection.output_attribution_reason = if (case.attribution == .concurrent_observed) "BackgroundJobsObserved" else null;
        projection.interval_saved = case.saved;
        projection.recording_settled = case.saved;
        projection.recording_failed = case.failed;
        projection.input_handed_off = case.handed_off;
        projection.process = if (case.exit) |code| .{ .foreground_finished = true, .exit_code = code } else null;
        var store = facts.Store.init(a);
        defer store.records.deinit(a);
        try store.records.append(a, &record);
        var recorder: ExecutionRecorder = .{};
        const cx = try ui.Cx.init(a, std.testing.io);
        defer cx.deinit();
        cx.setViewport(332, 358);
        const scope = try ui.Scope.init(a, null, cx.owner);
        defer scope.dispose();
        const root = try Execution.mount(cx, scope, &store, &record, .{ .context = &recorder, .perform = ExecutionRecorder.perform }, null);
        cx.root = root;
        root.setStyleInline(a, .{ .width = .{ .px = 332 } });
        for (0..4) |_| {
            cx.layout();
            _ = cx.render();
        }
        try std.testing.expectEqualStrings("同一终端观测片段", find(root, "ai.execution.result.output_label").?.getText().?.content);
        try std.testing.expectEqualStrings(projection.attributionLabel(), find(root, "ai.execution.result.output_attribution").?.getText().?.content);
        try std.testing.expectEqualStrings(if (case.saved) "同一终端观测片段 · 已保存" else if (case.failed) "同一终端观测片段 · 保存失败" else "同一终端观测片段 · 保存待确认", find(root, "ai.execution.result.output_scope").?.getText().?.content);
        try std.testing.expect(std.mem.indexOf(u8, find(root, "ai.execution.result.output_limit").?.getText().?.content, "后台输出可能在前台结束后继续") != null);
        try std.testing.expect(std.mem.indexOf(u8, find(root, "ai.execution.result.summary").?.getText().?.content, "封存") == null);
        if (case.exit) |code| {
            const expected = try std.fmt.allocPrint(a, "前台已结束 · 退出码 {d}", .{code});
            defer a.free(expected);
            try std.testing.expectEqualStrings(expected, find(root, "ai.execution.result.process").?.getText().?.content);
            if (code != 0 and !case.failed) try std.testing.expect(std.mem.indexOf(u8, find(root, "ai.execution.result.summary").?.getText().?.content, "执行失败") != null);
        } else {
            try std.testing.expect(find(root, "ai.execution.result.process") == null);
            try std.testing.expectEqualStrings("最近观测 · 用户已接管 · 命令继续运行", find(root, "ai.execution.result.summary").?.getText().?.content);
        }
        try std.testing.expect(find(root, "ai.execution.result.stop") == null and find(root, "ai.execution.result.takeover") == null);
        find(root, "ai.execution.result.view_terminal").?.behavior.events.on_click.?.invoke();
        try std.testing.expectEqual(@as(usize, 1), recorder.calls);
        try std.testing.expect(recorder.target.?.session.eql(projection.target.?));
        try std.testing.expect(recorder.target.?.conversation_id.eql(projection.conversation_id) and recorder.target.?.task_id.eql(projection.task_id));
        try std.testing.expect(recorder.target.?.execution_id.eql(projection.execution_id.?));
        try std.testing.expect(find(root, "ai.execution.result.details").?.globalRect().h <= 150);
        const title = find(root, "ai.execution.result.title").?.globalRect();
        const icon = find(root, "ai.execution.result.icon").?.globalRect();
        try std.testing.expect(@abs(icon.y + icon.h / 2 - title.y - title.h / 2) < 0.1);
    }
}

fn settleCard(cx: *ui.Cx) void {
    for (0..4) |_| {
        cx.advanceFrameClock();
        cx.layout();
        _ = cx.render();
    }
}
fn cardScrollState(node: *ui.Node) *ui.widgets.scroll_area.ScrollState {
    const context: *ui.widgets.scroll_area.ScrollEventCtx = @ptrCast(@alignCast(node.behavior.events.event_context.?));
    return context.state;
}

test "PATCH card scroll restores tool and execution positions after input and safely outlives record removal" {
    const long_line = "READING_POSITION_0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000";
    const output = try std.mem.join(a, "\n", &@as([30][]const u8, @splat(long_line)));
    defer a.free(output);
    inline for (.{ false, true }) |execution| {
        var record = executionFixture(.running, output);
        var record_alive = true;
        defer if (record_alive) record.deinit();
        record.command = long_line;
        if (!execution) {
            record.execution = null;
            record.name = "host.get_current_context";
            record.host = .{ .status = .succeeded, .content = output, .receipt = .{ .conversation_id = .generate(), .task_id = .generate(), .operation_id = 42, .binding_revision = 1 } };
        }
        var store = facts.Store.init(a);
        defer store.records.deinit(a);
        try store.records.append(a, &record);
        const cx = try ui.Cx.init(a, std.testing.io);
        defer cx.deinit();
        cx.reduced_motion = true;
        cx.setViewport(400, 400);
        cx.root = try ui.box(cx, .{ .width = .fill(), .height = .fill(), .direction = .column }, .{});
        const parent = try ui.Scope.init(a, null, cx.owner);
        defer parent.dispose();
        var scope = try parent.childScope();
        var card = if (execution) try @import("ui/ai_execution_result_view.zig").mount(cx, scope, &store, &record, null, null) else (try View.State.mount(cx, scope, &record)).root;
        try cx.root.?.appendChild(a, card);
        settleCard(cx);
        const body_id = if (execution) "ai.execution.result.details" else "ai.tool.result.details";
        const output_id = if (execution) "ai.execution.result.terminal_output" else "ai.tool.result.stdout";
        var body = find(card, body_id).?;
        const viewport = body.globalRect();
        cx.handleScroll(.{ .x = viewport.x + 30, .y = viewport.y + viewport.h / 2, .dx = 0, .dy = -40 });
        settleCard(cx);
        var text = find(card, output_id).?;
        const text_rect = text.globalRect();
        cx.handleScroll(.{ .x = viewport.x + 40, .y = @min(viewport.y + viewport.h - 5, @max(viewport.y + 5, text_rect.y + 10)), .dx = -55, .dy = 0 });
        settleCard(cx);
        const horizontal = text.parent.?.parent.?;
        try std.testing.expect(cardScrollState(horizontal).scroll_x > 0);
        // Dispose immediately after vertical input, before the next layout hook.
        cx.handleScroll(.{ .x = viewport.x + 30, .y = viewport.y + viewport.h / 2, .dx = 0, .dy = -20 });
        const saved_y = cardScrollState(body).scroll_y;
        const saved_x = cardScrollState(horizontal).scroll_x;
        try std.testing.expect(saved_y >= 60 and saved_x > 0);
        scope.dispose();
        cx.detachChild(cx.root.?, card);
        cx.destroyDetached(card);
        scope = try parent.childScope();
        card = if (execution) try @import("ui/ai_execution_result_view.zig").mount(cx, scope, &store, &record, null, null) else (try View.State.mount(cx, scope, &record)).root;
        try cx.root.?.appendChild(a, card);
        settleCard(cx);
        body = find(card, body_id).?;
        text = find(card, output_id).?;
        try std.testing.expectApproxEqAbs(saved_y, cardScrollState(body).scroll_y, 0.1);
        try std.testing.expectApproxEqAbs(saved_x, cardScrollState(text.parent.?.parent.?).scroll_x, 0.1);
        // Rollback can release the record before the old UI scope is disposed.
        record.deinit();
        record_alive = false;
        scope.dispose();
    }
}

test "PATCH card scroll resets output positions when selecting another original target" {
    const long_line = "SCOPED_OUTPUT_000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000";
    const output = try std.mem.join(a, "\n", &@as([20][]const u8, @splat(long_line)));
    defer a.free(output);
    var targets = [_]facts.Target{
        .{ .result = .{ .session_id = 101, .status = .succeeded, .stdout = output }, .label = "first" },
        .{ .result = .{ .session_id = 102, .status = .succeeded, .stdout = output }, .label = "second" },
    };
    var record: facts.Record = .{ .arena = .init(a), .owner = .{ .group = 7 }, .turn_id = 1, .call_id = "target-scroll", .name = "run_command", .arguments = "{}", .command = long_line, .arguments_hash = @splat(0), .targets = &targets, .dispatched = true, .expanded = true };
    defer record.deinit();
    const cx = try ui.Cx.init(a, std.testing.io);
    defer cx.deinit();
    cx.reduced_motion = true;
    cx.setViewport(400, 400);
    const scope = try ui.Scope.init(a, null, cx.owner);
    defer scope.dispose();
    const view = try View.State.mount(cx, scope, &record);
    cx.root = view.root;
    view.root.setStyleInline(a, .{ .width = .{ .px = 400 } });
    settleCard(cx);
    const body = view.body.globalRect();
    cx.handleScroll(.{ .x = body.x + 20, .y = body.y + body.h / 2, .dx = 0, .dy = -100 });
    settleCard(cx);
    try std.testing.expect(cardScrollState(view.body).scroll_y > 0);
    try view.select(1);
    settleCard(cx);
    try std.testing.expectEqual(@as(usize, 1), record.selected);
    try std.testing.expectEqual(@as(f32, 0), cardScrollState(view.body).scroll_y);
    try std.testing.expectEqual(@as(f32, 0), view.stdout_scroll.scroll_x);
    try std.testing.expectEqual(@as(f32, 0), view.stderr_scroll.scroll_x);
}
