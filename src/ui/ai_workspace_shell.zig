//! Standalone AI workspace page shell: conversation rail, AI content slot,
//! composer slot and a collapsible workspace/child inspection rail.
//! The module owns presentation and view state only; every action is reported
//! through Callbacks so the host can keep business state authoritative.
const std = @import("std");
const ui = @import("ui");
const T = @import("app_theme.zig");
const S = @import("ai_workspace_shell_styles.zig");
const file_icons = @import("file_workspace_icons.zig");
const TextureBackend = @import("../host/frame_texture_sink.zig").Backend;

pub const InspectorTab = enum { files, members, board, graph, rounds };
pub const PreviewMode = enum { diff, source };
pub const FileKind = enum { file, directory, symlink };

pub const Conversation = struct {
    id: []const u8,
    title: []const u8,
    subtitle: []const u8 = "",
    selected: bool = false,
};

pub const FileRow = struct {
    path: []const u8,
    name: []const u8 = "",
    depth: u16 = 0,
    kind: FileKind = .file,
    expanded: bool = false,
    added: u32 = 0,
    removed: u32 = 0,
    selected: bool = false,
};

pub const FilePreview = struct {
    file_name: []const u8 = "",
    path: []const u8 = "",
    diff: []const u8 = "",
    source: []const u8 = "",
};

pub const Callbacks = struct {
    context: ?*anyopaque = null,
    show_history: ?*const fn (?*anyopaque) void = null,
    new_chat: ?*const fn (?*anyopaque) void = null,
    select_conversation: ?*const fn (?*anyopaque, []const u8) void = null,
    toggle_left_rail: ?*const fn (?*anyopaque, bool) void = null,
    toggle_inspector: ?*const fn (?*anyopaque, bool) void = null,
    select_inspector_tab: ?*const fn (?*anyopaque, InspectorTab) void = null,
    choose_workspace: ?*const fn (?*anyopaque) void = null,
    refresh_files: ?*const fn (?*anyopaque) void = null,
    select_file: ?*const fn (?*anyopaque, []const u8) void = null,
    insert_file_reference: ?*const fn (?*anyopaque, []const u8) void = null,
    choose_preview_mode: ?*const fn (?*anyopaque, PreviewMode) void = null,
    close_inspector: ?*const fn (?*anyopaque) void = null,
    search_changed: ?*const fn (?*anyopaque, []const u8) void = null,
};

pub const Config = struct {
    cx: *ui.Cx,
    scope: *ui.Scope,
    /// Container that receives the retained page root.
    parent: ?*ui.Node = null,
    /// Alias for parent; either mount slot field is accepted.
    slot: ?*ui.Node = null,
    title: []const u8 = "新对话",
    scope_badge: []const u8 = "独立 AI · 读取选定会话",
    workspace_name: []const u8 = "ZeroWork",
    sessions: []const Conversation = &.{},
    files: []const FileRow = &.{},
    files_unavailable_reason: ?[]const u8 = null,
    preview_texture_backend: ?TextureBackend = null,
    preview_reference_requires_approval: bool = false,
    preview: FilePreview = .{},
    inspector_tab: InspectorTab = .files,
    inspector_open: bool = false,
    left_collapsed: bool = false,
    /// Group panes already provide the rounded card shell; set this when the
    /// page is mounted inside one so it does not paint a second card.
    embedded: bool = false,
    /// Full-window hosts reserve the native traffic-light strip here; workspace
    /// content mounts already sit below the shell title bar and leave this zero.
    top_inset: f32 = 0,
    left_inset: f32 = 0,
    callbacks: Callbacks = .{},
};

const StoredConversation = struct {
    id: []u8,
    title: []u8,
    subtitle: []u8,
    selected: bool,
};

const StoredFile = struct {
    path: []u8,
    name: []u8,
    depth: u16,
    kind: FileKind,
    expanded: bool,
    added: u32,
    removed: u32,
    selected: bool,
};

const SessionRowState = struct {
    view: *View,
    id: []const u8,
    index: usize,
    test_id: [72]u8 = undefined,

    fn select(self: *SessionRowState) void {
        selectConversation(self.view, self.id);
    }
};

const FileRowState = struct {
    view: *View,
    path: []const u8,
    index: usize,
    test_id: [72]u8 = undefined,

    fn select(self: *FileRowState) void {
        selectFile(self.view, self.path);
    }
};

const TabClick = struct {
    view: *View,
    tab: InspectorTab,

    fn choose(self: *TabClick) void {
        activateTab(self.view, self.tab, true);
    }
};

const PreviewModeClick = struct {
    view: *View,
    mode: PreviewMode,

    fn choose(self: *PreviewModeClick) void {
        if (self.view.callbacks.choose_preview_mode) |choose_mode|
            return choose_mode(self.view.callbacks.context, self.mode);
        set_preview_mode(self.view, self.mode);
    }
};

pub const MountConfig = Config;

pub const View = struct {
    cx: *ui.Cx,
    scope: *ui.Scope,
    callbacks: Callbacks,

    root: *ui.Node = undefined,
    left_rail: *ui.Node = undefined,
    new_chat_button: *ui.Node = undefined,
    collapse_button: *ui.Node = undefined,
    expand_button: *ui.Node = undefined,
    history_button: ?*ui.Node = null,
    search_value: *ui.Signal([]const u8) = undefined,
    search_input: ui.widgets.input.InputResult = undefined,
    session_scroll: ui.widgets.ScrollAreaResult = undefined,
    session_list: *ui.Node = undefined,
    list_scope: ?*ui.Scope = null,
    selected_id: *ui.Signal(?[]const u8) = undefined,
    sessions: std.ArrayList(StoredConversation) = .empty,
    search_text: []u8 = &.{},

    center: *ui.Node = undefined,
    center_slot: *ui.Node = undefined,
    composer_slot: *ui.Node = undefined,
    title_node: *ui.Node = undefined,
    scope_badge_node: *ui.Node = undefined,
    workspace_name_node: *ui.Node = undefined,
    inspector_toggle_style: *ui.Signal(ui.BoxStyle) = undefined,
    inspector_toggle: *ui.Node = undefined,

    inspector_root: *ui.Node = undefined,
    inspector_body: *ui.Node = undefined,
    tab_buttons: [5]*ui.Node = undefined,
    tab_styles: [5]*ui.Signal(ui.BoxStyle) = undefined,
    tab_pages: [5]*ui.Node = undefined,
    /// Empty-state placeholder inside each hostable page (members/board/graph/
    /// rounds); hidden while a real view is attached.
    inspector_empty_states: [5]?*ui.Node = .{ null, null, null, null, null },
    /// Real page views attached by the host through set_inspector_host.
    inspector_hosts: [5]?*ui.Node = .{ null, null, null, null, null },
    close_button: *ui.Node = undefined,

    files_page: *ui.Node = undefined,
    file_scroll: ui.widgets.ScrollAreaResult = undefined,
    file_list: *ui.Node = undefined,
    file_scope: ?*ui.Scope = null,
    files: std.ArrayList(StoredFile) = .empty,
    files_available: bool = true,
    files_notice: ?*ui.Node = null,
    workspace_picker: *ui.Node = undefined,
    refresh_files_button: ?*ui.Node = null,
    selected_file: *ui.Signal(?[]const u8) = undefined,

    preview_box: *ui.Node = undefined,
    preview_title: *ui.Node = undefined,
    preview_diff_status: *ui.Node = undefined,
    preview_diff_available: bool = false,
    preview_insert: ?*ui.Node = null,
    preview_reference_requires_approval: bool = false,
    preview_reference_available: bool = false,
    preview_placeholder: *ui.Node = undefined,
    preview_scroll: ui.widgets.ScrollAreaResult = undefined,
    preview_gutter: *ui.Node = undefined,
    preview_code: *ui.Node = undefined,
    preview_image_frame: *ui.Node = undefined,
    preview_image: *ui.Node = undefined,
    preview_texture_backend: ?TextureBackend = null,
    preview_texture: ?u32 = null,
    preview_image_size: struct { width: f32 = 0, height: f32 = 0 } = .{},
    preview_mode_styles: [2]*ui.Signal(ui.BoxStyle) = undefined,
    preview_mode_buttons: [2]*ui.Node = undefined,
    preview_name: []u8 = &.{},
    preview_path: []u8 = &.{},
    preview_diff: []u8 = &.{},
    preview_source: []u8 = &.{},
    preview_mode: PreviewMode = .diff,

    active_tab: InspectorTab = .files,
    left_collapsed: bool = false,
    inspector_open: bool = false,
    compact: bool = false,
    /// Filtering rebuilds rows from a text-input callback, so it waits for the
    /// next layout pass instead of freeing siblings mid-event.
    sessions_rebuild_pending: bool = false,
};

