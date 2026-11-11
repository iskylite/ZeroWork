const std = @import("std");
const ui = @import("ui");
const floating_input = @import("floating_input.zig");

pub const Mode = enum { content, panel };
pub const Owner = union(enum) {
    node: *ui.Node,
    resolve: struct { context: *anyopaque, get: *const fn (*anyopaque) ?*ui.Node },
};
pub const Options = struct { owner: Owner, mode: Mode = .content };

const WindowCover = struct { node_id: u32 };

/// Register the window's retained preferences surface so dialogs underneath it
/// suspend with their owners while nested preferences dialogs remain available.
pub fn registerWindowCover(cx: *ui.Cx, node: *ui.Node) !void {
    const cover = try cx.bindState(WindowCover, .{ .node_id = node.id });
    try cx.provide(WindowCover, cover);
}

pub fn coversPoint(cx: *const ui.Cx, x: f32, y: f32) bool {
    for (&cx.overlay_stack.layers) |*slot| if (slot.*) |*layer| {
        if (layer.suspended or layer.state == .exiting) continue;
        const node = if (layer.config.kind == .modal or layer.config.scoped_mask) layer.barrier_node else layer.content_node;
        if (node) |surface| {
            if (surface.isDisplayedInTree() and surface.frame_state.state_bits.flags.hit_test_visible and surface.globalRect().contains(x, y)) return true;
        }
    };
    return false;
}

/// Mount the Modal with managed_focus=false. Its portal provides stacking,
/// while this binding keeps geometry and focus attached to the live owner.
pub fn bind(cx: *ui.Cx, scope: *ui.Scope, modal: ui.widgets.modal.ModalResult, options: Options) !*Binding {
    if (!modal.portaled and modal.overlay.parent == null) {
        if (cx.root) |root| try root.appendChild(cx.allocator, modal.overlay);
    }
    const binding = try scope.createState(Binding, .{
        .cx = cx,
        .modal = modal,
        .owner = switch (options.owner) {
            .node => |node| .{ .node_id = node.id },
            .resolve => |resolver| .{ .resolve = .{ .context = resolver.context, .get = resolver.get } },
        },
        .mode = options.mode,
        .barrier_color = modal.overlay.getBackground(),
        .max_width = modal.dialog.style.getExt().max_width,
        .max_height = modal.dialog.style.getExt().max_height,
    });
    floating_input.protect(cx, modal.dialog);
    if (options.mode == .content) floating_input.protect(cx, modal.overlay);
    try cx.addAfterLayoutHook(binding, Binding.afterLayout);
    errdefer cx.removeAfterLayoutHook(binding);
    try scope.onCleanup(Binding, binding, Binding.cleanup);
    _ = binding.sync();
    return binding;
}

