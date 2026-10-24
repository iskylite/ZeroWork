//! Generational ElementId.
//!
//! Replaces cross-frame *Node holds (use-after-free risk). Each ElementId is
//! u32 (high 8-bit generation + low 24-bit index). Free increments the generation, so a
//! stale holder is detected on its next dereference.
//!
//! Design reference: Bevy ECS Entity / generational_arena / slotmap pattern.
//! Not bound to a concrete payload; wrap with SlotMap(T).
//!
//! Capacity: 24-bit index = 16M slots; 8-bit generation = 256 reuses, then wrap
//! (wrap makes the slot permanently invalid, preventing ABA).

const std = @import("std");
const testing = std.testing;

const INDEX_BITS: u5 = 24;
const GEN_BITS: u5 = 8;
const INDEX_MASK: u32 = (1 << INDEX_BITS) - 1;
const GEN_MASK: u32 = ((1 << GEN_BITS) - 1) << INDEX_BITS;

pub const MAX_INDEX: u32 = INDEX_MASK; // 16,777,215
pub const MAX_GEN: u8 = (1 << GEN_BITS) - 1; // 255

/// 32-bit generational handle. NULL = std.math.maxInt(u32) (generation=255, index=MAX_INDEX).
/// In practice, index=MAX_INDEX is never allocated (capacity check), so NULL and valid ids never
/// collide.
pub const ElementId = packed struct(u32) {
    index: u24,
    generation: u8,

    pub const NULL: ElementId = .{ .index = @as(u24, @intCast(MAX_INDEX)), .generation = MAX_GEN };

    pub fn raw(self: ElementId) u32 {
        return @bitCast(self);
    }

    pub fn fromRaw(value: u32) ElementId {
        return @bitCast(value);
    }

    pub fn eql(a: ElementId, b: ElementId) bool {
        return a.raw() == b.raw();
    }

    pub fn isNull(self: ElementId) bool {
        return self.eql(NULL);
    }
};

/// SlotMap(T): sparse storage indexed by ElementId. After free, generation++; get() with old id
/// returns null.
///
/// Implementation:
/// - `slots`: dense array; each slot holds (generation, value | next_free)
/// - `free_head`: free list head (u24 index; sentinel = MAX_INDEX)
///
/// Complexity: alloc/free/get/isValid all O(1).
pub fn SlotMap(comptime T: type) type {
    return struct {
        const Self = @This();

        const Slot = struct {
            /// Current generation number. On alloc: occupied=true and use this generation; on free:
            /// increment and occupied=false.
            generation: u8,
            occupied: bool,
            data: union {
                value: T,
                next_free: u32, // index of next free slot, MAX_INDEX = sentinel
            },
        };

        allocator: std.mem.Allocator,
        slots: std.ArrayListUnmanaged(Slot),
        free_head: u32, // MAX_INDEX = empty
        live_count: u32,

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{
                .allocator = allocator,
                .slots = .empty,
                .free_head = MAX_INDEX,
                .live_count = 0,
            };
        }

        pub fn deinit(self: *Self) void {
            self.slots.deinit(self.allocator);
            self.* = undefined;
        }

        /// Allocate a slot, return ElementId. Fails on: OOM or slot count reaches MAX_INDEX.
        pub fn alloc(self: *Self, value: T) !ElementId {
            if (self.free_head != MAX_INDEX) {
                const idx = self.free_head;
                const slot = &self.slots.items[idx];
                std.debug.assert(!slot.occupied);
                self.free_head = slot.data.next_free;
                slot.occupied = true;
                slot.data = .{ .value = value };
                self.live_count += 1;
                return .{
                    .index = @intCast(idx),
                    .generation = slot.generation,
                };
            }

            // Free list empty; append new slot.
            const idx = self.slots.items.len;
            if (idx >= MAX_INDEX) return error.SlotMapFull;

            try self.slots.append(self.allocator, .{
                .generation = 0,
                .occupied = true,
                .data = .{ .value = value },
            });
            self.live_count += 1;
            return .{
                .index = @intCast(idx),
                .generation = 0,
            };
        }

        /// Free a slot. Get with same id returns null. Freed/invalid id calls are no-op
        /// (fault-tolerant) but assert in debug.
        pub fn free(self: *Self, id: ElementId) void {
            if (!self.isValid(id)) {
                std.debug.assert(false);
                return;
            }
            const idx: u32 = id.index;
            const slot = &self.slots.items[idx];
            slot.occupied = false;
            // When generation wraps to MAX_GEN, slot dies permanently (not re-added to free list)
            // to avoid ABA.
            if (slot.generation == MAX_GEN) {
                // Permanently retire slot: not re-added to free list; live_count-- but memory
                // remains allocated.
                self.live_count -= 1;
                return;
            }
            slot.generation += 1;
            slot.data = .{ .next_free = self.free_head };
            self.free_head = idx;
            self.live_count -= 1;
        }

        pub fn isValid(self: *const Self, id: ElementId) bool {
            if (id.isNull()) return false;
            const idx: u32 = id.index;
            if (idx >= self.slots.items.len) return false;
            const slot = &self.slots.items[idx];
            return slot.occupied and slot.generation == id.generation;
        }

        pub fn get(self: *Self, id: ElementId) ?*T {
            if (!self.isValid(id)) return null;
            return &self.slots.items[id.index].data.value;
        }

        pub fn getConst(self: *const Self, id: ElementId) ?*const T {
            if (!self.isValid(id)) return null;
            return &self.slots.items[id.index].data.value;
        }

        pub fn count(self: *const Self) u32 {
            return self.live_count;
        }
    };
}

