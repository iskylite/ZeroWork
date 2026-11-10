const std = @import("std");
const ui = @import("ui");
const A = @import("ai/local_text_attachments.zig");
const V = @import("ui/ai_attachments_view.zig");
const theme = @import("ui/app_theme.zig");
const a = std.testing.allocator;
fn expectPreviewBounds(f: *Fixture) !void {
    const panel = f.view.preview_panel.globalRect();
    const body = f.view.preview_body.container.globalRect();
    try std.testing.expectApproxEqAbs(f.cx.viewport.width * 0.78, panel.w, 0.1);
    try std.testing.expect(panel.h <= f.cx.viewport.height - 32 + 0.1);
    try std.testing.expect(body.y >= panel.y and body.y + body.h <= panel.y + panel.h);
}

test "idle inline attachment preview dismiss only publishes visibility transitions" {
    var f: Fixture = undefined;
    try f.initInline();
    defer f.deinit();
    f.view.callbacks.preview_visibility = struct {
        fn changed(raw: *anyopaque, visible: bool) void {
            const fixture: *Fixture = @ptrCast(@alignCast(raw));
            fixture.calls += 1;
            Fixture.previewVisibility(raw, visible);
        }
    }.changed;
    const id = try f.add("/preview.txt", "captured text");
    try f.view.update(&f.draft);
    f.settle();
    f.view.dismiss();
    try std.testing.expectEqual(@as(usize, 0), f.calls);
    try f.view.openPreview(id);
    try std.testing.expectEqual(@as(usize, 1), f.calls);
    f.view.dismiss();
    try std.testing.expectEqual(@as(usize, 2), f.calls);
    f.cx.needs_redraw = false;
    f.view.dismiss();
    try std.testing.expectEqual(@as(usize, 2), f.calls);
    try std.testing.expect(!f.cx.needs_redraw);
}
const Fixture = struct {
    cx: *ui.Cx,
    scope: *ui.Scope,
    view: *V.View,
    draft: A.Draft,
    last: ?A.Ticket = null,
    calls: usize = 0,
    attaches: usize = 0,
    reselects: usize = 0,
    inline_holder: ?*ui.Node = null,
    conversation: ?*ui.Node = null,
    fn init(self: *Fixture) !void {
        try self.initMode(false);
    }
    fn initInline(self: *Fixture) !void {
        try self.initMode(true);
    }
    fn initMode(self: *Fixture, inline_preview: bool) !void {
        self.* = .{ .cx = try ui.Cx.init(a, std.testing.io), .scope = undefined, .view = undefined, .draft = try A.Draft.init(a, .{ .session = 101 }) };
        try self.cx.setTestFrameStep(100);
        self.cx.setViewport(1200, 900);
        self.cx.root = try ui.box(self.cx, .{ .width = .fill(), .height = .fill() }, .{});
        self.scope = try ui.Scope.init(a, null, self.cx.owner);
        const callbacks: V.Callbacks = .{ .context = self, .remove = remove, .attach = attach, .reselect = reselect };
        if (inline_preview) {
            const holder = try ui.boxStyled(self.cx, @import("ui/ai_attachments_styles.zig").inlineHolder, .{});
            self.inline_holder = holder;
            holder.setStyleInline(a, .{ .position = .absolute, .inset = .{ .left = .{ .px = 100 }, .top = .{ .px = 100 } }, .width = .{ .px = 600 } });
            try self.cx.root.?.appendChild(a, holder);
            self.view = try V.View.mountInline(self.cx, self.scope, callbacks, holder);
            self.conversation = try ui.boxStyled(self.cx, @import("ui/ai_assistant_styles.zig").conversation, .{});
            try self.cx.root.?.appendChild(a, self.conversation.?);
            self.view.callbacks.preview_visibility = previewVisibility;
            self.cx.root.?.behavior.events.capture_context = self;
            self.cx.root.?.behavior.events.on_event_capture = inlineEvent;
        } else self.view = try V.View.mount(self.cx, self.scope, callbacks);
        self.view.root.setStyleInline(a, .{ .position = .absolute, .inset = .{ .left = .{ .px = 100 }, .top = .{ .px = 500 } }, .width = .{ .px = 600 } });
        try self.cx.root.?.appendChild(a, self.view.root);
        self.settle();
    }
    fn previewVisibility(raw: *anyopaque, visible: bool) void {
        const self: *Fixture = @ptrCast(@alignCast(raw));
        self.inline_holder.?.setDisplay(if (visible) .flex else .none);
        self.conversation.?.setDisplay(if (visible) .none else .flex);
    }
    fn inlineEvent(event: ui.events.Event, raw: ?*anyopaque) ui.events.EventResult {
        const self: *Fixture = @ptrCast(@alignCast(raw orelse return .ignored));
        switch (event) {
            .key_down => |key| if (key.key == .escape and self.view.escapePreview()) return .stop,
            else => {},
        }
        return .ignored;
    }
    fn deinit(self: *Fixture) void {
        self.scope.dispose();
        self.cx.deinit();
        self.draft.deinit();
    }
    fn add(self: *Fixture, path: []const u8, bytes: []const u8) !A.Id {
        const ticket = try self.draft.begin();
        var reference = try A.ContentRef.create(a, path, bytes, 1);
        _ = try self.draft.complete(ticket, &reference);
        return ticket.id;
    }
    fn remove(raw: *anyopaque, ticket: A.Ticket) !void {
        const self: *Fixture = @ptrCast(@alignCast(raw));
        self.last = ticket;
        self.calls += 1;
        if (!ticket.owner.eql(self.draft.owner) or ticket.draft_epoch != self.draft.epoch) return error.StaleAttachment;
        if (!self.draft.remove(ticket.id)) return error.StaleAttachment;
        try self.view.update(&self.draft);
    }
    fn attach(raw: *anyopaque, ticket: A.Ticket) !void {
        const self: *Fixture = @ptrCast(@alignCast(raw));
        _ = try self.draft.attach(ticket);
        self.attaches += 1;
        try self.view.update(&self.draft);
    }
    fn reselect(raw: *anyopaque, ticket: A.Ticket) !void {
        const self: *Fixture = @ptrCast(@alignCast(raw));
        self.reselects += 1;
        self.last = ticket;
        // A cancelled chooser does not mutate the ready candidate or draft.
    }
    fn stage(self: *Fixture, path: []const u8, bytes: []const u8) !A.Ticket {
        const ticket = try self.draft.begin();
        var reference = try A.ContentRef.create(a, path, bytes, 1);
        try self.draft.stage(ticket, &reference);
        return ticket;
    }
    fn settle(self: *Fixture) void {
        self.cx.setTestFrameStep(16) catch unreachable;
        for (0..16) |_| {
            self.cx.advanceFrameClock();
            self.cx.layout();
            _ = self.cx.render();
        }
    }
    fn click(self: *Fixture, node: *ui.Node) void {
        const r = node.globalRect();
        self.cx.handleMouseDown(r.x + r.w / 2, r.y + r.h / 2, .{});
        self.cx.handleMouseUp(r.x + r.w / 2, r.y + r.h / 2);
        self.settle();
    }
};
fn find(node: *ui.Node, id: []const u8) ?*ui.Node {
    if (node.meta.ownership.meta.test_id) |value| if (std.mem.eql(u8, value, id)) return node;
    for (node.children.items) |child| if (find(child, id)) |found| return found;
    return null;
}

