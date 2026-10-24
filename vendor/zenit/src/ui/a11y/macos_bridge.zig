//! macOS NSAccessibility C ABI bridge (zig-side export).
//!
//! NSAccessibility protocol methods (accessibilityChildren / accessibilityHitTest: /
//! accessibilityRole / etc) call back into zig via C ABI and pull a11y node data from
//! cx.accessibility_tree.
//!
//! Reverse direction (zig -> ObjC notify_*) is precise dispatch via this module's retained-tree
//! push hooks; the system_sdk snapshot API is kept only as an explicit compat entry.
//!
//! Design:
//! - element_handle = ElementId.raw() (u32 packed). ObjC lazily generates NSAccessibilityElement
//!   proxies that hold only the handle, no zig memory
//! - strings via cx.a11y_label_buf hash -> []const u8 reverse lookup; C ABI copies UTF-8 bytes to
//!   an ObjC-provided buffer
//! - active context routed by window_id (see `g_active` table). ObjC ZenitA11yElement / MetalView
//!   proxies each hold window_id and pass it with every protocol method call

const std = @import("std");
const tree_mod = @import("tree.zig");
const router_mod = @import("nsaccessibility_router.zig");
const element_id_mod = @import("../core/element_id.zig");
const core_types = @import("../core/types.zig");

pub const ElementId = element_id_mod.ElementId;
pub const AXId = tree_mod.AXId;
pub const A11yNode = tree_mod.A11yNode;
pub const AccessibilityTree = tree_mod.AccessibilityTree;
pub const PlatformBridge = router_mod.PlatformBridge;

// compile-time invariant: tree.Role enum order matches window_bridge.m
// ZenitA11yTreeRole NS_ENUM. change tree.Role order must sync ObjC side.
comptime {
    const r = tree_mod.Role;
    std.debug.assert(@backingInt(r.none) == 0);
    std.debug.assert(@backingInt(r.button) == 2);
    std.debug.assert(@backingInt(r.checkbox) == 3);
    std.debug.assert(@backingInt(r.progressbar) == 8);
    std.debug.assert(@backingInt(r.textbox) == 10);
    std.debug.assert(@backingInt(r.dialog) == 28);
    std.debug.assert(@backingInt(r.generic) == 51);
    std.debug.assert(@backingInt(r.static_text) == 52);
    std.debug.assert(@backingInt(r.switch_control) == 53);
    std.debug.assert(@backingInt(r.scroll_area) == 54);
    std.debug.assert(@as(u32, @bitCast(tree_mod.State{ .disabled = true })) == (@as(u32, 1) << 0));
    std.debug.assert(@as(u32, @bitCast(tree_mod.State{ .focused = true })) == (@as(u32, 1) << 12));
    std.debug.assert(@as(u32, @bitCast(tree_mod.State{ .secure = true })) == (@as(u32, 1) << 17));
    std.debug.assert(@as(u32, @bitCast(tree_mod.State{ .expanded_present = true })) == (@as(u32, 1) << 18));
    std.debug.assert(@as(u16, @bitCast(tree_mod.A11yDirtyFlag{ .geometry_changed = true })) == (@as(u16, 1) << 8));
    std.debug.assert(@as(u16, @bitCast(tree_mod.A11yDirtyFlag{ .selection_changed = true })) == (@as(u16, 1) << 9));
    std.debug.assert(@as(u16, @bitCast(tree_mod.A11yDirtyFlag{ .row_count_changed = true })) == (@as(u16, 1) << 10));
}

/// caller-implemented "query cx-level string from ID" interface. Cx holds a11y_label_buf
/// (hash -> []const u8), inject fn ptr to label_buf into setActiveContext.
pub const LabelResolver = *const fn (ctx: *anyopaque, hash: u64) ?[]const u8;

/// scroll_to_visible: AXScrollToVisible, VoiceOver cursor moves off-viewport element call.
/// any element (include static_text, disabled) supported, no need declare in actions.
pub const Action = enum(u8) { press = 0, toggle = 1, increment = 2, decrement = 3, scroll_to_visible = 4 };
pub const ActionHandler = *const fn (ctx: *anyopaque, element: AXId, action: Action) bool;
pub const SelectionHandler = *const fn (ctx: *anyopaque, element: AXId, start_utf8: u32, end_utf8: u32) bool;
pub const FocusHandler = *const fn (ctx: *anyopaque, element: AXId, focused: bool) bool;
pub const TextValueHandler = *const fn (ctx: *anyopaque, element: AXId, value: []const u8) bool;
pub const NumericValueHandler = *const fn (ctx: *anyopaque, element: AXId, value: f32) bool;
pub const TextFrameHandler = *const fn (ctx: *anyopaque, element: AXId, start_utf8: u32, end_utf8: u32, out: *tree_mod.Frame) bool;
pub const TextRangeAtPointHandler = *const fn (ctx: *anyopaque, element: AXId, x: f32, y: f32, start_utf8: *u32, end_utf8: *u32) bool;

const ActiveContext = struct {
    tree: *AccessibilityTree,
    label_ctx: *anyopaque,
    label_resolver: LabelResolver,
    interaction_ctx: ?*anyopaque = null,
    action_handler: ?ActionHandler = null,
    selection_handler: ?SelectionHandler = null,
    focus_handler: ?FocusHandler = null,
    text_value_handler: ?TextValueHandler = null,
    numeric_value_handler: ?NumericValueHandler = null,
    text_frame_handler: ?TextFrameHandler = null,
    text_range_at_point_handler: ?TextRangeAtPointHandler = null,
};

/// Max concurrent registered windows. Fixed array, not HashMap: this table is read on the
/// **high-frequency** NSAccessibility callback path (VoiceOver walks children/role/label on each
/// navigation) and needs alloc-free deterministic lookup; window count is single digit.
///
/// WARNING: thread model: the table **relies on main-thread serialization**; multi-word struct
/// writes are not atomic. NSAccessibility protocol methods and the zenit render loop both run on
/// the main thread. If non-main-thread callbacks appear, slots need an atomic pointer/seqlock.
pub const MAX_WINDOWS = 16;

const Slot = struct {
    window_id: u32,
    ctx: ActiveContext,
    demand: ?ProjectionDemand = null,
};

var g_active: [MAX_WINDOWS]?Slot = @splat(null);

/// Lazy projection (Chrome-style "accessibility mode on first client"): a host
/// that skips per-frame projection until an assistive client shows up registers
/// a demand handler. The first query for its window runs the handler
/// synchronously, so the client never reads an unprojected tree; after that
/// `clientsSeen()` stays true and the host projects every frame again.
pub const ProjectionDemand = struct {
    ctx: *anyopaque,
    project: *const fn (ctx: *anyopaque) void,
};

/// Set by every NSAccessibility query. Never cleared: clients come and go
/// (VoiceOver, Accessibility Inspector, automation) and a dropped projection
/// would leave the next one reading stale geometry.
var g_clients_seen: bool = false;

pub fn clientsSeen() bool {
    return g_clients_seen;
}

/// Register (or clear, with null) the demand handler for a window. The slot
/// must already exist: hosts call this right after `setActiveContext*`.
pub fn setProjectionDemand(window_id: u32, demand: ?ProjectionDemand) void {
    for (&g_active) |*maybe| {
        if (maybe.*) |*slot| {
            if (slot.window_id == window_id) {
                slot.demand = demand;
                return;
            }
        }
    }
}

pub fn resetClientsSeenForTesting() void {
    g_clients_seen = false;
}

pub const TextInputAppliedHook = *const fn (window_id: u32, start_utf16: u64, end_utf16: u64, start_utf8: u32, end_utf8: u32) callconv(.c) c_int;
var g_text_input_applied_hook: ?TextInputAppliedHook = null;

pub fn setTextInputAppliedHook(hook: ?TextInputAppliedHook) void {
    g_text_input_applied_hook = hook;
}

/// Publish only an applied projection, never the speculative native packet.
/// Resolve focus afresh after dispatch: the handler may have removed its node.
pub fn publishAppliedPreedit(window_id: u32) void {
    const hook = g_text_input_applied_hook orelse return;
    const client = lookupTextInput(window_id) orelse return;
    if (client.secure) return;
    const marked = client.marked_range orelse return;
    var start: u32 = 0;
    var end: u32 = 0;
    if (!marked(client.context, &start, &end) or start > end or end > client.text_len(client.context)) return;
    const start16 = utf16ForUtf8(client, start) orelse return;
    const end16 = utf16ForUtf8(client, end) orelse return;
    _ = hook(window_id, start16, end16, start, end);
}

/// Text input is registered independently from the retained accessibility
/// tree. AppKit calls NSTextInputClient synchronously during event handling;
/// consulting the last rendered AX snapshot here would be one frame stale.
pub const TextInputClientResolver = *const fn (ctx: *anyopaque) ?core_types.TextInputClient;
const TextInputSlot = struct {
    window_id: u32,
    context: *anyopaque,
    resolver: TextInputClientResolver,
};
var g_text_input: [MAX_WINDOWS]?TextInputSlot = @splat(null);

fn lookupTextInput(window_id: u32) ?core_types.TextInputClient {
    if (window_id == ANY_WINDOW) {
        for (g_text_input) |maybe| if (maybe) |slot| return slot.resolver(slot.context);
        return null;
    }
    for (g_text_input) |maybe| if (maybe) |slot| {
        if (slot.window_id == window_id) return slot.resolver(slot.context);
    };
    return null;
}

pub fn setTextInputResolver(window_id: u32, context: *anyopaque, resolver: TextInputClientResolver) bool {
    var free_idx: ?usize = null;
    for (&g_text_input, 0..) |*maybe, i| {
        if (maybe.*) |slot| {
            if (slot.window_id == window_id) {
                maybe.* = .{ .window_id = window_id, .context = context, .resolver = resolver };
                return true;
            }
        } else if (free_idx == null) free_idx = i;
    }
    const idx = free_idx orelse return false;
    g_text_input[idx] = .{ .window_id = window_id, .context = context, .resolver = resolver };
    return true;
}

/// Unregister only the synchronous text client. Accessibility snapshots have
/// an independent lifetime and must not be torn down merely because a system
/// SDK/window backend is being replaced.
pub fn clearTextInputResolver(window_id: u32) void {
    for (&g_text_input) |*maybe| if (maybe.*) |slot| {
        if (slot.window_id == window_id) maybe.* = null;
    };
}

pub fn clearTextInputResolverForOwner(window_id: u32, owner: *anyopaque) void {
    for (&g_text_input) |*maybe| if (maybe.*) |slot| {
        if (slot.window_id == window_id and slot.context == owner) maybe.* = null;
    };
}

/// ObjC passes wildcard when can't get specific window_id (old single-window proxy,
/// unhooked test harness). lookup degrades to "first registered window in table".
pub const ANY_WINDOW: u32 = 0;
/// C ABI missing-handle sentinel. Handle zero is a valid first ElementId and
/// must never be overloaded as failure.
pub const INVALID_HANDLE: u64 = AXId.NULL.raw();

fn lookup(window_id: u32) ?ActiveContext {
    g_clients_seen = true;
    const idx = slotIndex(window_id) orelse return null;
    if (g_active[idx].?.demand) |demand| {
        // Projection re-registers this window in place (same index), so read
        // the slot again afterwards rather than holding a copy across it.
        demand.project(demand.ctx);
    }
    const slot = g_active[idx] orelse return null;
    return slot.ctx;
}

fn slotIndex(window_id: u32) ?usize {
    for (g_active, 0..) |maybe, i| {
        const slot = maybe orelse continue;
        if (window_id == ANY_WINDOW or slot.window_id == window_id) return i;
    }
    return null;
}