// ============================================================================
// Tests
// ============================================================================

test "ElementId pack/unpack" {
    const id: ElementId = .{ .index = 12345, .generation = 7 };
    const r = id.raw();
    const id2 = ElementId.fromRaw(r);
    try testing.expectEqual(id.index, id2.index);
    try testing.expectEqual(id.generation, id2.generation);
}

test "ElementId NULL distinct from any valid id" {
    try testing.expect(ElementId.NULL.isNull());
    const id: ElementId = .{ .index = 0, .generation = 0 };
    try testing.expect(!id.isNull());
}

test "SlotMap alloc/get/free roundtrip" {
    var sm = SlotMap(u32).init(testing.allocator);
    defer sm.deinit();

    const a = try sm.alloc(100);
    const b = try sm.alloc(200);
    try testing.expectEqual(@as(u32, 100), sm.get(a).?.*);
    try testing.expectEqual(@as(u32, 200), sm.get(b).?.*);
    try testing.expectEqual(@as(u32, 2), sm.count());

    sm.free(a);
    try testing.expect(sm.get(a) == null);
    try testing.expectEqual(@as(u32, 1), sm.count());
}

test "SlotMap ABA detection — old id rejected after slot reuse" {
    var sm = SlotMap(u32).init(testing.allocator);
    defer sm.deinit();

    const a = try sm.alloc(100);
    sm.free(a);
    const b = try sm.alloc(200);

    // b and a share same slot index but different generation.
    try testing.expectEqual(a.index, b.index);
    try testing.expect(a.generation != b.generation);

    // Old id dereference safely fails.
    try testing.expect(sm.get(a) == null);
    try testing.expect(!sm.isValid(a));

    // New id works normally.
    try testing.expectEqual(@as(u32, 200), sm.get(b).?.*);
    try testing.expect(sm.isValid(b));
}

test "SlotMap free list reuses slots in LIFO order" {
    var sm = SlotMap(u32).init(testing.allocator);
    defer sm.deinit();

    const a = try sm.alloc(1);
    const b = try sm.alloc(2);
    const c = try sm.alloc(3);

    sm.free(a);
    sm.free(c);

    const d = try sm.alloc(4);
    const e = try sm.alloc(5);

    // Free order a,c -> free_head=c -> reuse c before a.
    try testing.expectEqual(c.index, d.index);
    try testing.expectEqual(a.index, e.index);
    _ = b;
}

test "SlotMap generation overflow retires slot permanently" {
    var sm = SlotMap(u32).init(testing.allocator);
    defer sm.deinit();

    var id = try sm.alloc(1);
    // Push generation to MAX_GEN.
    var i: u32 = 0;
    while (i < MAX_GEN) : (i += 1) {
        sm.free(id);
        id = try sm.alloc(@intCast(i + 2));
    }
    // Now id.generation == MAX_GEN.
    try testing.expectEqual(MAX_GEN, id.generation);

    // Free again; slot should retire permanently.
    sm.free(id);

    // Next alloc should use new slot index, not reuse retired one.
    const next = try sm.alloc(999);
    try testing.expect(next.index != id.index);
}

test "SlotMap rejects invalid id from another map" {
    var sm1 = SlotMap(u32).init(testing.allocator);
    defer sm1.deinit();
    var sm2 = SlotMap(u32).init(testing.allocator);
    defer sm2.deinit();

    const a = try sm1.alloc(1);
    // sm2 has no slots; a should be invalid in sm2.
    try testing.expect(sm2.get(a) == null);
    try testing.expect(!sm2.isValid(a));
}

test "ElementId is exactly 4 bytes" {
    try testing.expectEqual(@as(usize, 4), @sizeOf(ElementId));
}
