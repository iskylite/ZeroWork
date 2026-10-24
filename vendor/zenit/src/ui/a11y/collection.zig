//! Semantic collection: exposes all data rows of a virtualized list to assistive tech, decoupled
//! from render virtualization. Design and native comparison: docs/A11Y_ARCHITECTURE.md section 12.
//! Each data item is an **entry**, three AX elements in one collection slot:
//!   Table (the collection node, AXTable)
//!     row  (AXRow, AXIndex = data index)
//!       cell  (AXCell; VoiceOver sets AXScrollToVisible on it)
//!         bound: pool node subtree (parent is the cell while projecting); unbound: cell_text
//!         (synthesized static text: component label or placeholder)
//! Identity: entry = (collection, data epoch, index). An epoch change destroys that epoch's
//! entries;
//! scrolling and pool rebind don't, so the VoiceOver cursor persists and only cell children change.
//! Offset: AXScrollToVisible in an AX callback only writes a 'committed offset' scalar (no app
//! code,
//! no render tree); frames are pure functions of it + provider geometry (reads agree in-window).
//! The app scroll applies next pump (applyPendingScroll) only if unchanged since commit: user wins.

const std = @import("std");
const tree_mod = @import("tree.zig");

const AXId = tree_mod.AXId;
const A11yNode = tree_mod.A11yNode;
const Frame = tree_mod.Frame;

pub const Rect = struct {
    x: f32 = 0,
    y: f32 = 0,
    w: f32 = 0,
    h: f32 = 0,
};

pub const Size = struct {
    w: f32 = 0,
    h: f32 = 0,
};

/// Collection data source, implemented by VirtualList etc; declared via `A11yProps.collection`.
/// Lifecycle: bound to the declaring table node; Cx.freeNode unregisters it, after which a11y
/// never calls the provider; if the table node is no longer projected, the collection exits at
/// the end of that projection. Component must keep provider state alive as long as the table node.
/// Callbacks run in AX callbacks: read-only, cheap, non-allocating, no UI state mutation;
/// only `apply_scroll` mutates, called at the pump safety point.
pub const Provider = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Total data items.
        count: *const fn (ctx: *anyopaque) u32,
        /// Data epoch: must change when data set changes (add/remove/swap source). Scrolling,
        /// rebind, row height changes don't count.
        data_generation: *const fn (ctx: *anyopaque) u64,
        /// Viewport rect in window content coordinates (top-left origin, logical points).
        viewport: *const fn (ctx: *anyopaque) Rect,
        /// Total content size.
        content_size: *const fn (ctx: *anyopaque) Size,
        /// Item at index rect in 'viewport coords at offset 0' (includes content padding,
        /// independent of scroll).
        item_rect: *const fn (ctx: *anyopaque, index: u32) Rect,
        /// Data item containing content y-coord; return null if out of bounds.
        index_at: *const fn (ctx: *anyopaque, y: f32) ?u32,
        /// The app's current scroll offset (read-only getter; contrast with apply_scroll, which
        /// writes it).
        scroll_offset: *const fn (ctx: *anyopaque) f32,
        /// Write scroll offset to app (instant, no animation). Call only at pump safety point.
        apply_scroll: *const fn (ctx: *anyopaque, offset: f32) void,
        /// Text for item at index; write to buf and return slice; use placeholder if null or empty
        /// slice.
        label: ?*const fn (ctx: *anyopaque, index: u32, buf: []u8) []const u8 = null,
    };

    fn count(self: Provider) u32 {
        return self.vtable.count(self.ctx);
    }
};

/// Entry slot identity, same strategy as ElementTable: slots at MAX generation retired forever.
pub const ItemSlot = packed struct(u32) {
    index: u24,
    generation: u8,

    const RETIRED: u8 = std.math.maxInt(u8);
};

pub const ItemRef = struct {
    slot: ItemSlot,
    kind: AXId.Kind,
};

pub fn itemId(slot: ItemSlot, kind: AXId.Kind) AXId {
    return .{ .payload = @bitCast(slot), .kind = kind };
}

const Pending = struct {
    /// Committed target offset.
    offset: f32,
    /// App scroll offset when submitted: if changed before apply, user scrolled, submission voided.
    base: f32,
};

