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
const Header = @import("ai_assistant_header.zig");
const id = @import("../host/identity.zig");
/// V0.7 §14: panel pages. Members is the ordinary mode; Board/Graph/Rounds
/// are the swarm/boost forms riding the same G3/G8 data sources.
pub const Page = enum { members, board, graph, rounds };

pub const Hooks = struct {
    context: *anyopaque,
    select: *const fn (*anyopaque, id.AgentId, u64) void,
    /// V0.7 §12.2: level-2 stall banner actions. urge_parent injects a
    /// user-attributed steer through the existing channel; stop_all stops
    /// every unsettled child of this parent.
    urge_parent: ?*const fn (*anyopaque) void = null,
    stop_all: ?*const fn (*anyopaque) void = null,
};
pub const View = struct {
    cx: *ui.Cx,
    scope: *ui.Scope,
    hooks: Hooks,
    open: *ui.Signal(bool),
    root: *ui.Node,
    content: *ui.Node,
    chrome: *ui.Node,
    painted_colors: theme.Colors,
    button: *ui.Node,
    badge: *ui.Node,
    heading_count: *ui.Node,
    /// V0.7 §12.2/§14.4: level-2 stall banner node (hidden unless escalated).
    stall_banner: ?*ui.Node = null,
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
    board_fingerprint: u64 = 0,
    graph_fingerprint: u64 = 0,
    rounds_fingerprint: u64 = 0,
    decisions_fingerprint: u64 = 0,
    /// V0.7 §14.2 Board filters: member (#seq), category, ask-only.
    board_filter_member: ?u32 = null,
    board_filter_ask_only: bool = false,
    rows: std.ArrayList(*Row) = .empty,
    rows_scope: ?*ui.Scope = null,
    fingerprint: u64 = 0,
    a11y_label: [80]u8 = undefined,
    pub fn mount(cx: *ui.Cx, scope: *ui.Scope, button: *ui.Node, hooks: Hooks) !*View {
        const open = try scope.createSignal(bool, false);
        const popup = try ui.widgets.Popover(.{ .open = open, .trigger = .manual, .anchor = .{ .node = button }, .position = .bottom_start, .offset = .{ .static = 6 }, .width = 400, .max_height = 300, .close_on_escape = true, .close_on_outside_click = true, .constrain_width_to_viewport = true, .flip = true, .viewport_padding = 8 }).mount(scope, cx);
        popup.wrapper.setStyleInline(cx.allocator, .{ .position = .absolute, .width = .{ .px = 0 }, .height = .{ .px = 0 } });
        popup.chrome.setStyleInline(cx.allocator, .{ .background = theme.current().overlay, .border = .{ .radius = 12 }, .padding = ui.Padding.all(8) });
        const heading = try ui.box(cx, .{ .width = .fill(), .height = .{ .px = 32 }, .direction = .row, .align_items = .center, .gap = 8, .padding = .{ .left = 52, .right = 12 }, .flex_shrink = 0 }, .{});
        heading.meta.ownership.meta.test_id = "ai.children.heading";
        const title = try ui.textStyled(cx, S.name, "子智能体");
        title.meta.ownership.meta.test_id = "ai.children.title";
        try heading.appendChild(cx.allocator, title);
        try heading.appendChild(cx.allocator, try ui.spacer(cx));
        const heading_count = try ui.textStyled(cx, S.secondary, "");
        try heading.appendChild(cx.allocator, heading_count);
        try popup.content.appendChild(cx.allocator, heading);
        const scroll = try ui.widgets.ScrollArea(.{ .direction = .vertical }).mount(popup.scope, cx);
        scroll.container.setStyleInline(cx.allocator, .{ .width = .fill(), .height = .{ .fit = .{ .max = 252 } }, .max_height = 252, .min_height = 0 });
        scroll.content.setStyleInline(cx.allocator, .{ .width = .fill(), .direction = .column });
        scroll.container.meta.ownership.meta.test_id = "ai.children.list";
        try popup.content.appendChild(cx.allocator, scroll.container);
        // 占位节点：banner 插在 content 顶部（heading 之后）；self 创建后再填
        // 充按钮与文案（V0.7 §12.2/§14.4 停滞警示条）。
        const banner_placeholder = try ui.box(cx, .{}, .{});
        banner_placeholder.setDisplay(.none);
        banner_placeholder.meta.ownership.meta.test_id = "ai.children.stall";
        try popup.content.insertChildBefore(cx.allocator, banner_placeholder, scroll.container);
        // V0.7 §14: page tab row below the banner; page bodies follow the
        // member list (all share the G3/G8 sources). Tabs beyond the member
        // list appear only when delegated children exist.
        const tab_row = try ui.box(cx, .{ .width = .fill(), .height = .{ .px = 28 }, .direction = .row, .align_items = .center, .gap = 6, .flex_shrink = 0 }, .{});
        tab_row.meta.ownership.meta.test_id = "ai.children.tabs";
        try popup.content.insertChildBefore(cx.allocator, tab_row, scroll.container);
        const board_list_placeholder = try ui.box(cx, .{ .width = .fill(), .direction = .column, .gap = 4 }, .{});
        board_list_placeholder.setDisplay(.none);
        try popup.content.appendChild(cx.allocator, board_list_placeholder);
        const graph_canvas_placeholder = try ui.box(cx, .{ .width = .fill(), .height = .{ .px = 220 }, .flex_shrink = 0 }, .{});
        graph_canvas_placeholder.setDisplay(.none);
        try popup.content.appendChild(cx.allocator, graph_canvas_placeholder);
        const rounds_list_placeholder = try ui.box(cx, .{ .width = .fill(), .direction = .column, .gap = 6 }, .{});
        rounds_list_placeholder.setDisplay(.none);
        try popup.content.appendChild(cx.allocator, rounds_list_placeholder);
        const badge = try Header.mountCountBadge(cx, button, "ai.children.count");
        const self = try scope.createState(View, .{ .cx = cx, .scope = popup.scope, .hooks = hooks, .open = open, .root = popup.wrapper, .content = scroll.content, .chrome = popup.chrome, .painted_colors = theme.current(), .button = button, .badge = badge, .heading_count = heading_count, .stall_banner = banner_placeholder, .board_list = board_list_placeholder, .graph_canvas = graph_canvas_placeholder, .rounds_list = rounds_list_placeholder });
        // V0.7 §12.2/§14.4: level-2 stall banner. Hidden until the host
        // escalates; carries the 催父/停全部 one-click actions.
        const banner_text = try ui.textStyled(cx, S.name, "集群停滞：父任务长时间无动作");
        banner_text.setStyleInline(cx.allocator, .{ .font_size = 12, .font_weight = 600 });
        try banner_placeholder.appendChild(cx.allocator, banner_text);
        const banner_actions = try ui.box(cx, .{ .direction = .row, .gap = 8, .width = .fill(), .flex_shrink = 0 }, .{});
        const urge = try ui.widgets.Button(.{ .label = "催父", .variant = .secondary, .on_click = cx.on(View, self, urgeParent) }).mount(popup.scope, cx);
        urge.meta.ownership.meta.test_id = "ai.children.stall.urge";
        try banner_actions.appendChild(cx.allocator, urge);
        const stop = try ui.widgets.Button(.{ .label = "停全部", .variant = .secondary, .on_click = cx.on(View, self, stopAll) }).mount(popup.scope, cx);
        stop.meta.ownership.meta.test_id = "ai.children.stall.stop";
        try banner_actions.appendChild(cx.allocator, stop);
        banner_placeholder.setStyleInline(cx.allocator, .{ .width = .fill(), .direction = .column, .gap = 6, .padding = ui.Padding.all(10), .border = .{ .width = 1, .radius = 8 }, .flex_shrink = 0 });
        try banner_placeholder.appendChild(cx.allocator, banner_actions);
        // V0.7 §14: page tabs (members always; Board/Graph/Rounds appear with
        // delegated children — setPages toggles their display).
        self.tab_members = try View.mountTab(cx, popup.scope, self, "成员", "ai.children.tab.members", .members);
        self.tab_board = try View.mountTab(cx, popup.scope, self, "Board", "ai.children.tab.board", .board);
        self.tab_graph = try View.mountTab(cx, popup.scope, self, "Graph", "ai.children.tab.graph", .graph);
        self.tab_rounds = try View.mountTab(cx, popup.scope, self, "Rounds", "ai.children.tab.rounds", .rounds);
        try tab_row.appendChild(cx.allocator, self.tab_members.?);
        try tab_row.appendChild(cx.allocator, self.tab_board.?);
        try tab_row.appendChild(cx.allocator, self.tab_graph.?);
        try tab_row.appendChild(cx.allocator, self.tab_rounds.?);
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
    pub fn setStallEscalated(self: *View, escalated: bool) void {
        const banner = self.stall_banner orelse return;
        banner.setDisplay(if (escalated) .flex else .none);
    }
    fn mountTab(cx: *ui.Cx, tab_scope: *ui.Scope, view: *View, label: []const u8, test_id: []const u8, page: Page) !*ui.Node {
        const state = try tab_scope.createState(TabPick, .{ .view = view, .page = page });
        const tab_button = try ui.widgets.Button(.{ .label = label, .variant = .ghost, .on_click = cx.on(TabPick, state, TabPick.choose) }).mount(tab_scope, cx);
        tab_button.meta.ownership.meta.test_id = test_id;
        return tab_button;
    }
    /// V0.7 §14: select the panel page (three-way mutual exclusion).
    fn selectPage(self: *View, page: Page) void {
        if (self.page == page) return;
        self.page = page;
        self.applyPageVisibility();
        self.fingerprint = 0;
        self.board_fingerprint = 0;
        self.graph_fingerprint = 0;
        self.rounds_fingerprint = 0;
        self.cx.requestRedraw();
    }
    /// Board/Graph/Rounds pages exist only with delegated children; in the
    /// ordinary mode the tabs stay hidden and the member list is the panel
    /// (§14.1: 普通模式无 Graph).
    pub fn setPagesAvailable(self: *View, children: usize) void {
        const available = children != 0;
        for ([_]?*ui.Node{ self.tab_board, self.tab_graph, self.tab_rounds }) |maybe| {
            if (maybe) |tab| tab.setDisplay(if (available) .flex else .none);
        }
        if (!available and self.page != .members) self.selectPage(.members);
    }
    fn applyPageVisibility(self: *View) void {
        const members = self.page == .members;
        if (self.board_list) |node| node.setDisplay(if (self.page == .board) .flex else .none);
        if (self.graph_canvas) |node| node.setDisplay(if (self.page == .graph) .flex else .none);
        if (self.rounds_list) |node| node.setDisplay(if (self.page == .rounds) .flex else .none);
        // The member scroll stays mounted; other pages overlay-hide it.
        if (self.rows_scope != null or members) {
            for (self.rows.items) |row| row.node.setDisplay(if (members) .flex else .none);
        }
        if (self.tab_members) |tab| {
            if (tab.behavior.interaction.a11y) |*a11y| a11y.pressed = members;
        }
    }
    /// V0.7 §10.2: render the Auto-upgrade decision timeline at the top of
    /// the Board page (explainable: why a request ran in parallel).
    pub fn updateDecisions(self: *View, rows: []const projection.DecisionRow) !void {
        const list = self.board_list orelse return;
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
            var label: [128]u8 = undefined;
            const head = try std.fmt.bufPrint(&label, "升级判定 · {s}", .{row.reason[0..@min(row.reason.len, 96)]});
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
        hash.update(if (self.board_filter_member) |member| &.{@as(u8, 1), @intCast(member)} else &.{@as(u8, 0)});
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
        // Rebuild the board page content.
        while (list.children.items.len != 0) {
            const child = list.children.items[0];
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
        if (shown == 0) try list.appendChild(self.cx.allocator, try ui.textStyled(self.cx, S.secondary, if (rows.len == 0) "留言板暂无帖子" else "当前筛选无匹配帖子"));
        _ = try self.mountBoardFilter(list);
    }
    /// §14.2: the filter row (仅看 ask toggle + member reset) rides the top
    /// of the Board page. Mounted dynamically after each rebuild.
    fn mountBoardFilter(self: *View, list: *ui.Node) !void {
        const state = try self.scope.createState(BoardFilterPick, .{ .view = self });
        const row = try ui.box(self.cx, .{ .width = .fill(), .direction = .row, .align_items = .center, .gap = 8, .padding = .{ .top = 4, .bottom = 4 }, .flex_shrink = 0 }, .{});
        row.meta.ownership.meta.test_id = "ai.children.board.filters";
        const ask = try ui.widgets.Button(.{ .label = if (self.board_filter_ask_only) "✓ 仅看 ask/answer" else "仅看 ask/answer", .variant = .ghost, .on_click = self.cx.on(BoardFilterPick, state, BoardFilterPick.toggleAsk) }).mount(self.scope, self.cx);
        ask.meta.ownership.meta.test_id = "ai.children.board.filter.ask";
        try row.appendChild(self.cx.allocator, ask);
        if (self.board_filter_member != null) {
            const reset = try ui.widgets.Button(.{ .label = "清除成员筛选", .variant = .ghost, .on_click = self.cx.on(BoardFilterPick, state, BoardFilterPick.resetMember) }).mount(self.scope, self.cx);
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
    /// V0.7 §14.2 Graph: deterministic radial layout — parent centered,
    /// children on a fixed ring (≤16, no physics). Node cards reuse the G3
    /// rows; edges are the accumulated board traffic (width by volume).
    pub fn updateGraph(self: *View, entries: []const projection.Entry, posts: []const projection.BoardRow) !void {
        const canvas = self.graph_canvas orelse return;
        var hash = std.hash.Wyhash.init(0);
        for (entries) |entry| {
            std.hash.autoHash(&hash, entry.seq);
            hash.update(entry.status);
            hash.update(entry.name);
        }
        // §14.2 edges: board post accumulation between parent and member
        // (width 1/2/4px by volume, accent translucent).
        for (posts) |post| std.hash.autoHash(&hash, post.origin);
        const stamp = hash.final();
        const visible = entries.len > 1;
        if (stamp == self.graph_fingerprint) return;
        self.graph_fingerprint = stamp;
        while (canvas.children.items.len != 0) {
            const child = canvas.children.items[0];
            self.cx.detachChild(canvas, child);
            self.cx.destroyDetached(child);
        }
        if (!visible) {
            // §14.2: ≤1 active child hides the Graph page.
            return;
        }
        // Fixed ring coordinates: radius scaled to the canvas, angles even.
        const center_x: f32 = 200;
        const center_y: f32 = 110;
        const radius: f32 = 80;
        for (entries[0..@min(entries.len, 16)], 0..) |entry, index| {
            const angle = 2 * std.math.pi * @as(f32, @floatFromInt(index)) / @as(f32, @floatFromInt(@min(entries.len, 16)));
            const x = center_x + radius * @cos(angle) - 50;
            const y = center_y + radius * @sin(angle) - 16;
            const node = try ui.box(self.cx, .{ .position = .absolute, .inset = .{ .left = .{ .px = x }, .top = .{ .px = y } }, .width = .{ .px = 100 }, .height = .{ .px = 32 }, .direction = .row, .align_items = .center, .gap = 4, .border = .{ .width = 1, .radius = 8 }, .padding = ui.Padding.all(6) }, .{});
            try node.appendChild(self.cx.allocator, try ui.textStyled(self.cx, S.secondary, if (entry.seq != 0) try std.fmt.allocPrint(self.cx.allocator, "#{d} {s}", .{ entry.seq, entry.name }) else entry.name));
            try canvas.appendChild(self.cx.allocator, node);
        }
        const parent_node = try ui.box(self.cx, .{ .position = .absolute, .inset = .{ .left = .{ .px = center_x - 40 }, .top = .{ .px = center_y - 16 } }, .width = .{ .px = 80 }, .height = .{ .px = 32 }, .align_items = .center, .justify = .center, .border = .{ .width = 1, .radius = 16 }, .flex_shrink = 0 }, .{});
        try parent_node.appendChild(self.cx.allocator, try ui.textStyled(self.cx, S.name, "父任务"));
        try canvas.appendChild(self.cx.allocator, parent_node);
        // Edges: per-member post volume draws a line from the ring node to
        // the parent. Simple axis-aligned segments (deterministic layout).
        for (entries[0..@min(entries.len, 16)], 0..) |entry, index| {
            var volume: usize = 0;
            for (posts) |post| if (post.origin == entry.seq) {
                volume += 1;
            };
            if (volume == 0) continue;
            const width: f32 = if (volume >= 4) 4 else if (volume >= 2) 2 else 1;
            const angle = 2 * std.math.pi * @as(f32, @floatFromInt(index)) / @as(f32, @floatFromInt(@min(entries.len, 16)));
            const node_x = center_x + radius * @cos(angle);
            const node_y = center_y + radius * @sin(angle);
            // Horizontal + vertical two-segment approximation toward center.
            const h_len = @abs(node_x - center_x);
            const h_x = @min(node_x, center_x);
            const horizontal = try ui.box(self.cx, .{ .position = .absolute, .inset = .{ .left = .{ .px = h_x }, .top = .{ .px = (node_y + center_y) / 2 } }, .width = .{ .px = h_len }, .height = .{ .px = width }, .background = theme.current().accent, .opacity = 0.35, .flex_shrink = 0 }, .{});
            try canvas.appendChild(self.cx.allocator, horizontal);
            const v_len = @abs(node_y - center_y);
            if (v_len > 0.5) {
                const v_y = @min(node_y, center_y);
                const vertical = try ui.box(self.cx, .{ .position = .absolute, .inset = .{ .left = .{ .px = node_x - width / 2 }, .top = .{ .px = v_y } }, .width = .{ .px = width }, .height = .{ .px = v_len }, .background = theme.current().accent, .opacity = 0.35, .flex_shrink = 0 }, .{});
                try canvas.appendChild(self.cx.allocator, vertical);
            }
        }
    }
    /// V0.7 §14.3 Rounds: boost chain rounds as a vertical timeline of node
    /// cards (seq/label/status/summary), with the final verification bar.
    pub fn updateRounds(self: *View, rows: []const projection.RoundRow) !void {
        const list = self.rounds_list orelse return;
        var hash = std.hash.Wyhash.init(0);
        for (rows) |row| {
            std.hash.autoHash(&hash, row.seq);
            hash.update(row.status);
            hash.update(row.summary);
        }
        const stamp = hash.final();
        if (stamp == self.rounds_fingerprint and list.children.items.len != 0) return;
        self.rounds_fingerprint = stamp;
        while (list.children.items.len != 0) {
            const child = list.children.items[0];
            self.cx.detachChild(list, child);
            self.cx.destroyDetached(child);
        }
        if (rows.len == 0) {
            try list.appendChild(self.cx.allocator, try ui.textStyled(self.cx, S.secondary, "暂无轮次记录"));
            return;
        }
        for (rows) |row| {
            var title: [96]u8 = undefined;
            const card = try ui.box(self.cx, .{ .width = .fill(), .direction = .column, .gap = 2, .padding = ui.Padding.all(8), .border = .{ .width = 1, .radius = 8 }, .flex_shrink = 0 }, .{});
            try card.appendChild(self.cx.allocator, try ui.textStyled(self.cx, S.name, try std.fmt.bufPrint(&title, "第 {d} 轮 · #{d} {s} · {s}", .{ row.round + 1, row.seq, if (row.label.len != 0) row.label else "", row.status })));
            if (row.summary.len != 0) try card.appendChild(self.cx.allocator, try ui.textStyled(self.cx, S.secondary, row.summary[0..@min(row.summary.len, 120)]));
            try list.appendChild(self.cx.allocator, card);
        }
        const verify = try ui.box(self.cx, .{ .width = .fill(), .direction = .row, .align_items = .center, .gap = 6, .padding = ui.Padding.all(8), .border = .{ .width = 1, .radius = 8 }, .flex_shrink = 0 }, .{});
        verify.meta.ownership.meta.test_id = "ai.children.rounds.verify";
        try verify.appendChild(self.cx.allocator, try ui.textStyled(self.cx, S.secondary, "父终验：进行中"));
        try list.appendChild(self.cx.allocator, verify);
    }
        fn urgeParent(self: *View) void {
        if (self.hooks.urge_parent) |urge| urge(self.hooks.context);
    }
    fn stopAll(self: *View) void {
        if (self.hooks.stop_all) |stop| stop(self.hooks.context);
    }
    pub fn update(self: *View, entries: []const projection.Entry) !void {
        return self.updateWithCount(entries, null);
    }
    /// Historical lists may show another parent's children. The header badge
    /// continues to describe only the currently displayed main conversation.
    pub fn updateWithCount(self: *View, entries: []const projection.Entry, running_count: ?usize) !void {
        if (!std.meta.eql(self.painted_colors, theme.current())) {
            self.painted_colors = theme.current();
            self.chrome.setStyleInline(self.cx.allocator, S.popup(self.cx.tokens));
            Header.repaintCountBadge(self.cx, self.badge);
            for (self.rows.items) |row| row.repaint();
        }
        var count: usize = 0;
        var hash = std.hash.Wyhash.init(0);
        for (entries) |entry| {
            count += @intFromBool(entry.running);
            std.hash.autoHash(&hash, .{ entry.agent, entry.revision, entry.group, entry.running, entry.reusable, entry.changed_at_ms });
            hash.update(entry.name);
            hash.update(entry.status);
            hash.update(entry.summary);
        }
        // V0.7 §14.1 计数口径: "运行中"仅含执行中与等待用户任务；排队等
        // 模型槽的任务单独计入徽标——徽标即待审批子任务数（§14.4 红点）。
        var waiting_approval: usize = 0;
        for (entries) |entry| {
            if (entry.status.len >= 12 and std.mem.eql(u8, entry.status[0..12], "等待用户")) waiting_approval += 1;
        }
        count = running_count orelse count;
        var count_buffer: [64]u8 = undefined;
        const count_label = if (waiting_approval != 0)
            try std.fmt.bufPrint(&count_buffer, "{d} 个运行中 · {d} 待审批", .{ count, waiting_approval })
        else
            try std.fmt.bufPrint(&count_buffer, "{d} 个运行中", .{count});
        if (!sameText(self.heading_count, count_label)) try self.heading_count.setTextContent(self.cx.allocator, count_label);
        const label = try std.fmt.bufPrint(&self.a11y_label, "子智能体，{d} 个运行中，{d} 个等待用户", .{ count, waiting_approval });
        if (self.button.behavior.interaction.a11y) |*a11y| a11y.label = label;
        try Header.updateCountBadge(self.cx, self.badge, waiting_approval);
        if (!self.open.peek()) {
            self.fingerprint = 0;
            return;
        }
        const stamp = hash.final();
        if (stamp == self.fingerprint) return;
        // While the list is open retain row nodes/order so a press cannot land
        // on a different Agent. The next open applies the latest grouped sort.
        if (self.rows.items.len != 0 and self.fingerprint != 0) {
            for (self.rows.items) |row| {
                row.node.setDisplay(.none);
                for (entries) |entry| if (row.agent.eql(entry.agent)) {
                    row.node.setDisplay(.flex);
                    try row.update(entry);
                    break;
                };
            }
            self.fingerprint = stamp;
            return;
        }
        if (self.rows_scope) |old| old.dispose();
        self.rows.clearRetainingCapacity();
        self.rows_scope = try self.scope.childScope();
        const scope = self.rows_scope.?;
        while (self.content.children.items.len != 0) {
            const node = self.content.children.items[0];
            self.cx.detachChild(self.content, node);
            self.cx.destroyDetached(node);
        }
        if (entries.len == 0) try self.content.appendChild(self.cx.allocator, try ui.textStyled(self.cx, S.secondary, "暂无子智能体"));
        var group: ?projection.Group = null;
        for (entries) |entry| {
            if (group != entry.group) {
                const header = try ui.textStyled(self.cx, S.secondary, switch (entry.group) {
                    .attention => "待处理",
                    .active => "进行中",
                    .recent => "最近结束",
                });
                header.setStyleInline(self.cx.allocator, .{ .padding = .{ .left = 52, .right = 8, .top = 8, .bottom = 4 }, .flex_shrink = 0 });
                try self.content.appendChild(self.cx.allocator, header);
                group = entry.group;
            }
            const row = try scope.createState(Row, .{ .view = self, .agent = entry.agent, .revision = entry.revision, .node = undefined, .name = undefined, .detail = undefined, .status = undefined, .spinner = undefined, .spinner_color = try scope.createSignal(?ui.Color, theme.current().accent) });
            const node = try ui.widgets.Button(.{ .variant = .ghost, .a11y_label = entry.name, .base_style = ui.BoxStyle{ .width = .fill(), .height = .{ .px = 60 }, .direction = .row, .justify = .start, .align_items = .center, .padding = ui.Padding.all(10), .gap = 10, .flex_shrink = 0, .border = .{ .radius = 8 } }, .on_click = self.cx.on(Row, row, Row.select) }).mount(scope, self.cx);
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
        self.fingerprint = stamp;
    }
    fn sameText(node: *ui.Node, value: []const u8) bool {
        return if (node.getText()) |text| std.mem.eql(u8, text.content, value) else false;
    }
    const Row = struct {
        view: *View,
        agent: id.AgentId,
        revision: u64,
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
            // V0.7 §2.1: rows show the host display name "#N label".
            const display = if (entry.seq != 0)
                if (entry.name.len != 0)
                    try std.fmt.bufPrint(&self.display_name, "#{d} {s}", .{ entry.seq, entry.name })
                else
                    try std.fmt.bufPrint(&self.display_name, "#{d}", .{entry.seq})
            else
                entry.name;
            if (!View.sameText(self.name, display)) try self.name.setTextContent(self.view.cx.allocator, display);
            if (self.node.behavior.interaction.a11y) |*a11y| a11y.label = try std.fmt.bufPrint(&self.a11y_label, "{s}，{s}", .{ display, entry.status });
            self.status_text.set(entry.status);
            self.visual = if (entry.running) .running else if (std.mem.eql(u8, entry.status, "失败")) .failed else if (entry.group == .attention) .attention else if (entry.group == .active) .waiting else if (std.mem.eql(u8, entry.status, "已停止")) .stopped else .complete;
            self.repaint();
            var buf: [256]u8 = undefined;
            const seconds: i64 = if (entry.changed_at_ms > 0) @max(0, @divTrunc(@import("../platform/realtime.zig").milliseconds(undefined) - entry.changed_at_ms, 1000)) else 0;
            var summary_len = @min(entry.summary.len, 100);
            while (summary_len != 0 and summary_len < entry.summary.len and entry.summary[summary_len] & 0xc0 == 0x80) summary_len -= 1;
            // V0.7 §3.8: usage facts as established facts (no ledger).
            const detail = if (entry.requests != 0)
                try std.fmt.bufPrint(&buf, "{s}{s} · {d} 次请求 · {d} tokens · {d} 秒前", .{ if (entry.summary.len != 0) entry.summary[0..summary_len] else entry.status, if (entry.reusable) " · 可复用" else "", entry.requests, entry.tokens, seconds })
            else
                try std.fmt.bufPrint(&buf, "{s}{s} · {d} 秒前", .{ if (entry.summary.len != 0) entry.summary[0..summary_len] else entry.status, if (entry.reusable) " · 可复用" else "", seconds });
            if (!View.sameText(self.detail, detail)) try self.detail.setTextContent(self.view.cx.allocator, detail);
        }
        const Visual = enum { running, waiting, attention, failed, stopped, complete };
        fn repaint(self: *Row) void {
            Logo.repaint(self.logo, self.agent);
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
                .attention => "circle-help",
                .failed => "circle-alert",
                .stopped => "circle-stop",
                .complete => "circle-check",
            }).?;
            const tint = switch (self.visual) {
                .running => unreachable,
                .waiting => colors.accent,
                .attention => colors.warn,
                .failed => colors.danger,
                .stopped => colors.fg_2,
                .complete => colors.ok,
            };
            self.status.setIcon(.{ .icon_id = asset.icon_id.?, .rep = asset.pickRep(16).?, .tint = tint });
        }
        fn select(self: *Row) void {
            self.view.open.set(false);
            self.view.hooks.select(self.view.hooks.context, self.agent, self.revision);
        }
    };
};
