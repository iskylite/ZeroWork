//! Publish a complete owned UIA snapshot on the UI thread after projection.
const std = @import("std");
const ui = @import("ui");
const platform = @import("platform");
const Tree = @FieldType(ui.Cx, "accessibility_tree");
const Nodes = @FieldType(Tree, "nodes");
const Items = @FieldType(Nodes, "items");
const TreeNode = @typeInfo(@typeInfo(Items).pointer.child).optional.child;
/// Roles reviewed against control_type() in native/windows/accessibility_bridge.cpp.
/// An unmapped role degrades to a UIA Pane (it never rejects the tree), so this
/// only makes a new role a deliberate mapping decision instead of a silent one.
const reviewed_role_count = 55;
comptime {
    const roles = @import("zenit_reflection").fields(@FieldType(TreeNode, "role")).len;
    if (roles != reviewed_role_count) @compileError(std.fmt.comptimePrint(
        "ui.a11y.Role has {d} values; map the new roles in control_type() (accessibility_bridge.cpp), then set reviewed_role_count to {d}",
        .{ roles, roles },
    ));
}
const Text = extern struct { bytes: ?[*]const u8 = null, length: usize = 0 };
const Offsets = extern struct { bytes: ?[*]const u32 = null, count: usize = 0 };
const GeometrySegment = extern struct { start: u32, end: u32, x: f32, y: f32, width: f32, height: f32 };
const Geometry = extern struct { segments: ?[*]const GeometrySegment = null, count: usize = 0 };
const CaretCandidate = extern struct {
    offset: u32,
    first_x: f32,
    first_y: f32,
    last_x: f32,
    last_y: f32,
    visible_first_x: f32,
    visible_first_y: f32,
    visible_last_x: f32,
    visible_last_y: f32,
    downstream: u8,
    visible: u8,
};
const Carets = extern struct { candidates: ?[*]const CaretCandidate = null, count: usize = 0 };
const Node = extern struct {
    id: u32,
    parent_index: u32,
    state: u32,
    role: u16,
    actions: u8,
    numeric: u8,
    setters: u8,
    x: f32,
    y: f32,
    width: f32,
    height: f32,
    value_now: f64,
    value_min: f64,
    value_max: f64,
    small_change: f64,
    large_change: f64,
    name: Text,
    description: Text,
    value: Text,
    identifier: Text,
    editable: u8,
    can_set_selection: u8,
    uniform_format: u8,
    can_scroll: u8,
    selection_start: u32,
    selection_end: u32,
    caret: u32,
    visible_start: u32,
    visible_end: u32,
    characters: Offsets,
    words: Offsets,
    paragraphs: Offsets,
    lines: Offsets,
    geometry_ready: u8,
    geometry: Geometry,
    carets_ready: u8,
    carets: Carets,
    rows_ready: u8,
    rows: Geometry,
};
extern fn zenit_windows_publish_accessibility(window: *anyopaque, nodes: ?[*]const Node, count: usize) c_int;
extern fn zenit_uia_node_size() usize;
const ActionCallback = *const fn (?*anyopaque, u32, u8, ?[*]const u8, usize, f64) callconv(.c) c_int;
extern fn zenit_windows_set_accessibility_action(window: *anyopaque, context: ?*anyopaque, callback: ?ActionCallback) c_int;
extern fn zenit_windows_drain_accessibility(window: *anyopaque) c_int;
extern fn zenit_a11y_set_text_selection(window_id: u32, handle: u64, start: u32, end: u32) c_int;
extern fn zenit_a11y_set_text_value(window_id: u32, handle: u64, bytes: ?[*]const u8, length: c_int) c_int;
extern fn zenit_a11y_set_numeric_value(window_id: u32, handle: u64, value: f32) c_int;
extern fn zenit_a11y_perform_action(window_id: u32, handle: u64, action: u8) c_int;
extern fn zenit_a11y_set_focus(window_id: u32, handle: u64, focused: c_int) c_int;
const AXId = ui.a11y.AXId;
const null_id = std.math.maxInt(u32);
const Range = struct { start: usize, end: usize };
const Pending = struct { source: usize, parent: u32 };