pub const Collection = struct {
    table: AXId,
    provider: Provider,
    data_generation: u64,
    count: u32,
    viewport: Rect,
    content: Size,
    committed_offset: f32,
    /// Component offset at last projection: snapshot of bound row subtree frame corresponds to
    /// this.
    projected_offset: f32 = 0,
    pending: ?Pending = null,
    seen_epoch: u64,
    hidden: bool,
    /// Data index -> entry slot index (entries created in this epoch).
    items: std.AutoHashMapUnmanaged(u32, u24) = .{},

    /// Amount to translate bound row subtree (projection snapshot) to match entry frame calculated
    /// at committed offset.
    pub fn frameShift(self: *const Collection) f32 {
        return self.projected_offset - self.committed_offset;
    }

    fn maxOffset(self: *const Collection) f32 {
        return @max(0, self.content.h - self.viewport.h);
    }

    /// Frame of item at index in window when offset is committed.
    fn itemFrame(self: *const Collection, index: u32) Frame {
        const r = self.provider.vtable.item_rect(self.provider.ctx, index);
        return .{
            .x = self.viewport.x + r.x,
            .y = self.viewport.y + r.y - self.committed_offset,
            .width = r.w,
            .height = r.h,
        };
    }

    /// Table's own frame: full content, translates with scroll (matches NSTableView).
    pub fn tableFrame(self: *const Collection) Frame {
        return .{
            .x = self.viewport.x,
            .y = self.viewport.y - self.committed_offset,
            .width = @max(self.content.w, self.viewport.w),
            .height = self.content.h,
        };
    }

    /// Data items intersecting viewport [first, first + len).
    pub fn visibleRange(self: *const Collection) struct { first: u32, len: u32 } {
        if (self.count == 0 or self.viewport.h <= 0) return .{ .first = 0, .len = 0 };
        const vt = self.provider.vtable;
        const top = self.committed_offset;
        const bottom = top + self.viewport.h;
        const first = vt.index_at(self.provider.ctx, top) orelse return .{ .first = 0, .len = 0 };
        var last = first;
        // Last item: take item inside viewport bottom edge; bottom edge at row boundary excludes
        // next row.
        if (vt.index_at(self.provider.ctx, @max(top, bottom - 0.5))) |i| last = @max(first, i);
        return .{ .first = first, .len = last - first + 1 };
    }
};