test "AI attachments empty picker tickets do not fabricate chips and ready geometry matches live Figma R25" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    _ = try f.draft.begin();
    try f.view.update(&f.draft);
    f.settle();
    try std.testing.expectEqual(@as(f32, 0), f.view.height());
    try std.testing.expectEqual(ui.types.Display.none, f.view.root.style.display);
    _ = try f.add("/selected/incident-notes.txt", "captured file text");
    try f.view.update(&f.draft);
    f.settle();
    try std.testing.expectEqual(@as(f32, 29), f.view.height());
    const rail = f.view.rail.container.globalRect();
    try std.testing.expectEqual(@as(f32, 600), rail.w);
    try std.testing.expectEqual(@as(f32, 20), rail.h);
    const card = find(f.view.root, "ai.attachment.local_text").?;
    try std.testing.expect(card.globalRect().w < 260);
    try std.testing.expectEqual(@as(f32, 20), card.globalRect().h);
    try std.testing.expectApproxEqAbs(rail.x, card.globalRect().x, 0.1);
    const open = find(card, "ai.attachment.open").?;
    try std.testing.expectEqual(@as(f32, 14), open.globalRect().h);
    try std.testing.expectApproxEqAbs(card.globalRect().x + 6, open.globalRect().x, 0.1);
    const remove = find(card, "ai.attachment.remove").?;
    try std.testing.expectEqual(@as(f32, 18.6171875), remove.globalRect().w);
    try std.testing.expectApproxEqAbs(card.globalRect().x + card.globalRect().w - 6 - remove.globalRect().w, remove.globalRect().x, 0.1);
    try std.testing.expectEqualStrings("incident-notes.txt", find(card, "ai.attachment.filename").?.getText().?.content);
}

test "AI attachments preview uses the immutable captured bytes and keep close never adds a duplicate" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const id = try f.add("/source/selected.txt", "original snapshot\n中文");
    try f.view.update(&f.draft);
    f.settle();
    f.click(find(f.view.root, "ai.attachment.open").?);
    try std.testing.expect(f.view.isPreviewOpen());
    try expectPreviewBounds(&f);
    try std.testing.expect(f.view.preview_body.container.globalRect().h > 400);
    try std.testing.expectEqualStrings("original snapshot\n中文", f.view.preview_label.getText().?.content);
    try std.testing.expectEqualStrings("/source/selected.txt", f.view.preview_identity.getText().?.content);
    f.click(find(f.view.preview_panel, "ai.attachment.preview.keep").?);
    try std.testing.expect(!f.view.isPreviewOpen());
    try std.testing.expectEqual(@as(usize, 1), f.draft.items.items.len);
    try f.view.openPreview(id);
    f.settle();
    try std.testing.expectEqualStrings("original snapshot\n中文", f.view.preview_reference.content().?.bytes);
    f.cx.handleKeyDown(.escape, .{});
    f.settle();
    try std.testing.expect(!f.view.isPreviewOpen());
    try std.testing.expect(f.view.preview_reference.content() == null);
    try std.testing.expectEqual(@as(usize, 0), f.calls);
}

