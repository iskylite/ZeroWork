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
};
const State = struct {
    cx: *ui.Cx,
    props: Props,
    root: *ui.Node,
    body: *ui.Node,
    status: *ui.Node,
    chevron: *ui.Node,
    clock: *ui.Node,
    mounted_ms: u64,
    last_tick_ms: u64 = 0,
    fn release(self: *State) void {
        self.cx.removeAfterLayoutHook(self);
    }
    fn tick(raw: *anyopaque, _: u8, _: bool) ui.AfterLayoutResult {
        const self: *State = @ptrCast(@alignCast(raw));
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
        self.body.setDisplay(if (self.props.expanded.*) .flex else .none);
        self.chevron.setTextContent(self.cx.allocator, if (self.props.expanded.*) "⌄" else "›") catch {};
        if (self.props.on_toggle) |callback| callback.invoke();
        self.cx.requestRedraw();
    }
};
pub fn mount(cx: *ui.Cx, scope: *ui.Scope, props: Props) !*ui.Node {
    const root = try ui.boxStyled(cx, S.card, .{});
    root.setStyleInline(cx.allocator, .{ .height = .{ .fit = .{} }, .background = theme.current().surface_1 });
    root.meta.ownership.meta.test_id = props.test_id;
    const header = try ui.widgets.Button(.{ .variant = .ghost, .label = "", .a11y_label = props.title, .base_style = S.ButtonStyle{ .width = .fill(), .height = .{ .px = 32 }, .padding = .{ .left = 10, .right = 12 }, .gap = 6, .background = ui.Color.TRANSPARENT, .corner_radius = 9, .flex_shrink = 0 } }).mount(scope, cx);
    header.setStyleInline(cx.allocator, .{ .justify = .start });
    for (header.children.items) |child| child.setDisplay(.none);
    const slot = try ui.box(cx, .{ .width = .{ .px = 22 }, .height = .{ .px = 22 }, .flex_shrink = 0 }, .{});
    const palette = theme.current();
    const status = try ui.iconTint(cx, switch (props.phase) {
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
    status.setStyleInline(cx.allocator, .{ .position = .absolute, .inset = .{ .left = .{ .px = 4 }, .top = .{ .px = 4 } } });
    const chevron = try ui.text(cx, if (props.expanded.*) "⌄" else "›", .{ .font_size = 16, .color = palette.fg_2 });
    chevron.setStyleInline(cx.allocator, .{ .position = .absolute, .inset = .{ .left = .{ .px = 4 }, .top = .{ .px = 0 } }, .width = .{ .px = 14 }, .height = .{ .px = 22 } });
    chevron.setOpacityRaw(0);
    try slot.appendChild(cx.allocator, status);
    try slot.appendChild(cx.allocator, chevron);
    try header.appendChild(cx.allocator, slot);
    const title_node = try ui.textStyled(cx, S.title, props.title);
    title_node.setStyleInline(cx.allocator, S.headerTitle(cx.tokens));
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
    scroll.container.setDisplay(if (props.expanded.*) .flex else .none);
    try root.appendChild(cx.allocator, scroll.container);
    const state = try scope.createState(State, .{ .cx = cx, .props = props, .root = root, .body = scroll.container, .status = status, .chevron = chevron, .clock = clock, .mounted_ms = @intCast(@divTrunc(@import("../platform/realtime.zig").monotonicNs(), std.time.ns_per_ms)) });
    if (props.phase == .assembling or props.phase == .running or props.phase == .approval or props.phase == .approved) {
        try cx.addAfterLayoutHook(state, State.tick);
        try scope.onCleanup(State, state, State.release);
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
    if (std.mem.eql(u8, name, "run_command")) return "执行命令";
    if (std.mem.eql(u8, name, "read_terminal")) return "读取终端";
    if (std.mem.eql(u8, name, "read_remote_file")) return "读取远程文件";
    if (std.mem.eql(u8, name, "list_remote_files")) return "列出远程文件";
    return name;
}
