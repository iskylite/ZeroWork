const std = @import("std");
const ui = @import("ui");
const view = @import("config/settings_content_view.zig");
comptime {
    _ = @import("application_data_cleanup_ui_tests.zig");
}
test "settings content mount is analyzed for all page branches" {
    const Fn = *const fn (*ui.Cx, *ui.Scope, *@import("config/settings_controller.zig").Controller, view.Hooks) anyerror!*ui.Node;
    const mount: Fn = view.mountContent;
    std.mem.doNotOptimizeAway(mount);
}
fn changed(_: *anyopaque) void {}
fn request(_: *anyopaque, _: view.Key, _: *ui.Node) void {}
fn action(_: *anyopaque, _: view.Action) void {}
fn providers(_: *anyopaque, cx: *ui.Cx, _: *ui.Scope) anyerror!*ui.Node {
    return ui.box(cx, .{}, .{});
}

fn tallProviders(_: *anyopaque, cx: *ui.Cx, _: *ui.Scope) anyerror!*ui.Node {
    // A deterministic long Provider fixture exercises the real page ScrollArea
    // without pretending that a network response or sample provider is live.
    return ui.box(cx, .{ .width = .fill(), .height = .{ .px = 1200 }, .flex_shrink = 0 }, .{});
}
test "eight live settings contents mount with an owned draft" {
    const cx = try ui.Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    const root = try ui.box(cx, .{}, .{});
    cx.root = root;
    const scope = try ui.Scope.init(std.testing.allocator, null, cx.owner);
    defer scope.dispose();
    var controller = try @import("config/settings_controller.zig").Controller.init(std.testing.allocator, .{});
    defer controller.deinit();
    var context: u8 = 0;
    for (0..8) |page| {
        controller.model.selectPage(page);
        const content = try view.mountContent(cx, scope, &controller, .{ .context = &context, .changed = changed, .request_edit = request, .action = action, .mount_providers = providers });
        try root.appendChild(cx.allocator, content);
    }
}
fn textNode(node: *ui.Node, needle: []const u8) ?*ui.Node {
    if (node.getText()) |text| if (std.mem.eql(u8, text.content, needle)) return node;
    for (node.children.items) |child| if (textNode(child, needle)) |found| return found;
    return null;
}
fn appearanceRequest(_: *anyopaque, _: @import("config/appearance_ui_context.zig").Command) void {}
test "appearance reads actual draft and theme click updates controller" {
    const cx = try ui.Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    const root = try ui.box(cx, .{}, .{});
    cx.root = root;
    const scope = try ui.Scope.init(std.testing.allocator, null, cx.owner);
    defer scope.dispose();
    var controller = try @import("config/settings_controller.zig").Controller.init(std.testing.allocator, .{});
    defer controller.deinit();
    try controller.editKey("ui", "font_size", .{ .unsigned = 21 });
    controller.theme_library.open = true;
    controller.folded_sections = 0;
    var registry = try @import("config/theme_registry.zig").Registry.init(std.testing.allocator);
    defer registry.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var runtime = try @import("config/runtime_config.zig").RuntimeConfig.loadOrDefault(std.testing.io, tmp.dir, std.testing.allocator, "config.toml");
    defer runtime.deinit();
    var context: u8 = 0;
    var appearance: @import("config/appearance_ui_context.zig").Context = .{ .registry = &registry, .runtime = &runtime, .context = &context, .request = appearanceRequest };
    const content = try view.mountContent(cx, scope, &controller, .{ .context = &context, .changed = changed, .request_edit = request, .action = action, .appearance = &appearance });
    try root.appendChild(cx.allocator, content);
    const size = byId(content, "settings.field.font_size").?;
    try std.testing.expect(textNode(size, "21") != null);
    const card = byId(content, "settings.theme.dracula").?;
    const click = card.behavior.events.on_click.?;
    click.callback(click.context);
    try std.testing.expectEqualStrings("dracula", controller.model.value.ui.theme);
}

fn byId(node: *ui.Node, id: []const u8) ?*ui.Node {
    if (node.meta.ownership.meta.test_id) |value| if (std.mem.eql(u8, value, id)) return node;
    for (node.children.items) |child| if (byId(child, id)) |found| return found;
    return null;
}

test "AI settings filtered fields retain body and footer without a missing Provider action" {
    const ProviderHooks = struct {
        mounted: bool = false,
        action_count: usize = 0,

        fn mount(raw: *anyopaque, cx: *ui.Cx, _: *ui.Scope) anyerror!*ui.Node {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.mounted = true;
            const node = try ui.box(cx, .{}, .{});
            node.meta.ownership.meta.test_id = "test.providers";
            return node;
        }
        fn mountAction(raw: *anyopaque, cx: *ui.Cx, _: *ui.Scope) anyerror!*ui.Node {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.action_count += 1;
            // Match the real host: the action needs the already mounted list.
            if (!self.mounted) return error.ProviderViewUnavailable;
            const node = try ui.box(cx, .{}, .{});
            node.meta.ownership.meta.test_id = "test.providers.add";
            return node;
        }
    };
    const cases = [_]struct { query: []const u8, section: []const u8, providers: bool }{
        .{ .query = "permission_mode", .section = "settings.ai.permissions", .providers = false },
        .{ .query = "redact_ip", .section = "settings.ai.context", .providers = false },
        .{ .query = "error_hint", .section = "settings.ai.behavior", .providers = false },
        .{ .query = "Provider", .section = "test.providers", .providers = true },
        .{ .query = "", .section = "settings.ai.permissions", .providers = true },
    };
    for (cases) |case| {
        const cx = try ui.Cx.init(std.testing.allocator, std.testing.io);
        defer cx.deinit();
        cx.root = try ui.box(cx, .{}, .{});
        const scope = try ui.Scope.init(std.testing.allocator, null, cx.owner);
        defer scope.dispose();
        var controller = try @import("config/settings_controller.zig").Controller.init(std.testing.allocator, .{});
        defer controller.deinit();
        controller.model.selectPage(4);
        controller.folded_sections = 0;
        try controller.setSearch(case.query);
        var context: ProviderHooks = .{};
        const mounted = try view.mountPage(cx, scope, &controller, .{
            .context = &context,
            .changed = changed,
            .request_edit = request,
            .action = action,
            .mount_providers = ProviderHooks.mount,
            .mount_provider_action = ProviderHooks.mountAction,
        });
        try cx.root.?.appendChild(cx.allocator, mounted.root);
        try std.testing.expect(byId(mounted.scroll_content, case.section) != null);
        for ([_][]const u8{ "permission_mode", "redact_ip", "error_hint" }) |key| {
            if (case.query.len != 0 and !std.mem.eql(u8, case.query, key)) continue;
            var buffer: [80]u8 = undefined;
            const id = try std.fmt.bufPrint(&buffer, "settings.field.{s}", .{key});
            try std.testing.expect(byId(mounted.scroll_content, id) != null);
        }
        try std.testing.expect(byId(mounted.root, "settings.footer") != null);
        try std.testing.expect(byId(mounted.root, "settings.save") == mounted.save_button);
        try std.testing.expect(byId(mounted.root, "settings.reset") == mounted.reset_button);
        try std.testing.expectEqualStrings("已保存", mounted.status_label.getText().?.content);
        try std.testing.expectEqual(case.providers, context.mounted);
        try std.testing.expectEqual(@as(usize, 0), context.action_count);
        try std.testing.expect(byId(mounted.root, "test.providers.add") == null);
    }
}

