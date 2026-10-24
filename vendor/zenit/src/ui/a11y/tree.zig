//! Accessibility Tree: true a11y projection.
//!
//! Builds a complete AccessibilityTree, projecting ElementTable + InteractionTable into
//! a platform-agnostic a11y node tree for NSAccessibility / IAccessible / AT-SPI.
//!
//! Design reference:
//! - macOS NSAccessibility protocol (accessibilityChildren / accessibilityHitTest:)
//! - W3C ARIA 1.2 / WAI-ARIA Authoring Practices
//! - Chrome AXTree / AXNode
//! - SwiftUI AccessibilityElement
//!
//! Constraints:
//! - **Do NOT** let a11y nodes hold *Node (use ElementId for frame-safety)
//! - **Do NOT** rebuild every frame (reactive: a node's a11y property change only dirties
//!   that a11y node)
//! - **Do NOT** confuse a11y focus and keyboard focus (two independent focused states)

const std = @import("std");
const testing = std.testing;
const element_id_mod = @import("../core/element_id.zig");
pub const collection = @import("collection.zig");

pub const ElementId = element_id_mod.ElementId;

/// AX layer element identity; the handle crossing the process boundary is its raw().
///
/// Node (kind = node) payload is ElementId raw, value-equal to ElementId zero-extended.
/// Collection entries (virtual list rows/cells etc., see docs/A11Y_ARCHITECTURE.md S12) are
/// not logical-tree nodes; identity is assigned by the a11y layer and kind distinguishes
/// the namespace: it does not borrow ElementId reserved values, and AX callbacks do not
/// request elements from the logical tree.
pub const AXId = packed struct(u64) {
    payload: u32,
    kind: Kind = .node,
    _reserved: u24 = 0,

    pub const Kind = enum(u8) {
        node = 0,
        /// Collection entry row (payload = collection.ItemSlot).
        row = 1,
        /// Collection entry cell.
        cell = 2,
        /// Synthetic static text without bound entry.
        cell_text = 3,
        _,
    };

    /// Refers to no element. Equals NULL node form, so old u32 sentinel 0xFFFFFFFF zero-
    /// extended still NULL.
    pub const NULL: AXId = node(ElementId.NULL);

    pub fn node(id: ElementId) AXId {
        return .{ .payload = id.raw(), .kind = .node };
    }

    pub fn raw(self: AXId) u64 {
        return @bitCast(self);
    }

    pub fn fromRaw(value: u64) AXId {
        return @bitCast(value);
    }

    pub fn eql(a: AXId, b: AXId) bool {
        return a.raw() == b.raw();
    }

    pub fn isNull(self: AXId) bool {
        return self.eql(NULL);
    }

    /// Node identity; other kinds return null.
    pub fn element(self: AXId) ?ElementId {
        if (self.kind != .node) return null;
        const id = ElementId.fromRaw(self.payload);
        return if (id.isNull()) null else id;
    }
};

// Native side (window_bridge.m's ZenitAXHandle / ZENIT_A11Y_INVALID_HANDLE) treats this as
// contract: node handle equals ElementId zero-extended, kind above payload, NULL equals old
// u32 sentinel. Field reordering silently breaks cross-language ABI, pinned here at compile
// time.
comptime {
    std.debug.assert(@bitSizeOf(AXId) == 64);
    std.debug.assert(AXId.NULL.raw() == 0x0000_0000_FFFF_FFFF);
    std.debug.assert(AXId.node(.{ .index = 0x123456, .generation = 0x78 }).raw() == 0x7812_3456);
    std.debug.assert(@bitOffsetOf(AXId, "kind") == 32);
}

/// Complete ARIA-style roles (covers most-used 30+; extend as needed)
pub const Role = enum(u16) {
    none,
    application,
    /// Button (normal / submit / reset)
    button,
    /// Checkbox
    checkbox,
    /// Radio button
    radio,
    /// Radio group
    radiogroup,
    /// Slider
    slider,
    /// Spinbutton
    spinbutton,
    /// Progressbar
    progressbar,
    /// Link
    link,
    /// Textbox (single-line input)
    textbox,
    /// Textarea (multiline)
    textarea,
    /// Searchbox
    searchbox,
    /// Combobox
    combobox,
    /// Listbox
    listbox,
    listitem,
    /// Tree
    tree,
    treeitem,
    /// Table
    grid,
    row,
    cell,
    columnheader,
    rowheader,
    /// Menu
    menu,
    menubar,
    menuitem,
    menuitemcheckbox,
    menuitemradio,
    /// Dialog
    dialog,
    alertdialog,
    /// Alert
    alert,
    status,
    log,
    /// Tablist
    tabs,
    tab,
    tabpanel,
    /// Tooltip
    tooltip,
    /// Generic container/group
    group,
    region,
    /// Text
    heading,
    paragraph,
    /// Img
    image,
    /// Content container (article)
    article,
    section,
    /// Navigation
    navigation,
    /// List (non-listbox list semantics)
    list,
    /// Cell hierarchy relationship
    separator,
    /// Form
    form,
    /// Main
    main,
    /// Banner
    banner,
    contentinfo,
    /// Generic container (no specific semantics)
    generic,
    /// Unannotated text node auto-projected as static text (AXStaticText). Not a component-
    /// declared role: projection inferred from `.text` node, value is text content. Appended at
    /// end,
    /// preserving existing role sequence (ObjC NS_ENUM aligns by ordinal, see macos_bridge.zig).
    static_text,
    /// ARIA switch. Previously projected as checkbox, VoiceOver read as "checkbox"; now
    /// single role, macOS maps to AXCheckBox + AXSwitch subrole.
    switch_control,
    /// Scrollable region (AXScrollArea). See a11y_projection.inferredProps.
    scroll_area,
};

/// Node state bits (ARIA aria-* attributes)
pub const State = packed struct(u32) {
    /// aria-disabled
    disabled: bool = false,
    /// aria-hidden
    hidden: bool = false,
    /// aria-expanded
    expanded: bool = false,
    /// aria-selected
    selected: bool = false,
    /// aria-checked (checkbox/radio)
    checked: bool = false,
    /// aria-checked = mixed (indeterminate)
    indeterminate: bool = false,
    /// aria-pressed (toggle button)
    pressed: bool = false,
    /// aria-required
    required: bool = false,
    /// aria-invalid
    invalid: bool = false,
    /// aria-readonly
    readonly: bool = false,
    /// aria-busy (async loading)
    busy: bool = false,
    /// aria-modal (dialog modal)
    modal: bool = false,
    /// Whether current a11y focus
    focused: bool = false,
    /// Whether focusable
    focusable: bool = false,
    /// aria-haspopup
    haspopup: bool = false,
    /// aria-multiline
    multiline: bool = false,
    /// aria-multiselectable
    multiselectable: bool = false,
    /// Secure editable controls must expose a secure native subrole while
    /// withholding their value/range contract.
    secure: bool = false,
    /// Distinguishes aria-expanded=false from an element which does not
    /// support expansion at all (notably leaf tree items).
    expanded_present: bool = false,
    _reserved: u13 = 0,
};

/// aria-live region level
pub const LiveRegion = enum(u8) {
    off,
    polite,
    assertive,
};