test "AI attachments remove callback keeps stable original owner epoch and ID and updates safely from the click" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const first = try f.add("/a/config.txt", "a");
    const second = try f.add("/b/config.txt", "b");
    try f.view.update(&f.draft);
    f.settle();
    f.click(find(f.view.root, "ai.attachment.remove").?);
    try std.testing.expectEqual(@as(usize, 1), f.calls);
    try std.testing.expectEqual(first, f.last.?.id);
    try std.testing.expect(f.last.?.owner.eql(.{ .session = 101 }));
    try std.testing.expectEqual(f.draft.epoch, f.last.?.draft_epoch);
    try std.testing.expectEqual(@as(usize, 1), f.draft.items.items.len);
    try std.testing.expectEqual(second, f.draft.items.items[0].id);
    try f.view.openPreview(second);
    f.settle();
    f.click(find(f.view.preview_panel, "ai.attachment.preview.remove").?);
    try std.testing.expectEqual(@as(usize, 2), f.calls);
    try std.testing.expectEqual(second, f.last.?.id);
    try std.testing.expectEqual(@as(f32, 0), f.view.height());
    try std.testing.expect(!f.view.isPreviewOpen());
}

test "AI attachments changing owner invalidates the old preview without touching either draft" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const id = try f.add("/old.txt", "old owner snapshot");
    try f.view.update(&f.draft);
    f.settle();
    try f.view.openPreview(id);
    f.settle();
    var other = try A.Draft.init(a, .{ .group = 101 });
    defer other.deinit();
    try f.view.update(&other);
    f.settle();
    try std.testing.expectEqual(@as(f32, 0), f.view.height());
    try std.testing.expect(!f.view.isPreviewOpen());
    try std.testing.expect(f.view.preview_reference.content() == null);
    try std.testing.expectEqual(@as(usize, 1), f.draft.items.items.len);
    try std.testing.expectEqual(@as(usize, 0), other.items.items.len);
    try std.testing.expectError(error.StaleAttachment, f.view.openPreview(id));
    try std.testing.expectEqual(@as(usize, 0), f.calls);
}

test "AI attachments preview resize preserves the material owned background" {
    const previous = theme.currentName();
    const parameters = theme.materialParameters();
    defer {
        theme.select(previous);
        _ = theme.setMaterialParameters(parameters.transparency, parameters.blur);
    }
    theme.select(.dark);
    _ = theme.setMaterialParameters(75, 24);
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const id = try f.add("/preview.txt", "captured");
    try f.view.update(&f.draft);
    f.settle();
    try f.view.openPreview(id);
    f.settle();
    const material = theme.layerBackground(2);
    f.view.preview_panel.setBackground(material);
    f.cx.setViewport(860, 480);
    f.settle();
    try std.testing.expectEqual(material, f.view.preview_panel.getBackground());
    try std.testing.expectEqualStrings("captured", f.view.preview_label.getText().?.content);
}

test "AI attachments horizontal rail keeps all entries on one row and theme changes retain geometry and captured preview" {
    const original_theme = theme.currentName();
    const parameters = theme.materialParameters();
    defer {
        theme.select(original_theme);
        _ = theme.setMaterialParameters(parameters.transparency, parameters.blur);
    }
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    var first: A.Id = 0;
    for (0..4) |index| {
        const id = try f.add("/source/selected.txt", "captured");
        if (index == 0) first = id;
    }
    try f.view.update(&f.draft);
    f.settle();
    const cards = f.view.rail.content.children.items;
    try std.testing.expectEqual(@as(usize, 4), cards.len);
    try std.testing.expectApproxEqAbs(cards[0].globalRect().x + cards[0].globalRect().w + 6, cards[1].globalRect().x, 0.1);
    try std.testing.expectApproxEqAbs(cards[0].globalRect().y, cards[3].globalRect().y, 0.1);
    try f.view.openPreview(first);
    f.settle();
    for (@import("config/theme_presets.zig").ids) |id| {
        theme.selectTokens(@import("config/theme_registry.zig").builtinTokens(id));
        _ = theme.setMaterialParameters(75, 24);
        f.cx.setTheme(theme.widgetTheme(theme.currentName()));
        // Match the host's theme publication, including two custom palettes
        // which share the SDK dark token pointer.
        f.cx.requestRedraw();
        f.settle();
        const card = find(f.view.root, "ai.attachment.local_text").?;
        try std.testing.expect(ui.Color.eql(theme.popupInset(), card.getBackground()));
        try std.testing.expectEqual(theme.current().overlay, f.view.preview_panel.getBackground());
        try std.testing.expectApproxEqAbs(card.globalRect().x + 6, find(card, "ai.attachment.open").?.globalRect().x, 0.1);
        try std.testing.expectEqualStrings("captured", f.view.preview_label.getText().?.content);
        try std.testing.expect(f.view.preview_body.container.globalRect().h > 400);
    }
}

test "AI attachments a long immutable preview scrolls inside its bounded bubble without growing the attachment row" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    var content: std.ArrayList(u8) = .empty;
    defer content.deinit(a);
    for (0..80) |_| try content.appendSlice(a, "captured original line\n");
    const id = try f.add("/long.log", content.items);
    try f.view.update(&f.draft);
    f.settle();
    try f.view.openPreview(id);
    f.settle();
    const body = f.view.preview_body.container.globalRect();
    f.cx.handleScroll(.{ .x = body.x + 30, .y = body.y + 30, .dx = 0, .dy = -500 });
    f.settle();
    try std.testing.expect(f.view.preview_body.state.scroll_y > 0);
    try std.testing.expect(f.view.preview_body.container.globalRect().h > 400);
    try std.testing.expectEqual(@as(f32, 25), f.view.root.globalRect().h);
    try std.testing.expectEqualStrings(content.items, f.view.preview_label.getText().?.content);
    try std.testing.expectEqual(@as(f32, 0), f.view.rail.state.scroll_y);
}

