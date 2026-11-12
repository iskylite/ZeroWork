//! Native notes presentation. The same renderer may be reparented within its
//! window; the document lease and the active Textarea outlive that handoff.
const std = @import("std");
const ui = @import("ui");
const contract = @import("../../host/plugin_ui_contract.zig");
const identity = @import("../../host/identity.zig");
const icons = @import("../../ui/file_workspace_icons.zig");
const scoped_modal = @import("../../ui/scoped_modal.zig");
const FileSheet = @import("../../platform/file_sheet.zig").Sheet;
const model = @import("model.zig");
const Store = @import("store.zig").Store;
const sessions = @import("document_sessions.zig");
const editor = @import("editor.zig");
const search_view = @import("editor_search.zig");
const editor_settings = @import("editor_settings.zig");
const management = @import("editor_management.zig");
const editor_images = @import("editor_images.zig");
const editor_clipboard = @import("editor_clipboard.zig");
const assets = @import("assets.zig");
const frames = @import("../../host/frame_texture_sink.zig");
const queries = @import("queries.zig");
const S = @import("styles.zig");
const terminal_search = @import("../../ui/terminal_search.zig");

const Directory = search_view.Directory;
const Create = union(enum) { library, folder: Directory, note: Directory };
const SearchSelection = struct {
    revision: u64,
    source: bool,
    editing: bool,
    anchor: u32,
    caret: u32,
};
const SearchOrigin = struct { key: ?model.NoteKey, scroll: f32, selection: ?SearchSelection };
const TreeNote = struct { key: model.NoteKey, folder: ?model.FolderId, title: []const u8, read_only: bool };
const MoreMenu = struct { button: *ui.Node, open: *ui.Signal(bool), wrapper: *ui.Node };
const Card = enum { none, tree, outline, search };
const BodyMode = struct { key: model.NoteKey, read_only: bool, source: bool, can_lock: bool };
const BlockRow = struct { height: f32, top: f32 = 0, rendered: ?*RenderedBlock = null };
const RenderedBlock = struct {
    index: usize,
    node: *ui.Node,
    scope: *ui.Scope,
    edit: ?*Click = null,
    image: ?*editor_images.Image = null,
};
const EditorRow = struct { node: *ui.Node, scope: *ui.Scope };
const RenderCounts = struct { layouts: usize = 0, parses: usize = 0, mounts: usize = 0, decodes: usize = 0, redraws: usize = 0 };
const ImportFeedback = union(enum) { idle, running, failed: anyerror };
const ImportNotice = struct { root: *ui.Node, message: *ui.Node, retry: *ui.Node, cancel_label: *ui.Signal([]const u8) };
const block_gap: f32 = 18;
const EditBoundary = struct {
    previous: []u8,
    body_generation: u64,
};
const SaveWorker = struct {
    store: *Store,
    packet: sessions.Commit,
    refresh_tree: bool,
    result: sessions.Receipt = undefined,
    done: std.atomic.Value(bool) = .init(false),
    thread: std.Thread = undefined,

    fn run(self: *SaveWorker) void {
        self.result = self.packet.run(self.store);
        self.done.store(true, .release);
    }
};
const Action = union(enum) {
    select_note: model.NoteKey,
    focus_editor: model.NoteKey,
    select_directory: Directory,
    begin_block: struct { range: editor.Block, offset: ?usize = null },
    append_block,
    end_block,
    toggle_source,
    preview_editor_image,
    toggle_read_only,
    wait_to_lock,
    cancel_import_and_lock,
    create: Create,
    manage: management.Request,
    browse_tree,
    toggle_tree,
    toggle_outline,
    dismiss_card,
    jump_to_heading: usize,
    find_document,
    undo: bool,
    search,
    search_back,
    search_hit: queries.SourceRef,
    source_ref: queries.SourceRef,
};