const AppearanceFixture = struct {
    cx: *ui.Cx,
    scope: *ui.Scope,
    controller: @import("config/settings_controller.zig").Controller,
    registry: @import("config/theme_registry.zig").Registry,
    runtime: @import("config/runtime_config.zig").RuntimeConfig,
    tmp: std.testing.TmpDir,
    context: @import("config/appearance_ui_context.zig").Context,
    busy: bool = false,
    font_problem: ?[]const u8 = null,
    last_command: ?@import("config/appearance_ui_context.zig").Command = null,
    rebuilds: usize = 0,
    fn init(self: *AppearanceFixture) !void {
        const a = std.testing.allocator;
        self.* = .{ .cx = try ui.Cx.init(a, std.testing.io), .scope = undefined, .controller = try @import("config/settings_controller.zig").Controller.init(a, .{}), .registry = try @import("config/theme_registry.zig").Registry.init(a), .runtime = undefined, .tmp = std.testing.tmpDir(.{}), .context = undefined };
        self.scope = try ui.Scope.init(a, null, self.cx.owner);
        self.runtime = try @import("config/runtime_config.zig").RuntimeConfig.loadOrDefault(std.testing.io, self.tmp.dir, a, "config.toml");
        self.context = .{ .registry = &self.registry, .runtime = &self.runtime, .context = self, .request = command, .busy = isBusy, .font_status = fontStatus };
        self.cx.setViewport(636, 628);
        self.cx.root = try ui.box(self.cx, .{ .width = .{ .px = 636 }, .height = .{ .px = 628 } }, .{});
    }
    fn deinit(self: *AppearanceFixture) void {
        self.scope.dispose();
        self.cx.deinit();
        self.controller.deinit();
        self.registry.deinit();
        self.runtime.deinit();
        self.tmp.cleanup();
    }
    fn command(raw: *anyopaque, value: @import("config/appearance_ui_context.zig").Command) void {
        const self: *AppearanceFixture = @ptrCast(@alignCast(raw));
        self.last_command = value;
    }
    fn isBusy(raw: *anyopaque) bool {
        const self: *AppearanceFixture = @ptrCast(@alignCast(raw));
        return self.busy;
    }
    fn fontStatus(raw: *anyopaque) @import("config/appearance_ui_context.zig").FontStatus {
        const self: *AppearanceFixture = @ptrCast(@alignCast(raw));
        return .{ .problem = self.font_problem };
    }
    fn rebuild(raw: *anyopaque) void {
        const self: *AppearanceFixture = @ptrCast(@alignCast(raw));
        self.rebuilds += 1;
    }
    fn mount(self: *AppearanceFixture) !view.Mounted {
        const mounted = try view.mountPage(self.cx, self.scope, &self.controller, .{ .context = self, .changed = rebuild, .request_edit = request, .action = action, .appearance = &self.context });
        try self.cx.root.?.appendChild(self.cx.allocator, mounted.root);
        self.cx.layout();
        return mounted;
    }
};
fn clickButton(node: *ui.Node) void {
    node.behavior.events.on_click.?.invoke();
}
fn inputEvent(state: *ui.widgets.input.TextInputState, event: ui.events.Event) void {
    const node = state.input_container_node.?;
    if (node.behavior.events.on_event_capture) |capture| if (capture(event, node.behavior.events.capture_context) == .stop) return;
    if (node.behavior.events.on_event) |handler| _ = handler(event, node.behavior.events.event_context);
}
fn inputFor(mounted: view.Mounted, id: []const u8) *ui.widgets.input.TextInputState {
    const node = byId(mounted.root, id).?;
    for (mounted.binding.ime_clients.items) |state| if (state.input_container_node == node) return state;
    unreachable;
}

test "settings material remount restores the same input focus cursor and reversed selection after IME commit" {
    const theme = @import("ui/app_theme.zig");
    theme.select(.dark);
    _ = theme.setMaterialVisible(false);
    defer _ = theme.setMaterialVisible(false);
    var f: AppearanceFixture = undefined;
    try f.init();
    defer f.deinit();
    f.controller.folded_sections = 0;
    const publication = try f.cx.bindState(@import("ui/shell_styles.zig").ThemePublication, .{});
    publication.publish(f.cx, theme.widgetTheme(.dark));
    const old_scope = try f.scope.childScope();
    const hooks: view.Hooks = .{ .context = &f, .changed = AppearanceFixture.rebuild, .request_edit = request, .action = action, .appearance = &f.context };
    const old = try view.mountPage(f.cx, old_scope, &f.controller, hooks);
    try f.cx.root.?.appendChild(f.cx.allocator, old.root);
    f.cx.layout();
    const input = inputFor(old, "settings.field.font_size");
    const old_id = input.input_container_node.?.id;
    f.cx.setFocus(input.input_container_node);
    inputEvent(input, .{ .key_down = .{ .key = .a, .modifiers = .{ .super = true } } });
    inputEvent(input, .{ .ime_preedit = .{ .text = "16", .cursor_utf8_offset = 2 } });
    _ = theme.setMaterialVisible(true);
    publication.publish(f.cx, theme.widgetTheme(.dark));
    // The host keeps its pending rebuild until this actual Input commits.
    try std.testing.expect(old.isComposing());
    try std.testing.expect((try old.captureFocus(std.testing.allocator)) == null);
    try std.testing.expect(f.cx.focus_manager.getFocused() == input.input_container_node.?);
    inputEvent(input, .{ .ime_commit = .{ .text = "16" } });
    try std.testing.expect(!old.isComposing());
    try std.testing.expect(input.setAccessibilitySelection(2, 1));
    var focus = (try old.captureFocus(std.testing.allocator)).?;
    defer focus.deinit(std.testing.allocator);

    // Match SettingsHost's real disposal order, rather than keeping the old
    // Input or its scope alive while mounting the replacement.
    old_scope.dispose();
    f.cx.detachChild(f.cx.root.?, old.root);
    f.cx.destroyDetached(old.root);
    try std.testing.expect(f.cx.focus_manager.getFocused() == null);
    const next_scope = try f.scope.childScope();
    const next = try view.mountPage(f.cx, next_scope, &f.controller, hooks);
    try f.cx.root.?.appendChild(f.cx.allocator, next.root);
    try std.testing.expect(next.restoreFocus(focus));
    f.cx.layout();
    const replacement = inputFor(next, "settings.field.font_size");
    try std.testing.expect(replacement.input_container_node.?.id != old_id);
    try std.testing.expect(f.cx.focus_manager.getFocused() == replacement.input_container_node.?);
    try std.testing.expect(replacement.focused);
    try std.testing.expectEqualStrings("16", replacement.getText());
    try std.testing.expectEqual(@as(u16, 16), f.controller.model.value.ui.font_size);
    try std.testing.expectEqual(@as(usize, 1), replacement.cursor_pos);
    try std.testing.expectEqual(@as(?usize, 2), replacement.selection_anchor);
}

test "settings material focus restore leaves other focus and unavailable fields alone" {
    var f: AppearanceFixture = undefined;
    try f.init();
    defer f.deinit();
    f.controller.folded_sections = 0;
    const mounted = try f.mount();
    const size = inputFor(mounted, "settings.field.font_size");
    const height = inputFor(mounted, "settings.field.line_height");
    f.cx.setFocus(size.input_container_node);
    try std.testing.expect(size.setAccessibilitySelection(1, 1));
    var focus = (try mounted.captureFocus(std.testing.allocator)).?;
    defer focus.deinit(std.testing.allocator);
    f.cx.setFocus(height.input_container_node);
    try std.testing.expect(!mounted.restoreFocus(focus));
    try std.testing.expect(f.cx.focus_manager.getFocused() == height.input_container_node.?);
    f.cx.setFocus(null);
    size.disabled = true;
    try std.testing.expect(!mounted.restoreFocus(focus));
    try std.testing.expect(f.cx.focus_manager.getFocused() == null);
    size.disabled = false;
    try std.testing.expect(mounted.restoreFocus(focus));
    try std.testing.expectEqual(@as(usize, 1), size.cursor_pos);
    try std.testing.expect(size.selection_anchor == null);
    f.cx.setFocus(mounted.reset_button);
    try std.testing.expect((try mounted.captureFocus(std.testing.allocator)) == null);

    f.cx.setFocus(null);
    f.controller.model.selectPage(5);
    const plugins = try f.mount();
    try std.testing.expect(!plugins.restoreFocus(focus));
    try std.testing.expect(f.cx.focus_manager.getFocused() == null);
}