test "AI attachments long English and Chinese filenames emit clipped ellipsis paint before the remove button" {
    for ([_][]const u8{ "/tmp/zerowork-ai-native-attachment-20261021.txt", "/tmp/非常长的中文本地文本附件名称不会覆盖右侧移除按钮.txt" }) |path| {
        var f: Fixture = undefined;
        try f.init();
        defer f.deinit();
        _ = try f.add(path, "captured text");
        try f.view.update(&f.draft);
        f.settle();
        const label = find(f.view.root, "ai.attachment.filename").?;
        const remove = find(f.view.root, "ai.attachment.remove").?;
        try std.testing.expect(label.globalRect().x + label.globalRect().w < remove.globalRect().x);
        try std.testing.expectEqual(@as(f32, 180), label.globalRect().w);
        var saw_ellipsis = false;
        var saw_truncated_run = false;
        for (f.cx.render()) |item| switch (item) {
            .text_run => |run| if (run.header.node_id == label.id) {
                try std.testing.expect(run.header.clip_id != std.math.maxInt(u32));
                const clip = f.cx.property_tree.clips.items[run.header.clip_id];
                try std.testing.expect(clip.world_aabb.x <= label.globalRect().x);
                try std.testing.expect(label.globalRect().x + label.globalRect().w < remove.globalRect().x);
                try std.testing.expect(run.x < 180);
                if (std.mem.eql(u8, run.content, "…")) saw_ellipsis = true else {
                    try std.testing.expect(run.content.len < std.fs.path.basename(path).len);
                    saw_truncated_run = true;
                }
            },
            else => {},
        };
        try std.testing.expect(saw_ellipsis and saw_truncated_run);
        f.click(remove);
        try std.testing.expectEqual(@as(usize, 1), f.calls);
        try std.testing.expectEqual(@as(usize, 0), f.draft.items.items.len);
    }
}

test "AI attachments candidate preview requires explicit attach and preserves source bytes before confirmation" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const ticket = try f.stage("/candidate.txt", "candidate original snapshot");
    try f.view.update(&f.draft);
    f.settle();
    try std.testing.expectEqual(@as(f32, 0), f.view.height());
    try std.testing.expectEqual(@as(usize, 0), f.draft.items.items.len);
    try std.testing.expect(f.view.isPreviewOpen());
    try expectPreviewBounds(&f);
    try std.testing.expectEqualStrings("candidate original snapshot", f.view.preview_label.getText().?.content);
    try std.testing.expectError(error.AttachmentsProcessing, f.draft.freeze());
    f.click(find(f.view.preview_panel, "ai.attachment.preview.reselect").?);
    try std.testing.expectEqual(@as(usize, 1), f.reselects);
    try std.testing.expect(ticket.eql(f.last.?));
    try std.testing.expect(f.draft.candidate(ticket) != null);
    f.click(find(f.view.preview_panel, "ai.attachment.preview.keep").?);
    try std.testing.expectEqual(@as(usize, 1), f.attaches);
    try std.testing.expectEqual(@as(usize, 1), f.draft.items.items.len);
    try std.testing.expectEqual(@as(usize, 0), f.draft.candidates.items.len);
    try std.testing.expectEqual(@as(f32, 29), f.view.height());
    try std.testing.expect(!f.view.isPreviewOpen());
}

test "AI attachments Escape cancels only the preview candidate and preserves an existing ready attachment" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const original = try f.add("/original.txt", "original ready");
    const ticket = try f.stage("/candidate.txt", "candidate");
    try f.view.update(&f.draft);
    f.settle();
    f.cx.handleKeyDown(.escape, .{});
    f.settle();
    try std.testing.expect(!f.view.isPreviewOpen());
    try std.testing.expect(!f.draft.contains(ticket));
    try std.testing.expectEqual(@as(usize, 1), f.draft.items.items.len);
    try std.testing.expectEqual(original, f.draft.items.items[0].id);
    try std.testing.expectEqualStrings("original ready", f.draft.items.items[0].reference.content().?.bytes);
}

test "AI attachments readonly sent history previews retained original bytes after draft removal" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const id = try f.add("/sent.txt", "immutable sent original");
    var sent = try f.draft.freeze();
    defer sent.deinit();
    try f.view.updateSent(&sent);
    _ = f.draft.remove(id);
    f.settle();
    try std.testing.expectEqual(ui.types.Display.none, find(f.view.root, "ai.attachment.remove").?.style.display);
    f.click(find(f.view.root, "ai.attachment.open").?);
    try std.testing.expectEqualStrings("immutable sent original", f.view.preview_label.getText().?.content);
    try std.testing.expectEqual(ui.types.Display.none, find(f.view.preview_panel, "ai.attachment.preview.remove").?.style.display);
    try std.testing.expectEqual(ui.types.Display.none, find(f.view.preview_panel, "ai.attachment.preview.reselect").?.style.display);
    f.click(find(f.view.preview_panel, "ai.attachment.preview.keep").?);
    try std.testing.expectEqual(@as(usize, 0), f.calls);
    try std.testing.expectEqual(@as(usize, 0), f.attaches);
}

test "AI attachments switching owner dismisses a candidate view and returning restores only that owner's candidate" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const ticket = try f.stage("/original.txt", "original owner candidate");
    try f.view.update(&f.draft);
    f.settle();
    var other = try A.Draft.init(a, .{ .session = 102 });
    defer other.deinit();
    try f.view.update(&other);
    f.settle();
    try std.testing.expect(!f.view.isPreviewOpen());
    try std.testing.expect(f.draft.candidate(ticket) != null);
    try f.view.update(&f.draft);
    f.settle();
    try std.testing.expect(f.view.isPreviewOpen());
    try std.testing.expectEqualStrings("original owner candidate", f.view.preview_reference.content().?.bytes);
    try std.testing.expectEqual(@as(usize, 0), f.calls);
}

