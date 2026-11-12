//! One left-aligned lifecycle row, updated in place from submitted to completed.
const std = @import("std");
const ui = @import("ui");
const theme = @import("app_theme.zig");
const Turn = @import("../ai/conversation_turn.zig").Turn;
pub fn rowStyle() ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .fit = .{} }, .min_height = 24, .direction = .row, .justify = .start, .align_items = .center, .flex_wrap = .wrap, .gap = 8, .flex_shrink = 0 };
}
pub fn dot(cx: *ui.Cx) !*ui.Node {
    const node = try ui.box(cx, .{ .width = .{ .px = 3 }, .height = .{ .px = 3 }, .flex_shrink = 0, .background = theme.current().fg_2.withAlpha(100), .border = .{ .width = 0, .radius = 1.5 } }, .{});
    node.meta.ownership.meta.test_id = "ai.turn.separator";
    return node;
}
pub fn elapsedLabel(buffer: []u8, elapsed_ms: u64) ![]const u8 {
    const seconds = elapsed_ms / std.time.ms_per_s;
    return if (seconds < 60) std.fmt.bufPrint(buffer, "处理用时{d}秒", .{seconds}) else std.fmt.bufPrint(buffer, "处理用时{d}分钟{d:0>2}秒", .{ seconds / 60, seconds % 60 });
}
pub fn elapsedMs(turn: *const Turn, now_wall: u64, now_mono: u64) u64 {
    const clock = turn.displayClock(now_mono);
    const elapsed = if (turn.restored_interrupted) (if (turn.started_mono_ms > 0) clock -| turn.started_mono_ms else turn.elapsed_ms) else if (turn.ended_at_ms) |ended| (if (turn.started_mono_ms > 0) turn.elapsed_ms else ended -| turn.sent_at_ms) else (if (turn.started_mono_ms > 0) now_mono -| turn.started_mono_ms else now_wall -| turn.sent_at_ms);
    var waiting: u64 = 0;
    for (turn.steps.items) |step| {
        waiting +|= step.approval_elapsed_ms;
        if (step.approval_started_ms) |start| waiting +|= (step.ended_ms orelse clock) -| start;
    }
    return elapsed -| waiting;
}
fn exactCount(buffer: *[26]u8, value: u64) ![]const u8 {
    var digits_buffer: [20]u8 = undefined;
    const digits = try std.fmt.bufPrint(&digits_buffer, "{d}", .{value});
    var end: usize = 0;
    for (digits, 0..) |digit, index| {
        if (index != 0 and (digits.len - index) % 3 == 0) {
            buffer[end] = ',';
            end += 1;
        }
        buffer[end] = digit;
        end += 1;
    }
    return buffer[0..end];
}
fn usageText(cx: *ui.Cx, text: []const u8, style: ui.TextStyle, comptime ink: []const u8) !*ui.Node {
    var painted = style;
    painted.color = @field(theme.current(), ink);
    const node = try ui.text(cx, text, painted);
    theme.bindInk(node, ink);
    return node;
}
fn usageRow(cx: *ui.Cx, parent: *ui.Node, label: []const u8, value: ?[]const u8, id: []const u8, title: bool) !void {
    const row = try ui.box(cx, .{ .width = .fill(), .min_height = 20, .direction = .row, .align_items = .center, .justify = .space_between, .gap = 8, .flex_shrink = 0 }, .{});
    row.meta.ownership.meta.test_id = id;
    const name = if (title)
        try usageText(cx, label, .{ .font_size = 12, .font_weight = 600, .wrap = .word }, "fg_1")
    else
        try usageText(cx, label, .{ .font_size = 11, .wrap = .word }, "fg_2");
    try row.appendChild(cx.allocator, name);
    if (value) |amount| {
        const node = try usageText(cx, amount, .{ .font_size = 11, .font_weight = 500, .text_align = .end, .wrap = .word }, "fg_1");
        try row.appendChild(cx.allocator, node);
    }
    try parent.appendChild(cx.allocator, row);
}
fn mountUsageDetails(cx: *ui.Cx, parent: *ui.Node, turn: *const Turn) !void {
    const card = try ui.box(cx, .{ .width = .fill(), .min_width = 0, .direction = .column, .gap = 7 }, .{});
    card.meta.ownership.meta.test_id = "ai.turn.usage.details";
    try parent.appendChild(cx.allocator, card);
    const reported = turn.input_tokens != null and turn.output_tokens != null;
    var count_buffer: [32]u8 = undefined;
    var buffer: [48]u8 = undefined;
    const total = if (reported) try std.fmt.bufPrint(&buffer, "{s} Token", .{try @import("ai_token_count.zig").format(&count_buffer, turn.input_tokens.? +| turn.output_tokens.?)}) else null;
    try usageRow(cx, card, "本回合累计用量", total, "ai.turn.usage.total", true);
    const metrics = try ui.box(cx, .{ .width = .fill(), .direction = .column }, .{});
    try card.appendChild(cx.allocator, metrics);
    var exact_buffer: [26]u8 = undefined;
    if (reported) {
        try usageRow(cx, metrics, "累计输入", try exactCount(&exact_buffer, turn.input_tokens.?), "ai.turn.usage.input", false);
        try usageRow(cx, metrics, "累计输出", try exactCount(&exact_buffer, turn.output_tokens.?), "ai.turn.usage.output", false);
    } else {
        try metrics.appendChild(cx.allocator, try usageText(cx, "服务商未返回完整用量。", .{ .font_size = 11, .wrap = .word }, "fg_2"));
    }
    const requests = turn.request_count orelse 0;
    if (reported or requests != 0) {
        const value = if (requests == 0) "未记录" else try std.fmt.bufPrint(&buffer, "{s} 次", .{try exactCount(&exact_buffer, requests)});
        try usageRow(cx, metrics, "模型请求", value, "ai.turn.usage.requests", false);
    }
    if (reported) {
        try card.appendChild(cx.allocator, try ui.box(cx, .{ .width = .fill(), .height = .{ .px = 1 }, .background = theme.current().fg_2.withAlpha(56), .flex_shrink = 0 }, .{}));
        try card.appendChild(cx.allocator, try usageText(cx, "共享的上下文会在每次请求中重复计入。", .{ .font_size = 10.5, .line_height = 14.0 / 10.5, .wrap = .word }, "fg_2"));
    }
}
pub fn waveOffset(time_ms: f64, index: usize, reduced_motion: bool) f32 {
    if (reduced_motion) return 0;
    return @floatCast(@sin(time_ms * (2.0 * std.math.pi / 1400.0) - @as(f64, @floatFromInt(index)) * 0.65) * 1.5);
}
pub const Label = struct {
    text: []const u8,
    animated: bool = true,
};
pub fn turnLabel(turn: *const Turn) Label {
    if (turn.restored_interrupted) return .{ .text = "已中断", .animated = false };
    if (turn.ended_at_ms != null) return .{ .text = "～回合结束～", .animated = false };
    // A decision that needs the user takes precedence over other active tools.
    for (turn.steps.items) |step| if (step.phase == .approval) return .{ .text = "等待确认 · 流程暂停", .animated = false };
    var index = turn.steps.items.len;
    while (index > 0) {
        index -= 1;
        const step = turn.steps.items[index];
        if (step.phase != .running) continue;
        const text = if (std.mem.eql(u8, step.name, "run_command")) "～执行命令中～" else if (std.mem.eql(u8, step.name, "read_terminal")) "～读取终端中～" else if (std.mem.eql(u8, step.name, "read_remote_file")) "～读取文件中～" else if (std.mem.eql(u8, step.name, "list_remote_files")) "～查看目录中～" else "～执行操作中～";
        return .{ .text = text };
    }
    for (turn.steps.items) |step| if (step.phase == .assembling or step.phase == .approved) return .{ .text = "～准备操作中～" };
    return .{ .text = "～大浪淘金中～" };
}
const Wave = struct {
    cx: *ui.Cx,
    root: *ui.Node,
    fn release(self: *Wave) void {
        self.cx.removeAfterLayoutHook(self);
    }
    fn tick(raw: *anyopaque, _: u8, _: bool) ui.AfterLayoutResult {
        const self: *Wave = @ptrCast(@alignCast(raw));
        if (@import("material_geometry.zig").snapshot(self.cx, self.root) == null) return .done;
        for (self.root.children.items, 0..) |glyph, index| glyph.setStyle(self.cx.allocator, .translate_y, waveOffset(self.cx.frame_time_ms, index, self.cx.reduced_motion));
        if (!self.cx.reduced_motion) self.cx.scheduleRedrawAfterNs(16 * std.time.ns_per_ms);
        return .done;
    }
};
fn runningLabel(cx: *ui.Cx, scope: *ui.Scope, label: Label) !*ui.Node {
    const root = try ui.box(cx, .{ .direction = .row, .height = .{ .px = 20 }, .gap = 0, .align_items = .center, .flex_shrink = 0 }, .{});
    root.behavior.interaction.a11y = .{ .role = .group, .label = label.text };
    var characters = (try std.unicode.Utf8View.init(label.text)).iterator();
    while (characters.nextCodepointSlice()) |character| {
        const glyph = try ui.text(cx, character, .{ .font_size = 11.5, .line_height = 16.0 / 11.5, .color = theme.current().fg_2 });
        glyph.meta.ownership.meta.test_id = "ai.turn.wave.glyph";
        glyph.behavior.interaction.a11y = .{ .hidden = true };
        try root.appendChild(cx.allocator, glyph);
    }
    if (label.animated) {
        const wave = try scope.createState(Wave, .{ .cx = cx, .root = root });
        try cx.addAfterLayoutHook(wave, Wave.tick);
        try scope.onCleanup(Wave, wave, Wave.release);
    }
    return root;
}
const Clock = struct {
    cx: *ui.Cx,
    node: *ui.Node,
    turn: *const Turn,
    seconds: ?u64 = null,
    fn release(self: *Clock) void {
        self.cx.removeAfterLayoutHook(self);
    }
    fn tick(raw: *anyopaque, _: u8, _: bool) ui.AfterLayoutResult {
        const self: *Clock = @ptrCast(@alignCast(raw));
        if (@import("material_geometry.zig").snapshot(self.cx, self.node) == null) return .done;
        const now_wall: u64 = @intCast(@max(0, @import("../platform/realtime.zig").milliseconds(self)));
        const now_mono: u64 = @intCast(@divTrunc(@import("../platform/realtime.zig").monotonicNs(), std.time.ns_per_ms));
        const elapsed = elapsedMs(self.turn, now_wall, now_mono);
        self.cx.scheduleRedrawAfterNs((std.time.ms_per_s - elapsed % std.time.ms_per_s) * std.time.ns_per_ms);
        if (self.seconds == elapsed / 1000) return .done;
        self.seconds = elapsed / 1000;
        var buffer: [96]u8 = undefined;
        self.node.setTextContent(self.cx.allocator, elapsedLabel(&buffer, elapsed) catch return .done) catch return .done;
        return .needs_layout;
    }
};
pub fn mount(cx: *ui.Cx, scope: *ui.Scope, turn: *const Turn, texture: ?u32) !*ui.Node {
    const row = try ui.box(cx, rowStyle(), .{});
    const completed = turn.displayFinished();
    row.meta.ownership.meta.test_id = if (turn.restored_interrupted) "ai.turn.interrupted" else if (completed) "ai.turn.complete" else "ai.turn.running";
    const logo = try ui.image(cx, texture orelse 0, .{ .width = .{ .px = 16 }, .height = .{ .px = 16 }, .flex_shrink = 0 });
    logo.meta.ownership.meta.test_id = "ai.turn.logo";
    try row.appendChild(cx.allocator, logo);
    const activity = turnLabel(turn);
    const label = if (!completed) try runningLabel(cx, scope, activity) else try ui.text(cx, activity.text, .{ .font_size = 11.5, .line_height = 16.0 / 11.5, .color = theme.current().fg_2 });
    label.meta.ownership.meta.test_id = "ai.turn.label";
    try row.appendChild(cx.allocator, label);
    try row.appendChild(cx.allocator, try dot(cx));
    var buffer: [96]u8 = undefined;
    const wall: u64 = @intCast(@max(0, @import("../platform/realtime.zig").milliseconds(row)));
    const mono: u64 = @intCast(@divTrunc(@import("../platform/realtime.zig").monotonicNs(), std.time.ns_per_ms));
    const elapsed = try ui.text(cx, try elapsedLabel(&buffer, elapsedMs(turn, wall, mono)), .{ .font_size = 10.5, .line_height = 16.0 / 10.5, .color = theme.current().fg_2 });
    elapsed.meta.ownership.meta.test_id = "ai.turn.elapsed";
    try row.appendChild(cx.allocator, elapsed);
    if (!completed) {
        const clock = try scope.createState(Clock, .{ .cx = cx, .node = elapsed, .turn = turn });
        try cx.addAfterLayoutHook(clock, Clock.tick);
        try scope.onCleanup(Clock, clock, Clock.release);
    } else {
        try row.appendChild(cx.allocator, try dot(cx));
        const popup = try ui.widgets.Popover(.{ .trigger = .manual, .position = .top_start, .width = @as(f32, 248), .constrain_width_to_viewport = true, .shift_main_axis = true, .offset = .{ .static = 6 } }).mount(scope, cx);
        popup.chrome.setStyleInline(cx.allocator, .{ .padding = ui.Padding.all(12), .border = .{ .width = 0, .radius = 12 } });
        try theme.bindMaterial(cx, scope, popup.chrome, "overlay");
        const usage = try ui.widgets.Button(.{
            .label = "用量明细",
            .a11y_label = "查看本回合用量明细",
            .variant = .ghost,
            .base_style = ui.BoxStyle{ .height = .{ .px = 22 }, .padding = .{ .left = 0, .right = 0 }, .font_size = 10.5, .text_color = theme.current().fg_2 },
            .on_click = popup.toggle,
        }).mount(scope, cx);
        usage.meta.ownership.meta.test_id = "ai.turn.tokens";
        try popup.trigger.appendChild(cx.allocator, usage);
        try mountUsageDetails(cx, popup.content, turn);
        try row.appendChild(cx.allocator, popup.wrapper);
    }
    return row;
}
