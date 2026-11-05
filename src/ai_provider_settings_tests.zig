const std = @import("std");
const ui = @import("ui");
const view = @import("config/ai_provider_settings.zig");
const draft = @import("config/settings_ai_draft.zig");
const Config = @import("config/config.zig");
const Controller = @import("config/settings_controller.zig").Controller;

const Fixture = struct {
    cx: *ui.Cx,
    scope: *ui.Scope,
    view_scope: *ui.Scope,
    controller: Controller,
    mounted: *view.ProviderView,
    saving: *ui.Signal(bool),
    changes: usize = 0,
    fn init(self: *Fixture, configured: bool) !void {
        return self.initWithCount(configured, if (configured) 1 else 0);
    }
    fn initWithCount(self: *Fixture, configured: bool, count: usize) !void {
        return self.initWithExpansion(configured, count, true);
    }
    fn initWithExpansion(self: *Fixture, configured: bool, count: usize, open_first: bool) !void {
        self.cx = try ui.Cx.init(std.testing.allocator, std.testing.io);
        try self.cx.setTestFrameStep(100);
        self.cx.setViewport(600, 700);
        self.cx.root = try ui.box(self.cx, .{ .width = .fill(), .height = .fill(), .direction = .column }, .{});
        self.scope = try ui.Scope.init(std.testing.allocator, null, self.cx.owner);
        var models = [_]Config.AiModel{ .{ .id = "configured-model", .context_window = 200000, .default = true, .reasoning = true, .vision = true }, .{ .id = "model-2", .context_window = 128000 } };
        var providers = Config.default_providers;
        if (configured) {
            providers[0].name = "anthropic";
            providers[0].endpoint = "https://example.test/v1/messages";
            providers[0].api_key = "test-key";
            providers[0].models = models[0..1];
            providers[0].model_count = 1;
            providers[0].enabled = true;
        }
        var value: Config.Config = .{};
        value.ai.providers = &providers;
        value.ai.provider_count = count;
        self.controller = try Controller.init(std.testing.allocator, value);
        // Editing/layout fixtures explicitly open the form they exercise.
        if (open_first and count > 0) try self.controller.ai_fields.provider_open.put(std.testing.allocator, 0, true);
        self.saving = try self.scope.createSignal(bool, false);
        self.changes = 0;
        self.view_scope = try self.scope.childScope();
        self.mounted = try view.ProviderView.mountWithHooks(self.cx, self.view_scope, &self.controller, .{ .context = self, .changed = changed, .saving = self.saving });
        try self.cx.root.?.appendChild(self.cx.allocator, self.mounted.root);
        self.frame();
    }
    fn remount(self: *Fixture) !void {
        const old = self.mounted.root;
        self.cx.detachChild(self.cx.root.?, old);
        self.view_scope.dispose();
        self.cx.destroyDetached(old);
        self.view_scope = try self.scope.childScope();
        self.mounted = try view.ProviderView.mountWithHooks(self.cx, self.view_scope, &self.controller, .{ .context = self, .changed = changed, .saving = self.saving });
        try self.cx.root.?.appendChild(self.cx.allocator, self.mounted.root);
        self.frame();
    }
    fn deinit(self: *Fixture) void {
        self.scope.dispose();
        self.controller.deinit();
        self.cx.deinit();
    }
    fn changed(raw: *anyopaque) void {
        const self: *Fixture = @ptrCast(@alignCast(raw));
        self.changes += 1;
    }
    fn frame(self: *Fixture) void {
        self.cx.requestRedraw();
        self.cx.advanceFrameClock();
        _ = self.cx.render();
    }
    fn clickId(self: *Fixture, id: []const u8) void {
        const node = byId(self.cx.root.?, id).?;
        if (node.behavior.events.on_click) |handler| handler.invoke() else if (node.behavior.events.on_event) |handler| {
            _ = handler(.{ .click = .{ .x = 0, .y = 0 } }, node.behavior.events.event_context);
        }
        self.frame();
        self.frame();
    }
    fn input(self: *Fixture, id: []const u8) *ui.widgets.input.TextInputState {
        if (std.mem.eql(u8, id, "settings.ai.model.id") and byId(self.cx.root.?, id) == null) self.clickId("settings.ai.model.catalog");
        const node = byId(self.cx.root.?, id).?;
        return @ptrCast(@alignCast(node.behavior.events.event_context.?));
    }
    fn replace(self: *Fixture, id: []const u8, value: []const u8) void {
        const state = self.input(id);
        inputEvent(state, .{ .key_down = .{ .key = .a, .modifiers = .{ .super = true } } });
        inputEvent(state, .{ .text_input = .{ .text = value } });
        if (std.mem.eql(u8, id, "settings.ai.model.id")) {
            self.clickId("settings.ai.model.catalog.manual");
            self.capabilities(false, false);
        }
    }
    fn capabilities(self: *Fixture, reasoning: bool, vision: bool) void {
        self.clickId("settings.ai.model.reasoning");
        self.clickId(if (reasoning) "settings.ai.model.reasoning.yes" else "settings.ai.model.reasoning.no");
        self.clickId("settings.ai.model.vision");
        self.clickId(if (vision) "settings.ai.model.vision.yes" else "settings.ai.model.vision.no");
    }
};
fn byId(node: *ui.Node, id: []const u8) ?*ui.Node {
    if (node.meta.ownership.meta.test_id) |value| if (std.mem.eql(u8, value, id)) return node;
    for (node.children.items) |child| if (byId(child, id)) |found| return found;
    return null;
}
fn hasText(node: *ui.Node, value: []const u8) bool {
    if (node.getText()) |text| if (std.mem.eql(u8, text.content, value)) return true;
    for (node.children.items) |child| if (hasText(child, value)) return true;
    return false;
}
fn inputEvent(state: *ui.widgets.input.TextInputState, event: ui.events.Event) void {
    _ = ui.widgets.input.inputEventHandler(event, state);
}

