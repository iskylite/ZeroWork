const std = @import("std");
const ui = @import("ui");
const contract = @import("../../host/plugin_ui_contract.zig");
const theme = @import("../../ui/app_theme.zig");
const hint = @import("../../ui/control_hint.zig");
const config = @import("config.zig");
const books = @import("bookmarks.zig");
const api = @import("page_service.zig");
const S = @import("renderer_styles.zig");

const Input = ui.widgets.input.InputResult;
const Popup = ui.widgets.popover.PopoverResult;

const BookmarkControl = struct {
    view: *View,
    index: usize,
    node: *ui.Node = undefined,
    wrapper: *ui.Node = undefined,
    label: *ui.Signal([]const u8),
    full_title: *ui.Signal([]const u8),
    style: *ui.Signal(ui.BoxStyle),
    width: f32 = 0,
    strip: bool,

    fn activate(self: *BookmarkControl) void {
        const item = self.view.bookmarkAt(self.index) orelse return;
        self.view.more_open.set(false);
        self.view.navigate(item.url);
    }

    fn event(input: ui.events.Event, raw: ?*anyopaque) ui.events.EventResult {
        const self: *BookmarkControl = @ptrCast(@alignCast(raw orelse return .ignored));
        switch (input) {
            .mouse_down => |mouse| if (mouse.button == .right) {
                self.context();
                return .stop;
            },
            .key_down => |key| if (key.key == .f10 and key.modifiers.shift) {
                self.context();
                return .stop;
            },
            .focus => if (self.strip) self.view.revealBookmark(self.index),
            else => {},
        }
        return .ignored;
    }

    fn context(self: *BookmarkControl) void {
        const view = self.view;
        const item = view.bookmarkAt(self.index) orelse return;
        view.popup_anchor = if (self.strip) self.node else view.more_button;
        view.selected_bookmark = item.id;
        view.more_open.set(false);
        view.context_open.set(true);
        view.request.cx.requestRedraw();
    }
};

