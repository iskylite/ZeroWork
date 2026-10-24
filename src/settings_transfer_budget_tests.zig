//! Real settings draft/save gate for a newly edited transfer window policy.
const std = @import("std");
const settings = @import("config/settings_controller.zig");
const runtime = @import("config/runtime_config.zig");
const config = @import("config/config.zig");
const schema = @import("config/settings_schema.zig");
const ui = @import("ui");
const view = @import("config/settings_content_view.zig");
const a = std.testing.allocator;
const io = std.testing.io;

test "settings transfer budget rejects edited per-job excess preserving raw draft then saves corrected pair" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var target = try runtime.RuntimeConfig.loadOrDefault(io, tmp.dir, a, "config.toml");
    defer target.deinit();
    var c = try settings.Controller.init(a, target.value);
    defer c.deinit();
    const revision = target.value.config_revision;
    const window = schema.find("transfer", "window_chunks").?;
    try c.editRaw("transfer", "window_chunks", " 33 ");
    try std.testing.expectEqualStrings(" 33 ", c.raw_fields[window].input.?);
    try std.testing.expectEqual(@as(u8, 33), c.model.value.transfer.window_chunks);
    try std.testing.expectEqual(error.TransferWindowBudgetExceeded, c.fieldProblem(window).?);
    try std.testing.expectEqual(settings.State.dirty_invalid, c.state());
    try std.testing.expect(!c.canSave());
    try std.testing.expectError(error.InvalidDraft, c.save(io, tmp.dir, &target));
    try std.testing.expectEqual(revision, target.value.config_revision);
    try std.testing.expectEqual(@as(u8, 16), target.value.transfer.window_chunks);
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "config.toml", .{}));
    // Another member can repair the combination. The original raw edit and
    // typed window remain intact, and no stale per-field error survives.
    try c.editRaw("transfer", "chunk_kb", "32");
    try std.testing.expect(c.fieldProblem(window) == null);
    try std.testing.expect(c.canSave());
    try std.testing.expectEqualStrings(" 33 ", c.raw_fields[window].input.?);
    try c.save(io, tmp.dir, &target);
    var reload = try runtime.RuntimeConfig.loadOrDefault(io, tmp.dir, a, "config.toml");
    defer reload.deinit();
    try std.testing.expectEqual(@as(u8, 33), reload.value.transfer.window_chunks);
    try std.testing.expectEqual(@as(u16, 32), reload.value.transfer.chunk_kb);
    try std.testing.expectEqual(settings.State.clean, c.state());
}

test "settings transfer budget catches global concurrency and reverting restores clean draft" {
    var c = try settings.Controller.init(a, .{});
    defer c.deinit();
    const concurrency = schema.find("transfer", "max_tasks").?;
    try c.editKey("transfer", "max_tasks", .{ .unsigned = 7 });
    try std.testing.expectEqual(error.TransferGlobalWindowBudgetExceeded, c.fieldProblem(concurrency).?);
    try std.testing.expectEqual(settings.State.dirty_invalid, c.state());
    try std.testing.expectEqualStrings("7", c.raw_fields[concurrency].input.?);
    try c.editRaw("transfer", "max_tasks", "3");
    try std.testing.expect(c.fieldProblem(concurrency) == null);
    try std.testing.expectEqual(settings.State.clean, c.state());
    try std.testing.expect(!c.model.dirty);
}

test "settings transfer budget leaves legacy over-budget configs loadable and unrelated saves available" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const legacy = "[transfer]\nchunk_kb = 65535\nwindow_chunks = 255\nmax_tasks = 255\n";
    const parsed = try config.Config.parse(legacy);
    try parsed.validate();
    try tmp.dir.writeFile(io, .{ .sub_path = "legacy.toml", .data = legacy });
    var target = try runtime.RuntimeConfig.loadOrDefault(io, tmp.dir, a, "legacy.toml");
    defer target.deinit();
    var c = try settings.Controller.init(a, target.value);
    defer c.deinit();
    try std.testing.expectEqual(settings.State.clean, c.state());
    try std.testing.expect(c.transferPolicyProblem() == null);
    // Even an unrelated setting on the transfer page is not a policy change.
    try c.editKey("transfer", "verify_md5", .{ .boolean = true });
    try c.editKey("ui", "font_size", .{ .unsigned = 18 });
    try std.testing.expect(c.canSave());
    try c.save(io, tmp.dir, &target);
    var reload = try runtime.RuntimeConfig.loadOrDefault(io, tmp.dir, a, "legacy.toml");
    defer reload.deinit();
    try std.testing.expectEqual(@as(u16, 65535), reload.value.transfer.chunk_kb);
    try std.testing.expectEqual(@as(u8, 255), reload.value.transfer.window_chunks);
    try std.testing.expectEqual(@as(u8, 255), reload.value.transfer.max_tasks);
    try std.testing.expect(reload.value.transfer.verify_md5);
    try std.testing.expectEqual(@as(u8, 18), reload.value.ui.font_size);
}

