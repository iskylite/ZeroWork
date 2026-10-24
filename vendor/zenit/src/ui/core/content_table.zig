//! ContentTable: NodeContent SoA, dense by ElementId.
//! One-to-one with ElementTable: ensureSlot is synced at element creation.
//! Currently dual-write: Node.visuals.content is still the source of truth and this table mirrors
//! it,
//! in preparation for switching the read path.
//! TextProps inline_buf is a self-referential slice: the set path must fixupAfterMove.
//! ImageProps/IconProps have no self-refs; copy values normally.

const std = @import("std");
const testing = std.testing;
const element_id_mod = @import("element_id.zig");
const types = @import("types.zig");

pub const ElementId = element_id_mod.ElementId;
pub const TextProps = types.TextProps;
pub const ImageProps = types.ImageProps;
pub const IconProps = types.IconProps;

/// Single-element content mirror (text + media).
/// Aligns with node.zig NodeContent / NodeMedia fields.
pub const ContentData = struct {
    text: ?TextProps = null,
    image: ?ImageProps = null,
    icon: ?IconProps = null,
};

pub const ContentTable = struct {
    allocator: std.mem.Allocator,
    items: std.ArrayListUnmanaged(ContentData),
    /// Replaced owned content/spans on text change: prior frame text blob and cached commands still
    /// borrow them (blob content lifetime until next-frame blob reset); don't release immediately;
    /// releaseRetired frees at next-frame blob reset. Node destroy doesn't go here (node already
    /// invisible).
    retired_content: std.ArrayListUnmanaged([]const u8) = .empty,
    retired_spans: std.ArrayListUnmanaged([]const types.TextSpan) = .empty,

    pub fn init(allocator: std.mem.Allocator) ContentTable {
        return .{ .allocator = allocator, .items = .empty };
    }

    pub fn deinit(self: *ContentTable) void {
        self.releaseRetired();
        self.retired_content.deinit(self.allocator);
        self.retired_spans.deinit(self.allocator);
        self.items.deinit(self.allocator);
        self.* = undefined;
    }

    /// Release swapped-out old text (frame boundary call: prior frame's borrows now all invalid).
    pub fn releaseRetired(self: *ContentTable) void {
        for (self.retired_content.items) |c| self.allocator.free(c);
        self.retired_content.clearRetainingCapacity();
        for (self.retired_spans.items) |s| self.allocator.free(s);
        self.retired_spans.clearRetainingCapacity();
    }

    /// Grow items and re-fixup all entry inline_buf self-refs.
    /// ArrayList realloc moves entries to new address; old inline_buf slices invalid;
    /// must re-fixup entire table.
    pub fn ensureSlot(self: *ContentTable, id: ElementId) !void {
        if (id.isNull()) return;
        const idx = id.index;
        if (self.items.items.len > idx) return;
        const old_ptr = if (self.items.items.len > 0) @intFromPtr(self.items.items.ptr) else 0;
        // One fallible reservation precedes all moves/length changes. A later
        // append must not fail after relocation but before inline fixups.
        try self.items.ensureTotalCapacity(self.allocator, @as(usize, idx) + 1);
        while (self.items.items.len <= idx) {
            self.items.appendAssumeCapacity(.{});
        }
        const new_ptr = @intFromPtr(self.items.items.ptr);
        if (old_ptr != 0 and old_ptr != new_ptr) {
            // Memory moved; all text inline_buf slices invalid; re-fixup each entry.
            for (self.items.items) |*entry| {
                if (entry.text) |*tt| tt.fixupAfterMove();
            }
        }
    }

    pub fn get(self: *const ContentTable, id: ElementId) ?ContentData {
        const entry = self.getPtr(id) orelse return null;
        return entry.*;
    }

    /// Borrowed entry. `ContentData` carries a whole `TextProps` (inline text
    /// buffer included); per-node readers that want one field (image, icon)
    /// must not copy the entry to get it.
    pub fn getPtr(self: *const ContentTable, id: ElementId) ?*const ContentData {
        if (id.isNull() or id.index >= self.items.items.len) return null;
        return &self.items.items[id.index];
    }

    /// Return TextProps value copy. After caller receives copy, content still points
    /// ContentTable internal inline_buf; intentional (caller usually reads immediately,
    /// doesn't copy struct). If caller `var t = getText().?; ... node.setText(t)`,
    /// setText re-fixups stored entry's inline_buf for consistency.
    pub fn getText(self: *const ContentTable, id: ElementId) ?TextProps {
        if (id.isNull() or id.index >= self.items.items.len) return null;
        return self.items.items[id.index].text;
    }

    /// Write text; fixupAfterMove redirects inline_buf self-ref slice to new storage address.
    /// Smart fixup: only if content bytes match inline_buf[0..inline_len] treat as inline-storage,
    /// redirect to slot's inline_buf; else keep external slice.
    pub fn setText(self: *ContentTable, id: ElementId, t: ?TextProps) void {
        if (id.isNull() or id.index >= self.items.items.len) return;
        var slot = &self.items.items[id.index];
        // Release old owned content/spans on text change; else swapped dupe leaks permanently.
        // Pointer guard: caller `getText -> modify field -> setText` writing back same memory can't
        // free.
        if (slot.text) |old| {
            const new_content_ptr: ?[*]const u8 = if (t) |nt| nt.content.ptr else null;
            const new_spans_ptr: ?[*]const types.TextSpan = if (t) |nt| nt.spans.ptr else null;
            // Retire instead of immediate release (see retired_content); fall back to immediate
            // release if registration fails.
            if (old.owned and old.content.len > 0 and old.content.ptr != new_content_ptr) {
                self.retired_content.append(self.allocator, old.content) catch self.allocator.free(old.content);
            }
            if (old.spans_owned and old.spans.len > 0 and old.spans.ptr != new_spans_ptr) {
                self.retired_spans.append(self.allocator, old.spans) catch self.allocator.free(old.spans);
            }
        }
        slot.text = t;
        if (slot.text) |*tt| {
            if (tt.inline_len > 0 and t.?.content.len == tt.inline_len) {
                if (std.mem.eql(u8, t.?.content, tt.inline_buf[0..tt.inline_len])) {
                    tt.content = tt.inline_buf[0..tt.inline_len];
                }
            }
        }
    }

    pub fn setImage(self: *ContentTable, id: ElementId, img: ?ImageProps) void {
        if (id.isNull() or id.index >= self.items.items.len) return;
        self.items.items[id.index].image = img;
    }

    pub fn setIcon(self: *ContentTable, id: ElementId, ic: ?IconProps) void {
        if (id.isNull() or id.index >= self.items.items.len) return;
        self.items.items[id.index].icon = ic;
    }

    /// Called by Cx.destroyElement; no shrinking (dense by index).
    pub fn clear(self: *ContentTable, id: ElementId) void {
        if (id.isNull() or id.index >= self.items.items.len) return;
        self.items.items[id.index] = .{};
    }
};

