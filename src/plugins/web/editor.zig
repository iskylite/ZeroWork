//! Native web connection form hosted by the standard connection wizard.
const std = @import("std");
const ui = @import("ui");
const contract = @import("../../host/plugin_ui_contract.zig");
const envelopes = @import("../../config/connection_envelope.zig");
const identity = envelopes.identity;
const config = @import("config.zig");
const bookmarks = @import("bookmarks.zig");
const RoutePicker = @import("../remote/route_picker.zig").RoutePicker;
const route_hop = @import("../remote/route_hop_control.zig");
const route_view = @import("../remote/route_view.zig");
const repair_view = @import("editor_repair.zig");
const S = @import("editor_styles.zig");

const Editor = struct {
    args: contract.EditorMount,
    arena: std.heap.ArenaAllocator,
    origin: ?identity.AssetOwner = null,
    group: ?identity.AssetGroupId = null,
    saved_bookmarks: []const bookmarks.Bookmark = &.{},
    load_failure: ?anyerror = null,
    closed: bool = false,
    mode: *ui.Signal(config.UrlMode) = undefined,
    route: *ui.Signal(config.RouteMode) = undefined,
    name: *ui.Signal([]const u8) = undefined,
    address: *ui.Signal([]const u8) = undefined,
    name_error: *ui.Signal([]const u8) = undefined,
    address_error: *ui.Signal([]const u8) = undefined,
    url_field: *ui.Node = undefined,
    path_view: *route_view.View = undefined,
    hops: [config.max_hops]?u64 = @splat(null),
    hop_count: usize = 0,
    add_disabled: *ui.Signal(bool) = undefined,
    locked: *ui.Signal(bool) = undefined,
    route_hook: bool = false,
    reveal_hop: ?usize = null,
    options: []const ui.widgets.SelectOption = &.{},
    form: *ui.Node = undefined,
    repair: ?*repair_view.Panel = null,
    feedback: *ui.Node = undefined,

    fn cleanup(self: *Editor) void {
        if (self.route_hook) self.args.cx.removeAfterLayoutHook(self);
        self.arena.deinit();
    }

    fn choosePreset(self: *Editor) void {
        self.chooseMode(.preset);
    }

    fn chooseManual(self: *Editor) void {
        self.chooseMode(.manual);
    }

    fn chooseMode(self: *Editor, mode: config.UrlMode) void {
        if (self.closed or self.mode.peek() == mode) return;
        self.mode.set(mode);
        self.url_field.setDisplay(if (mode == .preset) .flex else .none);
        self.address_error.set("");
        self.refreshTarget();
        self.changed();
    }

    fn chooseDirect(self: *Editor) void {
        self.chooseRoute(.direct);
    }

    fn chooseSsh(self: *Editor) void {
        self.chooseRoute(.ssh);
    }

    fn chooseRoute(self: *Editor, mode: config.RouteMode) void {
        if (self.closed or self.route.peek() == mode) return;
        self.route.set(mode);
        if (mode == .direct) self.hideRouteMenus();
        if (mode == .ssh and self.hop_count == 0) self.hop_count = 1;
        self.refreshHops();
        self.changed();
    }

    fn hideRouteMenus(self: *Editor) void {
        self.path_view.close();
    }

    fn visibilityChanged(raw: *anyopaque, visible: bool) void {
        const self: *Editor = @ptrCast(@alignCast(raw));
        if (!visible) self.hideRouteMenus();
    }

    fn pickerOptions(raw: *anyopaque, _: RoutePicker.Target) []const ui.widgets.SelectOption {
        const self: *Editor = @ptrCast(@alignCast(raw));
        return self.options;
    }

    fn pickerAvailable(raw: *anyopaque, target: RoutePicker.Target, value: []const u8) bool {
        const self: *Editor = @ptrCast(@alignCast(raw));
        const id = parseChoice(value);
        if (self.closed or self.locked.peek() or id == 0 or self.route.peek() != .ssh) return false;
        const resolver = self.args.connection_configs orelse return false;
        const live = resolver.registry.indexOf(@fromBackingInt(id)) orelse return false;
        if (!std.mem.eql(u8, resolver.registry.hosts[live].protocolId(), "ssh")) return false;
        for (self.hops[0..self.hop_count], 0..) |hop, i| {
            if (target == .replace and i == target.replace) continue;
            if (hop == id) return false;
        }
        return true;
    }

    fn pickerChoose(raw: *anyopaque, target: RoutePicker.Target, value: []const u8) void {
        const self: *Editor = @ptrCast(@alignCast(raw));
        if (!pickerAvailable(self, target, value)) return;
        const id = parseChoice(value);
        const index = switch (target) {
            .insert => |index| blk: {
                if (index > self.hop_count or self.hop_count >= config.max_hops) return;
                std.mem.copyBackwards(?u64, self.hops[index + 1 .. self.hop_count + 1], self.hops[index..self.hop_count]);
                self.hop_count += 1;
                break :blk index;
            },
            .replace => |index| if (index < self.hop_count) index else return,
        };
        self.hops[index] = id;
        self.path_view.picker.close();
        self.reveal_hop = index;
        self.refreshHops();
        self.changed();
    }

    fn routeLayout(raw: *anyopaque, _: u8, _: bool) ui.AfterLayoutResult {
        const self: *Editor = @ptrCast(@alignCast(raw));
        if (self.closed or !self.path_view.root.isDisplayedInTree()) return .done;
        const vertical = self.routeIsVertical();
        const natural = route_view.naturalHeight(self.hop_count, vertical);
        const cx = self.args.cx;
        const compact = S.wizard.compactWindow(cx.viewport.width, cx.viewport.height);
        const limit = @min(710, S.wizard.availableModalHeight(cx.viewport.height, compact));
        const height = if (self.route.peek() == .ssh) @min(natural, @max(52, limit - self.formHeight() - 16)) else 0;
        if (self.path_view.layout(vertical, height)) return .needs_layout;
        if (self.path_view.picker.update()) return .needs_layout;
        if (self.reveal_hop) |index| {
            self.reveal_hop = null;
            self.path_view.reveal(index);
        }
        return .done;
    }

    fn routeIsVertical(self: *const Editor) bool {
        return route_view.isVertical(self.hop_count, self.args.cx.viewport.width);
    }

    fn replaceHop(raw: *anyopaque, index: usize, trigger: *ui.Node) void {
        const self: *Editor = @ptrCast(@alignCast(raw));
        if (self.closed or self.locked.peek() or index >= self.hop_count or self.route.peek() != .ssh) return;
        self.path_view.picker.show(trigger, .{ .replace = index });
    }

    fn reorderHop(raw: *anyopaque, index: usize, action: route_hop.Action) void {
        const self: *Editor = @ptrCast(@alignCast(raw));
        if (self.closed or self.locked.peek() or index >= self.hop_count) return;
        switch (action) {
            .up => {
                if (index == 0) return;
                std.mem.swap(?u64, &self.hops[index], &self.hops[index - 1]);
            },
            .down => {
                if (index + 1 >= self.hop_count) return;
                std.mem.swap(?u64, &self.hops[index], &self.hops[index + 1]);
            },
            .remove => {
                for (index..self.hop_count - 1) |i| self.hops[i] = self.hops[i + 1];
                self.hop_count -= 1;
                self.hops[self.hop_count] = null;
                if (self.hop_count == 0) self.route.set(.direct);
            },
        }
        self.refreshHops();
        self.changed();
    }

    fn nameChanged(self: *Editor, _: []const u8) void {
        self.name_error.set("");
        self.refreshTarget();
        self.changed();
    }

    fn addressChanged(self: *Editor, _: []const u8) void {
        self.address_error.set("");
        self.refreshTarget();
        self.changed();
    }

    fn changed(self: *Editor) void {
        self.report(if (self.load_failure) |err| message(err) else "");
        self.args.events.changed(self.args.events.context);
    }

    fn report(self: *Editor, copy: []const u8) void {
        self.feedback.setTextContent(self.args.cx.allocator, copy) catch return;
        self.feedback.setDisplay(if (copy.len == 0) .none else .flex);
        self.args.cx.requestRedraw();
    }

    fn refreshTarget(self: *Editor) void {
        const a = self.args.cx.allocator;
        const preview = &self.path_view.preview;
        preview.names[9].?.setTextContent(a, self.name.peek()) catch {};
        preview.addresses[9].?.setTextContent(a, if (self.mode.peek() == .preset) self.address.peek() else "") catch {};
    }

    fn refreshHops(self: *Editor) void {
        self.path_view.setRoute(self.route.peek() == .ssh, self.hop_count);
        const a = self.args.cx.allocator;
        const preview = &self.path_view.preview;
        for (self.hops[0..self.hop_count], 1..) |id, i| {
            const host = if (id) |asset_id| host: {
                const resolver = self.args.connection_configs orelse break :host null;
                const index = resolver.registry.indexOf(@fromBackingInt(asset_id)) orelse break :host null;
                const asset = resolver.registry.hosts[index];
                break :host if (std.mem.eql(u8, asset.protocolId(), "ssh")) asset else null;
            } else null;
            preview.names[i].?.setTextContent(a, if (host) |asset| asset.name else if (id != null) "找不到此 SSH 主机" else "选择跳板") catch {};
            var buffer: [256]u8 = undefined;
            const address = if (host) |asset|
                if (asset.port == 22)
                    std.fmt.bufPrint(&buffer, "{s}@{s}", .{ asset.user, asset.host }) catch asset.host
                else
                    std.fmt.bufPrint(&buffer, "{s}@{s}:{d}", .{ asset.user, asset.host, asset.port }) catch asset.host
            else
                "";
            preview.addresses[i].?.setTextContent(a, address) catch {};
        }
        self.refreshTarget();
        var can_insert = false;
        if (self.hop_count < config.max_hops) {
            for (self.options) |option| if (pickerAvailable(self, .{ .insert = self.hop_count }, option.value)) {
                can_insert = true;
                break;
            };
        }
        self.add_disabled.set(!can_insert);
    }

    fn saved(self: *Editor) void {
        self.submit(.save);
    }

    fn opened(self: *Editor) void {
        self.submit(.save_and_open);
    }

    fn temporary(self: *Editor) void {
        self.submit(.temporary);
    }

    fn submit(self: *Editor, intent: contract.SubmitIntent) void {
        if (self.closed or self.load_failure != null or self.repair != null) return;
        var scratch = std.heap.ArenaAllocator.init(self.args.cx.allocator);
        defer scratch.deinit();
        const draft = self.snapshot(scratch.allocator()) catch |err| {
            switch (err) {
                error.MissingName, error.InvalidEnvelope => self.name_error.set(message(err)),
                error.MissingUrl, error.InvalidUrl, error.InvalidHost, error.InvalidPort, error.UnsupportedScheme => self.address_error.set(message(err)),
                else => self.report(message(err)),
            }
            return;
        };
        self.args.events.submit(self.args.events.context, draft, intent) catch |err| self.report(message(err));
    }

    fn snapshot(self: *Editor, allocator: std.mem.Allocator) !envelopes.Envelope {
        if (self.closed) return error.EditorClosed;
        if (self.load_failure) |err| return err;
        if (self.repair != null) return error.BookmarkRepairRequired;
        const name = std.mem.trim(u8, self.name.peek(), " \t\r\n");
        const origin = self.origin orelse identity.AssetOwner{ .id = @fromBackingInt(0), .revision = 1 };
        var value: envelopes.Envelope = .{
            .id = origin.id,
            .revision = origin.revision,
            .name = name,
            .protocol_id = config.protocol_id,
            .group_id = self.group,
            .payload_version = config.payload_version,
            .payload = "",
        };
        try value.validate();
        var ids: [config.max_hops]u64 = undefined;
        var route: config.Route = .{};
        if (self.route.peek() == .ssh) {
            if (self.hop_count == 0) return error.MissingSshReference;
            const resolver = self.args.connection_configs orelse return error.ConfigurationResolverUnavailable;
            var typed: [config.max_hops]identity.ConnectionId = undefined;
            for (self.hops[0..self.hop_count], ids[0..self.hop_count], typed[0..self.hop_count]) |hop, *id, *asset| {
                id.* = hop orelse return error.MissingSshReference;
                asset.* = @fromBackingInt(id.*);
            }
            var frozen = try resolver.freezeRoute(typed[0..self.hop_count], allocator);
            frozen.deinit();
            route = .{ .mode = .ssh, .hop_asset_ids = ids[0..self.hop_count] };
        }
        value.payload = try config.encode(allocator, .{
            .url_mode = self.mode.peek(),
            .start_url = if (self.mode.peek() == .preset) self.address.peek() else null,
            .route = route,
            .bookmarks = self.saved_bookmarks,
        });
        errdefer allocator.free(value.payload);
        value.name = try allocator.dupe(u8, name);
        return value;
    }

    fn snapshotCallback(raw: *anyopaque, allocator: std.mem.Allocator) !envelopes.Envelope {
        const self: *Editor = @ptrCast(@alignCast(raw));
        return self.snapshot(allocator);
    }

    fn close(raw: *anyopaque) void {
        const self: *Editor = @ptrCast(@alignCast(raw));
        self.closed = true;
    }

    fn cancelled(self: *Editor) void {
        if (self.closed) return;
        if (self.args.events.cancelled orelse self.args.events.dismiss) |callback| callback(self.args.events.context);
    }

    fn cancelCallback(raw: *anyopaque) void {
        const self: *Editor = @ptrCast(@alignCast(raw));
        const picker = self.path_view.picker;
        if (picker.popup.open.?.peek()) {
            picker.close();
            return;
        }
        self.cancelled();
    }

    fn dismissCallback(raw: *anyopaque) void {
        const self: *Editor = @ptrCast(@alignCast(raw));
        self.cancelled();
    }

    fn repairApplied(raw: *anyopaque, inputs: []const bookmarks.RepairInput) !void {
        const self: *Editor = @ptrCast(@alignCast(raw));
        const panel = self.repair orelse return error.BookmarkRepairRequired;
        self.saved_bookmarks = try bookmarks.applyRepair(self.arena.allocator(), inputs);
        self.args.cx.setFocus(null);
        panel.root.setDisplay(.none);
        self.repair = null;
        self.form.setDisplay(.flex);
        self.changed();
    }

    fn modalPresentation(raw: *anyopaque) contract.ModalPresentation {
        const self: *Editor = @ptrCast(@alignCast(raw));
        return .{ .width = if (self.repair != null) S.width else S.wizard.width, .title = if (self.repair != null) "修复书签" else if (self.origin != null) "编辑连接" else "新建连接" };
    }

    fn formHeight(self: *const Editor) f32 {
        return if (self.mode.peek() == .preset) 466 else 408;
    }

    fn modalHeight(raw: *anyopaque) ?f32 {
        const self: *Editor = @ptrCast(@alignCast(raw));
        if (self.repair != null) return 644;
        const form = self.formHeight();
        if (self.route.peek() == .direct) return form;
        return @min(710, form + 16 + route_view.naturalHeight(self.hop_count, self.routeIsVertical()));
    }
};

