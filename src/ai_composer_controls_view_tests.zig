const std = @import("std");
const ui = @import("ui");
const Controls = @import("ui/ai_composer_controls_view.zig");
const Styles = @import("ui/ai_composer_controls_styles.zig");
const config = @import("config/config.zig");
const a = std.testing.allocator;
const Fixture = struct {
    cx: *ui.Cx,
    scope: *ui.Scope,
    view: *Controls.View,
    panel: *ui.Node,
    send: *ui.Node,
    models: [2]config.AiModel,
    disabled_models: [1]config.AiModel,
    providers: [2]config.AiProvider,
    owned: std.heap.ArenaAllocator,
    calls: usize = 0,
    last: ?Controls.Envelope = null,
    reject: bool = false,
    fn init(self: *Fixture) !void {
        self.* = .{ .cx = try ui.Cx.init(a, std.testing.io), .scope = undefined, .view = undefined, .panel = undefined, .send = undefined, .models = .{ .{ .id = "alpha", .context_window = 200000, .reasoning = true, .vision = true, .efforts = .{ true, false, true, false, false, false, false } }, .{ .id = "quiet", .context_window = 32000, .efforts = @splat(false) } }, .disabled_models = .{.{ .id = "ghost", .efforts = @splat(false) }}, .providers = undefined, .owned = .init(a) };
        self.providers = .{ .{ .name = "lab", .enabled = true, .endpoint = "https://fixture.invalid/v1", .api_key = "fixture", .model_count = 2, .models = &self.models }, .{ .name = "offline", .enabled = false, .models = &self.disabled_models, .model_count = 1 } };
        self.cx.setViewport(1440, 900);
        self.cx.root = try ui.box(self.cx, .{ .width = .fill(), .height = .fill() }, .{});
        self.scope = try ui.Scope.init(a, null, self.cx.owner);
        self.panel = try ui.box(self.cx, .{ .position = .absolute, .inset = .{ .left = .{ .px = 100 }, .top = .{ .px = 100 } }, .width = .{ .px = 600 }, .height = .{ .px = 420 } }, .{});
        try self.cx.root.?.appendChild(a, self.panel);
        self.view = try Controls.View.mount(self.cx, self.scope, .{ .context = self, .action = action });
        self.view.root.setStyleInline(a, .{ .position = .absolute, .inset = .{ .left = .{ .px = 14 }, .top = .{ .px = 384 } }, .width = .{ .px = 572 } });
        try self.panel.appendChild(a, self.view.root);
        self.send = try ui.widgets.Button(.{ .a11y_label = "发送", .base_style = ui.BoxStyle{ .width = .{ .px = 28 }, .height = .{ .px = 28 }, .padding = .{} } }).mount(self.scope, self.cx);
        try self.view.trailing.appendChild(a, self.send);
        try self.view.update(self.snapshot());
        self.settle();
    }
    fn snapshot(self: *Fixture) Controls.Snapshot {
        return .{ .owner = .{ .session = 101 }, .revision = 1, .providers = &self.providers, .current = .{ .provider_id = "lab", .model_id = "alpha" }, .permission = .confirm, .effort = .high, .attachments = .{ .image = true, .local_text = true } };
    }
    fn deinit(self: *Fixture) void {
        self.scope.dispose();
        self.cx.deinit();
        self.owned.deinit();
    }
    fn action(raw: *anyopaque, value: Controls.Envelope) !void {
        const self: *Fixture = @ptrCast(@alignCast(raw));
        if (self.reject) return error.FixtureRejected;
        var copy = value;
        switch (value.action) {
            .model => |key| copy.action = .{ .model = try self.cloneKey(key) },
            .effort => |effort| copy.action = .{ .effort = .{ .model = try self.cloneKey(effort.model), .value = effort.value } },
            else => {},
        }
        self.last = copy;
        self.calls += 1;
    }
    fn cloneKey(self: *Fixture, value: Controls.ModelKey) !Controls.ModelKey {
        return .{ .provider_id = try self.owned.allocator().dupe(u8, value.provider_id), .model_id = try self.owned.allocator().dupe(u8, value.model_id) };
    }
    fn settle(self: *Fixture) void {
        self.cx.setTestFrameStep(16) catch unreachable;
        for (0..20) |_| {
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
    fn enter(self: *Fixture, node: *ui.Node) void {
        self.cx.setFocus(node);
        self.cx.handleKeyDown(.@"return", .{});
        self.settle();
    }
};
fn find(node: *ui.Node, id: []const u8) ?*ui.Node {
    if (node.meta.ownership.meta.test_id) |value| if (std.mem.eql(u8, value, id)) return node;
    for (node.children.items) |child| if (find(child, id)) |result| return result;
    return null;
}
fn hasText(node: *ui.Node, value: []const u8) bool {
    if (node.getText()) |text| if (std.mem.eql(u8, text.content, value)) return true;
    for (node.children.items) |child| if (hasText(child, value)) return true;
    return false;
}
fn modelOption(node: *ui.Node, name: []const u8) ?*ui.Node {
    if (node.meta.ownership.meta.test_id) |id| if (std.mem.eql(u8, id, "ai.model.option")) {
        if (hasText(node, name)) return node;
    };
    for (node.children.items) |child| if (modelOption(child, name)) |result| return result;
    return null;
}

test "AI composer controls match the V3 compact row and retain the host send slot" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const row = f.view.root.globalRect();
    const chip_width = f.view.buttons[2].globalRect().w;
    const positions = [_]f32{ 0, 32, 138, 0, 146 + chip_width };
    const widths = [_]f32{ 24, 98, chip_width, 0, 38 };
    for (f.view.buttons, 0..) |button, index| {
        if (index == 3) {
            try std.testing.expect(button.style.display == .none);
            continue;
        }
        const r = button.globalRect();
        try std.testing.expectApproxEqAbs(row.x + positions[index], r.x, 0.1);
        try std.testing.expectEqual(widths[index], r.w);
        try std.testing.expectEqual(@as(f32, 24), r.h);
        try std.testing.expectApproxEqAbs(row.y + 2, r.y, 0.1);
    }
    try std.testing.expectApproxEqAbs(row.x + 544, f.send.globalRect().x, 0.1);
    try std.testing.expectEqual(@as(f32, 28), f.send.globalRect().h);
    try std.testing.expectApproxEqAbs(row.x + 40, f.view.icons[1].globalRect().x, 0.1);
    try std.testing.expectApproxEqAbs(row.x + 56, f.view.labels[1].?.globalRect().x, 0.1);
    try std.testing.expectApproxEqAbs(row.x + 162, f.view.labels[2].?.globalRect().x, 0.1);
    const vision = find(f.view.buttons[2], "ai.composer.model.vision") orelse return error.MissingVisionIcon;
    try std.testing.expectEqual(@as(f32, 12), vision.globalRect().w);
    try std.testing.expectEqual(@as(f32, 12), vision.globalRect().h);
    try std.testing.expectApproxEqAbs(row.x + 146, vision.globalRect().x, 0.1);
    try std.testing.expectEqualStrings("支持图片输入与识图", vision.behavior.interaction.a11y.?.label.?);
    try std.testing.expectEqual(@as(f32, 12), f.view.icons[1].globalRect().w);
    try std.testing.expectEqual(@as(f32, 10), f.view.labels[2].?.getText().?.font_size);
    try std.testing.expectEqual(@as(u16, 400), f.view.labels[2].?.getText().?.font_weight);
    try std.testing.expectApproxEqAbs(row.x + 110, f.view.chevrons[0].globalRect().x, 0.1);
    try std.testing.expectApproxEqAbs(row.x + 138 + chip_width - 20, f.view.chevrons[1].globalRect().x, 0.1);
    try std.testing.expectApproxEqAbs(row.x + 154 + chip_width, f.view.ring.globalRect().x, 0.1);
    try std.testing.expectApproxEqAbs(f.view.labels[2].?.globalRect().x + f.view.labels[2].?.globalRect().w + 4, f.view.labels[3].?.globalRect().x, 0.1);
    try std.testing.expect(chip_width < 190);
    try std.testing.expectEqualStrings("alpha", f.view.labels[2].?.getText().?.content);
    try std.testing.expectEqualStrings("高", f.view.labels[3].?.getText().?.content);
    try std.testing.expectEqualStrings("—", f.view.labels[4].?.getText().?.content);
    try std.testing.expect(f.view.disabled[4].peek());
    try std.testing.expectEqual(@as(usize, 0), f.calls);
}

test "AI composer grouped model list uses configured capabilities and a captured typed selection awaiting acknowledgement" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    f.click(f.view.buttons[2]);
    const menu = find(f.cx.root.?, "ai.model.menu").?;
    const r = menu.globalRect();
    try std.testing.expectEqual(@as(f32, 336), r.w);
    try std.testing.expectEqual(@as(f32, 321.5), r.h);
    try std.testing.expectApproxEqAbs(f.view.buttons[2].globalRect().x, r.x, 0.1);
    try std.testing.expectApproxEqAbs(f.view.buttons[2].globalRect().y - 6, r.y + r.h, 0.1);
    try std.testing.expectEqual(@as(usize, 5), f.view.model_rows.items.len);
    try std.testing.expect(f.view.isOpen());
    const quiet = modelOption(menu, "quiet") orelse return error.MissingConfiguredModel;
    f.enter(quiet);
    try std.testing.expect(f.last.?.owner.eql(.{ .session = 101 }));
    try std.testing.expectEqualStrings("lab", f.last.?.action.model.provider_id);
    try std.testing.expectEqualStrings("quiet", f.last.?.action.model.model_id);
    try std.testing.expectEqualStrings("alpha", f.view.labels[2].?.getText().?.content);
    var accepted = f.snapshot();
    accepted.current = .{ .provider_id = "lab", .model_id = "quiet" };
    try f.view.update(accepted);
    f.settle();
    try std.testing.expectEqualStrings("quiet", f.view.labels[2].?.getText().?.content);
    try std.testing.expect(f.view.disabled[3].peek());
    try std.testing.expectEqualStrings("不支持推理", f.view.labels[3].?.getText().?.content);
    try std.testing.expectEqual(.none, f.view.labels[3].?.style.display);
}