// ============================================================================
// Tests
// ============================================================================

test "ContentTable: init/deinit empty" {
    var t = ContentTable.init(testing.allocator);
    defer t.deinit();
    try testing.expectEqual(@as(usize, 0), t.items.items.len);
}

test "ContentTable: ensureSlot grows up to index" {
    var t = ContentTable.init(testing.allocator);
    defer t.deinit();

    const id = ElementId{ .index = 3, .generation = 1 };
    try t.ensureSlot(id);
    try testing.expectEqual(@as(usize, 4), t.items.items.len);
    try testing.expect(t.getText(id) == null);
}

test "ContentTable: setText / getText roundtrip with inline_buf fixup" {
    var t = ContentTable.init(testing.allocator);
    defer t.deinit();

    const id = ElementId{ .index = 0, .generation = 1 };
    try t.ensureSlot(id);

    var src_text: TextProps = .{ .font_size = 16 };
    try src_text.setInlineContent("hi");

    t.setText(id, src_text);

    const got = t.getText(id).?;
    try testing.expectEqual(@as(f32, 16), got.font_size);
    try testing.expectEqualSlices(u8, "hi", got.content);
}

test "ContentTable: setImage / setIcon" {
    var t = ContentTable.init(testing.allocator);
    defer t.deinit();

    const id = ElementId{ .index = 0, .generation = 1 };
    try t.ensureSlot(id);

    t.setImage(id, .{ .texture_id = 42 });
    t.setIcon(id, .{ .icon_id = 7, .rep = .{ .size = 24, .shapes = &.{} } });

    const got = t.get(id).?;
    try testing.expectEqual(@as(u32, 42), got.image.?.texture_id);
    try testing.expectEqual(@as(u16, 7), got.icon.?.icon_id);
}

test "ContentTable: clear resets slot" {
    var t = ContentTable.init(testing.allocator);
    defer t.deinit();

    const id = ElementId{ .index = 0, .generation = 1 };
    try t.ensureSlot(id);
    var tp: TextProps = .{};
    try tp.setInlineContent("x");
    t.setText(id, tp);

    t.clear(id);
    try testing.expect(t.getText(id) == null);
}

test "ContentTable: setText frees replaced owned content" {
    var t = ContentTable.init(testing.allocator);
    defer t.deinit();

    const id = ElementId{ .index = 0, .generation = 1 };
    try t.ensureSlot(id);

    const first = try testing.allocator.dupe(u8, "first owned content!");
    t.setText(id, .{ .content = first, .owned = true });

    // Swap to new owned content: old first should auto-release via setText (leak detected by
    // testing.allocator).
    const second = try testing.allocator.dupe(u8, "second owned content");
    t.setText(id, .{ .content = second, .owned = true });
    try testing.expectEqualStrings("second owned content", t.getText(id).?.content);

    // Write back same memory unchanged: don't mistakenly free.
    var same = t.getText(id).?;
    same.color = .{ .r = 1, .g = 0, .b = 0, .a = 1 };
    t.setText(id, same);
    try testing.expectEqualStrings("second owned content", t.getText(id).?.content);

    // Cleanup: simulate node destroy path to release final owned content.
    if (t.getText(id)) |last| {
        if (last.owned) testing.allocator.free(last.content);
    }
}