const View = struct {
    cx: *ui.Cx,
    scope: *ui.Scope,
    store: *Store,
    documents: *sessions.Sessions,
    owner: identity.SessionHandle,
    save_feedback: ?ui.Handler(?[]const u8),
    save_notice: bool = false,
    focus_content: ?contract.ContentFocus,
    root: *ui.Node = undefined,
    main: *ui.Node = undefined,
    tree: *ui.Node = undefined,
    tree_content: *ui.Node = undefined,
    tree_geometry_refresh: bool = true,
    body: *ui.Node = undefined,
    body_content: *ui.Node = undefined,
    body_scroll: ui.widgets.ScrollAreaResult = undefined,
    body_mode: ?BodyMode = null,
    blocks_host: ?*ui.Node = null,
    append_button: ?*ui.Node = null,
    blocks_text: ?[]u8 = null,
    block_ranges: []editor.Block = &.{},
    block_rows: []BlockRow = &.{},
    rendered_blocks: std.ArrayList(*RenderedBlock) = .empty,
    editing_row: ?EditorRow = null,
    block_width: f32 = 0,
    block_compact: bool = false,
    block_theme: u32 = 0,
    render_counts: RenderCounts = .{},
    body_generation_seen: ?u64 = null,
    read_revision_seen: ?u64 = null,
    search: *search_view.Search = undefined,
    search_button: *ui.Node = undefined,
    search_back_button: *ui.Node = undefined,
    settings: *editor_settings.Settings = undefined,
    manager: *management.Manager = undefined,
    texture_backend: ?frames.Backend = null,
    images: std.ArrayList(*editor_images.Image) = .empty,
    image_poll_timer: ?u64 = null,
    image_button: *ui.Node = undefined,
    image_disabled: *ui.Signal(bool),
    image_open: *ui.Signal(bool),
    image_modal_dialog: *ui.Node = undefined,
    image_modal_node: *ui.Node = undefined,
    viewed_image: ?*editor_images.Image = null,
    editor_image: ?struct { scope: *ui.Scope, image: *editor_images.Image, pending: bool = true } = null,
    image_picker: ?struct { sheet: FileSheet, lease: sessions.Lease } = null,
    import_notice: ?ImportNotice = null,
    import_input: ?struct { lease: sessions.Lease, input: editor_images.ImportInput } = null,
    import_ticket: ?sessions.ImportTicket = null,
    import_waiting_for_editor: bool = false,
    import_job: ?*editor_images.Import = null,
    import_timer: ?u64 = null,
    import_feedback: ImportFeedback = .idle,
    directory_shield: *ui.Node = undefined,
    toggle: *ui.Node = undefined,
    path_slot: *ui.Node = undefined,
    path_button: *ui.Node = undefined,
    path_row: *ui.Node = undefined,
    path_max_width: f32 = 0,
    path_library: *ui.Node = undefined,
    path_folders: *ui.Node = undefined,
    path_leaf: *ui.Node = undefined,
    path_folder_group: *ui.Node = undefined,
    outline_button: *ui.Node = undefined,
    outline_hint: *ui.Node = undefined,
    outline_card: *ui.Node = undefined,
    outline_rows: *ui.Node = undefined,
    outline_scope: ?*ui.Scope = null,
    outline_dirty: bool = false,
    card: Card = .none,
    layout_height: f32 = 0,
    heading_target: ?usize = null,
    find_button: *ui.Node = undefined,
    source_button: *ui.Node = undefined,
    recent_button: *ui.Node = undefined,
    document_menu: *ui.Node = undefined,
    find_model: terminal_search.Model,
    find_view: terminal_search.View = undefined,
    find_reveal: bool = false,
    find_theme: u32 = 0,
    toolbar: *ui.Node = undefined,
    directory_header: *ui.Node = undefined,
    directory_add: *ui.Node = undefined,
    tree_scroll: ui.widgets.ScrollAreaResult = undefined,
    tree_selection: ?*ui.Node = null,
    focus_tree: bool = false,
    floating_header: ?FloatingHeader = null,
    lock: *ui.Node = undefined,
    unlock: *ui.Node = undefined,
    lock_choice: *ui.Signal(bool),
    edit_disabled: *ui.Signal(bool),
    lock_status: *ui.Node = undefined,
    lock_mode: ?sessions.SaveMode = null,
    lock_failure: ?sessions.SaveMode = null,
    lock_after_import: bool = false,
    lock_focus: ?ui.hit.NodeHandle = null,
    banner: *ui.Node = undefined,
    error_text: *ui.Node = undefined,
    retry: *ui.Node = undefined,
    save_banner: bool = false,
    body_scope: ?*ui.Scope = null,
    tree_scope: ?*ui.Scope = null,
    tree_actions: std.ArrayList(*TreeActions) = .empty,
    collapsed_branches: std.ArrayList(Directory) = .empty,
    name_open: *ui.Signal(bool),
    name_title: *ui.Signal([]const u8),
    name_value: *ui.Signal([]const u8),
    name_input: *ui.Node = undefined,
    name_error: *ui.Node = undefined,
    create_request: ?Create = null,
    focus_name: bool = false,
    active: bool = false,
    disposed: bool = false,
    compact: ?bool = null,
    tree_preference: ?bool = null,
    tree_open: bool = false,
    tree_dirty: bool = true,
    body_dirty: bool = true,
    layout_dirty: bool = true,
    focus_pending: bool = false,
    saved_focus: ?ui.hit.NodeHandle = null,
    presentation_focus: ?ui.hit.NodeHandle = null,
    directory: ?Directory = null,
    directory_selected: bool = false,
    key: ?model.NoteKey = null,
    lease: ?sessions.Lease = null,
    occupied: ?identity.SessionHandle = null,
    editing: bool = false,
    reading_caret: ?usize = null,
    edit_boundary: ?EditBoundary = null,
    source_mode: bool = false,
    editor_offset: ?usize = null,
    input: ?ui.widgets.input.TextareaResult = null,
    title: ?ui.widgets.EditableTextResult = null,
    title_label: ?*ui.Node = null,
    title_width: f32 = 0,
    title_invalid: bool = false,
    title_rejected: bool = false,
    title_dirty: bool = false,
    body_error: ?anyerror = null,
    search_open: bool = false,
    search_origin: ?SearchOrigin = null,
    search_selection_restore: ?SearchSelection = null,
    source_range: ?struct { revision: u64, range: queries.Range } = null,
    scroll_restore: ?f32 = null,
    save_timer: ?u64 = null,
    save_deadline_ns: ?i128 = null,
    save_worker: ?*SaveWorker = null,
    save_poll_timer: ?u64 = null,
    save_queued: bool = false,
    pending: ?Action = null,

    fn selectNote(self: *View, key: model.NoteKey) !void {
        if (std.meta.eql(self.key, @as(?model.NoteKey, key)) and self.occupied == null) return;
        try self.finishInput();
        try self.flushDraft();
        try self.finishBoundary();

        // Load and acquire the next lease before releasing the existing view.
        // A read or save failure leaves the original editor mounted.
        var committed = try self.store.loadNote(self.cx.allocator, key, .active);
        defer committed.deinit();
        var library = try self.store.loadLibrary(self.cx.allocator, key.library_id, .active);
        defer library.deinit();
        const folder = committed.value.folder_id;
        const depth = library.value.folderDepth(folder) orelse return error.Unavailable;
        const access = try self.documents.open(key, self.owner);
        const next_lease: ?sessions.Lease = switch (access) {
            .lease => |lease| lease,
            .occupied => null,
        };
        errdefer if (next_lease) |lease| self.documents.release(lease) catch {};
        if (self.lease) |old| try self.documents.release(old);
        self.cancelImagePicker();
        self.lease = next_lease;
        self.body_generation_seen = null;
        self.read_revision_seen = null;
        self.clearImportInput();
        self.import_feedback = .idle;
        self.syncImportFeedback();
        self.occupied = switch (access) {
            .lease => null,
            .occupied => |owner| owner,
        };
        self.lock_failure = null;
        if (!std.meta.eql(self.key, @as(?model.NoteKey, key))) self.scroll_restore = 0;
        self.key = key;
        self.heading_target = null;
        self.showCard(.none);
        self.directory = .{ .library = key.library_id, .folder = folder, .depth = depth };
        self.directory_selected = false;
        self.expandDirectoryPath(library.value, folder);
        self.editing = false;
        self.reading_caret = null;
        self.editor_offset = null;
        self.source_mode = false;
        self.source_range = null;
        self.title_invalid = false;
        self.title_rejected = false;
        self.title_dirty = false;
        self.body_error = null;
        self.body_dirty = true;
        self.tree_dirty = true;
        self.focus_pending = true;
        self.clearError();
        if (self.compact == true) {
            self.tree_preference = false;
            self.layout_dirty = true;
        }
        if (committed.value.body_md.len == 0 and self.lease != null and !committed.value.read_only) {
            self.editing = true;
        }
    }

    fn beginEditing(self: *View, offset: usize) !void {
        try self.finishInput();
        const lease = self.lease orelse return;
        if ((try self.documents.snapshot(lease)).read_only) return;
        self.editor_offset = offset;
        self.reading_caret = null;
        self.editing = true;
        self.source_mode = false;
        self.focus_pending = true;
        self.body_dirty = true;
    }

    fn perform(self: *View, action: Action) !void {
        switch (action) {
            .select_note => |key| {
                try self.selectNote(key);
                if (self.card == .tree) {
                    self.showCard(.none);
                    self.focusDocument();
                }
            },
            .focus_editor => |key| {
                if (self.documents.ownerFor(key)) |owner| {
                    const callback = self.focus_content orelse return error.DocumentInUse;
                    if (!callback.focus(callback.context, owner)) return error.DocumentInUse;
                } else {
                    try self.selectNote(key);
                    self.focusDocument();
                }
            },
            .select_directory => |directory| {
                self.directory = directory;
                self.directory_selected = true;
                self.tree_dirty = true;
                if (self.card == .tree) {
                    if (self.collapsedIndex(directory)) |index| _ = self.collapsed_branches.swapRemove(index);
                    self.cx.setFocus(self.path_button);
                    if (self.key == null) try self.updateBreadcrumb();
                }
                if (self.key == null) self.body_dirty = true;
            },
            .begin_block => |block| try self.beginEditing(block.range.start + (block.offset orelse 0)),
            .append_block => {
                const lease = self.lease orelse return;
                try self.beginEditing((try self.documents.snapshot(lease)).body_md.len);
            },
            .end_block => {
                try self.finishInput();
                try self.finishBoundary();
                if (self.input) |input| self.reading_caret = input.state.cursor.offset;
                self.editing = false;
                self.focus_pending = true;
                self.body_dirty = true;
            },
            .toggle_source => {
                if (self.key == null) return;
                try self.finishInput();
                try self.flushDraft();
                try self.finishBoundary();
                self.showCard(.none);
                const offset = if (self.input) |input| input.state.cursor.offset else null;
                self.source_mode = !self.source_mode;
                self.editing = false;
                if (self.source_mode) self.editor_offset = offset else self.reading_caret = offset;
                self.focus_pending = true;
                self.body_dirty = true;
            },
            .preview_editor_image => try self.previewEditorImage(),
            .toggle_read_only => {
                if (self.lock_mode != null) return;
                if (self.import_ticket != null or self.import_waiting_for_editor) {
                    self.lock_choice.set(true);
                } else {
                    try self.commitReadOnly();
                }
            },
            .wait_to_lock => {
                self.lock_choice.set(false);
                if (self.import_ticket == null and !self.import_waiting_for_editor) return self.commitReadOnly();
                self.lock_after_import = true;
                if (self.import_feedback == .failed) self.retryImport();
            },
            .cancel_import_and_lock => {
                self.lock_choice.set(false);
                self.cancelImport();
                try self.commitReadOnly();
            },
            .create => |request| self.openCreate(request),
            .manage => |request| {
                if (request == .recent) self.showCard(.none);
                if (request == .move or request == .delete) {
                    try self.finishInput();
                    try self.flushDraft();
                }
                try self.manager.show(request);
            },
            .browse_tree => {
                if (self.floating_header == null and self.treePinned()) {
                    self.showCard(.none);
                    self.focus_tree = true;
                } else {
                    self.showCard(if (self.card == .tree) .none else .tree);
                    self.focus_tree = self.card == .tree;
                }
            },
            .toggle_tree => {
                if (self.floating_header != null) {
                    try self.perform(.browse_tree);
                } else {
                    self.tree_preference = !self.treePinned();
                    self.showCard(.none);
                    self.layout_dirty = true;
                }
            },
            .toggle_outline => {
                if (self.card == .outline) return self.showCard(.none);
                if (self.key == null) return;
                try self.rebuildOutline();
                self.showCard(.outline);
            },
            .dismiss_card => {
                if (self.card == .none and self.floating_header == null) {
                    self.tree_preference = false;
                    self.layout_dirty = true;
                    return;
                }
                self.showCard(.none);
                self.focusDocument();
            },
            .jump_to_heading => |offset| {
                if (self.card != .outline) return;
                try self.finishInput();
                if (self.outline_dirty or self.body_dirty) return;
                if (self.compact == true) self.showCard(.none);
                if (self.input != null) {
                    _ = self.revealEditorRange(.{ .start = offset, .end = offset }, true);
                } else {
                    self.heading_target = offset;
                }
                self.focusDocument();
            },
            .find_document => try self.openDocumentFind(),
            .undo => |redo| {
                const lease = self.lease orelse return;
                const saved = try self.documents.snapshot(lease);
                if (saved.read_only) return;
                const changed = if (redo) try self.documents.redo(saved.stamp) else try self.documents.undo(saved.stamp);
                if (changed) {
                    self.body_dirty = true;
                    self.scheduleSave();
                }
            },
            .search => {
                if (self.search_open) {
                    self.search.focus();
                    return;
                }
                try self.finishInput();
                try self.flushDraft();
                if (self.search_origin == null) {
                    self.search_origin = .{ .key = self.key, .scroll = self.body_scroll.state.scroll_y, .selection = self.searchSelection() };
                    self.search.setDirectory(self.directory);
                }
                self.showSearch(true);
                self.search.focus();
            },
            .search_back => {
                const origin = self.search_origin orelse return;
                if (origin.key) |key| {
                    try self.selectNote(key);
                    self.scroll_restore = origin.scroll;
                    if (origin.selection) |selection| try self.restoreSearchSelection(selection);
                } else {
                    try self.finishInput();
                    try self.finishBoundary();
                    if (self.lease) |lease| try self.documents.release(lease);
                    self.lease = null;
                    self.key = null;
                    self.occupied = null;
                    self.editing = false;
                    self.body_dirty = true;
                }
                self.search_origin = null;
                self.showSearch(false);
                self.focusDocument();
            },
            .search_hit => |source| {
                try self.selectSource(source);
                self.showSearch(false);
                self.focusDocument();
            },
            .source_ref => |source| {
                try self.selectSource(source);
                self.search_origin = null;
                self.showSearch(false);
            },
        }
    }

    fn showSearch(self: *View, shown: bool) void {
        if (shown) self.showCard(.none);
        self.search_open = shown;
        self.main.setDisplay(if (shown) .none else .flex);
        self.syncToolbarVisibility();
        self.search.root.setDisplay(if (shown) .flex else .none);
        self.search.setActive(self.active and shown);
        if (shown) {
            self.cancelImagePoll();
            for (self.images.items) |image| image.pause();
        }
        self.syncDocumentTools();
        self.layout_dirty = true;
    }

    fn syncToolbarVisibility(self: *View) void {
        self.toolbar.setDisplay(if (self.floating_header != null and self.search_open) .none else .flex);
    }

    fn treePinned(self: *const View) bool {
        return self.tree_preference orelse (self.compact != true);
    }

    fn showCard(self: *View, card: Card) void {
        if (self.card == card) return;
        if (self.card == .search) {
            if (self.find_view.input_result.state.imeIsComposing()) self.find_view.input_result.state.cancelImeComposition();
            self.find_model.close();
            self.find_model.composing = false;
            self.find_reveal = false;
            self.paintFindMatch(null);
        }
        self.card = card;
        switch (card) {
            .tree => self.cx.setFocus(self.path_button),
            .outline => self.cx.setFocus(self.outline_button),
            else => {},
        }
        self.layout_dirty = true;
        self.redraw();
    }

    fn currentBody(self: *View) ![]const u8 {
        if (self.lease) |lease| return (try self.documents.snapshot(lease)).body_md;
        if (self.input) |input| return input.state.getText();
        return self.blocks_text orelse "";
    }

    fn rebuildOutline(self: *View) !void {
        const a = self.cx.allocator;
        const scope = try self.replaceContent(self.outline_rows, &self.outline_scope);
        const body = try self.currentBody();
        const ranges = try editor.blocks(a, body);
        defer a.free(ranges);
        for (ranges) |range| {
            const heading = editor.heading(range.text(body)) orelse continue;
            if (heading.title.len == 0) continue;
            const click = try scope.createState(Click, .{ .view = self, .action = .{ .jump_to_heading = range.start } });
            const row = try ui.widgets.Button(.{
                .variant = .ghost,
                .a11y_label = try scope.createText(heading.title, .{}),
                .base_style = ui.BoxStyle{
                    .width = .fill(),
                    .height = .{ .px = S.outline_row_height },
                    .justify = .start,
                    .padding = .{ .left = 8 + 10 * @as(f32, @floatFromInt(heading.level - 1)), .right = 8 },
                    .border = .{ .radius = 6 },
                    .flex_shrink = 0,
                    .overflow_hidden = true,
                },
                .on_click = self.cx.on(Click, click, Click.invoke),
            }).mount(scope, self.cx);
            row.meta.ownership.meta.test_id = "notes.outline.heading";
            var style = S.text(12.5, if (heading.level <= 2) 550 else 400, S.theme.current().fg_1);
            style.text_overflow = .ellipsis;
            style.selectable = false;
            const label = try ui.text(self.cx, "", style);
            try label.setTextContent(a, heading.title);
            S.theme.bindInk(label, "fg_1");
            label.setStyleInline(a, .{ .width = .fill(), .min_width = 0 });
            try row.appendChild(a, label);
            try self.outline_rows.appendChild(a, row);
        }
        if (self.outline_rows.children.items.len == 0) {
            const empty = try ui.text(self.cx, "此文档没有标题", S.text(12, 400, S.theme.current().fg_2));
            S.theme.bindInk(empty, "fg_2");
            empty.setStyleInline(a, .{ .height = .{ .px = S.outline_row_height }, .padding = .{ .left = 8, .top = 5 } });
            try self.outline_rows.appendChild(a, empty);
        }
        self.outline_dirty = false;
        self.layout_dirty = true;
    }

    fn openDocumentFind(self: *View) !void {
        if (self.key == null) return;
        if (self.card != .search) {
            try self.finishInput();
            try self.find_model.setSource(try self.currentBody());
            self.find_model.open = true;
            self.showCard(.search);
            self.find_view.root.setDisplay(.flex);
            self.findChanged();
        }
        self.find_view.focus();
    }

    fn findChanged(self: *View) void {
        self.find_view.refresh();
        self.find_theme = self.cx.theme_version;
        self.find_reveal = true;
        self.redraw();
    }

    fn findQuery(raw: ?*anyopaque, _: []const u8) void {
        const self: *View = @ptrCast(@alignCast(raw.?));
        self.findChanged();
    }

    fn findNext(raw: ?*anyopaque) void {
        const self: *View = @ptrCast(@alignCast(raw.?));
        self.find_model.next();
        self.findChanged();
    }

    fn findPrevious(raw: ?*anyopaque) void {
        const self: *View = @ptrCast(@alignCast(raw.?));
        self.find_model.previous();
        self.findChanged();
    }

    fn findClose(raw: ?*anyopaque) void {
        const self: *View = @ptrCast(@alignCast(raw.?));
        self.enqueue(.dismiss_card);
    }

    fn currentFindMatch(self: *const View) ?terminal_search.Model.Match {
        if (self.card != .search) return null;
        return self.find_model.match(self.find_model.currentIndex() orelse return null);
    }

    fn revealEditorRange(self: *View, range: terminal_search.Model.Match, align_top: bool) bool {
        const input = self.input orelse return false;
        const a11y = input.input.behavior.interaction.a11y orelse return false;
        const text = a11y.editable_text orelse return false;
        const start: u32 = @intCast(range.start);
        const end: u32 = @intCast(range.end);
        _ = input.state.setAccessibilitySelection(start, end);
        if (text.scroll_into_view) |scroll| _ = scroll(text.context, start, end, align_top);
        return true;
    }

    fn paintFindMatch(self: *View, hit: ?terminal_search.Model.Match) void {
        for (self.rendered_blocks.items) |rendered| {
            const range = self.block_ranges[rendered.index];
            const selected = if (hit) |match| match.start < range.end and match.end > range.start else false;
            const color = if (selected) S.theme.current().selection else ui.Color.TRANSPARENT;
            rendered.node.setBackground(color);
        }
    }

    fn searchSelection(self: *View) ?SearchSelection {
        if (self.body_dirty or (!self.source_mode and !self.editing)) return null;
        const input = self.input orelse return null;
        const lease = self.lease orelse return null;
        const document = self.documents.snapshot(lease) catch return null;
        return .{
            .revision = document.stamp.base_revision,
            .source = self.source_mode,
            .editing = self.editing,
            .anchor = @intCast(input.state.cursor.anchor orelse input.state.cursor.offset),
            .caret = @intCast(input.state.cursor.offset),
        };
    }

    fn restoreSearchSelection(self: *View, selection: SearchSelection) !void {
        const lease = self.lease orelse return;
        const document = try self.documents.snapshot(lease);
        if (document.stamp.base_revision != selection.revision or document.dirty) return;
        if (self.body_dirty or self.input == null or self.source_mode != selection.source or self.editing != selection.editing) {
            try self.finishBoundary();
            self.editing = selection.editing;
            self.source_mode = selection.source;
            self.focus_pending = true;
            self.body_dirty = true;
        }
        self.search_selection_restore = selection;
    }

    fn searchBack(raw: *anyopaque) void {
        const self: *View = @ptrCast(@alignCast(raw));
        self.enqueue(.search_back);
    }

    fn searchOpen(raw: *anyopaque, source: queries.SourceRef) void {
        const self: *View = @ptrCast(@alignCast(raw));
        self.enqueue(.{ .search_hit = source });
    }

    fn selectSource(self: *View, source: queries.SourceRef) !void {
        const resolver: queries.Queries = .{ .store = self.store };
        const resolved = try resolver.resolveSource(self.cx.allocator, source, null);
        if (resolved.state == .deleted) {
            try self.manager.show(.recent);
            self.setBanner("笔记已删除", false);
            return;
        }
        try self.selectNote(source.key);
        const draft_dirty = if (self.lease) |lease| (try self.documents.snapshot(lease)).dirty else false;
        if (resolved.state == .current and !draft_dirty) {
            self.source_range = .{ .revision = source.revision, .range = resolved.range.? };
            if (self.input == null) self.body_dirty = true;
        } else {
            self.source_range = null;
            if (!draft_dirty) self.scroll_restore = 0;
            self.setBanner("内容已更新", false);
        }
    }

    fn enqueue(self: *View, action: Action) void {
        if (!self.active or self.disposed) return;
        self.pending = action;
        self.redraw();
    }

    fn redraw(self: *View) void {
        if (!self.active or self.disposed) return;
        self.render_counts.redraws += 1;
        self.cx.requestRedraw();
    }

    fn afterLayout(raw: *anyopaque, _: u8, _: bool) ui.AfterLayoutResult {
        const self: *View = @ptrCast(@alignCast(raw));
        if (self.disposed or !self.active) return .done;
        self.render_counts.layouts += 1;
        if (self.pending) |pending| {
            self.pending = null;
            self.perform(pending) catch |err| self.showError(err);
        }
        self.pollImagePicker();
        const width = self.root.globalRect().w;
        const compact = (if (width > 0) width else self.cx.viewport.width) < S.compact_width;
        var changed = self.manager.tick();
        if (self.fitImageViewer()) changed = true;
        const height = self.root.globalRect().h;
        if (self.compact != compact or self.layout_dirty or height != self.layout_height) {
            self.layout_height = height;
            self.applyLayout(compact);
            changed = true;
        }
        if (self.tree_dirty) {
            self.tree_dirty = false;
            self.rebuildTree() catch |err| self.showError(err);
            changed = true;
        } else if (self.tree_geometry_refresh and self.tree_open and self.tree_content.globalRect().w > 0) {
            self.tree_geometry_refresh = false;
            // Moving content from a hidden tab can restore the scroll viewport
            // while leaving its retained rows with zero layout bounds.
            if (self.tree_content.children.items.len != 0 and self.tree_content.children.items[0].globalRect().h <= 0) {
                self.rebuildTree() catch |err| self.showError(err);
                changed = true;
            }
        }
        if (self.updateTreeActions()) changed = true;
        if (self.card == .tree and self.fitTreeCard()) changed = true;
        if (self.tree_open and self.focus_tree and self.tree_scroll.container.globalRect().h > 0) {
            self.focus_tree = false;
            self.revealTreeSelection();
            changed = true;
        }
        if (!self.search_open and self.fitPath()) changed = true;
        const refresh_outline = self.card == .outline and (self.outline_dirty or self.body_dirty);
        if (self.search_open) {
            if (self.search.restoreScroll()) changed = true;
        } else if (self.body_dirty) {
            self.body_dirty = false;
            self.rebuildBody() catch |err| self.showError(err);
            changed = true;
        } else {
            if (self.scroll_restore) |offset| {
                self.scroll_restore = null;
                ui.widgets.scroll_area.setScrollY(self.body_scroll.state, self.body_scroll.content, offset);
                changed = true;
            } else if (self.heading_target) |offset| {
                self.heading_target = null;
                if (self.revealBlock(offset, true)) changed = true;
            } else if (self.find_reveal) {
                self.find_reveal = false;
                if (self.currentFindMatch()) |hit| {
                    if (self.revealEditorRange(hit, false) or self.revealBlock(hit.start, false)) changed = true;
                }
            } else if (self.revealSource()) changed = true;
            if (self.updateVisibleBlocks() catch |err| blk: {
                self.showError(err);
                break :blk false;
            }) changed = true;
        }
        if (refresh_outline) {
            self.outline_dirty = false;
            self.rebuildOutline() catch |err| self.showError(err);
            changed = true;
        }
        if (self.card == .search) {
            self.find_view.fitPane(self.main.globalRect().w);
            if (self.find_theme != self.cx.theme_version) {
                self.find_theme = self.cx.theme_version;
                self.find_view.retheme();
            }
            self.paintFindMatch(self.currentFindMatch());
        }
        if (!self.search_open) if (self.search_selection_restore) |selection| {
            self.search_selection_restore = null;
            if (self.input) |input| _ = input.state.setAccessibilitySelection(selection.anchor, selection.caret);
        };
        if (!self.search_open) if (self.editing_row) |row| {
            const input = self.input.?;
            const top: f32 = if (self.compact == true) 32 else 24;
            if (row.node.style.margin.top != top) row.node.setStyle(self.cx.allocator, .margin, .{ .top = top });
            input.state.setMarkdownOptions(self.markdownOptions());
            if (input.fitContent(self.body_scroll.container.globalRect().h * 0.8)) changed = true;
        };
        if (self.input) |input| if (input.state.tokens != self.cx.tokens) {
            input.state.tokens = self.cx.tokens;
            input.state.dirty = true;
            input.input.markLayoutDirty();
            changed = true;
        };
        if (self.title) |title| {
            if (title.state.tokens != self.cx.tokens) {
                title.state.tokens = self.cx.tokens;
                title.state.dirty = true;
                if (title.state.text_display_node) |text| text.setTextColor(S.theme.current().fg_1);
            }
            const width_for_title = self.bodyWidth();
            if (@abs(self.title_width - width_for_title) > 0.01) {
                self.title_width = width_for_title;
                title.setWrapWidth(width_for_title);
                changed = true;
            }
            title.setMetrics(if (compact) 24 else 28, 1.25);
        }
        if (self.focus_name) {
            self.focus_name = false;
            self.cx.setFocus(self.name_input);
        }
        if (self.presentation_focus) |handle| {
            self.presentation_focus = null;
            if (self.cx.focus_manager.getFocused() == null) {
                if (self.cx.node_registry.resolve(handle, null)) |node| {
                    if (node.isDisplayedInTree()) self.cx.setFocus(node);
                }
            }
        }
        if (self.import_waiting_for_editor and self.input != null) {
            self.import_waiting_for_editor = false;
            self.startImport() catch |err| self.importFailed(err);
        }
        if (!self.search_open and self.updateImages()) changed = true;
        return if (changed) .needs_layout else .done;
    }

    fn applyLayout(self: *View, compact: bool) void {
        const floating = self.floating_header != null;
        const was_covered = self.saved_focus != null or (!floating and self.compact == true and self.tree_open);
        self.compact = compact;
        self.layout_dirty = false;
        const tree_popup = self.card == .tree;
        const pinned_tree = !floating and !tree_popup and self.treePinned() and (!compact or self.card == .none);
        self.tree_open = tree_popup or pinned_tree;
        const covered = compact and pinned_tree;
        if (covered and !was_covered) {
            if (self.cx.focus_manager.getFocused()) |focused| {
                if (focused.isDescendantOf(self.main) or focused.isDescendantOf(self.search.root)) self.saved_focus = self.cx.node_registry.handleFor(focused);
            }
            self.cx.setFocus(self.toggle);
        } else if (was_covered and !covered) {
            if (self.saved_focus) |handle| if (self.card == .none) {
                if (self.cx.node_registry.resolve(handle, null)) |node| self.cx.setFocus(node);
            };
            self.saved_focus = null;
        }
        const a = self.cx.allocator;
        const toolbar_height = if (floating) 0 else S.toolbar_height;
        const body_height = @max(0, self.layout_height - toolbar_height);
        if (tree_popup) {
            const height = @max(0, body_height - 2 * S.floating_card_top);
            const left = if (floating) S.floating_path_left else @max(24, self.path_slot.globalRect().x - self.root.globalRect().x);
            var tree_style = S.floatingCard(300, @min(height, 352), .{
                .top = .{ .px = toolbar_height + S.floating_card_top },
                .left = .{ .px = left },
            });
            tree_style.padding = .{ .top = 8 };
            self.tree.setStyleInline(a, tree_style);
        } else {
            var tree_style = S.navigation(compact);
            tree_style.padding = .{};
            tree_style.shadows = .{};
            self.tree.setStyleInline(a, tree_style);
        }
        if (self.card == .outline) {
            const rows: f32 = @floatFromInt(self.outline_rows.children.items.len);
            const content_height = S.outline_header_height + 2 * S.outline_padding +
                rows * S.outline_row_height + @max(0, rows - 1) * S.outline_row_gap;
            const available_height = @max(0, body_height - 2 * S.outline_vertical_inset);
            const outline_height = @min(content_height, @min(S.outline_max_height, available_height));
            var outline = S.floatingCard(S.outline_width, outline_height, .{
                .top = .{ .px = toolbar_height + (body_height - outline_height) / 2 },
                .right = .{ .px = 0 },
            });
            if (!compact) {
                outline.position = .relative;
                outline.inset = .{};
                outline.align_self = .center;
                outline.margin = .{ .top = toolbar_height };
                outline.z_index = 0;
            }
            self.outline_card.setStyleInline(a, outline);
        }
        self.directory_header.setDisplay(if (!floating and !tree_popup) .flex else .none);
        self.tree.setDisplay(if (self.tree_open) .flex else .none);
        self.outline_card.setDisplay(if (self.card == .outline) .flex else .none);
        self.find_view.root.setDisplay(if (self.card == .search) .flex else .none);
        self.tree_geometry_refresh = self.tree_open;
        if (self.floating_header == null) {
            const toggle_parent = if (pinned_tree) self.tree else self.root;
            if (self.toggle.parent != toggle_parent) toggle_parent.appendChild(a, self.toggle) catch |err| self.showError(err);
            self.toolbar.setStyle(a, .padding, .{ .left = 24, .right = if (!compact and pinned_tree) 8 else 44 });
        }
        self.find_view.root.setStyle(a, .inset, .{
            .top = .{ .px = toolbar_height + S.floating_card_top },
            .right = .{ .px = if (pinned_tree and !compact) S.directory_width + S.directory_gap + 8 else 8 },
        });
        self.directory_shield.setStyle(a, .inset, .{
            .top = .{ .px = toolbar_height },
            .left = .{ .px = 0 },
            .right = .{ .px = if (covered) S.directory_width else 0 },
            .bottom = .{ .px = 0 },
        });
        self.directory_shield.setDisplay(if (covered or tree_popup or (compact and self.card == .outline)) .flex else .none);
        const edge: f32 = if (compact) 24 else 48;
        self.body.setStyle(a, .padding, .{ .left = if (self.floating_header != null) S.floating_title_left else edge, .right = edge, .top = 4 });
        if (self.blocks_host) |host| host.setStyle(a, .margin, .{ .top = if (compact) 32 else 24 });
    }

    fn fitTreeCard(self: *View) bool {
        const content_height = self.tree_content.globalRect().h;
        if (content_height <= 0) return false;
        const toolbar_height = if (self.floating_header == null) S.toolbar_height else 0;
        const height = @min(content_height + 16, @min(352, @max(0, self.layout_height - toolbar_height - 2 * S.floating_card_top)));
        if (self.tree.style.height == .px and @abs(self.tree.style.height.px - height) < 0.25) return false;
        self.tree.setStyle(self.cx.allocator, .height, .{ .px = height });
        return true;
    }

    fn revealTreeSelection(self: *View) void {
        const scroll = self.tree_scroll;
        if (self.tree_selection) |target| {
            if (target.isDisplayedInTree()) {
                const rect = target.globalRect();
                const top = rect.y - scroll.content.globalRect().y;
                ui.widgets.scroll_area.scrollRectIntoView(scroll.state, scroll.content, top, rect.h, .nearest);
                self.cx.setFocus(target);
                return;
            }
        }
        self.cx.setFocus(self.tree);
    }

    fn fitPath(self: *View) bool {
        const slot = self.path_slot.globalRect();
        if (slot.w <= 0 or @abs(self.path_max_width - slot.w) < 0.25) return false;
        self.path_max_width = slot.w;
        const style: ui.BoxStyle = .{ .max_width = slot.w };
        self.path_button.setStyleInline(self.cx.allocator, style);
        self.path_row.setStyleInline(self.cx.allocator, style);
        const short = slot.w < 220;
        self.path_folders.setDisplay(if (short) .none else .flex);
        self.path_leaf.setDisplay(if (short) .flex else .none);
        return true;
    }

    fn setFloatingHeader(self: *View, header: ?FloatingHeader) void {
        // The floating slots reserve capacity at mount, and the docked parents
        // retain their capacity while these controls are in the floating header.
        const a = self.cx.allocator;
        if (header) |slots| {
            self.showCard(.none);
            slots.document.appendChild(a, self.toolbar) catch unreachable;
            slots.directory.appendChild(a, self.directory_add) catch unreachable;
            slots.directory.appendChild(a, self.outline_hint) catch unreachable;
            self.toolbar.setStyleInline(a, .{ .height = .{ .px = S.floating_header_height }, .padding = .{} });
            self.toggle.setDisplay(.none);
            self.directory_header.setDisplay(.none);
            self.directory_shield.setStyle(a, .inset, .{ .top = .{ .px = 0 }, .left = .{ .px = 0 }, .right = .{ .px = 0 }, .bottom = .{ .px = 0 } });
            for ([_]*ui.Node{ self.toolbar, slots.directory }) |node| {
                node.behavior.events.capture_context = self;
                node.behavior.events.on_event_capture = keyEvent;
            }
        } else if (self.floating_header) |slots| {
            self.showCard(.none);
            for ([_]*ui.Node{ self.toolbar, slots.directory }) |node| {
                node.behavior.events.capture_context = null;
                node.behavior.events.on_event_capture = null;
            }
            self.main.insertChildBefore(a, self.toolbar, self.banner) catch unreachable;
            self.directory_header.appendChild(a, self.directory_add) catch unreachable;
            self.toolbar.appendChild(a, self.outline_hint) catch unreachable;
            self.toolbar.setStyle(a, .height, .{ .px = S.toolbar_height });
            self.toggle.setDisplay(.flex);
            self.directory_header.setDisplay(.flex);
            self.tree.setStyleInline(a, .{ .shadows = .{}, .padding = .{} });
            self.directory_shield.setStyle(a, .inset, .{ .top = .{ .px = 0 }, .left = .{ .px = 0 }, .right = .{ .px = S.directory_width }, .bottom = .{ .px = 0 } });
        } else return;
        self.floating_header = header;
        self.tree_dirty = true;
        self.syncDocumentTools();
        self.syncToolbarVisibility();
        self.layout_dirty = true;
    }

    fn syncDocumentTools(self: *View) void {
        const floating = self.floating_header != null;
        self.document_menu.setDisplay(if (floating) .none else .flex);
        self.search_button.setDisplay(if (!floating and self.search_origin == null) .flex else .none);
        self.search_back_button.setDisplay(if (!floating and self.search_origin != null) .flex else .none);
        self.image_button.setDisplay(if (!floating and self.key != null) .flex else .none);
        self.find_button.setDisplay(if (self.key != null) .flex else .none);
        self.source_button.setDisplay(if (floating and self.key != null) .flex else .none);
        self.recent_button.setDisplay(if (floating) .flex else .none);
        self.outline_hint.setDisplay(if (self.key != null and !self.search_open) .flex else .none);
    }

    fn directoryTogglePosition() ui.BoxStyle {
        return .{ .position = .absolute, .inset = .{ .top = .{ .px = 18 }, .right = .{ .px = 8 } }, .z_index = 3 };
    }

    fn mountPath(self: *View) !void {
        const a = self.cx.allocator;
        const cx = self.cx;
        const click = try self.scope.createState(Click, .{ .view = self, .action = .browse_tree });
        self.path_button = try ui.widgets.Button(.{
            .variant = .ghost,
            .a11y_label = "浏览全部笔记",
            .base_style = ui.BoxStyle{ .width = .{ .fit = .{} }, .min_width = 0, .height = .{ .px = 28 }, .flex_shrink = 1, .justify = .start, .padding = .{}, .overflow_hidden = true },
            .on_click = cx.on(Click, click, Click.invoke),
        }).mount(self.scope, cx);
        self.path_button.meta.ownership.meta.test_id = "notes.breadcrumb.open-tree";
        var path_style = S.row(28, 4);
        path_style.width = .{ .fit = .{} };
        path_style.flex_shrink = 1;
        const path = try ui.box(cx, path_style, .{});
        self.path_row = path;
        try self.path_button.appendChild(a, path);
        try path.appendChild(a, try self.pathIcon(ui.icons.library, "知识库"));
        self.path_library = try self.pathLabel("全部笔记");
        self.path_library.meta.ownership.meta.test_id = "notes.breadcrumb.library";
        try path.appendChild(a, self.path_library);
        self.path_folder_group = try ui.box(cx, .{ .direction = .row, .gap = 4, .align_items = .center, .min_width = 0, .flex_shrink = 1, .overflow_hidden = true }, .{});
        try self.path_folder_group.appendChild(a, try self.pathIcon(ui.icons.chevron_right, null));
        try self.path_folder_group.appendChild(a, try self.pathIcon(ui.icons.folder, "文件夹"));
        self.path_folders = try self.pathLabel("");
        self.path_folders.meta.ownership.meta.test_id = "notes.breadcrumb.folders";
        try self.path_folder_group.appendChild(a, self.path_folders);
        self.path_leaf = try self.pathLabel("");
        self.path_leaf.meta.ownership.meta.test_id = "notes.breadcrumb.folder";
        self.path_leaf.setDisplay(.none);
        try self.path_folder_group.appendChild(a, self.path_leaf);
        try path.appendChild(a, self.path_folder_group);
        self.path_folder_group.setDisplay(.none);
        try path.appendChild(a, try self.pathIcon(ui.icons.chevron_down, null));
        self.path_slot = try ui.box(cx, S.row(28, 0), .{});
        self.path_slot.setStyle(a, .overflow, .hidden);
        try self.path_slot.appendChild(a, self.path_button);
        try self.toolbar.appendChild(a, self.path_slot);
    }

    fn pathLabel(self: *View, text: []const u8) !*ui.Node {
        var style = S.text(12, 400, S.theme.current().fg_2);
        style.text_overflow = .ellipsis;
        style.selectable = false;
        const label = try ui.text(self.cx, text, style);
        S.theme.bindInk(label, "fg_2");
        label.setStyleInline(self.cx.allocator, .{ .min_width = 0, .flex_shrink = 1 });
        return label;
    }

    fn pathIcon(self: *View, asset: ui.SvgAsset, hint: ?[]const u8) !*ui.Node {
        const a = self.cx.allocator;
        const size: f32 = if (hint == null) 12 else 14;
        const style: ui.BoxStyle = .{ .width = .{ .px = size }, .height = .{ .px = size }, .flex_shrink = 0 };
        const icon = try ui.iconTint(self.cx, asset, S.theme.current().fg_2, .{ .width = .{ .px = size }, .height = .{ .px = size }, .flex_shrink = 0 });
        S.theme.bindInk(icon, "fg_2");
        if (hint) |label| {
            const tip = try ui.widgets.Tooltip(.{ .text = label }).mount(self.scope, self.cx);
            tip.wrapper.setStyleInline(a, style);
            try tip.trigger.appendChild(a, icon);
            return tip.wrapper;
        }
        return icon;
    }

    fn toolHint(self: *View, button: *ui.Node, label: []const u8) !*ui.Node {
        const tip = try ui.widgets.Tooltip(.{ .text = label }).mount(self.scope, self.cx);
        const a = self.cx.allocator;
        tip.wrapper.setStyleInline(a, .{ .width = .{ .px = 28 }, .height = .{ .px = 28 }, .flex_shrink = 0 });
        try tip.trigger.appendChild(a, button);
        return tip.wrapper;
    }

    fn replaceContent(self: *View, host: *ui.Node, slot: *?*ui.Scope) !*ui.Scope {
        while (host.children.items.len != 0) {
            const child = host.children.items[host.children.items.len - 1];
            self.cx.detachChild(host, child);
            self.cx.destroyDetached(child);
        }
        if (slot.*) |child_scope| child_scope.dispose();
        slot.* = null;
        const next = try self.scope.childScope();
        slot.* = next;
        return next;
    }

    fn rebuildTree(self: *View) !void {
        self.tree_selection = null;
        self.tree_actions.clearRetainingCapacity();
        const scope = try self.replaceContent(self.tree_content, &self.tree_scope);
        var arena = std.heap.ArenaAllocator.init(self.cx.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const libraries = try self.store.listLibraryIds(a, .active);
        if (libraries.len == 0) {
            try self.tree_content.appendChild(self.cx.allocator, try self.actionButton(scope, .{ .create = .library }, "新建目录", ui.icons.folder_plus, false, "notes.directory.empty"));
            return;
        }
        for (libraries) |id| {
            const library = try self.store.loadLibrary(a, id, .active);
            defer library.deinit();
            const ids = try self.store.listNoteIds(a, id, .active);
            var notes: std.ArrayList(TreeNote) = .empty;
            for (ids) |note_id| {
                const note = self.store.loadNote(self.cx.allocator, .{ .library_id = id, .note_id = note_id }, .active) catch |err| switch (err) {
                    error.Unavailable, error.FileNotFound => continue,
                    else => return err,
                };
                defer note.deinit();
                const value = note.value;
                try notes.append(a, .{ .key = value.key(), .folder = value.folder_id, .title = try a.dupe(u8, value.title), .read_only = value.read_only });
            }
            try self.addDirectory(scope, self.tree_content, library.value, notes.items, .{ .library = id }, library.value.name);
        }
    }

    fn addDirectory(self: *View, scope: *ui.Scope, parent: *ui.Node, library: model.Library, notes: []const TreeNote, directory: Directory, title: []const u8) anyerror!void {
        const selected = (self.key == null or self.directory_selected) and self.directory != null and self.directory.?.library.eql(directory.library) and std.meta.eql(self.directory.?.folder, directory.folder);
        const a = self.cx.allocator;
        var directory_style = S.treeRow(directory.depth, selected);
        directory_style.gap = 4;
        directory_style.padding = .{ .left = 12 * @as(f32, @floatFromInt(directory.depth)), .right = 6 };
        const row = try ui.box(self.cx, directory_style, .{});
        row.meta.ownership.meta.test_id = "notes.directory.row";
        if (selected) try S.theme.bindMaterial(self.cx, scope, row, "selection");
        try parent.appendChild(a, row);
        const descendants = try ui.box(self.cx, S.stack(2), .{});
        try parent.appendChild(a, descendants);
        const branch = try self.mountBranch(scope, row, descendants, directory);
        const asset = if (directory.folder == null) ui.icons.library else ui.icons.folder;
        const directory_button = try self.treeLabel(scope, .{ .select_directory = directory }, title, asset, S.theme.current().accent, "notes.directory.select");
        try row.appendChild(a, directory_button);
        if (selected) self.tree_selection = directory_button;
        const controls = try ui.box(self.cx, .{ .direction = .row, .gap = 2, .align_items = .center, .flex_shrink = 0 }, .{});
        try row.appendChild(a, controls);
        if (directory.depth < 2) try controls.appendChild(a, try self.actionButton(scope, .{ .create = .{ .folder = directory } }, "新建子目录", ui.icons.folder_plus, true, "notes.directory.add-folder"));
        try controls.appendChild(a, try self.actionButton(scope, .{ .create = .{ .note = directory } }, "新建文档", ui.icons.file_plus, true, "notes.directory.add-document"));
        const target: management.Target = .{ .directory = directory };
        const remove = try self.menuItem(scope, "删除", .{ .manage = .{ .delete = target } }, true);
        const menu = if (directory.folder == null) blk: {
            const settings = try scope.createState(SettingsClick, .{ .view = self, .library = directory.library });
            const value = try self.mountMore(scope, controls, &.{
                .{ .label = "目录设置", .on_click = self.cx.on(SettingsClick, settings, SettingsClick.invoke) },
                remove,
            }, "notes.directory.more");
            settings.node = value.button;
            break :blk value;
        } else try self.mountMore(scope, controls, &.{
            try self.menuItem(scope, "重命名", .{ .manage = .{ .rename = target } }, false),
            try self.menuItem(scope, "移动到", .{ .manage = .{ .move = target } }, false),
            remove,
        }, "notes.directory.more");
        try self.mountTreeActions(scope, row, controls, menu);
        for (library.folders) |folder| {
            if (folder.deleted_at != null or !std.meta.eql(folder.parent_id, directory.folder)) continue;
            try self.addDirectory(scope, descendants, library, notes, .{ .library = directory.library, .folder = folder.id, .depth = directory.depth + 1 }, folder.name);
        }
        for (notes) |note| {
            if (!std.meta.eql(note.folder, directory.folder)) continue;
            const key = note.key;
            const active_note = std.meta.eql(self.key, @as(?model.NoteKey, key));
            var note_style = S.treeRow(directory.depth + 1, active_note and !self.directory_selected);
            note_style.padding = .{ .left = 32 + 12 * @as(f32, @floatFromInt(directory.depth)), .right = 6 };
            const note_row = try ui.box(self.cx, note_style, .{});
            if (active_note and !self.directory_selected) try S.theme.bindMaterial(self.cx, scope, note_row, "selection");
            try descendants.appendChild(a, note_row);
            const note_button = try self.treeLabel(scope, .{ .select_note = key }, note.title, icons.asset("note.md"), icons.color("note.md"), "notes.document.select");
            try note_row.appendChild(a, note_button);
            if (active_note and !self.directory_selected) self.tree_selection = note_button;
            if (active_note and self.lease != null and !note.read_only) {
                const note_target: management.Target = .{ .note = key };
                const note_controls = try ui.box(self.cx, .{ .flex_shrink = 0 }, .{});
                try note_row.appendChild(a, note_controls);
                const note_menu = try self.mountMore(scope, note_controls, &.{
                    try self.menuItem(scope, "移动到", .{ .manage = .{ .move = note_target } }, false),
                    try self.menuItem(scope, "删除", .{ .manage = .{ .delete = note_target } }, true),
                }, "notes.document.more");
                try self.mountTreeActions(scope, note_row, note_controls, note_menu);
            }
        }
        if (descendants.children.items.len == 0) {
            descendants.setDisplay(.none);
            branch.setOpacity(0);
            branch.setHitTestVisible(false);
            branch.setFocusable(false);
        }
    }

    fn treeLabel(self: *View, scope: *ui.Scope, action: Action, title: []const u8, asset: ui.SvgAsset, color: ui.Color, id: []const u8) !*ui.Node {
        const label = try scope.createText(title, .{});
        const callback = try scope.createState(Click, .{ .view = self, .action = action });
        const node = try ui.widgets.Button(.{
            .variant = .ghost,
            .a11y_label = label,
            .base_style = ui.BoxStyle{ .width = .fill(), .height = .{ .px = 28 }, .justify = .start, .padding = .{}, .min_width = 0, .overflow_hidden = true },
            .on_click = self.cx.on(Click, callback, Click.invoke),
        }).mount(scope, self.cx);
        node.meta.ownership.meta.test_id = id;
        const a = self.cx.allocator;
        const contents = try ui.box(self.cx, S.row(28, 7), .{});
        const icon = try ui.iconTint(self.cx, asset, color, .{ .width = .{ .px = 16 }, .height = .{ .px = 16 }, .flex_shrink = 0 });
        if (action == .select_directory) S.theme.bindInk(icon, "accent");
        try contents.appendChild(a, icon);
        const selected_note = action == .select_note and !self.directory_selected and std.meta.eql(self.key, @as(?model.NoteKey, action.select_note));
        const colors = S.theme.current();
        var style = S.text(12.5, if (action == .select_directory) 550 else 400, if (selected_note) colors.accent_ink else colors.fg_1);
        style.selectable = false;
        style.text_overflow = .ellipsis;
        const title_node = try ui.text(self.cx, "", style);
        if (selected_note) S.theme.bindInk(title_node, "accent_ink") else S.theme.bindInk(title_node, "fg_1");
        title_node.setStyleInline(a, .{ .width = .fill(), .min_width = 0 });
        try title_node.setTextContent(a, title);
        try contents.appendChild(a, title_node);
        try node.appendChild(a, contents);
        return node;
    }

    fn collapsedIndex(self: *const View, directory: Directory) ?usize {
        for (self.collapsed_branches.items, 0..) |entry, i| {
            if (entry.library.eql(directory.library) and std.meta.eql(entry.folder, directory.folder)) return i;
        }
        return null;
    }

    fn expandDirectoryPath(self: *View, library: model.Library, folder: ?model.FolderId) void {
        var current = folder;
        while (true) {
            if (self.collapsedIndex(.{ .library = library.id, .folder = current })) |i| _ = self.collapsed_branches.swapRemove(i);
            const id = current orelse return;
            current = library.folders[library.folderIndex(id) orelse return].parent_id;
        }
    }

    fn mountBranch(self: *View, scope: *ui.Scope, row: *ui.Node, descendants: *ui.Node, directory: Directory) !*ui.Node {
        const cx = self.cx;
        const collapsed = self.collapsedIndex(directory) != null;
        const branch = try scope.createState(TreeBranch, .{
            .view = self,
            .directory = directory,
            .descendants = descendants,
            .icon = try scope.createSignal(?ui.SvgAsset, null),
            .label = try scope.createText("", .{}),
        });
        branch.present(collapsed);
        const button = try ui.widgets.Button(.{
            .variant = .ghost,
            .icon_only = true,
            .icon_asset = branch.icon,
            .icon_size = @as(f32, 12),
            .a11y_label = branch.label,
            .base_style = ui.BoxStyle{ .width = .{ .px = 16 }, .height = .{ .px = 24 }, .flex_shrink = 0, .padding = .{}, .border = .{ .radius = 8 } },
            .on_click = cx.on(TreeBranch, branch, TreeBranch.toggle),
        }).mount(scope, cx);
        button.meta.ownership.meta.test_id = "notes.directory.branch";
        try row.appendChild(cx.allocator, button);
        return button;
    }

    fn mountTreeActions(self: *View, scope: *ui.Scope, row: *ui.Node, controls: *ui.Node, menu: MoreMenu) !void {
        const actions = try scope.createState(TreeActions, .{ .view = self, .row = row, .controls = controls, .menu = menu });
        controls.setDisplay(.none);
        try self.tree_actions.append(self.cx.allocator, actions);
        row.behavior.events.on_hover = self.cx.on(TreeActions, actions, TreeActions.enter);
        row.behavior.events.on_leave = self.cx.on(TreeActions, actions, TreeActions.leave);
    }

    fn updateTreeActions(self: *View) bool {
        const focused = self.cx.focus_manager.getFocused();
        const anchor = if (self.settings.open.peek()) blk: {
            const handle = self.settings.anchor orelse break :blk null;
            break :blk self.cx.node_registry.resolve(handle, null);
        } else null;
        var changed = false;
        for (self.tree_actions.items) |entry| {
            const visible = entry.row.isDisplayedInTree();
            if (!visible) {
                entry.hovered = false;
                if (entry.menu.open.peek()) entry.menu.open.set(false);
            }
            const has_focus = if (focused) |node| node.isDescendantOf(entry.row) else false;
            const show = visible and (entry.hovered or has_focus or entry.menu.open.peek() or anchor == entry.menu.button);
            const display: @TypeOf(entry.controls.style.display) = if (show) .flex else .none;
            if (entry.controls.style.display == display) continue;
            entry.controls.setDisplay(display);
            changed = true;
        }
        return changed;
    }

    fn menuItem(self: *View, scope: *ui.Scope, label: []const u8, action: Action, danger: bool) !ui.widgets.MenuItem {
        const callback = try scope.createState(Click, .{ .view = self, .action = action });
        return .{ .label = label, .danger = danger, .on_click = self.cx.on(Click, callback, Click.invoke) };
    }

    fn mountMore(self: *View, scope: *ui.Scope, parent: *ui.Node, items: []const ui.widgets.MenuItem, id: []const u8) !MoreMenu {
        const menu = try ui.widgets.Menu(.{ .items = items, .position = .bottom_end, .width = 152 }).mount(scope, self.cx);
        const button = try ui.widgets.Button(.{ .variant = .ghost, .icon_only = true, .icon_asset = ui.icons.ellipsis, .a11y_label = "更多操作", .base_style = S.tool() }).mount(scope, self.cx);
        button.meta.ownership.meta.test_id = id;
        try menu.trigger.appendChild(self.cx.allocator, button);
        try parent.appendChild(self.cx.allocator, menu.wrapper);
        return .{ .button = button, .open = menu.open.?, .wrapper = menu.wrapper };
    }

    fn applyManagement(raw: *anyopaque, mutation: management.Mutation) !void {
        const self: *View = @ptrCast(@alignCast(raw));
        switch (mutation.target) {
            .directory => |dir| try self.changeDirectory(dir, mutation),
            .note => |key| try self.changeManagedNote(key, mutation),
        }
        self.tree_dirty = true;
        self.updateBreadcrumb() catch {};
        self.redraw();
    }

    fn changeDirectory(self: *View, dir: Directory, mutation: management.Mutation) !void {
        var library = try self.store.loadLibrary(self.cx.allocator, dir.library, .include_deleted);
        defer library.deinit();
        const value = library.value;
        if (value.revision != mutation.revision) return error.RevisionChanged;
        var deleted_selection = false;
        var fallback: ?Directory = null;
        if (mutation.change == .delete) {
            if (self.key) |key| {
                if (key.library_id.eql(dir.library)) {
                    var note = try self.store.loadNote(self.cx.allocator, key, .active);
                    defer note.deinit();
                    deleted_selection = value.containsFolder(dir.folder, note.value.folder_id);
                }
            }
            if (deleted_selection) {
                try self.finishInput();
                try self.finishBoundary();
                try self.flushDraft();
            }
            try self.documents.requireUnleasedSubtreeExcept(value, dir.folder, if (deleted_selection) self.lease else null);
            if (dir.folder) |id| {
                const parent = value.folders[value.folderIndex(id) orelse return error.Unavailable].parent_id;
                fallback = .{ .library = dir.library, .folder = parent, .depth = @intFromBool(parent != null) };
            }
        }
        if (dir.folder) |id| {
            _ = try self.store.changeFolder(dir.library, id, mutation.revision, switch (mutation.change) {
                .rename => |name| .{ .rename = name },
                .move => |parent| .{ .move = parent },
                .delete => .delete,
                .restore => |name| .{ .restore = name },
            });
        } else {
            _ = try self.store.changeLibrary(dir.library, mutation.revision, switch (mutation.change) {
                .rename => |name| .{ .rename = name },
                .delete => .delete,
                .restore => |name| .{ .restore = name },
                .move => return error.Unavailable,
            });
        }
        if (deleted_selection) {
            if (self.lease) |lease| try self.documents.release(lease);
            self.clearDocument();
        }
        if (mutation.change == .delete) {
            if (self.directory) |selected| {
                if (selected.library.eql(dir.library) and value.containsFolder(dir.folder, selected.folder)) self.directory = fallback;
            }
            if (self.key == null) self.body_dirty = true;
        } else if (mutation.change == .move) {
            if (self.directory) |selected| {
                if (selected.library.eql(dir.library) and std.meta.eql(dir.folder, selected.folder)) {
                    self.directory.?.depth = if (mutation.change.move == null) 1 else 2;
                }
            }
        }
    }

    fn changeManagedNote(self: *View, key: model.NoteKey, mutation: management.Mutation) !void {
        if (mutation.change == .restore) {
            _ = try self.store.changeNote(key, mutation.revision, .restore);
            return;
        }
        const lease = self.lease orelse return error.DocumentInUse;
        if (!std.meta.eql(lease.key, key)) return error.DocumentInUse;
        try self.finishInput();
        try self.settleSave();
        try self.finishBoundary();
        const snapshot = try self.documents.snapshot(lease);
        if (snapshot.stamp.base_revision != mutation.revision) return error.RevisionChanged;
        switch (mutation.change) {
            .move => |folder| {
                var library = try self.store.loadLibrary(self.cx.allocator, key.library_id, .active);
                defer library.deinit();
                const depth = library.value.folderDepth(folder) orelse return error.Unavailable;
                try self.documents.move(snapshot.stamp, folder);
                self.directory = .{ .library = key.library_id, .folder = folder, .depth = depth };
            },
            .delete => {
                try self.documents.delete(snapshot.stamp);
                self.clearDocument();
            },
            else => return error.Unavailable,
        }
    }

    fn clearDocument(self: *View) void {
        self.showCard(.none);
        self.heading_target = null;
        self.cancelSaveTimer();
        self.cancelImagePicker();
        self.clearImportInput();
        self.import_feedback = .idle;
        self.syncImportFeedback();
        self.lease = null;
        self.key = null;
        self.occupied = null;
        self.editing = false;
        self.reading_caret = null;
        self.editor_offset = null;
        self.source_mode = false;
        self.source_range = null;
        self.search_origin = null;
        self.showSearch(false);
        self.clearError();
        self.body_dirty = true;
    }

    fn resetBlockCache(self: *View) void {
        const a = self.cx.allocator;
        if (self.blocks_text) |text| a.free(text);
        self.blocks_text = null;
        a.free(self.block_ranges);
        self.block_ranges = &.{};
        a.free(self.block_rows);
        self.block_rows = &.{};
        self.rendered_blocks.clearRetainingCapacity();
        self.blocks_host = null;
        self.append_button = null;
        self.editing_row = null;
    }

    fn resetBody(self: *View) !*ui.Scope {
        self.clearEditorImage();
        self.closeImageViewer();
        self.images.clearRetainingCapacity();
        self.resetBlockCache();
        self.body_mode = null;
        self.title = null;
        self.title_label = null;
        self.clearEditorState();
        return self.replaceContent(self.body_content, &self.body_scope);
    }

    fn clearEditorState(self: *View) void {
        self.input = null;
        self.import_notice = null;
    }

    fn rebuildBody(self: *View) !void {
        self.syncDocumentTools();
        try self.updateBreadcrumb();
        const key = self.key orelse {
            const scope = try self.resetBody();
            self.lock.setDisplay(.none);
            self.unlock.setDisplay(.none);
            const action: Create = if (self.directory) |directory| .{ .note = directory } else .library;
            try self.body_content.appendChild(self.cx.allocator, try self.actionButton(scope, .{ .create = action }, if (action == .library) "新建目录" else "新建文档", if (action == .library) ui.icons.folder_plus else ui.icons.file_plus, false, "notes.document.empty"));
            return;
        };
        if (self.lease) |lease| {
            const value = try self.documents.snapshot(lease);
            try self.mountDocument(.{ .key = key, .read_only = value.read_only, .can_lock = true, .source = self.source_mode }, value.title, value.body_md);
            self.body_generation_seen = value.body_generation;
        } else {
            var note = try self.store.loadNote(self.cx.allocator, key, .active);
            defer note.deinit();
            try self.mountDocument(.{ .key = key, .read_only = true, .can_lock = false, .source = self.source_mode }, note.value.title, note.value.body_md);
            self.read_revision_seen = note.value.revision;
        }
    }

    fn updateBreadcrumb(self: *View) !void {
        const a = self.cx.allocator;
        const library_id = if (self.key) |key| key.library_id else if (self.directory) |directory| directory.library else {
            self.path_folder_group.setDisplay(.none);
            try self.path_library.setTextContent(a, "全部笔记");
            return;
        };
        var library = try self.store.loadLibrary(a, library_id, .active);
        defer library.deinit();
        const value = library.value;
        const folder_id = if (self.lease) |lease| (try self.documents.snapshot(lease)).folder_id else if (self.key) |key| blk: {
            var note = try self.store.loadNote(a, key, .active);
            defer note.deinit();
            break :blk note.value.folder_id;
        } else self.directory.?.folder;
        const folder = if (folder_id) |id| value.folders[value.folderIndex(id) orelse return error.Unavailable] else null;
        self.path_folder_group.setDisplay(if (folder != null) .flex else .none);
        try self.path_library.setTextContent(a, value.name);
        const item = folder orelse return;
        const parent = if (item.parent_id) |id| value.folders[value.folderIndex(id) orelse return error.Unavailable].name else null;
        const folders = if (parent) |name| try std.fmt.allocPrint(a, "{s}  ›  {s}", .{ name, item.name }) else try a.dupe(u8, item.name);
        defer a.free(folders);
        try self.path_folders.setTextContent(a, folders);
        if (parent != null) {
            const leaf = try std.fmt.allocPrint(a, "… › {s}", .{item.name});
            defer a.free(leaf);
            try self.path_leaf.setTextContent(a, leaf);
        } else {
            try self.path_leaf.setTextContent(a, item.name);
        }
    }

    fn mountDocument(self: *View, mode: BodyMode, title: []const u8, text: []const u8) !void {
        if (mode.source or !std.meta.eql(self.body_mode, @as(?BodyMode, mode))) {
            const scope = try self.resetBody();
            try self.mountDocumentHeader(scope, mode, title);
            if (mode.source) {
                try self.mountEditor(scope, self.body_content, text, mode.read_only, false);
            } else {
                const a = self.cx.allocator;
                const host = try ui.box(self.cx, .{ .width = .fill(), .height = .{ .px = 0 }, .flex_shrink = 0, .margin = .{ .top = if (self.compact == true) 32 else 24 } }, .{});
                try self.body_content.appendChild(a, host);
                self.blocks_host = host;
                if (!mode.read_only) {
                    const button = try self.actionButton(scope, .append_block, "编辑正文", null, false, "notes.editor.append");
                    try self.body_content.appendChild(a, button);
                    self.append_button = button;
                }
                self.block_width = self.bodyWidth();
                self.block_compact = self.compact == true;
                self.block_theme = self.cx.theme_version;
            }
            self.body_mode = mode;
        }
        if (self.title_label) |label| {
            if (!std.mem.eql(u8, label.getText().?.content, title)) try label.setTextContent(self.cx.allocator, title);
        }
        if (!mode.source) {
            if (self.editing and !mode.read_only) {
                try self.mountDocumentEditor(text);
            } else {
                self.removeEditorRow();
                try self.updateBlockContent(text);
                if (self.append_button) |button| button.setDisplay(.flex);
            }
        }
        if (self.editor_offset) |offset| if (self.input) |input| {
            const caret: u32 = @intCast(@min(offset, text.len));
            _ = input.state.setAccessibilitySelection(caret, caret);
            self.editor_offset = null;
        };
        if (self.focus_pending) {
            self.focus_pending = false;
            self.cx.setFocus(if (self.input) |value| value.input else self.root);
        }
    }

    fn mountDocumentHeader(self: *View, scope: *ui.Scope, mode: BodyMode, title: []const u8) !void {
        const cx = self.cx;
        const compact = self.compact == true;
        self.lock.setDisplay(if (mode.can_lock and !mode.read_only) .flex else .none);
        self.unlock.setDisplay(if (mode.can_lock and mode.read_only) .flex else .none);
        self.image_disabled.set(mode.read_only);
        if (mode.read_only or mode.source) {
            const heading = try ui.text(cx, "", S.text(if (compact) 24 else 28, 650, S.theme.current().fg_1));
            heading.meta.ownership.meta.test_id = "notes.title";
            S.theme.bindInk(heading, "fg_1");
            self.title_label = heading;
            try heading.setTextContent(cx.allocator, title);
            try self.body_content.appendChild(cx.allocator, heading);
        } else {
            const title_value = try scope.createText(title, .{});
            const title_edit = try scope.createState(TitleEdit, .{ .view = self, .value = title_value });
            self.title_width = self.bodyWidth();
            self.title = try ui.widgets.EditableText(.{
                .value = ui.split(title_value, cx.on(TitleEdit, title_edit, TitleEdit.accept)),
                .font_size = @as(f32, if (compact) 24 else 28),
                .wrap_width = self.title_width,
                .activation = .click,
                .on_change = cx.on(View, self, titleChanged),
            }).mountResult(scope, cx);
            self.title.?.state.accept_newline = false;
            self.title.?.node.meta.ownership.meta.test_id = "notes.title";
            try self.body_content.appendChild(cx.allocator, self.title.?.node);
        }
        if (self.occupied != null) {
            const occupied = try self.actionButton(scope, .{ .focus_editor = self.key.? }, "在编辑窗口中打开", ui.icons.external_link, false, "notes.document.focus-editor");
            try self.body_content.appendChild(cx.allocator, occupied);
        }
    }

    fn bodyWidth(self: *View) f32 {
        const padding = self.body.style.padding;
        return @max(1, self.body_content.globalRect().w - padding.left - padding.right);
    }

    fn updateBlockContent(self: *View, text: []const u8) !void {
        const a = self.cx.allocator;
        const old_text = self.blocks_text;
        const old_top = self.viewportBlockTop();
        const anchor = self.blockAt(old_top);
        const anchor_offset = if (anchor < self.block_rows.len) old_top - self.block_rows[anchor].top else 0;
        var next_anchor: ?usize = if (anchor < self.block_rows.len) anchor else null;
        if (old_text == null or !std.mem.eql(u8, old_text.?, text)) {
            const next_text = try a.dupe(u8, text);
            errdefer a.free(next_text);
            const ranges = if (old_text) |old|
                try editor.reparseBlocks(a, old, self.block_ranges, next_text)
            else
                try editor.blocks(a, next_text);
            self.render_counts.parses += 1;
            errdefer a.free(ranges);
            const rows = try a.alloc(BlockRow, ranges.len);
            errdefer a.free(rows);
            const matched = if (old_text) |old| try editor.matchBlocks(a, old, self.block_ranges, next_text, ranges) else null;
            defer if (matched) |indices| a.free(indices);

            next_anchor = null;
            for (rows, ranges, 0..) |*row, range, i| {
                if (matched) |indices| if (indices[i]) |old_index| {
                    row.* = self.block_rows[old_index];
                    self.block_rows[old_index].rendered = null;
                    if (old_index == anchor) next_anchor = i;
                    if (row.rendered) |rendered| {
                        rendered.index = i;
                        if (rendered.edit) |action| action.action = .{ .begin_block = .{ .range = range } };
                    }
                    continue;
                };
                row.* = .{ .height = self.estimateBlock(range, next_text) };
            }
            for (self.block_rows) |row| if (row.rendered) |rendered| self.removeBlock(rendered);
            if (old_text) |old| a.free(old);
            a.free(self.block_ranges);
            a.free(self.block_rows);
            self.blocks_text = next_text;
            self.block_ranges = ranges;
            self.block_rows = rows;
        }
        self.positionBlocks();
        if (next_anchor) |index| {
            self.restoreBlockTop(self.block_rows[index].top + @min(anchor_offset, self.blockHeight(index)), old_top);
        }
    }

    fn restoreBlockTop(self: *View, next_top: f32, old_top: f32) void {
        if (@abs(next_top - old_top) < 0.25 or old_top < 0 or self.scroll_restore != null or self.source_range != null) return;
        self.scroll_restore = self.body_scroll.state.scroll_y + next_top - old_top;
    }

    fn updateVisibleBlocks(self: *View) !bool {
        const host = self.blocks_host orelse return false;
        if (self.editing_row != null) return false;
        const viewport = self.body_scroll.container.globalRect();
        const width = self.bodyWidth();
        if (viewport.h <= 0 or width <= 1) return false;
        const top = self.viewportBlockTop();
        const anchor = self.blockAt(top);
        const old_anchor_top = if (anchor < self.block_rows.len) self.block_rows[anchor].top else 0;
        const restyle = self.block_compact != (self.compact == true) or self.block_theme != self.cx.theme_version;
        var resize = @abs(self.block_width - width) >= 0.25 or restyle;
        if (restyle) {
            self.block_compact = self.compact == true;
            self.block_theme = self.cx.theme_version;
            var i: usize = self.rendered_blocks.items.len;
            while (i > 0) {
                i -= 1;
                const rendered = self.rendered_blocks.items[i];
                if (rendered.image) |image| {
                    image.label.setTextColor(S.theme.current().fg_2);
                } else {
                    self.block_rows[rendered.index].rendered = null;
                    self.removeBlock(rendered);
                }
            }
        }
        if (resize) {
            self.block_width = width;
            for (self.block_rows, self.block_ranges) |*row, range| {
                if (row.rendered == null) row.height = self.estimateBlock(range, self.blocks_text.?);
            }
        }
        for (self.rendered_blocks.items) |rendered| {
            const measured = rendered.node.globalRect().h;
            const row = &self.block_rows[rendered.index];
            if (measured > 0 and @abs(measured - row.height) >= 0.25) {
                row.height = measured;
                resize = true;
            }
        }
        if (resize) {
            self.positionBlocks();
            if (anchor < self.block_rows.len) self.restoreBlockTop(top + self.block_rows[anchor].top - old_anchor_top, top);
        }
        const start = self.blockAt(top - viewport.h);
        const end = @min(self.block_rows.len, self.blockAt(top + 2 * viewport.h) + 1);
        var changed = resize;
        var i = self.rendered_blocks.items.len;
        while (i > 0) {
            i -= 1;
            const rendered = self.rendered_blocks.items[i];
            if (rendered.index >= start and rendered.index < end) continue;
            if (rendered.image != null and rendered.image == self.viewed_image) continue;
            self.block_rows[rendered.index].rendered = null;
            self.removeBlock(rendered);
            changed = true;
        }
        for (start..end) |index| {
            if (self.block_rows[index].rendered != null) continue;
            try self.showBlock(host, index);
            changed = true;
        }
        return changed;
    }

    fn showBlock(self: *View, host: *ui.Node, index: usize) !void {
        const a = self.cx.allocator;
        try self.rendered_blocks.ensureUnusedCapacity(a, 1);
        const scope = try self.body_scope.?.childScope();
        errdefer scope.dispose();
        const row = &self.block_rows[index];
        const node = try self.mountBlockRow(host, row.top, 0);
        errdefer self.destroyBlockRow(node);
        const rendered = try scope.createState(RenderedBlock, .{ .index = index, .node = node, .scope = scope });
        try self.mountBlock(rendered, self.block_ranges[index], self.blocks_text.?, self.body_mode.?.read_only);
        self.rendered_blocks.appendAssumeCapacity(rendered);
        row.rendered = rendered;
        self.render_counts.mounts += 1;
    }

    fn estimateBlock(self: *const View, block: editor.Block, body: []const u8) f32 {
        if (block.kind == .image) return 24;
        const font: f32 = if (self.compact == true) 14 else 15;
        const columns: usize = @intFromFloat(@max(16, self.block_width / (font * 0.7)));
        var lines = std.mem.splitScalar(u8, block.text(body), '\n');
        var rows: usize = 0;
        while (lines.next()) |line| {
            const count = std.unicode.utf8CountCodepoints(line) catch line.len;
            rows += @max(1, std.math.divCeil(usize, count, columns) catch unreachable);
        }
        return font * 1.4 * @as(f32, @floatFromInt(rows));
    }

    fn viewportBlockTop(self: *const View) f32 {
        const content_top = self.body_scroll.content.globalRect().y;
        const blocks_top = self.blocks_host.?.globalRect().y - content_top;
        return self.body_scroll.state.scroll_y - blocks_top;
    }

    fn blockAt(self: *const View, top: f32) usize {
        var low: usize = 0;
        var high = self.block_rows.len;
        while (low < high) {
            const middle = low + (high - low) / 2;
            const row = self.block_rows[middle];
            const height = self.blockHeight(middle);
            if (row.top + height + block_gap <= top) low = middle + 1 else high = middle;
        }
        return low;
    }

    fn blockHeight(self: *const View, index: usize) f32 {
        return self.block_rows[index].height;
    }

    fn positionBlocks(self: *View) void {
        const a = self.cx.allocator;
        var top: f32 = 0;
        for (self.block_rows, 0..) |*row, i| {
            row.top = top;
            top += self.blockHeight(i) + block_gap;
        }
        for (self.rendered_blocks.items) |rendered| self.positionBlockRow(rendered.node, self.block_rows[rendered.index].top);
        const host = self.blocks_host.?;
        const height = @max(0, top - block_gap);
        if (host.style.height.px != height) host.setStyle(a, .height, .{ .px = height });
        host.setDisplay(if (height > 0) .flex else .none);
    }

    fn positionBlockRow(self: *View, row: *ui.Node, top: f32) void {
        if (row.style.inset().top.px == top) return;
        row.setStyle(self.cx.allocator, .inset, .{ .top = .{ .px = top }, .left = .{ .px = 0 } });
    }

    fn mountBlockRow(self: *View, host: *ui.Node, top: f32, gap: f32) !*ui.Node {
        var style = S.stack(gap);
        style.position = .absolute;
        style.inset = .{ .top = .{ .px = top }, .left = .{ .px = 0 } };
        const row = try ui.box(self.cx, style, .{});
        errdefer self.cx.destroyDetached(row);
        try host.appendChild(self.cx.allocator, row);
        return row;
    }

    fn destroyBlockRow(self: *View, node: *ui.Node) void {
        self.cx.detachChild(self.blocks_host.?, node);
        self.cx.destroyDetached(node);
    }

    fn removeEditorRow(self: *View) void {
        const active = self.editing_row orelse return;
        self.editing_row = null;
        self.clearEditorImage();
        self.clearEditorState();
        self.cx.detachChild(self.body_content, active.node);
        self.cx.destroyDetached(active.node);
        active.scope.dispose();
    }

    fn removeBlock(self: *View, rendered: *RenderedBlock) void {
        if (rendered.image) |image| {
            if (self.viewed_image == image) self.closeImageViewer();
            const index = std.mem.indexOfScalar(*editor_images.Image, self.images.items, image).?;
            _ = self.images.swapRemove(index);
        }
        const index = std.mem.indexOfScalar(*RenderedBlock, self.rendered_blocks.items, rendered).?;
        _ = self.rendered_blocks.swapRemove(index);
        const scope = rendered.scope;
        self.destroyBlockRow(rendered.node);
        scope.dispose();
    }

    fn mountBlock(self: *View, rendered: *RenderedBlock, block: editor.Block, text: []const u8, read_only: bool) !void {
        const cx = self.cx;
        const scope = rendered.scope;
        const content = block.text(text);
        if (block.kind == .image and self.texture_backend != null) {
            if (assets.parseImageLine(content)) |source| {
                const image = try editor_images.Image.mount(cx, scope, self.store, self.key.?.library_id, self.texture_backend.?, content, source, rendered.node, .{ .context = self, .show = showImage });
                try self.images.append(cx.allocator, image);
                rendered.image = image;
                return;
            }
        }
        var source_map: ?*const ui.widgets.markdown.SourceMap = null;
        const node = if (block.kind == .markdown) blk: {
            const value = try scope.createText(content, .{});
            const options = self.markdownOptions();
            if (read_only) break :blk try ui.widgets.Markdown(.{ .text = value, .options = options }).mount(scope, cx);
            const mapped = try ui.widgets.markdown.mountMapped(scope, cx, value.peek(), options);
            source_map = mapped.source_map;
            break :blk mapped.node;
        } else blk: {
            const label = try ui.text(cx, "", S.text(if (self.compact == true) 14 else 15, 400, S.theme.current().fg_1));
            try label.setTextContent(cx.allocator, content);
            label.setStyleInline(cx.allocator, .{ .width = .fill(), .min_width = 0, .flex_shrink = 0 });
            break :blk label;
        };
        node.meta.ownership.meta.test_id = "notes.document.block";
        if (!read_only) {
            const action = try scope.createState(Click, .{ .view = self, .action = .{ .begin_block = .{ .range = block } }, .block_node = node, .source_map = source_map });
            rendered.edit = action;
            node.behavior.events.on_click = cx.on(Click, action, Click.invoke);
            node.behavior.interaction.a11y = .{ .role = .button, .label = "编辑正文" };
        }
        try rendered.node.appendChild(cx.allocator, node);
    }

    fn revealSource(self: *View) bool {
        if (self.reading_caret) |caret| {
            if (self.blocks_host == null or self.editing_row != null) return false;
            self.reading_caret = null;
            return self.revealBlock(caret, false);
        }
        const source = self.source_range orelse return false;
        if (self.blocks_host == null or self.editing_row != null) return false;
        self.source_range = null;
        const shown_revision = if (self.lease) |lease| revision: {
            const document = self.documents.snapshot(lease) catch return false;
            break :revision if (document.dirty) null else document.stamp.base_revision;
        } else self.read_revision_seen;
        if (shown_revision != source.revision) {
            self.setBanner("内容已更新", false);
            return false;
        }
        return self.revealBlock(source.range.start_byte, false);
    }

    fn revealBlock(self: *View, offset: usize, align_top: bool) bool {
        if (self.blocks_host == null or self.editing_row != null) return false;
        for (self.block_ranges, 0..) |block, i| {
            if (offset > block.end and i + 1 < self.block_ranges.len) continue;
            const state = self.body_scroll.state;
            const top = state.scroll_y - self.viewportBlockTop() + self.block_rows[i].top;
            const height = self.blockHeight(i);
            ui.widgets.scroll_area.scrollRectIntoView(state, self.body_scroll.content, top, height, if (align_top or height > state.viewport_height) .start else .nearest);
            return true;
        }
        return false;
    }

    fn editorImageLine(self: *View) ?struct { raw: []const u8, source: assets.ImageLine } {
        const input = self.input orelse return null;
        const text = input.state.getText();
        const caret = input.state.cursor.offset;
        const start = if (std.mem.lastIndexOfScalar(u8, text[0..caret], '\n')) |newline| newline + 1 else 0;
        const end = std.mem.indexOfScalarPos(u8, text, start, '\n') orelse text.len;
        const raw = text[start..end];
        const source = assets.parseImageLine(raw) orelse return null;
        if (!assets.allowsImageParagraphAfter(text[0..start])) return null;
        return .{ .raw = raw, .source = source };
    }

    fn previewEditorImage(self: *View) !void {
        const line = self.editorImageLine() orelse return self.setBanner("请先将光标移到图片所在行", false);
        const backend = self.texture_backend orelse return;
        const key = self.key orelse return;
        self.clearEditorImage();
        const scope = try self.body_scope.?.childScope();
        errdefer scope.dispose();
        const image = try editor_images.Image.mount(self.cx, scope, self.store, key.library_id, backend, line.raw, line.source, self.body_content, .{ .context = self, .show = showImage });
        image.node.setDisplay(.none);
        self.editor_image = .{ .scope = scope, .image = image };
    }

    fn clearEditorImage(self: *View) void {
        const preview = self.editor_image orelse return;
        self.editor_image = null;
        if (self.viewed_image == preview.image) self.closeImageViewer();
        self.cx.detachChild(self.body_content, preview.image.node);
        self.cx.destroyDetached(preview.image.node);
        preview.scope.dispose();
    }

    fn updateEditorImage(self: *View) bool {
        const preview = if (self.editor_image) |*value| value else return false;
        if (!preview.pending) return false;
        const image = preview.image;
        _ = image.tick(true, @max(1, self.bodyWidth()), true, 96 * 1024 * 1024) catch {
            image.failed = true;
        };
        if (image.texture != null) {
            preview.pending = false;
            showImage(self, image);
            return true;
        }
        if (image.failed) {
            self.clearEditorImage();
            self.setBanner("无法读取图片", false);
            return true;
        }
        if (image.job != null and self.image_poll_timer == null) {
            self.image_poll_timer = self.cx.setTimer(20 * std.time.ns_per_ms, imagePoll, self) catch null;
        }
        return false;
    }

    fn updateImages(self: *View) bool {
        const editor_updated = self.updateEditorImage();
        if (self.images.items.len == 0 or self.input != null) return editor_updated;
        const viewport = self.body_scroll.container.globalRect();
        const width = self.bodyWidth();
        if (viewport.h <= 0 or width <= 1) return editor_updated;
        var running: usize = 0;
        var used: usize = 0;
        for (self.images.items) |image| {
            const rect = image.node.globalRect();
            if (rect.y + rect.h < viewport.y - 2 * viewport.h or rect.y > viewport.y + 3 * viewport.h) image.evict();
            used += image.bytes();
            if (image.job != null) running += 1;
        }
        var changed = editor_updated;
        for (self.images.items) |image| {
            const rect = image.node.globalRect();
            const visible = rect.y + rect.h >= viewport.y - viewport.h and rect.y <= viewport.y + 2 * viewport.h;
            const had_job = image.job != null;
            const before = image.bytes();
            if (image.tick(visible, width, running < 2, (96 * 1024 * 1024) -| used)) |updated| {
                changed = changed or updated;
            } else |_| {
                image.failed = true;
            }
            if (image.job != null and !had_job) {
                running += 1;
                self.render_counts.decodes += 1;
            }
            if (image.job == null and had_job) running -= 1;
            used += image.bytes() -| before;
        }
        if (running != 0 and self.image_poll_timer == null) {
            self.image_poll_timer = self.cx.setTimer(20 * std.time.ns_per_ms, imagePoll, self) catch null;
        }
        return changed;
    }

    fn imagePoll(raw: ?*anyopaque) void {
        const self: *View = @ptrCast(@alignCast(raw.?));
        self.image_poll_timer = null;
        if (!self.search_open) self.redraw();
    }

    fn cancelImagePoll(self: *View) void {
        if (self.image_poll_timer) |timer| self.cx.clearTimer(timer);
        self.image_poll_timer = null;
    }

    fn showImage(raw: *anyopaque, image: *editor_images.Image) void {
        const self: *View = @ptrCast(@alignCast(raw));
        const texture = image.texture orelse return;
        self.closeImageViewer();
        self.viewed_image = image;
        image.pinned = true;
        _ = self.fitImageViewer();
        self.image_modal_node.setImage(.{ .texture_id = texture });
        self.image_open.set(true);
        self.redraw();
    }

    fn fitImageViewer(self: *View) bool {
        const image = self.viewed_image orelse return false;
        const bounds = self.root.globalRect();
        if (bounds.w <= 0 or bounds.h <= 0) return false;
        const width: f32 = @floatFromInt(image.decoded.width);
        const height: f32 = @floatFromInt(image.decoded.height);
        const scale = @max(0, @min(1, @min((bounds.w - 96) / width, (bounds.h - 120) / height)));
        const fit_width = width * scale;
        const fit_height = height * scale;
        const node = self.image_modal_node;
        if (node.style.width == .px and node.style.width.px == fit_width and node.style.height == .px and node.style.height.px == fit_height) return false;
        node.setStyleInline(self.cx.allocator, .{ .width = .{ .px = fit_width }, .height = .{ .px = fit_height } });
        self.image_modal_dialog.setStyleInline(self.cx.allocator, .{ .width = .{ .px = fit_width + 32 } });
        return true;
    }

    fn closeImageViewer(self: *View) void {
        if (self.viewed_image) |image| {
            image.pinned = false;
            self.viewed_image = null;
            self.image_modal_node.setImage(null);
            self.image_open.set(false);
        }
    }

    fn imageModalChanged(self: *View, opened: bool) void {
        if (!opened) self.closeImageViewer();
    }

    fn markdownOptions(self: *const View) ui.widgets.MarkdownOptions {
        const c = S.theme.current();
        return .{
            .base_font_size = if (self.compact == true) 14 else 15,
            .code_font_size = 13,
            .text_color = c.fg_1,
            .code_color = c.fg_1,
            .code_bg = c.well,
            .rule_color = c.fg_2,
            .link_color = c.accent_ink,
            .paragraph_gap = 8,
            .code_line_height = 2.1,
        };
    }

    fn mountDocumentEditor(self: *View, text: []const u8) !void {
        if (self.editing_row != null) return;
        const a = self.cx.allocator;
        const scope = try self.body_scope.?.childScope();
        errdefer scope.dispose();
        const node = try ui.box(self.cx, S.stack(8), .{});
        errdefer self.cx.destroyDetached(node);
        node.setStyle(a, .margin, .{ .top = if (self.compact == true) 32 else 24 });
        try self.mountEditor(scope, node, text, false, true);
        try self.body_content.appendChild(a, node);
        self.editing_row = .{ .node = node, .scope = scope };
        self.blocks_host.?.setDisplay(.none);
        if (self.append_button) |button| button.setDisplay(.none);
        for (self.images.items) |image| image.pause();
        self.scroll_restore = 0;
    }

    fn mountEditor(self: *View, scope: *ui.Scope, parent: *ui.Node, text: []const u8, read_only: bool, live: bool) !void {
        const cx = self.cx;
        const value = try scope.createText(text, .{});
        const rows: u32 = @intFromFloat(@max(4, (self.root.globalRect().h - 160) / (if (live) @as(f32, 26) else 20)));
        const input = try ui.widgets.Textarea(.{
            .value = value,
            .rows = rows,
            .live_markdown = if (live) self.markdownOptions() else null,
            .readonly = read_only,
            .disabled = self.edit_disabled,
            .borderless = true,
            .placeholder = "开始输入…",
            .on_change = cx.on(View, self, bodyChanged),
        }).mountResult(scope, cx);
        input.input.meta.ownership.meta.test_id = "notes.editor.active";
        self.input = input;
        if (live) {
            input.wrapper.setStyleInline(cx.allocator, .{ .flex_shrink = 0 });
            try parent.appendChild(cx.allocator, input.wrapper);
        } else {
            const surface = try ui.box(cx, S.editor(rows), .{});
            try S.theme.bindMaterial(cx, scope, surface, "well");
            try surface.appendChild(cx.allocator, input.wrapper);
            try parent.appendChild(cx.allocator, surface);
        }
        if (!read_only) try self.mountImportNotice(scope, parent);
    }

    fn finishInput(self: *View) !void {
        if (self.title_invalid) return error.InvalidName;
        if (self.import_ticket != null or self.import_waiting_for_editor) return error.ImportInProgress;
        if (self.input) |input| if (input.state.imeIsComposing()) return error.InputComposition;
        if (self.title) |title| if (title.state.imeIsComposing()) return error.InputComposition;
        if (self.body_error != null) if (self.input) |input| try self.applyBody(input.state.getText());
    }

    fn finishBoundary(self: *View) !void {
        const boundary = self.edit_boundary orelse return;
        const lease = self.lease orelse return;
        const saved = try self.documents.snapshot(lease);
        try self.documents.recordBodyChange(saved.stamp, boundary.body_generation, .{ .start = 0, .end = saved.body_md.len }, boundary.previous);
        self.discardBoundary();
    }

    fn discardBoundary(self: *View) void {
        if (self.edit_boundary) |boundary| self.cx.allocator.free(boundary.previous);
        self.edit_boundary = null;
    }

    fn titleChanged(self: *View, text: []const u8) void {
        const lease = self.lease orelse return;
        const title = model.normalizeName(text, model.max_title) catch |err| {
            self.title_invalid = true;
            self.showError(err);
            return;
        };
        if (self.title_invalid or self.title_rejected) self.clearError();
        self.title_invalid = false;
        self.title_rejected = false;
        const prior = self.documents.snapshot(lease) catch |err| return self.showError(err);
        const changed = !std.mem.eql(u8, prior.title, title);
        self.documents.edit(prior.stamp, .{ .title = title, .body_md = prior.body_md }) catch |err| return self.showError(err);
        self.title_dirty = self.title_dirty or changed;
        self.scheduleSave();
    }

    fn bodyChanged(self: *View, text: []const u8) void {
        if (!self.acceptsNewEdits()) return;
        self.applyBody(text) catch |err| {
            self.body_error = err;
            self.showError(err);
        };
    }

    fn acceptsNewEdits(self: *const View) bool {
        return self.active and !self.search_open and self.card != .tree and
            !(self.compact == true and (self.tree_open or self.card == .outline)) and self.lock_mode == null;
    }

    fn captureEditBoundary(self: *View, prior: sessions.Snapshot) !void {
        if (self.edit_boundary != null) return;
        self.edit_boundary = .{
            .previous = try self.cx.allocator.dupe(u8, prior.body_md),
            .body_generation = prior.body_generation,
        };
    }

    fn applyBody(self: *View, text: []const u8) !void {
        const lease = self.lease orelse return error.Unavailable;
        const prior = try self.documents.snapshot(lease);
        try self.captureEditBoundary(prior);
        try self.documents.edit(prior.stamp, .{ .title = prior.title, .body_md = text });
        const changed = try self.documents.snapshot(lease);
        self.body_generation_seen = changed.body_generation;
        if (self.card == .outline and changed.body_generation != prior.body_generation) {
            self.outline_dirty = true;
            self.redraw();
        }
        if (self.card == .search) {
            self.find_model.setSource(changed.body_md) catch {};
            self.find_view.refresh();
        }
        if (self.import_ticket != null and changed.pending_import == null) self.cancelImport();
        self.body_error = null;
        self.scheduleSave();
    }

    fn scheduleSave(self: *View) void {
        self.cancelSaveTimer();
        const delay = sessions.Sessions.save_delay_ns;
        self.save_timer = self.cx.setTimer(delay, saveDue, self) catch {
            self.startSave();
            return;
        };
        self.save_deadline_ns = std.Io.Clock.awake.now(self.store.io).toNanoseconds() + delay;
    }

    fn cancelSaveTimer(self: *View) void {
        if (self.save_timer) |timer| self.cx.clearTimer(timer);
        self.save_timer = null;
        self.save_deadline_ns = null;
    }

    fn saveDue(raw: ?*anyopaque) void {
        const self: *View = @ptrCast(@alignCast(raw.?));
        self.save_timer = null;
        self.save_deadline_ns = null;
        self.startSave();
    }

    fn advanceBackgroundWork(self: *View, now_ns: i128) void {
        if (self.disposed or self.active) return;
        if (self.import_job) |job| if (job.done.load(.acquire)) {
            if (self.import_timer) |timer| self.cx.clearTimer(timer);
            importPoll(self);
        };
        if (self.save_worker) |worker| if (worker.done.load(.acquire)) {
            if (self.save_poll_timer) |timer| self.cx.clearTimer(timer);
            pollSave(self);
        };
        if (self.save_deadline_ns) |deadline| if (now_ns >= deadline) {
            self.cancelSaveTimer();
            self.startSave();
        };
    }

    fn startSave(self: *View) void {
        const lease = self.lease orelse return;
        if (self.save_worker != null) {
            self.save_queued = true;
            return;
        }
        const packet = (self.documents.beginSave(lease, .save) catch |err| {
            if (err != error.ImportInProgress) self.showSaveError(err);
            return;
        }) orelse return;
        const refresh_tree = self.title_dirty;
        self.title_dirty = false;
        self.startCommit(packet, refresh_tree);
    }

    fn commitReadOnly(self: *View) !void {
        if (self.lock_mode != null) return;
        try self.finishInput();
        const lease = self.lease orelse return;
        try self.settleSave();
        const saved = try self.documents.snapshot(lease);
        try self.finishBoundary();
        const mode: sessions.SaveMode = if (saved.read_only) .unlock else .lock;
        const packet = (try self.documents.beginSave(lease, mode)) orelse return;
        self.cancelSaveTimer();
        self.lock_mode = mode;
        const refresh_tree = self.title_dirty;
        self.title_dirty = false;
        if (self.active) if (self.cx.focus_manager.getFocused()) |focused| {
            if (focused.isDescendantOf(self.root)) {
                self.lock_focus = self.cx.node_registry.handleFor(focused);
                self.cx.setFocus(self.root);
            }
        };
        self.syncLockState();
        self.startCommit(packet, refresh_tree);
    }

    fn syncLockState(self: *View) void {
        if (!self.active) return;
        const mode = self.lock_mode;
        self.edit_disabled.set(mode != null);
        if (mode) |operation| {
            self.lock_status.setTextContent(self.cx.allocator, if (operation == .lock) "正在设为只读…" else "正在解除只读…") catch {};
            self.lock_status.setDisplay(.flex);
            self.image_disabled.set(true);
        } else {
            self.lock_status.setDisplay(.none);
            if (self.lease) |lease| {
                if (self.documents.snapshot(lease)) |saved| self.image_disabled.set(saved.read_only) else |_| {}
            }
        }
        self.redraw();
    }

    fn startCommit(self: *View, packet: sessions.Commit, refresh_tree: bool) void {
        const worker = self.cx.allocator.create(SaveWorker) catch return self.saveNow(packet, refresh_tree);
        worker.* = .{ .store = self.store, .packet = packet, .refresh_tree = refresh_tree };
        worker.thread = std.Thread.spawn(.{}, SaveWorker.run, .{worker}) catch {
            self.cx.allocator.destroy(worker);
            return self.saveNow(packet, refresh_tree);
        };
        self.save_worker = worker;
        self.scheduleSavePoll();
    }

    fn saveNow(self: *View, packet: sessions.Commit, refresh_tree: bool) void {
        var owned = packet;
        defer owned.deinit(self.documents.allocator);
        self.acceptSave(packet.run(self.store), refresh_tree) catch {};
    }

    fn scheduleSavePoll(self: *View) void {
        self.save_poll_timer = self.cx.setTimer(20 * std.time.ns_per_ms, pollSave, self) catch {
            self.settleSave() catch {};
            return;
        };
    }

    fn pollSave(raw: ?*anyopaque) void {
        const self: *View = @ptrCast(@alignCast(raw.?));
        self.save_poll_timer = null;
        const worker = self.save_worker orelse return;
        if (!worker.done.load(.acquire)) return self.scheduleSavePoll();
        const queued = self.save_queued;
        self.settleSave() catch return;
        if (queued and self.save_timer == null) self.startSave();
    }

    fn settleSave(self: *View) !void {
        const worker = self.save_worker orelse return;
        self.save_worker = null;
        self.save_queued = false;
        if (self.save_poll_timer) |timer| self.cx.clearTimer(timer);
        self.save_poll_timer = null;
        worker.thread.join();
        defer self.cx.allocator.destroy(worker);
        defer worker.packet.deinit(self.documents.allocator);
        try self.acceptSave(worker.result, worker.refresh_tree);
    }

    fn acceptSave(self: *View, receipt: sessions.Receipt, refresh_tree: bool) !void {
        const read_only_changed = receipt.request.mode != .save;
        if (read_only_changed) self.lock_mode = null;
        self.documents.finishSave(receipt) catch |err| {
            self.title_dirty = self.title_dirty or refresh_tree;
            self.cancelSaveTimer();
            if (read_only_changed and !self.disposed) {
                self.lock_failure = receipt.request.mode;
                self.syncLockState();
                if (self.active) if (self.lock_focus) |handle| {
                    if (self.cx.focus_manager.getFocused() == self.root or self.cx.focus_manager.getFocused() == null) {
                        if (self.cx.node_registry.resolve(handle, null)) |node| self.cx.setFocus(node);
                    }
                };
                self.lock_focus = null;
            }
            if (!self.disposed) self.showSaveError(err);
            return err;
        };
        self.lock_failure = null;
        self.resolveSaveFeedback();
        if (read_only_changed and !self.disposed) {
            self.lock_focus = null;
            self.editing = false;
            self.editor_offset = null;
            self.body_dirty = true;
            self.tree_dirty = true;
            self.syncLockState();
        }
        self.tree_dirty = self.tree_dirty or refresh_tree;
        if (self.active) {
            if (self.save_banner and !self.title_invalid) self.clearError();
            if (refresh_tree) self.redraw();
        }
    }

    fn flushDraft(self: *View) !void {
        const lease = self.lease orelse return;
        try self.settleSave();
        self.documents.flush(lease) catch |err| {
            if (err != error.ImportInProgress) self.showSaveError(err);
            return err;
        };
        self.resolveSaveFeedback();
        self.cancelSaveTimer();
        self.tree_dirty = self.tree_dirty or self.title_dirty;
        self.title_dirty = false;
    }

    fn retrySave(self: *View) void {
        if (self.lock_failure != null) {
            self.commitReadOnly() catch |err| self.showError(err);
            return;
        }
        self.finishInput() catch |err| return self.showError(err);
        self.cancelSaveTimer();
        self.startSave();
    }

    fn chooseImage(self: *View) void {
        if (!self.acceptsNewEdits() or self.image_picker != null) return;
        const lease = self.lease orelse return;
        const sheet = FileSheet.begin(self.cx, .{ .kind = .file, .title = "选择笔记图片" }) catch |err| return self.importFailed(err);
        self.image_picker = .{ .sheet = sheet, .lease = lease };
        self.cx.scheduleRedrawAfterNs(50 * std.time.ns_per_ms);
    }

    fn pollImagePicker(self: *View) void {
        const picker = self.image_picker orelse return;
        const count = picker.sheet.count() orelse {
            self.cx.scheduleRedrawAfterNs(50 * std.time.ns_per_ms);
            return;
        };
        self.image_picker = null;
        defer picker.sheet.deinit();
        if (count == 0 or !self.acceptsNewEdits() or !std.meta.eql(self.lease, @as(?sessions.Lease, picker.lease))) return;
        var path_buffer: [4096]u8 = undefined;
        const path = picker.sheet.path(0, &path_buffer) catch |err| return self.importFailed(err);
        self.queueImport(.{ .file = path }) catch |err| self.importFailed(err);
    }

    fn cancelImagePicker(self: *View) void {
        if (self.image_picker) |picker| picker.sheet.deinit();
        self.image_picker = null;
    }

    fn pasteImage(self: *View) bool {
        if (!self.acceptsNewEdits()) return false;
        const input = self.input orelse return false;
        const lease = self.lease orelse return false;
        const document = self.documents.snapshot(lease) catch return false;
        if (document.read_only or self.lock_mode != null) return false;
        if (input.state.imeIsComposing()) return false;
        const focused = self.cx.focus_manager.getFocused() orelse return false;
        if (focused != input.input and !focused.isDescendantOf(input.input)) return false;
        var pasted = (editor_clipboard.read(self.cx) catch |err| {
            self.importFailed(err);
            return true;
        }) orelse return false;
        defer pasted.deinit();
        self.queueImport(pasted.input) catch |err| self.importFailed(err);
        return true;
    }

    fn queueImport(self: *View, input: editor_images.ImportInput) !void {
        if (self.import_job != null or self.import_waiting_for_editor) return error.ImportInProgress;
        try self.finishInput();
        const lease = self.lease orelse return error.Unavailable;
        if ((try self.documents.snapshot(lease)).read_only) return error.ReadOnly;
        const source = try self.cx.allocator.dupe(u8, switch (input) {
            .file, .clipboard => |value| value,
        });
        self.clearImportInput();
        self.import_input = .{
            .lease = lease,
            .input = switch (input) {
                .file => .{ .file = source },
                .clipboard => .{ .clipboard = source },
            },
        };
        try self.queueImportStart();
    }

    fn queueImportStart(self: *View) !void {
        const pending = self.import_input orelse return;
        if (!std.meta.eql(self.lease, @as(?sessions.Lease, pending.lease))) return error.Unavailable;
        if (self.input == null) {
            // Open the append editor at the same safe boundary as a click.
            try self.perform(.append_block);
            self.import_waiting_for_editor = true;
            self.redraw();
            return;
        }
        try self.startImport();
    }

    fn startImport(self: *View) !void {
        if (self.import_job != null) return error.ImportInProgress;
        const pending = self.import_input orelse return;
        const input = self.input orelse return error.Unavailable;
        if (!std.meta.eql(self.lease, @as(?sessions.Lease, pending.lease))) return error.Unavailable;
        // The ticket must name the revision after any already-dispatched save.
        try self.settleSave();
        const saved = try self.documents.snapshot(pending.lease);
        const range: sessions.Range = if (input.state.cursor.selection()) |selection|
            .{ .start = selection.start, .end = selection.end }
        else
            .{ .start = input.state.cursor.offset, .end = input.state.cursor.offset };
        try editor_images.validateInsertion(saved.body_md, saved.pending_import orelse range);
        const ticket = self.import_ticket orelse try self.documents.beginImport(saved.stamp, range);
        self.import_ticket = ticket;
        const worker = try editor_images.Import.start(self.cx.allocator, self.store, ticket, pending.input);
        self.import_job = worker;
        self.import_feedback = .running;
        self.syncImportFeedback();
        self.scheduleImportPoll();
    }

    fn scheduleImportPoll(self: *View) void {
        self.import_timer = self.cx.setTimer(20 * std.time.ns_per_ms, importPoll, self) catch null;
    }

    fn importPoll(raw: ?*anyopaque) void {
        const self: *View = @ptrCast(@alignCast(raw.?));
        self.import_timer = null;
        const job = self.import_job orelse return;
        if (!job.done.load(.acquire)) return self.scheduleImportPoll();
        if (!job.cancel.isCancelled() and self.active) {
            if (self.input) |input| if (input.state.imeIsComposing()) return self.scheduleImportPoll();
        }
        self.import_job = null;
        defer job.deinit(self.cx.allocator);
        if (job.cancel.isCancelled()) return self.syncImportFeedback();
        self.finishImport(job) catch |err| {
            if (err == error.StaleImport) return self.cancelImport();
            self.importFailed(err);
        };
    }

    fn finishImport(self: *View, job: *editor_images.Import) !void {
        const imported = try job.result;
        const lease = job.ticket.stamp.lease;
        const saved = try self.documents.snapshot(lease);
        const range = saved.pending_import orelse return error.StaleImport;
        const markdown = try editor_images.insertion(self.cx.allocator, saved.body_md, range, imported.relativePath());
        defer self.cx.allocator.free(markdown);
        if (self.active and !self.lock_after_import and self.input != null and self.body_error == null) {
            const input = self.input.?;
            const caret = input.state.cursor.offset;
            const anchor = input.state.cursor.anchor orelse caret;
            const at_import = @min(caret, anchor) == range.start and @max(caret, anchor) == range.end;
            const inserted_end = range.start + markdown.len;
            const trailing_newlines = markdown.len - std.mem.trimEnd(u8, markdown, "\n").len;
            const following_line = inserted_end + (2 - trailing_newlines);
            try self.captureEditBoundary(saved);
            try self.documents.completeImportInEditor(job.ticket, markdown);
            const landed = try self.documents.snapshot(lease);
            self.body_generation_seen = landed.body_generation;
            if (input.state.replaceRangeChecked(range.start, range.end, markdown)) |_| {
                input.value.?.set(input.state.getText());
                if (at_import and inserted_end != following_line) {
                    _ = input.state.setAccessibilitySelection(@intCast(following_line), @intCast(following_line));
                } else if (!at_import) {
                    const mapped_anchor = mapImportOffset(anchor, range, inserted_end);
                    const mapped_caret = mapImportOffset(caret, range, inserted_end);
                    _ = input.state.setAccessibilitySelection(@intCast(mapped_anchor), @intCast(mapped_caret));
                }
            } else |_| {
                // The durable insertion succeeded. Reload the committed draft
                // if the widget could not allocate an undo entry.
                self.finishBoundary() catch |err| self.showError(err);
                self.removeEditorRow();
                self.editor_offset = following_line;
                self.focus_pending = true;
                self.body_dirty = true;
            }
        } else {
            try self.finishBoundary();
            try self.documents.completeImport(job.ticket, markdown);
            self.editing = false;
            self.reading_caret = range.start;
            self.editor_offset = null;
            self.source_mode = false;
            self.body_dirty = true;
        }
        self.import_ticket = null;
        self.clearImportInput();
        self.import_feedback = .idle;
        self.syncImportFeedback();
        if (self.lock_after_import) {
            self.lock_after_import = false;
            self.commitReadOnly() catch |err| {
                if (self.active) self.showError(err);
                self.scheduleSave();
            };
            return;
        }
        self.redraw();
        self.scheduleSave();
    }

    fn mapImportOffset(offset: usize, range: sessions.Range, inserted_end: usize) usize {
        if (offset <= range.start) return offset;
        if (offset < range.end) return inserted_end;
        return inserted_end + (offset - range.end);
    }

    fn cancelImport(self: *View) void {
        if (self.import_ticket) |ticket| self.documents.cancelImport(ticket) catch {};
        self.import_ticket = null;
        if (self.import_job) |job| job.cancel.cancel();
        self.lock_after_import = false;
        self.import_waiting_for_editor = false;
        self.clearImportInput();
        self.import_feedback = .idle;
        self.syncImportFeedback();
        self.scheduleSave();
    }

    fn retryImport(self: *View) void {
        self.queueImportStart() catch |err| self.importFailed(err);
    }

    fn clearImportInput(self: *View) void {
        if (self.import_input) |entry| self.cx.allocator.free(switch (entry.input) {
            .file, .clipboard => |source| source,
        });
        self.import_input = null;
    }

    fn importFailed(self: *View, err: anyerror) void {
        if (err == error.ImportInProgress) return;
        self.lock_after_import = false;
        self.import_feedback = .{ .failed = err };
        self.syncImportFeedback();
        if (self.active and self.import_notice == null) self.setBanner(importMessage(err), false);
        self.redraw();
    }

    fn importMessage(err: anyerror) []const u8 {
        return switch (err) {
            error.UnsupportedImage, error.AnimatedImageUnsupported => "不支持此图片格式",
            error.ImageTooLarge, error.ImageMemoryBudgetExceeded => "图片超出大小限制",
            error.InvalidImageLocation => "请在代码块或注释外插入图片",
            else => "导入图片失败",
        };
    }

    fn mountImportNotice(self: *View, scope: *ui.Scope, parent: *ui.Node) !void {
        const cx = self.cx;
        const notice = try ui.box(cx, S.row(34, 8), .{});
        errdefer cx.destroyDetached(notice);
        notice.meta.ownership.meta.test_id = "notes.image.import";
        notice.setStyleInline(cx.allocator, .{ .padding = .{ .left = 10, .right = 4 }, .background = S.theme.current().well, .border = .{ .radius = 8 } });
        notice.setDisplay(.none);
        const message = try ui.text(cx, "", S.text(12, 400, S.theme.current().fg_2));
        message.setStyleInline(cx.allocator, .{ .width = .fill(), .min_width = 0 });
        message.behavior.interaction.a11y = .{ .role = .status, .live = "polite" };
        try notice.appendChild(cx.allocator, message);
        const retry = try ui.widgets.Button(.{ .variant = .ghost, .label = "重试", .on_click = cx.on(View, self, retryImport) }).mount(scope, cx);
        retry.meta.ownership.meta.test_id = "notes.image.retry";
        try notice.appendChild(cx.allocator, retry);
        const cancel_label = try scope.createText("取消", .{});
        const cancel = try ui.widgets.Button(.{ .variant = .ghost, .label = cancel_label, .on_click = cx.on(View, self, cancelImport) }).mount(scope, cx);
        cancel.meta.ownership.meta.test_id = "notes.image.remove";
        try notice.appendChild(cx.allocator, cancel);
        try parent.appendChild(cx.allocator, notice);
        self.import_notice = .{ .root = notice, .message = message, .retry = retry, .cancel_label = cancel_label };
        self.syncImportFeedback();
    }

    fn syncImportFeedback(self: *View) void {
        if (!self.active) return;
        const notice = self.import_notice orelse return;
        const text = switch (self.import_feedback) {
            .idle => "",
            .running => "正在导入图片…",
            .failed => |err| importMessage(err),
        };
        if (text.len != 0 and !std.mem.eql(u8, notice.message.getText().?.content, text)) {
            notice.message.setTextContent(self.cx.allocator, text) catch {};
        }
        notice.cancel_label.set(if (self.import_feedback == .failed) "移除" else "取消");
        notice.retry.setDisplay(if (self.import_feedback == .failed and self.import_input != null and self.import_job == null) .flex else .none);
        notice.root.setDisplay(if (text.len == 0) .none else .flex);
    }

    fn openCreate(self: *View, request: Create) void {
        self.create_request = request;
        self.name_title.set(switch (request) {
            .library => "新建目录",
            .folder => "新建子目录",
            .note => "新建文档",
        });
        self.name_value.set("");
        self.name_error.setDisplay(.none);
        self.name_open.set(true);
        self.focus_name = true;
        self.redraw();
    }

    fn createConfirmed(self: *View) void {
        self.createObject() catch |err| {
            self.name_error.setTextContent(self.cx.allocator, errorText(err)) catch {};
            self.name_error.setDisplay(.flex);
            self.redraw();
            return;
        };
        self.name_open.set(false);
        self.create_request = null;
        self.redraw();
    }

    fn createSubmitted(self: *View, _: []const u8) void {
        self.createConfirmed();
    }

    fn createObject(self: *View) !void {
        const request = self.create_request orelse return;
        const name = self.name_value.peek();
        switch (request) {
            .library => {
                self.directory = .{ .library = try self.store.createLibrary(name) };
                self.tree_preference = true;
                self.layout_dirty = true;
            },
            .folder => |directory| {
                var library = try self.store.loadLibrary(self.cx.allocator, directory.library, .active);
                defer library.deinit();
                const id = try self.store.createFolder(directory.library, directory.folder, name, library.value.revision);
                self.expandDirectoryPath(library.value, directory.folder);
                self.directory = .{ .library = directory.library, .folder = id, .depth = directory.depth + 1 };
            },
            .note => |directory| {
                try self.finishInput();
                try self.flushDraft();
                const key = try self.store.createNote(directory.library, directory.folder, name);
                self.pending = .{ .select_note = key };
            },
        }
        self.tree_dirty = true;
        if (self.key == null) self.body_dirty = true;
    }

    fn showError(self: *View, err: anyerror) void {
        if (self.lease) |lease| {
            if (self.documents.snapshot(lease)) |document| {
                if (document.save_error) |save_error| {
                    if (save_error == err) return self.showSaveError(err);
                }
            } else |_| {}
        }
        self.setBanner(errorText(err), false);
    }

    fn showSaveError(self: *View, err: anyerror) void {
        var buffer: [256]u8 = undefined;
        const operation = switch (self.lock_failure orelse .save) {
            .save => "保存失败",
            .lock => "设为只读失败",
            .unlock => "解除只读失败",
        };
        const text = std.fmt.bufPrint(&buffer, "{s}：{s}", .{ operation, errorText(err) }) catch operation;
        if (self.active) {
            self.setBanner(text, true);
        } else if (self.save_feedback) |report| {
            self.save_notice = true;
            report.call(errorText(err));
        }
    }

    fn resolveSaveFeedback(self: *View) void {
        if (!self.save_notice or self.disposed) return;
        self.save_notice = false;
        if (self.save_feedback) |report| report.call(null);
    }

    fn setBanner(self: *View, text: []const u8, retry: bool) void {
        self.save_banner = retry;
        self.error_text.setTextContent(self.cx.allocator, text) catch {};
        self.banner.setDisplay(.flex);
        self.retry.setDisplay(if (retry) .flex else .none);
        self.redraw();
    }

    fn clearError(self: *View) void {
        self.save_banner = false;
        self.banner.setDisplay(.none);
        self.redraw();
    }

    fn errorText(err: anyerror) []const u8 {
        return switch (err) {
            error.InvalidName => "请输入有效的名称",
            error.NameTooLong => "名称超过长度限制",
            error.NameConflict => "当前位置已存在同名目录",
            error.InputComposition => "请先完成当前输入",
            error.ImportInProgress => "正在导入图片，请等待或取消导入",
            error.ReadOnly => "文档为只读",
            error.DocumentInUse => "文档正在另一窗口编辑",
            error.RevisionChanged => "内容已在另一处更新",
            error.AccessDenied => "请检查笔记目录权限",
            error.NoSpaceLeft => "磁盘空间不足",
            error.RecordTooLarge => "文档超过大小限制",
            error.FileNotFound, error.Unavailable => "笔记已移动或删除",
            else => "操作失败，请重试",
        };
    }

    fn handleKey(self: *View, key: ui.events.KeyCode, mods: ui.events.Modifiers) ui.events.EventResult {
        if (!self.active or self.name_open.peek() or self.lock_choice.peek() or self.settings.open.peek() or self.manager.open.peek() or self.image_open.peek()) return .ignored;
        if (key == .v and mods.super and !mods.shift and !mods.ctrl and !mods.alt and !self.search_open and self.pasteImage()) return .stop;
        if (key == .@"return" and mods.super and !mods.shift and !mods.ctrl and !mods.alt and !self.search_open) {
            if (self.input) |input| if (self.cx.focus_manager.getFocused() == input.input and !input.state.imeIsComposing()) {
                if (self.editorImageLine() != null) {
                    self.enqueue(.preview_editor_image);
                    return .stop;
                }
            };
        }
        if (key == .f and mods.super and !mods.shift and !mods.ctrl and !mods.alt) {
            self.enqueue(if (self.search_open) .search else .find_document);
            return .stop;
        }
        if (key == .s and mods.super and !mods.shift and !mods.ctrl and !mods.alt) {
            self.retrySave();
            return .stop;
        }
        if (key == .z and mods.super and !mods.ctrl and !mods.alt and !self.search_open and self.input == null and self.lease != null) {
            if (self.title) |title| if (self.cx.focus_manager.getFocused() == title.node) return .ignored;
            self.enqueue(.{ .undo = mods.shift });
            return .stop;
        }
        if (key == .escape and !mods.super and !mods.ctrl and !mods.alt and !mods.shift) {
            if (self.card != .none) {
                if (self.card == .search and self.find_view.input_result.state.imeIsComposing()) return .ignored;
                self.enqueue(.dismiss_card);
                return .stop;
            }
            if (self.search_open and self.search.imeIsComposing()) return .ignored;
            if (self.input) |input| if (input.state.imeIsComposing()) return .ignored;
            if (self.title) |title| if (title.state.imeIsComposing()) return .ignored;
            if (self.compact == true and self.tree_open) {
                self.enqueue(.toggle_tree);
                return .stop;
            }
            if (self.search_open) {
                self.enqueue(.search_back);
                return .stop;
            }
            if (self.source_mode or self.editing) {
                self.enqueue(if (self.source_mode) .toggle_source else .end_block);
                return .stop;
            }
            if (self.search_origin != null) {
                self.enqueue(.search);
                return .stop;
            }
        }
        return .ignored;
    }

    fn keyEvent(event: ui.events.Event, raw: ?*anyopaque) ui.events.EventResult {
        const self: *View = @ptrCast(@alignCast(raw.?));
        return switch (event) {
            .key_down => |key| self.handleKey(key.key, key.modifiers),
            else => .ignored,
        };
    }

    fn actionButton(self: *View, scope: *ui.Scope, action: Action, label: []const u8, asset: ?ui.SvgAsset, icon_only: bool, id: []const u8) !*ui.Node {
        const state = try scope.createState(Click, .{ .view = self, .action = action });
        const button = try ui.widgets.Button(.{
            .variant = .ghost,
            .label = if (icon_only) "" else label,
            .a11y_label = label,
            .icon_asset = asset,
            .icon_only = icon_only,
            .icon_size = @as(f32, 16),
            .base_style = if (icon_only) S.tool() else ui.BoxStyle{},
            .on_click = self.cx.on(Click, state, Click.invoke),
        }).mount(scope, self.cx);
        button.meta.ownership.meta.test_id = id;
        return button;
    }

    fn mountModal(self: *View) !void {
        const cx = self.cx;
        const scope = self.scope;
        const modal = try ui.widgets.Modal(.{
            .open = self.name_open,
            .title = self.name_title,
            .width = @as(f32, 352),
            .managed_focus = false,
            .close_on_overlay = false,
            .enter_transition = .none,
            .exit_transition = .none,
        }).mount(scope, cx);
        modal.overlay.meta.ownership.meta.test_id = "notes.directory.overlay";
        if (!modal.portaled) try self.root.appendChild(cx.allocator, modal.overlay);
        _ = try scoped_modal.bind(cx, scope, modal, .{ .owner = .{ .node = self.root } });
        const form = try ui.box(cx, S.stack(12), .{});
        try modal.body.appendChild(cx.allocator, form);
        const name = try ui.widgets.Input(.{
            .value = self.name_value,
            .placeholder = "名称",
            .on_submit = cx.on(View, self, createSubmitted),
        }).mountResult(scope, cx);
        self.name_input = name.input_container;
        self.name_input.meta.ownership.meta.test_id = "notes.directory.name";
        try form.appendChild(cx.allocator, name.node);
        self.name_error = try ui.text(cx, "", S.text(12, 400, S.theme.current().warn_ink));
        self.name_error.setDisplay(.none);
        try form.appendChild(cx.allocator, self.name_error);
        const actions = try ui.hstack(cx, .{ .width = .fill(), .justify = .end, .flex_shrink = 0 }, .{});
        try form.appendChild(cx.allocator, actions);
        const button = try ui.widgets.Button(.{ .label = "新建", .on_click = cx.on(View, self, createConfirmed) }).mount(scope, cx);
        button.meta.ownership.meta.test_id = "notes.directory.confirm";
        try actions.appendChild(cx.allocator, button);
    }

    fn mountLockChoice(self: *View) !void {
        const cx = self.cx;
        const scope = self.scope;
        const modal = try ui.widgets.Modal(.{
            .open = self.lock_choice,
            .title = "设为只读",
            .width = @as(f32, 420),
            .managed_focus = false,
            .background = S.theme.current().overlay,
            .close_on_overlay = false,
            .enter_transition = .none,
            .exit_transition = .none,
        }).mount(scope, cx);
        modal.dialog.meta.ownership.meta.test_id = "notes.read-only.import-choice";
        modal.dialog.setStyleInline(cx.allocator, .{ .border = .{ .radius = 14 } });
        if (!modal.portaled) try self.root.appendChild(cx.allocator, modal.overlay);
        _ = try scoped_modal.bind(cx, scope, modal, .{ .owner = .{ .node = self.root } });
        modal.body.setStyleInline(cx.allocator, .{ .padding = ui.Padding.all(24), .gap = 16 });
        try modal.body.appendChild(cx.allocator, try ui.text(cx, "这篇笔记有尚未完成的图片导入。", S.text(14, 400, S.theme.current().fg_2)));
        const actions = try ui.box(cx, S.row(34, 8), .{});
        actions.setStyleInline(cx.allocator, .{ .justify = .end });
        try actions.appendChild(cx.allocator, try self.actionButton(scope, .cancel_import_and_lock, "取消导入并设为只读", null, false, "notes.read-only.cancel-import"));
        const wait = try scope.createState(Click, .{ .view = self, .action = .wait_to_lock });
        const wait_button = try ui.widgets.Button(.{ .label = "等待导入", .on_click = cx.on(Click, wait, Click.invoke) }).mount(scope, cx);
        wait_button.meta.ownership.meta.test_id = "notes.read-only.wait-import";
        try actions.appendChild(cx.allocator, wait_button);
        try modal.body.appendChild(cx.allocator, actions);
    }

    fn prepareClose(raw: *anyopaque) !void {
        const self: *View = @ptrCast(@alignCast(raw));
        if (self.title_invalid) return error.InvalidName;
        if (self.import_waiting_for_editor) return error.ImportInProgress;
        if (self.settings.open.peek()) try self.settings.commit();
        if (self.input) |input| if (input.state.imeIsComposing()) input.state.cancelImeComposition();
        if (self.title) |title| if (title.state.imeIsComposing()) title.state.cancelImeComposition();
        try self.finishInput();
        try self.settleSave();
        self.documents.flushOwner(self.owner) catch |err| {
            if (err == error.ImportInProgress) self.showError(err) else self.showSaveError(err);
            return err;
        };
        self.resolveSaveFeedback();
        try self.finishBoundary();
        self.cancelSaveTimer();
    }

    fn update(raw: *anyopaque, value: contract.ContentUpdate) !void {
        const self: *View = @ptrCast(@alignCast(raw));
        if (!self.owner.eql(value.owner)) return error.StaleSession;
        self.tree_dirty = true;
        self.redraw();
    }

    fn focusChanged(_: *anyopaque, _: bool) void {}

    fn presentationChanged(raw: *anyopaque, value: contract.ContentPresentation) void {
        const self: *View = @ptrCast(@alignCast(raw));
        const visible = value == .active;
        if (self.disposed or self.active == visible) return;
        self.active = visible;
        self.search.setActive(self.active and self.search_open);
        if (self.active) {
            self.tree_geometry_refresh = true;
            self.syncLockState();
            self.syncImportFeedback();
            if (self.lease) |lease| if (self.documents.snapshot(lease)) |document| {
                if (document.save_error) |err| self.showSaveError(err) else if (self.save_banner) self.clearError();
                if (self.body_generation_seen != document.body_generation) {
                    self.editing = false;
                    self.discardBoundary();
                    self.body_dirty = true;
                }
            } else |_| {} else if (self.key) |key| {
                if (self.store.loadNote(self.cx.allocator, key, .active)) |record| {
                    var note = record;
                    defer note.deinit();
                    if (self.read_revision_seen != note.value.revision) self.body_dirty = true;
                } else |err| {
                    if (err == error.Unavailable or err == error.FileNotFound) self.clearDocument();
                    self.showError(err);
                }
            }
            self.redraw();
        } else {
            self.showCard(.none);
            self.cancelImagePoll();
            if (self.cx.focus_manager.getFocused()) |focused| {
                if (focused == self.root or focused.isDescendantOf(self.root)) {
                    self.presentation_focus = self.cx.node_registry.handleFor(focused);
                    self.cx.setFocus(null);
                }
            }
            self.name_open.set(false);
            self.lock_choice.set(false);
            self.cancelImagePicker();
            self.settings.dismiss();
            self.manager.dismiss();
            self.clearEditorImage();
            self.closeImageViewer();
            for (self.tree_actions.items) |entry| {
                entry.hovered = false;
                if (entry.menu.open.peek()) entry.menu.open.set(false);
            }
            for (self.images.items) |image| image.pause();
        }
    }

    fn unmount(raw: *anyopaque) void {
        const self: *View = @ptrCast(@alignCast(raw));
        self.closeImageViewer();
        self.dispose();
    }

    fn focusDocument(self: *View) void {
        if (self.search_open) return self.search.focus();
        self.cx.setFocus(if (self.input) |input| input.input else self.root);
    }

    fn settingsChanged(self: *View) void {
        self.tree_dirty = true;
        self.updateBreadcrumb() catch {};
        self.redraw();
    }

    fn dispose(self: *View) void {
        if (self.disposed) return;
        self.setFloatingHeader(null);
        self.disposed = true;
        self.cancelImagePicker();
        self.cancelImagePoll();
        self.cancelSaveTimer();
        self.settleSave() catch {};
        self.discardBoundary();
        self.clearEditorImage();
        if (self.import_timer) |timer| self.cx.clearTimer(timer);
        if (self.import_ticket) |ticket| self.documents.cancelImport(ticket) catch {};
        if (self.import_job) |job| {
            job.deinit(self.cx.allocator);
        }
        self.clearImportInput();
        self.resetBlockCache();
        self.rendered_blocks.deinit(self.cx.allocator);
        self.find_model.deinit();
        self.tree_actions.deinit(self.cx.allocator);
        self.collapsed_branches.deinit(self.cx.allocator);
        self.images.deinit(self.cx.allocator);
        self.cx.removeAfterLayoutHook(self);
        self.documents.releaseOwner(self.owner) catch |err| std.log.warn("notes release: {s}", .{@errorName(err)});
    }
};

const TreeBranch = struct {
    view: *View,
    directory: Directory,
    descendants: *ui.Node,
    icon: *ui.Signal(?ui.SvgAsset),
    label: *ui.Signal([]const u8),

    fn present(self: *TreeBranch, collapsed: bool) void {
        self.descendants.setDisplay(if (collapsed) .none else .flex);
        self.icon.set(if (collapsed) ui.icons.chevron_right else ui.icons.chevron_down);
        self.label.set(if (collapsed) "展开子项" else "收起子项");
    }

    fn toggle(self: *TreeBranch) void {
        const view = self.view;
        if (view.collapsedIndex(self.directory)) |i| {
            _ = view.collapsed_branches.swapRemove(i);
            self.present(false);
        } else {
            view.collapsed_branches.append(view.cx.allocator, self.directory) catch |err| return view.showError(err);
            self.present(true);
        }
        view.redraw();
    }
};

const TreeActions = struct {
    view: *View,
    row: *ui.Node,
    controls: *ui.Node,
    menu: MoreMenu,
    hovered: bool = false,

    fn enter(self: *TreeActions) void {
        self.hovered = true;
        self.view.redraw();
    }

    fn leave(self: *TreeActions) void {
        self.hovered = false;
        self.view.redraw();
    }
};

const TitleEdit = struct {
    view: *View,
    value: *ui.Signal([]const u8),

    fn accept(self: *TitleEdit, text: []const u8) void {
        if (!self.view.acceptsNewEdits()) return;
        const count = std.unicode.utf8CountCodepoints(text) catch return;
        const message = if (count > model.max_title)
            "标题最多 120 个字符"
        else if (std.mem.indexOfAny(u8, text, "\r\n") != null)
            "请输入单行标题"
        else {
            self.value.set(text);
            return;
        };
        self.view.title_rejected = true;
        self.view.setBanner(message, false);
    }
};

const Click = struct {
    view: *View,
    action: Action,
    block_node: ?*ui.Node = null,
    source_map: ?*const ui.widgets.markdown.SourceMap = null,

    fn invoke(self: *Click) void {
        var action = self.action;
        if (action == .begin_block) {
            const cx = self.view.cx;
            action.begin_block.offset = if (self.source_map) |map|
                map.offsetAt(cx, cx.mouse_x, cx.mouse_y)
            else
                ui.widgets.markdown.textOffsetAt(cx, self.block_node.?, cx.mouse_x, cx.mouse_y);
        }
        self.view.enqueue(action);
    }
};

const SettingsClick = struct {
    view: *View,
    library: model.LibraryId,
    node: *ui.Node = undefined,

    fn invoke(self: *SettingsClick) void {
        const view = self.view;
        view.settings.show(self.library, view.cx.node_registry.handleFor(self.node)) catch |err| view.showError(err);
    }
};

const vtable: contract.RendererInstance.VTable = .{
    .update = View.update,
    .focus_changed = View.focusChanged,
    .unmount = View.unmount,
    .prepare_close = View.prepareClose,
    .presentation_changed = View.presentationChanged,
};

fn from(instance: contract.RendererInstance) ?*View {
    if (instance.vtable != &vtable) return null;
    return @ptrCast(@alignCast(instance.context));
}

pub fn rootNode(instance: contract.RendererInstance) ?*ui.Node {
    return (from(instance) orelse return null).root;
}

pub const FloatingHeader = struct { document: *ui.Node, directory: *ui.Node };

pub fn setFloatingHeader(instance: contract.RendererInstance, header: ?FloatingHeader) void {
    const view = from(instance) orelse return;
    view.setFloatingHeader(header);
}

pub fn toggleDirectory(instance: contract.RendererInstance) bool {
    const view = from(instance) orelse return false;
    if (!view.active) return false;
    view.enqueue(.toggle_tree);
    return true;
}

pub fn handleKey(instance: contract.RendererInstance, key: ui.events.KeyCode, mods: ui.events.Modifiers) ui.events.EventResult {
    const view = from(instance) orelse return .ignored;
    return view.handleKey(key, mods);
}

pub fn focus(instance: contract.RendererInstance) bool {
    const view = from(instance) orelse return false;
    if (!view.active or view.disposed) return false;
    view.focusDocument();
    return true;
}

pub fn openSource(instance: contract.RendererInstance, source: queries.SourceRef) bool {
    const view = from(instance) orelse return false;
    if (view.disposed) return false;
    view.pending = .{ .source_ref = source };
    view.redraw();
    return true;
}

pub fn openNote(instance: contract.RendererInstance, key: model.NoteKey) bool {
    const view = from(instance) orelse return false;
    if (view.disposed) return false;
    view.pending = .{ .select_note = key };
    view.redraw();
    return true;
}

/// The native application loop also advances storage and import work when the
/// compositor withholds frames and Zenit's frame-driven timers cannot fire.
pub fn advanceBackgroundWork(instance: contract.RendererInstance, now_ns: i128) void {
    if (from(instance)) |view| view.advanceBackgroundWork(now_ns);
}

pub fn mount(request: contract.ContentMount, store: *Store, documents: *sessions.Sessions) !contract.RendererInstance {
    const cx = request.cx;
    const scope = request.scope;
    const self = try scope.createState(View, .{
        .cx = cx,
        .scope = scope,
        .store = store,
        .documents = documents,
        .owner = request.owner,
        .save_feedback = request.save_feedback,
        .focus_content = request.focus_content,
        .find_model = terminal_search.Model.init(cx.allocator),
        .texture_backend = if (request.frame_sink) |sink| sink.backend else null,
        .image_open = try scope.createSignal(bool, false),
        .image_disabled = try scope.createSignal(bool, true),
        .edit_disabled = try scope.createSignal(bool, false),
        .lock_choice = try scope.createSignal(bool, false),
        .name_open = try scope.createSignal(bool, false),
        .name_title = try scope.createText("", .{}),
        .name_value = try scope.createText("", .{}),
    });
    try scope.onCleanup(View, self, View.dispose);
    self.root = try ui.box(cx, S.root(), .{});
    self.root.meta.ownership.meta.test_id = "notes.workspace";
    self.root.behavior.interaction.focusable = true;
    self.root.behavior.interaction.tab_index = -1;
    self.root.behavior.events.capture_context = self;
    self.root.behavior.events.on_event_capture = View.keyEvent;
    self.main = try ui.box(cx, S.main(), .{});
    try self.root.appendChild(cx.allocator, self.main);

    const toolbar = try ui.box(cx, S.row(S.toolbar_height, 8), .{});
    self.toolbar = toolbar;
    toolbar.meta.ownership.meta.test_id = "notes.document.toolbar";
    try self.main.appendChild(cx.allocator, toolbar);
    self.search_back_button = try self.actionButton(scope, .search, "返回搜索结果", ui.icons.arrow_left, true, "notes.search.return");
    self.search_back_button.setDisplay(.none);
    try toolbar.appendChild(cx.allocator, self.search_back_button);
    try self.mountPath();
    self.lock_status = try ui.text(cx, "", S.text(12, 400, S.theme.current().fg_2));
    S.theme.bindInk(self.lock_status, "fg_2");
    self.lock_status.behavior.interaction.a11y = .{ .role = .status, .live = "polite" };
    self.lock_status.meta.ownership.meta.test_id = "notes.read-only.status";
    self.lock_status.setDisplay(.none);
    try toolbar.appendChild(cx.allocator, self.lock_status);
    self.search_button = try self.toolHint(try self.actionButton(scope, .search, "搜索笔记库", ui.icons.file_search, true, "notes.search.open"), "搜索笔记库");
    try toolbar.appendChild(cx.allocator, self.search_button);
    self.image_button = try ui.widgets.Button(.{
        .variant = .ghost,
        .icon_only = true,
        .icon_asset = ui.icons.image,
        .disabled = self.image_disabled,
        .icon_size = @as(f32, 16),
        .a11y_label = "插入图片",
        .base_style = S.tool(),
        .on_click = cx.on(View, self, View.chooseImage),
    }).mount(scope, cx);
    self.image_button.meta.ownership.meta.test_id = "notes.document.insert-image";
    self.image_button.setDisplay(.none);
    try toolbar.appendChild(cx.allocator, self.image_button);
    const lock_click = try scope.createState(Click, .{ .view = self, .action = .toggle_read_only });
    self.lock = try ui.widgets.Button(.{
        .variant = .ghost,
        .a11y_label = "设为只读",
        .icon_asset = ui.icons.lock_open,
        .icon_size = @as(f32, 16),
        .icon_only = true,
        .disabled = self.edit_disabled,
        .base_style = S.tool(),
        .on_click = cx.on(Click, lock_click, Click.invoke),
    }).mount(scope, cx);
    self.unlock = try ui.widgets.Button(.{
        .variant = .ghost,
        .label = "只读",
        .a11y_label = "解除只读",
        .icon_asset = ui.icons.lock,
        .icon_size = @as(f32, 16),
        .disabled = self.edit_disabled,
        .base_style = ui.BoxStyle{ .width = .{ .px = 76 }, .height = .{ .px = 28 }, .padding = .{}, .border = .{ .radius = 14 }, .background = S.theme.current().selection },
        .on_click = cx.on(Click, lock_click, Click.invoke),
    }).mount(scope, cx);
    for ([_]*ui.Node{ self.lock, self.unlock }) |button| {
        button.meta.ownership.meta.test_id = "notes.read-only.toggle";
        button.setDisplay(.none);
        try toolbar.appendChild(cx.allocator, button);
    }
    self.document_menu = (try self.mountMore(scope, toolbar, &.{
        try self.menuItem(scope, "查看源码", .toggle_source, false),
        try self.menuItem(scope, "查看当前图片", .preview_editor_image, false),
        try self.menuItem(scope, "最近删除", .{ .manage = .recent }, false),
    }, "notes.document.toolbar.more")).wrapper;
    self.find_button = try self.toolHint(try self.actionButton(scope, .find_document, "搜索当前文档", ui.icons.search, true, "notes.find.open"), "搜索当前文档");
    self.source_button = try self.toolHint(try self.actionButton(scope, .toggle_source, "切换 Markdown 源码", ui.icons.code_xml, true, "notes.document.source"), "切换 Markdown 源码");
    self.recent_button = try self.toolHint(try self.actionButton(scope, .{ .manage = .recent }, "最近删除", ui.icons.trash_2, true, "notes.document.recent"), "最近删除");
    self.find_button.setDisplay(.none);
    try toolbar.insertChildBefore(cx.allocator, self.find_button, self.lock);
    for ([_]*ui.Node{ self.source_button, self.recent_button }) |button| {
        button.setDisplay(.none);
        try toolbar.appendChild(cx.allocator, button);
    }

    self.banner = try ui.box(cx, S.row(38, 8), .{});
    self.banner.setStyleInline(cx.allocator, .{
        .width = .{ .fit = .{} },
        .align_self = .stretch,
        .margin = .{ .left = 24, .right = 24 },
        .padding = .{ .left = 12, .right = 4 },
        .background = S.theme.states().feedback_warn,
        .border = .{ .radius = 8 },
    });
    self.banner.setDisplay(.none);
    try self.main.appendChild(cx.allocator, self.banner);
    const error_icon = try ui.iconTint(cx, ui.icons.circle_alert, S.theme.current().warn_ink, .{ .width = .{ .px = 16 }, .height = .{ .px = 16 }, .flex_shrink = 0 });
    try self.banner.appendChild(cx.allocator, error_icon);
    self.error_text = try ui.text(cx, "", S.text(13, 500, S.theme.current().warn_ink));
    S.theme.bindInk(self.error_text, "warn_ink");
    self.error_text.setStyleInline(cx.allocator, .{ .width = .fill(), .min_width = 0 });
    self.error_text.meta.ownership.meta.test_id = "notes.save.error";
    try self.banner.appendChild(cx.allocator, self.error_text);
    self.retry = try ui.widgets.Button(.{
        .variant = .ghost,
        .label = "重试",
        .a11y_label = "重试保存",
        .icon_asset = ui.icons.refresh_cw,
        .icon_size = @as(f32, 16),
        .base_style = ui.BoxStyle{ .width = .{ .px = 72 }, .height = .{ .px = 28 }, .padding = .{}, .border = .{ .radius = 14 } },
        .on_click = cx.on(View, self, View.retrySave),
    }).mount(scope, cx);
    self.retry.meta.ownership.meta.test_id = "notes.save.retry";
    try self.banner.appendChild(cx.allocator, self.retry);

    const body_scroll = try ui.widgets.ScrollArea(.{ .rubber_band_y = false }).mount(scope, cx);
    self.body_scroll = body_scroll;
    body_scroll.container.meta.ownership.meta.test_id = "notes.document.scroll";
    body_scroll.content.style.flex_shrink = 0;
    self.body = try ui.box(cx, S.stack(18), .{});
    try body_scroll.content.appendChild(cx.allocator, self.body);
    self.body_content = self.body;
    try self.main.appendChild(cx.allocator, body_scroll.container);
    self.search = try search_view.Search.mount(cx, scope, store, .{ .context = self, .back = View.searchBack, .open = View.searchOpen });
    try self.root.appendChild(cx.allocator, self.search.root);

    self.directory_shield = try self.actionButton(scope, .dismiss_card, "收起目录", null, true, "notes.navigation.dismiss");
    self.directory_shield.setStyleInline(cx.allocator, .{
        .position = .absolute,
        .inset = .{ .top = .{ .px = 0 }, .left = .{ .px = 0 }, .right = .{ .px = S.directory_width }, .bottom = .{ .px = 0 } },
        .width = .fill(),
        .height = .fill(),
        .background = ui.Color.TRANSPARENT,
        .hit_behavior = .@"opaque",
        .z_index = 1,
    });
    self.directory_shield.setDisplay(.none);
    try self.root.appendChild(cx.allocator, self.directory_shield);

    self.tree = try ui.box(cx, S.navigation(false), .{});
    self.tree.meta.ownership.meta.test_id = "notes.navigation";
    self.tree.behavior.interaction.focusable = true;
    self.tree.behavior.interaction.tab_index = -1;
    try S.theme.bindMaterial(cx, scope, self.tree, "surface_1");
    self.tree.setDisplay(.none);
    const header = try ui.box(cx, S.row(S.toolbar_height, 6), .{});
    self.directory_header = header;
    header.setStyleInline(cx.allocator, .{ .padding = .{ .left = 16, .right = 40 } });
    const label = try ui.text(cx, "笔记库", S.text(14, 650, S.theme.current().fg_1));
    S.theme.bindInk(label, "fg_1");
    label.setStyleInline(cx.allocator, .{ .width = .fill() });
    try header.appendChild(cx.allocator, label);
    self.directory_add = try self.actionButton(scope, .{ .create = .library }, "新建目录", ui.icons.plus, true, "notes.directory.add");
    try header.appendChild(cx.allocator, self.directory_add);
    try self.tree.appendChild(cx.allocator, header);
    const tree_scroll = try ui.widgets.ScrollArea(.{ .padding = .{ .left = 8, .right = 8, .bottom = 8 } }).mount(scope, cx);
    self.tree_scroll = tree_scroll;
    tree_scroll.container.meta.ownership.meta.test_id = "notes.navigation.scroll";
    self.tree_content = try ui.box(cx, S.stack(2), .{});
    try tree_scroll.content.appendChild(cx.allocator, self.tree_content);
    try self.tree.appendChild(cx.allocator, tree_scroll.container);
    try self.root.appendChild(cx.allocator, self.tree);

    self.outline_card = try ui.box(cx, .{}, .{});
    self.outline_card.meta.ownership.meta.test_id = "notes.outline";
    try S.theme.bindMaterial(cx, scope, self.outline_card, "surface_1");
    self.outline_card.setDisplay(.none);
    var outline_header_style = S.row(S.outline_header_height, 0);
    outline_header_style.padding = .{ .left = 14, .right = 14 };
    const outline_header = try ui.box(cx, outline_header_style, .{});
    const outline_title = try ui.text(cx, "目录", S.text(13, 650, S.theme.current().fg_1));
    outline_title.meta.ownership.meta.test_id = "notes.outline.title";
    S.theme.bindInk(outline_title, "fg_1");
    try outline_header.appendChild(cx.allocator, outline_title);
    try self.outline_card.appendChild(cx.allocator, outline_header);
    const outline_scroll = try ui.widgets.ScrollArea(.{ .padding = ui.Padding.all(S.outline_padding), .rubber_band_y = false }).mount(scope, cx);
    self.outline_rows = try ui.box(cx, S.stack(S.outline_row_gap), .{});
    try outline_scroll.content.appendChild(cx.allocator, self.outline_rows);
    try self.outline_card.appendChild(cx.allocator, outline_scroll.container);
    try self.root.insertChildBefore(cx.allocator, self.outline_card, self.tree);
    self.outline_button = try self.actionButton(scope, .toggle_outline, "文档标题目录", ui.icons.list_tree, true, "notes.outline.toggle");
    self.outline_hint = try self.toolHint(self.outline_button, "文档标题目录");
    self.outline_hint.setDisplay(.none);
    try toolbar.appendChild(cx.allocator, self.outline_hint);
    self.find_view = try terminal_search.mount(cx, scope, &self.find_model, .{
        .context = self,
        .placeholder = "搜索当前文档…",
        .input_label = "搜索当前文档",
        .on_query = View.findQuery,
        .on_next = View.findNext,
        .on_previous = View.findPrevious,
        .on_close = View.findClose,
    });
    self.find_view.root.meta.ownership.meta.test_id = "notes.find";
    self.find_view.input_result.input_container.meta.ownership.meta.test_id = "notes.find.query";
    self.find_view.count.meta.ownership.meta.test_id = "notes.find.count";
    for (self.find_view.actions, [_][]const u8{ "notes.find.previous", "notes.find.next", "notes.find.close" }) |button, id| button.meta.ownership.meta.test_id = id;
    self.find_view.root.setStyle(cx.allocator, .inset, .{ .top = .{ .px = 4 }, .right = .{ .px = 8 } });
    self.find_view.root.setDisplay(.none);
    try self.root.appendChild(cx.allocator, self.find_view.root);

    self.toggle = try self.actionButton(scope, .toggle_tree, "显示或隐藏笔记库", ui.icons.panel_right, true, "notes.navigation.toggle");
    self.toggle.setStyleInline(cx.allocator, View.directoryTogglePosition());
    try self.root.appendChild(cx.allocator, self.toggle);
    self.settings = try editor_settings.Settings.mount(cx, scope, store, cx.on(View, self, View.settingsChanged));
    self.settings.popup.wrapper.setStyleInline(cx.allocator, .{ .position = .absolute });
    try self.root.appendChild(cx.allocator, self.settings.popup.wrapper);
    self.manager = try management.Manager.mount(cx, scope, self.root, store, .{ .context = self, .apply = View.applyManagement });
    try self.mountModal();
    try self.mountLockChoice();
    const image_modal = try ui.widgets.Modal(.{
        .open = self.image_open,
        .width = @max(240, cx.viewport.width - 64),
        .max_height = @max(160, cx.viewport.height - 32),
        .managed_focus = false,
        .on_open_change = cx.on(View, self, View.imageModalChanged),
    }).mount(scope, cx);
    if (!image_modal.portaled) try self.root.appendChild(cx.allocator, image_modal.overlay);
    _ = try scoped_modal.bind(cx, scope, image_modal, .{ .owner = .{ .node = self.root } });
    image_modal.dialog.meta.ownership.meta.test_id = "notes.document.image-viewer";
    self.image_modal_dialog = image_modal.dialog;
    self.image_modal_node = try ui.box(cx, .{ .flex_shrink = 0 }, .{});
    try image_modal.body.appendChild(cx.allocator, self.image_modal_node);
    try request.slot.appendChild(cx.allocator, self.root);
    try cx.addAfterLayoutHook(self, View.afterLayout);
    return .{ .context = self, .vtable = &vtable };
}

test {
    _ = editor;
    _ = editor_images;
    _ = management;
}

test "notes renderer preserves the live Textarea and blocks navigation on save failure" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var store = try Store.init(a, io, temporary.dir);
    defer store.deinit();
    var documents = sessions.Sessions.init(a, &store);
    defer documents.deinit();
    var feedback: TestFeedback = .{};
    const library = try store.createLibrary("运维");
    const first = try store.createNote(library, null, "生产证书");
    const second = try store.createNote(library, null, "故障记录");

    const cx = try ui.Cx.init(a, io);
    defer cx.deinit();
    cx.setViewport(1154, 828);
    cx.root = try ui.box(cx, .{ .width = .fill(), .height = .fill() }, .{});
    const scope = try ui.Scope.init(a, null, cx.owner);
    defer scope.dispose();
    const owner: identity.SessionHandle = .{ .session_id = @fromBackingInt(1), .generation = 1 };
    const instance = try mount(.{
        .cx = cx,
        .scope = scope,
        .slot = cx.root.?,
        .owner = owner,
        .connection = .{ .protocol_id = "notes", .name = "笔记", .payload_version = 1, .payload = "{}" },
        .save_feedback = cx.on(TestFeedback, &feedback, TestFeedback.report),
    }, &store, &documents);
    defer instance.vtable.unmount(instance.context);
    instance.vtable.presentation_changed.?(instance.context, .active);
    const view = from(instance).?;
    try std.testing.expect(openNote(instance, first));
    try cx.setTestFrameStep(16);
    for (0..4) |_| {
        cx.advanceFrameClock();
        cx.layout();
        _ = cx.render();
    }
    try std.testing.expectEqual(@as(f32, 252), view.tree.globalRect().w);
    try std.testing.expectEqual(@as(f32, 886), view.main.globalRect().w);
    const root_directory = view.tree_content.children.items[0];
    const descendants = view.tree_content.children.items[1];
    const branch = root_directory.children.items[0];
    branch.behavior.events.on_click.?.invoke();
    try std.testing.expectEqual(.none, descendants.style.display);
    branch.behavior.events.on_click.?.invoke();
    try std.testing.expectEqual(.flex, descendants.style.display);
    const controls = view.tree_actions.items[0].controls;
    try std.testing.expectEqual(.none, controls.style.display);
    root_directory.behavior.events.on_hover.?.invoke();
    layoutTestFrames(cx);
    try std.testing.expectEqual(.flex, controls.style.display);
    root_directory.behavior.events.on_leave.?.invoke();
    layoutTestFrames(cx);
    try std.testing.expectEqual(.none, controls.style.display);
    const active = view.input.?.input;
    cx.setFocus(active);
    cx.handleTextInput("运行 `nginx -t`");
    for (0..12) |_| {
        cx.advanceFrameClock();
        cx.layout();
        _ = cx.render();
    }
    try std.testing.expectEqual(active, view.input.?.input);
    try std.testing.expectEqualStrings("运行 `nginx -t`", (try documents.snapshot(view.lease.?)).body_md);
    try std.testing.expectEqualStrings("运行 `nginx -t`", view.input.?.state.getText());
    try std.testing.expectEqual(active, cx.focus_manager.getFocused().?);

    var denied = io.vtable.*;
    denied.dirRename = TestIo.failRename;
    store.io.vtable = &denied;
    try std.testing.expectError(error.AccessDenied, instance.vtable.prepare_close.?(instance.context));
    try std.testing.expectError(error.AccessDenied, view.selectNote(second));
    try std.testing.expectEqual(active, view.input.?.input);
    try std.testing.expectEqual(first, view.key.?);
    try std.testing.expect((try documents.snapshot(view.lease.?)).dirty);

    store.io = io;
    try instance.vtable.prepare_close.?(instance.context);
    try view.selectNote(second);
    var saved = try store.loadNote(a, first, .active);
    defer saved.deinit();
    try std.testing.expectEqualStrings("运行 `nginx -t`", saved.value.body_md);

    for (0..4) |_| {
        cx.layout();
        _ = cx.render();
    }
    const png = "\x89PNG\r\n\x1a\n\x00\x00\x00\x0dIHDR" ++
        "\x00\x00\x00\x01\x00\x00\x00\x01\x08\x06\x00\x00\x00\x1f\x15\xc4\x89" ++
        "\x00\x00\x00\x0dIDAT\x78\x9c\x63\xf8\xcf\xc0\xf0\x1f\x00\x05\x00\x01\xff\x89\x99\x3d\x1d" ++
        "\x00\x00\x00\x00IEND\xae\x42\x60\x82";
    const image_input = view.input.?.input;
    cx.setFocus(image_input);
    try view.queueImport(.{ .clipboard = png });
    for (0..100) |_| {
        if (view.import_job.?.done.load(.acquire)) break;
        try std.Io.sleep(io, .fromMilliseconds(5), .awake);
    }
    try std.testing.expect(view.import_job.?.done.load(.acquire));
    if (view.import_timer) |timer| cx.clearTimer(timer);
    View.importPoll(view);
    const image_text = try a.dupe(u8, view.input.?.state.getText());
    defer a.free(image_text);
    try std.testing.expectEqual(image_input, view.input.?.input);
    try std.testing.expectEqual(image_input, cx.focus_manager.getFocused().?);
    try std.testing.expect(std.mem.endsWith(u8, image_text, "\n\n"));
    try std.testing.expectEqual(image_text.len, view.input.?.state.cursor.offset);
    // A document opened directly in the editor has no reading-mode images.
    // Its Cmd+Return preview must still decode and open the imported image.
    const PreviewBackend = struct {
        fn create(_: *anyopaque, width: u32, height: u32) !u32 {
            try std.testing.expectEqual(@as(u32, 1), width);
            try std.testing.expectEqual(@as(u32, 1), height);
            return 1;
        }
        fn update(_: *anyopaque, _: u32, pixels: []const u8) !void {
            try std.testing.expectEqual(@as(usize, 4), pixels.len);
        }
        fn release(_: *anyopaque, _: u32) void {}
    };
    view.texture_backend = .{ .context = view, .create = PreviewBackend.create, .update = PreviewBackend.update, .release = PreviewBackend.release };
    try std.testing.expectEqual(@as(usize, 0), view.images.items.len);
    try std.testing.expect(view.input.?.state.setAccessibilitySelection(0, 0));
    cx.handleKeyDown(.@"return", .{ .super = true });
    for (0..100) |_| {
        layoutTestFrames(cx);
        if (view.image_open.peek()) break;
        try std.Io.sleep(io, .fromMilliseconds(5), .awake);
    }
    try std.testing.expect(view.image_open.peek());
    try std.testing.expect(view.viewed_image == view.editor_image.?.image);
    view.clearEditorImage();
    view.texture_backend = null;
    cx.setFocus(image_input);
    try std.testing.expect(view.input.?.state.setAccessibilitySelection(@intCast(image_text.len), @intCast(image_text.len)));
    cx.handleTextInput("图片后的正文");
    try std.testing.expect(std.mem.endsWith(u8, view.input.?.state.getText(), "\n\n图片后的正文"));
    cx.handleKeyDown(.z, .{ .super = true });
    try std.testing.expectEqualStrings(image_text, view.input.?.state.getText());
    cx.handleKeyDown(.z, .{ .super = true });
    try std.testing.expectEqualStrings("", (try documents.snapshot(view.lease.?)).body_md);
    cx.handleKeyDown(.z, .{ .super = true, .shift = true });
    try std.testing.expectEqualStrings(image_text, (try documents.snapshot(view.lease.?)).body_md);
    cx.handleKeyDown(.z, .{ .super = true });

    try view.queueImport(.{ .clipboard = png });
    try std.testing.expectError(error.ImportInProgress, view.selectNote(first));
    try std.testing.expectError(error.ImportInProgress, instance.vtable.prepare_close.?(instance.context));
    try std.testing.expectEqual(view.editing_row.?.node, view.import_notice.?.root.parent.?);
    try view.perform(.toggle_read_only);
    try std.testing.expect(view.lock_choice.peek());
    try view.perform(.wait_to_lock);
    try std.testing.expect(view.lock_after_import);
    try std.testing.expect(!(try documents.snapshot(view.lease.?)).read_only);
    for (0..100) |_| {
        if (view.import_job.?.done.load(.acquire)) break;
        try std.Io.sleep(io, .fromMilliseconds(5), .awake);
    }
    try std.testing.expect(view.import_job.?.done.load(.acquire));
    instance.vtable.presentation_changed.?(instance.context, .occluded);
    const before_import = view.render_counts;
    advanceBackgroundWork(instance, std.Io.Clock.awake.now(io).toNanoseconds());
    try std.testing.expectEqualDeep(before_import, view.render_counts);
    try std.testing.expectEqual(.flex, view.import_notice.?.root.style.display);
    try view.settleSave();
    instance.vtable.presentation_changed.?(instance.context, .active);
    try std.testing.expectEqual(.none, view.import_notice.?.root.style.display);
    const imported = try documents.snapshot(view.lease.?);
    var references = assets.ReferenceIterator.init(imported.body_md);
    try std.testing.expect(references.next() != null);
    try std.testing.expect(imported.read_only);
    try view.perform(.toggle_read_only);
    try view.settleSave();
    try std.testing.expect(!(try documents.snapshot(view.lease.?)).read_only);
    try view.perform(.{ .undo = false });
    try std.testing.expectEqualStrings("", (try documents.snapshot(view.lease.?)).body_md);
    try view.perform(.{ .undo = true });
    view.enqueue(.toggle_source);
    layoutTestFrames(cx);
    try std.testing.expect(view.source_mode);
    try std.testing.expect(view.input.?.state.setAccessibilitySelection(0, 2));
    try view.queueImport(.{ .clipboard = "unsupported image fixture" });
    const original_ticket = view.import_ticket.?;
    const original_anchor = (try documents.snapshot(view.lease.?)).pending_import.?;
    try std.testing.expectError(error.ImportInProgress, view.queueImport(.{ .clipboard = png }));
    try std.testing.expectEqualStrings("unsupported image fixture", view.import_input.?.input.clipboard);
    for (0..100) |_| {
        if (view.import_job.?.done.load(.acquire)) break;
        try std.Io.sleep(io, .fromMilliseconds(5), .awake);
    }
    try std.testing.expect(view.import_job.?.done.load(.acquire));
    if (view.import_timer) |timer| cx.clearTimer(timer);
    View.importPoll(view);
    try std.testing.expect(view.import_feedback == .failed);
    const original_error = view.import_feedback.failed;
    View.importFailed(view, error.ImportInProgress);
    try std.testing.expectEqual(original_error, view.import_feedback.failed);
    try std.testing.expectEqual(.flex, view.import_notice.?.retry.style.display);
    try std.testing.expect(view.input.?.state.setAccessibilitySelection(4, 4));
    view.retryImport();
    try std.testing.expectEqualDeep(original_ticket, view.import_job.?.ticket);
    try std.testing.expectEqualDeep(original_anchor, (try documents.snapshot(view.lease.?)).pending_import.?);
    for (0..100) |_| {
        if (view.import_job.?.done.load(.acquire)) break;
        try std.Io.sleep(io, .fromMilliseconds(5), .awake);
    }
    try std.testing.expect(view.import_job.?.done.load(.acquire));
    const original_source = try a.dupe(u8, view.input.?.state.getText());
    defer a.free(original_source);
    store.io.vtable = &denied;
    try view.perform(.toggle_read_only);
    try view.perform(.cancel_import_and_lock);
    try std.testing.expect(view.import_job.?.cancel.isCancelled());
    try std.testing.expectError(error.ImportInProgress, view.queueImport(.{ .clipboard = png }));
    try std.testing.expect(view.import_input == null);
    try std.testing.expect(view.edit_disabled.peek());
    try std.testing.expectError(error.AccessDenied, view.settleSave());
    try std.testing.expect(!view.edit_disabled.peek());
    const after_failed_lock = try documents.snapshot(view.lease.?);
    try std.testing.expect(!after_failed_lock.read_only and after_failed_lock.pending_import == null);
    try std.testing.expectEqualStrings(original_source, after_failed_lock.body_md);
    store.io = io;
    view.retrySave();
    try view.settleSave();
    try std.testing.expect((try documents.snapshot(view.lease.?)).read_only);
    try view.perform(.toggle_read_only);
    try view.settleSave();
    layoutTestFrames(cx);
    try std.testing.expect(view.input.?.state.setAccessibilitySelection(0, 2));
    const third = try store.createNote(library, null, "备用证书");
    try view.perform(.search);
    cx.layout();
    _ = cx.render();
    cx.handleTextInput("证书");
    for (0..120) |_| {
        if (view.search.list.children.items.len != 0) break;
        try std.Io.sleep(io, .fromMilliseconds(5), .awake);
        cx.fireDueTimers();
        cx.layout();
        _ = cx.render();
    }
    try std.testing.expectEqual(@as(usize, 2), view.search.list.children.items.len);
    try std.testing.expectEqualStrings("notes.search.result", view.search.list.children.items[0].meta.ownership.meta.test_id.?);
    const first_hit = view.search.result_rows.items[0].source.key;
    const next_hit = view.search.result_rows.items[1].source.key;
    if (std.meta.eql(first_hit, first)) {
        try std.testing.expectEqual(third, next_hit);
    } else {
        try std.testing.expectEqual(third, first_hit);
        try std.testing.expectEqual(first, next_hit);
    }

    cx.handleImePreedit("候选", 6);
    try std.testing.expect(view.search.imeIsComposing());
    cx.handleKeyDown(.down, .{});
    cx.handleKeyDown(.@"return", .{});
    try std.testing.expect(view.search_open and view.search.selected == null);
    cx.handleKeyDown(.escape, .{});
    try std.testing.expect(view.search_open and !view.search.imeIsComposing());
    cx.handleKeyDown(.@"return", .{ .ctrl = true });
    try std.testing.expect(view.search_open and view.search.selected == null);
    cx.handleKeyDown(.@"return", .{});
    layoutTestFrames(cx);
    try std.testing.expectEqual(first_hit, view.key.?);

    try view.perform(.search);
    layoutTestFrames(cx);
    try std.testing.expectEqualStrings("证书", view.search.query.peek());
    try std.testing.expectEqual(first_hit, view.search.selected.?.key);
    cx.handleKeyDown(.down, .{});
    try std.testing.expectEqual(next_hit, view.search.selected.?.key);
    try std.testing.expect(view.search_open);
    try std.testing.expectEqual(view.search.input, cx.focus_manager.getFocused().?);
    cx.handleKeyDown(.up, .{});
    try std.testing.expectEqual(first_hit, view.search.selected.?.key);
    cx.handleKeyDown(.down, .{});
    cx.handleKeyDown(.@"return", .{});
    layoutTestFrames(cx);
    try std.testing.expectEqual(next_hit, view.key.?);
    try view.perform(.search);
    try std.testing.expectEqual(next_hit, view.search.selected.?.key);
    try view.perform(.search_back);
    try std.testing.expectEqual(second, view.key.?);
    layoutTestFrames(cx);
    try std.testing.expect(view.source_mode);
    try std.testing.expectEqual(@as(?usize, 0), view.input.?.state.cursor.anchor);
    try std.testing.expectEqual(@as(usize, 2), view.input.?.state.cursor.offset);
    view.enqueue(.toggle_source);
    layoutTestFrames(cx);
    try std.testing.expect(!view.source_mode);
    view.enqueue(.append_block);
    layoutTestFrames(cx);
    const body_before_append = try a.dupe(u8, (try documents.snapshot(view.lease.?)).body_md);
    defer a.free(body_before_append);
    const suffix_start = body_before_append.len + 2;
    cx.setFocus(view.input.?.input);
    cx.handleTextInput("\n\n验收");
    try std.testing.expectEqualStrings("验收", view.input.?.state.getText()[suffix_start..]);
    try std.testing.expect(view.input.?.state.setAccessibilitySelection(@intCast(suffix_start), @intCast(suffix_start + "验".len)));
    try view.perform(.search);
    try std.testing.expect(view.search_origin.?.selection != null);
    layoutTestFrames(cx);
    cx.handleKeyDown(.@"return", .{});
    layoutTestFrames(cx);
    try std.testing.expectEqual(next_hit, view.key.?);
    try view.perform(.search);
    try view.perform(.search_back);
    layoutTestFrames(cx);
    try std.testing.expectEqual(second, view.key.?);
    try std.testing.expect(view.input != null);
    try std.testing.expectEqualStrings("验收", view.input.?.state.getText()[suffix_start..]);
    try std.testing.expectEqual(@as(?usize, suffix_start), view.input.?.state.cursor.anchor);
    try std.testing.expectEqual(suffix_start + "验".len, view.input.?.state.cursor.offset);
    try std.testing.expect(view.editing_row != null);
    cx.handleTextInput("复");
    const expected_body = try std.mem.concat(a, u8, &.{ body_before_append, "\n\n复收" });
    defer a.free(expected_body);
    try std.testing.expectEqualStrings(expected_body, (try documents.snapshot(view.lease.?)).body_md);
    view.enqueue(.end_block);
    layoutTestFrames(cx);

    const before_hide = try documents.snapshot(view.lease.?);
    try documents.edit(before_hide.stamp, .{ .title = before_hide.title, .body_md = "隐藏期间保存的草稿" });
    instance.vtable.presentation_changed.?(instance.context, .hidden);
    store.io.vtable = &denied;
    defer store.io = io;
    view.scheduleSave();
    const deadline = view.save_deadline_ns.?;
    advanceBackgroundWork(instance, deadline - 1);
    try std.testing.expect(view.save_worker == null);
    advanceBackgroundWork(instance, deadline);
    try std.testing.expect(view.save_worker != null);
    try std.testing.expectError(error.AccessDenied, view.settleSave());
    try std.testing.expectEqual(@as(usize, 1), feedback.failures);
    try std.testing.expectEqual(.none, view.banner.style.display);
    try std.testing.expect((try documents.snapshot(view.lease.?)).dirty);
    instance.vtable.presentation_changed.?(instance.context, .active);
    try std.testing.expectEqual(.flex, view.banner.style.display);
    try std.testing.expectEqual(.flex, view.retry.style.display);

    store.io = io;
    view.retrySave();
    try view.settleSave();
    try std.testing.expectEqual(@as(usize, 1), feedback.resolved);
    try std.testing.expectEqual(.none, view.banner.style.display);
    var committed = try store.loadNote(a, second, .active);
    defer committed.deinit();
    try std.testing.expectEqualStrings("隐藏期间保存的草稿", committed.value.body_md);

    for (0..3) |_| {
        cx.layout();
        _ = cx.render();
    }
    const heading = view.title.?;
    var long_title: [model.max_title * "证".len]u8 = undefined;
    for (0..model.max_title) |i| @memcpy(long_title[i * "证".len ..][0.."证".len], "证");
    cx.setFocus(heading.node);
    heading.state.selectAll();
    cx.handleTextInput(&long_title);
    try std.testing.expectEqualStrings(&long_title, heading.state.getText());
    cx.handleTextInput("续");
    try std.testing.expectEqualStrings(&long_title, heading.state.getText());
    try std.testing.expectEqualStrings(&long_title, (try documents.snapshot(view.lease.?)).title);
    cx.setViewport(592, 408);
    for (0..4) |_| {
        cx.layout();
        _ = cx.render();
    }
    try std.testing.expectEqual(heading.node, view.title.?.node);
    try std.testing.expectApproxEqAbs(@as(f32, 544), heading.node.globalRect().w, 0.01);
    try std.testing.expect(heading.node.globalRect().h > 30);
}