pub const Registry = struct {
    collections: std.ArrayListUnmanaged(?Collection) = .empty,
    by_table: std.AutoHashMapUnmanaged(u64, u32) = .{},
    items: std.ArrayListUnmanaged(Item) = .empty,
    free_items: std.ArrayListUnmanaged(u24) = .empty,

    const Item = struct {
        generation: u8 = 0,
        live: bool = false,
        collection: u32 = 0,
        index: u32 = 0,
        /// Projection epoch of most recent projection binding.
        bound_epoch: u64 = 0,
        /// Was bound at end of last projection (determines if cell has pool subtree or cell_text).
        bound: bool = false,
    };

    pub fn deinit(self: *Registry, allocator: std.mem.Allocator) void {
        for (self.collections.items) |*maybe| {
            if (maybe.*) |*c| c.items.deinit(allocator);
        }
        self.collections.deinit(allocator);
        self.by_table.deinit(allocator);
        self.items.deinit(allocator);
        self.free_items.deinit(allocator);
    }

    pub fn collectionForTable(self: *const Registry, table: AXId) ?*const Collection {
        const idx = self.by_table.get(table.raw()) orelse return null;
        return if (self.collections.items[idx]) |*c| c else null;
    }

    pub fn tableOf(self: *const Registry, idx: u32) AXId {
        return self.collections.items[idx].?.table;
    }

    fn collectionPtr(self: *Registry, idx: u32) *Collection {
        return &self.collections.items[idx].?;
    }

    /// Resolve entry AXId to slot; return null if stale or not entry identity.
    pub const Resolved = struct { slot: ItemSlot, item: *const Item, collection: *const Collection };

    pub fn resolve(self: *const Registry, id: AXId) ?Resolved {
        switch (id.kind) {
            .row, .cell, .cell_text => {},
            else => return null,
        }
        const slot: ItemSlot = @bitCast(id.payload);
        if (slot.index >= self.items.items.len) return null;
        const item = &self.items.items[slot.index];
        if (!item.live or item.generation != slot.generation) return null;
        const c = if (self.collections.items[item.collection]) |*c| c else return null;
        // Row count shrinks without data epoch change (violates provider contract), out-of-bounds
        // entries can't call provider.
        if (item.index >= c.count) return null;
        return .{ .slot = slot, .item = item, .collection = c };
    }

    /// Get entry by data index, create if missing (no notification: AT-fetched elements don't need
    /// 'created' notice).
    pub fn ensureItem(self: *Registry, allocator: std.mem.Allocator, collection_idx: u32, index: u32) !ItemSlot {
        const c = self.collectionPtr(collection_idx);
        if (c.items.get(index)) |slot_index| {
            return .{ .index = slot_index, .generation = self.items.items[slot_index].generation };
        }
        try c.items.ensureUnusedCapacity(allocator, 1);
        const slot_index: u24 = while (self.free_items.pop()) |candidate| {
            if (self.items.items[candidate].generation != ItemSlot.RETIRED) break candidate;
        } else blk: {
            if (self.items.items.len >= std.math.maxInt(u24)) return error.ItemTableFull;
            try self.free_items.ensureTotalCapacity(allocator, self.items.items.len + 1);
            try self.items.append(allocator, .{});
            break :blk @intCast(self.items.items.len - 1);
        };
        const item = &self.items.items[slot_index];
        item.* = .{
            .generation = item.generation,
            .live = true,
            .collection = collection_idx,
            .index = index,
        };
        c.items.putAssumeCapacity(index, slot_index);
        return .{ .index = slot_index, .generation = item.generation };
    }

    /// Free slot: generation advances, retired slots never reused. free_items capacity pre-reserved
    /// at slot creation, no allocation here.
    fn freeItem(self: *Registry, slot_index: u24) void {
        const item = &self.items.items[slot_index];
        item.live = false;
        item.generation +%= 1;
        if (item.generation == ItemSlot.RETIRED) return;
        self.free_items.appendAssumeCapacity(slot_index);
    }

    /// Synthesize A11yNode for entry element per collection state. Frame computed from committed
    /// offset.
    pub fn synthesize(self: *const Registry, id: AXId) ?A11yNode {
        const r = self.resolve(id) orelse return null;
        const c = r.collection;
        const slot = r.slot;
        const frame = c.itemFrame(r.item.index);
        var node: A11yNode = .{
            .element = id,
            .frame = frame,
            .row_index = r.item.index,
            .state = .{ .hidden = c.hidden },
        };
        switch (id.kind) {
            .row => {
                node.role = .row;
                node.parent = c.table;
            },
            .cell => {
                node.role = .cell;
                node.parent = itemId(slot, .row);
                node.column_index = 0;
            },
            .cell_text => {
                node.role = .static_text;
                node.parent = itemId(slot, .cell);
                // Text not stored in LabelStore (entries materialized in AX callback), bridge
                // fetches via itemText.
                node.text_hash = 1;
                // After binding, replaced by pool node subtree, cell_text no longer exists.
                if (r.item.bound) return null;
            },
            else => unreachable,
        }
        return node;
    }

    /// cell_text content: component-provided label, else pre-localization placeholder 'Row N'
    /// (1-indexed).
    pub fn itemText(self: *const Registry, id: AXId, buf: []u8) ?[]const u8 {
        if (id.kind != .cell_text) return null;
        const r = self.resolve(id) orelse return null;
        if (r.item.bound) return null;
        const p = r.collection.provider;
        if (p.vtable.label) |label| {
            const text = label(p.ctx, r.item.index, buf);
            if (text.len > 0) return text;
        }
        return std.fmt.bufPrint(buf, "Row {d}", .{@as(u64, r.item.index) + 1}) catch null;
    }

    /// Child count for collection element; returns null for non-collection (caller uses tree's
    /// child list).
    pub fn childCount(self: *const Registry, tree: *tree_mod.AccessibilityTree, id: AXId) ?usize {
        if (id.kind == .node) {
            const c = self.collectionForTable(id) orelse return null;
            return if (c.hidden) 0 else c.count;
        }
        const r = self.resolve(id) orelse return 0;
        if (r.collection.hidden) return 0;
        return switch (id.kind) {
            .row => 1,
            .cell => if (r.item.bound) tree.exposedChildren(id).len else 1,
            else => 0,
        };
    }

    /// i-th child. Table rows materialized on demand here (range fetch only materializes requested
    /// rows).
    pub fn childAt(self: *Registry, allocator: std.mem.Allocator, tree: *tree_mod.AccessibilityTree, id: AXId, i: usize) ?AXId {
        if (id.kind == .node) {
            const idx = self.by_table.get(id.raw()) orelse return null;
            const c = self.collectionPtr(idx);
            if (c.hidden or i >= c.count) return null;
            const slot = self.ensureItem(allocator, idx, @intCast(i)) catch return null;
            return itemId(slot, .row);
        }
        const r = self.resolve(id) orelse return null;
        if (r.collection.hidden) return null;
        const slot = r.slot;
        return switch (id.kind) {
            .row => if (i == 0) itemId(slot, .cell) else null,
            .cell => if (r.item.bound) blk: {
                const kids = tree.exposedChildren(id);
                break :blk if (i < kids.len) kids[i] else null;
            } else if (i == 0) itemId(slot, .cell_text) else null,
            else => null,
        };
    }

    /// Row at index (for AXRows range fetching).
    pub fn rowAt(self: *Registry, allocator: std.mem.Allocator, table: AXId, index: u32) ?AXId {
        const idx = self.by_table.get(table.raw()) orelse return null;
        const c = self.collectionPtr(idx);
        if (c.hidden or index >= c.count) return null;
        const slot = self.ensureItem(allocator, idx, index) catch return null;
        return itemId(slot, .row);
    }

    /// Hit test: which entry element contains window point (unbound row returns cell_text, bound
    /// row returns cell, deeper nodes handled by caller's node scan).
    pub fn hitTest(self: *Registry, allocator: std.mem.Allocator, x: f32, y: f32) ?struct { id: AXId, table: AXId } {
        for (self.collections.items, 0..) |*maybe, idx| {
            const c = &(maybe.* orelse continue);
            if (c.hidden) continue;
            const v = c.viewport;
            // Closed interval, consistent with node scan hit semantics.
            if (x < v.x or y < v.y or x > v.x + v.w or y > v.y + v.h) continue;
            const index = c.provider.vtable.index_at(c.provider.ctx, y - v.y + c.committed_offset) orelse continue;
            const slot = self.ensureItem(allocator, @intCast(idx), index) catch return null;
            const bound = self.items.items[slot.index].bound;
            return .{ .id = itemId(slot, if (bound) .cell else .cell_text), .table = c.table };
        }
        return null;
    }

    /// Called in AX callback: write minimum scroll containing id's entry (.nearest) to committed
    /// offset. Don't call app code; real scroll applied by applyPendingScroll at pump safety point.
    pub fn commitScrollToVisible(self: *Registry, id: AXId) bool {
        const r = self.resolve(id) orelse return false;
        const c = self.collectionPtr(r.item.collection);
        // Collections invisible to AT don't accept programmatic scroll.
        if (c.hidden) return false;
        const rect = c.provider.vtable.item_rect(c.provider.ctx, r.item.index);
        var offset = c.committed_offset;
        if (rect.y < offset) {
            offset = rect.y;
        } else if (rect.y + rect.h > offset + c.viewport.h) {
            offset = rect.y + rect.h - c.viewport.h;
        }
        offset = std.math.clamp(offset, 0, c.maxOffset());
        if (offset == c.committed_offset) return true;
        const base = if (c.pending) |p| p.base else c.provider.vtable.scroll_offset(c.provider.ctx);
        c.pending = .{ .offset = offset, .base = base };
        c.committed_offset = offset;
        return true;
    }

    /// Called at pump safety point: apply pending submission for id's collection. If app scroll
    /// changed since submission (user scrolled), void it; committed offset reverts to app offset at
    /// next projection.
    pub fn applyPendingScroll(self: *Registry, id: AXId) bool {
        const r = self.resolve(id) orelse return false;
        const c = self.collectionPtr(r.item.collection);
        const pending = c.pending orelse return true;
        c.pending = null;
        if (c.hidden) return false;
        if (c.provider.vtable.scroll_offset(c.provider.ctx) != pending.base) return false;
        c.provider.vtable.apply_scroll(c.provider.ctx, pending.offset);
        // Component may clamp/align; use actual landing position, don't defer convergence to next
        // projection.
        c.committed_offset = c.provider.vtable.scroll_offset(c.provider.ctx);
        return true;
    }
};