pub fn mount(_: ?*anyopaque, args: contract.EditorMount) !contract.EditorInstance {
    if (!std.mem.eql(u8, args.protocol_id, config.protocol_id)) return error.ProtocolMismatch;
    const cx = args.cx;
    const scope = args.scope;
    const self = try scope.createState(Editor, .{ .args = args, .arena = .init(cx.allocator) });
    scope.onCleanup(Editor, self, Editor.cleanup) catch |err| {
        self.cleanup();
        return err;
    };
    var payload: config.Payload = .{ .url_mode = .preset };
    var repair: ?config.Repair = null;
    if (args.initial) |initial| {
        self.origin = .{ .id = initial.id, .revision = initial.revision };
        self.group = initial.group_id;
        // A decoded document owns its strings via the editor arena.
        const decoded = config.decode(self.arena.allocator(), initial.payload_version, initial.payload) catch |err| blk: {
            if (err == error.OutOfMemory) return err;
            self.load_failure = err;
            break :blk null;
        };
        if (decoded) |data| switch (data.content) {
            .ready => |value| payload = value,
            .repair => |draft| {
                payload = draft.base;
                repair = draft;
            },
        };
    }
    self.saved_bookmarks = payload.bookmarks;
    self.name = try scope.createText(if (args.initial) |initial| initial.name else "", .{});
    self.address = try scope.createText(payload.start_url orelse "", .{});
    self.name_error = try scope.createText("", .{});
    self.address_error = try scope.createText("", .{});
    self.mode = try scope.createSignal(config.UrlMode, payload.url_mode);
    self.route = try scope.createSignal(config.RouteMode, payload.route.mode);
    self.add_disabled = try scope.createSignal(bool, false);
    self.locked = try scope.createSignal(bool, self.load_failure != null);
    self.hop_count = payload.route.hop_asset_ids.len;
    for (payload.route.hop_asset_ids, 0..) |id, index| self.hops[index] = id;
    self.options = try hopOptions(self);

    const root = try ui.boxStyled(cx, S.layout, .{});
    root.meta.ownership.meta.test_id = "web.editor";
    try args.slot.appendChild(cx.allocator, root);
    const form = try ui.boxStyled(cx, S.layout, .{});
    try root.appendChild(cx.allocator, form);
    self.form = form;
    const scroll = try ui.widgets.ScrollArea(.{}).mount(scope, cx);
    scroll.container.setStyleInline(cx.allocator, S.wizard.scroll());
    scroll.container.meta.ownership.meta.test_id = "web.editor.scroll";
    try form.appendChild(cx.allocator, scroll.container);
    const body = try ui.boxStyled(cx, S.body, .{});
    try scroll.content.appendChild(cx.allocator, body);

    const name_field = try labeled(cx, body, "名称");
    try textField(cx, scope, name_field, self.name, self.name_error, "例如：生产监控", "web.editor.name", cx.on(Editor, self, Editor.nameChanged));

    const mode_field = try labeled(cx, body, "打开方式");
    const mode_track = try ui.boxStyled(cx, S.segmentTrack, .{});
    mode_track.meta.ownership.meta.test_id = "web.editor.mode";
    try mode_field.appendChild(cx.allocator, mode_track);
    try segmentButton(cx, scope, mode_track, self.mode, .preset, "预设网址", "web.editor.mode.preset", cx.on(Editor, self, Editor.choosePreset));
    try segmentButton(cx, scope, mode_track, self.mode, .manual, "手动输入", "web.editor.mode.manual", cx.on(Editor, self, Editor.chooseManual));

    self.url_field = try labeled(cx, body, "起始网址");
    try textField(cx, scope, self.url_field, self.address, self.address_error, "https://intranet.example.com", "web.editor.url", cx.on(Editor, self, Editor.addressChanged));
    self.url_field.setDisplay(if (payload.url_mode == .preset) .flex else .none);

    const route_field = try labeled(cx, body, "连接路径");
    self.path_view = try route_view.mount(cx, scope, .{
        .locked = self.locked,
        .insert_disabled = self.add_disabled,
        .direct = cx.on(Editor, self, Editor.chooseDirect),
        .ssh = cx.on(Editor, self, Editor.chooseSsh),
        .hop_actions = .{ .context = self, .replace = Editor.replaceHop, .reorder = Editor.reorderHop },
        .picker_actions = .{ .context = self, .options = Editor.pickerOptions, .available = Editor.pickerAvailable, .choose = Editor.pickerChoose },
        .target_role = "目标网页",
        .target_icon = ui.icons.globe,
    });
    try route_field.appendChild(cx.allocator, self.path_view.root);
    try cx.addAfterLayoutHook(self, Editor.routeLayout);
    self.route_hook = true;
    try scope.createEffect(.{ .editor = self, .route = self.route, .theme = try cx.themeSignal(scope) }, struct {
        fn paint(ctx: anytype) void {
            _ = ctx.theme.get();
            ctx.editor.path_view.paint(ctx.route.get() == .ssh);
        }
    }.paint);
    self.refreshHops();

    self.feedback = try ui.textStyled(cx, S.feedback, "");
    self.feedback.meta.ownership.meta.test_id = "web.editor.feedback";
    try body.appendChild(cx.allocator, self.feedback);
    self.report(if (self.load_failure) |err| message(err) else "");

    const footer = try ui.boxStyled(cx, S.footer, .{});
    footer.meta.ownership.meta.test_id = "web.editor.footer";
    try form.appendChild(cx.allocator, footer);
    try actionButton(cx, scope, footer, "取消", "web.editor.cancel", false, .{ .value = false }, cx.on(Editor, self, Editor.cancelled));
    try footer.appendChild(cx.allocator, try ui.spacer(cx));
    const disabled: ui.Source(bool) = .{ .value = self.load_failure != null };
    if (self.origin == null) try actionButton(cx, scope, footer, "临时连接", "web.editor.temporary", false, disabled, cx.on(Editor, self, Editor.temporary));
    try actionButton(cx, scope, footer, "仅保存", "web.editor.save", false, disabled, cx.on(Editor, self, Editor.saved));
    try actionButton(cx, scope, footer, "保存并连接", "web.editor.open", true, disabled, cx.on(Editor, self, Editor.opened));

    if (repair) |draft| {
        form.setDisplay(.none);
        self.repair = try repair_view.mount(cx, scope, root, draft.rows, .{
            .context = self,
            .apply = Editor.repairApplied,
            .cancel = Editor.dismissCallback,
        });
    }
    return .{ .context = self, .handles_actions = true, .vtable = &.{
        .snapshot = Editor.snapshotCallback,
        .clear_secrets = noSecrets,
        .unmount = Editor.close,
        .cancel = Editor.cancelCallback,
        .preferred_modal_height = Editor.modalHeight,
        .modal_presentation = Editor.modalPresentation,
        .visibility_changed = Editor.visibilityChanged,
    } };
}