pub fn mount(config: Config) !*View {
    const cx = config.cx;
    const scope = config.scope;
    const self = try scope.createState(View, .{
        .cx = cx,
        .scope = scope,
        .callbacks = config.callbacks,
        .files_available = config.files_unavailable_reason == null,
        .preview_texture_backend = config.preview_texture_backend,
        .preview_reference_requires_approval = config.preview_reference_requires_approval,
        .selected_id = try scope.createSignal(?[]const u8, null),
        .selected_file = try scope.createSignal(?[]const u8, null),
    });

    const mount_parent = config.parent orelse config.slot orelse return error.MountSlotRequired;
    self.root = if (config.embedded) try ui.boxStyled(cx, S.rootPlain, .{}) else try ui.boxStyled(cx, S.rootCard, .{});
    self.root.meta.ownership.meta.test_id = "ai.workspace.shell";
    if (config.top_inset != 0 or config.left_inset != 0) {
        self.root.setStyleInline(cx.allocator, .{ .padding = .{ .top = config.top_inset, .left = config.left_inset } });
    }
    try mount_parent.appendChild(cx.allocator, self.root);

    try buildLeftRail(self);
    try buildCenter(self, config);
    try buildInspector(self, config.files_unavailable_reason);
    try set_sessions(self, config.sessions);
    try set_files(self, config.files);
    try set_file_preview(self, config.preview.file_name, config.preview.path, config.preview.diff, config.preview.source);
    set_inspector_tab(self, config.inspector_tab);
    set_inspector_open(self, config.inspector_open);
    set_left_collapsed(self, config.left_collapsed);
    try applyDynamicStyles(self);

    try scope.createEffect(.{ .view = self, .publication = try cx.themeSignal(scope) }, struct {
        fn run(ctx: anytype) void {
            _ = ctx.publication.get();
            applyDynamicStyles(ctx.view) catch {};
            ctx.view.cx.requestRedraw();
        }
    }.run);
    try cx.addAfterLayoutHook(self, afterLayout);
    try scope.onCleanup(View, self, cleanup);
    return self;
}

fn buildLeftRail(self: *View) !void {
    const cx = self.cx;
    const scope = self.scope;
    self.left_rail = try ui.boxStyled(cx, S.leftRail, .{});
    self.left_rail.meta.ownership.meta.test_id = "ai.workspace.left";
    try self.root.appendChild(cx.allocator, self.left_rail);

    const header = try ui.boxStyled(cx, S.railHeader, .{});
    header.meta.ownership.meta.test_id = "ai.workspace.left.header";
    try self.left_rail.appendChild(cx.allocator, header);
    const title = try ui.textStyled(cx, S.railTitle, "AI 对话");
    title.meta.ownership.meta.test_id = "ai.workspace.left.title";
    try header.appendChild(cx.allocator, title);
    try header.appendChild(cx.allocator, try ui.spacer(cx));

    if (self.callbacks.show_history != null) {
        const history = try ui.widgets.Button(.{
            .variant = .ghost,
            .icon_only = true,
            .icon_asset = ui.icons.clock,
            .icon_size = 14,
            .a11y_label = "查看历史对话",
            .base_style = S.iconButton(),
            .on_click = cx.on(View, self, showHistory),
        }).mount(scope, cx);
        history.meta.ownership.meta.test_id = "ai.workspace.history";
        history.setDisplay(.none);
        self.history_button = history;
        try header.appendChild(cx.allocator, history);
    }
    self.new_chat_button = try ui.widgets.Button(.{
        .label = "新建",
        .variant = .ghost,
        .icon_asset = ui.icons.plus,
        .icon_size = 13,
        .a11y_label = "新建 AI 对话",
        .base_style = S.newChatButton(),
        .on_click = cx.on(View, self, newChat),
    }).mount(scope, cx);
    self.new_chat_button.meta.ownership.meta.test_id = "ai.workspace.new";
    try header.appendChild(cx.allocator, self.new_chat_button);

    self.collapse_button = try ui.widgets.Button(.{
        .variant = .ghost,
        .icon_only = true,
        .icon_asset = ui.icons.panel_left_close,
        .icon_size = 14,
        .a11y_label = "收起 AI 对话栏",
        .base_style = S.iconButton(),
        .on_click = cx.on(View, self, toggle_left_rail),
    }).mount(scope, cx);
    self.collapse_button.meta.ownership.meta.test_id = "ai.workspace.collapse";
    try header.appendChild(cx.allocator, self.collapse_button);

    const search = try ui.boxStyled(cx, S.searchField, .{});
    search.meta.ownership.meta.test_id = "ai.workspace.search";
    try self.left_rail.appendChild(cx.allocator, search);
    try search.appendChild(cx.allocator, try T.icon(cx, ui.icons.search, "fg_2", .{ .width = .{ .px = 14 }, .height = .{ .px = 14 }, .flex_shrink = 0 }));
    self.search_value = try scope.createText("", .{});
    self.search_input = try ui.widgets.Input(.{
        .value = self.search_value,
        .placeholder = "搜索历史对话…",
        .size = .sm,
        .embedded = true,
        .on_change = cx.on(View, self, set_search_query),
    }).mountResult(scope, cx);
    self.search_input.node.setStyleInline(cx.allocator, S.searchInput());
    self.search_input.input_container.setStyleInline(cx.allocator, S.searchInput());
    self.search_input.input_container.meta.ownership.meta.test_id = "ai.workspace.search.input";
    try search.appendChild(cx.allocator, self.search_input.node);

    self.session_scroll = try ui.widgets.ScrollArea(.{ .direction = .vertical }).mount(scope, cx);
    self.session_scroll.container.setStyleInline(cx.allocator, S.listViewport(cx.tokens));
    self.session_scroll.container.meta.ownership.meta.test_id = "ai.workspace.sessions";
    self.session_scroll.content.setStyleInline(cx.allocator, S.listContent(cx.tokens));
    @import("ai_card_scroll.zig").containVertical(self.session_scroll);
    try self.left_rail.appendChild(cx.allocator, self.session_scroll.container);
    self.session_list = self.session_scroll.content;
}