const View = struct {
    request: contract.ContentMount,
    page: api.Page,
    preset: bool,
    root: *ui.Node = undefined,
    toolbar: *ui.Node = undefined,
    document: *ui.Node = undefined,
    address_shell: *ui.Node = undefined,
    address: Input = undefined,
    address_text: *ui.Signal([]const u8) = undefined,
    state_panel: *ui.Node = undefined,
    state_title: *ui.Node = undefined,
    state_detail: *ui.Node = undefined,
    state_warning: *ui.Node = undefined,
    state_icon: *ui.Node = undefined,
    state_warning_icon: *ui.Node = undefined,
    reconnect_button: *ui.Node = undefined,
    retry_button: *ui.Node = undefined,
    route_button: *ui.Node = undefined,
    state_actions: *ui.Node = undefined,
    login_notice: *ui.Node = undefined,
    back_disabled: *ui.Signal(bool) = undefined,
    forward_disabled: *ui.Signal(bool) = undefined,
    reload_disabled: *ui.Signal(bool) = undefined,
    reload_icon: *ui.Signal(?ui.SvgAsset) = undefined,
    reload_label: *ui.Signal([]const u8) = undefined,
    star_disabled: *ui.Signal(bool) = undefined,
    star_tint: *ui.Signal(?ui.Color) = undefined,
    star_icon: *ui.Signal(?ui.SvgAsset) = undefined,
    star_label: *ui.Signal([]const u8) = undefined,
    star_button: *ui.Node = undefined,
    more_button: *ui.Node = undefined,
    copy_disabled: *ui.Signal(bool) = undefined,
    more_open: *ui.Signal(bool) = undefined,
    context_open: *ui.Signal(bool) = undefined,
    edit_open: *ui.Signal(bool) = undefined,
    route_open: *ui.Signal(bool) = undefined,
    feedback_open: *ui.Signal(bool) = undefined,
    feedback_text: *ui.Node = undefined,
    route_text: *ui.Node = undefined,
    route_status: *ui.Node = undefined,
    route_endpoint: *ui.Node = undefined,
    edit_title: *ui.Signal([]const u8) = undefined,
    edit_url: *ui.Signal([]const u8) = undefined,
    edit_name: Input = undefined,
    edit_address: Input = undefined,
    edit_error: *ui.Node = undefined,
    strip: *ui.Node = undefined,
    scroll: ui.widgets.ScrollAreaResult = undefined,
    left_button: *ui.Node = undefined,
    right_button: *ui.Node = undefined,
    left_disabled: *ui.Signal(bool) = undefined,
    right_disabled: *ui.Signal(bool) = undefined,
    strip_bookmarks: [books.max_count]*BookmarkControl = undefined,
    menu_bookmarks: [books.max_count]*BookmarkControl = undefined,
    menu_list: ui.widgets.ScrollAreaResult = undefined,
    popup_anchor: ?*ui.Node = null,
    selected_bookmark: ?books.Id = null,
    focus_bookmark_after_remove: ?usize = null,
    edit_arena: ?std.heap.ArenaAllocator = null,
    edit_original: ?books.Bookmark = null,
    token: ?u64 = null,
    snapshot: ?api.Snapshot = null,
    saved_bookmarks: ?config.Decoded = null,
    saved_revision: u64 = 0,
    strip_width: f32 = -1,
    list_height: f32 = -1,
    strip_total: f32 = 0,
    strip_overflow: bool = false,
    active: bool = true,
    address_edited: bool = false,
    focus_address_pending: bool = false,
    focus_edit_pending: bool = false,
    hook_installed: bool = false,
    closed: bool = false,

    fn cleanup(self: *View) void {
        if (self.closed) return;
        self.closed = true;
        self.detach();
        if (self.hook_installed) self.request.cx.removeAfterLayoutHook(self);
        if (self.snapshot) |*value| value.deinit();
        if (self.saved_bookmarks) |*value| value.deinit();
        if (self.edit_arena) |*arena| arena.deinit();
    }

    fn detach(self: *View) void {
        if (self.token) |token| {
            self.page.detach(token);
            self.token = null;
        }
    }

    fn afterLayout(raw: *anyopaque, _: u8, _: bool) ui.AfterLayoutResult {
        const self: *View = @ptrCast(@alignCast(raw));
        if (self.closed or !self.active) return .done;
        if (!self.root.isDisplayedInTree()) {
            self.detach();
            return .done;
        }
        const rect = self.document.globalRect();
        if (rect.w <= 0 or rect.h <= 0) return .done;
        if (self.token == null) self.token = self.page.attach() catch return .done;
        const status_changed = self.refresh() catch return .done;
        const bookmarks_changed = self.projectBookmarks();
        return if (status_changed or bookmarks_changed) .needs_layout else .done;
    }

    fn refresh(self: *View) !bool {
        const cx = self.request.cx;
        if (self.request.web_bookmarks) |facade| self.refreshSavedBookmarks(facade) catch {};
        const next = try self.page.snapshot(cx.allocator);
        if (self.snapshot) |*old| old.deinit();
        self.snapshot = next;
        const state = &self.snapshot.?;
        const connection_down = state.path == .disconnected;
        const visible = !connection_down and (state.page == .displayed or (state.page == .loading and state.current_url != null));

        if (self.token) |token| {
            if (try self.page.surfaceBinding(token)) |binding| {
                if (self.request.web_surface) |facade| {
                    try facade.sync(binding.surface, binding.binding, self.document, visible);
                }
            }
        }
        if (!self.address_edited) self.address_text.set(self.displayAddress());
        self.back_disabled.set(!state.can_go_back or connection_down);
        self.forward_disabled.set(!state.can_go_forward or connection_down);
        const connecting = state.path == .connecting;
        const busy = state.loading or connecting;
        self.reload_disabled.set(!busy and (connection_down or (state.current_url == null and state.pending_url == null)));
        self.reload_icon.set(if (busy) ui.icons.x else ui.icons.rotate_cw);
        self.reload_label.set(if (connecting) "取消连接" else if (state.loading) "停止加载" else "重新加载");
        self.copy_disabled.set(state.current_url == null);
        self.projectStar();
        const status_changed = self.projectStatus(visible);
        if (state.path == .connecting) {
            cx.scheduleRedrawAfterNs(40 * std.time.ns_per_ms);
        } else if (state.path == .ready and (state.loading or (state.pending_url != null and state.page == .blank))) {
            cx.scheduleRedrawAfterNs(66 * std.time.ns_per_ms);
        }
        if (self.focus_address_pending and cx.overlay_stack.topmost() == null) {
            self.focus_address_pending = false;
            self.focusAddress();
        }
        if (self.focus_edit_pending and self.edit_name.input_container.isDisplayedInTree()) {
            self.focus_edit_pending = false;
            cx.setFocus(self.edit_name.input_container);
        }
        if (connection_down and state.reset_warning == .needs_display and self.state_warning.globalRect().h > 0) {
            try self.page.command(.acknowledge_reset);
        }
        return status_changed;
    }

    fn refreshSavedBookmarks(self: *View, facade: contract.WebBookmarks) !void {
        var arena = std.heap.ArenaAllocator.init(self.request.cx.allocator);
        defer arena.deinit();
        const envelope = facade.snapshot(arena.allocator()) catch |err| switch (err) {
            error.ConnectionNotFound, error.AssetNotFound, error.BookmarkRepairRequired => return,
            else => return err,
        };
        if (envelope.revision == self.saved_revision) return;
        var decoded = try config.decode(self.request.cx.allocator, envelope.payload_version, envelope.payload);
        if (decoded.content == .repair) {
            decoded.deinit();
            return;
        }
        if (self.saved_bookmarks) |*previous| previous.deinit();
        self.saved_bookmarks = decoded;
        self.saved_revision = envelope.revision;
    }

    fn displayAddress(self: *const View) []const u8 {
        const state = self.snapshot orelse return "";
        return state.pending_url orelse state.current_url orelse state.start_url orelse "";
    }

    fn bookmarkList(self: *const View) []const books.Bookmark {
        if (self.saved_bookmarks) |decoded| return decoded.content.ready.bookmarks;
        return if (self.snapshot) |value| value.bookmarks else &.{};
    }

    fn bookmarkAt(self: *const View, index: usize) ?books.Bookmark {
        const list = self.bookmarkList();
        return if (index < list.len) list[index] else null;
    }

    fn currentBookmark(self: *const View) ?books.Bookmark {
        const address = if (self.snapshot) |value| value.current_url orelse return null else return null;
        for (self.bookmarkList()) |item| if (std.mem.eql(u8, address, item.url)) return item;
        return null;
    }

    fn selectedBookmark(self: *const View) ?books.Bookmark {
        const selected = self.selected_bookmark orelse return null;
        for (self.bookmarkList()) |item| if (item.id.eql(selected)) return item;
        return null;
    }

    fn projectStar(self: *View) void {
        const snapshot = self.snapshot.?;
        const marked = self.currentBookmark() != null;
        self.star_disabled.set(snapshot.path == .disconnected or snapshot.current_url == null or snapshot.page != .displayed);
        self.star_tint.set(if (marked) theme.current().accent_ink else null);
        self.star_icon.set(if (marked) ui.assets.common.star_filled else ui.icons.star);
        self.star_label.set(if (marked) "编辑书签" else "添加书签");
    }

    fn projectStatus(self: *View, page_visible: bool) bool {
        const cx = self.request.cx;
        const state = self.snapshot.?;
        const disconnected = state.path == .disconnected;
        const failed = state.page == .failed;
        const connecting = state.path == .connecting;
        const notice_visible = page_visible and state.login_notice;
        const warning_visible = disconnected and state.reset_warning != .none;
        const layout_changed = (self.state_panel.style.display != .none) == page_visible or
            ((self.login_notice.style.display != .none) != notice_visible) or
            ((self.state_warning.style.display != .none) != warning_visible) or
            ((self.state_actions.style.display != .none) != (disconnected or failed));
        show(self.state_panel, !page_visible);
        show(self.state_actions, disconnected or failed);
        show(self.reconnect_button, disconnected);
        show(self.retry_button, failed and !disconnected);
        show(self.route_button, disconnected and state.route_mode == .ssh);
        show(self.state_warning, warning_visible);
        show(self.login_notice, notice_visible);
        show(self.state_icon, !disconnected and !failed);
        show(self.state_warning_icon, disconnected or failed);

        const heading = if (disconnected)
            "SSH 转发已断开"
        else if (failed)
            "无法打开网页"
        else if (connecting)
            "正在连接 SSH"
        else if (state.page == .loading or state.pending_url != null)
            "正在加载网页"
        else
            "输入网址";
        setText(cx, self.state_title, heading);
        var path: std.Io.Writer.Allocating = .init(cx.allocator);
        defer path.deinit();
        if (connecting and state.error_message == null) {
            for (state.hops, 0..) |hop, index| {
                if (index != 0) path.writer.writeAll(" → ") catch break;
                path.writer.writeAll(hop.name) catch break;
            }
        }
        const detail = state.error_message orelse if (connecting)
            path.written()
        else if (!disconnected and !failed and state.pending_url == null and state.current_url == null)
            "在地址栏输入网址，或选择书签。"
        else
            "";
        show(self.state_detail, detail.len != 0);
        setText(cx, self.state_detail, detail);
        if (self.route_open.peek()) self.projectRoute();
        return layout_changed;
    }

    fn projectRoute(self: *View) void {
        const state = self.snapshot orelse return;
        const cx = self.request.cx;
        show(self.route_status, state.forwarding != null);
        if (state.forwarding) |forwarding| setText(cx, self.route_status, forwardingStatus(forwarding).label);
        const port = if (state.forwarding) |forwarding| switch (forwarding) {
            .listening => |port| port,
            else => null,
        } else null;
        show(self.route_endpoint, port != null);
        if (port) |value| {
            var buffer: [32]u8 = undefined;
            setText(cx, self.route_endpoint, std.fmt.bufPrint(&buffer, "SOCKS5 · 127.0.0.1:{d}", .{value}) catch unreachable);
        }
        if (state.route_mode == .direct) {
            setText(self.request.cx, self.route_text, "直接连接");
            return;
        }
        var output: std.Io.Writer.Allocating = .init(self.request.cx.allocator);
        defer output.deinit();
        for (state.hops, 0..) |hop, index| {
            if (index != 0) output.writer.writeByte('\n') catch return;
            output.writer.print("{d}. {s}  {s}:{d}", .{ index + 1, hop.name, hop.host, hop.port }) catch return;
        }
        setText(self.request.cx, self.route_text, output.written());
    }

    fn projectBookmarks(self: *View) bool {
        const cx = self.request.cx;
        const list = self.bookmarkList();
        const current = self.currentBookmark();
        var total: f32 = 0;
        for (self.strip_bookmarks, self.menu_bookmarks, 0..) |strip, menu, index| {
            const item = if (index < list.len) list[index] else null;
            show(strip.wrapper, item != null);
            show(menu.wrapper, item != null);
            if (item) |entry| {
                if (!std.mem.eql(u8, strip.full_title.peek(), entry.title)) {
                    strip.width = std.math.clamp(@ceil(cx.text.measureTextWidth(entry.title, 12, 500, false)) + 20, S.bookmark_min, S.bookmark_max);
                    strip.full_title.set(entry.title);
                    menu.full_title.set(entry.title);
                    menu.label.set(entry.title);
                    var prefix: [128]u8 = undefined;
                    strip.label.set(fitBookmarkLabel(cx, entry.title, strip.width - 20, &prefix));
                }
                total += strip.width + if (index == 0) @as(f32, 0) else S.bookmark_gap;
                strip.style.set(S.bookmark(strip.width, if (current) |active| active.id.eql(entry.id) else false));
            }
        }
        self.strip_total = total;
        const width = self.toolbar.globalRect().w;
        // Four toolbar controls, separator, their spacing and 132pt address.
        const available = @max(0, @min(S.strip_max, width - 292));
        const needs_arrows = total > available;
        const strip_visible = list.len != 0 and available >= S.bookmark_min + if (needs_arrows) @as(f32, 64) else @as(f32, 0);
        const viewport = if (strip_visible) @min(total, available - if (needs_arrows) @as(f32, 64) else @as(f32, 0)) else 0;
        const menu_height: f32 = if (strip_visible) 0 else @min(238, @as(f32, @floatFromInt(list.len)) * 30);
        show(self.strip, strip_visible);
        show(self.menu_list.container, menu_height > 0);
        show(self.left_button, strip_visible and needs_arrows);
        show(self.right_button, strip_visible and needs_arrows);
        self.strip_overflow = strip_visible and needs_arrows;
        self.left_disabled.set(self.scroll.state.scroll_x <= 0.5);
        self.right_disabled.set(self.scroll.state.scroll_x >= @max(0, total - viewport) - 0.5);

        if (self.focus_bookmark_after_remove) |old_index| {
            const target = if (list.len == 0)
                self.star_button
            else if (strip_visible)
                self.strip_bookmarks[@min(old_index, list.len - 1)].node
            else
                self.more_button;
            cx.setFocus(target);
            self.focus_bookmark_after_remove = null;
        }

        const changed = self.strip_width != viewport or self.list_height != menu_height;
        if (self.strip_width != viewport) {
            self.strip_width = viewport;
            self.scroll.container.setStyleInline(cx.allocator, .{ .width = .{ .px = viewport }, .height = .{ .px = 32 }, .flex_shrink = 0 });
        }
        if (self.list_height != menu_height) {
            self.list_height = menu_height;
            self.menu_list.container.setStyleInline(cx.allocator, .{ .width = .fill(), .height = .{ .px = menu_height }, .flex_shrink = 0 });
        }
        if (self.scroll.content.style.width != .px or self.scroll.content.style.width.px != total) {
            self.scroll.content.setStyleInline(cx.allocator, .{ .width = .{ .px = total }, .height = .fill(), .direction = .row, .align_items = .center, .gap = S.bookmark_gap, .flex_shrink = 0 });
            return true;
        }
        return changed;
    }

    fn revealBookmark(self: *View, index: usize) void {
        if (!self.strip_overflow) return;
        var left: f32 = 0;
        for (self.strip_bookmarks[0..index]) |item| left += item.width + S.bookmark_gap;
        const right = left + self.strip_bookmarks[index].width;
        if (left < self.scroll.state.scroll_x) self.scrollTo(left) else if (right > self.scroll.state.scroll_x + self.strip_width)
            self.scrollTo(right - self.strip_width);
    }

    fn scrollTo(self: *View, offset: f32) void {
        const state = self.scroll.state;
        state.scroll_x = std.math.clamp(offset, 0, @max(0, self.strip_total - self.strip_width));
        state.bonus_x = 0;
        state.bounce_active_x = false;
        self.scroll.content.style.translate_x = state.contentTranslateX();
        self.scroll.content.markCompositePropDirty();
        self.request.cx.requestRedraw();
    }

    fn scrollLeft(self: *View) void {
        var at: f32 = 0;
        var previous: f32 = 0;
        for (self.strip_bookmarks[0..self.bookmarkList().len]) |item| {
            if (at >= self.scroll.state.scroll_x - 0.5) break;
            previous = at;
            at += item.width + S.bookmark_gap;
        }
        self.scrollTo(previous);
    }

    fn scrollRight(self: *View) void {
        var at: f32 = 0;
        for (self.strip_bookmarks[0..self.bookmarkList().len]) |item| {
            at += item.width + S.bookmark_gap;
            if (at > self.scroll.state.scroll_x + 0.5) break;
        }
        self.scrollTo(at);
    }

    fn update(raw: *anyopaque, snapshot: contract.ContentUpdate) !void {
        const self: *View = @ptrCast(@alignCast(raw));
        if (self.closed or !self.request.owner.eql(snapshot.owner)) return error.StaleBinding;
    }

    fn focusChanged(raw: *anyopaque, active: bool) void {
        const self: *View = @ptrCast(@alignCast(raw));
        if (self.closed) return;
        self.active = active;
        if (!active) {
            self.more_open.set(false);
            self.context_open.set(false);
            self.edit_open.set(false);
            self.route_open.set(false);
            self.feedback_open.set(false);
            self.detach();
        }
    }

    fn unmount(raw: *anyopaque) void {
        const self: *View = @ptrCast(@alignCast(raw));
        self.cleanup();
    }

    fn status(raw: *anyopaque) contract.ConnectionStatus {
        const self: *View = @ptrCast(@alignCast(raw));
        const state = self.snapshot orelse return .{ .state = .connecting, .label = "准备浏览器连接" };
        if (state.forwarding) |forwarding| return forwardingStatus(forwarding);
        return switch (state.path) {
            .idle => .{ .state = .connecting, .label = "等待网址" },
            .connecting => .{ .state = .connecting, .label = "正在连接 SSH" },
            .ready => .{ .state = .online, .label = "直接连接" },
            .disconnected => .{ .state = .degraded, .label = "SSH 转发已断开" },
            .closed => .{ .state = .ended, .label = "连接已关闭" },
        };
    }

    fn forwardingStatus(forwarding: api.Forwarding) contract.ConnectionStatus {
        return switch (forwarding) {
            .idle => .{ .state = .connecting, .label = "SSH 转发未启动" },
            .connecting => .{ .state = .connecting, .label = "正在连接 SSH" },
            .listening => .{ .state = .online, .label = "SSH 转发已就绪" },
            .stopping => .{ .state = .connecting, .label = "正在关闭 SSH 转发" },
            .disconnected => .{ .state = .degraded, .label = "SSH 转发已断开" },
        };
    }

    fn focusAddressRaw(raw: *anyopaque) void {
        const self: *View = @ptrCast(@alignCast(raw));
        self.focusAddress();
    }

    fn focusAddress(self: *View) void {
        if (self.closed or !self.active) return;
        if (self.token) |token| self.page.releaseFocus(token) catch {};
        self.request.cx.setFocus(self.address.input_container);
        self.address.state.selectAll();
        self.request.cx.requestRedraw();
    }

    fn addressChanged(self: *View, _: []const u8) void {
        self.address_edited = true;
        self.feedback_open.set(false);
    }

    fn addressEvent(event: ui.events.Event, raw: ?*anyopaque) ui.events.EventResult {
        const self: *View = @ptrCast(@alignCast(raw orelse return .ignored));
        if (event == .key_down and event.key_down.key == .escape and self.address_edited) {
            if (self.address.state.imeIsComposing()) return .ignored;
            self.address_edited = false;
            self.address_text.set(self.displayAddress());
            self.feedback_open.set(false);
            return .stop;
        }
        return .ignored;
    }

    fn navigate(self: *View, value: []const u8) void {
        self.page.command(.{ .navigate = value }) catch |err| {
            self.report(err);
            return;
        };
        self.address_edited = false;
        self.feedback_open.set(false);
        self.request.cx.requestRedraw();
    }

    fn action(self: *View, command: api.Command) void {
        self.page.command(command) catch |err| self.report(err);
        self.request.cx.requestRedraw();
    }

    fn back(self: *View) void {
        self.action(.back);
    }

    fn forward(self: *View) void {
        self.action(.forward);
    }

    fn reloadOrStop(self: *View) void {
        const state = self.snapshot orelse return;
        self.action(if (state.loading or state.path == .connecting) .stop else .reload);
    }

    fn reconnect(self: *View) void {
        self.action(.reconnect);
    }

    fn dismissLoginNotice(self: *View) void {
        self.action(.dismiss_login_notice);
    }

    fn goStart(self: *View) void {
        self.more_open.set(false);
        if (self.snapshot) |snapshot| if (snapshot.start_url) |start| self.navigate(start);
    }

    fn copyUrl(self: *View) void {
        self.more_open.set(false);
        const snapshot = self.snapshot orelse return;
        const address = snapshot.current_url orelse return;
        if (!ui.platform_services.clipboardSetText(self.request.cx.system_sdk, address))
            self.report(error.ClipboardUnavailable);
    }

    fn toggleMore(self: *View) void {
        self.more_open.set(!self.more_open.peek());
    }

    fn showDetailsRaw(raw: *anyopaque) void {
        const self: *View = @ptrCast(@alignCast(raw));
        self.showDetails();
    }

    fn showDetails(self: *View) void {
        const anchor = if (self.route_button.isDisplayedInTree()) self.route_button else self.more_button;
        if (self.closed or !self.active) return;
        self.more_open.set(false);
        self.popup_anchor = anchor;
        self.projectRoute();
        self.route_open.set(true);
        self.request.cx.requestRedraw();
    }

    fn connectionDetailsOpen(raw: *anyopaque) bool {
        const self: *View = @ptrCast(@alignCast(raw));
        return self.active and !self.closed and self.route_open.peek();
    }

    fn projectForwarding(raw: *anyopaque) contract.ForwardingStatus {
        const self: *View = @ptrCast(@alignCast(raw));
        const state = self.snapshot orelse return .{ .state = .idle };
        return .{
            .state = if (state.forwarding) |value| switch (value) {
                .idle => .idle,
                .connecting => .connecting,
                .listening => |port| .{ .listening = port },
                .stopping => .stopping,
                .disconnected => .disconnected,
            } else .direct,
            .exit = if (state.hops.len != 0) state.hops[state.hops.len - 1].name else "",
            .connections = state.forwarding_connections,
            .uploaded = state.forwarding_uploaded,
            .downloaded = state.forwarding_downloaded,
            .error_text = state.forwarding_error,
            .logs = state.forwarding_logs,
        };
    }

    fn mutate(self: *View, mutation: books.Mutation) !void {
        if (self.request.web_bookmarks) |facade| {
            try facade.apply(mutation);
            self.saved_revision = 0;
        } else {
            try self.page.mutateBookmark(mutation);
        }
        self.feedback_open.set(false);
        self.request.cx.requestRedraw();
    }

    fn star(self: *View) void {
        const snapshot = self.snapshot orelse return;
        const address = snapshot.current_url orelse return;
        if (self.currentBookmark()) |item| {
            self.selected_bookmark = item.id;
            self.popup_anchor = self.star_button;
            self.openEditor();
            return;
        }
        self.mutate(.{ .add = .{ .url = address, .page_title = snapshot.title } }) catch |err| self.report(err);
    }

    fn openEditor(self: *View) void {
        const item = self.selectedBookmark() orelse return;
        if (self.edit_arena) |*arena| arena.deinit();
        self.edit_arena = std.heap.ArenaAllocator.init(self.request.cx.allocator);
        self.edit_original = null;
        const allocator = self.edit_arena.?.allocator();
        const title = allocator.dupe(u8, item.title) catch return;
        const url = allocator.dupe(u8, item.url) catch return;
        self.edit_original = .{ .id = item.id, .title = title, .url = url };
        self.edit_title.set(title);
        self.edit_url.set(url);
        setText(self.request.cx, self.edit_error, "");
        show(self.edit_error, false);
        self.context_open.set(false);
        self.edit_open.set(true);
        self.focus_edit_pending = true;
        self.request.cx.requestRedraw();
    }

    fn cancelEdit(self: *View) void {
        self.edit_open.set(false);
        self.returnFocus();
    }

    fn editChanged(self: *View, _: []const u8) void {
        show(self.edit_error, false);
    }

    fn editClosed(self: *View, open: bool) void {
        if (!open) self.returnFocus();
    }

    fn returnFocus(self: *View) void {
        if (!self.active or self.closed) return;
        const target = self.popup_anchor orelse self.star_button;
        if (target.isDisplayedInTree()) self.request.cx.setFocus(target);
    }

    fn commitEdit(self: *View) void {
        const original = self.edit_original orelse return;
        self.mutate(.{ .edit = .{
            .expected = original,
            .title = self.edit_title.peek(),
            .url = self.edit_url.peek(),
        } }) catch |err| {
            setText(self.request.cx, self.edit_error, message(err));
            show(self.edit_error, true);
            return;
        };
        self.cancelEdit();
    }

    fn submitEdit(self: *View, _: []const u8) void {
        self.commitEdit();
    }

    fn removeBookmark(self: *View) void {
        const selected = self.selected_bookmark orelse return;
        self.mutate(.{ .remove = selected }) catch |err| {
            self.context_open.set(false);
            self.report(err);
            return;
        };
        self.context_open.set(false);
        for (self.bookmarkList(), 0..) |item, index| {
            if (item.id.eql(selected)) {
                self.focus_bookmark_after_remove = index;
                break;
            }
        }
    }

    fn report(self: *View, err: anyerror) void {
        setText(self.request.cx, self.feedback_text, message(err));
        self.feedback_open.set(true);
        self.request.cx.requestRedraw();
    }

    fn popupAnchor(raw: *anyopaque) ui.widgets.popover.AnchorRect {
        const self: *View = @ptrCast(@alignCast(raw));
        const rect = (self.popup_anchor orelse self.more_button).globalRect();
        return .{ .x = rect.x, .y = rect.y, .w = rect.w, .h = rect.h };
    }
};