test "AI composer vision icon follows selected model capability" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const icon = f.view.model_vision;
    try std.testing.expectEqual(ui.icons.get("image").?.icon_id.?, icon.getIcon().?.icon_id);
    var next = f.snapshot();
    next.current = .{ .provider_id = "lab", .model_id = "quiet" };
    next.effort = null;
    try f.view.update(next);
    f.settle();
    try std.testing.expectEqual(.none, f.view.model_vision_hint.wrapper.style.display);
    try std.testing.expectEqual(.flex, f.view.model_text_icon.style.display);
    try std.testing.expectEqual(ui.icons.get("brain").?.icon_id.?, f.view.model_text_icon.getIcon().?.icon_id);
    try std.testing.expectApproxEqAbs(f.view.buttons[2].globalRect().x + 24, f.view.labels[2].?.globalRect().x, 0.1);
    try std.testing.expect(!f.view.model_vision_hint.open.?.peek());
}

test "AI composer permission labels preserve real confirm and auto modes and only update on host acknowledgement" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    f.enter(f.view.buttons[1]);
    const menu = find(f.cx.root.?, "ai.permission.menu").?;
    try std.testing.expectEqual(@as(f32, 344), menu.globalRect().w);
    try std.testing.expectEqual(@as(f32, 194), menu.globalRect().h);
    f.enter(find(menu, "ai.permission.auto").?);
    try std.testing.expectEqual(Controls.PermissionMode.auto, f.last.?.action.permission);
    try std.testing.expectEqualStrings("确认后执行", f.view.labels[1].?.getText().?.content);
    var accepted = f.snapshot();
    accepted.permission = .auto;
    try f.view.update(accepted);
    f.settle();
    try std.testing.expectEqualStrings("自动执行", f.view.labels[1].?.getText().?.content);
    try std.testing.expectEqualStrings("自动执行", f.view.buttons[1].behavior.interaction.a11y.?.label.?);
}