test "settings transfer budget rechecks latest merged policy before any persistence" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var target = try runtime.RuntimeConfig.loadOrDefault(io, tmp.dir, a, "config.toml");
    defer target.deinit();
    var c = try settings.Controller.init(a, target.value);
    defer c.deinit();
    try c.editRaw("transfer", "max_tasks", "6"); // draft = 1 MiB x 6
    try std.testing.expect(c.canSave());
    try target.updateSetting(io, tmp.dir, "transfer", "window_chunks", .{ .unsigned = 32 }); // latest = 2 MiB x 3
    const revision = target.value.config_revision;
    try std.testing.expectError(error.TransferGlobalWindowBudgetExceeded, c.save(io, tmp.dir, &target)); // merged = 2 MiB x 6
    try std.testing.expectEqual(revision, target.value.config_revision);
    try std.testing.expectEqual(@as(u8, 3), target.value.transfer.max_tasks);
    try std.testing.expectEqualStrings("6", c.raw_fields[schema.find("transfer", "max_tasks").?].input.?);
    try std.testing.expectEqual(error.TransferGlobalWindowBudgetExceeded, c.fieldProblem(schema.find("transfer", "max_tasks").?).?);
    try std.testing.expectEqual(settings.State.dirty_invalid, c.state());
    try c.editRaw("transfer", "max_tasks", "2");
    try std.testing.expect(c.canSave());
    try c.save(io, tmp.dir, &target);
    try std.testing.expectEqual(@as(u8, 32), target.value.transfer.window_chunks);
    try std.testing.expectEqual(@as(u8, 2), target.value.transfer.max_tasks);
}

fn changed(_: *anyopaque) void {}
fn request(_: *anyopaque, _: view.Key, _: *ui.Node) void {}
fn action(_: *anyopaque, _: view.Action) void {}
fn byId(node: *ui.Node, id: []const u8) ?*ui.Node {
    if (node.meta.ownership.meta.test_id) |value| if (std.mem.eql(u8, value, id)) return node;
    for (node.children.items) |child| if (byId(child, id)) |found| return found;
    return null;
}
fn inputFor(page: view.Mounted, id: []const u8) *ui.widgets.input.TextInputState {
    const node = byId(page.root, id).?;
    for (page.binding.ime_clients.items) |state| if (state.input_container_node == node) return state;
    unreachable;
}
fn replaceInput(cx: *ui.Cx, state: *ui.widgets.input.TextInputState, text: []const u8) void {
    const node = state.input_container_node.?;
    cx.setFocus(node);
    if (node.behavior.events.on_event) |handler| {
        _ = handler(.{ .key_down = .{ .key = .a, .modifiers = .{ .super = true } } }, node.behavior.events.event_context);
        _ = handler(.{ .text_input = .{ .text = text } }, node.behavior.events.event_context);
    }
}

test "settings transfer budget actual Cx inputs show field issue and clear it when another policy field repairs budget" {
    const cx = try ui.Cx.init(a, io);
    defer cx.deinit();
    cx.setViewport(636, 628);
    const scope = try ui.Scope.init(a, null, cx.owner);
    defer scope.dispose();
    cx.root = try ui.box(cx, .{ .width = .{ .px = 636 }, .height = .{ .px = 628 } }, .{});
    var c = try settings.Controller.init(a, .{});
    defer c.deinit();
    c.model.selectPage(3);
    c.folded_sections = 0;
    var context: u8 = 0;
    const page = try view.mountPage(cx, scope, &c, .{ .context = &context, .changed = changed, .request_edit = request, .action = action });
    try cx.root.?.appendChild(cx.allocator, page.root);
    cx.layout();
    const window_input = inputFor(page, "settings.field.window_chunks");
    replaceInput(cx, window_input, "33");
    cx.layout();
    try std.testing.expectEqualStrings("33", window_input.getText());
    const error_note = byId(page.root, "settings.error.window_chunks").?;
    try std.testing.expect(std.mem.indexOf(u8, error_note.getText().?.content, "2 MiB") != null);
    try std.testing.expectEqual(.flex, error_note.style.display);
    try std.testing.expect(page.save_button.behavior.interaction.a11y.?.disabled);
    replaceInput(cx, inputFor(page, "settings.field.chunk_kb"), "32");
    cx.layout();
    try std.testing.expectEqualStrings("33", window_input.getText());
    try std.testing.expectEqual(.none, error_note.style.display);
    try std.testing.expect(!page.save_button.behavior.interaction.a11y.?.disabled);
}