fn noSecrets(_: *anyopaque) void {}

fn parseChoice(value: []const u8) u64 {
    return std.fmt.parseInt(u64, value, 10) catch 0;
}

fn hopOptions(self: *Editor) ![]const ui.widgets.SelectOption {
    const a = self.arena.allocator();
    var options: std.ArrayList(ui.widgets.SelectOption) = .empty;
    if (self.args.connection_configs) |resolver| for (resolver.registry.hosts) |host| {
        if (!std.mem.eql(u8, host.protocolId(), "ssh")) continue;
        const id = @backingInt(host.connection_id);
        try options.append(a, .{
            .value = try std.fmt.allocPrint(a, "{d}", .{id}),
            .label = try a.dupe(u8, host.name),
            .test_id = try std.fmt.allocPrint(a, "web.editor.ssh.{d}", .{id}),
        });
    };
    return options.toOwnedSlice(a);
}

fn segmentButton(cx: *ui.Cx, scope: *ui.Scope, parent: *ui.Node, selected: anytype, choice: @TypeOf(selected.peek()), label: []const u8, id: []const u8, action: ui.Handler(void)) !void {
    const style = try scope.createSignal(ui.BoxStyle, S.segment(selected.peek() == choice));
    const node = try ui.widgets.Button(.{ .variant = .ghost, .label = label, .base_style = style, .on_click = action }).mount(scope, cx);
    node.meta.ownership.meta.test_id = id;
    try parent.appendChild(cx.allocator, node);
    try scope.createEffect(.{ .style = style, .selected = selected, .choice = choice, .node = node, .publication = try cx.themeSignal(scope) }, struct {
        fn paint(ctx: anytype) void {
            _ = ctx.publication.get();
            const active = ctx.selected.get() == ctx.choice;
            ctx.style.set(S.segment(active));
            if (ctx.node.behavior.interaction.a11y) |*attributes| attributes.pressed = active;
        }
    }.paint);
}

