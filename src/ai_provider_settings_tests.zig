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
        return self.initWithCount(configured, if (configured) 1 else 0);
    }
    fn initWithCount(self: *Fixture, configured: bool, count: usize) !void {
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
        self.saving = try self.scope.createSignal(bool, false);
        self.changes = 0;
        self.mounted = try view.ProviderView.mountWithHooks(self.cx, self.scope, &self.controller, .{ .context = self, .changed = changed, .saving = self.saving });
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
    try std.testing.expectApproxEqAbs(@as(f32, 44), model.h, 0.1);
    const name = byId(f.mounted.root, "settings.ai.provider.0.name").?.globalRect();
    const kind = byId(f.mounted.root, "settings.ai.provider.0.kind").?.globalRect();
    const endpoint = byId(f.mounted.root, "settings.ai.provider.0.endpoint").?.globalRect();
    try std.testing.expectApproxEqAbs(name.y, kind.y, 0.1);
    try std.testing.expectApproxEqAbs(name.w, kind.w, 0.1);
    try std.testing.expectApproxEqAbs(@as(f32, 14), kind.x - name.x - name.w, 0.1);
    try std.testing.expectApproxEqAbs(@as(f32, 552), endpoint.w, 0.1);
    try std.testing.expect(hasText(f.mounted.root, "已启用"));
    try std.testing.expect(hasText(f.mounted.root, "API Key 存储于 macOS 钥匙串"));
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
    // Closing and reopening an accordion rebuilds its nodes without losing invalid raw.
    f.clickId("settings.ai.provider.0.header");
    f.clickId("settings.ai.provider.0.header");
    const restored = f.input("settings.ai.provider.0.endpoint");
    _ = endpoint; // the previous view's pointer is intentionally not reused after rebuild.
    try std.testing.expectEqualStrings("gateway-without-scheme", restored.getText());
    f.cx.setFocus(byId(f.mounted.root, "settings.ai.provider.0.endpoint").?);
    try std.testing.expect(f.mounted.consumeEscape());
    try std.testing.expectEqualStrings("https://example.test/v1/messages", restored.getText());
    try std.testing.expectEqual(@import("config/settings_controller.zig").State.clean, f.controller.state());
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
    try std.testing.expect(!f.controller.model.value.ai.providers[0].enabled);
    f.clickId("settings.ai.provider.0.enabled");
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
    f.frame();
    f.frame();
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
    f.clickId("settings.ai.provider.0.header");
    f.clickId("settings.ai.provider.0.header");
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
    const folded = f.controller.ai_fields.provider_open.get(0);
    f.clickId("settings.ai.provider.0.enabled");
    try std.testing.expect(f.controller.model.value.ai.providers[0].enabled);
    try std.testing.expectEqualStrings(draft.problemText(error.DefaultProtected), f.mounted.error_text);
    try std.testing.expectEqual(folded, f.controller.ai_fields.provider_open.get(0));
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