test "AI attachments sent preview scope teardown releases the portal while keeping the global material" {
    const previous_theme = theme.currentName();
    const previous_material = theme.materialVisible();
    defer {
        theme.select(previous_theme);
        _ = theme.setMaterialVisible(previous_material);
    }
    theme.select(.dark);
    _ = theme.setMaterialVisible(true);
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const id = try f.add("/history/original.txt", "original sent bytes");
    var sent = try f.draft.freeze();
    defer sent.deinit();
    const Layers = @import("ui/background_layers.zig");
    const background = try Layers.View.mount(f.cx, f.scope);
    try f.cx.root.?.insertChildBefore(a, background.root, f.cx.root.?.children.items[0]);
    try background.update(.{ .id = 777, .width = 640, .height = 256 }, .{ .background = .{ .enabled = true, .path = "/fixture", .transparency = 50 } }, 1200, 900);
    for (0..3) |_| {
        const history_scope = try f.scope.childScope();
        var scope_live = true;
        defer if (scope_live) history_scope.dispose();
        const view = try V.View.mount(f.cx, history_scope, .{ .context = &f });
        const root = view.root;
        root.setStyleInline(a, .{ .position = .absolute, .inset = .{ .left = .{ .px = 100 }, .top = .{ .px = 380 } }, .width = .{ .px = 600 } });
        try f.cx.root.?.appendChild(a, root);
        try background.isolate(view.preview_scope, view.preview_panel);
        try view.updateSent(&sent);
        f.settle();
        try view.openPreview(id);
        f.settle();
        try std.testing.expectEqualStrings("original sent bytes", view.preview_reference.content().?.bytes);
        try std.testing.expect(find(view.preview_panel, "appearance.surface") == null);
        f.cx.setFocus(view.preview_primary);
        // This is the host safe-point order: release hooks/focus/portals while
        // their nodes still exist, then detach and destroy the history row.
        history_scope.dispose();
        scope_live = false;
        try std.testing.expect(f.cx.focus_manager.current_focus == null);
        f.cx.detachChild(f.cx.root.?, root);
        f.cx.destroyDetached(root);
        f.settle();
    }
    try std.testing.expectEqualStrings("original sent bytes", sent.items[0].reference.content().?.bytes);
}

test "AI attachments V3 context modal preserves source and independent body scroll from inline host" {
    const old_theme = theme.currentName();
    defer theme.select(old_theme);
    var f: Fixture = undefined;
    try f.initInline();
    defer f.deinit();
    try std.testing.expect(f.view.popup == null);
    _ = try f.stage("/candidate.txt", "captured inline candidate");
    try f.view.update(&f.draft);
    f.settle();
    const panel = f.view.preview_panel;
    try std.testing.expect(!panel.isDescendantOf(f.inline_holder.?));
    try std.testing.expect(f.view.modal != null);
    try std.testing.expect(f.view.isPreviewOpen());
    try std.testing.expectEqual(ui.types.Display.none, f.view.root.style.display);
    try std.testing.expectApproxEqAbs(f.cx.viewport.width * 0.11, panel.globalRect().x, 0.1);
    try std.testing.expect(panel.globalRect().y >= 16);
    try expectPreviewBounds(&f);
    try std.testing.expect(panel.globalRect().h >= 260);
    try std.testing.expect(f.view.preview_body.container.globalRect().h > 400);
    try std.testing.expect(f.view.preview_body.container.globalRect().y > panel.globalRect().y);
    try std.testing.expectEqual(theme.current().overlay, panel.getBackground());
    try std.testing.expectEqualStrings("captured inline candidate", f.view.preview_reference.content().?.bytes);
    for ([_]theme.Name{ .light, .dark, .sauber }) |name| {
        theme.select(name);
        f.cx.setTheme(theme.widgetTheme(name));
        f.cx.requestRedraw();
        f.settle();
        try std.testing.expectEqual(ui.types.Display.none, f.conversation.?.style.display);
        try std.testing.expectEqual(ui.types.Display.flex, f.inline_holder.?.style.display);
        try std.testing.expectEqual(theme.current().overlay, panel.getBackground());
    }
    f.click(find(panel, "ai.attachment.preview.keep").?);
    try std.testing.expectEqual(@as(usize, 1), f.attaches);
    try std.testing.expect(!f.view.isPreviewOpen());
    try std.testing.expect(!f.view.modal_open.?.peek());
    for (f.cx.overlay_stack.layers) |slot| if (slot) |layer| {
        if (layer.content_node == panel) try std.testing.expect(layer.suspended);
    };
    for ([_]theme.Name{ .dark, .light, .sauber }) |name| {
        theme.select(name);
        f.cx.setTheme(theme.widgetTheme(name));
        f.cx.requestRedraw();
        f.settle();
        try std.testing.expect(!f.view.modal_open.?.peek());
        for (f.cx.overlay_stack.layers) |slot| if (slot) |layer| {
            if (layer.content_node == panel) try std.testing.expect(layer.suspended);
        };
    }
    try f.view.openPreview(f.draft.items.items[0].id);
    f.settle();
    f.cx.handleKeyDown(.escape, .{});
    f.settle();
    try std.testing.expect(!f.view.isPreviewOpen());
    try std.testing.expectEqual(@as(usize, 1), f.draft.items.items.len);
}