test "appearance geometry uses V3 card padding and 32 pixel field controls" {
    var f: AppearanceFixture = undefined;
    try f.init();
    defer f.deinit();
    f.controller.folded_sections = 0;
    const mounted = try f.mount();
    const font = byId(mounted.root, "settings.appearance.font").?.globalRect();
    const family = byId(mounted.root, "settings.field.font_family").?.globalRect();
    try std.testing.expectApproxEqAbs(@as(f32, 626), font.w, 0.1);
    try std.testing.expectApproxEqAbs(@as(f32, 390), family.x - font.x, 0.1);
    try std.testing.expectApproxEqAbs(@as(f32, 72.5), family.y - font.y, 0.1);
    try std.testing.expectApproxEqAbs(@as(f32, 220), family.w, 0.1);
    try std.testing.expectApproxEqAbs(@as(f32, 32), family.h, 0.1);
    const material = byId(mounted.root, "settings.appearance.materials").?.globalRect();
    try std.testing.expectApproxEqAbs(@as(f32, 62), byId(mounted.root, "settings.materials.header").?.globalRect().h, 0.1);
    for ([_][]const u8{ "fit", "alignment" }) |field| {
        var buffer: [80]u8 = undefined;
        const control = byId(mounted.root, try std.fmt.bufPrint(&buffer, "settings.field.{s}", .{field})).?.globalRect();
        try std.testing.expectApproxEqAbs(@as(f32, 16), material.x + material.w - control.x - control.w, 0.1);
        try std.testing.expectApproxEqAbs(@as(f32, 220), control.w, 0.1);
        try std.testing.expectApproxEqAbs(@as(f32, 32), control.h, 0.1);
    }
    for ([_][]const u8{ "transparency", "blur_px" }) |field| {
        var buffer: [80]u8 = undefined;
        const number = byId(mounted.root, try std.fmt.bufPrint(&buffer, "settings.field.{s}", .{field})).?.globalRect();
        try std.testing.expectApproxEqAbs(@as(f32, 90), number.w, 0.1);
        try std.testing.expectApproxEqAbs(@as(f32, 32), number.h, 0.1);
    }
    // Turning a background off does not hide its editable draft.
    try std.testing.expect(!f.controller.model.value.ui.materials.background.enabled);
    try std.testing.expect(byId(mounted.root, "settings.background.choose") != null);
}

test "appearance V3 inline preview and theme import expose real capability" {
    var f: AppearanceFixture = undefined;
    try f.init();
    defer f.deinit();
    f.controller.folded_sections = 0;
    try f.controller.editKey("ui.materials.background", "path", .{ .text = "/fixture.png" });
    const mounted = try f.mount();
    const preview = byId(mounted.root, "settings.background.preview").?;
    try std.testing.expectApproxEqAbs(@as(f32, 116), preview.globalRect().h, 0.1);
    try std.testing.expect(byId(mounted.root, "settings.materials.preview.full") != null);
    const remove = byId(mounted.root, "settings.theme.remove.current").?;
    try std.testing.expect(remove.behavior.interaction.a11y.?.disabled);
    try std.testing.expect(byId(mounted.root, "settings.theme.import") != null);
    try std.testing.expect(byId(mounted.root, "settings.font.preview.caret") != null);
}

test "appearance removed thumbnail clears while failed replacement retains last good" {
    var f: AppearanceFixture = undefined;
    try f.init();
    defer f.deinit();
    f.context.mount_image = struct {
        fn mount(_: *anyopaque, cx: *ui.Cx, _: *ui.Scope, width: f32, height: f32) anyerror!*ui.Node {
            const node = try ui.box(cx, .{ .width = .{ .px = width }, .height = .{ .px = height } }, .{});
            node.meta.ownership.meta.test_id = "test.prepared.thumbnail";
            return node;
        }
    }.mount;
    try f.controller.editKey("ui.materials.background", "enabled", .{ .boolean = true });
    var request_good = try f.controller.requestBackground("/good.png");
    defer request_good.deinit();
    var good: @import("config/background_asset.zig").Prepared = .{
        .draft_id = request_good.request.draft_id,
        .asset_revision = request_good.request.asset_revision,
        .path = try std.testing.allocator.dupe(u8, request_good.request.path),
        .image = .{ .width = 1, .height = 1, .pixels = try std.testing.allocator.dupe(u8, &.{ 255, 0, 0, 255 }) },
    };
    try std.testing.expect(try f.controller.completeBackground(&good));
    const ready = try f.mount();
    try std.testing.expect(byId(ready.root, "test.prepared.thumbnail") != null);
    try std.testing.expect(!byId(ready.root, "settings.materials.preview.open").?.behavior.interaction.a11y.?.disabled);

    var request_bad = try f.controller.requestBackground("/bad.png");
    defer request_bad.deinit();
    f.context.selected_image_path = request_bad.request.path;
    try std.testing.expect(f.controller.failBackground(request_bad.request, error.InvalidImage));
    const failed = try f.mount();
    try std.testing.expect(byId(failed.root, "test.prepared.thumbnail") != null);
    try std.testing.expectEqualStrings("bad.png", byId(failed.root, "settings.background.filename").?.getText().?.content);
    try std.testing.expect(!byId(failed.root, "settings.materials.preview.open").?.behavior.interaction.a11y.?.disabled);

    clickButton(byId(failed.root, "settings.background.remove").?);
    // SettingsHost clears the selected worker path on this ordinary draft edit.
    f.context.selected_image_path = "";
    const empty = try f.mount();
    const preview = byId(empty.root, "settings.materials.preview.open").?;
    try std.testing.expect(byId(preview, "test.prepared.thumbnail") == null);
    try std.testing.expect(firstImage(preview) != null);
    try std.testing.expect(!preview.behavior.interaction.a11y.?.disabled);
    try std.testing.expectEqualStrings("尚未选择图片", byId(empty.root, "settings.background.filename").?.getText().?.content);
    try std.testing.expectEqualStrings("", f.controller.model.value.ui.materials.background.path);
    try std.testing.expectEqualStrings("/good.png", f.controller.background.last_good.?.path);
    try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255 }, f.controller.background.last_good.?.image.pixels);
}

