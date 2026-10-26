//! Registry-driven connection editor shell. The shell owns Modal, contribution
//! picker and slots; connection fields, validation and actions belong to the
//! selected provider's EditorInstance.
const std = @import("std");
const ui = @import("ui");
const S = @import("wizard_styles.zig");
const identity = @import("../host/identity.zig");
const plugins = @import("../host/plugin_registry.zig");
const plugin_ui = @import("../host/plugin_ui_contract.zig");
const envelope_mod = @import("../config/connection_envelope.zig");
// Compatibility value types are owned by the remote provider. Existing probe
// and persistence adapters may still exchange these; the shell never reads them.
const remote_types = @import("../plugins/remote/editor.zig");
pub const Draft = remote_types.Draft;
pub const Protocol = remote_types.Protocol;
pub const Auth = remote_types.Auth;
pub const Result = remote_types.Result;
pub const SaveReceipt = remote_types.SaveReceipt;
pub const SaveFailure = remote_types.SaveFailure;
pub const Step = remote_types.Step;
pub const TestState = remote_types.TestState;
pub const TestProgress = remote_types.TestProgress;
pub const parsePort = remote_types.parsePort;
pub const advanceAllowed = remote_types.advanceAllowed;
pub const formatTestLine = remote_types.formatTestLine;
pub const test_detail_max = remote_types.test_detail_max;
pub const ValidationError = remote_types.ValidationError;
var next_editor_id: std.atomic.Value(u64) = .init(1);

