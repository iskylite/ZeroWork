//! Aggregates existing step cards without changing their content or disclosure.
const std = @import("std");
const ui = @import("ui");
const S = @import("ai_step_group_styles.zig");
const theme = @import("app_theme.zig");
const groups = @import("../ai/step_groups.zig");
const events = @import("../ai/step_events.zig");
const motion = @import("layout_motion.zig");
pub const Props = struct {
    group: *groups.State,
    title: []const u8,
    projection: []const u8,
    tool_name: ?[]const u8 = null,
    step_count: ?usize = null,
    phase: events.Phase,
    elapsed_ms: u64,
    live: bool = false,
    on_toggle: ?ui.Handler(void) = null,
};
pub const Result = struct { root: *ui.Node, content: *ui.Node };
const State = struct {
    cx: *ui.Cx,
    props: Props,
    disclosure: *motion.Disclosure,
    indicator: *@import("ai_step_disclosure.zig").Indicator,
    clock: *ui.Node,
    mounted_ms: u64,
    last_tick_ms: u64 = 0,
    fn toggle(self: *State) void {
        self.props.group.expanded = !self.props.group.expanded;
        self.disclosure.setExpanded(self.props.group.expanded);
        self.indicator.setExpanded(self.props.group.expanded);
        if (self.props.on_toggle) |callback| callback.invoke();
        self.cx.requestRedraw();
    }
    fn cleanup(self: *State) void {
        self.cx.removeAfterLayoutHook(self);
        self.props.group.release();
    }
    fn tick(raw: *anyopaque, _: u8, _: bool) ui.AfterLayoutResult {
        const self: *State = @ptrCast(@alignCast(raw));
        const now = monotonicMs();
        self.cx.scheduleRedrawAfterNs(100 * std.time.ns_per_ms);
        if (now -| self.last_tick_ms < 100) return .done;
        self.last_tick_ms = now;
        var buffer: [32]u8 = undefined;
        const value = elapsed(&buffer, self.props.elapsed_ms +| (now -| self.mounted_ms)) catch return .done;
        self.clock.setTextContent(self.cx.allocator, value) catch return .done;
        return .needs_layout;
    }
};
fn monotonicMs() u64 {
    return @intCast(@divTrunc(@import("../platform/realtime.zig").monotonicNs(), std.time.ns_per_ms));
}
fn elapsed(buffer: []u8, ms: u64) ![]const u8 {
    return if (ms < 1000) std.fmt.bufPrint(buffer, "{d}ms", .{ms}) else std.fmt.bufPrint(buffer, "{d:.1}s", .{@as(f64, @floatFromInt(ms)) / 1000});
}
pub fn mount(cx: *ui.Cx, scope: *ui.Scope, props: Props) !Result {
    const root = try ui.boxStyled(cx, S.root, .{});
    root.meta.ownership.meta.test_id = "ai.step_group";
    const header = try ui.widgets.Button(.{ .variant = .ghost, .label = "", .a11y_label = try scope.createText(props.title, .{}), .base_style = S.steps.ButtonStyle{ .width = .fill(), .height = .{ .px = 32 }, .padding = .{ .left = 10, .right = 12 }, .gap = 6, .background = theme.popupAction(), .corner_radius = 9, .flex_shrink = 0 } }).mount(scope, cx);
    header.setStyleInline(cx.allocator, S.header(cx.tokens));
    header.meta.ownership.meta.test_id = "ai.step_group.header";
    for (header.children.items) |child| child.setDisplay(.none);
    const palette = theme.current();
    const indicator = try @import("ai_step_disclosure.zig").Indicator.mount(cx, scope, header, props.tool_name, if (props.phase == .failed or props.phase == .rejected) palette.warn else if (props.phase == .succeeded) palette.ok else palette.fg_2, props.group.expanded, "ai.step_group.status", "ai.step_group.disclosure");
    const title = try ui.textStyled(cx, S.steps.title, props.title);
    title.setStyleInline(cx.allocator, S.steps.headerTitle(cx.tokens));
    title.meta.ownership.meta.test_id = "ai.step_group.title";
    try header.appendChild(cx.allocator, title);
    try header.appendChild(cx.allocator, try ui.boxStyled(cx, S.steps.headerSeparator, .{}));
    const summary = try ui.boxStyled(cx, S.summary, .{});
    summary.meta.ownership.meta.test_id = "ai.step_group.summary";
    const header_projection = @import("ai_tool_header_projection.zig");
    const status_label = if (props.phase == .failed) "有步骤失败" else if (props.phase == .rejected) "有步骤被拒绝" else if (props.phase == .cancelled) "有步骤取消" else header_projection.phaseLabel(props.phase);
    const projected = try header_projection.withStatus(cx.allocator, props.projection, status_label);
    defer cx.allocator.free(projected);
    if (props.step_count) |count| {
        var count_buffer: [64]u8 = undefined;
        const label = try ui.text(cx, try std.fmt.bufPrint(&count_buffer, "{d} 个步骤", .{count}), .{ .font_size = 10.5, .line_height = 16.0 / 10.5, .color = palette.fg_2 });
        label.setStyleInline(cx.allocator, S.count(cx.tokens));
        label.meta.ownership.meta.test_id = "ai.step_group.count";
        try summary.appendChild(cx.allocator, label);
        try summary.appendChild(cx.allocator, try ui.boxStyled(cx, S.steps.headerSeparator, .{}));
    }
    const projection = try ui.text(cx, projected, .{ .font_size = 10.5, .line_height = 16.0 / 10.5, .color = if (props.phase == .failed or props.phase == .rejected) palette.warn else palette.fg_2, .text_overflow = .ellipsis });
    projection.setStyleInline(cx.allocator, S.steps.headerSummary(cx.tokens));
    projection.meta.ownership.meta.test_id = "ai.step_group.projection";
    try summary.appendChild(cx.allocator, projection);
    try header.appendChild(cx.allocator, summary);
    var buffer: [32]u8 = undefined;
    const clock = try ui.textStyled(cx, S.steps.elapsed, try elapsed(&buffer, props.elapsed_ms));
    clock.setStyleInline(cx.allocator, S.steps.elapsedSlot(cx.tokens));
    clock.meta.ownership.meta.test_id = "ai.step_group.elapsed";
    try header.appendChild(cx.allocator, clock);
    try root.appendChild(cx.allocator, header);
    const content = try ui.boxStyled(cx, S.content, .{});
    content.meta.ownership.meta.test_id = "ai.step_group.content";
    for ([_]bool{ false, true }) |bottom| {
        const edge = try ui.boxStyled(cx, S.edge, .{});
        edge.meta.ownership.meta.test_id = if (bottom) "ai.step_group.edge.bottom" else "ai.step_group.edge.top";
        edge.setStyleInline(cx.allocator, .{ .inset = if (bottom) .{ .left = .{ .px = 0 }, .bottom = .{ .px = 0 } } else .{ .left = .{ .px = 0 }, .top = .{ .px = 0 } } });
        edge.setHitTestVisible(false);
        try content.appendChild(cx.allocator, edge);
    }
    const disclosure = try motion.Disclosure.mount(cx, scope, content, props.group.expanded);
    try root.appendChild(cx.allocator, disclosure.root);
    const state = try scope.createState(State, .{ .cx = cx, .props = props, .disclosure = disclosure, .indicator = indicator, .clock = clock, .mounted_ms = monotonicMs() });
    props.group.retain();
    scope.onCleanup(State, state, State.cleanup) catch |err| {
        props.group.release();
        return err;
    };
    if (props.live) try cx.addAfterLayoutHook(state, State.tick);
    _ = ui.clickable(header, cx.on(State, state, State.toggle));
    return .{ .root = root, .content = content };
}
