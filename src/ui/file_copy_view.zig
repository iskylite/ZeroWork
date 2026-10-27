//! V3 transfer confirmation: frozen source/target, native Modal with explicit actions.
const std = @import("std");
const ui = @import("ui");
const Files = @import("file_workspace_view.zig");
const C = @import("../host/file_workspace_controller.zig");
const S = @import("file_workspace_styles.zig");
const M = @import("file_mkdir_styles.zig");
const V3 = @import("file_copy_styles.zig");
pub const Options = struct { resume_transfer: bool = true, md5_check: bool = false };
pub const Submit = *const fn (?*anyopaque, C.FrozenTransfer, Options) anyerror!void;
const Frozen = struct { arena: std.heap.ArenaAllocator, intent: C.FrozenTransfer };
pub const View = struct {
    cx: *ui.Cx,
    pane: *Files.Pane,
    context: ?*anyopaque,
    callback: Submit,
    root: *ui.Node = undefined,
    overlay: *ui.Node = undefined,
    open_value: *ui.Signal(bool),
    heading: *ui.Node = undefined,
    heading_icon: *ui.Node = undefined,
    subtitle: *ui.Node = undefined,
    filename: *ui.Node = undefined,
    summary: *ui.Node = undefined,
    source_caption: *ui.Node = undefined,
    target_caption: *ui.Node = undefined,
    primary_label: *ui.Signal([]const u8),
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
        const self = try scope.createState(View, .{ .cx = cx, .pane = pane, .context = context, .callback = callback, .open_value = try scope.createSignal(bool, false), .primary_label = try scope.createText("开始上传", .{}), .confirm_icon = try scope.createSignal(?ui.SvgAsset, ui.icons.arrow_down_to_line), .resume_value = try scope.createSignal(bool, true), .md5_value = try scope.createSignal(bool, false) });
        try scope.onCleanup(View, self, cleanup);
        const modal = try ui.widgets.Modal(.{ .open = self.open_value, .width = @as(f32, 480), .max_height = @as(f32, 420), .close_on_overlay = false, .on_open_change = cx.on(View, self, openChanged) }).mount(scope, cx);
        self.overlay = modal.overlay;
        self.overlay.meta.ownership.meta.test_id = "files.copy.overlay";
        self.root = modal.body;
        self.root.setStyleInline(cx.allocator, V3.root());
        modal.dialog.setStyleInline(cx.allocator, .{ .padding = ui.Padding.all(0), .height = .{ .fit = .{} }, .background = S.theme.current().overlay, .border = .{ .radius = 14 } });
        if (!modal.portaled) try pane.root.appendChild(cx.allocator, modal.overlay);
        self.root.meta.ownership.meta.test_id = "files.copy.confirmation";
        const header = try ui.box(cx, V3.header(), .{});
        try self.root.appendChild(cx.allocator, header);
        const title_column = try ui.box(cx, .{ .width = .fill(), .flex = 1, .height = .{ .px = 42 }, .direction = .column, .gap = 4, .min_width = 0 }, .{});
        try header.appendChild(cx.allocator, title_column);
        const heading_row = try ui.box(cx, .{ .width = .fill(), .height = .{ .px = 22 }, .direction = .row, .align_items = .center, .gap = 8 }, .{});
        try title_column.appendChild(cx.allocator, heading_row);
        self.heading_icon = try ui.iconTint(cx, ui.icons.arrow_up_from_line, V3.theme.current().accent, .{ .width = .{ .px = 18 }, .height = .{ .px = 18 }, .flex_shrink = 0 });
        self.heading_icon.meta.ownership.meta.test_id = "files.copy.heading.icon";
        try heading_row.appendChild(cx.allocator, self.heading_icon);
        self.heading = try v3Label(cx, heading_row, "", 15, 600, false, "files.copy.heading", 22);
        self.subtitle = try v3Label(cx, title_column, "", 11, 400, true, "files.copy.subtitle", 16);
        const close = try ui.widgets.Button(.{ .variant = .ghost, .icon_only = true, .icon_asset = ui.icons.x, .icon_size = @as(f32, 14), .a11y_label = "关闭传输确认", .base_style = M.button(), .on_click = cx.on(View, self, dismiss) }).mount(scope, cx);
        close.meta.ownership.meta.test_id = "files.copy.close";
        try header.appendChild(cx.allocator, close);
        const body = try ui.box(cx, V3.body(), .{});
        try self.root.appendChild(cx.allocator, body);
        const summary = try ui.box(cx, V3.summary(), .{});
        try body.appendChild(cx.allocator, summary);
        try summary.appendChild(cx.allocator, try ui.iconTint(cx, ui.icons.files, V3.theme.current().accent, .{ .width = .{ .px = 24 }, .height = .{ .px = 24 }, .flex_shrink = 0 }));
        const summary_text = try ui.box(cx, .{ .width = .fill(), .flex = 1, .height = .{ .px = 32 }, .direction = .column, .gap = 2, .min_width = 0 }, .{});
        try summary.appendChild(cx.allocator, summary_text);
        self.filename = try v3Label(cx, summary_text, "", 12, 500, false, "files.copy.filename", 16);
        self.summary = try v3Label(cx, summary_text, "", 10.5, 400, true, "files.copy.summary", 14);
        self.source = try self.pathField(body, &self.source_caption, "files.copy.source");
        self.target = try self.pathField(body, &self.target_caption, "files.copy.target");
        const options = try ui.box(cx, V3.row(24, 20), .{});
        try body.appendChild(cx.allocator, options);
        const resume_box = try ui.widgets.Checkbox(.{ .checked = self.resume_value, .label = "断点续传", .box_size = @as(f32, 14), .label_font_size = @as(f32, 11) }).mount(scope, cx);
        resume_box.meta.ownership.meta.test_id = "files.copy.resume";
        try options.appendChild(cx.allocator, resume_box);
        const md5_box = try ui.widgets.Checkbox(.{ .checked = self.md5_value, .label = "完成后校验 MD5", .box_size = @as(f32, 14), .label_font_size = @as(f32, 11) }).mount(scope, cx);
        md5_box.meta.ownership.meta.test_id = "files.copy.md5";
        try options.appendChild(cx.allocator, md5_box);
        _ = try v3Label(cx, body, "遇到同名文件时，先询问再处理。", 11, 400, true, "files.copy.policy", 16);
        const actions = try ui.box(cx, V3.footer(), .{});
        try self.root.appendChild(cx.allocator, actions);
        self.feedback = try v3Label(cx, actions, "", 10.5, 400, true, "files.copy.feedback", 16);
        self.feedback.setStyleInline(cx.allocator, .{ .flex = 1, .min_width = 0 });
        const cancel = try ui.widgets.Button(.{ .label = "取消", .variant = .secondary, .base_style = V3.button(false), .on_click = cx.on(View, self, dismiss) }).mount(scope, cx);
        cancel.meta.ownership.meta.test_id = "files.copy.cancel";
        try actions.appendChild(cx.allocator, cancel);
        self.confirm = try ui.widgets.Button(.{ .label = self.primary_label, .variant = .primary, .icon_asset = self.confirm_icon, .icon_size = @as(f32, 14), .base_style = V3.button(true), .on_click = cx.on(View, self, submit) }).mount(scope, cx);
        self.confirm.meta.ownership.meta.test_id = "files.copy.submit";
        try actions.appendChild(cx.allocator, self.confirm);
        return self;
    }
    pub fn open(self: *View, intent: C.FrozenTransfer, defaults: Options) !void {
        if (self.shown) return error.CopyConfirmationAlreadyOpen;
        if (intent.paths.len == 0) return error.NoFilesSelected;
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
        const upload = intent.source.endpoint == .local_fs;
        const heading_asset = if (upload) ui.icons.arrow_up_from_line else ui.icons.arrow_down_to_line;
        if (heading_asset.icon_id) |id| if (heading_asset.pickRep(18)) |rep| self.heading_icon.setIcon(.{ .icon_id = id, .rep = rep, .tint = V3.theme.current().accent });
        try self.heading.setTextContent(self.cx.allocator, if (upload) "上传文件" else "下载文件");
        try self.subtitle.setTextContent(self.cx.allocator, if (upload) "本地文件 → 远端目录" else "远端文件 → 本地保存目录");
        self.primary_label.set(if (upload) "开始上传" else "开始下载");
        var title: [8192]u8 = undefined;
        const name = std.fs.path.basename(paths[0]);
        try self.filename.setTextContent(self.cx.allocator, if (paths.len == 1) name else try std.fmt.bufPrint(&title, "{s} 等 {d} 个项目", .{ name, paths.len }));
        try self.summary.setTextContent(self.cx.allocator, try std.fmt.bufPrint(&title, "已选择 {d} 项 · SFTP #{d}", .{ paths.len, @backingInt(intent.owner.session_id) }));
        try self.source_caption.setTextContent(self.cx.allocator, if (upload) "本地来源目录" else "远端来源目录");
        try self.target_caption.setTextContent(self.cx.allocator, if (upload) "远端目标目录" else "本地保存目录");
        try self.source.setTextContent(self.cx.allocator, frozen.source.directory);
        try self.target.setTextContent(self.cx.allocator, frozen.destination.directory);
        try self.feedback.setTextContent(self.cx.allocator, "");
        self.shown = true;
        self.pane.view.confirmation_open.set(true);
        self.open_value.set(true);
        self.cx.requestRedraw();
    }
    pub fn dismiss(self: *View) void {
        self.shown = false;
        self.pane.view.confirmation_open.set(false);
        self.open_value.set(false);
        self.cx.requestRedraw();
    }
    fn pathField(self: *View, parent: *ui.Node, caption: **ui.Node, id: []const u8) !*ui.Node {
        const field = try ui.box(self.cx, V3.field(), .{});
        try parent.appendChild(self.cx.allocator, field);
        caption.* = try v3Label(self.cx, field, "", 11, 500, true, "files.copy.field.label", 16);
        const well = try ui.box(self.cx, V3.path(), .{});
        try field.appendChild(self.cx.allocator, well);
        const value = try v3Label(self.cx, well, "", 11, 400, false, id, 16);
        if (value.getText()) |props| { var next = props; next.use_monospace_font = true; next.text_overflow = .ellipsis_smart; value.setText(next); }
        return value;
    }
    fn openChanged(self: *View, value: bool) void { if (!value) self.dismiss(); }
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
fn v3Label(cx: *ui.Cx, parent: *ui.Node, value: []const u8, size: f32, weight: u16, secondary: bool, id: []const u8, height: f32) !*ui.Node {
    const node = try ui.text(cx, "", V3.text(size, weight, secondary));
    try node.setTextContent(cx.allocator, value);
    node.meta.ownership.meta.test_id = id;
    node.setStyleInline(cx.allocator, .{ .width = .fill(), .min_width = 0, .height = .{ .px = height }, .flex_shrink = 0, .overflow = .hidden, .overflow_hidden = true });
    try parent.appendChild(cx.allocator, node);
    return node;
}