test "AI attachments restore pending candidate before layout using the same owner projection" {
    var f: Fixture = undefined;
    try f.initInline();
    defer f.deinit();
    const ticket = try f.stage("/original/pending.txt", "pending snapshot before first layout");
    try f.view.update(&f.draft);
    // Main's stageRemote calls these consecutively before the safe layout hook.
    try f.view.restoreCandidate(.{ .group = 101 });
    try std.testing.expect(!f.view.isPreviewOpen());
    try f.view.restoreCandidate(f.draft.owner);
    try std.testing.expect(f.view.isPreviewOpen());
    try std.testing.expectEqualStrings("pending snapshot before first layout", f.view.preview_reference.content().?.bytes);
    try std.testing.expect(f.draft.candidate(ticket) != null);
    f.settle();
    try std.testing.expect(f.view.isPreviewOpen());
}

test "AI attachments collapsing inline preview preserves the candidate and reopening restores only its original owner" {
    var f: Fixture = undefined;
    try f.initInline();
    defer f.deinit();
    const ticket = try f.stage("/original/candidate.txt", "original candidate across presentation close");
    try f.view.update(&f.draft);
    f.settle();
    f.view.dismiss();
    f.settle();
    try std.testing.expect(!f.view.isPreviewOpen());
    try std.testing.expect(f.draft.candidate(ticket) != null);
    try f.view.restoreCandidate(.{ .group = 101 });
    f.settle();
    try std.testing.expect(!f.view.isPreviewOpen());
    try f.view.restoreCandidate(f.draft.owner);
    f.settle();
    try std.testing.expect(f.view.isPreviewOpen());
    try std.testing.expectEqualStrings("original candidate across presentation close", f.view.preview_reference.content().?.bytes);
    f.cx.handleKeyDown(.escape, .{});
    f.settle();
    try std.testing.expect(!f.draft.contains(ticket));
    try std.testing.expectEqual(@as(usize, 0), f.draft.items.items.len);
}

test "AI attachments sent history forwards original content into stable inline preview and survives rebuilding the history scope" {
    var f: Fixture = undefined;
    try f.initInline();
    defer f.deinit();
    const id = try f.add("/sent/original.txt", "sent original across history rebuild");
    var sent = try f.draft.freeze();
    defer sent.deinit();
    try f.view.update(&f.draft);
    f.settle();
    const Forward = struct {
        view: *V.View,
        calls: usize = 0,
        ticket: ?A.Ticket = null,
        fn preview(raw: *anyopaque, ticket: A.Ticket, reference: A.ContentRef) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.calls += 1;
            self.ticket = ticket;
            try self.view.openSentPreview(ticket, reference);
        }
    };
    var forward: Forward = .{ .view = f.view };
    const history_scope = try f.scope.childScope();
    var scope_live = true;
    defer if (scope_live) history_scope.dispose();
    const history_view = try V.View.mount(f.cx, history_scope, .{ .context = &forward, .preview_sent = Forward.preview });
    const history_root = history_view.root;
    history_root.setStyleInline(a, .{ .position = .absolute, .inset = .{ .left = .{ .px = 100 }, .top = .{ .px = 600 } }, .width = .{ .px = 600 } });
    try f.cx.root.?.appendChild(a, history_root);
    try history_view.updateSent(&sent);
    try std.testing.expect(f.draft.remove(id));
    try f.view.update(&f.draft);
    f.settle();
    f.click(find(history_root, "ai.attachment.open").?);
    try std.testing.expectEqual(@as(usize, 1), forward.calls);
    try std.testing.expectEqual(id, forward.ticket.?.id);
    try std.testing.expect(f.view.isPreviewOpen());
    try std.testing.expect(!history_view.isPreviewOpen());
    try std.testing.expectEqualStrings("sent original across history rebuild", f.view.preview_reference.content().?.bytes);
    history_scope.dispose();
    scope_live = false;
    f.cx.detachChild(f.cx.root.?, history_root);
    f.cx.destroyDetached(history_root);
    f.settle();
    try std.testing.expectEqualStrings("sent original across history rebuild", f.view.preview_reference.content().?.bytes);
    try std.testing.expectEqual(ui.types.Display.none, find(f.view.preview_panel, "ai.attachment.preview.remove").?.style.display);
    try std.testing.expectEqual(ui.types.Display.none, find(f.view.preview_panel, "ai.attachment.preview.reselect").?.style.display);
    f.cx.handleKeyDown(.escape, .{});
    f.settle();
    try std.testing.expect(!f.view.isPreviewOpen());
    try std.testing.expectEqual(@as(usize, 0), f.draft.items.items.len);
}

