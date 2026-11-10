const ui = @import("ui");
const V = @import("ui/ai_remote_picker.zig");

test "remote authentication presentation keeps host fingerprints out of private key prompts" {
    const std = @import("std");
    const auth = @import("proto/ssh/auth_challenge.zig");
    const Adapter = @import("plugins/remote/challenge_bridge.zig");
    const shared = @import("host/challenge_host.zig");
    const Callbacks = struct {
        fn submit(_: *anyopaque, _: auth.RequestIdentity, _: auth.Reply) !void {}
        fn cancel(_: *anyopaque, _: auth.RequestIdentity) void {}
    };
    var context: u8 = 0;
    var host = shared.Host.init(std.testing.allocator);
    defer host.deinit();
    var adapter: Adapter.Bridge = .{};
    defer adapter.clear();
    var key: @import("ui/host_key_confirmation.zig").Request = .{};
    @memcpy(key.algorithm[0..7], "ssh-rsa");
    key.algorithm_len = 7;
    @memcpy(key.fingerprint[0..14], "SHA256:fixture");
    key.fingerprint_len = 14;
    for ([_]auth.Kind{ .host_key_unknown, .private_key_passphrase, .password }) |kind| {
        var mailbox: auth.InteractiveBridge = .{};
        _ = try mailbox.offerChallenge(.{
            .key = .{ .owner = .{ .session = .{ .session_id = @fromBackingInt(71), .generation = 1 } }, .operation_id = 8, .attempt_id = 1 },
            .hop_index = 0,
            .kind = kind,
            .endpoint_identity = .{ .host = "fixture", .user = "operator" },
            .prompts = if (kind == .host_key_unknown) &.{} else &.{.{ .text = "Secret" }},
            .presentation_config_revision = 1,
        });
        try adapter.sync(&host, mailbox.snapshot(), .{ .host_key = key, .private_key_path = "/fixture/key" }, .{ .context = &context, .submit = Callbacks.submit, .cancel = Callbacks.cancel }, 1);
        const view = host.snapshot(0, null).?;
        if (kind == .host_key_unknown) {
            try std.testing.expect(std.mem.indexOf(u8, view.payload.material, "SHA256:fixture") != null);
        } else {
            try std.testing.expectEqualStrings("", view.payload.material);
        }
        adapter.clear();
    }
}

