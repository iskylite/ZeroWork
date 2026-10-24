/// Spinner Component
///
/// Rotating loading animation (Material Design circular progress style), replicating MUI
/// CircularProgress keyframes. View in spinner.yix (custom canvas), keyframes and drawing
/// in styles.yss.
const std = @import("std");
const math = std.math;
const core = @import("../../core.zig");
const Cx = core.Cx;
const Node = core.Node;
const box = core.box;
const Color = core.Color;
const Scope = @import("../../reactive.zig").Scope;
const styles = @import("_styles.yss.zig");

/// Create Spinner: `W.Spinner(.{ .size = 24 })`
pub const Spinner = @import("_spinner.yix.zig").Spinner;
pub const SpinnerProps = @import("_spinner.yix.zig").SpinnerProps;

// ========== Test ==========

test "Spinner: basic mount" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 100 }, .height = .{ .px = 100 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const spinner = try Spinner(.{}).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, spinner);

    ctx.layout();
    try std.testing.expectEqual(@as(f32, 20), spinner.rectFromWorldOrFallback().w);
    try std.testing.expect(spinner.hasBeforeRenderHooks());
    try std.testing.expect(spinner.meta.per_frame.custom_hooks.draw != null);
    try std.testing.expectEqual(core.A11yRole.progressbar, spinner.behavior.interaction.a11y.?.role);
    try std.testing.expectEqualStrings("Spinner", spinner.meta.ownership.meta.component_name.?);
}

test "Spinner: custom size" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 200 }, .height = .{ .px = 200 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const spinner = try Spinner(.{ .size = 40, .stroke_width = 4 }).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, spinner);

    ctx.layout();
    try std.testing.expectEqual(@as(f32, 40), spinner.rectFromWorldOrFallback().w);
    try std.testing.expectEqual(@as(f32, 40), spinner.rectFromWorldOrFallback().h);
}

test "Spinner: custom draw emits display list arc" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    ctx.setViewport(120, 120);

    const root = try box(ctx, .{ .width = .{ .px = 120 }, .height = .{ .px = 120 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const spinner = try Spinner(.{}).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, spinner);

    ctx.layout();
    _ = ctx.render();

    var saw_arc = false;
    for (ctx.display_list.items.items) |item| {
        switch (item) {
            .arc => |arc| {
                saw_arc = true;
                try std.testing.expectEqual(spinner.id, arc.header.node_id);
                try std.testing.expect(arc.outer_radius > 0);
            },
            else => {},
        }
    }
    try std.testing.expect(saw_arc);
}

test "Spinner: custom draw replays own content from display list" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    ctx.setViewport(80, 80);

    const root = try box(ctx, .{ .width = .{ .px = 80 }, .height = .{ .px = 80 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const spinner = try Spinner(.{}).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, spinner);

    ctx.layout();
    ctx.perf.display_list_own_replay_count = 0;
    _ = ctx.render();
    const commands = ctx.lowerForEncoderPaintTable();

    try std.testing.expect(ctx.perf.display_list_own_replay_count >= 1);

    var saw_arc = false;
    for (commands) |cmd| {
        if (cmd.kind == .path and cmd.arc_outer_radius > 0 and cmd.stroke_width > 0) {
            saw_arc = true;
            break;
        }
    }
    try std.testing.expect(saw_arc);
}

test "Spinner: 圆弧只由绝对时间决定（帧率不影响速度），周期首尾衔接" {
    const a0 = styles.arcAt(0);
    try std.testing.expectApproxEqAbs(@as(f32, -math.pi / 2.0), a0.start, 0.0001);
    // Same at any given moment regardless of prior frames; full cycle returns arc to
    // start, total rotation 270 degrees
    const cycle: f64 = styles.cycle_seconds * 1000.0;
    const a1 = styles.arcAt(cycle);
    try std.testing.expectApproxEqAbs(a0.end - a0.start, a1.end - a1.start, 0.0001);
    try std.testing.expectApproxEqAbs(@mod(a0.start + 1.5 * math.pi, math.tau), @mod(a1.start, math.tau), 0.001);
    // Arc is longest at half period
    const half = styles.arcAt(cycle / 2.0);
    try std.testing.expect(half.end - half.start > a0.end - a0.start + 4.0);
}

test "Spinner: 颜色缺省取主题强调色，换主题跟随" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    ctx.setViewport(60, 60);
    const root = try box(ctx, .{ .width = .{ .px = 60 }, .height = .{ .px = 60 } }, .{});
    ctx.root = root;
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();
    const spinner = try Spinner(.{}).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, spinner);
    ctx.setTheme(&core.theme.dark);
    ctx.layout();
    _ = ctx.render();
    var color: ?Color = null;
    for (ctx.display_list.items.items) |item| switch (item) {
        .arc => |arc| color = arc.color,
        else => {},
    };
    try std.testing.expect(Color.eql(core.theme.dark.tokens.color.accent, color.?));
}

// Per-allocation OOM sweep; see src/ui/components/oom_sweep.zig
test "spinner: mount 在任意分配点失败时不泄漏（sweep）" {
    try @import("../oom_sweep.zig").sweepMount("spinner", struct {
        fn m(scope: *Scope, cx: *Cx) anyerror!?*Node {
            return try Spinner(.{ .size = 24 }).mount(scope, cx);
        }
    }.m);
}

// Test collection from styles.yss; this line required; see docs/STYLING.md
test {
    _ = @import("_styles.yss.zig");
}