test "native provider cards default collapsed and preserve manual expansion within settings" {
    var f: Fixture = undefined;
    try f.initWithExpansion(true, 2, false);
    defer f.deinit();
    for (0..2) |i| {
        var buffer: [64]u8 = undefined;
        const id = try std.fmt.bufPrint(&buffer, "settings.ai.provider.{d}.header", .{i});
        try std.testing.expect(!byId(f.mounted.root, id).?.behavior.interaction.a11y.?.expanded.?);
    }
    try std.testing.expectApproxEqAbs(@as(f32, 64), byId(f.mounted.root, "settings.ai.provider.0.card").?.globalRect().h, 0.1);
    f.clickId("settings.ai.provider.0.header");
    try std.testing.expect(byId(f.mounted.root, "settings.ai.provider.0.header").?.behavior.interaction.a11y.?.expanded.?);
    try f.remount();
    try std.testing.expect(byId(f.mounted.root, "settings.ai.provider.0.header").?.behavior.interaction.a11y.?.expanded.?);
    try std.testing.expect(!byId(f.mounted.root, "settings.ai.provider.1.header").?.behavior.interaction.a11y.?.expanded.?);
    try std.testing.expect(!f.controller.model.dirty);
    try std.testing.expectEqual(@as(usize, 0), f.changes);
}

test "provider enabled status stays readable in every builtin at maximum transparency" {
    const theme = @import("ui/app_theme.zig");
    const previous = theme.currentName();
    const parameters = theme.materialParameters();
    defer {
        theme.select(previous);
        _ = theme.setMaterialParameters(parameters.transparency, parameters.blur);
    }
    for (@import("config/theme_presets.zig").ids) |id| {
        theme.selectTokens(@import("config/theme_registry.zig").builtinTokens(id));
        _ = theme.setMaterialParameters(100, 0);
        var f: Fixture = undefined;
        try f.init(true);
        defer f.deinit();
        const badge = byId(f.mounted.root, "settings.ai.provider.0.status").?;
        const background = badge.getBackground();
        try std.testing.expectEqual(theme.popupInset(), background);
        const ink = badge.getText().?.color;
        const low = @min(statusLuminance(ink), statusLuminance(background));
        const high = @max(statusLuminance(ink), statusLuminance(background));
        try std.testing.expect((high + 0.05) / (low + 0.05) >= 4.5);
        try std.testing.expectEqualStrings("已启用", badge.getText().?.content);
    }
}
fn statusLuminance(c: ui.Color) f64 {
    var result: f64 = 0;
    inline for (.{ "r", "g", "b" }, .{ 0.2126, 0.7152, 0.0722 }) |field, weight| {
        const channel = @as(f64, @floatFromInt(@field(c, field))) / 255;
        result += weight * (if (channel <= 0.04045) channel / 12.92 else std.math.pow(f64, (channel + 0.055) / 1.055, 2.4));
    }
    return result;
}

