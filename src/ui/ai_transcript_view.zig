//! Retained transcript rows. Each logical section of the conversation owns a
//! stable row node and a private scope. A content fingerprint decides whether
//! the row is left untouched (no node destruction, no remeasure, no focus loss)
//! or only that row's body is re-rendered. This replaces the old whole-tree
//! teardown, which dropped scroll offsets, disclosure geometry and widget state
//! on every refresh.
const std = @import("std");
const ui = @import("ui");

pub const Kind = enum { history, virtual, live, cards, compaction, steer, recovery, empty };

/// One desired section of the transcript. `key` is a stable business identity;
/// `fingerprint` covers every input that section renders.
pub const Spec = struct {
    key: u64,
    kind: Kind,
    fingerprint: u64,
    arg: usize = 0,
    context: *anyopaque,
    render: *const fn (*anyopaque, usize, *ui.Scope, *ui.Node) anyerror!void,
    /// Update a retained body (e.g. a virtual list) when its data changes.
    update: ?*const fn (*anyopaque, usize, *ui.Scope, *ui.Node) anyerror!void = null,
    /// Called immediately before this section's body is re-rendered or the
    /// whole section is removed. The owner drops retained pointers into that
    /// body's scope/nodes here, before disposal invalidates them.
    invalidate: ?*const fn (*anyopaque) void = null,
};

pub const Row = struct {
    key: u64,
    kind: Kind,
    root: *ui.Node,
    scope: *ui.Scope,
    body_scope: ?*ui.Scope = null,
    fingerprint: ?u64 = null,
    /// Optional retained widget owned by this row (e.g. the virtual history view).
    extra: ?*anyopaque = null,
    context: ?*anyopaque = null,
    invalidate: ?*const fn (*anyopaque) void = null,
};