fn show(node: *ui.Node, visible: bool) void {
    node.setDisplay(if (visible) .flex else .none);
}

fn setText(cx: *ui.Cx, node: *ui.Node, value: []const u8) void {
    if (node.getText()) |current| if (std.mem.eql(u8, current.content, value)) return;
    node.setTextContent(cx.allocator, value) catch {};
}

fn message(err: anyerror) []const u8 {
    return switch (err) {
        error.BookmarkCapacity => "最多保存 16 个书签，请先移除一个。",
        error.DuplicateBookmarkUrl => "该网址已在书签中。",
        error.BookmarkConflict => "该书签已被修改，请重新打开后编辑。",
        error.BookmarkNotFound => "该书签已被移除。",
        error.InvalidBookmarkTitle => "请输入书签名称。",
        error.ClipboardUnavailable => "无法复制网址。",
        error.InvalidUrl, error.MissingUrl, error.InvalidHost, error.InvalidPort, error.UnsupportedScheme => "请输入有效的 HTTP 或 HTTPS 网址。",
        error.ResetWarningRequired => "请确认重新连接后再打开网址。",
        else => "操作未完成，请重试。",
    };
}

fn fitBookmarkLabel(cx: *ui.Cx, title: []const u8, width: f32, buffer: []u8) []const u8 {
    if (cx.text.measureTextWidth(title, 12, 500, false) <= width) return title;
    const ellipsis = "…";
    const available = width - cx.text.measureTextWidth(ellipsis, 12, 500, false);
    var end: usize = 0;
    var characters = (std.unicode.Utf8View.init(title) catch return ellipsis).iterator();
    while (characters.nextCodepointSlice()) |character| {
        const candidate = end + character.len;
        if (candidate + ellipsis.len > buffer.len or cx.text.measureTextWidth(title[0..candidate], 12, 500, false) > available) break;
        end = candidate;
    }
    @memcpy(buffer[0..end], title[0..end]);
    @memcpy(buffer[end..][0..ellipsis.len], ellipsis);
    return buffer[0 .. end + ellipsis.len];
}

