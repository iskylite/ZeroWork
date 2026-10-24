//! GpuDraw IR: GPU encoder output format.
//!
//! Rendering pipeline:
//!   DisplayItem (paint pass only IR) -> GpuDraw -> GPU command buffer
//!
//! GpuDraw is the final CPU IR: all state refs needed for one GPU draw. Intentionally
//! packed/compact to help the batcher merge adjacent draws.
//!
//! Design reference:
//! - Skia DisplayList -> backend draw call
//! - Impeller Entity -> GPU command
//! - WebRender Primitives -> renderer batches
//!
//! Pitfalls:
//! - **do not** let GpuDraw hold owned resource pointers; GPU resources go via
//!   ResourcePool handles (u64); GpuDraw references the handle index only
//! - **do not** embed GPU API state objects (pipeline state object etc.); use a
//!   small integer id, the backend table resolves it
//! - **do not** persist GpuDraw cross-frame; the draw stream is regenerated each frame
//!   (layer_tree persists cross-frame, the GpuDraw stream is frame-transient)

const std = @import("std");
const testing = std.testing;

/// render pipeline type id (pipeline state object number; backend resolves via table). 0 = invalid;
/// 1.. = valid pipeline.
pub const PipelineId = u16;

/// GPU resource handle (from ResourcePool; u32 extract low bits of ResourceHandle). MAX = no
/// reference.
pub const GpuRangeHandle = u32;

/// buffer range reference (vbo / ibo / uniform)
pub const BufferRange = packed struct(u64) {
    /// resource handle (from ResourcePool; low u24)
    handle: u24,
    /// start offset (in elements)
    offset: u20 = 0,
    /// element count
    count: u20 = 0,

    pub const NONE: BufferRange = .{ .handle = 0xFFFFFF };

    pub fn isNone(self: BufferRange) bool {
        return self.handle == 0xFFFFFF;
    }
};

/// blend mode (part of GPU pipeline state; separated for batcher to decide whether to merge)
pub const BlendMode = enum(u8) {
    none,
    alpha,
    additive,
    multiply,
    screen,
    overlay,
    pre_alpha,
};

/// scissor rect id (0 = no scissor; > 0 references frame scissor table)
pub const ScissorId = u16;

/// LayerId (same concept as layer_tree.LayerId, u32 packed; use u32 raw to avoid circular import)
pub const LayerIdRaw = u32;

/// complete state for single GPU draw call. **64-byte aligned** for cache-line friendly sequential
/// scan by batcher (one draw = 1 cache line).
pub const GpuDraw = extern struct {
    /// render pipeline (determines shader + vertex format)
    pipeline: PipelineId = 0,
    /// scissor rect id
    scissor: ScissorId = 0,
    /// blend mode
    blend: BlendMode = .none,
    /// is instanced draw
    instanced: bool = false,
    _pad0: [2]u8 = .{ 0, 0 },
    /// layer containing this draw
    layer_id_raw: LayerIdRaw = 0,
    /// vertex buffer range
    vbo: BufferRange = BufferRange.NONE,
    /// index buffer range (NONE = non-indexed draw)
    ibo: BufferRange = BufferRange.NONE,
    /// uniform buffer range
    uniforms: BufferRange = BufferRange.NONE,
    /// primary texture handle (NONE = none)
    texture0: GpuRangeHandle = 0xFFFFFFFF,
    /// secondary texture handle (NONE = none)
    texture1: GpuRangeHandle = 0xFFFFFFFF,
    /// instance count (for instanced draw)
    instance_count: u32 = 1,

    /// determine if two draws can merge into same batch. Condition: same pipeline + blend + scissor
    /// + same layer + both non-instanced + no texture or same texture (simplified condition)
    pub fn canBatchWith(a: GpuDraw, b: GpuDraw) bool {
        if (a.pipeline != b.pipeline) return false;
        if (a.blend != b.blend) return false;
        if (a.scissor != b.scissor) return false;
        if (a.layer_id_raw != b.layer_id_raw) return false;
        if (a.instanced or b.instanced) return false;
        if (a.texture0 != b.texture0) return false;
        if (a.texture1 != b.texture1) return false;
        return true;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "BufferRange is exactly 8 bytes" {
    try testing.expectEqual(@as(usize, 8), @sizeOf(BufferRange));
}

test "BufferRange NONE detection" {
    const none = BufferRange.NONE;
    try testing.expect(none.isNone());

    const real: BufferRange = .{ .handle = 5, .offset = 100, .count = 24 };
    try testing.expect(!real.isNone());
}

test "GpuDraw canBatchWith: same pipeline + same state → true" {
    const a = GpuDraw{ .pipeline = 1, .blend = .alpha, .scissor = 2, .layer_id_raw = 5 };
    const b = GpuDraw{ .pipeline = 1, .blend = .alpha, .scissor = 2, .layer_id_raw = 5 };
    try testing.expect(a.canBatchWith(b));
}

test "GpuDraw canBatchWith: different pipeline → false" {
    const a = GpuDraw{ .pipeline = 1 };
    const b = GpuDraw{ .pipeline = 2 };
    try testing.expect(!a.canBatchWith(b));
}

test "GpuDraw canBatchWith: different blend → false" {
    const a = GpuDraw{ .pipeline = 1, .blend = .alpha };
    const b = GpuDraw{ .pipeline = 1, .blend = .multiply };
    try testing.expect(!a.canBatchWith(b));
}

test "GpuDraw canBatchWith: different scissor → false" {
    const a = GpuDraw{ .pipeline = 1, .scissor = 2 };
    const b = GpuDraw{ .pipeline = 1, .scissor = 3 };
    try testing.expect(!a.canBatchWith(b));
}

test "GpuDraw canBatchWith: different layer → false" {
    const a = GpuDraw{ .pipeline = 1, .layer_id_raw = 5 };
    const b = GpuDraw{ .pipeline = 1, .layer_id_raw = 6 };
    try testing.expect(!a.canBatchWith(b));
}

test "GpuDraw canBatchWith: different texture → false" {
    const a = GpuDraw{ .pipeline = 1, .texture0 = 100 };
    const b = GpuDraw{ .pipeline = 1, .texture0 = 200 };
    try testing.expect(!a.canBatchWith(b));
}

test "GpuDraw canBatchWith: instanced → false" {
    const a = GpuDraw{ .pipeline = 1, .instanced = true };
    const b = GpuDraw{ .pipeline = 1 };
    try testing.expect(!a.canBatchWith(b));
}