/// Orientation exposed by controls whose interaction model has a primary axis.
/// `undefined` means the role's native default should be used.
pub const Orientation = enum(u8) {
    undefined,
    horizontal,
    vertical,
};

pub const SortDirection = enum(u8) {
    none,
    ascending,
    descending,
    other,
};

/// Window content coordinates, in logical points with a top-left origin.
/// Platform bridges are responsible for projecting this into screen space.
pub const Frame = struct {
    x: f32 = 0,
    y: f32 = 0,
    width: f32 = 0,
    height: f32 = 0,

    pub fn isUsable(self: Frame) bool {
        return std.math.isFinite(self.x) and std.math.isFinite(self.y) and
            std.math.isFinite(self.width) and std.math.isFinite(self.height) and
            self.width >= 0 and self.height >= 0;
    }
};

/// Actions which the current retained node can actually route.  These are not
/// inferred merely from the role: a slider without a live key/event handler
/// must not advertise increment/decrement to assistive technology.
pub const Actions = packed struct(u8) {
    press: bool = false,
    toggle: bool = false,
    increment: bool = false,
    decrement: bool = false,
    _reserved: u4 = 0,
};

/// Read/write text contract. Offsets are UTF-8 byte offsets, matching Zenit's
/// canonical editing model; native bridges convert them to platform units.
pub const EditableText = struct {
    selection_start: u32 = 0,
    selection_end: u32 = 0,
    caret: u32 = 0,
    visible_start: u32 = 0,
    visible_end: u32 = std.math.maxInt(u32),
    can_set_selection: bool = false,
    can_set_value: bool = false,
    uniform_format: bool = false,
    can_scroll: bool = false,
};

/// Single a11y node
pub const A11yNode = struct {
    /// AX identity (AXId.node(ElementId) when projected)
    element: AXId,
    /// Parent a11y node (not necessarily same as ElementTable parent: a11y tree can prune)
    parent: AXId = AXId.NULL,
    role: Role = .none,
    state: State = .{},
    live: LiveRegion = .off,
    /// Label hash (actual string via caller's label_resolver, avoid holding []const u8)
    label_hash: u64 = 0,
    /// Description (aria-describedby reference) hash
    description_hash: u64 = 0,
    /// Placeholder and stable application identifier are independent from the
    /// accessible name; VoiceOver uses both through dedicated AX attributes.
    placeholder_hash: u64 = 0,
    identifier_hash: u64 = 0,
    /// Value (slider/progress/spinbutton)
    value_now: f32 = 0,
    value_min: f32 = 0,
    value_max: f32 = 0,
    value_small_change: ?f32 = null,
    value_large_change: ?f32 = null,
    numeric_value_present: bool = false,
    /// Whether the source node published a callable numeric setter. Native
    /// selector gating must be node-specific rather than inferred from the
    /// window-wide interaction router.
    can_set_numeric_value: bool = false,
    can_set_expanded: bool = false,
    can_set_item_selection: bool = false,
    /// Current AXValue text.
    text_hash: u64 = 0,
    /// Announcement payload is independent from AXValue. Alerts and status
    /// regions commonly derive this from their label or subtree text while
    /// exposing no value attribute.
    live_text_hash: u64 = 0,
    /// Index within parent (for NSAccessibility children ordering)
    sibling_index: u32 = 0,
    /// aria-activedescendant, for combobox/listbox containers: self keeps focus but tells AT
    /// which child is active via active_descendant. AXId.NULL = no active descendant (default)
    active_descendant: AXId = AXId.NULL,
    /// Current layout-space geometry and callable behavior capabilities.
    frame: Frame = .{},
    actions: Actions = .{},
    /// null means the node does not publish the complete editable-text
    /// contract. Platform bridges must then fail closed even for textbox roles.
    editable_text: ?EditableText = null,
    orientation: Orientation = .undefined,
    sort_direction: SortDirection = .none,
    /// ARIA heading/tree/table metadata. Levels are 1-based; zero means
    /// unspecified. Row/column indices are zero-based for AppKit NSRange.
    level: u16 = 0,
    row_index: u32 = 0,
    row_span: u32 = 1,
    column_index: u32 = 0,
    column_span: u32 = 1,
    /// aria-setsize / aria-rowcount; 0 = not declared (see types.A11yProps.set_size).
    set_size: u32 = 0,
    /// aria-posinset, 1-indexed; 0 = not declared.
    pos_in_set: u32 = 0,
    /// Projected in collection row (bound pool node subtree), that collection's table. These
    /// nodes' frames are projection snapshots; AX callbacks translate by offset difference after
    /// scroll submit, aligning with entry elements.
    collection_table: AXId = AXId.NULL,
};

pub fn announcementHash(node: A11yNode) u64 {
    return if (node.live_text_hash != 0) node.live_text_hash else node.text_hash;
}

/// Tree dirty flags (reactive consumer: which a11y nodes need re-projection this frame)
pub const A11yDirtyFlag = packed struct(u16) {
    role_changed: bool = false,
    state_changed: bool = false,
    label_changed: bool = false,
    value_changed: bool = false,
    /// live region content changed -> needs announce
    live_announce: bool = false,
    /// focus changed -> needs platform notification
    focus_changed: bool = false,
    structure_changed: bool = false,
    /// active_descendant changed -> needs NSAccessibility AXSelectedChildren re-projection
    active_descendant_changed: bool = false,
    /// Geometry is a first-class AX attribute and must invalidate cached
    /// positions even when no semantic property changed.
    geometry_changed: bool = false,
    /// Text selection changes use a distinct AppKit notification from value
    /// changes. Keeping the bit separate prevents noisy full-value announces.
    selection_changed: bool = false,
    /// collection logical count (set_size) changed -> platform sends RowCountChanged.
    row_count_changed: bool = false,
    _reserved: u5 = 0,
};

/// Structural dirty state must survive node removal. A dirty map containing
/// flags alone cannot recover the former parent once `nodes[index]` is null,
/// which used to make removal notifications disappear in the router.
pub const StructureChange = struct {
    had_old: bool = false,
    old_parent: AXId = AXId.NULL,
    old_hidden: bool = false,
    has_new: bool = false,
    new_parent: AXId = AXId.NULL,
    new_hidden: bool = false,
};

pub const ChildSpan = struct { start: u32, len: u32 };