test "AI composer effort is a real slider whose keyboard skips unsupported model steps" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    f.enter(f.view.buttons[2]);
    const menu = find(f.cx.root.?, "ai.model.menu").?;
    try std.testing.expectEqual(@as(f32, 336), menu.globalRect().w);
    try std.testing.expectEqual(@as(f32, 321.5), menu.globalRect().h);
    try std.testing.expectEqual(@as(f32, 266), f.view.slider_track.globalRect().w);
    try std.testing.expect(ui.Color.eql(Styles.theme.current().accent, f.view.slider_thumb.getBackground()));
    try std.testing.expectEqual(@as(usize, 2), f.view.reasoning_count);
    for (f.view.slider_markers[0..2], 0..) |marker, index| {
        try std.testing.expectEqual(@as(f32, 4), marker.globalRect().w);
        try std.testing.expectApproxEqAbs(f.view.slider_track.globalRect().x - 2 + @as(f32, @floatFromInt(index)) * f.view.slider_track.globalRect().w, marker.globalRect().x, 0.1);
    }
    f.cx.setFocus(f.view.slider.wrapper);
    f.cx.handleKeyDown(.left, .{});
    f.settle();
    try std.testing.expectEqual(Controls.Effort.low, f.last.?.action.effort.value);
    try std.testing.expectEqualStrings("alpha", f.last.?.action.effort.model.model_id);
    try std.testing.expectEqual(@as(f32, 4), f.view.slider_value.peek());
    var accepted = f.snapshot();
    accepted.effort = .low;
    try f.view.update(accepted);
    f.settle();
    try std.testing.expect(f.view.isOpen());
    try std.testing.expectEqual(@as(f32, 0), f.view.slider_value.peek());
    try std.testing.expectEqualStrings("低", f.view.labels[3].?.getText().?.content);
    f.cx.setFocus(f.view.slider.wrapper);
    f.cx.handleKeyDown(.end, .{});
    f.settle();
    try std.testing.expectEqual(Controls.Effort.high, f.last.?.action.effort.value);
    try std.testing.expect(f.view.effort_ticks[4].style.display == .none);
    accepted.current = .{ .provider_id = "lab", .model_id = "quiet" };
    try f.view.update(accepted);
    f.settle();
    try std.testing.expect(f.view.isOpen());
    try std.testing.expect(f.view.disabled[3].peek());
}