test "appearance footer reports failed replacement even with clean configuration fields" {
    var f: AppearanceFixture = undefined;
    try f.init();
    defer f.deinit();
    f.controller.deinit();
    f.controller = try @import("config/settings_controller.zig").Controller.init(std.testing.allocator, .{
        .ui = .{ .materials = .{ .background = .{ .enabled = true, .path = "/saved.png" } } },
    });
    const mounted = try f.mount();
    try std.testing.expectEqualStrings("已保存", mounted.status_label.getText().?.content);
    var bad = try f.controller.requestBackground("/broken.png");
    defer bad.deinit();
    try std.testing.expect(f.controller.failBackground(bad.request, error.InvalidImage));
    try std.testing.expect(!f.controller.model.dirty);
    try std.testing.expectEqualStrings("/saved.png", f.controller.model.value.ui.materials.background.path);
    mounted.refreshFooter();
    try std.testing.expectEqualStrings("背景图片准备失败，草稿已保留", mounted.status_label.getText().?.content);
    try std.testing.expect(mounted.save_button.behavior.interaction.a11y.?.disabled);
    const rebuilt = try f.mount();
    try std.testing.expectEqualStrings("背景图片准备失败，草稿已保留", rebuilt.status_label.getText().?.content);

    try f.controller.editKey("ui.materials.background", "enabled", .{ .boolean = false });
    rebuilt.refreshFooter();
    try std.testing.expectEqualStrings("未保存", rebuilt.status_label.getText().?.content);
    try std.testing.expect(!rebuilt.save_button.behavior.interaction.a11y.?.disabled);
    try std.testing.expect(f.controller.background.problem != null);
}

test "appearance legacy library state cannot replace V3 inline theme selection" {
    var f: AppearanceFixture = undefined;
    try f.init();
    defer f.deinit();
    f.controller.theme_library.open = true;
    f.context.library_dismissed = true;
    try f.controller.theme_library.setQuery(std.testing.allocator, "zz-no-match");
    try f.controller.editKey("ui", "font_size", .{ .unsigned = 21 });
    const mounted = try f.mount();
    const strip = byId(mounted.root, "settings.theme.strip").?;
    try std.testing.expectApproxEqAbs(@as(f32, 75), strip.globalRect().h, 0.1);
    try std.testing.expect(byId(mounted.root, "settings.theme.grid") == null);
    try std.testing.expect(byId(mounted.root, "settings.theme.library.open") == null);
    try std.testing.expect(byId(mounted.root, "settings.theme.library.close") == null);
    const light = byId(mounted.root, "settings.theme.light").?;
    try std.testing.expectApproxEqAbs(@as(f32, 150), light.globalRect().w, 0.1);
    try std.testing.expectApproxEqAbs(@as(f32, 75), light.globalRect().h, 0.1);
    clickButton(light);
    try std.testing.expectEqualStrings("light", f.controller.model.value.ui.theme);
    try std.testing.expectEqual(@as(u16, 21), f.controller.model.value.ui.font_size);
    try std.testing.expectEqualStrings("zz-no-match", f.controller.theme_library.query);
}

test "appearance numeric input keeps invalid raw and composition while footer tracks host readiness" {
    var f: AppearanceFixture = undefined;
    try f.init();
    defer f.deinit();
    f.controller.folded_sections = 0;
    const mounted = try f.mount();
    const size = inputFor(mounted, "settings.field.font_size");
    inputEvent(size, .{ .key_down = .{ .key = .a, .modifiers = .{ .super = true } } });
    inputEvent(size, .{ .text_input = .{ .text = "97" } });
    try std.testing.expectEqualStrings("97", size.getText());
    try std.testing.expectEqual(@as(u16, 14), f.controller.model.value.ui.font_size);
    try std.testing.expect(mounted.save_button.behavior.interaction.a11y.?.disabled);
    try std.testing.expectEqual(@as(usize, 0), f.rebuilds);
    inputEvent(size, .{ .ime_preedit = .{ .text = "ni", .cursor_utf8_offset = 2 } });
    try std.testing.expect(mounted.isComposing());
    f.cx.setFocus(size.input_container_node);
    try std.testing.expect(!mounted.consumeEscape());
    const capture = size.input_container_node.?.behavior.events.on_event_capture.?;
    try std.testing.expectEqual(.ignored, capture(.{ .key_down = .{ .key = .escape } }, size.input_container_node.?.behavior.events.capture_context));
    inputEvent(size, .{ .ime_preedit = .{ .text = "", .cursor_utf8_offset = 0 } });
    try std.testing.expect(mounted.consumeEscape());
    try std.testing.expect(!mounted.consumeEscape());
    try std.testing.expectEqualStrings("14", size.getText());
    try f.controller.editKey("ui", "font_size", .{ .unsigned = 15 });
    mounted.refreshFooter();
    try std.testing.expect(!mounted.save_button.behavior.interaction.a11y.?.disabled);
    f.busy = true;
    mounted.refreshFooter();
    try std.testing.expect(mounted.save_button.behavior.interaction.a11y.?.disabled);
    f.busy = false;
    f.font_problem = "UnsupportedWeight";
    mounted.refreshFooter();
    try std.testing.expect(mounted.save_button.behavior.interaction.a11y.?.disabled);
    try std.testing.expect(textNode(mounted.root, "UnsupportedWeight") != null);
}

test "settings fixed footer stays outside the scrolling viewport at canonical size" {
    // V3 keeps the heading and footer fixed while only the body scrolls.
    for ([_]f32{ 628, 556 }) |height| {
        const cx = try ui.Cx.init(std.testing.allocator, std.testing.io);
        defer cx.deinit();
        cx.setViewport(636, height);
        const root = try ui.box(cx, .{ .width = .{ .px = 636 }, .height = .{ .px = height }, .direction = .column }, .{});
        cx.root = root;
        const scope = try ui.Scope.init(std.testing.allocator, null, cx.owner);
        defer scope.dispose();
        var controller = try @import("config/settings_controller.zig").Controller.init(std.testing.allocator, .{});
        defer controller.deinit();
        controller.model.selectPage(4);
        var context: u8 = 0;
        const page = try view.mountPage(cx, scope, &controller, .{ .context = &context, .changed = changed, .request_edit = request, .action = action, .mount_providers = tallProviders });
        try root.appendChild(cx.allocator, page.root);
        cx.layout();
        const viewport = byId(page.root, "settings.viewport").?;
        const footer = byId(page.root, "settings.footer").?;
        const before = footer.globalRect();
        try std.testing.expectApproxEqAbs(@as(f32, 62), viewport.globalRect().y, 0.1);
        try std.testing.expectApproxEqAbs(height - 120, viewport.globalRect().h, 0.1);
        try std.testing.expectApproxEqAbs(height - 58, before.y, 0.1);
        try std.testing.expectApproxEqAbs(@as(f32, 58), before.h, 0.1);
        try std.testing.expectApproxEqAbs(@as(f32, 0), before.y - viewport.globalRect().y - viewport.globalRect().h, 0.1);
        page.scroll_state.viewport_height = viewport.globalRect().h;
        page.scroll_state.content_height = page.scroll_content.globalRect().h;
        try std.testing.expect(page.scroll_state.maxScrollY() > 0);
        ui.widgets.setScrollY(page.scroll_state, page.scroll_content, page.scroll_state.maxScrollY());
        cx.layout();
        try std.testing.expectEqual(before, footer.globalRect());
        try std.testing.expect(page.save_button.behavior.interaction.a11y.?.disabled);
        try std.testing.expect(!page.reset_button.behavior.interaction.a11y.?.disabled);
    }
}