fn buildCenter(self: *View, config: Config) !void {
    const cx = self.cx;
    const scope = self.scope;
    self.center = try ui.boxStyled(cx, S.centerPane, .{});
    self.center.meta.ownership.meta.test_id = "ai.workspace.center";
    try self.root.appendChild(cx.allocator, self.center);

    const header = try ui.boxStyled(cx, S.centerHeader, .{});
    header.meta.ownership.meta.test_id = "ai.workspace.center.header";
    try self.center.appendChild(cx.allocator, header);

    self.expand_button = try ui.widgets.Button(.{
        .variant = .ghost,
        .icon_only = true,
        .icon_asset = ui.icons.panel_left_open,
        .icon_size = 15,
        .a11y_label = "展开 AI 对话栏",
        .base_style = S.iconButton(),
        .on_click = cx.on(View, self, toggle_left_rail),
    }).mount(scope, cx);
    self.expand_button.meta.ownership.meta.test_id = "ai.workspace.expand";
    self.expand_button.setDisplay(.none);
    try header.appendChild(cx.allocator, self.expand_button);

    self.title_node = try ui.textStyled(cx, S.title, config.title);
    self.title_node.meta.ownership.meta.test_id = "ai.workspace.title";
    self.title_node.setStyleInline(cx.allocator, .{ .width = .{ .fit = .{} }, .min_width = 0, .max_width = 280, .flex_shrink = 1 });
    try header.appendChild(cx.allocator, self.title_node);

    const badge = try ui.boxStyled(cx, S.scopeBadge, .{});
    badge.meta.ownership.meta.test_id = "ai.workspace.scope";
    try header.appendChild(cx.allocator, badge);
    try badge.appendChild(cx.allocator, try T.icon(cx, ui.icons.sparkles, "accent_ink", .{ .width = .{ .px = 12 }, .height = .{ .px = 12 }, .flex_shrink = 0 }));
    self.scope_badge_node = try ui.textStyled(cx, S.scopeBadgeText, config.scope_badge);
    self.scope_badge_node.setStyleInline(cx.allocator, .{ .width = .{ .fit = .{} }, .min_width = 0, .max_width = 220 });
    try badge.appendChild(cx.allocator, self.scope_badge_node);

    try header.appendChild(cx.allocator, try ui.spacer(cx));

    const workspace = try ui.boxStyled(cx, S.workspacePill, .{});
    self.workspace_picker = workspace;
    if (self.callbacks.choose_workspace != null) {
        workspace.behavior.interaction.a11y = .{ .role = .button, .label = "选择本地工作区" };
        workspace.setFocusable(true);
        _ = ui.clickable(workspace, cx.on(View, self, chooseWorkspace));
    }
    workspace.meta.ownership.meta.test_id = "ai.workspace.workspace";
    if (!self.files_available) workspace.setDisplay(.none);
    try header.appendChild(cx.allocator, workspace);
    try workspace.appendChild(cx.allocator, try T.icon(cx, ui.icons.folder, "fg_2", .{ .width = .{ .px = 14 }, .height = .{ .px = 14 }, .flex_shrink = 0 }));
    self.workspace_name_node = try ui.textStyled(cx, S.workspaceText, config.workspace_name);
    self.workspace_name_node.setStyleInline(cx.allocator, .{ .width = .{ .fit = .{} }, .min_width = 0, .max_width = 130 });
    try workspace.appendChild(cx.allocator, self.workspace_name_node);
    try workspace.appendChild(cx.allocator, try T.icon(cx, ui.icons.chevron_down, "fg_3", .{ .width = .{ .px = 12 }, .height = .{ .px = 12 }, .flex_shrink = 0 }));

    self.inspector_toggle_style = try scope.createSignal(ui.BoxStyle, S.inspectorToggle(false));
    self.inspector_toggle = try ui.widgets.Button(.{
        .label = "检查器",
        .variant = .ghost,
        .icon_asset = ui.icons.panel_right,
        .icon_size = 14,
        .a11y_label = "打开或关闭检查器",
        .base_style = self.inspector_toggle_style,
        .on_click = cx.on(View, self, toggle_inspector),
    }).mount(scope, cx);
    self.inspector_toggle.meta.ownership.meta.test_id = "ai.workspace.inspector.toggle";
    try header.appendChild(cx.allocator, self.inspector_toggle);

    self.center_slot = try ui.boxStyled(cx, S.centerSlot, .{});
    self.center_slot.meta.ownership.meta.test_id = "ai.workspace.center.slot";
    try self.center.appendChild(cx.allocator, self.center_slot);

    self.composer_slot = try ui.boxStyled(cx, S.composerSlot, .{});
    self.composer_slot.meta.ownership.meta.test_id = "ai.workspace.composer";
    try self.center.appendChild(cx.allocator, self.composer_slot);
}

fn buildInspector(self: *View, files_unavailable_reason: ?[]const u8) !void {
    const cx = self.cx;
    const scope = self.scope;
    self.inspector_root = try ui.boxStyled(cx, S.inspector, .{});
    self.inspector_root.meta.ownership.meta.test_id = "ai.workspace.inspector";
    self.inspector_root.setDisplay(.none);
    try self.root.appendChild(cx.allocator, self.inspector_root);

    const header = try ui.boxStyled(cx, S.inspectorHeader, .{});
    header.meta.ownership.meta.test_id = "ai.workspace.inspector.header";
    try self.inspector_root.appendChild(cx.allocator, header);

    const labels = [_][]const u8{ "文件", "成员", "留言板", "关系图", "轮次" };
    const test_ids = [_][]const u8{
        "ai.workspace.inspector.tab.files",
        "ai.workspace.inspector.tab.members",
        "ai.workspace.inspector.tab.board",
        "ai.workspace.inspector.tab.graph",
        "ai.workspace.inspector.tab.rounds",
    };
    inline for (labels, 0..) |label, index| {
        const style = try scope.createSignal(ui.BoxStyle, S.tabButton(false));
        self.tab_styles[index] = style;
        const state = try scope.createState(TabClick, .{ .view = self, .tab = @fromBackingInt(@intCast(index)) });
        const button = try ui.widgets.Button(.{
            .label = label,
            .variant = .ghost,
            .base_style = style,
            .on_click = cx.on(TabClick, state, TabClick.choose),
        }).mount(scope, cx);
        button.meta.ownership.meta.test_id = test_ids[index];
        self.tab_buttons[index] = button;
        try header.appendChild(cx.allocator, button);
    }
    try header.appendChild(cx.allocator, try ui.spacer(cx));

    self.close_button = try ui.widgets.Button(.{
        .variant = .ghost,
        .icon_only = true,
        .icon_asset = ui.icons.x,
        .icon_size = 14,
        .a11y_label = "关闭检查器",
        .base_style = S.iconButton(),
        .on_click = cx.on(View, self, close_inspector),
    }).mount(scope, cx);
    self.close_button.meta.ownership.meta.test_id = "ai.workspace.inspector.close";
    try header.appendChild(cx.allocator, self.close_button);

    self.inspector_body = try ui.boxStyled(cx, S.inspectorBody, .{});
    self.inspector_body.meta.ownership.meta.test_id = "ai.workspace.inspector.body";
    try self.inspector_root.appendChild(cx.allocator, self.inspector_body);

    self.files_page = try buildFilesPage(self);
    if (files_unavailable_reason) |reason| {
        self.file_scroll.container.setDisplay(.none);
        self.preview_box.setDisplay(.none);
        self.files_notice = try buildEmptyPage(self, "未选择工作区", reason, ui.icons.folder, "ai.workspace.files.unavailable");
        try self.files_page.appendChild(cx.allocator, self.files_notice.?);
    }
    self.tab_pages[0] = self.files_page;
    self.tab_pages[1] = try buildInspectorHostPage(self, 1, "暂无子智能体", "创建多智能体任务后，成员会显示在这里。", ui.icons.users, "ai.workspace.empty.members");
    self.tab_pages[2] = try buildInspectorHostPage(self, 2, "暂无留言", "子智能体之间的共享留言会显示在这里。", ui.icons.message_square, "ai.workspace.empty.board");
    self.tab_pages[3] = try buildInspectorHostPage(self, 3, "暂无关系图", "启动子智能体后，协调者与成员关系会显示在这里。", ui.icons.network, "ai.workspace.empty.graph");
    self.tab_pages[4] = try buildInspectorHostPage(self, 4, "暂无轮次", "Boost 模式下的实现、挑战、修复与终验会显示在这里。", ui.icons.list_ordered, "ai.workspace.empty.rounds");
    for (self.tab_pages) |page| {
        page.setDisplay(.none);
        try self.inspector_body.appendChild(cx.allocator, page);
    }
    self.tab_pages[0].setDisplay(.flex);
}

