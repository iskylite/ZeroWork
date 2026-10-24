//! command_encoder/local_sort_cluster.zig: local-sort **cluster state machine**.
//!
//! Holds the fixed-size cluster of accumulated 'reorderable commands' (the stateful half;
//! local_sort.zig holds the pure functions: which pipeline a command belongs to, its bounds).
//!
//! Cohesion:
//!   - fields only `refs` + `len`; four methods (clear / isEmpty / tryAppend /
//!     buildDispatchOrder) touch only these, zero encoder dependency;
//!   - encoder side has only 3 touch points: `var cluster = ...Cluster{}`,
//!     `cluster.tryAppend(...)`, `self.flushLocalSortCluster(commands, &cluster)`
//!     (flush stays in the encoder: it calls dispatchCommand, the encoding loop's job).
//!
//! Independently testable: capacity exhausted, fence rejected, overlap rejected, pipeline
//! stable sort are asserted directly (see tests at end of this file).
//!
//! WARNING contract from local_sort.zig: `buildDispatchOrder` output must be
//! 'bucket per pipeline, bucket-internal preserve insertion order'. Local-sort reorders only when
//! **bounds don't overlap**, so unchanged bucket-internal order is visually equivalent to the
//! original. Arbitrary bucket-internal reorder breaks the invariant.
//!
//! Not here: deciding 'which command enters cluster' (bounds/pipeline) stays in local_sort.zig;
//! emitting cluster commands (flush -> dispatchCommand) stays in the encoder.
//! This module only 'accumulates'.

const std = @import("std");
const lsort = @import("local_sort.zig");

/// Cluster capacity. Matches history value when inlined in encoder (128 paint commands);
/// exceed then reject entry and trigger flush, behavior unchanged.
pub const capacity: usize = 128;

pub const RejectReason = enum {
    none,
    overlap,
    capacity,
    unsortable,
};

const SortableRef = struct {
    index: usize,
    pipeline: lsort.PipelineKind,
    bounds: [4]f32,
};

pub const LocalSortCluster = struct {
    refs: [capacity]SortableRef = undefined,
    len: usize = 0,

    pub fn clear(self: *LocalSortCluster) void {
        self.len = 0;
    }

    pub fn isEmpty(self: *const LocalSortCluster) bool {
        return self.len == 0;
    }

    /// Try append `commands[index]` into cluster.
    ///
    /// Return `.unsortable` two cases (fence command / can't compute bounds) caller
    /// directly dispatch; `.overlap` / `.capacity` caller flush then retry once.
    pub fn tryAppend(self: *LocalSortCluster, commands: anytype, index: usize) RejectReason {
        const pipeline = lsort.localSortPipelineKind(commands[index]);
        if (pipeline == .fence) return .unsortable;
        const bounds = lsort.localSortBoundsForCommand(commands[index]) orelse return .unsortable;
        if (self.len >= self.refs.len) return .capacity;

        for (self.refs[0..self.len]) |ref| {
            if (ref.pipeline == pipeline) continue;
            if (lsort.rectsOverlap(ref.bounds, bounds)) return .overlap;
        }

        self.refs[self.len] = .{
            .index = index,
            .pipeline = pipeline,
            .bounds = bounds,
        };
        self.len += 1;
        return .none;
    }

    /// Output dispatch order bucketed per pipeline (sdf -> image -> icon -> text),
    /// bucket-internal preserve insertion, see module head order contract.
    pub fn buildDispatchOrder(self: *const LocalSortCluster, out: *[capacity]usize) []const usize {
        var out_len: usize = 0;
        const order = [_]lsort.PipelineKind{ .sdf, .image, .icon, .text };
        for (order) |pipeline| {
            for (self.refs[0..self.len]) |ref| {
                if (ref.pipeline != pipeline) continue;
                out[out_len] = ref.index;
                out_len += 1;
            }
        }
        return out[0..out_len];
    }
};

