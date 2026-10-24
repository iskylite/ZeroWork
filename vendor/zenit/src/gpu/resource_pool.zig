//! GPU ResourcePool: cross-frame GPU resource ownership + epoch retirement queue.
//! Use with FrameSync:
//! - Call beginFrame(epoch) to start work; release via release(handle) to queue retirement
//! - Ring buffer mode: resources are destroyed when epoch reaches epoch+MAX_FRAMES_IN_FLIGHT
//!
//! No concrete backend resource types; payload is type-erased *anyopaque with caller-provided
//! deinit_fn(*anyopaque). Single pool manages multiple resource kinds (Texture/Buffer/Pipeline);
//! handle includes kind tag for distinction.
//!
//! Design (from Chromium cc):
//! 1. Handles are generational, safe from ABA after free
//! 2. Release always deferred until GPU frame completes
//! 3. No atomic refcounts; single-threaded GUI is sufficient
//! 4. Pool can be drained (on window close), syncs until all retirements complete
//!
//! Usage:
//! ```
//! var pool = ResourcePool.init(allocator, 3); // 3 = MAX_FRAMES_IN_FLIGHT
//! defer pool.deinit();
//!
//! const tex_ptr = backend.createTexture(...);
//! const handle = try pool.alloc(.texture, tex_ptr, &textureDeinit);
//!
//! // Each frame:
//! pool.beginFrame();
//! ...
//! pool.release(handle); // does not destroy immediately
//! pool.endFrame(); // advances ring; epoch-N retirements execute deinit_fn
//! ```

const std = @import("std");
const testing = std.testing;

pub const MAX_FRAMES_IN_FLIGHT_DEFAULT: u8 = 3;

/// Resource type tag, for debug/stats; doesn't affect pool behavior.
pub const ResourceKind = enum(u8) {
    texture,
    buffer,
    sampler,
    pipeline,
    bind_group,
    shader,
    other,
};

pub const DeinitFn = *const fn (payload: *anyopaque) void;

/// Generational handle. 32-bit index + 8-bit gen + 8-bit kind = 48 bit; pad to u64 align.
pub const ResourceHandle = packed struct(u64) {
    index: u32,
    generation: u16,
    kind: u8,
    _pad: u8 = 0,

    pub const NULL: ResourceHandle = .{ .index = 0xFFFFFFFF, .generation = 0xFFFF, .kind = 0xFF };

    pub fn isNull(self: ResourceHandle) bool {
        return self.index == 0xFFFFFFFF;
    }

    pub fn eql(a: ResourceHandle, b: ResourceHandle) bool {
        const ar: u64 = @bitCast(a);
        const br: u64 = @bitCast(b);
        return ar == br;
    }
};

const Slot = struct {
    generation: u16,
    occupied: bool,
    kind: ResourceKind,
    payload: ?*anyopaque,
    deinit_fn: ?DeinitFn,
    /// When occupied=false, this field is free list chain.
    next_free: u32,
};

const PendingRelease = struct {
    index: u32,
    generation: u16,
};