pub fn labeled(cx: *ui.Cx, parent: *ui.Node, label: []const u8) !*ui.Node {
    const node = try ui.boxStyled(cx, S.field, .{});
    try node.appendChild(cx.allocator, try ui.textStyled(cx, S.wizard.label, label));
    try parent.appendChild(cx.allocator, node);
    return node;
}

pub fn textField(cx: *ui.Cx, scope: *ui.Scope, parent: *ui.Node, value: *ui.Signal([]const u8), field_error: *ui.Signal([]const u8), placeholder: []const u8, id: []const u8, changed: ui.Handler([]const u8)) !void {
    const input = try ui.widgets.Input(.{ .value = value, .placeholder = placeholder, .error_msg = field_error, .on_change = changed }).mountResult(scope, cx);
    input.node.setStyleInline(cx.allocator, .{ .width = .fill(), .height = .{ .fit = .{} }, .min_height = 34, .min_width = 0, .flex_shrink = 0 });
    input.input_container.setStyleInline(cx.allocator, S.input());
    S.theme.styleInput(input);
    input.input_container.meta.ownership.meta.test_id = id;
    try parent.appendChild(cx.allocator, input.node);
}

pub fn actionButton(cx: *ui.Cx, scope: *ui.Scope, parent: *ui.Node, label: []const u8, id: []const u8, primary: bool, disabled: ui.Source(bool), action: ui.Handler(void)) !void {
    const base = try S.theme.paintSignal(ui.BoxStyle, cx, scope, S.action, .{primary});
    const button = try ui.widgets.Button(.{ .variant = @as(ui.widgets.ButtonVariant, if (primary) .primary else .ghost), .label = label, .base_style = base, .disabled = disabled, .on_click = action }).mount(scope, cx);
    button.meta.ownership.meta.test_id = id;
    try parent.appendChild(cx.allocator, button);
}