pub const AccessibilityTree = struct {
    allocator: std.mem.Allocator,
    /// dense by ElementId.index
    nodes: std.ArrayListUnmanaged(?A11yNode),
    /// Dense projection mark parallel to `nodes`. A render projection is a
    /// replacement snapshot; entries not observed in the current epoch must
    /// be removed instead of leaking into later screens.
    seen_epochs: std.ArrayListUnmanaged(u64),
    projection_epoch: u64 = 0,
    projection_active: bool = false,
    /// Dirty queue pending platform notification (element id -> flags)
    dirty: std.AutoHashMapUnmanaged(u64, A11yDirtyFlag),
    /// Parent snapshots for structural changes, keyed by the generational raw
    /// handle just like `dirty`.
    structure_changes: std.AutoHashMapUnmanaged(u64, StructureChange),
    /// Current a11y focused element
    focused: AXId = AXId.NULL,
    /// Parent -> ordered visible children index list, so the native side gets the i-th child
    /// in O(1). A per-call scan would make a single `accessibilityChildren` O(n*k^2); a large
    /// parent (~170 direct children) takes tens of ms per AXChildren call and VoiceOver
    /// fetches children on every step. Struct changes (add/remove/reparent/reorder sibling/
    /// hidden toggle) mark dirty; the first fetch rebuilds once in O(n log n).
    child_index_dirty: bool = true,
    child_order: std.ArrayListUnmanaged(AXId) = .empty,
    child_spans: std.AutoHashMapUnmanaged(u64, ChildSpan) = .{},
    /// Semantic collections and item tables (see collection.zig).
    collections: collection.Registry = .{},
    /// Projection context: collection row table being projected (set on node during upsert).
    projection_collection_host: AXId = AXId.NULL,

    pub fn init(allocator: std.mem.Allocator) AccessibilityTree {
        return .{
            .allocator = allocator,
            .nodes = .empty,
            .seen_epochs = .empty,
            .dirty = .{},
            .structure_changes = .{},
        };
    }

    pub fn deinit(self: *AccessibilityTree) void {
        self.nodes.deinit(self.allocator);
        self.seen_epochs.deinit(self.allocator);
        self.dirty.deinit(self.allocator);
        self.structure_changes.deinit(self.allocator);
        self.child_order.deinit(self.allocator);
        self.child_spans.deinit(self.allocator);
        self.collections.deinit(self.allocator);
        self.* = undefined;
    }

    /// Project/update an a11y node.
    /// Dirty flags auto-accumulate; caller drainDirty at frame end to push changes to platform.
    pub fn upsert(self: *AccessibilityTree, incoming: A11yNode) !void {
        var node = incoming;
        if (node.state.hidden or node.state.disabled) {
            node.state.focused = false;
        }
        if (self.projection_active) node.collection_table = self.projection_collection_host;
        const idx = denseIndex(node.element) orelse return error.UnsupportedElementKind;
        while (self.nodes.items.len <= idx) {
            try self.nodes.append(self.allocator, null);
        }
        while (self.seen_epochs.items.len <= idx) {
            try self.seen_epochs.append(self.allocator, 0);
        }
        if (self.projection_active) self.seen_epochs.items[idx] = self.projection_epoch;
        // Compare in place: the retained semantic snapshot is large, and the
        // slot is not overwritten until all dirty flags have been derived.
        const old = if (self.nodes.items[idx]) |*value| value else null;
        var flag: A11yDirtyFlag = .{};
        if (old == null or !old.?.element.eql(node.element)) {
            flag.structure_changed = true;
            flag.focus_changed = node.state.focused;
            flag.live_announce = !node.state.hidden and node.live != .off and announcementHash(node) != 0;
            if (old) |stale| {
                try self.recordStructureChange(stale.element, .{
                    .had_old = true,
                    .old_parent = stale.parent,
                    .old_hidden = stale.state.hidden,
                });
                try self.markDirty(stale.element, .{ .structure_changed = true });
                if (self.focused.eql(stale.element)) {
                    self.focused = AXId.NULL;
                    try self.markDirty(stale.element, .{ .focus_changed = true });
                }
            }
            try self.recordStructureChange(node.element, .{
                .has_new = true,
                .new_parent = node.parent,
                .new_hidden = node.state.hidden,
            });
        } else {
            const o = old.?;
            if (o.role != node.role) flag.role_changed = true;
            const o_state: u32 = @bitCast(o.state);
            const n_state: u32 = @bitCast(node.state);
            const focused_mask: u32 = @as(u32, 1) << 12;
            // hidden toggle is struct change (structure_changed below covers it), do not also
            // report
            // state change: else modal open causes every previously-hidden element to send
            // AXValueChanged (real VoiceOver axprobe observed this noise).
            const hidden_mask: u32 = @as(u32, 1) << 1;
            const ignored_mask = focused_mask | hidden_mask;
            if ((o_state & ~ignored_mask) != (n_state & ~ignored_mask)) flag.state_changed = true;
            if (o.label_hash != node.label_hash or
                o.description_hash != node.description_hash or
                o.placeholder_hash != node.placeholder_hash) flag.label_changed = true;
            if (o.value_now != node.value_now or o.value_min != node.value_min or
                o.value_max != node.value_max or
                !std.meta.eql(o.value_small_change, node.value_small_change) or
                !std.meta.eql(o.value_large_change, node.value_large_change) or
                o.numeric_value_present != node.numeric_value_present or
                o.text_hash != node.text_hash) flag.value_changed = true;
            if ((o.editable_text == null) != (node.editable_text == null) or
                o.can_set_numeric_value != node.can_set_numeric_value or
                o.can_set_expanded != node.can_set_expanded or
                o.can_set_item_selection != node.can_set_item_selection or
                !std.meta.eql(o.actions, node.actions)) flag.state_changed = true;
            if (o.editable_text != null and node.editable_text != null and
                (o.editable_text.?.selection_start != node.editable_text.?.selection_start or
                    o.editable_text.?.selection_end != node.editable_text.?.selection_end or
                    o.editable_text.?.caret != node.editable_text.?.caret))
            {
                flag.selection_changed = true;
            }
            if (o.editable_text != null and node.editable_text != null) {
                const old_editable = o.editable_text.?;
                const new_editable = node.editable_text.?;
                if (old_editable.can_set_selection != new_editable.can_set_selection or
                    old_editable.can_set_value != new_editable.can_set_value or
                    old_editable.uniform_format != new_editable.uniform_format or
                    old_editable.can_scroll != new_editable.can_scroll) flag.state_changed = true;
                if (old_editable.visible_start != new_editable.visible_start or
                    old_editable.visible_end != new_editable.visible_end) flag.geometry_changed = true;
            }
            if ((announcementHash(o.*) != announcementHash(node) or o.live != node.live) and
                !node.state.hidden and node.live != .off and announcementHash(node) != 0) flag.live_announce = true;
            if (o.state.focused != node.state.focused) flag.focus_changed = true;
            if (!o.active_descendant.eql(node.active_descendant)) flag.active_descendant_changed = true;
            if (!std.meta.eql(o.frame, node.frame)) flag.geometry_changed = true;
            if (!o.parent.eql(node.parent) or o.sibling_index != node.sibling_index or
                o.state.hidden != node.state.hidden)
            {
                flag.structure_changed = true;
                try self.recordStructureChange(node.element, .{
                    .had_old = true,
                    .old_parent = o.parent,
                    .old_hidden = o.state.hidden,
                    .has_new = true,
                    .new_parent = node.parent,
                    .new_hidden = node.state.hidden,
                });
            }
            if (o.set_size != node.set_size) flag.row_count_changed = true;
            if (o.identifier_hash != node.identifier_hash or
                o.orientation != node.orientation or
                o.sort_direction != node.sort_direction or
                o.level != node.level or o.row_index != node.row_index or
                o.row_span != node.row_span or o.column_index != node.column_index or
                o.column_span != node.column_span or
                o.pos_in_set != node.pos_in_set)
            {
                flag.state_changed = true;
            }
        }
        self.nodes.items[idx] = node;
        if (flag.structure_changed) self.child_index_dirty = true;
        if (@as(u16, @bitCast(flag)) != 0) {
            try self.markDirty(node.element, flag);
        }
        if (node.state.focused) {
            if (!self.focused.isNull() and !self.focused.eql(node.element)) {
                const previous = self.focused;
                if (self.slotPtr(previous)) |slot| {
                    if (slot.*) |*previous_node| {
                        if (previous_node.element.eql(previous) and previous_node.state.focused) {
                            previous_node.state.focused = false;
                            try self.markDirty(previous, .{ .focus_changed = true });
                        }
                    }
                }
            }
            self.focused = node.element;
        } else if (self.focused.eql(node.element)) {
            self.focused = AXId.NULL;
        }
    }

    /// Begin a full retained-tree projection. Pair with `finishProjection`.
    pub fn beginProjection(self: *AccessibilityTree) void {
        std.debug.assert(!self.projection_active);
        self.projection_epoch +%= 1;
        if (self.projection_epoch == 0) {
            @memset(self.seen_epochs.items, 0);
            self.projection_epoch = 1;
        }
        self.projection_active = true;
    }

    /// Remove every entry which was not upserted since `beginProjection`.
    /// This preserves node-level diffs while making screen/root replacement
    /// semantics exact.
    pub fn finishProjection(self: *AccessibilityTree) !void {
        if (!self.projection_active) return;
        const epoch = self.projection_epoch;
        try collection.finishEpoch(&self.collections, .{ .tree = self }, epoch);
        for (self.nodes.items, 0..) |maybe, idx| {
            const node = maybe orelse continue;
            const seen = idx < self.seen_epochs.items.len and self.seen_epochs.items[idx] == epoch;
            if (!seen) try self.remove(node.element);
        }
        self.projection_active = false;
    }

    pub fn remove(self: *AccessibilityTree, id: AXId) !void {
        const slot = self.slotPtr(id) orelse return;
        const existing = slot.* orelse return;
        // A stale generation must not remove the live element which reused the
        // same dense index.
        if (!existing.element.eql(id)) return;
        slot.* = null;
        self.child_index_dirty = true;
        try self.recordStructureChange(id, .{
            .had_old = true,
            .old_parent = existing.parent,
            .old_hidden = existing.state.hidden,
        });
        try self.markDirty(id, .{ .structure_changed = true });
        if (self.focused.eql(id)) {
            self.focused = AXId.NULL;
            try self.markDirty(id, .{ .focus_changed = true });
        }
    }

    /// Get element. Collection entries synthesized on-demand from collection state; collection
    /// table frames computed on-the-fly from committed offset (projection snapshot stale after AX
    /// callback scroll submit).
    pub fn get(self: *const AccessibilityTree, id: AXId) ?A11yNode {
        if (id.kind != .node) return self.collections.synthesize(id);
        const idx = denseIndex(id) orelse return null;
        if (idx >= self.nodes.items.len) return null;
        var node = self.nodes.items[idx] orelse return null;
        if (!node.element.eql(id)) return null;
        if (self.collections.collectionForTable(id)) |c| node.frame = c.tableFrame();
        if (!node.collection_table.isNull()) {
            if (self.collections.collectionForTable(node.collection_table)) |c| node.frame.y += c.frameShift();
        }
        return node;
    }

    // ── Semantic Collections ─────────────────────────────────────────────────────────

    /// Projection: node declared collection. Return collection index for bindCollectionItem.
    pub fn syncCollection(self: *AccessibilityTree, table: AXId, provider: collection.Provider, hidden: bool) !u32 {
        return collection.syncCollection(&self.collections, self.allocator, .{ .tree = self }, table, provider, self.projection_epoch, hidden);
    }

    /// Projection: pool node bound to item index. Return that item's cell AXId (pool node
    /// subtree's parent).
    pub fn bindCollectionItem(self: *AccessibilityTree, collection_idx: u32, index: u32) !AXId {
        return collection.bindItem(&self.collections, self.allocator, collection_idx, index, self.projection_epoch);
    }

    /// Table node release: collection and items exit immediately, no more calls to that
    /// provider functions.
    pub fn retireCollection(self: *AccessibilityTree, table: AXId) !void {
        try collection.retireTable(&self.collections, .{ .tree = self }, table);
    }

    /// Child count: collection table/row/cell parsed from collection, rest use ordered children.
    pub fn childCount(self: *AccessibilityTree, parent: AXId) usize {
        return self.collections.childCount(self, parent) orelse self.exposedChildren(parent).len;
    }

    /// i-th child. Collection table rows materialized on-demand here.
    pub fn childAt(self: *AccessibilityTree, parent: AXId, i: usize) ?AXId {
        if (parent.kind != .node or self.collections.collectionForTable(parent) != null) {
            return self.collections.childAt(self.allocator, self, parent, i);
        }
        const kids = self.exposedChildren(parent);
        return if (i < kids.len) kids[i] else null;
    }

    /// Get by node identity. Framework internals and tests query by Node, avoid writing
    /// AXId.node(...) everywhere.
    pub fn getNode(self: *const AccessibilityTree, id: ElementId) ?A11yNode {
        return self.get(AXId.node(id));
    }

    /// Node's index in dense storage; null if not a node identity.
    fn denseIndex(id: AXId) ?usize {
        const eid = id.element() orelse return null;
        return eid.index;
    }

    /// Projected identity lookup without collection synthesis or dynamic geometry.
    /// Ordering only needs stored identity/parent/sibling fields; public get()
    /// additionally resolves the current collection frame.
    fn projectedNode(self: *const AccessibilityTree, id: AXId) ?*const A11yNode {
        const idx = denseIndex(id) orelse return null;
        if (idx >= self.nodes.items.len) return null;
        const node = if (self.nodes.items[idx]) |*node| node else return null;
        return if (node.element.eql(id)) node else null;
    }

    const ChildOrderKey = struct { sibling_index: u32, element: AXId };

    fn childOrderKey(self: *const AccessibilityTree, id: AXId) ?ChildOrderKey {
        if (id.kind == .node) {
            const node = self.projectedNode(id) orelse return null;
            return .{ .sibling_index = node.sibling_index, .element = node.element };
        }
        // children() also sorts IDs already in the caller's output. Preserve
        // synthetic entry lookup and its provider behavior on that path.
        const node = self.get(id) orelse return null;
        return .{ .sibling_index = node.sibling_index, .element = node.element };
    }

    fn slotPtr(self: *AccessibilityTree, id: AXId) ?*?A11yNode {
        const idx = denseIndex(id) orelse return null;
        if (idx >= self.nodes.items.len) return null;
        return &self.nodes.items[idx];
    }

    pub fn count(self: *const AccessibilityTree) usize {
        var n: usize = 0;
        for (self.nodes.items) |maybe| {
            if (maybe != null) n += 1;
        }
        return n;
    }

    pub fn markDirty(self: *AccessibilityTree, id: AXId, flag: A11yDirtyFlag) !void {
        if (id.isNull()) return;
        const gop = try self.dirty.getOrPut(self.allocator, id.raw());
        if (!gop.found_existing) {
            gop.value_ptr.* = flag;
        } else {
            const a: u16 = @bitCast(gop.value_ptr.*);
            const b: u16 = @bitCast(flag);
            gop.value_ptr.* = @bitCast(a | b);
        }
    }

    pub fn recordStructureChange(self: *AccessibilityTree, id: AXId, change: StructureChange) !void {
        if (id.isNull()) return;
        const gop = try self.structure_changes.getOrPut(self.allocator, id.raw());
        if (!gop.found_existing) {
            gop.value_ptr.* = change;
            return;
        }
        // Preserve the earliest old location and the latest new location when
        // a node is moved repeatedly before frame-end.
        if (!gop.value_ptr.had_old and change.had_old) {
            gop.value_ptr.had_old = true;
            gop.value_ptr.old_parent = change.old_parent;
            gop.value_ptr.old_hidden = change.old_hidden;
        }
        if (change.has_new) {
            gop.value_ptr.has_new = true;
            gop.value_ptr.new_parent = change.new_parent;
            gop.value_ptr.new_hidden = change.new_hidden;
        } else if (change.had_old) {
            gop.value_ptr.has_new = false;
        }
    }

    pub fn structureChange(self: *const AccessibilityTree, id: AXId) ?StructureChange {
        return self.structure_changes.get(id.raw());
    }

    /// Platform bridge calls at frame end: consume dirty queue.
    /// Callback can invoke platform API on each entry (NSAccessibilityPostNotification etc).
    pub fn drainDirty(
        self: *AccessibilityTree,
        ctx: *anyopaque,
        cb: *const fn (ctx: *anyopaque, id: AXId, flag: A11yDirtyFlag) void,
    ) void {
        var iter = self.dirty.iterator();
        while (iter.next()) |entry| {
            const id = AXId.fromRaw(entry.key_ptr.*);
            cb(ctx, id, entry.value_ptr.*);
        }
        self.dirty.clearRetainingCapacity();
        self.structure_changes.clearRetainingCapacity();
    }

    /// Return element's a11y children (sorted by sibling_index).
    /// `parent` visible children by (sibling_index, raw handle) stable sort; `AXId.NULL` for
    /// top level. Slice valid until next struct change. Index rebuild OOM returns empty slice
    /// (keeps dirty, retries next fetch): AT sees empty subtree once, better than wrong data.
    pub fn exposedChildren(self: *AccessibilityTree, parent: AXId) []const AXId {
        if (self.child_index_dirty) {
            self.rebuildChildIndex() catch return &.{};
        }
        const span = self.child_spans.get(parent.raw()) orelse return &.{};
        return self.child_order.items[span.start..][0..span.len];
    }

    fn rebuildChildIndex(self: *AccessibilityTree) !void {
        self.child_order.clearRetainingCapacity();
        self.child_spans.clearRetainingCapacity();
        for (self.nodes.items) |*maybe| {
            const node = if (maybe.*) |*value| value else continue;
            if (node.state.hidden) continue;
            try self.child_order.append(self.allocator, node.element);
        }
        const Ctx = struct {
            tree: *const AccessibilityTree,
            fn lessThan(ctx: @This(), a: AXId, b: AXId) bool {
                const na = ctx.tree.projectedNode(a).?;
                const nb = ctx.tree.projectedNode(b).?;
                if (na.parent.raw() != nb.parent.raw()) return na.parent.raw() < nb.parent.raw();
                if (na.sibling_index != nb.sibling_index) return na.sibling_index < nb.sibling_index;
                return na.element.raw() < nb.element.raw();
            }
        };
        std.sort.pdq(AXId, self.child_order.items, Ctx{ .tree = self }, Ctx.lessThan);
        var start: usize = 0;
        while (start < self.child_order.items.len) {
            const parent_raw = self.projectedNode(self.child_order.items[start]).?.parent.raw();
            var end = start + 1;
            while (end < self.child_order.items.len and
                self.projectedNode(self.child_order.items[end]).?.parent.raw() == parent_raw) end += 1;
            try self.child_spans.put(self.allocator, parent_raw, .{ .start = @intCast(start), .len = @intCast(end - start) });
            start = end;
        }
        self.child_index_dirty = false;
    }

    pub fn children(
        self: *const AccessibilityTree,
        parent: AXId,
        out: *std.ArrayListUnmanaged(AXId),
        allocator: std.mem.Allocator,
    ) !void {
        // Dense projection often already has sibling order. Detect that while
        // collecting instead of looking every identity up again to verify it.
        var ordered = out.items.len == 0;
        var previous: ?ChildOrderKey = null;
        for (self.nodes.items) |*maybe| {
            if (maybe.*) |*n| {
                if (n.parent.eql(parent) and !n.state.hidden) {
                    try out.append(allocator, n.element);
                    if (previous) |left| {
                        if (n.sibling_index < left.sibling_index or
                            (n.sibling_index == left.sibling_index and n.element.raw() < left.element.raw())) ordered = false;
                    }
                    previous = .{ .sibling_index = n.sibling_index, .element = n.element };
                }
            }
        }
        if (ordered) return;
        // Keep this helper's documented order identical to the native pull
        // bridge. Stable raw-handle tie-breaking makes malformed duplicate
        // sibling indices deterministic instead of dense-slot dependent.
        var i: usize = 1;
        while (i < out.items.len) : (i += 1) {
            var j = i;
            while (j > 0) : (j -= 1) {
                const left = self.childOrderKey(out.items[j - 1]) orelse break;
                const right = self.childOrderKey(out.items[j]) orelse break;
                const right_before = right.sibling_index < left.sibling_index or
                    (right.sibling_index == left.sibling_index and right.element.raw() < left.element.raw());
                if (!right_before) break;
                std.mem.swap(AXId, &out.items[j - 1], &out.items[j]);
            }
        }
    }
};