// The configured fixture reproduces the prototype's single model and collapsed connection details.
test "native provider cards use V3 header field grid and a single model row" {
    var f: Fixture = undefined;
    try f.initWithCount(true, 2);
    defer f.deinit();
    const first = byId(f.mounted.root, "settings.ai.provider.0.card").?.globalRect();
    const second = byId(f.mounted.root, "settings.ai.provider.1.card").?.globalRect();
    const header = byId(f.mounted.root, "settings.ai.provider.0.header").?.globalRect();
    const model = byId(f.mounted.root, "settings.ai.provider.0.model.0.card").?.globalRect();
    try std.testing.expectApproxEqAbs(@as(f32, 580), first.w, 0.1);
    try std.testing.expectApproxEqAbs(@as(f32, 64), header.h, 0.1);
    try std.testing.expectApproxEqAbs(@as(f32, 64), second.h, 0.1);
    try std.testing.expectApproxEqAbs(@as(f32, 60), model.h, 0.1);
    const name = byId(f.mounted.root, "settings.ai.provider.0.name").?.globalRect();
    const kind = byId(f.mounted.root, "settings.ai.provider.0.kind").?.globalRect();
    const endpoint = byId(f.mounted.root, "settings.ai.provider.0.endpoint").?.globalRect();
    try std.testing.expectApproxEqAbs(name.y, kind.y, 0.1);
    try std.testing.expectApproxEqAbs(name.w, kind.w, 0.1);
    try std.testing.expectApproxEqAbs(@as(f32, 14), kind.x - name.x - name.w, 0.1);
    try std.testing.expectApproxEqAbs(@as(f32, 552), endpoint.w, 0.1);
    try std.testing.expect(hasText(f.mounted.root, "已启用"));
    try std.testing.expectEqualStrings("API Key 存储于 macOS 钥匙串", byId(f.mounted.root, "settings.ai.provider.0.keychain").?.behavior.interaction.a11y.?.label.?);
    try std.testing.expect(!f.controller.model.dirty);
}

test "native provider invalid endpoint retains raw typed value footer gate and field Escape across page remount" {
    var f: Fixture = undefined;
    try f.init(true);
    defer f.deinit();
    const endpoint = f.input("settings.ai.provider.0.endpoint");
    f.replace("settings.ai.provider.0.endpoint", "gateway-without-scheme");
    try std.testing.expectEqualStrings("https://example.test/v1/messages", f.controller.model.value.ai.providers[0].endpoint);
    try std.testing.expectEqualStrings("gateway-without-scheme", f.controller.ai_fields.get(.{ .provider = 0, .field = .endpoint }).?.input);
    try std.testing.expectEqual(@import("config/settings_controller.zig").State.dirty_invalid, f.controller.state());
    try std.testing.expect(!f.controller.canSave());
    try std.testing.expect(f.changes > 0);
    f.frame();
    try std.testing.expect(endpoint.has_error);
    const invalid_node = byId(f.mounted.root, "settings.ai.provider.0.endpoint").?;
    const colors = @import("ui/app_theme.zig");
    try std.testing.expectEqual(if (endpoint.focused) colors.states().error_focus else colors.states().tag_danger, invalid_node.getBackground());
    // Closing and reopening retains the input instance and its invalid raw draft.
    f.clickId("settings.ai.provider.0.header");
    f.clickId("settings.ai.provider.0.header");
    const restored = f.input("settings.ai.provider.0.endpoint");
    try std.testing.expectEqualStrings("gateway-without-scheme", restored.getText());
    f.cx.setFocus(byId(f.mounted.root, "settings.ai.provider.0.endpoint").?);
    try std.testing.expect(f.mounted.consumeEscape());
    try std.testing.expectEqualStrings("https://example.test/v1/messages", restored.getText());
    try std.testing.expectEqual(@import("config/settings_controller.zig").State.clean, f.controller.state());
    f.frame();
    try std.testing.expect(!restored.has_error);
    try std.testing.expectEqual(if (restored.focused) colors.states().focus else colors.popupInset(), byId(f.mounted.root, "settings.ai.provider.0.endpoint").?.getBackground());
    try std.testing.expect(!f.mounted.consumeEscape());
}