fn message(err: anyerror) []const u8 {
    return switch (err) {
        error.MissingName => "请输入连接名称。",
        error.InvalidEnvelope => "连接名称包含无效字符。",
        error.MissingUrl => "请输入起始网址。",
        error.InvalidUrl, error.InvalidHost, error.InvalidPort, error.UnsupportedScheme => "请输入有效的 HTTP(S) 网址。",
        error.MissingSshReference, error.ConfigurationResolverUnavailable => "请选择已保存的 SSH 主机。",
        error.MissingRouteReference, error.ProtocolMismatch, error.InvalidSshReference => "跳板已失效，请重新选择 SSH 主机。",
        error.DuplicateRoute, error.DuplicateEndpoint => "连接路径中有重复的 SSH 主机。",
        error.TooManyJumps => "最多可以添加 8 个 SSH 跳板。",
        error.RevisionConflict, error.ConnectionRevisionConflict, error.StaleAsset => "连接配置已更新，请重新打开编辑器后保存。",
        error.UnsupportedPayloadVersion => "此连接的配置版本暂不支持。",
        error.BookmarkRepairRequired => "请先修复书签。",
        else => @import("../../ui/feedback_message.zig").knownMessage(@errorName(err)) orelse "未能保存连接，请检查配置后重试。",
    };
}