/// cx sets this during init/render and clears it on deinit.
///
/// Registered by `window_id`: multiple windows each register their own a11y tree; ObjC proxy
/// objects hold window_id so callbacks hit their own slot without overriding.
/// Re-registering the same window_id updates in place (syncA11yTree calls it each frame).
///
/// Table full: silently discard (return false); a11y degrading beats a render crash.
pub fn setActiveContext(
    window_id: u32,
    tree: *AccessibilityTree,
    label_ctx: *anyopaque,
    label_resolver: LabelResolver,
) bool {
    return setActiveContextWithFullInteractions(
        window_id,
        tree,
        label_ctx,
        label_resolver,
        null,
        null,
        null,
        null,
        null,
        null,
        null,
        null,
    );
}

/// Production registration including callable interaction routes. Tests and
/// non-interactive consumers may keep using setActiveContext, which advertises
/// no callable native actions and therefore fails closed.
pub fn setActiveContextWithInteractions(
    window_id: u32,
    tree: *AccessibilityTree,
    label_ctx: *anyopaque,
    label_resolver: LabelResolver,
    interaction_ctx: ?*anyopaque,
    action_handler: ?ActionHandler,
    selection_handler: ?SelectionHandler,
) bool {
    return setActiveContextWithFullInteractions(
        window_id,
        tree,
        label_ctx,
        label_resolver,
        interaction_ctx,
        action_handler,
        selection_handler,
        null,
        null,
        null,
        null,
        null,
    );
}

pub fn setActiveContextWithFullInteractions(
    window_id: u32,
    tree: *AccessibilityTree,
    label_ctx: *anyopaque,
    label_resolver: LabelResolver,
    interaction_ctx: ?*anyopaque,
    action_handler: ?ActionHandler,
    selection_handler: ?SelectionHandler,
    focus_handler: ?FocusHandler,
    text_value_handler: ?TextValueHandler,
    numeric_value_handler: ?NumericValueHandler,
    text_frame_handler: ?TextFrameHandler,
    text_range_at_point_handler: ?TextRangeAtPointHandler,
) bool {
    const ctx = ActiveContext{
        .tree = tree,
        .label_ctx = label_ctx,
        .label_resolver = label_resolver,
        .interaction_ctx = interaction_ctx,
        .action_handler = action_handler,
        .selection_handler = selection_handler,
        .focus_handler = focus_handler,
        .text_value_handler = text_value_handler,
        .numeric_value_handler = numeric_value_handler,
        .text_frame_handler = text_frame_handler,
        .text_range_at_point_handler = text_range_at_point_handler,
    };
    var free_idx: ?usize = null;
    for (&g_active, 0..) |*maybe, i| {
        if (maybe.*) |slot| {
            if (slot.window_id == window_id) {
                // Hosts re-register every frame: keep the projection demand, but
                // only for the same owner. Another Cx taking over this window id
                // must not inherit a handler pointing at the old one, which can
                // be freed while the slot stays registered to the new owner.
                const demand = if (slot.demand) |d| (if (d.ctx == ctx.label_ctx) d else null) else null;
                maybe.* = .{ .window_id = window_id, .ctx = ctx, .demand = demand };
                return true;
            }
        } else if (free_idx == null) {
            free_idx = i;
        }
    }
    const idx = free_idx orelse return false;
    g_active[idx] = .{ .window_id = window_id, .ctx = ctx };
    return true;
}

/// unregister a window's a11y tree. other window registrations unaffected.
pub fn clearActiveContext(window_id: u32) void {
    var removed = false;
    for (&g_active) |*maybe| {
        if (maybe.*) |slot| {
            if (slot.window_id == window_id) {
                maybe.* = null;
                removed = true;
            }
        }
    }
    if (removed) {
        if (g_push_hooks.window_cleared) |hook| _ = hook(window_id);
    }
    clearTextInputResolver(window_id);
}

/// A newly allocated Cx still has a default window id, and an old Cx may be
/// destroyed after its replacement registers. Neither owns the other Cx's
/// registrations merely because the numeric window id happens to match.
pub fn clearActiveContextForOwner(window_id: u32, owner: *anyopaque) void {
    var removed = false;
    for (&g_active) |*maybe| if (maybe.*) |*slot| {
        if (slot.window_id == window_id and slot.ctx.label_ctx == owner) {
            maybe.* = null;
            removed = true;
        } else if (slot.demand) |d| {
            // Belt and braces: never leave a demand handler to a freed owner.
            if (d.ctx == owner) slot.demand = null;
        }
    };
    if (removed) {
        if (g_push_hooks.window_cleared) |hook| _ = hook(window_id);
    }
    clearTextInputResolverForOwner(window_id, owner);
}

/// clear entire table (test fixture; production should clearActiveContext per-window).
pub fn clearAllActiveContexts() void {
    g_active = @splat(null);
    g_text_input = @splat(null);
}

/// current registered window count (diagnostic/test).
pub fn activeContextCount() usize {
    var n: usize = 0;
    for (g_active) |maybe| {
        if (maybe != null) n += 1;
    }
    return n;
}

// C ABI exports (called from ObjC).
// Each export's first parameter is `window_id`; ObjC-side ZenitA11yElement / MetalView
// proxy holds owning window id and passes it each protocol method, zig end routes to that window's
// own AccessibilityTree. Pass ANY_WINDOW(0) degrades to "first registered window" (old behavior).

const INVALID_TEXT_OFFSET: u64 = std.math.maxInt(u64);

export fn zenit_text_input_length(window_id: u32) u64 {
    const client = lookupTextInput(window_id) orelse return INVALID_TEXT_OFFSET;
    return @intCast(client.text_len(client.context));
}

export fn zenit_text_input_copy(window_id: u32, start_utf8: u64, buf: ?[*]u8, buf_len: c_int) c_int {
    if (buf_len < 0 or (buf_len > 0 and buf == null)) return -1;
    const client = lookupTextInput(window_id) orelse return -1;
    if (client.secure) return -1;
    const total = client.text_len(client.context);
    const start = std.math.cast(usize, start_utf8) orelse return -1;
    if (start > total) return -1;
    if (buf_len == 0) return 0;
    const out = buf.?[0..@intCast(buf_len)];
    const copied = @min(client.copy_text(client.context, start, out), out.len);
    return @intCast(copied);
}

export fn zenit_text_input_selection(window_id: u32, start: ?*u32, end: ?*u32, caret: ?*u32) c_int {
    const client = lookupTextInput(window_id) orelse return 0;
    if (client.secure) return 0;
    const total: u32 = @intCast(@min(client.text_len(client.context), std.math.maxInt(u32)));
    const selection = client.selection(client.context);
    if (start) |out| out.* = @min(selection.start, total);
    if (end) |out| out.* = @min(selection.end, total);
    if (caret) |out| out.* = @min(selection.caret, total);
    return 1;
}

export fn zenit_text_input_frame(window_id: u32, start_utf8: u32, end_utf8: u32, x: ?*f32, y: ?*f32, width: ?*f32, height: ?*f32) c_int {
    const client = lookupTextInput(window_id) orelse return 0;
    if (client.secure) return 0;
    const callback = client.frame_for_range orelse return 0;
    var rect: core_types.A11yRect = undefined;
    if (!callback(client.context, start_utf8, end_utf8, &rect)) return 0;
    if (!std.math.isFinite(rect.x) or !std.math.isFinite(rect.y) or
        !std.math.isFinite(rect.width) or !std.math.isFinite(rect.height)) return 0;
    if (x) |out| out.* = rect.x;
    if (y) |out| out.* = rect.y;
    if (width) |out| out.* = rect.width;
    if (height) |out| out.* = rect.height;
    return 1;
}

export fn zenit_text_input_range_at_point(window_id: u32, x: f32, y: f32, start_utf8: ?*u32, end_utf8: ?*u32) c_int {
    const client = lookupTextInput(window_id) orelse return 0;
    if (client.secure) return 0;
    const callback = client.range_at_point orelse return 0;
    var start: u32 = 0;
    var end: u32 = 0;
    if (!callback(client.context, x, y, &start, &end)) return 0;
    if (start_utf8) |out| out.* = start;
    if (end_utf8) |out| out.* = end;
    return 1;
}

fn validUtf8ChunkPrefix(bytes: []const u8) usize {
    var len = bytes.len;
    var attempts: u3 = 0;
    while (len > 0 and !std.unicode.utf8ValidateSlice(bytes[0..len]) and attempts < 4) : (attempts += 1) len -= 1;
    return if (std.unicode.utf8ValidateSlice(bytes[0..len])) len else 0;
}

/// Scan a live UTF-8 model without materialising the complete document. The
/// return values are clamped down to scalar boundaries, matching NSString's
/// behaviour for malformed half-surrogate range requests.
fn utf16ForUtf8(client: core_types.TextInputClient, requested: usize) ?u64 {
    const total = client.text_len(client.context);
    const target = @min(requested, total);
    var byte_pos: usize = 0;
    var utf16_pos: u64 = 0;
    var buf: [4096]u8 = undefined;
    while (byte_pos < target) {
        // Read past `target` when possible. A native UTF-16 request may land
        // in the middle of a UTF-8 scalar; limiting the copy to `target`
        // would leave only an invalid prefix (for example the first two bytes
        // of a three-byte CJK scalar). Reading the complete scalar lets us
        // clamp the request down to its start, as NSTextInputClient expects.
        const wanted = @min(buf.len, total - byte_pos);
        const copied = @min(client.copy_text(client.context, byte_pos, buf[0..wanted]), wanted);
        if (copied == 0) return null;
        const valid_len = validUtf8ChunkPrefix(buf[0..copied]);
        if (valid_len == 0) return null;
        var i: usize = 0;
        while (i < valid_len) {
            const seq_len = std.unicode.utf8ByteSequenceLength(buf[i]) catch return null;
            if (i + seq_len > valid_len) break;
            if (byte_pos + i + seq_len > target) return utf16_pos;
            const scalar = std.unicode.utf8Decode(buf[i .. i + seq_len]) catch return null;
            utf16_pos += if (scalar > 0xFFFF) 2 else 1;
            i += seq_len;
        }
        byte_pos += valid_len;
    }
    return utf16_pos;
}

fn utf8ForUtf16(client: core_types.TextInputClient, requested: u64) ?u64 {
    const total = client.text_len(client.context);
    var byte_pos: usize = 0;
    var utf16_pos: u64 = 0;
    var buf: [4096]u8 = undefined;
    while (byte_pos < total) {
        const wanted = @min(buf.len, total - byte_pos);
        const copied = @min(client.copy_text(client.context, byte_pos, buf[0..wanted]), wanted);
        if (copied == 0) return null;
        const valid_len = validUtf8ChunkPrefix(buf[0..copied]);
        if (valid_len == 0) return null;
        var i: usize = 0;
        while (i < valid_len) {
            const seq_len = std.unicode.utf8ByteSequenceLength(buf[i]) catch return null;
            if (i + seq_len > valid_len) break;
            const scalar = std.unicode.utf8Decode(buf[i .. i + seq_len]) catch return null;
            const units: u64 = if (scalar > 0xFFFF) 2 else 1;
            if (utf16_pos + units > requested) return @intCast(byte_pos + i);
            utf16_pos += units;
            i += seq_len;
            if (utf16_pos == requested) return @intCast(byte_pos + i);
        }
        byte_pos += valid_len;
    }
    return @intCast(total);
}

export fn zenit_text_input_utf16_for_utf8(window_id: u32, utf8_offset: u64) u64 {
    const client = lookupTextInput(window_id) orelse return INVALID_TEXT_OFFSET;
    if (client.secure) return INVALID_TEXT_OFFSET;
    const requested = std.math.cast(usize, utf8_offset) orelse return INVALID_TEXT_OFFSET;
    return utf16ForUtf8(client, requested) orelse INVALID_TEXT_OFFSET;
}

export fn zenit_text_input_utf8_for_utf16(window_id: u32, utf16_offset: u64) u64 {
    const client = lookupTextInput(window_id) orelse return INVALID_TEXT_OFFSET;
    if (client.secure) return INVALID_TEXT_OFFSET;
    return utf8ForUtf16(client, utf16_offset) orelse INVALID_TEXT_OFFSET;
}

