//! One stable state/disclosure slot for live tools and provider thinking.
const std = @import("std");
const ui = @import("ui");
const theme = @import("app_theme.zig");
const S = @import("ai_tool_results_styles.zig");
const events = @import("../ai/step_events.zig");
pub const Props = struct {
    title: []const u8,
    projection: []const u8,
    detail: []const u8,
    copy_detail: bool = true,
    phase: events.Phase,
    elapsed_ms: u64,
    expanded: *bool,
    test_id: []const u8 = "ai.step",
    on_toggle: ?ui.Handler(void) = null,
    scroll_position: ?*@import("../ai/conversation_turn.zig").ThinkingScroll = null,
};
const State = struct {
    cx: *ui.Cx,
    props: Props,
    root: *ui.Node,
    body: *ui.Node,
    disclosure: *@import("layout_motion.zig").Disclosure,
    status: *ui.Node,
    chevron: *ui.Node,
    clock: *ui.Node,
    mounted_ms: u64,
    last_tick_ms: u64 = 0,
    follow: ?@import("ai_tail_follow.zig").Follow = null,
    restore_scroll: bool = true,
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
        if (self.props.phase != .assembling and self.props.phase != .running and self.props.phase != .approval and self.props.phase != .approved) return .done;
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
    fn hover(self: *State) void {
        self.status.setOpacityRaw(0);
        self.chevron.setOpacityRaw(1);
    }
    fn leave(self: *State) void {
        self.status.setOpacityRaw(1);
        self.chevron.setOpacityRaw(0);
    }
    fn toggle(self: *State) void {
        self.props.expanded.* = !self.props.expanded.*;
        self.disclosure.setExpanded(self.props.expanded.*);
        self.chevron.setTextContent(self.cx.allocator, if (self.props.expanded.*) "⌄" else "›") catch {};
        if (self.props.on_toggle) |callback| callback.invoke();
        self.cx.requestRedraw();
    }
};
pub fn mount(cx: *ui.Cx, scope: *ui.Scope, props: Props) !*ui.Node {
    const root = try ui.boxStyled(cx, S.card, .{});
    root.setStyleInline(cx.allocator, .{ .height = .{ .fit = .{} } });
    root.meta.ownership.meta.test_id = props.test_id;
    const header = try ui.widgets.Button(.{ .variant = .ghost, .label = "", .a11y_label = props.title, .base_style = S.ButtonStyle{ .width = .fill(), .height = .{ .px = 32 }, .padding = .{ .left = 10, .right = 12 }, .gap = 6, .background = ui.Color.TRANSPARENT, .corner_radius = 9, .flex_shrink = 0 } }).mount(scope, cx);
    header.setStyleInline(cx.allocator, S.header(cx.tokens));
    header.meta.ownership.meta.test_id = "ai.step.header";
    for (header.children.items) |child| child.setDisplay(.none);
    const slot = try ui.box(cx, .{ .width = .{ .px = 22 }, .height = .{ .px = 22 }, .flex_shrink = 0 }, .{});
    const palette = theme.current();
    const spinning = props.phase == .assembling or props.phase == .running or props.phase == .approved;
    const status = if (spinning) try ui.widgets.Spinner(.{ .size = 14, .stroke_width = 1.6, .color = palette.fg_2 }).mount(scope, cx) else try ui.iconTint(cx, switch (props.phase) {
        .succeeded => ui.icons.check,
        .approval => ui.icons.get("hand").?,
        .failed, .rejected => ui.icons.get("circle-alert").?,
        .cancelled => ui.icons.get("square").?,
        else => ui.icons.get("loader-circle").?,
    }, switch (props.phase) {
        .succeeded => palette.ok,
        .failed, .rejected => palette.warn,
        else => palette.fg_2,
    }, .{ .width = .{ .px = 14 }, .height = .{ .px = 14 } });
    status.meta.ownership.meta.test_id = if (spinning) "ai.step.spinner" else "ai.step.status";
    status.setStyleInline(cx.allocator, .{ .position = .absolute, .inset = .{ .left = .{ .px = 4 }, .top = .{ .px = 4 } } });
    const chevron = try ui.text(cx, if (props.expanded.*) "⌄" else "›", .{ .font_size = 16, .color = palette.fg_2 });
    chevron.setStyleInline(cx.allocator, .{ .position = .absolute, .inset = .{ .left = .{ .px = 4 }, .top = .{ .px = 0 } }, .width = .{ .px = 14 }, .height = .{ .px = 22 } });
    chevron.setOpacityRaw(0);
    try slot.appendChild(cx.allocator, status);
    try slot.appendChild(cx.allocator, chevron);
    try header.appendChild(cx.allocator, slot);
    const title_node = try ui.textStyled(cx, S.title, props.title);
    title_node.setStyleInline(cx.allocator, .{ .width = .{ .fit = .{} }, .max_width = 128, .height = .{ .px = 18 }, .flex_shrink = 0 });
    title_node.meta.ownership.meta.test_id = "ai.step.title";
    try header.appendChild(cx.allocator, title_node);
    const projection = try ui.text(cx, props.projection, .{ .font_size = 10.5, .line_height = 16.0 / 10.5, .color = palette.fg_2, .text_overflow = .ellipsis });
    projection.setStyleInline(cx.allocator, S.headerSummary(cx.tokens));
    projection.meta.ownership.meta.test_id = "ai.step.projection";
    try header.appendChild(cx.allocator, projection);
    var buf: [32]u8 = undefined;
    const elapsed = if (props.elapsed_ms < 1000) try std.fmt.bufPrint(&buf, "{d}ms", .{props.elapsed_ms}) else try std.fmt.bufPrint(&buf, "{d:.1}s", .{@as(f64, @floatFromInt(props.elapsed_ms)) / 1000});
    const clock = try ui.textStyled(cx, S.elapsed, elapsed);
    clock.setStyleInline(cx.allocator, S.elapsedSlot(cx.tokens));
    clock.meta.ownership.meta.test_id = "ai.step.elapsed";
    try header.appendChild(cx.allocator, clock);
    try root.appendChild(cx.allocator, header);
    // Sibling scopes are disposed in creation order: save the position before
    // ScrollArea releases its state during a conversation rebuild.
    const state_scope = try scope.childScope();
    const scroll = try ui.widgets.ScrollArea(.{ .direction = .vertical }).mount(scope, cx);
    scroll.container.setStyleInline(cx.allocator, .{ .width = .fill(), .height = .{ .fit = .{ .max = 150 } }, .flex_shrink = 0 });
    scroll.content.setStyleInline(cx.allocator, S.content(cx.tokens));
    const text = try ui.text(cx, props.detail, .{ .font_size = 11, .wrap = .word, .line_height = 16.0 / 11.0, .color = palette.fg_2 });
    try scroll.content.appendChild(cx.allocator, text);
    scroll.container.meta.ownership.meta.test_id = "ai.step.details";
    text.meta.ownership.meta.test_id = "ai.step.detail";
    if (props.copy_detail and props.detail.len > 0) {
        const copy = try scope.createState(Copy, .{ .cx = cx, .text = try scope.createText(props.detail, .{}) });
        const copy_button = try ui.widgets.Button(.{ .label = "复制", .variant = .ghost, .on_click = cx.on(Copy, copy, Copy.run) }).mount(scope, cx);
        copy_button.meta.ownership.meta.test_id = "ai.step.copy";
        try scroll.content.appendChild(cx.allocator, copy_button);
    }
    const disclosure = try @import("layout_motion.zig").Disclosure.mount(cx, scope, scroll.container, props.expanded.*);
    try root.appendChild(cx.allocator, disclosure.root);
    const state = try state_scope.createState(State, .{ .cx = cx, .props = props, .root = root, .body = scroll.container, .disclosure = disclosure, .status = status, .chevron = chevron, .clock = clock, .mounted_ms = @intCast(@divTrunc(@import("../platform/realtime.zig").monotonicNs(), std.time.ns_per_ms)), .follow = if (props.scroll_position) |position| .{ .scroll = scroll, .following = position.following } else null });
    if (props.scroll_position != null or props.phase == .assembling or props.phase == .running or props.phase == .approval or props.phase == .approved) {
        try cx.addAfterLayoutHook(state, State.tick);
        try state_scope.onCleanup(State, state, State.release);
        if (props.scroll_position) |position| position.retain();
    }
    _ = ui.clickable(header, cx.on(State, state, State.toggle));
    const hovered = try ui.hooks.useHover(scope, header);
    const focused = try ui.hooks.useFocusState(scope, cx, header);
    try scope.createEffect(.{ .hovered = hovered, .focused = focused.visible, .state = state }, struct {
        fn run(ctx: anytype) void {
            if (ctx.hovered.get() or ctx.focused.get()) ctx.state.hover() else ctx.state.leave();
        }
    }.run);
    return root;
}
const Copy = struct {
    cx: *ui.Cx,
    text: *ui.Signal([]const u8),
    fn run(self: *Copy) void {
        _ = ui.platform_services.clipboardSetText(self.cx.system_sdk, self.text.peek());
    }
};
pub fn title(name: []const u8) []const u8 {
    if (@import("ai_tool_titles.zig").title(name)) |label| return label;
    if (std.mem.eql(u8, name, "run_command")) return "执行命令";
    if (std.mem.eql(u8, name, "read_terminal")) return "读取终端";
    if (std.mem.eql(u8, name, "read_remote_file")) return "读取远程文件";
    if (std.mem.eql(u8, name, "list_remote_files")) return "列出远程文件";
    return name;
}
