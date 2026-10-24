//! Fixed-address layout header chunks and sparse table-owned TextLayout blocks.
//! Header and text borrows survive directory growth. They expire on slot clear,
//! replacement, element reuse or teardown. Geometry remains node-owned.
const std = @import("std");
const testing = std.testing;
const nlo = @import("node_layout_output.zig");
const TextLayout = @import("text_layout.zig").TextLayout;
pub const ElementId = @import("element_id.zig").ElementId;
pub const NodeLayoutOutput = nlo.NodeLayoutOutput;
comptime {
    assertFields(NodeLayoutOutput, &.{ "vector", "artifacts" });
    assertFields(nlo.LayoutArtifacts, &.{ "children_bbox", "text_layout" });
    if (@sizeOf(NodeLayoutOutput) > 256) @compileError("Sparse layout header budget exceeded");
}
fn assertFields(comptime T: type, comptime names: []const []const u8) void {
    const fields = @import("zenit_reflection").fields(T);
    if (fields.len != names.len) @compileError("Layout field set changed: review ownership and reset");
    for (fields) |field| {
        var found = false;
        for (names) |name| found = found or std.mem.eql(u8, name, field.name);
        if (!found) @compileError("Unhandled layout field: " ++ field.name);
    }
}
pub const LayoutOutputTable = struct {
    const HEADER_CHUNK = 64;
    const TEXT_CHUNK = 8;
    const TextHandle = struct { chunk: usize, slot: u3 };
    const Slot = struct {
        output: NodeLayoutOutput = .{},
        generation: u8 = 0,
        live: bool = false,
        revision: u64 = 0,
        text: ?TextHandle = null,
    };
    const HeaderBlock = [HEADER_CHUNK]Slot;
    const TextBlock = [TEXT_CHUNK]TextLayout;
    // Metadata lives outside payload pages; unused text slots are never touched.
    const TextChunk = struct { block: ?*TextBlock = null, used: u8 = 0, next_free: ?usize = null };
    allocator: std.mem.Allocator,
    headers: std.ArrayListUnmanaged(*HeaderBlock) = .empty,
    texts: std.ArrayListUnmanaged(TextChunk) = .empty,
    len: usize = 0,
    free_text_head: ?usize = null,
    /// At most one empty block survives churn; no live payload moves.
    spare_text_chunk: ?usize = null,
    /// Cleared by the frame host before layout. A failed cache allocation
    /// aborts that layout/paint frame rather than displaying partially wrapped
    /// text. Existing complete outputs remain owned and valid for retry.
    layout_oom: bool = false,
    pub fn init(allocator: std.mem.Allocator) LayoutOutputTable {
        return .{ .allocator = allocator };
    }
    pub fn deinit(self: *LayoutOutputTable) void {
        for (self.texts.items) |chunk| if (chunk.block) |p| self.allocator.destroy(p);
        self.texts.deinit(self.allocator);
        for (self.headers.items) |p| self.allocator.destroy(p);
        self.headers.deinit(self.allocator);
        self.* = undefined;
    }
    fn slotAt(self: *const LayoutOutputTable, index: usize) *Slot {
        return &self.headers.items[index / HEADER_CHUNK][index % HEADER_CHUNK];
    }
    fn validSlot(self: *const LayoutOutputTable, id: ElementId) ?*Slot {
        if (id.isNull() or id.index >= self.len) return null;
        const slot = self.slotAt(id.index);
        return if (slot.live and slot.generation == id.generation) slot else null;
    }
    /// Stage every missing block before publishing length or a new generation.
    /// OOM preserves all existing output, IDs and borrowed addresses.
    pub fn ensureSlot(self: *LayoutOutputTable, id: ElementId) !void {
        if (id.isNull()) return;
        const needed: usize = @as(usize, id.index) + 1;
        const chunks = (needed + HEADER_CHUNK - 1) / HEADER_CHUNK;
        if (chunks > self.headers.items.len) {
            const missing = chunks - self.headers.items.len;
            const staged = try self.allocator.alloc(*HeaderBlock, missing);
            defer self.allocator.free(staged);
            var count: usize = 0;
            errdefer for (staged[0..count]) |p| self.allocator.destroy(p);
            for (staged) |*p| {
                p.* = try self.allocator.create(HeaderBlock);
                p.*.* = @splat(.{});
                count += 1;
            }
            try self.headers.ensureUnusedCapacity(self.allocator, missing);
            for (staged) |p| self.headers.appendAssumeCapacity(p);
        }
        self.len = @max(self.len, needed);
        const slot = self.slotAt(id.index);
        if (!slot.live or slot.generation != id.generation) {
            self.releaseText(slot);
            const revision = slot.revision +% 1;
            slot.* = .{ .live = true, .generation = id.generation, .revision = revision };
        }
    }
    fn allocText(self: *LayoutOutputTable) !TextHandle {
        if (self.free_text_head) |index| {
            const chunk = &self.texts.items[index];
            if (chunk.block == null) chunk.block = try self.allocator.create(TextBlock);
            const slot: u3 = @intCast(@ctz(~chunk.used));
            chunk.used |= @as(u8, 1) << slot;
            if (self.spare_text_chunk == index) self.spare_text_chunk = null;
            if (chunk.used == 255) {
                self.free_text_head = chunk.next_free;
                chunk.next_free = null;
            }
            return .{ .chunk = index, .slot = slot };
        }
        try self.texts.ensureUnusedCapacity(self.allocator, 1);
        const block = try self.allocator.create(TextBlock);
        const index = self.texts.items.len;
        self.texts.appendAssumeCapacity(.{ .block = block, .used = 1 });
        self.free_text_head = index;
        return .{ .chunk = index, .slot = 0 };
    }
    fn textPtr(self: *const LayoutOutputTable, handle: TextHandle) *TextLayout {
        return &self.texts.items[handle.chunk].block.?[handle.slot];
    }
    fn releaseText(self: *LayoutOutputTable, slot: *Slot) void {
        if (slot.text) |handle| {
            const chunk = &self.texts.items[handle.chunk];
            if (chunk.used == 255) {
                chunk.next_free = self.free_text_head;
                self.free_text_head = handle.chunk;
            }
            chunk.used &= ~(@as(u8, 1) << handle.slot);
            if (chunk.used == 0) {
                if (self.spare_text_chunk == null) {
                    self.spare_text_chunk = handle.chunk;
                } else {
                    self.allocator.destroy(chunk.block.?);
                    chunk.block = null;
                }
            }
        }
        slot.text = null;
        slot.output.artifacts.text_layout = null;
    }
    /// Allocate before commit; failure leaves the complete old output intact.
    /// Existing caches update without allocating. Success expires TextBorrow.
    pub fn storeTextLayout(self: *LayoutOutputTable, id: ElementId, value: *const TextLayout) !void {
        const slot = self.validSlot(id) orelse return error.InvalidElement;
        const handle = slot.text orelse self.allocText() catch |err| {
            self.layout_oom = true;
            return err;
        };
        const target = self.textPtr(handle);
        // Header/vector setters commonly pass their own borrowed cache back.
        // Preserve ownership without copying 12KB through a temporary.
        if (target != value) target.* = value.*;
        slot.text = handle;
        slot.output.artifacts.text_layout = target;
        slot.revision +%= 1;
    }
    pub fn clearTextLayout(self: *LayoutOutputTable, id: ElementId) void {
        const slot = self.validSlot(id) orelse return;
        self.releaseText(slot);
        slot.revision +%= 1;
    }
    pub fn getConstPtr(self: *const LayoutOutputTable, id: ElementId) ?*const NodeLayoutOutput {
        return &(self.validSlot(id) orelse return null).output;
    }
    pub fn getPtr(self: *LayoutOutputTable, id: ElementId) ?*NodeLayoutOutput {
        return &(self.validSlot(id) orelse return null).output;
    }
    /// Borrowed header snapshot; text expires on clear/replacement/reuse.
    /// set only accepts this slot's own text pointer. Clone via storeTextLayout.
    pub fn get(self: *const LayoutOutputTable, id: ElementId) ?NodeLayoutOutput {
        return (self.getConstPtr(id) orelse return null).*;
    }
    pub fn set(self: *LayoutOutputTable, id: ElementId, value: NodeLayoutOutput) !void {
        const slot = self.validSlot(id) orelse return error.InvalidElement;
        if (value.artifacts.text_layout) |text| {
            // A generic header write must never import an untracked lifetime.
            // Explicit storeTextLayout is the only payload copy/ownership API.
            if (slot.text == null or self.textPtr(slot.text.?) != text) return error.ExternalTextLayout;
        } else self.clearTextLayout(id);
        // No header mutation may precede the fallible payload clone.
        slot.output.vector = value.vector;
        slot.output.artifacts.children_bbox = value.artifacts.children_bbox;
    }
    /// Caller frees geometry first. Text ownership is released here.
    pub fn clear(self: *LayoutOutputTable, id: ElementId) void {
        const slot = self.validSlot(id) orelse return;
        self.releaseText(slot);
        const revision = slot.revision +% 1;
        slot.* = .{ .revision = revision };
    }
    pub const TextBorrow = struct {
        id: ElementId,
        revision: u64,
        pub fn resolve(self: TextBorrow, table: *const LayoutOutputTable) ?*const TextLayout {
            const slot = table.validSlot(self.id) orelse return null;
            return if (slot.revision == self.revision) slot.output.artifacts.text_layout else null;
        }
    };
    pub fn borrowText(self: *const LayoutOutputTable, id: ElementId) ?TextBorrow {
        const slot = self.validSlot(id) orelse return null;
        if (slot.text == null) return null;
        return .{ .id = id, .revision = slot.revision };
    }
    pub const MemoryStats = struct {
        slot_bytes: usize,
        len_bytes: usize,
        capacity_bytes: usize,
        text_layout_live_slots: usize,
        text_payload_bytes: usize,
        text_capacity_bytes: usize,
        metadata_bytes: usize,
    };
    pub fn memoryStats(self: *const LayoutOutputTable) MemoryStats {
        var live: usize = 0;
        var blocks: usize = 0;
        for (self.texts.items) |chunk| {
            live += @popCount(chunk.used);
            if (chunk.block != null) blocks += 1;
        }
        return .{ .slot_bytes = @sizeOf(Slot), .len_bytes = self.len * @sizeOf(Slot), .capacity_bytes = self.headers.items.len * @sizeOf(HeaderBlock), .text_layout_live_slots = live, .text_payload_bytes = live * @sizeOf(TextLayout), .text_capacity_bytes = blocks * @sizeOf(TextBlock), .metadata_bytes = self.headers.capacity * @sizeOf(*HeaderBlock) + self.texts.capacity * @sizeOf(TextChunk) };
    }
    pub const MemoryRange = struct { address: usize, bytes: usize };
    pub fn appendMemoryRanges(self: *const LayoutOutputTable, ranges: *std.ArrayListUnmanaged(MemoryRange), allocator: std.mem.Allocator) !void {
        if (self.headers.capacity != 0) try ranges.append(allocator, .{ .address = @intFromPtr(self.headers.items.ptr), .bytes = self.headers.capacity * @sizeOf(*HeaderBlock) });
        if (self.texts.capacity != 0) try ranges.append(allocator, .{ .address = @intFromPtr(self.texts.items.ptr), .bytes = self.texts.capacity * @sizeOf(TextChunk) });
        for (self.headers.items) |p| try ranges.append(allocator, .{ .address = @intFromPtr(p), .bytes = @sizeOf(HeaderBlock) });
        for (self.texts.items) |chunk| if (chunk.block) |p| try ranges.append(allocator, .{ .address = @intFromPtr(p), .bytes = @sizeOf(TextBlock) });
    }
};