test "AI composer identical polling preserves open list and Escape restores its trigger" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    f.enter(f.view.buttons[2]);
    const version = f.view.model_version.peek();
    for (0..5) |_| try f.view.update(f.snapshot());
    f.settle();
    try std.testing.expectEqual(version, f.view.model_version.peek());
    try std.testing.expect(f.cx.focus_manager.current_focus == f.view.model_close);
    f.cx.handleKeyDown(.escape, .{});
    f.settle();
    try std.testing.expect(!f.view.isOpen());
    try std.testing.expect(f.cx.focus_manager.current_focus == f.view.buttons[2]);
}

test "AI composer minimum float width retains every control and only supported pointer effort is emitted" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    f.panel.setStyleInline(a, .{ .width = .{ .px = 520 } });
    f.view.root.setStyleInline(a, .{ .width = .{ .px = 492 } });
    f.settle();
    const row = f.view.root.globalRect();
    try std.testing.expectApproxEqAbs(row.x + row.w - 28, f.send.globalRect().x, 0.1);
    try std.testing.expect(f.view.buttons[4].globalRect().x + 68 < f.send.globalRect().x);
    f.click(f.view.buttons[2]);
    const area = f.view.slider.wrapper.children.items[0].globalRect();
    f.cx.handleMouseDown(area.x + area.w * 0.3, area.y + area.h / 2, .{});
    f.cx.handleMouseUp(area.x + area.w * 0.3, area.y + area.h / 2);
    f.settle();
    const accepted = f.last.?.action.effort.value;
    try std.testing.expect(accepted == .low or accepted == .high);
    try std.testing.expectEqual(@as(f32, 4), f.view.slider_value.peek());
}

