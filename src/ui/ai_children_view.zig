//! Stable rows keep their child identity while a popover is being operated.
const std = @import("std");
const ui = @import("ui");
const theme = @import("app_theme.zig");
const projection = @import("../ai/child_projection.zig");
const Logo = @import("ai_child_logo.zig");
const S = @import("ai_children_styles.zig");
/// V0.7 §14.2: Board filter actions (cx.on needs a named outer type).
const BoardFilterPick = struct {
    view: *View,
    fn toggleAsk(self: *BoardFilterPick) void {
        self.view.setBoardFilters(self.view.board_filter_member, !self.view.board_filter_ask_only);
    }
    fn resetMember(self: *BoardFilterPick) void {
        self.view.setBoardFilters(null, self.view.board_filter_ask_only);
    }
};

/// V0.7 §14: page tab click handler (cx.on needs a named outer type).
const TabPick = struct {
    view: *View,
    page: Page,
    fn choose(self: *TabPick) void {
        self.view.selectPage(self.page);
    }
};
const GraphPick = struct {
    view: *View,
    agent: id.AgentId,
    revision: u64,
    allocator: std.mem.Allocator,
    accessible: []u8 = &.{},
    fn release(self: *GraphPick) void {
        self.allocator.free(self.accessible);
    }
    fn choose(self: *GraphPick) void {
        self.view.graph_open.set(false);
        self.view.hooks.select(self.view.hooks.context, self.agent, self.revision);
    }
};
const Header = @import("ai_assistant_header.zig");
const id = @import("../host/identity.zig");
/// V0.7 §14: panel pages. Members is the ordinary mode; Board/Graph/Rounds
/// are the swarm/boost forms riding the same G3/G8 data sources.
pub const Page = enum { members, board, graph, rounds };