/// count top-level a11y nodes (parent.isNull()).
export fn zenit_a11y_root_count(window_id: u32) c_int {
    const active = lookup(window_id) orelse return 0;
    return @intCast(active.tree.exposedChildren(AXId.NULL).len);
}

/// idx-th root handle, stable-sort by sibling_index (then raw handle).
/// out-of-bounds returns INVALID_HANDLE; ElementId raw=0 valid.
export fn zenit_a11y_root_at(window_id: u32, idx: c_int) u64 {
    const active = lookup(window_id) orelse return INVALID_HANDLE;
    return exposedChildAt(active.tree, AXId.NULL, idx);
}

/// Whether a virtual element handle still belongs to the current window tree.
/// Native bridges use this to retain live NSAccessibilityElement instances
/// while pruning stale generational handles after a rebuild.
export fn zenit_a11y_exists(window_id: u32, handle: u64) c_int {
    const active = lookup(window_id) orelse return 0;
    return if (active.tree.get(AXId.fromRaw(handle)) != null) 1 else 0;
}

/// element's a11y children count. collection tables report all data rows (matches NSTableView AXChildren).
export fn zenit_a11y_children_count(window_id: u32, parent_raw: u64) c_int {
    const active = lookup(window_id) orelse return 0;
    const n = active.tree.childCount(AXId.fromRaw(parent_raw));
    return @intCast(@min(n, std.math.maxInt(c_int)));
}

/// idx-th child handle. Collection table rows materialized on-demand here.
export fn zenit_a11y_children_at(window_id: u32, parent_raw: u64, idx: c_int) u64 {
    const active = lookup(window_id) orelse return INVALID_HANDLE;
    if (idx < 0) return INVALID_HANDLE;
    const child = active.tree.childAt(AXId.fromRaw(parent_raw), @intCast(idx)) orelse return INVALID_HANDLE;
    return child.raw();
}

/// Collection table row info: row count, visible range by committed offset intersect viewport.
/// non-collection-table returns 0.
export fn zenit_a11y_collection_info(window_id: u32, handle: u64, count: ?*u32, first_visible: ?*u32, visible_len: ?*u32) c_int {
    const active = lookup(window_id) orelse return 0;
    const c = active.tree.collections.collectionForTable(AXId.fromRaw(handle)) orelse return 0;
    const visible = if (c.hidden) @TypeOf(c.visibleRange()){ .first = 0, .len = 0 } else c.visibleRange();
    if (count) |out| out.* = if (c.hidden) 0 else c.count;
    if (first_visible) |out| out.* = visible.first;
    if (visible_len) |out| out.* = visible.len;
    return 1;
}

/// Collection table index-th row (AXRows paginated fetch). out-of-bounds or non-collection returns INVALID.
export fn zenit_a11y_collection_row_at(window_id: u32, handle: u64, index: u32) u64 {
    const active = lookup(window_id) orelse return INVALID_HANDLE;
    const row = active.tree.collections.rowAt(active.tree.allocator, AXId.fromRaw(handle), index) orelse return INVALID_HANDLE;
    return row.raw();
}

/// call inside AX callback (not deferred): write collection entry scroll-into-viewport offset to a11y
/// layer committed offset, subsequent frame / visible row reads this frame reflect new position.
/// app-side scroll by deferred execute perform_action(scroll_to_visible) follow. non-collection-entry
/// returns 0.
export fn zenit_a11y_commit_scroll_to_visible(window_id: u32, handle: u64) c_int {
    const active = lookup(window_id) orelse return 0;
    return if (active.tree.collections.commitScrollToVisible(AXId.fromRaw(handle))) 1 else 0;
}

fn nodeComesBefore(a: A11yNode, b: A11yNode) bool {
    if (a.sibling_index != b.sibling_index) return a.sibling_index < b.sibling_index;
    return a.element.raw() < b.element.raw();
}

/// top element: ordered child list index on tree, O(1).
fn exposedChildAt(tree: *AccessibilityTree, parent: AXId, idx: c_int) u64 {
    if (idx < 0) return INVALID_HANDLE;
    const kids = tree.exposedChildren(parent);
    const i: usize = @intCast(idx);
    if (i >= kids.len) return INVALID_HANDLE;
    return kids[i].raw();
}

/// set total count (aria-setsize / aria-rowcount), 0 = undeclared.
export fn zenit_a11y_set_size(window_id: u32, handle: u64) u32 {
    const active = lookup(window_id) orelse return 0;
    const id = AXId.fromRaw(handle);
    if (active.tree.collections.collectionForTable(id)) |c| return if (c.hidden) 0 else c.count;
    const node = active.tree.get(id) orelse return 0;
    return node.set_size;
}

/// node role (a11y_tree.Role u16). invalid handle or absent -> .none (0).
export fn zenit_a11y_role(window_id: u32, handle: u64) c_int {
    const active = lookup(window_id) orelse return 0;
    const id = AXId.fromRaw(handle);
    const node = active.tree.get(id) orelse return 0;
    return @intCast(@backingInt(node.role));
}

/// node state packed bits (a11y_tree.State u32).
export fn zenit_a11y_state(window_id: u32, handle: u64) u32 {
    const active = lookup(window_id) orelse return 0;
    const id = AXId.fromRaw(handle);
    const node = active.tree.get(id) orelse return 0;
    return @bitCast(node.state);
}

/// Parent/focus/active-descendant relationships are pulled by the native
/// proxy cache. INVALID_HANDLE means absent and is never confused with a live
/// index-zero element.
export fn zenit_a11y_parent(window_id: u32, handle: u64) u64 {
    const active = lookup(window_id) orelse return INVALID_HANDLE;
    const node = active.tree.get(AXId.fromRaw(handle)) orelse return INVALID_HANDLE;
    return if (node.parent.isNull()) INVALID_HANDLE else node.parent.raw();
}

export fn zenit_a11y_focused(window_id: u32) u64 {
    const active = lookup(window_id) orelse return INVALID_HANDLE;
    const focused = active.tree.focused;
    const node = active.tree.get(focused) orelse return INVALID_HANDLE;
    if (node.state.hidden or !node.state.focused) return INVALID_HANDLE;
    return focused.raw();
}

export fn zenit_a11y_active_descendant(window_id: u32, handle: u64) u64 {
    const active = lookup(window_id) orelse return INVALID_HANDLE;
    const node = active.tree.get(AXId.fromRaw(handle)) orelse return INVALID_HANDLE;
    if (node.active_descendant.isNull()) return INVALID_HANDLE;
    const descendant = active.tree.get(node.active_descendant) orelse return INVALID_HANDLE;
    if (descendant.state.hidden) return INVALID_HANDLE;
    if (!isDescendantOf(active.tree, descendant, node.element)) return INVALID_HANDLE;
    return descendant.element.raw();
}

fn isDescendantOf(tree: *const AccessibilityTree, child: A11yNode, ancestor: AXId) bool {
    var parent = child.parent;
    var depth: usize = 0;
    while (!parent.isNull() and depth <= tree.nodes.items.len) : (depth += 1) {
        if (parent.eql(ancestor)) return true;
        const node = tree.get(parent) orelse return false;
        parent = node.parent;
    }
    return false;
}

/// Deepest exposed element containing a window-content point. Equal-depth
/// overlap resolves to later sibling order, matching retained paint order.
export fn zenit_a11y_hit_test(window_id: u32, x: f32, y: f32) u64 {
    const active = lookup(window_id) orelse return INVALID_HANDLE;
    var best: ?A11yNode = null;
    var best_depth: usize = 0;
    for (active.tree.nodes.items) |maybe| {
        const node = maybe orelse continue;
        if (node.state.hidden or !node.frame.isUsable() or node.frame.width <= 0 or node.frame.height <= 0) continue;
        if (x < node.frame.x or y < node.frame.y or
            x > node.frame.x + node.frame.width or y > node.frame.y + node.frame.height) continue;
        const depth = nodeDepth(active.tree, node);
        if (best == null or depth > best_depth or
            (depth == best_depth and nodeComesBefore(best.?, node)))
        {
            best = node;
            best_depth = depth;
        }
    }
    // Collection: a point inside the viewport lands on an entry. Deeper nodes inside a bound row
    // (button, text) are hit by the node scan above, and the deeper one wins; an unbound row can
    // only hit its entry element.
    if (active.tree.collections.hitTest(active.tree.allocator, x, y)) |hit| {
        if (active.tree.get(hit.id)) |item| {
            const depth = nodeDepth(active.tree, item);
            if (best == null or depth > best_depth) return hit.id.raw();
        }
    }
    return if (best) |node| node.element.raw() else INVALID_HANDLE;
}

fn nodeDepth(tree: *const AccessibilityTree, start: A11yNode) usize {
    var depth: usize = 0;
    var parent = start.parent;
    // A malformed cycle must not make an AX callback hang.
    while (!parent.isNull() and depth <= tree.nodes.items.len) : (depth += 1) {
        const node = tree.get(parent) orelse break;
        parent = node.parent;
    }
    return depth;
}

/// Element frame in window content coordinates (logical points, top-left
/// origin). Return 1 on success; invalid/stale handles return 0 and never write.
export fn zenit_a11y_frame(window_id: u32, handle: u64, x: ?*f32, y: ?*f32, width: ?*f32, height: ?*f32) c_int {
    const active = lookup(window_id) orelse return 0;
    const node = active.tree.get(AXId.fromRaw(handle)) orelse return 0;
    if (!node.frame.isUsable()) return 0;
    if (x) |out| out.* = node.frame.x;
    if (y) |out| out.* = node.frame.y;
    if (width) |out| out.* = node.frame.width;
    if (height) |out| out.* = node.frame.height;
    return 1;
}

export fn zenit_a11y_orientation(window_id: u32, handle: u64) u8 {
    const active = lookup(window_id) orelse return @backingInt(tree_mod.Orientation.undefined);
    const node = active.tree.get(AXId.fromRaw(handle)) orelse return @backingInt(tree_mod.Orientation.undefined);
    return @backingInt(node.orientation);
}

export fn zenit_a11y_sort_direction(window_id: u32, handle: u64) u8 {
    const active = lookup(window_id) orelse return @backingInt(tree_mod.SortDirection.none);
    const node = active.tree.get(AXId.fromRaw(handle)) orelse return @backingInt(tree_mod.SortDirection.none);
    return @backingInt(node.sort_direction);
}

export fn zenit_a11y_level(window_id: u32, handle: u64) u16 {
    const active = lookup(window_id) orelse return 0;
    const node = active.tree.get(AXId.fromRaw(handle)) orelse return 0;
    return node.level;
}

export fn zenit_a11y_row_index_range(window_id: u32, handle: u64, index: ?*u32, span: ?*u32) c_int {
    const active = lookup(window_id) orelse return 0;
    const node = active.tree.get(AXId.fromRaw(handle)) orelse return 0;
    switch (node.role) {
        .row, .cell, .rowheader, .columnheader => {
            if (index) |out| out.* = node.row_index;
        },
        .treeitem => {
            if (index) |out| out.* = node.row_index;
        },
        .listitem => {
            // if declared pos_in_set (virtual list data position) use it, else fall back visible
            // sibling order.
            if (index) |out| out.* = if (node.pos_in_set > 0) node.pos_in_set - 1 else node.sibling_index;
        },
        else => return 0,
    }
    if (span) |out| out.* = @max(node.row_span, 1);
    return 1;
}

export fn zenit_a11y_column_index_range(window_id: u32, handle: u64, index: ?*u32, span: ?*u32) c_int {
    const active = lookup(window_id) orelse return 0;
    const node = active.tree.get(AXId.fromRaw(handle)) orelse return 0;
    switch (node.role) {
        .cell, .rowheader, .columnheader => {},
        else => return 0,
    }
    if (index) |out| out.* = node.column_index;
    if (span) |out| out.* = @max(node.column_span, 1);
    return 1;
}