fn buildFilesPage(self: *View) !*ui.Node {
    const cx = self.cx;
    const page = try ui.boxStyled(cx, S.filesPage, .{});
    page.meta.ownership.meta.test_id = "ai.workspace.files.page";

    self.file_scroll = try ui.widgets.ScrollArea(.{ .direction = .vertical }).mount(self.scope, cx);
    self.file_scroll.container.setStyleInline(cx.allocator, S.fileTreeViewport(cx.tokens));
    self.file_scroll.container.meta.ownership.meta.test_id = "ai.workspace.files";
    self.file_scroll.content.setStyleInline(cx.allocator, S.fileTreeContent(cx.tokens));
    @import("ai_card_scroll.zig").containVertical(self.file_scroll);
    try page.appendChild(cx.allocator, self.file_scroll.container);
    self.file_list = self.file_scroll.content;

    self.preview_box = try ui.boxStyled(cx, S.preview, .{});
    self.preview_box.meta.ownership.meta.test_id = "ai.workspace.preview";
    try page.appendChild(cx.allocator, self.preview_box);

    const preview_header = try ui.boxStyled(cx, S.previewHeader, .{});
    try self.preview_box.appendChild(cx.allocator, preview_header);
    try preview_header.appendChild(cx.allocator, try T.icon(cx, ui.icons.file_diff, "fg_2", .{ .width = .{ .px = 14 }, .height = .{ .px = 14 }, .flex_shrink = 0 }));
    self.preview_title = try ui.textStyled(cx, S.previewTitle, "未选择文件");
    self.preview_title.setStyleInline(cx.allocator, .{ .width = .fill(), .min_width = 0 });
    try preview_header.appendChild(cx.allocator, self.preview_title);

    const insert = try ui.widgets.Button(.{
        .variant = .ghost,
        .icon_only = true,
        .icon_asset = ui.icons.at_sign,
        .icon_size = 14,
        .a11y_label = "引用到对话",
        .base_style = S.iconButton(),
        .on_click = cx.on(View, self, insertFileReference),
    }).mount(self.scope, cx);
    insert.meta.ownership.meta.test_id = "ai.workspace.preview.insert";
    try preview_header.appendChild(cx.allocator, insert);
    self.preview_insert = insert;
    if (self.callbacks.insert_file_reference == null or self.preview_reference_requires_approval) insert.setDisplay(.none);
    if (self.callbacks.refresh_files != null) {
        const refresh = try ui.widgets.Button(.{
            .label = "刷新",
            .variant = .ghost,
            .a11y_label = "刷新工作区文件",
            .on_click = cx.on(View, self, refreshFiles),
        }).mount(self.scope, cx);
        refresh.meta.ownership.meta.test_id = "ai.workspace.files.refresh";
        self.refresh_files_button = refresh;
        try preview_header.appendChild(cx.allocator, refresh);
    }

    const segment = try ui.boxStyled(cx, S.previewSegment, .{});
    try preview_header.appendChild(cx.allocator, segment);
    self.preview_mode_styles[0] = try self.scope.createSignal(ui.BoxStyle, S.previewSegmentButton(true));
    self.preview_mode_styles[1] = try self.scope.createSignal(ui.BoxStyle, S.previewSegmentButton(false));
    const mode_labels = [_][]const u8{ "Diff", "源码" };
    const mode_ids = [_][]const u8{ "ai.workspace.preview.diff", "ai.workspace.preview.source" };
    inline for (mode_labels, 0..) |label, index| {
        const state = try self.scope.createState(PreviewModeClick, .{ .view = self, .mode = @fromBackingInt(@intCast(index)) });
        const button = try ui.widgets.Button(.{
            .label = label,
            .variant = .ghost,
            .base_style = self.preview_mode_styles[index],
            .on_click = cx.on(PreviewModeClick, state, PreviewModeClick.choose),
        }).mount(self.scope, cx);
        button.meta.ownership.meta.test_id = mode_ids[index];
        self.preview_mode_buttons[index] = button;
        try segment.appendChild(cx.allocator, button);
    }

    self.preview_diff_status = try ui.textStyled(cx, S.railEmpty, "");
    self.preview_diff_status.meta.ownership.meta.test_id = "ai.workspace.preview.diff.status";
    self.preview_diff_status.behavior.interaction.a11y = .{ .role = .status, .live = "polite" };
    self.preview_diff_status.setStyleInline(cx.allocator, .{ .width = .fill(), .min_width = 0, .padding = .{ .left = 10, .right = 10, .top = 4, .bottom = 6 } });
    self.preview_diff_status.setDisplay(.none);
    try self.preview_box.appendChild(cx.allocator, self.preview_diff_status);
    if (self.callbacks.choose_preview_mode != null) segment.setDisplay(.none);

    const body = try ui.boxStyled(cx, S.previewBody, .{});
    try self.preview_box.appendChild(cx.allocator, body);
    self.preview_placeholder = try ui.textStyled(cx, S.previewPlaceholder, "选择文件后，在此查看源码与差异。");
    self.preview_placeholder.meta.ownership.meta.test_id = "ai.workspace.preview.placeholder";
    self.preview_placeholder.setStyleInline(cx.allocator, .{ .width = .fill(), .height = .fill(), .padding = .{ .left = 16, .right = 16 } });
    try body.appendChild(cx.allocator, self.preview_placeholder);

    self.preview_scroll = try ui.widgets.ScrollArea(.{ .direction = .both, .rubber_band_x = false, .rubber_band_y = false }).mount(self.scope, cx);
    self.preview_scroll.container.setStyleInline(cx.allocator, S.previewScroll(cx.tokens));
    self.preview_scroll.container.setDisplay(.none);
    try body.appendChild(cx.allocator, self.preview_scroll.container);
    self.preview_scroll.content.setStyleInline(cx.allocator, S.previewContent(cx.tokens));
    const gutter_box = try ui.box(cx, .{ .width = .{ .px = 32 }, .height = .{ .fit = .{} }, .flex_shrink = 0, .padding = .{ .left = 2, .right = 4, .top = 6, .bottom = 6 } }, .{});
    self.preview_gutter = try ui.textStyled(cx, S.previewGutter, "");
    self.preview_gutter.setStyleInline(cx.allocator, .{ .width = .{ .px = 26 } });
    try gutter_box.appendChild(cx.allocator, self.preview_gutter);
    try self.preview_scroll.content.appendChild(cx.allocator, gutter_box);
    const code_box = try ui.box(cx, .{ .width = .{ .fit = .{} }, .height = .{ .fit = .{} }, .flex_shrink = 0, .padding = .{ .left = 2, .right = 10, .top = 6, .bottom = 6 } }, .{});
    self.preview_code = try ui.textStyled(cx, S.previewCode, "");
    try code_box.appendChild(cx.allocator, self.preview_code);
    try self.preview_scroll.content.appendChild(cx.allocator, code_box);

    self.preview_image_frame = try ui.box(cx, .{ .width = .fill(), .height = .fill(), .align_items = .center, .justify = .center, .padding = ui.Padding.all(8) }, .{});
    self.preview_image_frame.setDisplay(.none);
    try body.appendChild(cx.allocator, self.preview_image_frame);
    self.preview_image = try ui.box(cx, .{ .width = .{ .px = 1 }, .height = .{ .px = 1 }, .flex_shrink = 0 }, .{});
    self.preview_image.meta.ownership.meta.test_id = "ai.workspace.preview.image";
    try self.preview_image_frame.appendChild(cx.allocator, self.preview_image);
    return page;
}

/// Hostable inspector page: a plain container with the empty placeholder as
/// its first child. The real view is appended by set_inspector_host and the
/// placeholder is hidden while it is mounted.
fn buildInspectorHostPage(self: *View, index: usize, title_text: []const u8, detail: []const u8, icon: ui.SvgAsset, test_id: []const u8) !*ui.Node {
    const cx = self.cx;
    const page = try ui.boxStyled(cx, S.inspectorPage, .{});
    page.meta.ownership.meta.test_id = switch (index) {
        1 => "ai.workspace.inspector.page.members",
        2 => "ai.workspace.inspector.page.board",
        3 => "ai.workspace.inspector.page.graph",
        else => "ai.workspace.inspector.page.rounds",
    };
    const empty = try buildEmptyPage(self, title_text, detail, icon, test_id);
    self.inspector_empty_states[index] = empty;
    try page.appendChild(cx.allocator, empty);
    return page;
}