pub const Hooks = struct {
    context: *anyopaque,
    select: *const fn (*anyopaque, id.AgentId, u64) void,
    open_approval: ?*const fn (*anyopaque, id.AgentId) void = null,
    /// V0.7 §12.2: level-2 stall banner actions. urge_parent injects a
    /// user-attributed steer through the existing channel; stop_all stops
    /// every unsettled child of this parent.
    urge_parent: ?*const fn (*anyopaque, id.TaskId) void = null,
    stop_all: ?*const fn (*anyopaque, id.TaskId) void = null,
};
pub const View = struct {
    cx: *ui.Cx,
    scope: *ui.Scope,
    hooks: Hooks,
    open: *ui.Signal(bool),
    root: *ui.Node,
    content: *ui.Node,
    scroll: ui.widgets.scroll_area.ScrollAreaResult,
    tabs: *ui.Node,
    decisions_list: *ui.Node,
    viewport: ui.Size,
    board_scope: ?*ui.Scope = null,
    graph_open: *ui.Signal(bool),
    graph_dialog: *ui.Node,
    graph_scope: ?*ui.Scope = null,
    chrome: *ui.Node,
    painted_colors: theme.Colors,
    button: *ui.Node,
    badge: *ui.Node,
    running_badge: *ui.Node,
    heading_count: *ui.Node,
    heading_title: *ui.Node,
    stall_stop: *ui.Node = undefined,
    /// V0.7 §12.2/§14.4: level-2 stall banner node (hidden unless escalated).
    stall_banner: ?*ui.Node = null,
    stall_task: ?id.TaskId = null,
    /// V0.7 §14.1-14.3: panel page tabs. The default page keeps the member
    /// list; Board/Graph/Rounds pages appear only with delegated children.
    page: Page = .members,
    tab_members: ?*ui.Node = null,
    tab_board: ?*ui.Node = null,
    tab_graph: ?*ui.Node = null,
    tab_rounds: ?*ui.Node = null,
    board_list: ?*ui.Node = null,
    graph_canvas: ?*ui.Node = null,
    rounds_list: ?*ui.Node = null,
    verification_button: *ui.Node = undefined,
    verification_label: *ui.Node = undefined,
    verification_arrow: *ui.Node = undefined,
    verification_detail: *ui.Node = undefined,
    verification_expanded: bool = false,
    board_fingerprint: u64 = 0,
    graph_fingerprint: u64 = 0,
    rounds_fingerprint: u64 = 0,
    decisions_fingerprint: u64 = 0,
    /// V0.7 §14.2 Board filters: member (#seq), category, ask-only.
    board_filter_member: ?u32 = null,
    board_filter_ask_only: bool = false,
    rows: std.ArrayList(*Row) = .empty,
    fingerprint: u64 = 0,
    a11y_label: [128]u8 = undefined,
    pub fn mount(cx: *ui.Cx, scope: *ui.Scope, button: *ui.Node, hooks: Hooks) !*View {
        const open = try scope.createSignal(bool, false);
        const popup = try ui.widgets.Popover(.{ .open = open, .trigger = .manual, .anchor = .{ .node = button }, .position = .bottom_start, .offset = .{ .static = 6 }, .max_height = 440, .close_on_escape = true, .close_on_outside_click = true, .flip = true, .shift_main_axis = true, .viewport_padding = 8 }).mount(scope, cx);
        popup.wrapper.setStyleInline(cx.allocator, .{ .position = .absolute, .width = .{ .px = 0 }, .height = .{ .px = 0 } });
        popup.chrome.setStyleInline(cx.allocator, S.panel(cx.tokens, cx.viewport));
        popup.chrome.meta.ownership.meta.test_id = "ai.children.panel";
        const heading = try ui.box(cx, .{ .width = .fill(), .height = .{ .px = 32 }, .direction = .row, .align_items = .center, .gap = 8, .padding = .{ .left = 4, .right = 4 }, .flex_shrink = 0 }, .{});
        heading.meta.ownership.meta.test_id = "ai.children.heading";
        const title = try ui.textStyled(cx, S.name, "子智能体");
        title.meta.ownership.meta.test_id = "ai.children.title";
        try heading.appendChild(cx.allocator, title);
        const heading_spacer = try ui.spacer(cx);
        try heading.appendChild(cx.allocator, heading_spacer);
        const heading_count = try ui.textStyled(cx, S.secondary, "");
        try heading.appendChild(cx.allocator, heading_count);
        try popup.content.appendChild(cx.allocator, heading);
        const banner_placeholder = try ui.box(cx, .{}, .{});
        banner_placeholder.setDisplay(.none);
        banner_placeholder.meta.ownership.meta.test_id = "ai.children.stall";
        try popup.content.appendChild(cx.allocator, banner_placeholder);
        const tab_row = try ui.box(cx, .{ .width = .{ .fit = .{} }, .height = .{ .px = 32 }, .direction = .row, .align_items = .center, .gap = 6, .flex_shrink = 0 }, .{});
        tab_row.meta.ownership.meta.test_id = "ai.children.tabs";
        try heading.insertChildBefore(cx.allocator, tab_row, heading_spacer);

        const scroll = try ui.widgets.ScrollArea(.{ .direction = .vertical }).mount(popup.scope, cx);
        @import("ai_card_scroll.zig").containVertical(scroll);
        scroll.container.setStyleInline(cx.allocator, S.panelBody(cx.viewport, false, false));
        scroll.container.meta.ownership.meta.test_id = "ai.children.viewport";
        scroll.content.setStyleInline(cx.allocator, .{ .width = .fill(), .direction = .column });
        try popup.content.appendChild(cx.allocator, scroll.container);

        const members = try ui.box(cx, S.page(4), .{});
        members.meta.ownership.meta.test_id = "ai.children.list";
        try scroll.content.appendChild(cx.allocator, members);
        const board = try ui.box(cx, S.page(6), .{});
        board.meta.ownership.meta.test_id = "ai.children.board";
        const decisions = try ui.box(cx, S.page(4), .{});
        try board.appendChild(cx.allocator, decisions);
        try scroll.content.appendChild(cx.allocator, board);
        const graph_open = try scope.createSignal(bool, false);
        const graph_modal = try ui.widgets.Modal(.{ .open = graph_open, .width = @max(0, cx.viewport.width - 24), .max_height = @max(0, cx.viewport.height - 24), .background = theme.current().overlay }).mount(scope, cx);
        if (!graph_modal.portaled) if (cx.root) |root| try root.appendChild(cx.allocator, graph_modal.overlay);
        graph_modal.dialog.setStyleInline(cx.allocator, .{ .height = .{ .px = @max(0, cx.viewport.height - 24) } });
        if (graph_modal.dialog.behavior.interaction.a11y) |*a11y| a11y.label = "关系图";
        graph_modal.body.setStyleInline(cx.allocator, .{ .width = .fill(), .height = .fill(), .direction = .column, .gap = 8, .padding = .{ .left = 16, .right = 16, .top = 12, .bottom = 12 } });
        const graph_header = try ui.box(cx, .{ .width = .fill(), .direction = .row, .align_items = .center, .flex_shrink = 0 }, .{});
        try graph_header.appendChild(cx.allocator, try ui.textStyled(cx, S.name, "关系图"));
        try graph_header.appendChild(cx.allocator, try ui.spacer(cx));
        try graph_modal.body.appendChild(cx.allocator, graph_header);
        const graph_scroll = try ui.widgets.ScrollArea(.{ .direction = .both }).mount(scope, cx);
        @import("ai_card_scroll.zig").showOverflowScrollbar(graph_scroll);
        graph_scroll.container.setStyleInline(cx.allocator, .{ .width = .fill(), .height = .fill(), .min_width = 0, .min_height = 0 });
        graph_scroll.content.setStyleInline(cx.allocator, .{ .width = .{ .fit = .{} }, .height = .{ .fit = .{} } });
        try graph_modal.body.appendChild(cx.allocator, graph_scroll.container);
        const graph = try ui.box(cx, .{}, .{});
        graph.meta.ownership.meta.test_id = "ai.children.graph";
        try graph_scroll.content.appendChild(cx.allocator, graph);
        const rounds = try ui.box(cx, S.page(8), .{});
        rounds.meta.ownership.meta.test_id = "ai.children.rounds";
        try scroll.content.appendChild(cx.allocator, rounds);

        const running_badge = try Header.mountDotBadge(cx, button, "ai.children.running");
        const badge = try Header.mountCountBadge(cx, button, "ai.children.count");
        badge.setTextColor(theme.current().danger_ink);
        const self = try scope.createState(View, .{ .cx = cx, .scope = popup.scope, .hooks = hooks, .open = open, .root = popup.wrapper, .content = members, .scroll = scroll, .tabs = tab_row, .decisions_list = decisions, .viewport = cx.viewport, .chrome = popup.chrome, .painted_colors = theme.current(), .button = button, .badge = badge, .running_badge = running_badge, .heading_count = heading_count, .heading_title = title, .stall_banner = banner_placeholder, .board_list = board, .graph_canvas = graph, .graph_open = graph_open, .graph_dialog = graph_modal.dialog, .rounds_list = rounds });
        const close_graph = try ui.widgets.Button(.{ .label = "关闭", .variant = .ghost, .on_click = cx.on(View, self, closeGraph) }).mount(scope, cx);
        close_graph.meta.ownership.meta.test_id = "ai.children.graph.close";
        try graph_header.appendChild(cx.allocator, close_graph);
        // V0.7 §12.2/§14.4: level-2 stall banner. Hidden until the host
        // escalates; carries the 催父/停全部 one-click actions.
        const warning = try ui.iconTint(cx, ui.icons.get("timer").?, theme.current().warn, .{ .width = .{ .px = 14 }, .height = .{ .px = 14 }, .flex_shrink = 0 });
        try banner_placeholder.appendChild(cx.allocator, warning);
        try banner_placeholder.appendChild(cx.allocator, try ui.textStyled(cx, S.secondary, "进度停滞"));
        try banner_placeholder.appendChild(cx.allocator, try ui.spacer(cx));
        const urge = try ui.widgets.Button(.{ .label = "提醒", .a11y_label = "提醒协调者", .variant = .secondary, .on_click = cx.on(View, self, urgeParent) }).mount(popup.scope, cx);
        urge.meta.ownership.meta.test_id = "ai.children.stall.urge";
        try banner_placeholder.appendChild(cx.allocator, urge);
        const stop = try ui.widgets.Button(.{ .label = "停止子任务", .a11y_label = "停止本任务的子任务", .variant = .ghost, .on_click = cx.on(View, self, stopAll) }).mount(popup.scope, cx);
        stop.meta.ownership.meta.test_id = "ai.children.stall.stop";
        self.stall_stop = stop;
        try banner_placeholder.appendChild(cx.allocator, stop);
        banner_placeholder.setStyleInline(cx.allocator, .{ .width = .fill(), .height = .{ .px = 34 }, .direction = .row, .align_items = .center, .gap = 6, .padding = .{ .left = 8, .right = 4 }, .background = theme.popupAction(), .border = .{ .radius = 8 }, .flex_shrink = 0 });
        self.verification_button = try ui.widgets.Button(.{ .variant = .ghost, .base_style = S.verificationFooter(), .a11y_label = "终验", .on_click = cx.on(View, self, toggleVerification) }).mount(popup.scope, cx);
        self.verification_button.meta.ownership.meta.test_id = "ai.children.rounds.verify";
        self.verification_label = try ui.textStyled(cx, S.name, "终验");
        self.verification_arrow = try ui.iconTint(cx, ui.icons.chevron_down, theme.current().fg_2, .{ .width = .{ .px = 12 }, .height = .{ .px = 12 }, .flex_shrink = 0 });
        try self.verification_button.appendChild(cx.allocator, self.verification_label);
        try self.verification_button.appendChild(cx.allocator, try ui.spacer(cx));
        try self.verification_button.appendChild(cx.allocator, self.verification_arrow);
        try popup.content.appendChild(cx.allocator, self.verification_button);
        self.verification_detail = try ui.box(cx, S.page(6), .{});
        self.verification_detail.meta.ownership.meta.test_id = "ai.children.rounds.verification";
        try rounds.appendChild(cx.allocator, self.verification_detail);
        // V0.7 §14: page tabs (members always; Board/Graph/Rounds appear with
        // delegated children — setPages toggles their display).
        self.tab_members = try View.mountTab(cx, popup.scope, self, "成员", "ai.children.tab.members", .members);
        self.tab_board = try View.mountTab(cx, popup.scope, self, "留言板", "ai.children.tab.board", .board);
        self.tab_graph = try View.mountTab(cx, popup.scope, self, "关系图", "ai.children.tab.graph", .graph);
        self.tab_rounds = try View.mountTab(cx, popup.scope, self, "轮次", "ai.children.tab.rounds", .rounds);
        try tab_row.appendChild(cx.allocator, self.tab_members.?);
        try tab_row.appendChild(cx.allocator, self.tab_board.?);
        try tab_row.appendChild(cx.allocator, self.tab_graph.?);
        try tab_row.appendChild(cx.allocator, self.tab_rounds.?);
        self.setPagesAvailable(.auto, 0, 0);
        self.applyPageVisibility();
        try scope.onCleanup(View, self, cleanup);
        _ = ui.clickable(button, cx.on(View, self, toggle));
        return self;
    }
    fn cleanup(self: *View) void {
        self.rows.deinit(self.cx.allocator);
    }
    fn toggle(self: *View) void {
        self.open.set(!self.open.peek());
        self.fingerprint = 0;
        self.cx.requestRedraw();
    }
    /// V0.7 §12.2/§14.4: show or clear the level-2 stall banner.
    pub fn setStallTask(self: *View, task: ?id.TaskId) void {
        const banner = self.stall_banner orelse return;
        const previous = self.stall_task;
        self.stall_task = task;
        if ((previous == null) == (task == null)) return;
        banner.setDisplay(if (task != null) .flex else .none);
        self.scroll.container.setStyleInline(self.cx.allocator, S.panelBody(self.viewport, task != null, self.page == .rounds));
    }
    fn mountTab(cx: *ui.Cx, tab_scope: *ui.Scope, view: *View, label: []const u8, test_id: []const u8, page: Page) !*ui.Node {
        const state = try tab_scope.createState(TabPick, .{ .view = view, .page = page });
        const tab_button = try ui.widgets.Button(.{ .label = label, .variant = .ghost, .on_click = cx.on(TabPick, state, TabPick.choose) }).mount(tab_scope, cx);
        tab_button.meta.ownership.meta.test_id = test_id;
        return tab_button;
    }
    fn closeGraph(self: *View) void {
        self.graph_open.set(false);
    }

    fn selectPage(self: *View, page: Page) void {
        if (page == .graph) {
            self.open.set(false);
            self.graph_open.set(true);
            self.cx.requestRedraw();
            return;
        }
        if (self.page == page) return;
        self.page = page;
        self.applyPageVisibility();
        ui.widgets.scroll_area.setScrollY(self.scroll.state, self.scroll.content, 0);
        self.cx.requestRedraw();
    }

    pub fn setPagesAvailable(self: *View, mode: @import("../ai/swarm_mode.zig").Mode, children: usize, active: usize) void {
        const board = mode != .auto and children != 0;
        const graph = mode == .swarm and active > 1;
        const rounds = mode == .boost and children != 0;
        self.tabs.setDisplay(if (board) .flex else .none);
        self.heading_title.setDisplay(if (board) .none else .flex);
        if (self.tab_board) |tab| tab.setDisplay(if (board) .flex else .none);
        if (self.tab_graph) |tab| tab.setDisplay(if (graph) .flex else .none);
        if (self.tab_rounds) |tab| tab.setDisplay(if (rounds) .flex else .none);
        if (switch (self.page) {
            .members => false,
            .board => !board,
            .graph => !graph,
            .rounds => !rounds,
        }) self.selectPage(.members);
    }

    fn applyPageVisibility(self: *View) void {
        self.content.setDisplay(if (self.page == .members) .flex else .none);
        if (self.board_list) |node| node.setDisplay(if (self.page == .board) .flex else .none);
        if (self.rounds_list) |node| node.setDisplay(if (self.page == .rounds) .flex else .none);
        self.verification_button.setDisplay(if (self.page == .rounds) .flex else .none);
        self.scroll.container.setStyleInline(self.cx.allocator, S.panelBody(self.viewport, self.stall_task != null, self.page == .rounds));
        for ([_]?*ui.Node{ self.tab_members, self.tab_board, self.tab_graph, self.tab_rounds }, 0..) |maybe, index| {
            const tab = maybe orelse continue;
            const active = index == @backingInt(self.page);
            tab.setBackground(if (active) theme.popupSelection() else ui.Color.TRANSPARENT);
            if (tab.behavior.interaction.a11y) |*a11y| a11y.selected = active;
        }
    }

    /// V0.7 §10.2: render the Auto-upgrade decision timeline at the top of
    /// the Board page (explainable: why a request ran in parallel).
    pub fn updateDecisions(self: *View, rows: []const projection.DecisionRow) !void {
        const list = self.decisions_list;
        var hash = std.hash.Wyhash.init(0);
        for (rows) |row| {
            std.hash.autoHash(&hash, row.at_ms);
            hash.update(row.reason);
        }
        const stamp = hash.final();
        if (stamp == self.decisions_fingerprint) return;
        self.decisions_fingerprint = stamp;
        while (list.children.items.len != 0) {
            const child = list.children.items[0];
            self.cx.detachChild(list, child);
            self.cx.destroyDetached(child);
        }
        for (rows) |row| {
            var label: [256]u8 = undefined;
            const head = try std.fmt.bufPrint(&label, "本次并行执行 · {s}", .{row.reason});
            const wrap = try ui.box(self.cx, .{ .width = .fill(), .direction = .column, .gap = 2, .padding = ui.Padding.all(8), .border = .{ .width = 1, .radius = 8 }, .flex_shrink = 0 }, .{});
            wrap.meta.ownership.meta.test_id = "ai.children.decision";
            try wrap.appendChild(self.cx.allocator, try ui.textStyled(self.cx, S.secondary, head));
            try list.appendChild(self.cx.allocator, wrap);
        }
    }
    /// V0.7 §14.2 Board: render the G8 board post stream (from/#to +
    /// category icon + folded text). Read-only; delivery watermarks stay
    /// owned by the model/panel levels separately (G2).
    pub fn updateBoard(self: *View, rows: []const projection.BoardRow) !void {
        const list = self.board_list orelse return;
        var hash = std.hash.Wyhash.init(0);
        std.hash.autoHash(&hash, rows.len != 0);
        std.hash.autoHash(&hash, self.board_filter_member);
        std.hash.autoHash(&hash, self.board_filter_ask_only);
        for (rows) |row| {
            // §14.2 filters: by member, by category, ask-only.
            if (self.board_filter_member) |member| if (member != row.origin) continue;
            if (self.board_filter_ask_only and std.mem.eql(u8, row.category, "ask") == false and !std.mem.eql(u8, row.category, "answer")) continue;
            std.hash.autoHash(&hash, row.origin);
            hash.update(row.kind);
            hash.update(row.category);
            hash.update(row.to);
            hash.update(row.text);
        }
        const stamp = hash.final();
        if (stamp == self.board_fingerprint) return;
        self.board_fingerprint = stamp;
        if (self.board_scope) |old| old.dispose();
        self.board_scope = try self.scope.childScope();
        // Keep the decision timeline mounted while messages change.
        var index = list.children.items.len;
        while (index != 0) {
            index -= 1;
            const child = list.children.items[index];
            if (child == self.decisions_list) continue;
            self.cx.detachChild(list, child);
            self.cx.destroyDetached(child);
        }
        var shown: usize = 0;
        for (rows) |row| {
            if (self.board_filter_member) |member| if (member != row.origin) continue;
            if (self.board_filter_ask_only and !std.mem.eql(u8, row.category, "ask") and !std.mem.eql(u8, row.category, "answer")) continue;
            shown += 1;
            var label: [96]u8 = undefined;
            const head = try std.fmt.bufPrint(&label, "从 #{d} → {s} · {s}", .{ row.origin, row.to, row.category });
            const wrap = try ui.box(self.cx, .{ .width = .fill(), .direction = .column, .gap = 2, .flex_shrink = 0 }, .{});
            try wrap.appendChild(self.cx.allocator, try ui.textStyled(self.cx, S.secondary, head));
            const body = if (row.text.len > 160) row.text[0..160] else row.text;
            try wrap.appendChild(self.cx.allocator, try ui.textStyled(self.cx, S.name, body));
            try list.appendChild(self.cx.allocator, wrap);
        }
        if (shown == 0) try list.appendChild(self.cx.allocator, try ui.textStyled(self.cx, S.secondary, if (rows.len == 0) "暂无留言" else "暂无匹配留言"));
        if (rows.len != 0) try self.mountBoardFilter(list);
    }
    /// §14.2: the filter row (仅看 ask toggle + member reset) rides the top
    /// of the Board page. Mounted dynamically after each rebuild.
    fn mountBoardFilter(self: *View, list: *ui.Node) !void {
        const scope = self.board_scope.?;
        const state = try scope.createState(BoardFilterPick, .{ .view = self });
        const row = try ui.box(self.cx, .{ .width = .fill(), .direction = .row, .align_items = .center, .gap = 8, .padding = .{ .top = 4, .bottom = 4 }, .flex_shrink = 0 }, .{});
        row.meta.ownership.meta.test_id = "ai.children.board.filters";
        const ask = try ui.widgets.Button(.{ .label = if (self.board_filter_ask_only) "✓ 仅看提问与回复" else "仅看提问与回复", .variant = .ghost, .on_click = self.cx.on(BoardFilterPick, state, BoardFilterPick.toggleAsk) }).mount(scope, self.cx);
        ask.meta.ownership.meta.test_id = "ai.children.board.filter.ask";
        try row.appendChild(self.cx.allocator, ask);
        if (self.board_filter_member != null) {
            const reset = try ui.widgets.Button(.{ .label = "清除成员筛选", .variant = .ghost, .on_click = self.cx.on(BoardFilterPick, state, BoardFilterPick.resetMember) }).mount(scope, self.cx);
            reset.meta.ownership.meta.test_id = "ai.children.board.filter.reset";
            try row.appendChild(self.cx.allocator, reset);
        }
        if (list.children.items.len != 0) try list.insertChildBefore(self.cx.allocator, row, list.children.items[0]) else try list.appendChild(self.cx.allocator, row);
    }
    /// §14.2: set Board filters (member #seq or null for all; ask-only).
    pub fn setBoardFilters(self: *View, member: ?u32, ask_only: bool) void {
        self.board_filter_member = member;
        self.board_filter_ask_only = ask_only;
        self.board_fingerprint = 0;
        self.cx.requestRedraw();
    }
    /// V0.7 §14.2 Graph: radial layout with readable cards in a scrollable canvas.
    pub fn updateGraph(self: *View, entries: []const projection.Entry, posts: []const projection.BoardRow) !void {
        const canvas = self.graph_canvas orelse return;
        var hash = std.hash.Wyhash.init(0);
        for (entries) |entry| {
            std.hash.autoHash(&hash, .{ entry.seq, entry.agent, entry.revision, entry.awaiting_approval, entry.waiting_user, entry.running });
            hash.update(entry.status);
            hash.update(entry.name);
        }
        // §14.2 edges: board post accumulation between parent and member
        // (width 1/2/4px by volume, accent translucent).
        for (posts) |post| std.hash.autoHash(&hash, post.origin);
        const stamp = hash.final();
        const visible = entries.len > 1;
        if (stamp == self.graph_fingerprint) return;
        if (self.cx.pressed_node) |pressed| if (pressed.isDescendantOf(canvas)) {
            self.cx.scheduleRedrawAfterNs(16 * std.time.ns_per_ms);
            return;
        };
        self.graph_fingerprint = stamp;
        if (self.graph_scope) |old| old.dispose();
        self.graph_scope = null;
        while (canvas.children.items.len != 0) {
            const child = canvas.children.items[0];
            self.cx.detachChild(canvas, child);
            self.cx.destroyDetached(child);
        }
        if (!visible) return;

        const scope = try self.scope.childScope();
        self.graph_scope = scope;
        // §14.2: deterministic ring coordinates cap at 16 members; extra
        // members stay visible in the member list without inflating the ring.
        const count = @min(entries.len, 16);
        var card_width: f32 = 136;
        for (entries) |entry| {
            var prefix: [16]u8 = undefined;
            const number = try std.fmt.bufPrint(&prefix, "#{d}  ", .{entry.seq});
            const text_width = self.cx.text.measureTextWidth(number, 12, 600, false) +
                self.cx.text.measureTextWidth(entry.name, 12, 600, false);
            card_width = @max(card_width, @ceil(text_width) + 28);
        }
        const radius = @max(card_width / 2 + 58, (card_width + 24) / (2 * @sin(std.math.pi / @as(f32, @floatFromInt(count)))));
        const center_x = @max(radius + card_width / 2 + 24, (self.viewport.width - 56) / 2);
        const center_y = @max(radius + 40, (self.viewport.height - 96) / 2);
        canvas.setStyleInline(self.cx.allocator, .{ .width = .{ .px = center_x * 2 }, .height = .{ .px = center_y * 2 }, .flex_shrink = 0 });
        for (entries[0..count], 0..) |entry, index| {
            var volume: usize = 0;
            for (posts) |post| if (post.origin == entry.seq) {
                volume += 1;
            };
            const width: f32 = if (volume >= 4) 4 else if (volume >= 2) 2 else 1;
            const angle = 2 * std.math.pi * @as(f32, @floatFromInt(index)) / @as(f32, @floatFromInt(count));
            const node_x = center_x + radius * @cos(angle);
            const node_y = center_y + radius * @sin(angle);
            // Horizontal + vertical two-segment approximation toward center.
            const h_len = @abs(node_x - center_x);
            const h_x = @min(node_x, center_x);
            const horizontal = try ui.box(self.cx, .{ .position = .absolute, .inset = .{ .left = .{ .px = h_x }, .top = .{ .px = center_y } }, .width = .{ .px = h_len }, .height = .{ .px = width }, .background = theme.current().accent, .opacity = 0.35, .flex_shrink = 0 }, .{});
            try canvas.appendChild(self.cx.allocator, horizontal);
            const v_len = @abs(node_y - center_y);
            if (v_len > 0.5) {
                const v_y = @min(node_y, center_y);
                const vertical = try ui.box(self.cx, .{ .position = .absolute, .inset = .{ .left = .{ .px = node_x - width / 2 }, .top = .{ .px = v_y } }, .width = .{ .px = width }, .height = .{ .px = v_len }, .background = theme.current().accent, .opacity = 0.35, .flex_shrink = 0 }, .{});
                try canvas.appendChild(self.cx.allocator, vertical);
            }
        }
        const colors = theme.current();
        const parent_node = try ui.box(self.cx, S.graphNode(center_x, center_y, 68, colors.accent), .{});
        try parent_node.appendChild(self.cx.allocator, try ui.textStyled(self.cx, S.name, "协调者"));
        try canvas.appendChild(self.cx.allocator, parent_node);

        for (entries[0..count], 0..) |entry, index| {
            const angle = 2 * std.math.pi * @as(f32, @floatFromInt(index)) / @as(f32, @floatFromInt(count));
            const x = center_x + radius * @cos(angle);
            const y = center_y + radius * @sin(angle);
            const tint = if (entry.awaiting_approval or entry.waiting_user) colors.warn else if (entry.running) colors.accent else if (std.mem.eql(u8, entry.status, "已完成")) colors.ok else colors.fg_2;
            const width = card_width;
            const pick = try scope.createState(GraphPick, .{ .view = self, .agent = entry.agent, .revision = entry.revision, .allocator = scope.allocator });
            try scope.onCleanup(GraphPick, pick, GraphPick.release);
            pick.accessible = try std.fmt.allocPrint(scope.allocator, "#{d} {s}，{s}", .{ entry.seq, entry.name, entry.status });
            const node = try ui.widgets.Button(.{ .variant = .ghost, .a11y_label = pick.accessible, .base_style = S.graphNode(x, y, width, tint), .on_click = self.cx.on(GraphPick, pick, GraphPick.choose) }).mount(scope, self.cx);
            node.setStyleInline(self.cx.allocator, S.graphNode(x, y, width, tint));
            node.meta.ownership.meta.test_id = "ai.children.graph.member";
            const caption = try ui.textStyled(self.cx, S.name, "");
            const caption_text = try std.fmt.allocPrint(scope.allocator, "#{d}  {s}", .{ entry.seq, entry.name });
            defer scope.allocator.free(caption_text);
            try caption.setTextContent(self.cx.allocator, caption_text);
            try node.appendChild(self.cx.allocator, caption);
            try canvas.appendChild(self.cx.allocator, node);
        }
    }
    /// V0.7 §14.3 Rounds: boost chain rounds as a vertical timeline of node
    /// cards (seq/label/status/summary), with the final verification bar.
    pub fn updateRounds(self: *View, boost: projection.BoostView) !void {
        const list = self.rounds_list orelse return;
        var hash = std.hash.Wyhash.init(0);
        if (boost.parent) |parent| std.hash.autoHash(&hash, .{ parent.task, parent.status, parent.verification != null });
        for (boost.rows) |row| {
            std.hash.autoHash(&hash, .{ row.seq, row.status, row.round, row.previous_seq });
            hash.update(row.label);
            hash.update(row.summary);
        }
        const stamp = hash.final();
        if (stamp == self.rounds_fingerprint) return;
        self.rounds_fingerprint = stamp;
        self.clearContent(self.verification_detail);
        var index = list.children.items.len;
        while (index > 1) {
            index -= 1;
            const child = list.children.items[index];
            self.cx.detachChild(list, child);
            self.cx.destroyDetached(child);
        }
        const items = if (boost.parent) |parent| parent.verification orelse &.{} else &.{};
        if (items.len == 0) self.verification_expanded = false;
        const passed = for (items) |item| {
            if (!item.passed) break false;
        } else true;
        const summary = if (items.len != 0)
            if (passed) "终验通过" else "终验未通过"
        else if (boost.parent) |parent|
            if (@import("../ai/task_budget.zig").terminal(parent.status)) "未提交终验" else "等待终验"
        else
            "等待终验";
        try self.verification_label.setTextContent(self.cx.allocator, summary);
        self.verification_label.setTextColor(if (items.len == 0) theme.current().fg_2 else if (passed) theme.current().ok else theme.current().danger_ink);
        self.verification_button.setFocusable(items.len != 0);
        if (self.verification_button.behavior.interaction.a11y) |*attrs| {
            attrs.label = summary;
            attrs.expanded = if (items.len != 0) self.verification_expanded else null;
        }
        self.verification_arrow.setDisplay(if (items.len == 0) .none else .flex);
        self.verification_detail.setDisplay(if (self.verification_expanded) .flex else .none);
        for (items) |item| {
            const card = try ui.box(self.cx, S.timelineCard(true), .{});
            const heading = try ui.box(self.cx, .{ .width = .fill(), .direction = .row, .align_items = .center, .gap = 6 }, .{});
            const icon = if (item.passed) ui.icons.get("circle-check").? else ui.icons.get("circle-x").?;
            try heading.appendChild(self.cx.allocator, try ui.iconTint(self.cx, icon, if (item.passed) theme.current().ok else theme.current().danger_ink, .{ .width = .{ .px = 14 }, .height = .{ .px = 14 }, .flex_shrink = 0 }));
            try heading.appendChild(self.cx.allocator, try ui.textStyled(self.cx, S.name, item.requirement));
            try card.appendChild(self.cx.allocator, heading);
            try card.appendChild(self.cx.allocator, try ui.textStyled(self.cx, S.detail, item.detail));
            try self.verification_detail.appendChild(self.cx.allocator, card);
        }
        if (boost.rows.len == 0) try list.appendChild(self.cx.allocator, try ui.textStyled(self.cx, S.secondary, "暂无轮次"));
        for (boost.rows) |row| {
            var title: [160]u8 = undefined;
            const card = try ui.box(self.cx, S.timelineCard(false), .{});
            const phase = switch (row.round.phase) {
                .implementation => "实现",
                .challenge => "复审",
                .repair => "修复",
            };
            const heading = try std.fmt.bufPrint(&title, "第 {d} 轮 · {s}   #{d} {s}", .{ row.round.number, phase, row.seq, row.label });
            try card.appendChild(self.cx.allocator, try ui.textStyled(self.cx, S.name, heading));
            var status: [100]u8 = undefined;
            const state = switch (row.status) {
                .succeeded => "已完成",
                .failed => "失败",
                .cancelled => "已停止",
                .outcome_unknown, .interrupted => "待核验",
                .queued_dependency => "等待前序",
                .human_wait => "等待用户",
                .waiting_model => "等待模型",
                .settling => "收尾中",
                .waiting_children => "等待子任务",
                .running => "运行中",
            };
            const caption = if (row.previous_seq) |seq| try std.fmt.bufPrint(&status, "{s} · 接续 #{d}", .{ state, seq }) else state;
            try card.appendChild(self.cx.allocator, try ui.textStyled(self.cx, S.secondary, caption));
            if (row.summary.len != 0) try card.appendChild(self.cx.allocator, try ui.textStyled(self.cx, S.secondary, row.summary));
            try list.appendChild(self.cx.allocator, card);
        }
    }

    fn clearContent(self: *View, parent: *ui.Node) void {
        while (parent.children.items.len != 0) {
            const child = parent.children.items[0];
            self.cx.detachChild(parent, child);
            self.cx.destroyDetached(child);
        }
    }

    fn toggleVerification(self: *View) void {
        if (self.verification_detail.children.items.len == 0) return;
        self.verification_expanded = !self.verification_expanded;
        self.verification_detail.setDisplay(if (self.verification_expanded) .flex else .none);
        if (self.verification_button.behavior.interaction.a11y) |*attrs| attrs.expanded = self.verification_expanded;
        ui.widgets.setScrollY(self.scroll.state, self.scroll.content, 0);
        self.cx.requestRedraw();
    }
    fn urgeParent(self: *View) void {
        if (self.hooks.urge_parent) |urge| urge(self.hooks.context, self.stall_task orelse return);
    }
    fn stopAll(self: *View) void {
        if (self.hooks.stop_all) |stop| stop(self.hooks.context, self.stall_task orelse return);
    }
    pub fn update(self: *View, entries: []const projection.Entry) !void {
        return self.updateWithCount(entries, null);
    }
    /// Historical lists may show another parent's children. The header badge
    /// continues to describe only the currently displayed main conversation.
    pub fn updateWithCount(self: *View, entries: []const projection.Entry, running_count: ?usize) !void {
        if (!std.meta.eql(self.viewport, self.cx.viewport)) {
            self.viewport = self.cx.viewport;
            self.graph_dialog.setStyleInline(self.cx.allocator, .{ .width = .{ .px = @max(0, self.viewport.width - 24) }, .height = .{ .px = @max(0, self.viewport.height - 24) } });
            self.chrome.setStyleInline(self.cx.allocator, S.panel(self.cx.tokens, self.viewport));
            self.scroll.container.setStyleInline(self.cx.allocator, S.panelBody(self.viewport, self.stall_task != null, self.page == .rounds));
            self.graph_fingerprint = 0;
        }
        if (!std.meta.eql(self.painted_colors, theme.current())) {
            self.painted_colors = theme.current();
            self.chrome.setStyleInline(self.cx.allocator, S.panel(self.cx.tokens, self.viewport));
            self.applyPageVisibility();
            Header.repaintCountBadge(self.cx, self.badge);
            self.badge.setTextColor(theme.current().danger_ink);
            self.graph_fingerprint = 0;
            for (self.rows.items) |row| row.repaint();
        }
        var count: usize = 0;
        var active_count: usize = 0;
        var hash = std.hash.Wyhash.init(0);
        for (entries) |entry| {
            count += @intFromBool(entry.running or entry.waiting_user);
            active_count += @intFromBool(entry.active or entry.waiting_user);
            std.hash.autoHash(&hash, .{ entry.agent, entry.revision, entry.group, entry.running, entry.awaiting_approval, entry.reusable, entry.changed_at_ms });
            hash.update(entry.name);
            hash.update(entry.status);
            hash.update(entry.summary);
        }
        var waiting_approval: usize = 0;
        for (entries) |entry| waiting_approval += @intFromBool(entry.awaiting_approval);
        count = running_count orelse count;
        var count_buffer: [64]u8 = undefined;
        const count_label = if (waiting_approval != 0)
            try std.fmt.bufPrint(&count_buffer, "{d} 待审批", .{waiting_approval})
        else if (count != 0)
            try std.fmt.bufPrint(&count_buffer, "{d} 运行中", .{count})
        else
            "";
        self.heading_count.setDisplay(if (count_label.len == 0) .none else .flex);
        const stoppable = for (entries) |entry| {
            if (entry.active or entry.running) break true;
        } else false;
        self.stall_stop.setDisplay(if (stoppable) .flex else .none);
        if (!sameText(self.heading_count, count_label)) try self.heading_count.setTextContent(self.cx.allocator, count_label);
        const label = try std.fmt.bufPrint(&self.a11y_label, "子智能体，{d} 个运行中，{d} 个待审批", .{ count, waiting_approval });
        if (self.button.behavior.interaction.a11y) |*a11y| a11y.label = label;
        try Header.updateCountBadge(self.cx, self.badge, waiting_approval);
        // The approval number keeps priority over the ambient running dot.
        Header.updateDotBadge(self.cx, self.running_badge, waiting_approval == 0 and active_count != 0);
        if (!self.open.peek()) {
            self.fingerprint = 0;
            var index = self.rows.items.len;
            while (index != 0) {
                index -= 1;
                const row = self.rows.items[index];
                if (row.node.style.display != .none) continue;
                self.cx.detachChild(self.content, row.node);
                self.cx.destroyDetached(row.node);
                _ = self.rows.orderedRemove(index);
                row.scope.dispose();
            }
            return;
        }
        const stamp = hash.final();
        if (stamp == self.fingerprint) return;
        if (self.cx.pressed_node) |pressed| {
            if (pressed.isDescendantOf(self.content)) {
                self.cx.scheduleRedrawAfterNs(16 * std.time.ns_per_ms);
                return;
            }
        }
        var same_order = self.fingerprint != 0;
        var index: usize = 0;
        if (same_order) for (self.content.children.items) |node| {
            if (node.style.display == .none) continue;
            const row = for (self.rows.items) |row| {
                if (row.node == node) break row;
            } else continue;
            if (index >= entries.len or !row.agent.eql(entries[index].agent) or row.group != entries[index].group) {
                same_order = false;
                break;
            }
            index += 1;
        };
        if (same_order and index == entries.len) {
            for (entries) |entry| try self.rowFor(entry.agent).?.update(entry);
            self.fingerprint = stamp;
            return;
        }
        for (self.rows.items) |row| {
            if (row.node.parent != null) self.cx.detachChild(self.content, row.node);
            row.node.setDisplay(.none);
        }
        while (self.content.children.items.len != 0) {
            const node = self.content.children.items[0];
            self.cx.detachChild(self.content, node);
            self.cx.destroyDetached(node);
        }
        if (entries.len == 0) try self.content.appendChild(self.cx.allocator, try ui.textStyled(self.cx, S.secondary, "暂无子智能体"));
        const grouped = entries.len > 1 and entries[0].group != entries[entries.len - 1].group;
        var group: ?projection.Group = null;
        for (entries) |entry| {
            if (grouped and group != entry.group and entry.group != .approval) {
                const header = try ui.textStyled(self.cx, S.secondary, switch (entry.group) {
                    .approval => "待审批",
                    .attention => "待处理",
                    .active => "进行中",
                    .recent => "最近结束",
                });
                header.setStyleInline(self.cx.allocator, .{ .padding = .{ .left = 52, .right = 8, .top = 8, .bottom = 4 }, .flex_shrink = 0 });
                try self.content.appendChild(self.cx.allocator, header);
                group = entry.group;
            }
            if (self.rowFor(entry.agent)) |row| {
                row.group = entry.group;
                row.node.setDisplay(.flex);
                try self.content.appendChild(self.cx.allocator, row.node);
                try row.update(entry);
                continue;
            }
            const scope = try self.scope.childScope();
            errdefer scope.dispose();
            const row = try scope.createState(Row, .{ .view = self, .agent = entry.agent, .revision = entry.revision, .group = entry.group, .scope = scope, .node = undefined, .name = undefined, .detail = undefined, .status = undefined, .spinner = undefined, .spinner_color = try scope.createSignal(?ui.Color, theme.current().accent) });
            const node = try ui.widgets.Button(.{ .variant = .ghost, .a11y_label = entry.name, .base_style = ui.BoxStyle{ .width = .fill(), .height = .{ .px = 52 }, .direction = .row, .justify = .start, .align_items = .center, .padding = ui.Padding.all(10), .gap = 10, .flex_shrink = 0, .border = .{ .radius = 8 } }, .on_click = self.cx.on(Row, row, Row.select) }).mount(scope, self.cx);
            for (node.children.items) |slot| slot.setDisplay(.none);
            row.node = node;
            node.meta.ownership.meta.test_id = try std.fmt.bufPrint(&row.test_id, "ai.child.{s}", .{std.fmt.bytesToHex(entry.agent.bytes, .lower)});
            row.logo = try Logo.mount(self.cx, entry.agent);
            try node.appendChild(self.cx.allocator, row.logo);
            const copy = try ui.box(self.cx, .{ .width = .fill(), .flex = 1, .min_width = 0, .direction = .column, .gap = 3 }, .{});
            row.name = try ui.textStyled(self.cx, S.name, "");
            row.name.meta.ownership.meta.test_id = "ai.child.row.name";
            row.name.setStyleInline(self.cx.allocator, .{ .width = .fill(), .min_width = 0, .overflow_hidden = true });
            row.detail = try ui.textStyled(self.cx, S.secondary, "");
            row.detail.meta.ownership.meta.test_id = "ai.child.row.detail";
            row.detail.setStyleInline(self.cx.allocator, .{ .width = .fill(), .min_width = 0, .overflow_hidden = true });
            row.status_text = try scope.createText(entry.status, .{});
            const status_tip = try ui.widgets.Tooltip(.{ .text = row.status_text, .width = 132 }).mount(scope, self.cx);
            status_tip.wrapper.meta.ownership.meta.test_id = "ai.child.row.status";
            status_tip.wrapper.setStyleInline(self.cx.allocator, .{ .width = .{ .px = 24 }, .height = .{ .px = 24 }, .flex_shrink = 0 });
            status_tip.trigger.setStyleInline(self.cx.allocator, .{ .width = .{ .px = 24 }, .height = .{ .px = 24 }, .align_items = .center, .justify = .center, .flex_shrink = 0 });
            row.status = try ui.iconTint(self.cx, ui.icons.circle, theme.current().fg_2, .{ .width = .{ .px = 16 }, .height = .{ .px = 16 }, .flex_shrink = 0 });
            row.status.meta.ownership.meta.test_id = "ai.child.status.icon";
            try status_tip.trigger.appendChild(self.cx.allocator, row.status);
            row.spinner = try ui.widgets.Spinner(.{ .size = 16, .stroke_width = 1.5, .color = row.spinner_color }).mount(scope, self.cx);
            row.spinner.meta.ownership.meta.test_id = "ai.child.status.spinner";
            row.spinner.behavior.interaction.a11y = .{ .hidden = true };
            try status_tip.trigger.appendChild(self.cx.allocator, row.spinner);
            try copy.appendChild(self.cx.allocator, row.name);
            try copy.appendChild(self.cx.allocator, row.detail);
            try node.appendChild(self.cx.allocator, copy);
            try node.appendChild(self.cx.allocator, status_tip.wrapper);
            try self.content.appendChild(self.cx.allocator, node);
            try row.update(entry);
            try self.rows.append(self.cx.allocator, row);
        }
        // Keep retired rows until the popover closes so a retained pointer
        // cannot turn into a different member during the current interaction.
        for (self.rows.items) |row| if (row.node.parent == null) try self.content.appendChild(self.cx.allocator, row.node);
        self.fingerprint = stamp;
    }
    fn rowFor(self: *View, agent: id.AgentId) ?*Row {
        for (self.rows.items) |row| if (row.agent.eql(agent)) return row;
        return null;
    }
    fn sameText(node: *ui.Node, value: []const u8) bool {
        return if (node.getText()) |text| std.mem.eql(u8, text.content, value) else false;
    }
    const Row = struct {
        view: *View,
        agent: id.AgentId,
        revision: u64,
        group: projection.Group,
        scope: *ui.Scope,
        approval: bool = false,
        test_id: [48]u8 = undefined,
        a11y_label: [384]u8 = undefined,
        display_name: [64]u8 = undefined,
        node: *ui.Node,
        logo: *ui.Node = undefined,
        status_text: *ui.Signal([]const u8) = undefined,
        visual: Visual = .complete,
        name: *ui.Node,
        detail: *ui.Node,
        status: *ui.Node,
        spinner: *ui.Node,
        spinner_color: *ui.Signal(?ui.Color),
        fn update(self: *Row, entry: projection.Entry) !void {
            self.revision = entry.revision;
            self.approval = entry.awaiting_approval;
            const status = if (self.approval) "在主对话审批" else entry.status;
            // V0.7 §2.1: rows show the host display name "#N label".
            const display = if (entry.seq != 0)
                if (entry.name.len != 0)
                    try std.fmt.bufPrint(&self.display_name, "#{d} {s}", .{ entry.seq, entry.name })
                else
                    try std.fmt.bufPrint(&self.display_name, "#{d}", .{entry.seq})
            else
                entry.name;
            if (!View.sameText(self.name, display)) try self.name.setTextContent(self.view.cx.allocator, display);
            if (self.node.behavior.interaction.a11y) |*a11y| a11y.label = try std.fmt.bufPrint(&self.a11y_label, "{s}，{s}", .{ display, status });
            self.status_text.set(status);
            self.visual = if (self.approval) .approval else if (entry.running) .running else if (std.mem.eql(u8, entry.status, "失败")) .failed else if (entry.group == .attention) .attention else if (entry.group == .active) .waiting else if (std.mem.eql(u8, entry.status, "已停止")) .stopped else .complete;
            self.repaint();
            var buf: [256]u8 = undefined;
            const seconds: i64 = if (entry.changed_at_ms > 0) @max(0, @divTrunc(@import("../platform/realtime.zig").milliseconds(undefined) - entry.changed_at_ms, 1000)) else 0;
            var summary_len = @min(entry.summary.len, 100);
            while (summary_len != 0 and summary_len < entry.summary.len and entry.summary[summary_len] & 0xc0 == 0x80) summary_len -= 1;
            // V0.7 §3.8: usage facts as established facts (no ledger).
            const detail = if (self.approval) status else if (entry.requests != 0)
                try std.fmt.bufPrint(&buf, "{s}{s} · {d} 次请求 · {d} tokens · {d} 秒前", .{ if (entry.summary.len != 0) entry.summary[0..summary_len] else entry.status, if (entry.reusable) " · 可复用" else "", entry.requests, entry.tokens, seconds })
            else
                try std.fmt.bufPrint(&buf, "{s}{s} · {d} 秒前", .{ if (entry.summary.len != 0) entry.summary[0..summary_len] else entry.status, if (entry.reusable) " · 可复用" else "", seconds });
            if (!View.sameText(self.detail, detail)) try self.detail.setTextContent(self.view.cx.allocator, detail);
        }
        const Visual = enum { running, waiting, approval, attention, failed, stopped, complete };
        fn repaint(self: *Row) void {
            Logo.repaint(self.logo, self.agent);
            self.node.setBackground(if (self.approval) theme.popupSelection() else theme.popupAction());
            const colors = theme.current();
            const running = self.visual == .running;
            self.spinner.setDisplay(if (running) .flex else .none);
            self.status.setDisplay(if (running) .none else .flex);
            if (running) {
                self.spinner_color.set(colors.accent);
                return;
            }
            const asset = ui.icons.get(switch (self.visual) {
                .running => unreachable,
                .waiting => "clock-3",
                .approval => "shield",
                .attention => "circle-help",
                .failed => "circle-alert",
                .stopped => "circle-stop",
                .complete => "circle-check",
            }).?;
            const tint = switch (self.visual) {
                .running => unreachable,
                .waiting => colors.accent,
                .approval, .attention => colors.warn,
                .failed => colors.danger,
                .stopped => colors.fg_2,
                .complete => colors.ok,
            };
            self.status.setIcon(.{ .icon_id = asset.icon_id.?, .rep = asset.pickRep(16).?, .tint = tint });
        }
        fn select(self: *Row) void {
            self.view.open.set(false);
            if (self.approval) {
                if (self.view.hooks.open_approval) |open_approval| open_approval(self.view.hooks.context, self.agent);
            } else self.view.hooks.select(self.view.hooks.context, self.agent, self.revision);
        }
    };
};