/// Packed tree.Actions. Capability bits are additionally masked by whether
/// this window registered a live interaction handler.
export fn zenit_a11y_actions(window_id: u32, handle: u64) u8 {
    const active = lookup(window_id) orelse return 0;
    if (active.interaction_ctx == null or active.action_handler == null) return 0;
    const node = active.tree.get(AXId.fromRaw(handle)) orelse return 0;
    if (node.state.disabled) return 0;
    return @bitCast(node.actions);
}

export fn zenit_a11y_perform_action(window_id: u32, handle: u64, action_raw: u8) c_int {
    const active = lookup(window_id) orelse return 0;
    const ctx = active.interaction_ctx orelse return 0;
    const handler = active.action_handler orelse return 0;
    const id = AXId.fromRaw(handle);
    const node = active.tree.get(id) orelse return 0;
    const action = std.enums.fromInt(Action, action_raw) orelse return 0;
    if (node.state.disabled and action != .scroll_to_visible) return 0;
    const advertised = switch (action) {
        .press => node.actions.press,
        .toggle => node.actions.toggle,
        .increment => node.actions.increment,
        .decrement => node.actions.decrement,
        .scroll_to_visible => true,
    };
    if (!advertised) return 0;
    return if (handler(ctx, id, action)) 1 else 0;
}

export fn zenit_a11y_set_focus(window_id: u32, handle: u64, focused: c_int) c_int {
    const active = lookup(window_id) orelse return 0;
    const ctx = active.interaction_ctx orelse return 0;
    const handler = active.focus_handler orelse return 0;
    const id = AXId.fromRaw(handle);
    const node = active.tree.get(id) orelse return 0;
    // Clearing stale focus remains legal after a control becomes disabled or
    // hidden; acquiring focus is restricted to an enabled, exposed target.
    if (focused != 0 and (!node.state.focusable or node.state.disabled or node.state.hidden)) return 0;
    if (focused == 0 and !node.state.focused) return 0;
    return if (handler(ctx, id, focused != 0)) 1 else 0;
}

/// Returns UTF-8 byte selection/caret offsets. Native bridges convert these to
/// their required unit (UTF-16 on AppKit). No complete contract => return 0.
export fn zenit_a11y_text_selection(window_id: u32, handle: u64, start: ?*u32, end: ?*u32, caret: ?*u32) c_int {
    const active = lookup(window_id) orelse return 0;
    const node = active.tree.get(AXId.fromRaw(handle)) orelse return 0;
    const editable = node.editable_text orelse return 0;
    if (start) |out| out.* = editable.selection_start;
    if (end) |out| out.* = editable.selection_end;
    if (caret) |out| out.* = editable.caret;
    return 1;
}

/// bit 0 = readable range/value contract, bit 1 = writable selection,
/// bit 2 = writable value, bit 3 = range geometry / point hit-testing.
export fn zenit_a11y_text_capabilities(window_id: u32, handle: u64) u8 {
    const active = lookup(window_id) orelse return 0;
    const node = active.tree.get(AXId.fromRaw(handle)) orelse return 0;
    const editable = node.editable_text orelse return 0;
    const interactive = active.interaction_ctx != null and !node.state.disabled;
    return @as(u8, 1) |
        (if (editable.can_set_selection and active.selection_handler != null and interactive) @as(u8, 2) else 0) |
        (if (editable.can_set_value and active.text_value_handler != null and interactive and !node.state.readonly) @as(u8, 4) else 0) |
        (if (active.text_frame_handler != null and active.text_range_at_point_handler != null) @as(u8, 8) else 0);
}

export fn zenit_a11y_set_text_selection(window_id: u32, handle: u64, start_utf8: u32, end_utf8: u32) c_int {
    const active = lookup(window_id) orelse return 0;
    const ctx = active.interaction_ctx orelse return 0;
    const handler = active.selection_handler orelse return 0;
    const id = AXId.fromRaw(handle);
    const node = active.tree.get(id) orelse return 0;
    const editable = node.editable_text orelse return 0;
    if (!editable.can_set_selection or node.state.disabled) return 0;
    return if (handler(ctx, id, start_utf8, end_utf8)) 1 else 0;
}

export fn zenit_a11y_text_visible_range(window_id: u32, handle: u64, start: ?*u32, end: ?*u32) c_int {
    const active = lookup(window_id) orelse return 0;
    const node = active.tree.get(AXId.fromRaw(handle)) orelse return 0;
    const editable = node.editable_text orelse return 0;
    if (start) |out| out.* = editable.visible_start;
    if (end) |out| out.* = editable.visible_end;
    return 1;
}

export fn zenit_a11y_set_text_value(window_id: u32, handle: u64, bytes: ?[*]const u8, len: c_int) c_int {
    if (len < 0 or (len > 0 and bytes == null)) return 0;
    const active = lookup(window_id) orelse return 0;
    const ctx = active.interaction_ctx orelse return 0;
    const handler = active.text_value_handler orelse return 0;
    const id = AXId.fromRaw(handle);
    const node = active.tree.get(id) orelse return 0;
    const editable = node.editable_text orelse return 0;
    if (!editable.can_set_value or node.state.disabled or node.state.readonly) return 0;
    const value = if (len == 0) "" else bytes.?[0..@intCast(len)];
    return if (handler(ctx, id, value)) 1 else 0;
}

export fn zenit_a11y_text_frame(
    window_id: u32,
    handle: u64,
    start_utf8: u32,
    end_utf8: u32,
    x: ?*f32,
    y: ?*f32,
    width: ?*f32,
    height: ?*f32,
) c_int {
    const active = lookup(window_id) orelse return 0;
    const ctx = active.interaction_ctx orelse return 0;
    const handler = active.text_frame_handler orelse return 0;
    const id = AXId.fromRaw(handle);
    const node = active.tree.get(id) orelse return 0;
    if (node.editable_text == null) return 0;
    var frame: tree_mod.Frame = .{};
    if (!handler(ctx, id, start_utf8, end_utf8, &frame) or !frame.isUsable()) return 0;
    if (x) |out| out.* = frame.x;
    if (y) |out| out.* = frame.y;
    if (width) |out| out.* = frame.width;
    if (height) |out| out.* = frame.height;
    return 1;
}

export fn zenit_a11y_text_range_at_point(
    window_id: u32,
    handle: u64,
    x: f32,
    y: f32,
    start_utf8: ?*u32,
    end_utf8: ?*u32,
) c_int {
    const active = lookup(window_id) orelse return 0;
    const ctx = active.interaction_ctx orelse return 0;
    const handler = active.text_range_at_point_handler orelse return 0;
    const id = AXId.fromRaw(handle);
    const node = active.tree.get(id) orelse return 0;
    if (node.editable_text == null) return 0;
    var start: u32 = 0;
    var end: u32 = 0;
    if (!handler(ctx, id, x, y, &start, &end)) return 0;
    if (start_utf8) |out| out.* = start;
    if (end_utf8) |out| out.* = end;
    return 1;
}

export fn zenit_a11y_set_numeric_value(window_id: u32, handle: u64, value: f32) c_int {
    if (!std.math.isFinite(value)) return 0;
    const active = lookup(window_id) orelse return 0;
    const ctx = active.interaction_ctx orelse return 0;
    const handler = active.numeric_value_handler orelse return 0;
    const id = AXId.fromRaw(handle);
    const node = active.tree.get(id) orelse return 0;
    if (!validNumericNode(node) or !node.can_set_numeric_value or node.state.disabled or node.state.readonly) return 0;
    const clamped = std.math.clamp(value, node.value_min, node.value_max);
    return if (handler(ctx, id, clamped)) 1 else 0;
}

/// bit 0 = readable numeric contract, bit 1 = writable numeric value.
export fn zenit_a11y_numeric_capabilities(window_id: u32, handle: u64) u8 {
    const active = lookup(window_id) orelse return 0;
    const node = active.tree.get(AXId.fromRaw(handle)) orelse return 0;
    if (!validNumericNode(node)) return 0;
    const readable: u8 = switch (node.role) {
        .slider, .spinbutton, .progressbar => 1,
        else => 0,
    };
    if (readable == 0) return 0;
    const writable = active.interaction_ctx != null and active.numeric_value_handler != null and
        node.can_set_numeric_value and !node.state.disabled and !node.state.readonly;
    return readable | (if (writable) @as(u8, 2) else 0);
}

/// copy label to buf. return bytes written (UTF-8); 0 = no label / fail.
/// ObjC typical: call once for length (buf=NULL, buf_len=0 zig return actual length for caller
/// alloc).
export fn zenit_a11y_label(window_id: u32, handle: u64, buf: ?[*]u8, buf_len: c_int) c_int {
    return resolveStringFromNode(window_id, handle, .label, buf, buf_len);
}

export fn zenit_a11y_description(window_id: u32, handle: u64, buf: ?[*]u8, buf_len: c_int) c_int {
    return resolveStringFromNode(window_id, handle, .description, buf, buf_len);
}

export fn zenit_a11y_placeholder(window_id: u32, handle: u64, buf: ?[*]u8, buf_len: c_int) c_int {
    return resolveStringFromNode(window_id, handle, .placeholder, buf, buf_len);
}

export fn zenit_a11y_identifier(window_id: u32, handle: u64, buf: ?[*]u8, buf_len: c_int) c_int {
    return resolveStringFromNode(window_id, handle, .identifier, buf, buf_len);
}

export fn zenit_a11y_value(window_id: u32, handle: u64, buf: ?[*]u8, buf_len: c_int) c_int {
    return resolveStringFromNode(window_id, handle, .value, buf, buf_len);
}

export fn zenit_a11y_numeric_value(window_id: u32, handle: u64, now: ?*f32, min: ?*f32, max: ?*f32) c_int {
    const active = lookup(window_id) orelse return 0;
    const node = active.tree.get(AXId.fromRaw(handle)) orelse return 0;
    if (!validNumericNode(node)) return 0;
    switch (node.role) {
        .slider, .spinbutton, .progressbar => {},
        else => return 0,
    }
    if (now) |out| out.* = node.value_now;
    if (min) |out| out.* = node.value_min;
    if (max) |out| out.* = node.value_max;
    return 1;
}

fn validNumericNode(node: A11yNode) bool {
    return node.numeric_value_present and
        std.math.isFinite(node.value_now) and
        std.math.isFinite(node.value_min) and
        std.math.isFinite(node.value_max) and
        node.value_min <= node.value_max and
        node.value_now >= node.value_min and node.value_now <= node.value_max;
}

const StringField = enum { label, description, placeholder, identifier, value };

/// Collection entry text temp buffer. export only called by AX callback on main thread, no reentry.
var g_item_text_buf: [512]u8 = undefined;

fn resolveStringFromNode(window_id: u32, handle: u64, field: StringField, buf: ?[*]u8, buf_len: c_int) c_int {
    const active = lookup(window_id) orelse return 0;
    const id = AXId.fromRaw(handle);
    if (id.kind == .cell_text) {
        if (field != .value) return 0;
        const text = active.tree.collections.itemText(id, &g_item_text_buf) orelse return 0;
        return copyOut(text, buf, buf_len);
    }
    const node = active.tree.get(id) orelse return 0;
    const hash: u64 = switch (field) {
        .label => node.label_hash,
        .description => node.description_hash,
        .placeholder => node.placeholder_hash,
        .identifier => node.identifier_hash,
        .value => node.text_hash,
    };
    if (hash == 0) return 0;
    const str = active.label_resolver(active.label_ctx, hash) orelse return 0;
    return copyOut(str, buf, buf_len);
}

fn copyOut(str: []const u8, buf: ?[*]u8, buf_len: c_int) c_int {
    if (str.len == 0) return 0;

    // probe mode: buf=NULL -> return actual length
    if (buf == null or buf_len <= 0) return @intCast(str.len);

    const write_len = @min(@as(usize, @intCast(buf_len)), str.len);
    @memcpy(buf.?[0..write_len], str[0..write_len]);
    return @intCast(write_len);
}