test "local file selection captures text and images but only references binary and non-UTF8 data" {
    const capture = @import("host/ai_local_file_snapshot.zig");
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var token: @import("ai/provider.zig").CancelToken = .{};
    for ([_]struct { name: []const u8, bytes: []const u8, reference: bool }{
        .{ .name = "plain.bin", .bytes = "UTF-8 文本", .reference = false },
        .{ .name = "archive.txt", .bytes = "PK\x03\x04private binary bytes", .reference = true },
        .{ .name = "document.pdf", .bytes = "%PDF-1.7\nprivate PDF content", .reference = true },
        .{ .name = "unknown.dat", .bytes = "\xff\xfe\xfa", .reference = true },
    }) |fixture| {
        try tmp.dir.writeFile(io, .{ .sub_path = fixture.name, .data = fixture.bytes });
        const path = try tmp.dir.realPathFileAlloc(io, fixture.name, a);
        defer a.free(path);
        var selected = try capture.capture(a, io, path, &token);
        defer selected.release();
        const content = selected.file.content().?;
        try std.testing.expectEqual(fixture.reference, content.source == .local_reference);
        try std.testing.expectEqualStrings(if (fixture.reference) "" else fixture.bytes, content.bytes);
        try std.testing.expectEqualStrings(path, content.path);
    }
    const png = "\x89PNG\r\n\x1a\n\x00\x00\x00\x0dIHDR" ++
        "\x00\x00\x00\x01\x00\x00\x00\x01\x08\x06\x00\x00\x00\x1f\x15\xc4\x89" ++
        "\x00\x00\x00\x0dIDAT\x78\x9c\x63\xf8\xcf\xc0\xf0\x1f\x00\x05\x00\x01\xff\x89\x99\x3d\x1d" ++
        "\x00\x00\x00\x00IEND\xae\x42\x60\x82";
    try tmp.dir.writeFile(io, .{ .sub_path = "image.txt", .data = png });
    const image_path = try tmp.dir.realPathFileAlloc(io, "image.txt", a);
    defer a.free(image_path);
    var image = try capture.capture(a, io, image_path, &token);
    defer image.release();
    try std.testing.expect(image == .image);
    try std.testing.expectEqualStrings(png, image.image.content().?.bytes);
    try tmp.dir.writeFile(io, .{ .sub_path = "image.txt", .data = png[0..20] });
    try std.testing.expectError(error.InvalidImage, capture.capture(a, io, image_path, &token));
    token.cancel();
    try std.testing.expectError(error.Cancelled, capture.capture(a, io, image_path, &token));
}

test "local file selection bounds binary reads and preserves source across persistence and remote prompts" {
    const capture = @import("host/ai_local_file_snapshot.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(std.testing.io, "large.iso", .{});
    try file.setLength(std.testing.io, 16 * 1024 * 1024 * 1024);
    file.close(std.testing.io);
    const path = try tmp.dir.realPathFileAlloc(std.testing.io, "large.iso", a);
    defer a.free(path);
    var token: @import("ai/provider.zig").CancelToken = .{};
    var selected = try capture.capture(a, std.testing.io, path, &token);
    defer selected.release();
    const content = selected.file.content().?;
    try std.testing.expect(content.source == .local_reference);
    try std.testing.expectEqual(@as(usize, 0), content.bytes.len);
    const encoded = try std.json.Stringify.valueAlloc(a, content, .{});
    defer a.free(encoded);
    const parsed = try std.json.parseFromSlice(A.Content, a, encoded, .{});
    defer parsed.deinit();
    var restored = try A.ContentRef.restore(a, parsed.value);
    defer restored.release();
    var draft = try A.Draft.init(a, .{ .session = 777 }); // An SSH assistant still gets a host-local locator.
    defer draft.deinit();
    const ticket = try draft.begin();
    _ = try draft.complete(ticket, &restored);
    var bundle = try draft.freeze();
    defer bundle.deinit();
    const wire = try @import("ai/local_text_request.zig").compose(a, "inspect", &bundle, 4096);
    defer a.free(wire);
    for ([_][]const u8{ "<local_file_reference>", "source_kind=host_local", "source_name=本机", path, "Never pass this path to SSH", "If no host-local tool is available", "reason=size_limit", "file_size_bytes=17179869184", "content_limit_bytes=10000000", "reference_only=true", "content_included=false", "suggested_max_read_bytes=4096", "Do not automatically read, load, upload or decode the entire file", "do not automatically paginate through the entire file" }) |expected| try std.testing.expect(std.mem.indexOf(u8, wire, expected) != null);
    try std.testing.expect(std.mem.indexOf(u8, wire, "<remote_file_reference>") == null);
    try std.testing.expectError(error.InvalidAttachmentPath, A.ContentRef.createLocalReference(a, "relative.iso", .{}));
}

test "local file reference preview names the host and explains binary and encoding failures" {
    var f: Fixture = undefined;
    try f.initInline();
    defer f.deinit();
    for ([_]A.LocalReference{ .{}, .{ .reason = .encoding }, .{ .reason = .size_limit }, .{ .reason = .text_limit }, .{ .reason = .image_limit }, .{ .reason = .image_count } }) |reason| {
        const ticket = try f.draft.begin();
        var reference = try A.ContentRef.createLocalReference(a, "/tmp/local-fixture.iso", reason);
        _ = try f.draft.complete(ticket, &reference);
        try f.view.update(&f.draft);
        f.settle();
        try f.view.openPreview(ticket.id);
        f.settle();
        try std.testing.expectEqualStrings("本机文件引用", f.view.preview_title.getText().?.content);
        const explanation = f.view.preview_label.getText().?.content;
        try std.testing.expect(std.mem.indexOf(u8, explanation, switch (reason.reason) {
            .binary => "二进制",
            .encoding => "UTF-8",
            .size_limit => "大小限制",
            .text_limit => "64 KiB",
            .image_limit => "像素限制",
            .image_count => "数量",
        }) != null);
        try std.testing.expect(std.mem.indexOf(u8, explanation, "本机绝对路径") != null);
        f.view.dismiss();
    }
}

test "local file limits attach references for oversized text image bytes and image dimensions" {
    const capture = @import("host/ai_local_file_snapshot.zig");
    const images = @import("ai/image_attachments.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var token: @import("ai/provider.zig").CancelToken = .{};
    const text = try a.alloc(u8, A.max_bytes + 1);
    defer a.free(text);
    @memset(text, 't');
    for ([_]usize{ A.max_bytes, text.len }) |size| {
        try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "selected.log", .data = text[0..size] });
        const path = try tmp.dir.realPathFileAlloc(std.testing.io, "selected.log", a);
        defer a.free(path);
        var selected = try capture.capture(a, std.testing.io, path, &token);
        defer selected.release();
        const content = selected.file.content().?;
        if (size == A.max_bytes) {
            try std.testing.expect(content.source == .local_file);
            try std.testing.expectEqual(size, content.bytes.len);
        } else {
            try std.testing.expect(content.source.local_reference.reason == .text_limit);
            try std.testing.expectEqual(@as(?u64, A.max_bytes + 1), content.source.local_reference.size_bytes);
            try std.testing.expectEqual(@as(usize, 0), content.bytes.len);
            var draft = try A.Draft.init(a, .{ .session = 101 });
            defer draft.deinit();
            const ticket = try draft.begin();
            var incoming = selected.file.retain();
            _ = try draft.complete(ticket, &incoming);
            var bundle = try draft.freeze();
            defer bundle.deinit();
            const wire = try @import("ai/local_text_request.zig").compose(a, "inspect", &bundle, 4096);
            defer a.free(wire);
            for ([_][]const u8{ "reason=text_limit", "file_size_bytes=65537", "content_limit_bytes=65536", "Do not automatically read", "at most 4096 bytes per call" }) |expected| try std.testing.expect(std.mem.indexOf(u8, wire, expected) != null);
            try std.testing.expect(std.mem.indexOf(u8, wire, text[0..256]) == null);
        }
    }
    const encoded = "iVBORw0KGgoAAAANSUhEUgAAIygAAAABCAYAAACzIwVFAAAAPUlEQVR4nO3DQQ0AAAwDofNvurOxByS0mqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqr64wFXfA3LIKy7pwAAAABJRU5ErkJggg==";
    var png: [118]u8 = undefined;
    try std.base64.standard.Decoder.decode(&png, encoded);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "wide.png", .data = &png });
    const image_path = try tmp.dir.realPathFileAlloc(std.testing.io, "wide.png", a);
    defer a.free(image_path);
    var wide = try capture.capture(a, std.testing.io, image_path, &token);
    defer wide.release();
    try std.testing.expect(wide.file.content().?.source.local_reference.reason == .image_limit);
    try std.testing.expectEqual(@as(?u64, png.len), wide.file.content().?.source.local_reference.size_bytes);
    const file = try tmp.dir.openFile(std.testing.io, "wide.png", .{ .mode = .read_write });
    try file.setLength(std.testing.io, images.max_bytes + 1);
    file.close(std.testing.io);
    var huge = try capture.capture(a, std.testing.io, image_path, &token);
    defer huge.release();
    try std.testing.expect(huge.file.content().?.source.local_reference.reason == .size_limit);
    try std.testing.expectEqual(@as(usize, 0), huge.file.content().?.bytes.len);
}