/// UIA snapshot element id is 32-bit ElementId raw (C++ side Node.id). Node identity AXId
/// handle is ElementId zero-extended, mutual conversion loses no information.
fn handle(raw: u32) u64 {
    return AXId.fromRaw(raw).raw();
}
fn nodeRaw(node: TreeNode) u32 {
    return node.element.payload;
}

/// Node connected to root via parent chain of 'node identity'. Collection entries (virtual list
/// rows / cells, AXId kind
/// != node) synthesized by a11y layer on demand, not in dense node table; UIA bridge currently
/// publishes only nodes, nodes
/// hanging under collection entries thus unreachable, entire subtree skipped rather than marking
/// whole snapshot disconnected.
fn connectedThroughNodes(tree: anytype, node: TreeNode) bool {
    var parent = node.parent;
    for (0..tree.nodes.items.len + 1) |_| {
        if (parent.isNull()) return true;
        if (parent.kind != .node) return false;
        const p = tree.get(parent) orelse return false;
        if (p.state.hidden) return false;
        parent = p.parent;
    }
    return false;
}

fn itemContainer(cx: *ui.Cx, node: TreeNode) ?TreeNode {
    const expected: @TypeOf(node.role) = switch (node.role) {
        .radio => .radiogroup,
        .listitem => .listbox,
        .treeitem => .tree,
        .tab => .tabs,
        else => return null,
    };
    var current = node;
    for (0..cx.accessibility_tree.nodes.items.len) |_| {
        const parent = cx.accessibility_tree.get(current.parent) orelse return null;
        switch (parent.role) {
            .radiogroup, .listbox, .tree, .tabs => return if (parent.role == expected) parent else null,
            else => current = parent,
        }
    }
    return null;
}