// ── test ───────────────────────────────────────────────────────────────
// Previously this logic nested struct in encoder, observe indirectly via encodeCommands;
// below duck-typed mock commands drive direct (same hand-wave as MockItem in
// command_encoder_test.zig, render module doesn't import ui paint_table).

const MockItem = struct {
    // WARNING enum members must match local_sort.zig switch labels (there anytype duck-type
    // direct switch it.kind). But it's this module private test fixture:
    // command_encoder_test.zig each keep own MockItem, no cross-import,
    // avoid 'existing module depends on new module's test type' reverse coupling.
    kind: enum { none, rect, text, image, shadow, gradient, path, control } = .rect,
    geom: struct { x: f32 = 0, y: f32 = 0, w: f32 = 10, h: f32 = 10 } = .{},
    rotate: f32 = 0,
    arc_outer_radius: f32 = 0,
    icon_rep_ptr: ?*const u8 = null,
    text_content: []const u8 = "x",
    text_font_size: f32 = 12,
    shadow_blur: f32 = 0,
    shadow_offset_x: f32 = 0,
    shadow_offset_y: f32 = 0,
    shadow_spread: f32 = 0,
    shadow2_color: struct { a: f32 = 0 } = .{},
    shadow2_blur: f32 = 0,
    shadow2_offset_x: f32 = 0,
    shadow2_offset_y: f32 = 0,
};

const rects = [_]MockItem{
    .{ .kind = .rect, .geom = .{ .x = 0, .y = 0, .w = 10, .h = 10 } },
    .{ .kind = .image, .geom = .{ .x = 100, .y = 0, .w = 10, .h = 10 } },
    .{ .kind = .text, .geom = .{ .x = 200, .y = 0, .w = 0, .h = 0 } },
};

test "tryAppend: 同 pipeline 相互重叠也照收（bounds 只跨 pipeline 检查）" {
    var cluster = LocalSortCluster{};
    const overlapping = [_]MockItem{
        .{ .kind = .rect, .geom = .{ .x = 0, .y = 0, .w = 50, .h = 50 } },
        .{ .kind = .rect, .geom = .{ .x = 1, .y = 1, .w = 50, .h = 50 } },
    };
    try std.testing.expectEqual(RejectReason.none, cluster.tryAppend(&overlapping, 0));
    try std.testing.expectEqual(RejectReason.none, cluster.tryAppend(&overlapping, 1));
    try std.testing.expectEqual(@as(usize, 2), cluster.len);
}

test "tryAppend: 跨 pipeline 且 bounds 重叠 ⇒ .overlap，不改动簇" {
    var cluster = LocalSortCluster{};
    // rects[0]: rect -> sdf, bounds at (0,0).
    try std.testing.expectEqual(RejectReason.none, cluster.tryAppend(&rects, 0));
    const overlapping_image = [_]MockItem{
        .{ .kind = .image, .geom = .{ .x = 5, .y = 5, .w = 10, .h = 10 } },
    };
    try std.testing.expectEqual(RejectReason.overlap, cluster.tryAppend(&overlapping_image, 0));
    // Reject must be 'no side effect': cluster still only first.
    try std.testing.expectEqual(@as(usize, 1), cluster.len);
}

test "tryAppend: 跨 pipeline bounds 不重叠 ⇒ 入簇" {
    var cluster = LocalSortCluster{};
    try std.testing.expectEqual(RejectReason.none, cluster.tryAppend(&rects, 0));
    try std.testing.expectEqual(RejectReason.none, cluster.tryAppend(&rects, 1));
    try std.testing.expectEqual(@as(usize, 2), cluster.len);
}

test "tryAppend: control（fence）恒 .unsortable，即便簇为空" {
    var cluster = LocalSortCluster{};
    const ctl = [_]MockItem{.{ .kind = .control }};
    try std.testing.expectEqual(RejectReason.unsortable, cluster.tryAppend(&ctl, 0));
    try std.testing.expectEqual(@as(usize, 0), cluster.len);
}