pub const ResourcePool = struct {
    allocator: std.mem.Allocator,
    slots: std.ArrayListUnmanaged(Slot),
    free_head: u32, // 0xFFFFFFFF = empty
    /// Ring buffer, one bucket per frame; endFrame advances current; after advance old bucket
    /// resources destroyed.
    pending: []std.ArrayListUnmanaged(PendingRelease),
    current_bucket: u8,
    max_frames_in_flight: u8,
    /// Accumulated stats
    stats_alloc_count: u64 = 0,
    stats_release_count: u64 = 0,
    stats_deinit_count: u64 = 0,
    stats_live_count: u32 = 0,

    pub fn init(allocator: std.mem.Allocator, max_frames_in_flight: u8) !ResourcePool {
        std.debug.assert(max_frames_in_flight >= 1 and max_frames_in_flight <= 8);
        const buckets = try allocator.alloc(std.ArrayListUnmanaged(PendingRelease), max_frames_in_flight);
        for (buckets) |*b| b.* = .empty;
        return .{
            .allocator = allocator,
            .slots = .empty,
            .free_head = 0xFFFFFFFF,
            .pending = buckets,
            .current_bucket = 0,
            .max_frames_in_flight = max_frames_in_flight,
        };
    }

    pub fn deinit(self: *ResourcePool) void {
        // Close: drain all pending (any order, frames stopped anyway)
        for (self.pending) |*bucket| {
            self.flushBucket(bucket);
            bucket.deinit(self.allocator);
        }
        self.allocator.free(self.pending);

        // Destroy still-occupied resources too, user-unreleased also cleaned
        for (self.slots.items) |*slot| {
            if (slot.occupied) {
                if (slot.deinit_fn) |f| {
                    if (slot.payload) |p| f(p);
                }
                slot.occupied = false;
                self.stats_deinit_count += 1;
            }
        }
        self.slots.deinit(self.allocator);
        self.* = undefined;
    }

    /// Allocate handle. payload and deinit_fn can both be null (placeholder handle).
    pub fn alloc(
        self: *ResourcePool,
        kind: ResourceKind,
        payload_ptr: ?*anyopaque,
        deinit_fn: ?DeinitFn,
    ) !ResourceHandle {
        if (self.free_head != 0xFFFFFFFF) {
            const idx = self.free_head;
            const slot = &self.slots.items[idx];
            std.debug.assert(!slot.occupied);
            self.free_head = slot.next_free;
            slot.occupied = true;
            slot.kind = kind;
            slot.payload = payload_ptr;
            slot.deinit_fn = deinit_fn;
            self.stats_alloc_count += 1;
            self.stats_live_count += 1;
            return .{
                .index = idx,
                .generation = slot.generation,
                .kind = @backingInt(kind),
            };
        }

        const idx = self.slots.items.len;
        if (idx >= 0xFFFFFFFE) return error.ResourcePoolFull;
        try self.slots.append(self.allocator, .{
            .generation = 0,
            .occupied = true,
            .kind = kind,
            .payload = payload_ptr,
            .deinit_fn = deinit_fn,
            .next_free = 0xFFFFFFFF,
        });
        self.stats_alloc_count += 1;
        self.stats_live_count += 1;
        return .{
            .index = @intCast(idx),
            .generation = 0,
            .kind = @backingInt(kind),
        };
    }

    pub fn isValid(self: *const ResourcePool, handle: ResourceHandle) bool {
        if (handle.isNull()) return false;
        if (handle.index >= self.slots.items.len) return false;
        const slot = &self.slots.items[handle.index];
        return slot.occupied and slot.generation == handle.generation;
    }

    pub fn payload(self: *ResourcePool, handle: ResourceHandle) ?*anyopaque {
        if (!self.isValid(handle)) return null;
        return self.slots.items[handle.index].payload;
    }

    /// Submit handle into retire queue. Destroyed after frame+max_frames_in_flight.
    /// Duplicate release / invalid handle asserts in debug; release always no-op fault-tolerant.
    pub fn release(self: *ResourcePool, handle: ResourceHandle) void {
        if (!self.isValid(handle)) {
            std.debug.assert(false);
            return;
        }
        const idx = handle.index;
        // Mark occupied=false immediately prevent double-free treated valid;
        // but generation ++ only after actual deinit (ABA safe during retire stay).
        // Actually here need immediate ++ so old handle isValid=false;
        // real resource payload stays in slot until retire deinit.
        const slot = &self.slots.items[idx];
        slot.generation +%= 1; // wrap allowed; gen=0xFFFF -> 0 reallocate, sync with fresh slot
        // Note: placeholder still true, retire phase can find payload; use isValid needs generation
        // match
        // so handle now invalid (generation mismatch), even occupied=true won't pass isValid.
        self.pending[self.current_bucket].append(self.allocator, .{
            .index = idx,
            .generation = slot.generation,
        }) catch {
            // OOM degrade: destroy immediate; doesn't affect correctness, just loses delayed
            // protection
            self.flushSlot(idx);
        };
        self.stats_release_count += 1;
        self.stats_live_count -= 1;
    }

    /// Advance one frame: current bucket resources still wait max_frames_in_flight-1 frames to
    /// destroy.
    /// Call order: endFrame then start next frame work.
    pub fn endFrame(self: *ResourcePool) void {
        // Advance current_bucket; new current's bucket is max_frames_in_flight-1 frames old,
        // that frame's GPU work done now, can safely destroy.
        self.current_bucket = (self.current_bucket + 1) % self.max_frames_in_flight;
        const bucket = &self.pending[self.current_bucket];
        self.flushBucket(bucket);
    }

    /// Force recover all pending (close window, device lost)
    pub fn drainAll(self: *ResourcePool) void {
        for (self.pending) |*bucket| {
            self.flushBucket(bucket);
        }
    }

    fn flushBucket(self: *ResourcePool, bucket: *std.ArrayListUnmanaged(PendingRelease)) void {
        for (bucket.items) |entry| {
            self.flushSlot(entry.index);
        }
        bucket.clearRetainingCapacity();
    }

    fn flushSlot(self: *ResourcePool, idx: u32) void {
        const slot = &self.slots.items[idx];
        if (!slot.occupied) return; // already destroyed
        if (slot.deinit_fn) |f| {
            if (slot.payload) |p| f(p);
        }
        slot.occupied = false;
        slot.payload = null;
        slot.deinit_fn = null;
        slot.next_free = self.free_head;
        self.free_head = idx;
        self.stats_deinit_count += 1;
    }

    pub fn liveCount(self: *const ResourcePool) u32 {
        return self.stats_live_count;
    }
};

// ============================================================================
// Tests
// ============================================================================

const TestResource = struct {
    value: u32,
    deinited: *bool,

    fn deinitCb(ptr: *anyopaque) void {
        const r: *TestResource = @ptrCast(@alignCast(ptr));
        r.deinited.* = true;
    }
};

