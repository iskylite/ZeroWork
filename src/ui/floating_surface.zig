//! Retained panels share the window overlay stack with portaled popovers.
const ui = @import("ui");
const Layer = @typeInfo(@typeInfo(@FieldType(@FieldType(ui.Cx, "overlay_stack"), "layers")).array.child).optional.child;
pub const workspace_popup = "zerowork.workspace-popup";

pub const Surface = struct {
    cx: *ui.Cx,
    node: *ui.Node,
    handle: ?@FieldType(Layer, "handle") = null,
    close: ?ui.HandlerRef,
    tier: @FieldType(@FieldType(Layer, "config"), "tier"),
    group: ?[]const u8,
    coverage: *ui.Node,
    outside_click: bool,

    pub const Options = struct {
        close: ?ui.HandlerRef = null,
        dialog: bool = false,
        group: ?[]const u8 = null,
        coverage: ?*ui.Node = null,
        outside_click: bool = false,
    };

    pub fn mount(cx: *ui.Cx, scope: *ui.Scope, node: *ui.Node, options: Options) !*Surface {
        const self = try scope.createState(Surface, .{ .cx = cx, .node = node, .close = options.close, .tier = if (options.dialog) .dialog else .overlay, .group = options.group, .coverage = options.coverage orelse node, .outside_click = options.outside_click });
        _ = try node.style.ensureExtFallible(cx.allocator);
        try cx.addAfterLayoutHook(self, afterLayout);
        errdefer cx.removeAfterLayoutHook(self);
        try scope.onCleanup(Surface, self, cleanup);
        return self;
    }
    fn displayed(self: *const Surface) bool {
        const root = self.cx.root orelse return false;
        return self.node.isDescendantOf(root) and self.node.isDisplayedInTree() and self.node.frame_state.state_bits.flags.hit_test_visible;
    }
    /// Opening an already visible panel through its toolbar also activates it.
    pub fn activate(self: *Surface) void {
        if (!self.displayed()) return;
        const stack = &self.cx.overlay_stack;
        if (self.handle) |handle| {
            stack.raise(handle);
        } else {
            const handle = stack.push(.{
                .kind = .non_modal,
                .tier = self.tier,
                .group = self.group,
                .dismiss = .{ .outside_click = if (self.outside_click) .close else .none, .escape = self.close != null },
                .on_dismiss_request = self.close,
                .focus = .{ .auto_focus = false, .restore = false },
                .enter_transition = .none,
                .exit_transition = .none,
                .retained_panel = true,
            }) catch |err| {
                @import("std").log.warn("floating panel: {s}", .{@errorName(err)});
                return;
            };
            stack.bindRetainedPanel(handle, self.node, self.coverage);
            if (stack.findLayer(handle)) |layer| layer.skip_outside_click_frame = true;
            self.handle = handle;
        }
        self.cx.requestRedraw();
    }
    pub fn deactivate(self: *Surface) void {
        if (self.handle) |handle| self.cx.overlay_stack.removePermanently(handle);
        self.handle = null;
    }
    fn afterLayout(raw: *anyopaque, _: u8, _: bool) ui.AfterLayoutResult {
        const self: *Surface = @ptrCast(@alignCast(raw));
        if (!self.displayed()) {
            self.deactivate();
        } else if (self.handle == null) {
            self.activate();
        }
        return .done;
    }
    fn cleanup(self: *Surface) void {
        self.cx.removeAfterLayoutHook(self);
        self.deactivate();
    }
};