// ============================================================================
// Tests
// ============================================================================

test "AccessibilityTree: upsert / get / count" {
    var tree = AccessibilityTree.init(testing.allocator);
    defer tree.deinit();

    const id1 = AXId.node(.{ .index = 1, .generation = 0 });
    try tree.upsert(.{
        .element = id1,
        .role = .button,
        .state = .{ .focusable = true },
        .label_hash = 0x12345,
    });

    const got = tree.get(id1).?;
    try testing.expectEqual(Role.button, got.role);
    try testing.expectEqual(@as(u64, 0x12345), got.label_hash);
    try testing.expectEqual(@as(usize, 1), tree.count());
}

test "AccessibilityTree: upsert detects changes and marks dirty" {
    var tree = AccessibilityTree.init(testing.allocator);
    defer tree.deinit();

    const id = AXId.node(.{ .index = 1, .generation = 0 });
    try tree.upsert(.{ .element = id, .role = .button });

    // First insert -> structure_changed
    try testing.expect(tree.dirty.get(id.raw()).?.structure_changed);

    // Clear queue
    tree.dirty.clearRetainingCapacity();

    // role modified -> role_changed dirty
    try tree.upsert(.{ .element = id, .role = .checkbox });
    try testing.expect(tree.dirty.get(id.raw()).?.role_changed);
}

