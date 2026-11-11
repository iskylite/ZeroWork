const std = @import("std");
const ui = @import("ui");
const scoped_modal = @import("../../ui/scoped_modal.zig");
const model = @import("model.zig");
const Store = @import("store.zig").Store;
const S = @import("styles.zig");

pub const Directory = @import("editor_search.zig").Directory;
pub const Target = union(enum) {
    directory: Directory,
    note: model.NoteKey,

    pub fn library(self: Target) model.LibraryId {
        return switch (self) {
            .directory => |value| value.library,
            .note => |value| value.library_id,
        };
    }
};
pub const Request = union(enum) { rename: Target, move: Target, delete: Target, recent };
pub const Mutation = struct {
    target: Target,
    revision: u64,
    change: union(enum) { rename: []const u8, move: ?model.FolderId, delete, restore: ?[]const u8 },
};
pub const Callbacks = struct {
    context: *anyopaque,
    apply: *const fn (*anyopaque, Mutation) anyerror!void,
};

const Item = struct { target: Target, revision: u64, title: []const u8, path: []const u8, parent: ?model.FolderId, deleted_at: ?i64 };

fn folderPath(a: std.mem.Allocator, library: model.Library, folder: ?model.FolderId) ![]const u8 {
    const id = folder orelse return a.dupe(u8, library.name);
    const entry = library.folders[library.folderIndex(id) orelse return error.Unavailable];
    const parent = try folderPath(a, library, entry.parent_id);
    return std.fmt.allocPrint(a, "{s} / {s}", .{ parent, entry.name });
}

fn capture(a: std.mem.Allocator, store: *Store, target: Target, library: model.Library) !Item {
    switch (target) {
        .directory => |dir| {
            if (dir.folder) |id| {
                const folder = library.folders[library.folderIndex(id) orelse return error.Unavailable];
                return .{ .target = target, .revision = library.revision, .title = try a.dupe(u8, folder.name), .path = try folderPath(a, library, folder.parent_id), .parent = folder.parent_id, .deleted_at = folder.deleted_at };
            }
            return .{ .target = target, .revision = library.revision, .title = try a.dupe(u8, library.name), .path = "", .parent = null, .deleted_at = library.deleted_at };
        },
        .note => |key| {
            var note = try store.loadNote(a, key, .include_deleted);
            defer note.deinit();
            return .{ .target = target, .revision = note.value.revision, .title = try a.dupe(u8, note.value.title), .path = try folderPath(a, library, note.value.folder_id), .parent = note.value.folder_id, .deleted_at = note.value.deleted_at };
        },
    }
}

fn canMove(target: Target, library: model.Library, parent: ?model.FolderId) bool {
    if (!library.folderVisible(parent)) return false;
    if (target != .directory) return true;
    const moving = target.directory.folder orelse return false;
    const destination = parent orelse return true;
    if (destination.eql(moving)) return false;
    if (library.folders[library.folderIndex(destination).?].parent_id != null) return false;
    for (library.folders) |folder| {
        // Deleted children still participate in the persisted hierarchy.
        if (folder.parent_id) |id| if (id.eql(moving)) return false;
    }
    return true;
}

fn suggestName(a: std.mem.Allocator, store: *Store, item: Item) ![]const u8 {
    const root = item.target.directory.folder == null;
    const ids = if (root) try store.listLibraryIds(a, .active) else &.{};
    var names: std.ArrayList([]const u8) = .empty;
    if (root) {
        for (ids) |id| {
            var library = try store.loadLibrary(a, id, .active);
            defer library.deinit();
            try names.append(a, try a.dupe(u8, library.value.name));
        }
    } else {
        var library = try store.loadLibrary(a, item.target.library(), .include_deleted);
        defer library.deinit();
        for (library.value.folders) |folder| {
            if (std.meta.eql(folder.parent_id, item.parent) and library.value.folderVisible(folder.id)) try names.append(a, try a.dupe(u8, folder.name));
        }
    }
    var number: usize = 1;
    while (true) : (number += 1) {
        const suffix = if (number == 1) "（恢复）" else try std.fmt.allocPrint(a, "（恢复 {d}）", .{number});
        const maximum = model.max_directory_name - try std.unicode.utf8CountCodepoints(suffix);
        var iterator = (try std.unicode.Utf8View.init(item.title)).iterator();
        for (0..maximum) |_| _ = iterator.nextCodepointSlice() orelse break;
        const name = try std.mem.concat(a, u8, &.{ item.title[0..iterator.i], suffix });
        for (names.items) |existing| {
            if (std.mem.eql(u8, name, existing)) break;
        } else return name;
    }
}

