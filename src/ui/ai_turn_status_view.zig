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
    return if (seconds < 60) std.fmt.bufPrint(buffer, "已运行{d}秒", .{seconds}) else std.fmt.bufPrint(buffer, "已运行{d}分钟{d:0>2}秒", .{ seconds / 60, seconds % 60 });
}
pub fn elapsedMs(turn: *const Turn, now_wall: u64, now_mono: u64) u64 {
    if (turn.ended_at_ms) |ended| return if (turn.started_mono_ms > 0) turn.elapsed_ms else ended -| turn.sent_at_ms;
    return if (turn.started_mono_ms > 0) now_mono -| turn.started_mono_ms else now_wall -| turn.sent_at_ms;
}
pub fn usageLabel(buffer: []u8, turn: *const Turn) ![]const u8 {
    const input = turn.input_tokens orelse return "Token 用量未返回";
    const output = turn.output_tokens orelse return "Token 用量未返回";
    return std.fmt.bufPrint(buffer, "Token {d}", .{input +| output});
}
pub fn waveOffset(time_ms: f64, index: usize, reduced_motion: bool) f32 {
    if (reduced_motion) return 0;
    return @floatCast(@sin(time_ms * (2.0 * std.math.pi / 1400.0) - @as(f64, @floatFromInt(index)) * 0.65) * 1.5);
}
const Wave = struct {
    cx: *ui.Cx,
    root: *ui.Node,
    glyphs: [7]*ui.Node,
    fn release(self: *Wave) void {
        self.cx.removeAfterLayoutHook(self);
    }
    fn tick(raw: *anyopaque, _: u8, _: bool) ui.AfterLayoutResult {
        const self: *Wave = @ptrCast(@alignCast(raw));
        if (!self.root.isDisplayedInTree()) return .done;
        for (self.glyphs, 0..) |glyph, index| glyph.setStyleInline(self.cx.allocator, .{ .translate_y = waveOffset(self.cx.frame_time_ms, index, self.cx.reduced_motion) });
        if (!self.cx.reduced_motion) self.cx.scheduleRedrawAfterNs(16 * std.time.ns_per_ms);
        return .done;
    }
};
fn runningLabel(cx: *ui.Cx, scope: *ui.Scope) !*ui.Node {
    const root = try ui.box(cx, .{ .direction = .row, .height = .{ .px = 20 }, .gap = 0, .align_items = .center, .flex_shrink = 0 }, .{});
    root.behavior.interaction.a11y = .{ .role = .group, .label = "～大海淘金中～" };
    const wave = try scope.createState(Wave, .{ .cx = cx, .root = root, .glyphs = undefined });
    for ([_][]const u8{ "～", "大", "海", "淘", "金", "中", "～" }, 0..) |character, index| {
        const glyph = try ui.text(cx, character, .{ .font_size = 11.5, .line_height = 16.0 / 11.5, .color = theme.current().fg_2 });
        glyph.meta.ownership.meta.test_id = "ai.turn.wave.glyph";
        glyph.behavior.interaction.a11y = .{ .hidden = true };
        wave.glyphs[index] = glyph;
        try root.appendChild(cx.allocator, glyph);
    }
    try cx.addAfterLayoutHook(wave, Wave.tick);
    try scope.onCleanup(Wave, wave, Wave.release);
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
    const completed = turn.ended_at_ms != null;
    row.meta.ownership.meta.test_id = if (completed) "ai.turn.complete" else "ai.turn.running";
    const logo = try ui.image(cx, texture orelse 0, .{ .width = .{ .px = 16 }, .height = .{ .px = 16 }, .flex_shrink = 0 });
    logo.meta.ownership.meta.test_id = "ai.turn.logo";
    try row.appendChild(cx.allocator, logo);
    const label = if (!completed) try runningLabel(cx, scope) else try ui.text(cx, "～回合结束～", .{ .font_size = 11.5, .line_height = 16.0 / 11.5, .color = theme.current().fg_2 });
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
        const usage = try ui.text(cx, try usageLabel(&buffer, turn), .{ .font_size = 10.5, .line_height = 16.0 / 10.5, .color = theme.current().fg_2 });
        usage.meta.ownership.meta.test_id = "ai.turn.tokens";
        try row.appendChild(cx.allocator, usage);
    }
    return row;
}