test "AI composer attachment menu enables only actual hooks and never manufactures an attachment" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    f.click(f.view.buttons[0]);
    const menu = find(f.cx.root.?, "ai.attachment.menu").?;
    try std.testing.expectEqual(@as(f32, 300), menu.globalRect().w);
    try std.testing.expectEqual(@as(f32, 166), menu.globalRect().h);
    try std.testing.expect(f.view.attachment_disabled[2].peek());
    try std.testing.expect(f.view.attachment_disabled[3].peek());
    f.click(find(menu, "ai.attachment.remote_file").?);
    try std.testing.expectEqual(@as(usize, 0), f.calls);
    f.enter(find(menu, "ai.attachment.local_text").?);
    try std.testing.expectEqual(Controls.Attachment.local_text, f.last.?.action.attachment);
    try std.testing.expectEqual(@as(usize, 0), f.view.source.?.value.attachments.count);
    var updated = f.snapshot();
    updated.attachments = .{};
    try f.view.update(updated);
    f.settle();
    try std.testing.expect(f.view.disabled[0].peek());
}

test "AI composer usage and ring reflect only provided measurements and source labels are owned" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    var label = [_]u8{ 'h', 'i', 's', 't', 'o', 'r', 'y' };
    const parts = [_]Controls.UsagePart{.{ .name = &label, .tokens = 42000 }};
    var measured = f.snapshot();
    measured.usage = .{ .used_tokens = 46000, .limit_tokens = 200000, .estimated = true, .parts = &parts, .request_tokens = 4000, .redacted = false };
    try f.view.update(measured);
    label[0] = 'X';
    f.settle();
    try std.testing.expectEqualStrings("23%", f.view.labels[4].?.getText().?.content);
    try std.testing.expectEqualStrings("history", f.view.source.?.value.usage.?.parts[0].name);
    f.click(f.view.buttons[4]);
    const menu = find(f.cx.root.?, "ai.usage.menu").?;
    try std.testing.expectEqual(@as(f32, 344), menu.globalRect().w);
    try std.testing.expectEqual(@as(f32, 142), menu.globalRect().h);
    try std.testing.expect(find(menu, "ai.usage.compaction.status") == null);
    const track = find(menu, "ai.usage.track").?.globalRect();
    const action_button = find(menu, "ai.usage.compaction.start").?.globalRect();
    try std.testing.expectEqual(@as(f32, 24), action_button.w);
    try std.testing.expectEqual(@as(f32, 24), action_button.h);
    try std.testing.expectApproxEqAbs(track.x + track.w + 8, action_button.x, 0.1);
    try std.testing.expectApproxEqAbs(track.y + track.h / 2, action_button.y + action_button.h / 2, 0.1);
    var found = false;
    for (f.cx.display_list.items.items) |item| if (item == .arc and item.arc.header.node_id == f.view.ring.id and ui.Color.eql(item.arc.color, Styles.theme.current().accent)) {
        found = true;
        try std.testing.expectApproxEqAbs(@as(f32, 0.23), (item.arc.end_angle - item.arc.start_angle) / std.math.tau, 0.001);
    };
    try std.testing.expect(found);
    try std.testing.expectEqual(@as(usize, 0), f.calls);
}

