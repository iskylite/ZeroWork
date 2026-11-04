//! Shared preset colour buttons for group and session-tab settings.
const ui = @import("ui");
const theme = @import("app_theme.zig");
const S = @import("color_palette_styles.zig");
pub const colors = [_]u32{ 0x818cf8, 0x6366f1, 0x87bde8, 0x5bbfc4, 0x67b88b, 0xa3bd6b, 0xe2ad67, 0xe89963, 0xe27878, 0xdf8598, 0xc48cdb, 0x94a3b8 };
pub const labels = [_][]const u8{ "#818cf8", "#6366f1", "#87bde8", "#5bbfc4", "#67b88b", "#a3bd6b", "#e2ad67", "#e89963", "#e27878", "#df8598", "#c48cdb", "#94a3b8" };
const names = [_][]const u8{ "淡紫", "靛蓝", "天蓝", "青色", "绿色", "草绿", "金色", "橙色", "红色", "粉色", "紫色", "灰蓝" };
pub const Hooks = struct { context: *anyopaque, choose: *const fn (*anyopaque, u32) void };
pub const View = struct {
    cx: *ui.Cx,
    root: *ui.Node,
    hooks: Hooks,
    buttons: [colors.len]*ui.Node = undefined,
    checks: [colors.len]*ui.Node = undefined,
    pub fn mount(cx: *ui.Cx, scope: *ui.Scope, comptime prefix: []const u8, disabled: *ui.Signal(bool), hooks: Hooks) !*View {
        const self = try scope.createState(View, .{ .cx = cx, .root = try ui.box(cx, S.palette(), .{}), .hooks = hooks });
        self.root.meta.ownership.meta.test_id = prefix ++ ".palette";
        inline for (0..2) |row_index| {
            const row = try ui.box(cx, S.row(), .{});
            try self.root.appendChild(cx.allocator, row);
            inline for (0..6) |column| {
                const index = row_index * 6 + column;
                const color = colors[index];
                const action = try scope.createState(Choice, .{ .view = self, .color = color });
                const button = try ui.widgets.Button(.{ .variant = .ghost, .icon_only = true, .a11y_label = names[index] ++ " " ++ labels[index], .disabled = disabled, .focus_ring = .{ .color = theme.current().accent, .width = 1.5, .offset = 3 }, .base_style = S.swatch(color), .hover_style = .{ .background = ui.Color.hex(color) }, .pressed_style = .{ .background = ui.Color.hex(color) }, .on_click = cx.on(Choice, action, Choice.choose) }).mount(scope, cx);
                button.meta.ownership.meta.test_id = prefix ++ "." ++ labels[index][1..];
                const check = try ui.iconTint(cx, ui.icons.check, ui.Color.hex(0x1f2937), .{ .width = .{ .px = 18 }, .height = .{ .px = 18 }, .flex_shrink = 0 });
                check.setStyleInline(cx.allocator, .{ .opacity = 0 });
                try button.appendChild(cx.allocator, check);
                self.buttons[index] = button;
                self.checks[index] = check;
                try row.appendChild(cx.allocator, button);
            }
        }
        return self;
    }
    pub fn select(self: *View, color: ?u32) void {
        for (colors, 0..) |preset, index| {
            const selected = color != null and color.? == preset;
            self.checks[index].setStyleInline(self.cx.allocator, .{ .opacity = if (selected) 1 else 0 });
            self.buttons[index].setStyleInline(self.cx.allocator, .{ .outline = .{ .width = if (selected) 2 else 0, .offset = 2, .color = theme.current().fg_1 } });
            if (self.buttons[index].behavior.interaction.a11y) |*a11y| a11y.pressed = selected;
        }
    }
};
const Choice = struct {
    view: *View,
    color: u32,
    fn choose(self: *Choice) void {
        self.view.hooks.choose(self.view.hooks.context, self.color);
    }
};
