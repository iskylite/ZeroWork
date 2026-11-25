const std = @import("std");
const ui = @import("ui");
const App = @import("zenit_app").App;
const styles = @import("notification_styles.zig");
const theme = @import("app_theme.zig");

const State = struct {
    app: ?*App = null,
    reason: []const u8 = "",
    guidance: []const u8 = "",

    fn quit(self: *State) void {
        if (self.app) |app| app.quit();
    }
};
const state_id = std.hash.Wyhash.hash(0, "ZeroWork.startupFailure");

/// Show a readable failure without opening a workspace or loading preferences.
pub fn show(io: std.Io, reason: []const u8, guidance: []const u8, notify: *const fn ([]const u8) void) !void {
    const app = try App.init(std.heap.c_allocator, .{
        .io = io,
        .font = .{ .fallback_families = @import("../platform/ui_fonts.zig").families },
        .window = .{ .title = "ZeroWork", .width = 388, .height = 224, .min_width = 388, .min_height = 224 },
    });
    defer app.deinit();
    (try app.cx.state(State, state_id, .{})).* = .{ .app = app, .reason = reason, .guidance = guidance };
    try app.mount(mount);
    notify(reason);
    app.activate();
    try app.run();
}

fn mount(cx: *ui.Cx, scope: *ui.Scope) !*ui.Node {
    const state = try cx.state(State, state_id, .{});
    cx.setTheme(theme.widgetTheme(theme.currentName()));
    const root = try ui.box(cx, .{
        .width = .fill(),
        .height = .fill(),
        .direction = .column,
        .align_items = .center,
        .justify = .center,
        .background = theme.baseColors().app,
    }, .{});
    const card = try ui.boxStyled(cx, styles.card, .{});
    card.setStyleInline(cx.allocator, .{ .width = .{ .px = styles.width } });
    card.meta.ownership.meta.test_id = "startup.failure.card";
    card.behavior.interaction.a11y = .{ .role = .alert, .live = "assertive" };
    try root.appendChild(cx.allocator, card);

    const header = try ui.boxStyled(cx, styles.header, .{});
    try card.appendChild(cx.allocator, header);
    const error_ink = styles.statusInk(3);
    try header.appendChild(cx.allocator, try ui.iconTint(cx, ui.icons.circle_alert, error_ink, styles.icon()));
    const title = try ui.textStyled(cx, styles.title, "无法读取配置");
    title.setTextColor(error_ink);
    title.setStyleInline(cx.allocator, styles.textBox(cx.tokens));
    title.meta.ownership.meta.test_id = "startup.failure.title";
    try header.appendChild(cx.allocator, title);

    const body = try ui.boxStyled(cx, styles.body, .{});
    try card.appendChild(cx.allocator, body);
    var detail_style = styles.detail(cx.tokens);
    detail_style.wrap = .word;
    detail_style.text_overflow = .clip;
    const reason = try ui.text(cx, state.reason, detail_style);
    reason.setTextColor(error_ink);
    reason.meta.ownership.meta.test_id = "startup.failure.reason";
    try body.appendChild(cx.allocator, reason);
    try body.appendChild(cx.allocator, try ui.text(cx, state.guidance, detail_style));

    const footer = try ui.boxStyled(cx, styles.footer, .{});
    footer.setStyleInline(cx.allocator, .{ .justify = .end });
    try card.appendChild(cx.allocator, footer);
    const quit = try ui.widgets.Button(.{
        .label = "退出",
        .variant = .primary,
        .size = .xs,
        .base_style = @import("notification_history_styles.zig").action(),
        .on_click = cx.on(State, state, State.quit),
    }).mount(scope, cx);
    quit.meta.ownership.meta.test_id = "startup.failure.quit";
    try footer.appendChild(cx.allocator, quit);
    cx.setFocus(quit);
    return root;
}