test "AccessibilityTree: projection removes nodes absent from the next root" {
    var tree = AccessibilityTree.init(testing.allocator);
    defer tree.deinit();

    const old_only = AXId.node(.{ .index = 1, .generation = 0 });
    const retained = AXId.node(.{ .index = 2, .generation = 0 });
    tree.beginProjection();
    try tree.upsert(.{ .element = old_only, .role = .button });
    try tree.upsert(.{ .element = retained, .role = .checkbox });
    try tree.finishProjection();
    tree.dirty.clearRetainingCapacity();

    tree.beginProjection();
    try tree.upsert(.{ .element = retained, .role = .checkbox });
    try tree.finishProjection();

    try testing.expect(tree.get(old_only) == null);
    try testing.expect(tree.get(retained) != null);
    try testing.expect(tree.dirty.get(old_only.raw()).?.structure_changed);
}

test "AccessibilityTree: state change tracked" {
    var tree = AccessibilityTree.init(testing.allocator);
    defer tree.deinit();

    const id = AXId.node(.{ .index = 1, .generation = 0 });
    try tree.upsert(.{ .element = id, .role = .checkbox, .state = .{} });
    tree.dirty.clearRetainingCapacity();

    try tree.upsert(.{ .element = id, .role = .checkbox, .state = .{ .checked = true } });
    try testing.expect(tree.dirty.get(id.raw()).?.state_changed);
}