// ============================================================================
// Push side (zig -> ObjC NSAccessibilityPostNotification)
// ----------------------------------------------------------------------------
// At end of cx.render(), a11y_router.flushToBridge pushes the dirty queue here.
// window_id is carried by PushCxRef (cx's system_sdk WindowId); the ObjC side
// zenitWrapperForWindowId matches the wrapper by NSWindow.windowNumber.
//
// All retained-tree notifications use this exact-element route. The older
// SystemSdk snapshot calls remain an explicit compatibility API and Cx does
// not automatically duplicate focus notifications through that path.
// ============================================================================

/// Platform push hooks, example builds (window_bridge.m linked) override these fn ptr to send
/// notifications to NSAccessibilityPostNotification;
/// test builds default no-op to avoid link errors. Designed analogous to weak symbol; register
/// runtime via setPushHooks.
pub const PushHooks = struct {
    property_changed: ?*const fn (window_id: u32, element_raw: u64, flags: u16) callconv(.c) c_int = null,
    focus_changed: ?*const fn (window_id: u32, element_raw: u64) callconv(.c) c_int = null,
    children_changed: ?*const fn (window_id: u32, element_raw: u64) callconv(.c) c_int = null,
    announce: ?*const fn (window_id: u32, text_ptr: [*]const u8, text_len: c_int, priority: u8) callconv(.c) c_int = null,
    /// aria-activedescendant, caller pass container ElementId (combobox/listbox/grid) + current
    /// active child ElementId.
    /// When active.isNull(), indicates no active descendant (popover closed etc).
    active_descendant_changed: ?*const fn (window_id: u32, container_raw: u64, active_raw: u64) callconv(.c) c_int = null,
    window_cleared: ?*const fn (window_id: u32) callconv(.c) c_int = null,
    /// Single node exits tree: platform sends UIElementDestroyed and removes from element cache.
    element_destroyed: ?*const fn (window_id: u32, element_raw: u64) callconv(.c) c_int = null,
    /// One flush ends: platform dispatches consolidated layout notifications.
    flush_end: ?*const fn (window_id: u32) callconv(.c) c_int = null,
};

var g_push_hooks: PushHooks = .{};

pub fn setPushHooks(hooks: PushHooks) void {
    g_push_hooks = hooks;
}

/// Caller-supplied context, cx inits with window_id + its own label_buf pointer.
pub const PushCxRef = struct {
    window_id: u32,
    label_ctx: *anyopaque,
    label_resolver: LabelResolver,
};

fn pushChildrenChanged(ctx: *anyopaque, id: AXId) void {
    const cx: *PushCxRef = @ptrCast(@alignCast(ctx));
    const hook = g_push_hooks.children_changed orelse return;
    _ = hook(cx.window_id, id.raw());
}

fn pushAnnounce(ctx: *anyopaque, _: AXId, text_hash: u64, live: tree_mod.LiveRegion) void {
    const cx: *PushCxRef = @ptrCast(@alignCast(ctx));
    const hook = g_push_hooks.announce orelse return;
    const str = cx.label_resolver(cx.label_ctx, text_hash) orelse return;
    if (str.len == 0) return;
    _ = hook(cx.window_id, str.ptr, @intCast(str.len), @backingInt(live));
}

fn pushProperty(ctx: *anyopaque, id: AXId, _: A11yNode, flag: tree_mod.A11yDirtyFlag) void {
    const cx: *PushCxRef = @ptrCast(@alignCast(ctx));
    const hook = g_push_hooks.property_changed orelse return;
    _ = hook(cx.window_id, id.raw(), @bitCast(flag));
}

fn pushFocus(ctx: *anyopaque, id: AXId, _: ?A11yNode) void {
    const cx: *PushCxRef = @ptrCast(@alignCast(ctx));
    const hook = g_push_hooks.focus_changed orelse return;
    _ = hook(cx.window_id, if (id.isNull()) INVALID_HANDLE else id.raw());
}

fn pushActiveDescendant(ctx: *anyopaque, container: AXId, active: AXId) void {
    const cx: *PushCxRef = @ptrCast(@alignCast(ctx));
    const hook = g_push_hooks.active_descendant_changed orelse return;
    _ = hook(cx.window_id, container.raw(), active.raw());
}

fn pushDestroyed(ctx: *anyopaque, id: AXId) void {
    const cx: *PushCxRef = @ptrCast(@alignCast(ctx));
    const hook = g_push_hooks.element_destroyed orelse return;
    _ = hook(cx.window_id, id.raw());
}

fn pushFlushEnd(ctx: *anyopaque) void {
    const cx: *PushCxRef = @ptrCast(@alignCast(ctx));
    const hook = g_push_hooks.flush_end orelse return;
    _ = hook(cx.window_id);
}

const PUSH_VTABLE = PlatformBridge.VTable{
    .notify_property = pushProperty,
    .notify_focus = pushFocus,
    .notify_children_changed = pushChildrenChanged,
    .announce = pushAnnounce,
    .notify_active_descendant = pushActiveDescendant,
    .notify_destroyed = pushDestroyed,
    .flush_end = pushFlushEnd,
};