test "LayoutOutputTable stable headers text borrows generation and reclamation" {
    var t = LayoutOutputTable.init(testing.allocator);
    defer t.deinit();
    const id = ElementId{ .index = 0, .generation = 1 };
    try t.ensureSlot(id);
    const header = t.getConstPtr(id).?;
    try testing.expectEqual(@as(usize, 0), t.memoryStats().text_capacity_bytes);
    const text = TextLayout{ .line_count = 7, .total_height = 91 };
    try t.storeTextLayout(id, &text);
    const borrow = t.borrowText(id).?;
    const ptr = borrow.resolve(&t).?;
    try t.ensureSlot(.{ .index = 5000, .generation = 2 });
    try testing.expect(header == t.getConstPtr(id).?);
    try testing.expect(ptr == borrow.resolve(&t).?);
    t.clear(id);
    try testing.expect(borrow.resolve(&t) == null);
    try testing.expect(t.get(id) == null);
    try testing.expectEqual(@sizeOf(LayoutOutputTable.TextBlock), t.memoryStats().text_capacity_bytes);
    const reused = ElementId{ .index = 0, .generation = 2 };
    try t.ensureSlot(reused);
    try testing.expect(t.getConstPtr(reused).?.artifacts.text_layout == null);
    try testing.expect(t.getConstPtr(id) == null);
    try t.storeTextLayout(reused, &text);
    try testing.expect(borrow.resolve(&t) == null);
}
fn sparseFailureContract(allocator: std.mem.Allocator) !void {
    var t = LayoutOutputTable.init(allocator);
    defer t.deinit();
    const id = ElementId{ .index = 0, .generation = 1 };
    try t.ensureSlot(id);
    const text = TextLayout{ .line_count = 7 };
    try t.storeTextLayout(id, &text);
    const ptr = t.getConstPtr(id).?;
    const borrow = t.borrowText(id).?;
    t.ensureSlot(.{ .index = 200, .generation = 1 }) catch |err| {
        try testing.expect(ptr == t.getConstPtr(id).?);
        try testing.expectEqual(@as(u16, 7), borrow.resolve(&t).?.line_count);
        return err;
    };
    for (1..10) |i| {
        const other = ElementId{ .index = @intCast(i), .generation = 1 };
        try t.ensureSlot(other);
        t.storeTextLayout(other, &text) catch |err| {
            try testing.expectEqual(@as(f32, 1), t.get(other).?.vector.stroke.width);
            try testing.expect(t.get(other).?.artifacts.text_layout == null);
            try testing.expectEqual(@as(u16, 7), borrow.resolve(&t).?.line_count);
            return err;
        };
        var header = t.get(other).?;
        header.vector.stroke.width = 4;
        try t.set(other, header);
    }
    try testing.expectEqual(@as(usize, 10), t.memoryStats().text_layout_live_slots);
    try testing.expect(ptr == t.getConstPtr(id).?);
    const replacement = TextLayout{ .line_count = 2 };
    try t.storeTextLayout(id, &replacement);
    try testing.expect(borrow.resolve(&t) == null);
    for (0..10) |i| t.clear(.{ .index = @intCast(i), .generation = 1 });
    try testing.expectEqual(@sizeOf(LayoutOutputTable.TextBlock), t.memoryStats().text_capacity_bytes);
    try t.ensureSlot(id);
    try t.storeTextLayout(id, &text);
    try t.set(id, .{});
    try testing.expect(t.get(id).?.artifacts.text_layout == null);
}
test "LayoutOutputTable allocation release reuse and exhaustive OOM" {
    try testing.checkAllAllocationFailures(testing.allocator, sparseFailureContract, .{});
}

