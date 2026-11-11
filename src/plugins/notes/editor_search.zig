const std = @import("std");
const ui = @import("ui");
const queries = @import("queries.zig");
const Store = @import("store.zig").Store;
const model = @import("model.zig");
const S = @import("styles.zig");
const icons = @import("../../ui/file_workspace_icons.zig");

const Page = queries.Page(queries.Hit);
pub const Directory = struct { library: model.LibraryId, folder: ?model.FolderId = null, depth: u8 = 0 };
pub const Hooks = struct {
    context: *anyopaque,
    back: *const fn (*anyopaque) void,
    open: *const fn (*anyopaque, queries.SourceRef) void,
};

const Job = struct {
    store: *Store,
    arena: std.heap.ArenaAllocator,
    input: []const u8,
    directory: ?Directory,
    cursor: ?[]const u8,
    cancel: queries.CancelToken = .{},
    done: std.atomic.Value(bool) = .init(false),
    result: anyerror!Page = error.Cancelled,
    thread: ?std.Thread = null,

    fn run(self: *Job) void {
        defer self.done.store(true, .release);
        const ids: []const model.LibraryId = if (self.directory) |directory| &.{directory.library} else &.{};
        const service = queries.Queries{ .store = self.store };
        const result = service.search(self.arena.allocator(), .user, .{
            .query = self.input,
            .library_ids = ids,
            .folder_id = if (self.directory) |directory| directory.folder else null,
            .limit = 20,
            .cursor = self.cursor,
        }, &self.cancel) catch |err| {
            self.result = err;
            return;
        };
        self.result = result.value;
    }

    fn join(self: *Job) void {
        if (self.thread) |thread| thread.join();
        self.thread = null;
    }

    fn deinit(self: *Job, a: std.mem.Allocator) void {
        self.cancel.cancel();
        self.join();
        self.arena.deinit();
        a.destroy(self);
    }
};