fn buildEmptyPage(self: *View, title_text: []const u8, detail: []const u8, icon: ui.SvgAsset, test_id: []const u8) !*ui.Node {
    const cx = self.cx;
    const page = try ui.boxStyled(cx, S.emptyState, .{});
    page.meta.ownership.meta.test_id = test_id;
    try page.appendChild(cx.allocator, try T.icon(cx, icon, "fg_3", .{ .width = .{ .px = 28 }, .height = .{ .px = 28 }, .flex_shrink = 0 }));
    const title = try ui.textStyled(cx, S.emptyTitle, title_text);
    title.setStyleInline(cx.allocator, .{ .width = .fill(), .min_width = 0 });
    try page.appendChild(cx.allocator, title);
    const detail_node = try ui.textStyled(cx, S.emptyText, detail);
    detail_node.setStyleInline(cx.allocator, .{ .width = .fill(), .min_width = 0 });
    try page.appendChild(cx.allocator, detail_node);
    return page;
}

pub fn set_sessions(self: *View, sessions: []const Conversation) !void {
    // The host projects on layout; do not recreate focused rows or lose scroll
    // on every frame when the authoritative conversation snapshot is unchanged.
    if (self.list_scope != null and self.sessions.items.len == sessions.len) unchanged: {
        for (self.sessions.items, sessions) |stored, incoming| {
            if (stored.selected != incoming.selected or
                !std.mem.eql(u8, stored.id, incoming.id) or
                !std.mem.eql(u8, stored.title, incoming.title) or
                !std.mem.eql(u8, stored.subtitle, incoming.subtitle)) break :unchanged;
        }
        return;
    }

    var next: std.ArrayList(StoredConversation) = .empty;
    errdefer {
        for (next.items) |item| freeStoredConversation(self.cx.allocator, item);
        next.deinit(self.cx.allocator);
    }
    try next.ensureTotalCapacity(self.cx.allocator, sessions.len);
    for (sessions) |conversation| {
        next.appendAssumeCapacity(try storeConversation(self.cx.allocator, conversation));
    }

    clearSessionRows(self);
    self.selected_id.set(null); // the signal borrows an ID from the old rows
    freeSessions(self);
    self.sessions = next;
    next = .empty;

    var selected: ?[]const u8 = null;
    for (self.sessions.items) |item| {
        if (!item.selected) continue;
        selected = item.id;
        break;
    }
    self.selected_id.set(selected);
    try buildSessionRows(self);
    self.cx.requestRedraw();
}

fn showHistory(self: *View) void {
    if (self.callbacks.show_history) |f| f(self.callbacks.context);
}
fn chooseWorkspace(self: *View) void {
    if (self.callbacks.choose_workspace) |f| f(self.callbacks.context);
}
fn refreshFiles(self: *View) void {
    if (self.callbacks.refresh_files) |f| f(self.callbacks.context);
}
/// No cached file name, body or selection may survive a scope handoff.
pub fn bind_files(self: *View, name: ?[]const u8, can_choose: bool) !void {
    if (self.files_available) {
        try set_file_preview(self, "", "", "", "");
        try set_files(self, &.{});
    }
    self.selected_file.set(null);
    self.files_available = name != null;
    self.workspace_picker.setDisplay(if (can_choose or name != null) .flex else .none);
    try set_workspace_name(self, name orelse "选择工作区");
    self.file_scroll.container.setDisplay(if (name != null) .flex else .none);
    self.preview_box.setDisplay(if (name != null) .flex else .none);
    if (self.files_notice) |n| n.setDisplay(if (name == null) .flex else .none);
    set_preview_mode(self, .source);
    if (self.preview_mode_buttons[0].parent) |segment| segment.setDisplay(.none);
    try self.preview_placeholder.setTextContent(self.cx.allocator, "选择文本或图片查看内容。");
    self.cx.requestRedraw();
}
pub fn preview_notice(self: *View, text: []const u8) !void {
    try set_file_preview(self, "", "", "", "");
    try self.preview_placeholder.setTextContent(self.cx.allocator, text);
}

pub fn set_files(self: *View, files: []const FileRow) !void {
    if (!self.files_available) return;
    var previous_selection: ?[]u8 = null;
    if (self.selected_file.peek()) |value| previous_selection = try self.cx.allocator.dupe(u8, value);
    defer if (previous_selection) |value| self.cx.allocator.free(value);

    var next: std.ArrayList(StoredFile) = .empty;
    errdefer {
        for (next.items) |item| freeStoredFile(self.cx.allocator, item);
        next.deinit(self.cx.allocator);
    }
    try next.ensureTotalCapacity(self.cx.allocator, files.len);
    for (files) |row| {
        next.appendAssumeCapacity(try storeFile(self.cx.allocator, row));
    }

    clearFileRows(self);
    self.selected_file.set(null); // drop borrowed storage before freeing it
    freeFiles(self);
    self.files = next;
    next = .empty; // Ownership transferred even if mounting the new rows fails.

    var selected: ?[]const u8 = null;
    for (self.files.items) |item| {
        if (!item.selected) continue;
        selected = item.path;
        break;
    }
    if (selected == null) if (previous_selection) |value| {
        if (findFile(self, value)) |match| selected = match;
    };
    self.selected_file.set(selected);
    try buildFileRows(self);
    self.cx.requestRedraw();
}

pub fn set_left_collapsed(self: *View, collapsed: bool) void {
    if (self.left_collapsed == collapsed) {
        self.left_rail.setDisplay(if (collapsed) .none else .flex);
        self.expand_button.setDisplay(if (collapsed) .flex else .none);
        return;
    }
    self.left_collapsed = collapsed;
    self.left_rail.setDisplay(if (collapsed) .none else .flex);
    self.expand_button.setDisplay(if (collapsed) .flex else .none);
    self.root.markLayoutDirty();
    self.cx.requestRedraw();
}

pub fn set_inspector_open(self: *View, open: bool) void {
    if (self.inspector_open == open and (self.inspector_root.style.display == .flex) == open) {
        applyInspectorToggleStyle(self);
        return;
    }
    self.inspector_open = open;
    self.inspector_root.setDisplay(if (open) .flex else .none);
    applyInspectorToggleStyle(self);
    self.root.markLayoutDirty();
    self.cx.requestRedraw();
}

pub fn set_inspector_tab(self: *View, tab: InspectorTab) void {
    self.active_tab = tab;
    const active_index = @backingInt(tab);
    for (self.tab_pages, 0..) |page, index| {
        page.setDisplay(if (index == active_index) .flex else .none);
    }
    applyTabStyles(self) catch {};
    self.inspector_body.markLayoutDirty();
    self.cx.requestRedraw();
}

/// Returns the container node of an inspector page. Hosts build their real
/// view directly inside it; the empty placeholder remains its first child so
/// it can be restored when the host is detached.
pub fn inspector_page(self: *View, tab: InspectorTab) *ui.Node {
    return self.tab_pages[@backingInt(tab)];
}

/// Attaches an externally built real view to the members, board, graph or
/// rounds page. The page's empty placeholder is hidden while the host is
/// mounted. Passing null detaches the previous host without destroying it and
/// restores the empty state. The caller keeps ownership of the host node.
pub fn set_inspector_host(self: *View, tab: InspectorTab, node: ?*ui.Node) !void {
    const index = @backingInt(tab);
    if (index == 0) return error.InspectorTabHasNoHost;
    const page = self.tab_pages[index];
    if (node) |host| {
        if (page.isDescendantOf(host)) return error.InvalidInspectorHost;
    }
    const previous = self.inspector_hosts[index];
    if (node) |host| {
        // Keep tab bookkeeping coherent when the same real view is moved from
        // another inspector page.
        for (self.inspector_hosts, 0..) |slot, slot_index| {
            const other = slot orelse continue;
            if (slot_index == index or other != host) continue;
            self.inspector_hosts[slot_index] = null;
            if (self.inspector_empty_states[slot_index]) |empty| empty.setDisplay(.flex);
        }
        try page.appendChild(self.cx.allocator, host);
        host.setStyleInline(self.cx.allocator, S.inspectorHost(self.cx.tokens));
        host.setDisplay(.flex);
        self.inspector_hosts[index] = host;
    } else {
        self.inspector_hosts[index] = null;
    }
    if (previous) |old| {
        const same = if (node) |host| old == host else false;
        if (!same and old.parent == page) self.cx.detachChildRetained(page, old);
    }
    if (self.inspector_empty_states[index]) |empty| {
        empty.setDisplay(if (self.inspector_hosts[index] == null) .flex else .none);
    }
    page.markLayoutDirty();
    self.inspector_body.markLayoutDirty();
    self.cx.requestRedraw();
}