// -- Projection-time interface (wrapped by AccessibilityTree; see tree.zig) ----

pub const Recorder = struct {
    tree: *tree_mod.AccessibilityTree,

    /// Entry element exit: notify old parent of child change and send destroy.
    fn removed(self: Recorder, id: AXId, old_parent: AXId) !void {
        try self.tree.recordStructureChange(id, .{ .had_old = true, .old_parent = old_parent });
        try self.tree.markDirty(id, .{ .structure_changed = true });
    }

    /// Entry element appear: only notify parent of child change (AT fetches on demand, no
    /// per-element 'created').
    fn added(self: Recorder, id: AXId, new_parent: AXId) !void {
        try self.tree.recordStructureChange(id, .{ .has_new = true, .new_parent = new_parent });
        try self.tree.markDirty(id, .{ .structure_changed = true });
    }
};

/// Called when projection encounters collection-declaring node. Return collection index for row
/// binding in this projection.
pub fn syncCollection(
    reg: *Registry,
    allocator: std.mem.Allocator,
    rec: Recorder,
    table: AXId,
    provider: Provider,
    epoch: u64,
    hidden: bool,
) !u32 {
    const vt = provider.vtable;
    const generation = vt.data_generation(provider.ctx);
    const count = provider.count();
    const app_offset = vt.scroll_offset(provider.ctx);
    if (reg.by_table.get(table.raw())) |idx| {
        const c = reg.collectionPtr(idx);
        c.provider = provider;
        if (c.data_generation != generation) {
            try destroyItems(reg, rec, c);
            c.data_generation = generation;
            // Data changed, pending submission on old geometry meaningless.
            c.pending = null;
        }
        if (c.count != count) {
            c.count = count;
            try rec.tree.markDirty(table, .{ .row_count_changed = true });
        }
        c.viewport = vt.viewport(provider.ctx);
        c.content = vt.content_size(provider.ctx);
        // Converge: if no pending, follow app; if pending but app scrolled (user), void it.
        if (c.pending) |p| {
            if (app_offset != p.base) c.pending = null;
        }
        if (c.pending == null) c.committed_offset = app_offset;
        c.projected_offset = app_offset;
        c.seen_epoch = epoch;
        c.hidden = hidden;
        return idx;
    }
    const idx: u32 = for (reg.collections.items, 0..) |maybe, i| {
        if (maybe == null) break @intCast(i);
    } else blk: {
        try reg.collections.append(allocator, null);
        break :blk @intCast(reg.collections.items.len - 1);
    };
    try reg.by_table.ensureUnusedCapacity(allocator, 1);
    reg.collections.items[idx] = .{
        .table = table,
        .provider = provider,
        .data_generation = generation,
        .count = count,
        .viewport = vt.viewport(provider.ctx),
        .content = vt.content_size(provider.ctx),
        .committed_offset = app_offset,
        .projected_offset = app_offset,
        .seen_epoch = epoch,
        .hidden = hidden,
    };
    reg.by_table.putAssumeCapacity(table.raw(), idx);
    try rec.tree.markDirty(table, .{ .row_count_changed = true });
    return idx;
}

