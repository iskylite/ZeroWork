//! One stable state/disclosure slot for live tools and provider thinking.
const std = @import("std");
const ui = @import("ui");
const theme = @import("app_theme.zig");
const S = @import("ai_tool_results_styles.zig");
const events = @import("../ai/step_events.zig");
pub const Props = struct {
    title: []const u8,
    projection: []const u8,
    projection_is_status: bool = false,
    tool_name: ?[]const u8 = null,
    tool_arguments: ?[]const u8 = null,
    decision: ?bool = null,
    detail: []const u8,
    detail_content: ?*ui.Node = null,
    copy_detail: bool = true,
    phase: events.Phase,
    elapsed_ms: u64,
    show_elapsed: bool = true,
    expanded: *bool,
    test_id: []const u8 = "ai.step",
    on_toggle: ?ui.Handler(void) = null,
    scroll_position: ?*@import("../ai/conversation_turn.zig").ThinkingScroll = null,
};
pub const Result = struct {
    root: *ui.Node,
    state: *State,
    pub fn update(self: Result, props: Props) !void {
        try self.state.update(props);
    }
    pub fn rebindExpanded(self: Result, expanded: *bool) void {
        self.state.props.expanded = expanded;
    }
};
fn setText(cx: *ui.Cx, node: *ui.Node, text: []const u8) !void {
    if (node.getText()) |old| if (std.mem.eql(u8, old.content, text)) return;
    try node.setTextContent(cx.allocator, text);
}
const State = struct {
    cx: *ui.Cx,
    props: Props,
    root: *ui.Node,
    body: *ui.Node,
    disclosure: *@import("layout_motion.zig").Disclosure,
    indicator: *@import("ai_step_disclosure.zig").Indicator,
    clock: *ui.Node,
    title: *ui.Node,
    title_value: *ui.Signal([]const u8),
    projection: *ui.Node,
    detail_text: *ui.Node,
    detail_value: *ui.Signal([]const u8),
    ticking: bool = false,
    mounted_ms: u64,
    last_tick_ms: u64 = 0,
    follow: ?@import("ai_tail_follow.zig").Follow = null,
    restore_scroll: bool = true,
    fn update(self: *State, props: Props) !void {
        if (self.props.scroll_position != props.scroll_position or self.props.detail_content != props.detail_content) return error.StepIdentityChanged;
        self.detail_value.set(props.detail);
        self.props = props;
        self.props.detail = self.detail_value.peek();
        self.mounted_ms = @intCast(@divTrunc(@import("../platform/realtime.zig").monotonicNs(), std.time.ns_per_ms));
        const title_text = if (props.tool_name) |name| try @import("ai_tool_titles.zig").action(self.cx.allocator, name, props.tool_arguments orelse props.projection) else try self.cx.allocator.dupe(u8, props.title);
        defer self.cx.allocator.free(title_text);
        self.title_value.set(title_text);
        if (self.indicator.header.behavior.interaction.a11y) |*attrs| attrs.label = self.title_value.peek();
        try setText(self.cx, self.title, title_text);
        const projection = @import("ai_tool_header_projection.zig");
        const text = if (props.projection_is_status) try self.cx.allocator.dupe(u8, props.projection) else if (props.tool_name) |name| try projection.projectWithStatus(self.cx.allocator, name, props.projection, projection.phaseLabel(props.phase)) else try projection.withStatus(self.cx.allocator, props.projection, projection.phaseLabel(props.phase));
        defer self.cx.allocator.free(text);
        try setText(self.cx, self.projection, text);
        const palette = theme.current();
        self.projection.setTextColor(if (props.phase == .failed or props.phase == .rejected) palette.warn else palette.fg_2);
        _ = self.indicator.activity.setTint(switch (props.phase) {
            .succeeded => palette.ok,
            .failed, .rejected => palette.warn,
            else => palette.fg_2,
        });
        if (props.expanded.* or props.copy_detail) try setText(self.cx, self.detail_text, self.props.detail);
        self.clock.setDisplay(if (props.show_elapsed) .flex else .none);
        var buffer: [32]u8 = undefined;
        try setText(self.cx, self.clock, if (props.phase == .approval) "待确认" else if (props.elapsed_ms < 1000) try std.fmt.bufPrint(&buffer, "{d}ms", .{props.elapsed_ms}) else try std.fmt.bufPrint(&buffer, "{d:.1}s", .{@as(f64, @floatFromInt(props.elapsed_ms)) / 1000}));
        const ticking = props.scroll_position != null or props.phase == .assembling or props.phase == .running or props.phase == .approval or props.phase == .approved;
        if (ticking and !self.ticking) try self.cx.addAfterLayoutHook(self, State.tick);
        if (!ticking and self.ticking) self.cx.removeAfterLayoutHook(self);
        self.ticking = ticking;
    }
    fn release(self: *State) void {
        self.rememberScroll();
        self.cx.removeAfterLayoutHook(self);
        if (self.props.scroll_position) |position| position.release();
    }
    fn rememberScroll(self: *State) void {
        if (self.restore_scroll) return;
        if (self.follow) |*follow| {
            // Nested scroll hand-off can move to an edge without incrementing
            // input_serial. Content growth itself never changes the offset.
            if (follow.scroll.state.input_serial != follow.input_serial or @abs(follow.scroll.state.scroll_y - self.props.scroll_position.?.offset) > 0.1) {
                follow.following = follow.scroll.state.scroll_y >= follow.scroll.state.maxScrollY() - 1;
                follow.input_serial = follow.scroll.state.input_serial;
            }
            self.props.scroll_position.?.following = follow.following;
            self.props.scroll_position.?.offset = follow.scroll.state.scroll_y;
        }
    }
    fn tick(raw: *anyopaque, _: u8, _: bool) ui.AfterLayoutResult {
        const self: *State = @ptrCast(@alignCast(raw));
        if (@import("material_geometry.zig").snapshot(self.cx, self.root) == null) return .done;
        if (self.props.expanded.*) if (self.follow) |*follow| {
            if (self.restore_scroll) {
                const content_height = follow.scroll.content.globalRect().h;
                const viewport_height = follow.scroll.container.globalRect().h;
                // The host can mount us inside its after-layout hook. Wait for
                // the new nodes' first layout before clamping a saved offset.
                if (content_height <= 0 or viewport_height <= 0) return .done;
                follow.scroll.state.content_height = content_height;
                follow.scroll.state.viewport_height = viewport_height;
                ui.widgets.setScrollY(follow.scroll.state, follow.scroll.content, self.props.scroll_position.?.offset);
                self.restore_scroll = false;
            }
            self.rememberScroll();
            follow.update();
            self.rememberScroll();
        };
        if (self.props.phase != .assembling and self.props.phase != .running and self.props.phase != .approved) return .done;
        const now: u64 = @intCast(@divTrunc(@import("../platform/realtime.zig").monotonicNs(), std.time.ns_per_ms));
        self.cx.scheduleRedrawAfterNs(100 * std.time.ns_per_ms);
        if (now -| self.last_tick_ms < 100) return .done;
        self.last_tick_ms = now;
        const elapsed = self.props.elapsed_ms +| (now -| self.mounted_ms);
        var buffer: [32]u8 = undefined;
        const value = if (elapsed < 1000) std.fmt.bufPrint(&buffer, "{d}ms", .{elapsed}) catch return .done else std.fmt.bufPrint(&buffer, "{d:.1}s", .{@as(f64, @floatFromInt(elapsed)) / 1000}) catch return .done;
        self.clock.setTextContent(self.cx.allocator, value) catch return .done;
        return .needs_layout;
    }
    fn toggle(self: *State) void {
        self.props.expanded.* = !self.props.expanded.*;
        if (self.props.expanded.*) setText(self.cx, self.detail_text, self.detail_value.peek()) catch {};
        self.disclosure.setExpanded(self.props.expanded.*);
        self.indicator.setExpanded(self.props.expanded.*);
        if (self.props.on_toggle) |callback| callback.invoke();
        self.cx.requestRedraw();
    }
};
pub fn mount(cx: *ui.Cx, scope: *ui.Scope, props: Props) !*ui.Node {
    return (try mountRetained(cx, scope, props)).root;
}
pub fn mountRetained(cx: *ui.Cx, scope: *ui.Scope, props: Props) !Result {
    const root = try ui.boxStyled(cx, S.card, .{});
    @import("layer_materials.zig").card(root, .action);
    root.setStyleInline(cx.allocator, .{ .height = .{ .fit = .{} } });
    root.meta.ownership.meta.test_id = props.test_id;
    const header = try ui.widgets.Button(.{ .variant = .ghost, .label = "", .a11y_label = props.title, .base_style = S.ButtonStyle{ .width = .fill(), .height = .{ .px = 32 }, .padding = .{ .left = 10, .right = 12 }, .gap = 6, .background = ui.Color.TRANSPARENT, .corner_radius = 9, .flex_shrink = 0 } }).mount(scope, cx);
    header.setStyleInline(cx.allocator, S.header(cx.tokens));
    header.meta.ownership.meta.test_id = "ai.step.header";
    for (header.children.items) |child| child.setDisplay(.none);
    const palette = theme.current();
    const indicator = try @import("ai_step_disclosure.zig").Indicator.mount(cx, scope, header, props.tool_name, switch (props.phase) {
        .succeeded => palette.ok,
        .failed, .rejected => palette.warn,
        else => palette.fg_2,
    }, props.expanded.*, "ai.step.status", "ai.step.disclosure");
    const action_title = if (props.tool_name) |name| try @import("ai_tool_titles.zig").action(cx.allocator, name, props.tool_arguments orelse props.projection) else try cx.allocator.dupe(u8, props.title);
    defer cx.allocator.free(action_title);
    const title_value = try scope.createText(action_title, .{});
    if (header.behavior.interaction.a11y) |*attrs| attrs.label = title_value.peek();
    const title_node = try ui.textStyled(cx, S.title, action_title);
    title_node.setStyleInline(cx.allocator, S.headerTitle(cx.tokens));
    title_node.meta.ownership.meta.test_id = "ai.step.title";
    try header.appendChild(cx.allocator, title_node);
    const separator = try ui.boxStyled(cx, S.headerSeparator, .{});
    separator.meta.ownership.meta.test_id = "ai.step.separator";
    try header.appendChild(cx.allocator, separator);
    const header_projection = @import("ai_tool_header_projection.zig");
    const status_label = header_projection.phaseLabel(props.phase);
    const projected = if (props.projection_is_status) try cx.allocator.dupe(u8, props.projection) else if (props.tool_name) |name| try header_projection.projectWithStatus(cx.allocator, name, props.projection, status_label) else try header_projection.withStatus(cx.allocator, props.projection, status_label);
    defer cx.allocator.free(projected);
    // The actual zenit text builder copies this temporary into node ownership.
    const projection = try ui.text(cx, projected, .{ .font_size = 10.5, .line_height = 16.0 / 10.5, .color = if (props.phase == .failed or props.phase == .rejected) palette.warn else palette.fg_2, .text_overflow = .ellipsis });
    projection.setStyleInline(cx.allocator, S.headerSummary(cx.tokens));
    projection.meta.ownership.meta.test_id = "ai.step.projection";
    try header.appendChild(cx.allocator, projection);
    var buf: [32]u8 = undefined;
    const elapsed = if (props.phase == .approval) "待确认" else if (props.elapsed_ms < 1000) try std.fmt.bufPrint(&buf, "{d}ms", .{props.elapsed_ms}) else try std.fmt.bufPrint(&buf, "{d:.1}s", .{@as(f64, @floatFromInt(props.elapsed_ms)) / 1000});
    const clock = try ui.textStyled(cx, S.elapsed, elapsed);
    clock.setStyleInline(cx.allocator, S.elapsedSlot(cx.tokens));
    clock.meta.ownership.meta.test_id = "ai.step.elapsed";
    if (!props.show_elapsed) clock.setDisplay(.none);
    try header.appendChild(cx.allocator, clock);
    try root.appendChild(cx.allocator, header);
    // Sibling scopes are disposed in creation order: save the position before
    // ScrollArea releases its state during a conversation rebuild.
    const state_scope = try scope.childScope();
    const scroll = try ui.widgets.ScrollArea(.{ .direction = .vertical }).mount(scope, cx);
    @import("ai_card_scroll.zig").containVertical(scroll);
    scroll.container.setStyleInline(cx.allocator, .{ .width = .fill(), .height = .{ .fit = .{ .max = 150 } }, .flex_shrink = 0 });
    scroll.content.setStyleInline(cx.allocator, S.content(cx.tokens));
    if (props.tool_name) |name| {
        if (props.detail_content == null and !std.mem.startsWith(u8, props.detail, "工具：")) {
            const tool_detail = try @import("ai_tool_titles.zig").detail(cx.allocator, name);
            defer cx.allocator.free(tool_detail);
            const tool = try ui.textStyled(cx, S.text, tool_detail);
            tool.meta.ownership.meta.test_id = "ai.step.tool_id";
            try scroll.content.appendChild(cx.allocator, tool);
        }
    }
    const detail_value = try scope.createText(props.detail, .{});
    const text = try ui.text(cx, if (props.expanded.* or props.copy_detail) props.detail else "", .{ .font_size = 11, .wrap = .word, .line_height = 16.0 / 11.0, .color = palette.fg_2 });
    try scroll.content.appendChild(cx.allocator, text);
    if (props.detail_content) |body| {
        text.setDisplay(.none);
        try scroll.content.appendChild(cx.allocator, body);
    }
    scroll.container.meta.ownership.meta.test_id = "ai.step.details";
    text.meta.ownership.meta.test_id = "ai.step.detail";
    if (props.copy_detail and props.detail.len > 0) {
        const copy = try scope.createState(Copy, .{ .cx = cx, .text = detail_value });
        copy.button = try @import("copy_button.zig").Button.mount(cx, scope, .{ .icon_only = true, .icon_asset = ui.icons.copy, .icon_size = 14, .a11y_label = "复制步骤详情", .variant = .ghost, .base_style = S.button(24), .on_click = cx.on(Copy, copy, Copy.run) });
        const copy_button = copy.button.node;
        copy_button.meta.ownership.meta.test_id = "ai.step.copy";
        const copy_hint = try @import("control_hint.zig").mount(cx, scope, copy_button, "复制步骤详情", .{ .id = "ai.step.copy.tooltip" });
        try scroll.content.appendChild(cx.allocator, copy_hint.wrapper);
    }
    try @import("ai_text_selection.zig").attach(cx, scope, scroll.content);
    const disclosure = try @import("layout_motion.zig").Disclosure.mount(cx, scope, scroll.container, props.expanded.*);
    try root.appendChild(cx.allocator, disclosure.root);
    const state = try state_scope.createState(State, .{ .cx = cx, .props = props, .root = root, .body = scroll.container, .disclosure = disclosure, .indicator = indicator, .clock = clock, .title = title_node, .title_value = title_value, .projection = projection, .detail_text = text, .detail_value = detail_value, .mounted_ms = @intCast(@divTrunc(@import("../platform/realtime.zig").monotonicNs(), std.time.ns_per_ms)), .follow = if (props.scroll_position) |position| .{ .scroll = scroll, .following = position.following } else null });
    state.props.detail = detail_value.peek();
    try state_scope.onCleanup(State, state, State.release);
    if (props.scroll_position) |position| position.retain();
    if (props.scroll_position != null or props.phase == .assembling or props.phase == .running or props.phase == .approval or props.phase == .approved) {
        try cx.addAfterLayoutHook(state, State.tick);
        state.ticking = true;
    }
    _ = ui.clickable(header, cx.on(State, state, State.toggle));
    return .{ .root = root, .state = state };
}
const Copy = struct {
    cx: *ui.Cx,
    text: *ui.Signal([]const u8),
    button: *@import("copy_button.zig").Button = undefined,
    fn run(self: *Copy) void {
        self.button.copy(self.text.peek());
    }
};
pub fn title(name: []const u8) []const u8 {
    return @import("ai_tool_titles.zig").title(name) orelse "工具调用";
}
