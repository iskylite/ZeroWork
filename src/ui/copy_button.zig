//! Clipboard actions acknowledge the actual write on the button itself.
const std = @import("std");
const ui = @import("ui");
const theme = @import("app_theme.zig");

pub const Button = struct {
    cx: *ui.Cx,
    node: *ui.Node = undefined,
    status: *ui.Signal(Status),
    timer: ?u64 = null,
    const Status = enum { idle, copied, failed };

    /// Keep custom button layouts while sharing the same acknowledgement timer.
    pub fn attach(cx: *ui.Cx, scope: *ui.Scope, node: *ui.Node) !*Button {
        const self = try scope.createState(Button, .{ .cx = cx, .node = node, .status = try scope.createSignal(Status, .idle) });
        const icon = findIcon(node);
        const label = findLabel(node);
        try scope.createEffect(.{
            .status = self.status,
            .cx = cx,
            .node = node,
            .icon = icon,
            .label = label,
            .original_icon = if (icon) |n| n.getIcon() else null,
            .original_text = try scope.createText(if (label) |n| n.getText().?.content else "", .{}),
            .original_color = if (label) |n| n.getText().?.color else ui.Color.TRANSPARENT,
            .original_name = try scope.createText(if (node.behavior.interaction.a11y) |attrs| attrs.label orelse "" else "", .{}),
        }, struct {
            fn update(ctx: anytype) void {
                const status = ctx.status.get();
                const color = if (status == .copied) theme.current().ok_ink else theme.current().danger_ink;
                if (ctx.icon) |n| {
                    if (status == .idle) n.setIcon(ctx.original_icon) else {
                        const asset = if (status == .copied) ui.icons.check else ui.icons.get("circle-alert").?;
                        if (asset.icon_id) |id| if (asset.pickRep(16)) |rep| n.setIcon(.{ .icon_id = id, .rep = rep, .tint = color });
                    }
                }
                if (ctx.label) |n| {
                    n.setTextContent(ctx.cx.allocator, switch (status) {
                        .idle => ctx.original_text.peek(),
                        .copied => "已复制",
                        .failed => "复制失败",
                    }) catch {};
                    n.setTextColor(if (status == .idle) ctx.original_color else color);
                }
                if (ctx.node.behavior.interaction.a11y) |*attrs| attrs.label = switch (status) {
                    .idle => ctx.original_name.peek(),
                    .copied => "已复制",
                    .failed => "复制失败，请重试",
                };
                ctx.node.markRenderDirty();
            }
        }.update);
        try scope.onCleanup(Button, self, release);
        return self;
    }

    fn findIcon(node: *ui.Node) ?*ui.Node {
        if (node.style.display == .none) return null;
        if (node.getIcon() != null) return node;
        for (node.children.items) |child| if (findIcon(child)) |found| return found;
        return null;
    }

    fn findLabel(node: *ui.Node) ?*ui.Node {
        if (node.style.display == .none) return null;
        if (node.getText()) |text| if (text.content.len > 0) return node;
        for (node.children.items) |child| if (findLabel(child)) |found| return found;
        return null;
    }

    pub fn mount(cx: *ui.Cx, scope: *ui.Scope, args: anytype) !*Button {
        var props = ui.reactive.props.coerce(ui.widgets.button.ButtonProps, args);
        const self = try scope.createState(Button, .{ .cx = cx, .status = try scope.createSignal(Status, .idle) });
        props.icon_asset = try scope.derive(?ui.SvgAsset, .{ .status = self.status, .original = props.icon_asset }, struct {
            fn get(ctx: anytype) ?ui.SvgAsset {
                return switch (ctx.status.get()) {
                    .idle => ctx.original.get(),
                    .copied => ui.icons.check,
                    .failed => ui.icons.get("circle-alert").?,
                };
            }
        }.get);
        props.icon_tint = try scope.derive(?ui.Color, .{ .status = self.status, .original = props.icon_tint }, struct {
            fn get(ctx: anytype) ?ui.Color {
                return switch (ctx.status.get()) {
                    .idle => ctx.original.get(),
                    .copied => theme.current().ok_ink,
                    .failed => theme.current().danger_ink,
                };
            }
        }.get);
        props.a11y_label = try scope.derive([]const u8, .{ .status = self.status, .original = props.a11y_label }, struct {
            fn get(ctx: anytype) []const u8 {
                return switch (ctx.status.get()) {
                    .idle => ctx.original.get(),
                    .copied => "已复制",
                    .failed => "复制失败，请重试",
                };
            }
        }.get);
        props.label = try scope.derive([]const u8, .{ .status = self.status, .original = props.label }, struct {
            fn get(ctx: anytype) []const u8 {
                const original = ctx.original.get();
                if (original.len == 0) return original;
                return switch (ctx.status.get()) {
                    .idle => original,
                    .copied => "已复制",
                    .failed => "复制失败",
                };
            }
        }.get);
        self.node = try ui.widgets.Button(props).mount(scope, cx);
        try scope.onCleanup(Button, self, release);
        return self;
    }

    pub fn copy(self: *Button, text: []const u8) void {
        self.report(ui.platform_services.clipboardSetText(self.cx.system_sdk, text));
    }

    pub fn report(self: *Button, success: bool) void {
        if (self.timer) |id| self.cx.clearTimer(id);
        self.timer = null;
        self.status.set(if (success) .copied else .failed);
        // A one-shot Cx timer wakes an idle window; no layout or animation is required.
        self.timer = self.cx.setTimer(2 * std.time.ns_per_s, reset, self) catch {
            self.status.set(.idle);
            self.cx.requestRedraw();
            return;
        };
        self.cx.requestRedraw();
    }

    fn reset(raw: ?*anyopaque) void {
        const self: *Button = @ptrCast(@alignCast(raw orelse return));
        self.timer = null;
        self.status.set(.idle);
        self.cx.requestRedraw();
    }

    fn release(self: *Button) void {
        if (self.timer) |id| self.cx.clearTimer(id);
        self.timer = null;
    }
};

