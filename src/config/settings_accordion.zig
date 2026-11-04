//! Native Accordion semantics with the app's interruptible, per-window motion.
const std = @import("std");
const ui = @import("ui");
const motion = @import("../ui/layout_motion.zig");

pub fn item(props: anytype) Builder(@TypeOf(props)) {
    return .{ .props = props };
}

fn Builder(comptime Props: type) type {
    return struct {
        props: Props,
        pub fn mount(self: @This(), scope: *ui.Scope, cx: *ui.Cx) !ui.widgets.AccordionItemResult {
            const result = try ui.widgets.AccordionItem(self.props).mount(scope, cx);
            errdefer cx.freeNode(result.item);
            const owner = result.item.meta.ownership.scope.scope orelse scope;
            const expanded = result.header.behavior.interaction.a11y.?.expanded.?;
            // The stock before-render hook owns imperative geometry and a
            // hover border. Settings uses its own flat hover surface; keep
            // keyboard, controlled state and accessibility owned by the widget.
            result.item.meta.per_frame.hooks.before_render.main = null;
            result.body.setStyle(cx.allocator, .flex_shrink, @as(f32, 0));
            const angle: f32 = if (expanded) std.math.pi / 2.0 else 0;
            const state = try owner.createState(State, .{
                .cx = cx,
                .header = result.header,
                .chevron = result.chevron,
                .body = undefined,
                .rotation = .{ .value = angle, .target = angle, .from = angle },
            });
            try cx.addAfterLayoutHook(state, State.afterLayout);
            try owner.onCleanup(State, state, State.cleanup);
            // Apply a new target before Disclosure samples this frame, so a
            // rapid reversal cannot advance one frame toward the old target.
            state.body = try motion.Disclosure.attach(cx, owner, result.body.parent.?, result.body, expanded);
            return result;
        }
    };
}

const State = struct {
    cx: *ui.Cx,
    header: *ui.Node,
    chevron: *ui.Node,
    body: *motion.Disclosure,
    rotation: motion.Height,

    fn afterLayout(raw: *anyopaque, _: u8, _: bool) ui.AfterLayoutResult {
        const self: *State = @ptrCast(@alignCast(raw));
        const expanded = self.header.behavior.interaction.a11y.?.expanded.?;
        const changed = self.body.expanded != expanded;
        self.body.setExpanded(expanded);
        const angle = self.rotation.sample(self.cx, if (expanded) std.math.pi / 2.0 else 0, true);
        if (@abs(self.chevron.style.rotate() - angle) > 0.001) self.chevron.setStyle(self.cx.allocator, .rotate, angle);
        return if (changed) .needs_layout else .done;
    }
    fn cleanup(self: *State) void {
        self.cx.removeAfterLayoutHook(self);
    }
};
