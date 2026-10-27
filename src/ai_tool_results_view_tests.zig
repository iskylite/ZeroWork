//! Cx layout and exact owned facts; no provider/remote IO is mocked as native evidence.
const std = @import("std");
const ui = @import("ui");
const facts = @import("ai/tool_results.zig");
const loop = @import("ai/tool_loop.zig");
const View = @import("ui/ai_tool_results_view.zig");
const a = std.testing.allocator;
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
        cx.advanceFrameClock();
        cx.layout();
        _ = cx.render();
    }
    try std.testing.expectEqual(@as(f32, 32), card.globalRect().h);
    try std.testing.expect(!store.records.items[0].expanded);
    find(card, "ai.tool.result.disclosure").?.parent.?.behavior.events.on_click.?.invoke();
    for (0..4) |_| {
        cx.advanceFrameClock();
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
    cx.layout();
    try std.testing.expectApproxEqAbs(@as(f32, 32), state.root.globalRect().h, 0.1);
}
