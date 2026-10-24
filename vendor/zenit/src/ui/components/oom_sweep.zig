//! Component mount per-allocation OOM injection sweep. Test support, not a product code path.
//!
//! Guards in mount cannot be verified by reading code; the reliable method is injecting a failure
//! at each allocation point and using a per-case GPA to judge whether anything leaked.
//!
//! Judgment criteria:
//! - Each injection point gets its own `GeneralPurposeAllocator(.{ .safety = true })`; judge by
//!   `deinit() == .leak`. An arena hides leaks entirely.
//! - On mount success the caller (here) calls `freeNode(root)`; on failure it does nothing. Whether
//!   the failure path cleans up after itself is the contract under test.
//! - Idle protection is a **ratio**, not an absolute floor: `induced > 0` would pass with 1 of ~889
//!   points failing. Require at least half of the points to induce failure; the ratio is a stable
//!   invariant, absolute counts drift as components evolve.
const std = @import("std");
const core = @import("../core.zig");
pub const Cx = core.Cx;
pub const Node = core.Node;
pub const Scope = @import("../reactive.zig").Scope;

/// Tested mount unified shape: return root node caller must free (null = no root to free).
pub const MountFn = *const fn (scope: *Scope, cx: *Cx) anyerror!?*Node;

/// `ZENIT_MOUNT_STATS=1`: test mount once and print allocation count, new signals/memos/effects.
fn mountStatsOnly() bool {
    return @import("zenit_environment").has("ZENIT_MOUNT_STATS");
}

pub fn sweepMount(comptime label: []const u8, mount: MountFn) !void {
    const t = std.testing;

    // Measure successful call cost in allocation points.
    const total_allocs = blk: {
        var arena = std.heap.ArenaAllocator.init(t.allocator);
        defer arena.deinit();
        var counting = t.FailingAllocator.init(arena.allocator(), .{});
        const ctx = try Cx.init(counting.allocator(), std.testing.io);
        defer ctx.deinit();
        // Popover/Tooltip etc. need portal, require cx.root; same shape as component's basic tests.
        ctx.root = try core.box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
        const scope = try Scope.init(counting.allocator(), null, ctx.owner);
        defer scope.dispose();
        const before = counting.alloc_index;
        const kinds_before = ctx.owner.graph.countByKind();
        _ = try mount(scope, ctx);
        if (mountStatsOnly()) {
            const kinds_after = ctx.owner.graph.countByKind();
            std.debug.print("[mount-stats] {s} allocs={d} signal={d} memo={d} effect={d}\n", .{
                label,
                counting.alloc_index - before,
                kinds_after.get(.signal) - kinds_before.get(.signal),
                kinds_after.get(.memo) - kinds_before.get(.memo),
                kinds_after.get(.effect) - kinds_before.get(.effect),
            });
        }
        break :blk counting.alloc_index - before;
    };
    try t.expect(total_allocs > 0);
    // Skip per-point injection when only sampling mount baseline (docs/SIGNAL_API_DESIGN.md §7 P0
    // baseline).
    if (mountStatsOnly()) return;

    // During injection, control flow regions (For / Show...) on allocation failure mid-effect
    // downgrade to "log error, keep old row" by design, not leak; its err log fails the test,
    // suppress here (leaks still judged by GPA).
    const control_flow = @import("../control_flow.zig");
    control_flow.control_flow_suppress_error_log = true;
    defer control_flow.control_flow_suppress_error_log = false;

    var induced: usize = 0;
    var leaked: usize = 0;
    var first_leak: ?usize = null;
    for (0..total_allocs) |failure_index| {
        var gpa = std.heap.DebugAllocator(.{ .safety = true }){};
        {
            var failing = t.FailingAllocator.init(gpa.allocator(), .{});
            const ctx = Cx.init(failing.allocator(), std.testing.io) catch {
                _ = gpa.deinit();
                continue;
            };
            ctx.root = core.box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{}) catch {
                ctx.deinit();
                _ = gpa.deinit();
                continue;
            };
            const scope = Scope.init(failing.allocator(), null, ctx.owner) catch {
                ctx.deinit();
                _ = gpa.deinit();
                continue;
            };
            failing.fail_index = failing.alloc_index + failure_index;
            failing.resize_fail_index = failing.resize_index + failure_index;
            const result = mount(scope, ctx);
            failing.fail_index = std.math.maxInt(usize);
            failing.resize_fail_index = std.math.maxInt(usize);
            if (result) |maybe_root| {
                if (maybe_root) |root| ctx.freeNode(root);
            } else |_| {
                induced += 1;
            }
            scope.dispose();
            ctx.deinit();
        }
        if (gpa.deinit() == .leak) {
            leaked += 1;
            if (first_leak == null) first_leak = failure_index;
        }
    }
    // See file header: card by ratio, not absolute floor. Normal ~100% (every allocation point
    // induced once, mount mostly fails return); dropping below half means sweep doesn't truly cover
    // mount.
    const min_induced = total_allocs / 2;
    if (induced < min_induced) {
        std.debug.print(
            "\n[{s}] sweep 覆盖坍塌: induced={d} / total_allocs={d}（要求 >= {d}）\n",
            .{ label, induced, total_allocs, min_induced },
        );
    }
    try t.expect(induced >= min_induced);
    if (leaked > 0) {
        std.debug.print(
            "\n[{s}] LEAK at {d}/{d} failure points; first={?d}\n",
            .{ label, leaked, total_allocs, first_leak },
        );
    }
    try t.expectEqual(@as(usize, 0), leaked);
}