test "AI remote filename button stays inside its bounded table cell" {
    const std = @import("std");
    const Probe = struct {
        clicks: usize = 0,
        fn click(self: *@This()) void {
            self.clicks += 1;
        }
    };
    const allocator = std.testing.allocator;
    const cx = try ui.Cx.init(allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(860, 480);
    const scope = try ui.Scope.init(allocator, null, cx.owner);
    defer scope.dispose();
    cx.root = try ui.box(cx, .{ .width = .fill(), .height = .fill() }, .{});
    const cell = try ui.box(cx, .{ .width = .{ .px = 180 }, .height = .{ .px = 43 }, .direction = .row, .min_width = 0 }, .{});
    try cx.root.?.appendChild(allocator, cell);
    var probe: Probe = .{};
    const name = "very-long-remote-filename-that-must-not-paint-over-the-size-or-modified-time-column.txt";
    const filename = try V.filenameButton(scope, cx, name, cx.on(Probe, &probe, Probe.click), null);
    const button_node = filename.button;
    try cell.appendChild(allocator, button_node);
    cx.layout();
    const rect = button_node.globalRect();
    try std.testing.expectEqual(@as(f32, 180), rect.w);
    try std.testing.expectEqual(@as(f32, 32), rect.h);
    const label = filename.label;
    try std.testing.expect(label.getText().?.text_overflow == .ellipsis);
    try std.testing.expect(label.globalRect().x + label.globalRect().w <= rect.x + rect.w);
    try std.testing.expectEqualStrings(name, button_node.behavior.interaction.a11y.?.label.?);
    cx.handleClick(rect.x + rect.w / 2, rect.y + rect.h / 2);
    try std.testing.expectEqual(@as(usize, 1), probe.clicks);
}

test "AI remote picker leaves a reused earlier authentication modal accessible" {
    const std = @import("std");
    const Shared = @import("ui/challenge_window_host.zig").Services;
    const files = @import("host/file_binding_host.zig");
    const attachments = @import("ai/local_text_attachments.zig");
    const scope_mod = @import("ai/tool_scope.zig");
    const Callbacks = struct {
        fn ensure(_: *anyopaque, _: V.Source) !files.Bindings {
            return error.UnexpectedFileConnection;
        }
        fn live(_: *anyopaque, _: scope_mod.Owner) ?scope_mod.Scope {
            return null;
        }
        fn stage(_: *anyopaque, _: scope_mod.Owner, _: *attachments.ContentRef) !void {
            return error.UnexpectedAttachment;
        }
    };
    const allocator = std.testing.allocator;
    const cx = try ui.Cx.init(allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(1100, 720);
    cx.root = try ui.box(cx, .{ .width = .fill(), .height = .fill() }, .{});
    const scope = try ui.Scope.init(allocator, null, cx.owner);
    defer scope.dispose();
    // The window creates its shared authentication presenter before the AI
    // picker. Its later challenge reuses that original portal node.
    const shared = try Shared.mount(cx, scope);
    var unused_host: files.FileBindingHost = undefined;
    var context: u8 = 0;
    const picker = try V.View.mount(cx, scope, &unused_host, .{ .context = &context, .ensure = Callbacks.ensure, .live = Callbacks.live, .stage = Callbacks.stage });
    defer picker.release() catch unreachable;
    try cx.root.?.appendChild(allocator, picker.root);
    try picker.open(.{ .session = 1 }, &.{});
    cx.layout();
    _ = cx.render();

    const owner: @import("host/identity.zig").SessionHandle = .{ .session_id = @fromBackingInt(1), .generation = 1 };
    try shared.host.offer(owner, 1, 1, .trust_material, .{ .title = "核对主机密钥", .choices = &.{ .{ .value = "trust_once", .label = "仅本次信任" }, .{ .value = "trust_save", .label = "保存并继续" } } }, std.math.maxInt(u64));
    try shared.view.update(owner);
    cx.layout();
    _ = cx.render();
    try std.testing.expect(cx.overlay_stack.topmost().?.content_node == shared.view.modal.dialog);
    try std.testing.expect(cx.focus_manager.activeScope() == shared.view.modal.overlay);
    const action_id = ui.a11y.AXId.fromRaw(shared.view.trust_actions[0].element_id_raw);
    const action = cx.accessibility_tree.get(action_id).?;
    try std.testing.expect(!action.state.hidden);
    try std.testing.expect(!action.state.disabled);

    // Dismissing this independent challenge restores the still-open picker.
    _ = try shared.host.withdraw(owner, 1, 1);
    try shared.view.update(owner);
    for (0..20) |_| {
        var unused: [1]std.c.pollfd = undefined;
        _ = std.c.poll(&unused, 0, 16);
        cx.advanceFrameClock();
        cx.layout();
        _ = cx.render();
    }
    try std.testing.expect(picker.open_state);
    try std.testing.expect(cx.focus_manager.activeScope() != shared.view.modal.overlay);
    const close = struct {
        fn find(node: *ui.Node) ?*ui.Node {
            if (node.meta.ownership.meta.test_id) |id| if (std.mem.eql(u8, id, "ai.remote.close")) return node;
            for (node.children.items) |child| if (find(child)) |found| return found;
            return null;
        }
    }.find(cx.root.?).?;
    const close_action = cx.accessibility_tree.get(ui.a11y.AXId.fromRaw(close.element_id_raw)).?;
    try std.testing.expect(!close_action.state.hidden);
    try std.testing.expect(!close_action.state.disabled);
}

test "AI remote source tooltip follows selected name and clears stale names on empty reopen" {
    const std = @import("std");
    const files = @import("host/file_binding_host.zig");
    const attachments = @import("ai/local_text_attachments.zig");
    const owner_scope = @import("ai/tool_scope.zig");
    const Callbacks = struct {
        fn ensure(_: *anyopaque, _: V.Source) !files.Bindings {
            return error.NoFixtureIO;
        }
        fn live(_: *anyopaque, _: owner_scope.Owner) ?owner_scope.Scope {
            return null;
        }
        fn stage(_: *anyopaque, _: owner_scope.Owner, _: *attachments.ContentRef) !void {}
        fn find(node: *ui.Node) ?*ui.Node {
            if (node.meta.ownership.meta.test_id) |id| if (std.mem.eql(u8, id, "ai.remote.source")) return node;
            for (node.children.items) |child| if (find(child)) |found| return found;
            return null;
        }
    };
    const a = std.testing.allocator;
    const cx = try ui.Cx.init(a, std.testing.io);
    defer cx.deinit();
    cx.setViewport(860, 480);
    cx.root = try ui.box(cx, .{ .width = .fill(), .height = .fill() }, .{});
    const scope = try ui.Scope.init(a, null, cx.owner);
    defer scope.dispose();
    var host: files.FileBindingHost = undefined;
    var context: u8 = 0;
    const picker = try V.View.mount(cx, scope, &host, .{ .context = &context, .ensure = Callbacks.ensure, .live = Callbacks.live, .stage = Callbacks.stage });
    defer picker.release() catch unreachable;
    const long_name = "very-long-remote-source-name.production.example.internal";
    try cx.root.?.appendChild(a, picker.root);
    const sources = [_]V.Source{
        .{ .session = .{ .session_id = @fromBackingInt(1), .generation = 1 }, .name = long_name, .cwd = "/fixture", .available = true },
        .{ .session = .{ .session_id = @fromBackingInt(2), .generation = 1 }, .name = "第二个远程来源", .cwd = "/fixture", .available = true },
    };
    try std.testing.expectError(error.NoFixtureIO, picker.open(.{ .group = 1 }, &sources));
    cx.layout();
    _ = cx.render();
    try std.testing.expectEqualStrings(long_name, picker.source_hint_label.getText().?.content);
    const trigger = Callbacks.find(cx.root.?).?.parent.?;
    // Exercise the Select's real keyboard selection callback, including the
    // failed connection path: the name still follows the user's selection.
    _ = trigger.behavior.events.on_key_down.?(.end, .{}, trigger.behavior.events.key_context);
    _ = trigger.behavior.events.on_key_down.?(.@"return", .{}, trigger.behavior.events.key_context);
    try std.testing.expectEqualStrings(sources[1].name, picker.source_hint_label.getText().?.content);
    try picker.open(.{ .group = 1 }, &.{});
    try std.testing.expectEqualStrings("远程来源", picker.source_hint_label.getText().?.content);
}

test "AI remote reference owns only its source and path through prompt and persistence" {
    const std = @import("std");
    const attachments = @import("ai/local_text_attachments.zig");
    const a = std.testing.allocator;
    const owner: attachments.SessionHandle = .{ .session_id = @fromBackingInt(101), .generation = 7 };
    var source_name = "remote fixture".*;
    var path = "/not-a-local-file/Rocky.iso".*;
    var reference = try attachments.ContentRef.createRemoteReference(a, owner, &source_name, &path);
    defer reference.release();
    @memset(&source_name, 'x');
    @memset(&path, 'x');
    const content = reference.content().?;
    try std.testing.expectEqualStrings("remote fixture", content.source.remote_file.source_name);
    try std.testing.expectEqualStrings("/not-a-local-file/Rocky.iso", content.path);
    try std.testing.expect(content.source.remote_file.reference_only);
    try std.testing.expect(content.source.remote_file.operation == null);
    try std.testing.expectEqual(@as(usize, 0), content.bytes.len);

    var draft = try attachments.Draft.init(a, .{ .session = 101 });
    defer draft.deinit();
    const ticket = try draft.begin();
    var incoming = reference.retain();
    _ = try draft.complete(ticket, &incoming);
    var sent = try draft.freeze();
    defer sent.deinit();
    const wire = try @import("ai/local_text_request.zig").compose(a, "inspect this reference", &sent, 4096);
    defer a.free(wire);
    for ([_][]const u8{ "<remote_file_reference>", "source_session=101", "source_generation=7", "source_name=remote fixture", "path=/not-a-local-file/Rocky.iso", "File contents are not included", "file tool" }) |expected| {
        try std.testing.expect(std.mem.indexOf(u8, wire, expected) != null);
    }
    for ([_][]const u8{ "text:", "read_bytes=", "captured_at_ms=", "<remote_file_attachment>" }) |absent| {
        try std.testing.expect(std.mem.indexOf(u8, wire, absent) == null);
    }

    const encoded = try std.json.Stringify.valueAlloc(a, content, .{});
    defer a.free(encoded);
    const parsed = try std.json.parseFromSlice(attachments.Content, a, encoded, .{});
    defer parsed.deinit();
    var restored = try attachments.ContentRef.restore(a, parsed.value);
    defer restored.release();
    try std.testing.expect(restored.content().?.source.remote_file.reference_only);
    try std.testing.expect(restored.content().?.source.remote_file.owner.eql(owner));
    try std.testing.expectEqualStrings(content.path, restored.content().?.path);
    try std.testing.expectEqual(@as(usize, 0), restored.content().?.bytes.len);
    try std.testing.expectError(error.InvalidRemotePath, attachments.ContentRef.createRemoteReference(a, owner, "remote", "relative.iso"));
}

test "AI remote reference confirmation discards preview bytes while preserving the preview snapshot" {
    const std = @import("std");
    const attachments = @import("ai/local_text_attachments.zig");
    const a = std.testing.allocator;
    const owner: attachments.SessionHandle = .{ .session_id = @fromBackingInt(101), .generation = 7 };
    var preview = try attachments.ContentRef.restore(a, .{
        .path = "/fixture/secret.txt",
        .bytes = "preview-only confidential text",
        .captured_at_ms = 123,
        .sha256 = @splat(0),
        .bom_preserved = false,
        .source = .{ .remote_file = .{ .owner = owner, .source_name = "remote fixture", .source_revision = 2, .operation = .{ .owner = .{ .session = owner }, .operation_id = 3 }, .actual_path = "/fixture/secret.txt", .original_size = 30, .read_bytes = 30, .read_limit = 4096, .truncated = false } },
    });
    defer preview.release();
    var draft = try attachments.Draft.init(a, .{ .session = 101 });
    defer draft.deinit();
    const ticket = try draft.begin();
    var incoming = preview.retain();
    try draft.stage(ticket, &incoming);
    _ = try draft.attach(ticket);
    const attached = draft.items.items[0].reference.content().?;
    try std.testing.expect(attached.source.remote_file.reference_only);
    try std.testing.expectEqual(@as(usize, 0), attached.bytes.len);
    try std.testing.expectEqualStrings(preview.content().?.path, attached.path);
    try std.testing.expectEqualStrings("preview-only confidential text", preview.content().?.bytes);
    var bundle = try draft.freeze();
    defer bundle.deinit();
    const wire = try @import("ai/local_text_request.zig").compose(a, "inspect", &bundle, 4096);
    defer a.free(wire);
    try std.testing.expect(std.mem.indexOf(u8, wire, "preview-only confidential text") == null);
}