test "positive shadow spread and dual-shadow tails block image reordering" {
    var cluster = LocalSortCluster{};
    const spread = [_]MockItem{
        .{ .kind = .image, .geom = .{ .x = 25, .y = 0, .w = 5, .h = 10 } },
        .{ .kind = .shadow, .geom = .{ .w = 10, .h = 10 }, .shadow_blur = 1, .shadow_spread = 30 },
    };
    try std.testing.expectEqual(RejectReason.none, cluster.tryAppend(&spread, 0));
    try std.testing.expectEqual(RejectReason.overlap, cluster.tryAppend(&spread, 1));
    cluster.clear();
    const dual = [_]MockItem{
        .{ .kind = .image, .geom = .{ .x = -30, .y = 0, .w = 5, .h = 10 } },
        .{ .kind = .shadow, .geom = .{ .w = 10, .h = 10 }, .shadow_blur = 1, .shadow2_color = .{ .a = 1 }, .shadow2_blur = 10, .shadow2_offset_x = 40 },
    };
    try std.testing.expectEqual(RejectReason.none, cluster.tryAppend(&dual, 0));
    try std.testing.expectEqual(RejectReason.overlap, cluster.tryAppend(&dual, 1));
}

test "wide text stays a fence even when em estimates would miss adjacent images" {
    var cluster = LocalSortCluster{};
    const text = [_]MockItem{.{ .kind = .text, .text_content = "WWW", .text_font_size = 64 }};
    try std.testing.expectEqual(RejectReason.unsortable, cluster.tryAppend(&text, 0));
    try std.testing.expect(cluster.isEmpty());
}

test "buildDispatchOrder: 按 pipeline 分桶、桶内保插入序" {
    var cluster = LocalSortCluster{};
    // Insertion order: image, sdf, icon, sdf, interleaved. Note each bounds don't overlap
    // (cross-pipeline overlap rejected by tryAppend, can't mix same cluster).
    const seq = [_]MockItem{
        .{ .kind = .image, .geom = .{ .x = 0, .y = 0, .w = 5, .h = 5 } },
        .{ .kind = .rect, .geom = .{ .x = 0, .y = 10, .w = 5, .h = 5 } },
        .{ .kind = .image, .geom = .{ .x = 200, .y = 0, .w = 5, .h = 5 }, .icon_rep_ptr = &@as(u8, 0) },
        .{ .kind = .rect, .geom = .{ .x = 100, .y = 0, .w = 5, .h = 5 } },
    };
    for (0..seq.len) |i| {
        try std.testing.expectEqual(RejectReason.none, cluster.tryAppend(&seq, i));
    }
    var buf: [capacity]usize = undefined;
    const order = cluster.buildDispatchOrder(&buf);
    // sdf(1), sdf(3), image(0), icon(2)
    try std.testing.expectEqualSlices(usize, &[_]usize{ 1, 3, 0, 2 }, order);
}

test "clear 后可复用且 isEmpty 为真" {
    var cluster = LocalSortCluster{};
    try std.testing.expect(cluster.isEmpty());
    try std.testing.expectEqual(RejectReason.none, cluster.tryAppend(&rects, 0));
    try std.testing.expect(!cluster.isEmpty());
    cluster.clear();
    try std.testing.expect(cluster.isEmpty());
    try std.testing.expectEqual(RejectReason.none, cluster.tryAppend(&rects, 0));
}

test "容量耗尽返回 .capacity 而非静默丢命令" {
    // Regression anchor: refs fixed-size array, overflow if full still write undefined memory.
    var cluster = LocalSortCluster{};
    var cmds: [capacity + 1]MockItem = undefined;
    for (&cmds) |*c| c.* = .{ .kind = .rect, .geom = .{ .x = 0, .y = 0, .w = 1, .h = 1 } };
    for (0..capacity) |i| {
        try std.testing.expectEqual(RejectReason.none, cluster.tryAppend(&cmds, i));
    }
    try std.testing.expectEqual(RejectReason.capacity, cluster.tryAppend(&cmds, capacity));
    try std.testing.expectEqual(@as(usize, capacity), cluster.len);
}