test "AccessibilityTree: live region announce on text change" {
    var tree = AccessibilityTree.init(testing.allocator);
    defer tree.deinit();

    const id = AXId.node(.{ .index = 1, .generation = 0 });
    try tree.upsert(.{ .element = id, .role = .status, .live = .polite, .text_hash = 100 });
    tree.dirty.clearRetainingCapacity();

    try tree.upsert(.{ .element = id, .role = .status, .live = .polite, .text_hash = 200 });
    try testing.expect(tree.dirty.get(id.raw()).?.live_announce);
}

test "AccessibilityTree: a populated live region announces when inserted or enabled" {
    var tree = AccessibilityTree.init(testing.allocator);
    defer tree.deinit();

    const inserted = AXId.node(.{ .index = 1, .generation = 0 });
    try tree.upsert(.{ .element = inserted, .role = .alert, .live = .assertive, .text_hash = 123 });
    try testing.expect(tree.dirty.get(inserted.raw()).?.live_announce);

    const enabled = AXId.node(.{ .index = 2, .generation = 0 });
    try tree.upsert(.{ .element = enabled, .role = .status, .text_hash = 456 });
    tree.dirty.clearRetainingCapacity();
    try tree.upsert(.{ .element = enabled, .role = .status, .live = .polite, .text_hash = 456 });
    try testing.expect(tree.dirty.get(enabled.raw()).?.live_announce);
}

test "AccessibilityTree: active_descendant diff sets flag" {
    var tree = AccessibilityTree.init(testing.allocator);
    defer tree.deinit();

    const container = AXId.node(.{ .index = 0, .generation = 0 });
    const opt_a = AXId.node(.{ .index = 1, .generation = 0 });
    const opt_b = AXId.node(.{ .index = 2, .generation = 0 });

    try tree.upsert(.{ .element = container, .role = .combobox });
    // First dirty ever drained (here directly clear then diff)
    tree.dirty.clearRetainingCapacity();

    try tree.upsert(.{ .element = container, .role = .combobox, .active_descendant = opt_a });
    {
        const flag = tree.dirty.get(container.raw()).?;
        try testing.expect(flag.active_descendant_changed);
    }
    tree.dirty.clearRetainingCapacity();

    // Write same value -> should not re-dirty
    try tree.upsert(.{ .element = container, .role = .combobox, .active_descendant = opt_a });
    try testing.expect(tree.dirty.get(container.raw()) == null);

    // Switch to B -> re-dirty
    try tree.upsert(.{ .element = container, .role = .combobox, .active_descendant = opt_b });
    {
        const flag = tree.dirty.get(container.raw()).?;
        try testing.expect(flag.active_descendant_changed);
    }
}

test "AccessibilityTree: focused tracked" {
    var tree = AccessibilityTree.init(testing.allocator);
    defer tree.deinit();

    const id = AXId.node(.{ .index = 1, .generation = 0 });
    try tree.upsert(.{ .element = id, .role = .button, .state = .{ .focused = true, .focusable = true } });
    try testing.expect(tree.focused.eql(id));
    try testing.expect(tree.dirty.get(id.raw()).?.focus_changed);
}

test "AccessibilityTree: generation replacement cannot retain a stale focus handle" {
    var tree = AccessibilityTree.init(testing.allocator);
    defer tree.deinit();

    const old = AXId.node(.{ .index = 3, .generation = 1 });
    const replacement = AXId.node(.{ .index = 3, .generation = 2 });
    try tree.upsert(.{ .element = old, .role = .button, .state = .{ .focused = true, .focusable = true } });
    tree.dirty.clearRetainingCapacity();
    tree.structure_changes.clearRetainingCapacity();

    try tree.upsert(.{ .element = replacement, .role = .button });
    try testing.expect(tree.focused.isNull());
    try testing.expect(tree.dirty.get(old.raw()).?.focus_changed);
    try testing.expect(tree.get(old) == null);
    try testing.expect(tree.get(replacement) != null);
}

test "AccessibilityTree: removal retains former parent until dirty drain" {
    var tree = AccessibilityTree.init(testing.allocator);
    defer tree.deinit();

    const parent = AXId.node(.{ .index = 1, .generation = 0 });
    const child = AXId.node(.{ .index = 2, .generation = 0 });
    try tree.upsert(.{ .element = parent, .role = .group });
    try tree.upsert(.{ .element = child, .parent = parent, .role = .button });
    tree.dirty.clearRetainingCapacity();
    tree.structure_changes.clearRetainingCapacity();

    try tree.remove(child);
    try testing.expect(tree.get(child) == null);
    const change = tree.structureChange(child).?;
    try testing.expect(change.had_old);
    try testing.expect(change.old_parent.eql(parent));
    try testing.expect(!change.has_new);
}

test "AccessibilityTree: drainDirty visits all entries" {
    var tree = AccessibilityTree.init(testing.allocator);
    defer tree.deinit();

    try tree.upsert(.{ .element = AXId.node(.{ .index = 1, .generation = 0 }), .role = .button });
    try tree.upsert(.{ .element = AXId.node(.{ .index = 2, .generation = 0 }), .role = .checkbox });

    const Counter = struct {
        n: u32 = 0,
        fn cb(ctx: *anyopaque, id: AXId, flag: A11yDirtyFlag) void {
            const c: *@This() = @ptrCast(@alignCast(ctx));
            c.n += 1;
            _ = id;
            _ = flag;
        }
    };
    var counter = Counter{};
    tree.drainDirty(&counter, &Counter.cb);
    try testing.expectEqual(@as(u32, 2), counter.n);
    try testing.expectEqual(@as(u32, 0), tree.dirty.count());
}