test "native provider model dialog cancel preserves existing models and unrelated settings" {
    var f: Fixture = undefined;
    try f.init(true);
    defer f.deinit();
    try f.controller.editRaw("ssh", "keepalive_sec", "44");
    f.clickId("settings.ai.provider.0.add_model");
    try std.testing.expectEqual(@as(usize, 1), f.controller.model.value.ai.providers[0].model_count);
    f.replace("settings.ai.model.id", "ops-model-2");
    f.replace("settings.ai.model.context", "128000");
    try std.testing.expectEqual(@as(usize, 1), f.controller.model.value.ai.providers[0].model_count);
    f.clickId("settings.ai.model.cancel");
    try std.testing.expect(!f.mounted.hasModelEditor());
    try std.testing.expectEqualStrings("configured-model", f.controller.model.value.ai.providers[0].models[0].id);
    try std.testing.expect(f.controller.model.value.ai.providers[0].models[0].default);
    try std.testing.expectEqual(@as(u16, 44), f.controller.model.value.ssh.keepalive_sec);
    try std.testing.expect(f.controller.canSave());
}

test "native provider create local Ollama form saves vision independently and reloads without network" {
    var f: Fixture = undefined;
    try f.init(false);
    defer f.deinit();
    f.clickId("settings.ai.add_provider");
    try std.testing.expectEqual(@as(usize, 1), f.controller.model.value.ai.provider_count);
    f.replace("settings.ai.provider.0.name", "Production Gateway");
    // Use the existing provider edit API to choose the local adapter; no transport is invoked.
    var owned = try @import("config/runtime_config.zig").Snapshot.init(std.testing.allocator, f.controller.model.value);
    defer owned.deinit();
    owned.value.ai.providers[0].kind = .ollama;
    try f.controller.editProviders(owned.value.ai);
    f.replace("settings.ai.provider.0.endpoint", "http://127.0.0.1:11434/api/chat");
    f.clickId("settings.ai.provider.0.add_model");
    f.replace("settings.ai.model.id", "local-model");
    f.replace("settings.ai.model.context", "8192");
    f.capabilities(false, true);
    f.clickId("settings.ai.model.save");
    const model = f.controller.model.value.ai.providers[0].models[0];
    try std.testing.expect(model.vision and !model.reasoning);
    try std.testing.expectEqualStrings("", f.controller.model.value.ai.providers[0].api_key);
    try std.testing.expect(f.controller.model.value.ai.providers[0].enabled);
    // Explicit enable initializes a missing default; selection remains the same draft transaction.
    try f.controller.selectProvider("Production Gateway");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var target = try @import("config/runtime_config.zig").RuntimeConfig.loadOrDefault(std.testing.io, tmp.dir, std.testing.allocator, "settings.toml");
    defer target.deinit();
    try f.controller.save(std.testing.io, tmp.dir, &target);
    var loaded = try @import("config/runtime_config.zig").RuntimeConfig.loadOrDefault(std.testing.io, tmp.dir, std.testing.allocator, "settings.toml");
    defer loaded.deinit();
    try std.testing.expect(loaded.value.ai.providers[0].models[0].vision);
    try std.testing.expect(!loaded.value.ai.providers[0].models[0].reasoning);
    try std.testing.expectEqualStrings("Production Gateway", loaded.value.ai.default_provider);
    try std.testing.expectEqual(@import("config/settings_controller.zig").State.clean, f.controller.state());
}