test "ResourceHandle is 8 bytes" {
    try testing.expectEqual(@as(usize, 8), @sizeOf(ResourceHandle));
}

test "ResourcePool alloc + isValid + payload" {
    var pool = try ResourcePool.init(testing.allocator, 3);
    defer pool.deinit();

    var deinited = false;
    var resource = TestResource{ .value = 42, .deinited = &deinited };
    const h = try pool.alloc(.texture, &resource, &TestResource.deinitCb);
    try testing.expect(pool.isValid(h));
    const p = pool.payload(h).?;
    const got: *TestResource = @ptrCast(@alignCast(p));
    try testing.expectEqual(@as(u32, 42), got.value);
    try testing.expectEqual(@as(u32, 1), pool.liveCount());

    // Released but not yet epoch, resource shouldn't deinit
    pool.release(h);
    try testing.expect(!deinited);
    try testing.expect(!pool.isValid(h));
    try testing.expectEqual(@as(u32, 0), pool.liveCount());
}

test "ResourcePool epoch-N retirement: deinit happens after N endFrame calls" {
    var pool = try ResourcePool.init(testing.allocator, 3);
    defer pool.deinit();

    var deinited = false;
    var resource = TestResource{ .value = 1, .deinited = &deinited };
    const h = try pool.alloc(.texture, &resource, &TestResource.deinitCb);

    pool.release(h);

    // Frame 1 endFrame: advance to bucket 1, bucket 1 prior empty (never used), no destroy
    pool.endFrame();
    try testing.expect(!deinited);

    // Frame 2 endFrame: advance to bucket 2, still empty
    pool.endFrame();
    try testing.expect(!deinited);

    // Frame 3 endFrame: advance back to bucket 0 (release time bucket), destroy
    pool.endFrame();
    try testing.expect(deinited);
}

test "ResourcePool ABA: old handle invalid after release+realloc" {
    var pool = try ResourcePool.init(testing.allocator, 3);
    defer pool.deinit();

    var d1 = false;
    var r1 = TestResource{ .value = 1, .deinited = &d1 };
    const h1 = try pool.alloc(.texture, &r1, &TestResource.deinitCb);
    pool.release(h1);

    // Realloc immediate, won't reuse h1's slot (slot still pending), but free_head slot will reuse
    // here h1 release slot not back to free list (wait endFrame), so alloc below uses new slot
    var d2 = false;
    var r2 = TestResource{ .value = 2, .deinited = &d2 };
    const h2 = try pool.alloc(.texture, &r2, &TestResource.deinitCb);

    try testing.expect(!pool.isValid(h1));
    try testing.expect(pool.isValid(h2));
    try testing.expect(!ResourceHandle.eql(h1, h2));
}

test "ResourcePool slot reuse after retire — generation differs" {
    var pool = try ResourcePool.init(testing.allocator, 2);
    defer pool.deinit();

    var d1 = false;
    var r1 = TestResource{ .value = 1, .deinited = &d1 };
    const h1 = try pool.alloc(.buffer, &r1, &TestResource.deinitCb);
    const idx1 = h1.index;
    pool.release(h1);
    pool.endFrame();
    pool.endFrame(); // now slot back to free list

    var d2 = false;
    var r2 = TestResource{ .value = 2, .deinited = &d2 };
    const h2 = try pool.alloc(.buffer, &r2, &TestResource.deinitCb);

    try testing.expectEqual(idx1, h2.index); // reuse slot
    try testing.expect(h1.generation != h2.generation);
    try testing.expect(!pool.isValid(h1));
    try testing.expect(pool.isValid(h2));
    try testing.expect(d1); // first resource destroyed
}

test "ResourcePool drainAll forces immediate cleanup" {
    var pool = try ResourcePool.init(testing.allocator, 4);
    defer pool.deinit();

    var d = false;
    var r = TestResource{ .value = 1, .deinited = &d };
    const h = try pool.alloc(.pipeline, &r, &TestResource.deinitCb);
    pool.release(h);
    try testing.expect(!d);

    pool.drainAll();
    try testing.expect(d);
}

test "ResourcePool deinit cleans live resources" {
    var d1 = false;
    var d2 = false;
    var r1 = TestResource{ .value = 1, .deinited = &d1 };
    var r2 = TestResource{ .value = 2, .deinited = &d2 };
    {
        var pool = try ResourcePool.init(testing.allocator, 3);
        defer pool.deinit();
        _ = try pool.alloc(.texture, &r1, &TestResource.deinitCb);
        _ = try pool.alloc(.buffer, &r2, &TestResource.deinitCb);
        // don't active release, deinit should clean up
    }
    try testing.expect(d1);
    try testing.expect(d2);
}

test "ResourcePool null payload + null deinit_fn allowed" {
    var pool = try ResourcePool.init(testing.allocator, 2);
    defer pool.deinit();

    const h = try pool.alloc(.other, null, null);
    try testing.expect(pool.isValid(h));
    try testing.expect(pool.payload(h) == null);
    pool.release(h);
    pool.endFrame();
    pool.endFrame();
    // didn't crash
}
