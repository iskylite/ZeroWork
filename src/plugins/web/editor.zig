//! Native web connection wizard hosted by the shared 3-step connection wizard.
const std = @import("std");
const ui = @import("ui");
const contract = @import("../../host/plugin_ui_contract.zig");
const envelopes = @import("../../config/connection_envelope.zig");
const identity = envelopes.identity;
const Stepper = @import("../../ui/connection_stepper.zig");
const Review = @import("../../ui/connection_review.zig");
const layout_motion = @import("../../ui/layout_motion.zig");
const config = @import("config.zig");
const bookmarks = @import("bookmarks.zig");
const urls = @import("urls.zig");
const RoutePicker = @import("../remote/route_picker.zig").RoutePicker;
const route_hop = @import("../remote/route_hop_control.zig");
const route_view = @import("../remote/route_view.zig");
const repair_view = @import("editor_repair.zig");
const S = @import("editor_styles.zig");

const step_count: usize = 3;
const step_labels = [step_count][]const u8{ "连接与网址", "连接路径", "核对与连接" };
const step_scroll_ids = [step_count][]const u8{ "web.editor.scroll", "wizard.scroll.route", "wizard.scroll.review" };
const review_note = "仅保存配置不会打开浏览器页签。经 SSH 跳板时将在打开网页时逐跳认证并建立转发。";

