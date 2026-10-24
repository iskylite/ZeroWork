//! Explicit native component fixture only. No SSH/local directory service,
//! PTY, transfer job, credentials or primary-application entry is created.
const std = @import("std");
const ui = @import("ui");
const App = @import("zenit_app").App;
const files = @import("ui/file_workspace_view.zig");
const theme = @import("ui/app_theme.zig");
const FixtureState = enum { normal, empty, failed };
var selected_state: FixtureState = .normal;
const owner = @import("host/identity.zig").SessionHandle{ .session_id = @fromBackingInt(301), .generation = 7 };
const Fixture = struct {
    view: *files.View,
    fn action(raw: *anyopaque, envelope: files.Envelope) !void {
        const self: *Fixture = @ptrCast(@alignCast(raw));
        if (envelope.action != .selection) return error.FixtureHasNoDirectoryService;
        var projection = self.view.source.?.value;
        projection.revision += 1;
        const pane = &projection.panes[@backingInt(envelope.side)];
        pane.selection_revision += 1;
        pane.selected_keys = envelope.action.selection.keys;
        pane.anchor = envelope.action.selection.anchor;
        pane.focused_key = envelope.action.selection.focused_key;
        try self.view.update(projection);
    }
};
fn mount(cx: *ui.Cx, scope: *ui.Scope) !*ui.Node {
    theme.select(.dark);
    cx.setTheme(theme.widgetTheme(.dark));
    const fixture = try scope.createState(Fixture, .{ .view = undefined });
    fixture.view = try files.View.mount(cx, scope, .{ .context = fixture, .action = Fixture.action });
    const rows = try scope.createState([48]files.Entry, undefined);
    for (rows, 0..) |*entry, i| {
        var name_buffer: [128]u8 = undefined;
        const name = if (i == 0) ".." else if (i == 1) "fixtures" else if (i == 4) try std.fmt.bufPrint(&name_buffer, "deployment-fixture-with-a-long-name-for-native-layout-{d}.yaml", .{i}) else try std.fmt.bufPrint(&name_buffer, "native-fixture-{d:0>3}.txt", .{i});
        const owned_name = try scope.createText(name, .{});
        const path = try std.fmt.allocPrint(cx.allocator, "/fixtures/local/{s}", .{name});
        defer cx.allocator.free(path);
        const owned_path = try scope.createText(path, .{});
        entry.* = .{ .absolute_path = owned_path.peek(), .raw_name = owned_name.peek(), .display_name = owned_name.peek(), .kind = if (i < 2) .directory else .file, .size = if (i == 3 or i == 4) 0 else if (i == 5) null else i * 1024, .modified_label = "2026-10-20 09:12", .modified_full = "2026-10-20T09:12:00+08:00" };
    }
    const remote_rows = try scope.createState([12]files.Entry, undefined);
    for (remote_rows, rows[0..12]) |*entry, local| {
        const path = try std.fmt.allocPrint(cx.allocator, "/fixtures/remote/{s}", .{local.raw_name});
        defer cx.allocator.free(path);
        const owned_path = try scope.createText(path, .{});
        entry.* = local;
        entry.absolute_path = owned_path.peek();
    }
    var projection: files.Projection = .{ .revision = 1, .owner = owner, .panes = .{
        .{ .stamp = .{ .owner = owner, .endpoint = .{ .kind = .local_fs, .binding_id = 1, .binding_generation = 1 }, .request_id = 1, .directory_revision = 1 }, .title = "本地 · UI Fixture", .subtitle = "本机文件", .badge = "本地", .resolved_path = "/fixtures/local/", .entries = rows, .writable = true, .can_transfer = true },
        .{ .stamp = .{ .owner = owner, .endpoint = .{ .kind = .sftp, .binding_id = 7, .binding_generation = 2 }, .request_id = 1, .directory_revision = 1 }, .title = "远程 · UI Fixture", .subtitle = "SFTP · #301", .badge = "SFTP #301", .resolved_path = "/fixtures/remote/", .entries = remote_rows, .writable = true, .can_transfer = true },
    } };
    try fixture.view.update(projection);
    if (selected_state != .normal) {
        _ = try fixture.view.flush();
        projection.revision += 1;
        projection.panes[1].stamp.request_id += 1;
        projection.panes[1].entries = &.{};
        projection.panes[1].state = if (selected_state == .empty) .empty else .failed;
        projection.panes[1].failure = if (selected_state == .failed) "Connection lost" else "";
        try fixture.view.update(projection);
    }
    const backdrop = try ui.box(cx, .{ .width = .fill(), .height = .fill(), .background = theme.current().app }, .{});
    try backdrop.appendChild(cx.allocator, fixture.view.root);
    return backdrop;
}
pub fn main(init: std.process.Init) !void {
    var args = init.minimal.args.iterate();
    _ = args.next();
    while (args.next()) |arg| {
        if (!std.mem.startsWith(u8, arg, "--state=")) return error.InvalidFixtureArgument;
        selected_state = std.meta.stringToEnum(FixtureState, arg[8..]) orelse return error.InvalidFixtureState;
    }
    const app = try App.init(std.heap.c_allocator, .{ .io = init.io, .window = .{ .width = 1194, .height = 794, .min_width = 790, .min_height = 374, .title = "ZeroWork · Files Component Fixture", .titlebar = .custom_inset, .titlebar_height = 0, .hide_native_controls = true } });
    defer app.deinit();
    try app.runWith(mount);
}
