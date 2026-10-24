//! DisplayItem -> GpuDraw direct encoder
//!
//! encodeDisplayItem translates a single DisplayItem directly to GpuDraw (one-to-one or
//! one-to-many).
//!
//! Batcher: encodeStream processes a DisplayItem sequence into a GpuDraw sequence; adjacent
//! mergeable draws (same pipeline + scissor + blend + layer + compatible texture) merge into one
//! batch (vbo range extends, instance count++).
//!
//! Pure CPU IR conversion; it does not allocate GPU buffers (backend responsibility). Output
//! GpuDraw vbo/ibo/uniforms fields are placeholder NONE; the backend encode fills real buffer
//! ranges.

const std = @import("std");
const testing = std.testing;
const paint_table_mod = @import("paint_table.zig");
const gpu_draw_mod = @import("gpu_draw.zig");

pub const DisplayItem = paint_table_mod.DisplayItem;
pub const DisplayItemKind = paint_table_mod.DisplayItemKind;
pub const GpuDraw = gpu_draw_mod.GpuDraw;
pub const PipelineId = gpu_draw_mod.PipelineId;
pub const BlendMode = gpu_draw_mod.BlendMode;

/// DisplayItemKind -> PipelineId mapping. Each kind maps fixed pipeline; backend registers these
/// pipelines into table at init, PipelineId is 1-based.
pub fn pipelineForKind(kind: DisplayItemKind) PipelineId {
    return switch (kind) {
        .none => 0,
        .rect => 1,
        .text => 2,
        .image => 3,
        .path => 4,
        .shadow => 5,
        .gradient => 6,
        .control => 0, // effect/clip token doesn't go through GPU pipeline
    };
}

/// single DisplayItem direct to one GpuDraw (no merge; merge is encodeStream's job)
pub fn encodeOne(item: DisplayItem, layer_id_raw: u32) GpuDraw {
    return GpuDraw{
        .pipeline = pipelineForKind(item.kind),
        .scissor = 0,
        .blend = if (item.kind == .text or item.kind == .image) .alpha else .none,
        .instanced = false,
        .layer_id_raw = layer_id_raw,
        .vbo = .NONE,
        .ibo = .NONE,
        .uniforms = .NONE,
        .texture0 = if (item.kind == .image or item.kind == .text)
            @truncate(item.resource_handle)
        else
            0xFFFFFFFF,
        .texture1 = 0xFFFFFFFF,
        .instance_count = 1,
    };
}

/// batch encode: DisplayItem sequence -> GpuDraw sequence, adjacent mergeable stacked into
/// instance_count++. Returns number of GpuDraw written to out. out length needs >= items.len.
pub fn encodeStream(
    items: []const DisplayItem,
    layer_id_raw: u32,
    out: []GpuDraw,
) usize {
    if (items.len == 0) return 0;
    std.debug.assert(out.len >= items.len);

    var write: usize = 0;
    var current = encodeOne(items[0], layer_id_raw);

    for (items[1..]) |item| {
        const candidate = encodeOne(item, layer_id_raw);
        if (current.canBatchWith(candidate)) {
            // merge: instance_count++ (real vbo merge handled by backend encode)
            current.instance_count += 1;
        } else {
            out[write] = current;
            write += 1;
            current = candidate;
        }
    }
    out[write] = current;
    write += 1;
    return write;
}

/// stats: adjacent mergeable consecutive run length (for batcher effectiveness measurement).
pub fn maxBatchableRun(items: []const DisplayItem, layer_id_raw: u32) u32 {
    if (items.len == 0) return 0;
    var max_run: u32 = 1;
    var cur_run: u32 = 1;
    var prev = encodeOne(items[0], layer_id_raw);
    for (items[1..]) |item| {
        const cand = encodeOne(item, layer_id_raw);
        if (prev.canBatchWith(cand)) {
            cur_run += 1;
            if (cur_run > max_run) max_run = cur_run;
        } else {
            cur_run = 1;
            prev = cand;
        }
    }
    return max_run;
}

// ============================================================================
// Tests
// ============================================================================