pub fn set_title(self: *View, value: []const u8) !void {
    try self.title_node.setTextContent(self.cx.allocator, value);
}

pub fn set_scope_badge(self: *View, value: []const u8) !void {
    try self.scope_badge_node.setTextContent(self.cx.allocator, value);
}

pub fn set_workspace_name(self: *View, value: []const u8) !void {
    try self.workspace_name_node.setTextContent(self.cx.allocator, value);
}

pub fn set_file_preview(self: *View, file_name: []const u8, path: []const u8, diff: []const u8, source: []const u8) !void {
    if (!self.files_available) return;
    if (self.preview_reference_requires_approval) set_preview_reference_available(self, false);
    if (self.callbacks.choose_preview_mode != null) set_preview_diff_offer(self, false);
    if (self.preview_texture != null) {
        self.preview_image_frame.setDisplay(.none);
        self.preview_image.setImage(null);
        releasePreviewTexture(self);
    }
    try replaceBytes(self.cx.allocator, &self.preview_name, file_name);
    try replaceBytes(self.cx.allocator, &self.preview_path, path);
    try replaceBytes(self.cx.allocator, &self.preview_diff, diff);
    try replaceBytes(self.cx.allocator, &self.preview_source, source);

    const shown_name = if (self.preview_name.len != 0) self.preview_name else if (self.preview_path.len != 0) std.fs.path.basename(self.preview_path) else "";
    try self.preview_title.setTextContent(self.cx.allocator, if (shown_name.len != 0) shown_name else "未选择文件");
    const has_file = shown_name.len != 0;
    self.preview_placeholder.setDisplay(if (has_file) .none else .flex);
    self.preview_scroll.container.setDisplay(if (has_file) .flex else .none);
    self.selected_file.set(if (has_file) findFile(self, self.preview_path) else null);
    try updatePreviewText(self);
    self.cx.requestRedraw();
}

/// Run only on the UI thread for the currently authorized preview.
pub fn set_preview_diff_offer(self: *View, available: bool) void {
    if (self.callbacks.choose_preview_mode == null or self.preview_diff_available == available) return;
    self.preview_diff_available = available;
    if (self.preview_mode_buttons[0].parent) |segment| segment.setDisplay(if (available) .flex else .none);
    if (!available) show_preview_diff_status(self, "") catch {};
}

pub fn show_preview_diff_status(self: *View, note: []const u8) !void {
    try replaceBytes(self.cx.allocator, &self.preview_diff, "");
    try self.preview_diff_status.setTextContent(self.cx.allocator, note);
    self.preview_diff_status.setDisplay(if (note.len == 0) .none else .flex);
    set_preview_mode(self, .source);
    self.cx.requestRedraw();
}

pub fn show_verified_preview_diff(self: *View, note: []const u8, text: []const u8) !void {
    if (!self.preview_diff_available or self.preview_path.len == 0) return;
    try replaceBytes(self.cx.allocator, &self.preview_diff, text);
    try self.preview_diff_status.setTextContent(self.cx.allocator, note);
    self.preview_diff_status.setDisplay(.flex);
    set_preview_mode(self, .diff);
    try updatePreviewText(self);
    self.cx.requestRedraw();
}

pub fn set_preview_reference_available(self: *View, eligible: bool) void {
    self.preview_reference_available = eligible and self.callbacks.insert_file_reference != null;
    if (self.preview_insert) |insert| insert.setDisplay(if (self.preview_reference_available) .flex else .none);
}

/// The mounted page owns one GPU texture, never the worker's pixel buffer.
pub fn set_image_preview(self: *View, path: []const u8, width: u32, height: u32, rgba: []const u8) !void {
    if (!self.files_available) return;
    const backend = self.preview_texture_backend orelse return error.ImagePreviewUnavailable;
    const texture = try backend.create(backend.context, width, height);
    errdefer backend.release(backend.context, texture);
    try backend.update(backend.context, texture, rgba);
    try set_file_preview(self, std.fs.path.basename(path), path, "", "");
    self.preview_texture = texture;
    self.preview_image_size = .{ .width = @floatFromInt(width), .height = @floatFromInt(height) };
    self.preview_scroll.container.setDisplay(.none);
    self.preview_image.setImage(.{ .texture_id = texture });
    self.preview_image_frame.setDisplay(.flex);
    self.cx.requestRedraw();
}

fn releasePreviewTexture(self: *View) void {
    const texture = self.preview_texture orelse return;
    self.preview_texture = null;
    if (self.preview_texture_backend) |backend| backend.release(backend.context, texture);
}

fn layoutPreviewImage(self: *View) bool {
    if (self.preview_texture == null or !self.preview_image_frame.isDisplayedInTree()) return false;
    const frame = self.preview_image_frame.globalRect();
    const size = self.preview_image_size;
    const scale = @min(1, @min(@max(1, frame.w - 16) / size.width, @max(1, frame.h - 16) / size.height));
    const width = @max(1, size.width * scale);
    const height = @max(1, size.height * scale);
    const actual = self.preview_image.globalRect();
    if (@abs(actual.w - width) < 0.1 and @abs(actual.h - height) < 0.1) return false;
    self.preview_image.setStyleInline(self.cx.allocator, .{ .width = .{ .px = width }, .height = .{ .px = height } });
    return true;
}

pub fn set_preview_mode(self: *View, mode: PreviewMode) void {
    if (self.preview_mode == mode) return;
    self.preview_mode = mode;
    applyPreviewModeStyles(self) catch {};
    updatePreviewText(self) catch {};
    self.cx.requestRedraw();
}

pub fn toggle_preview_mode(self: *View) void {
    set_preview_mode(self, if (self.preview_mode == .diff) .source else .diff);
}

fn updatePreviewText(self: *View) !void {
    const text = if (self.preview_mode == .diff) self.preview_diff else self.preview_source;
    const fallback = if (self.preview_mode == .diff) "此文件没有可显示的差异。" else "此文件暂无内容。";
    try self.preview_code.setTextContent(self.cx.allocator, if (text.len != 0) text else fallback);
    if (self.preview_mode == .source and text.len != 0) {
        const numbers = try lineNumbers(self.cx.allocator, text);
        defer self.cx.allocator.free(numbers);
        try self.preview_gutter.setTextContent(self.cx.allocator, numbers);
        self.preview_gutter.setDisplay(.flex);
    } else {
        self.preview_gutter.setDisplay(.none);
    }
}

fn applyDynamicStyles(self: *View) !void {
    try applyTabStyles(self);
    try applyPreviewModeStyles(self);
    applyInspectorToggleStyle(self);
    recolorButtonContents(self.inspector_toggle, if (self.inspector_open) T.current().accent_ink else T.current().fg_2);
    self.cx.requestRedraw();
}

fn applyTabStyles(self: *View) !void {
    const active_index = @backingInt(self.active_tab);
    inline for (self.tab_styles, 0..) |style, index| {
        const active = index == active_index;
        style.set(S.tabButton(active));
        recolorButtonContents(self.tab_buttons[index], if (active) T.current().fg_1 else T.current().fg_2);
    }
}

fn applyPreviewModeStyles(self: *View) !void {
    inline for (self.preview_mode_styles, 0..) |style, index| {
        const active = index == @backingInt(self.preview_mode);
        style.set(S.previewSegmentButton(active));
        recolorButtonContents(self.preview_mode_buttons[index], if (active) T.current().fg_1 else T.current().fg_2);
    }
}

fn applyInspectorToggleStyle(self: *View) void {
    self.inspector_toggle_style.set(S.inspectorToggle(self.inspector_open));
}

