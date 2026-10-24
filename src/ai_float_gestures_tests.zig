const std = @import("std");
const ui = @import("ui");
const float = @import("ai/float_model.zig");
const gestures = @import("ui/ai_float_gestures.zig");
const styles = @import("ui/ai_assistant_styles.zig");

const pane: float.Rect = .{ .x = 240, .y = 62, .width = 1190, .height = 790 };
const window: float.Rect = .{ .x = 0, .y = 0, .width = 1440, .height = 900 };

const Fixture = struct {
    cx: *ui.Cx,
    scope: *ui.Scope,
    card: *ui.Node,
    grip: *ui.Node,
    view: *gestures.View,
    model: float.Model = .{ .visible = true, .expanded = true },
    input: ui.widgets.input.InputResult,

    fn init(self: *Fixture) !void {
        self.* = .{ .cx = try ui.Cx.init(std.testing.allocator, std.testing.io), .scope = undefined, .card = undefined, .grip = undefined, .view = undefined, .input = undefined };
        self.scope = try ui.Scope.init(std.testing.allocator, null, self.cx.owner);
        self.cx.setViewport(1440, 900);
        self.cx.root = try ui.box(self.cx, .{ .width = .fill(), .height = .fill() }, .{});
        self.card = try ui.boxStyled(self.cx, styles.panel, .{});
        self.grip = try ui.boxStyled(self.cx, styles.gripRow, .{});
        try self.grip.appendChild(self.cx.allocator, try ui.boxStyled(self.cx, styles.grip, .{}));
        try self.card.appendChild(self.cx.allocator, self.grip);
        const text = try self.scope.createText("selected input stays local", .{});
        self.input = try ui.widgets.Input(.{ .value = text }).mountResult(self.scope, self.cx);
        self.input.node.setStyleInline(self.cx.allocator, .{ .width = .{ .px = 300 }, .height = .{ .px = 32 }, .margin = .{ .left = 20, .top = 20 } });
        try self.card.appendChild(self.cx.allocator, self.input.node);
        try self.cx.root.?.appendChild(self.cx.allocator, self.card);
        self.view = try gestures.View.mount(self.cx, self.scope, self.card, self.grip, &self.model);
        self.layout();
    }
    fn deinit(self: *Fixture) void {
        self.scope.dispose();
        self.cx.deinit();
    }
    fn layout(self: *Fixture) void {
        self.view.updateBounds(pane, window);
        const rect = self.model.rect(pane, window);
        self.card.setStyleInline(self.cx.allocator, .{ .position = .absolute, .inset = .{ .left = .{ .px = rect.x }, .top = .{ .px = rect.y } }, .width = .{ .px = rect.width }, .height = .{ .px = rect.height } });
        self.cx.frame_count += 1;
        self.cx.frame_time_ms += 16;
        self.cx.layout();
    }
    fn begin(self: *Fixture, node: *ui.Node, dx: f32, dy: f32) void {
        const rect = node.globalRect();
        const x = rect.x + rect.w / 2;
        const y = rect.y + rect.h / 2;
        self.cx.handleMouseDown(x, y, .{});
        self.cx.handleMouseMove(x + dx, y + dy);
        self.layout();
    }
    fn finish(self: *Fixture) void {
        self.cx.handleMouseUp(self.cx.mouse_x, self.cx.mouse_y);
        self.layout();
    }
};

test "AI float desired rectangle survives smaller bounds and resize enforces minima with opposite edges fixed" {
    var model: float.Model = .{ .visible = true, .expanded = true };
    const desired: float.Rect = .{ .x = 600, .y = 180, .width = 700, .height = 500 };
    model.setRectangle(desired, pane, window);
    const small: float.Rect = .{ .x = 0, .y = 0, .width = 500, .height = 300 };
    model.updateBounds(small, window);
    try std.testing.expectEqual(desired, model.desired.?);
    try std.testing.expectEqual(@as(f32, 484), model.clamped.?.width);
    try std.testing.expectEqual(@as(f32, 284), model.clamped.?.height);
    model.updateBounds(pane, window);
    try std.testing.expectEqual(desired, model.clamped.?);
    const minimum = float.resized(desired, .nw, 1000, 1000, pane, window);
    try std.testing.expectEqual(@as(f32, 520), minimum.width);
    try std.testing.expectEqual(@as(f32, 354), minimum.height);
    try std.testing.expectEqual(desired.x + desired.width, minimum.x + minimum.width);
    try std.testing.expectEqual(desired.y + desired.height, minimum.y + minimum.height);
}