test "pipelineForKind: stable ids" {
    try testing.expectEqual(@as(PipelineId, 0), pipelineForKind(.none));
    try testing.expectEqual(@as(PipelineId, 1), pipelineForKind(.rect));
    try testing.expectEqual(@as(PipelineId, 2), pipelineForKind(.text));
}

test "encodeOne: rect → no-blend, no-texture" {
    const item: DisplayItem = .{ .kind = .rect };
    const draw = encodeOne(item, 0);
    try testing.expectEqual(@as(PipelineId, 1), draw.pipeline);
    try testing.expectEqual(BlendMode.none, draw.blend);
    try testing.expectEqual(@as(u32, 0xFFFFFFFF), draw.texture0);
}

test "encodeOne: text → alpha blend, texture0 from resource_handle" {
    const item: DisplayItem = .{ .kind = .text, .resource_handle = 0xCAFE };
    const draw = encodeOne(item, 0);
    try testing.expectEqual(@as(PipelineId, 2), draw.pipeline);
    try testing.expectEqual(BlendMode.alpha, draw.blend);
    try testing.expectEqual(@as(u32, 0xCAFE), draw.texture0);
}

test "encodeStream: 3 同质 rect → 1 batched draw with instance_count=3" {
    const items = [_]DisplayItem{
        .{ .kind = .rect },
        .{ .kind = .rect },
        .{ .kind = .rect },
    };
    var out: [3]GpuDraw = undefined;
    const written = encodeStream(&items, 7, &out);
    try testing.expectEqual(@as(usize, 1), written);
    try testing.expectEqual(@as(u32, 3), out[0].instance_count);
    try testing.expectEqual(@as(u32, 7), out[0].layer_id_raw);
}

test "encodeStream: rect + text + rect → 3 separate draws (different pipeline)" {
    const items = [_]DisplayItem{
        .{ .kind = .rect },
        .{ .kind = .text },
        .{ .kind = .rect },
    };
    var out: [3]GpuDraw = undefined;
    const written = encodeStream(&items, 0, &out);
    try testing.expectEqual(@as(usize, 3), written);
}

test "encodeStream: 5 rects + 3 texts + 2 rects → 3 batches (5,3,2)" {
    const items = [_]DisplayItem{
        .{ .kind = .rect },
        .{ .kind = .rect },
        .{ .kind = .rect },
        .{ .kind = .rect },
        .{ .kind = .rect },
        .{ .kind = .text, .resource_handle = 1 },
        .{ .kind = .text, .resource_handle = 1 },
        .{ .kind = .text, .resource_handle = 1 },
        .{ .kind = .rect },
        .{ .kind = .rect },
    };
    var out: [10]GpuDraw = undefined;
    const written = encodeStream(&items, 0, &out);
    try testing.expectEqual(@as(usize, 3), written);
    try testing.expectEqual(@as(u32, 5), out[0].instance_count);
    try testing.expectEqual(@as(u32, 3), out[1].instance_count);
    try testing.expectEqual(@as(u32, 2), out[2].instance_count);
}

test "encodeStream: text with different resource_handle → 不合并" {
    const items = [_]DisplayItem{
        .{ .kind = .text, .resource_handle = 100 },
        .{ .kind = .text, .resource_handle = 200 },
    };
    var out: [2]GpuDraw = undefined;
    const written = encodeStream(&items, 0, &out);
    try testing.expectEqual(@as(usize, 2), written);
}

test "maxBatchableRun: 5 同质 rect → 5" {
    const items = [_]DisplayItem{
        .{ .kind = .rect },
        .{ .kind = .rect },
        .{ .kind = .rect },
        .{ .kind = .rect },
        .{ .kind = .rect },
    };
    try testing.expectEqual(@as(u32, 5), maxBatchableRun(&items, 0));
}

test "maxBatchableRun: 交替 rect/text → 1" {
    const items = [_]DisplayItem{
        .{ .kind = .rect },
        .{ .kind = .text },
        .{ .kind = .rect },
        .{ .kind = .text },
    };
    try testing.expectEqual(@as(u32, 1), maxBatchableRun(&items, 0));
}

test "encodeStream: empty input → 0 output" {
    const items: []const DisplayItem = &.{};
    var out: [1]GpuDraw = undefined;
    const written = encodeStream(items, 0, &out);
    try testing.expectEqual(@as(usize, 0), written);
}