test "enabled settings save icon stays visible within its button in every theme" {
    const theme = @import("ui/app_theme.zig");
    const previous = theme.currentName();
    defer theme.select(previous);
    for (std.enums.values(theme.Name)) |name| {
        theme.select(name);
        const cx = try ui.Cx.init(std.testing.allocator, std.testing.io);
        defer cx.deinit();
        cx.setTheme(theme.widgetTheme(name));
        cx.setViewport(636, 628);
        cx.root = try ui.box(cx, .{ .width = .{ .px = 636 }, .height = .{ .px = 628 } }, .{});
        const scope = try ui.Scope.init(std.testing.allocator, null, cx.owner);
        defer scope.dispose();
        var controller = try @import("config/settings_controller.zig").Controller.init(std.testing.allocator, .{});
        defer controller.deinit();
        controller.model.selectPage(5);
        try controller.editKey("ui", "font_size", .{ .unsigned = 15 });
        var context: u8 = 0;
        const page = try view.mountPage(cx, scope, &controller, .{ .context = &context, .changed = changed, .request_edit = request, .action = action });
        try cx.root.?.appendChild(cx.allocator, page.root);
        cx.layout();
        try std.testing.expect(!page.save_button.behavior.interaction.a11y.?.disabled);
        const icon = firstImage(page.save_button).?;
        const icon_rect = icon.globalRect();
        const button_rect = page.save_button.globalRect();
        try std.testing.expectApproxEqAbs(@as(f32, 14), icon_rect.w, 0.1);
        try std.testing.expectApproxEqAbs(@as(f32, 14), icon_rect.h, 0.1);
        try std.testing.expect(icon_rect.x >= button_rect.x and icon_rect.x + icon_rect.w <= button_rect.x + button_rect.w);
        try std.testing.expect(icon_rect.y >= button_rect.y and icon_rect.y + icon_rect.h <= button_rect.y + button_rect.h);
        const ink = relativeLuminance(if (icon.getIcon()) |props| props.tint else icon.getImage().?.tint);
        const background = relativeLuminance(page.save_button.getBackground());
        const contrast = (@max(ink, background) + 0.05) / (@min(ink, background) + 0.05);
        try std.testing.expect(contrast >= 3);
    }
}

fn firstImage(node: *ui.Node) ?*ui.Node {
    if (node.getIcon() != null or node.getImage() != null) return node;
    for (node.children.items) |child| if (firstImage(child)) |found| return found;
    return null;
}

fn relativeLuminance(color: ui.Color) f32 {
    var total: f32 = 0;
    for ([_]u8{ color.r, color.g, color.b }, [_]f32{ 0.2126, 0.7152, 0.0722 }) |value, weight| {
        const channel = @as(f32, @floatFromInt(value)) / 255;
        total += weight * (if (channel <= 0.04045) channel / 12.92 else std.math.pow(f32, (channel + 0.055) / 1.055, 2.4));
    }
    return total;
}

test "global material settings keep flat sections and shared chooser roles while raw draft survives rebuild" {
    const theme = @import("ui/app_theme.zig");
    const previous = theme.currentName();
    const was_visible = theme.materialVisible();
    defer {
        theme.select(previous);
        _ = theme.setMaterialVisible(was_visible);
    }
    for (std.enums.values(theme.Name)) |name| {
        theme.select(name);
        _ = theme.setMaterialVisible(true);
        var f: AppearanceFixture = undefined;
        try f.init();
        defer f.deinit();
        f.cx.setTheme(theme.widgetTheme(name));
        f.controller.folded_sections = 0;
        try f.controller.setSearch("font");
        try f.controller.editKey("ui", "font_size", .{ .unsigned = 15 });
        const mounted = try f.mount();
        try std.testing.expectEqual(theme.current().surface_1, mounted.root.getBackground());
        // Current Bridge font section 355:1290687 has no fill. Sections
        // share the main surface; only fields and the chooser add a layer.
        try std.testing.expectEqual(theme.current().surface_2, byId(mounted.root, "settings.appearance.font").?.getBackground());
        const family = byId(mounted.root, "settings.field.font_family").?;
        try std.testing.expectEqual(theme.current().well, family.getBackground());
        _ = f.cx.render();
        const family_rect = family.globalRect();
        f.cx.handleMouseDown(family_rect.x + 8, family_rect.y + 8, .{});
        f.cx.handleMouseUp(family_rect.x + 8, family_rect.y + 8);
        try std.testing.expectEqual(theme.current().overlay, byId(f.cx.root.?, "settings.chooser.font_family").?.getBackground());
        try std.testing.expect(mounted.consumeEscape());
        try std.testing.expectEqual(theme.current().action_accent, mounted.save_button.getBackground());
        try std.testing.expectEqual(@as(u8, 255), mounted.save_button.getBackground().a);
        try std.testing.expect(!mounted.save_button.behavior.interaction.a11y.?.disabled);
        const size = inputFor(mounted, "settings.field.font_size");
        inputEvent(size, .{ .key_down = .{ .key = .a, .modifiers = .{ .super = true } } });
        inputEvent(size, .{ .text_input = .{ .text = "97" } });
        try std.testing.expectEqualStrings("97", size.getText());
        _ = theme.setMaterialVisible(false);
        f.cx.setTheme(theme.widgetTheme(name));
        const rebuilt = try f.mount();
        try std.testing.expectEqualStrings("97", inputFor(rebuilt, "settings.field.font_size").getText());
        try std.testing.expectEqual(@as(u16, 15), f.controller.model.value.ui.font_size);
        try std.testing.expectEqual(@as(u8, 255), rebuilt.root.getBackground().a);
        try std.testing.expect(rebuilt.save_button.behavior.interaction.a11y.?.disabled);
    }
}

test "settings search repaints its retained opaque input after material readiness without losing composition" {
    const theme = @import("ui/app_theme.zig");
    const previous_parameters = theme.materialParameters();
    defer _ = theme.setMaterialParameters(previous_parameters.transparency, previous_parameters.blur);
    _ = theme.setMaterialParameters(0, 0);
    const previous = theme.currentName();
    const was_visible = theme.materialVisible();
    defer {
        theme.select(previous);
        _ = theme.setMaterialVisible(was_visible);
    }
    for (std.enums.values(theme.Name)) |name| {
        _ = theme.setMaterialVisible(false);
        _ = theme.setMaterialParameters(0, 0);
        theme.select(name);
        const cx = try ui.Cx.init(std.testing.allocator, std.testing.io);
        defer cx.deinit();
        const publication = try cx.bindState(@import("ui/shell_styles.zig").ThemePublication, .{});
        publication.publish(cx, theme.widgetTheme(name));
        const scope = try ui.Scope.init(std.testing.allocator, null, cx.owner);
        defer scope.dispose();
        cx.setViewport(636, 628);
        cx.root = try ui.box(cx, .{ .width = .fill(), .height = .fill() }, .{});
        const query = try scope.createText("背景", .{});
        const input = try ui.widgets.Input(.{ .value = query, .placeholder = "搜索设置…", .leading_icon_asset = ui.icons.search, .width = @as(f32, 240) }).mountResult(scope, cx);
        input.node.style.height = .{ .px = 30 };
        try cx.root.?.appendChild(cx.allocator, input.node);
        cx.layout();
        const rect = input.node.globalRect();
        const id = input.input_container.id;
        try std.testing.expectEqual(@as(u8, 255), input.input_container.getBackground().a);
        cx.setFocus(input.input_container);
        inputEvent(input.state, .{ .ime_preedit = .{ .text = "ni", .cursor_utf8_offset = 2 } });
        const cursor = input.state.cursor_pos;
        const selection = input.state.selection_anchor;
        try std.testing.expect(input.state.imeIsComposing());
        _ = theme.setMaterialVisible(true);
        _ = theme.setMaterialParameters(75, 0);
        publication.publish(cx, theme.widgetTheme(name));
        view.styles.paintSearch(cx, &input);
        cx.layout();
        try std.testing.expectEqual(theme.current().well, input.input_container.getBackground());
        try std.testing.expect(input.input_container.getBackground().a < 255);
        try std.testing.expectEqual(id, input.input_container.id);
        try std.testing.expectEqual(rect, input.node.globalRect());
        try std.testing.expectEqualStrings("背景", query.peek());
        try std.testing.expectEqual(cursor, input.state.cursor_pos);
        try std.testing.expectEqual(selection, input.state.selection_anchor);
        try std.testing.expect(input.state.imeIsComposing());
        try std.testing.expect(cx.focused_node == input.input_container);
        _ = theme.setMaterialVisible(false);
        _ = theme.setMaterialParameters(0, 0);
        publication.publish(cx, theme.widgetTheme(name));
        view.styles.paintSearch(cx, &input);
        try std.testing.expectEqual(theme.current().well, input.input_container.getBackground());
        try std.testing.expectEqual(@as(u8, 255), input.input_container.getBackground().a);
        try std.testing.expect(input.state.imeIsComposing());
    }
}