const TestEvents = struct {
    intent: ?contract.SubmitIntent = null,

    fn changed(_: *anyopaque) void {}

    fn submit(raw: *anyopaque, _: envelopes.Envelope, intent: contract.SubmitIntent) !void {
        const self: *TestEvents = @ptrCast(@alignCast(raw));
        self.intent = intent;
    }

    fn bind(self: *TestEvents) contract.EditorEvents {
        return .{ .context = self, .changed = changed, .submit = submit };
    }
};

test "web editor keeps the original owner and bookmarks and applies ordered SSH routes" {
    const a = std.testing.allocator;
    var scratch = std.heap.ArenaAllocator.init(a);
    defer scratch.deinit();
    const draft = scratch.allocator();
    const hosts = @import("../../config/hosts.zig");
    var registry: hosts.Registry = .{ .arena = .init(a), .hosts = &.{} };
    defer registry.deinit();
    const edge = try registry.add(.{ .name = "edge", .host = "edge.invalid", .user = "web" });
    const exit = try registry.add(.{ .name = "exit", .host = "exit.invalid", .user = "web" });
    const initial = try config.encode(draft, .{
        .url_mode = .preset,
        .start_url = "http://10.10.0.8/status",
        .route = .{ .mode = .ssh, .hop_asset_ids = &.{ @backingInt(edge.id), @backingInt(exit.id) } },
        .bookmarks = &.{.{ .id = .{ .bytes = @splat(3) }, .title = "监控概览", .url = "http://10.10.0.8/overview" }},
    });
    const cx = try ui.Cx.init(a, std.testing.io);
    defer cx.deinit();
    const scope = try ui.Scope.init(a, null, cx.owner);
    defer scope.dispose();
    cx.root = try ui.box(cx, .{ .width = .fill(), .height = .fill() }, .{});
    var events: TestEvents = .{};
    const view = try mount(null, .{
        .cx = cx,
        .scope = scope,
        .slot = cx.root.?,
        .protocol_id = config.protocol_id,
        .draft_revision = 1,
        .connection_configs = .init(&registry),
        .events = events.bind(),
        .initial = .{ .id = @fromBackingInt(9), .revision = 12, .name = "监控", .protocol_id = config.protocol_id, .payload = initial },
    });
    const editor: *Editor = @ptrCast(@alignCast(view.context));
    editor.chooseManual();
    editor.chooseDirect();
    const direct = try view.vtable.snapshot(view.context, draft);
    try std.testing.expectEqual(@as(u64, 9), @backingInt(direct.id));
    try std.testing.expectEqual(@as(u64, 12), direct.revision);
    var direct_data = try config.decode(a, direct.payload_version, direct.payload);
    defer direct_data.deinit();
    try std.testing.expectEqual(config.UrlMode.manual, direct_data.content.ready.url_mode);
    try std.testing.expect(direct_data.content.ready.start_url == null);
    try std.testing.expectEqual(@as(usize, 0), direct_data.content.ready.route.hop_asset_ids.len);
    try std.testing.expectEqual(@as(usize, 1), direct_data.content.ready.bookmarks.len);

    editor.choosePreset();
    editor.chooseSsh();
    Editor.reorderHop(editor, 1, .up);
    const ssh = try view.vtable.snapshot(view.context, draft);
    var ssh_data = try config.decode(a, ssh.payload_version, ssh.payload);
    defer ssh_data.deinit();
    try std.testing.expectEqualStrings("http://10.10.0.8/status", ssh_data.content.ready.start_url.?);
    try std.testing.expectEqualSlices(u64, &.{ @backingInt(exit.id), @backingInt(edge.id) }, ssh_data.content.ready.route.hop_asset_ids);
    editor.saved();
    try std.testing.expectEqual(contract.SubmitIntent.save, events.intent.?);
}

