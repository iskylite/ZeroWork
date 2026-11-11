//! Retained timeline rows. Each row owns its scope; a reset removes only the
//! changed suffix. Group headers survive stream updates and detail disclosure.
const std = @import("std");
const ui = @import("ui");
pub const Group = @import("ai_step_group_view.zig");
pub const Row = struct {
    first: usize,
    kind: enum { message, input, notice, group, step },
    root: *ui.Node,
    scope: *ui.Scope,
    fingerprint: ?u64 = null,
    group: ?Group.Result = null,
    body: ?*ui.Node = null,
    body_scope: ?*ui.Scope = null,
    body_fingerprint: ?u64 = null,
    details: ?*View = null,
    prose: ?*@import("ai_message_view.zig").Retained = null,
    notes_citations_mounted: bool = false,
    step: ?@import("ai_step_view.zig").Result = null,
    source_key: u64 = 0,
};
pub const View = struct {
    cx: *ui.Cx,
    scope: *ui.Scope,
    root: *ui.Node,
    context: *anyopaque,
    sync: *const fn (*anyopaque, *View) anyerror!void,
    on_toggle: ui.Handler(void),
    rows: std.ArrayList(*Row) = .empty,
    dirty: bool = true,

    pub fn mount(cx: *ui.Cx, scope: *ui.Scope, parent: *ui.Node, context: *anyopaque, sync: *const fn (*anyopaque, *View) anyerror!void, on_toggle: ui.Handler(void)) !*View {
        const root = try ui.box(cx, .{ .width = .fill(), .height = .{ .fit = .{} }, .direction = .column, .gap = 8, .flex_shrink = 0, .min_width = 0 }, .{});
        root.meta.ownership.meta.test_id = "ai.timeline";
        const self = try scope.createState(View, .{ .cx = cx, .scope = scope, .root = root, .context = context, .sync = sync, .on_toggle = on_toggle });
        try scope.onCleanup(View, self, cleanup);
        try cx.addAfterLayoutHook(self, tick);
        try parent.appendChild(cx.allocator, root);
        return self;
    }
    fn cleanup(self: *View) void {
        self.cx.removeAfterLayoutHook(self);
        self.rows.deinit(self.cx.allocator);
    }
    pub fn invalidate(self: *View) void {
        self.dirty = true;
        self.cx.requestRedraw();
    }
    pub fn toggled(self: *View) void {
        self.on_toggle.invoke();
        self.invalidate();
    }
    fn tick(raw: *anyopaque, _: u8, _: bool) ui.AfterLayoutResult {
        const self: *View = @ptrCast(@alignCast(raw));
        if (!self.dirty) return .done;
        self.dirty = false;
        self.sync(self.context, self) catch return .done;
        return .needs_layout;
    }
    pub fn truncate(self: *View, count: usize) void {
        while (self.rows.items.len > count) {
            const removed = self.rows.pop().?;
            const root = removed.root;
            const scope = removed.scope;
            self.cx.detachChild(self.root, root);
            scope.dispose();
            self.cx.destroyDetached(root);
        }
    }
    pub fn row(self: *View, slot: usize, first: usize, kind: @FieldType(Row, "kind")) !*Row {
        if (slot < self.rows.items.len) {
            const old = self.rows.items[slot];
            if (old.first == first and old.kind == kind) return old;
            self.truncate(slot);
        }
        try self.rows.ensureUnusedCapacity(self.cx.allocator, 1);
        const scope = try self.scope.childScope();
        errdefer scope.dispose();
        const root = try ui.box(self.cx, .{ .width = .fill(), .height = .{ .fit = .{} }, .direction = .column, .gap = 8, .min_width = 0, .flex_shrink = 0 }, .{});
        const result = try scope.createState(Row, .{ .first = first, .kind = kind, .root = root, .scope = scope });
        try self.root.appendChild(self.cx.allocator, root);
        self.rows.appendAssumeCapacity(result);
        return result;
    }
    pub fn clearBody(self: *View, row_value: *Row) void {
        const container = row_value.body orelse return;
        // Clear borrowed pointers before disposing callbacks and descendant nodes.
        const scope = row_value.body_scope;
        row_value.body_scope = null;
        row_value.details = null;
        row_value.prose = null;
        row_value.notes_citations_mounted = false;
        row_value.step = null;
        row_value.body_fingerprint = null;
        if (scope) |value| value.dispose();
        while (container.children.items.len > 0) {
            const node = container.children.items[container.children.items.len - 1];
            self.cx.detachChild(container, node);
            self.cx.destroyDetached(node);
        }
    }
    pub fn body(self: *View, row_value: *Row, parent: *ui.Node) !*ui.Node {
        if (row_value.body == null) {
            const node = try ui.box(self.cx, .{ .width = .fill(), .height = .{ .fit = .{} }, .direction = .column, .gap = 6, .min_width = 0, .flex_shrink = 0 }, .{});
            try parent.appendChild(self.cx.allocator, node);
            row_value.body = node;
        }
        return row_value.body.?;
    }
};