pub fn mount(_: ?*anyopaque, request: contract.ContentMount) !contract.RendererInstance {
    const cx = request.cx;
    const scope = request.scope;
    const page = try api.Page.lookup(request.service_access orelse return error.ServiceUnavailable);
    var configuration = try config.decode(cx.allocator, request.connection.payload_version, request.connection.payload);
    defer configuration.deinit();
    const payload = switch (configuration.content) {
        .ready => |value| value,
        .repair => return error.BookmarkRepairRequired,
    };
    const self = try scope.createState(View, .{
        .request = request,
        .page = page,
        .preset = payload.url_mode == .preset,
        .focus_address_pending = payload.url_mode == .manual,
    });
    try scope.onCleanup(View, self, View.cleanup);

    self.back_disabled = try scope.createSignal(bool, true);
    self.forward_disabled = try scope.createSignal(bool, true);
    self.reload_disabled = try scope.createSignal(bool, true);
    self.reload_icon = try scope.createSignal(?ui.SvgAsset, ui.icons.rotate_cw);
    self.reload_label = try scope.createText("重新加载", .{});
    self.star_disabled = try scope.createSignal(bool, true);
    self.star_tint = try scope.createSignal(?ui.Color, null);
    self.star_icon = try scope.createSignal(?ui.SvgAsset, ui.icons.star);
    self.star_label = try scope.createText("添加书签", .{});
    self.copy_disabled = try scope.createSignal(bool, true);
    self.more_open = try scope.createSignal(bool, false);
    self.context_open = try scope.createSignal(bool, false);
    self.edit_open = try scope.createSignal(bool, false);
    self.route_open = try scope.createSignal(bool, false);
    self.feedback_open = try scope.createSignal(bool, false);
    self.left_disabled = try scope.createSignal(bool, true);
    self.right_disabled = try scope.createSignal(bool, true);

    self.root = try ui.box(cx, .{
        .width = .fill(),
        .height = .fill(),
        .min_height = 0,
        .direction = .column,
        .gap = 12,
        .padding = .{ .top = 10 },
    }, .{});
    self.root.meta.ownership.meta.test_id = "web.content";
    try request.slot.appendChild(cx.allocator, self.root);
    try buildToolbar(self);
    try buildDocument(self);
    try buildPopups(self);
    const address_focus = try ui.hooks.useFocusState(scope, cx, self.address.input_container);
    try scope.createEffect(.{ .view = self, .publication = try cx.themeSignal(scope), .focused = address_focus.focused }, struct {
        fn repaint(ctx: anytype) void {
            _ = ctx.publication.get();
            const view = ctx.view;
            view.toolbar.setStyleInline(view.request.cx.allocator, S.toolbar());
            view.address_shell.setStyleInline(view.request.cx.allocator, S.address(ctx.focused.get()));
            view.document.setStyleInline(view.request.cx.allocator, S.document());
        }
    }.repaint);
    try cx.addAfterLayoutHook(self, View.afterLayout);
    self.hook_installed = true;
    return .{ .context = self, .vtable = &.{
        .update = View.update,
        .focus_changed = View.focusChanged,
        .unmount = View.unmount,
        .connection_status = View.status,
        .show_connection_details = View.showDetailsRaw,
        .connection_details_open = View.connectionDetailsOpen,
        .forwarding_status = View.projectForwarding,
        .focus_address = View.focusAddressRaw,
    } };
}