test "native provider model dialog rejects duplicate ids zero windows and missing reasoning efforts without mutating the draft" {
    var f: Fixture = undefined;
    try f.init(true);
    defer f.deinit();
    f.clickId("settings.ai.provider.0.add_model");
    f.replace("settings.ai.model.id", "configured-model");
    f.replace("settings.ai.model.context", "128000");
    f.clickId("settings.ai.model.save");
    try std.testing.expectEqualStrings(draft.problemText(error.DuplicateModelId), f.mounted.model_editor.?.error_text.peek());
    f.replace("settings.ai.model.id", "other");
    f.replace("settings.ai.model.context", "0");
    f.clickId("settings.ai.model.save");
    try std.testing.expectEqualStrings(draft.problemText(error.InvalidContextWindow), f.mounted.model_editor.?.error_text.peek());
    f.clickId("settings.ai.model.cancel");
    f.clickId("settings.ai.provider.0.model.0.edit_model");
    for (f.mounted.model_editor.?.efforts) |effort| effort.set(false);
    f.clickId("settings.ai.model.save");
    try std.testing.expectEqualStrings(draft.problemText(error.LastEffortRequired), f.mounted.model_editor.?.error_text.peek());
    try std.testing.expect(f.controller.model.value.ai.providers[0].models[0].efforts[2]);
    f.clickId("settings.ai.model.cancel");
    f.clickId("settings.ai.provider.0.model.0.delete_model");
    try std.testing.expectEqual(@as(usize, 1), f.controller.model.value.ai.providers[0].model_count);
}

test "native provider pending transaction disables mounted controls and protects IME Escape" {
    var f: Fixture = undefined;
    try f.init(true);
    defer f.deinit();
    const state = f.input("settings.ai.provider.0.name");
    inputEvent(state, .{ .ime_preedit = .{ .text = "pin", .cursor_utf8_offset = 3 } });
    try std.testing.expect(f.mounted.isComposing());
    f.cx.setFocus(byId(f.mounted.root, "settings.ai.provider.0.name").?);
    try std.testing.expect(!f.mounted.consumeEscape());
    inputEvent(state, .{ .ime_preedit = .{ .text = "", .cursor_utf8_offset = 0 } });
    f.controller.save_operation = 7;
    f.saving.set(true);
    f.frame();
    try std.testing.expect(state.disabled);
    const count = f.controller.model.value.ai.provider_count;
    f.clickId("settings.ai.add_provider");
    try std.testing.expectEqual(count, f.controller.model.value.ai.provider_count);
    f.controller.save_operation = null;
}

test "native provider endpoint policy rejects credentials fragments missing hosts and model defaults stay scoped" {
    for ([_][]const u8{ "example.test/v1", "ftp://example.test", "http:///path", "https://u:p@example.test", "https://example.test/#fragment", "https://example.test/\x00" }) |url| try std.testing.expect(!draft.endpointValid(url));
    try std.testing.expect(draft.endpointValid("http://127.0.0.1:11434/api/chat"));
    try std.testing.expect(draft.endpointValid("https://example.test/v1/chat/completions"));
    var f: Fixture = undefined;
    try f.init(true);
    defer f.deinit();
    try f.controller.editAiRaw(.{ .provider = 0, .field = .name }, "renamed");
    try std.testing.expectEqualStrings("renamed", f.controller.model.value.ai.default_provider);
    try f.controller.editAiRaw(.{ .provider = 0, .field = .api_key }, "");
    try std.testing.expect(!f.controller.canSave());
}

test "native provider disclosure accepts actual Cx pointer independently of enable" {
    var f: Fixture = undefined;
    try f.init(true);
    defer f.deinit();
    const header = byId(f.mounted.root, "settings.ai.provider.0.header").?;
    const rect = header.globalRect();
    f.cx.handleClick(rect.x + rect.w / 2, rect.y + rect.h / 2);
    for (0..4) |_| f.frame();
    try std.testing.expect(!(f.controller.ai_fields.provider_open.get(0) orelse true));
    try std.testing.expect(f.controller.model.value.ai.providers[0].enabled);
    try std.testing.expectApproxEqAbs(@as(f32, 64), byId(f.mounted.root, "settings.ai.provider.0.card").?.globalRect().h, 0.1);
    f.clickId("settings.ai.provider.0.header");
    try std.testing.expect(byId(f.mounted.root, "settings.ai.provider.0.endpoint").?.isDisplayedInTree());
    try std.testing.expect(hasText(byId(f.mounted.root, "settings.ai.provider.0.kind").?, "Anthropic"));
}

