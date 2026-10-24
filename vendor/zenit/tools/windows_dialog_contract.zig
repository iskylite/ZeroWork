const std = @import("std");
const ui = @import("ui");
const App = @import("zenit_app").App;
const Kind = enum { open_file, save_file, pick_folder };
const State = struct {
    app: *App,
    root: *ui.Node,
    status: *ui.Node,
    directory: []const u8,
    pending: ?Kind = null,
    short_buffer: bool = false,
    fn queue(self: *@This(), kind: Kind, small_buffer: bool) void {
        self.pending = kind;
        self.short_buffer = small_buffer;
        self.app.cx.needs_redraw = true;
    }
    pub fn open(self: *@This()) void {
        self.queue(.open_file, false);
    }
    pub fn save(self: *@This()) void {
        self.queue(.save_file, false);
    }
    pub fn folder(self: *@This()) void {
        self.queue(.pick_folder, false);
    }
    pub fn short(self: *@This()) void {
        self.queue(.open_file, true);
    }
    fn report(self: *@This(), text: []const u8) void {
        const owned = self.app.cx.allocator.dupe(u8, text) catch @panic("dialog status allocation");
        self.status.setText(.{ .content = owned, .font_size = 14, .color = ui.Color.WHITE });
    }
};
fn draw(_: ui.DrawContext, context: ?*anyopaque) anyerror!void {
    const state: *State = @ptrCast(@alignCast(context orelse return));
    const kind = state.pending orelse return;
    state.pending = null;
    // Defer until after the harness publishes the click response. This is a
    // genuinely blocking SDK dialog, not a simulated harness route.
    const a = state.app.cx.allocator;
    const io = state.app.cx.io;
    try std.Io.Dir.cwd().createDirPath(io, state.directory);
    const input = try std.fmt.allocPrint(a, "{s}\\输入-🧪.txt", .{state.directory});
    defer a.free(input);
    const file = try std.Io.Dir.cwd().createFile(io, input, .{});
    try file.writeStreamingAll(io, "Zenit native dialog fixture\n");
    file.close(io);
    const folder = try std.fmt.allocPrint(a, "{s}\\文件夹", .{state.directory});
    defer a.free(folder);
    try std.Io.Dir.cwd().createDirPath(io, folder);
    var buffer: [65536]u8 = undefined;
    const picked = state.app.sdk.runDialog(.{
        .kind = switch (kind) {
            .open_file => .open_file,
            .save_file => .save_file,
            .pick_folder => .pick_folder,
        },
        .title = if (kind == .save_file) "保存-🧪.txt" else "Zenit native dialog acceptance",
        .default_path = if (kind == .pick_folder) folder else state.directory,
    }, buffer[0..if (state.short_buffer) 8 else buffer.len]) catch |err| {
        state.report(@errorName(err));
        return;
    };
    state.report(picked orelse "cancelled");
}
pub fn mount(app: *App, scope: *ui.Scope, cx: *ui.Cx) !*ui.Node {
    const root = try ui.box(cx, .{ .display = .none, .width = .{ .grow = .{} }, .height = .{ .px = 180 }, .direction = .column, .gap = 12 }, .{});
    const status = try ui.text(cx, "ready", .{ .font_size = 14, .color = ui.Color.WHITE });
    status.meta.ownership.meta.test_id = "dialog.status";
    const exe_dir = try std.process.executableDirPathAlloc(cx.io, cx.allocator);
    defer cx.allocator.free(exe_dir);
    const directory = try std.fmt.allocPrint(cx.allocator, "{s}\\dialog-fixtures", .{exe_dir});
    const state = try cx.bindState(State, .{ .app = app, .root = root, .status = status, .directory = directory });
    root.setCustomDraw(draw, state);
    const path = try ui.text(cx, directory, .{ .font_size = 12, .color = ui.Color.WHITE });
    path.meta.ownership.meta.test_id = "dialog.directory";
    try root.appendChild(cx.allocator, path);
    const row = try ui.box(cx, .{ .width = .{ .grow = .{} }, .height = .{ .px = 40 }, .direction = .row, .gap = 12 }, .{});
    try root.appendChild(cx.allocator, row);
    inline for (.{ .{ "dialog.open", "Open", State.open }, .{ "dialog.save", "Save", State.save }, .{ "dialog.folder", "Folder", State.folder }, .{ "dialog.short", "Short buffer", State.short } }) |spec| {
        const button = try ui.widgets.Button(.{ .label = spec[1], .on_click = cx.on(State, state, spec[2]) }).mount(scope, cx);
        button.meta.ownership.meta.test_id = spec[0];
        try row.appendChild(cx.allocator, button);
    }
    try root.appendChild(cx.allocator, status);
    return root;
}