fn buildToolbar(self: *View) !void {
    const cx = self.request.cx;
    const scope = self.request.scope;
    self.toolbar = try ui.box(cx, S.toolbar(), .{});
    self.toolbar.meta.ownership.meta.test_id = "web.toolbar";
    try self.root.appendChild(cx.allocator, self.toolbar);
    try self.toolbar.appendChild(cx.allocator, try iconButton(cx, scope, "web.back", "后退", ui.icons.arrow_left, self.back_disabled, @as(?ui.Color, null), cx.on(View, self, View.back)));
    try self.toolbar.appendChild(cx.allocator, try iconButton(cx, scope, "web.forward", "前进", ui.icons.arrow_right, self.forward_disabled, @as(?ui.Color, null), cx.on(View, self, View.forward)));
    try self.toolbar.appendChild(cx.allocator, try iconButton(cx, scope, "web.reload", self.reload_label, self.reload_icon, self.reload_disabled, @as(?ui.Color, null), cx.on(View, self, View.reloadOrStop)));
    const divider = try ui.box(cx, .{
        .width = .{ .px = 1 },
        .height = .{ .px = 16 },
        .flex_shrink = 0,
        .margin = .{ .left = 4, .right = 5 },
        .background = theme.current().border,
    }, .{});
    try theme.bindMaterial(cx, scope, divider, "border");
    try self.toolbar.appendChild(cx.allocator, divider);

    self.address_shell = try ui.box(cx, S.address(false), .{});
    try self.toolbar.appendChild(cx.allocator, self.address_shell);
    const globe = try theme.icon(cx, ui.icons.globe, "fg_2", .{ .width = .{ .px = 16 }, .height = .{ .px = 16 }, .flex_shrink = 0 });
    try self.address_shell.appendChild(cx.allocator, globe);
    self.address_text = try scope.createText("", .{});
    self.address = try ui.widgets.Input(.{
        .value = self.address_text,
        .placeholder = if (self.preset) "" else "输入网址，例如 https://intranet.example.com",
        .growable = true,
        .embedded = true,
        .on_change = cx.on(View, self, View.addressChanged),
        .on_submit = cx.on(View, self, View.navigate),
    }).mountResult(scope, cx);
    self.address.node.setStyleInline(cx.allocator, .{ .width = .fill(), .min_width = 0, .height = .{ .px = 32 } });
    self.address.input_container.setStyleInline(cx.allocator, .{ .min_width = 0, .height = .{ .px = 32 } });
    self.address.input_container.meta.ownership.meta.test_id = "web.address";
    self.address.input_container.behavior.events.on_event_capture = View.addressEvent;
    self.address.input_container.behavior.events.capture_context = self;
    try self.address_shell.appendChild(cx.allocator, self.address.node);
    self.star_button = try iconButton(cx, scope, "web.address.bookmark", self.star_label, self.star_icon, self.star_disabled, self.star_tint, cx.on(View, self, View.star));
    try self.address_shell.appendChild(cx.allocator, self.star_button);

    self.strip = try ui.box(cx, .{ .width = .{ .fit = .{} }, .height = .{ .px = 32 }, .flex_shrink = 0, .direction = .row, .gap = S.bookmark_gap, .align_items = .center }, .{});
    self.strip.meta.ownership.meta.test_id = "web.bookmarks";
    try self.toolbar.appendChild(cx.allocator, self.strip);
    self.left_button = try iconButton(cx, scope, "web.bookmarks.scroll.left", "向左滚动书签", ui.icons.chevron_left, self.left_disabled, @as(?ui.Color, null), cx.on(View, self, View.scrollLeft));
    try self.strip.appendChild(cx.allocator, self.left_button);
    self.scroll = try ui.widgets.ScrollArea(.{ .width = 1, .height = 32, .direction = .horizontal, .rubber_band_x = false }).mount(scope, cx);
    self.scroll.container.meta.ownership.meta.test_id = "web.bookmarks.viewport";
    try self.strip.appendChild(cx.allocator, self.scroll.container);
    self.right_button = try iconButton(cx, scope, "web.bookmarks.scroll.right", "向右滚动书签", ui.icons.chevron_right, self.right_disabled, @as(?ui.Color, null), cx.on(View, self, View.scrollRight));
    try self.strip.appendChild(cx.allocator, self.right_button);
    for (&self.strip_bookmarks, 0..) |*control, index|
        control.* = try bookmarkControl(self, scope, self.scroll.content, index, true);
    show(self.strip, false);

    self.more_button = try iconButton(cx, scope, "web.menu", "浏览器操作", ui.icons.ellipsis, false, @as(?ui.Color, null), cx.on(View, self, View.toggleMore));
    try self.toolbar.appendChild(cx.allocator, self.more_button);
}

