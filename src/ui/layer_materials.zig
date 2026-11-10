//! Material ownership is indexed on topology changes. Only visible surfaces
//! take part in compositing; ordinary clipped cards retain a constant fill.
const std = @import("std");
const ui = @import("ui");
const theme = @import("app_theme.zig");
const geometry = @import("material_geometry.zig");
const Rect = ui.ComputedRect;
pub const CardRole = enum { overlay, surface_1, surface_2, well, action, control, settings_card, custom, global_notification };
pub fn card(node: *ui.Node, comptime role: CardRole) void {
    const name = "MaterialSurface." ++ @tagName(role);
    if (node.meta.ownership.meta.component_name) |old| if (std.mem.eql(u8, old, name)) return;
    node.meta.ownership.meta.component_name = name;
    node.invalidateTreeStructure();
}
/// A surface whose pixels can change independently of the application theme.
/// Floating text over it needs a readable backdrop even at high transparency.
pub fn variableBackdrop(node: *ui.Node) void {
    const name = "MaterialBackdrop.variable";
    if (node.meta.ownership.meta.component_name) |old| if (std.mem.eql(u8, old, name)) return;
    node.meta.ownership.meta.component_name = name;
    node.invalidateTreeStructure();
}
pub fn overlay(node: *ui.Node) void {
    // Backdrop isolation is also used by inline approval cards. Preserve their
    // declared tint and layer role instead of turning them into overlay chrome.
    if (node.meta.ownership.meta.component_name) |name| if (std.mem.startsWith(u8, name, "MaterialSurface.")) return;
    card(node, .overlay);
}
pub const Stats = struct {
    scene_rebuilds: usize = 0,
    geometry_builds: usize = 0,
    visible_surfaces: usize = 0,
};
const Entry = struct { node: *ui.Node, owner: ?*ui.Node, level: usize, portal_root: bool };
const Snapshot = geometry.Snapshot;
pub const Policy = struct {
    cx: *ui.Cx,
    entries: std.ArrayList(Entry) = .empty,
    variable_backdrops: std.ArrayList(*ui.Node) = .empty,
    scene_ids: std.AutoHashMapUnmanaged(u32, *ui.Node) = .empty,
    paints: std.ArrayList(*Compensation) = .empty,
    paint_ids: std.AutoHashMapUnmanaged(u32, *Compensation) = .empty,
    underlays: std.ArrayList(geometry.Shape) = .empty,
    candidates: std.ArrayList(geometry.Shape) = .empty,
    scene_revision: u64 = std.math.maxInt(u64),
    portal_revision: u64 = 0,
    scene_order: u64 = 0,
    scene_root: ?*ui.Node = null,
    scene_overlay: ui.Color = ui.Color.TRANSPARENT,
    layout_changed: bool = false,
    stats: Stats = .{},
    last_colors: ?theme.Colors = null,
    last_transparency: ?f32 = null,
    readability_cache: ?struct { overlay: ui.Color, fg_1: ui.Color, fg_2: ui.Color, alpha: u8 } = null,

    pub fn mount(cx: *ui.Cx, scope: *ui.Scope) !void {
        try @import("floating_input.zig").Policy.mount(cx, scope);
        const self = try scope.createState(Policy, .{ .cx = cx });
        try cx.addAfterLayoutHook(self, afterLayout);
        errdefer cx.removeAfterLayoutHook(self);
        try scope.onCleanup(Policy, self, cleanup);
    }
    fn cleanup(self: *Policy) void {
        self.cx.removeAfterLayoutHook(self);
        for (self.paints.items) |paint| paint.deinit(self.cx.allocator);
        self.paints.deinit(self.cx.allocator);
        self.paint_ids.deinit(self.cx.allocator);
        self.entries.deinit(self.cx.allocator);
        self.variable_backdrops.deinit(self.cx.allocator);
        self.scene_ids.deinit(self.cx.allocator);
        self.underlays.deinit(self.cx.allocator);
        self.candidates.deinit(self.cx.allocator);
    }
    fn afterLayout(raw: *anyopaque, _: u8, _: bool) ui.AfterLayoutResult {
        const self: *Policy = @ptrCast(@alignCast(raw));
        self.layout_changed = false;
        self.sync();
        return if (self.layout_changed) .needs_layout else .done;
    }
    fn marked(node: *ui.Node) bool {
        return if (node.meta.ownership.meta.component_name) |name| std.mem.startsWith(u8, name, "MaterialSurface.") else false;
    }
    fn fixedLevel(node: *ui.Node) ?usize {
        const name = node.meta.ownership.meta.component_name orelse return null;
        return if (std.mem.eql(u8, name, "MaterialSurface.global_notification")) 4 else null;
    }
    fn cardColor(node: *ui.Node) ui.Color {
        const name = node.meta.ownership.meta.component_name orelse return theme.baseColors().overlay;
        if (std.mem.eql(u8, name, "MaterialSurface.overlay")) return theme.baseColors().overlay;
        inline for (.{ "surface_1", "surface_2", "well" }) |role| if (std.mem.eql(u8, name, "MaterialSurface." ++ role)) return @field(theme.current(), role);
        if (std.mem.eql(u8, name, "MaterialSurface.settings_card")) return theme.settingsCard();
        if (std.mem.eql(u8, name, "MaterialSurface.action")) return theme.popupAction();
        if (std.mem.eql(u8, name, "MaterialSurface.control")) return theme.popupInset();
        return node.getBackground();
    }
    fn floating(node: *ui.Node) bool {
        const glass = node.style.glass_params() orelse return false;
        // Surface identity must survive a missed palette publication. Canvas
        // capture/blur nodes are image processing, not floating UI surfaces.
        return !glass.capture_current_target and !glass.a11y_exempt;
    }
    fn portal(self: *Policy, node: *ui.Node) bool {
        for (self.cx.overlay_stack.layers) |slot| if (slot) |layer| if (layer.content_node == node) return true;
        return false;
    }
    fn portalKey(self: *Policy) u64 {
        var hash = std.hash.Wyhash.init(0);
        for (self.cx.overlay_stack.layers) |slot| if (slot) |layer| {
            std.hash.autoHash(&hash, .{ layer.handle.id, layer.suspended, if (layer.content_node) |n| n.id else @as(u32, 0), layer.trigger_handle, layer.previous_focus, if (layer.content_node) |n| n.style.z_index() else @as(i32, 0) });
        };
        return hash.final();
    }
    fn orderKey(self: *Policy) u64 {
        var hash = std.hash.Wyhash.init(0);
        for (self.entries.items) |entry| {
            var cursor: ?*ui.Node = entry.node;
            while (cursor) |node| : (cursor = node.parent) std.hash.autoHash(&hash, node.style.z_index());
        }
        return hash.final();
    }
    fn collect(self: *Policy, node: *ui.Node, depth: usize, owner: ?*ui.Node, portal_root: bool) !void {
        if (node.meta.ownership.meta.test_id) |id| if (std.mem.eql(u8, id, "appearance.background") or std.mem.eql(u8, id, "appearance.material.compensation")) return;
        if (!portal_root and self.portal(node)) return;
        if (std.mem.eql(u8, node.meta.ownership.meta.component_name orelse "", "MaterialBackdrop.variable"))
            try self.variable_backdrops.append(self.cx.allocator, node);
        const boundary = portal_root or marked(node) or floating(node);
        const level = fixedLevel(node) orelse depth + @as(usize, if (boundary and !portal_root) 1 else 0);
        if (boundary) {
            try self.entries.append(self.cx.allocator, .{ .node = node, .owner = owner, .level = level, .portal_root = portal_root });
            try self.scene_ids.put(self.cx.allocator, node.id, node);
        }
        var ordered = false;
        for (node.children.items) |child| if (child.style.z_index() > 0) {
            ordered = true;
            break;
        };
        if (!ordered) {
            for (node.children.items) |child| try self.collect(child, level, if (boundary) node else owner, false);
        } else {
            const Child = struct { node: *ui.Node, index: usize };
            const children = try self.cx.allocator.alloc(Child, node.children.items.len);
            defer self.cx.allocator.free(children);
            for (node.children.items, 0..) |child, index| children[index] = .{ .node = child, .index = index };
            std.mem.sort(Child, children, {}, struct {
                fn less(_: void, a: Child, b: Child) bool {
                    const az = @max(0, a.node.style.z_index());
                    const bz = @max(0, b.node.style.z_index());
                    return if (az == bz) a.index < b.index else az < bz;
                }
            }.less);
            for (children) |child| try self.collect(child.node, level, if (boundary) node else owner, false);
        }
    }
    fn nearest(self: *Policy, node: ?*ui.Node) ?*ui.Node {
        var cursor = node;
        while (cursor) |n| : (cursor = n.parent) if (marked(n) or floating(n) or self.portal(n)) return n;
        return null;
    }
    fn rebuild(self: *Policy, portal_key: u64) !void {
        self.entries.clearRetainingCapacity();
        self.variable_backdrops.clearRetainingCapacity();
        self.scene_ids.clearRetainingCapacity();
        if (self.cx.root) |root| try self.collect(root, 0, null, false);
        // Overlay content is already sorted by its manager's inherited z-index.
        var portals: std.ArrayList(Entry) = .empty;
        defer portals.deinit(self.cx.allocator);
        for (self.cx.overlay_stack.layers) |slot| if (slot) |layer| {
            if (layer.suspended) continue;
            const content = layer.content_node orelse continue;
            const anchor = trigger(self.cx, layer);
            try portals.append(self.cx.allocator, .{ .node = content, .owner = self.nearest(anchor), .level = 1 + self.ownerLevel(anchor, 32), .portal_root = true });
        };
        std.mem.sort(Entry, portals.items, {}, struct {
            fn less(_: void, a: Entry, b: Entry) bool {
                return a.node.style.z_index() < b.node.style.z_index();
            }
        }.less);
        for (portals.items) |entry| try self.collect(entry.node, entry.level, entry.owner, true);
        self.scene_revision = self.structureRevision();
        self.portal_revision = portal_key;
        self.scene_root = self.cx.root;
        self.scene_overlay = theme.baseColors().overlay;
        self.scene_order = self.orderKey();
        self.stats.scene_rebuilds += 1;
        // Detached retained overlays keep valid paint caches. Destroyed nodes
        // are absent from the registry's lifetime ledger, so no raw borrow is read.
        var i: usize = 0;
        while (i < self.paints.items.len) {
            const paint = self.paints.items[i];
            var remove = !self.cx.node_registry.generations.contains(paint.id);
            if (self.scene_ids.get(paint.id)) |node| {
                remove = std.mem.indexOfScalar(*ui.Node, node.children.items, paint.root) == null or !self.cx.node_registry.isCurrentIdentity(paint.root_handle, paint.root);
            }
            if (remove) {
                // Retained popovers invalidate handles when detached, but their
                // children survive. Remove the old paint from the live tree
                // before replacing its cache; otherwise every reopen adds a veil.
                if (self.scene_ids.get(paint.id)) |node| {
                    if (std.mem.indexOfScalar(*ui.Node, node.children.items, paint.root)) |index| {
                        const root = node.children.items[index];
                        if (root.id == paint.root_handle.id) {
                            self.cx.detachChild(node, root);
                            self.cx.destroyDetached(root);
                            self.layout_changed = true;
                        }
                    }
                }
                _ = self.paint_ids.remove(paint.id);
                _ = self.paints.swapRemove(i);
                paint.deinit(self.cx.allocator);
            } else i += 1;
        }
    }
    fn background(node: *ui.Node, color: ui.Color) void {
        if (!ui.Color.eql(node.getBackground(), color)) node.setBackground(color);
    }
    fn structureRevision(self: *Policy) u64 {
        return self.cx.world.structure_revision;
    }
    pub fn sync(self: *Policy) void {
        const portal_key = self.portalKey();
        // Topology is checked before reading indexed pointers: a disposed Scope
        // may have freed them. Z-order changes also invalidate the paint order.
        if (self.scene_root != self.cx.root or self.scene_revision != self.structureRevision() or self.portal_revision != portal_key or !ui.Color.eql(self.scene_overlay, theme.baseColors().overlay) or self.scene_order != self.orderKey()) self.rebuild(portal_key) catch return;
        const colors = theme.current();
        const transparency = theme.materialParameters().transparency;
        const material_changed = self.last_colors == null or !std.meta.eql(self.last_colors.?, colors) or self.last_transparency != transparency;
        self.last_colors = colors;
        self.last_transparency = transparency;
        self.underlays.clearRetainingCapacity();
        self.stats.visible_surfaces = 0;
        for (self.entries.items) |entry| {
            const node = entry.node;
            // Portal chrome includes Tooltip (which clears its default shadow),
            // Popover and Modal (which otherwise retain different shadow lists).
            // Non-portaled floating panels already declare elevation. Keep
            // shadowless inline material cards/bodies flat inside their owner.
            const existing = node.style.shadowSlice();
            const elevated = for (existing) |shadow| {
                if (shadow.color.a != 0) break true;
            } else false;
            if (entry.portal_root or (floating(node) and (entry.owner == null or elevated)) or fixedLevel(node) != null) {
                const shadow = theme.floatingShadow();
                if (existing.len != 1 or !std.meta.eql(existing[0], shadow)) {
                    node.setStyleInline(self.cx.allocator, .{ .shadows = ui.ShadowList.of(&.{shadow}) });
                }
            }
            if (entry.portal_root or std.mem.eql(u8, node.meta.ownership.meta.component_name orelse "", "MaterialSurface.overlay")) {
                const glass = theme.overlayGlass();
                if (node.style.glass_params() == null or !std.meta.eql(node.style.glass_params().?, glass)) node.setStyleInline(self.cx.allocator, .{ .glass = glass });
                if (node.style.border.color.a != 0) node.setBorderColor(ui.Color.TRANSPARENT);
                if (node.style.outline()) |outline| if (outline.width != 0) node.setStyle(self.cx.allocator, .outline, .{ .width = 0, .color = ui.Color.TRANSPARENT });
            }
            const sample = geometry.snapshot(self.cx, node) orelse {
                // Retained hidden/zero-size content gets palette updates only
                // on publication; scrolling never records its background.
                if (material_changed) background(node, (if (entry.portal_root) theme.baseColors().overlay else cardColor(node)).withAlpha(theme.layerAlpha(entry.level)));
                if (transparency == 0) self.discard(node);
                continue;
            };
            self.stats.visible_surfaces += 1;
            self.compensate(entry, sample) catch {};
            self.underlays.append(self.cx.allocator, .{ .rect = sample.rect, .clip = sample.clip, .radius = node.style.effectiveRadius(), .level = entry.level }) catch {};
        }
        // Only our excluded paint children changed topology during sync.
        self.scene_revision = self.structureRevision();
    }
    fn discard(self: *Policy, node: *ui.Node) void {
        const removed = self.paint_ids.fetchRemove(node.id) orelse return;
        const paint = removed.value;
        if (std.mem.indexOfScalar(*ui.Node, node.children.items, paint.root) != null) {
            self.cx.detachChild(node, paint.root);
            self.cx.destroyDetached(paint.root);
            self.layout_changed = true;
        }
        if (std.mem.indexOfScalar(*Compensation, self.paints.items, paint)) |index| _ = self.paints.swapRemove(index);
        paint.deinit(self.cx.allocator);
    }
    fn readableAlpha(self: *Policy) u8 {
        const colors = theme.baseColors();
        const fill = colors.overlay.withAlpha(255);
        const fg_1 = colors.fg_1.withAlpha(255);
        const fg_2 = colors.fg_2.withAlpha(255);
        if (self.readability_cache) |cached| {
            if (ui.Color.eql(cached.overlay, fill) and ui.Color.eql(cached.fg_1, fg_1) and ui.Color.eql(cached.fg_2, fg_2)) return cached.alpha;
        }
        const contrast = @import("theme_states.zig").contrast;
        var result: u8 = 255;
        // Check both extremes: real video and terminal pixels can change at any
        // time, so a stable tint avoids sampling the content or flickering.
        for (0..256) |candidate| {
            const amount = @as(f32, @floatFromInt(candidate)) / 255;
            var readable = true;
            for ([_]ui.Color{ ui.Color.BLACK, ui.Color.WHITE }) |backdrop| {
                const composed = ui.Color.lerp(backdrop, fill, amount);
                for ([_]ui.Color{ fg_1, fg_2 }) |ink| {
                    const on_light_side = contrast(fill, ui.Color.BLACK) > contrast(ink, ui.Color.BLACK);
                    if (contrast(composed, ink) < 4.5 or (contrast(composed, ui.Color.BLACK) > contrast(ink, ui.Color.BLACK)) != on_light_side) readable = false;
                }
            }
            if (readable) {
                result = @intCast(candidate);
                break;
            }
        }
        self.readability_cache = .{ .overlay = fill, .fg_1 = fg_1, .fg_2 = fg_2, .alpha = result };
        return result;
    }
    fn compensate(self: *Policy, entry: Entry, sample: Snapshot) !void {
        const node = entry.node;
        const nominal = (if (entry.portal_root) theme.baseColors().overlay else cardColor(node)).withAlpha(theme.layerAlpha(entry.level));
        if (theme.materialParameters().transparency == 0) {
            background(node, nominal);
            self.discard(node);
            return;
        }
        if (entry.portal_root) for (self.variable_backdrops.items) |backdrop| {
            const behind = geometry.snapshot(self.cx, backdrop) orelse continue;
            if (geometry.overlaps(sample.visible, behind.visible)) {
                background(node, nominal.withAlpha(@max(nominal.a, self.readableAlpha())));
                self.discard(node);
                return;
            }
        };
        const blur = node.style.backdrop_blur();
        const reach = Rect.init(sample.visible.x - 3 * blur, sample.visible.y - 3 * blur, sample.visible.w + 6 * blur, sample.visible.h + 6 * blur);
        var needed = entry.level > 1;
        if (needed and fixedLevel(node) == null) if (entry.owner) |parent| {
            const shape: geometry.Shape = .{ .rect = parent.globalRect(), .clip = sample.clip, .radius = parent.style.effectiveRadius(), .level = 0 };
            // A physical clipping ancestor already clips rounded corners as
            // well as its rectangle. Its inline descendants cannot escape it.
            if (((parent.style.overflow != .visible or parent.style.overflow_hidden) and node.isDescendantOf(parent)) or shape.contains(sample.visible)) needed = false;
        };
        var alpha = nominal.a;
        self.candidates.clearRetainingCapacity();
        for (self.underlays.items) |shape| {
            if (!geometry.overlaps(reach, shape.visible())) continue;
            try self.candidates.append(self.cx.allocator, shape);
            if (shape.level >= entry.level) {
                alpha = 0;
                needed = true;
            }
        }
        if (!needed) {
            background(node, nominal);
            self.discard(node);
            return;
        }
        var paint = self.paint_ids.get(node.id);
        if (paint == null) {
            try self.paints.ensureUnusedCapacity(self.cx.allocator, 1);
            try self.paint_ids.ensureUnusedCapacity(self.cx.allocator, 1);
            const value = try self.cx.allocator.create(Compensation);
            errdefer self.cx.allocator.destroy(value);
            const root = try ui.box(self.cx, .{ .position = .absolute, .inset = .{ .left = .{ .px = 0 }, .right = .{ .px = 0 }, .top = .{ .px = 0 }, .bottom = .{ .px = 0 } }, .width = .fill(), .height = .fill(), .hit_behavior = .pass_through, .hit_roles = .{ .pointer = false, .scroll = false, .inspect = false }, .overflow = .hidden, .border = .{ .radius = node.style.effectiveRadius() } }, .{});
            errdefer self.cx.destroyDetached(root);
            root.meta.ownership.meta.test_id = "appearance.material.compensation";
            const generation = try self.cx.node_registry.trackGeneration(root);
            _ = try self.cx.node_registry.trackGeneration(node);
            value.* = .{ .id = node.id, .root = root, .root_handle = .{ .id = root.id, .generation = generation } };
            try node.insertChildBefore(self.cx.allocator, root, if (node.children.items.len > 0) node.children.items[0] else null);
            self.paints.appendAssumeCapacity(value);
            self.paint_ids.putAssumeCapacity(node.id, value);
            self.layout_changed = true;
            paint = value;
        }
        const value = paint.?;
        const color = nominal.withAlpha(alpha);
        const geometry_paint: geometry.Paint = .{ .rect = sample.rect, .region = sample.visible, .level = entry.level, .alpha = alpha, .blur = blur, .shapes = self.candidates.items };
        const key = geometry_paint.key(node.style.effectiveRadius());
        if (value.key != key) {
            try geometry.build(self.cx.allocator, geometry_paint, &value.pending);
            if (value.root.style.effectiveRadius() != node.style.effectiveRadius()) value.root.setStyle(self.cx.allocator, .corner_radius, .{ .all = node.style.effectiveRadius() });
            try value.apply(self.cx, color);
            value.key = key;
            self.stats.geometry_builds += 1;
            self.layout_changed = true;
        } else if (!ui.Color.eql(value.color, color)) try value.repaint(self.cx, color);
        background(node, color);
    }
    fn trigger(cx: *ui.Cx, layer: anytype) ?*ui.Node {
        if (layer.trigger_handle) |handle| {
            if (cx.node_registry.resolve(handle, null)) |node| return node;
            // Hidden/reopened triggers can be outside the current frame's hit
            // snapshot while their generation and object identity remain live.
            // Match OverlayStack's weak-reference contract, never trust a stale
            // raw pointer after unregister/destroy or a failed track operation.
            if (layer.trigger_node) |node| {
                if (cx.node_registry.isCurrentIdentity(handle, node)) return node;
                // detachChild invalidates a generation even when the same
                // retained node is reattached. Reacquire it only through a live
                // tree with both its monotone ID and pointer matching. The
                // cached pointer is compared, never dereferenced on this path.
                if (cx.root) |root| if (liveTrigger(root, handle.id, node)) |live| return live;
                for (cx.overlay_stack.layers) |slot| if (slot) |parent| {
                    if (parent.suspended) continue;
                    if (parent.content_node) |content| if (liveTrigger(content, handle.id, node)) |live| return live;
                };
            }
            return null;
        }
        if (layer.trigger_node == null) {
            if (layer.previous_focus) |handle| return cx.node_registry.resolve(handle, null);
        }
        return null;
    }
    fn liveTrigger(root: *ui.Node, id: u32, cached: *ui.Node) ?*ui.Node {
        if (root == cached and root.id == id) return root;
        for (root.children.items) |child| if (liveTrigger(child, id, cached)) |live| return live;
        return null;
    }
    fn ownerLevel(self: *Policy, node: ?*ui.Node, remaining: usize) usize {
        if (remaining == 0) return 32;
        var cursor = node;
        while (cursor) |current| : (cursor = current.parent) {
            if (fixedLevel(current)) |level| return level;
            // Portal DOM ancestry stops at the portal; resume at its live trigger.
            for (self.cx.overlay_stack.layers) |slot| {
                const layer = slot orelse continue;
                if (layer.suspended or layer.content_node != current) continue;
                return 1 + self.ownerLevel(trigger(self.cx, layer), remaining - 1);
            }
            if (marked(current) or floating(current)) {
                return 1 + self.ownerLevel(current.parent, remaining - 1);
            }
        }
        return 0;
    }
};
const Compensation = struct {
    id: u32,
    root: *ui.Node,
    root_handle: ui.hit.NodeHandle,
    key: ?u64 = null,
    color: ui.Color = ui.Color.TRANSPARENT,
    nodes: std.ArrayList(*ui.Node) = .empty,
    patches: std.ArrayList(geometry.Patch) = .empty,
    pending: std.ArrayList(geometry.Patch) = .empty,
    fn deinit(self: *Compensation, a: std.mem.Allocator) void {
        self.nodes.deinit(a);
        self.patches.deinit(a);
        self.pending.deinit(a);
        a.destroy(self);
    }
    fn paintNode(cx: *ui.Cx, node: *ui.Node, patch: geometry.Patch, color: ui.Color) void {
        const gradient: ?ui.Gradient = if (patch.first == patch.last) null else .{ .from = color.withAlpha(patch.first), .to = color.withAlpha(patch.last), .direction = .horizontal };
        if (!std.meta.eql(node.style.gradient(), gradient)) node.setStyle(cx.allocator, .gradient, gradient);
        const fill = if (gradient == null) color.withAlpha(patch.first) else ui.Color.TRANSPARENT;
        if (!ui.Color.eql(node.getBackground(), fill)) node.setBackground(fill);
    }
    fn apply(self: *Compensation, cx: *ui.Cx, color: ui.Color) !void {
        try self.nodes.ensureTotalCapacity(cx.allocator, self.pending.items.len);
        while (self.nodes.items.len < self.pending.items.len) {
            const node = try ui.box(cx, .{ .position = .absolute, .hit_behavior = .pass_through, .hit_roles = .{ .pointer = false, .scroll = false, .inspect = false } }, .{});
            try self.root.appendChild(cx.allocator, node);
            self.nodes.appendAssumeCapacity(node);
        }
        for (self.nodes.items, 0..) |node, index| {
            node.setDisplay(if (index < self.pending.items.len) .flex else .none);
            if (index >= self.pending.items.len) continue;
            const patch = self.pending.items[index];
            const old = if (index < self.patches.items.len) self.patches.items[index] else null;
            if (old == null or old.?.x != patch.x or old.?.y != patch.y or old.?.w != patch.w or old.?.h != patch.h) node.setStyleInline(cx.allocator, .{ .width = .{ .px = patch.w }, .height = .{ .px = patch.h }, .inset = .{ .left = .{ .px = patch.x }, .top = .{ .px = patch.y } } });
            paintNode(cx, node, patch, color);
        }
        std.mem.swap(std.ArrayList(geometry.Patch), &self.patches, &self.pending);
        self.color = color;
    }
    fn repaint(self: *Compensation, cx: *ui.Cx, color: ui.Color) !void {
        for (self.patches.items, 0..) |patch, index| paintNode(cx, self.nodes.items[index], patch, color);
        self.color = color;
    }
};