test "native provider focused add model pointer opens isolated editor and cancel restores the underlying page" {
    var f: Fixture = undefined;
    try f.init(true);
    defer f.deinit();
    const add = byId(f.mounted.root, "settings.ai.provider.0.add_model").?;
    f.cx.setFocus(add);
    const rect = add.globalRect();
    f.cx.handleClick(rect.x + rect.w / 2, rect.y + rect.h / 2);
    for (0..6) |_| f.frame();
    try std.testing.expectEqual(@as(usize, 1), f.controller.model.value.ai.providers[0].model_count);
    const editor = byId(f.cx.root.?, "settings.ai.model.catalog").?;
    try std.testing.expect(editor.isDisplayedInTree());
    f.replace("settings.ai.model.id", "ops-model-2");
    f.replace("settings.ai.model.context", "128000");
    const cancel = byId(f.cx.root.?, "settings.ai.model.cancel").?;
    f.cx.setFocus(cancel);
    const cancel_rect = cancel.globalRect();
    f.cx.handleClick(cancel_rect.x + cancel_rect.w / 2, cancel_rect.y + cancel_rect.h / 2);
    for (0..6) |_| f.frame();
    try std.testing.expectEqual(@as(usize, 1), f.controller.model.value.ai.providers[0].model_count);
    try std.testing.expect(!f.mounted.hasModelEditor());
    try std.testing.expect(byId(f.cx.root.?, "settings.ai.model.id") == null);
}

test "native provider model dialog preserves an active composition before Escape can cancel" {
    var f: Fixture = undefined;
    try f.init(true);
    defer f.deinit();
    f.clickId("settings.ai.provider.0.model.0.edit_model");
    const state = f.input("settings.ai.model.id");
    inputEvent(state, .{ .ime_preedit = .{ .text = "pin", .cursor_utf8_offset = 3 } });
    try std.testing.expect(f.mounted.isComposing());
    try std.testing.expect(!f.mounted.consumeEscape());
    try std.testing.expect(!f.mounted.model_editor.?.done);
    inputEvent(state, .{ .ime_preedit = .{ .text = "", .cursor_utf8_offset = 0 } });
    try std.testing.expect(f.mounted.consumeEscape()); // close model search first
    f.frame();
    try std.testing.expect(f.mounted.hasModelEditor());
    try std.testing.expect(f.mounted.consumeEscape());
    for (0..6) |_| f.frame();
    try std.testing.expect(!f.mounted.hasModelEditor());
    try std.testing.expectEqualStrings("configured-model", f.controller.model.value.ai.providers[0].models[0].id);
}

fn configureInactive(f: *Fixture, index: usize, name: []const u8) !void {
    var owned = try @import("config/runtime_config.zig").Snapshot.init(std.testing.allocator, f.controller.model.value);
    defer owned.deinit();
    const p = &owned.value.ai.providers[index];
    p.name = name;
    p.kind = .ollama;
    p.endpoint = "http://127.0.0.1:9/api/chat";
    p.api_key = "";
    p.enabled = false;
    p.models = try owned.arena.allocator().alloc(Config.AiModel, 1);
    p.models[0] = .{ .id = "fixture-model", .context_window = 8192, .default = true };
    p.model_count = 1;
    try f.controller.editProviders(owned.value.ai);
    // A direct structural fixture edit must explicitly refresh the view.
    // Folding no longer acts as an accidental form rebuild.
    try f.remount();
}

test "native provider explicit enable protects the last default and selects an enabled replacement" {
    var f: Fixture = undefined;
    try f.initWithCount(false, 2);
    defer f.deinit();
    try configureInactive(&f, 0, "first");
    try configureInactive(&f, 1, "second");
    try std.testing.expect(!f.controller.model.value.ai.providers[0].enabled);
    f.replace("settings.ai.provider.0.endpoint", "http://localhost:9/api/chat");
    try std.testing.expect(!f.controller.model.value.ai.providers[0].enabled);
    f.clickId("settings.ai.provider.0.enabled");
    try std.testing.expect(f.controller.model.value.ai.providers[0].enabled);
    try std.testing.expectEqualStrings("first", f.controller.model.value.ai.default_provider);
    const folded = f.controller.ai_fields.provider_open.get(0) orelse true;
    f.clickId("settings.ai.provider.0.enabled");
    try std.testing.expect(f.controller.model.value.ai.providers[0].enabled);
    try std.testing.expectEqualStrings(draft.problemText(error.DefaultProtected), f.mounted.error_text);
    try std.testing.expectEqual(folded, f.controller.ai_fields.provider_open.get(0) orelse true);
    f.clickId("settings.ai.provider.1.enabled");
    try std.testing.expect(f.controller.model.value.ai.providers[1].enabled);
    f.clickId("settings.ai.provider.0.enabled");
    try std.testing.expect(!f.controller.model.value.ai.providers[0].enabled);
    try std.testing.expectEqualStrings("second", f.controller.model.value.ai.default_provider);
}