/// Called when projection encounters pool node bound to item at index. Return that entry's cell
/// AXId: pool node subtree projects directly with it as parent.
pub fn bindItem(reg: *Registry, allocator: std.mem.Allocator, collection_idx: u32, index: u32, epoch: u64) !AXId {
    const c = reg.collectionPtr(collection_idx);
    if (index >= c.count) return error.ItemOutOfRange;
    const slot = try reg.ensureItem(allocator, collection_idx, index);
    reg.items.items[slot.index].bound_epoch = epoch;
    return itemId(slot, .cell);
}

/// Called at projection end: collections not appearing exit wholly; entries with flipped binding
/// state record cell_text enter/exit.
pub fn finishEpoch(reg: *Registry, rec: Recorder, epoch: u64) !void {
    for (reg.collections.items) |*maybe| {
        const c = &(maybe.* orelse continue);
        if (c.seen_epoch != epoch) {
            try retire(reg, rec, c);
            maybe.* = null;
            continue;
        }
        var it = c.items.valueIterator();
        while (it.next()) |slot_index| {
            const item = &reg.items.items[slot_index.*];
            const bound_now = item.bound_epoch == epoch;
            if (bound_now == item.bound) continue;
            const slot: ItemSlot = .{ .index = slot_index.*, .generation = item.generation };
            const text = itemId(slot, .cell_text);
            const cell = itemId(slot, .cell);
            if (bound_now) try rec.removed(text, cell) else try rec.added(text, cell);
            item.bound = bound_now;
        }
    }
}

/// Called when table node freed (see Provider lifecycle). Don't call provider.
pub fn retireTable(reg: *Registry, rec: Recorder, table: AXId) !void {
    const idx = reg.by_table.get(table.raw()) orelse return;
    const maybe = &reg.collections.items[idx];
    try retire(reg, rec, &maybe.*.?);
    maybe.* = null;
}

fn retire(reg: *Registry, rec: Recorder, c: *Collection) !void {
    try destroyItems(reg, rec, c);
    _ = reg.by_table.remove(c.table.raw());
    c.items.deinit(rec.tree.allocator);
}

fn destroyItems(reg: *Registry, rec: Recorder, c: *Collection) !void {
    var it = c.items.valueIterator();
    while (it.next()) |slot_index| {
        const item = &reg.items.items[slot_index.*];
        const slot: ItemSlot = .{ .index = slot_index.*, .generation = item.generation };
        const row = itemId(slot, .row);
        const cell = itemId(slot, .cell);
        if (!item.bound) try rec.removed(itemId(slot, .cell_text), cell);
        try rec.removed(cell, row);
        try rec.removed(row, c.table);
        reg.freeItem(slot_index.*);
    }
    c.items.clearRetainingCapacity();
}

// ── test ───────────────────────────────────────────────────────────────

const testing = std.testing;
const AccessibilityTree = tree_mod.AccessibilityTree;

/// Uniform 20pt data source: viewport at (10, 100) in window, 300w x 100h (5 rows per screen).
const FakeList = struct {
    count: u32 = 1000,
    generation: u64 = 1,
    offset: f32 = 0,
    applied: ?f32 = null,
    retired: bool = false,

    const row_h: f32 = 20;
    const vp: Rect = .{ .x = 10, .y = 100, .w = 300, .h = 100 };

    fn self_(ctx: *anyopaque) *FakeList {
        const s: *FakeList = @ptrCast(@alignCast(ctx));
        // After unregister, a11y layer never calls provider.
        std.debug.assert(!s.retired);
        return s;
    }
    fn countFn(ctx: *anyopaque) u32 {
        return self_(ctx).count;
    }
    fn generationFn(ctx: *anyopaque) u64 {
        return self_(ctx).generation;
    }
    fn viewportFn(ctx: *anyopaque) Rect {
        _ = self_(ctx);
        return vp;
    }
    fn contentFn(ctx: *anyopaque) Size {
        return .{ .w = vp.w, .h = @as(f32, @floatFromInt(self_(ctx).count)) * row_h };
    }
    fn rectFn(ctx: *anyopaque, index: u32) Rect {
        _ = self_(ctx);
        return .{ .x = 0, .y = @as(f32, @floatFromInt(index)) * row_h, .w = vp.w, .h = row_h };
    }
    fn indexAtFn(ctx: *anyopaque, y: f32) ?u32 {
        const s = self_(ctx);
        if (y < 0) return null;
        const i: u32 = @intFromFloat(@floor(y / row_h));
        return if (i < s.count) i else null;
    }
    fn offsetFn(ctx: *anyopaque) f32 {
        return self_(ctx).offset;
    }
    fn applyFn(ctx: *anyopaque, offset: f32) void {
        const s = self_(ctx);
        s.applied = offset;
        s.offset = offset;
    }
    fn labelFn(ctx: *anyopaque, index: u32, buf: []u8) []const u8 {
        _ = self_(ctx);
        return std.fmt.bufPrint(buf, "Item {d}", .{index}) catch "";
    }

    const vtable = Provider.VTable{
        .count = countFn,
        .data_generation = generationFn,
        .viewport = viewportFn,
        .content_size = contentFn,
        .item_rect = rectFn,
        .index_at = indexAtFn,
        .scroll_offset = offsetFn,
        .apply_scroll = applyFn,
        .label = labelFn,
    };

    fn provider(self: *FakeList) Provider {
        return .{ .ctx = self, .vtable = &vtable };
    }
};