pub const Wizard = struct {
    plugin_registry: plugins.Registry = .{},
    connection_configs: ?@import("../host/connection_config_resolver.zig").Resolver = null,
    editor_host: ?*@import("../host/content_context.zig").EditorHost = null,
    protocol_id: []const u8 = "",
    protocol_options: []ui.widgets.SelectOption = &.{},
    owned_ids: std.ArrayList([]u8) = .empty,
    plugin_slot: ?*ui.Node = null,
    modal_body: ?*ui.Node = null,
    parent_presentation_visible: bool = true,
    parent_barrier_color: ui.Color = ui.Color.TRANSPARENT,
    plugin_scope: ?*ui.Scope = null,
    plugin_editor: ?plugin_ui.EditorInstance = null,
    plugin_error: ?*ui.Node = null,
    on_envelope: ?*const fn (*anyopaque, envelope_mod.Envelope, plugin_ui.SubmitIntent) anyerror!void = null,
    envelope_context: ?*anyopaque = null,
    on_editor_mounted: ?*const fn (*anyopaque, plugin_ui.EditorInstance) anyerror!void = null,
    editor_mounted_context: ?*anyopaque = null,
    on_cancel: ?*const fn (*anyopaque) void = null,
    cancel_context: ?*anyopaque = null,
    draft_id: u64 = 0,
    draft_revision: u64 = 1,
    saving: bool = false,
    cx: *ui.Cx = undefined,
    scope: *ui.Scope = undefined,
    alloc: std.mem.Allocator = undefined,
    root: ?*ui.Node = null,
    modal: ?*ui.Node = null,
    header: ?*ui.Node = null,
    title: ?*ui.Node = null,
    footer: ?*ui.Node = null,
    authentication_area: *ui.Node = undefined,
    protocol_icon: ?*ui.Node = null,
    protocol_picker: ?*ui.Node = null,
    painted_colors: ?S.theme.Colors = null,
    open: ?*ui.Signal(bool) = null,
    locked: ?*ui.Signal(bool) = null,
    sig_protocol: ?*ui.Signal(?[]const u8) = null,

    pub fn setRegistry(self: *Wizard, source: plugins.Registry) void {
        self.plugin_registry = source;
    }
    pub fn selectContribution(self: *Wizard, id: []const u8) !void {
        const manifest = self.plugin_registry.find(id) orelse return error.UnknownPlugin;
        if (manifest.connection == null) return error.ConnectionEditorUnavailable;
        self.protocol_id = manifest.id;
        self.sig_protocol.?.set(manifest.id);
        try self.mountContributedEditor(null);
        self.refreshAppearance();
    }
    pub fn reset(self: *Wizard) !void {
        if (self.title) |title| try title.setTextContent(self.alloc, "新建连接");
        self.draft_revision = std.math.add(u64, self.draft_revision, 1) catch return error.RevisionExhausted;
        try self.mountContributedEditor(null);
    }
    pub fn loadEnvelope(self: *Wizard, value: envelope_mod.Envelope) !void {
        if (self.title) |title| try title.setTextContent(self.alloc, if (@backingInt(value.id) == 0) "新建连接" else "编辑连接");
        const manifest = self.plugin_registry.find(value.protocol_id) orelse return error.UnknownPlugin;
        const contribution = manifest.connection orelse return error.ConnectionEditorUnavailable;
        const decode = contribution.decode orelse return error.ConnectionCodecUnavailable;
        var arena = std.heap.ArenaAllocator.init(self.alloc);
        defer arena.deinit();
        const decoded = try decode(arena.allocator(), value);
        self.protocol_id = manifest.id;
        self.sig_protocol.?.set(manifest.id);
        try self.mountContributedEditor(decoded);
        self.refreshAppearance();
    }
    pub fn deliverChild(self: *Wizard, completion: @import("../host/content_context.zig").ChildCompletion) void {
        if (completion.request.parent_editor_id != self.draft_id) return;
        const editor = self.plugin_editor orelse return;
        if (editor.vtable.child_completed) |deliver| deliver(editor.context, completion);
    }
    pub fn mount(self: *Wizard, cx: *ui.Cx, scope: *ui.Scope) !*ui.Node {
        self.cx = cx;
        self.scope = scope;
        self.alloc = cx.allocator;
        if (self.draft_id == 0) {
            const id = next_editor_id.fetchAdd(1, .monotonic);
            if (id == 0 or id == std.math.maxInt(u64)) return error.IdentityExhausted;
            self.draft_id = id;
        }
        self.open = try scope.createSignal(bool, false);
        self.locked = try scope.createSignal(bool, false);
        self.sig_protocol = try scope.createSignal(?[]const u8, null);
        const modal = try ui.widgets.Modal(.{ .open = ui.split(self.open.?, cx.on(Wizard, self, openChanged)), .width = S.width, .max_height = S.max_height, .background = S.theme.current().overlay, .close_on_overlay = false }).mount(scope, cx);
        self.root = modal.overlay;
        self.modal = modal.dialog;
        self.modal_body = modal.body;
        modal.overlay.meta.ownership.meta.test_id = "wizard.overlay";
        modal.dialog.meta.ownership.meta.test_id = "wizard.dialog";
        modal.dialog.setStyleInline(self.alloc, S.panel(cx.tokens));
        modal.body.setStyleInline(self.alloc, S.modalBody());
        const header = try ui.box(cx, S.header(), .{});
        self.header = header;
        self.protocol_icon = try ui.iconTint(cx, ui.icons.plug, S.theme.current().accent, S.icon(18));
        self.protocol_icon.?.meta.ownership.meta.test_id = "wizard.protocol.icon";
        self.protocol_icon.?.setDisplay(.none);
        try header.appendChild(self.alloc, self.protocol_icon.?);
        self.title = try ui.text(cx, "新建连接", S.text(13, 700, false));
        self.title.?.meta.ownership.meta.test_id = "wizard.title";
        try header.appendChild(self.alloc, self.title.?);
        try header.appendChild(self.alloc, try ui.spacer(cx));
        var count: usize = 0;
        for (self.plugin_registry.manifests()) |manifest| if (manifest.connection != null) {
            count += 1;
        };
        self.protocol_options = try self.alloc.alloc(ui.widgets.SelectOption, count);
        var i: usize = 0;
        for (self.plugin_registry.manifests()) |manifest| {
            if (manifest.connection == null) continue;
            const test_id = try std.fmt.allocPrint(self.alloc, "wizard.protocol.{s}", .{manifest.id});
            try self.owned_ids.append(self.alloc, test_id);
            self.protocol_options[i] = .{ .value = manifest.id, .label = manifest.display_name, .icon = @import("session_icon.zig").asset(manifest.icons.protocol), .test_id = test_id };
            i += 1;
        }
        if (self.plugin_registry.find(self.protocol_id) == null and count != 0) self.protocol_id = self.protocol_options[0].value;
        self.sig_protocol.?.set(if (count == 0) null else self.protocol_id);
        const close = try ui.widgets.Button(.{ .label = "", .variant = .ghost, .a11y_label = "关闭向导", .on_click = cx.on(Wizard, self, cancel) }).mount(scope, cx);
        close.meta.ownership.meta.test_id = "wizard.close";
        try close.appendChild(self.alloc, try ui.iconTint(cx, ui.icons.x, S.theme.current().fg_2, S.icon(14)));
        try header.appendChild(self.alloc, close);
        try modal.body.appendChild(self.alloc, header);
        const body = try ui.box(cx, S.body(), .{});
        body.setStyleInline(self.alloc, .{ .padding = .{}, .gap = 0, .flex = 1 });
        self.plugin_slot = try ui.boxStyled(cx, S.editorSlot, .{});
        self.plugin_slot.?.meta.ownership.meta.test_id = "wizard.plugin.editor";
        self.plugin_slot.?.meta.ownership.hooks.on_cleanup = .{ .context = self, .callback = slotGone };
        try body.appendChild(self.alloc, self.plugin_slot.?);
        self.plugin_error = try ui.text(cx, "", S.text(12, 400, true));
        self.plugin_error.?.setDisplay(.none);
        try body.appendChild(self.alloc, self.plugin_error.?);
        self.authentication_area = try ui.boxStyled(cx, S.stack, .{});
        self.authentication_area.setDisplay(.none);
        try body.appendChild(self.alloc, self.authentication_area);
        try modal.body.appendChild(self.alloc, body);
        self.footer = try ui.box(cx, S.footer(), .{});
        self.footer.?.meta.ownership.meta.test_id = "wizard.footer";
        try self.footer.?.appendChild(self.alloc, try ui.spacer(cx));
        const save = try ui.widgets.Button(.{ .label = "保存主机", .variant = .ghost, .disabled = self.locked.?, .on_click = cx.on(Wizard, self, saveOnly) }).mount(scope, cx);
        save.meta.ownership.meta.test_id = "wizard.save_only";
        try self.footer.?.appendChild(self.alloc, save);
        const submit = try ui.widgets.Button(.{ .label = "保存并打开", .disabled = self.locked.?, .on_click = cx.on(Wizard, self, saveAndOpen) }).mount(scope, cx);
        submit.meta.ownership.meta.test_id = "wizard.save";
        try self.footer.?.appendChild(self.alloc, submit);
        try modal.body.appendChild(self.alloc, self.footer.?);
        try self.mountContributedEditor(null);
        self.refreshAppearance();
        self.root.?.setHitTestVisible(false);
        self.root.?.setDisplay(.none);
        try cx.addAfterLayoutHook(self, viewportHook);
        try scope.onCleanup(Wizard, self, cleanup);
        _ = self.updateViewport();
        return if (modal.portaled) try ui.box(cx, .{ .width = .{ .px = 0 }, .height = .{ .px = 0 }, .display = .none }, .{}) else self.root.?;
    }
    fn slotGone(raw: *anyopaque) void {
        const self: *Wizard = @ptrCast(@alignCast(raw));
        self.plugin_slot = null;
    }
    fn destroyEditorNodes(self: *Wizard) void {
        self.protocol_picker = null;
        if (self.plugin_slot) |slot| while (slot.children.items.len != 0) {
            const child = slot.children.items[slot.children.items.len - 1];
            slot.removeChild(child);
            self.cx.destroyDetached(child);
        };
    }
    fn releasePluginScope(self: *Wizard) void {
        self.plugin_scope = null;
        if (self.plugin_editor) |editor| {
            editor.vtable.clear_secrets(editor.context);
            editor.vtable.unmount(editor.context);
        }
        self.plugin_editor = null;
        // Provider node cleanup callbacks may borrow scope-owned editor state.
        // Destroy the slot subtree while that state is still alive.
        self.destroyEditorNodes();
    }
    pub fn releaseContributedEditor(self: *Wizard) void {
        if (self.plugin_editor) |editor| {
            editor.vtable.clear_secrets(editor.context);
            editor.vtable.unmount(editor.context);
        }
        self.plugin_editor = null;
        if (self.plugin_scope) |scope| scope.dispose();
        self.plugin_scope = null;
        self.destroyEditorNodes();
    }
    fn mountContributedEditor(self: *Wizard, initial: ?envelope_mod.Envelope) !void {
        self.releaseContributedEditor();
        const manifest = self.plugin_registry.find(self.protocol_id) orelse return;
        const connection = manifest.connection orelse return;
        const mount_editor = connection.editor_factory.mount orelse return error.ConnectionEditorUnavailable;
        const scope = try self.scope.childScope();
        self.plugin_scope = scope;
        errdefer self.releaseContributedEditor();
        self.plugin_editor = try mount_editor(connection.editor_factory.context, .{ .cx = self.cx, .scope = scope, .slot = self.plugin_slot.?, .protocol_id = manifest.id, .protocol_picker = .{ .context = self, .mount = mountProtocolPicker }, .initial = initial, .draft_revision = self.draft_revision, .events = .{ .context = self, .changed = editorChanged, .submit = editorSubmit, .dismiss = editorDismiss, .cancelled = editorCancelled }, .editor_host = self.editor_host, .editor_id = self.draft_id, .connection_configs = self.connection_configs });
        try scope.onCleanup(Wizard, self, releasePluginScope);
        if (self.on_editor_mounted) |hook| try hook(self.editor_mounted_context orelse return error.EditorHookUnavailable, self.plugin_editor.?);
        if (self.plugin_error) |node| node.setDisplay(.none);
        self.footer.?.setDisplay(if (self.plugin_editor.?.handles_actions) .none else .flex);
    }
    fn editorChanged(raw: *anyopaque) void {
        const self: *Wizard = @ptrCast(@alignCast(raw));
        self.draft_revision = std.math.add(u64, self.draft_revision, 1) catch 0;
        self.cx.requestRedraw();
    }
    fn editorDismiss(raw: *anyopaque) void {
        const self: *Wizard = @ptrCast(@alignCast(raw));
        self.hide();
    }
    fn editorCancelled(raw: *anyopaque) void {
        const self: *Wizard = @ptrCast(@alignCast(raw));
        self.hide();
        if (self.on_cancel) |callback| callback(self.cancel_context orelse return);
    }
    fn editorSubmit(raw: *anyopaque, value: envelope_mod.Envelope, intent: plugin_ui.SubmitIntent) !void {
        const self: *Wizard = @ptrCast(@alignCast(raw));
        if (!std.mem.eql(u8, value.protocol_id, self.protocol_id)) return error.ProtocolMismatch;
        const manifest = self.plugin_registry.find(value.protocol_id) orelse return error.UnknownPlugin;
        const connection = manifest.connection orelse return error.ConnectionEditorUnavailable;
        try value.validate();
        if (value.payload_version != connection.payload_version) return error.UnsupportedPayloadVersion;
        try connection.validate_payload(value.payload);
        const encode = connection.encode orelse return error.ConnectionCodecUnavailable;
        var arena = std.heap.ArenaAllocator.init(self.alloc);
        defer arena.deinit();
        const encoded = try encode(arena.allocator(), value);
        try encoded.validate();
        if (self.saving) return error.SaveInProgress;
        const submit = self.on_envelope orelse return error.ConnectionSubmitUnavailable;
        self.saving = true;
        self.locked.?.set(true);
        defer {
            self.saving = false;
            self.locked.?.set(false);
        }
        try submit(self.envelope_context orelse return error.ConnectionSubmitUnavailable, encoded, intent);
        if (intent != .probe) self.hide();
    }
    fn saveOnly(self: *Wizard) void {
        self.saveContributed(true);
    }
    fn saveAndOpen(self: *Wizard) void {
        self.saveContributed(false);
    }
    fn saveContributed(self: *Wizard, only: bool) void {
        const editor = self.plugin_editor orelse return;
        var arena = std.heap.ArenaAllocator.init(self.alloc);
        defer arena.deinit();
        const value = editor.vtable.snapshot(editor.context, arena.allocator()) catch |err| {
            self.showError(err);
            return;
        };
        editorSubmit(self, value, if (only) .save else .save_and_open) catch |err| self.showError(err);
    }
    fn showError(self: *Wizard, err: anyerror) void {
        if (self.plugin_error) |node| {
            node.setTextContent(self.alloc, @errorName(err)) catch {};
            node.setDisplay(.flex);
        }
        self.cx.requestRedraw();
    }
    fn mountProtocolPicker(raw: *anyopaque, cx: *ui.Cx, scope: *ui.Scope) !*ui.Node {
        const self: *Wizard = @ptrCast(@alignCast(raw));
        const picker = try ui.box(cx, .{ .width = .fill(), .height = .{ .px = 41 }, .direction = .row, .align_items = .center, .padding = ui.Padding.all(5), .gap = 6, .background = S.theme.current().well, .border = .{ .radius = 9 }, .flex_shrink = 0 }, .{});
        picker.meta.ownership.meta.test_id = "wizard.protocol";
        self.protocol_picker = picker;
        for (self.protocol_options, 0..) |option, index| {
            const click = try scope.createState(ProtocolClick, .{ .wizard = self, .index = index });
            const button = try ui.widgets.Button(.{ .label = option.label, .variant = .ghost, .disabled = self.locked.?, .on_click = cx.on(ProtocolClick, click, ProtocolClick.activate), .base_style = @as(@FieldType(ui.widgets.ControlShellConfig, "style"), .{ .width = .fill(), .flex = 1, .height = .{ .px = 31 }, .padding = .{}, .corner_radius = 7, .font_size = 11, .font_weight = 400, .text_color = if (std.mem.eql(u8, option.value, self.protocol_id)) S.theme.current().accent_ink else S.theme.current().fg_1, .background = if (std.mem.eql(u8, option.value, self.protocol_id)) S.theme.current().selection else ui.Color.TRANSPARENT, .border_width = 0 }) }).mount(scope, cx);
            button.meta.ownership.meta.test_id = option.test_id;
            if (button.behavior.interaction.a11y) |*access| {
                access.selected = std.mem.eql(u8, option.value, self.protocol_id);
                access.pressed = access.selected;
            }
            try picker.appendChild(self.alloc, button);
        }
        return picker;
    }
    const ProtocolClick = struct {
        wizard: *Wizard,
        index: usize,
        fn activate(self: *ProtocolClick) void {
            const wizard = self.wizard;
            const selected = wizard.protocol_options[self.index].value;
            if (std.mem.eql(u8, selected, wizard.protocol_id)) return;
            wizard.selectContribution(selected) catch |err| wizard.showError(err);
        }
    };
    fn refreshAppearance(self: *Wizard) void {
        const colors = S.theme.current();
        self.painted_colors = colors;
        if (self.modal) |node| node.setStyleInline(self.alloc, .{ .background = colors.overlay });
        if (self.title) |node| node.setTextColor(colors.fg_1);
        if (self.protocol_picker) |picker| {
            picker.setBackground(colors.well);
            for (picker.children.items, 0..) |button, index| {
                if (index >= self.protocol_options.len) break;
                const chosen = std.mem.eql(u8, self.protocol_options[index].value, self.protocol_id);
                button.setStyleInline(self.alloc, .{ .background = if (chosen) colors.selection else ui.Color.TRANSPARENT });
                paintPickerText(button, if (chosen) colors.accent_ink else colors.fg_1);
            }
        }
        const manifest = self.plugin_registry.find(self.protocol_id) orelse return;
        if (self.protocol_icon) |node| {
            const asset = @import("session_icon.zig").asset(manifest.icons.protocol);
            if (asset.icon_id) |id| if (asset.pickRep(18)) |rep| node.setIcon(.{ .icon_id = id, .rep = rep, .tint = S.theme.current().accent });
        }
    }
    fn paintPickerText(node: *ui.Node, color: ui.Color) void {
        if (node.getText() != null) node.setTextColor(color);
        for (node.children.items) |child| paintPickerText(child, color);
    }
    pub fn show(self: *Wizard) void {
        self.refreshAppearance();
        const root = self.root orelse return;
        if (self.plugin_editor) |editor| if (editor.vtable.visibility_changed) |changed| changed(editor.context, true);
        self.open.?.set(true);
        root.setDisplay(.flex);
        root.setHitTestVisible(true);
        self.cx.requestRedraw();
    }
    pub fn hide(self: *Wizard) void {
        const root = self.root orelse return;
        if (self.plugin_editor) |editor| {
            editor.vtable.clear_secrets(editor.context);
            if (editor.vtable.visibility_changed) |changed| changed(editor.context, false);
        }
        self.open.?.set(false);
        root.setHitTestVisible(false);
        root.setDisplay(.none);
    }
    pub fn cancel(self: *Wizard) void {
        if (self.plugin_editor) |editor| if (editor.vtable.cancel) |request| {
            request(editor.context);
            return;
        };
        self.hide();
        if (self.on_cancel) |callback| callback(self.cancel_context orelse return);
    }
    pub fn isVisible(self: *const Wizard) bool {
        return if (self.root) |root| root.style.display != .none else false;
    }
    fn openChanged(self: *Wizard, visible: bool) void {
        if (!visible and self.isVisible()) self.cancel();
    }
    pub fn updateViewport(self: *Wizard) bool {
        const node = self.modal orelse return false;
        // Modal's deferred style host can initialise after mount. Reapply the
        // owned content contract once, before natural editor height escapes it.
        var body_changed = false;
        const colors = S.theme.current();
        if (self.painted_colors == null or !std.meta.eql(self.painted_colors.?, colors)) {
            self.refreshAppearance();
            body_changed = true;
        }
        const parent_visible = if (self.plugin_editor) |editor| if (editor.vtable.parent_presentation_visible) |get| get(editor.context) else true else true;
        if (self.parent_presentation_visible != parent_visible) {
            if (self.root) |barrier| {
                if (!parent_visible) self.parent_barrier_color = barrier.getBackground();
                barrier.setBackground(if (parent_visible) self.parent_barrier_color else ui.Color.TRANSPARENT);
            }
            node.setDisplay(if (parent_visible) .flex else .none);
            self.parent_presentation_visible = parent_visible;
            body_changed = true;
        }
        if (self.modal_body) |body| if (!std.meta.eql(body.style.padding, ui.Padding.ZERO)) {
            body.setStyleInline(self.alloc, S.modalBody());
            body_changed = true;
        };
        const width = @min(S.width, @max(1, self.cx.viewport.width - 32));
        var preferred = S.max_height;
        if (self.plugin_editor) |editor| if (editor.vtable.preferred_modal_height) |get| if (get(editor.context)) |value| {
            if (std.math.isFinite(value) and value > 0) preferred = @min(value, S.max_height);
        };
        const compact = self.cx.viewport.width <= 860 or self.cx.viewport.height <= 480;
        if (self.header) |header| {
            const desired_h: f32 = if (compact) 48 else 52;
            if (header.style.height != .px or header.style.height.px != desired_h) {
                header.setStyleInline(self.alloc, .{ .height = .{ .px = desired_h }, .padding = .{ .left = if (compact) 18 else 20, .right = if (compact) 18 else 20, .top = if (compact) 12 else 14, .bottom = if (compact) 12 else 14 } });
                body_changed = true;
            }
        }
        const height = @min(preferred, @max(1, self.cx.viewport.height - @as(f32, if (compact) 48 else 32)));
        const changed = node.style.width != .px or node.style.width.px != width or node.style.height != .px or node.style.height.px != height;
        if (changed) node.setStyleInline(self.alloc, .{ .width = .{ .px = width }, .height = .{ .px = height } });
        return changed or body_changed;
    }
    fn viewportHook(raw: *anyopaque, _: u8, _: bool) ui.AfterLayoutResult {
        const self: *Wizard = @ptrCast(@alignCast(raw));
        return if (self.updateViewport()) .needs_layout else .done;
    }
    fn cleanup(self: *Wizard) void {
        self.cx.removeAfterLayoutHook(self);
        self.releaseContributedEditor();
        self.alloc.free(self.protocol_options);
        self.protocol_options = &.{};
        for (self.owned_ids.items) |value| self.alloc.free(value);
        self.owned_ids.deinit(self.alloc);
    }
};