test "native provider reveal key is transient and deletion requires explicit confirmation" {
    var f: Fixture = undefined;
    try f.initWithCount(true, 2);
    defer f.deinit();
    const key_input = f.input("settings.ai.provider.0.api_key");
    f.clickId("settings.ai.provider.0.reveal_key");
    try std.testing.expectEqual(ui.widgets.InputType.text, key_input.input_type);
    f.clickId("settings.ai.provider.0.reveal_key");
    try std.testing.expectEqual(ui.widgets.InputType.password, key_input.input_type);
    try std.testing.expect(!f.controller.model.dirty);
    try configureInactive(&f, 1, "inactive");
    f.clickId("settings.ai.provider.1.header");
    f.clickId("settings.ai.provider.1.model.0.delete_model");
    try std.testing.expect(f.mounted.hasModelEditor());
    try std.testing.expectEqual(@as(usize, 1), f.controller.model.value.ai.providers[1].model_count);
    f.clickId("settings.ai.delete.cancel");
    try std.testing.expect(!f.mounted.hasModelEditor());
    try std.testing.expectEqual(@as(usize, 1), f.controller.model.value.ai.providers[1].model_count);
    f.clickId("settings.ai.provider.1.model.0.delete_model");
    f.clickId("settings.ai.delete.confirm");
    try std.testing.expectEqual(@as(usize, 0), f.controller.model.value.ai.providers[1].model_count);
    try std.testing.expect(!f.controller.model.value.ai.providers[1].enabled);
}

test "native provider empty registry shows first add action and creates only a draft" {
    var f: Fixture = undefined;
    try f.initWithCount(false, 0);
    defer f.deinit();
    try std.testing.expect(byId(f.mounted.root, "settings.ai.providers.empty") != null);
    try std.testing.expect(byId(f.mounted.root, "settings.ai.provider.0.card") == null);
    f.clickId("settings.ai.providers.empty.add");
    try std.testing.expectEqual(@as(usize, 1), f.controller.model.value.ai.provider_count);
    try std.testing.expect(byId(f.mounted.root, "settings.ai.providers.empty") == null);
    try std.testing.expect(byId(f.mounted.root, "settings.ai.provider.0.name") != null);
    try std.testing.expectEqual(@as(usize, 0), f.controller.model.original.ai.provider_count);
}

test "native provider model dialog fits the compact settings panel" {
    var f: Fixture = undefined;
    try f.init(true);
    defer f.deinit();
    f.cx.setViewport(860, 480);
    f.frame();
    f.clickId("settings.ai.provider.0.add_model");
    const dialog = byId(f.cx.root.?, "settings.ai.model.dialog").?.globalRect();
    const footer = byId(f.cx.root.?, "settings.ai.model.footer").?.globalRect();
    try std.testing.expectApproxEqAbs(@as(f32, 416), dialog.h, 0.1);
    try std.testing.expectApproxEqAbs(@as(f32, 480), dialog.w, 0.1);
    try std.testing.expect(footer.y + footer.h <= dialog.y + dialog.h + 0.1);
    f.clickId("settings.ai.model.cancel");
}