fn buildSessionRows(self: *View) !void {
    const cx = self.cx;
    const scope = try self.scope.childScope();
    self.list_scope = scope;
    var visible: usize = 0;
    for (self.sessions.items, 0..) |*conversation, index| {
        if (!sessionMatches(conversation, self.search_text)) continue;
        const state = try scope.createState(SessionRowState, .{ .view = self, .id = conversation.id, .index = index });
        const row = try ui.boxStyled(cx, S.sessionRow, .{});
        row.meta.ownership.meta.test_id = std.fmt.bufPrint(&state.test_id, "ai.workspace.session.{d}", .{index}) catch "ai.workspace.session";
        row.behavior.interaction.a11y = .{ .role = .button, .label = conversation.title };
        row.setFocusable(true);
        const hovered = try ui.hooks.useHover(scope, row);
        try scope.createEffect(.{ .cx = cx, .row = row, .hovered = hovered, .selected = self.selected_id, .id = conversation.id, .publication = try cx.themeSignal(scope) }, struct {
            fn run(ctx: anytype) void {
                _ = ctx.publication.get();
                const selected = if (ctx.selected.get()) |value| std.mem.eql(u8, value, ctx.id) else false;
                ctx.row.setStyleInline(ctx.cx.allocator, S.sessionRowBackground(selected, ctx.hovered.get()));
                ctx.cx.requestRedraw();
            }
        }.run);
        _ = ui.clickable(row, cx.on(SessionRowState, state, SessionRowState.select));
        const title = try ui.textStyled(cx, S.sessionTitle, conversation.title);
        title.setStyleInline(cx.allocator, .{ .width = .fill(), .min_width = 0 });
        try row.appendChild(cx.allocator, title);
        if (conversation.subtitle.len != 0) {
            const subtitle = try ui.textStyled(cx, S.sessionSubtitle, conversation.subtitle);
            subtitle.setStyleInline(cx.allocator, .{ .width = .fill(), .min_width = 0 });
            try row.appendChild(cx.allocator, subtitle);
        }
        try self.session_list.appendChild(cx.allocator, row);
        visible += 1;
    }
    if (visible == 0) {
        const empty = try ui.box(cx, .{ .width = .fill(), .height = .{ .fit = .{} }, .padding = .{ .left = 8, .right = 8, .top = 12, .bottom = 4 } }, .{});
        empty.meta.ownership.meta.test_id = "ai.workspace.sessions.empty";
        const label = try ui.textStyled(cx, S.railEmpty, if (self.search_text.len == 0) "暂无对话。新建一个 AI 对话，开始处理当前工作区。" else "没有匹配的对话，换一个关键词试试。");
        label.setStyleInline(cx.allocator, .{ .width = .fill(), .min_height = 0 });
        try empty.appendChild(cx.allocator, label);
        try self.session_list.appendChild(cx.allocator, empty);
    } else {}
    ui.widgets.setScrollY(self.session_scroll.state, self.session_scroll.content, 0);
}

fn buildFileRows(self: *View) !void {
    const cx = self.cx;
    const scope = try self.scope.childScope();
    self.file_scope = scope;
    if (self.files.items.len == 0) {
        const empty = try ui.box(cx, .{ .width = .fill(), .height = .{ .fit = .{} }, .padding = .{ .left = 8, .right = 8, .top = 14, .bottom = 6 } }, .{});
        empty.meta.ownership.meta.test_id = "ai.workspace.files.empty";
        const label = try ui.textStyled(cx, S.railEmpty, "暂无工作区文件。打开本地工作区后，文件会显示在这里。");
        label.setStyleInline(cx.allocator, .{ .width = .fill(), .min_height = 0 });
        try empty.appendChild(cx.allocator, label);
        try self.file_list.appendChild(cx.allocator, empty);
    } else {}
    for (self.files.items, 0..) |*item, index| {
        const state = try scope.createState(FileRowState, .{ .view = self, .path = item.path, .index = index });
        const row = try ui.box(cx, S.fileRow(item.depth), .{});
        row.meta.ownership.meta.test_id = std.fmt.bufPrint(&state.test_id, "ai.workspace.file.{d}", .{index}) catch "ai.workspace.file";
        row.behavior.interaction.a11y = .{ .role = .button, .label = item.name };
        row.setFocusable(true);
        const hovered = try ui.hooks.useHover(scope, row);
        try scope.createEffect(.{ .cx = cx, .row = row, .hovered = hovered, .selected = self.selected_file, .path = item.path, .publication = try cx.themeSignal(scope) }, struct {
            fn run(ctx: anytype) void {
                _ = ctx.publication.get();
                const selected = if (ctx.selected.get()) |value| std.mem.eql(u8, value, ctx.path) else false;
                ctx.row.setStyleInline(ctx.cx.allocator, S.fileRowBackground(selected, ctx.hovered.get()));
                ctx.cx.requestRedraw();
            }
        }.run);
        _ = ui.clickable(row, cx.on(FileRowState, state, FileRowState.select));

        if (item.kind == .directory) {
            try row.appendChild(cx.allocator, try T.icon(cx, if (item.expanded) ui.icons.chevron_down else ui.icons.chevron_right, "fg_3", .{ .width = .{ .px = 12 }, .height = .{ .px = 12 }, .flex_shrink = 0 }));
        } else {
            const spacer = try ui.box(cx, .{ .width = .{ .px = 12 }, .height = .{ .px = 12 }, .flex_shrink = 0 }, .{});
            try row.appendChild(cx.allocator, spacer);
        }
        const icon_asset: ui.SvgAsset = switch (item.kind) {
            .directory => if (item.expanded) ui.icons.folder_open else ui.icons.folder,
            .symlink => ui.icons.link,
            .file => file_icons.asset(item.path),
        };
        const icon_tint = switch (item.kind) {
            .directory => T.current().accent,
            .symlink => T.current().fg_2,
            .file => file_icons.color(item.path),
        };
        try row.appendChild(cx.allocator, try ui.iconTint(cx, icon_asset, icon_tint, .{ .width = .{ .px = 14 }, .height = .{ .px = 14 }, .flex_shrink = 0 }));
        const name = if (item.kind == .directory)
            try ui.textStyled(cx, S.fileRowDirectoryName, item.name)
        else
            try ui.textStyled(cx, S.fileRowName, item.name);
        name.setStyleInline(cx.allocator, .{ .width = .fill(), .min_width = 0 });
        try row.appendChild(cx.allocator, name);
        if (item.added != 0) {
            const added = try ui.textStyled(cx, S.fileAdd, "");
            var buffer: [16]u8 = undefined;
            try added.setTextContent(cx.allocator, try std.fmt.bufPrint(&buffer, "+{d}", .{item.added}));
            added.setStyleInline(cx.allocator, .{ .width = .{ .fit = .{} }, .flex_shrink = 0 });
            try row.appendChild(cx.allocator, added);
        }
        if (item.removed != 0) {
            const removed = try ui.textStyled(cx, S.fileRemove, "");
            var buffer: [16]u8 = undefined;
            try removed.setTextContent(cx.allocator, try std.fmt.bufPrint(&buffer, "−{d}", .{item.removed}));
            removed.setStyleInline(cx.allocator, .{ .width = .{ .fit = .{} }, .flex_shrink = 0 });
            try row.appendChild(cx.allocator, removed);
        }
        try self.file_list.appendChild(cx.allocator, row);
    }
    ui.widgets.setScrollY(self.file_scroll.state, self.file_scroll.content, 0);
}

fn clearSessionRows(self: *View) void {
    clearRows(self, &self.session_list, &self.list_scope);
}

fn clearFileRows(self: *View) void {
    clearRows(self, &self.file_list, &self.file_scope);
}

fn clearRows(self: *View, list: **ui.Node, child_scope: *?*ui.Scope) void {
    if (child_scope.*) |scope| {
        scope.dispose();
        child_scope.* = null;
    }
    const node = list.*;
    if (self.cx.focused_node) |focused| if (focused.isDescendantOf(node)) self.cx.clearFocus();
    if (self.cx.pressed_node) |pressed| if (pressed.isDescendantOf(node)) self.cx.cancelPointerInteractions(.explicit);
    while (node.children.items.len != 0) {
        const child = node.children.items[0];
        self.cx.detachChild(node, child);
        self.cx.destroyDetached(child);
    }
}

