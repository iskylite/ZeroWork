//! A visible preparation may only insert local caret draws into an unchanged
//! hidden scene. Never put a draw over an occluder or flatten an effect group.
const std = @import("std");
pub const Item = struct {
    label: []const u8 = "",
    digest: u64,
    bounds: [4]f32,
    paint_bounds: ?[4]f32 = null,
    unbounded: bool = false,
    clip: bool = false,
    clip_delta: i8 = 0,
    effect_delta: i8 = 0,
    drawable: bool = true,
    local_caret: bool = false,
};
fn overlaps(a: [4]f32, b: [4]f32) bool {
    return a[0] < b[0] + b[2] and b[0] < a[0] + a[2] and a[1] < b[1] + b[3] and b[1] < a[1] + a[3];
}
pub fn select(allocator: std.mem.Allocator, hidden: []const Item, visible: []const Item, rects: []const [4]f32, patches: []const [4]f32) ![]bool {
    const selected = try allocator.alloc(bool, visible.len);
    errdefer allocator.free(selected);
    @memset(selected, false);
    var next: usize = 0;
    var depth: i32 = 0;
    var additions: usize = 0;
    var clips: [64]usize = undefined;
    var clip_depth: usize = 0;
    for (visible, 0..) |item, i| {
        const matches = next < hidden.len and item.digest == hidden[next].digest;
        if (matches) {
            next += 1;
            // A later paint could obscure a caret. Copying its hidden pixels
            // first and drawing the caret last would reverse this ordering.
            if (item.drawable) for (visible[0..i], selected[0..i]) |earlier, added| {
                if (!added or !earlier.drawable) continue;
                // The opaque native patch replaces its *whole crop*. Even a
                // later draw touching only its AA/alignment fringe must reject.
                for (patches) |patch| {
                    if (overlaps(earlier.bounds, patch) and
                        (item.unbounded or overlaps(item.paint_bounds orelse item.bounds, patch)))
                    {
                        std.log.debug("[caret-replay] occluder label={s} unbounded={} bounds={any} patch={any}", .{ item.label, item.unbounded, item.paint_bounds orelse item.bounds, patch });
                        return error.CaretOccluded;
                    }
                }
            };
            if (item.clip and depth == 0) {
                if (item.clip_delta == 1) {
                    if (clip_depth == clips.len) return error.InvalidCaretStructure;
                    clips[clip_depth] = i;
                    clip_depth += 1;
                } else {
                    if (clip_depth == 0) return error.InvalidCaretStructure;
                    clip_depth -= 1;
                    selected[i] = selected[clips[clip_depth]];
                }
            }
        } else {
            if (depth != 0 or !item.local_caret) {
                std.log.warn("[caret-replay] mismatch visible={d}/{s} hidden={d}/{s} depth={d} bounds={any} expected={any}", .{ i, item.label, next, if (next < hidden.len) hidden[next].label else "end", depth, item.bounds, if (next < hidden.len) hidden[next].bounds else [4]f32{ 0, 0, 0, 0 } });
                return error.NonLocalCaretChange;
            }
            var contained = false;
            for (rects) |r| {
                if (item.bounds[0] >= r[0] - 0.01 and item.bounds[1] >= r[1] - 0.01 and
                    item.bounds[0] + item.bounds[2] <= r[0] + r[2] + 0.01 and
                    item.bounds[1] + item.bounds[3] <= r[1] + r[3] + 0.01) contained = true;
            }
            if (!contained) return error.UndeclaredCaretChange;
            selected[i] = true;
            for (clips[0..clip_depth]) |begin| selected[begin] = true;
            additions += 1;
        }
        depth += item.effect_delta;
        if (depth < 0) return error.InvalidCaretStructure;
    }
    // A declared caret may be entirely clipped or suppressed after preedit.
    // Identical scenes need no added draw; flipping the copied background is
    // equivalent to both ordinary phases, and still avoids idle GPU frames.
    if (next != hidden.len or depth != 0 or clip_depth != 0) {
        std.log.warn("[caret-replay] incomplete hidden={d}/{d} effects={d} clips={d} additions={d}", .{ next, hidden.len, depth, clip_depth, additions });
        return error.NonLocalCaretChange;
    }
    return selected;
}
test "caret patch rejects content changes effects and later occlusion" {
    const bg: Item = .{ .digest = 1, .bounds = .{ 0, 0, 100, 100 } };
    const caret: Item = .{ .digest = 2, .bounds = .{ 20, 20, 2, 18 }, .local_caret = true };
    const rects = [_][4]f32{caret.bounds};
    const accepted = try select(std.testing.allocator, &.{bg}, &.{ bg, caret }, &rects, &rects);
    defer std.testing.allocator.free(accepted);
    try std.testing.expectEqualSlices(bool, &.{ false, true }, accepted);
    try std.testing.expectError(error.CaretOccluded, select(std.testing.allocator, &.{bg}, &.{ caret, bg }, &rects, &rects));
    try std.testing.expectError(error.NonLocalCaretChange, select(std.testing.allocator, &.{bg}, &.{caret}, &rects, &rects));
    const begin: Item = .{ .digest = 3, .bounds = .{ 0, 0, 0, 0 }, .effect_delta = 1, .drawable = false };
    const end: Item = .{ .digest = 4, .bounds = .{ 0, 0, 0, 0 }, .effect_delta = -1, .drawable = false };
    try std.testing.expectError(error.NonLocalCaretChange, select(std.testing.allocator, &.{ begin, end }, &.{ begin, caret, end }, &rects, &rects));
    try std.testing.expectError(error.UndeclaredCaretChange, select(std.testing.allocator, &.{bg}, &.{ bg, caret }, &.{.{ 0, 0, 2, 18 }}, &rects));
}