const Editor = struct {
    args: contract.EditorMount,
    arena: std.heap.ArenaAllocator,
    origin: ?identity.AssetOwner = null,
    group: ?identity.AssetGroupId = null,
    saved_bookmarks: []const bookmarks.Bookmark = &.{},
    load_failure: ?anyerror = null,
    closed: bool = false,
    step: usize = 0,
    highest_step: usize = 0,
    step_invalid: [step_count]bool = @splat(false),
    mode: *ui.Signal(config.UrlMode) = undefined,
    route: *ui.Signal(config.RouteMode) = undefined,
    name: *ui.Signal([]const u8) = undefined,
    address: *ui.Signal([]const u8) = undefined,
    name_error: *ui.Signal([]const u8) = undefined,
    address_error: *ui.Signal([]const u8) = undefined,
    url_field: *ui.Node = undefined,
    identity_card: *ui.Node = undefined,
    identity_heading: *ui.Node = undefined,
    path_view: *route_view.View = undefined,
    route_error: *ui.Node = undefined,
    has_route_error: bool = false,
    hops: [config.max_hops]?u64 = @splat(null),
    hop_count: usize = 0,
    add_disabled: *ui.Signal(bool) = undefined,
    locked: *ui.Signal(bool) = undefined,
    route_hook: bool = false,
    reveal_hop: ?usize = null,
    last_compact: ?bool = null,
    last_route_chrome: ?bool = null,
    options: []const ui.widgets.SelectOption = &.{},
    form: *ui.Node = undefined,
    body_shell: *ui.Node = undefined,
    stepper: *ui.Node = undefined,
    step_entries: [step_count]Stepper.Entry = undefined,
    scrolls: [step_count]ui.widgets.ScrollAreaResult = undefined,
    step_panels: [step_count]*ui.Node = undefined,
    summary_view: *Review.Summary = undefined,
    footer: *ui.Node = undefined,
    back_button: *ui.Node = undefined,
    cancel_button: *ui.Node = undefined,
    next_button: *ui.Node = undefined,
    temporary_button: ?*ui.Node = null,
    save_button: *ui.Node = undefined,
    open_button: *ui.Node = undefined,
    repair: ?*repair_view.Panel = null,
    feedback_box: *ui.Node = undefined,
    feedback_icon: *ui.Node = undefined,
    feedback: *ui.Node = undefined,
    has_feedback: bool = false,
    height_motion: layout_motion.Height = .{},

    fn cleanup(self: *Editor) void {
        if (self.route_hook) self.args.cx.removeAfterLayoutHook(self);
        self.arena.deinit();
    }

    fn isCompact(self: *const Editor) bool {
        const vp = self.args.cx.viewport;
        return S.wizard.compactWindow(vp.width, vp.height);
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
        self.step_invalid[0] = false;
        self.refreshTarget();
        self.syncReview();
        self.paintStepper();
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
        self.setRouteError("");
        self.step_invalid[1] = false;
        self.refreshHops();
        self.syncReview();
        self.paintStepper();
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
        self.setRouteError("");
        self.step_invalid[1] = false;
        self.refreshHops();
        self.syncReview();
        self.paintStepper();
        self.changed();
    }

    fn afterLayout(raw: *anyopaque, _: u8, _: bool) ui.AfterLayoutResult {
        const self: *Editor = @ptrCast(@alignCast(raw));
        if (self.closed or self.repair != null) return .done;
        var needs_layout = false;
        const compact = self.isCompact();
        const route_chrome = self.step == 1;
        if (self.last_compact == null or self.last_compact.? != compact or self.last_route_chrome == null or self.last_route_chrome.? != route_chrome) {
            self.applyCompactLayout(compact);
            needs_layout = true;
        }
        if (route_chrome and self.path_view.root.isDisplayedInTree()) {
            const vertical = self.routeIsVertical();
            const extra_lines: usize = if (self.has_route_error) 1 else 0;
            const height = if (self.route.peek() == .ssh)
                route_view.chainHeight(self.hop_count, vertical, self.args.cx.viewport.height, compact, extra_lines)
            else
                0;
            if (self.path_view.layout(vertical, height)) needs_layout = true;
            if (self.path_view.picker.update()) needs_layout = true;
            if (self.reveal_hop) |index| {
                self.reveal_hop = null;
                self.path_view.reveal(index);
            }
        }
        return if (needs_layout) .needs_layout else .done;
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
        self.setRouteError("");
        self.step_invalid[1] = false;
        self.refreshHops();
        self.syncReview();
        self.paintStepper();
        self.changed();
    }

    fn nameChanged(self: *Editor, _: []const u8) void {
        self.name_error.set("");
        self.step_invalid[0] = false;
        self.refreshTarget();
        self.syncReview();
        self.paintStepper();
        self.changed();
    }

    fn addressChanged(self: *Editor, _: []const u8) void {
        self.address_error.set("");
        self.step_invalid[0] = false;
        self.refreshTarget();
        self.syncReview();
        self.paintStepper();
        self.changed();
    }

    fn changed(self: *Editor) void {
        self.report(if (self.load_failure) |err| message(err) else "");
        self.args.events.changed(self.args.events.context);
    }

    fn report(self: *Editor, copy: []const u8) void {
        const a = self.args.cx.allocator;
        self.has_feedback = copy.len != 0;
        self.feedback.setTextContent(a, copy) catch return;
        self.feedback_box.setDisplay(if (copy.len == 0) .none else .flex);
        self.args.cx.requestRedraw();
    }

    fn setRouteError(self: *Editor, copy: []const u8) void {
        const a = self.args.cx.allocator;
        self.has_route_error = copy.len != 0;
        self.route_error.setTextContent(a, copy) catch {};
        self.route_error.setDisplay(if (copy.len == 0) .none else .flex);
        self.args.cx.requestRedraw();
    }

    fn refreshTarget(self: *Editor) void {
        const a = self.args.cx.allocator;
        const preview = &self.path_view.preview;
        const trimmed_name = std.mem.trim(u8, self.name.peek(), " \t\r\n");
        preview.names[9].?.setTextContent(a, if (trimmed_name.len != 0) trimmed_name else "目标网页") catch {};
        const trimmed_url = std.mem.trim(u8, self.address.peek(), " \t\r\n");
        preview.addresses[9].?.setTextContent(a, if (self.mode.peek() == .preset) trimmed_url else "手动输入网址") catch {};
    }

    fn refreshHops(self: *Editor) void {
        self.path_view.setRoute(self.route.peek() == .ssh, self.hop_count);
        const a = self.args.cx.allocator;
        const preview = &self.path_view.preview;
        for (self.hops[0..self.hop_count], 1..) |id, i| {
            const host = self.resolveSshHost(id);
            preview.names[i].?.setTextContent(a, if (host) |asset| asset.name else if (id != null) "找不到此 SSH 主机" else "选择跳板") catch {};
            var buffer: [256]u8 = undefined;
            const address = formatHostAddress(host, &buffer);
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

    fn resolveSshHost(self: *const Editor, id: ?u64) ?@TypeOf(self.args.connection_configs.?.registry.hosts[0]) {
        const asset_id = id orelse return null;
        const resolver = self.args.connection_configs orelse return null;
        const index = resolver.registry.indexOf(@fromBackingInt(asset_id)) orelse return null;
        const asset = resolver.registry.hosts[index];
        return if (std.mem.eql(u8, asset.protocolId(), "ssh")) asset else null;
    }

    fn formatHostAddress(host: anytype, buffer: *[256]u8) []const u8 {
        const asset = host orelse return "";
        return if (asset.port == 22)
            std.fmt.bufPrint(buffer, "{s}@{s}", .{ asset.user, asset.host }) catch asset.host
        else
            std.fmt.bufPrint(buffer, "{s}@{s}:{d}", .{ asset.user, asset.host, asset.port }) catch asset.host;
    }

    fn validateIdentity(self: *Editor) bool {
        var valid = true;
        const trimmed_name = std.mem.trim(u8, self.name.peek(), " \t\r\n");
        if (trimmed_name.len == 0) {
            self.name_error.set(message(error.MissingName));
            valid = false;
        } else if (!std.unicode.utf8ValidateSlice(trimmed_name) or std.mem.indexOfAny(u8, trimmed_name, "\x00\r\n") != null) {
            self.name_error.set(message(error.InvalidEnvelope));
            valid = false;
        } else {
            self.name_error.set("");
        }

        if (self.mode.peek() == .preset) {
            const raw_url = std.mem.trim(u8, self.address.peek(), " \t\r\n");
            if (raw_url.len == 0) {
                self.address_error.set(message(error.MissingUrl));
                valid = false;
            } else {
                var scratch = std.heap.ArenaAllocator.init(self.args.cx.allocator);
                defer scratch.deinit();
                if (urls.normalize(scratch.allocator(), raw_url)) |_| {
                    self.address_error.set("");
                } else |err| {
                    self.address_error.set(message(err));
                    valid = false;
                }
            }
        } else {
            self.address_error.set("");
        }

        self.step_invalid[0] = !valid;
        self.paintStepper();
        return valid;
    }

    fn validateRoute(self: *Editor) bool {
        if (self.route.peek() == .direct) {
            self.setRouteError("");
            self.step_invalid[1] = false;
            self.paintStepper();
            return true;
        }
        if (self.hop_count == 0) {
            self.setRouteError(message(error.MissingSshReference));
            self.step_invalid[1] = true;
            self.paintStepper();
            return false;
        }
        const resolver = self.args.connection_configs orelse {
            self.setRouteError(message(error.ConfigurationResolverUnavailable));
            self.step_invalid[1] = true;
            self.paintStepper();
            return false;
        };
        var scratch = std.heap.ArenaAllocator.init(self.args.cx.allocator);
        defer scratch.deinit();
        var typed: [config.max_hops]identity.ConnectionId = undefined;
        for (self.hops[0..self.hop_count], typed[0..self.hop_count]) |hop, *asset| {
            const id = hop orelse {
                self.setRouteError(message(error.MissingSshReference));
                self.step_invalid[1] = true;
                self.paintStepper();
                return false;
            };
            asset.* = @fromBackingInt(id);
        }
        var frozen = resolver.freezeRoute(typed[0..self.hop_count], scratch.allocator()) catch |err| {
            self.setRouteError(message(err));
            self.step_invalid[1] = true;
            self.paintStepper();
            return false;
        };
        frozen.deinit();
        self.setRouteError("");
        self.step_invalid[1] = false;
        self.paintStepper();
        return true;
    }

    fn goStep(self: *Editor, target: usize) void {
        if (self.closed or target >= step_count) return;
        self.hideRouteMenus();
        self.step = target;
        if (target > self.highest_step) self.highest_step = target;
        self.applyStep();
        if (target == 2) {
            self.syncReview();
            self.summary_view.resetScroll();
        }
        ui.widgets.setScrollY(self.scrolls[target].state, self.scrolls[target].content, 0);
        self.paintStepper();
        self.args.cx.requestRedraw();
    }

    fn navigateTo(self: *Editor, target: usize) void {
        if (self.closed or self.repair != null or target >= step_count) return;
        if (target <= self.step) {
            self.goStep(target);
            return;
        }
        if (self.step == 0 and !self.validateIdentity()) return;
        if (target >= 2 and !self.validateRoute()) {
            self.goStep(1);
            return;
        }
        self.goStep(target);
    }

    fn step0Clicked(self: *Editor) void {
        self.navigateTo(0);
    }

    fn step1Clicked(self: *Editor) void {
        self.navigateTo(1);
    }

    fn step2Clicked(self: *Editor) void {
        self.navigateTo(2);
    }

    fn backClicked(self: *Editor) void {
        if (self.step > 0) self.goStep(self.step - 1);
    }

    fn nextClicked(self: *Editor) void {
        if (self.closed or self.repair != null) return;
        if (self.step == 0) {
            if (!self.validateIdentity()) return;
            self.goStep(1);
        } else if (self.step == 1) {
            if (!self.validateRoute()) return;
            self.goStep(2);
        }
    }

    fn editIdentityClicked(self: *Editor) void {
        self.goStep(0);
    }

    fn editRouteClicked(self: *Editor) void {
        self.goStep(1);
    }

    fn applyStep(self: *Editor) void {
        for (self.scrolls, 0..) |scroll, i| {
            scroll.container.setDisplay(if (i == self.step) .flex else .none);
        }
        self.back_button.setDisplay(if (self.step > 0) .flex else .none);
        self.next_button.setDisplay(if (self.step < 2) .flex else .none);
        if (self.temporary_button) |btn| btn.setDisplay(if (self.step == 2) .flex else .none);
        self.save_button.setDisplay(if (self.step == 2) .flex else .none);
        self.open_button.setDisplay(if (self.step == 2) .flex else .none);
        self.applyCompactLayout(self.isCompact());
    }

    fn applyCompactLayout(self: *Editor, compact: bool) void {
        self.last_compact = compact;
        self.last_route_chrome = self.step == 1;
        self.body_shell.setStyleInline(self.args.cx.allocator, .{
            .padding = S.wizard.stepBodyPadding(),
            .gap = S.wizard.stepBodyGap(self.step == 1),
        });
        Stepper.layout(self.args.cx, self.stepper, compact);
        for (self.step_panels) |panel| {
            panel.setStyleInline(self.args.cx.allocator, S.stepBody());
        }
        self.summary_view.setCompact(compact);
        self.footer.setStyleInline(self.args.cx.allocator, S.stepFooter(self.step == 1, compact, self.step == 2));
        self.paintTheme();
    }

    fn paintStepper(self: *Editor) void {
        Stepper.paintTrack(self.stepper);
        for (0..step_count) |i| {
            const completed = i < self.highest_step and !self.step_invalid[i] and i != self.step;
            Stepper.paint(self.args.cx, self.step_entries[i], i == self.step, completed, self.step_invalid[i]);
        }
    }

    fn paintTheme(self: *Editor) void {
        const colors = S.theme.current();
        self.paintStepper();
        self.identity_card.setBackground(S.wizard.identityPanel(undefined).background.?);
        self.identity_heading.setTextColor(colors.fg_1);
        self.path_view.paint(self.route.peek() == .ssh);
        self.route_error.setTextColor(colors.danger_ink);
        self.feedback_box.setBackground(S.wizard.saveErrorBackground());
        if (ui.icons.circle_alert.icon_id) |id| {
            if (ui.icons.circle_alert.pickRep(16)) |rep| {
                self.feedback_icon.setIcon(.{ .icon_id = id, .rep = rep, .tint = colors.danger_ink });
            }
        }
        self.feedback.setTextColor(colors.danger_ink);
        const compact = self.isCompact();
        self.footer.setStyleInline(self.args.cx.allocator, S.stepFooter(self.step == 1, compact, self.step == 2));
    }

    fn syncReview(self: *Editor) void {
        var scratch = std.heap.ArenaAllocator.init(self.args.cx.allocator);
        defer scratch.deinit();
        const a = scratch.allocator();

        const trimmed_name = std.mem.trim(u8, self.name.peek(), " \t\r\n");
        const trimmed_url = std.mem.trim(u8, self.address.peek(), " \t\r\n");
        const is_preset = self.mode.peek() == .preset;
        const is_ssh = self.route.peek() == .ssh;

        const mode_text = if (is_preset) "预设网址" else "手动输入";
        const url_value = if (is_preset) (if (trimmed_url.len != 0) trimmed_url else "未填写") else "地址栏输入";
        const access_value = if (is_ssh)
            (std.fmt.allocPrint(a, "{d} 跳 SSH 转发", .{self.hop_count}) catch "经 SSH 跳板")
        else
            "直连访问";
        const options_text = if (self.saved_bookmarks.len != 0)
            (std.fmt.allocPrint(a, "已保存书签 {d} 个", .{self.saved_bookmarks.len}) catch "")
        else
            "";

        var nodes: [10]Review.RouteNodeData = undefined;
        var count: usize = 0;
        nodes[count] = .{ .name = "本机", .caption = "ZeroWork 客户端", .icon = ui.icons.laptop };
        count += 1;
        if (is_ssh) {
            for (self.hops[0..self.hop_count], 0..) |id, idx| {
                if (count + 1 >= nodes.len) break;
                const host = self.resolveSshHost(id);
                var addr_buf: [256]u8 = undefined;
                const caption = if (host != null)
                    (a.dupe(u8, formatHostAddress(host, &addr_buf)) catch "")
                else
                    (std.fmt.allocPrint(a, "跳板 #{d}", .{idx + 1}) catch "SSH 跳板");
                nodes[count] = .{
                    .name = if (host) |h| h.name else if (id != null) "找不到此 SSH 主机" else "未选择跳板",
                    .caption = caption,
                    .icon = ui.icons.server,
                };
                count += 1;
            }
        }
        nodes[count] = .{
            .name = if (trimmed_name.len != 0) trimmed_name else "目标网页",
            .caption = if (is_preset and trimmed_url.len != 0) trimmed_url else "手动输入网址",
            .icon = ui.icons.globe,
            .highlighted = true,
        };
        count += 1;

        self.summary_view.update(.{
            .icon = ui.icons.globe,
            .name = if (trimmed_name.len != 0) trimmed_name else "未命名网页",
            .subtitle = if (is_preset) (if (trimmed_url.len != 0) trimmed_url else "预设网址") else "手动输入网址",
            .protocol_badge = "浏览器",
            .endpoint_caption = if (is_preset) "起始网址" else "打开方式",
            .endpoint = if (is_preset) (if (trimmed_url.len != 0) trimmed_url else "未填写") else "打开后手动输入",
            .values = .{ mode_text, url_value, access_value },
            .options = options_text,
            .route_nodes = nodes[0..count],
            .note = review_note,
            .show_note = true,
        });
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
                error.MissingName, error.InvalidEnvelope => {
                    self.name_error.set(message(err));
                    self.step_invalid[0] = true;
                    self.goStep(0);
                },
                error.MissingUrl, error.InvalidUrl, error.InvalidHost, error.InvalidPort, error.UnsupportedScheme => {
                    self.address_error.set(message(err));
                    self.step_invalid[0] = true;
                    self.goStep(0);
                },
                error.MissingSshReference, error.ConfigurationResolverUnavailable, error.MissingRouteReference, error.ProtocolMismatch, error.InvalidSshReference, error.DuplicateRoute, error.DuplicateEndpoint, error.TooManyJumps => {
                    self.setRouteError(message(err));
                    self.step_invalid[1] = true;
                    self.goStep(1);
                },
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
        self.syncReview();
        self.applyStep();
        self.changed();
    }

    fn modalPresentation(raw: *anyopaque) contract.ModalPresentation {
        const self: *Editor = @ptrCast(@alignCast(raw));
        return .{
            .width = if (self.repair != null) S.width else S.wizard.width,
            .title = if (self.repair != null) "修复书签" else if (self.origin != null) "编辑连接" else "新建连接",
        };
    }

    fn targetHeight(self: *const Editor) f32 {
        if (self.repair != null) return 644;
        const compact = self.isCompact();
        const extra_feedback: f32 = if (self.has_feedback) 48 else 0;
        return switch (self.step) {
            0 => blk: {
                const content_h = self.scrolls[0].content.globalRect().h;
                if (content_h > 0) {
                    const header_h: f32 = if (compact) 48 else 52;
                    const track_margin: f32 = if (compact) 4 else 8;
                    const footer_h = S.wizard.stepFooterHeight(false, compact, false);
                    break :blk @min(S.wizard.remote_max_height, header_h + track_margin + 36 + 12 + content_h + extra_feedback + footer_h);
                }
                const err_count: f32 = @as(f32, @floatFromInt(
                    @intFromBool(self.name_error.peek().len != 0) +
                        @intFromBool(self.mode.peek() == .preset and self.address_error.peek().len != 0),
                ));
                const base: f32 = if (self.mode.peek() == .preset)
                    (if (compact) 456 else 484)
                else
                    (if (compact) 388 else 416);
                break :blk @min(S.wizard.remote_max_height, base + extra_feedback + err_count * 18);
            },
            1 => blk: {
                const extra_lines: usize = @intFromBool(self.has_route_error) + @as(usize, if (self.has_feedback) 2 else 0);
                const hops = if (self.route.peek() == .ssh) self.hop_count else 0;
                break :blk route_view.modalHeight(hops, self.args.cx.viewport.width, compact, extra_lines);
            },
            else => @min(S.wizard.remote_max_height, (if (compact) S.wizard.review_compact_height else S.wizard.review_height) + extra_feedback),
        };
    }

    fn modalHeight(raw: *anyopaque) ?f32 {
        const self: *Editor = @ptrCast(@alignCast(raw));
        if (self.repair != null) return 644;
        return self.height_motion.sample(self.args.cx, self.targetHeight(), true);
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

    const a = cx.allocator;
    const compact = self.isCompact();
    const colors = S.theme.current();

    const root = try ui.boxStyled(cx, S.layout, .{});
    root.meta.ownership.meta.test_id = "web.editor";
    try args.slot.appendChild(a, root);
    const form = try ui.boxStyled(cx, S.layout, .{});
    try root.appendChild(a, form);
    self.form = form;

    const body_shell = try ui.box(cx, .{
        .width = .fill(),
        .height = .fill(),
        .flex = 1,
        .min_height = 0,
        .direction = .column,
        .padding = S.wizard.stepBodyPadding(),
        .gap = S.wizard.stepBodyGap(false),
    }, .{});
    try form.appendChild(a, body_shell);
    self.body_shell = body_shell;

    // Unified 36px segmented stepper
    self.stepper = try Stepper.row(cx);
    Stepper.layout(cx, self.stepper, compact);
    try body_shell.appendChild(a, self.stepper);
    const step_handlers = [step_count]ui.Handler(void){
        cx.on(Editor, self, Editor.step0Clicked),
        cx.on(Editor, self, Editor.step1Clicked),
        cx.on(Editor, self, Editor.step2Clicked),
    };
    for (0..step_count) |i| {
        const step_style = try scope.createSignal(ui.BoxStyle, S.wizard.reviewStep(true));
        self.step_entries[i] = try Stepper.appendLabeled(
            cx,
            scope,
            self.stepper,
            i,
            step_labels[i],
            Stepper.step_ids[i],
            self.locked,
            step_style,
            step_handlers[i],
        );
    }

    // Step 0, 1, 2 scroll containers
    for (0..step_count) |i| {
        const scroll = try ui.widgets.ScrollArea(.{}).mount(scope, cx);
        scroll.container.setStyleInline(a, S.wizard.scroll());
        scroll.container.meta.ownership.meta.test_id = step_scroll_ids[i];
        try body_shell.appendChild(a, scroll.container);
        self.scrolls[i] = scroll;

        const panel = try ui.box(cx, S.stepBody(), .{});
        try scroll.content.appendChild(a, panel);
        self.step_panels[i] = panel;
    }

    // Step 0: 连接与网址 inside S.wizard.identityPanel
    const id_card = try ui.box(cx, S.wizard.identityPanel(undefined), .{});
    id_card.setStyleInline(a, .{ .gap = 10 });
    try self.step_panels[0].appendChild(a, id_card);
    self.identity_card = id_card;

    const heading = try ui.text(cx, "连接信息", .{
        .font_size = 14,
        .font_weight = 600,
        .color = colors.fg_1,
    });
    try id_card.appendChild(a, heading);
    self.identity_heading = heading;

    const name_field = try panelLabeled(cx, id_card, "名称");
    try panelTextField(cx, scope, name_field, self.name, self.name_error, "例如：生产监控", "web.editor.name", cx.on(Editor, self, Editor.nameChanged));

    const mode_field = try panelLabeled(cx, id_card, "打开方式");
    const mode_track = try ui.boxStyled(cx, S.segmentTrack, .{});
    mode_track.meta.ownership.meta.test_id = "web.editor.mode";
    try mode_field.appendChild(a, mode_track);
    try segmentButton(cx, scope, mode_track, self.mode, .preset, "预设网址", "web.editor.mode.preset", cx.on(Editor, self, Editor.choosePreset));
    try segmentButton(cx, scope, mode_track, self.mode, .manual, "手动输入", "web.editor.mode.manual", cx.on(Editor, self, Editor.chooseManual));

    self.url_field = try panelLabeled(cx, id_card, "起始网址");
    try panelTextField(cx, scope, self.url_field, self.address, self.address_error, "https://intranet.example.com", "web.editor.url", cx.on(Editor, self, Editor.addressChanged));
    self.url_field.setDisplay(if (payload.url_mode == .preset) .flex else .none);

    // Step 1: 连接路径 using shared route_view
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
    try self.step_panels[1].appendChild(a, self.path_view.root);

    self.route_error = try ui.textStyled(cx, S.feedback, "");
    self.route_error.setStyleInline(a, S.wizard.errorLabel());
    self.route_error.meta.ownership.meta.test_id = "wizard.route.error";
    self.route_error.setDisplay(.none);
    try self.step_panels[1].appendChild(a, self.route_error);

    // Step 2: 核对与连接 using shared Review.Summary
    const review_root = try ui.box(cx, S.wizard.reviewStack(undefined), .{});
    review_root.meta.ownership.meta.test_id = "web.editor.review";
    try self.step_panels[2].appendChild(a, review_root);
    self.summary_view = try Review.Summary.mount(cx, scope, review_root, .{
        .icon = ui.icons.globe,
        .endpoint_caption = "起始网址",
        .details_title = "连接详情",
        .edit_identity_id = "web.editor.review.modify",
        .edit_route_id = "web.editor.review.route.modify",
        .fields = .{
            .{ .label = "打开方式", .test_id = "web.editor.review.mode" },
            .{ .label = "起始网址", .test_id = "web.editor.review.url", .mono = true },
            .{ .label = "连接路径", .test_id = "web.editor.review.access" },
        },
        .note = review_note,
        .locked = self.locked,
        .on_edit_identity = cx.on(Editor, self, Editor.editIdentityClicked),
        .on_edit_route = cx.on(Editor, self, Editor.editRouteClicked),
    });

    // Fixed error banner above footer
    const fb_box = try ui.box(cx, S.wizard.saveError(), .{});
    fb_box.setBackground(S.wizard.saveErrorBackground());
    fb_box.setDisplay(.none);
    try form.appendChild(a, fb_box);
    self.feedback_box = fb_box;

    const fb_icon = try ui.iconTint(cx, ui.icons.circle_alert, colors.danger_ink, .{ .width = .{ .px = 16 }, .height = .{ .px = 16 }, .flex_shrink = 0 });
    try fb_box.appendChild(a, fb_icon);
    self.feedback_icon = fb_icon;

    self.feedback = try ui.textStyled(cx, S.feedback, "");
    self.feedback.setStyleInline(a, .{ .width = .fill(), .min_width = 0, .flex = 1 });
    self.feedback.meta.ownership.meta.test_id = "web.editor.feedback";
    try fb_box.appendChild(a, self.feedback);

    // Fixed footer aligned with SSH/KVM
    const footer = try ui.box(cx, S.stepFooter(false, compact, false), .{});
    footer.meta.ownership.meta.test_id = "web.editor.footer";
    try form.appendChild(a, footer);
    self.footer = footer;

    self.back_button = try mountAction(cx, scope, footer, "上一步", "web.editor.back", false, false, .{ .value = false }, cx.on(Editor, self, Editor.backClicked));
    self.cancel_button = try mountAction(cx, scope, footer, "取消", "web.editor.cancel", false, true, .{ .value = false }, cx.on(Editor, self, Editor.cancelled));
    try footer.appendChild(a, try ui.spacer(cx));
    const disabled: ui.Source(bool) = .{ .signal = self.locked };
    self.next_button = try mountAction(cx, scope, footer, "下一步", "web.editor.next", true, false, disabled, cx.on(Editor, self, Editor.nextClicked));
    if (self.origin == null) {
        self.temporary_button = try mountAction(cx, scope, footer, "临时连接", "web.editor.temporary", false, false, disabled, cx.on(Editor, self, Editor.temporary));
    }
    self.save_button = try mountAction(cx, scope, footer, if (self.origin != null) "保存更改" else "仅保存", "web.editor.save", false, false, disabled, cx.on(Editor, self, Editor.saved));
    self.open_button = try mountAction(cx, scope, footer, "保存并连接", "web.editor.open", true, false, disabled, cx.on(Editor, self, Editor.opened));

    try cx.addAfterLayoutHook(self, Editor.afterLayout);
    self.route_hook = true;
    try scope.createEffect(.{ .editor = self, .route = self.route, .theme = try cx.themeSignal(scope) }, struct {
        fn paint(ctx: anytype) void {
            _ = ctx.theme.get();
            _ = ctx.route.get();
            ctx.editor.paintTheme();
        }
    }.paint);

    self.refreshHops();
    self.syncReview();
    self.applyStep();
    self.paintTheme();
    self.report(if (self.load_failure) |err| message(err) else "");

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

fn panelLabeled(cx: *ui.Cx, parent: *ui.Node, label: []const u8) !*ui.Node {
    const node = try ui.boxStyled(cx, S.panelField, .{});
    try node.appendChild(cx.allocator, try ui.textStyled(cx, S.wizard.label, label));
    try parent.appendChild(cx.allocator, node);
    return node;
}

fn panelTextField(cx: *ui.Cx, scope: *ui.Scope, parent: *ui.Node, value: *ui.Signal([]const u8), field_error: *ui.Signal([]const u8), placeholder: []const u8, id: []const u8, changed: ui.Handler([]const u8)) !void {
    const input = try ui.widgets.Input(.{ .value = value, .placeholder = placeholder, .error_msg = field_error, .on_change = changed }).mountResult(scope, cx);
    input.node.setStyleInline(cx.allocator, .{ .width = .fill(), .height = .{ .fit = .{} }, .min_height = 34, .min_width = 0, .flex_shrink = 0 });
    input.input_container.setStyleInline(cx.allocator, S.input());
    S.theme.stylePanelInput(input);
    input.input_container.meta.ownership.meta.test_id = id;
    try parent.appendChild(cx.allocator, input.node);
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
    _ = try mountAction(cx, scope, parent, label, id, primary, false, disabled, action);
}

fn mountAction(cx: *ui.Cx, scope: *ui.Scope, parent: *ui.Node, label: []const u8, id: []const u8, primary: bool, ghost: bool, disabled: ui.Source(bool), action: ui.Handler(void)) !*ui.Node {
    const base = if (ghost)
        try scope.createSignal(ui.BoxStyle, S.ghostAction())
    else
        try S.theme.paintSignal(ui.BoxStyle, cx, scope, S.action, .{primary});
    if (ghost) {
        try scope.createEffect(.{ .base = base, .publication = try cx.themeSignal(scope) }, struct {
            fn paint(ctx: anytype) void {
                _ = ctx.publication.get();
                ctx.base.set(S.ghostAction());
            }
        }.paint);
    }
    const variant: ui.widgets.ButtonVariant = if (primary) .primary else .ghost;
    const button = try ui.widgets.Button(.{ .variant = variant, .label = label, .base_style = base, .disabled = disabled, .on_click = action }).mount(scope, cx);
    button.meta.ownership.meta.test_id = id;
    try parent.appendChild(cx.allocator, button);
    return button;
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

fn findTestNode(root: *ui.Node, id: []const u8) ?*ui.Node {
    if (root.meta.ownership.meta.test_id) |tid| {
        if (std.mem.eql(u8, tid, id)) return root;
    }
    for (root.children.items) |child| {
        if (findTestNode(child, id)) |found| return found;
    }
    return null;
}

fn findTestText(root: *ui.Node, needle: []const u8) bool {
    if (root.getText()) |txt| {
        if (std.mem.indexOf(u8, txt.content, needle) != null) return true;
    }
    for (root.children.items) |child| {
        if (findTestText(child, needle)) return true;
    }
    return false;
}

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

test "web editor uses unified 3-step wizard, segmented stepper, route view and review summary" {
    const a = std.testing.allocator;
    const hosts = @import("../../config/hosts.zig");
    var registry: hosts.Registry = .{ .arena = .init(a), .hosts = &.{} };
    defer registry.deinit();
    const jump = try registry.add(.{ .name = "jump-a", .host = "jump.invalid", .user = "ops" });

    const cx = try ui.Cx.init(a, std.testing.io);
    defer cx.deinit();
    cx.viewport = .{ .width = 1440, .height = 900 };
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
    });
    const editor: *Editor = @ptrCast(@alignCast(view.context));
    _ = cx.render();

    // Segmented 36px stepper
    const steps_node = findTestNode(cx.root.?, "wizard.steps").?;
    try std.testing.expectApproxEqAbs(@as(f32, 36), steps_node.globalRect().h, 0.5);
    try std.testing.expect(editor.scrolls[0].container.isDisplayedInTree());
    try std.testing.expect(!editor.scrolls[1].container.isDisplayedInTree());
    try std.testing.expect(!editor.scrolls[2].container.isDisplayedInTree());

    // Empty Step 0 validation blocks advancing to Step 1
    editor.nextClicked();
    try std.testing.expectEqual(@as(usize, 0), editor.step);
    try std.testing.expect(editor.step_invalid[0]);
    try std.testing.expect(editor.name_error.peek().len != 0);
    try std.testing.expect(editor.address_error.peek().len != 0);

    // Valid Step 0 advances to Step 1
    editor.name.set("内网监控");
    editor.address.set("https://monitor.invalid:8443/app");
    editor.nextClicked();
    try std.testing.expectEqual(@as(usize, 1), editor.step);
    try std.testing.expect(!editor.step_invalid[0]);
    try std.testing.expect(editor.scrolls[1].container.isDisplayedInTree());
    try std.testing.expect(findTestNode(cx.root.?, "wizard.access.direct") != null);
    try std.testing.expect(findTestNode(cx.root.?, "wizard.access.jump") != null);

    // Selecting routed mode with empty hop blocks advancing to Step 2
    editor.chooseSsh();
    editor.nextClicked();
    try std.testing.expectEqual(@as(usize, 1), editor.step);
    try std.testing.expect(editor.step_invalid[1]);
    try std.testing.expect(editor.route_error.isDisplayedInTree());

    // Choosing a valid SSH hop advances to Step 2 (Review.Summary)
    var val_buf: [32]u8 = undefined;
    const hop_val = try std.fmt.bufPrint(&val_buf, "{d}", .{@backingInt(jump.id)});
    Editor.pickerChoose(editor, .{ .replace = 0 }, hop_val);
    editor.nextClicked();
    try std.testing.expectEqual(@as(usize, 2), editor.step);
    try std.testing.expect(editor.scrolls[2].container.isDisplayedInTree());
    _ = cx.render();
    try std.testing.expect(findTestNode(cx.root.?, "wizard.review.summary") != null);
    try std.testing.expect(findTestNode(cx.root.?, "wizard.review.route") != null);
    try std.testing.expect(findTestText(findTestNode(cx.root.?, "web.editor.review.access").?, "1 跳 SSH 转发"));
    try std.testing.expect(findTestText(findTestNode(cx.root.?, "wizard.review.route").?, "jump-a"));

    // Modify buttons return cleanly to Step 0 / Step 1
    editor.editRouteClicked();
    try std.testing.expectEqual(@as(usize, 1), editor.step);
    editor.nextClicked();
    editor.editIdentityClicked();
    try std.testing.expectEqual(@as(usize, 0), editor.step);
}