fn buildDocument(self: *View) !void {
    const cx = self.request.cx;
    const scope = self.request.scope;
    self.login_notice = try ui.box(cx, .{
        .width = .fill(),
        .height = .{ .px = 32 },
        .flex_shrink = 0,
        .align_items = .center,
        .direction = .row,
        .padding = .{ .left = 10, .right = 6 },
        .background = theme.current().well,
        .border = .{ .radius = 8 },
    }, .{});
    self.login_notice.meta.ownership.meta.test_id = "web.login.notice";
    try theme.bindMaterial(cx, scope, self.login_notice, "well");
    const notice = try caption(cx, "连接已恢复，请重新登录网站。", 12, 500, false);
    notice.setStyleInline(cx.allocator, .{ .width = .fill(), .min_width = 0 });
    try self.login_notice.appendChild(cx.allocator, notice);
    try self.login_notice.appendChild(cx.allocator, try iconButton(cx, scope, "web.login.notice.close", "关闭提示", ui.icons.x, false, @as(?ui.Color, null), cx.on(View, self, View.dismissLoginNotice)));
    show(self.login_notice, false);
    try self.root.appendChild(cx.allocator, self.login_notice);

    self.document = try ui.box(cx, S.document(), .{});
    self.document.meta.ownership.meta.test_id = "web.document";
    try self.root.appendChild(cx.allocator, self.document);

    self.state_panel = try ui.box(cx, .{
        .width = .fill(),
        .max_width = 540,
        .direction = .column,
        .align_items = .center,
        .gap = 12,
        .padding = ui.Padding.all(12),
    }, .{});
    self.state_panel.meta.ownership.meta.test_id = "web.state";
    try self.document.appendChild(cx.allocator, self.state_panel);
    const icon_tile = try ui.box(cx, .{
        .width = .{ .px = 56 },
        .height = .{ .px = 56 },
        .justify = .center,
        .align_items = .center,
        .background = theme.current().well,
        .border = .{ .radius = 17 },
    }, .{});
    try theme.bindMaterial(cx, scope, icon_tile, "well");
    self.state_icon = try theme.icon(cx, ui.icons.globe, "fg_3", .{ .width = .{ .px = 28 }, .height = .{ .px = 28 } });
    try icon_tile.appendChild(cx.allocator, self.state_icon);
    self.state_warning_icon = try theme.icon(cx, ui.icons.triangle_alert, "warn_ink", .{ .width = .{ .px = 28 }, .height = .{ .px = 28 } });
    try icon_tile.appendChild(cx.allocator, self.state_warning_icon);
    show(self.state_warning_icon, false);
    try self.state_panel.appendChild(cx.allocator, icon_tile);
    self.state_title = try caption(cx, "输入网址", 22, 650, true);
    self.state_title.meta.ownership.meta.test_id = "web.state.title";
    try self.state_panel.appendChild(cx.allocator, self.state_title);
    self.state_detail = try caption(cx, "", 13, 400, true);
    self.state_detail.meta.ownership.meta.test_id = "web.state.detail";
    try self.state_panel.appendChild(cx.allocator, self.state_detail);
    self.state_warning = try caption(cx, "重新连接将清除网页登录、未提交内容和浏览历史。", 13, 400, true);
    self.state_warning.meta.ownership.meta.test_id = "web.reconnect.notice";
    try self.state_panel.appendChild(cx.allocator, self.state_warning);
    show(self.state_warning, false);

    self.state_actions = try ui.box(cx, .{ .direction = .row, .align_items = .center, .justify = .center, .gap = 8 }, .{});
    try self.state_panel.appendChild(cx.allocator, self.state_actions);
    self.reconnect_button = try textButton(cx, scope, "web.reconnect", "重新连接", .primary, cx.on(View, self, View.reconnect));
    self.retry_button = try textButton(cx, scope, "web.retry", "重新加载", .primary, cx.on(View, self, View.reloadOrStop));
    self.route_button = try textButton(cx, scope, "web.route.details", "查看路径", .secondary, cx.on(View, self, View.showDetails));
    for ([_]*ui.Node{ self.reconnect_button, self.retry_button, self.route_button }) |button|
        try self.state_actions.appendChild(cx.allocator, button);
    show(self.state_actions, false);
}