test "AccessibilityTree: children lookup" {
    var tree = AccessibilityTree.init(testing.allocator);
    defer tree.deinit();

    const root = AXId.node(.{ .index = 0, .generation = 0 });
    const c1 = AXId.node(.{ .index = 1, .generation = 0 });
    const c2 = AXId.node(.{ .index = 2, .generation = 0 });

    try tree.upsert(.{ .element = root, .role = .group });
    try tree.upsert(.{ .element = c1, .parent = root, .role = .button, .sibling_index = 9 });
    try tree.upsert(.{ .element = c2, .parent = root, .role = .button, .sibling_index = 1 });

    var out: std.ArrayListUnmanaged(AXId) = .empty;
    defer out.deinit(testing.allocator);
    try tree.children(root, &out, testing.allocator);
    try testing.expectEqual(@as(usize, 2), out.items.len);
    try testing.expect(out.items[0].eql(c2));
    try testing.expect(out.items[1].eql(c1));
}

test "AccessibilityTree: children preserves hidden filtering, ties, and appended output order" {
    var tree = AccessibilityTree.init(testing.allocator);
    defer tree.deinit();
    const root = AXId.node(.{ .index = 0, .generation = 0 });
    const first = AXId.node(.{ .index = 9, .generation = 0 });
    const tie_low = AXId.node(.{ .index = 3, .generation = 0 });
    const tie_high = AXId.node(.{ .index = 7, .generation = 0 });
    const hidden = AXId.node(.{ .index = 2, .generation = 0 });
    const unrelated = AXId.node(.{ .index = 11, .generation = 0 });
    try tree.upsert(.{ .element = root, .role = .group });
    try tree.upsert(.{ .element = first, .parent = root, .sibling_index = 0 });
    try tree.upsert(.{ .element = tie_low, .parent = root, .sibling_index = 2 });
    try tree.upsert(.{ .element = tie_high, .parent = root, .sibling_index = 2 });
    try tree.upsert(.{ .element = hidden, .parent = root, .sibling_index = 0, .state = .{ .hidden = true } });
    try tree.upsert(.{ .element = unrelated, .sibling_index = 1 });
    var out: std.ArrayListUnmanaged(AXId) = .empty;
    defer out.deinit(testing.allocator);
    try tree.children(root, &out, testing.allocator);
    try testing.expectEqualSlices(AXId, &.{ first, tie_low, tie_high }, out.items);
    try testing.expectEqualSlices(AXId, out.items, tree.exposedChildren(root));
    out.clearRetainingCapacity();
    // Existing output participates in sorting even when it is not a child.
    try out.append(testing.allocator, unrelated);
    try tree.children(root, &out, testing.allocator);
    try testing.expectEqualSlices(AXId, &.{ first, unrelated, tie_low, tie_high }, out.items);
}

test "AccessibilityTree: children keeps stale identity barriers in prefilled output" {
    var tree = AccessibilityTree.init(testing.allocator);
    defer tree.deinit();
    const root = AXId.node(.{ .index = 0, .generation = 0 });
    const child = AXId.node(.{ .index = 2, .generation = 1 });
    const stale = AXId.node(.{ .index = 2, .generation = 0 });
    const other = AXId.node(.{ .index = 5, .generation = 0 });
    try tree.upsert(.{ .element = root });
    try tree.upsert(.{ .element = child, .parent = root, .sibling_index = 0 });
    try tree.upsert(.{ .element = other, .sibling_index = 9 });
    var out: std.ArrayListUnmanaged(AXId) = .empty;
    defer out.deinit(testing.allocator);
    try out.appendSlice(testing.allocator, &.{ other, stale });
    try tree.children(root, &out, testing.allocator);
    // Identity mismatch stops each insertion, rather than sorting using the
    // replacement generation's node metadata.
    try testing.expectEqualSlices(AXId, &.{ other, stale, child }, out.items);
    try testing.expect(tree.projectedNode(stale) == null);
    try testing.expect(tree.projectedNode(AXId.NULL) == null);
    try testing.expect(tree.projectedNode(AXId.node(.{ .index = 90, .generation = 0 })) == null);
    try testing.expect(tree.projectedNode(.{ .payload = 2, .kind = .row }) == null);
}

test "State / A11yDirtyFlag are properly sized" {
    try testing.expectEqual(@as(usize, 4), @sizeOf(State));
    try testing.expectEqual(@as(usize, 2), @sizeOf(A11yDirtyFlag));
}

test "AccessibilityTree: exposedChildren 有序、跳过 hidden、结构变化后重建" {
    var tree = AccessibilityTree.init(testing.allocator);
    defer tree.deinit();

    const root = AXId.node(.{ .index = 1, .generation = 0 });
    const a = AXId.node(.{ .index = 9, .generation = 0 });
    const b = AXId.node(.{ .index = 4, .generation = 0 });
    const hidden = AXId.node(.{ .index = 5, .generation = 0 });
    try tree.upsert(.{ .element = root, .role = .group });
    // dense slot order (4,5,9) vs sibling order (a=0,b=1) reversed: output must follow
    // sibling order.
    try tree.upsert(.{ .element = a, .parent = root, .role = .button, .sibling_index = 0 });
    try tree.upsert(.{ .element = b, .parent = root, .role = .button, .sibling_index = 1 });
    try tree.upsert(.{ .element = hidden, .parent = root, .role = .button, .sibling_index = 2, .state = .{ .hidden = true } });

    const kids = tree.exposedChildren(root);
    try testing.expectEqual(@as(usize, 2), kids.len);
    try testing.expect(kids[0].eql(a));
    try testing.expect(kids[1].eql(b));
    try testing.expectEqual(@as(usize, 1), tree.exposedChildren(AXId.NULL).len);

    // Swap sibling order: index must invalidate+rebuild, not return stale order.
    try tree.upsert(.{ .element = a, .parent = root, .role = .button, .sibling_index = 1 });
    try tree.upsert(.{ .element = b, .parent = root, .role = .button, .sibling_index = 0 });
    const swapped = tree.exposedChildren(root);
    try testing.expect(swapped[0].eql(b));
    try testing.expect(swapped[1].eql(a));

    // Delete also invalidates.
    try tree.remove(b);
    try testing.expectEqual(@as(usize, 1), tree.exposedChildren(root).len);

    // Pure property change (label) should not invalidate index.
    _ = tree.exposedChildren(root);
    try tree.upsert(.{ .element = a, .parent = root, .role = .button, .sibling_index = 1, .label_hash = 42 });
    try testing.expect(!tree.child_index_dirty);
}

test "AccessibilityTree: hidden 翻转只算结构变化，不再报 state_changed（模态打开时的 ValueChanged 噪声）" {
    var tree = AccessibilityTree.init(testing.allocator);
    defer tree.deinit();
    const id = AXId.node(.{ .index = 1, .generation = 0 });
    try tree.upsert(.{ .element = id, .role = .button, .state = .{ .hidden = true } });
    tree.dirty.clearRetainingCapacity();
    tree.structure_changes.clearRetainingCapacity();
    try tree.upsert(.{ .element = id, .role = .button });
    const flag = tree.dirty.get(id.raw()).?;
    try testing.expect(flag.structure_changed);
    try testing.expect(!flag.state_changed);
}

test {
    // collection.zig only imported via tree.zig; without explicit reference, its tests
    // won't compile (orphan test).
    _ = collection;
}

