//! Read-only projections of configured AI capabilities. Selection only emits
//! a typed, captured action; the host confirms it with update().
const std = @import("std");
const ui = @import("ui");
const config = @import("../config/config.zig");
const provider = @import("../ai/provider.zig");
pub const Owner = @import("../ai/tool_scope.zig").Owner;
const S = @import("ai_composer_controls_styles.zig");
pub const Effort = provider.Effort;
pub const PermissionMode = config.PermissionMode;
pub const Attachment = enum { image, local_text, remote_file, paste_image };
pub const AttachmentState = struct { image: bool = false, local_text: bool = false, remote_file: bool = false, paste_image: bool = false, count: usize = 0 };
pub const ModelKey = struct {
    provider_id: []const u8,
    model_id: []const u8,
    pub fn eql(self: ModelKey, other: ModelKey) bool {
        return std.mem.eql(u8, self.provider_id, other.provider_id) and std.mem.eql(u8, self.model_id, other.model_id);
    }
};
pub const UsagePart = struct { name: []const u8, tokens: u64 };
pub const Usage = struct {
    used_tokens: u64,
    limit_tokens: u64,
    estimated: bool = false,
    parts: []const UsagePart = &.{},
    request_tokens: ?u64 = null,
    redacted: ?bool = null,
    compaction: @import("../ai/context_compaction.zig").Status = .idle,
    can_compact: bool = false,
    compaction_before: u64 = 0,
    compaction_after: u64 = 0,
};
pub const Snapshot = struct {
    owner: Owner,
    /// Configuration epoch. Current selection/usage may update within it;
    /// replacing provider identities/capabilities requires a newer epoch.
    revision: u64,
    providers: []const config.AiProvider = &.{},
    current: ?ModelKey = null,
    permission: PermissionMode = .confirm,
    effort: ?Effort = null,
    thinking: ?bool = null,
    attachments: AttachmentState = .{},
    usage: ?Usage = null,
    editable: bool = true,
};
pub const Action = union(enum) {
    compact_context,
    cancel_compaction,
    model: ModelKey,
    permission: PermissionMode,
    effort: struct { model: ModelKey, value: Effort },
    thinking: struct { model: ModelKey, enabled: bool },
    attachment: Attachment,
};
pub const Envelope = struct { owner: Owner, revision: u64, action: Action };
pub const Callbacks = struct { context: *anyopaque, action: *const fn (*anyopaque, Envelope) anyerror!void, open_settings: ?*const fn (*anyopaque) void = null };
pub fn providerId(value: config.AiProvider) []const u8 {
    return if (value.name.len != 0) value.name else @tagName(value.kind);
}
pub fn permissionLabel(value: PermissionMode) []const u8 {
    return if (value == .confirm) "确认后执行" else "自动执行";
}
pub fn effortLabel(value: Effort) []const u8 {
    return switch (value) {
        .low => "低",
        .medium => "中",
        .high => "高",
        .xhigh => "较高",
        .max => "最高",
        .none => "关闭",
        .ultra => "超高",
    };
}
const Model = struct { key: ModelKey, enabled: bool, context_window: u32, context_discovered: bool, reasoning: bool, toggle: bool, thinking_default: ?bool, vision: bool, efforts: [7]bool };
const Projection = struct { owner: Owner, revision: u64, models: []const Model, current: ?ModelKey, permission: PermissionMode, effort: ?Effort, thinking: ?bool, attachments: AttachmentState, usage: ?Usage, editable: bool, config_hash: u64 };
const Owned = struct {
    arena: std.heap.ArenaAllocator,
    value: Projection,
    fn init(allocator: std.mem.Allocator, snapshot: Snapshot) !Owned {
        if (snapshot.revision == 0 or (switch (snapshot.owner) {
            .session => |id| id == 0,
            .group => |id| id == 0,
        })) return error.InvalidOwner;
        if (snapshot.usage) |usage| if (usage.limit_tokens == 0) return error.InvalidUsage;
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const a = arena.allocator();
        var models: std.ArrayList(Model) = .empty;
        var hash = std.hash.Wyhash.init(0);
        for (snapshot.providers) |item| {
            const id = providerId(item);
            for (item.models) |model| {
                if (model.id.len == 0) continue;
                try appendModel(a, &models, &hash, id, item.kind, item.endpoint, item.enabled and @import("../config/settings_ai_draft.zig").endpointValid(item.endpoint) and (item.api_key.len != 0 or @import("../ai/provider_config.zig").allowsNoAuth(item.kind, item.endpoint)), model);
            }
            if (item.models.len == 0 and item.model.len != 0) try appendModel(a, &models, &hash, id, item.kind, item.endpoint, item.enabled and @import("../config/settings_ai_draft.zig").endpointValid(item.endpoint) and (item.api_key.len != 0 or @import("../ai/provider_config.zig").allowsNoAuth(item.kind, item.endpoint)), .{ .id = item.model, .context_window = item.context_window, .efforts = @splat(false) });
        }
        var usage = snapshot.usage;
        if (usage) |*value| {
            const parts = try a.dupe(UsagePart, value.parts);
            for (parts) |*part| part.name = try a.dupe(u8, part.name);
            value.parts = parts;
        }
        const current = if (snapshot.current) |key| try cloneKey(a, key) else null;
        return .{ .arena = arena, .value = .{ .owner = snapshot.owner, .revision = snapshot.revision, .models = try models.toOwnedSlice(a), .current = current, .permission = snapshot.permission, .effort = snapshot.effort, .thinking = snapshot.thinking, .attachments = snapshot.attachments, .usage = usage, .editable = snapshot.editable, .config_hash = hash.final() } };
    }
    fn appendModel(a: std.mem.Allocator, models: *std.ArrayList(Model), hash: *std.hash.Wyhash, id: []const u8, kind: config.ProviderKind, endpoint: []const u8, enabled: bool, value: config.AiModel) !void {
        const key: ModelKey = .{ .provider_id = id, .model_id = value.id };
        for (models.items) |previous| if (previous.key.eql(key)) return error.DuplicateModel;
        const efforts = if (kind == .openai_compat or value.reasoning_discovered) value.efforts else @as([7]bool, @splat(false));
        try models.append(a, .{ .key = try cloneKey(a, key), .enabled = enabled and std.mem.trim(u8, value.id, " \t\r\n").len != 0 and value.context_window != 0, .context_window = value.context_window, .context_discovered = value.context_discovered, .reasoning = value.reasoning, .thinking_default = value.thinking_default, .toggle = value.reasoning_toggle and (value.reasoning_adaptive or @import("../ai/provider_config.zig").toggleProtocol(kind, endpoint, value.id) != .none), .vision = value.vision, .efforts = efforts });
        hash.update(id);
        hash.update(&.{0});
        hash.update(value.id);
        hash.update(&.{ 0, @intFromBool(enabled), @intFromBool(value.reasoning), @intFromBool(value.vision), @intFromBool(value.reasoning_toggle), @intFromBool(value.reasoning_discovered), @intFromBool(value.reasoning_adaptive) });
        hash.update(&.{if (value.thinking_default) |v| (if (v) @as(u8, 1) else 2) else 0});
        hash.update(std.mem.asBytes(&value.context_window));
        hash.update(std.mem.asBytes(&value.context_discovered));
        for (efforts) |supported| hash.update(&.{@intFromBool(supported)});
    }
    fn deinit(self: *Owned) void {
        self.arena.deinit();
    }
};
fn cloneKey(a: std.mem.Allocator, key: ModelKey) !ModelKey {
    return .{ .provider_id = try a.dupe(u8, key.provider_id), .model_id = try a.dupe(u8, key.model_id) };
}
const ReasoningChoice = union(enum) { off, on, effort: Effort };
const Capture = struct { owner: Owner, revision: u64 };
const Popup = struct { widget: ui.widgets.popover.PopoverResult, body: *ui.Node, title: ?*ui.Node = null, capture: ?Capture = null };
const Choice = struct {
    view: *View,
    kind: S.Kind,
    action: ?Action = null,
    fn choose(self: *Choice) void {
        if (self.action) |action| self.view.emit(self.kind, action) else self.view.close(self.kind, true);
    }
};
const Anchor = struct {
    view: *View,
    kind: S.Kind,
    fn get(raw: *anyopaque) ui.widgets.popover.AnchorRect {
        const self: *Anchor = @ptrCast(@alignCast(raw));
        const rect = self.view.buttons[@backingInt(self.kind)].globalRect();
        return .{ .x = rect.x, .y = rect.y, .w = rect.w, .h = rect.h };
    }
    fn openChanged(self: *Anchor, open: bool) void {
        if (open) return;
        const popup = &self.view.popups[@backingInt(self.kind)];
        popup.capture = null;
        self.view.focus_pending = null;
        if (self.view.cx.focus_manager.current_focus) |focused| if (focused.isDescendantOf(popup.widget.chrome)) self.view.cx.setFocus(self.view.buttons[@backingInt(self.kind)]);
    }
};