test "all settings pages keep a positive modal viewport through tiny resize" {
    for (0..view.modal_heights.len) |page| {
        try std.testing.expect(view.constrainedModalHeight(page, 16) >= 1);
        try std.testing.expect(view.constrainedModalHeight(page, 480) <= 448);
    }
}

test "plugin design previews never become production settings" {
    var f: AppearanceFixture = undefined;
    try f.init();
    defer f.deinit();
    f.controller.model.selectPage(5);
    // Even a retained prototype selection must return the real plugin list.
    for (std.enums.values(@import("config/plugin_page.zig").PreviewKind)) |kind| {
        f.controller.plugin_page.select(.{ .planned = .ftp_ftps });
        try f.controller.plugin_page.showPreview(kind);
        const page = try f.mount();
        try std.testing.expect(byId(page.root, "settings.plugins") != null);
        try std.testing.expect(byId(page.root, "settings.plugin.detail") == null);
        try std.testing.expect(byId(page.root, "capabilities") == null);
        try std.testing.expect(byId(page.root, "permissions") == null);
        try std.testing.expect(byId(page.root, "ftp_ftps") == null);
        try std.testing.expect(byId(page.root, "后续扩展") == null);
        try std.testing.expect(!f.controller.model.dirty);
    }
}

const SettingsProbe = struct {
    requested_key: ?view.Key = null,
    request_count: usize = 0,
    action_value: ?view.Action = null,
    action_count: usize = 0,
    allow_clear: bool = false,
    fn requestEdit(raw: *anyopaque, key: view.Key, _: *ui.Node) void {
        const self: *SettingsProbe = @ptrCast(@alignCast(raw));
        self.requested_key = key;
        self.request_count += 1;
    }
    fn runAction(raw: *anyopaque, value: view.Action) void {
        const self: *SettingsProbe = @ptrCast(@alignCast(raw));
        self.action_value = value;
        self.action_count += 1;
    }
    fn actionState(raw: *anyopaque, value: view.Action) view.ActionState {
        const self: *SettingsProbe = @ptrCast(@alignCast(raw));
        return if ((value == .clear_logs or value == .clear_all) and !self.allow_clear) .{ .enabled = false, .reason = "请先结束活动会话" } else .{};
    }
    fn mount(self: *SettingsProbe, fixture: *AppearanceFixture, page: usize) !view.Mounted {
        fixture.controller.model.selectPage(page);
        const result = try view.mountPage(fixture.cx, fixture.scope, &fixture.controller, .{ .context = self, .changed = changed, .request_edit = requestEdit, .action = runAction, .action_state = actionState, .mount_providers = providers });
        try fixture.cx.root.?.appendChild(fixture.cx.allocator, result.root);
        fixture.cx.layout();
        return result;
    }
};

fn replaceInput(state: *ui.widgets.input.TextInputState, text: []const u8) void {
    inputEvent(state, .{ .key_down = .{ .key = .a, .modifiers = .{ .super = true } } });
    inputEvent(state, .{ .text_input = .{ .text = text } });
}

test "native settings SSH uses precise accordion and inline control geometry" {
    var f: AppearanceFixture = undefined;
    try f.init();
    defer f.deinit();
    f.controller.model.selectPage(2);
    const mounted = try f.mount();
    const connection = byId(mounted.root, "settings.ssh.connection").?;
    const reconnect = byId(mounted.root, "settings.ssh.reconnect").?;
    const keepalive = byId(mounted.root, "settings.field.keepalive_sec").?;
    try std.testing.expectApproxEqAbs(@as(f32, 626), connection.globalRect().w, 0.1);
    try std.testing.expectApproxEqAbs(@as(f32, 279), connection.globalRect().h, 0.1);
    try std.testing.expectApproxEqAbs(@as(f32, 62), reconnect.globalRect().h, 0.1);
    try std.testing.expectApproxEqAbs(@as(f32, 220), keepalive.globalRect().w, 0.1);
    try std.testing.expectApproxEqAbs(@as(f32, 32), keepalive.globalRect().h, 0.1);
    try std.testing.expectApproxEqAbs(@as(f32, 390), keepalive.globalRect().x - connection.globalRect().x, 0.1);
    try std.testing.expectApproxEqAbs(@as(f32, 72.5), keepalive.globalRect().y - connection.globalRect().y, 0.1);
    try std.testing.expect(!byId(mounted.root, "settings.ssh.reconnect.header").?.behavior.interaction.a11y.?.expanded.?);
    try std.testing.expectEqualStrings("30", inputFor(mounted, "settings.field.keepalive_sec").getText());
    try std.testing.expect(!f.controller.model.dirty);
}

test "native settings invalid inline raw and IME survive without remount and Escape restores typed value" {
    var f: AppearanceFixture = undefined;
    try f.init();
    defer f.deinit();
    f.controller.model.selectPage(2);
    const mounted = try f.mount();
    const input = inputFor(mounted, "settings.field.keepalive_sec");
    replaceInput(input, "0");
    try std.testing.expectEqualStrings("0", input.getText());
    try std.testing.expectEqual(@as(u16, 30), f.controller.model.value.ssh.keepalive_sec);
    try std.testing.expectEqual(@import("config/settings_controller.zig").State.dirty_invalid, f.controller.state());
    try std.testing.expect(mounted.save_button.behavior.interaction.a11y.?.disabled);
    try std.testing.expect(textNode(mounted.root, "请输入 1–65535 的整数") != null);
    try std.testing.expectEqual(@as(usize, 0), f.rebuilds);
    f.cx.setFocus(input.input_container_node);
    inputEvent(input, .{ .ime_preedit = .{ .text = "ni", .cursor_utf8_offset = 2 } });
    try std.testing.expect(mounted.isComposing());
    try std.testing.expect(!mounted.consumeEscape());
    inputEvent(input, .{ .ime_preedit = .{ .text = "", .cursor_utf8_offset = 0 } });
    try std.testing.expect(mounted.consumeEscape());
    try std.testing.expectEqualStrings("30", input.getText());
    try std.testing.expect(!f.controller.model.dirty);
    replaceInput(input, "47");
    try std.testing.expectEqual(@as(u16, 47), f.controller.model.value.ssh.keepalive_sec);
    try std.testing.expect(textNode(mounted.root, "连接保活、超时与终端类型") != null);
}

