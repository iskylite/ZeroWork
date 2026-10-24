const ui = @import("ui");
const App = @import("zenit_app").App;

var app: *App = undefined;
var visible: *ui.Signal(bool) = undefined;
var sample: *ui.Node = undefined;
var label: *ui.Node = undefined;
var moving: *ui.Node = undefined;
var mode_label: *ui.Node = undefined;
var stage: usize = 0;

const Actions = struct {
    fn next(_: *@This()) void {
        stage = (stage + 1) % 3;
        const colors = [_]ui.Color{ ui.Color.rgba(220, 30, 70, 150), ui.Color.rgba(20, 200, 90, 80), ui.Color.rgba(40, 80, 220, 220) };
        const labels = [_][]const u8{ "Long retained text: glyphs 中文", "短", "" };
        sample.setBackground(colors[stage]);
        label.setText(.{ .content = labels[stage], .font_size = 20, .color = ui.Color.WHITE });
        const ext = moving.style.ensureExtFallible(app.cx.allocator) catch unreachable;
        ext.inset = .{ .left = .{ .px = if (stage == 1) 340 else 290 }, .top = .{ .px = 48 } };
        moving.markLayoutDirty();
    }
    fn full(_: *@This()) void {
        app.renderer.setRetainedEnabled(false);
        mode_label.setText(.{ .content = "full", .font_size = 12, .color = app.cx.tokens.tokens.color.fg_secondary });
    }
    fn retained(_: *@This()) void {
        app.renderer.setRetainedEnabled(true);
        mode_label.setText(.{ .content = "retained", .font_size = 12, .color = app.cx.tokens.tokens.color.fg_secondary });
    }
};

pub fn open() void {
    visible.set(true);
}

pub fn mount(owner: *App, cx: *ui.Cx, scope: *ui.Scope) !void {
    app = owner;
    visible = try scope.createSignal(bool, false);
    // Compare retained and full pixels at the same fixed transform. Opening
    // animation timing is covered separately from this cache correctness fixture.
    const modal = try ui.widgets.Modal(.{ .title = "Retained pixel contract", .width = 520, .open = visible, .enter_transition = .none, .exit_transition = .none }).mount(scope, cx);
    if (!modal.portaled) try cx.root.?.appendChild(cx.allocator, modal.overlay);
    modal.dialog.meta.ownership.meta.test_id = "retained.dialog";
    const actions = try cx.bindState(Actions, .{});
    const controls = try ui.box(cx, .{ .width = .{ .grow = .{} }, .height = .{ .px = 34 }, .direction = .row, .gap = 8 }, .{});
    try modal.body.appendChild(cx.allocator, controls);
    const next = try ui.widgets.Button(.{ .label = "Change pixels", .on_click = cx.on(Actions, actions, Actions.next) }).mount(scope, cx);
    next.meta.ownership.meta.test_id = "retained.change";
    try controls.appendChild(cx.allocator, next);
    const full = try ui.widgets.Button(.{ .label = "Full", .on_click = cx.on(Actions, actions, Actions.full) }).mount(scope, cx);
    full.meta.ownership.meta.test_id = "retained.full";
    try controls.appendChild(cx.allocator, full);
    const retained = try ui.widgets.Button(.{ .label = "Retained", .on_click = cx.on(Actions, actions, Actions.retained) }).mount(scope, cx);
    retained.meta.ownership.meta.test_id = "retained.enable";
    try controls.appendChild(cx.allocator, retained);
    mode_label = try ui.text(cx, "retained", .{ .font_size = 12, .color = cx.tokens.tokens.color.fg_secondary });
    mode_label.meta.ownership.meta.test_id = "retained.mode";
    try modal.body.appendChild(cx.allocator, mode_label);
    sample = try ui.box(cx, .{ .width = .{ .px = 450 }, .height = .{ .px = 100 }, .background = ui.Color.rgba(220, 30, 70, 150), .corner_radius = 16, .position = .relative }, .{});
    sample.meta.ownership.meta.test_id = "retained.sample";
    try modal.body.appendChild(cx.allocator, sample);
    label = try ui.text(cx, "Long retained text: glyphs 中文", .{ .font_size = 20, .color = ui.Color.WHITE });
    try sample.appendChild(cx.allocator, label);
    moving = try ui.box(cx, .{ .position = .absolute, .width = .{ .px = 60 }, .height = .{ .px = 36 }, .background = ui.Color.rgba(255, 220, 20, 128), .corner_radius = 8 }, .{});
    (try moving.style.ensureExtFallible(cx.allocator)).inset = .{ .left = .{ .px = 290 }, .top = .{ .px = 48 } };
    try sample.appendChild(cx.allocator, moving);
}