pub const View = struct {
    cx: *ui.Cx,
    scope: *ui.Scope,
    callbacks: Callbacks,
    root: *ui.Node = undefined,
    /// Append the host's existing send/stop controls here once.
    trailing: *ui.Node = undefined,
    buttons: [5]*ui.Node = undefined,
    button_styles: [5]*ui.Signal(ui.BoxStyle) = undefined,
    disabled: [5]*ui.Signal(bool) = undefined,
    hover_style: *ui.Signal(?ui.BoxStyle),
    labels: [5]?*ui.Node = @splat(null),
    icons: [5]*ui.Node = undefined,
    chevrons: [3]*ui.Node = undefined,
    popups: [5]Popup = undefined,
    popup_count: usize = 0,
    source: ?Owned = null,
    pending: ?Owned = null,
    clear_pending: bool = false,
    filtered: std.ArrayList(usize) = .empty,
    model_rows: std.ArrayList(struct { index: usize, header: bool }) = .empty,
    collapsed_providers: std.ArrayList([]u8) = .empty,
    pending_provider: ?usize = null,
    model_card: *ui.Node = undefined,
    model_title: *ui.Node = undefined,
    model_close: *ui.Node = undefined,
    reasoning_card: *ui.Node = undefined,
    effort_area: *ui.Node = undefined,
    model_count: *ui.Signal(usize),
    model_version: *ui.Signal(u64),
    model_empty: *ui.Node = undefined,
    model_settings: *ui.Node = undefined,
    model_list: *ui.Node = undefined,
    permission_rows: [2]*ui.Node = undefined,
    permission_styles: [2]*ui.Signal(ui.BoxStyle) = undefined,
    permission_checks: [2]*ui.Node = undefined,
    slider_value: *ui.Signal(f32),
    reasoning_choices: [8]ReasoningChoice = undefined,
    reasoning_count: usize = 0,
    slider: ui.widgets.slider.SliderResult = undefined,
    slider_markers: [8]*ui.Node = undefined,
    slider_thumb: *ui.Node = undefined,
    slider_track: *ui.Node = undefined,
    effort_name: *ui.Node = undefined,
    effort_ticks: [8]*ui.Node = undefined,
    attachment_rows: [4]*ui.Node = undefined,
    attachment_disabled: [4]*ui.Signal(bool) = undefined,
    usage_body: *ui.Node = undefined,
    usage_scope: ?*ui.Scope = null,
    ring: *ui.Node = undefined,
    model_brand: *ui.Node = undefined,
    model_brand_hash: ?u64 = null,
    focus_pending: ?S.Kind = null,
    colors: S.theme.Colors,
    last_error: ?anyerror = null,
    popup_layout_dirty: bool = true,
    viewport: ui.Size = .ZERO,

    pub fn mount(cx: *ui.Cx, scope: *ui.Scope, callbacks: Callbacks) !*View {
        const self = try scope.createState(View, .{ .cx = cx, .scope = scope, .callbacks = callbacks, .hover_style = try scope.createSignal(?ui.BoxStyle, S.hover()), .model_count = try scope.createSignal(usize, 0), .model_version = try scope.createSignal(u64, 0), .slider_value = try scope.createSignal(f32, 0), .colors = S.theme.current() });
        try scope.onCleanup(View, self, release);
        self.root = try ui.box(cx, S.row(), .{});
        self.root.meta.ownership.meta.test_id = "ai.composer.controls";
        // Clear our focus before native Button/Popover child scopes dispose.
        const focus_guard = try scope.childScope();
        try focus_guard.onCleanup(View, self, releaseFocus);
        const names = [_][]const u8{ "添加附件", "执行权限", "选择模型", "推理档位", "上下文与来源" };
        const assets = [_]ui.SvgAsset{ ui.icons.plus, ui.icons.get("hand").?, ui.icons.chevron_down, ui.icons.get("sliders-horizontal").?, ui.icons.circle };
        for (0..5) |index| {
            self.disabled[index] = try scope.createSignal(bool, true);
            const base = switch (index) {
                0 => S.iconButton(8),
                1 => S.chip(98, 8),
                2 => S.chip(190, 8),
                3 => S.chip(80, 7),
                else => S.chip(48, 8),
            };
            self.button_styles[index] = try scope.createSignal(ui.BoxStyle, base);
            const toggle_context = try scope.createState(Toggle, .{ .view = self, .kind = @fromBackingInt(@intCast(index)) });
            const button = try ui.widgets.Button(.{ .variant = .ghost, .a11y_label = names[index], .disabled = self.disabled[index], .base_style = self.button_styles[index], .hover_style = self.hover_style, .on_click = cx.on(Toggle, toggle_context, Toggle.click) }).mount(scope, cx);
            prepareCustomButton(button, if (index == 0) .center else .start, cx.allocator);
            button.meta.ownership.meta.test_id = switch (index) {
                0 => "ai.composer.attachment",
                1 => "ai.composer.permission",
                2 => "ai.composer.model",
                3 => "ai.composer.effort",
                else => "ai.composer.usage",
            };
            self.buttons[index] = button;
            const size: f32 = switch (index) {
                0, 4 => 14,
                1 => 12,
                3 => 14,
                2 => 10,
                else => 16,
            };
            self.icons[index] = if (index == 4) try ui.box(cx, S.ring(), .{}) else try ui.iconTint(cx, assets[index], S.theme.current().fg_3, S.icon(size));
            if (index != 2) try button.appendChild(cx.allocator, self.icons[index]);
            if (index == 1 or index == 3 or index == 4) self.icons[index].setStyleInline(cx.allocator, S.chipIcon(@fromBackingInt(@intCast(index))));
            if (index == 2) {
                self.model_brand = try ui.box(cx, S.modelBrand(), .{});
                self.model_brand.meta.ownership.meta.test_id = "ai.composer.model.logo";
                try button.appendChild(cx.allocator, self.model_brand);
            }
            if (index == 1 or index == 2 or index == 3 or index == 4) {
                const text = try self.label(button, if (index == 1) "执行权限" else if (index == 2) "未配置模型" else if (index == 3) "推理设置" else "—", S.text(10, 400, 14, true), S.chipLabel(@fromBackingInt(@intCast(index))));
                self.labels[index] = text;
            }
            if (index == 1 or index == 2 or index == 3) {
                const chevron = if (index == 2) self.icons[index] else try ui.iconTint(cx, ui.icons.chevron_down, S.theme.current().fg_3, S.icon(10));
                self.chevrons[if (index == 3) 2 else index - 1] = chevron;
                chevron.setStyleInline(cx.allocator, S.chipChevron(@fromBackingInt(@intCast(index))));
                try button.appendChild(cx.allocator, chevron);
            }
            if (index == 4) {
                self.ring = self.icons[index];
                self.ring.setCustomDraw(drawRing, self);
            }
            try self.root.appendChild(cx.allocator, button);
        }
        self.buttons[3].setDisplay(.none);
        cx.detachChild(self.buttons[3], self.labels[3].?);
        self.labels[3].?.setStyleInline(cx.allocator, S.combinedEffortLabel());
        try self.buttons[2].insertChildBefore(cx.allocator, self.labels[3].?, self.chevrons[1]);
        try self.root.appendChild(cx.allocator, try ui.spacer(cx));
        self.trailing = try ui.box(cx, S.trailing(), .{});
        self.trailing.meta.ownership.meta.test_id = "ai.composer.trailing";
        try self.root.appendChild(cx.allocator, self.trailing);
        for (0..5) |index| {
            self.popups[index] = try self.mountPopup(@fromBackingInt(@intCast(index)));
            self.popup_count += 1;
        }
        try self.mountAttachments();
        try self.mountPermissions();
        try self.mountModels();
        try self.mountEffort();
        const usage_scroll = try ui.widgets.ScrollArea(.{}).mount(scope, cx);
        usage_scroll.container.setStyleInline(cx.allocator, .{ .width = .fill(), .height = .fill(), .flex = 1, .min_height = 0 });
        usage_scroll.content.setStyleInline(cx.allocator, .{ .width = .fill(), .direction = .column, .gap = 6 });
        self.usage_body = usage_scroll.content;
        try self.popups[@backingInt(S.Kind.usage)].body.appendChild(cx.allocator, usage_scroll.container);
        try cx.addAfterLayoutHook(self, afterLayout);
        return self;
    }
    const Toggle = struct {
        view: *View,
        kind: S.Kind,
        fn click(self: *Toggle) void {
            self.view.toggle(self.kind);
        }
    };
    fn mountPopup(self: *View, kind: S.Kind) !Popup {
        const anchor = try self.scope.createState(Anchor, .{ .view = self, .kind = kind });
        const open = try self.scope.createSignal(bool, false);
        const result = try ui.widgets.Popover(.{ .open = open, .trigger = .manual, .position = .top_start, .anchor = .{ .virtual = .{ .ctx = anchor, .getRect = Anchor.get } }, .offset = .{ .static = 6 }, .width = S.width(kind), .max_height = if (kind == .usage) 600 else S.height(kind), .close_on_escape = true, .close_on_outside_click = true, .constrain_width_to_viewport = true, .flip = true, .shift_main_axis = true, .viewport_padding = 8, .on_open_change = self.cx.on(Anchor, anchor, Anchor.openChanged) }).mount(self.scope, self.cx);
        result.wrapper.setStyleInline(self.cx.allocator, S.wrapper());
        try self.root.appendChild(self.cx.allocator, result.wrapper);
        result.chrome.setStyleInline(self.cx.allocator, S.panel(kind, self.cx.viewport));
        result.chrome.meta.ownership.meta.test_id = switch (kind) {
            .attachment => "ai.attachment.menu",
            .permission => "ai.permission.menu",
            .model => "ai.model.menu",
            .effort => "ai.effort.menu",
            .usage => "ai.usage.menu",
        };
        var title: ?*ui.Node = null;
        if (kind == .permission or kind == .usage) {
            const header = try ui.box(self.cx, S.header(), .{});
            try header.appendChild(self.cx.allocator, try ui.iconTint(self.cx, if (kind == .permission) ui.icons.shield else ui.icons.chart_pie, S.theme.current().accent, S.icon(16)));
            title = try self.label(header, switch (kind) {
                .permission => "执行权限",
                .model => "选择模型",
                .effort => "推理档位",
                .usage => "上下文与来源",
                else => unreachable,
            }, S.text(13, 700, 20, false), S.flexibleLabel(20));
            title.?.meta.ownership.meta.test_id = if (kind == .permission) "ai.permission.title" else "ai.usage.title";
            const close_context = try self.scope.createState(Choice, .{ .view = self, .kind = kind });
            const close_button = try ui.widgets.Button(.{ .variant = .ghost, .icon_only = true, .icon_asset = ui.icons.x, .icon_size = 16, .a11y_label = "关闭选项", .base_style = S.close(), .hover_style = self.hover_style, .on_click = self.cx.on(Choice, close_context, Choice.choose) }).mount(self.scope, self.cx);
            try header.appendChild(self.cx.allocator, close_button);
            try result.content.appendChild(self.cx.allocator, header);
        }
        const body = if (kind == .attachment) result.content else try ui.box(self.cx, S.body(kind), .{});
        if (kind != .attachment) try result.content.appendChild(self.cx.allocator, body);
        return .{ .widget = result, .body = body, .title = title };
    }
    fn mountAttachments(self: *View) !void {
        const names = [_][]const u8{ "选择图片…", "选择本地文本…", "引用远程文件…", "粘贴图片" };
        const assets = [_]ui.SvgAsset{ ui.icons.get("image").?, ui.icons.get("file-text").?, ui.icons.get("server").?, ui.icons.get("clipboard-paste").? };
        const parent = self.popups[@backingInt(S.Kind.attachment)].body;
        for (0..4) |index| {
            self.attachment_disabled[index] = try self.scope.createSignal(bool, true);
            const choice = try self.scope.createState(Choice, .{ .view = self, .kind = .attachment, .action = .{ .attachment = @fromBackingInt(@intCast(index)) } });
            const button = try ui.widgets.Button(.{ .variant = .ghost, .a11y_label = names[index], .disabled = self.attachment_disabled[index], .base_style = S.attachmentRow(), .hover_style = self.hover_style, .on_click = self.cx.on(Choice, choice, Choice.choose) }).mount(self.scope, self.cx);
            prepareCustomButton(button, .start, self.cx.allocator);
            self.attachment_rows[index] = button;
            button.meta.ownership.meta.test_id = switch (index) {
                0 => "ai.attachment.image",
                1 => "ai.attachment.local_text",
                2 => "ai.attachment.remote_file",
                else => "ai.attachment.paste_image",
            };
            try button.appendChild(self.cx.allocator, try ui.iconTint(self.cx, assets[index], S.theme.current().fg_2, S.icon(16)));
            _ = try self.label(button, names[index], S.text(11.5, 400, 18, false), S.flexibleLabel(18));
            _ = try self.label(button, if (index == 2) "/" else if (index == 3) "⌘V" else "", S.text(10.5, 400, 16, true), S.label(38, 16));
            try parent.appendChild(self.cx.allocator, button);
        }
    }
    fn mountPermissions(self: *View) !void {
        const parent = self.popups[@backingInt(S.Kind.permission)].body;
        for (0..2) |index| {
            const mode: PermissionMode = @fromBackingInt(@intCast(index));
            self.permission_styles[index] = try self.scope.createSignal(ui.BoxStyle, S.option(32, false));
            const choice = try self.scope.createState(Choice, .{ .view = self, .kind = .permission, .action = .{ .permission = mode } });
            const button = try ui.widgets.Button(.{ .variant = .ghost, .a11y_label = permissionLabel(mode), .disabled = self.disabled[1], .base_style = self.permission_styles[index], .hover_style = self.hover_style, .on_click = self.cx.on(Choice, choice, Choice.choose) }).mount(self.scope, self.cx);
            prepareCustomButton(button, .start, self.cx.allocator);
            button.meta.ownership.meta.test_id = if (mode == .confirm) "ai.permission.confirm" else "ai.permission.auto";
            self.permission_rows[index] = button;
            self.permission_checks[index] = try ui.iconTint(self.cx, ui.icons.circle, S.theme.current().fg_2, S.icon(14));
            try button.appendChild(self.cx.allocator, self.permission_checks[index]);
            try button.appendChild(self.cx.allocator, try ui.iconTint(self.cx, ui.icons.get(if (mode == .confirm) "hand" else "shield-check").?, S.theme.current().fg_2, S.icon(16)));
            _ = try self.label(button, permissionLabel(mode), S.text(12, 500, 18, false), S.flexibleLabel(18));
            try parent.appendChild(self.cx.allocator, button);
            _ = try self.label(parent, if (mode == .confirm) "只读检查自动进行，修改前由你确认。" else "允许当前会话内自主操作；组写调用仍需确认。", S.text(10.5, 400, 16, true), S.flexibleLabel(16));
        }
        _ = try self.label(parent, "仅作用于当前助手范围；禁止项始终不可执行。", S.text(10.5, 400, 16, true), S.flexibleLabel(16));
    }
    fn mountModels(self: *View) !void {
        const parent = self.popups[@backingInt(S.Kind.model)].body;
        const header = try ui.box(self.cx, S.modelHeader(), .{});
        try header.appendChild(self.cx.allocator, try ui.iconTint(self.cx, ui.icons.sparkles, S.theme.current().fg_2, S.icon(17)));
        self.model_title = try self.label(header, "模型与推理强度", S.text(13, 700, 20, false), S.flexibleLabel(20));
        const close_context = try self.scope.createState(Choice, .{ .view = self, .kind = .model });
        self.model_close = try ui.widgets.Button(.{ .variant = .ghost, .icon_only = true, .icon_asset = ui.icons.x, .icon_size = 14, .a11y_label = "关闭模型列表", .base_style = S.close(), .hover_style = self.hover_style, .on_click = self.cx.on(Choice, close_context, Choice.choose) }).mount(self.scope, self.cx);
        self.model_close.setStyleInline(self.cx.allocator, .{ .width = .{ .px = 24 }, .height = .{ .px = 24 } });
        self.model_close.meta.ownership.meta.test_id = "ai.model.close";
        try header.appendChild(self.cx.allocator, self.model_close);
        try parent.appendChild(self.cx.allocator, header);
        self.model_card = try ui.box(self.cx, S.modelListCard(192), .{});
        try parent.appendChild(self.cx.allocator, self.model_card);
        self.model_empty = try self.label(self.model_card, "暂无已配置模型", S.text(11.5, 400, 18, true), S.flexibleLabel(30));
        self.model_settings = try ui.widgets.Button(.{ .label = "打开 AI 设置", .variant = .secondary, .base_style = S.option(28, false), .on_click = self.cx.on(View, self, openModelSettings) }).mount(self.scope, self.cx);
        self.model_settings.meta.ownership.meta.test_id = "ai.model.settings";
        try self.model_card.appendChild(self.cx.allocator, self.model_settings);
        const list = try ui.widgets.VirtualList(.{ .item_count = self.model_count, .data_version = self.model_version, .item_height = 30, .item_height_fn = modelItemHeight, .item_height_context = self, .height = 172, .overscan = 1 }).rows(self, renderModel).viewMount(self.scope, self.cx);
        self.model_list = list.root.?;
        self.model_list.meta.ownership.meta.test_id = "ai.model.list";
        self.model_list.setStyleInline(self.cx.allocator, S.models());
        try self.model_card.appendChild(self.cx.allocator, self.model_list);
        self.reasoning_card = try ui.box(self.cx, S.modelCard(40), .{});
        try parent.appendChild(self.cx.allocator, self.reasoning_card);
    }
    fn openModelSettings(self: *View) void {
        if (self.callbacks.open_settings) |open| open(self.callbacks.context);
    }
    fn modelItemHeight(index: usize, raw: ?*anyopaque) f32 {
        const self: *View = @ptrCast(@alignCast(raw orelse return 30));
        return if (index < self.model_rows.items.len and self.model_rows.items[index].header) 24 else 30;
    }
    fn renderModel(self: *View, filtered_index: usize, scope: *ui.Scope, cx: *ui.Cx) !*ui.Node {
        const source = if (self.source) |*source| &source.value else return error.NoModelSource;
        if (filtered_index >= self.model_rows.items.len) return error.StaleModelRow;
        const entry = self.model_rows.items[filtered_index];
        const model = source.models[entry.index];
        if (entry.header) {
            const state = try scope.createState(ProviderGroup, .{ .view = self, .index = entry.index });
            const row = try ui.widgets.Button(.{ .variant = .ghost, .a11y_label = model.key.provider_id, .base_style = S.groupLabel(), .on_click = cx.on(ProviderGroup, state, ProviderGroup.toggle) }).mount(scope, cx);
            row.meta.ownership.meta.test_id = "ai.model.provider";
            const collapsed = self.providerCollapsed(model.key.provider_id);
            try row.appendChild(cx.allocator, try ui.iconTint(cx, if (collapsed) ui.icons.chevron_right else ui.icons.chevron_down, S.theme.current().fg_2, S.icon(12)));
            const brand = @import("ai_brand.zig");
            try row.appendChild(cx.allocator, try brand.mount(cx, brand.provider(model.key.provider_id, ""), model.key.provider_id, 16));
            _ = try self.label(row, model.key.provider_id, S.text(10, 400, 12, true), S.flexibleLabel(12));
            return row;
        }
        const id = try scope.createText(model.key.model_id, .{});
        const provider_id = try scope.createText(model.key.provider_id, .{});
        const choice = try scope.createState(Choice, .{ .view = self, .kind = .model, .action = .{ .model = .{ .provider_id = provider_id.peek(), .model_id = id.peek() } } });
        const selected = if (source.current) |current| current.eql(model.key) else false;
        var levels: std.Io.Writer.Allocating = .init(scope.allocator);
        defer levels.deinit();
        for (model.efforts, 0..) |supported, effort_index| if (supported and model.reasoning) {
            if (levels.written().len != 0) try levels.writer.writeAll(" / ");
            try levels.writer.writeAll(effortLabel(@fromBackingInt(@intCast(effort_index))));
        };
        const full_name = try std.fmt.allocPrint(scope.allocator, "{s}\n{s} · {s}\n{s}上下文 {d} tokens · {s}\n{s} · 工具能力未声明\n{s}{s}", .{ id.peek(), provider_id.peek(), id.peek(), if (model.context_discovered) "已发现" else "配置", model.context_window, if (model.enabled) "可用" else "Provider 未配置或已禁用", if (model.vision) "支持图片输入" else "仅文本输入", if (model.reasoning) "推理档位：" else "无推理档位", levels.written() });
        defer scope.allocator.free(full_name);
        const description = try scope.createText(full_name, .{});
        // Tooltip has no fixed-width contract in this zenit revision. Its
        // underlying native Popover gives the shared model-info surface its
        // declared 284px width while retaining hover, flip and viewport clamp.
        const hint = try ui.widgets.Popover(.{ .trigger = .hover, .position = .right, .offset = .{ .static = 8 }, .width = 284, .max_height = 180, .constrain_width_to_viewport = true, .shift_main_axis = true, .tier = .tooltip, .close_on_outside_click = false, .close_on_escape = false }).mount(scope, cx);
        hint.chrome.meta.ownership.meta.test_id = "ai.model.details";
        hint.chrome.setHitTestVisible(false);
        hint.chrome.setStyleInline(cx.allocator, .{ .width = .{ .px = 284 }, .min_width = 284, .max_width = 284, .padding = .{ .left = 12, .right = 12, .top = 10, .bottom = 10 }, .background = S.theme.current().well, .border = .{ .radius = 9 } });
        var detail_style = S.text(11, 400, 18, true);
        detail_style.wrap = .word;
        const detail_label = try ui.text(cx, description.peek(), detail_style);
        detail_label.setStyleInline(cx.allocator, .{ .width = .fill() });
        try hint.content.appendChild(cx.allocator, detail_label);
        const button = try ui.widgets.Button(.{ .variant = .ghost, .a11y_label = description, .disabled = !model.enabled or !source.editable, .base_style = S.modelOption(selected), .hover_style = self.hover_style, .on_click = cx.on(Choice, choice, Choice.choose) }).mount(scope, cx);
        prepareCustomButton(button, .start, cx.allocator);
        button.meta.ownership.meta.test_id = "ai.model.option";
        if (button.behavior.interaction.a11y) |*attrs| {
            attrs.selected = selected;
            attrs.description = description.peek();
        }
        const ink = if (model.enabled) S.theme.current().fg_2 else S.theme.current().fg_3;
        var marker_style = S.modelMarker();
        marker_style.width = .{ .px = if (selected) 4.234375 else 3.171875 };
        const marker = try ui.box(cx, marker_style, .{});
        marker.meta.ownership.meta.test_id = if (selected) "ai.model.selected" else "ai.model.unselected";
        if (selected) {
            _ = try self.label(marker, "›", S.modelMarkerText(), S.label(4.234375, 16));
        } else {
            try marker.appendChild(cx.allocator, try ui.box(cx, S.modelMarkerDot(), .{}));
        }
        try button.appendChild(cx.allocator, marker);
        const brand = @import("ai_brand.zig");
        const logo = try brand.mount(cx, brand.model(id.peek()), brand.basename(id.peek()), 20);
        logo.meta.ownership.meta.test_id = "ai.model.logo";
        try button.appendChild(cx.allocator, logo);
        const name = try self.label(button, id.peek(), S.text(11, 400, 13, false), S.flexibleLabel(13));
        name.setTextColor(if (model.enabled) S.theme.current().fg_1 else S.theme.current().fg_3);
        var context_buffer: [32]u8 = undefined;
        const context_text = if (model.context_window >= 1000000) try std.fmt.bufPrint(&context_buffer, "{s}{d}M", .{ if (model.context_discovered) "" else "配置", model.context_window / 1000000 }) else try std.fmt.bufPrint(&context_buffer, "{s}{d}k", .{ if (model.context_discovered) "" else "配置", model.context_window / 1000 });
        const context_width = @max(@ceil(cx.text.measureTextWidth(context_text, 10, 400, true)) + 2, @as(f32, @floatFromInt(context_text.len)) * 6.5);
        const context_label = try self.label(button, context_text, S.text(10, 400, 13, false), S.label(context_width, 13));
        if (context_label.getText()) |text| {
            var value = text;
            value.use_monospace_font = true;
            value.text_overflow = .clip;
            context_label.setText(value);
        }
        context_label.setTextColor(ink);
        context_label.meta.ownership.meta.test_id = "ai.model.context";
        if (model.reasoning) {
            const reasoning_hint = try ui.widgets.Tooltip(.{ .text = "支持推理" }).mount(scope, cx);
            reasoning_hint.wrapper.setStyleInline(cx.allocator, S.visionTarget());
            reasoning_hint.trigger.setStyleInline(cx.allocator, S.visionTarget());
            reasoning_hint.trigger.meta.ownership.meta.test_id = "ai.model.reasoning";
            reasoning_hint.content.meta.ownership.meta.test_id = "ai.model.reasoning.tooltip";
            try reasoning_hint.trigger.appendChild(cx.allocator, try ui.iconTint(cx, ui.icons.get("brain").?, ink, S.icon(14)));
            try button.appendChild(cx.allocator, reasoning_hint.wrapper);
        }
        if (model.vision) {
            const vision_hint = try ui.widgets.Tooltip(.{ .text = "支持图片输入与识图" }).mount(scope, cx);
            vision_hint.wrapper.setStyleInline(cx.allocator, S.visionTarget());
            vision_hint.trigger.setStyleInline(cx.allocator, S.visionTarget());
            try vision_hint.trigger.appendChild(cx.allocator, try ui.iconTint(cx, ui.icons.get("image").?, ink, S.icon(14)));
            try button.appendChild(cx.allocator, vision_hint.wrapper);
        }
        hint.wrapper.setStyleInline(cx.allocator, .{ .width = .fill(), .height = .{ .px = 30 }, .min_width = 0 });
        hint.trigger.setStyleInline(cx.allocator, .{ .width = .fill(), .height = .{ .px = 30 }, .min_width = 0 });
        try hint.trigger.appendChild(cx.allocator, button);
        // Native Tooltip supplies hover; focus state drives the same information
        // surface for keyboard users without introducing another control.
        const focused = try ui.hooks.useFocusState(scope, cx, button);
        const hovered = try ui.hooks.useHover(scope, hint.wrapper);
        if (hint.open) |open| try scope.createEffect(.{ .focused = focused.focused, .hovered = hovered, .open = open, .parent = self.popups[@backingInt(S.Kind.model)].widget.open.? }, struct {
            fn run(ctx: anytype) void {
                ctx.open.set(ctx.parent.get() and (ctx.focused.get() or ctx.hovered.get()));
            }
        }.run);
        return hint.wrapper;
    }
    fn mountEffort(self: *View) !void {
        const parent = self.reasoning_card;
        self.effort_name = try self.label(parent, "不支持推理设置", S.text(10, 400, 16.5, true), S.flexibleLabel(16.5));
        const area = try ui.box(self.cx, S.sliderArea(), .{});
        self.effort_area = area;
        self.slider = try ui.widgets.Slider(.{ .label_text = "推理档位", .min = 0, .max = 4, .step = 0, .width = 308, .track_height = 3, .thumb_size = 12, .value = ui.split(self.slider_value, self.cx.on(View, self, effortProposed)), .disabled = self.disabled[@backingInt(S.Kind.effort)], .test_id = "ai.effort.slider.track" }).mount(self.scope, self.cx);
        self.slider.wrapper.setStyleInline(self.cx.allocator, S.slider());
        self.slider.wrapper.meta.ownership.meta.test_id = "ai.effort.slider";
        self.slider.wrapper.behavior.events.capture_context = self;
        self.slider.wrapper.behavior.events.on_event_capture = sliderKey;
        // These are the public Node parts of the installed native Slider:
        // track-area contains track/fill followed by the pointer-driven thumb.
        const track_area = self.slider.wrapper.children.items[0];
        self.slider_track = track_area.children.items[0];
        self.slider_thumb = track_area.children.items[1];
        self.slider_track.setBackground(S.theme.current().well);
        self.slider_thumb.setStyleInline(self.cx.allocator, S.sliderThumb());
        for (0..8) |index| {
            const tick = try ui.box(self.cx, S.sliderTick(index, 8), .{});
            self.slider_markers[index] = tick;
            tick.meta.ownership.meta.test_id = "ai.effort.marker";
            try track_area.insertChildBefore(self.cx.allocator, tick, self.slider_thumb);
        }
        try area.appendChild(self.cx.allocator, self.slider.wrapper);
        const ticks = try ui.box(self.cx, S.ticks(), .{});
        for (0..8) |index| self.effort_ticks[index] = try self.label(ticks, "", S.text(9, 400, 12, true), S.label(32, 12));
        try area.appendChild(self.cx.allocator, ticks);
        try parent.appendChild(self.cx.allocator, area);
    }
    /// Borrowed inputs are projected to owned display data during this call.
    /// Publication/rebinding happens in the next safe layout hook.
    pub fn update(self: *View, snapshot: ?Snapshot) !void {
        if (snapshot) |value| {
            var next = try Owned.init(self.cx.allocator, value);
            errdefer next.deinit();
            const previous = if (self.pending) |*pending| &pending.value else if (self.source) |*source| &source.value else null;
            if (previous) |old| if (old.owner.eql(value.owner)) {
                if (value.revision < old.revision) return error.StaleSnapshot;
                if (value.revision == old.revision and next.value.config_hash != old.config_hash) return error.ConfigurationChangedWithoutRevision;
                if (projectionEql(old.*, next.value)) {
                    next.deinit();
                    return;
                }
            };
            if (self.pending) |*old| old.deinit();
            self.pending = next;
            self.clear_pending = false;
        } else {
            if (self.source == null and self.pending == null and !self.clear_pending) return;
            if (self.pending) |*old| old.deinit();
            self.pending = null;
            self.clear_pending = true;
        }
        self.cx.requestRedraw();
    }
    pub fn dismiss(self: *View) void {
        for (0..5) |index| self.close(@fromBackingInt(@intCast(index)), false);
        self.focus_pending = null;
    }
    pub fn isOpen(self: *const View) bool {
        for (self.popups) |popup| if (popup.widget.open.?.peek()) return true;
        return false;
    }
    pub fn flush(self: *View) !void {
        if (self.pending_provider) |index| {
            self.pending_provider = null;
            try self.toggleProvider(index);
        }
        var changed = false;
        if (self.clear_pending) {
            self.clear_pending = false;
            self.dismiss();
            if (self.source) |*old| old.deinit();
            self.source = null;
            changed = true;
        } else if (self.pending) |next| {
            if (self.source) |*old| {
                if (!old.value.owner.eql(next.value.owner) or old.value.revision != next.value.revision) {
                    self.dismiss();
                } else if (!optionalKeyEql(old.value.current, next.value.current)) self.close(.effort, false);
                old.deinit();
            }
            self.source = next;
            self.pending = null;
            changed = true;
        }
        const colors = S.theme.current();
        const themed = !std.meta.eql(colors, self.colors);
        if (themed) {
            repaint(self.root, self.colors);
            for (self.popups) |popup| repaint(popup.widget.chrome, self.colors);
        }
        if (changed or themed) {
            try self.refresh();
            try self.filterModels();
            try self.refreshUsage();
            self.colors = colors;
        }
        if (changed or themed or self.popup_layout_dirty or !std.meta.eql(self.viewport, self.cx.viewport)) {
            for (0..5) |index| {
                const kind: S.Kind = @fromBackingInt(@intCast(index));
                var style = S.panel(kind, self.cx.viewport);
                if (kind == .model) {
                    const middle: f32 = 180;
                    const reason_height: f32 = if (self.disabled[3].peek()) 32.5 else 67.5;
                    var reason_style = S.modelCard(reason_height);
                    reason_style.padding = ui.Padding.all(8);
                    reason_style.gap = 3;
                    self.reasoning_card.setStyleInline(self.cx.allocator, reason_style);
                    self.model_card.setStyleInline(self.cx.allocator, S.modelListCard(middle));
                    const panel_height = @min(30 + 26 + middle + reason_height + 18, @max(0, self.cx.viewport.height - 16));
                    style.height = .{ .px = panel_height };
                    style.min_height = panel_height;
                }
                if (kind == .usage) if (self.source) |source| if (source.value.usage) |usage| {
                    const panel_height = @min(@as(f32, 116) + @as(f32, @floatFromInt(usage.parts.len)) * 26, @max(0, self.cx.viewport.height - 16));
                    style.height = .{ .px = panel_height };
                    style.min_height = panel_height;
                    style.max_height = panel_height;
                };
                self.popups[index].widget.chrome.setStyleInline(self.cx.allocator, style);
            }
            self.popup_layout_dirty = false;
            self.viewport = self.cx.viewport;
        }
        // Native Slider reapplies its own white/disabled thumb when the
        // capability signal changes; keep the current global-role paint.
        const slider_ink = if (self.disabled[3].peek()) colors.fg_3 else colors.accent;
        if (!ui.Color.eql(self.slider_thumb.getBackground(), slider_ink)) self.slider_thumb.setBackground(slider_ink);
        const fill = self.slider_track.children.items[0];
        if (!ui.Color.eql(fill.getBackground(), slider_ink)) fill.setBackground(slider_ink);
    }
    fn toggle(self: *View, requested: S.Kind) void {
        const kind: S.Kind = if (requested == .effort) .model else requested;
        const index = @backingInt(kind);
        if (self.disabled[index].peek() or self.source == null) return;
        if (self.popups[index].widget.open.?.peek()) {
            self.close(kind, true);
            return;
        }
        self.dismiss();
        const source = &self.source.?.value;
        self.last_error = null;
        self.popups[index].capture = .{ .owner = source.owner, .revision = source.revision };
        self.popups[index].widget.open.?.set(true);
        self.focus_pending = kind;
        self.popup_layout_dirty = true;
        self.cx.requestRedraw();
    }
    fn close(self: *View, kind: S.Kind, restore: bool) void {
        const popup = &self.popups[@backingInt(kind)];
        const was_open = popup.widget.open.?.peek();
        popup.widget.open.?.set(false);
        popup.capture = null;
        if (restore and was_open) self.cx.setFocus(self.buttons[@backingInt(kind)]);
    }
    fn capture(self: *View, kind: S.Kind) ?Capture {
        const popup = &self.popups[@backingInt(if (kind == .effort) S.Kind.model else kind)];
        if (!popup.widget.open.?.peek()) return null;
        const captured = popup.capture orelse return null;
        const source = if (self.source) |*source| &source.value else return null;
        if (!captured.owner.eql(source.owner) or captured.revision != source.revision) return null;
        if (self.clear_pending) return null;
        if (self.pending) |*pending| if (!captured.owner.eql(pending.value.owner) or captured.revision != pending.value.revision) return null;
        return captured;
    }
    fn findModel(self: *const View, key: ModelKey) ?Model {
        const source = if (self.source) |source| source.value else return null;
        for (source.models) |item| if (item.key.eql(key)) return item;
        return null;
    }
    fn currentModel(self: *const View) ?Model {
        const source = if (self.source) |source| source.value else return null;
        return self.findModel(source.current orelse return null);
    }
    fn attachmentAvailable(self: *const View, attachment: Attachment) bool {
        const source = if (self.source) |source| source.value else return false;
        if (!source.editable) return false;
        const allowed = switch (attachment) {
            .image => source.attachments.image,
            .local_text => source.attachments.local_text,
            .remote_file => source.attachments.remote_file,
            .paste_image => source.attachments.paste_image,
        };
        if (!allowed) return false;
        // Capture remains available when the next model lacks vision. The
        // host preserves the image and explains why sending is blocked.
        return true;
    }
    fn emit(self: *View, kind: S.Kind, action: Action) void {
        const captured = self.capture(kind) orelse return;
        const source = &self.source.?.value;
        if (!source.editable) return;
        switch (action) {
            .model => |key| {
                const selected = self.findModel(key) orelse return;
                if (!selected.enabled) return;
            },
            .permission => {},
            .compact_context => if (source.usage == null or !source.usage.?.can_compact) return,
            .cancel_compaction => if (source.usage == null or source.usage.?.compaction != .running) return,
            .effort => |value| {
                const selected = self.currentModel() orelse return;
                if (!selected.enabled or !selected.key.eql(value.model) or !selected.reasoning or !selected.efforts[@backingInt(value.value)]) return;
            },
            .thinking => |value| {
                const selected = self.currentModel() orelse return;
                if (!selected.enabled or !selected.key.eql(value.model) or !selected.reasoning or !selected.toggle) return;
            },
            .attachment => |attachment| if (!self.attachmentAvailable(attachment)) return,
        }
        self.callbacks.action(self.callbacks.context, .{ .owner = captured.owner, .revision = captured.revision, .action = action }) catch |err| {
            self.last_error = err;
            if (self.popups[@backingInt(kind)].title) |title| title.setTextContent(self.cx.allocator, "无法更新，请重试") catch {};
            return;
        };
        self.last_error = null;
        if (kind != .effort and kind != .model and kind != .usage) self.close(kind, true);
    }
    fn chooseReasoning(self: *View, index: usize) void {
        if (index >= self.reasoning_count) return;
        const selected = self.currentModel() orelse return;
        switch (self.reasoning_choices[index]) {
            .off => self.emit(.model, .{ .thinking = .{ .model = selected.key, .enabled = false } }),
            .on => self.emit(.model, .{ .thinking = .{ .model = selected.key, .enabled = true } }),
            .effort => |value| self.emit(.effort, .{ .effort = .{ .model = selected.key, .value = value } }),
        }
    }
    fn effortProposed(self: *View, raw: f32) void {
        if (!std.math.isFinite(raw) or self.reasoning_count == 0) return;
        const index: usize = @intFromFloat(@round(std.math.clamp(raw, 0, 4) * @as(f32, @floatFromInt(self.reasoning_count - 1)) / 4));
        self.chooseReasoning(index);
    }
    fn sliderKey(event: ui.events.Event, raw: ?*anyopaque) ui.events.EventResult {
        const self: *View = @ptrCast(@alignCast(raw orelse return .ignored));
        if (event != .key_down) return .ignored;
        const key = event.key_down.key;
        if (key != .left and key != .right and key != .home and key != .end) return .ignored;
        if (self.capture(.effort) == null or self.disabled[@backingInt(S.Kind.effort)].peek()) return .ignored;
        if (self.reasoning_count == 0) return .ignored;
        const current: i32 = @intFromFloat(@round(self.slider_value.peek() * @as(f32, @floatFromInt(self.reasoning_count - 1)) / 4));
        const last: i32 = @intCast(self.reasoning_count - 1);
        const next = if (key == .home) 0 else if (key == .end) last else std.math.clamp(current + @as(i32, if (key == .left) -1 else 1), 0, last);
        self.chooseReasoning(@intCast(next));
        return .stop;
    }
    const ProviderGroup = struct {
        view: *View,
        index: usize,
        fn toggle(self: *ProviderGroup) void {
            self.view.pending_provider = self.index;
            self.view.cx.requestRedraw();
        }
    };
    fn providerCollapsed(self: *View, id: []const u8) bool {
        for (self.collapsed_providers.items) |value| if (std.mem.eql(u8, value, id)) return true;
        return false;
    }
    fn toggleProvider(self: *View, index: usize) !void {
        const source = if (self.source) |*value| &value.value else return;
        if (index >= source.models.len) return;
        const id = source.models[index].key.provider_id;
        for (self.collapsed_providers.items, 0..) |value, i| if (std.mem.eql(u8, value, id)) {
            self.cx.allocator.free(self.collapsed_providers.orderedRemove(i));
            try self.filterModels();
            return;
        };
        const copy = try self.cx.allocator.dupe(u8, id);
        errdefer self.cx.allocator.free(copy);
        try self.collapsed_providers.append(self.cx.allocator, copy);
        try self.filterModels();
    }
    fn filterModels(self: *View) !void {
        self.filtered.clearRetainingCapacity();
        if (self.source) |*source| for (source.value.models, 0..) |_, index| {
            try self.filtered.append(self.cx.allocator, index);
        };
        self.model_rows.clearRetainingCapacity();
        var previous: ?[]const u8 = null;
        if (self.source) |source| for (self.filtered.items) |index| {
            const id = source.value.models[index].key.provider_id;
            if (previous == null or !std.mem.eql(u8, previous.?, id)) try self.model_rows.append(self.cx.allocator, .{ .index = index, .header = true });
            if (!self.providerCollapsed(id)) try self.model_rows.append(self.cx.allocator, .{ .index = index, .header = false });
            previous = id;
        };
        self.model_count.set(self.model_rows.items.len);
        self.model_version.set(self.model_version.peek() +| 1);
        self.popup_layout_dirty = true;
        self.model_empty.setDisplay(if (self.filtered.items.len == 0) .flex else .none);
        self.model_list.setDisplay(if (self.filtered.items.len == 0) .none else .flex);
        var available = false;
        if (self.source) |*value| for (value.value.models) |model| {
            available = available or model.enabled;
        };
        self.model_settings.setDisplay(if (!available and self.callbacks.open_settings != null) .flex else .none);
        try self.model_empty.setTextContent(self.cx.allocator, "暂无已配置模型");
    }
    fn refreshModelBrand(self: *View, id: ?[]const u8) !void {
        const brand = @import("ai_brand.zig");
        self.model_brand.setDisplay(if (id != null) .flex else .none);
        var hash = std.hash.Wyhash.init(0);
        hash.update(id orelse "");
        std.hash.autoHash(&hash, S.theme.current().fg_1);
        std.hash.autoHash(&hash, S.theme.current().hover);
        if (self.model_brand_hash == hash.final()) return;
        const next = if (id) |name| try brand.mount(self.cx, brand.model(name), brand.basename(name), 16) else null;
        while (self.model_brand.children.items.len > 0) {
            const child = self.model_brand.children.items[0];
            self.cx.detachChild(self.model_brand, child);
            self.cx.destroyDetached(child);
        }
        if (next) |node| try self.model_brand.appendChild(self.cx.allocator, node);
        self.model_brand_hash = hash.final();
    }
    fn refresh(self: *View) !void {
        const colors = S.theme.current();
        const source = if (self.source) |*source| &source.value else null;
        const editable = if (source) |value| value.editable else false;
        const current = self.currentModel();
        var any_model = false;
        if (source) |value| for (value.models) |item| {
            any_model = any_model or item.enabled;
        };
        var any_attachment = false;
        for (0..4) |index| {
            const enabled = self.attachmentAvailable(@fromBackingInt(@intCast(index)));
            self.attachment_disabled[index].set(!enabled);
            for (self.attachment_rows[index].children.items) |child| {
                if (child.getText() != null) child.setTextColor(if (enabled) colors.fg_1 else colors.fg_3);
                _ = child.setTint(if (enabled) colors.fg_2 else colors.fg_3);
            }
            any_attachment = any_attachment or enabled;
        }
        var any_effort = false;
        if (current) |item| for (item.efforts) |enabled| {
            any_effort = any_effort or enabled;
        };
        self.disabled[0].set(!any_attachment);
        self.disabled[1].set(!editable);
        self.disabled[2].set(!editable or (!any_model and self.callbacks.open_settings == null));
        self.reasoning_count = 0;
        if (current) |model| if (model.reasoning and model.enabled) {
            if (model.toggle) {
                self.reasoning_choices[self.reasoning_count] = .off;
                self.reasoning_count += 1;
            }
            for ([_]usize{ 5, 0, 1, 2, 3, 4, 6 }) |index| if (model.efforts[index]) {
                self.reasoning_choices[self.reasoning_count] = .{ .effort = @fromBackingInt(@intCast(index)) };
                self.reasoning_count += 1;
            };
            if (model.toggle and !any_effort) {
                self.reasoning_choices[self.reasoning_count] = .on;
                self.reasoning_count += 1;
            }
        };
        self.disabled[3].set(!editable or self.reasoning_count == 0);
        self.disabled[4].set(source == null or source.?.usage == null);
        if (self.disabled[0].peek()) self.close(.attachment, false);
        if (self.disabled[1].peek()) self.close(.permission, false);
        if (self.disabled[2].peek()) self.close(.model, false);
        if (self.disabled[3].peek()) self.close(.effort, false);
        if (self.disabled[4].peek()) self.close(.usage, false);
        self.hover_style.set(S.hover());
        for (0..5) |index| {
            self.button_styles[index].set(switch (index) {
                0 => S.iconButton(8),
                1 => S.chip(98, 8),
                2 => S.chip(190, 8),
                3 => S.chip(80, 7),
                else => S.chip(48, 8),
            });
            _ = self.icons[index].setTint(if (self.disabled[index].peek()) colors.fg_3 else colors.fg_2);
            if (self.labels[index]) |label_node| label_node.setTextColor(if (self.disabled[index].peek()) colors.fg_3 else colors.fg_2);
        }
        for (self.chevrons) |icon_node| _ = icon_node.setTint(colors.fg_2);
        const has_modality = current != null;
        const permission = if (source) |value| permissionLabel(value.permission) else "执行权限";
        try self.labels[1].?.setTextContent(self.cx.allocator, permission);
        if (self.buttons[1].behavior.interaction.a11y) |*attrs| attrs.label = self.labels[1].?.getText().?.content;
        setAsset(self.icons[1], if (source != null and source.?.permission == .auto) "shield-check" else "hand", 12, if (editable) colors.fg_2 else colors.fg_3);
        const full_model_name = if (current) |item| item.key.model_id else if (source) |value| if (value.current) |key| key.model_id else "未配置模型" else "未配置模型";
        try self.refreshModelBrand(if (current) |item| item.key.model_id else null);
        var model_label_buffer: [512]u8 = undefined;
        var displayed_model_name = full_model_name;
        if (self.cx.text.measureTextWidth(full_model_name, 10, 400, false) > 100) {
            var end = @min(full_model_name.len, model_label_buffer.len - 4);
            const ellipsis_width = self.cx.text.measureTextWidth("…", 10, 400, false);
            while (end > 0) : (end -= 1) {
                if (std.unicode.utf8ValidateSlice(full_model_name[0..end]) and self.cx.text.measureTextWidth(full_model_name[0..end], 10, 400, false) + ellipsis_width <= 100) break;
            }
            displayed_model_name = try std.fmt.bufPrint(&model_label_buffer, "{s}…", .{full_model_name[0..end]});
        }
        try self.labels[2].?.setTextContent(self.cx.allocator, displayed_model_name);
        if (self.buttons[2].behavior.interaction.a11y) |*attrs| attrs.label = full_model_name;
        for (0..2) |index| {
            const selected = source != null and @backingInt(source.?.permission) == index;
            self.permission_styles[index].set(S.option(32, selected));
            setAsset(self.permission_checks[index], if (selected) "check" else "circle", 14, colors.fg_2);
            if (self.permission_rows[index].behavior.interaction.a11y) |*attrs| attrs.selected = selected;
        }
        const effort = if (source) |value| value.effort else null;
        const default_thinking = if (current) |m| m.thinking_default orelse false else false;
        const thinking_enabled = if (source) |value| value.thinking orelse default_thinking else default_thinking;
        self.effort_area.setDisplay(if (!self.disabled[3].peek()) .flex else .none);
        self.effort_name.setDisplay(.flex);
        const effort_text = if (current == null or !current.?.enabled) "模型未就绪" else if (!current.?.reasoning) "不支持推理" else if (current.?.toggle and !any_effort) (if (source.?.thinking == null and current.?.thinking_default == null) "默认" else if (thinking_enabled) "思考开" else "思考关") else if (!any_effort) "推理未开放" else if (effort) |value| if (current.?.efforts[@backingInt(value)]) effortLabel(value) else "档位不支持" else "默认";
        var effort_heading: [96]u8 = undefined;
        try self.effort_name.setTextContent(self.cx.allocator, if (!self.disabled[3].peek()) try std.fmt.bufPrint(&effort_heading, "推理强度 {s}", .{effort_text}) else if (current != null and current.?.enabled and current.?.reasoning and !current.?.toggle and !any_effort) "未开放思考开关或推理档位" else effort_text);
        try self.labels[3].?.setTextContent(self.cx.allocator, effort_text);
        const model_width = @max(24, @min(100, self.cx.text.measureTextWidth(self.labels[2].?.getText().?.content, 10, 400, false)));
        const show_effort = current != null and current.?.reasoning;
        self.labels[3].?.setDisplay(if (show_effort) .flex else .none);
        const effort_width = if (show_effort) @max(10, self.cx.text.measureTextWidth(effort_text, 10, 400, false)) else 0;
        self.labels[2].?.setStyleInline(self.cx.allocator, S.compactModelLabel(model_width, has_modality));
        self.labels[3].?.setStyleInline(self.cx.allocator, S.compactEffortLabel(model_width, effort_width, has_modality));
        self.chevrons[1].setStyleInline(self.cx.allocator, S.compactModelChevron(model_width, effort_width, has_modality));
        self.button_styles[2].set(S.naturalChip());
        var selected_choice: usize = 0;
        for (self.reasoning_choices[0..self.reasoning_count], 0..) |choice, index| {
            const selected = switch (choice) {
                .off => !thinking_enabled,
                .on => thinking_enabled,
                .effort => |value| effort != null and value == effort.? and (source.?.thinking == null or thinking_enabled),
            };
            if (selected) selected_choice = index;
        }
        self.slider_value.set(if (self.reasoning_count > 1) @as(f32, @floatFromInt(selected_choice)) * 4 / @as(f32, @floatFromInt(self.reasoning_count - 1)) else 0);
        for (0..8) |index| {
            const visible = index < self.reasoning_count;
            self.effort_ticks[index].setDisplay(if (visible) .flex else .none);
            self.slider_markers[index].setDisplay(if (visible) .flex else .none);
            if (visible) {
                const choice = self.reasoning_choices[index];
                try self.effort_ticks[index].setTextContent(self.cx.allocator, switch (choice) {
                    .off => "关闭",
                    .on => "开启",
                    .effort => |value| effortLabel(value),
                });
                self.slider_markers[index].setStyleInline(self.cx.allocator, S.sliderTick(index, self.reasoning_count));
            }
            self.effort_ticks[index].setTextColor(colors.fg_2);
        }
        self.slider_track.setBackground(colors.well);
        self.slider_thumb.setStyleInline(self.cx.allocator, S.sliderThumb());
        self.effort_name.setTextColor(colors.fg_2);
        if (self.buttons[3].behavior.interaction.a11y) |*attrs| attrs.label = self.effort_name.getText().?.content;
        var buffer: [64]u8 = undefined;
        const usage = if (source) |value| value.usage else null;
        try self.labels[4].?.setTextContent(self.cx.allocator, if (usage) |value| try percentText(&buffer, value) else "—");
        self.labels[4].?.setStyleInline(self.cx.allocator, .{ .position = .relative, .inset = .{}, .width = .{ .fit = .{} }, .height = .{ .px = 14 }, .flex_shrink = 0 });
        self.ring.setStyleInline(self.cx.allocator, .{ .position = .relative, .inset = .{}, .width = .{ .px = 8 }, .height = .{ .px = 8 }, .flex_shrink = 0 });
        self.button_styles[4].set(S.naturalChip());
        self.ring.markRenderDirty();
    }
    fn refreshUsage(self: *View) !void {
        while (self.usage_body.children.items.len != 0) {
            const node = self.usage_body.children.items[0];
            self.cx.detachChild(self.usage_body, node);
            self.cx.destroyDetached(node);
        }
        if (self.usage_scope) |old| old.dispose();
        self.usage_scope = try self.scope.childScope();
        const source = if (self.source) |source| source.value else return;
        const usage = source.usage orelse return;
        var buffer: [192]u8 = undefined;
        const summary = try ui.box(self.cx, S.usageRow(), .{});
        summary.meta.ownership.meta.test_id = "ai.usage.summary";
        _ = try self.label(summary, "上下文已用", S.text(11, 400, 18, true), S.label(64, 18));
        var percent_buffer: [24]u8 = undefined;
        _ = try self.label(summary, try percentText(&percent_buffer, usage), S.text(11.5, 500, 18, false), S.label(34, 18));
        try summary.appendChild(self.cx.allocator, try ui.spacer(self.cx));
        var used_buffer: [24]u8 = undefined;
        var limit_buffer: [24]u8 = undefined;
        _ = try self.label(summary, try std.fmt.bufPrint(&buffer, "{s}{s} / {s}", .{ if (usage.estimated) "~" else "", try tokenText(&used_buffer, usage.used_tokens), try tokenText(&limit_buffer, usage.limit_tokens) }), S.text(11.5, 500, 18, false), S.label(112, 18));
        try self.usage_body.appendChild(self.cx.allocator, summary);
        const track_row = try ui.box(self.cx, S.usageTrackRow(), .{});
        const track = try ui.box(self.cx, S.usageTrack(), .{});
        track.meta.ownership.meta.test_id = "ai.usage.track";
        var remaining: f32 = 1;
        for (usage.parts, 0..) |part, index| {
            const ratio = @min(remaining, @as(f32, @floatFromInt(part.tokens)) / @as(f32, @floatFromInt(usage.limit_tokens)));
            if (ratio <= 0) continue;
            try track.appendChild(self.cx.allocator, try ui.box(self.cx, S.usageSegment(ratio, index), .{}));
            remaining -= ratio;
        }
        try track_row.appendChild(self.cx.allocator, track);
        const running = usage.compaction == .running;
        const action_label: []const u8 = if (running) "取消压缩" else switch (usage.compaction) {
            .failed => "压缩失败，点击重试",
            .cancelled => "已取消压缩，点击重新压缩",
            .succeeded => if (usage.can_compact) "上下文已压缩，点击再次压缩" else "上下文已压缩",
            else => if (usage.can_compact) "压缩上下文" else "对话较短，无需压缩",
        };
        const choice = try self.usage_scope.?.createState(Choice, .{ .view = self, .kind = .usage, .action = if (running) .cancel_compaction else .compact_context });
        const disabled = try self.usage_scope.?.createSignal(bool, !running and !usage.can_compact);
        const button = try ui.widgets.Button(.{ .a11y_label = action_label, .icon_only = true, .icon_asset = if (running) ui.icons.x else ui.icons.get("minimize-2").?, .icon_size = @as(f32, 16), .icon_tint = S.theme.current().accent_ink, .variant = .ghost, .disabled = disabled, .base_style = S.compactionButton(), .hover_style = S.hover(), .on_click = self.cx.on(Choice, choice, Choice.choose) }).mount(self.usage_scope.?, self.cx);
        button.meta.ownership.meta.test_id = if (running) "ai.usage.compaction.cancel" else "ai.usage.compaction.start";
        const hint = try ui.widgets.Tooltip(.{ .text = action_label, .open_delay_ms = 450 }).mount(self.usage_scope.?, self.cx);
        try hint.trigger.appendChild(self.cx.allocator, button);
        try track_row.appendChild(self.cx.allocator, hint.wrapper);
        try self.usage_body.appendChild(self.cx.allocator, track_row);
        for (usage.parts, 0..) |part, index| {
            const row = try ui.box(self.cx, S.usageRow(), .{});
            try row.appendChild(self.cx.allocator, try ui.box(self.cx, S.usageSwatch(index), .{}));
            _ = try self.label(row, part.name, S.text(11, 400, 18, true), S.flexibleLabel(18));
            const value = try self.label(row, try std.fmt.bufPrint(&buffer, "{s}{s}", .{ if (usage.estimated) "~" else "", try tokenText(&used_buffer, part.tokens) }), S.text(11, 400, 18, false), S.label(64, 18));
            value.meta.ownership.meta.test_id = "ai.usage.part.value";
            try self.usage_body.appendChild(self.cx.allocator, row);
        }
        const desired_height = @min(@as(f32, 116) + @as(f32, @floatFromInt(usage.parts.len)) * 26, @max(0, self.cx.viewport.height - 16));
        self.popups[@backingInt(S.Kind.usage)].widget.chrome.setStyleInline(self.cx.allocator, .{ .height = .{ .px = desired_height }, .min_height = desired_height, .max_height = desired_height });
    }
    fn afterLayout(raw: *anyopaque, _: u8, _: bool) ui.AfterLayoutResult {
        const self: *View = @ptrCast(@alignCast(raw));
        self.flush() catch {};
        // The installed Button recipe forwards frame dimensions but omits
        // positioning. Send and Stop share this slot; position their native
        // button nodes explicitly so the hidden sibling cannot shrink Send.
        var slot_changed = false;
        for (self.trailing.children.items) |button| if (button.style.position != .absolute) {
            button.setStyleInline(self.cx.allocator, .{ .position = .absolute, .inset = .{ .left = .{ .px = 0 }, .top = .{ .px = 0 } }, .width = .{ .px = 28 }, .height = .{ .px = 28 }, .min_width = 28, .min_height = 28, .flex_shrink = 0 });
            slot_changed = true;
        };
        if (slot_changed) return .needs_layout;
        for (self.trailing.children.items) |button| {
            const id = button.meta.ownership.meta.test_id orelse continue;
            if ((!std.mem.eql(u8, id, "ai.send") and !std.mem.eql(u8, id, "ai.stop")) or button.getOpacity() == 0) continue;
            const hovered = if (self.cx.hovered_node) |node| node == button or node.isDescendantOf(button) else false;
            button.setBackground(if (hovered) S.theme.current().hover else S.theme.current().surface_2);
            if (!std.mem.eql(u8, id, "ai.send")) continue;
            const disabled = if (button.behavior.interaction.a11y) |attrs| attrs.disabled else false;
            button.setOpacityRaw(if (disabled) 0.45 else 1);
            for (button.children.items) |child| {
                if (child.getIcon() != null) _ = child.setTint(if (disabled) S.theme.current().fg_2 else S.theme.current().fg_1);
            }
        }
        var parent: ?*ui.Node = self.root;
        while (parent) |node| : (parent = node.parent) if (node.style.display == .none) {
            self.dismiss();
            return .done;
        };
        if (self.focus_pending) |kind| {
            self.focus_pending = null;
            const node = switch (kind) {
                .model => self.model_close,
                .permission => self.permission_rows[if (self.source) |source| @backingInt(source.value.permission) else 0],
                .effort => self.slider.wrapper,
                .attachment => self.attachment_rows[firstEnabled(self.attachment_disabled) orelse 0],
                .usage => self.buttons[4],
            };
            self.cx.setFocus(node);
        }
        return .done;
    }
    fn label(self: *View, parent: *ui.Node, text_value: []const u8, style: ui.TextStyle, box: ui.BoxStyle) !*ui.Node {
        var label_style = style;
        label_style.text_overflow = .clip;
        const node = try ui.text(self.cx, "", label_style);
        try node.setTextContent(self.cx.allocator, text_value);
        node.setStyleInline(self.cx.allocator, box);
        try parent.appendChild(self.cx.allocator, node);
        return node;
    }
    fn drawRing(ctx: ui.DrawContext, raw: ?*anyopaque) anyerror!void {
        const self: *View = @ptrCast(@alignCast(raw orelse return));
        const dl = ctx.display_list orelse return;
        const header = ctx.display_header orelse return;
        try dl.append(.{ .arc = .{ .header = header, .cx = 4, .cy = 4, .outer_radius = 4, .stroke_width = 1, .start_angle = 0, .end_angle = std.math.tau, .color = S.theme.current().fg_3 } });
        const source = if (self.source) |source| source.value else return;
        const usage = source.usage orelse return;
        const ratio = @min(1, @as(f32, @floatFromInt(usage.used_tokens)) / @as(f32, @floatFromInt(usage.limit_tokens)));
        if (ratio > 0) try dl.append(.{ .arc = .{ .header = header, .cx = 4, .cy = 4, .outer_radius = 4, .stroke_width = 1, .start_angle = -std.math.pi / 2.0, .end_angle = -std.math.pi / 2.0 + std.math.tau * ratio, .color = S.theme.current().accent } });
    }
    fn release(self: *View) void {
        self.cx.removeAfterLayoutHook(self);
        if (self.source) |*source| source.deinit();
        if (self.pending) |*pending| pending.deinit();
        self.filtered.deinit(self.cx.allocator);
        self.model_rows.deinit(self.cx.allocator);
        for (self.collapsed_providers.items) |id| self.cx.allocator.free(id);
        self.collapsed_providers.deinit(self.cx.allocator);
    }
    fn releaseFocus(self: *View) void {
        const focused = self.cx.focus_manager.current_focus orelse return;
        if (focused.isDescendantOf(self.root)) {
            self.cx.clearFocus();
            return;
        }
        for (self.popups[0..self.popup_count]) |popup| if (focused.isDescendantOf(popup.widget.chrome)) {
            self.cx.clearFocus();
            return;
        };
    }
};
fn firstEnabled(disabled: [4]*ui.Signal(bool)) ?usize {
    for (disabled, 0..) |signal, index| if (!signal.peek()) return index;
    return null;
}
fn setAsset(node: *ui.Node, name: []const u8, size: f32, tint: ui.Color) void {
    const asset = ui.icons.get(name) orelse return;
    if (asset.icon_id) |id| if (asset.pickRep(size)) |rep| node.setIcon(.{ .icon_id = id, .rep = rep, .tint = tint });
}
fn percentage(value: Usage) u64 {
    return @intFromFloat(@min(999, @floor(@as(f64, @floatFromInt(value.used_tokens)) * 100 / @as(f64, @floatFromInt(value.limit_tokens)))));
}
fn optionalKeyEql(first: ?ModelKey, second: ?ModelKey) bool {
    if (first) |key| return if (second) |other| key.eql(other) else false;
    return second == null;
}
fn projectionEql(first: Projection, second: Projection) bool {
    return first.owner.eql(second.owner) and first.revision == second.revision and first.config_hash == second.config_hash and optionalKeyEql(first.current, second.current) and first.permission == second.permission and first.effort == second.effort and first.thinking == second.thinking and std.meta.eql(first.attachments, second.attachments) and first.editable == second.editable and usageEql(first.usage, second.usage);
}
fn usageEql(first: ?Usage, second: ?Usage) bool {
    const one = first orelse return second == null;
    const two = second orelse return false;
    if (one.compaction_before != two.compaction_before or one.compaction_after != two.compaction_after or one.compaction != two.compaction or one.can_compact != two.can_compact or one.used_tokens != two.used_tokens or one.limit_tokens != two.limit_tokens or one.estimated != two.estimated or one.request_tokens != two.request_tokens or one.redacted != two.redacted or one.parts.len != two.parts.len) return false;
    for (one.parts, two.parts) |left, right| if (left.tokens != right.tokens or !std.mem.eql(u8, left.name, right.name)) return false;
    return true;
}
fn prepareCustomButton(button: *ui.Node, justify: ui.JustifyContent, allocator: std.mem.Allocator) void {
    // A label-less native Button retains an empty content slot. Hide that
    // slot before adding the custom row, preserving its scope and behavior.
    for (button.children.items) |child| child.setDisplay(.none);
    // The native Button recipe centers its frame regardless of base_style.
    button.setStyleInline(allocator, .{ .justify = justify });
}
fn repaint(node: *ui.Node, old: S.theme.Colors) void {
    node.setBackground(remap(node.getBackground(), old));
    if (node.getText()) |text_value| node.setTextColor(remap(text_value.color, old));
    if (node.getIcon()) |icon| _ = node.setTint(remap(icon.tint, old));
    for (node.children.items) |child| repaint(child, old);
}
fn remap(value: ui.Color, old: S.theme.Colors) ui.Color {
    const next = S.theme.current();
    inline for (@typeInfo(S.theme.Colors).@"struct".field_names) |field| if (ui.Color.eql(value, @field(old, field))) return @field(next, field);
    return value;
}