pub const Search = struct {
    cx: *ui.Cx,
    scope: *ui.Scope,
    store: *Store,
    hooks: Hooks,
    root: *ui.Node = undefined,
    list: *ui.Node = undefined,
    scroll: ui.widgets.ScrollAreaResult = undefined,
    saved_scroll: ?f32 = null,
    selected: ?queries.SourceRef = null,
    selected_row: ?*Result = null,
    result_rows: std.ArrayList(*Result) = .empty,
    input: *ui.Node = undefined,
    input_state: *ui.widgets.input.TextInputState = undefined,
    query: *ui.Signal([]const u8),
    scope_label: *ui.Signal([]const u8),
    scope_button: *ui.Node = undefined,
    rows: ?*ui.Scope = null,
    directory: ?Directory = null,
    scoped: bool = false,
    active: bool = false,
    job: ?*Job = null,
    completed: ?*Job = null,
    timer: ?u64 = null,
    poll_timer: ?u64 = null,
    pending: bool = false,
    cursor: ?[]const u8 = null,

    pub fn mount(cx: *ui.Cx, scope: *ui.Scope, store: *Store, hooks: Hooks) !*Search {
        const self = try scope.createState(Search, .{
            .cx = cx,
            .scope = scope,
            .store = store,
            .hooks = hooks,
            .query = try scope.createText("", .{}),
            .scope_label = try scope.createText("全部目录", .{}),
        });
        try scope.onCleanup(Search, self, cleanup);
        self.root = try ui.box(cx, S.main(), .{});
        self.root.setDisplay(.none);
        self.root.meta.ownership.meta.test_id = "notes.search";
        const toolbar = try ui.box(cx, S.row(64, 8), .{});
        toolbar.setStyleInline(cx.allocator, .{ .padding = .{ .left = 24, .right = 42 } });
        try self.root.appendChild(cx.allocator, toolbar);

        const back = try ui.widgets.Button(.{
            .variant = .ghost,
            .icon_only = true,
            .icon_asset = ui.icons.arrow_left,
            .a11y_label = "返回笔记",
            .base_style = S.tool(),
            .on_click = cx.on(Search, self, goBack),
        }).mount(scope, cx);
        back.meta.ownership.meta.test_id = "notes.search.back";
        try toolbar.appendChild(cx.allocator, back);

        const input = try ui.widgets.Input(.{
            .value = self.query,
            .growable = true,
            .placeholder = "搜索笔记",
            .on_change = cx.on(Search, self, changed),
        }).mountResult(scope, cx);
        self.input = input.input_container;
        self.input_state = input.state;
        self.input.behavior.events.on_event_capture = keyEvent;
        self.input.behavior.events.capture_context = self;
        self.input.meta.ownership.meta.test_id = "notes.search.query";
        try toolbar.appendChild(cx.allocator, input.node);
        self.scope_button = try ui.widgets.Button(.{
            .variant = .ghost,
            .label = self.scope_label,
            .on_click = cx.on(Search, self, toggleScope),
        }).mount(scope, cx);
        self.scope_button.meta.ownership.meta.test_id = "notes.search.scope";
        try toolbar.appendChild(cx.allocator, self.scope_button);
        const clear = try ui.widgets.Button(.{
            .variant = .ghost,
            .icon_only = true,
            .icon_asset = ui.icons.x,
            .a11y_label = "清空搜索",
            .base_style = S.tool(),
            .on_click = cx.on(Search, self, clearQuery),
        }).mount(scope, cx);
        clear.meta.ownership.meta.test_id = "notes.search.clear";
        try toolbar.appendChild(cx.allocator, clear);

        const scroll = try ui.widgets.ScrollArea(.{ .padding = .{ .left = 24, .right = 24, .bottom = 24 }, .rubber_band_y = false }).mount(scope, cx);
        self.scroll = scroll;
        self.list = try ui.box(cx, S.stack(6), .{});
        scroll.container.meta.ownership.meta.test_id = "notes.search.list";
        scroll.content.style.flex_shrink = 0;
        try scroll.content.appendChild(cx.allocator, self.list);
        try self.root.appendChild(cx.allocator, scroll.container);
        return self;
    }

    pub fn setDirectory(self: *Search, directory: ?Directory) void {
        if (std.meta.eql(self.directory, directory)) return;
        self.directory = directory;
        if (directory == null) self.scoped = false;
        self.scope_button.setDisplay(if (directory == null) .none else .flex);
        self.updateScope();
        if (self.scoped) self.request(null);
    }

    pub fn setActive(self: *Search, active: bool) void {
        if (self.active == active) return;
        self.active = active;
        if (active) {
            if (self.pending) self.schedule(0);
        } else {
            self.saved_scroll = self.scroll.state.scroll_y;
            if (self.job) |job| {
                job.cancel.cancel();
                self.pending = true;
            }
            self.stopTimer(&self.timer);
        }
    }

    pub fn restoreScroll(self: *Search) bool {
        if (!self.active) return false;
        const position = self.saved_scroll orelse return false;
        self.saved_scroll = null;
        ui.widgets.scroll_area.setScrollY(self.scroll.state, self.scroll.content, position);
        return true;
    }

    pub fn focus(self: *Search) void {
        self.cx.setFocus(self.input);
    }

    pub fn imeIsComposing(self: *const Search) bool {
        return self.input_state.imeIsComposing();
    }

    fn hasCurrentResults(self: *const Search) bool {
        return self.active and !self.pending and self.job == null;
    }

    fn keyEvent(event: ui.events.Event, raw: ?*anyopaque) ui.events.EventResult {
        if (event != .key_down) return .ignored;
        const self: *Search = @ptrCast(@alignCast(raw.?));
        if (!self.hasCurrentResults() or self.imeIsComposing()) return .ignored;
        const key = event.key_down;
        if (key.modifiers.super or key.modifiers.ctrl or key.modifiers.alt or key.modifiers.shift) return .ignored;
        const rows = self.result_rows.items;
        if (rows.len == 0) return .ignored;
        const index = if (self.selected_row) |selected| selected.index else 0;
        switch (key.key) {
            .@"return" => rows[index].open(),
            .up, .down => {
                const next = if (self.selected_row == null) 0 else if (key.key == .up) index -| 1 else @min(index + 1, rows.len - 1);
                rows[next].select();
                ui.widgets.scrollIntoView(self.scroll.state, self.scroll.content, self.list.children.items[next], .nearest);
            },
            else => return .ignored,
        }
        return .stop;
    }

    fn goBack(self: *Search) void {
        self.hooks.back(self.hooks.context);
    }

    fn changed(self: *Search, _: []const u8) void {
        self.request(null);
    }

    fn clearQuery(self: *Search) void {
        self.query.set("");
        self.request(null);
        self.focus();
    }

    fn toggleScope(self: *Search) void {
        if (self.directory == null) return;
        self.scoped = !self.scoped;
        self.updateScope();
        self.request(null);
    }

    fn updateScope(self: *Search) void {
        self.scope_label.set(if (self.scoped) "当前目录" else "全部目录");
    }

    fn more(self: *Search) void {
        if (!self.hasCurrentResults()) return;
        const job = self.completed orelse return;
        const result = job.result catch return;
        self.request(result.next_cursor);
    }

    fn request(self: *Search, cursor: ?[]const u8) void {
        if (self.selected_row) |row| row.style.set(rowStyle(false));
        self.selected = null;
        self.selected_row = null;
        self.saved_scroll = 0;
        const a = self.cx.allocator;
        const next = if (cursor) |value| a.dupe(u8, value) catch null else null;
        if (self.cursor) |value| a.free(value);
        self.cursor = next;
        self.pending = true;
        if (self.job) |job| job.cancel.cancel();
        if (self.active) self.schedule(150 * std.time.ns_per_ms);
    }

    fn schedule(self: *Search, delay: u64) void {
        self.stopTimer(&self.timer);
        self.timer = self.cx.setTimer(delay, begin, self) catch null;
    }

    fn begin(raw: ?*anyopaque) void {
        const self: *Search = @ptrCast(@alignCast(raw.?));
        self.timer = null;
        if (!self.active or !self.pending or self.job != null) return;
        self.pending = false;
        self.launch() catch self.drawMessage("搜索失败，请重试");
    }

    fn launch(self: *Search) !void {
        const input = std.mem.trim(u8, self.query.peek(), " \t\r\n");
        if (input.len == 0) {
            self.clearRows();
            if (self.completed) |job| job.deinit(self.cx.allocator);
            self.completed = null;
            return;
        }
        const a = self.cx.allocator;
        const job = try a.create(Job);
        errdefer a.destroy(job);
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        errdefer arena.deinit();
        job.* = .{
            .store = self.store,
            .arena = arena,
            .input = try arena.allocator().dupe(u8, input),
            .directory = if (self.scoped) self.directory else null,
            .cursor = if (self.cursor) |value| try arena.allocator().dupe(u8, value) else null,
        };
        job.arena = arena;
        job.thread = try std.Thread.spawn(.{}, Job.run, .{job});
        self.job = job;
        self.schedulePoll();
    }

    fn schedulePoll(self: *Search) void {
        self.poll_timer = self.cx.setTimer(20 * std.time.ns_per_ms, poll, self) catch {
            const job = self.job orelse return;
            job.join();
            self.publish(job);
            return;
        };
    }

    fn poll(raw: ?*anyopaque) void {
        const self: *Search = @ptrCast(@alignCast(raw.?));
        self.poll_timer = null;
        const job = self.job orelse return;
        if (!job.done.load(.acquire)) return self.schedulePoll();
        self.publish(job);
    }

    fn publish(self: *Search, job: *Job) void {
        self.job = null;
        job.join();
        if (!self.active or self.pending) {
            job.deinit(self.cx.allocator);
            if (self.active and self.timer == null) self.schedule(0);
            return;
        }
        self.clearRows();
        if (self.completed) |old| old.deinit(self.cx.allocator);
        self.completed = job;
        self.renderRows(job.result catch {
            self.drawMessage("搜索失败，请重试");
            return;
        }) catch self.drawMessage("搜索失败，请重试");
    }

    fn clearRows(self: *Search) void {
        self.selected_row = null;
        self.result_rows.clearRetainingCapacity();
        while (self.list.children.items.len != 0) {
            const child = self.list.children.items[self.list.children.items.len - 1];
            self.cx.detachChild(self.list, child);
            self.cx.destroyDetached(child);
        }
        if (self.rows) |scope| scope.dispose();
        self.rows = null;
    }

    fn drawMessage(self: *Search, message: []const u8) void {
        self.clearRows();
        const text = ui.text(self.cx, message, S.text(13, 400, S.theme.current().fg_2)) catch return;
        self.list.appendChild(self.cx.allocator, text) catch return;
        if (self.active) self.cx.requestRedraw();
    }

    fn renderRows(self: *Search, page: Page) !void {
        if (page.entries.len == 0) return self.drawMessage("没有找到相关笔记");
        const scope = try self.scope.childScope();
        self.rows = scope;
        const cx = self.cx;
        try self.result_rows.ensureTotalCapacity(cx.allocator, page.entries.len);
        for (page.entries, 0..) |hit, index| {
            const source: queries.SourceRef = .{
                .key = .{ .library_id = hit.library_id, .note_id = hit.note_id },
                .revision = hit.revision,
                .range = .{ .start_byte = hit.start_byte, .end_byte = hit.end_byte },
            };
            const selected = std.meta.eql(self.selected, @as(?queries.SourceRef, source));
            const row_style = try scope.createSignal(ui.BoxStyle, rowStyle(selected));
            const result = try scope.createState(Result, .{
                .search = self,
                .source = source,
                .style = row_style,
                .index = index,
            });
            if (selected) self.selected_row = result;
            const row = try ui.widgets.Button(.{
                .variant = .ghost,
                .base_style = row_style,
                .on_click = cx.on(Result, result, Result.open),
            }).mount(scope, cx);
            row.meta.ownership.meta.test_id = "notes.search.result";
            const contents = try ui.box(cx, .{ .width = .fill(), .direction = .row, .align_items = .start, .min_width = 0, .gap = 12 }, .{});
            const icon = try ui.iconTint(cx, icons.asset("note.md"), icons.color("note.md"), .{ .width = .{ .px = 18 }, .height = .{ .px = 18 }, .flex_shrink = 0 });
            try contents.appendChild(cx.allocator, icon);
            const entry = try ui.box(cx, S.stack(6), .{});
            const title = try ui.text(cx, "", S.text(16, 600, S.theme.current().fg_1));
            try title.setTextContent(cx.allocator, hit.title);
            try entry.appendChild(cx.allocator, title);
            const path = try std.mem.join(cx.allocator, "  ›  ", hit.path);
            defer cx.allocator.free(path);
            const location = try ui.text(cx, "", S.text(12, 400, S.theme.current().fg_3));
            try location.setTextContent(cx.allocator, path);
            try entry.appendChild(cx.allocator, location);
            if (hit.excerpt.len != 0) {
                var style = S.text(14, 400, S.theme.current().fg_2);
                style.wrap = .word;
                style.max_lines = 2;
                const excerpt = try ui.text(cx, "", style);
                try excerpt.setTextContent(cx.allocator, hit.excerpt);
                try entry.appendChild(cx.allocator, excerpt);
            }
            try contents.appendChild(cx.allocator, entry);
            try row.appendChild(cx.allocator, contents);
            try self.list.appendChild(cx.allocator, row);
            self.result_rows.appendAssumeCapacity(result);
        }
        if (page.next_cursor != null) {
            try self.list.appendChild(cx.allocator, try ui.widgets.Button(.{
                .variant = .ghost,
                .label = "下一页",
                .on_click = cx.on(Search, self, more),
            }).mount(scope, cx));
        }
        cx.requestRedraw();
    }

    fn stopTimer(self: *Search, slot: *?u64) void {
        if (slot.*) |timer| self.cx.clearTimer(timer);
        slot.* = null;
    }

    fn cleanup(self: *Search) void {
        self.stopTimer(&self.timer);
        self.stopTimer(&self.poll_timer);
        if (self.job) |job| job.deinit(self.cx.allocator);
        if (self.completed) |job| job.deinit(self.cx.allocator);
        if (self.cursor) |cursor| self.cx.allocator.free(cursor);
        self.result_rows.deinit(self.cx.allocator);
    }
};

fn rowStyle(selected: bool) ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .fit = .{} }, .padding = .{ .left = 14, .right = 14, .top = 12, .bottom = 12 }, .justify = .start, .background = if (selected) S.theme.current().selection else ui.Color.TRANSPARENT, .border = .{ .radius = 9 } };
}

const Result = struct {
    search: *Search,
    source: queries.SourceRef,
    style: *ui.Signal(ui.BoxStyle),
    index: usize,

    fn select(self: *Result) void {
        if (self.search.selected_row == self) return;
        if (self.search.selected_row) |row| row.style.set(rowStyle(false));
        self.search.selected = self.source;
        self.search.selected_row = self;
        self.style.set(rowStyle(true));
    }

    fn open(self: *Result) void {
        if (!self.search.hasCurrentResults()) return;
        self.select();
        self.search.hooks.open(self.search.hooks.context, self.source);
    }
};