test "AI composer source and configuration changes reject a previously captured model action" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    f.click(f.view.buttons[2]);
    const quiet = modelOption(find(f.cx.root.?, "ai.model.menu").?, "quiet").?;
    var next = f.snapshot();
    next.owner = .{ .session = 202 };
    try f.view.update(next);
    _ = f.cx.dispatcher.dispatch(.{ .click = .{ .x = 0, .y = 0 } }, quiet);
    try std.testing.expectEqual(@as(usize, 0), f.calls);
    f.settle();
    try std.testing.expect(!f.view.isOpen());
    next.revision = 2;
    try f.view.update(next);
    f.settle();
    next.revision = 1;
    try std.testing.expectError(error.StaleSnapshot, f.view.update(next));
    next.revision = 2;
    f.models[0].vision = false;
    try std.testing.expectError(error.ConfigurationChangedWithoutRevision, f.view.update(next));
}

test "AI composer theme changes repaint open popovers and callback errors do not fake acceptance" {
    const previous = Styles.theme.currentName();
    defer Styles.theme.select(previous);
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    f.click(f.view.buttons[1]);
    f.reject = true;
    f.enter(find(find(f.cx.root.?, "ai.permission.menu").?, "ai.permission.auto").?);
    try std.testing.expectEqual(error.FixtureRejected, f.view.last_error.?);
    try std.testing.expectEqualStrings("确认后执行", f.view.labels[1].?.getText().?.content);
    Styles.theme.select(.light);
    f.cx.setTheme(Styles.theme.widgetTheme(.light));
    f.settle();
    try std.testing.expect(ui.Color.eql(Styles.theme.current().surface_2, f.view.buttons[1].getBackground()));
    try std.testing.expect(ui.Color.eql(Styles.theme.current().overlay, find(f.cx.root.?, "ai.permission.menu").?.getBackground()));
    f.view.dismiss();
    f.settle();
    try std.testing.expect(!f.view.isOpen());
}

test "AI composer model identities expose provider and ID and unconfigured models link to settings" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    f.enter(f.view.buttons[2]);
    const alpha = modelOption(f.cx.root.?, "alpha").?;
    try std.testing.expectEqualStrings("alpha\nlab · alpha\n配置上下文 200000 tokens · 可用\n支持图片输入 · 工具能力未声明\n推理档位：低 / 高", alpha.behavior.interaction.a11y.?.label.?);
    try std.testing.expectEqualStrings("alpha\nlab · alpha\n配置上下文 200000 tokens · 可用\n支持图片输入 · 工具能力未声明\n推理档位：低 / 高", alpha.behavior.interaction.a11y.?.description.?);
    const Hook = struct {
        fn open(raw: *anyopaque) void {
            const fixture: *Fixture = @ptrCast(@alignCast(raw));
            fixture.calls += 1;
        }
    };
    f.view.callbacks.open_settings = Hook.open;
    f.providers[0].api_key = "";
    var snapshot = f.snapshot();
    snapshot.revision += 1;
    try f.view.update(snapshot);
    f.settle();
    try std.testing.expect(!f.view.disabled[2].peek());
    f.enter(f.view.buttons[2]);
    const settings = find(f.cx.root.?, "ai.model.settings").?;
    try std.testing.expect(settings.style.display != .none);
    f.enter(settings);
    try std.testing.expectEqual(@as(usize, 1), f.calls);
    try std.testing.expect(f.last == null);
}