fn percentText(buffer: []u8, usage: Usage) ![]const u8 {
    if (usage.used_tokens > 0 and percentage(usage) == 0) return "<1%";
    return std.fmt.bufPrint(buffer, "{d}%", .{percentage(usage)});
}
fn tokenText(buffer: []u8, value: u64) ![]const u8 {
    if (value >= 1000000) return std.fmt.bufPrint(buffer, "{d:.1}M", .{@as(f64, @floatFromInt(value)) / 1000000});
    if (value >= 1000) return std.fmt.bufPrint(buffer, "{d:.1}K", .{@as(f64, @floatFromInt(value)) / 1000});
    return std.fmt.bufPrint(buffer, "{d}", .{value});
}

test "composer readiness matches an unauthenticated local gateway without enabling remote endpoints" {
    var models = [_]config.AiModel{.{ .id = "local-model", .context_window = 8192, .default = true }};
    var providers = [_]config.AiProvider{.{ .name = "local", .kind = .openai_compat, .enabled = true, .endpoint = "http://127.0.0.1:3425/v1/chat/completions", .model_count = 1, .models = &models }};
    var local = try Owned.init(std.testing.allocator, .{ .owner = .{ .session = 1 }, .revision = 1, .providers = &providers });
    defer local.arena.deinit();
    try std.testing.expect(local.value.models[0].enabled);
    providers[0].endpoint = "https://example.test/v1/chat/completions";
    var remote = try Owned.init(std.testing.allocator, .{ .owner = .{ .session = 1 }, .revision = 2, .providers = &providers });
    defer remote.arena.deinit();
    try std.testing.expect(!remote.value.models[0].enabled);
}