test "native settings reconnect off and zero disable dependencies while retaining raw and typed values" {
    var f: AppearanceFixture = undefined;
    try f.init();
    defer f.deinit();
    f.controller.model.selectPage(2);
    f.controller.folded_sections = 0;
    const mounted = try f.mount();
    const max = inputFor(mounted, "settings.field.reconnect_max");
    const backoff = inputFor(mounted, "settings.field.reconnect_backoff");
    replaceInput(backoff, "[1,2]");
    try std.testing.expect(!f.controller.canSave());
    replaceInput(max, "0");
    try std.testing.expect(!max.disabled);
    try std.testing.expect(backoff.disabled);
    try std.testing.expect(byId(mounted.root, "settings.field.buffer_input").?.behavior.interaction.a11y.?.disabled);
    try std.testing.expect(f.controller.canSave());
    try std.testing.expectEqualStrings("[1,2]", backoff.getText());
    try std.testing.expectEqual([5]u8{ 1, 2, 4, 8, 16 }, f.controller.model.value.ssh.reconnect_backoff);
    try std.testing.expect(textNode(mounted.root, "自动重连与输入缓存") != null);
    clickButton(byId(mounted.root, "settings.field.auto_reconnect").?);
    try std.testing.expect(!f.controller.model.value.ssh.auto_reconnect);
    try std.testing.expect(max.disabled);
    clickButton(byId(mounted.root, "settings.field.auto_reconnect").?);
    try std.testing.expect(!max.disabled);
    try std.testing.expect(backoff.disabled);
    replaceInput(max, "5");
    try std.testing.expect(!backoff.disabled);
    try std.testing.expect(!f.controller.canSave());
    replaceInput(backoff, "[0,3,5,8,13]");
    try std.testing.expect(f.controller.canSave());
    try std.testing.expectEqual(@as(u8, 13), f.controller.model.value.ssh.reconnect_backoff[4]);
}

test "native settings save operation locks controls already mounted" {
    var f: AppearanceFixture = undefined;
    try f.init();
    defer f.deinit();
    f.controller.model.selectPage(2);
    f.controller.folded_sections = 0;
    const mounted = try f.mount();
    const input = inputFor(mounted, "settings.field.keepalive_sec");
    replaceInput(input, "31");
    var save = try f.controller.beginSave(&f.runtime, false);
    defer save.deinit();
    defer _ = f.controller.failSave(&save, error.Cancelled);
    mounted.refreshFooter();
    try std.testing.expect(input.disabled);
    try std.testing.expect(byId(mounted.root, "settings.field.compression").?.behavior.interaction.a11y.?.disabled);
    const before = f.controller.folded_sections;
    const header = byId(mounted.root, "settings.ssh.reconnect.header").?;
    _ = header.behavior.events.on_event.?(.{ .key_down = .{ .key = .space } }, header.behavior.events.event_context);
    try std.testing.expectEqual(before, f.controller.folded_sections);
    try std.testing.expect(byId(mounted.root, "settings.ssh.reconnect.header").?.behavior.interaction.a11y.?.expanded.?);
}

test "native settings shortcut chips show all 27 actions and request a single editable action" {
    var f: AppearanceFixture = undefined;
    try f.init();
    defer f.deinit();
    f.controller.folded_sections = 0;
    var probe: SettingsProbe = .{};
    const mounted = try probe.mount(&f, 1);
    const keys = @import("config/keybindings.zig");
    var count: usize = 0;
    for (std.enums.values(keys.Action)) |action_id| {
        var buffer: [96]u8 = undefined;
        const id = try std.fmt.bufPrint(&buffer, "settings.key.{s}", .{@tagName(action_id)});
        const node = byId(mounted.root, id).?;
        count += 1;
        const before = probe.request_count;
        clickButton(node);
        if (action_id == .recent_tab or action_id == .accept_completion) {
            try std.testing.expectEqual(before, probe.request_count);
        } else {
            try std.testing.expectEqual(before + 1, probe.request_count);
            try std.testing.expectEqualStrings(@tagName(action_id), probe.requested_key.?.key);
            try std.testing.expectEqualStrings("keys", probe.requested_key.?.section);
        }
    }
    try std.testing.expectEqual(@as(usize, 27), count);
    try std.testing.expectEqual(@as(usize, 25), probe.request_count);
    try std.testing.expectApproxEqAbs(@as(f32, 110), byId(mounted.root, "settings.key.tab_9").?.globalRect().w, 0.1);
    try std.testing.expect(!f.controller.model.dirty);
}

test "native settings cross category search retains invalid draft and restores the original page" {
    var f: AppearanceFixture = undefined;
    try f.init();
    defer f.deinit();
    f.controller.editRaw("ui", "font_size", "97") catch {};
    const folds = f.controller.folded_sections;
    try f.controller.setSearch("重连");
    try std.testing.expectEqual(@as(usize, 0), f.controller.model.page_index);
    const mounted = try f.mount();
    try std.testing.expect(textNode(mounted.root, "4 个结果 · SSH 与网络") == null);
    try std.testing.expect(byId(mounted.root, "settings.ssh.connection") == null);
    try std.testing.expect(byId(mounted.root, "settings.field.reconnect_max") != null);
    try std.testing.expect(byId(mounted.root, "settings.notifications.events") != null);
    try std.testing.expect(byId(mounted.root, "settings.field.reconnect") != null);
    try std.testing.expect(byId(mounted.root, "settings.field.transfer_done") == null);
    try f.controller.setSearch("通知");
    const category = try f.mount();
    try std.testing.expect(byId(category.root, "settings.notifications.attention") != null);
    try std.testing.expect(byId(category.root, "settings.field.quiet_hours") != null);
    try f.controller.setSearch("unmatched-setting-zzz");
    const empty = try f.mount();
    try std.testing.expect(textNode(empty.root, "没有匹配的设置") != null);
    try std.testing.expectEqualStrings("unmatched-setting-zzz", f.controller.search_query);
    try f.controller.setSearch("");
    try std.testing.expectEqual(@as(usize, 0), f.controller.model.page_index);
    try std.testing.expectEqual(folds, f.controller.folded_sections);
    try std.testing.expectEqualStrings("97", f.controller.raw_fields[@import("config/settings_schema.zig").find("ui", "font_size").?].input.?);
}

test "native settings data actions use host availability and leave the draft intact" {
    var f: AppearanceFixture = undefined;
    try f.init();
    defer f.deinit();
    f.controller.folded_sections = 0;
    try f.controller.editKey("ui", "font_size", .{ .unsigned = 18 });
    var probe: SettingsProbe = .{};
    const blocked = try probe.mount(&f, 7);
    const clear = byId(blocked.root, "settings.data.clear_logs").?;
    const clear_all = byId(blocked.root, "settings.data.clear_all").?;
    try std.testing.expect(clear_all.behavior.interaction.a11y.?.disabled);
    clickButton(clear_all);
    try std.testing.expect(textNode(blocked.root, "存储于 macOS 钥匙串") != null);
    try std.testing.expect(textNode(blocked.root, "~/.zerowork/") == null);
    try std.testing.expect(clear.behavior.interaction.a11y.?.disabled);
    clickButton(clear);
    try std.testing.expectEqual(@as(usize, 0), probe.action_count);
    probe.allow_clear = true;
    const ready = try probe.mount(&f, 7);
    clickButton(byId(ready.root, "settings.data.clear_logs").?);
    try std.testing.expectEqual(view.Action.clear_logs, probe.action_value.?);
    try std.testing.expectEqual(@as(usize, 1), probe.action_count);
    clickButton(byId(ready.root, "settings.data.clear_all").?);
    try std.testing.expectEqual(view.Action.clear_all, probe.action_value.?);
    try std.testing.expectEqual(@as(usize, 2), probe.action_count);
    try std.testing.expectEqual(@as(u16, 18), f.controller.model.value.ui.font_size);
    try std.testing.expect(f.controller.model.dirty);
}