fn perform(context: ?*anyopaque, raw: u32, action: u8, bytes: ?[*]const u8, length: usize, number: f64) callconv(.c) c_int {
    const cx: *ui.Cx = @ptrCast(@alignCast(context orelse return 0));
    const root = cx.root orelse return 0;
    // Deferred updates and earlier actions may have removed/disabled a control
    // since its last presentation. Reproject before touching the live handler.
    cx.syncA11yTreeFromInteractions(root);
    const node = cx.accessibility_tree.get(AXId.fromRaw(raw)) orelse return 0;
    if (node.state.hidden or node.state.disabled) return 0;
    switch (action) {
        2 => {
            if (!node.state.focusable) return 0;
            return zenit_a11y_set_focus(cx.native_window_id, handle(raw), 1);
        },
        0 => {
            if (!node.actions.press) return 0;
            switch (node.role) {
                .button, .link, .menuitem => {},
                else => return 0,
            }
        },
        1 => {
            if (!node.actions.toggle or node.state.readonly) return 0;
            switch (node.role) {
                .checkbox, .menuitemcheckbox, .switch_control => {},
                else => return 0,
            }
        },
        9, 10 => {
            if (!node.can_set_expanded or node.state.readonly) return 0;
            return @intFromBool(cx.setA11yExpanded(raw, action == 9));
        },
        6, 7, 8 => {
            if (node.can_set_item_selection) {
                const group = itemContainer(cx, node) orelse return 0;
                if (group.state.disabled or group.state.hidden or group.state.readonly) return 0;
                if (action == 7 and !group.state.multiselectable) {
                    for (cx.accessibility_tree.nodes.items) |entry| {
                        const sibling = entry orelse continue;
                        const container = itemContainer(cx, sibling) orelse continue;
                        if (container.element.eql(group.element) and nodeRaw(sibling) != raw and sibling.state.selected) return 0;
                    }
                }
                if (action == 8 and group.state.required and node.state.selected) {
                    var count: usize = 0;
                    for (cx.accessibility_tree.nodes.items) |entry| {
                        const sibling = entry orelse continue;
                        const container = itemContainer(cx, sibling) orelse continue;
                        if (container.element.eql(group.element) and sibling.state.selected) count += 1;
                    }
                    if (count <= 1) return 0;
                }
                return @intFromBool(cx.setA11yItemSelection(raw, switch (action) {
                    6 => .replace,
                    7 => .add,
                    else => .remove,
                }));
            }
            if (action == 8) return 0;
            if (node.role != .radio or !node.actions.press or node.state.readonly) return 0;
            const group = cx.accessibility_tree.get(node.parent) orelse return 0;
            if (group.role != .radiogroup) return 0;
            if (action == 7) {
                for (cx.accessibility_tree.nodes.items) |entry| {
                    const sibling = entry orelse continue;
                    if (sibling.parent.eql(group.element) and sibling.role == .radio and
                        nodeRaw(sibling) != raw and sibling.state.checked) return 0;
                }
            }
            if (node.state.checked) return 1;
            return zenit_a11y_perform_action(cx.native_window_id, handle(raw), 0);
        },
        11, 12 => {
            const editable = node.editable_text orelse return 0;
            if ((action == 11 and !editable.can_set_selection) or
                (action == 12 and (!editable.can_scroll or (number != 0 and number != 1))) or
                node.state.secure or bytes == null or length < 8 or length > 256 * 1024) return 0;
            const payload = bytes.?[0..length];
            const expected = payload[8..];
            const current = text(cx, node.text_hash);
            const current_bytes: []const u8 = if (current.bytes) |ptr| ptr[0..current.length] else "";
            if (!std.mem.eql(u8, expected, current_bytes)) return 0;
            const start = std.mem.readInt(u32, payload[0..4], .little);
            const end = std.mem.readInt(u32, payload[4..8], .little);
            if (start > expected.len or end > expected.len) return 0;
            if (action == 12) return @intFromBool(cx.scrollA11yTextRange(raw, start, end, number == 1));
            return zenit_a11y_set_text_selection(cx.native_window_id, handle(raw), start, end);
        },
        4 => {
            const editable = node.editable_text orelse return 0;
            if (!editable.can_set_value or node.state.readonly or length > 65536 or (length > 0 and bytes == null)) return 0;
            switch (node.role) {
                .textbox, .textarea, .searchbox => {},
                else => return 0,
            }
            return zenit_a11y_set_text_value(cx.native_window_id, handle(raw), bytes, @intCast(length));
        },
        5 => {
            if (!node.can_set_numeric_value or node.state.readonly or !std.math.isFinite(number) or number < node.value_min or number > node.value_max) return 0;
            switch (node.role) {
                .slider, .spinbutton, .progressbar => {},
                else => return 0,
            }
            const value: f32 = @floatCast(number);
            if (!std.math.isFinite(value)) return 0;
            return zenit_a11y_set_numeric_value(cx.native_window_id, handle(raw), value);
        },
        else => return 0,
    }
    return zenit_a11y_perform_action(cx.native_window_id, handle(raw), action);
}
pub fn install(cx: *ui.Cx, window: *platform.Window) !void {
    if (zenit_windows_set_accessibility_action(window.native, cx, &perform) == 0)
        return error.AccessibilityHandlerInstallFailed;
}
pub fn detach(window: *platform.Window) void {
    _ = zenit_windows_set_accessibility_action(window.native, null, null);
}
pub fn drain(window: *platform.Window) void {
    _ = zenit_windows_drain_accessibility(window.native);
}