test "LayoutOutputTable header set rejects foreign text and accepts self borrows" {
    var t = LayoutOutputTable.init(testing.allocator);
    defer t.deinit();
    const a = ElementId{ .index = 0, .generation = 1 };
    const b = ElementId{ .index = 1, .generation = 1 };
    try t.ensureSlot(a);
    try t.ensureSlot(b);
    const text = TextLayout{ .line_count = 19 };
    try t.storeTextLayout(a, &text);
    const ptr = t.getConstPtr(a).?.artifacts.text_layout.?;
    try t.set(a, t.get(a).?);
    try testing.expect(ptr == t.getConstPtr(a).?.artifacts.text_layout.?);
    try testing.expectError(error.ExternalTextLayout, t.set(b, t.get(a).?));
    try testing.expect(t.getConstPtr(b).?.artifacts.text_layout == null);
    try t.storeTextLayout(b, ptr);
    try testing.expect(ptr != t.getConstPtr(b).?.artifacts.text_layout.?);
    const borrow_b = t.borrowText(b).?;
    t.clear(a);
    try testing.expectEqual(@as(u16, 19), borrow_b.resolve(&t).?.line_count);
    try testing.expectEqual(@as(usize, 1), t.memoryStats().text_layout_live_slots);
}

test "LayoutOutputTable free cursor and bounded spare survive repeated churn" {
    var t = LayoutOutputTable.init(testing.allocator);
    defer t.deinit();
    const text = TextLayout{ .line_count = 3 };
    for (0..32) |i| try t.ensureSlot(.{ .index = @intCast(i), .generation = 1 });
    for (0..20) |_| {
        for (0..32) |i| try t.storeTextLayout(.{ .index = @intCast(i), .generation = 1 }, &text);
        try testing.expectEqual(@as(usize, 32), t.memoryStats().text_layout_live_slots);
        for (0..32) |i| t.clearTextLayout(.{ .index = @intCast(i), .generation = 1 });
        try testing.expectEqual(@sizeOf(LayoutOutputTable.TextBlock), t.memoryStats().text_capacity_bytes);
    }
}