const TABLE = AXId.node(.{ .index = 7, .generation = 0 });
const CONTENT = AXId.node(.{ .index = 8, .generation = 0 });

/// One projection: table node + pool nodes at each index in bound (one content node per pool).
fn project(tree: *AccessibilityTree, list: *FakeList, bound: []const u32) !void {
    tree.beginProjection();
    try tree.upsert(.{ .element = TABLE, .role = .grid });
    const cidx = try tree.syncCollection(TABLE, list.provider(), false);
    for (bound, 0..) |index, k| {
        const cell = try tree.bindCollectionItem(cidx, index);
        // Consistent with a11y_projection.syncCollectionItem: row subtree covers owning table,
        // frame uses projection snapshot (row top = viewport top + row pos - component offset).
        tree.projection_collection_host = TABLE;
        defer tree.projection_collection_host = AXId.NULL;
        try tree.upsert(.{
            .element = AXId.node(.{ .index = @intCast(100 + k), .generation = 0 }),
            .parent = cell,
            .role = .static_text,
            .frame = .{
                .x = 10,
                .y = 100 + @as(f32, @floatFromInt(index)) * FakeList.row_h - list.offset,
                .width = 300,
                .height = FakeList.row_h,
            },
        });
    }
    try tree.finishProjection();
}

test "collection: children sorts prefilled synthetic rows with projected nodes" {
    var tree = AccessibilityTree.init(testing.allocator);
    defer tree.deinit();
    var list = FakeList{};
    try project(&tree, &list, &.{});
    const row = tree.childAt(TABLE, 3).?;
    const child = AXId.node(.{ .index = 30, .generation = 0 });
    const prefilled = AXId.node(.{ .index = 31, .generation = 0 });
    try tree.upsert(.{ .element = child, .parent = TABLE, .sibling_index = 1 });
    try tree.upsert(.{ .element = prefilled, .sibling_index = 9 });
    var out: std.ArrayListUnmanaged(AXId) = .empty;
    defer out.deinit(testing.allocator);
    try out.appendSlice(testing.allocator, &.{ prefilled, row });
    try tree.children(TABLE, &out, testing.allocator);
    try testing.expectEqualSlices(AXId, &.{ row, child, prefilled }, out.items);
    try testing.expectEqual(AXId.Kind.row, tree.get(out.items[0]).?.element.kind);
}

test "collection: 表格暴露全部数据行，行 > 单元格 > 文字的父链与 frame" {
    var tree = AccessibilityTree.init(testing.allocator);
    defer tree.deinit();
    var list = FakeList{};
    try project(&tree, &list, &.{});

    try testing.expectEqual(@as(usize, 1000), tree.childCount(TABLE));
    const row = tree.childAt(TABLE, 500).?;
    try testing.expectEqual(AXId.Kind.row, row.kind);
    // Same index fetched again returns same entry.
    try testing.expect(tree.childAt(TABLE, 500).?.eql(row));

    const row_node = tree.get(row).?;
    try testing.expectEqual(Role.row, row_node.role);
    try testing.expect(row_node.parent.eql(TABLE));
    try testing.expectEqual(@as(u32, 500), row_node.row_index);
    // Rows outside viewport also have real frame (matches NSTableView): 100 + 500*20.
    try testing.expectEqual(@as(f32, 10_100), row_node.frame.y);

    const cell = tree.childAt(row, 0).?;
    try testing.expectEqual(Role.cell, tree.get(cell).?.role);
    try testing.expect(tree.get(cell).?.parent.eql(row));
    try testing.expectEqual(@as(usize, 1), tree.childCount(cell));
    const text = tree.childAt(cell, 0).?;
    try testing.expectEqual(Role.static_text, tree.get(text).?.role);
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("Item 500", tree.collections.itemText(text, &buf).?);

    // Table frame is full content, translates with offset.
    const table_frame = tree.get(TABLE).?.frame;
    try testing.expectEqual(@as(f32, 100), table_frame.y);
    try testing.expectEqual(@as(f32, 20_000), table_frame.height);
}

const Role = tree_mod.Role;

test "collection: 绑定翻转只改单元格的子元素，行与单元格身份不变" {
    var tree = AccessibilityTree.init(testing.allocator);
    defer tree.deinit();
    var list = FakeList{};
    try project(&tree, &list, &.{});
    const row = tree.childAt(TABLE, 3).?;
    const cell = tree.childAt(row, 0).?;
    const text = tree.childAt(cell, 0).?;
    tree.dirty.clearRetainingCapacity();
    tree.structure_changes.clearRetainingCapacity();

    // Item 3 bound to pool node: cell subtree swaps to pool node children, cell_text exits (sends
    // destroy).
    try project(&tree, &list, &.{3});
    try testing.expect(tree.childAt(TABLE, 3).?.eql(row));
    try testing.expect(tree.childAt(row, 0).?.eql(cell));
    try testing.expectEqual(@as(usize, 1), tree.childCount(cell));
    try testing.expectEqual(AXId.Kind.node, tree.childAt(cell, 0).?.kind);
    try testing.expect(tree.get(text) == null);
    const removed = tree.structureChange(text).?;
    try testing.expect(removed.had_old and !removed.has_new and removed.old_parent.eql(cell));

    // Unbind again: cell_text returns, hangs under same cell.
    tree.dirty.clearRetainingCapacity();
    tree.structure_changes.clearRetainingCapacity();
    try project(&tree, &list, &.{});
    try testing.expect(tree.childAt(cell, 0).?.eql(text));
    const added = tree.structureChange(text).?;
    try testing.expect(added.has_new and added.new_parent.eql(cell));
}