const TestFeedback = struct {
    failures: usize = 0,
    resolved: usize = 0,

    fn report(self: *TestFeedback, message: ?[]const u8) void {
        if (message != null) {
            self.failures += 1;
        } else {
            self.resolved += 1;
        }
    }
};

const TestIo = struct {
    fn failRename(_: ?*anyopaque, _: std.Io.Dir, _: []const u8, _: std.Io.Dir, _: []const u8) std.Io.Dir.RenameError!void {
        return error.AccessDenied;
    }
};

test "notes search gates saves and restores scope selection and scroll" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var store = try Store.init(a, io, temporary.dir);
    defer store.deinit();
    var documents = sessions.Sessions.init(a, &store);
    defer documents.deinit();
    const library = try store.createLibrary("运维");
    const folder = try store.createFolder(library, null, "生产", 1);
    const other = try store.createFolder(library, null, "测试", 2);
    const origin = try store.createNote(library, folder, "问题记录");
    const outside = try store.createNote(library, other, "测试证书");
    for (0..16) |index| {
        var title: [48]u8 = undefined;
        _ = try store.createNote(library, folder, try std.fmt.bufPrint(&title, "证书示例 {d}", .{index}));
    }

    const cx = try ui.Cx.init(a, io);
    defer cx.deinit();
    cx.setViewport(644, 344);
    cx.root = try ui.box(cx, .{ .width = .fill(), .height = .fill() }, .{});
    const scope = try ui.Scope.init(a, null, cx.owner);
    defer scope.dispose();
    const instance = try mount(.{
        .cx = cx,
        .scope = scope,
        .slot = cx.root.?,
        .owner = .{ .session_id = @fromBackingInt(1), .generation = 1 },
        .connection = .{ .protocol_id = "notes", .name = "笔记", .payload_version = 1, .payload = "{}" },
    }, &store, &documents);
    defer instance.vtable.unmount(instance.context);
    instance.vtable.presentation_changed.?(instance.context, .active);
    const view = from(instance).?;
    try std.testing.expect(openNote(instance, origin));
    try cx.setTestFrameStep(16);
    layoutTestFrames(cx);

    const editor_node = view.input.?.input;
    cx.setFocus(editor_node);
    cx.handleTextInput("原笔记草稿");
    try std.testing.expect(view.input.?.state.setAccessibilitySelection(0, "原笔记".len));
    var denied = io.vtable.*;
    denied.dirRename = TestIo.failRename;
    defer store.io = io;
    store.io.vtable = &denied;
    view.enqueue(.search);
    layoutTestFrames(cx);
    try std.testing.expect(!view.search_open and view.search_origin == null);
    try std.testing.expectEqual(editor_node, view.input.?.input);
    try std.testing.expectEqual(editor_node, cx.focus_manager.getFocused().?);
    try std.testing.expectEqual(.flex, view.retry.style.display);
    try std.testing.expect((try documents.snapshot(view.lease.?)).dirty);

    store.io = io;
    view.enqueue(.search);
    layoutTestFrames(cx);
    try std.testing.expect(view.search_open);
    try std.testing.expect(!(try documents.snapshot(view.lease.?)).dirty);
    try std.testing.expectEqualStrings("", view.search.query.peek());
    try std.testing.expectEqual(@as(usize, 0), view.search.list.children.items.len);
    cx.handleKeyDown(.@"return", .{});
    layoutTestFrames(cx);
    try std.testing.expect(view.search_open);

    cx.handleTextInput("证书");
    try waitForSearchTest(view);
    try std.testing.expectEqual(@as(usize, 17), view.search.result_rows.items.len);
    var outside_row: ?*ui.Node = null;
    for (view.search.result_rows.items, view.search.list.children.items) |result, row| {
        if (std.meta.eql(result.source.key, outside)) outside_row = row;
    }
    view.search.scope_button.behavior.events.on_click.?.invoke();
    outside_row.?.behavior.events.on_click.?.invoke();
    layoutTestFrames(cx);
    try std.testing.expect(view.search_open);
    try std.testing.expectEqual(origin, view.key.?);
    try waitForSearchTest(view);
    try std.testing.expectEqualStrings("当前目录", view.search.scope_label.peek());
    try std.testing.expectEqual(@as(usize, 16), view.search.result_rows.items.len);

    view.search.focus();
    for (0..15) |_| cx.handleKeyDown(.down, .{});
    const selected = view.search.selected.?;
    const scroll = view.search.scroll.state.scroll_y;
    try std.testing.expect(scroll > 0);
    cx.handleKeyDown(.@"return", .{});
    layoutTestFrames(cx);
    try std.testing.expect(!view.search_open);
    try std.testing.expectEqual(selected.key, view.key.?);

    cx.setFocus(view.input.?.input);
    cx.handleTextInput("命中页草稿");
    store.io.vtable = &denied;
    view.search_back_button.behavior.events.on_click.?.invoke();
    layoutTestFrames(cx);
    try std.testing.expect(!view.search_open);
    try std.testing.expectEqual(selected.key, view.key.?);
    try std.testing.expectEqual(.flex, view.retry.style.display);
    try std.testing.expect((try documents.snapshot(view.lease.?)).dirty);

    store.io = io;
    cx.handleKeyDown(.escape, .{});
    layoutTestFrames(cx);
    try std.testing.expect(!view.search_open and view.input == null);
    try std.testing.expectEqual(view.root, cx.focus_manager.getFocused().?);
    cx.handleKeyDown(.escape, .{});
    layoutTestFrames(cx);
    try std.testing.expect(view.search_open);
    try std.testing.expectEqualStrings("证书", view.search.query.peek());
    try std.testing.expectEqualStrings("当前目录", view.search.scope_label.peek());
    try std.testing.expectEqualDeep(selected, view.search.selected.?);
    try std.testing.expectApproxEqAbs(scroll, view.search.scroll.state.scroll_y, 0.01);

    cx.handleKeyDown(.a, .{ .super = true });
    cx.handleTextInput("无此内容");
    try waitForSearchTest(view);
    try std.testing.expectEqualStrings("无此内容", view.search.query.peek());
    try std.testing.expectEqualStrings("当前目录", view.search.scope_label.peek());
    try std.testing.expectEqual(@as(usize, 0), view.search.result_rows.items.len);
    try std.testing.expectEqual(@as(usize, 1), view.search.list.children.items.len);
    try std.testing.expectEqualStrings("没有找到相关笔记", view.search.list.children.items[0].getText().?.content);
    cx.handleKeyDown(.escape, .{});
    layoutTestFrames(cx);
    try std.testing.expect(!view.search_open);
    try std.testing.expectEqual(origin, view.key.?);
    try std.testing.expectEqualStrings("原笔记草稿", view.input.?.state.getText());
    try std.testing.expectEqual(@as(?usize, 0), view.input.?.state.cursor.anchor);
    try std.testing.expectEqual("原笔记".len, view.input.?.state.cursor.offset);

    cx.handleKeyDown(.f, .{ .super = true });
    layoutTestFrames(cx);
    try std.testing.expectEqual(.search, view.card);
    try std.testing.expect(!view.search_open);
    try std.testing.expectEqual(view.find_view.input_result.input_container, cx.focus_manager.getFocused().?);
    cx.handleTextInput("原笔记");
    layoutTestFrames(cx);
    try std.testing.expectEqual(@as(usize, 1), view.find_model.count());
}