fn buildPopups(self: *View) !void {
    const cx = self.request.cx;
    const scope = self.request.scope;
    const more = try makePopup(self, "web.menu.popup", self.more_open, .{ .node = self.more_button }, 216, null);
    const copy = try ui.widgets.Button(.{
        .label = "复制网址",
        .disabled = self.copy_disabled,
        .variant = .ghost,
        .base_style = S.menuRow(),
        .on_click = cx.on(View, self, View.copyUrl),
    }).mount(more.scope, cx);
    copy.meta.ownership.meta.test_id = "web.menu.copy";
    try more.content.appendChild(cx.allocator, copy);
    if (self.preset) try more.content.appendChild(cx.allocator, try menuButton(cx, more.scope, "web.menu.start", "回到起始网址", cx.on(View, self, View.goStart)));
    try more.content.appendChild(cx.allocator, try menuButton(cx, more.scope, "web.menu.route", "查看路径", cx.on(View, self, View.showDetails)));
    self.menu_list = try ui.widgets.ScrollArea(.{ .height = 1, .direction = .vertical, .rubber_band_y = false }).mount(more.scope, cx);
    self.menu_list.container.meta.ownership.meta.test_id = "web.menu.bookmarks";
    try more.content.appendChild(cx.allocator, self.menu_list.container);
    for (&self.menu_bookmarks, 0..) |*control, index|
        control.* = try bookmarkControl(self, more.scope, self.menu_list.content, index, false);
    show(self.menu_list.container, false);

    const anchor: ui.widgets.popover.Anchor = .{ .virtual = .{ .ctx = self, .getRect = View.popupAnchor } };
    const context = try makePopup(self, "web.bookmark.context", self.context_open, anchor, 150, null);
    try context.content.appendChild(cx.allocator, try menuButton(cx, context.scope, "web.bookmark.context.edit", "编辑书签…", cx.on(View, self, View.openEditor)));
    try context.content.appendChild(cx.allocator, try menuButton(cx, context.scope, "web.bookmark.context.remove", "移除", cx.on(View, self, View.removeBookmark)));

    const editor = try makePopup(self, "web.bookmark.edit", self.edit_open, anchor, 380, cx.on(View, self, View.editClosed));
    editor.content.setStyleInline(cx.allocator, .{ .width = .fill(), .direction = .column, .gap = 8, .padding = ui.Padding.all(10) });
    const heading = try ui.box(cx, .{ .width = .fill(), .direction = .row, .align_items = .center }, .{});
    const title = try caption(cx, "编辑书签", 14, 650, false);
    title.setStyleInline(cx.allocator, .{ .width = .fill() });
    try heading.appendChild(cx.allocator, title);
    try heading.appendChild(cx.allocator, try iconButton(cx, editor.scope, "web.bookmark.edit.close", "关闭", ui.icons.x, false, @as(?ui.Color, null), cx.on(View, self, View.cancelEdit)));
    try editor.content.appendChild(cx.allocator, heading);
    self.edit_title = try scope.createText("", .{});
    self.edit_url = try scope.createText("", .{});
    self.edit_name = try ui.widgets.Input(.{
        .value = self.edit_title,
        .label_text = "名称",
        .growable = true,
        .on_change = cx.on(View, self, View.editChanged),
        .on_submit = cx.on(View, self, View.submitEdit),
    }).mountResult(editor.scope, cx);
    self.edit_address = try ui.widgets.Input(.{
        .value = self.edit_url,
        .label_text = "网址",
        .growable = true,
        .on_change = cx.on(View, self, View.editChanged),
        .on_submit = cx.on(View, self, View.submitEdit),
    }).mountResult(editor.scope, cx);
    self.edit_name.input_container.meta.ownership.meta.test_id = "web.bookmark.edit.name";
    self.edit_address.input_container.meta.ownership.meta.test_id = "web.bookmark.edit.url";
    try editor.content.appendChild(cx.allocator, self.edit_name.node);
    try editor.content.appendChild(cx.allocator, self.edit_address.node);
    self.edit_error = try caption(cx, "", 12, 400, false);
    self.edit_error.setTextColor(theme.current().danger_ink);
    theme.bindInk(self.edit_error, "danger_ink");
    self.edit_error.meta.ownership.meta.test_id = "web.bookmark.edit.error";
    show(self.edit_error, false);
    try editor.content.appendChild(cx.allocator, self.edit_error);
    const buttons = try ui.box(cx, .{ .width = .fill(), .direction = .row, .gap = 8, .justify = .end }, .{});
    try buttons.appendChild(cx.allocator, try textButton(cx, editor.scope, "web.bookmark.edit.cancel", "取消", .secondary, cx.on(View, self, View.cancelEdit)));
    try buttons.appendChild(cx.allocator, try textButton(cx, editor.scope, "web.bookmark.edit.save", "保存", .primary, cx.on(View, self, View.commitEdit)));
    try editor.content.appendChild(cx.allocator, buttons);

    const route = try makePopup(self, "web.route.popup", self.route_open, anchor, 326, null);
    route.content.setStyleInline(cx.allocator, .{ .width = .fill(), .direction = .column, .gap = 8, .padding = ui.Padding.all(10) });
    try route.content.appendChild(cx.allocator, try caption(cx, "连接路径", 14, 650, false));
    self.route_status = try caption(cx, "", 13, 400, false);
    try route.content.appendChild(cx.allocator, self.route_status);
    self.route_endpoint = try caption(cx, "", 13, 400, false);
    self.route_endpoint.meta.ownership.meta.test_id = "web.route.endpoint";
    try route.content.appendChild(cx.allocator, self.route_endpoint);
    self.route_text = try caption(cx, "", 13, 400, false);
    try route.content.appendChild(cx.allocator, self.route_text);

    const feedback = try makePopup(self, "web.feedback", self.feedback_open, .{ .node = self.star_button }, 284, null);
    self.feedback_text = try caption(cx, "", 12, 500, false);
    self.feedback_text.setStyleInline(cx.allocator, .{ .width = .fill(), .padding = ui.Padding.all(8) });
    try feedback.content.appendChild(cx.allocator, self.feedback_text);
}