test "native protocol model effort claims cannot enable an unsupported composer slider" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    for ([_]config.ProviderKind{ .anthropic, .ollama }) |kind| {
        f.providers[0].kind = kind;
        f.models[0].efforts = @splat(true);
        var snapshot = f.snapshot();
        snapshot.revision += @as(u64, @intCast(@backingInt(kind))) + 1;
        try f.view.update(snapshot);
        f.settle();
        try std.testing.expect(f.view.disabled[3].peek());
        const before = f.calls;
        f.click(f.view.buttons[2]);
        try std.testing.expect(f.view.popups[2].widget.open.?.peek());
        f.view.dismiss();
        try std.testing.expectEqual(before, f.calls);
        try std.testing.expect(f.models[0].reasoning and f.models[0].efforts[4]);
    }
    f.providers[0].kind = .openai_compat;
    var restored = f.snapshot();
    restored.revision = 10;
    try f.view.update(restored);
    f.settle();
    try std.testing.expect(!f.view.disabled[3].peek());
    f.click(f.view.buttons[2]);
    try std.testing.expect(f.view.popups[2].widget.open.?.peek());
}

test "AI composer callable reasoning models remain selectable when reasoning controls are unavailable" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    f.panel.setStyleInline(a, .{ .width = .{ .px = 520 } });
    f.view.root.setStyleInline(a, .{ .width = .{ .px = 492 } });
    f.models[0].id = "codex/gpt-6.1-sol";
    f.models[0].efforts = @splat(false);
    f.models[0].reasoning = true;
    f.models[0].reasoning_toggle = false;
    var snapshot = f.snapshot();
    snapshot.current.?.model_id = f.models[0].id;
    snapshot.revision += 1;
    try f.view.update(snapshot);
    f.settle();
    try std.testing.expect(!f.view.disabled[2].peek());
    try std.testing.expect(f.view.disabled[3].peek());
    try std.testing.expectEqualStrings("推理未开放", f.view.labels[3].?.getText().?.content);
    try std.testing.expectEqualStrings("未开放思考开关或推理档位", f.view.effort_name.getText().?.content);
    const row = f.view.root.globalRect();
    try std.testing.expectApproxEqAbs(row.x + row.w - 28, f.send.globalRect().x, 0.1);
    try std.testing.expect(f.view.buttons[4].globalRect().x + 68 < f.send.globalRect().x);
    f.click(f.view.buttons[2]);
    const option = modelOption(f.view.popups[2].body, f.models[0].id) orelse return error.MissingConfiguredModel;
    f.enter(option);
    try std.testing.expectEqualStrings(f.models[0].id, f.last.?.action.model.model_id);
}

test "AI composer combined model card switches to a real binary thinking control" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    f.models[0].id = "mimo-v2.6-pro";
    f.models[0].reasoning_toggle = true;
    f.models[0].efforts = @splat(false);
    f.models[0].thinking_default = true;
    var snapshot = f.snapshot();
    snapshot.revision = 2;
    snapshot.current = .{ .provider_id = "lab", .model_id = "mimo-v2.6-pro" };
    snapshot.effort = null;
    try f.view.update(snapshot);
    f.settle();
    try std.testing.expectEqualStrings("思考开", f.view.labels[3].?.getText().?.content);
    try std.testing.expect(f.view.labels[3].?.parent == f.view.buttons[2]);
    f.click(f.view.buttons[2]);
    f.cx.setFocus(f.view.slider.wrapper);
    f.cx.handleKeyDown(.home, .{});
    f.settle();
    try std.testing.expect(!f.last.?.action.thinking.enabled);
    try std.testing.expect(f.view.isOpen());
    snapshot.thinking = false;
    try f.view.update(snapshot);
    f.settle();
    try std.testing.expectEqualStrings("思考关", f.view.labels[3].?.getText().?.content);
    try std.testing.expect(f.view.effort_area.style.display == .flex);
    try std.testing.expectEqualStrings("关闭", f.view.effort_ticks[0].getText().?.content);
    try std.testing.expectEqualStrings("开启", f.view.effort_ticks[1].getText().?.content);
}