test "copy button acknowledges writes, isolates state, resets and cleans up" {
    const a = std.testing.allocator;
    const cx = try ui.Cx.init(a, std.testing.io);
    defer cx.deinit();
    const scope = try ui.Scope.init(a, null, cx.owner);
    defer scope.dispose();
    cx.root = try ui.box(cx, .{ .width = .{ .px = 200 }, .height = .{ .px = 80 } }, .{});
    const label = try scope.createText("复制代码", .{});
    const button = try Button.mount(cx, scope, .{ .variant = .ghost, .icon_only = true, .icon_asset = ui.icons.copy, .a11y_label = label });
    try cx.root.?.appendChild(a, button.node);
    const other = try Button.mount(cx, scope, .{ .label = "复制", .variant = .ghost });
    try cx.root.?.appendChild(a, other.node);

    // A missing SDK is a real failed clipboard write, never a success.
    button.copy("exact bytes\n\n");
    try std.testing.expectEqual(Button.Status.failed, button.status.peek());
    try std.testing.expectEqualStrings("复制失败，请重试", button.node.behavior.interaction.a11y.?.label.?);
    try std.testing.expectEqual(Button.Status.idle, other.status.peek());
    button.report(true);
    try std.testing.expectEqualStrings("已复制", button.node.behavior.interaction.a11y.?.label.?);
    const previous_timer = button.timer.?;
    button.report(true);
    try std.testing.expect(button.timer.? != previous_timer);
    for (cx.timers.items) |timer| try std.testing.expect(timer.id != previous_timer);
    label.set("复制调用参数");
    for (cx.timers.items) |*timer| if (timer.id == button.timer.?) {
        timer.due_ns = 0;
        break;
    };
    cx.fireDueTimers();
    try std.testing.expectEqual(Button.Status.idle, button.status.peek());
    try std.testing.expectEqualStrings("复制调用参数", button.node.behavior.interaction.a11y.?.label.?);

    // Custom icon/label children retain their layout and restore on the same timer.
    const custom = try ui.widgets.Button(.{ .variant = .ghost, .a11y_label = "复制日志" }).mount(scope, cx);
    try cx.root.?.appendChild(a, custom);
    const custom_icon = try ui.iconTint(cx, ui.icons.copy, theme.current().fg_2, .{ .width = .{ .px = 16 }, .height = .{ .px = 16 } });
    const original_icon = custom_icon.getIcon().?;
    try custom.appendChild(a, custom_icon);
    const custom_label = try ui.text(cx, "复制日志", .{ .font_size = 11 });
    try custom.appendChild(a, custom_label);
    const attached = try Button.attach(cx, scope, custom);
    attached.report(true);
    try std.testing.expectEqualStrings("已复制", custom_label.getText().?.content);
    try std.testing.expectEqual(ui.icons.check.icon_id.?, custom_icon.getIcon().?.icon_id);
    attached.report(false);
    try std.testing.expectEqualStrings("复制失败", custom_label.getText().?.content);
    for (cx.timers.items) |*timer| if (timer.id == attached.timer.?) {
        timer.due_ns = 0;
        break;
    };
    // Fire the timeout directly, without a layout pass or ongoing animation.
    cx.fireDueTimers();
    try std.testing.expectEqualStrings("复制日志", custom_label.getText().?.content);
    try std.testing.expectEqual(original_icon.icon_id, custom_icon.getIcon().?.icon_id);
    try std.testing.expectEqualStrings("复制日志", custom.behavior.interaction.a11y.?.label.?);

    // Disposal while a reset is pending must cancel its callback.
    const child = try scope.childScope();
    const transient = try Button.mount(cx, child, .{ .label = "复制" });
    try cx.root.?.appendChild(a, transient.node);
    transient.report(true);
    const pending_timer = transient.timer.?;
    child.dispose();
    for (cx.timers.items) |timer| try std.testing.expect(timer.id != pending_timer);
    cx.fireDueTimers();
}