fn makePopup(
    self: *View,
    id: []const u8,
    open: *ui.Signal(bool),
    anchor: ui.widgets.popover.Anchor,
    width: f32,
    on_change: ?ui.Handler(bool),
) !Popup {
    const cx = self.request.cx;
    const popup = try ui.widgets.Popover(.{
        .trigger = .manual,
        .open = open,
        .on_open_change = on_change,
        .anchor = anchor,
        .position = .bottom_end,
        .width = width,
        .constrain_width_to_viewport = true,
        .viewport_padding = 12,
        .shift_main_axis = true,
        .size_policy = .fit_content,
        .offset = .{ .static = 8 },
        .enter_transition = .none,
        .exit_transition = .none,
    }).mount(self.request.scope, cx);
    popup.chrome.meta.ownership.meta.test_id = id;
    popup.chrome.setStyleInline(cx.allocator, S.popover());
    // These popovers use an explicit anchor and portal. Their unused inline
    // triggers must not introduce an extra row or a gap in the document.
    popup.wrapper.setStyleInline(cx.allocator, .{ .position = .absolute, .width = .{ .px = 0 }, .height = .{ .px = 0 } });
    try self.root.appendChild(cx.allocator, popup.wrapper);
    return popup;
}

fn bookmarkControl(self: *View, scope: *ui.Scope, parent: *ui.Node, index: usize, strip: bool) !*BookmarkControl {
    const cx = self.request.cx;
    const control = try scope.createState(BookmarkControl, .{
        .view = self,
        .index = index,
        .strip = strip,
        .label = try scope.createText("", .{}),
        .full_title = try scope.createText("", .{}),
        .style = try scope.createSignal(ui.BoxStyle, if (strip) S.bookmark(S.bookmark_min, false) else S.menuRow()),
    });
    control.node = try ui.widgets.Button(.{
        .label = control.label,
        .a11y_label = control.full_title,
        .variant = .ghost,
        .size = .sm,
        .base_style = control.style,
        .on_click = cx.on(BookmarkControl, control, BookmarkControl.activate),
    }).mount(scope, cx);
    control.node.meta.ownership.meta.test_id = if (strip)
        try scopedId(scope, "web.bookmarks.item.{d}", index + 1)
    else
        try scopedId(scope, "web.menu.bookmark.{d}", index + 1);
    control.node.behavior.events.on_event_capture = BookmarkControl.event;
    control.node.behavior.events.capture_context = control;
    control.wrapper = control.node;
    if (strip) {
        const tooltip = try hint.mount(cx, scope, control.node, control.full_title, .{
            .id = try scopedId(scope, "web.bookmarks.tooltip.{d}", index + 1),
            .width = 180,
        });
        control.wrapper = tooltip.wrapper;
    }
    try parent.appendChild(cx.allocator, control.wrapper);
    show(control.wrapper, false);
    return control;
}

fn iconButton(cx: *ui.Cx, scope: *ui.Scope, id: []const u8, label: anytype, icon: anytype, disabled: anytype, tint: anytype, action: ui.Handler(void)) !*ui.Node {
    const node = try ui.widgets.Button(.{
        .a11y_label = label,
        .icon_only = true,
        .icon_asset = icon,
        .icon_tint = tint,
        .icon_size = @as(f32, 16),
        .variant = .ghost,
        .size = .sm,
        .disabled = disabled,
        .base_style = S.tool(),
        .hover_style = try theme.paintSignal(?ui.BoxStyle, cx, scope, S.toolHover, .{}),
        .on_click = action,
    }).mount(scope, cx);
    node.meta.ownership.meta.test_id = id;
    return node;
}

fn textButton(cx: *ui.Cx, scope: *ui.Scope, id: []const u8, label: []const u8, variant: ui.widgets.ButtonVariant, action: ui.Handler(void)) !*ui.Node {
    const node = try ui.widgets.Button(.{ .label = label, .variant = variant, .on_click = action }).mount(scope, cx);
    node.meta.ownership.meta.test_id = id;
    return node;
}

fn menuButton(cx: *ui.Cx, scope: *ui.Scope, id: []const u8, label: []const u8, action: ui.Handler(void)) !*ui.Node {
    const node = try ui.widgets.Button(.{ .label = label, .variant = .ghost, .base_style = S.menuRow(), .on_click = action }).mount(scope, cx);
    node.meta.ownership.meta.test_id = id;
    return node;
}

fn caption(cx: *ui.Cx, value: []const u8, size: f32, weight: u16, centered: bool) !*ui.Node {
    const node = try ui.text(cx, value, .{
        .font_size = size,
        .font_weight = weight,
        .color = if (weight >= 600) theme.current().fg_1 else theme.current().fg_2,
        .wrap = .word,
        .text_align = if (centered) .center else .start,
        .selectable = false,
    });
    if (centered) node.setStyleInline(cx.allocator, .{ .width = .fill(), .min_width = 0 });
    if (weight >= 600) theme.bindInk(node, "fg_1") else theme.bindInk(node, "fg_2");
    return node;
}

fn scopedId(scope: *ui.Scope, comptime format: []const u8, index: usize) ![]const u8 {
    var storage: [64]u8 = undefined;
    return (try scope.createText(try std.fmt.bufPrint(&storage, format, .{index}), .{})).peek();
}