fn waitForSearchTest(view: *View) !void {
    for (0..120) |_| {
        if (!view.search.pending and view.search.job == null) {
            layoutTestFrames(view.cx);
            return;
        }
        try std.Io.sleep(std.testing.io, .fromMilliseconds(5), .awake);
        view.cx.advanceFrameClock();
        view.cx.fireDueTimers();
        view.cx.layout();
        _ = view.cx.render();
    }
    return error.SearchTestTimeout;
}

test "notes renderer reuses shifted blocks and bounds visible work while retaining the editor" {
    const previous_theme = S.theme.currentName();
    defer S.theme.select(previous_theme);
    S.theme.select(.dark);
    const a = std.testing.allocator;
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var store = try Store.init(a, io, temporary.dir);
    defer store.deinit();
    var documents = sessions.Sessions.init(a, &store);
    defer documents.deinit();
    const library = try store.createLibrary("回归");
    const key = try store.createNote(library, null, "长文档");
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(a);
    try text.appendSlice(a, "alpha\n");
    for (0..240) |i| try text.print(a, "段落 {d} **内容**\n\n", .{i});
    _ = try store.changeNote(key, 1, .{ .save = .{ .title = "长文档", .body_md = text.items } });

    const cx = try ui.Cx.init(a, io);
    defer cx.deinit();
    cx.setViewport(1154, 450);
    try cx.setTestFrameStep(16);
    cx.root = try ui.box(cx, .{ .width = .fill(), .height = .fill() }, .{});
    const scope = try ui.Scope.init(a, null, cx.owner);
    defer scope.dispose();
    const owner: identity.SessionHandle = .{ .session_id = @fromBackingInt(2), .generation = 1 };
    const instance = try mount(.{
        .cx = cx,
        .scope = scope,
        .slot = cx.root.?,
        .owner = owner,
        .connection = .{ .protocol_id = "notes", .name = "笔记", .payload_version = 1, .payload = "{}" },
    }, &store, &documents);
    defer instance.vtable.unmount(instance.context);
    const view = from(instance).?;
    instance.vtable.presentation_changed.?(instance.context, .active);
    try std.testing.expect(openNote(instance, key));
    layoutTestFrames(cx);
    try std.testing.expectEqual(@as(usize, 240), view.block_rows.len);
    const cite_range: queries.Range = .{ .start_byte = 0, .end_byte = "段落".len };
    const revision = (try documents.snapshot(view.lease.?)).stamp.base_revision;
    view.source_range = .{ .revision = revision, .range = cite_range };
    try std.testing.expect(view.revealSource());
    view.source_range = .{ .revision = revision - 1, .range = cite_range };
    try std.testing.expect(!view.revealSource());
    try std.testing.expect(view.source_range == null);
    view.clearError();
    try std.testing.expect(view.rendered_blocks.items.len < 60);
    try std.testing.expect(view.block_rows[239].rendered == null);
    const heading = view.title.?.node;
    try std.testing.expectApproxEqAbs(@as(f32, 790), view.block_rows[2].rendered.?.node.globalRect().w, 0.01);

    const block = view.block_rows[0].rendered.?.edit.?.block_node.?;
    const rect = block.globalRect();
    cx.handleMouseDown(rect.x + rect.w - 2, rect.y + rect.h / 2, .{});
    cx.handleMouseUp(rect.x + rect.w - 2, rect.y + rect.h / 2);
    layoutTestFrames(cx);
    try std.testing.expect(view.input != null);
    const input = view.input.?;
    try std.testing.expectEqual("alpha\n段落 0 **内容**".len, input.state.cursor.offset);
    try std.testing.expect(input.state.setAccessibilitySelection(0, 3));
    const editor_text = try a.dupe(u8, input.state.getText());
    defer a.free(editor_text);
    const parses_before_theme = view.render_counts.parses;
    S.theme.select(.light);
    cx.setTheme(S.theme.widgetTheme(.light));
    layoutTestFrames(cx);
    try std.testing.expectEqual(input.input, view.input.?.input);
    try std.testing.expectEqualStrings(editor_text, view.input.?.state.getText());
    try std.testing.expectEqual(@as(?usize, 0), view.input.?.state.cursor.anchor);
    try std.testing.expectEqual(@as(usize, 3), view.input.?.state.cursor.offset);
    try std.testing.expectEqual(cx.tokens, input.state.tokens);
    try std.testing.expectEqual(cx.tokens, view.title.?.state.tokens);
    try std.testing.expectEqual(S.theme.current().fg_1, view.title.?.state.text_display_node.?.getText().?.color);

    try std.testing.expectEqual(parses_before_theme, view.render_counts.parses);
    view.enqueue(.end_block);
    layoutTestFrames(cx);
    const retained = view.block_rows[2].rendered.?.node;
    view.enqueue(.{ .begin_block = .{ .range = view.block_ranges[0] } });
    layoutTestFrames(cx);
    const active_input = view.input.?;

    var long_line: [740 * "段".len]u8 = undefined;
    for (0..740) |i| @memcpy(long_line[i * "段".len ..][0.."段".len], "段");
    const replacement = try std.mem.concat(a, u8, &.{ &long_line, "\n\n新增一段" });
    defer a.free(replacement);
    // Replace across the first two logical lines as one document selection.
    try std.testing.expect(active_input.state.setAccessibilitySelection(0, @intCast(view.block_ranges[0].end)));
    cx.handleTextInput(replacement);
    try std.testing.expectEqual(active_input.input, view.input.?.input);
    try std.testing.expect(std.mem.startsWith(u8, active_input.state.getText(), replacement));
    try std.testing.expect(std.mem.startsWith(u8, (try documents.snapshot(view.lease.?)).body_md, replacement));
    view.enqueue(.end_block);
    layoutTestFrames(cx);
    try std.testing.expectEqual(@as(usize, 241), view.block_rows.len);
    try std.testing.expectEqual(retained, view.block_rows[3].rendered.?.node);
    try std.testing.expectEqual(heading, view.title.?.node);
    const action = view.block_rows[3].rendered.?.edit.?.action.begin_block.range;
    try std.testing.expectEqual(view.block_ranges[3].start, action.start);

    const scroll = view.body_scroll;
    ui.widgets.scroll_area.setScrollY(scroll.state, scroll.content, scroll.state.maxScrollY());
    layoutTestFrames(cx);
    try std.testing.expect(view.block_rows[239].rendered != null);
    try std.testing.expect(view.block_rows[3].rendered == null);
    try std.testing.expect(view.rendered_blocks.items.len < 60);

    const clean_resume = view.render_counts;
    const before_hide = try a.dupe(u8, (try documents.snapshot(view.lease.?)).body_md);
    defer a.free(before_hide);
    instance.vtable.presentation_changed.?(instance.context, .hidden);
    view.bodyChanged("隐藏页面的过期输入事件");
    try std.testing.expectEqualStrings(before_hide, (try documents.snapshot(view.lease.?)).body_md);
    view.root.setDisplay(.none);
    for (0..625) |_| {
        cx.advanceFrameClock();
        cx.fireDueTimers();
        cx.layout();
    }
    try std.testing.expectEqualDeep(clean_resume, view.render_counts);
    view.root.setDisplay(.flex);
    instance.vtable.presentation_changed.?(instance.context, .active);
    layoutTestFrames(cx);
    try std.testing.expectEqual(clean_resume.parses, view.render_counts.parses);
    try std.testing.expectEqual(clean_resume.mounts, view.render_counts.mounts);

    view.enqueue(.end_block);
    layoutTestFrames(cx);
    try view.flushDraft();
    try view.selectSource(.{ .key = key, .revision = 1, .range = .{ .start_byte = 5, .end_byte = 8 } });
    layoutTestFrames(cx);
    try std.testing.expectApproxEqAbs(@as(f32, 0), scroll.state.scroll_y, 0.01);
    const before_update = view.render_counts;
    instance.vtable.presentation_changed.?(instance.context, .occluded);
    for ([_][]const u8{ "第一次后台变更", "最终后台变更" }) |changed_body| {
        const lease = view.lease.?;
        const snapshot = try documents.snapshot(lease);
        try documents.edit(snapshot.stamp, .{ .title = snapshot.title, .body_md = changed_body });
        try instance.vtable.update(instance.context, .{ .owner = owner, .revision = 1, .title = "笔记", .status = "" });
    }
    view.startSave();
    try view.settleSave();
    try std.testing.expectEqualDeep(before_update, view.render_counts);
    instance.vtable.presentation_changed.?(instance.context, .active);
    layoutTestFrames(cx);
    try std.testing.expectEqual(before_update.parses + 1, view.render_counts.parses);
    try std.testing.expectEqual(@as(usize, 1), view.block_rows.len);
    try std.testing.expectEqualStrings("最终后台变更", view.blocks_text.?);
}

fn layoutTestFrames(cx: *ui.Cx) void {
    for (0..6) |_| {
        cx.advanceFrameClock();
        cx.layout();
        _ = cx.render();
    }
}