test "caret replay selects only its balanced clip ancestry" {
    const begin: Item = .{ .digest = 1, .bounds = .{ 0, 0, 0, 0 }, .clip = true, .clip_delta = 1, .drawable = false };
    const end: Item = .{ .digest = 2, .bounds = .{ 0, 0, 0, 0 }, .clip = true, .clip_delta = -1, .drawable = false };
    const caret: Item = .{ .digest = 3, .bounds = .{ 20, 20, 2, 18 }, .local_caret = true };
    const replay = try select(std.testing.allocator, &.{ begin, end, begin, end }, &.{ begin, end, begin, caret, end }, &.{caret.bounds}, &.{caret.bounds});
    defer std.testing.allocator.free(replay);
    try std.testing.expectEqualSlices(bool, &.{ false, false, true, true, true }, replay);
}
test "identical clipped caret scenes keep their background without replay" {
    const bg: Item = .{ .digest = 1, .bounds = .{ 0, 0, 100, 100 } };
    const replay = try select(std.testing.allocator, &.{bg}, &.{bg}, &.{.{ 20, 20, 2, 18 }}, &.{.{ 19, 19, 4, 20 }});
    defer std.testing.allocator.free(replay);
    try std.testing.expectEqualSlices(bool, &.{false}, replay);
}

test "later selection or highlight touching only the aligned patch fringe rejects" {
    const caret: Item = .{ .digest = 1, .bounds = .{ 20.25, 20.25, 1, 18 }, .local_caret = true };
    // Native 2x crop: floor(40.5)-2 -> 38, ceil(42.5)+3 -> 46.
    // Includes 2px outset, quad alignment and the actual surface clipping.
    const patch = [4]f32{ 19, 19, 4, 21 };
    for ([_][4]f32{ .{ 19, 22, 0.5, 2 }, .{ 22, 22, 0.5, 2 } }) |edge| {
        const overlay: Item = .{ .label = "selection/highlight", .digest = 2, .bounds = edge };
        try std.testing.expect(!overlaps(caret.bounds, edge));
        try std.testing.expectError(error.CaretOccluded, select(std.testing.allocator, &.{overlay}, &.{ caret, overlay }, &.{caret.bounds}, &.{patch}));
    }
    const unknown: Item = .{ .digest = 3, .bounds = .{ 500, 500, 1, 1 }, .unbounded = true };
    try std.testing.expectError(error.CaretOccluded, select(std.testing.allocator, &.{unknown}, &.{ caret, unknown }, &.{caret.bounds}, &.{patch}));
}
