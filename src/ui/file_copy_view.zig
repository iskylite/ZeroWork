//! V2 Bridge 342:1091861: explicit, frozen cross-card copy confirmation.
const std = @import("std");
const ui = @import("ui");
const Files = @import("file_workspace_view.zig");
const C = @import("../host/file_workspace_controller.zig");
const S = @import("file_workspace_styles.zig");
const M = @import("file_mkdir_styles.zig");
pub const Options = struct { resume_transfer: bool = true, md5_check: bool = false };
pub const Submit = *const fn (?*anyopaque, C.FrozenTransfer, Options) anyerror!void;
const Frozen = struct { arena: std.heap.ArenaAllocator, intent: C.FrozenTransfer };
pub const View = struct {
    cx: *ui.Cx,
    pane: *Files.Pane,
    context: ?*anyopaque,
    callback: Submit,
    root: *ui.Node = undefined,
    heading: *ui.Node = undefined,
    source: *ui.Node = undefined,
    target: *ui.Node = undefined,
    feedback: *ui.Node = undefined,
    confirm: *ui.Node = undefined,
    confirm_icon: *ui.Signal(?ui.SvgAsset),
    resume_value: *ui.Signal(bool),
    md5_value: *ui.Signal(bool),
    frozen: ?Frozen = null,
    shown: bool = false,
    pub fn mount(cx: *ui.Cx, scope: *ui.Scope, pane: *Files.Pane, context: ?*anyopaque, callback: Submit) !*View {
        const self = try scope.createState(View, .{ .cx = cx, .pane = pane, .context = context, .callback = callback, .confirm_icon = try scope.createSignal(?ui.SvgAsset, ui.icons.arrow_down_to_line), .resume_value = try scope.createSignal(bool, true), .md5_value = try scope.createSignal(bool, false) });
        try scope.onCleanup(View, self, cleanup);
        self.root = try ui.boxStyled(cx, S.copyConfirmation, .{});
        self.root.meta.ownership.meta.test_id = "files.copy.confirmation";
        self.heading = try label(cx, self.root, M.heading, "files.copy.heading", 18);
        self.source = try label(cx, self.root, M.path, "files.copy.source", 16);
        self.target = try label(cx, self.root, M.path, "files.copy.target", 16);
        const options = try ui.box(cx, S.line(20), .{});
        try self.root.appendChild(cx.allocator, options);
        const resume_box = try ui.widgets.Checkbox(.{ .checked = self.resume_value, .label = "断点续传", .box_size = @as(f32, 14), .label_font_size = @as(f32, 10.5) }).mount(scope, cx);
        resume_box.meta.ownership.meta.test_id = "files.copy.resume";
        try options.appendChild(cx.allocator, resume_box);
        const md5_box = try ui.widgets.Checkbox(.{ .checked = self.md5_value, .label = "MD5 校验", .box_size = @as(f32, 14), .label_font_size = @as(f32, 10.5) }).mount(scope, cx);
        md5_box.meta.ownership.meta.test_id = "files.copy.md5";
        try options.appendChild(cx.allocator, md5_box);
        const spacer = try ui.box(cx, .{ .flex = 1 }, .{});
        try options.appendChild(cx.allocator, spacer);
        const policy = try ui.textStyled(cx, S.secondary, "同名先询问");
        try options.appendChild(cx.allocator, policy);
        const actions = try ui.box(cx, S.line(30), .{});
        try self.root.appendChild(cx.allocator, actions);
        self.feedback = try ui.textStyled(cx, S.secondary, "");
        self.feedback.setStyleInline(cx.allocator, .{ .flex = 1, .min_width = 0, .overflow = .hidden });
        try actions.appendChild(cx.allocator, self.feedback);
        const cancel = try ui.widgets.Button(.{ .variant = .ghost, .icon_only = true, .icon_asset = ui.icons.x, .icon_size = @as(f32, 16), .a11y_label = "取消传输", .base_style = M.button(), .on_click = cx.on(View, self, dismiss) }).mount(scope, cx);
        cancel.meta.ownership.meta.test_id = "files.copy.cancel";
        try actions.appendChild(cx.allocator, cancel);
        self.confirm = try ui.widgets.Button(.{ .variant = .ghost, .icon_only = true, .icon_asset = self.confirm_icon, .icon_size = @as(f32, 16), .a11y_label = "确认传输", .base_style = M.button(), .on_click = cx.on(View, self, submit) }).mount(scope, cx);
        self.confirm.meta.ownership.meta.test_id = "files.copy.submit";
        try actions.appendChild(cx.allocator, self.confirm);
        try pane.root.appendChild(cx.allocator, self.root);
        self.root.setDisplay(.none);
        return self;
    }
    pub fn open(self: *View, intent: C.FrozenTransfer, defaults: Options) !void {
        if (self.shown) return error.CopyConfirmationAlreadyOpen;
        var arena = std.heap.ArenaAllocator.init(self.cx.allocator);
        errdefer arena.deinit();
        const a = arena.allocator();
        var frozen = intent;
        frozen.source.directory = try a.dupe(u8, intent.source.directory);
        frozen.destination.directory = try a.dupe(u8, intent.destination.directory);
        const paths = try a.alloc([]const u8, intent.paths.len);
        for (paths, intent.paths) |*path, original| path.* = try a.dupe(u8, original);
        frozen.paths = paths;
        if (self.frozen) |*old| old.arena.deinit();
        self.frozen = .{ .arena = arena, .intent = frozen };
        self.confirm_icon.set(if (intent.source.endpoint == .local_fs) ui.icons.arrow_up_from_line else ui.icons.arrow_down_to_line);
        self.resume_value.set(defaults.resume_transfer);
        self.md5_value.set(defaults.md5_check);
        var title: [256]u8 = undefined;
        try self.heading.setTextContent(self.cx.allocator, try std.fmt.bufPrint(&title, "{s} {d} 项 · SFTP #{d} · 目标已锁定", .{ if (intent.source.endpoint == .local_fs) @as([]const u8, "上传") else "下载", paths.len, @backingInt(intent.owner.session_id) }));
        var path_buffer: [8192]u8 = undefined;
        try self.source.setTextContent(self.cx.allocator, try std.fmt.bufPrint(&path_buffer, "源 {s} · {d} 项", .{ frozen.source.directory, paths.len }));
        try self.target.setTextContent(self.cx.allocator, try std.fmt.bufPrint(&path_buffer, "目标 {s}", .{frozen.destination.directory}));
        try self.feedback.setTextContent(self.cx.allocator, "");
        self.shown = true;
        self.root.setDisplay(.flex);
        self.cx.requestRedraw();
    }
    pub fn dismiss(self: *View) void {
        self.shown = false;
        self.root.setDisplay(.none);
        self.cx.requestRedraw();
    }
    fn submit(self: *View) void {
        if (!self.shown) return;
        const frozen = self.frozen orelse return;
        self.callback(self.context, frozen.intent, .{ .resume_transfer = self.resume_value.peek(), .md5_check = self.md5_value.peek() }) catch |err| {
            self.feedback.setTextContent(self.cx.allocator, @errorName(err)) catch {};
            self.cx.requestRedraw();
            return;
        };
        self.dismiss();
    }
    fn cleanup(self: *View) void {
        if (self.frozen) |*frozen| frozen.arena.deinit();
    }
};
fn label(cx: *ui.Cx, parent: *ui.Node, comptime styled: fn (*const ui.ThemeTokens) ui.TextStyle, id: []const u8, height: f32) !*ui.Node {
    const node = try ui.textStyled(cx, styled, "");
    node.meta.ownership.meta.test_id = id;
    node.setStyleInline(cx.allocator, .{ .width = .fill(), .min_width = 0, .height = .{ .px = height }, .flex_shrink = 0, .overflow = .hidden });
    try parent.appendChild(cx.allocator, node);
    return node;
}