test "registered editor owns the shared wizard slot and survives shell reopen" {
    const Driver = struct {
        mounts: usize = 0,
        releases: usize = 0,
        clears: usize = 0,
        submits: usize = 0,
        fn mount(raw: ?*anyopaque, args: plugin_ui.EditorMount) !plugin_ui.EditorInstance {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.mounts += 1;
            try args.slot.appendChild(args.cx.allocator, try ui.text(args.cx, "custom editor", .{}));
            return .{ .context = self, .vtable = &.{ .snapshot = snapshot, .clear_secrets = clear, .unmount = release } };
        }
        fn snapshot(_: *anyopaque, _: std.mem.Allocator) !envelope_mod.Envelope {
            return .{ .protocol_id = "spec.editor", .name = "retained draft", .payload = "{}" };
        }
        fn clear(raw: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.clears += 1;
        }
        fn release(raw: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.releases += 1;
        }
        fn validate(_: []const u8) !void {}
        fn codec(allocator: std.mem.Allocator, value: envelope_mod.Envelope) !envelope_mod.Envelope {
            return value.clone(allocator);
        }
        fn submit(raw: *anyopaque, value: envelope_mod.Envelope, _: plugin_ui.SubmitIntent) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            try std.testing.expectEqualStrings("spec.editor", value.protocol_id);
            try std.testing.expectEqualStrings("retained draft", value.name);
            self.submits += 1;
        }
    };
    var driver: Driver = .{};
    const manifests = [_]plugins.PluginManifest{.{ .id = "spec.editor", .display_name = "Custom editor", .workspace_kind = "custom", .content_renderer = "custom", .connection = .{ .editor_factory = .{ .context = &driver, .mount = Driver.mount }, .validate_payload = Driver.validate, .encode = Driver.codec, .decode = Driver.codec } }};
    const source: plugins.Registry = .{ .published = .{ .entries = &manifests, .renderers = &.{} } };
    const cx = try ui.Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    const scope = try ui.Scope.init(std.testing.allocator, null, cx.owner);
    cx.setViewport(900, 700);
    cx.root = try ui.box(cx, .{ .width = .fill(), .height = .fill() }, .{});
    var wizard: Wizard = .{};
    wizard.setRegistry(source);
    wizard.on_envelope = Driver.submit;
    wizard.envelope_context = &driver;
    try cx.root.?.appendChild(cx.allocator, try wizard.mount(cx, scope));
    try std.testing.expectEqual(@as(usize, 1), wizard.protocol_options.len);
    try std.testing.expectEqualStrings("spec.editor", wizard.protocol_options[0].value);
    wizard.show();
    try std.testing.expect(wizard.plugin_editor != null);
    try std.testing.expectEqual(ui.types.Display.flex, wizard.plugin_slot.?.style.display);
    wizard.hide();
    wizard.show();
    try std.testing.expectEqual(@as(usize, 1), driver.mounts);
    wizard.saveContributed(true);
    try std.testing.expectEqual(@as(usize, 1), driver.submits);
    scope.dispose();
    try std.testing.expectEqual(@as(usize, 1), driver.releases);
    try std.testing.expect(driver.clears >= 2);
}