fn before(_: void, a: TreeNode, b: TreeNode) bool {
    if (a.parent.raw() != b.parent.raw()) return a.parent.raw() < b.parent.raw();
    if (a.sibling_index != b.sibling_index) return a.sibling_index < b.sibling_index;
    return a.element.raw() < b.element.raw();
}
fn text(cx: *ui.Cx, hash: u64) Text {
    const bytes = cx.a11y_label_buf.get(hash) orelse return .{};
    return .{ .bytes = bytes.ptr, .length = bytes.len };
}
pub fn clear(window: *platform.Window) void {
    _ = zenit_windows_publish_accessibility(window.native, null, 0);
}
pub fn publish(cx: *ui.Cx, window: *platform.Window) !void {
    if (zenit_uia_node_size() != @sizeOf(Node)) return error.AccessibilityAbiMismatch;
    // getSize rounds to integral logical units. The physical client size and
    // current DPI preserve the fractional logical boundary used by native UIA.
    const drawable = window.getDrawableSize();
    const scale = window.getScaleFactor();
    if (!std.math.isFinite(scale) or scale <= 0) return error.InvalidAccessibilityGeometry;
    const viewport = ui.ComputedRect.init(0, 0, @as(f32, @floatFromInt(drawable[0])) / scale, @as(f32, @floatFromInt(drawable[1])) / scale);
    var ordered: std.ArrayList(TreeNode) = .empty;
    defer ordered.deinit(cx.allocator);
    for (cx.accessibility_tree.nodes.items) |maybe| {
        const node = maybe orelse continue;
        if (node.state.hidden or node.element.kind != .node) continue;
        if (!connectedThroughNodes(&cx.accessibility_tree, node)) continue;
        if (ordered.items.len == 4096) return error.AccessibilityTreeTooLarge;
        try ordered.append(cx.allocator, node);
    }
    std.mem.sort(TreeNode, ordered.items, {}, before);
    var ranges: std.AutoHashMapUnmanaged(u64, Range) = .{};
    defer ranges.deinit(cx.allocator);
    for (ordered.items, 0..) |node, i| {
        const entry = try ranges.getOrPut(cx.allocator, node.parent.raw());
        if (!entry.found_existing) entry.value_ptr.* = .{ .start = i, .end = i + 1 } else entry.value_ptr.end = i + 1;
    }
    var queue: std.ArrayList(Pending) = .empty;
    defer queue.deinit(cx.allocator);
    if (ranges.get(AXId.NULL.raw())) |range| {
        for (range.start..range.end) |i| try queue.append(cx.allocator, .{ .source = i, .parent = null_id });
    }
    var result: std.ArrayList(Node) = .empty;
    defer result.deinit(cx.allocator);
    var boundary_storage: std.ArrayList([]u32) = .empty;
    defer {
        for (boundary_storage.items) |owned| cx.allocator.free(owned);
        boundary_storage.deinit(cx.allocator);
    }
    var editable_bytes: usize = 0;
    var geometry_storage: std.ArrayList([]GeometrySegment) = .empty;
    defer {
        for (geometry_storage.items) |owned| cx.allocator.free(owned);
        geometry_storage.deinit(cx.allocator);
    }
    var caret_storage: std.ArrayList([]CaretCandidate) = .empty;
    defer {
        for (caret_storage.items) |owned| cx.allocator.free(owned);
        caret_storage.deinit(cx.allocator);
    }
    var row_bytes: usize = 0;
    var caret_bytes: usize = 0;
    var geometry_bytes: usize = 0;
    var cursor: usize = 0;
    while (cursor < queue.items.len) : (cursor += 1) {
        const pending = queue.items[cursor];
        const node = ordered.items[pending.source];
        if (ranges.get(node.element.raw())) |range| {
            for (range.start..range.end) |i| {
                if (queue.items.len >= ordered.items.len) return error.AccessibilityDisconnectedProjection;
                try queue.append(cx.allocator, .{ .source = i, .parent = @intCast(cursor) });
            }
        }
        const numeric = node.numeric_value_present and std.math.isFinite(node.value_now) and
            std.math.isFinite(node.value_min) and std.math.isFinite(node.value_max) and
            node.value_min <= node.value_now and node.value_now <= node.value_max;
        const frame = if (node.frame.isUsable()) node.frame else @FieldType(TreeNode, "frame"){};
        var unit_offsets: [4]Offsets = @splat(.{});
        var geometry: Geometry = .{};
        var geometry_ready = false;
        var carets: Carets = .{};
        var carets_ready = false;
        var rows: Geometry = .{};
        var rows_ready = false;
        if (node.editable_text != null and !node.state.secure) {
            const value = text(cx, node.text_hash);
            const bytes: []const u8 = if (value.bytes) |ptr| ptr[0..value.length] else "";
            if (bytes.len > 8 * 1024 * 1024 - editable_bytes) return error.AccessibilityTreeTooLarge;
            editable_bytes += bytes.len;
            inline for (.{ ui.a11y.characterBoundaries, ui.a11y.wordBoundaries, ui.a11y.paragraphBoundaries }, 0..) |make, index| {
                const owned = try make(cx.allocator, bytes);
                boundary_storage.append(cx.allocator, owned) catch |err| {
                    cx.allocator.free(owned);
                    return err;
                };
                unit_offsets[index] = .{ .bytes = owned.ptr, .count = owned.len };
            }
            // Pending wrapping has no reliable visual lines yet. Keep current
            // text/selection and let TextRange use its next larger known unit.
            const lines = cx.a11yTextLineBoundaries(nodeRaw(node), bytes) catch |err| switch (err) {
                error.AccessibilityLayoutPending => null,
                else => return err,
            };
            if (lines) |owned| {
                boundary_storage.append(cx.allocator, owned) catch |err| {
                    cx.allocator.free(owned);
                    return err;
                };
                unit_offsets[3] = .{ .bytes = owned.ptr, .count = owned.len };
            }
            // Pending shaping and bounded geometry exhaustion leave text
            // readable without claiming known geometry. Malformed geometry,
            // stale text and allocation failures still reject the candidate.
            const queried = cx.a11yTextGeometryClipped(nodeRaw(node), bytes, viewport) catch |err| switch (err) {
                error.AccessibilityLayoutPending, error.AccessibilityGeometryQuota => null,
                else => return err,
            };
            if (queried) |pieces| {
                defer cx.allocator.free(pieces);
                // Geometry is optional. Exhausting its independent budget must
                // not discard updated text/selection or unrelated controls.
                if (pieces.len <= (8 * 1024 * 1024 - geometry_bytes) / @sizeOf(GeometrySegment)) {
                    const owned = try cx.allocator.alloc(GeometrySegment, pieces.len);
                    geometry_storage.append(cx.allocator, owned) catch |err| {
                        cx.allocator.free(owned);
                        return err;
                    };
                    for (pieces, owned) |piece, *dest| dest.* = .{
                        .start = piece.start,
                        .end = piece.end,
                        .x = piece.rect.x,
                        .y = piece.rect.y,
                        .width = piece.rect.width,
                        .height = piece.rect.height,
                    };
                    geometry_bytes += pieces.len * @sizeOf(GeometrySegment);
                    geometry = .{ .segments = owned.ptr, .count = owned.len };
                    geometry_ready = true;
                }
            }
            const row_regions = cx.a11yTextRowGeometryClipped(nodeRaw(node), bytes, viewport) catch |err| switch (err) {
                error.AccessibilityLayoutPending, error.AccessibilityGeometryQuota => null,
                else => return err,
            };
            if (row_regions) |pieces| {
                defer cx.allocator.free(pieces);
                if (pieces.len <= (8 * 1024 * 1024 - row_bytes) / @sizeOf(GeometrySegment)) {
                    const owned = try cx.allocator.alloc(GeometrySegment, pieces.len);
                    geometry_storage.append(cx.allocator, owned) catch |err| {
                        cx.allocator.free(owned);
                        return err;
                    };
                    for (pieces, owned) |piece, *dest| dest.* = .{
                        .start = piece.start,
                        .end = piece.end,
                        .x = piece.rect.x,
                        .y = piece.rect.y,
                        .width = piece.rect.width,
                        .height = piece.rect.height,
                    };
                    row_bytes += pieces.len * @sizeOf(GeometrySegment);
                    rows = .{ .segments = owned.ptr, .count = owned.len };
                    rows_ready = true;
                }
            }
            const candidates = cx.a11yTextCaretCandidates(nodeRaw(node), bytes, viewport) catch |err| switch (err) {
                error.AccessibilityLayoutPending, error.AccessibilityGeometryQuota => null,
                else => return err,
            };
            if (candidates) |pieces| {
                defer cx.allocator.free(pieces);
                if (pieces.len <= (8 * 1024 * 1024 - caret_bytes) / @sizeOf(CaretCandidate)) {
                    const owned = try cx.allocator.alloc(CaretCandidate, pieces.len);
                    caret_storage.append(cx.allocator, owned) catch |err| {
                        cx.allocator.free(owned);
                        return err;
                    };
                    for (pieces, owned) |piece, *dest| dest.* = .{
                        .offset = piece.offset,
                        .first_x = piece.first.x,
                        .first_y = piece.first.y,
                        .last_x = piece.last.x,
                        .last_y = piece.last.y,
                        .visible_first_x = if (piece.visible) |line| line.first.x else 0,
                        .visible_first_y = if (piece.visible) |line| line.first.y else 0,
                        .visible_last_x = if (piece.visible) |line| line.last.x else 0,
                        .visible_last_y = if (piece.visible) |line| line.last.y else 0,
                        .downstream = @intFromBool(piece.downstream),
                        .visible = @intFromBool(piece.visible != null),
                    };
                    caret_bytes += pieces.len * @sizeOf(CaretCandidate);
                    carets = .{ .candidates = owned.ptr, .count = owned.len };
                    carets_ready = true;
                }
            }
        }
        try result.append(cx.allocator, .{
            .id = nodeRaw(node),
            .parent_index = pending.parent,
            .state = @bitCast(node.state),
            .role = @backingInt(node.role),
            .actions = @bitCast(node.actions),
            .numeric = @intFromBool(numeric),
            .setters = @as(u8, @intFromBool(if (node.editable_text) |editable| editable.can_set_value else false)) | (@as(u8, @intFromBool(node.can_set_numeric_value)) << 1) | (@as(u8, @intFromBool(node.can_set_item_selection)) << 2) | (@as(u8, @intFromBool(node.can_set_expanded)) << 3),
            .x = frame.x,
            .y = frame.y,
            .width = frame.width,
            .height = frame.height,
            .value_now = node.value_now,
            .value_min = node.value_min,
            .value_max = node.value_max,
            .small_change = if (node.value_small_change) |value| value else std.math.nan(f64),
            .large_change = if (node.value_large_change) |value| value else std.math.nan(f64),
            .name = text(cx, node.label_hash),
            .description = text(cx, node.description_hash),
            .value = if (node.state.secure) .{} else text(cx, node.text_hash),
            .identifier = text(cx, node.identifier_hash),
            .characters = unit_offsets[0],
            .words = unit_offsets[1],
            .paragraphs = unit_offsets[2],
            .lines = unit_offsets[3],
            .geometry_ready = @intFromBool(geometry_ready),
            .geometry = geometry,
            .carets_ready = @intFromBool(carets_ready),
            .carets = carets,
            .rows_ready = @intFromBool(rows_ready),
            .rows = rows,
            .can_scroll = @intFromBool(if (!node.state.secure) (if (node.editable_text) |editable| editable.can_scroll else false) else false),
            .uniform_format = @intFromBool(if (!node.state.secure) (if (node.editable_text) |editable| editable.uniform_format else false) else false),
            .editable = @intFromBool(node.editable_text != null and !node.state.secure),
            .can_set_selection = @intFromBool(if (!node.state.secure) (if (node.editable_text) |editable| editable.can_set_selection else false) else false),
            .selection_start = if (!node.state.secure) (if (node.editable_text) |editable| editable.selection_start else 0) else 0,
            .selection_end = if (!node.state.secure) (if (node.editable_text) |editable| editable.selection_end else 0) else 0,
            .caret = if (!node.state.secure) (if (node.editable_text) |editable| editable.caret else 0) else 0,
            .visible_start = if (!node.state.secure) (if (node.editable_text) |editable| editable.visible_start else 0) else 0,
            .visible_end = if (!node.state.secure) (if (node.editable_text) |editable| editable.visible_end else 0) else 0,
        });
    }
    if (result.items.len != ordered.items.len) return error.AccessibilityDisconnectedProjection;
    if (zenit_windows_publish_accessibility(window.native, result.items.ptr, result.items.len) == 0)
        return error.AccessibilityPublishFailed;
}