pub const Manager = struct {
    const Mode = enum { rename, move, delete, recent, restore_name };
    const Intent = union(enum) { confirm, cancel, restore: Item, move: ?model.FolderId };
    cx: *ui.Cx,
    scope: *ui.Scope,
    store: *Store,
    callbacks: Callbacks,
    open: *ui.Signal(bool),
    name: *ui.Signal([]const u8),
    confirm_label: *ui.Signal([]const u8),
    mode: Mode = .recent,
    pending: ?Intent = null,
    item: ?Item = null,
    item_arena: std.heap.ArenaAllocator,
    rows_scope: ?*ui.Scope = null,
    dialog: *ui.Node = undefined,
    heading: *ui.Node = undefined,
    description: *ui.Node = undefined,
    restore_hint: *ui.Node = undefined,
    name_box: *ui.Node = undefined,
    name_input: *ui.Node = undefined,
    list_box: *ui.Node = undefined,
    list: *ui.Node = undefined,
    scroll: ui.widgets.ScrollAreaResult = undefined,
    problem: *ui.Node = undefined,
    confirm: *ui.Node = undefined,
    focus_name: bool = false,

    pub fn mount(cx: *ui.Cx, scope: *ui.Scope, root: *ui.Node, store: *Store, callbacks: Callbacks) !*Manager {
        const self = try scope.createState(Manager, .{
            .cx = cx,
            .scope = scope,
            .store = store,
            .callbacks = callbacks,
            .open = try scope.createSignal(bool, false),
            .name = try scope.createText("", .{}),
            .confirm_label = try scope.createText("", .{}),
            .item_arena = .init(cx.allocator),
        });
        try scope.onCleanup(Manager, self, dispose);
        const colors = S.theme.current();
        const modal = try ui.widgets.Modal(.{
            .open = self.open,
            .width = @as(f32, 420),
            .managed_focus = false,
            .background = colors.overlay,
            .overlay_color = ui.Color.rgba(colors.fg_1.r, colors.fg_1.g, colors.fg_1.b, 26),
            .close_on_overlay = false,
            .enter_transition = .none,
            .exit_transition = .none,
        }).mount(scope, cx);
        self.dialog = modal.dialog;
        modal.dialog.meta.ownership.meta.test_id = "notes.management";
        if (!modal.portaled) try root.appendChild(cx.allocator, modal.overlay);
        const a = cx.allocator;
        modal.dialog.setStyleInline(a, .{ .border = .{ .radius = 14 } });
        modal.body.setStyleInline(a, .{ .padding = ui.Padding.all(24) });
        _ = try scoped_modal.bind(cx, scope, modal, .{ .owner = .{ .node = root } });
        const content = try ui.box(cx, S.stack(12), .{});
        try modal.body.appendChild(a, content);
        self.heading = try ui.text(cx, "", S.text(18, 650, colors.fg_1));
        self.heading.setStyleInline(a, .{ .width = .fill(), .padding = .{ .right = 28 } });
        try content.appendChild(a, self.heading);
        const close = try ui.widgets.Button(.{
            .variant = .ghost,
            .icon_only = true,
            .icon_asset = ui.icons.x,
            .icon_size = @as(f32, 16),
            .a11y_label = "关闭",
            .base_style = S.tool(),
            .on_click = cx.on(Manager, self, cancelClicked),
        }).mount(scope, cx);
        close.setStyleInline(a, .{ .position = .absolute, .inset = .{ .top = .{ .px = 14 }, .right = .{ .px = 16 } } });
        close.meta.ownership.meta.test_id = "notes.management.close";
        try modal.dialog.appendChild(a, close);
        self.description = try ui.text(cx, "", S.text(14, 400, colors.fg_2));
        try content.appendChild(a, self.description);
        const name = try ui.widgets.Input(.{ .value = self.name, .label_text = "名称", .growable = true, .on_submit = cx.on(Manager, self, submitted) }).mountResult(scope, cx);
        self.name_box = name.node;
        self.name_input = name.input_container;
        self.name_input.setStyleInline(a, .{ .height = .{ .px = 38 }, .border = .{ .radius = 7 } });
        try content.appendChild(a, self.name_box);
        self.restore_hint = try ui.text(cx, "不会覆盖现有目录。", S.text(12, 400, colors.fg_3));
        try content.appendChild(a, self.restore_hint);
        self.scroll = try ui.widgets.ScrollArea(.{ .rubber_band_y = false }).mount(scope, cx);
        self.list_box = self.scroll.container;
        self.list_box.setStyleInline(a, .{ .height = .{ .px = 224 }, .flex_shrink = 0 });
        self.list = try ui.box(cx, S.stack(2), .{});
        try self.scroll.content.appendChild(a, self.list);
        try content.appendChild(a, self.list_box);
        self.problem = try ui.text(cx, "", S.text(12, 400, S.theme.current().warn_ink));
        self.problem.meta.ownership.meta.test_id = "notes.management.error";
        try content.appendChild(a, self.problem);
        const footer = try ui.box(cx, S.row(34, 12), .{});
        footer.setStyleInline(a, .{ .justify = .end });
        try content.appendChild(a, footer);
        const button_style: ui.BoxStyle = .{ .width = .{ .px = 80 }, .height = .{ .px = 34 }, .border = .{ .radius = 8 } };
        const cancel = try ui.widgets.Button(.{ .variant = .secondary, .label = "取消", .base_style = button_style, .on_click = cx.on(Manager, self, cancelClicked) }).mount(scope, cx);
        cancel.meta.ownership.meta.test_id = "notes.management.cancel";
        try footer.appendChild(a, cancel);
        self.confirm = try ui.widgets.Button(.{ .variant = .primary, .label = self.confirm_label, .base_style = button_style, .on_click = cx.on(Manager, self, confirmClicked) }).mount(scope, cx);
        try footer.appendChild(a, self.confirm);
        return self;
    }

    pub fn show(self: *Manager, request: Request) !void {
        self.pending = null;
        self.item = null;
        self.clearList();
        _ = self.item_arena.reset(.retain_capacity);
        if (request == .recent) return self.showRecent();
        const target = switch (request) {
            .rename, .move, .delete => |value| value,
            .recent => unreachable,
        };
        var library = try self.store.loadLibrary(self.cx.allocator, target.library(), .active);
        defer library.deinit();
        const a = self.item_arena.allocator();
        const item = try capture(a, self.store, target, library.value);
        if (item.deleted_at != null) return error.Unavailable;
        self.item = item;
        self.name.set(item.title);
        switch (request) {
            .rename => try self.configure(.rename, "重命名目录", "", "保存"),
            .delete => try self.configure(.delete, if (target == .note) "删除文档" else "删除目录", try std.fmt.allocPrint(a, "将「{s}」移至最近删除。", .{item.title}), "删除"),
            .move => {
                try self.configure(.move, "移动到", "", "");
                const scope = try self.replaceList();
                if (item.parent != null and canMove(target, library.value, null)) try self.addRow(scope, library.value.name, .{ .move = null }, "notes.move.destination");
                for (library.value.folders) |folder| {
                    if (std.meta.eql(item.parent, @as(?model.FolderId, folder.id)) or !canMove(target, library.value, folder.id)) continue;
                    try self.addRow(scope, try folderPath(a, library.value, folder.id), .{ .move = folder.id }, "notes.move.destination");
                }
                if (self.list.children.items.len == 0) try self.addEmpty("没有可移动的位置");
            },
            .recent => unreachable,
        }
    }

    pub fn dismiss(self: *Manager) void {
        self.pending = null;
        self.focus_name = false;
        self.open.set(false);
    }

    pub fn tick(self: *Manager) bool {
        if (!self.open.peek()) return false;
        if (self.focus_name) {
            self.focus_name = false;
            self.cx.setFocus(self.name_input);
        }
        const intent = self.pending orelse return false;
        self.pending = null;
        self.handle(intent) catch |err| self.showError(err);
        return true;
    }

    fn configure(self: *Manager, mode: Mode, title: []const u8, description: []const u8, label: []const u8) !void {
        self.mode = mode;
        const restoring = mode == .restore_name;
        self.dialog.meta.ownership.meta.test_id = if (restoring) "notes.restore.conflict" else "notes.management";
        self.name_input.meta.ownership.meta.test_id = if (restoring) "notes.restore.name" else "notes.management.name";
        self.confirm.meta.ownership.meta.test_id = if (restoring) "notes.restore.confirm" else "notes.management.confirm";
        try self.heading.setTextContent(self.cx.allocator, title);
        if (self.dialog.behavior.interaction.a11y) |*a11y| a11y.label = title;
        try self.description.setTextContent(self.cx.allocator, description);
        self.description.setDisplay(if (description.len > 0) .flex else .none);
        self.focus_name = mode == .rename or restoring;
        self.name_box.setDisplay(if (self.focus_name) .flex else .none);
        self.restore_hint.setDisplay(if (restoring) .flex else .none);
        self.list_box.setDisplay(if (mode == .move or mode == .recent) .flex else .none);
        self.confirm_label.set(label);
        self.confirm.setDisplay(if (label.len > 0) .flex else .none);
        self.problem.setDisplay(.none);
        self.open.set(true);
        self.cx.requestRedraw();
    }

    fn showRecent(self: *Manager) !void {
        try self.configure(.recent, "最近删除", "", "");
        const scope = try self.replaceList();
        const a = self.item_arena.allocator();
        var items: std.ArrayList(Item) = .empty;
        for (try self.store.listLibraryIds(a, .include_deleted)) |id| {
            var library = try self.store.loadLibrary(a, id, .include_deleted);
            defer library.deinit();
            if (library.value.deleted_at != null) try items.append(a, try capture(a, self.store, .{ .directory = .{ .library = id } }, library.value));
            for (library.value.folders) |folder| {
                if (folder.deleted_at != null) try items.append(a, try capture(a, self.store, .{ .directory = .{ .library = id, .folder = folder.id } }, library.value));
            }
            for (try self.store.listNoteIds(a, id, .include_deleted)) |note_id| {
                var note = try self.store.loadNote(a, .{ .library_id = id, .note_id = note_id }, .include_deleted);
                defer note.deinit();
                if (note.value.deleted_at != null) try items.append(a, .{
                    .target = .{ .note = note.value.key() },
                    .revision = note.value.revision,
                    .title = try a.dupe(u8, note.value.title),
                    .path = try folderPath(a, library.value, note.value.folder_id),
                    .parent = note.value.folder_id,
                    .deleted_at = note.value.deleted_at,
                });
            }
        }
        std.mem.sort(Item, items.items, {}, struct {
            fn newer(_: void, lhs: Item, rhs: Item) bool {
                return lhs.deleted_at.? > rhs.deleted_at.?;
            }
        }.newer);
        for (items.items) |item| {
            const label = if (item.path.len > 0) try std.fmt.allocPrint(a, "{s} / {s}", .{ item.path, item.title }) else item.title;
            try self.addRow(scope, label, .{ .restore = item }, "notes.recent.restore");
        }
        if (items.items.len == 0) try self.addEmpty("没有最近删除的项目");
    }

    fn handle(self: *Manager, intent: Intent) !void {
        switch (intent) {
            .cancel => if (self.mode == .restore_name) try self.show(.recent) else self.dismiss(),
            .move => |folder| {
                const item = self.item orelse return;
                try self.apply(item, .{ .move = folder });
                self.dismiss();
            },
            .restore => |item| {
                self.apply(item, .{ .restore = null }) catch |err| switch (err) {
                    error.NameConflict => {
                        self.item = item;
                        const a = self.item_arena.allocator();
                        const message = if (item.path.len == 0)
                            try std.fmt.allocPrint(a, "已有「{s}」目录。", .{item.title})
                        else
                            try std.fmt.allocPrint(a, "「{s}」中已有「{s}」。", .{ item.path, item.title });
                        self.name.set(try suggestName(a, self.store, item));
                        try self.configure(.restore_name, "恢复目录", message, "恢复");
                        return;
                    },
                    else => return err,
                };
                try self.show(.recent);
            },
            .confirm => {
                const item = self.item orelse return;
                try self.apply(item, switch (self.mode) {
                    .rename => .{ .rename = self.name.peek() },
                    .delete => .delete,
                    .restore_name => .{ .restore = self.name.peek() },
                    .move, .recent => return,
                });
                if (self.mode == .restore_name) try self.show(.recent) else self.dismiss();
            },
        }
    }

    fn apply(self: *Manager, item: Item, change: @FieldType(Mutation, "change")) !void {
        try self.callbacks.apply(self.callbacks.context, .{ .target = item.target, .revision = item.revision, .change = change });
    }

    fn clearList(self: *Manager) void {
        while (self.list.children.items.len > 0) {
            const row = self.list.children.items[self.list.children.items.len - 1];
            self.cx.detachChild(self.list, row);
            self.cx.destroyDetached(row);
        }
        if (self.rows_scope) |old| old.dispose();
        self.rows_scope = null;
    }

    fn replaceList(self: *Manager) !*ui.Scope {
        self.scroll.state.scroll_y = 0;
        self.scroll.content.setStyle(self.cx.allocator, .translate_y, 0);
        self.rows_scope = try self.scope.childScope();
        return self.rows_scope.?;
    }

    fn addRow(self: *Manager, scope: *ui.Scope, title: []const u8, intent: Intent, id: []const u8) !void {
        const row = try scope.createState(Row, .{ .manager = self, .intent = intent });
        const label = try scope.createText(title, .{});
        const node = try ui.widgets.Button(.{
            .variant = .ghost,
            .label = label,
            .a11y_label = label,
            .icon_asset = if (intent == .restore) ui.icons.rotate_ccw else ui.icons.folder,
            .base_style = S.treeRow(0, false),
            .on_click = self.cx.on(Row, row, Row.clicked),
        }).mount(scope, self.cx);
        node.meta.ownership.meta.test_id = id;
        try self.list.appendChild(self.cx.allocator, node);
    }

    fn addEmpty(self: *Manager, message: []const u8) !void {
        try self.list.appendChild(self.cx.allocator, try ui.text(self.cx, message, S.text(13, 400, S.theme.current().fg_2)));
    }

    fn showError(self: *Manager, err: anyerror) void {
        const text = switch (err) {
            error.NameConflict => "当前位置已存在同名目录",
            error.ParentDeleted => "请先恢复所在目录",
            error.FolderDepthExceeded => "目标位置超出目录层级限制",
            error.InvalidName => "请输入有效的名称",
            error.NameTooLong => "名称超过长度限制",
            error.ProtectedDocument, error.ReadOnly => "所选项目包含只读文档",
            error.DocumentInUse => "请先在编辑窗口中关闭该文档",
            error.RevisionChanged => "项目已更新，请重新打开后再试",
            error.ImportInProgress => "请等待图片导入完成或取消导入",
            error.InputComposition => "请先完成当前输入",
            error.NoSpaceLeft => "磁盘空间不足",
            error.AccessDenied => "无法保存，请检查笔记目录权限",
            else => "操作失败，请重试",
        };
        self.problem.setTextContent(self.cx.allocator, text) catch {};
        self.problem.setDisplay(.flex);
    }

    const Row = struct {
        manager: *Manager,
        intent: Intent,
        fn clicked(self: *Row) void {
            self.manager.queue(self.intent);
        }
    };
    fn queue(self: *Manager, intent: Intent) void {
        self.pending = intent;
        self.cx.requestRedraw();
    }
    fn cancelClicked(self: *Manager) void {
        self.queue(.cancel);
    }
    fn confirmClicked(self: *Manager) void {
        self.queue(.confirm);
    }
    fn submitted(self: *Manager, _: []const u8) void {
        self.queue(.confirm);
    }
    fn dispose(self: *Manager) void {
        self.item_arena.deinit();
    }
};

