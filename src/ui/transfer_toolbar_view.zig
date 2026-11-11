//! Global queue progress in the retained 28-point transfer button.
const std = @import("std");
const ui = @import("ui");
const theme = @import("app_theme.zig");
pub const Phase = enum { idle, running, waiting, paused, failed, completed };
pub const View = struct {
    cx: *ui.Cx,
    root: *ui.Node,
    idle: *ui.Node,
    ring: *ui.Node,
    label: *ui.Node,
    phase: Phase = .idle,
    fraction: ?f32 = null,
    pub fn mount(cx: *ui.Cx, scope: *ui.Scope, button: *ui.Node) !*View {
        const self = try scope.createState(View, .{ .cx = cx, .root = button, .idle = undefined, .ring = undefined, .label = undefined });
        self.idle = try theme.icon(cx, ui.icons.arrow_down_up, "fg_2", .{
            .width = .{ .px = 16 },
            .height = .{ .px = 16 },
        });
        // Center the arrow independently of the button's content slot.
        self.idle.setStyleInline(cx.allocator, .{
            .position = .absolute,
            .inset = .{ .left = .{ .px = 6 }, .top = .{ .px = 6 } },
        });
        try button.appendChild(cx.allocator, self.idle);
        self.ring = try ui.box(cx, .{ .position = .absolute, .inset = .{ .left = .{ .px = 2 }, .top = .{ .px = 2 } }, .width = .{ .px = 24 }, .height = .{ .px = 24 }, .hit_behavior = .pass_through }, .{});
        self.ring.meta.ownership.meta.test_id = "toolbar.transfers.progress";
        self.ring.setCustomDraw(draw, self);
        try button.appendChild(cx.allocator, self.ring);
        self.label = try ui.text(cx, "", .{ .font_size = 8, .font_weight = 600, .color = theme.current().accent_ink, .line_height = 1.5, .text_align = .center, .selectable = false });
        self.label.setStyleInline(cx.allocator, .{ .position = .absolute, .inset = .{ .left = .{ .px = 1 }, .top = .{ .px = 8 } }, .width = .{ .px = 26 }, .height = .{ .px = 12 }, .hit_behavior = .pass_through });
        self.label.meta.ownership.meta.test_id = "toolbar.transfers.percent";
        try button.appendChild(cx.allocator, self.label);
        self.update(.idle, null);
        return self;
    }
    pub fn update(self: *View, phase: Phase, fraction: ?f32) void {
        const changed = self.phase != phase or self.fraction != fraction;
        self.phase = phase;
        self.fraction = fraction;
        self.idle.setDisplay(if (phase == .idle) .flex else .none);
        self.ring.setDisplay(if (phase == .idle) .none else .flex);
        self.label.setDisplay(if (phase == .idle) .none else .flex);
        var text: [16]u8 = undefined;
        const label = switch (phase) {
            .idle => "",
            .failed => "!",
            .paused => "Ⅱ",
            .completed => "✓",
            else => if (fraction) |f| std.fmt.bufPrint(&text, "{d:.0}%", .{std.math.clamp(f, 0, 1) * 100}) catch "" else "·",
        };
        if (!std.mem.eql(u8, self.label.getText().?.content, label)) self.label.setTextContent(self.cx.allocator, label) catch {};
        self.label.setTextColor(if (phase == .failed) theme.current().danger_ink else if (phase == .completed) theme.current().ok_ink else theme.current().accent_ink);
        if (self.root.behavior.interaction.a11y) |*props| props.description = switch (phase) {
            .idle => "全局传输队列",
            .running => if (fraction == null) "正在传输，大小未知" else "全局传输进度",
            .waiting => "等待传输",
            .paused => "传输已暂停",
            .failed => "传输失败，打开查看详情",
            .completed => "传输已完成",
        };
        if (changed or (fraction == null and phase == .running)) self.ring.markRenderDirty();
        if (fraction == null and phase == .running) self.cx.scheduleRedrawAfterNs(100 * std.time.ns_per_ms);
    }
    fn draw(ctx: ui.DrawContext, raw: ?*anyopaque) anyerror!void {
        const self: *View = @ptrCast(@alignCast(raw orelse return));
        const dl = ctx.display_list orelse return;
        const header = ctx.display_header orelse return;
        try dl.append(.{ .arc = .{ .header = header, .cx = 12, .cy = 12, .outer_radius = 12, .stroke_width = 2, .start_angle = 0, .end_angle = std.math.tau, .color = theme.current().well_border } });
        const start: f32 = if (self.fraction == null and self.phase == .running) @floatCast(@mod(self.cx.frame_time_ms / 800, 1) * std.math.tau) else -std.math.pi / 2.0;
        const ratio: f32 = if (self.phase == .failed or self.phase == .completed) 1 else self.fraction orelse 0.22;
        if (ratio > 0) try dl.append(.{ .arc = .{ .header = header, .cx = 12, .cy = 12, .outer_radius = 12, .stroke_width = 2, .start_angle = start, .end_angle = start + std.math.tau * ratio, .color = if (self.phase == .failed) theme.current().danger else if (self.phase == .completed) theme.current().ok else theme.current().accent } });
    }
};