test "AI composer provider groups are all expanded without extra controls" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    f.click(f.view.buttons[2]);
    try std.testing.expectEqual(@as(usize, 5), f.view.model_rows.items.len);
    try std.testing.expect(f.view.model_rows.items[0].header);
    try std.testing.expect(f.view.model_rows.items[3].header);
    try std.testing.expect(!f.view.model_rows.items[4].header);
    try std.testing.expectEqualStrings("模型与推理强度", f.view.model_title.getText().?.content);
    try std.testing.expectApproxEqAbs(f.view.model_card.globalRect().h - 8, f.view.model_list.globalRect().h, 0.1);
}

test "AI composer context compaction emits captured start and cancel with acknowledged states" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    var snapshot = f.snapshot();
    snapshot.usage = .{ .used_tokens = 6000, .limit_tokens = 32000, .can_compact = true };
    try f.view.update(snapshot);
    f.settle();
    f.click(f.view.buttons[4]);
    try std.testing.expect(find(f.cx.root.?, "ai.usage.compaction.status") == null);
    f.enter(find(f.cx.root.?, "ai.usage.compaction.start").?);
    try std.testing.expectEqual(@as(usize, 1), f.calls);
    try std.testing.expect(f.last.?.action == .compact_context);
    try std.testing.expect(f.view.source.?.value.usage.?.compaction == .idle);
    snapshot.usage.?.compaction = .running;
    snapshot.usage.?.can_compact = false;
    try f.view.update(snapshot);
    f.settle();
    f.enter(find(f.cx.root.?, "ai.usage.compaction.cancel").?);
    try std.testing.expectEqual(@as(usize, 2), f.calls);
    try std.testing.expect(f.last.?.action == .cancel_compaction);
    snapshot.usage.?.compaction = .failed;
    snapshot.usage.?.can_compact = true;
    try f.view.update(snapshot);
    f.settle();
    f.enter(find(f.cx.root.?, "ai.usage.compaction.start").?);
    try std.testing.expect(f.last.?.action == .compact_context);
    snapshot.usage.?.can_compact = false;
    snapshot.usage.?.compaction = .idle;
    try f.view.update(snapshot);
    f.settle();
    const before = f.calls;
    f.enter(find(f.cx.root.?, "ai.usage.compaction.start").?);
    try std.testing.expectEqual(before, f.calls);
}

test "AI composer declared none and ultra are distinct endpoint slider choices" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    f.models[0].efforts = .{ true, false, false, false, false, true, true };
    var declared = f.snapshot();
    declared.revision += 1;
    try f.view.update(declared);
    f.settle();
    f.enter(f.view.buttons[2]);
    try std.testing.expectEqual(@as(usize, 3), f.view.reasoning_count);
    try std.testing.expectEqualStrings("关闭", f.view.effort_ticks[0].getText().?.content);
    try std.testing.expectEqualStrings("超高", f.view.effort_ticks[2].getText().?.content);
    f.cx.setFocus(f.view.slider.wrapper);
    f.cx.handleKeyDown(.home, .{});
    f.settle();
    try std.testing.expectEqual(Controls.Effort.none, f.last.?.action.effort.value);
    f.cx.handleKeyDown(.end, .{});
    f.settle();
    try std.testing.expectEqual(Controls.Effort.ultra, f.last.?.action.effort.value);
}

test "AI composer pointer reaches every one of seven declared native efforts" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    f.models[0].efforts = @splat(true);
    var declared = f.snapshot();
    declared.revision += 1;
    try f.view.update(declared);
    f.settle();
    f.enter(f.view.buttons[2]);
    const area = f.view.slider_track.globalRect();
    for ([_]Controls.Effort{ .none, .low, .medium, .high, .xhigh, .max, .ultra }, 0..) |expected, index| {
        const x = area.x + std.math.clamp(area.w * @as(f32, @floatFromInt(index)) / 6, 0.5, area.w - 0.5);
        f.cx.handleMouseDown(x, area.y + area.h / 2, .{});
        f.cx.handleMouseUp(x, area.y + area.h / 2);
        f.settle();
        try std.testing.expectEqual(expected, f.last.?.action.effort.value);
    }
}