test "notes management keeps a deleted directory until the new name is confirmed" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try Store.init(a, io, tmp.dir);
    defer store.deinit();
    const library_id = try store.createLibrary("工作笔记");
    const original = try store.createFolder(library_id, null, "服务器运维", 1);
    const descendant = try store.createNote(library_id, original, "配置");
    _ = try store.changeFolder(library_id, original, 2, .delete);
    _ = try store.createFolder(library_id, null, "服务器运维", 3);
    _ = try store.createFolder(library_id, null, "服务器运维（恢复）", 4);

    const cx = try ui.Cx.init(a, io);
    defer cx.deinit();
    cx.setViewport(1154, 828);
    cx.root = try ui.box(cx, .{ .width = .fill(), .height = .fill() }, .{});
    const scope = try ui.Scope.init(a, null, cx.owner);
    defer scope.dispose();
    const Apply = struct {
        fn run(raw: *anyopaque, mutation: Mutation) !void {
            const backing: *Store = @ptrCast(@alignCast(raw));
            const target = mutation.target.directory;
            _ = try backing.changeFolder(target.library, target.folder.?, mutation.revision, .{ .restore = mutation.change.restore });
        }
    };
    const manager = try Manager.mount(cx, scope, cx.root.?, &store, .{ .context = &store, .apply = Apply.run });
    try manager.show(.recent);
    var library = try store.loadLibrary(a, library_id, .active);
    defer library.deinit();
    const target: Target = .{ .directory = .{ .library = library_id, .folder = original } };
    try manager.handle(.{ .restore = try capture(manager.item_arena.allocator(), &store, target, library.value) });
    try std.testing.expectEqual(Manager.Mode.restore_name, manager.mode);
    try std.testing.expectEqualStrings("服务器运维（恢复 2）", manager.name.peek());
    cx.layout();
    _ = cx.render();
    const dialog_rect = manager.dialog.globalRect();
    const name_rect = manager.name_input.globalRect();
    try std.testing.expectApproxEqAbs(@as(f32, 420), dialog_rect.w, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 24), name_rect.x - dialog_rect.x, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 38), name_rect.h, 0.01);
    try std.testing.expectError(error.Unavailable, store.loadNote(a, descendant, .active));
    try manager.handle(.cancel);
    try std.testing.expectError(error.Unavailable, store.loadNote(a, descendant, .active));
    try manager.handle(.{ .restore = try capture(manager.item_arena.allocator(), &store, target, library.value) });
    try manager.handle(.confirm);
    var note = try store.loadNote(a, descendant, .active);
    defer note.deinit();
    try std.testing.expectEqual(original, note.value.folder_id.?);
    var restored = try store.loadLibrary(a, library_id, .active);
    defer restored.deinit();
    try std.testing.expectEqualStrings("服务器运维（恢复 2）", restored.value.folders[restored.value.folderIndex(original).?].name);
}