pub fn toggle_left_rail(self: *View) void {
    const next = !self.left_collapsed;
    set_left_collapsed(self, next);
    if (self.callbacks.toggle_left_rail) |callback| callback(self.callbacks.context, next);
}

pub fn toggle_inspector(self: *View) void {
    const next = !self.inspector_open;
    set_inspector_open(self, next);
    if (self.callbacks.toggle_inspector) |callback| callback(self.callbacks.context, next);
}

pub fn close_inspector(self: *View) void {
    set_inspector_open(self, false);
    if (self.callbacks.close_inspector) |callback| callback(self.callbacks.context);
}

fn newChat(self: *View) void {
    if (self.callbacks.new_chat) |callback| callback(self.callbacks.context);
}

fn selectConversation(self: *View, id: []const u8) void {
    // Historical previews/restore confirmations must not mark a row current
    // before the host's actual binding has been changed.
    if (self.callbacks.select_conversation) |callback| callback(self.callbacks.context, id);
}

fn selectFile(self: *View, path: []const u8) void {
    self.selected_file.set(path);
    self.cx.requestRedraw();
    if (self.callbacks.select_file) |callback| callback(self.callbacks.context, path);
}

fn insertFileReference(self: *View) void {
    if (self.preview_path.len == 0) return;
    if (self.preview_reference_requires_approval and !self.preview_reference_available) return;
    if (self.callbacks.insert_file_reference) |callback| callback(self.callbacks.context, self.preview_path);
}

/// Host entry point for restoring or clearing the rail filter. The native
/// Input reports user keystrokes through the same path.
pub fn set_search_query(self: *View, value: []const u8) void {
    replaceBytes(self.cx.allocator, &self.search_text, value) catch return;
    self.sessions_rebuild_pending = true;
    self.cx.requestRedraw();
    if (self.callbacks.search_changed) |callback| callback(self.callbacks.context, value);
}

fn activateTab(self: *View, tab: InspectorTab, notify: bool) void {
    set_inspector_tab(self, tab);
    if (notify) if (self.callbacks.select_inspector_tab) |callback| callback(self.callbacks.context, tab);
}

fn afterLayout(raw: *anyopaque, _: u8, _: bool) ui.AfterLayoutResult {
    const self: *View = @ptrCast(@alignCast(raw));
    var relayout = layoutPreviewImage(self);
    if (self.sessions_rebuild_pending) {
        self.sessions_rebuild_pending = false;
        clearSessionRows(self);
        buildSessionRows(self) catch {};
        relayout = true;
    }
    const width = self.root.globalRect().w;
    if (width <= 0) return if (relayout) .needs_layout else .done;
    const compact = width < S.compact_width;
    if (compact == self.compact) return if (relayout) .needs_layout else .done;
    self.compact = compact;
    var changed = false;
    if (compact) {
        if (!self.left_collapsed) {
            set_left_collapsed(self, true);
            changed = true;
        }
        if (self.inspector_open) {
            set_inspector_open(self, false);
            changed = true;
        }
    }
    return if (changed) .needs_layout else .done;
}

fn cleanup(self: *View) void {
    self.cx.removeAfterLayoutHook(self);
    releasePreviewTexture(self);
    freeSessions(self);
    freeFiles(self);
    freeBytes(self.cx.allocator, &self.search_text);
    freeBytes(self.cx.allocator, &self.preview_name);
    freeBytes(self.cx.allocator, &self.preview_path);
    freeBytes(self.cx.allocator, &self.preview_diff);
    freeBytes(self.cx.allocator, &self.preview_source);
}

fn storeConversation(allocator: std.mem.Allocator, source: Conversation) !StoredConversation {
    var id = try dupeOrEmpty(allocator, source.id);
    errdefer freeBytes(allocator, &id);
    var title = try dupeOrEmpty(allocator, source.title);
    errdefer freeBytes(allocator, &title);
    var subtitle = try dupeOrEmpty(allocator, source.subtitle);
    errdefer freeBytes(allocator, &subtitle);
    return .{ .id = id, .title = title, .subtitle = subtitle, .selected = source.selected };
}

fn storeFile(allocator: std.mem.Allocator, source: FileRow) !StoredFile {
    var path = try dupeOrEmpty(allocator, source.path);
    errdefer freeBytes(allocator, &path);
    const effective_name = if (source.name.len != 0) source.name else std.fs.path.basename(source.path);
    var name = try dupeOrEmpty(allocator, effective_name);
    errdefer freeBytes(allocator, &name);
    return .{ .path = path, .name = name, .depth = source.depth, .kind = source.kind, .expanded = source.expanded, .added = source.added, .removed = source.removed, .selected = source.selected };
}

fn freeStoredConversation(allocator: std.mem.Allocator, item: StoredConversation) void {
    var id = item.id;
    var title = item.title;
    var subtitle = item.subtitle;
    freeBytes(allocator, &id);
    freeBytes(allocator, &title);
    freeBytes(allocator, &subtitle);
}

fn freeStoredFile(allocator: std.mem.Allocator, item: StoredFile) void {
    var path = item.path;
    var name = item.name;
    freeBytes(allocator, &path);
    freeBytes(allocator, &name);
}

fn freeSessions(self: *View) void {
    for (self.sessions.items) |item| freeStoredConversation(self.cx.allocator, item);
    self.sessions.deinit(self.cx.allocator);
    self.sessions = .empty;
}

fn freeFiles(self: *View) void {
    for (self.files.items) |item| freeStoredFile(self.cx.allocator, item);
    self.files.deinit(self.cx.allocator);
    self.files = .empty;
}

fn findFile(self: *View, path: []const u8) ?[]const u8 {
    for (self.files.items) |item| if (std.mem.eql(u8, item.path, path)) return item.path;
    return null;
}

fn sessionMatches(conversation: *const StoredConversation, query: []const u8) bool {
    return containsIgnoreCase(conversation.title, query) or containsIgnoreCase(conversation.subtitle, query);
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var start: usize = 0;
    while (start + needle.len <= haystack.len) : (start += 1) {
        var index: usize = 0;
        while (index < needle.len) : (index += 1) {
            if (std.ascii.toLower(haystack[start + index]) != std.ascii.toLower(needle[index])) break;
        }
        if (index == needle.len) return true;
    }
    return false;
}

fn replaceBytes(allocator: std.mem.Allocator, destination: *[]u8, value: []const u8) !void {
    const copy = try dupeOrEmpty(allocator, value);
    freeBytes(allocator, destination);
    destination.* = copy;
}

fn dupeOrEmpty(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    if (value.len == 0) return emptyBytes();
    return allocator.dupe(u8, value);
}

fn emptyBytes() []u8 {
    return @constCast(&[_]u8{});
}

fn freeBytes(allocator: std.mem.Allocator, bytes: *[]u8) void {
    if (bytes.len != 0) allocator.free(bytes.*);
    bytes.* = emptyBytes();
}

fn recolorButtonContents(node: *ui.Node, color: ui.Color) void {
    if (node.getText() != null) {
        node.setTextColor(color);
        return;
    }
    if (node.getIcon() != null) {
        _ = node.setTint(color);
        return;
    }
    for (node.children.items) |child| recolorButtonContents(child, color);
}

fn lineNumbers(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var count: usize = 1;
    for (text) |byte| if (byte == '\n') {
        count += 1;
    };
    if (text.len != 0 and text[text.len - 1] == '\n') count -= 1;
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    try output.ensureTotalCapacity(allocator, count * 4);
    var buffer: [24]u8 = undefined;
    for (0..count) |index| {
        const line = try std.fmt.bufPrint(&buffer, "{d}\n", .{index + 1});
        try output.appendSlice(allocator, line);
    }
    return output.toOwnedSlice(allocator);
}