test "collection: AX 回调里提交滚动后 frame 立即一致，pump 时应用到组件" {
    var tree = AccessibilityTree.init(testing.allocator);
    defer tree.deinit();
    var list = FakeList{};
    try project(&tree, &list, &.{});
    const c = tree.collections.collectionForTable(TABLE).?;
    try testing.expectEqual(@as(u32, 0), c.visibleRange().first);
    try testing.expectEqual(@as(u32, 5), c.visibleRange().len);

    // Item 5 just below viewport bottom: .nearest scrolls one row (20pt).
    const cell5 = tree.childAt(tree.childAt(TABLE, 5).?, 0).?;
    try testing.expect(tree.collections.commitScrollToVisible(cell5));
    try testing.expectEqual(@as(f32, 20), c.committed_offset);
    try testing.expectEqual(@as(f32, 100 + 5 * 20 - 20), tree.get(cell5).?.frame.y);
    try testing.expectEqual(@as(u32, 1), c.visibleRange().first);
    // Component hasn't moved yet.
    try testing.expectEqual(@as(?f32, null), list.applied);

    // Re-submit next row in same service window: continue scrolling one row from committed offset,
    // not recalc from component offset.
    const cell6 = tree.childAt(tree.childAt(TABLE, 6).?, 0).?;
    try testing.expect(tree.collections.commitScrollToVisible(cell6));
    try testing.expectEqual(@as(f32, 40), c.committed_offset);
    // Item 3 (60..80) in committed viewport [40, 140) re-submitted: stays. Recalc from component
    // offset (0) would snap viewport to top, VO cursor row jumps away.
    const cell3 = tree.childAt(tree.childAt(TABLE, 3).?, 0).?;
    try testing.expect(tree.collections.commitScrollToVisible(cell3));
    try testing.expectEqual(@as(f32, 40), c.committed_offset);

    // Apply at pump safety point; next projection follows component offset.
    try testing.expect(tree.collections.applyPendingScroll(cell6));
    try testing.expectEqual(@as(?f32, 40), list.applied);
    try project(&tree, &list, &.{});
    try testing.expectEqual(@as(f32, 40), tree.collections.collectionForTable(TABLE).?.committed_offset);
}

test "collection: 用户在应用之前滚动过，待定提交作废" {
    var tree = AccessibilityTree.init(testing.allocator);
    defer tree.deinit();
    var list = FakeList{};
    try project(&tree, &list, &.{});
    const cell9 = tree.childAt(tree.childAt(TABLE, 9).?, 0).?;
    try testing.expect(tree.collections.commitScrollToVisible(cell9));

    list.offset = 300; // User's scroll wheel first
    try testing.expect(!tree.collections.applyPendingScroll(cell9));
    try testing.expectEqual(@as(?f32, null), list.applied);
    try project(&tree, &list, &.{});
    try testing.expectEqual(@as(f32, 300), tree.collections.collectionForTable(TABLE).?.committed_offset);

    // Projection finds user scrolled, void it too (application hasn't run yet).
    try testing.expect(tree.collections.commitScrollToVisible(cell9));
    list.offset = 500;
    try project(&tree, &list, &.{});
    try testing.expectEqual(@as(f32, 500), tree.collections.collectionForTable(TABLE).?.committed_offset);
    try testing.expect(tree.collections.applyPendingScroll(cell9));
    try testing.expectEqual(@as(?f32, null), list.applied);
}

test "collection: 数据代变化销毁本代条目，旧身份失效，行数变化发通知" {
    var tree = AccessibilityTree.init(testing.allocator);
    defer tree.deinit();
    var list = FakeList{};
    try project(&tree, &list, &.{});
    const row = tree.childAt(TABLE, 2).?;
    const cell = tree.childAt(row, 0).?;
    tree.dirty.clearRetainingCapacity();
    tree.structure_changes.clearRetainingCapacity();

    list.generation = 2;
    list.count = 10;
    try project(&tree, &list, &.{});
    try testing.expect(tree.get(row) == null);
    try testing.expect(tree.get(cell) == null);
    try testing.expect(tree.structureChange(row).?.had_old);
    try testing.expect(tree.dirty.get(TABLE.raw()).?.row_count_changed);
    try testing.expectEqual(@as(usize, 10), tree.childCount(TABLE));
    // Item 2 in new epoch is new identity.
    try testing.expect(!tree.childAt(TABLE, 2).?.eql(row));
}