test "AI float actual Cx grip drag commits and Escape or window blur rolls geometry back" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const initial = f.model.rect(pane, window);
    f.begin(f.grip, 80, 50);
    try std.testing.expect(f.view.bindings[0].?.isDragging());
    f.finish();
    try std.testing.expectEqual(initial.x + 80, f.model.desired.?.x);
    try std.testing.expectEqual(initial.y + 50, f.model.desired.?.y);
    const committed = f.model.geometry();
    f.begin(f.grip, 40, 35);
    f.model.status.state = .thinking;
    f.cx.handleKeyDown(.escape, .{});
    f.layout();
    try std.testing.expectEqual(committed, f.model.geometry());
    try std.testing.expectEqual(@import("ai/status.zig").State.thinking, f.model.status.state);
    try std.testing.expect(!f.view.bindings[0].?.isDragging());
    f.begin(f.grip, 45, 30);
    f.cx.cancelPointerInteractions(.window_blur);
    f.layout();
    try std.testing.expectEqual(committed, f.model.geometry());
    try std.testing.expect(f.view.active == null);
}

test "AI float actual Cx all four edges and corners resize without capturing central text input" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const initial: float.Rect = .{ .x = 600, .y = 180, .width = 600, .height = 420 };
    for ([_]float.Edge{ .n, .s, .w, .e, .nw, .ne, .sw, .se }, 0..) |edge, index| {
        f.model.setRectangle(initial, pane, window);
        f.layout();
        const dx: f32 = if (edge.west()) -40 else if (edge.east()) 40 else 0;
        const dy: f32 = if (edge.north()) -20 else if (edge.south()) 20 else 0;
        f.begin(f.view.handles[index], dx, dy);
        try std.testing.expect(f.view.bindings[index + 1].?.isDragging());
        f.finish();
        const result = f.model.rect(pane, window);
        try std.testing.expectEqual(initial.width + if (dx == 0) @as(f32, 0) else 40, result.width);
        try std.testing.expectEqual(initial.height + if (dy == 0) @as(f32, 0) else 20, result.height);
        try std.testing.expectEqual(initial.x + if (edge.west()) @as(f32, -40) else 0, result.x);
        try std.testing.expectEqual(initial.y + if (edge.north()) @as(f32, -20) else 0, result.y);
    }
    const geometry = f.model.geometry();
    const input = f.input.input_container.globalRect();
    f.cx.handleMouseDown(input.x + 20, input.y + input.h / 2, .{});
    f.cx.handleMouseMove(input.x + 100, input.y + input.h / 2);
    f.finish();
    try std.testing.expect(f.cx.focus_manager.getFocused() == f.input.input_container);
    try std.testing.expect(f.cx.drag_manager.session == null);
    try std.testing.expectEqual(geometry, f.model.geometry());
}

test "AI float double click resets only position maximize restores size and owner cancel discards late pointer" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const manual: float.Rect = .{ .x = 600, .y = 180, .width = 720, .height = 480 };
    f.model.setRectangle(manual, pane, window);
    f.layout();
    const grip = f.grip.globalRect();
    f.cx.handleClick(grip.x + grip.w / 2, grip.y + grip.h / 2);
    f.cx.handleClick(grip.x + grip.w / 2, grip.y + grip.h / 2);
    f.layout();
    const reset = f.model.rect(pane, window);
    try std.testing.expectEqual(manual.width, reset.width);
    try std.testing.expectEqual(manual.height, reset.height);
    try std.testing.expectEqual(pane.x + (pane.width - reset.width) / 2, reset.x);
    try std.testing.expectEqual(pane.y + 14, reset.y);
    f.view.toggleMaximized();
    f.layout();
    try std.testing.expectEqual(float.safeBounds(pane, window), f.model.rect(pane, window));
    for (f.view.handles) |handle| try std.testing.expect(!handle.isDisplayedInTree());
    f.view.toggleMaximized();
    f.layout();
    try std.testing.expectEqual(reset, f.model.rect(pane, window));
    f.begin(f.grip, 50, 20);
    f.view.cancel(); // Host calls this before moving its per-owner model state.
    const archived = f.model;
    f.model = .{ .visible = true, .expanded = true };
    f.layout();
    f.cx.handleMouseMove(1200, 700);
    f.finish();
    try std.testing.expect(f.model.desired == null);
    try std.testing.expectEqual(reset, archived.desired.?);
}

test "AI float scope teardown cancels an active resize and clears its native event bindings" {
    var f: Fixture = undefined;
    try f.init();
    defer f.cx.deinit();
    const initial = f.model.geometry();
    const grip = f.grip;
    const handles = f.view.handles;
    f.begin(handles[7], 40, 20);
    try std.testing.expect(f.view.active != null);
    f.scope.dispose();
    try std.testing.expectEqual(initial, f.model.geometry());
    try std.testing.expect(f.cx.drag_manager.session == null);
    try std.testing.expect(grip.behavior.events.on_event == null and grip.behavior.events.on_event_capture == null);
    for (handles) |handle| try std.testing.expect(handle.behavior.events.on_event == null and handle.behavior.events.event_context == null);
}