/// Caller-side: get PlatformBridge instance bound to cx_ref.
pub fn pushBridge(cx_ref: *PushCxRef) PlatformBridge {
    return .{ .ctx = cx_ref, .vtable = &PUSH_VTABLE };
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

/// Test window_id. Real values from NSWindow.windowNumber, tests only require non-zero (0 is
/// ANY_WINDOW wildcard, degrades to
/// "first registered window", can't test routing).
const WIN: u32 = 7;

const TestLabelCtx = struct {
    map: std.AutoHashMap(u64, []const u8),
    fn resolve(ctx: *anyopaque, hash: u64) ?[]const u8 {
        const self: *TestLabelCtx = @ptrCast(@alignCast(ctx));
        return self.map.get(hash);
    }
};

test "macos_bridge: root_count / root_at" {
    var tree = AccessibilityTree.init(testing.allocator);
    defer tree.deinit();
    var ctx = TestLabelCtx{ .map = std.AutoHashMap(u64, []const u8).init(testing.allocator) };
    defer ctx.map.deinit();

    const r1 = AXId.node(.{ .index = 1, .generation = 0 });
    const r2 = AXId.node(.{ .index = 2, .generation = 0 });
    const child = AXId.node(.{ .index = 3, .generation = 0 });
    try tree.upsert(.{ .element = r1, .role = .button });
    try tree.upsert(.{ .element = r2, .role = .button });
    try tree.upsert(.{ .element = child, .parent = r1, .role = .listitem });

    try testing.expect(setActiveContext(WIN, &tree, &ctx, &TestLabelCtx.resolve));
    defer clearActiveContext(WIN);

    try testing.expectEqual(@as(c_int, 2), zenit_a11y_root_count(WIN));
    const first = zenit_a11y_root_at(WIN, 0);
    const second = zenit_a11y_root_at(WIN, 1);
    try testing.expect(first == r1.raw() or first == r2.raw());
    try testing.expect(second == r1.raw() or second == r2.raw());
    try testing.expect(first != second);
}

test "macos_bridge: raw handle zero is valid and exposure order is semantic" {
    clearAllActiveContexts();
    defer clearAllActiveContexts();

    var tree = AccessibilityTree.init(testing.allocator);
    defer tree.deinit();
    var ctx = TestLabelCtx{ .map = std.AutoHashMap(u64, []const u8).init(testing.allocator) };
    defer ctx.map.deinit();

    const zero = AXId.node(.{ .index = 0, .generation = 0 });
    const early = AXId.node(.{ .index = 3, .generation = 0 });
    const hidden = AXId.node(.{ .index = 4, .generation = 0 });
    try tree.upsert(.{ .element = zero, .role = .button, .sibling_index = 20 });
    try tree.upsert(.{ .element = early, .role = .checkbox, .sibling_index = 2 });
    try tree.upsert(.{ .element = hidden, .role = .link, .sibling_index = 1, .state = .{ .hidden = true } });
    try testing.expectEqual(@as(u32, 0), zero.raw());
    try testing.expect(setActiveContext(WIN, &tree, &ctx, &TestLabelCtx.resolve));

    try testing.expectEqual(@as(c_int, 2), zenit_a11y_root_count(WIN));
    try testing.expectEqual(early.raw(), zenit_a11y_root_at(WIN, 0));
    try testing.expectEqual(zero.raw(), zenit_a11y_root_at(WIN, 1));
    try testing.expectEqual(INVALID_HANDLE, zenit_a11y_root_at(WIN, 2));
    try testing.expectEqual(@as(c_int, @backingInt(tree_mod.Role.button)), zenit_a11y_role(WIN, 0));
}

test "macos_bridge: children_count / children_at" {
    var tree = AccessibilityTree.init(testing.allocator);
    defer tree.deinit();
    var ctx = TestLabelCtx{ .map = std.AutoHashMap(u64, []const u8).init(testing.allocator) };
    defer ctx.map.deinit();

    const parent = AXId.node(.{ .index = 1, .generation = 0 });
    const c1 = AXId.node(.{ .index = 2, .generation = 0 });
    const c2 = AXId.node(.{ .index = 3, .generation = 0 });
    try tree.upsert(.{ .element = parent, .role = .group });
    try tree.upsert(.{ .element = c1, .parent = parent, .role = .button, .sibling_index = 0 });
    try tree.upsert(.{ .element = c2, .parent = parent, .role = .button, .sibling_index = 1 });

    try testing.expect(setActiveContext(WIN, &tree, &ctx, &TestLabelCtx.resolve));
    defer clearActiveContext(WIN);

    try testing.expectEqual(@as(c_int, 2), zenit_a11y_children_count(WIN, parent.raw()));
    const got1 = zenit_a11y_children_at(WIN, parent.raw(), 0);
    const got2 = zenit_a11y_children_at(WIN, parent.raw(), 1);
    try testing.expect(got1 == c1.raw() or got1 == c2.raw());
    try testing.expect(got2 == c1.raw() or got2 == c2.raw());
    try testing.expect(got1 != got2);
}

test "macos_bridge: role + state" {
    var tree = AccessibilityTree.init(testing.allocator);
    defer tree.deinit();
    var ctx = TestLabelCtx{ .map = std.AutoHashMap(u64, []const u8).init(testing.allocator) };
    defer ctx.map.deinit();

    const id = AXId.node(.{ .index = 1, .generation = 0 });
    try tree.upsert(.{
        .element = id,
        .role = .checkbox,
        .state = .{ .checked = true, .focusable = true },
    });

    try testing.expect(setActiveContext(WIN, &tree, &ctx, &TestLabelCtx.resolve));
    defer clearActiveContext(WIN);

    try testing.expectEqual(@as(c_int, @backingInt(tree_mod.Role.checkbox)), zenit_a11y_role(WIN, id.raw()));
    const state_bits: tree_mod.State = @bitCast(zenit_a11y_state(WIN, id.raw()));
    try testing.expect(state_bits.checked);
    try testing.expect(state_bits.focusable);
}

test "macos_bridge: frame is element-local snapshot and stale handles fail closed" {
    var tree = AccessibilityTree.init(testing.allocator);
    defer tree.deinit();
    var labels = TestLabelCtx{ .map = std.AutoHashMap(u64, []const u8).init(testing.allocator) };
    defer labels.map.deinit();

    const id = AXId.node(.{ .index = 5, .generation = 2 });
    try tree.upsert(.{ .element = id, .role = .button, .frame = .{ .x = 12.5, .y = 31, .width = 88, .height = 24 } });
    try testing.expect(setActiveContext(WIN, &tree, &labels, &TestLabelCtx.resolve));
    defer clearActiveContext(WIN);

    var x: f32 = 0;
    var y: f32 = 0;
    var width: f32 = 0;
    var height: f32 = 0;
    try testing.expectEqual(@as(c_int, 1), zenit_a11y_frame(WIN, id.raw(), &x, &y, &width, &height));
    try testing.expectEqual(@as(f32, 12.5), x);
    try testing.expectEqual(@as(f32, 31), y);
    try testing.expectEqual(@as(f32, 88), width);
    try testing.expectEqual(@as(f32, 24), height);
    const stale = AXId.node(.{ .index = 5, .generation = 3 });
    try testing.expectEqual(@as(c_int, 0), zenit_a11y_frame(WIN, stale.raw(), &x, &y, &width, &height));
}

const TestInteractionCtx = struct {
    action_count: usize = 0,
    last_action: ?Action = null,
    selection_count: usize = 0,
    selection_start: u32 = 0,
    selection_end: u32 = 0,
    focus_count: usize = 0,
    last_focused: ?bool = null,
    text_value_count: usize = 0,
    text_value_len: usize = 0,
    numeric_count: usize = 0,
    numeric_value: f32 = 0,

    fn action(ctx: *anyopaque, _: AXId, requested: Action) bool {
        const self: *TestInteractionCtx = @ptrCast(@alignCast(ctx));
        self.action_count += 1;
        self.last_action = requested;
        return true;
    }

    fn selection(ctx: *anyopaque, _: AXId, start: u32, end: u32) bool {
        const self: *TestInteractionCtx = @ptrCast(@alignCast(ctx));
        self.selection_count += 1;
        self.selection_start = start;
        self.selection_end = end;
        return true;
    }

    fn focus(ctx: *anyopaque, _: AXId, focused: bool) bool {
        const self: *TestInteractionCtx = @ptrCast(@alignCast(ctx));
        self.focus_count += 1;
        self.last_focused = focused;
        return true;
    }

    fn textValue(ctx: *anyopaque, _: AXId, value: []const u8) bool {
        const self: *TestInteractionCtx = @ptrCast(@alignCast(ctx));
        self.text_value_count += 1;
        self.text_value_len = value.len;
        return true;
    }

    fn numericValue(ctx: *anyopaque, _: AXId, value: f32) bool {
        const self: *TestInteractionCtx = @ptrCast(@alignCast(ctx));
        self.numeric_count += 1;
        self.numeric_value = value;
        return true;
    }

    fn textFrame(_: *anyopaque, _: AXId, start: u32, end: u32, out: *tree_mod.Frame) bool {
        out.* = .{ .x = @floatFromInt(start), .y = 8, .width = @floatFromInt(end - start), .height = 16 };
        return true;
    }

    fn rangeAtPoint(_: *anyopaque, _: AXId, _: f32, _: f32, start: *u32, end: *u32) bool {
        start.* = 2;
        end.* = 6;
        return true;
    }
};

test "macos_bridge: actions and editable text require a live per-window route" {
    clearAllActiveContexts();
    defer clearAllActiveContexts();

    const WIN_A: u32 = 31;
    const WIN_B: u32 = 32;
    const id = AXId.node(.{ .index = 1, .generation = 4 });
    var tree_a = AccessibilityTree.init(testing.allocator);
    defer tree_a.deinit();
    var tree_b = AccessibilityTree.init(testing.allocator);
    defer tree_b.deinit();
    const node: A11yNode = .{
        .element = id,
        .role = .slider,
        .value_now = 42,
        .value_min = 10,
        .value_max = 90,
        .numeric_value_present = true,
        .actions = .{ .increment = true, .decrement = true },
        .editable_text = .{ .selection_start = 2, .selection_end = 5, .caret = 5, .can_set_selection = true },
    };
    try tree_a.upsert(node);
    try tree_b.upsert(node);

    var labels_a = TestLabelCtx{ .map = std.AutoHashMap(u64, []const u8).init(testing.allocator) };
    defer labels_a.map.deinit();
    var labels_b = TestLabelCtx{ .map = std.AutoHashMap(u64, []const u8).init(testing.allocator) };
    defer labels_b.map.deinit();
    var interactions_a = TestInteractionCtx{};

    try testing.expect(setActiveContextWithInteractions(
        WIN_A,
        &tree_a,
        &labels_a,
        &TestLabelCtx.resolve,
        &interactions_a,
        &TestInteractionCtx.action,
        &TestInteractionCtx.selection,
    ));
    // B intentionally has no route despite having identical handles/capability
    // snapshots; it must not call A or advertise a writable protocol.
    try testing.expect(setActiveContext(WIN_B, &tree_b, &labels_b, &TestLabelCtx.resolve));

    try testing.expectEqual(@as(u8, 0b1100), zenit_a11y_actions(WIN_A, id.raw()));
    try testing.expectEqual(@as(u8, 0), zenit_a11y_actions(WIN_B, id.raw()));
    try testing.expectEqual(@as(c_int, 1), zenit_a11y_perform_action(WIN_A, id.raw(), @backingInt(Action.increment)));
    try testing.expectEqual(@as(c_int, 0), zenit_a11y_perform_action(WIN_B, id.raw(), @backingInt(Action.increment)));
    try testing.expectEqual(@as(usize, 1), interactions_a.action_count);
    try testing.expectEqual(Action.increment, interactions_a.last_action.?);
    var now: f32 = 0;
    var min: f32 = 0;
    var max: f32 = 0;
    try testing.expectEqual(@as(c_int, 1), zenit_a11y_numeric_value(WIN_A, id.raw(), &now, &min, &max));
    try testing.expectEqual(@as(f32, 42), now);
    try testing.expectEqual(@as(f32, 10), min);
    try testing.expectEqual(@as(f32, 90), max);
    try testing.expectEqual(@as(u8, 0b01), zenit_a11y_numeric_capabilities(WIN_A, id.raw()));
    try testing.expectEqual(@as(u8, 0b01), zenit_a11y_numeric_capabilities(WIN_B, id.raw()));

    var start: u32 = 0;
    var end: u32 = 0;
    var caret: u32 = 0;
    try testing.expectEqual(@as(c_int, 1), zenit_a11y_text_selection(WIN_A, id.raw(), &start, &end, &caret));
    try testing.expectEqual(@as(u8, 0b11), zenit_a11y_text_capabilities(WIN_A, id.raw()));
    try testing.expectEqual(@as(u8, 0b01), zenit_a11y_text_capabilities(WIN_B, id.raw()));
    try testing.expectEqual(@as(u32, 2), start);
    try testing.expectEqual(@as(u32, 5), end);
    try testing.expectEqual(@as(u32, 5), caret);
    try testing.expectEqual(@as(c_int, 1), zenit_a11y_set_text_selection(WIN_A, id.raw(), 7, 9));
    try testing.expectEqual(@as(c_int, 0), zenit_a11y_set_text_selection(WIN_B, id.raw(), 7, 9));
    try testing.expectEqual(@as(usize, 1), interactions_a.selection_count);
    try testing.expectEqual(@as(u32, 7), interactions_a.selection_start);
    try testing.expectEqual(@as(u32, 9), interactions_a.selection_end);
}

test "macos_bridge: full text numeric focus and geometry contracts stay per-window" {
    clearAllActiveContexts();
    defer clearAllActiveContexts();

    const WIN_A: u32 = 41;
    const WIN_B: u32 = 42;
    const id = AXId.node(.{ .index = 0, .generation = 0 });
    const node: A11yNode = .{
        .element = id,
        .role = .slider,
        .state = .{ .focused = true, .focusable = true },
        .numeric_value_present = true,
        .can_set_numeric_value = true,
        .value_now = 3,
        .value_min = 0,
        .value_max = 5,
        .editable_text = .{
            .selection_start = 1,
            .selection_end = 1,
            .caret = 1,
            .visible_start = 1,
            .visible_end = 7,
            .can_set_selection = true,
            .can_set_value = true,
        },
    };
    var tree_a = AccessibilityTree.init(testing.allocator);
    defer tree_a.deinit();
    var tree_b = AccessibilityTree.init(testing.allocator);
    defer tree_b.deinit();
    try tree_a.upsert(node);
    try tree_b.upsert(node);
    var labels_a = TestLabelCtx{ .map = std.AutoHashMap(u64, []const u8).init(testing.allocator) };
    defer labels_a.map.deinit();
    var labels_b = TestLabelCtx{ .map = std.AutoHashMap(u64, []const u8).init(testing.allocator) };
    defer labels_b.map.deinit();
    var interactions = TestInteractionCtx{};

    try testing.expect(setActiveContextWithFullInteractions(
        WIN_A,
        &tree_a,
        &labels_a,
        &TestLabelCtx.resolve,
        &interactions,
        &TestInteractionCtx.action,
        &TestInteractionCtx.selection,
        &TestInteractionCtx.focus,
        &TestInteractionCtx.textValue,
        &TestInteractionCtx.numericValue,
        &TestInteractionCtx.textFrame,
        &TestInteractionCtx.rangeAtPoint,
    ));
    try testing.expect(setActiveContext(WIN_B, &tree_b, &labels_b, &TestLabelCtx.resolve));

    try testing.expectEqual(@as(u8, 0b1111), zenit_a11y_text_capabilities(WIN_A, id.raw()));
    try testing.expectEqual(@as(u8, 0b0001), zenit_a11y_text_capabilities(WIN_B, id.raw()));
    try testing.expectEqual(@as(u8, 0b11), zenit_a11y_numeric_capabilities(WIN_A, id.raw()));
    try testing.expectEqual(@as(u8, 0b01), zenit_a11y_numeric_capabilities(WIN_B, id.raw()));

    var visible_start: u32 = 0;
    var visible_end: u32 = 0;
    try testing.expectEqual(@as(c_int, 1), zenit_a11y_text_visible_range(WIN_A, id.raw(), &visible_start, &visible_end));
    try testing.expectEqual(@as(u32, 1), visible_start);
    try testing.expectEqual(@as(u32, 7), visible_end);
    try testing.expectEqual(@as(c_int, 1), zenit_a11y_set_text_value(WIN_A, id.raw(), "hello".ptr, 5));
    try testing.expectEqual(@as(c_int, 0), zenit_a11y_set_text_value(WIN_B, id.raw(), "wrong".ptr, 5));
    try testing.expectEqual(@as(usize, 1), interactions.text_value_count);
    try testing.expectEqual(@as(usize, 5), interactions.text_value_len);

    try testing.expectEqual(@as(c_int, 1), zenit_a11y_set_numeric_value(WIN_A, id.raw(), 99));
    try testing.expectEqual(@as(f32, 5), interactions.numeric_value);
    try testing.expectEqual(@as(c_int, 0), zenit_a11y_set_numeric_value(WIN_B, id.raw(), 4));

    var x: f32 = 0;
    var y: f32 = 0;
    var width: f32 = 0;
    var height: f32 = 0;
    try testing.expectEqual(@as(c_int, 1), zenit_a11y_text_frame(WIN_A, id.raw(), 2, 6, &x, &y, &width, &height));
    try testing.expectEqual(@as(f32, 2), x);
    try testing.expectEqual(@as(f32, 4), width);
    var point_start: u32 = 0;
    var point_end: u32 = 0;
    try testing.expectEqual(@as(c_int, 1), zenit_a11y_text_range_at_point(WIN_A, id.raw(), 10, 12, &point_start, &point_end));
    try testing.expectEqual(@as(u32, 2), point_start);
    try testing.expectEqual(@as(u32, 6), point_end);

    var readonly_node = node;
    readonly_node.state.readonly = true;
    try tree_a.upsert(readonly_node);
    try testing.expectEqual(@as(u8, 0b1011), zenit_a11y_text_capabilities(WIN_A, id.raw()));
    try testing.expectEqual(@as(c_int, 1), zenit_a11y_set_text_selection(WIN_A, id.raw(), 0, 3));
    try testing.expectEqual(@as(c_int, 0), zenit_a11y_set_text_value(WIN_A, id.raw(), "changed".ptr, 7));
    readonly_node.state.disabled = true;
    try tree_a.upsert(readonly_node);
    try testing.expectEqual(@as(u8, 0b1001), zenit_a11y_text_capabilities(WIN_A, id.raw()));
    try testing.expectEqual(@as(c_int, 0), zenit_a11y_set_text_selection(WIN_A, id.raw(), 0, 3));
    try tree_a.upsert(node);

    try testing.expectEqual(id.raw(), zenit_a11y_focused(WIN_A));
    try testing.expectEqual(@as(c_int, 1), zenit_a11y_set_focus(WIN_A, id.raw(), 0));
    try testing.expectEqual(false, interactions.last_focused.?);
    try testing.expectEqual(@as(c_int, 0), zenit_a11y_set_focus(WIN_B, id.raw(), 0));
}

test "macos_bridge: parent active descendant and deepest hit test are exact" {
    clearAllActiveContexts();
    defer clearAllActiveContexts();

    var tree = AccessibilityTree.init(testing.allocator);
    defer tree.deinit();
    var labels = TestLabelCtx{ .map = std.AutoHashMap(u64, []const u8).init(testing.allocator) };
    defer labels.map.deinit();
    const root = AXId.node(.{ .index = 0, .generation = 0 });
    const child = AXId.node(.{ .index = 1, .generation = 0 });
    const active = AXId.node(.{ .index = 2, .generation = 0 });
    try tree.upsert(.{
        .element = root,
        .role = .listbox,
        .active_descendant = active,
        .frame = .{ .x = 0, .y = 0, .width = 100, .height = 100 },
    });
    try tree.upsert(.{
        .element = child,
        .parent = root,
        .role = .group,
        .frame = .{ .x = 10, .y = 10, .width = 80, .height = 80 },
    });
    try tree.upsert(.{
        .element = active,
        .parent = child,
        .role = .listitem,
        .state = .{ .selected = true },
        .frame = .{ .x = 20, .y = 20, .width = 20, .height = 20 },
    });
    try testing.expect(setActiveContext(WIN, &tree, &labels, &TestLabelCtx.resolve));

    try testing.expectEqual(root.raw(), zenit_a11y_parent(WIN, child.raw()));
    try testing.expectEqual(child.raw(), zenit_a11y_parent(WIN, active.raw()));
    try testing.expectEqual(active.raw(), zenit_a11y_active_descendant(WIN, root.raw()));
    try testing.expectEqual(active.raw(), zenit_a11y_hit_test(WIN, 25, 25));
    try testing.expectEqual(child.raw(), zenit_a11y_hit_test(WIN, 50, 50));
    try testing.expectEqual(INVALID_HANDLE, zenit_a11y_hit_test(WIN, 150, 150));
}

test "macos_bridge: label resolve + probe length" {
    var tree = AccessibilityTree.init(testing.allocator);
    defer tree.deinit();
    var ctx = TestLabelCtx{ .map = std.AutoHashMap(u64, []const u8).init(testing.allocator) };
    defer ctx.map.deinit();

    const id = AXId.node(.{ .index = 1, .generation = 0 });
    const label = "Click Me";
    const label_hash: u64 = std.hash.Wyhash.hash(0, label);
    try ctx.map.put(label_hash, label);

    try tree.upsert(.{ .element = id, .role = .button, .label_hash = label_hash });

    try testing.expect(setActiveContext(WIN, &tree, &ctx, &TestLabelCtx.resolve));
    defer clearActiveContext(WIN);

    // probe: buf=null returns actual length
    try testing.expectEqual(@as(c_int, @intCast(label.len)), zenit_a11y_label(WIN, id.raw(), null, 0));

    // copy: write to buf
    var buf: [32]u8 = undefined;
    const n = zenit_a11y_label(WIN, id.raw(), &buf, buf.len);
    try testing.expectEqual(@as(c_int, @intCast(label.len)), n);
    try testing.expectEqualStrings(label, buf[0..@intCast(n)]);
}

test "macos_bridge: no active context returns zero" {
    clearAllActiveContexts();
    try testing.expectEqual(@as(c_int, 0), zenit_a11y_root_count(WIN));
    try testing.expectEqual(INVALID_HANDLE, zenit_a11y_root_at(WIN, 0));
    try testing.expectEqual(@as(c_int, 0), zenit_a11y_children_count(WIN, 0));
}

// Multi-window routing acceptance core: two windows register separate trees, query each by
// window_id get each's content,
// unregister one doesn't affect the other. Pass this before modifying this file.
test "macos_bridge: two windows route independently" {
    clearAllActiveContexts();
    defer clearAllActiveContexts();

    const WIN_A: u32 = 11;
    const WIN_B: u32 = 22;

    var tree_a = AccessibilityTree.init(testing.allocator);
    defer tree_a.deinit();
    var tree_b = AccessibilityTree.init(testing.allocator);
    defer tree_b.deinit();

    var ctx_a = TestLabelCtx{ .map = std.AutoHashMap(u64, []const u8).init(testing.allocator) };
    defer ctx_a.map.deinit();
    var ctx_b = TestLabelCtx{ .map = std.AutoHashMap(u64, []const u8).init(testing.allocator) };
    defer ctx_b.map.deinit();

    // A: 1 root, label Alpha. B: 2 roots, first label Bravo.
    const a_root = AXId.node(.{ .index = 1, .generation = 0 });
    const label_a = "Alpha";
    const hash_a = std.hash.Wyhash.hash(0, label_a);
    try ctx_a.map.put(hash_a, label_a);
    try tree_a.upsert(.{ .element = a_root, .role = .button, .label_hash = hash_a });

    const b_root1 = AXId.node(.{ .index = 1, .generation = 0 });
    const b_root2 = AXId.node(.{ .index = 2, .generation = 0 });
    const label_b = "Bravo";
    const hash_b = std.hash.Wyhash.hash(0, label_b);
    try ctx_b.map.put(hash_b, label_b);
    try tree_b.upsert(.{ .element = b_root1, .role = .checkbox, .label_hash = hash_b });
    try tree_b.upsert(.{ .element = b_root2, .role = .textbox });

    try testing.expect(setActiveContext(WIN_A, &tree_a, &ctx_a, &TestLabelCtx.resolve));
    try testing.expect(setActiveContext(WIN_B, &tree_b, &ctx_b, &TestLabelCtx.resolve));
    try testing.expectEqual(@as(usize, 2), activeContextCount());

    // Each queries own root count, old single-slot impl B overwrites A, here A becomes 2.
    try testing.expectEqual(@as(c_int, 1), zenit_a11y_root_count(WIN_A));
    try testing.expectEqual(@as(c_int, 2), zenit_a11y_root_count(WIN_B));

    // Same raw handle value in two windows points to different nodes, role must resolve per-window.
    try testing.expectEqual(
        @as(c_int, @backingInt(tree_mod.Role.button)),
        zenit_a11y_role(WIN_A, a_root.raw()),
    );
    try testing.expectEqual(
        @as(c_int, @backingInt(tree_mod.Role.checkbox)),
        zenit_a11y_role(WIN_B, b_root1.raw()),
    );

    // label uses each own label_ctx (different hash table).
    var buf: [32]u8 = undefined;
    const na = zenit_a11y_label(WIN_A, a_root.raw(), &buf, buf.len);
    try testing.expectEqualStrings(label_a, buf[0..@intCast(na)]);
    const nb = zenit_a11y_label(WIN_B, b_root1.raw(), &buf, buf.len);
    try testing.expectEqualStrings(label_b, buf[0..@intCast(nb)]);
    // A's hash doesn't find in B's table, proves label_ctx not crossed.
    try testing.expectEqual(@as(c_int, 0), zenit_a11y_label(WIN_B, b_root2.raw(), &buf, buf.len));

    // Unregister A doesn't affect B.
    clearActiveContext(WIN_A);
    try testing.expectEqual(@as(usize, 1), activeContextCount());
    try testing.expectEqual(@as(c_int, 0), zenit_a11y_root_count(WIN_A));
    try testing.expectEqual(@as(c_int, 2), zenit_a11y_root_count(WIN_B));
}

test "macos_bridge: ANY_WINDOW falls back to first registered window" {
    clearAllActiveContexts();
    defer clearAllActiveContexts();

    var tree = AccessibilityTree.init(testing.allocator);
    defer tree.deinit();
    var ctx = TestLabelCtx{ .map = std.AutoHashMap(u64, []const u8).init(testing.allocator) };
    defer ctx.map.deinit();
    try tree.upsert(.{ .element = AXId.node(.{ .index = 1, .generation = 0 }), .role = .button });

    try testing.expect(setActiveContext(99, &tree, &ctx, &TestLabelCtx.resolve));
    // Unlinked ObjC proxy pass 0 still gets tree (old single-window behavior compat).
    try testing.expectEqual(@as(c_int, 1), zenit_a11y_root_count(ANY_WINDOW));
    // But wrong window_id doesn't find, wildcard != "any id hits".
    try testing.expectEqual(@as(c_int, 0), zenit_a11y_root_count(98));
}

test "macos_bridge: table full degrades instead of erroring" {
    clearAllActiveContexts();
    defer clearAllActiveContexts();

    var tree = AccessibilityTree.init(testing.allocator);
    defer tree.deinit();
    var ctx = TestLabelCtx{ .map = std.AutoHashMap(u64, []const u8).init(testing.allocator) };
    defer ctx.map.deinit();

    for (0..MAX_WINDOWS) |i| {
        try testing.expect(setActiveContext(@intCast(i + 1), &tree, &ctx, &TestLabelCtx.resolve));
    }
    // MAX_WINDOWS+1 register fails but no panic / no error.
    try testing.expect(!setActiveContext(9999, &tree, &ctx, &TestLabelCtx.resolve));
    // Already registered works normally.
    try testing.expectEqual(@as(c_int, 0), zenit_a11y_root_count(9999));
}

const PushTestState = struct {
    property_count: usize = 0,
    property_window: u32 = 0,
    property_handle: u64 = INVALID_HANDLE,
    property_flags: u16 = 0,
    focus_count: usize = 0,
    focus_handle: u64 = INVALID_HANDLE,
    announce_count: usize = 0,
    announce_priority: u8 = 0,
    clear_count: usize = 0,
    cleared_window: u32 = 0,
};

var g_push_test = PushTestState{};

fn testPushProperty(window_id: u32, handle: u64, flags: u16) callconv(.c) c_int {
    g_push_test.property_count += 1;
    g_push_test.property_window = window_id;
    g_push_test.property_handle = handle;
    g_push_test.property_flags = flags;
    return 1;
}

fn testPushFocus(_: u32, handle: u64) callconv(.c) c_int {
    g_push_test.focus_count += 1;
    g_push_test.focus_handle = handle;
    return 1;
}

fn testPushAnnounce(_: u32, _: [*]const u8, _: c_int, priority: u8) callconv(.c) c_int {
    g_push_test.announce_count += 1;
    g_push_test.announce_priority = priority;
    return 1;
}

fn testPushWindowCleared(window_id: u32) callconv(.c) c_int {
    g_push_test.clear_count += 1;
    g_push_test.cleared_window = window_id;
    return 1;
}

test "macos_bridge: retained push preserves exact target flags priority and focus clear" {
    clearAllActiveContexts();
    defer clearAllActiveContexts();
    g_push_test = .{};
    setPushHooks(.{
        .property_changed = testPushProperty,
        .focus_changed = testPushFocus,
        .announce = testPushAnnounce,
    });
    defer setPushHooks(.{});

    var tree = AccessibilityTree.init(testing.allocator);
    defer tree.deinit();
    var labels = TestLabelCtx{ .map = std.AutoHashMap(u64, []const u8).init(testing.allocator) };
    defer labels.map.deinit();
    const text = "Danger";
    const hash = std.hash.Wyhash.hash(0, text);
    try labels.map.put(hash, text);
    const id = AXId.node(.{ .index = 0, .generation = 0 });
    var ref = PushCxRef{ .window_id = 77, .label_ctx = &labels, .label_resolver = &TestLabelCtx.resolve };
    try tree.upsert(.{
        .element = id,
        .role = .alert,
        .live = .assertive,
        .text_hash = hash,
        .state = .{ .focused = true, .focusable = true },
    });
    router_mod.flushToBridge(&tree, pushBridge(&ref));
    try testing.expectEqual(@as(usize, 1), g_push_test.announce_count);
    try testing.expectEqual(@as(u8, @backingInt(tree_mod.LiveRegion.assertive)), g_push_test.announce_priority);
    try testing.expectEqual(@as(usize, 1), g_push_test.focus_count);
    try testing.expectEqual(id.raw(), g_push_test.focus_handle);

    try tree.upsert(.{
        .element = id,
        .role = .status,
        .live = .assertive,
        .text_hash = hash,
        .frame = .{ .x = 5, .y = 6, .width = 7, .height = 8 },
    });
    router_mod.flushToBridge(&tree, pushBridge(&ref));
    try testing.expectEqual(@as(usize, 1), g_push_test.property_count);
    try testing.expectEqual(@as(u32, 77), g_push_test.property_window);
    try testing.expectEqual(id.raw(), g_push_test.property_handle);
    const flags: tree_mod.A11yDirtyFlag = @bitCast(g_push_test.property_flags);
    try testing.expect(flags.role_changed);
    try testing.expect(flags.geometry_changed);
    try testing.expectEqual(@as(usize, 2), g_push_test.focus_count);
    try testing.expectEqual(INVALID_HANDLE, g_push_test.focus_handle);
}

test "macos_bridge: clearing one window emits one teardown and preserves peers" {
    clearAllActiveContexts();
    defer clearAllActiveContexts();
    g_push_test = .{};
    setPushHooks(.{ .window_cleared = testPushWindowCleared });
    defer setPushHooks(.{});

    var tree_a = AccessibilityTree.init(testing.allocator);
    defer tree_a.deinit();
    var tree_b = AccessibilityTree.init(testing.allocator);
    defer tree_b.deinit();
    var labels = TestLabelCtx{ .map = std.AutoHashMap(u64, []const u8).init(testing.allocator) };
    defer labels.map.deinit();
    try tree_a.upsert(.{ .element = AXId.node(.{ .index = 0, .generation = 0 }), .role = .button });
    try tree_b.upsert(.{ .element = AXId.node(.{ .index = 0, .generation = 0 }), .role = .checkbox });
    try testing.expect(setActiveContext(81, &tree_a, &labels, &TestLabelCtx.resolve));
    try testing.expect(setActiveContext(82, &tree_b, &labels, &TestLabelCtx.resolve));

    clearActiveContext(81);
    try testing.expectEqual(@as(usize, 1), g_push_test.clear_count);
    try testing.expectEqual(@as(u32, 81), g_push_test.cleared_window);
    try testing.expectEqual(@as(c_int, 0), zenit_a11y_root_count(81));
    try testing.expectEqual(@as(c_int, 1), zenit_a11y_root_count(82));
    clearActiveContext(81);
    try testing.expectEqual(@as(usize, 1), g_push_test.clear_count);
}

const LiveTextTestState = struct {
    text: []const u8,
    marked: ?struct { start: u32, end: u32 } = null,
    secure: bool = false,
    selection: core_types.TextInputSelection = .{ .start = 0, .end = 0, .caret = 0 },

    fn length(context: *anyopaque) usize {
        const self: *@This() = @ptrCast(@alignCast(context));
        return self.text.len;
    }

    fn copy(context: *anyopaque, start: usize, out: []u8) usize {
        const self: *@This() = @ptrCast(@alignCast(context));
        if (start >= self.text.len) return 0;
        const count = @min(out.len, self.text.len - start);
        @memcpy(out[0..count], self.text[start..][0..count]);
        return count;
    }

    fn readSelection(context: *anyopaque) core_types.TextInputSelection {
        const self: *@This() = @ptrCast(@alignCast(context));
        return self.selection;
    }

    fn readMarked(context: *anyopaque, start: *u32, end: *u32) bool {
        const self: *@This() = @ptrCast(@alignCast(context));
        const range = self.marked orelse return false;
        start.* = range.start;
        end.* = range.end;
        return true;
    }

    fn resolve(context: *anyopaque) ?core_types.TextInputClient {
        return .{
            .context = context,
            .text_len = length,
            .copy_text = copy,
            .selection = readSelection,
            .marked_range = readMarked,
            .secure = (@as(*@This(), @ptrCast(@alignCast(context)))).secure,
        };
    }
};

test "macos_bridge: live text client maps CJK and non-BMP UTF-8 UTF-16 ranges" {
    clearAllActiveContexts();
    defer clearAllActiveContexts();

    const TEXT_WINDOW: u32 = 901;
    var state = LiveTextTestState{
        .text = "A中🙂한",
        .selection = .{ .start = 1, .end = 8, .caret = 8 },
    };
    try testing.expect(setTextInputResolver(TEXT_WINDOW, &state, LiveTextTestState.resolve));

    try testing.expectEqual(@as(u64, 11), zenit_text_input_length(TEXT_WINDOW));
    try testing.expectEqual(@as(u64, 0), zenit_text_input_utf16_for_utf8(TEXT_WINDOW, 0));
    try testing.expectEqual(@as(u64, 1), zenit_text_input_utf16_for_utf8(TEXT_WINDOW, 1));
    // A request inside the CJK character (U+4E2D) clamps to scalar start rather than failing.
    try testing.expectEqual(@as(u64, 1), zenit_text_input_utf16_for_utf8(TEXT_WINDOW, 2));
    try testing.expectEqual(@as(u64, 2), zenit_text_input_utf16_for_utf8(TEXT_WINDOW, 4));
    try testing.expectEqual(@as(u64, 2), zenit_text_input_utf16_for_utf8(TEXT_WINDOW, 5));
    try testing.expectEqual(@as(u64, 4), zenit_text_input_utf16_for_utf8(TEXT_WINDOW, 8));
    try testing.expectEqual(@as(u64, 5), zenit_text_input_utf16_for_utf8(TEXT_WINDOW, 11));

    try testing.expectEqual(@as(u64, 0), zenit_text_input_utf8_for_utf16(TEXT_WINDOW, 0));
    try testing.expectEqual(@as(u64, 1), zenit_text_input_utf8_for_utf16(TEXT_WINDOW, 1));
    try testing.expectEqual(@as(u64, 4), zenit_text_input_utf8_for_utf16(TEXT_WINDOW, 2));
    // A UTF-16 offset between 🙂's surrogate pair clamps to its UTF-8 start.
    try testing.expectEqual(@as(u64, 4), zenit_text_input_utf8_for_utf16(TEXT_WINDOW, 3));
    try testing.expectEqual(@as(u64, 8), zenit_text_input_utf8_for_utf16(TEXT_WINDOW, 4));
    try testing.expectEqual(@as(u64, 11), zenit_text_input_utf8_for_utf16(TEXT_WINDOW, 5));

    var start: u32 = 0;
    var end: u32 = 0;
    var caret: u32 = 0;
    try testing.expectEqual(@as(c_int, 1), zenit_text_input_selection(TEXT_WINDOW, &start, &end, &caret));
    try testing.expectEqual(@as(u32, 1), start);
    try testing.expectEqual(@as(u32, 8), end);
    try testing.expectEqual(@as(u32, 8), caret);

    var copied: [7]u8 = undefined;
    try testing.expectEqual(@as(c_int, 7), zenit_text_input_copy(TEXT_WINDOW, 4, &copied, copied.len));
    try testing.expectEqualStrings("🙂한", &copied);
}

test "macos_bridge: UTF conversion preserves scalars across bridge chunk boundaries" {
    clearAllActiveContexts();
    defer clearAllActiveContexts();

    var text: [4102]u8 = undefined;
    @memset(text[0..4095], 'a');
    @memcpy(text[4095..4098], "中");
    @memcpy(text[4098..4102], "🙂");
    var state = LiveTextTestState{ .text = &text };
    try testing.expect(setTextInputResolver(902, &state, LiveTextTestState.resolve));

    try testing.expectEqual(@as(u64, 4098), zenit_text_input_utf16_for_utf8(902, text.len));
    try testing.expectEqual(@as(u64, 4098), zenit_text_input_utf8_for_utf16(902, 4096));
    try testing.expectEqual(@as(u64, 4098), zenit_text_input_utf8_for_utf16(902, 4097));
    try testing.expectEqual(@as(u64, 4102), zenit_text_input_utf8_for_utf16(902, 4098));
}

test "macos_bridge: applied preedit publishes only a live nonsecure model range" {
    clearAllActiveContexts();
    defer clearAllActiveContexts();
    const Capture = struct {
        var calls: usize = 0;
        var received: [5]u64 = undefined;
        fn apply(window: u32, start16: u64, end16: u64, start8: u32, end8: u32) callconv(.c) c_int {
            calls += 1;
            received = .{ window, start16, end16, start8, end8 };
            return 1;
        }
    };
    Capture.calls = 0;
    setTextInputAppliedHook(Capture.apply);
    defer setTextInputAppliedHook(null);
    var state = LiveTextTestState{ .text = "A😀你好Z", .marked = .{ .start = 5, .end = 11 } };
    try testing.expect(setTextInputResolver(903, &state, LiveTextTestState.resolve));
    publishAppliedPreedit(903);
    try testing.expectEqual(@as(usize, 1), Capture.calls);
    try testing.expectEqual([5]u64{ 903, 3, 5, 5, 11 }, Capture.received);
    var boundary: [4102]u8 = undefined;
    @memset(boundary[0..4095], 'a');
    @memcpy(boundary[4095..4099], "🙂");
    @memcpy(boundary[4099..4102], "你");
    state.text = &boundary;
    state.marked = .{ .start = 4099, .end = 4102 };
    publishAppliedPreedit(903);
    try testing.expectEqual([5]u64{ 903, 4097, 4098, 4099, 4102 }, Capture.received);
    state.text = "A😀你好Z";
    state.secure = true;
    publishAppliedPreedit(903);
    state.secure = false;
    state.marked = .{ .start = 5, .end = 99 };
    publishAppliedPreedit(903);
    state.marked = .{ .start = 6, .end = 5 };
    publishAppliedPreedit(903);
    state.marked = null;
    publishAppliedPreedit(903);
    clearTextInputResolverForOwner(903, &state);
    publishAppliedPreedit(903);
    try testing.expectEqual(@as(usize, 2), Capture.calls);
}

test "macos_bridge: 虚拟化列表报逻辑总数与数据位置，而不是可见槽位" {
    clearAllActiveContexts();
    defer clearAllActiveContexts();
    var tree = AccessibilityTree.init(testing.allocator);
    defer tree.deinit();
    var ctx = TestLabelCtx{ .map = std.AutoHashMap(u64, []const u8).init(testing.allocator) };
    defer ctx.map.deinit();

    const list = AXId.node(.{ .index = 1, .generation = 0 });
    const visible_first = AXId.node(.{ .index = 2, .generation = 0 });
    const plain = AXId.node(.{ .index = 3, .generation = 0 });
    try tree.upsert(.{ .element = list, .role = .list, .set_size = 100_000 });
    // Visible first row is actually data row 5000 (pos_in_set counts from 1).
    try tree.upsert(.{ .element = visible_first, .parent = list, .role = .listitem, .sibling_index = 0, .pos_in_set = 5000 });
    // Row without declared pos_in_set falls back to visible sibling order.
    try tree.upsert(.{ .element = plain, .parent = list, .role = .listitem, .sibling_index = 1 });
    try testing.expect(setActiveContext(WIN, &tree, &ctx, &TestLabelCtx.resolve));

    try testing.expectEqual(@as(u32, 100_000), zenit_a11y_set_size(WIN, list.raw()));
    var index: u32 = 0;
    var span: u32 = 0;
    try testing.expectEqual(@as(c_int, 1), zenit_a11y_row_index_range(WIN, visible_first.raw(), &index, &span));
    try testing.expectEqual(@as(u32, 4999), index);
    try testing.expectEqual(@as(c_int, 1), zenit_a11y_row_index_range(WIN, plain.raw(), &index, &span));
    try testing.expectEqual(@as(u32, 1), index);
}