pub const Binding = struct {
    cx: *ui.Cx,
    modal: ui.widgets.modal.ModalResult,
    owner: union(enum) {
        node_id: u32,
        resolve: struct { context: *anyopaque, get: *const fn (*anyopaque) ?*ui.Node },
    },
    mode: Mode,
    barrier_color: ui.Color,
    max_width: f32,
    max_height: f32,
    prior_focus: ?ui.hit.NodeHandle = null,
    active_owner: ?ui.hit.NodeHandle = null,
    geometry: ?ui.ComputedRect = null,
    applied_mode: ?Mode = null,

    pub fn setMode(self: *Binding, mode: Mode) void {
        if (self.mode == mode) return;
        self.mode = mode;
        self.cx.requestRedraw();
    }

    fn cleanup(self: *Binding) void {
        self.cx.removeAfterLayoutHook(self);
    }

    fn afterLayout(raw: *anyopaque, _: u8, _: bool) ui.AfterLayoutResult {
        const self: *Binding = @ptrCast(@alignCast(raw));
        return if (self.sync()) .needs_layout else .done;
    }

    fn visibleOwner(self: *Binding) ?*ui.Node {
        const root = self.cx.root orelse return null;
        const node = switch (self.owner) {
            .node_id => |id| if (id == root.id) root else self.cx.node_registry.resolveLiveId(id),
            .resolve => |resolver| resolver.get(resolver.context),
        } orelse return null;
        if (!node.isDescendantOf(root) or !node.isDisplayedInTree()) return null;
        if (node != root) if (self.cx.consume(WindowCover)) |window_cover| {
            if (self.cx.node_registry.resolveLiveId(window_cover.node_id)) |cover| {
                if (cover.isDisplayedInTree() and !floating_input.containsPress(self.cx, cover, node)) return null;
            }
        };
        return node;
    }

    fn bounds(self: *Binding, node: *ui.Node) ui.ComputedRect {
        var rect = intersect(node.globalRect(), .{ .x = 0, .y = 0, .w = self.cx.viewport.width, .h = self.cx.viewport.height });
        var parent = node.parent;
        while (parent) |ancestor| : (parent = ancestor.parent) {
            if (ancestor.style.overflow_hidden) rect = intersect(rect, ancestor.globalRect());
        }
        return rect;
    }

    fn sync(self: *Binding) bool {
        const overlay = self.modal.overlay;
        const opened = self.modal.open_source.peek();
        const owner = if (opened) self.visibleOwner() else null;
        const rect = if (owner) |node| self.bounds(node) else ui.ComputedRect{ .x = 0, .y = 0, .w = 0, .h = 0 };
        const visible = rect.w > 0 and rect.h > 0;
        const handle = if (visible) self.cx.node_registry.handleFor(owner.?) else null;
        if (self.cx.overlay_stack.findLayerForNode(overlay)) |layer| {
            const mask = visible and self.mode == .content;
            if (layer.config.scoped_mask != mask or !std.meta.eql(layer.trigger_handle, handle)) {
                self.cx.overlay_stack.setScopedOwner(layer.handle, if (visible) owner else null, mask);
            }
        }
        if (!visible) {
            self.restoreFocus();
            self.active_owner = null;
            self.geometry = null;
            if (overlay.style.display == .none) return false;
            overlay.setDisplay(.none);
            return true;
        }

        const node = owner.?;
        const parent_rect = if (overlay.parent) |parent| parent.globalRect() else ui.ComputedRect{ .x = 0, .y = 0, .w = 0, .h = 0 };
        const geometry = ui.ComputedRect{ .x = rect.x - parent_rect.x, .y = rect.y - parent_rect.y, .w = rect.w, .h = rect.h };
        const reveal = overlay.style.display == .none;
        const changed = reveal or !std.meta.eql(self.geometry, @as(?ui.ComputedRect, geometry)) or self.applied_mode != self.mode or
            overlay.style.width != .px or overlay.style.width.px != geometry.w or
            overlay.style.height != .px or overlay.style.height.px != geometry.h;
        if (changed) {
            overlay.setStyleInline(self.cx.allocator, .{
                .position = .absolute,
                .inset = .{ .top = .{ .px = geometry.y }, .left = .{ .px = geometry.x } },
                .width = .{ .px = geometry.w },
                .height = .{ .px = geometry.h },
                .overflow_hidden = true,
                .background = if (self.mode == .content) self.barrier_color else ui.Color.TRANSPARENT,
                .hit_behavior = if (self.mode == .content) .@"opaque" else .pass_through,
                .hit_roles = .{ .pointer = self.mode == .content, .scroll = self.mode == .content },
            });
            self.modal.dialog.setStyleInline(self.cx.allocator, .{
                .max_width = @min(self.max_width, @max(1, geometry.w - 12)),
                .max_height = @min(self.max_height, @max(1, geometry.h - 12)),
            });
            overlay.setDisplay(.flex);
            if (self.mode == .content) floating_input.protect(self.cx, overlay);
            self.geometry = geometry;
            self.applied_mode = self.mode;
        }
        self.active_owner = handle;
        if (self.mode == .content) {
            if (self.cx.focus_manager.getFocused()) |focused| {
                if (focused.isDescendantOf(node) and !self.cx.overlay_stack.allowsScopedFocus(focused)) {
                    self.prior_focus = self.cx.node_registry.handleFor(focused);
                    self.cx.setFocus(firstFocusable(self.modal.dialog) orelse self.modal.dialog);
                }
            } else if (reveal) self.cx.setFocus(firstFocusable(self.modal.dialog));
        }
        return changed;
    }

    fn restoreFocus(self: *Binding) void {
        const focused = self.cx.focus_manager.getFocused();
        const prior = self.cx.node_registry.resolve(self.prior_focus, null);
        self.prior_focus = null;
        if (focused) |node| {
            if (!floating_input.containsPress(self.cx, self.modal.overlay, node)) return;
            const owner = self.cx.node_registry.resolve(self.active_owner, null);
            if (prior) |target| if (owner != null and owner.?.isDisplayedInTree() and target.isDescendantOf(owner.?) and target.isDisplayedInTree()) {
                self.cx.setFocus(target);
                return;
            };
            self.cx.setFocus(null);
        }
    }
};

fn firstFocusable(node: *ui.Node) ?*ui.Node {
    if (node.style.display == .none) return null;
    if (node.behavior.interaction.focusable) return node;
    for (node.children.items) |child| if (firstFocusable(child)) |target| return target;
    return null;
}

fn intersect(a: ui.ComputedRect, b: ui.ComputedRect) ui.ComputedRect {
    const x = @max(a.x, b.x);
    const y = @max(a.y, b.y);
    return .{ .x = x, .y = y, .w = @max(0, @min(a.x + a.w, b.x + b.w) - x), .h = @max(0, @min(a.y + a.h, b.y + b.h) - y) };
}