test "fixture nested editor opens its registered child from real pointer dispatch" {
    const fixtures = @import("../plugins/fixture_probe/plugin.zig");
    const Driver = struct {
        fn create(_: *anyopaque, _: @import("../host/session_host.zig").CreateRequest) !void {}
        fn cancel(_: *anyopaque, _: @import("../host/session_host.zig").OperationKey) @import("../host/session_host.zig").CloseReceipt {
            return .released;
        }
        fn close(_: *anyopaque, _: identity.SessionHandle, _: @import("../host/session_host.zig").OperationKey) !@import("../host/session_host.zig").CloseReceipt {
            return .released;
        }
        fn stale(_: *anyopaque, _: identity.SessionHandle, _: @import("../host/session_host.zig").OperationKey) void {}
        fn validate(_: []const u8) !void {}
        fn codec(a: std.mem.Allocator, value: envelope_mod.Envelope) !envelope_mod.Envelope {
            return value.clone(a);
        }
        fn migrate(a: std.mem.Allocator, value: envelope_mod.Envelope, _: u32) !envelope_mod.Envelope {
            return value.clone(a);
        }
        fn save(_: *anyopaque, _: envelope_mod.Envelope) !identity.AssetOwner {
            return .{ .id = @fromBackingInt(91), .revision = 1 };
        }
        fn find(node: *ui.Node, id: []const u8) ?*ui.Node {
            if (node.meta.ownership.meta.test_id) |actual| if (std.mem.eql(u8, actual, id)) return node;
            for (node.children.items) |child| if (find(child, id)) |found| return found;
            return null;
        }
        fn click(cx: *ui.Cx, node: *ui.Node) void {
            const rect = node.globalRect();
            cx.handleClick(rect.x + rect.w / 2, rect.y + rect.h / 2);
            cx.handleMouseUpEx(rect.x + rect.w / 2, rect.y + rect.h / 2, .left, .{});
        }
    };
    const a = std.testing.allocator;
    const fixture = try fixtures.Plugin.init(a);
    defer fixture.deinit();
    var definitions = plugins.PluginHost.init(a);
    defer definitions.deinit();
    try definitions.registerRenderer(.{ .kind = "terminal", .shared_renderer = true });
    try definitions.registerRenderer(fixture.renderer());
    var driver: u8 = 0;
    const factory: @import("../host/session_host.zig").Adapter.VTable = .{ .create = Driver.create, .cancel = Driver.cancel, .close = Driver.close, .release_stale = Driver.stale };
    try definitions.register(.{ .id = "ssh", .display_name = "SSH", .connection = .{ .create_kind = .saved_or_temporary, .editor_factory = .{ .mount = @import("../plugins/remote/editor_factory.zig").mount }, .validate_payload = Driver.validate, .encode = Driver.codec, .decode = Driver.codec, .migrate = Driver.migrate }, .session_factory = .{ .context = &driver, .vtable = &factory }, .workspace_kind = "terminal", .content_renderer = "terminal" });
    try definitions.register(fixture.manifest());
    var source = try definitions.publish();
    defer source.deinit();
    const cx = try ui.Cx.init(a, std.testing.io);
    defer cx.deinit();
    cx.setViewport(1440, 900);
    try cx.setTestFrameStep(100);
    cx.root = try ui.box(cx, .{ .width = .fill(), .height = .fill() }, .{});
    const scope = try ui.Scope.init(a, null, cx.owner);
    defer scope.dispose();
    const parent = try cx.bindState(Wizard, .{});
    parent.setRegistry(source);
    try cx.root.?.appendChild(a, try parent.mount(cx, scope));
    const nested = try @import("plugin_editor_host.zig").Host.mount(cx, scope, parent, source, .{ .context = &driver, .save = Driver.save });
    try cx.root.?.appendChild(a, nested.root);
    defer parent.releaseContributedEditor();
    try parent.selectContribution("fixture_probe");
    parent.show();
    for (0..4) |_| {
        cx.advanceFrameClock();
        _ = cx.render();
    }
    var retained_arena = std.heap.ArenaAllocator.init(a);
    defer retained_arena.deinit();
    const parent_instance = parent.plugin_editor.?;
    const before = try parent_instance.vtable.snapshot(parent_instance.context, retained_arena.allocator());
    const route = Driver.find(parent.plugin_slot.?, "fixture.route").?;
    Driver.click(cx, route);
    for (0..4) |_| {
        cx.advanceFrameClock();
        _ = cx.render();
    }
    const child_button = Driver.find(parent.plugin_slot.?, "fixture.child_ssh").?;
    try std.testing.expect(child_button.isDisplayedInTree());
    Driver.click(cx, child_button);
    for (0..4) |_| {
        cx.advanceFrameClock();
        _ = cx.render();
    }
    try std.testing.expect(nested.host.active != null);
    try std.testing.expect(nested.host.child.open.?.get());
    try std.testing.expect(nested.host.child.root.?.isDisplayedInTree());
    const name = Driver.find(nested.host.child.root.?, "wizard.name").?;
    try std.testing.expect(name.isDisplayedInTree());
    const cancel_button = Driver.find(nested.host.child.root.?, "wizard.cancel").?;
    Driver.click(cx, cancel_button);
    for (0..4) |_| {
        cx.advanceFrameClock();
        _ = cx.render();
    }
    try std.testing.expect(nested.host.active == null);
    try std.testing.expect(!nested.host.child.isVisible());
    try std.testing.expect(parent.isVisible());
    try std.testing.expectEqual(parent_instance.context, parent.plugin_editor.?.context);
    try std.testing.expect(child_button.isDisplayedInTree());
    Driver.click(cx, route);
    for (0..4) |_| {
        cx.advanceFrameClock();
        _ = cx.render();
    }
    const after = try parent_instance.vtable.snapshot(parent_instance.context, retained_arena.allocator());
    try std.testing.expectEqualStrings(before.name, after.name);
    try std.testing.expectEqualStrings(before.payload, after.payload);
}
