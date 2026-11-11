const std = @import("std");
const ui = @import("ui");
const model = @import("model.zig");
const Store = @import("store.zig").Store;
const S = @import("styles.zig");

pub const Settings = struct {
    cx: *ui.Cx,
    store: *Store,
    changed: ui.Handler(void),
    popup: ui.widgets.popover.PopoverResult = undefined,
    anchor: ?ui.hit.NodeHandle = null,
    library: ?model.LibraryId = null,
    revision: u64 = 0,
    open: *ui.Signal(bool),
    name: *ui.Signal([]const u8),
    checked: *ui.Signal(bool),
    name_input: *ui.Node = undefined,
    problem: *ui.Node = undefined,

    pub fn mount(cx: *ui.Cx, scope: *ui.Scope, store: *Store, changed: ui.Handler(void)) !*Settings {
        const self = try scope.createState(Settings, .{
            .cx = cx,
            .store = store,
            .changed = changed,
            .open = try scope.createSignal(bool, false),
            .name = try scope.createText("", .{}),
            .checked = try scope.createSignal(bool, false),
        });
        self.popup = try ui.widgets.Popover(.{
            .open = ui.split(self.open, cx.on(Settings, self, openChanged)),
            .trigger = .manual,
            .anchor = .{ .virtual = .{ .ctx = self, .getRect = anchorRect } },
            .position = .left_start,
            .width = @as(f32, 352),
            .max_width = @as(f32, 352),
            .constrain_width_to_viewport = true,
            .shift_main_axis = true,
            .offset = .{ .static = 12 },
            .size_policy = .fit_content,
            .enter_transition = .none,
            .exit_transition = .none,
        }).mount(scope, cx);
        self.popup.chrome.meta.ownership.meta.test_id = "notes.library.settings.popover";
        const stack = try ui.box(cx, S.stack(14), .{});
        stack.setStyleInline(cx.allocator, .{ .padding = ui.Padding.all(20) });
        try self.popup.content.appendChild(cx.allocator, stack);
        const header = try ui.box(cx, S.row(28, 6), .{});
        const heading = try ui.text(cx, "目录设置", S.text(15, 650, S.theme.current().fg_1));
        heading.setStyleInline(cx.allocator, .{ .width = .fill() });
        try header.appendChild(cx.allocator, heading);
        const close = try ui.widgets.Button(.{
            .variant = .ghost,
            .icon_only = true,
            .icon_asset = ui.icons.x,
            .a11y_label = "关闭",
            .base_style = S.tool(),
            .on_click = cx.on(Settings, self, closeClick),
        }).mount(scope, cx);
        close.meta.ownership.meta.test_id = "notes.settings.close";
        try header.appendChild(cx.allocator, close);
        try stack.appendChild(cx.allocator, header);

        const name = try ui.widgets.Input(.{
            .value = self.name,
            .label_text = "名称",
            .growable = true,
            .on_submit = cx.on(Settings, self, submit),
        }).mountResult(scope, cx);
        self.name_input = name.input_container;
        self.name_input.meta.ownership.meta.test_id = "notes.settings.name";
        try stack.appendChild(cx.allocator, name.node);

        const row = try ui.box(cx, S.row(30, 8), .{});
        const label = try ui.text(cx, "允许 AI 读取", S.text(13, 550, S.theme.current().fg_1));
        label.setStyleInline(cx.allocator, .{ .width = .fill() });
        try row.appendChild(cx.allocator, label);
        const toggle = try ui.widgets.Switch(.{
            .checked = self.checked,
            .on_change = cx.on(Settings, self, permissionChanged),
        }).mount(scope, cx);
        toggle.meta.ownership.meta.test_id = "notes.settings.ai-toggle";
        if (toggle.behavior.interaction.a11y) |*a11y| {
            a11y.label = "允许 AI 读取";
            a11y.description = "相关内容会发送给当前 AI 模型";
        }
        const tooltip = try ui.widgets.Tooltip(.{ .text = "相关内容会发送给当前 AI 模型" }).mount(scope, cx);
        try tooltip.trigger.appendChild(cx.allocator, toggle);
        try row.appendChild(cx.allocator, tooltip.wrapper);
        try stack.appendChild(cx.allocator, row);

        self.problem = try ui.text(cx, "", S.text(12, 400, S.theme.current().warn_ink));
        self.problem.setDisplay(.none);
        try stack.appendChild(cx.allocator, self.problem);
        return self;
    }

    pub fn show(self: *Settings, library_id: model.LibraryId, anchor: ui.hit.NodeHandle) !void {
        if (self.open.peek()) try self.commit();
        var library = try self.store.loadLibrary(self.cx.allocator, library_id, .active);
        defer library.deinit();
        self.anchor = anchor;
        self.library = library_id;
        self.revision = library.value.revision;
        self.name.set(library.value.name);
        self.checked.set(library.value.ai_readable);
        self.problem.setDisplay(.none);
        self.open.set(true);
        self.cx.requestRedraw();
    }

    pub fn commit(self: *Settings) !void {
        const library = self.library orelse return;
        self.revision = self.store.changeLibrary(library, self.revision, .{ .rename = self.name.peek() }) catch |err| {
            self.showError(err);
            return err;
        };
        self.open.set(false);
        self.library = null;
        self.changed.invoke();
    }

    pub fn dismiss(self: *Settings) void {
        self.open.set(false);
        self.library = null;
    }

    fn permissionChanged(self: *Settings, enabled: bool) void {
        const library = self.library orelse return;
        self.revision = self.store.changeLibrary(library, self.revision, .{ .ai_readable = enabled }) catch |err| {
            self.checked.set(!enabled);
            self.showError(err);
            return;
        };
        self.problem.setDisplay(.none);
    }

    fn openChanged(self: *Settings, value: bool) void {
        if (!value) self.commit() catch {};
    }

    fn submit(self: *Settings, _: []const u8) void {
        self.commit() catch {};
    }

    fn closeClick(self: *Settings) void {
        self.commit() catch {};
    }

    fn showError(self: *Settings, err: anyerror) void {
        const text = switch (err) {
            error.InvalidName => "请输入有效的目录名称",
            error.NameTooLong => "目录名称超过长度限制",
            error.NameConflict => "已存在同名目录",
            error.ProtectedDocument => "此目录包含只读文档",
            error.RevisionChanged => "目录已更新，请重新打开设置",
            else => "设置保存失败",
        };
        self.problem.setTextContent(self.cx.allocator, text) catch {};
        self.problem.setDisplay(.flex);
        self.cx.requestRedraw();
    }

    fn anchorRect(raw: *anyopaque) ui.widgets.popover.AnchorRect {
        const self: *Settings = @ptrCast(@alignCast(raw));
        const node = self.cx.node_registry.resolve(self.anchor, null) orelse return .{ .x = 0, .y = 0, .w = 0, .h = 0 };
        const r = node.globalRect();
        return .{ .x = r.x, .y = r.y, .w = r.w, .h = r.h };
    }
};