test "web editor repairs every retained bookmark before submitting its original revision" {
    const a = std.testing.allocator;
    var scratch = std.heap.ArenaAllocator.init(a);
    defer scratch.deinit();
    const draft = scratch.allocator();
    const cx = try ui.Cx.init(a, std.testing.io);
    defer cx.deinit();
    const scope = try ui.Scope.init(a, null, cx.owner);
    defer scope.dispose();
    cx.root = try ui.box(cx, .{ .width = .fill(), .height = .fill() }, .{});
    var events: TestEvents = .{};
    const view = try mount(null, .{
        .cx = cx,
        .scope = scope,
        .slot = cx.root.?,
        .protocol_id = config.protocol_id,
        .draft_revision = 1,
        .events = events.bind(),
        .initial = .{
            .id = @fromBackingInt(14),
            .revision = 4,
            .name = "内网网页",
            .protocol_id = config.protocol_id,
            .payload = "{\"url_mode\":\"manual\",\"bookmarks\":[{\"id\":\"01010101010101010101010101010101\",\"title\":\"日志查询\",\"url\":\"https://\"},false]}",
        },
    });
    const editor: *Editor = @ptrCast(@alignCast(view.context));
    const panel = editor.repair.?;
    try std.testing.expectEqual(@as(usize, 2), panel.rows.len);
    try std.testing.expect(panel.apply_disabled.peek());
    try std.testing.expectError(error.BookmarkRepairRequired, view.vtable.snapshot(view.context, draft));
    try std.testing.expectEqualStrings("修复书签", view.vtable.modal_presentation.?(view.context).title);
    // Repair the first row through its inline inputs, then remove the raw entry.
    panel.address.set("https://ops.invalid/logs");
    panel.applyRow();
    panel.rows[1].remove();
    try std.testing.expect(!panel.apply_disabled.peek());
    panel.apply();
    try std.testing.expect(events.intent == null);
    try std.testing.expectEqualStrings("编辑连接", view.vtable.modal_presentation.?(view.context).title);
    const result = try view.vtable.snapshot(view.context, draft);
    var decoded = try config.decode(a, result.payload_version, result.payload);
    defer decoded.deinit();
    try std.testing.expectEqual(@as(u64, 4), result.revision);
    try std.testing.expectEqual(@as(usize, 1), decoded.content.ready.bookmarks.len);
    try std.testing.expectEqualStrings("https://ops.invalid/logs", decoded.content.ready.bookmarks[0].url);
    editor.saved();
    try std.testing.expectEqual(contract.SubmitIntent.save, events.intent.?);
}