test "native provider long model choice preserves the catalog trigger and chevron bounds" {
    var f: Fixture = undefined;
    try f.init(true);
    defer f.deinit();
    f.cx.setViewport(860, 480);
    f.clickId("settings.ai.provider.0.model.0.edit_model");
    const editor = f.mounted.model_editor.?;
    const label = editor.catalog_label.?;
    try label.setTextContent(f.cx.allocator, "organization/production-inference-model-with-a-very-long-descriptive-name-and-version-2026-10-26");
    f.frame();
    f.frame();
    const trigger = byId(f.cx.root.?, "settings.ai.model.catalog").?;
    const rect = trigger.globalRect();
    const label_rect = label.globalRect();
    const chevron = trigger.children.items[trigger.children.items.len - 1].globalRect();
    try std.testing.expect(label_rect.x + label_rect.w <= chevron.x + 0.1);
    try std.testing.expect(chevron.x + chevron.w <= rect.x + rect.w + 0.1);
    try std.testing.expectEqual(@as(f32, 12), chevron.w);
    try std.testing.expectEqual(@as(@TypeOf(label.getText().?.text_overflow), .ellipsis), label.getText().?.text_overflow);
    f.clickId("settings.ai.model.cancel");
}

test "native provider saves enabled connection without models and discovers models later" {
    var f: Fixture = undefined;
    try f.init(false);
    defer f.deinit();
    f.clickId("settings.ai.add_provider");
    try std.testing.expect(f.controller.model.value.ai.providers[0].enabled);
    f.replace("settings.ai.provider.0.name", "Empty Gateway");
    f.replace("settings.ai.provider.0.endpoint", "http://127.0.0.1:11434/v1");
    try std.testing.expectEqual(@as(usize, 0), f.controller.model.value.ai.providers[0].model_count);
    try std.testing.expect(f.controller.canSave());
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var target = try @import("config/runtime_config.zig").RuntimeConfig.loadOrDefault(std.testing.io, tmp.dir, std.testing.allocator, "settings.toml");
    defer target.deinit();
    try f.controller.save(std.testing.io, tmp.dir, &target);
    try std.testing.expect(target.value.ai.providers[0].enabled);
    try std.testing.expectEqual(@as(usize, 0), target.value.ai.providers[0].model_count);
}

test "provider folds animate without rebuilding forms or notifying settings changes" {
    var f: Fixture = undefined;
    try f.initWithCount(true, 2);
    defer f.deinit();
    try f.cx.setTestFrameStep(16);
    const header = byId(f.mounted.root, "settings.ai.provider.0.header").?;
    const second = byId(f.mounted.root, "settings.ai.provider.1.header").?;
    const endpoint = byId(f.mounted.root, "settings.ai.provider.0.endpoint").?;
    const card = byId(f.mounted.root, "settings.ai.provider.0.card").?;
    const content = byId(card, "accordion.content").?;
    const scope = f.mounted.render_scope;
    f.replace("settings.ai.provider.0.endpoint", "invalid-raw-value");
    f.frame();
    const open_height = content.globalRect().h;
    const changes = f.changes;
    const toggle = struct {
        fn run(node: *ui.Node) void {
            _ = node.behavior.events.on_event.?(.{ .key_down = .{ .key = .space } }, node.behavior.events.event_context);
        }
    }.run;
    toggle(header);
    f.frame();
    f.frame();
    try std.testing.expect(content.globalRect().h > 0 and content.globalRect().h < open_height);
    const partial = content.globalRect().h;
    toggle(header);
    f.frame();
    try std.testing.expect(content.globalRect().h >= partial - 0.1);
    for (0..30) |_| f.frame();
    try std.testing.expectApproxEqAbs(open_height, content.globalRect().h, 0.2);
    toggle(header);
    for (0..30) |_| f.frame();
    try std.testing.expectApproxEqAbs(@as(f32, 0), content.globalRect().h, 0.1);
    try std.testing.expectEqual(@import("ui/app_theme.zig").current().well, card.getBackground());
    try std.testing.expectEqual(@as(u16, 600), header.children.items[2].children.items[0].getText().?.font_weight);
    toggle(second);
    for (0..30) |_| f.frame();
    try std.testing.expect(second.behavior.interaction.a11y.?.expanded.?);
    try std.testing.expectEqual(scope, f.mounted.render_scope);
    try std.testing.expect(!f.mounted.pending);
    try std.testing.expectEqual(changes, f.changes);
    try std.testing.expectEqual(endpoint, byId(f.mounted.root, "settings.ai.provider.0.endpoint").?);
    try std.testing.expectEqualStrings("invalid-raw-value", f.input("settings.ai.provider.0.endpoint").getText());
    try std.testing.expect(!f.controller.canSave());
}