test "collection: 注销后不再调用 provider，条目随之失效" {
    var tree = AccessibilityTree.init(testing.allocator);
    defer tree.deinit();
    var list = FakeList{};
    try project(&tree, &list, &.{});
    const row = tree.childAt(TABLE, 1).?;

    try tree.retireCollection(TABLE);
    list.retired = true; // Any provider call triggers assertion afterwards
    try testing.expect(tree.get(row) == null);
    try testing.expect(tree.collections.collectionForTable(TABLE) == null);
    try testing.expectEqual(@as(usize, 0), tree.childCount(row));
    try testing.expect(tree.collections.hitTest(testing.allocator, 50, 150) == null);
    // Table node itself still fetched as normal node, frame no longer overwritten by collection.
    _ = tree.get(TABLE);
}

test "collection: 表格不再被投影时整体退出" {
    var tree = AccessibilityTree.init(testing.allocator);
    defer tree.deinit();
    var list = FakeList{};
    try project(&tree, &list, &.{});
    const row = tree.childAt(TABLE, 1).?;
    tree.beginProjection();
    try tree.finishProjection();
    try testing.expect(tree.get(row) == null);
    try testing.expect(tree.collections.collectionForTable(TABLE) == null);
}

test "collection: 命中测试落在视口内的条目上" {
    var tree = AccessibilityTree.init(testing.allocator);
    defer tree.deinit();
    var list = FakeList{ .offset = 40 };
    try project(&tree, &list, &.{});
    // y=150 at 50pt inside viewport, plus offset 40 -> content y=90 -> item 4; unbound returns
    // cell_text.
    const hit = tree.collections.hitTest(testing.allocator, 50, 150).?;
    try testing.expectEqual(AXId.Kind.cell_text, hit.id.kind);
    try testing.expectEqual(@as(u32, 4), tree.get(hit.id).?.row_index);
    try testing.expect(tree.collections.hitTest(testing.allocator, 50, 250) == null);
}

test "collection: 条目槽位代际推到上限后永久退役" {
    var reg = Registry{};
    defer reg.deinit(testing.allocator);
    try reg.collections.append(testing.allocator, .{
        .table = TABLE,
        .provider = undefined,
        .data_generation = 0,
        .count = 1,
        .viewport = .{},
        .content = .{},
        .committed_offset = 0,
        .seen_epoch = 0,
        .hidden = false,
    });
    var first: ?u24 = null;
    var cycles: usize = 0;
    while (cycles < 300) : (cycles += 1) {
        const slot = try reg.ensureItem(testing.allocator, 0, 0);
        if (first == null) first = slot.index;
        if (slot.index != first.?) break;
        try testing.expect(slot.generation != ItemSlot.RETIRED);
        _ = reg.collectionPtr(0).items.remove(0);
        reg.freeItem(slot.index);
    }
    // First slot not reused after full generations, gets new slot.
    try testing.expect(cycles < 300);
    try testing.expectEqual(ItemSlot.RETIRED, reg.items.items[first.?].generation);
}

test "collection: 提交滚动后，绑定行内节点的 frame 与条目一起平移" {
    var tree = AccessibilityTree.init(testing.allocator);
    defer tree.deinit();
    var list = FakeList{};
    try project(&tree, &list, &.{4});
    const content = AXId.node(.{ .index = 100, .generation = 0 });
    const cell4 = tree.childAt(tree.childAt(TABLE, 4).?, 0).?;
    try testing.expectEqual(tree.get(cell4).?.frame.y, tree.get(content).?.frame.y);

    const cell7 = tree.childAt(tree.childAt(TABLE, 7).?, 0).?;
    try testing.expect(tree.collections.commitScrollToVisible(cell7));
    // Projection hasn't re-run: entries and row nodes already translated by committed offset (60).
    try testing.expectEqual(@as(f32, 100 + 4 * 20 - 60), tree.get(cell4).?.frame.y);
    try testing.expectEqual(tree.get(cell4).?.frame.y, tree.get(content).?.frame.y);
}

test "collection: 行数缩小而数据代未变时，越界条目失效而不是调 provider 越界" {
    var tree = AccessibilityTree.init(testing.allocator);
    defer tree.deinit();
    var list = FakeList{};
    try project(&tree, &list, &.{});
    const row = tree.childAt(TABLE, 900).?;
    list.count = 100; // Violates contract: data epoch not advanced
    try project(&tree, &list, &.{});
    try testing.expect(tree.get(row) == null);
}

test "collection: 隐藏的集合不接受程序化滚动" {
    var tree = AccessibilityTree.init(testing.allocator);
    defer tree.deinit();
    var list = FakeList{};
    try project(&tree, &list, &.{});
    const cell9 = tree.childAt(tree.childAt(TABLE, 9).?, 0).?;
    tree.beginProjection();
    try tree.upsert(.{ .element = TABLE, .role = .grid });
    _ = try tree.syncCollection(TABLE, list.provider(), true);
    try tree.finishProjection();
    try testing.expect(!tree.collections.commitScrollToVisible(cell9));
    try testing.expectEqual(@as(f32, 0), tree.collections.collectionForTable(TABLE).?.committed_offset);
}
