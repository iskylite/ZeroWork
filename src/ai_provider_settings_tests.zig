const std = @import("std");
const ui = @import("ui");
const view = @import("config/ai_provider_settings.zig");
const draft = @import("config/settings_ai_draft.zig");
const Config = @import("config/config.zig");
const Controller = @import("config/settings_controller.zig").Controller;

const Fixture = struct {
    cx: *ui.Cx,
    scope: *ui.Scope,
    controller: Controller,
    mounted: *view.ProviderView,
    saving: *ui.Signal(bool),
    changes: usize = 0,
    fn init(self: *Fixture, configured: bool) !void {
        self.cx = try ui.Cx.init(std.testing.allocator, std.testing.io);
        self.cx.setViewport(600, 700);
        self.cx.root = try ui.box(self.cx, .{ .width = .fill(), .height = .fill(), .direction = .column }, .{});
        self.scope = try ui.Scope.init(std.testing.allocator, null, self.cx.owner);
        var models = [_]Config.AiModel{ .{ .id = "configured-model", .context_window = 200000, .default = true, .reasoning = true, .vision = true }, .{ .id = "model-2", .context_window = 128000 } };
        var providers = Config.default_providers;
        if (configured) {
            providers[0].endpoint = "https://example.test/v1/messages";
            providers[0].api_key = "test-key";
            providers[0].models = models[0..1];
            providers[0].model_count = 1;
            providers[0].enabled = true;
        }
        var value: Config.Config = .{};
        value.ai.providers = &providers;
        self.controller = try Controller.init(std.testing.allocator, value);
        self.saving = try self.scope.createSignal(bool, false);
        self.changes = 0;
        self.mounted = try view.ProviderView.mountWithHooks(self.cx, self.scope, &self.controller, .{ .context = self, .changed = changed, .saving = self.saving });
        try self.cx.root.?.appendChild(self.cx.allocator, try self.mounted.mountAddProviderAction(self.scope, self.cx));
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
        self.cx.frame_count += 1;
        self.cx.frame_time_ms += 16;
        _ = self.cx.render();
    }
    fn clickId(self: *Fixture, id: []const u8) void {
        const node = byId(self.cx.root.?, id).?;
        if (node.behavior.events.on_click) |handler| handler.invoke() else if (node.behavior.events.on_event) |handler| {
            _ = handler(.{ .key_down = .{ .key = .space, .modifiers = .{} } }, node.behavior.events.event_context);
        }
        self.frame();
        self.frame();
    }
    fn input(self: *Fixture, id: []const u8) *ui.widgets.input.TextInputState {
        const node = byId(self.mounted.root, id).?;
        return @ptrCast(@alignCast(node.behavior.events.event_context.?));
    }
    fn replace(self: *Fixture, id: []const u8, value: []const u8) void {
        const state = self.input(id);
        inputEvent(state, .{ .key_down = .{ .key = .a, .modifiers = .{ .super = true } } });
        inputEvent(state, .{ .text_input = .{ .text = value } });
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

// The configured fixture reproduces the prototype's single model and collapsed connection details.
test "native provider cards follow exact Figma geometry and show real configuration status" {
    var f: Fixture = undefined;
    try f.init(true);
    defer f.deinit();
    const first = byId(f.mounted.root, "settings.ai.provider.0.card").?.globalRect();
    const second = byId(f.mounted.root, "settings.ai.provider.1.card").?.globalRect();
    const connection = byId(f.mounted.root, "settings.ai.provider.0.connection").?.globalRect();
    const model = byId(f.mounted.root, "settings.ai.provider.0.model.0.card").?.globalRect();
    try std.testing.expectApproxEqAbs(@as(f32, 600), first.w, 0.1);
    try std.testing.expectApproxEqAbs(@as(f32, 170), first.h, 0.1);
    try std.testing.expectApproxEqAbs(@as(f32, 50), second.h, 0.1);
    try std.testing.expectApproxEqAbs(@as(f32, 48), connection.h, 0.1);
    try std.testing.expectApproxEqAbs(@as(f32, 32), model.h, 0.1);
    try std.testing.expectApproxEqAbs(@as(f32, 244), byId(f.mounted.root, "settings.ai.provider.0.name").?.globalRect().w, 0.1);
    try std.testing.expect(!f.controller.model.dirty);
    f.clickId("settings.ai.provider.0.connection.header");
    try std.testing.expect(hasText(f.mounted.root, "API Key 存储于 macOS 钥匙串"));
    try std.testing.expect(!hasText(f.mounted.root, "明文保存 · 权限 600"));
}

test "native provider invalid endpoint retains raw typed value footer gate and field Escape across page remount" {
    var f: Fixture = undefined;
    try f.init(true);
    defer f.deinit();
    f.clickId("settings.ai.provider.0.connection.header");
    const endpoint = f.input("settings.ai.provider.0.endpoint");
    f.replace("settings.ai.provider.0.endpoint", "gateway-without-scheme");
    try std.testing.expectEqualStrings("https://example.test/v1/messages", f.controller.model.value.ai.providers[0].endpoint);
    try std.testing.expectEqualStrings("gateway-without-scheme", f.controller.ai_fields.get(.{ .provider = 0, .field = .endpoint }).?.input);
    try std.testing.expectEqual(@import("config/settings_controller.zig").State.dirty_invalid, f.controller.state());
    try std.testing.expect(!f.controller.canSave());
    try std.testing.expect(f.changes > 0);
    // Closing and reopening an accordion rebuilds its nodes without losing invalid raw.
    f.clickId("settings.ai.provider.0.connection.header");
    f.clickId("settings.ai.provider.0.connection.header");
    const restored = f.input("settings.ai.provider.0.endpoint");
    _ = endpoint; // the previous view's pointer is intentionally not reused after rebuild.
    try std.testing.expectEqualStrings("gateway-without-scheme", restored.getText());
    f.cx.setFocus(byId(f.mounted.root, "settings.ai.provider.0.endpoint").?);
    try std.testing.expect(f.mounted.consumeEscape());
    try std.testing.expectEqualStrings("https://example.test/v1/messages", restored.getText());
    try std.testing.expectEqual(@import("config/settings_controller.zig").State.clean, f.controller.state());
    try std.testing.expect(!f.mounted.consumeEscape());
}

test "native provider inline add model cancel preserves existing model and other settings" {
    var f: Fixture = undefined;
    try f.init(true);
    defer f.deinit();
    try f.controller.editRaw("ssh", "keepalive_sec", "44");
    f.clickId("settings.ai.provider.0.add_model");
    try std.testing.expectEqual(@as(usize, 2), f.controller.model.value.ai.providers[0].model_count);
    try std.testing.expect(f.controller.model.value.ai.providers[0].models[0].default);
    try std.testing.expect(!f.controller.model.value.ai.providers[0].models[1].default);
    try std.testing.expect(!f.controller.canSave());
    try std.testing.expect(byId(f.mounted.root, "settings.ai.provider.0.model.1.model_id") != null);
    f.replace("settings.ai.provider.0.model.1.model_id", "ops-model-2");
    f.replace("settings.ai.provider.0.model.1.context_window", "128000");
    try std.testing.expect(f.controller.canSave());
    f.clickId("settings.ai.provider.0.model.1.cancel_model");
    try std.testing.expectEqual(@as(usize, 1), f.controller.model.value.ai.providers[0].model_count);
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
    try std.testing.expectEqual(@as(usize, 4), f.controller.model.value.ai.provider_count);
    f.replace("settings.ai.provider.3.name", "Production Gateway");
    // Use the existing provider edit API to choose the local adapter; no transport is invoked.
    var owned = try @import("config/runtime_config.zig").Snapshot.init(std.testing.allocator, f.controller.model.value);
    defer owned.deinit();
    owned.value.ai.providers[3].kind = .ollama;
    try f.controller.editProviders(owned.value.ai);
    f.replace("settings.ai.provider.3.endpoint", "http://127.0.0.1:11434/api/chat");
    f.clickId("settings.ai.provider.3.add_model");
    f.replace("settings.ai.provider.3.model.0.model_id", "local-model");
    f.replace("settings.ai.provider.3.model.0.context_window", "8192");
    f.clickId("settings.ai.provider.3.model.0.vision");
    const model = f.controller.model.value.ai.providers[3].models[0];
    try std.testing.expect(model.vision and !model.reasoning);
    try std.testing.expectEqualStrings("", f.controller.model.value.ai.providers[3].api_key);
    // First legal provider initializes the empty default only through an explicit draft choice.
    try f.controller.selectProvider("Production Gateway");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var target = try @import("config/runtime_config.zig").RuntimeConfig.loadOrDefault(std.testing.io, tmp.dir, std.testing.allocator, "settings.toml");
    defer target.deinit();
    try f.controller.save(std.testing.io, tmp.dir, &target);
    var loaded = try @import("config/runtime_config.zig").RuntimeConfig.loadOrDefault(std.testing.io, tmp.dir, std.testing.allocator, "settings.toml");
    defer loaded.deinit();
    try std.testing.expect(loaded.value.ai.providers[3].models[0].vision);
    try std.testing.expect(!loaded.value.ai.providers[3].models[0].reasoning);
    try std.testing.expectEqualStrings("Production Gateway", loaded.value.ai.default_provider);
    try std.testing.expectEqual(@import("config/settings_controller.zig").State.clean, f.controller.state());
}

test "native provider duplicate model window zero and last effort cannot become saved defaults" {
    var f: Fixture = undefined;
    try f.init(true);
    defer f.deinit();
    f.clickId("settings.ai.provider.0.add_model");
    f.replace("settings.ai.provider.0.model.1.model_id", "configured-model");
    try std.testing.expectEqual(error.DuplicateModelId, f.controller.ai_fields.get(.{ .provider = 0, .model = 1, .field = .model_id }).?.problem.?);
    f.replace("settings.ai.provider.0.model.1.model_id", "other");
    f.replace("settings.ai.provider.0.model.1.context_window", "0");
    try std.testing.expect(!f.controller.canSave());
    f.clickId("settings.ai.provider.0.model.1.cancel_model");
    f.clickId("settings.ai.provider.0.model.0.header");
    f.clickId("settings.ai.provider.0.model.0.low");
    f.clickId("settings.ai.provider.0.model.0.medium");
    f.clickId("settings.ai.provider.0.model.0.high");
    try std.testing.expect(f.controller.model.value.ai.providers[0].models[0].efforts[2]);
    try std.testing.expectEqualStrings("推理模型至少保留一个 effort 档位", f.mounted.error_text);
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

test "native provider connection disclosure accepts actual Cx pointer click at laid out center" {
    var f: Fixture = undefined;
    try f.init(true);
    defer f.deinit();
    f.cx.layout();
    const header = byId(f.mounted.root, "settings.ai.provider.0.connection.header").?;
    try std.testing.expect(!hasText(header, "Anthropic Messages"));
    const rect = header.globalRect();
    f.cx.handleClick(rect.x + rect.w / 2, rect.y + rect.h / 2);
    f.frame();
    f.frame();
    try std.testing.expect(f.controller.ai_fields.connection_open.get(0) orelse false);
    const endpoint = byId(f.mounted.root, "settings.ai.provider.0.endpoint").?;
    try std.testing.expect(endpoint.globalRect().h > 0);
    try std.testing.expect(endpoint.isDisplayedInTree());
    try std.testing.expect(hasText(byId(f.mounted.root, "settings.ai.provider.0.kind").?, "Anthropic Messages"));
}

test "native provider focused add model pointer click rebuild keeps blur state alive" {
    var f: Fixture = undefined;
    try f.init(true);
    defer f.deinit();
    const add = byId(f.mounted.root, "settings.ai.provider.0.add_model").?;
    f.cx.setFocus(add);
    try std.testing.expect(f.cx.focus_manager.getFocused() == add);
    const rect = add.globalRect();
    f.cx.handleClick(rect.x + rect.w / 2, rect.y + rect.h / 2);
    f.frame();
    f.frame();
    try std.testing.expectEqual(@as(usize, 2), f.controller.model.value.ai.providers[0].model_count);
    const editor = byId(f.mounted.root, "settings.ai.provider.0.model.1.model_id").?;
    try std.testing.expect(f.cx.focus_manager.getFocused() == editor);
    try std.testing.expect(editor.isDisplayedInTree());
    f.replace("settings.ai.provider.0.model.1.model_id", "ops-model-2");
    f.replace("settings.ai.provider.0.model.1.context_window", "128000");
    try std.testing.expect(f.controller.canSave());
    const cancel = byId(f.mounted.root, "settings.ai.provider.0.model.1.cancel_model").?;
    f.cx.setFocus(cancel);
    const cancel_rect = cancel.globalRect();
    f.cx.handleClick(cancel_rect.x + cancel_rect.w / 2, cancel_rect.y + cancel_rect.h / 2);
    f.frame();
    f.frame();
    try std.testing.expectEqual(@as(usize, 1), f.controller.model.value.ai.providers[0].model_count);
    try std.testing.expect(byId(f.mounted.root, "settings.ai.provider.0.model.1.model_id") == null);
}