/// Owned UTF-8 byte boundaries for UI Automation Character units. Uses the
/// same Unicode grapheme engine as editing, and scans long RI/ZWJ runs linearly.
pub fn characterBoundaries(allocator: std.mem.Allocator, value: []const u8) ![]u32 {
    if (value.len > std.math.maxInt(u32) or !std.unicode.utf8ValidateSlice(value)) return error.InvalidAccessibilityText;
    var boundaries: std.ArrayList(u32) = .empty;
    defer boundaries.deinit(allocator);
    try boundaries.append(allocator, 0);
    var cursor = @import("text_core").grapheme.BoundaryCursor.init(value);
    var position: usize = 0;
    while (position < value.len) {
        position = cursor.next(position);
        try boundaries.append(allocator, @intCast(position));
    }
    return boundaries.toOwnedSlice(allocator);
}

test "characterBoundaries shares extended grapheme clusters" {
    const value = "e\u{0301}👩‍💻🇨🇳\r\n";
    const boundaries = try characterBoundaries(testing.allocator, value);
    defer testing.allocator.free(boundaries);
    try testing.expectEqualSlices(u32, &.{ 0, 3, 14, 22, 24 }, boundaries);
    const empty = try characterBoundaries(testing.allocator, "");
    defer testing.allocator.free(empty);
    try testing.expectEqualSlices(u32, &.{0}, empty);
    try testing.expectError(error.InvalidAccessibilityText, characterBoundaries(testing.allocator, "\xff"));
}

/// Editor word categories, traversed as whole graphemes. Separators following
/// a word belong to that unit. CJK/emoji clusters each form a separate unit.
pub fn wordBoundaries(allocator: std.mem.Allocator, value: []const u8) ![]u32 {
    const characters = try characterBoundaries(allocator, value);
    defer allocator.free(characters);
    const Doc = struct {
        pub fn getByteAt(_: *const @This(), _: usize) ?u8 {
            return null;
        }
    };
    const Cursor = @import("text_core").cursor.DocCursor(Doc);
    var result: std.ArrayList(u32) = .empty;
    defer result.deinit(allocator);
    try result.append(allocator, 0);
    var i: usize = 0;
    while (i + 1 < characters.len) {
        const first = value[characters[i]];
        if (first >= 0xe0) {
            i += 1;
        } else if (first >= 0x80 or !Cursor.isWordSeparator(first)) {
            while (i + 1 < characters.len) : (i += 1) {
                const lead = value[characters[i]];
                if (lead >= 0xe0 or (lead < 0x80 and Cursor.isWordSeparator(lead))) break;
            }
        }
        while (i + 1 < characters.len and Cursor.isWordSeparator(value[characters[i]])) : (i += 1) {}
        try result.append(allocator, characters[i]);
    }
    return result.toOwnedSlice(allocator);
}

/// Logical paragraphs include their terminating newline. CRLF remains atomic;
/// visual wrapping is intentionally not a paragraph boundary.
pub fn paragraphBoundaries(allocator: std.mem.Allocator, value: []const u8) ![]u32 {
    const characters = try characterBoundaries(allocator, value);
    defer allocator.free(characters);
    var result: std.ArrayList(u32) = .empty;
    defer result.deinit(allocator);
    try result.append(allocator, 0);
    var after_break = false;
    for (characters[0 .. characters.len - 1], characters[1..]) |first, last| {
        const cluster = value[first..last];
        if (cluster[0] == '\r' or cluster[0] == '\n' or std.mem.eql(u8, cluster, "\u{2029}")) {
            after_break = true;
        } else if (after_break) {
            // Empty rows after a paragraph belong to it; the next content
            // cluster starts a new paragraph. Leading blank rows form a unit.
            try result.append(allocator, first);
            after_break = false;
        }
    }
    if (result.items[result.items.len - 1] != value.len) try result.append(allocator, @intCast(value.len));
    return result.toOwnedSlice(allocator);
}

test "textUnitBoundaries preserves graphemes and logical paragraphs" {
    const words = try wordBoundaries(testing.allocator, "a\u{1ab0}b, 中👩‍💻 x");
    defer testing.allocator.free(words);
    try testing.expectEqualSlices(u32, &.{ 0, 7, 10, 22, 23 }, words);
    const greek = try wordBoundaries(testing.allocator, "αβ γ");
    defer testing.allocator.free(greek);
    try testing.expectEqualSlices(u32, &.{ 0, 5, 7 }, greek);
    const paragraphs = try paragraphBoundaries(testing.allocator, "中\r\n\nB\rC\u{2029}D");
    defer testing.allocator.free(paragraphs);
    try testing.expectEqualSlices(u32, &.{ 0, 6, 8, 12, 13 }, paragraphs);
    inline for (.{ wordBoundaries, paragraphBoundaries }) |make| {
        const empty = try make(testing.allocator, "");
        defer testing.allocator.free(empty);
        try testing.expectEqualSlices(u32, &.{0}, empty);
        try testing.expectError(error.InvalidAccessibilityText, make(testing.allocator, "\xff"));
    }
}

test "textUnitBoundaries agrees with editor word navigation" {
    const Doc = struct {
        bytes: []const u8,
        pub fn totalLength(self: *const @This()) usize {
            return self.bytes.len;
        }
        pub fn getByteAt(self: *const @This(), offset: usize) ?u8 {
            return if (offset < self.bytes.len) self.bytes[offset] else null;
        }
    };
    const Cursor = @import("text_core").cursor.DocCursor(Doc);
    for ([_][]const u8{ "  alpha_beta, γδ! 中字 👩‍💻🇨🇳", "a\u{0301}b x", "\r\n\tfoo/bar", "", "😀😀😀" }) |value| {
        const words = try wordBoundaries(testing.allocator, value);
        defer testing.allocator.free(words);
        const doc = Doc{ .bytes = value };
        for (words[0 .. words.len - 1], words[1..]) |first, last| {
            try testing.expectEqual(@as(usize, last), Cursor.nextWordBoundary(&doc, first));
        }
    }
}

test "textUnitBoundaries merges empty paragraph rows" {
    for ([_]struct { value: []const u8, expected: []const u32 }{
        .{ .value = "A\n\nB\n\n", .expected = &.{ 0, 3, 6 } },
        .{ .value = "\n\nB", .expected = &.{ 0, 2, 3 } },
        .{ .value = "A\r\n\r\nB", .expected = &.{ 0, 5, 6 } },
        .{ .value = "\n\n", .expected = &.{ 0, 2 } },
    }) |fixture| {
        const boundaries = try paragraphBoundaries(testing.allocator, fixture.value);
        defer testing.allocator.free(boundaries);
        try testing.expectEqualSlices(u32, fixture.expected, boundaries);
    }
}

test "AccessibilityTree: editable format capability changes mark state dirty" {
    var tree = AccessibilityTree.init(testing.allocator);
    defer tree.deinit();
    const id = AXId.node(.{ .index = 1, .generation = 0 });
    var node: A11yNode = .{ .element = id, .role = .textbox, .editable_text = .{} };
    try tree.upsert(node);
    tree.dirty.clearRetainingCapacity();
    node.editable_text.?.uniform_format = true;
    try tree.upsert(node);
    try testing.expect(tree.dirty.get(id.raw()).?.state_changed);
    try testing.expect(tree.get(id).?.editable_text.?.uniform_format);
}