test "file type icons follow local and remote attachments, preview and sent history across themes" {
    const icons = @import("ui/file_workspace_icons.zig");
    const old_theme = theme.currentName();
    defer theme.select(old_theme);
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const iso = try f.draft.begin();
    var local = try A.ContentRef.createLocalReference(a, "/Rocky-8.10-x86_64-dvd1.iso", .{ .reason = .binary });
    defer local.release();
    _ = try f.draft.complete(iso, &local);
    const pdf = try f.draft.begin();
    var remote = try A.ContentRef.createRemoteReference(a, .{ .session_id = @fromBackingInt(301), .generation = 7 }, "SFTP", "/report.PDF");
    defer remote.release();
    _ = try f.draft.complete(pdf, &remote);
    _ = try f.add("/main.rs", "fn main() {}");
    var sent = try f.draft.freeze();
    defer sent.deinit();
    try f.view.update(&f.draft);
    f.settle();
    for ([_]bool{ false, true }) |history| {
        if (history) {
            try f.view.updateSent(&sent);
            f.settle();
        }
        for ([_]theme.Name{ .light, .dark, .sauber }) |name| {
            theme.select(name);
            f.cx.setTheme(theme.widgetTheme(name));
            f.settle();
            if (f.view.preview_reference.content()) |content| {
                try std.testing.expectEqual(icons.asset(content.path).icon_id.?, f.view.preview_icon.getIcon().?.icon_id);
                try std.testing.expectEqual(icons.color(content.path), f.view.preview_icon.getIcon().?.tint);
            }
            for (f.view.cards.items, sent.items) |card, item| {
                const path = item.reference.content().?.path;
                const icon = card.icons[0].getIcon().?;
                try std.testing.expectEqual(icons.asset(path).icon_id.?, icon.icon_id);
                try std.testing.expectEqual(icons.color(path), icon.tint);
            }
            try f.view.openPreview(iso.id);
            f.settle();
            try std.testing.expectEqual(icons.asset("Rocky.iso").icon_id.?, f.view.preview_icon.getIcon().?.icon_id);
            try std.testing.expectEqual(icons.color("Rocky.iso"), f.view.preview_icon.getIcon().?.tint);
            try f.view.openPreview(pdf.id);
            f.settle();
            try std.testing.expectEqual(icons.asset("report.pdf").icon_id.?, f.view.preview_icon.getIcon().?.icon_id);
            try std.testing.expectEqual(icons.color("report.pdf"), f.view.preview_icon.getIcon().?.tint);
        }
    }
}