pub const View = struct {
    cx: *ui.Cx,
    scope: *ui.Scope,
    parent: *ui.Node,
    rows: std.ArrayList(*Row) = .empty,

    pub fn mount(cx: *ui.Cx, scope: *ui.Scope, parent: *ui.Node) !*View {
        const self = try scope.createState(View, .{ .cx = cx, .scope = scope, .parent = parent });
        try scope.onCleanup(View, self, cleanup);
        return self;
    }
    /// Node destruction is owned by the parent tree; only the ledger is freed.
    fn cleanup(self: *View) void {
        self.rows.deinit(self.cx.allocator);
    }

    /// Match by identity, including retained rows shifted by an insertion or
    /// removal. sync retires unmatched rows before building the desired order.
    pub fn row(self: *View, slot: usize, key: u64, kind: Kind) !*Row {
        if (slot < self.rows.items.len) {
            const old = self.rows.items[slot];
            if (old.key == key and old.kind == kind) return old;
            for (self.rows.items[slot + 1 ..], slot + 1..) |candidate, index| {
                if (candidate.key != key or candidate.kind != kind) continue;
                try self.parent.insertChildBefore(self.cx.allocator, candidate.root, old.root);
                _ = self.rows.orderedRemove(index);
                self.rows.insertAssumeCapacity(slot, candidate);
                return candidate;
            }
        }
        try self.rows.ensureUnusedCapacity(self.cx.allocator, 1);
        const scope = try self.scope.childScope();
        errdefer scope.dispose();
        // The conversation itself keeps a 6px column gap. Mirroring it on the
        // section root preserves the exact spacing of the former flat child list.
        const root = try ui.box(self.cx, .{
            .width = .fill(),
            .height = .{ .fit = .{} },
            .direction = .column,
            .gap = 6,
            .min_width = 0,
            .flex_shrink = 0,
        }, .{});
        errdefer self.cx.destroyDetached(root);
        const result = try scope.createState(Row, .{ .key = key, .kind = kind, .root = root, .scope = scope });
        try self.parent.insertChildBefore(self.cx.allocator, root, if (slot < self.rows.items.len) self.rows.items[slot].root else null);
        self.rows.insertAssumeCapacity(slot, result);
        return result;
    }

    /// Re-render one section in place: the row node and its scope survive, only
    /// the body subtree and the body's child scope are replaced.
    pub fn clearBody(self: *View, row_value: *Row) void {
        row_value.extra = null;
        row_value.fingerprint = null;
        if (row_value.body_scope) |scope| {
            row_value.body_scope = null;
            scope.dispose();
        }
        while (row_value.root.children.items.len > 0) {
            const child = row_value.root.children.items[row_value.root.children.items.len - 1];
            self.cx.detachChild(row_value.root, child);
            self.cx.destroyDetached(child);
        }
    }

    fn remove(self: *View, index: usize) void {
        const removed = self.rows.orderedRemove(index);
        if (removed.invalidate) |hook| if (removed.context) |context| hook(context);
        const root = removed.root;
        const scope = removed.scope;
        self.cx.detachChild(self.parent, root);
        scope.dispose();
        self.cx.destroyDetached(root);
    }

    pub fn truncate(self: *View, count: usize) void {
        while (self.rows.items.len > count) self.remove(self.rows.items.len - 1);
    }

    /// Returns true when at least one section was created, removed or
    /// re-rendered, so the caller can request a layout only when necessary.
    pub fn sync(self: *View, specs: []const Spec) !bool {
        var changed = false;
        // Retire old owners before rendering any replacement. Otherwise a late
        // invalidation hook can clear pointers just published by the new body.
        var remaining = self.rows.items.len;
        while (remaining > 0) {
            remaining -= 1;
            const old = self.rows.items[remaining];
            const retained = for (specs) |spec| {
                if (spec.key == old.key and spec.kind == old.kind) break true;
            } else false;
            if (!retained) {
                self.remove(remaining);
                changed = true;
            }
        }
        for (specs, 0..) |spec, slot| {
            const same_slot = slot < self.rows.items.len and self.rows.items[slot].key == spec.key and self.rows.items[slot].kind == spec.kind;
            const row_value = try self.row(slot, spec.key, spec.kind);
            changed = changed or !same_slot;
            row_value.context = spec.context;
            row_value.invalidate = spec.invalidate;
            if (row_value.fingerprint == spec.fingerprint) continue;
            changed = true;
            if (spec.update) |update| if (row_value.body_scope) |body_scope| {
                errdefer {
                    if (spec.invalidate) |hook| hook(spec.context);
                    self.clearBody(row_value);
                }
                try update(spec.context, spec.arg, body_scope, row_value.root);
                row_value.fingerprint = spec.fingerprint;
                continue;
            };
            if (spec.invalidate) |hook| hook(spec.context);
            self.clearBody(row_value);
            const body_scope = try row_value.scope.childScope();
            row_value.body_scope = body_scope;
            errdefer {
                if (spec.invalidate) |hook| hook(spec.context);
                self.clearBody(row_value);
            }
            try spec.render(spec.context, spec.arg, body_scope, row_value.root);
            row_value.root.setDisplay(if (row_value.root.children.items.len == 0) .none else .flex);
            row_value.fingerprint = spec.fingerprint;
        }
        if (self.rows.items.len != specs.len) changed = true;
        self.truncate(specs.len);
        return changed;
    }
};

/// Rebind borrowed Turn addresses when the host's history ArrayList moves, or
/// when the completed current turn is moved into history. The nested arrays and
/// segments retain their allocations; only pointers into the Turn itself move.
pub const TurnBindings = struct {
    const Turn = @import("../ai/conversation_turn.zig").Turn;
    const Step = @import("ai_step_view.zig").Result;
    const Target = union(enum) { turn: **Turn, thinking: Step };
    const Link = struct {
        owner: *TurnBindings,
        next: ?*Link,
        index: usize,
        id: u64,
        target: Target,
        fn cleanup(self: *Link) void {
            var cursor = &self.owner.head;
            while (cursor.*) |link| {
                if (link == self) {
                    cursor.* = self.next;
                    return;
                }
                cursor = &link.next;
            }
        }
    };
    head: ?*Link = null,
    pub fn bind(self: *TurnBindings, scope: *ui.Scope, index: usize, turn: *Turn, target: Target) !void {
        const link = try scope.createState(Link, .{ .owner = self, .next = self.head, .index = index, .id = turn.id, .target = target });
        try scope.onCleanup(Link, link, Link.cleanup);
        self.head = link;
    }
    pub fn rebind(self: *TurnBindings, history: anytype) void {
        var cursor = self.head;
        while (cursor) |link| : (cursor = link.next) {
            if (link.index >= history.len) continue;
            if (history[link.index].turn) |*turn| {
                if (turn.id != link.id) continue;
                switch (link.target) {
                    .turn => |pointer| pointer.* = turn,
                    .thinking => |step| step.rebindExpanded(&turn.thinking_expanded),
                }
            }
        }
    }
};