test "native settings field help is an inline description without a focus stealing action" {
    var f: AppearanceFixture = undefined;
    try f.init();
    defer f.deinit();
    f.controller.model.selectPage(2);
    f.controller.folded_sections = 0;
    const mounted = try f.mount();
    const help = byId(mounted.root, "settings.help.content.totp_autofill").?;
    try std.testing.expect(help.getText().?.content.len != 0);
    try std.testing.expect(!help.behavior.interaction.focusable);
    try std.testing.expect(byId(mounted.root, "settings.help.totp_autofill") == null);
    try std.testing.expect(!mounted.consumeEscape());
    try std.testing.expect(!f.controller.model.dirty);
}

fn nonemptyTexts(node: *ui.Node) usize {
    if (node.style.display == .none) return 0;
    var count: usize = if (node.getText()) |text| @intFromBool(text.content.len != 0) else 0;
    for (node.children.items) |child| count += nonemptyTexts(child);
    return count;
}
fn sectionSummary(node: *ui.Node) ?*ui.Node {
    if (node.meta.ownership.meta.test_id) |id| if (std.mem.endsWith(u8, id, ".summary")) return node;
    for (node.children.items) |child| if (sectionSummary(child)) |found| return found;
    return null;
}
fn expectCleanSectionHeaders(node: *ui.Node) !void {
    if (node.meta.ownership.meta.test_id) |id| {
        if (std.mem.endsWith(u8, id, ".header")) {
            if (sectionSummary(node)) |value| {
                try std.testing.expect(value.getText() != null);
                const shown = value.getText().?.content.len != 0;
                try std.testing.expectEqual(if (shown) ui.types.Display.flex else ui.types.Display.none, value.style.display);
                try std.testing.expectEqual(@as(usize, if (shown) 2 else 1), nonemptyTexts(node));
                // Title + summary form the flexible middle column, leaving the
                // native chevron at the trailing edge even on narrow panels.
                try std.testing.expect(node.children.items.len == 3 or node.children.items.len == 4);
                const heading = node.children.items[1];
                try std.testing.expectEqual(@as(f32, 1), heading.style.flex);
                if (shown) {
                    const title = heading.children.items[0].globalRect();
                    const detail = value.globalRect();
                    try std.testing.expectApproxEqAbs(title.x, detail.x, 0.1);
                    try std.testing.expect(detail.y >= title.y + title.h + 1.9);
                }
            } else try std.testing.expectEqual(@as(usize, 1), nonemptyTexts(node));
        }
    }
    for (node.children.items) |child| try expectCleanSectionHeaders(child);
}

test "native settings section headers retain V3 descriptions while actual fields remain editable" {
    for (0..8) |index| {
        var f: AppearanceFixture = undefined;
        try f.init();
        defer f.deinit();
        f.controller.model.selectPage(index);
        f.controller.folded_sections = 0;
        const mounted = try view.mountPage(f.cx, f.scope, &f.controller, .{ .context = &f, .changed = AppearanceFixture.rebuild, .request_edit = request, .action = action, .appearance = &f.context, .mount_providers = providers });
        try f.cx.root.?.appendChild(f.cx.allocator, mounted.root);
        f.cx.layout();
        try expectCleanSectionHeaders(mounted.root);
        if (index == 2) {
            const keepalive = inputFor(mounted, "settings.field.keepalive_sec");
            replaceInput(keepalive, "44");
            try std.testing.expectEqual(@as(u16, 44), f.controller.model.value.ssh.keepalive_sec);
        }
        if (index == 4) {
            const permissions = byId(mounted.root, "settings.ai.permissions.header").?;
            try std.testing.expect(textNode(permissions, "确认后执行") == null);
            try std.testing.expect(textNode(byId(mounted.root, "settings.field.permission_mode").?, "确认后执行") != null);
        }
    }
}

test "native settings section headers retain readable collapsed summaries across all pages" {
    for (0..8) |index| {
        var f: AppearanceFixture = undefined;
        try f.init();
        defer f.deinit();
        f.controller.model.selectPage(index);
        f.controller.folded_sections = std.math.maxInt(u64);
        const mounted = try view.mountPage(f.cx, f.scope, &f.controller, .{ .context = &f, .changed = AppearanceFixture.rebuild, .request_edit = request, .action = action, .appearance = &f.context, .mount_providers = providers });
        try f.cx.root.?.appendChild(f.cx.allocator, mounted.root);
        f.cx.layout();
        try expectCleanSectionHeaders(mounted.root);
        if (index == 0) {
            const selected = f.registry.get(f.controller.model.value.ui.theme).?.theme.name;
            try std.testing.expectEqualStrings(selected, byId(mounted.root, "settings.appearance.themes.summary").?.getText().?.content);
            try std.testing.expectEqualStrings("辅助显示与侧栏", byId(mounted.root, "settings.appearance.aids.summary").?.getText().?.content);
        }
        if (index == 7) {
            const value = byId(mounted.root, "settings.data.history.summary").?;
            try std.testing.expectEqualStrings("缓冲、快照与保留策略", value.getText().?.content);
        }
    }
}

test "native settings unit suffixes stay outside editable numeric values" {
    var f: AppearanceFixture = undefined;
    try f.init();
    defer f.deinit();
    f.controller.model.selectPage(7);
    f.controller.folded_sections = 0;
    const mounted = try f.mount();
    for ([_][]const u8{ "ring_mb", "checkpoint_sec", "retention_days" }, [_][]const u8{ "MiB", "秒", "天" }) |name, unit| {
        var buffer: [96]u8 = undefined;
        const id = try std.fmt.bufPrint(&buffer, "settings.field.{s}", .{name});
        try std.testing.expect(textNode(byId(mounted.root, id).?, unit) != null);
    }
    const input = inputFor(mounted, "settings.field.ring_mb");
    try std.testing.expectEqualStrings("64", input.getText());
    replaceInput(input, "128");
    try std.testing.expectEqual(@as(u16, 128), f.controller.model.value.log.ring_mb);
    try std.testing.expectEqualStrings("缓冲、快照与保留策略", byId(mounted.root, "settings.data.history.summary").?.getText().?.content);
    try std.testing.expectEqual(ui.types.Display.flex, byId(mounted.root, "settings.data.history.summary").?.style.display);
}

// Presentation rounding must never write the rounded value back without input.
test "settings line height display preserves precise value when submitted unchanged" {
    var f: AppearanceFixture = undefined;
    try f.init();
    defer f.deinit();
    f.controller.folded_sections = 0;
    f.controller.model.value.ui.line_height = 1.5714285;
    const expected = f.controller.model.value.ui.line_height;
    const mounted = try f.mount();
    const input = inputFor(mounted, "settings.field.line_height");
    try std.testing.expectEqualStrings("1.57", input.getText());
    f.cx.setFocus(input.input_container_node);
    f.cx.handleKeyDown(.@"return", .{});
    try std.testing.expectEqual(expected, f.controller.model.value.ui.line_height);
}

test "settings section cards explicitly suppress inherited outline on every edge" {
    const cx = try ui.Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    const root = try ui.box(cx, .{}, .{});
    cx.root = root;
    const scope = try ui.Scope.init(std.testing.allocator, null, cx.owner);
    defer scope.dispose();
    var controller = try @import("config/settings_controller.zig").Controller.init(std.testing.allocator, .{});
    defer controller.deinit();
    controller.model.selectPage(2);
    var context: u8 = 0;
    const content = try view.mountContent(cx, scope, &controller, .{ .context = &context, .changed = changed, .request_edit = request, .action = action, .mount_providers = providers });
    try root.appendChild(cx.allocator, content);
    const card = byId(content, "settings.ssh.connection").?;
    for (card.style.border.resolvedWidths()) |edge| try std.testing.expectEqual(@as(f32, 0), edge);
}
