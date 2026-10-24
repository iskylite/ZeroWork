const std = @import("std");
const applog = @import("../platform/applog.zig");
const ui = @import("ui");
const text_frame = @import("../vt/text_frame.zig");
const TextSlot = @import("../vt/text_slot.zig").TextSlot;
const Presentation = @import("../host/runtime_service.zig").Runtime;
const PastePolicy = @import("paste_policy.zig").Policy;
const terminal_selection = @import("terminal_selection.zig");
const command_palette = @import("command_palette.zig");
const builtin_commands = @import("builtin_commands.zig");
const terminal_search = @import("terminal_search.zig");
const design = @import("design.zig");
const app_theme = @import("app_theme.zig");
const overlay_styles = @import("terminal_overlay_styles.zig");
const history_replay = @import("history_replay.zig");
const completion_mod = @import("completion.zig");
const completion_controller = @import("completion_controller.zig");
const local_command_state = @import("local_command_state.zig");
const terminal_service = @import("../host/terminal_service.zig");
const SessionHandle = @import("../host/identity.zig").SessionHandle;
const TerminalSurface = @import("terminal_surface.zig").Surface;
const OperationKey = @import("../host/operation.zig").OperationKey;
pub const TerminalStatus = @import("terminal_status_snapshot.zig");

/// Overlay boxes per terminal view: one cursor block plus per-row selection
/// highlights. Selections longer than the pool clip visually (copy still works
/// off the exact cell coordinates).
const selection_overlay_count = 300;

const blink_interval_ms: i64 = 500;

/// ── @ 命令面板几何（mockup-commands.png）──────────────────────────
/// PNG/HTML dimensions apply to the production palette as well.
const palette_width: f32 = 430;
const palette_header_height: f32 = 36;
const palette_row_height: f32 = 38;
const palette_hint_height: f32 = 46;
const palette_z_index: i16 = 30;

/// Terminal typography. Row pitch = font_size × line_height (Zenit text
/// layout contract), column width = measured monospace advance.
const terminal_font_size_default: f32 = 13;
const terminal_line_height_default: f32 = 1.5;
const terminal_row_height_default: f32 = 20;
/// Upper bound on VT grid rows we can display (PTY resize clamps to 300;
/// the row pool only materializes nodes for rows the frame actually has).
const max_grid_rows: usize = 300;

/// Last-placed overlay geometry: skip redundant node writes on idle frames.
const OverlayCache = struct {
    placed: bool = false,
    x: f32 = 0,
    y: f32 = 0,
    w: f32 = 0,
    h: f32 = 0,
};

/// Wall-clock milliseconds (same source as src/platform/realtime.zig; Zig
/// 0.17 std.time dropped milliTimestamp).
fn wallClockMs() i64 {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(.REALTIME, &ts) != 0) return 0;
    return @as(i64, @intCast(ts.sec)) * std.time.ms_per_s + @divTrunc(@as(i64, @intCast(ts.nsec)), std.time.ns_per_ms);
}

pub const TerminalViewNode = struct {
    root: *ui.Node,
    rows_box: *ui.Node,
    cx: *ui.Cx,
    worker: ?*Presentation = null,
    terminal_surface: ?*TerminalSurface = null,
    terminal_theme: ?terminal_service.Theme = null,
    terminal_menu_handler: ?TerminalSurface.MenuHandler = null,
    worker_menu_owner: ?SessionHandle = null,
    paste_policy: PastePolicy = .{},
    paste_confirmation_pending: bool = false,
    pending_paste: ?[]u8 = null,
    pending_paste_offset: usize = 0,
    /// UI-side blink phase (wall-clock driven, independent of VT output).
    cursor_visible: bool = true,
    focus_border_color: ui.Color,
    idle_border_color: ui.Color,
    base_fg: ui.Color = .{ .r = 0, .g = 0, .b = 0, .a = 255 },
    selection: terminal_selection.SelectionState = .{},
    tombstone: @import("session_tombstone.zig").Tombstone = .{},
    reconnect_button_visible: bool = false,
    /// Latest decoded frame geometry. Text itself lives in the output node;
    /// overlays are reprojected from these every frame.
    frame_cursor: text_frame.Cursor = .{ .row = 0, .col = 0, .visible = false },
    frame_cols: u16 = 0,
    frame_rows: u16 = 0,
    has_frame: bool = false,
    status_publication: ?TerminalStatus.Snapshot = null,
    status_operation: ?OperationKey = null,
    status_publication_cutoff: u64 = 0,
    /// Measured monospace cell geometry (advance of 'M' via CoreText; row
    /// pitch = font_size × line_height per Zenit's text layout). These anchor
    /// the cursor/selection overlays AND the PTY resize math.
    cell_width: f32 = 7.8,
    cell_height: f32 = terminal_row_height_default,
    terminal_font_size: f32 = 13,
    terminal_font_weight: u16 = 400,
    terminal_font_family: ?[]u8 = null,
    terminal_font_family_id: u16 = 0,
    cursor_style: CursorStyle = .block,
    input_line_highlight: bool = false,
    input_highlight_node: ?*ui.Node = null,
    input_highlight_bar: ?*ui.Node = null,
    terminal_line_height: f32 = terminal_line_height_default,
    metrics: terminal_selection.CellMetrics = .{ .origin_x = 18, .origin_y = 18, .cell_width = 8, .cell_height = 18, .cols = 160 },
    pointer_trace_metrics: ?terminal_selection.CellMetrics = null,
    cursor_overlay: *ui.Node,
    selection_overlays: [selection_overlay_count]*ui.Node,
    /// Active IME composition text (owned). Rendered inline at the end of
    /// the frame text with an underline; keystrokes during composition are
    /// consumed by the IME, not forwarded to the remote.
    preedit: ?[]u8 = null,
    /// Per-row text nodes (lazily created up to max_grid_rows) with cached
    /// content for Ghostty-style damage tracking: a row whose content is
    /// byte-identical to the last frame is skipped entirely — no setText,
    /// no shape, no layout. This is the core display-plane optimization
    /// that makes scrolling/clear/echo proportional to actual changes
    /// instead of always paying the full-viewport cost.
    row_nodes: [max_grid_rows]?*ui.Node = @splat(null),
    row_texts: [max_grid_rows][]u8 = @splat(&[_]u8{}),
    /// Per-row cached span arrays (owned). Parallel to row_texts.
    row_span_sets: [max_grid_rows][]ui.types.TextSpan = @splat(&.{}),
    /// Overlay dirty caches: skip node writes (and their render-dirty marks)
    /// when geometry is unchanged, so idle frames cost nothing.
    cursor_cache: OverlayCache = .{},
    selection_caches: [selection_overlay_count]OverlayCache = @splat(.{}),
    /// Token for the worker frame hook. The hook must stop running before the
    /// tab's runtime is cleaned up: it dereferences the worker (text slot) and
    /// the terminal nodes every frame. Close removes it synchronously on the
    /// UI thread (hooks are UI-thread driven, so no interleaving); the scope
    /// cleanup path is a fallback and both sides are idempotent via this token.
    frame_hook: ?*FrameHook = null,
    /// Optional status-bar node mirroring the live VT/PTY grid size. Written
    /// by the frame hook with a dirty-check, so idle frames cost nothing.
    grid_status_node: ?*ui.Node = null,
    /// Last grid size written to grid_status_node (dirty-check state).
    grid_label_cols: u16 = 0,
    grid_label_rows: u16 = 0,
    grid_label_shown: bool = false,

    /// ── @ 命令面板（行首触发，见 command_palette.zig）──────────────
    /// 过滤/选择/采纳状态机 + 行首检测的本地 line-buffer 追踪。
    trusted_snapshot: ?terminal_service.trusted_edit.Snapshot = null,
    trusted_operation: u64 = 0,
    trusted_action: ?enum { history, begin, end, literal } = null,
    trusted_lease: u64 = 0,
    trusted_execute: bool = false,
    trusted_literal_token: u64 = 0,
    trusted_suppressed: ?struct { token: u64, revision: u64 } = null,
    trusted_draft: std.ArrayList(u8) = .empty,
    completion_enabled: bool = true,
    completion: completion_controller.Controller,
    completion_matches: [64]completion_mod.Match = undefined,
    completion_count: usize = 0,
    completion_selected: usize = 0,
    completion_panel: *ui.Node,
    completion_scope: *ui.Scope,
    completion_scroll: ui.widgets.ScrollAreaResult,
    completion_rows: std.ArrayList(*ui.Node) = .empty,
    completion_cache: OverlayCache = .{},
    ghost_node: *ui.Node,
    ghost_cache: OverlayCache = .{},
    palette: command_palette.Palette = .{},
    local_editor: command_palette.Editor = .{},
    line: command_palette.LineTracker = .{},
    local_input_node: *ui.Node,
    local_input_cache: OverlayCache = .{},
    /// 面板卡片节点：mount 时一次性创建（absolute + pass_through +
    /// z_index，默认隐藏）；行节点在 rows_box 里按匹配窗口重建。
    palette_panel: *ui.Node,
    palette_scope: *ui.Scope,
    palette_scroll: ui.widgets.ScrollAreaResult,
    palette_rows_box: *ui.Node,
    palette_count_text: *ui.Node,
    palette_rows: std.ArrayList(*ui.Node) = .empty,
    /// 面板几何脏检查（复用光标/选区 overlay 的跳写机制）。
    palette_cache: OverlayCache = .{},
    /// 上次渲染的行窗口（first/count/selected_offset）：窗口没变时 ↑↓ 只用
    /// setBackground 刷两行，不走整表重建。
    palette_rendered: PaletteRendered = .{},
    /// Retained accessory nodes follow the same global appearance publication
    /// as the terminal, without rebuilding an open or hidden input overlay.
    overlay_colors: ?app_theme.Colors = null,
    /// Adopt notifications and execution both stay client-local.
    palette_observer: ?PaletteObserver = null,
    input_observer: ?InputObserver = null,
    text_input_modified: bool = false,
    suppress_broadcast: bool = false,
    pending_paste_broadcast: bool = false,
    interaction_observer: ?InteractionObserver = null,
    /// Session-only switches set by @theme/@ts/@sync. They intentionally
    /// remain outside persisted Config and are owned by this terminal tab.
    local_state: local_command_state.State = .{},
    cmd_c_mode: CmdCMode = .smart,
    /// Updated by the worker/OSC state bridge. Fullscreen input is transparent.
    remote_input_context: RemoteInputContext = .{},
    history: history_replay.Timeline,
    history_bar: ?*ui.Node = null,
    history_track: ?*ui.Node = null,
    history_fill: ?*ui.Node = null,
    history_dragging: bool = false,
    history_search_top: ?u32 = null,
    history_legacy_start: usize = 0,
    history_search_wire: std.ArrayList(u8) = .empty,
    search: terminal_search.Model,
    search_open: bool = false,
    search_scope: ?*ui.Scope = null,
    search_view: ?terminal_search.View = null,
    search_marks: std.ArrayList(*ui.Node) = .empty,
    service_search: ?terminal_service.SearchSnapshot = null,
    search_anchor: ?terminal_service.Anchor = null,
    search_locate_pending: bool = false,
    error_hint: ?*@import("command_error_hint_view.zig").View = null,

    const PaletteRendered = struct {
        first: usize = 0,
        count: usize = 0,
        selected_offset: ?usize = null,
    };

    /// Borrowed bytes and stable terminal identity are valid during callback.
    /// Called only after successful source input, with explicit @sync enabled.
    pub const InputObserver = struct {
        context: ?*anyopaque = null,
        on_input: *const fn (context: ?*anyopaque, source: *TerminalViewNode, bytes: []const u8) void,
        on_service_input: ?*const fn (?*anyopaque, SessionHandle, u64, @import("broadcast_event.zig").Payload) void = null,
        paste_stamp: ?*const fn (?*anyopaque, SessionHandle) u64 = null,
    };

    pub const PaletteObserver = struct {
        context: ?*anyopaque = null,
        on_command: *const fn (context: ?*anyopaque, command: []const u8, executed: bool) void,
    };

    pub const CmdCMode = enum { smart, copy_only, signal_only };
    pub const InteractionAction = enum { copy, paste, paste_without_newlines, menu };
    pub const InteractionObserver = struct {
        context: ?*anyopaque = null,
        on_action: *const fn (context: ?*anyopaque, action: InteractionAction, x: f32, y: f32) void,
    };
    pub const RemoteInputContext = struct {
        prompt_editing: bool = true,
        alternate_screen: bool = false,
        bracketed_paste: bool = false,
    };

    fn mountHistoryBar(self: *TerminalViewNode) !void {
        const cx = self.cx;
        const c = app_theme.current();
        const bar = try ui.box(cx, .{ .height = .{ .px = 34 }, .width = .fill(), .direction = .row, .align_items = .center, .gap = 12, .padding = .{ .left = 14, .right = 14 }, .background = c.overlay }, .{});
        try bar.appendChild(cx.allocator, try ui.text(cx, "📜 历史回溯模式 · 只读", .{ .font_size = 10.5, .color = c.warn_ink }));
        const track = try ui.box(cx, .{ .height = .{ .px = 12 }, .width = .fill(), .background = c.well, .border = .{ .radius = 6 } }, .{});
        const fill = try ui.box(cx, .{ .height = .{ .px = 12 }, .width = .{ .percent = 100 }, .background = c.accent, .border = .{ .radius = 6 } }, .{});
        try track.appendChild(cx.allocator, fill);
        track.behavior.events.on_event = historyEvent;
        track.behavior.events.event_context = @ptrCast(self);
        try bar.appendChild(cx.allocator, track);
        try bar.appendChild(cx.allocator, try ui.text(cx, "拖动回放 · 可选择复制 · ESC 返回实时流", .{ .font_size = 10.5, .color = c.fg_2 }));
        // Insert before the terminal rows; bar appears only in @log mode.
        bar.style.position = .absolute;
        const bext = try bar.style.ensureExtFallible(cx.allocator);
        bext.inset = .{ .top = .{ .px = 0 }, .left = .{ .px = 0 }, .right = .{ .px = 0 } };
        try self.root.appendChild(cx.allocator, bar);
        bar.setDisplay(.none);
        self.history_bar = bar;
        self.history_track = track;
        self.history_fill = fill;
    }

    pub fn openHistory(self: *TerminalViewNode) bool {
        if (!self.history.open()) return false;
        self.refreshOverlayTheme();
        self.closeSearch();
        self.cancelLocalCommand();
        self.clearPreedit();
        self.clearPendingPaste();
        self.paste_confirmation_pending = false;
        self.selection.clear();
        if (self.history_bar) |bar| bar.setDisplay(.flex);
        self.rows_box.style.padding.top = 34;
        _ = self.renderFrame(self.cx, text_frame.decode(self.history.current().?.wire).?) catch {};
        self.focus();
        return true;
    }

    pub fn closeHistory(self: *TerminalViewNode) void {
        self.history.close();
        self.history_search_top = null;
        self.history_dragging = false;
        self.selection.clear();
        if (self.history_bar) |bar| bar.setDisplay(.none);
        self.rows_box.style.padding.top = 0;
        if (self.history.latest()) |entry| _ = self.renderFrame(self.cx, text_frame.decode(entry.wire).?) catch {};
        self.focus();
    }

    /// Extracts a selection from the frame currently shown by history replay.
    /// Archived panes have no worker, so copy must use the retained VT frame
    /// rather than the live worker selection API.
    fn copyHistorySelection(self: *TerminalViewNode, selection: @import("../vt/engine.zig").Selection, allocator: std.mem.Allocator) ![]u8 {
        const entry = self.history.current() orelse return allocator.alloc(u8, 0);
        const frame = text_frame.decode(if (self.history_search_top != null) self.history_search_wire.items else entry.wire) orelse return error.InvalidFrame;
        return extractFrameSelection(frame, selection, allocator);
    }

    fn seekHistory(self: *TerminalViewNode, x: f32) void {
        const track = self.history_track orelse return;
        const rect = track.rectFromWorldOrFallback();
        if (rect.w <= 0) return;
        const fraction = std.math.clamp((x - rect.x) / rect.w, 0, 1);
        self.history.seek(fraction);
        self.history_search_top = null;
        self.history_legacy_start = self.history.legacyOffset(self.history.selected.?);
        if (self.history_fill) |fill| {
            fill.style.width = .{ .percent = fraction * 100 };
            fill.markLayoutDirty();
        }
        self.selection.clear();
        if (self.history.current()) |entry| {
            _ = self.renderFrame(self.cx, text_frame.decode(entry.wire).?) catch {};
            if (self.search_open) {
                if (entry.search) |document| {
                    self.search.setSource(document.text) catch {};
                } else if (self.history.legacySource(self.cx.allocator)) |source| {
                    defer self.cx.allocator.free(source);
                    self.search.setSource(source) catch {};
                } else |_| {}
                if (self.search_view) |*view| view.refresh();
                self.refreshSearchMarks() catch {};
            }
        }
    }

    fn historyEvent(event: ui.events.Event, raw: ?*anyopaque) ui.events.EventResult {
        const self: *TerminalViewNode = @ptrCast(@alignCast(raw orelse return .ignored));
        switch (event) {
            .mouse_down => |mouse| {
                if (mouse.button != .left) return .ignored;
                self.history_dragging = true;
                self.seekHistory(mouse.x);
                return .stop;
            },
            .mouse_move => |mouse| {
                if (!self.history_dragging) return .ignored;
                self.seekHistory(mouse.x);
                return .stop;
            },
            .mouse_up => |mouse| {
                if (!self.history_dragging) return .ignored;
                self.seekHistory(mouse.x);
                self.history_dragging = false;
                return .stop;
            },
            else => return .ignored,
        }
    }

    pub fn openSearch(self: *TerminalViewNode) void {
        self.search_open = true;
        self.search.open = true;
        if (self.history.current()) |entry| {
            self.history_search_top = null;
            self.history_legacy_start = self.history.legacyOffset(self.history.selected.?);
            if (entry.search) |document| {
                self.search.setSource(document.text) catch {};
            } else if (self.history.legacySource(self.cx.allocator)) |source| {
                defer self.cx.allocator.free(source);
                self.search.setSource(source) catch {};
            } else |_| {}
        } else if (self.terminal_surface != null) {
            self.refreshServiceSearch() catch {};
        } else if (self.worker) |worker| {
            if (worker.searchText(self.cx.allocator)) |text| {
                defer self.cx.allocator.free(text);
                self.search.setSource(text) catch {};
            } else |_| {}
        }
        if (self.search_view) |*view| {
            view.root.setDisplay(.flex);
            view.refresh();
            view.focus();
        }
        self.cx.requestRedraw();
    }
    pub fn closeSearch(self: *TerminalViewNode) void {
        self.search_open = false;
        self.search.close();
        self.search_locate_pending = false;
        if (self.search_view) |*view| view.root.setDisplay(.none);
        for (self.search_marks.items) |mark| mark.setDisplay(.none);
        self.focus();
    }

    /// Called after the view has been moved into its stable SessionTab address.
    pub fn attachSearch(self: *TerminalViewNode, scope: *ui.Scope) !void {
        const child = try scope.childScope();
        self.search_scope = child;
        self.palette_panel.behavior.events.capture_context = @ptrCast(self);
        self.palette_panel.behavior.events.on_event_capture = palettePointer;
        try self.mountHistoryBar();
        const view = try terminal_search.mount(self.cx, child, &self.search, .{
            .context = @ptrCast(self),
            .on_query = searchQuery,
            .on_next = searchNext,
            .on_previous = searchPrevious,
            .on_close = searchClose,
        });
        self.search_view = view;
        view.root.setDisplay(.none);
        try self.root.appendChild(self.cx.allocator, view.root);
    }

    fn searchQuery(raw: ?*anyopaque, _: []const u8) void {
        const self: *TerminalViewNode = @ptrCast(@alignCast(raw.?));
        self.releaseSearchAnchor();
        self.locateSearch();
    }
    fn searchNext(raw: ?*anyopaque) void {
        const self: *TerminalViewNode = @ptrCast(@alignCast(raw.?));
        self.search.next();
        self.locateSearch();
    }
    fn searchPrevious(raw: ?*anyopaque) void {
        const self: *TerminalViewNode = @ptrCast(@alignCast(raw.?));
        self.search.previous();
        self.locateSearch();
    }
    fn searchClose(raw: ?*anyopaque) void {
        const self: *TerminalViewNode = @ptrCast(@alignCast(raw.?));
        self.closeSearch();
    }
    fn locateSearch(self: *TerminalViewNode) void {
        if (self.search_view) |*view| view.refresh();
        if (self.search.currentIndex()) |index| if (self.search.match(index)) |hit| {
            if (self.history.current()) |entry| {
                if (entry.search != null) {
                    self.locateHistorySearch(hit) catch {};
                } else if (self.history.legacyLocation(hit.start)) |location| {
                    self.history.selected = location.frame;
                    self.history_legacy_start = location.start;
                    _ = self.renderFrame(self.cx, text_frame.decode(self.history.current().?.wire).?) catch {};
                }
            } else if (self.terminal_surface) |surface| {
                self.search_locate_pending = true;
                self.locateServiceSearch(surface, hit) catch {};
            } else if (self.worker) |worker| {
                worker.locateSearchRow(std.mem.count(u8, self.search.source.items[0..hit.start], "\n"));
            }
        };
        self.cx.requestRedraw();
        self.refreshSearchMarks() catch {};
    }

    fn releaseSearchAnchor(self: *TerminalViewNode) void {
        if (self.search_anchor) |anchor| if (self.terminal_surface) |surface| {
            if (surface.owner.eql(anchor.owner)) surface.releaseAnchorLater(anchor);
        };
        self.search_anchor = null;
    }
    fn clearServiceSearch(self: *TerminalViewNode) void {
        self.releaseSearchAnchor();
        if (self.service_search) |*snapshot| snapshot.deinit(self.cx.allocator);
        self.service_search = null;
        self.search_locate_pending = false;
    }
    fn refreshServiceSearch(self: *TerminalViewNode) !void {
        const surface = self.terminal_surface orelse return;
        const displayed = surface.snapshot orelse return;
        if (!displayed.owner.eql(surface.owner)) return error.StaleOwner;
        if (self.service_search) |*previous| {
            if (previous.owner.eql(surface.owner) and previous.document.source_version == displayed.projection.version) {
                if (self.search_locate_pending) if (self.search.currentIndex()) |index| if (self.search.match(index)) |hit| try self.locateServiceSearch(surface, hit);
                return;
            }
        }
        var next = try surface.service.searchSnapshot(self.cx.allocator);
        errdefer next.deinit(self.cx.allocator);
        if (!next.owner.eql(surface.owner)) return error.StaleOwner;
        const retained = if (self.search_anchor) |anchor| surface.service.resolveAnchor(anchor) catch |err| switch (err) {
            error.WorkerBusy => return err,
            else => null,
        } else null;
        if (retained) |point| if (point.source_version != next.document.source_version) return error.StaleProjection;
        try self.search.setSource(next.document.text);
        var restored = false;
        if (retained) |point| {
            if (point.source_version == next.document.source_version and point.alternate_screen == next.document.alternate_screen) {
                for (self.search.matches.items, 0..) |hit, index| {
                    const mapped = next.document.point(hit.start) orelse continue;
                    const before = if (hit.start > 0) next.document.spanAt(hit.start - 1) else null;
                    // Selection anchors track the gap after the preceding cell.
                    // Reflow can put that gap at the end of the previous visual
                    // row while the hit begins at column zero of its continuation.
                    const gap_matches = if (before) |cell| cell.end == hit.start and cell.row + 1 == next.document.spanAt(hit.start).?.row and
                        std.meta.eql(next.document.rows[cell.row].logical_id, next.document.rows[cell.row + 1].logical_id) and
                        next.document.rows[cell.row].screen_row == point.row and cell.col + cell.width == point.col else false;
                    if ((mapped.row == point.row and mapped.col == point.col) or gap_matches) {
                        self.search.current = index;
                        restored = true;
                        break;
                    }
                }
            }
        }
        if (self.search_anchor != null and !restored) {
            self.releaseSearchAnchor();
            self.search.current = 0;
        }
        if (self.service_search) |*previous| previous.deinit(self.cx.allocator);
        self.service_search = next;
        if (self.search_view) |*view| view.refresh();
        if (next.document.source_version != displayed.projection.version) surface.force_snapshot = true;
        if (self.search_locate_pending) if (self.search.currentIndex()) |index| if (self.search.match(index)) |hit| try self.locateServiceSearch(surface, hit);
    }
    fn locateServiceSearch(self: *TerminalViewNode, surface: *TerminalSurface, hit: terminal_search.Model.Match) !void {
        const snapshot = if (self.service_search) |*value| value else return;
        if (!snapshot.owner.eql(surface.owner)) return error.StaleOwner;
        const point = snapshot.document.point(hit.start) orelse return;
        // createAnchor checks source_version while holding the original
        // service's serialization guard. A stale row index is never reused.
        const anchor = surface.service.createAnchor(point) catch |err| {
            if (err == error.StaleProjection) surface.force_snapshot = true;
            return err;
        };
        surface.service.scroll(.{ .anchor = anchor }) catch |err| {
            surface.releaseAnchorLater(anchor);
            return err;
        };
        self.releaseSearchAnchor();
        self.search_anchor = anchor;
        self.search_locate_pending = false;
        surface.force_snapshot = true;
    }

    fn refreshSearchMarks(self: *TerminalViewNode) !void {
        for (self.search_marks.items) |mark| mark.setDisplay(.none);
        if (!self.search_open or self.search.query.items.len == 0) return;
        if (self.history.current()) |entry| {
            if (entry.search) |document| return self.refreshHistorySearchMarks(&document);
        }
        if (self.terminal_surface) |surface| return self.refreshServiceSearchMarks(surface);
        const offset = if (self.worker) |worker| worker.searchViewportOffset() else 0;
        const root_rect = self.root.globalRect();
        var used: usize = 0;
        for (self.search.matches.items, 0..) |hit, index| {
            const source_start = if (self.history.current() != null) self.history_legacy_start else 0;
            if (hit.start < source_start) continue;
            if (self.history.current()) |entry| {
                const source_end = source_start + text_frame.decode(entry.wire).?.text.len;
                if (hit.end > source_end) continue;
            }
            const absolute_row = std.mem.count(u8, self.search.source.items[source_start..hit.start], "\n");
            if (absolute_row < offset or absolute_row >= offset + self.frame_rows) continue;
            const line_begin = if (std.mem.lastIndexOfScalar(u8, self.search.source.items[0..hit.start], '\n')) |at| at + 1 else 0;
            const prefix = self.search.source.items[line_begin..hit.start];
            const col = displayCellWidth(prefix);
            const width = displayCellWidth(self.search.source.items[hit.start..hit.end]);
            var mark: *ui.Node = undefined;
            if (used < self.search_marks.items.len) {
                mark = self.search_marks.items[used];
            } else {
                mark = try ui.box(self.cx, .{ .position = .absolute, .direction = .row, .align_items = .center, .z_index = 8, .border = .{ .width = 0, .color = design.color.accent, .radius = 3 } }, .{});
                (try mark.style.ensureExtFallible(self.cx.allocator)).hit_behavior = .pass_through;
                try mark.appendChild(self.cx.allocator, try ui.text(self.cx, "", .{ .use_monospace_font = true, .font_size = self.terminal_font_size, .line_height = self.terminal_line_height }));
                try self.root.appendChild(self.cx.allocator, mark);
                try self.search_marks.append(self.cx.allocator, mark);
            }
            const current = index == self.search.current;
            (try mark.style.ensureExtFallible(self.cx.allocator)).inset = .{ .left = .{ .px = self.metrics.origin_x - root_rect.x + @as(f32, @floatFromInt(col)) * self.cell_width }, .top = .{ .px = self.metrics.origin_y - root_rect.y + @as(f32, @floatFromInt(absolute_row - offset)) * self.cell_height } };
            mark.style.width = .{ .px = @as(f32, @floatFromInt(width)) * self.cell_width };
            mark.style.height = .{ .px = self.cell_height };
            mark.setBackground(if (current) design.color.accent else ui.Color.rgba(212, 154, 12, 71));
            const text = mark.children.items[0];
            try text.setTextContent(self.cx.allocator, self.search.source.items[hit.start..hit.end]);
            if (text.getText()) |old| {
                var properties = old;
                properties.color = if (current) ui.Color.WHITE else self.base_fg;
                properties.font_size = self.terminal_font_size;
                text.setText(properties);
            }
            mark.setDisplay(.flex);
            mark.markLayoutDirty();
            used += 1;
        }
    }

    fn locateHistorySearch(self: *TerminalViewNode, hit: terminal_search.Model.Match) !void {
        const entry = self.history.current() orelse return;
        const document = entry.search orelse return;
        const span = document.spanAt(hit.start) orelse return;
        const original = text_frame.decode(entry.wire) orelse return error.InvalidFrame;
        const top = span.row;
        var output: std.ArrayList(u8) = .empty;
        defer output.deinit(self.cx.allocator);
        var styles: std.ArrayList(text_frame.WireSpan) = .empty;
        defer styles.deinit(self.cx.allocator);
        const end = @min(document.rows.len, @as(usize, top) + original.rows);
        var cell_index: usize = 0;
        while (cell_index < document.spans.len and document.spans[cell_index].row < top) : (cell_index += 1) {}
        for (document.rows[top..end], 0..) |row, index| {
            if (index > 0) try output.append(self.cx.allocator, '\n');
            const offset = output.items.len;
            try output.appendSlice(self.cx.allocator, document.text[row.start..row.end]);
            while (cell_index < document.spans.len and document.spans[cell_index].row == top + index) : (cell_index += 1) {
                const cell = document.spans[cell_index];
                if (cell.color == 0 and cell.bg == 0 and cell.flags == 0) continue;
                const style: text_frame.WireSpan = .{ .start = @intCast(offset + cell.start - row.start), .end = @intCast(offset + cell.end - row.start), .color = cell.color, .bg = cell.bg, .flags = cell.flags };
                if (styles.items.len > 0) {
                    const previous = &styles.items[styles.items.len - 1];
                    if (previous.end == style.start and previous.color == style.color and previous.bg == style.bg and previous.flags == style.flags) {
                        previous.end = style.end;
                        continue;
                    }
                }
                if (styles.items.len == std.math.maxInt(u16)) return error.SearchTooLarge;
                try styles.append(self.cx.allocator, style);
            }
        }
        self.history_search_wire.clearRetainingCapacity();
        const style_bytes = styles.items.len * text_frame.span_wire_bytes;
        try self.history_search_wire.resize(self.cx.allocator, text_frame.header_bytes + style_bytes + output.items.len);
        text_frame.encodeHeader(self.history_search_wire.items[0..text_frame.header_bytes], .{ .visible = false }, original.cols, original.rows, styles.items.len, output.items.len);
        for (styles.items, 0..) |style, index| {
            const at = text_frame.header_bytes + index * text_frame.span_wire_bytes;
            const bytes = self.history_search_wire.items[at..][0..text_frame.span_wire_bytes];
            std.mem.writeInt(u32, bytes[0..4], style.start, .little);
            std.mem.writeInt(u32, bytes[4..8], style.end, .little);
            std.mem.writeInt(u32, bytes[8..12], style.color, .little);
            std.mem.writeInt(u32, bytes[12..16], style.bg, .little);
            std.mem.writeInt(u32, bytes[16..20], style.flags, .little);
        }
        @memcpy(self.history_search_wire.items[text_frame.header_bytes + style_bytes ..], output.items);
        self.history_search_top = top;
        self.selection.clear();
        _ = try self.renderFrame(self.cx, text_frame.decode(self.history_search_wire.items).?);
    }

    fn refreshHistorySearchMarks(self: *TerminalViewNode, document: *const @import("../vt/search_snapshot.zig").Document) !void {
        const top = self.history_search_top orelse return;
        const root_rect = self.root.globalRect();
        var used: usize = 0;
        for (self.search.matches.items, 0..) |hit, index| {
            const first = document.spanAt(hit.start) orelse continue;
            const last = document.spanAt(hit.end - 1) orelse continue;
            var row_index = first.row;
            while (row_index <= last.row) : (row_index += 1) {
                if (row_index < top or row_index >= top + self.frame_rows) continue;
                const row = document.rows[row_index];
                const start = document.spanAt(@max(hit.start, row.start)) orelse continue;
                const end = document.spanAt(@min(hit.end, row.end) -| 1) orelse continue;
                if (start.row != row_index or end.row != row_index) continue;
                const mark = if (used < self.search_marks.items.len) self.search_marks.items[used] else block: {
                    const node = try ui.box(self.cx, .{ .position = .absolute, .z_index = 8 }, .{});
                    (try node.style.ensureExtFallible(self.cx.allocator)).hit_behavior = .pass_through;
                    try node.appendChild(self.cx.allocator, try ui.text(self.cx, "", .{ .use_monospace_font = true }));
                    try self.root.appendChild(self.cx.allocator, node);
                    try self.search_marks.append(self.cx.allocator, node);
                    break :block node;
                };
                (try mark.style.ensureExtFallible(self.cx.allocator)).inset = .{ .left = .{ .px = self.metrics.origin_x - root_rect.x + @as(f32, @floatFromInt(start.col)) * self.cell_width }, .top = .{ .px = self.metrics.origin_y - root_rect.y + @as(f32, @floatFromInt(row_index - top)) * self.cell_height } };
                mark.style.width = .{ .px = @as(f32, @floatFromInt(end.col + end.width - start.col)) * self.cell_width };
                mark.style.height = .{ .px = self.cell_height };
                mark.setBackground(if (index == self.search.current) app_theme.current().accent else ui.Color.rgba(212, 154, 12, 71));
                const text = mark.children.items[0];
                try text.setTextContent(self.cx.allocator, document.text[start.start..end.end]);
                if (text.getText()) |old| {
                    var props = old;
                    props.color = if (index == self.search.current) ui.Color.WHITE else self.base_fg;
                    props.font_size = self.terminal_font_size;
                    props.line_height = self.terminal_line_height;
                    text.setText(props);
                }
                mark.setDisplay(.flex);
                mark.markLayoutDirty();
                used += 1;
            }
        }
    }

    fn refreshServiceSearchMarks(self: *TerminalViewNode, surface: *TerminalSurface) !void {
        const captured = if (self.service_search) |*value| value else return;
        const displayed = surface.snapshot orelse return;
        if (!captured.owner.eql(surface.owner) or !displayed.owner.eql(captured.owner) or captured.document.source_version != displayed.projection.version) return;
        const document = &captured.document;
        const root = self.root.globalRect();
        const canvas = surface.root.globalRect();
        const origin_x = canvas.x - root.x + @import("terminal_styles.zig").inset + surface.bodyX();
        const origin_y = canvas.y - root.y + @import("terminal_styles.zig").inset;
        var used: usize = 0;
        for (self.search.matches.items, 0..) |hit, index| {
            const first = document.spanAt(hit.start) orelse continue;
            const last = document.spanAt(hit.end - 1) orelse continue;
            var row_index = first.row;
            while (row_index <= last.row) : (row_index += 1) {
                const row = document.rows[row_index];
                const visible = for (displayed.projection.visible_rows) |line| {
                    if (std.meta.eql(line.id, row.id)) break line.viewport_y;
                } else continue;
                const start = document.spanAt(@max(hit.start, row.start)) orelse continue;
                const end = document.spanAt(@min(hit.end, row.end) -| 1) orelse continue;
                if (start.row != row_index or end.row != row_index) continue;
                const width = end.col + end.width - start.col;
                if (width == 0) continue;
                const mark = if (used < self.search_marks.items.len) self.search_marks.items[used] else value: {
                    const node = try ui.box(self.cx, .{ .position = .absolute, .direction = .row, .align_items = .center, .z_index = 8, .border = .{ .radius = 3 } }, .{});
                    (try node.style.ensureExtFallible(self.cx.allocator)).hit_behavior = .pass_through;
                    try node.appendChild(self.cx.allocator, try ui.text(self.cx, "", .{ .font_size = self.terminal_font_size, .line_height = self.terminal_line_height, .font_family = self.terminal_font_family_id, .use_monospace_font = self.terminal_font_family_id == 0 }));
                    try self.root.appendChild(self.cx.allocator, node);
                    try self.search_marks.append(self.cx.allocator, node);
                    break :value node;
                };
                (try mark.style.ensureExtFallible(self.cx.allocator)).inset = .{ .left = .{ .px = origin_x + @as(f32, @floatFromInt(start.col)) * surface.options.cell_width }, .top = .{ .px = origin_y + @as(f32, @floatFromInt(visible)) * surface.options.row_height } };
                mark.style.width = .{ .px = @as(f32, @floatFromInt(width)) * surface.options.cell_width };
                mark.style.height = .{ .px = surface.options.row_height };
                mark.setBackground(if (index == self.search.current) app_theme.current().accent else ui.Color.rgba(212, 154, 12, 71));
                const text = mark.children.items[0];
                try text.setTextContent(self.cx.allocator, document.text[start.start..end.end]);
                if (text.getText()) |old| {
                    var props = old;
                    props.color = if (index == self.search.current) ui.Color.WHITE else self.base_fg;
                    props.font_family = self.terminal_font_family_id;
                    props.use_monospace_font = self.terminal_font_family_id == 0;
                    props.font_size = self.terminal_font_size;
                    props.line_height = self.terminal_line_height;
                    text.setText(props);
                }
                mark.setDisplay(.flex);
                mark.markLayoutDirty();
                used += 1;
            }
        }
    }

    pub fn searchModel(self: *TerminalViewNode) *terminal_search.Model {
        return &self.search;
    }

    pub fn setRemoteInputContext(self: *TerminalViewNode, input: RemoteInputContext) void {
        self.remote_input_context = input;
        if (input.alternate_screen or !input.prompt_editing) {
            self.cancelLocalCommand();
            self.completion.dismiss();
            self.renderCompletion();
        }
    }

    /// Apply a settings change to an already-mounted terminal without
    /// rebuilding its node tree or stealing focus from the active editor.
    pub fn refreshCompletionState(self: *TerminalViewNode) void {
        self.refreshCompletion();
    }

    pub fn mount(cx: *ui.Cx) !TerminalViewNode {
        const c = app_theme.current();
        const root = try ui.box(cx, .{
            .width = .fill(),
            .height = .fill(),
            .direction = .column,
            .padding = .{ .top = 8, .bottom = 8, .left = 12, .right = 12 },
            .background = ui.Color.TRANSPARENT,
            // Borderless by design: the terminal pane blends into the page.
            // Focus feedback comes from the tab bar highlight, not a frame.
            .border = .{ .width = 0, .color = cx.tokens.tokens.color.border, .radius = 10 },
        }, .{});
        root.meta.ownership.meta.test_id = "terminal.input";
        // Monospace + explicit advance: terminal column semantics (1 cell =
        // 1 advance) for both the glyphs and the overlay/resize math below.
        // Measuring once via CoreText and pinning monospace_char_width keeps
        // the renderer's fast path and the overlay geometry on one number.
        var cell_width: f32 = 7.8;
        if (cx.text.shapeText(.{
            .text = "M",
            .font_family = "system",
            .font_size = terminal_font_size_default,
            .font_weight = 400,
            .use_monospace = true,
        })) |run| {
            if (run.total_advance > 0) cell_width = run.total_advance;
        } else |_| {}
        // Ghostty-style row pool: the content area is a column of fixed-height
        // text nodes, one per VT grid row. Row nodes are created lazily as
        // frames arrive; unchanged rows are skipped entirely on consume.
        const rows_box = try ui.box(cx, .{
            .width = .fill(),
            .height = .fill(),
            .direction = .column,
        }, .{});
        try root.appendChild(cx.allocator, rows_box);
        root.behavior.interaction.focusable = true;

        // Passive overlays (cursor block + selection rows). Absolute inside
        // root, pointer-transparent; geometry is reprojected every frame from
        // the output node's world rect and the frame's grid metadata.
        const cursor_overlay = try makeOverlay(cx, cx.tokens.tokens.color.accent, 2);
        try root.appendChild(cx.allocator, cursor_overlay);
        var selection_overlays: [selection_overlay_count]*ui.Node = undefined;
        for (&selection_overlays) |*slot| {
            const node = try makeOverlay(cx, c.selection, 1);
            try root.appendChild(cx.allocator, node);
            slot.* = node;
        }

        // @ 命令面板：一次性创建的浮动卡片（absolute + z_index，
        // 默认隐藏）；行节点在打开/过滤时于 rows_box 内重建（几十个节点，便宜）。
        const palette_nodes = try makeCatalogueNodes(cx);
        try root.appendChild(cx.allocator, palette_nodes.panel);
        const local_input_node = try ui.text(cx, "", .{
            .font_size = terminal_font_size_default,
            .font_weight = 600,
            .line_height = terminal_line_height_default,
            .color = c.accent_ink,
            .use_monospace_font = true,
            .monospace_char_width = cell_width,
            .wrap = .none,
        });
        local_input_node.style.position = .absolute;
        const local_ext = try local_input_node.style.ensureExtFallible(cx.allocator);
        local_ext.inset = .{ .top = .{ .px = 0 }, .left = .{ .px = 0 } };
        local_ext.hit_behavior = .pass_through;
        local_ext.z_index = 3;
        local_input_node.setDisplay(.none);
        try root.appendChild(cx.allocator, local_input_node);

        const completion_nodes = try makeCompletionNodes(cx);
        try root.appendChild(cx.allocator, completion_nodes.panel);
        const ghost_node = try ui.text(cx, "", .{ .font_size = terminal_font_size_default, .line_height = terminal_line_height_default, .color = c.fg_3, .use_monospace_font = true, .monospace_char_width = cell_width, .wrap = .none });
        ghost_node.style.position = .absolute;
        const ghost_ext = try ghost_node.style.ensureExtFallible(cx.allocator);
        ghost_ext.inset = .{ .top = .{ .px = 0 }, .left = .{ .px = 0 } };
        ghost_ext.hit_behavior = .pass_through;
        ghost_ext.z_index = 3;
        ghost_node.setDisplay(.none);
        try root.appendChild(cx.allocator, ghost_node);
        var completer = completion_controller.Controller.init(cx.allocator, true);
        errdefer completer.deinit();
        // Real built-in commands, not the screenshot's example history.
        for ([_][]const u8{ "git status", "git diff", "git log", "git branch", "ls -la", "pwd", "df -h", "du -sh ", "ps aux", "systemctl status ", "journalctl -f", "kubectl get pods", "kubectl get nodes -o wide", "kubectl describe pod ", "docker ps", "docker logs " }) |command| try completer.add(command, .builtin, 1, 0);
        return .{
            .completion = completer,
            .completion_panel = completion_nodes.panel,
            .completion_scope = completion_nodes.scope,
            .completion_scroll = completion_nodes.scroll,
            .ghost_node = ghost_node,
            .root = root,
            .rows_box = rows_box,
            .cx = cx,
            .focus_border_color = cx.tokens.tokens.color.accent,
            .idle_border_color = cx.tokens.tokens.color.border,
            .cell_width = cell_width,
            .cell_height = terminal_row_height_default,
            .terminal_font_size = terminal_font_size_default,
            .terminal_line_height = terminal_line_height_default,
            .cursor_overlay = cursor_overlay,
            .selection_overlays = selection_overlays,
            .palette_panel = palette_nodes.panel,
            .palette_scope = palette_nodes.scope,
            .palette_scroll = palette_nodes.scroll,
            .palette_rows_box = palette_nodes.rows_box,
            .palette_count_text = palette_nodes.count_text,
            .local_input_node = local_input_node,
            .search = terminal_search.Model.init(cx.allocator),
            .history = history_replay.Timeline.init(cx.allocator, 16 * 1024 * 1024),
        };
    }

    /// Workspace theme injection: terminal base fg (default text), the idle
    /// border color and the focused border color. Called after mount;
    /// overrides the generic dark-theme tokens that made the pale theme's
    /// terminal text near-invisible and the border a black frame.
    pub fn setThemeColors(self: *TerminalViewNode, base_fg: ui.Color, idle_border: ui.Color, focus_border: ui.Color) void {
        self.refreshOverlayTheme();
        self.idle_border_color = idle_border;
        self.focus_border_color = focus_border;
        self.base_fg = base_fg;
        for (self.row_nodes) |maybe| {
            if (maybe) |node| {
                if (node.getText()) |props| {
                    var next = props;
                    next.color = base_fg;
                    node.setText(next);
                    node.markRenderDirty();
                }
            }
        }
        self.root.setBorderColor(idle_border);
    }

    fn paintPaletteShell(self: *TerminalViewNode, panel: *ui.Node) void {
        const c = app_theme.current();
        panel.setStyleInline(self.cx.allocator, overlay_styles.panelPaint());
        const header = panel.children.items[0];
        const footer = panel.children.items[2];
        if (panel == self.palette_panel) {
            _ = header.children.items[0].setTint(c.accent);
            header.children.items[1].setTextColor(c.fg_1);
            for (footer.children.items) |node| node.setTextColor(c.fg_2);
            return;
        }
        header.setStyleInline(self.cx.allocator, .{ .border_bottom_color = c.border });
        footer.setStyleInline(self.cx.allocator, .{ .border_top_color = c.border });
        for (header.children.items) |node| node.setTextColor(c.fg_2);
        for (footer.children.items) |node| node.setTextColor(c.fg_2);
    }

    /// Paint only: preserve node IDs, row matching, scroll, selection, focus,
    /// history drag state and every coordinate used by terminal gestures.
    fn refreshOverlayTheme(self: *TerminalViewNode) void {
        const c = app_theme.current();
        if (self.overlay_colors) |old| if (std.meta.eql(old, c)) return;
        self.paintPaletteShell(self.palette_panel);
        self.paintPaletteShell(self.completion_panel);
        for (self.palette_rows.items, 0..) |row, i| {
            row.setBackground(overlay_styles.rowBackground(self.palette_rendered.selected_offset == i));
            _ = row.children.items[0].setTint(c.fg_2);
            row.children.items[1].setTextColor(c.accent_ink);
            row.children.items[2].setTextColor(c.fg_1);
        }
        for (self.completion_rows.items, 0..) |row, i| {
            row.setBackground(overlay_styles.rowBackground(self.completion_selected == i));
            const label = row.children.items[0];
            if (label.getText()) |old| {
                var next = old;
                next.color = c.fg_1;
                // getText borrows node-owned spans. Transfer a repainted copy
                // back to the same label, preserving the byte range/weight.
                const spans = self.cx.allocator.dupe(ui.types.TextSpan, next.spans) catch continue;
                for (spans) |*span| {
                    span.color = c.accent_ink;
                }
                next.spans = spans;
                next.spans_owned = true;
                label.setText(next);
                label.markRenderDirty();
            }
            const badge = row.children.items[1];
            const source = self.completion_matches[i].candidate.source;
            badge.setBackground(overlay_styles.badgeBackground(source));
            badge.children.items[0].setTextColor(overlay_styles.badgeForeground(source));
            if (row.children.items.len > 2) row.children.items[2].setTextColor(c.fg_2);
        }
        if (self.history_bar) |bar| {
            bar.setBackground(c.overlay);
            bar.children.items[0].setTextColor(c.warn_ink);
            bar.children.items[2].setTextColor(c.fg_2);
        }
        if (self.history_track) |track| track.setBackground(c.well);
        if (self.history_fill) |fill| fill.setBackground(c.accent);
        self.local_input_node.setTextColor(c.accent_ink);
        self.ghost_node.setTextColor(c.fg_3);
        self.cursor_overlay.setBackground(c.accent);
        for (self.selection_overlays) |node| node.setBackground(c.selection);
        if (self.input_highlight_node) |node| node.setBackground(c.accent.withAlpha(10));
        if (self.input_highlight_bar) |node| node.setBackground(c.accent.withAlpha(150));
        if (self.search_view) |*view| view.retheme();
        self.overlay_colors = c;
        self.cx.requestRedraw();
    }

    pub fn localCommandState(self: *const TerminalViewNode) local_command_state.State {
        return self.local_state;
    }

    /// Toggle the session-local timestamp gutter from the terminal context menu.
    pub fn toggleTimestampGutter(self: *TerminalViewNode) bool {
        const next = !self.local_state.timestamp_gutter;
        _ = self.local_state.applyTimestamp(next);
        self.cx.requestRedraw();
        return next;
    }

    pub fn toggleBlockSelection(self: *TerminalViewNode) bool {
        const next = !self.local_state.block_selection;
        _ = self.local_state.applyBlockSelection(next);
        self.cx.requestRedraw();
        return next;
    }

    fn applyLocalCommand(self: *TerminalViewNode, command: builtin_commands.Command) bool {
        switch (command) {
            .log => {
                return self.openHistory();
            },
            .timestamp => |enabled| {
                _ = self.local_state.applyTimestamp(enabled);
                return true;
            },
            .sync => return false,
            .theme => |name| {
                if (self.local_state.applyTheme(name) == .invalid_theme) return false;
                // Session themes affect this terminal pane only. Keep the
                // surrounding chrome untouched and reuse the existing row
                // styling path so no alternate UI is introduced.
                const Colors = struct { fg: ui.Color, bg: ui.Color, border: ui.Color };
                const colors: Colors = switch (self.local_state.theme) {
                    .default => .{ .fg = ui.Color.rgb(15, 23, 42), .bg = ui.Color.rgb(247, 253, 249), .border = ui.Color.rgb(207, 229, 216) },
                    .dark_pro => .{ .fg = ui.Color.rgb(226, 232, 240), .bg = ui.Color.rgb(15, 23, 42), .border = ui.Color.rgb(71, 85, 105) },
                    .solarized_dark => .{ .fg = ui.Color.rgb(147, 161, 161), .bg = ui.Color.rgb(0, 43, 54), .border = ui.Color.rgb(88, 110, 117) },
                    .dracula => .{ .fg = ui.Color.rgb(248, 248, 242), .bg = ui.Color.rgb(40, 42, 54), .border = ui.Color.rgb(98, 114, 164) },
                    .catppuccin_mocha => .{ .fg = ui.Color.rgb(205, 214, 244), .bg = ui.Color.rgb(30, 30, 46), .border = ui.Color.rgb(88, 91, 112) },
                };
                self.root.setBackground(colors.bg);
                self.setThemeColors(colors.fg, colors.border, self.focus_border_color);
                return true;
            },
            else => return false,
        }
    }

    pub const CursorStyle = enum { block, bar, underline };

    /// The name is copied before old storage is released; the process-owned
    /// registry id is what Zenit's render pipeline stores on text nodes.
    pub fn setTypographyFamily(self: *TerminalViewNode, size: f32, line_height: f32, weight: u16, family: []const u8, family_id: u16) !void {
        const owned = try self.cx.allocator.dupe(u8, family);
        const previous = self.terminal_font_family;
        self.terminal_font_family = owned;
        self.terminal_font_family_id = family_id;
        self.setTypography(size, line_height, weight);
        if (previous) |old| self.cx.allocator.free(old);
    }

    pub fn setCursorStyle(self: *TerminalViewNode, style: CursorStyle) void {
        self.cursor_style = style;
        self.renderCursorOverlay();
        self.cx.requestRedraw();
    }

    pub fn setInputLineHighlight(self: *TerminalViewNode, enabled: bool) !void {
        if (enabled and self.input_highlight_node == null) {
            const row = try makeOverlay(self.cx, app_theme.current().accent.withAlpha(10), 1);
            errdefer self.cx.destroyDetached(row);
            const bar = try makeOverlay(self.cx, app_theme.current().accent.withAlpha(150), 2);
            errdefer self.cx.destroyDetached(bar);
            try self.root.appendChild(self.cx.allocator, row);
            self.root.appendChild(self.cx.allocator, bar) catch |err| {
                self.cx.detachChild(self.root, row);
                return err;
            };
            self.input_highlight_node = row;
            self.input_highlight_bar = bar;
        }
        self.input_line_highlight = enabled;
        self.renderInputLineHighlight();
        self.cx.requestRedraw();
    }

    fn renderInputLineHighlight(self: *TerminalViewNode) void {
        const row = self.input_highlight_node orelse return;
        const bar = self.input_highlight_bar orelse return;
        if (self.terminal_surface != null) {
            row.setDisplay(.none);
            bar.setDisplay(.none);
            return;
        }
        const visible = self.input_line_highlight and self.has_frame and self.frame_cursor.visible and
            self.frame_cursor.row < self.frame_rows and self.remote_input_context.prompt_editing and
            !self.remote_input_context.alternate_screen and self.history.selected == null;
        row.setDisplay(if (visible) .flex else .none);
        bar.setDisplay(.none);
        if (!visible) return;
        const root = self.root.globalRect();
        const y = self.metrics.origin_y - root.y + @as(f32, @floatFromInt(self.frame_cursor.row)) * self.cell_height;
        const x = self.metrics.origin_x - root.x;
        for ([_]*ui.Node{ row, bar }, 0..) |node, index| {
            const ext = node.style.ensureExtFallible(self.cx.allocator) catch return;
            ext.inset = .{ .left = .{ .px = x }, .top = .{ .px = y } };
            node.style.width = .{ .px = if (index == 0) @as(f32, @floatFromInt(self.frame_cols)) * self.cell_width else 2 };
            node.style.height = .{ .px = self.cell_height };
            node.markLayoutDirty();
        }
    }

    pub fn setTimestampGutter(self: *TerminalViewNode, enabled: bool) void {
        _ = self.local_state.applyTimestamp(enabled);
        self.cx.requestRedraw();
    }

    pub fn setTypography(self: *TerminalViewNode, size: f32, line_height: f32, weight: u16) void {
        self.terminal_font_size = size;
        self.terminal_font_weight = weight;
        self.terminal_line_height = line_height;
        self.cell_height = size * line_height;
        if (self.cx.text.shapeText(.{ .text = "M", .font_family = self.terminal_font_family orelse "system", .font_family_id = self.terminal_font_family_id, .font_size = size, .font_weight = weight, .use_monospace = self.terminal_font_family_id == 0 })) |run| {
            if (run.total_advance > 0) self.cell_width = run.total_advance;
        } else |_| {}
        for (self.row_nodes) |maybe| if (maybe) |node| {
            var props = node.getText() orelse continue;
            props.font_size = size;
            props.font_family = self.terminal_font_family_id;
            // An explicit prepared family must use its registry face. The
            // semantic mono flag would override it with the global mono slot.
            props.use_monospace_font = self.terminal_font_family_id == 0;
            if (props.spans.len > 0) {
                const adjusted = self.cx.allocator.dupe(ui.types.TextSpan, props.spans) catch continue;
                for (adjusted) |*span| if (span.font_weight != null) {
                    span.font_weight = boldWeight(weight);
                };
                if (props.spans_owned) self.cx.allocator.free(props.spans);
                props.spans = adjusted;
                props.spans_owned = true;
            }
            props.font_weight = weight;
            props.line_height = line_height;
            props.monospace_char_width = self.cell_width;
            node.setText(props);
            node.style.height = .{ .px = self.cell_height };
            node.markLayoutDirty();
        };
        for ([_]*ui.Node{ self.ghost_node, self.local_input_node }) |node| {
            if (node.getText()) |old| {
                var props = old;
                props.font_family = self.terminal_font_family_id;
                props.use_monospace_font = self.terminal_font_family_id == 0;
                props.font_size = size;
                props.font_weight = weight;
                props.line_height = line_height;
                props.monospace_char_width = self.cell_width;
                node.setText(props);
                node.markLayoutDirty();
            }
        }
        self.root.markLayoutDirty();
        self.cx.requestRedraw();
    }

    /// Creates (or returns the existing) text node for one grid row.
    /// Fixed height = one cell row, monospace, single line, no wrap.
    fn ensureRowNode(self: *TerminalViewNode, cx: *ui.Cx, row: usize) !*ui.Node {
        if (row >= max_grid_rows) return error.RowOutOfBounds;
        if (self.row_nodes[row]) |node| return node;
        const node = try ui.text(cx, "", .{
            .font_size = self.terminal_font_size,
            .font_weight = self.terminal_font_weight,
            .font_family = self.terminal_font_family_id,
            .use_monospace_font = self.terminal_font_family_id == 0,
            .line_height = self.terminal_line_height,
            .color = self.base_fg,
            .wrap = .none,
            .monospace_char_width = self.cell_width,
        });
        node.style.width = .fill();
        node.style.height = .{ .px = self.cell_height };
        try self.rows_box.appendChild(cx.allocator, node);
        self.row_nodes[row] = node;
        return node;
    }

    fn makeOverlay(cx: *ui.Cx, background: ui.Color, z_index: i16) !*ui.Node {
        const node = try ui.box(cx, .{
            .position = .absolute,
            .width = .{ .px = 0 },
            .height = .{ .px = 0 },
            .background = background,
        }, .{});
        const ext = try node.style.ensureExtFallible(cx.allocator);
        ext.inset = .{ .top = .{ .px = 0 }, .left = .{ .px = 0 } };
        ext.hit_behavior = .pass_through;
        ext.z_index = z_index;
        node.setDisplay(.none);
        return node;
    }

    const CommandPaletteNodes = struct {
        panel: *ui.Node,
        rows_box: *ui.Node,
        scope: *ui.Scope,
        scroll: ui.widgets.ScrollAreaResult,
        count_text: *ui.Node,
    };

    fn makeCatalogueNodes(cx: *ui.Cx) !CommandPaletteNodes {
        const c = app_theme.current();
        const panel = try ui.box(cx, overlay_styles.cataloguePanel(), .{});
        panel.meta.ownership.meta.test_id = "terminal.commands";
        panel.setDisplay(.none);
        const header = try ui.box(cx, overlay_styles.catalogueHeader(), .{});
        try header.appendChild(cx.allocator, try ui.iconTint(cx, ui.icons.command, c.accent, .{ .width = .{ .px = 16 }, .height = .{ .px = 16 }, .flex_shrink = 0 }));
        const title = try ui.text(cx, "本地指令", overlay_styles.catalogueTitle());
        title.setStyleInline(cx.allocator, .{ .width = .{ .grow = .{ .min = 0 } }, .height = .{ .px = 18 }, .min_width = 0 });
        try header.appendChild(cx.allocator, title);
        try panel.appendChild(cx.allocator, header);
        const scope = try ui.Scope.init(cx.allocator, null, cx.owner);
        errdefer scope.dispose();
        const scroll = try ui.widgets.ScrollArea(.{ .height = overlay_styles.catalogue_viewport_height, .direction = .vertical }).mount(scope, cx);
        scroll.container.setStyleInline(cx.allocator, .{ .width = .fill(), .flex_shrink = 0, .min_width = 0, .min_height = 0 });
        scroll.container.meta.ownership.meta.test_id = "terminal.commands.rows";
        scroll.content.setStyleInline(cx.allocator, overlay_styles.catalogueRows());
        try panel.appendChild(cx.allocator, scroll.container);
        const footer = try ui.box(cx, overlay_styles.catalogueFooter(), .{});
        const count = try ui.text(cx, "", overlay_styles.catalogueCount());
        count.setStyleInline(cx.allocator, .{ .flex_shrink = 0, .overflow = .visible });
        try footer.appendChild(cx.allocator, count);
        try footer.appendChild(cx.allocator, try ui.spacer(cx));
        const keys = try ui.text(cx, "↑↓ 选择 · → 采纳 · ↵ 执行 · Esc 关闭", overlay_styles.catalogueHint());
        keys.setStyleInline(cx.allocator, .{ .min_width = 0, .flex_shrink = 1 });
        try footer.appendChild(cx.allocator, keys);
        try panel.appendChild(cx.allocator, footer);
        return .{ .panel = panel, .rows_box = scroll.content, .count_text = count, .scope = scope, .scroll = scroll };
    }

    /// @ 命令面板卡片：标题行 + 行容器 + 底部提示行。mount 时一次性创建；
    /// 默认隐藏，打开时由 placeOverlay/hideOverlay 按光标行锚定显示。
    fn makeCommandPaletteNodes(cx: *ui.Cx) !CommandPaletteNodes {
        const c = app_theme.current();
        const panel = try ui.box(cx, .{
            .position = .absolute,
            .width = .{ .px = palette_width },
            .direction = .column,
            .background = c.overlay,
            .border = .{ .width = 0, .color = c.border, .radius = 12 },
            .shadow = .{ .color = c.shadow, .blur = 28, .offset_x = 0, .offset_y = 10 },
            .overflow = .hidden,
        }, .{});
        const ext = try panel.style.ensureExtFallible(cx.allocator);
        ext.inset = .{ .top = .{ .px = 0 }, .left = .{ .px = 0 } };
        ext.z_index = palette_z_index;
        panel.setDisplay(.none);

        // 标题行：“内置指令” + 触发规则说明（浅灰小字）。
        const header = try ui.box(cx, .{
            .height = .{ .px = palette_header_height },
            .direction = .row,
            .align_items = .center,
            .gap = 8,
            .padding = .{ .left = 14, .right = 14, .top = 0, .bottom = 0 },
            .border_bottom_width = 0,
            .border_bottom_color = c.border,
        }, .{});
        try header.appendChild(cx.allocator, try ui.text(cx, "内置指令", .{
            .font_size = 10.5,
            .font_weight = 600,
            .color = c.fg_2,
        }));
        try header.appendChild(cx.allocator, try ui.text(cx, "仅在提示行行首键入 · 不发送远端", .{
            .font_size = 10.5,
            .color = c.fg_2,
        }));
        try panel.appendChild(cx.allocator, header);

        // 命令行容器：行节点每次打开/过滤时整体重建（文本是静态串，零拷贝）。
        const scope = try ui.Scope.init(cx.allocator, null, cx.owner);
        errdefer scope.dispose();
        const scroll = try ui.widgets.ScrollArea(.{ .height = palette_row_height * command_palette.max_visible_rows, .direction = .vertical }).mount(scope, cx);
        const rows_box = scroll.content;
        try panel.appendChild(cx.allocator, scroll.container);

        // 底部提示行：共 N 条匹配（左）+ 键位说明（右）。
        const hint = try ui.box(cx, .{
            .height = .{ .px = palette_hint_height },
            .direction = .row,
            .align_items = .center,
            .gap = 12,
            .padding = .{ .left = 14, .right = 14, .top = 0, .bottom = 0 },
            .border_top_width = 0,
            .border_top_color = c.border,
        }, .{});
        const count_text = try ui.text(cx, "", .{ .font_size = 10, .color = c.fg_2 });
        try hint.appendChild(cx.allocator, count_text);
        try hint.appendChild(cx.allocator, try ui.spacer(cx));
        try hint.appendChild(cx.allocator, try ui.text(cx, "↑↓ 选择 · → 采纳 · ↵ 执行 · @@ 转义 @", .{
            .font_size = 10,
            .color = c.fg_2,
        }));
        try panel.appendChild(cx.allocator, hint);

        return .{ .panel = panel, .rows_box = rows_box, .count_text = count_text, .scope = scope, .scroll = scroll };
    }

    /// 面板单行：蓝色命令名（等宽、定宽对齐）+ 黑色说明 + spacer +
    /// 右灰示例。选中态整行浅蓝背景。
    fn makePaletteRow(cx: *ui.Cx, entry: builtin_commands.Entry, selected: bool) !*ui.Node {
        const c = app_theme.current();
        const row = try ui.box(cx, overlay_styles.catalogueRow(selected), .{});
        row.meta.ownership.meta.test_id = entry.name;
        try row.appendChild(cx.allocator, try ui.iconTint(cx, catalogueIcon(entry.name), c.fg_2, overlay_styles.catalogueIcon()));
        const name = try ui.text(cx, entry.name, overlay_styles.catalogueName());
        name.setStyleInline(cx.allocator, .{ .width = .{ .px = 58 }, .height = .{ .px = 18 }, .flex_shrink = 0 });
        try row.appendChild(cx.allocator, name);
        const description = try ui.text(cx, entry.paletteDescription(), overlay_styles.catalogueDescription());
        description.setStyleInline(cx.allocator, .{ .width = .{ .grow = .{ .min = 0 } }, .height = .{ .px = 18 }, .min_width = 0 });
        try row.appendChild(cx.allocator, description);
        return row;
    }

    fn catalogueIcon(name: []const u8) ui.SvgAsset {
        const names = [_][]const u8{ "@up", "@dl", "@ai", "@new", "@dup", "@grp", "@pin", "@sync", "@ts", "@log", "@socks", "@theme", "@help", "@@" };
        const icons = [_]ui.SvgAsset{ ui.icons.upload, ui.icons.download, ui.icons.sparkles, ui.icons.plus, ui.icons.copy, ui.icons.panels_top_left, ui.icons.pin, ui.icons.radio, ui.icons.clock_3, ui.icons.rotate_ccw_clock, ui.icons.plug_zap, ui.icons.palette, ui.icons.book_open, ui.icons.at_sign };
        for (names, icons) |candidate, icon| if (std.mem.eql(u8, name, candidate)) return icon;
        return ui.icons.command;
    }

    /// Refreshes the status-bar grid label from the latest frame geometry.
    /// Dirty-checked: unchanged frames skip the setText + render-dirty path.
    pub fn updateGridStatus(self: *TerminalViewNode) void {
        const node = self.grid_status_node orelse return;
        if (self.grid_label_shown and
            self.grid_label_cols == self.frame_cols and
            self.grid_label_rows == self.frame_rows) return;
        if (!self.has_frame) return;
        self.grid_label_cols = self.frame_cols;
        self.grid_label_rows = self.frame_rows;
        self.grid_label_shown = true;
        var buffer: [16]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buffer);
        writer.print("{d}×{d}", .{ self.frame_cols, self.frame_rows }) catch return;
        node.setTextContent(self.cx.allocator, writer.buffered()) catch return;
        node.markRenderDirty();
    }

    fn makeCompletionNodes(cx: *ui.Cx) !CommandPaletteNodes {
        const nodes = try makeCommandPaletteNodes(cx);
        nodes.panel.meta.ownership.meta.test_id = "terminal.completion";
        // Completion rows are virtualized/rebuilt by the controller. Keep the
        // scroll state's content height under our control instead of letting
        // the layout pass replace it with the currently visible child rect.
        nodes.scroll.state.external_content_height = true;
        nodes.panel.style.width = .{ .px = 520 };
        nodes.scroll.content.style.direction = .column;

        // Reuse the scrolling shell, replace @-specific header/footer content.
        const header = nodes.panel.children.items[0];
        while (header.children.items.len > 0) {
            const child = header.children.items[0];
            header.removeChild(child);
            cx.destroyDetached(child);
        }
        try header.appendChild(cx.allocator, try ui.text(cx, "历史命令 · 可在设置关闭", .{ .font_size = 10.5, .color = app_theme.current().fg_2, .wrap = .none }));
        header.style.height = .{ .px = 32 };
        header.style.flex_shrink = 0;
        const footer = nodes.panel.children.items[2];
        while (footer.children.items.len > 0) {
            const child = footer.children.items[0];
            footer.removeChild(child);
            cx.destroyDetached(child);
        }
        try footer.appendChild(cx.allocator, try ui.text(cx, "↑↓ 选择    → 采纳到行    ↵ 提交原输入", .{ .font_size = 10, .color = app_theme.current().fg_2, .wrap = .none }));
        footer.style.height = .{ .px = 32 };
        footer.style.flex_shrink = 0;
        return nodes;
    }

    fn completionAllowed(self: *TerminalViewNode) bool {
        const surface = self.terminal_surface orelse return false;
        const snapshot = self.trusted_snapshot orelse return false;
        return self.completion_enabled and snapshot.owner.eql(surface.owner) and snapshot.editable() and
            surface.active and surface.focused and surface.preedit.len == 0 and surface.selection == null and
            surface.pending.items.len == 0 and surface.trusted_pending == null and self.trusted_action == null and
            surface.snapshot != null and !surface.snapshot.?.read_only and !surface.snapshot.?.projection.modes.alternate_screen and
            !self.local_editor.active and !self.palette.isOpen() and surface.pending_paste == null and surface.paste_requested == null;
    }

    fn clearTrustedSnapshot(self: *TerminalViewNode) void {
        if (self.trusted_snapshot) |*snapshot| snapshot.deinit(self.cx.allocator);
        self.trusted_snapshot = null;
    }

    fn requestTrusted(self: *TerminalViewNode, action: @FieldType(TerminalViewNode, "trusted_action"), replacement: []const u8) !void {
        const surface = self.terminal_surface orelse return error.TrustedEditUnavailable;
        const snapshot = self.trusted_snapshot orelse return error.TrustedEditUnavailable;
        self.trusted_operation = try std.math.add(u64, self.trusted_operation, 1);
        try surface.requestTrustedEdit(.{ .operation = self.trusted_operation, .token = snapshot.token, .revision = snapshot.revision, .kind = switch (action.?) {
            .begin => .begin,
            .end => .end,
            else => .replace,
        }, .replacement = replacement, .lease = self.trusted_lease });
        self.trusted_action = action;
        self.completion.dismiss();
    }

    fn refreshTrustedEdit(self: *TerminalViewNode) void {
        const surface = self.terminal_surface orelse return;
        const next = surface.service.trustedSnapshot(self.cx.allocator) catch |err| {
            if (err != error.WorkerBusy) self.clearTrustedSnapshot();
            return;
        };
        const changed = if (next) |value| if (self.trusted_snapshot) |old| value.token != old.token or value.revision != old.revision else true else self.trusted_snapshot != null;
        self.clearTrustedSnapshot();
        self.trusted_snapshot = next;
        if (surface.trusted_outcome) |outcome| {
            surface.trusted_outcome = null;
            if (outcome.operation == self.trusted_operation) {
                const action = self.trusted_action;
                self.trusted_action = null;
                if (outcome.applied) {
                    if (action == .begin) {
                        self.trusted_lease = outcome.lease;
                        self.openCommandPalette();
                        if (self.trusted_draft.items.len != 0) _ = serviceEditText(self, self.trusted_draft.items);
                        if (self.palette.isOpen()) self.refreshCommandPaletteRows();
                    } else if (action == .literal) {
                        self.trusted_literal_token = if (next) |value| value.token else 0;
                        self.trusted_lease = 0;
                    } else if (action == .end) {
                        self.trusted_lease = 0;
                        if (self.trusted_execute) {
                            self.trusted_execute = false;
                            self.executeLocalCommandChecked();
                        }
                    }
                } else {
                    if (action == .literal) self.local_editor.adopt(self.cx.allocator, "@@") catch {};
                    if (action == .begin) {
                        self.local_editor.adopt(self.cx.allocator, "@") catch {};
                        _ = self.local_editor.insert(self.cx.allocator, self.trusted_draft.items) catch false;
                    }
                    self.trusted_lease = 0;
                    self.trusted_execute = false;
                    self.closeCommandPalette();
                    surface.showError(error.TrustedEditRejected);
                }
                if (action != .begin and self.trusted_draft.items.len != 0) {
                    self.local_editor.adopt(self.cx.allocator, self.trusted_draft.items) catch {};
                }
                self.trusted_draft.clearRetainingCapacity();
            }
        }
        if (surface.recovered_input.items.len != 0) {
            self.local_editor.adopt(self.cx.allocator, surface.recovered_input.items) catch {};
            surface.recovered_input.clearRetainingCapacity();
        }
        if (self.trusted_lease != 0 and self.trusted_action == null) {
            if (next == null or next.?.lease != self.trusted_lease) {
                if (self.palette.isOpen()) {
                    const recovered = std.mem.concat(self.cx.allocator, u8, &.{ "@", self.palette.query.items }) catch null;
                    if (recovered) |text| {
                        defer self.cx.allocator.free(text);
                        self.local_editor.adopt(self.cx.allocator, text) catch {};
                    }
                }
                self.trusted_lease = 0;
                self.closeCommandPalette();
                // Keep the editor text available for recovery; Enter is gated
                // by the shell lease and cannot become a shell submission.
                surface.showError(error.TrustedEditRejected);
            }
        }
        if (changed) self.refreshCompletion();
        self.renderCommandPalette();
        self.renderLocalInput();
        self.renderCompletion();
    }

    fn serviceEditKey(raw: *anyopaque, key: ui.events.KeyCode, modifiers: ui.events.Modifiers) bool {
        const self: *TerminalViewNode = @ptrCast(@alignCast(raw));
        const surface = self.terminal_surface orelse return false;
        if (key == .c and modifiers.ctrl and !modifiers.super) {
            self.trusted_action = null;
            self.trusted_lease = 0;
            self.trusted_execute = false;
            self.trusted_draft.clearRetainingCapacity();
            self.closeCommandPalette();
            self.local_editor.cancel();
            return false;
        }
        if (self.trusted_execute) return true;
        if (self.trusted_action == .begin) {
            // A submit typed before the Begin ack needs a fresh user action.
            return true;
        }
        if (self.local_editor.active) {
            if (key == .@"return") self.executeLocalCommand() else {
                const mapped: ?command_palette.Editor.Key = switch (key) {
                    .left => .left,
                    .right => .right,
                    .home => .home,
                    .end => .end,
                    .delete => .backspace,
                    .forward_delete => .delete,
                    .escape => .escape,
                    else => null,
                };
                if (mapped) |value| _ = self.local_editor.key(value);
                if (!self.local_editor.active and self.trusted_lease != 0) self.requestTrusted(.end, "") catch |err| surface.showError(err);
                self.renderLocalInput();
            }
            return true;
        }
        if (self.palette.isOpen()) {
            switch (self.palette.handleKey(self.cx.allocator, paletteKeyFrom(key, modifiers))) {
                .adopt => self.commitPaletteCommand(false),
                .execute => self.commitPaletteCommand(true),
                .close => {
                    self.closeCommandPalette();
                    self.requestTrusted(.end, "") catch |err| surface.showError(err);
                },
                .none => self.refreshCommandPaletteSelection(),
                .forward, .escape_at => return true,
            }
            return true;
        }
        if (self.handleCompletionKey(key, modifiers)) return true;
        if (key == .@"return" and surface.trusted_pending == null) if (self.trusted_snapshot) |snapshot| {
            if (snapshot.editable() and snapshot.buffer.len > 0) self.recordCompletionHistory(snapshot.buffer);
        };
        self.completion.dismiss();
        self.renderCompletion();
        return false;
    }

    fn serviceEditText(raw: *anyopaque, text: []const u8) bool {
        const self: *TerminalViewNode = @ptrCast(@alignCast(raw));
        const surface = self.terminal_surface orelse return false;
        if (self.trusted_action == .begin or self.trusted_execute) {
            if (text.len <= terminal_service.trusted_edit.max_buffer - self.trusted_draft.items.len) self.trusted_draft.appendSlice(self.cx.allocator, text) catch {} else surface.showError(error.InputQueueFull);
            return true;
        }
        if (self.local_editor.active) {
            _ = self.local_editor.insert(self.cx.allocator, text) catch false;
            self.renderLocalInput();
            return true;
        }
        if (self.palette.isOpen()) {
            if (self.palette.query.items.len == 0 and text.len > 0 and text[0] == '@') {
                self.closeCommandPalette();
                self.requestTrusted(.literal, "@") catch |err| {
                    surface.showError(err);
                    return true;
                };
                if (text.len > 1) surface.queueText(text[1..]) catch |err| surface.showError(err);
                return true;
            }
            switch (self.palette.handleChar(self.cx.allocator, text)) {
                .filtered => self.refreshCommandPaletteRows(),
                .escape_at => self.requestTrusted(.literal, "@") catch |err| surface.showError(err),
                .none => {},
            }
            return true;
        }
        if (std.mem.eql(u8, text, "@") and self.completionAllowed()) {
            const snapshot = self.trusted_snapshot.?;
            if (snapshot.buffer.len == 0 and self.trusted_literal_token != snapshot.token) {
                self.requestTrusted(.begin, "") catch |err| {
                    surface.showError(err);
                    return false;
                };
                return true;
            }
        }
        self.completion.dismiss();
        self.renderCompletion();
        return false;
    }

    /// SFTP can feed only paths actually observed, never screenshot samples.
    pub fn addCompletionPath(self: *TerminalViewNode, command: []const u8) !void {
        try self.completion.add(command, .path, 1, wallClockMs());
    }

    fn recordCompletionHistory(self: *TerminalViewNode, command: []const u8) void {
        for (self.completion.candidates.items) |*candidate| {
            if (candidate.source == .history and std.mem.eql(u8, candidate.text, command)) {
                candidate.frequency +|= 1;
                candidate.last_used_ms = wallClockMs();
                return;
            }
        }
        self.completion.add(command, .history, 1, wallClockMs()) catch {};
    }

    fn refreshCompletion(self: *TerminalViewNode) void {
        self.completion.enabled = self.completion_enabled;
        if (!self.completionAllowed()) {
            self.completion.dismiss();
        } else {
            const snapshot = self.trusted_snapshot.?;
            const suppressed = if (self.trusted_suppressed) |value| value.token == snapshot.token and value.revision == snapshot.revision else false;
            if (snapshot.buffer.len == 0 or suppressed) {
                self.completion.dismiss();
            } else {
                self.line.content.clearRetainingCapacity();
                self.line.content.appendSlice(self.cx.allocator, snapshot.buffer) catch return;
                self.line.unknown = false;
                self.completion_count = self.completion.historyMenu(snapshot.buffer, wallClockMs(), self.completion_matches[0..6]).len;
                self.completion.state.suggestion = null;
                self.completion.state.menu_open = self.completion_count != 0;
                self.completion_selected = @min(self.completion_selected, self.completion_count -| 1);
                self.rebuildCompletionRows() catch {};
            }
        }
        self.renderCompletion();
    }

    fn handleCompletionKey(self: *TerminalViewNode, key: ui.events.KeyCode, modifiers: ui.events.Modifiers) bool {
        if (!self.completionAllowed()) {
            self.completion.dismiss();
            return false;
        }
        if (key == .semicolon and ui.events.primaryModifier(modifiers) and !modifiers.shift and !modifiers.alt) {
            self.trusted_suppressed = null;
            self.completion_selected = 0;
            self.refreshCompletion();
            return true;
        }
        if (key == .tab) {
            if (self.trusted_snapshot) |snapshot| self.trusted_suppressed = .{ .token = snapshot.token, .revision = snapshot.revision };
            // Close local UI before shell changes the remote line.
            self.completion.dismiss();
            self.renderCompletion();
            return false;
        }
        if (modifiers.ctrl or modifiers.alt or modifiers.super or modifiers.shift) return false;
        if (key == .escape and (self.completion.state.menu_open or self.completion.state.suggestion != null)) {
            if (self.trusted_snapshot) |snapshot| self.trusted_suppressed = .{ .token = snapshot.token, .revision = snapshot.revision };
            self.completion.dismiss();
            self.renderCompletion();
            return true;
        }
        if (self.completion.state.menu_open) {
            if (key == .up or key == .down) {
                if (self.completion_count > 0) self.completion_selected = if (key == .up) self.completion_selected -| 1 else @min(self.completion_selected + 1, self.completion_count - 1);
                self.rebuildCompletionRows() catch {};
                ui.widgets.scrollRectIntoView(self.completion_scroll.state, self.completion_scroll.content, @as(f32, @floatFromInt(self.completion_selected)) * 29, 29, .nearest);
                return true;
            }
            if (key == .right) {
                if (self.completion_count > 0) self.acceptCompletion(self.completion_matches[self.completion_selected].candidate.text, false);
                return true;
            }
        }
        return false;
    }

    fn acceptCompletion(self: *TerminalViewNode, command: []const u8, _: bool) void {
        if (!self.completionAllowed()) return;
        const surface = self.terminal_surface orelse return;
        self.requestTrusted(.history, command) catch |err| surface.showError(err);
        self.completion.dismiss();
        self.renderCompletion();
    }

    fn rebuildCompletionRows(self: *TerminalViewNode) !void {
        const cx = self.cx;
        const c = app_theme.current();
        for (self.completion_rows.items) |node| {
            self.completion_scroll.content.removeChild(node);
            cx.destroyDetached(node);
        }
        self.completion_rows.clearRetainingCapacity();
        for (self.completion_matches[0..self.completion_count], 0..) |match, i| {
            const row = try ui.box(cx, .{ .height = .{ .px = 29 }, .width = .fill(), .direction = .row, .align_items = .center, .gap = 10, .padding = .{ .left = 14, .right = 14 }, .background = overlay_styles.rowBackground(i == self.completion_selected), .flex_shrink = 0, .overflow = .hidden }, .{});
            const label = try ui.text(cx, match.candidate.text, .{ .font_size = 12, .color = c.fg_1, .use_monospace_font = true, .wrap = .none });
            label.style.flex = 1;
            (try label.style.ensureExtFallible(cx.allocator)).min_width = 0;
            label.style.overflow = .hidden;
            var props = label.getText().?;
            const span = try cx.allocator.alloc(ui.types.TextSpan, 1);
            span[0] = .{ .start = @intCast(if (std.mem.startsWith(u8, match.candidate.text, self.line.content.items)) self.line.content.items.len else 0), .end = @intCast(match.candidate.text.len), .color = c.accent_ink, .font_weight = 700 };
            props.spans = span;
            props.spans_owned = true;
            label.setText(props);
            try row.appendChild(cx.allocator, label);
            const source = match.candidate.source;
            const badge = try ui.box(cx, .{ .padding = .{ .left = 7, .right = 7, .top = 2, .bottom = 2 }, .background = overlay_styles.badgeBackground(source), .border = .{ .radius = 4 }, .flex_shrink = 0 }, .{});
            try badge.appendChild(cx.allocator, try ui.text(cx, switch (source) {
                .history => "历史",
                .path => "路径缓存",
                .builtin => "内置",
            }, .{ .font_size = 9, .font_weight = 600, .color = overlay_styles.badgeForeground(source) }));
            try row.appendChild(cx.allocator, badge);
            if (source == .history) {
                var buf: [64]u8 = undefined;
                const minutes = @divTrunc(@max(0, wallClockMs() - match.candidate.last_used_ms), 60000);
                const freq = try std.fmt.bufPrint(&buf, "×{d} · {d}m前", .{ match.candidate.frequency, minutes });
                try row.appendChild(cx.allocator, try ui.text(cx, freq, .{ .font_size = 9.5, .color = c.fg_2, .use_monospace_font = true, .wrap = .none }));
            }
            row.behavior.events.on_event = completionPointer;
            row.behavior.events.event_context = @ptrCast(self);
            try self.completion_rows.append(cx.allocator, row);
            try self.completion_scroll.content.appendChild(cx.allocator, row);
        }
        self.completion_scroll.state.content_height = @as(f32, @floatFromInt(self.completion_count)) * 29;
        self.completion_scroll.state.external_content_height = true;
    }

    fn completionPointer(event: ui.events.Event, raw: ?*anyopaque) ui.events.EventResult {
        const self: *TerminalViewNode = @ptrCast(@alignCast(raw orelse return .ignored));
        if (event != .mouse_down or event.mouse_down.button != .left) return .ignored;
        for (self.completion_rows.items, 0..) |row, i| {
            const rect = row.rectFromWorldOrFallback();
            if (event.mouse_down.y >= rect.y and event.mouse_down.y < rect.y + rect.h) {
                self.completion_selected = i;
                self.acceptCompletion(self.completion_matches[i].candidate.text, false);
                return .handled;
            }
        }
        return .ignored;
    }

    fn renderCompletion(self: *TerminalViewNode) void {
        self.refreshOverlayTheme();
        if (!self.completionAllowed()) self.completion.dismiss();
        const root = self.root.globalRect();
        const content = if (self.terminal_surface) |surface| surface.root.globalRect() else self.rows_box.globalRect();
        const cursor_x = self.metrics.origin_x - root.x + @as(f32, @floatFromInt(self.frame_cursor.col)) * self.metrics.cell_width;
        const cursor_y = self.metrics.origin_y - root.y + @as(f32, @floatFromInt(self.frame_cursor.row)) * self.metrics.cell_height;
        if (self.completion.state.suggestion) |suffix| {
            const width = @max(0, content.x + content.w - root.x - cursor_x);
            if (width > 0 and self.preedit == null and self.frame_cursor.visible) {
                self.ghost_node.setTextContent(self.cx.allocator, suffix) catch {};
                if (self.ghost_node.getText()) |props| {
                    var next = props;
                    next.font_size = self.terminal_font_size;
                    next.line_height = self.terminal_line_height;
                    next.monospace_char_width = self.metrics.cell_width;
                    self.ghost_node.setText(next);
                }
                self.ghost_node.style.overflow = .hidden;
                placeOverlay(self.ghost_node, &self.ghost_cache, cursor_x, cursor_y, width, self.metrics.cell_height);
            } else hideOverlay(self.ghost_node, &self.ghost_cache);
        } else hideOverlay(self.ghost_node, &self.ghost_cache);
        if (!self.completion.state.menu_open or content.w <= 0 or content.h <= 0) {
            hideOverlay(self.completion_panel, &self.completion_cache);
            return;
        }
        const width = @min(@as(f32, 520), content.w);
        const height = @min(content.h, 64 + 29 * @as(f32, @floatFromInt(@min(@as(usize, 6), self.completion_count))));
        const rows_height = @max(0, height - 64);
        self.completion_scroll.container.style.height = .{ .px = rows_height };
        self.completion_scroll.state.viewport_height = rows_height;
        self.completion_scroll.container.markLayoutDirty();
        const left = content.x - root.x;
        const top = content.y - root.y;
        const x = std.math.clamp(cursor_x, left, left + content.w - width);
        var y = cursor_y + self.metrics.cell_height;
        if (y + height > top + content.h) y = cursor_y - height;
        y = std.math.clamp(y, top, top + content.h - height);
        const resized = !self.completion_cache.placed or self.completion_cache.w != width or self.completion_cache.h != height;
        placeOverlay(self.completion_panel, &self.completion_cache, x, y, width, height);
        if (resized) self.completion_panel.markLayoutDirty();
    }

    /// ── @ 命令面板：打开/关闭/刷新/定位 ─────────────────────────────
    fn openCommandPalette(self: *TerminalViewNode) void {
        self.completion.dismiss();
        self.renderCompletion();
        self.palette.open();
        self.refreshCommandPaletteRows();
        // 立即按当前光标行定位一次（FrameHook 每帧还会重锚定）。
        self.renderCommandPalette();
    }

    fn closeCommandPalette(self: *TerminalViewNode) void {
        self.palette.close();
        hideOverlay(self.palette_panel, &self.palette_cache);
        self.cx.requestRedraw();
    }

    /// 打开 / 过滤变化时重建匹配行；滚动由真实 ScrollArea 处理。removeChild 不释放
    /// 节点内存，须显式 freeNode；行文本是 catalog 静态串，重建成本为常数。
    fn refreshCommandPaletteRows(self: *TerminalViewNode) void {
        const cx = self.cx;
        for (self.palette_rows.items) |row| {
            self.palette_rows_box.removeChild(row);
            cx.freeNode(row);
        }
        self.palette_rows.clearRetainingCapacity();

        const window: command_palette.Palette.VisibleWindow = .{ .first = 0, .count = self.palette.matchCount(), .selected_offset = if (self.palette.matchCount() > 0) self.palette.selected else null };
        var index: usize = 0;
        while (index < window.count) : (index += 1) {
            const entry = self.palette.matchAt(window.first + index);
            const selected = (window.selected_offset orelse std.math.maxInt(usize)) == index;
            const row = makePaletteRow(cx, entry, selected) catch continue;
            self.palette_rows_box.appendChild(cx.allocator, row) catch {
                cx.freeNode(row);
                continue;
            };
            self.palette_rows.append(cx.allocator, row) catch break;
        }
        self.palette_scroll.state.content_height = @max(0, @as(f32, @floatFromInt(window.count)) * overlay_styles.catalogue_row_pitch - overlay_styles.catalogue_row_gap);
        ui.widgets.scroll_area.setScrollY(self.palette_scroll.state, self.palette_scroll.content, 0);
        self.palette_rendered = .{
            .first = window.first,
            .count = window.count,
            .selected_offset = window.selected_offset,
        };

        var buffer: [32]u8 = undefined;
        const label = if (self.palette.matchCount() > 0)
            std.fmt.bufPrint(&buffer, "共{d}项", .{self.palette.matchCount()}) catch ""
        else
            "无匹配";
        self.palette_count_text.setTextContent(cx.allocator, label) catch {};
        self.palette_count_text.markRenderDirty();
        if (self.palette_count_text.parent) |footer| {
            const keys = footer.children.items[footer.children.items.len - 1];
            keys.setTextContent(cx.allocator, if (window.count == 0) "Esc 关闭" else "↑↓ 选择 · → 采纳 · ↵ 执行 · Esc 关闭") catch {};
        }
        cx.requestRedraw();
    }

    /// ↑↓ 选中移动后的轻量刷新：窗口未变时仅 setBackground 重刷旧/新两行。
    fn refreshCommandPaletteSelection(self: *TerminalViewNode) void {
        const window: command_palette.Palette.VisibleWindow = .{ .first = 0, .count = self.palette.matchCount(), .selected_offset = if (self.palette.matchCount() > 0) self.palette.selected else null };
        if (self.palette_rendered.first == window.first and
            self.palette_rendered.count == window.count)
        {
            if (self.palette_rendered.selected_offset != window.selected_offset) {
                if (self.palette_rendered.selected_offset) |previous| {
                    if (previous < self.palette_rows.items.len) {
                        self.palette_rows.items[previous].setBackground(overlay_styles.rowBackground(false));
                        self.palette_rows.items[previous].markRenderDirty();
                    }
                }
                if (window.selected_offset) |current| {
                    if (current < self.palette_rows.items.len) {
                        self.palette_rows.items[current].setBackground(overlay_styles.rowBackground(true));
                        self.palette_rows.items[current].markRenderDirty();
                    }
                }
                self.palette_rendered.selected_offset = window.selected_offset;
                self.revealPaletteSelection();
                self.cx.requestRedraw();
            }
            return;
        }
        // 窗口滚动（选中行移出可视区）→ 整表重建。
        self.refreshCommandPaletteRows();
    }

    /// 每帧（FrameHook）重锚定：面板开着时挂在光标行下方（底部放不下则放
    /// 光标行上方），x 跟随 metrics.origin_x；几何脏检查跳过静止帧。
    fn renderCommandPalette(self: *TerminalViewNode) void {
        self.refreshOverlayTheme();
        if (!self.palette.isOpen()) {
            hideOverlay(self.palette_panel, &self.palette_cache);
            return;
        }
        const root_rect = self.root.globalRect();
        const content = if (self.terminal_surface) |surface| surface.root.globalRect() else self.rows_box.globalRect();
        // The design uses a 430px card on normal panes, but a split/narrow
        // pane can be smaller than that. Keep the floating card inside its
        // content viewport instead of letting the fixed width spill past the
        // pane edge (which also made the right side unclickable).
        if (content.w <= 0 or content.h <= 0) {
            hideOverlay(self.palette_panel, &self.palette_cache);
            return;
        }
        const panel_width = @min(palette_width, content.w);
        const rows: u32 = if (self.frame_rows > 0) self.frame_rows else 24;
        const cursor_row: u32 = @min(self.frame_cursor.row, rows - 1);
        const matching_height = @max(0, @as(f32, @floatFromInt(self.palette.matchCount())) * overlay_styles.catalogue_row_pitch - overlay_styles.catalogue_row_gap);
        const rows_height = @min(overlay_styles.catalogue_viewport_height, @min(matching_height, @max(0, content.h - overlay_styles.catalogue_chrome_height)));
        const panel_height = @min(content.h, overlay_styles.catalogue_chrome_height + rows_height);
        if (self.palette_scroll.state.viewport_height != rows_height) {
            self.palette_scroll.container.style.height = .{ .px = rows_height };
            self.palette_scroll.container.markLayoutDirty();
            self.palette_scroll.state.viewport_height = rows_height;
            self.revealPaletteSelection();
        }
        const cursor_y = self.metrics.origin_y - root_rect.y +
            @as(f32, @floatFromInt(cursor_row)) * self.metrics.cell_height;
        var y = cursor_y + self.metrics.cell_height;
        const content_bottom = content.y + content.h - root_rect.y;
        if (y + panel_height > content_bottom) y = cursor_y - panel_height;
        y = std.math.clamp(y, content.y - root_rect.y, content_bottom - panel_height);
        var x = self.metrics.origin_x - root_rect.x;
        const content_right = content.x + content.w - root_rect.x;
        if (x + panel_width > content_right) x = @max(0, content_right - panel_width);
        placeOverlay(self.palette_panel, &self.palette_cache, x, y, panel_width, panel_height);
    }

    fn revealPaletteSelection(self: *TerminalViewNode) void {
        ui.widgets.scrollRectIntoView(self.palette_scroll.state, self.palette_scroll.content, @as(f32, @floatFromInt(self.palette.selected)) * overlay_styles.catalogue_row_pitch, overlay_styles.catalogue_row_height, .nearest);
    }

    fn palettePointer(event: ui.events.Event, raw: ?*anyopaque) ui.events.EventResult {
        const self: *TerminalViewNode = @ptrCast(@alignCast(raw orelse return .ignored));
        if (event != .mouse_down or event.mouse_down.button != .left) return .ignored;
        const mouse = event.mouse_down;
        const rect = self.palette_scroll.container.globalRect();
        if (mouse.y < rect.y or mouse.y >= rect.y + rect.h or mouse.x < rect.x or mouse.x >= rect.x + rect.w - 12) return .ignored;
        const position = mouse.y - rect.y + self.palette_scroll.state.scroll_y;
        const index: usize = @intFromFloat(@max(0, @floor(position / overlay_styles.catalogue_row_pitch)));
        if (position - @as(f32, @floatFromInt(index)) * overlay_styles.catalogue_row_pitch >= overlay_styles.catalogue_row_height) return .stop;
        if (index >= self.palette.matchCount()) return .stop;
        self.palette.selected = index;
        _ = self.palette.handleKey(self.cx.allocator, .adopt);
        self.commitPaletteCommand(false);
        self.focus();
        return .stop;
    }

    /// 采纳（→）/执行（↵）面板当前选中命令。
    ///
    /// → 采纳到本地编辑器；↵ 校验并执行本地动作。不会发送远端 shell。
    fn commitPaletteCommand(self: *TerminalViewNode, executed: bool) void {
        const text = self.palette.adoptedText() orelse {
            self.closeCommandPalette();
            return;
        };
        self.local_editor.adopt(self.cx.allocator, text) catch return;
        applog.info(.ui, "@palette {s}: {s}", .{ if (executed) "execute" else "adopt", text });
        self.closeCommandPalette();
        if (executed) self.executeLocalCommand();
        self.renderLocalInput();
    }

    fn executeLocalCommand(self: *TerminalViewNode) void {
        if (self.local_editor.key(.execute) != .execute) return;
        if (self.terminal_surface) |surface| {
            const snapshot = self.trusted_snapshot orelse {
                surface.showError(error.StaleEdit);
                return;
            };
            if (self.trusted_lease == 0 or snapshot.lease != self.trusted_lease or !snapshot.editable() or self.trusted_action != null) {
                surface.showError(error.StaleEdit);
                return;
            }
            self.requestTrusted(.end, "") catch |err| {
                surface.showError(err);
                return;
            };
            self.trusted_execute = true;
            return;
        }
        self.executeLocalCommandChecked();
    }
    fn executeLocalCommandChecked(self: *TerminalViewNode) void {
        const parsed = builtin_commands.parse(self.local_editor.text.items);
        // Display-only commands are intrinsically session-local. @sync must
        // reach the workspace observer for frozen group approval. Other commands use the
        // existing workspace observer (which owns cross-session actions).
        if (switch (parsed) {
            .timestamp, .theme, .log => true,
            else => false,
        }) {
            _ = self.applyLocalCommand(parsed);
            self.local_editor.cancel();
            self.renderLocalInput();
            self.cx.requestRedraw();
            return;
        }
        const observer = self.palette_observer orelse return;
        observer.on_command(observer.context, self.local_editor.text.items, true);
        self.local_editor.cancel();
        self.renderLocalInput();
    }

    pub fn cancelLocalCommand(self: *TerminalViewNode) void {
        self.local_editor.cancel();
        self.closeCommandPalette();
        self.renderLocalInput();
    }

    fn renderLocalInput(self: *TerminalViewNode) void {
        if (!self.local_editor.active) {
            const visible = self.local_input_node.style.display != .none;
            hideOverlay(self.local_input_node, &self.local_input_cache);
            if (visible) {
                self.local_input_node.setDisplay(.none);
                self.cx.requestRedraw();
            }
            return;
        }
        const content_changed = if (self.local_input_node.getText()) |props| !std.mem.eql(u8, props.content, self.local_editor.text.items) else true;
        if (content_changed) self.local_input_node.setTextContent(self.cx.allocator, self.local_editor.text.items) catch return;
        const previous = self.local_input_cache;
        const root = self.root.globalRect();
        const x = self.metrics.origin_x - root.x + @as(f32, @floatFromInt(self.frame_cursor.col)) * self.metrics.cell_width;
        const y = self.metrics.origin_y - root.y + @as(f32, @floatFromInt(self.frame_cursor.row)) * self.metrics.cell_height;
        placeOverlay(self.local_input_node, &self.local_input_cache, x, y, @as(f32, @floatFromInt(displayCellWidth(self.local_editor.text.items))) * self.metrics.cell_width, self.metrics.cell_height);
        if (content_changed or !std.meta.eql(previous, self.local_input_cache)) self.cx.requestRedraw();
    }

    pub fn refreshTombstone(self: *TerminalViewNode) void {
        self.reconnect_button_visible = self.tombstone.canReconnect();
    }

    /// Begins the UI-side reconnect transition without rebuilding a SessionRuntime.
    /// The caller owns the actual transport reconstruction and must call restore()
    /// only after the new worker is ready.
    pub fn beginReconnect(self: *TerminalViewNode) bool {
        const started = self.tombstone.beginReconnect();
        self.refreshTombstone();
        return started;
    }

    pub fn reconnectLabel(self: *const TerminalViewNode) []const u8 {
        return self.tombstone.reconnectLabel();
    }

    pub fn focus(self: *TerminalViewNode) void {
        self.cx.setFocus(self.root);
    }

    /// Binds an existing domain service; process/VT ownership stays outside UI.
    pub fn bindTerminalService(self: *TerminalViewNode, service: terminal_service.Service) !void {
        if (self.terminal_surface) |surface| {
            if (surface.service.binding.eql(service.binding)) return;
            self.unbindTerminalService(surface.owner);
        }
        if (self.worker != null) return error.TerminalAlreadyBound;
        const surface = try TerminalSurface.create(self.cx, self.root, service, self.surfaceOptions());
        surface.menu_handler = self.terminal_menu_handler;
        surface.shell_observer = .{ .context = self, .accepted = serviceShellAccepted, .paste_stamp = servicePasteStamp };
        surface.enhancement = .{ .context = self, .key = serviceEditKey, .text = serviceEditText };
        self.terminal_surface = surface;
        if (self.terminal_theme) |theme| try surface.setTheme(theme);
        self.root.setStyle(self.cx.allocator, .padding, ui.Padding{});
        self.rows_box.setDisplay(.none);
        self.cursor_overlay.setDisplay(.none);
        for (self.selection_overlays) |node| node.setDisplay(.none);
        if (self.input_highlight_node) |node| node.setDisplay(.none);
        if (self.input_highlight_bar) |node| node.setDisplay(.none);
        surface.install();
        self.cx.requestRedraw();
    }
    fn serviceShellAccepted(raw: *anyopaque, owner: SessionHandle, event: u64, payload: @import("broadcast_event.zig").Payload) void {
        const self: *TerminalViewNode = @ptrCast(@alignCast(raw));
        if (self.input_observer) |observer| if (observer.on_service_input) |callback| callback(observer.context, owner, event, payload);
    }
    fn servicePasteStamp(raw: *anyopaque, owner: SessionHandle) u64 {
        const self: *TerminalViewNode = @ptrCast(@alignCast(raw));
        if (self.input_observer) |observer| if (observer.paste_stamp) |callback| return callback(observer.context, owner);
        return 0;
    }
    pub fn unbindTerminalService(self: *TerminalViewNode, expected_owner: SessionHandle) void {
        const surface = self.terminal_surface orelse return;
        if (!surface.owner.eql(expected_owner)) return;
        self.clearServiceSearch();
        self.search.setSource("") catch {};
        if (self.search_view) |*view| view.refresh();
        for (self.search_marks.items) |mark| mark.setDisplay(.none);
        if (self.error_hint) |hint| hint.resetFacts();
        self.clearTrustedSnapshot();
        self.trusted_action = null;
        self.trusted_lease = 0;
        self.trusted_execute = false;
        self.trusted_literal_token = 0;
        self.trusted_suppressed = null;
        self.trusted_draft.clearRetainingCapacity();
        self.closeCommandPalette();
        self.completion.dismiss();
        self.terminal_surface = null;
        surface.destroy();
        self.cx.requestRedraw();
    }
    /// The handler receives the clicked service owner and window coordinates;
    /// it never has to infer its execution target from the active tab.
    pub fn setTerminalMenuHandler(self: *TerminalViewNode, handler: ?TerminalSurface.MenuHandler) void {
        self.terminal_menu_handler = handler;
        if (self.terminal_surface) |surface| surface.menu_handler = handler;
    }
    /// The SSH host supplies this immutable UI owner; never borrow mutable
    /// worker/transport state or infer the owner from the active tab.
    pub fn setWorkerMenuHandler(self: *TerminalViewNode, owner: SessionHandle, handler: ?TerminalSurface.MenuHandler) void {
        self.worker_menu_owner = if (handler != null) owner else null;
        self.terminal_menu_handler = handler;
    }
    pub fn configureErrorHint(self: *TerminalViewNode, owner: SessionHandle, enabled: bool, handler: ?@import("../ai/command_error_hint.zig").Handler) !void {
        if (self.error_hint == null and handler != null) self.error_hint = try @import("command_error_hint_view.zig").View.create(self.cx, self.root);
        if (self.error_hint) |hint| {
            hint.configure(owner, enabled, handler);
            if (hint.model.baseline_pending) if (self.worker) |worker| try hint.model.primeSequence(owner, worker.semanticSequence());
        }
    }
    pub fn commandErrorHint(self: *const TerminalViewNode, owner: SessionHandle, command_id: u64) ?@import("../ai/command_error_hint.zig").Hint {
        return if (self.error_hint) |hint| hint.model.current(owner, command_id) else null;
    }
    pub fn refreshTerminalService(self: *TerminalViewNode, expected_owner: SessionHandle, active: bool) !bool {
        const surface = self.terminal_surface orelse return false;
        surface.configure(self.surfaceOptions());
        const changed = try surface.refresh(expected_owner, active);
        if (surface.snapshot) |snapshot| {
            self.frame_cols = snapshot.projection.cols;
            self.frame_rows = snapshot.projection.rows;
            self.frame_cursor = .{ .row = snapshot.projection.cursor.row, .col = snapshot.projection.cursor.col, .visible = snapshot.projection.cursor.visible and !snapshot.read_only };
            self.has_frame = true;
            const canvas = surface.root.globalRect();
            self.metrics.origin_x = canvas.x + @import("terminal_styles.zig").inset + surface.bodyX();
            self.metrics.origin_y = canvas.y + @import("terminal_styles.zig").inset;
            self.metrics.cell_width = surface.options.cell_width;
            self.metrics.cell_height = surface.options.row_height;
            self.updateGridStatus();
            if (self.error_hint) |hint| try hint.observe(snapshot.owner, &snapshot.projection);
        }
        self.refreshTrustedEdit();
        if (self.search_open) {
            self.refreshServiceSearch() catch |err| {
                if (err != error.WorkerBusy and err != error.StaleProjection) applog.warn(.ui, "terminal search: {s}", .{@errorName(err)});
            };
            if (self.search_view) |*view| view.fitPane(self.root.rectFromWorldOrFallback().w);
            try self.refreshSearchMarks();
        }
        return changed;
    }
    pub fn terminalSnapshot(self: *TerminalViewNode, expected_owner: SessionHandle) ?*const terminal_service.TerminalSnapshot {
        const surface = self.terminal_surface orelse return null;
        if (!surface.owner.eql(expected_owner)) return null;
        return if (surface.snapshot) |*snapshot| snapshot else null;
    }

    /// A receipt from this owner-bound displayed projection. Merely reading
    /// a worker counter, selecting a tab, or rebuilding nodes cannot clear it.
    pub fn notificationReadSequence(self: *TerminalViewNode, expected: SessionHandle) ?u64 {
        if (self.history.selected != null or !self.has_frame) return null;
        if (self.terminal_surface) |surface| {
            if (!surface.owner.eql(expected)) return null;
            const snapshot = surface.snapshot orelse return null;
            if (!snapshot.owner.eql(expected) or snapshot.output_sequence == 0) return null;
            const bar = snapshot.projection.scrollback;
            if (bar.viewport_offset +| bar.viewport_rows < bar.total_rows) return null;
            return snapshot.output_sequence;
        }
        const hook = self.frame_hook orelse return null;
        if (self.worker == null or self.worker.? != hook.worker or hook.thread.hasJoined() or hook.thread.isStopping()) return null;
        const published = (hook.worker.notificationPublication(expected) catch return null) orelse return null;
        const displayed = self.status_publication orelse return null;
        if (!published.at_tail or published.output_sequence == 0 or !displayed.owner.eql(expected) or displayed.revision != published.text_generation or hook.seen_generation.* != published.text_generation) return null;
        return published.output_sequence;
    }

    /// Read-only, owner-checked facts from the terminal's actual display
    /// publication. This neither allocates nor reads a socket/PTY/VT engine.
    pub fn statusSnapshot(self: *TerminalViewNode, expected: OperationKey) ?TerminalStatus.Snapshot {
        if (expected.owner != .session or self.history.selected != null) return null;
        if (self.terminal_surface) |surface| {
            if (!surface.owner.eql(expected.owner.session)) return null;
            const value = surface.snapshot orelse return null;
            if (!value.owner.eql(expected.owner.session) or value.read_only or value.eof_seen or value.projection.version == 0) return null;
            const result: TerminalStatus.Snapshot = .{ .owner = value.owner, .revision = value.geometry_revision, .cols = value.projection.cols, .rows = value.projection.rows, .encoding = if (std.unicode.utf8ValidateSlice(value.projection.graphemes)) .utf8 else .unknown };
            return if (result.accepts(expected)) result else null;
        }
        const hook = self.frame_hook orelse return null;
        if (self.worker == null or self.worker.? != hook.worker or hook.thread.hasFailed() or hook.thread.hasJoined() or hook.thread.isStopping() or !hook.worker.isAttached()) return null;
        const state = hook.thread.reconnectSnapshot() orelse return null;
        if (state.key == null or !state.key.?.eql(expected) or (state.phase != .active and state.phase != .ready) or state.failure != null) return null;
        const value = self.status_publication orelse return null;
        if (!value.accepts(expected) or !self.has_frame or value.revision != hook.seen_generation.* or value.cols != self.frame_cols or value.rows != self.frame_rows) return null;
        return value;
    }
    pub fn setTerminalTheme(self: *TerminalViewNode, theme: terminal_service.Theme) !void {
        if (theme.revision == 0) return error.InvalidTheme;
        if (self.terminal_theme) |previous| {
            if (theme.revision < previous.revision) return error.StaleTheme;
            if (theme.revision == previous.revision and !std.meta.eql(theme, previous)) return error.ConflictingTheme;
            // Appearance is reconciled after every layout. An already applied
            // theme must not request another frame and keep an idle shell busy.
            if (std.meta.eql(theme, previous)) {
                // The terminal palette may stay unchanged while application
                // overlays publish a new global theme or material opacity.
                self.refreshOverlayTheme();
                return;
            }
        }
        if (self.terminal_surface) |surface| try surface.setTheme(theme);
        self.terminal_theme = theme;
        self.refreshOverlayTheme();
        self.cx.requestRedraw();
    }
    pub fn pasteTerminalText(self: *TerminalViewNode, expected_owner: SessionHandle, bytes: []const u8) !void {
        const surface = self.terminal_surface orelse return error.NoTerminal;
        if (!surface.owner.eql(expected_owner)) return error.StaleOwner;
        try surface.requestPaste(bytes);
    }
    pub fn hasSelection(self: *const TerminalViewNode) bool {
        // An in-flight worker must not turn Cmd-C into a terminal signal or
        // right click into paste. Copy can report the transient busy result.
        if (self.terminal_surface) |surface| return surface.hasSelection() catch |err| {
            return err == error.WorkerBusy;
        };
        return self.selection.normalized() != null;
    }
    pub fn copySelectionText(self: *TerminalViewNode, allocator: std.mem.Allocator) !?[]u8 {
        if (self.terminal_surface) |surface| {
            return surface.copySelectionText(allocator);
        }
        const selection = self.selection.normalized() orelse return null;
        if (self.history.selected != null) return try self.copyHistorySelection(selection, allocator);
        const worker = self.worker orelse return null;
        return try worker.copySelection(selection, allocator);
    }
    pub fn requestPaste(self: *TerminalViewNode, bytes: []const u8) !void {
        if (self.terminal_surface) |surface| {
            // Menu/Cmd-V enters here before Surface's own input handler.
            // Keep rejection feedback on that same pane even when the caller
            // also reports the error through the legacy workspace status.
            surface.requestPaste(bytes) catch |err| {
                surface.showError(err);
                return err;
            };
            return;
        }
        if (self.history.selected != null or !self.tombstone.allowsRemoteInput()) return error.ReadOnlyTerminal;
        if (self.worker == null) return error.NoTerminal;
        if (self.paste_confirmation_pending or self.pending_paste != null) return error.PendingPaste;
        if (bytes.len == 0) return;
        const decision = self.paste_policy.inspect(bytes);
        if (decision == .reject) return if (decision.reject == .too_large) error.PasteTooLarge else error.InvalidPaste;
        if (self.local_editor.active or self.palette.isOpen()) {
            _ = pushText(self, bytes);
            return;
        }
        switch (decision) {
            .safe => try self.pushBytesToWorkerChecked(bytes, .paste),
            .confirm => {
                try self.stashPendingPaste(bytes);
                self.paste_confirmation_pending = true;
                self.cx.requestRedraw();
            },
            .reject => unreachable,
        }
    }
    /// A terminal gesture reads the SDK clipboard and retains this exact view.
    /// It never copies an existing selection or looks up a different active tab.
    pub fn pasteClipboard(self: *TerminalViewNode) !void {
        if (self.history.selected != null or !self.tombstone.allowsRemoteInput()) return error.ReadOnlyTerminal;
        if (self.worker == null and self.terminal_surface == null) return error.NoTerminal;
        const bytes = (try ui.platform_services.clipboardGetTextAllocChecked(self.cx.system_sdk, self.cx.allocator)) orelse return;
        defer self.cx.allocator.free(bytes);
        try self.requestPaste(bytes);
    }
    fn copyWorkerSelection(self: *TerminalViewNode) !void {
        const bytes = (try self.copySelectionText(self.cx.allocator)) orelse return;
        defer self.cx.allocator.free(bytes);
        const copied = bytes.len > 0 and self.copySelectionToClipboard(self.cx, bytes);
        if (@import("../platform/runtime_mode.zig").automation) std.debug.print("TERMINAL_POINTER_COPY {{\"node_id\":{d},\"bytes\":{d},\"sdk_present\":{},\"copied\":{}}}\n", .{ self.root.id, bytes.len, self.cx.system_sdk != null, copied });
        if (bytes.len == 0) return;
        if (!copied) return error.ClipboardUnavailable;
    }
    /// Opt-in native acceptance diagnostics contain geometry and lengths only.
    /// They never include terminal selection or system clipboard contents.
    fn traceWorkerPointer(self: *const TerminalViewNode, phase: []const u8, button: ui.events.MouseButton, x: f32, y: f32) void {
        if (!@import("../platform/runtime_mode.zig").automation) return;
        const point = self.metrics.pointAt(x, y);
        std.debug.print("TERMINAL_POINTER {{\"node_id\":{d},\"phase\":\"{s}\",\"button\":\"{s}\",\"x\":{d},\"y\":{d},\"row\":{d},\"col\":{d},\"origin_x\":{d},\"origin_y\":{d},\"cell_width\":{d},\"cell_height\":{d},\"dragging\":{},\"collapsed\":{}}}\n", .{ self.root.id, phase, @tagName(button), x, y, point.row, point.col, self.metrics.origin_x, self.metrics.origin_y, self.metrics.cell_width, self.metrics.cell_height, self.selection.dragging, self.selection.isCollapsed() });
    }
    fn clipboardError(self: *TerminalViewNode, err: anyerror) void {
        const message = switch (err) {
            error.ClipboardUnavailable, error.NotSupported => "复制或粘贴失败：剪贴板不可用",
            error.ReadOnlyTerminal => "当前终端只读，不能粘贴",
            error.PendingPaste => "请先确认或取消待发送的粘贴",
            error.PasteTooLarge => "粘贴超过 1 MiB 限制",
            error.InvalidPaste => "粘贴包含无效文本或终端控制序列",
            else => "复制或粘贴失败，请重试",
        };
        if (self.frame_hook) |hook| {
            hook.status.setTextContent(self.cx.allocator, message) catch {};
            hook.status.markRenderDirty();
        }
        applog.warn(.ui, "terminal clipboard: {s}", .{@errorName(err)});
        self.cx.requestRedraw();
    }
    pub fn insertLocalPaths(self: *TerminalViewNode, expected_owner: SessionHandle, paths: []const []const u8) !void {
        const surface = self.terminal_surface orelse return error.NoTerminal;
        if (!surface.owner.eql(expected_owner) or self.cx.focus_manager.getFocused() != self.root) return error.StaleOwner;
        const bytes = try @import("../local/path_input.zig").quotePaths(self.cx.allocator, paths);
        defer self.cx.allocator.free(bytes);
        try surface.requestPaste(bytes);
    }
    fn surfaceOptions(self: *TerminalViewNode) @import("terminal_surface.zig").Options {
        const background = self.root.getBackground();
        return .{ .font_size = self.terminal_font_size, .row_height = self.cell_height, .cell_width = self.cell_width, .family_id = self.terminal_font_family_id, .family_name = self.terminal_font_family orelse "system", .weight = self.terminal_font_weight, .foreground = self.base_fg, .background = if (background.a == 0) @import("app_theme.zig").current().terminal else background, .cursor = self.focus_border_color, .timestamps = self.local_state.timestamp_gutter, .highlight = self.input_line_highlight, .cursor_style = switch (self.cursor_style) {
            .block => .block,
            .bar => .bar,
            .underline => .underline,
        } };
    }

    /// Installs normal selection/search/Escape handling for an archive pane,
    /// with no SSH worker and no text-input client.
    pub fn bindArchived(self: *TerminalViewNode) void {
        self.tombstone.end("历史归档 · 只读");
        self.root.behavior.events.key_context = @ptrCast(self);
        self.root.behavior.events.event_context = @ptrCast(self);
        self.root.behavior.events.on_key_down = onWorkerKeyDown;
        self.root.behavior.events.on_event = onWorkerEvent;
    }

    pub fn bindWorker(self: *TerminalViewNode, worker: *Presentation) void {
        self.worker = worker;
        self.status_publication = null;
        self.status_operation = null;
        self.status_publication_cutoff = 0;
        // Connection established: wipe the "正在连接…" banner (and anything
        // else staged on the row pool). The first VT frame arrives within
        // milliseconds and repopulates the rows with real terminal content,
        // so clearing here cannot flash empty.
        for (&self.row_texts) |*text| {
            if (text.len > 0) self.cx.allocator.free(text.*);
            text.* = &[_]u8{};
        }
        for (self.row_nodes) |maybe| {
            if (maybe) |node| {
                node.setTextContent(self.cx.allocator, "") catch {};
                node.markRenderDirty();
            }
        }
        self.cx.requestRedraw();
        self.root.behavior.events.key_context = @ptrCast(self);
        self.root.behavior.events.event_context = @ptrCast(self);
        self.root.behavior.events.on_key_down = onWorkerKeyDown;
        self.root.behavior.events.on_event = onWorkerEvent;
        // Register as a text-input client so the platform IME gate opens and
        // character keystrokes arrive as .text_input events. The terminal is a
        // pass-through surface: empty buffer, empty selection.
        self.root.behavior.interaction.text_input_client = .{
            .context = @ptrCast(self),
            .text_len = textInputLen,
            .copy_text = textInputCopy,
            .selection = textInputSelection,
        };
    }

    fn textInputLen(raw: *anyopaque) usize {
        // The terminal document is the frame text plus any active preedit.
        // The caret sits at its end: this is the mapping IME candidate-window
        // positioning (firstRectForCharacterRange) uses, so it must track the
        // rendered content, not report a stub 0 (which pinned the candidate
        // window to the pane's top-left corner).
        const view: *TerminalViewNode = @ptrCast(@alignCast(raw));
        // Sum of rendered row content + newlines (the IME caret mapping).
        var total: usize = 0;
        for (view.row_texts, 0..) |text, i| {
            if (view.row_nodes[i] == null) break;
            total += text.len;
            if (i + 1 < max_grid_rows and view.row_nodes[i + 1] != null) total += 1;
        }
        if (view.preedit) |p| total += p.len;
        return total;
    }

    fn textInputCopy(_: *anyopaque, _: usize, out: []u8) usize {
        if (out.len > 0) out[0] = 0;
        return 0;
    }

    fn textInputSelection(raw: *anyopaque) ui.types.TextInputSelection {
        const len: u32 = @intCast(textInputLen(raw));
        return .{ .start = len, .end = len, .caret = len };
    }

    fn onWorkerEvent(event: ui.events.Event, context: ?*anyopaque) ui.events.EventResult {
        const raw = context orelse return .ignored;
        const view: *TerminalViewNode = @ptrCast(@alignCast(raw));
        switch (event) {
            .key_down, .key_up, .text_input, .ime_preedit, .ime_commit => if (view.cx.focus_manager.getFocused() != view.root) return .ignored,
            else => {},
        }
        switch (event) {
            .text_input => |input| {
                view.suppress_broadcast = view.text_input_modified;
                defer view.suppress_broadcast = false;
                return pushTextFrom(view, input.text, .ordinary);
            },
            .key_up => |key| {
                view.text_input_modified = key.modifiers.ctrl or key.modifiers.alt or key.modifiers.super or key.modifiers.shift;
                return .ignored;
            },
            .ime_preedit => |preedit| {
                view.setPreedit(preedit.text);
                return .handled;
            },
            .ime_commit => |commit| {
                view.clearPreedit();
                view.suppress_broadcast = view.text_input_modified;
                defer view.suppress_broadcast = false;
                return pushTextFrom(view, commit.text, .ordinary);
            },
            .mouse_down => |mouse| {
                view.traceWorkerPointer("down", mouse.button, mouse.x, mouse.y);
                if (mouse.button == .right) {
                    view.cx.setFocus(view.root);
                    view.pasteClipboard() catch |err| view.clipboardError(err);
                    return .handled;
                }
                if (mouse.button == .middle) {
                    const owner = view.worker_menu_owner orelse return .ignored;
                    const handler = view.terminal_menu_handler orelse return .ignored;
                    if (view.worker == null) return .ignored;
                    handler.request(handler.context, owner, mouse.x, mouse.y);
                    return .handled;
                }
                if (mouse.button != .left) return .ignored;
                // Terminal takes keyboard focus on click so keystrokes route here.
                view.cx.setFocus(view.root);
                view.selection.begin(view.metrics.pointAt(mouse.x, mouse.y));
                return .handled;
            },
            .mouse_move => |mouse| {
                if (view.selection.dragging) {
                    view.selection.update(view.metrics.pointAt(mouse.x, mouse.y));
                    return .handled;
                }
                return .ignored;
            },
            .mouse_up => |mouse| {
                view.traceWorkerPointer("up", mouse.button, mouse.x, mouse.y);
                if (mouse.button != .left) return .ignored;
                if (view.selection.dragging) {
                    view.selection.update(view.metrics.pointAt(mouse.x, mouse.y));
                    view.selection.endDrag();
                    // A click without a drag clears the selection instead of
                    // leaving an invisible zero-width highlight behind.
                    if (view.selection.isCollapsed()) {
                        view.selection.clear();
                    } else view.copyWorkerSelection() catch |err| view.clipboardError(err);
                }
                return .handled;
            },
            else => return .ignored,
        }
    }

    /// Menu/shortcut paste entry: same policy path as text_input (multiline
    /// pastes stage for confirmation instead of bypassing it).
    pub fn pushText(view: *TerminalViewNode, bytes: []const u8) ui.events.EventResult {
        return pushTextFrom(view, bytes, .paste);
    }

    fn pushTextFrom(view: *TerminalViewNode, bytes: []const u8, source: @import("../vt/reconnect_replay.zig").Source) ui.events.EventResult {
        if (view.terminal_surface) |surface| {
            surface.requestPaste(bytes) catch |err| surface.showError(err);
            return .stop;
        }
        if (view.history.selected != null) return .handled;
        if (bytes.len == 0) return .handled;
        // While a multiline paste awaits confirmation, keystrokes are modal
        // too — otherwise typed characters interleave with a not-yet-sent blob.
        if (view.paste_confirmation_pending) return .handled;
        if (view.local_editor.active) {
            _ = view.local_editor.insert(view.cx.allocator, bytes) catch false;
            view.renderLocalInput();
            return .handled;
        }

        // ── @ 命令面板 ──────────────────────────────────────────────
        // 面板打开时：可打印字符进入过滤串（不发送远端）；面板开着 + 空过滤
        // 串 + 单个 '@' 即 @@ 转义 → 发送字面 '@'；含控制字节的输入（多行
        // 粘贴、Esc 等）关闭面板并走下面的正常输入路径。
        if (view.palette.isOpen()) {
            if (containsControlByte(bytes)) {
                view.closeCommandPalette();
            } else switch (view.palette.handleChar(view.cx.allocator, bytes)) {
                .none => return .handled,
                .filtered => {
                    view.refreshCommandPaletteRows();
                    return .handled;
                },
                .escape_at => {
                    // @@ 转义：面板已关，发送字面 '@'（line buffer 随之非空，
                    // 行首触发失效，符合预期）。
                    view.pushBytesToWorker("@");
                    return .handled;
                },
            }
        } else if (bytes.len == 1 and bytes[0] == '@' and
            view.line.atLineStart() and view.worker != null and
            view.preedit == null and view.tombstone.allowsRemoteInput() and
            view.remote_input_context.prompt_editing and !view.remote_input_context.alternate_screen)
        {
            // 行首 '@'（line buffer 为空，见 LineTracker）：打开面板并吞掉该
            // 字符 —— 它不发送远端，直到采纳/执行/@@ 转义。
            view.openCommandPalette();
            return .handled;
        }
        // ────────────────────────────────────────────────────────────

        switch (view.paste_policy.inspect(bytes)) {
            .safe => view.pushBytesToWorkerFrom(bytes, source),
            .reject => applog.warn(.ui, "paste rejected by policy ({d} bytes)", .{bytes.len}),
            .confirm => {
                // Multiline paste: hold the payload and ask the user. Enter
                // sends it (pumped in queue-sized chunks), Escape drops it.
                view.stashPendingPaste(bytes) catch |err| {
                    view.clipboardError(err);
                    return .handled;
                };
                view.paste_confirmation_pending = true;
            },
        }
        return .handled;
    }

    fn stashPendingPaste(self: *TerminalViewNode, bytes: []const u8) !void {
        const owned = try self.cx.allocator.dupe(u8, bytes);
        self.clearPendingPaste();
        self.pending_paste = owned;
        self.pending_paste_offset = 0;
        self.pending_paste_broadcast = self.local_state.broadcast and !self.suppress_broadcast;
    }

    pub fn clearPendingPaste(self: *TerminalViewNode) void {
        if (self.pending_paste) |owned| self.cx.allocator.free(owned);
        self.pending_paste = null;
        self.pending_paste_offset = 0;
    }

    fn pushBytesToWorker(self: *TerminalViewNode, bytes: []const u8) void {
        self.pushBytesToWorkerFrom(bytes, .application);
    }

    fn pushBytesToWorkerFrom(self: *TerminalViewNode, bytes: []const u8, source: @import("../vt/reconnect_replay.zig").Source) void {
        self.pushBytesToWorkerChecked(bytes, source) catch |err| applog.warn(.ui, "input push failed ({d} bytes): {s}", .{ bytes.len, @errorName(err) });
    }
    fn pushBytesToWorkerChecked(self: *TerminalViewNode, bytes: []const u8, source: @import("../vt/reconnect_replay.zig").Source) !void {
        const worker = self.worker orelse return error.NoTerminal;
        if (self.history.selected != null) {
            worker.discardBufferedInput();
            return error.ReadOnlyTerminal;
        }
        if (!self.tombstone.allowsRemoteInput() and !(source == .ordinary and worker.allowsBufferedOrdinaryInput())) return error.ReadOnlyTerminal;
        try worker.pushInputFrom(bytes, source);
        // 行首 @ 触发的依据：所有成功发往远端的输入都喂给本地 line-buffer
        // 追踪（可打印字符累积、\r/杀行 ctrl 清空、历史回溯等置 unknown，
        // 见 command_palette.LineTracker）。
        // Record only known commands successfully queued for remote input.
        // Walk through compound completion + Return atomically as well.
        var start: usize = 0;
        for (bytes, 0..) |byte, index| {
            if (byte != '\r' and byte != '\n') continue;
            self.line.record(self.cx.allocator, bytes[start..index]);
            if (!self.line.unknown and self.line.content.items.len > 0) self.recordCompletionHistory(self.line.content.items);
            self.line.record(self.cx.allocator, bytes[index .. index + 1]);
            start = index + 1;
        }
        self.line.record(self.cx.allocator, bytes[start..]);
        self.refreshCompletion();
        if (self.local_state.allowsBroadcast(true, worker.reconnectState() == .connected, self.history.selected != null or !self.tombstone.allowsRemoteInput(), self.suppress_broadcast)) {
            if (self.input_observer) |observer| observer.on_input(observer.context, self, bytes);
        }
    }

    /// Recipient writes bypass local command parsing and observers. They may
    /// never buffer into a disconnected session or mutate a read-only replay.
    pub fn receiveBroadcast(self: *TerminalViewNode, bytes: []const u8) !void {
        if (self.history.selected != null or !self.tombstone.allowsRemoteInput()) return error.ReadOnlyTerminal;
        if (self.paste_confirmation_pending or self.pending_paste != null) return error.PendingPaste;
        const worker = self.worker orelse return error.NoTerminal;
        if (worker.reconnectState() != .connected) return error.DisconnectedTerminal;
        try worker.pushInputFrom(bytes, .broadcast);
        self.line.record(self.cx.allocator, bytes);
    }

    /// Drains a confirmed paste in input-queue-sized chunks. Called every frame
    /// so a 1 MiB paste flows as capacity frees instead of failing once.
    fn pumpPendingPaste(self: *TerminalViewNode) void {
        if (self.history.selected != null or self.paste_confirmation_pending) return;
        const pending = self.pending_paste orelse return;
        const worker = self.worker orelse return;
        if (!self.tombstone.allowsRemoteInput()) return;
        if (worker.reconnectState() != .connected) return;
        // Queue capacity can free without remote echo. Keep a bounded retry
        // while bytes remain instead of relying on the lifecycle fallback.
        defer if (self.pending_paste != null) self.cx.scheduleRedrawAfterNs(8 * std.time.ns_per_ms);
        const remaining = pending.len - self.pending_paste_offset;
        if (remaining == 0) {
            self.clearPendingPaste();
            return;
        }
        const free = worker.inputFreeCapacity();
        if (free == 0) return;
        const chunk = @min(free, remaining);
        const start = self.pending_paste_offset;
        worker.pushInputFrom(pending[start .. start + chunk], .paste) catch |err| {
            applog.warn(.ui, "paste chunk push failed: {s}", .{@errorName(err)});
            return;
        };
        // 确认后的粘贴分块不走 pushBytesToWorker，这里同样喂 line-buffer
        // 追踪（多行粘贴里的 \r 会按序清空行状态）。
        self.line.record(self.cx.allocator, pending[start .. start + chunk]);
        if (self.pending_paste_broadcast and self.local_state.broadcast) {
            if (self.input_observer) |observer| observer.on_input(observer.context, self, pending[start .. start + chunk]);
        }
        self.pending_paste_offset += chunk;
        if (self.pending_paste_offset >= pending.len) self.clearPendingPaste();
    }

    pub fn consumeWorkerText(self: *TerminalViewNode, cx: *ui.Cx, worker: *Presentation, seen_generation: *u64, scratch: []u8) !bool {
        const hook = self.frame_hook;
        const before = if (hook) |value| value.thread.reconnectSnapshot() else null;
        if (before) |state| if (!std.meta.eql(state.key, self.status_operation)) {
            // A reconnect retains the VT and TextSlot. Publications already
            // queued before this key was observed still belong to the old key.
            self.status_publication = null;
            self.status_operation = state.key;
            self.status_publication_cutoff = worker.textSlot().generation.load(.acquire);
            if (self.error_hint) |hint| hint.resetFacts();
        };
        const previous_generation = seen_generation.*;
        const changed = try self.consumeText(cx, worker.textSlot(), seen_generation, scratch);
        if (changed and seen_generation.* != previous_generation and seen_generation.* > self.status_publication_cutoff and self.history.selected == null) {
            if (hook) |value| if (value.worker == worker and self.worker == worker) {
                const after = value.thread.reconnectSnapshot() orelse return changed;
                if (before) |state| if (state.key != null and state.key.?.owner == .session and std.meta.eql(state.key, after.key) and (state.phase == .active or state.phase == .ready) and (after.phase == .active or after.phase == .ready) and after.failure == null) {
                    // consumeText already admitted these exact wire bytes.
                    if (text_frame.decode(scratch)) |frame| self.status_publication = .{ .owner = state.key.?.owner.session, .operation_key = state.key, .revision = seen_generation.*, .cols = frame.cols, .rows = frame.rows, .encoding = if (std.unicode.utf8ValidateSlice(frame.text)) .utf8 else .unknown, .frame_version = text_frame.frame_version };
                };
            };
        }
        if (self.history.selected == null) if (self.error_hint) |hint| if (hint.model.enabled and (hint.model.baseline_pending or worker.semanticSequence() > hint.model.seen_sequence)) {
            const expected = hint.model.owner orelse return changed;
            if (before) |state| if (self.worker != null and self.worker.? == worker and hook.?.worker == worker and !hook.?.thread.isStopping() and state.key != null and state.key.?.owner == .session and state.key.?.owner.session.eql(expected)) {
                var projection = try worker.copyProjection(cx.allocator);
                defer projection.deinit(cx.allocator);
                const after = hook.?.thread.reconnectSnapshot() orelse return changed;
                if (std.meta.eql(state.key, after.key)) try hint.observe(expected, &projection);
            };
        };
        return changed;
    }

    pub fn addWorkerFrameHook(self: *TerminalViewNode, cx: *ui.Cx, worker: *Presentation, thread: *Presentation, status: *ui.Node, seen_generation: *u64, scratch: []u8) !void {
        const hook = try cx.allocator.create(FrameHook);
        hook.* = .{ .view = self, .cx = cx, .worker = worker, .thread = thread, .status = status, .seen_generation = seen_generation, .scratch = scratch };
        try cx.addAfterLayoutHook(hook, FrameHook.run);
        // Deliberately NO scope registration: the hook's lifetime is owned by
        // this view (the tab), and removeFrameHook is its sole destroyer —
        // called by closeTab and by Workspace cleanup. A scope entry made the
        // destruction order depend on scope dispose ordering relative to the
        // tab free, which crashed both ways (freed view in hook cleanup /
        // freed hook via the view token).
        self.frame_hook = hook;
        self.status_operation = if (thread.reconnectSnapshot()) |state| state.key else null;
        self.status_publication = null;
        self.status_publication_cutoff = 0;
    }

    /// Detaches and frees the per-frame hook. The view (tab) owns the hook
    /// memory; safe because the caller keeps the tab alive. Idempotent.
    pub fn removeFrameHook(self: *TerminalViewNode, cx: *ui.Cx) void {
        const hook = self.frame_hook orelse return;
        self.frame_hook = null;
        self.status_publication = null;
        self.status_operation = null;
        cx.removeAfterLayoutHook(hook);
        cx.allocator.destroy(hook);
    }

    const FrameHook = struct {
        view: *TerminalViewNode,
        cx: *ui.Cx,
        worker: *Presentation,
        thread: *Presentation,
        status: *ui.Node,
        failed_shown: bool = false,
        paste_prompt_shown: bool = false,
        last_blink_ms: i64 = 0,
        seen_generation: *u64,
        scratch: []u8,
        // Smoothness diagnostics: hook cost + wall-clock gap between
        // consecutive runs, bucketed at 120Hz-vsync granularity. On a 120Hz
        // display, any gap > 8.3ms is a dropped vsync (visible jank that the
        // old >33ms threshold was blind to).
        perf_frames: u32 = 0,
        perf_hook_ns: u64 = 0,
        perf_gaps_9: u32 = 0,
        perf_gaps_17: u32 = 0,
        perf_gaps_25: u32 = 0,
        perf_gaps_34: u32 = 0,
        perf_max_gap: i64 = 0,
        perf_consumes: u32 = 0,
        perf_last_run_ms: i64 = 0,
        perf_last_log_ms: i64 = 0,

        fn run(ctx: *anyopaque, _: u8, _: bool) ui.AfterLayoutResult {
            const self: *FrameHook = @ptrCast(@alignCast(ctx));
            const view = self.view;
            const t0 = wallClockMs();

            // 1. Consume any freshly published frame. Text-side errors only
            //    stall the display for one frame; they must never be confused
            //    with connection failures.
            const consumed = view.consumeWorkerText(self.cx, self.worker, self.seen_generation, self.scratch) catch |err| blk: {
                applog.warn(.ui, "frame consume failed: {s}", .{@errorName(err)});
                break :blk false;
            };

            // 2. Session state transitions (unchanged policy).
            const connection = self.thread.reconnectSnapshot() orelse return .done;
            if (connection.phase == .ended and !self.failed_shown) {
                view.clearPendingPaste();
                view.paste_confirmation_pending = false;
                view.tombstone.end("远端 Shell 已退出");
                view.refreshTombstone();
                var message: [96]u8 = undefined;
                const label = if (connection.exit_code) |code|
                    std.fmt.bufPrint(&message, "远端 Shell 已退出 · exit {d} · 只读", .{code}) catch "远端 Shell 已退出 · 只读"
                else
                    "远端 Shell 已退出 · 退出码未知 · 只读";
                self.status.setTextContent(self.cx.allocator, label) catch {};
                self.status.markRenderDirty();
                self.failed_shown = true;
                self.cx.requestRedraw();
            }
            if (view.tombstone.state != .active and self.worker.reconnectState() == .connected and self.worker.isAttached()) {
                view.tombstone.restore();
                self.failed_shown = false;
                view.refreshTombstone();
                // 重连后的远端是全新 shell（空提示行）：本地行缓冲追踪同步
                // 清空，行首 '@' 触发保持有效。
                view.line.clearLine();
                self.status.setTextContent(self.cx.allocator, view.tombstone.banner()) catch {};
                self.status.markRenderDirty();
                self.cx.requestRedraw();
            }
            if (self.thread.hasFailed() and !self.failed_shown) {
                view.clearPendingPaste();
                view.paste_confirmation_pending = false;
                view.tombstone.end("worker failed");
                view.refreshTombstone();
                self.status.setTextContent(self.cx.allocator, view.tombstone.banner()) catch {};
                self.status.markRenderDirty();
                self.failed_shown = true;
                self.cx.requestRedraw();
            }

            // 3. Multiline-paste confirmation hint on the status line.
            if (view.paste_confirmation_pending != self.paste_prompt_shown) {
                self.paste_prompt_shown = view.paste_confirmation_pending;
                const hint: []const u8 = if (view.paste_confirmation_pending)
                    "多行粘贴待确认：Enter 发送 · Esc 取消"
                else
                    view.tombstone.banner();
                self.status.setTextContent(self.cx.allocator, hint) catch {};
                self.status.markRenderDirty();
                self.cx.requestRedraw();
            }

            // A read-only history view cannot carry unsent keys into a later
            // connection. Paste approvals were already revoked on loss.
            if (view.history.selected != null) self.worker.discardBufferedInput();
            // 4. Pump a confirmed paste in queue-sized chunks.
            view.pumpPendingPaste();

            // 5. Cursor blink on a wall clock — independent of VT output, so
            //    the cursor keeps blinking on an idle shell. New output snaps
            //    the cursor back on.
            const now_ms = wallClockMs();
            if (consumed) {
                view.cursor_visible = true;
                self.last_blink_ms = now_ms;
            } else if (now_ms - self.last_blink_ms >= blink_interval_ms) {
                self.last_blink_ms = now_ms;
                view.cursor_visible = !view.cursor_visible;
            }

            // 6. Focus border + overlays follow layout every frame; PTY/grid
            //    size tracks the content rect.
            view.updateMetrics();
            if (view.search_open) {
                if (view.search_view) |*search_view| search_view.fitPane(view.root.rectFromWorldOrFallback().w);
                view.refreshSearchMarks() catch {};
            }
            view.syncGridSize();
            view.updateFocusBorder();
            view.renderOverlays();
            // 7. Status-bar grid label (dirty-checked).
            view.updateGridStatus();
            // 8. @ 命令面板：开着时按光标行重锚定（几何脏检查跳过静止帧；
            //    行内容刷新是事件驱动的，不走这里）。
            view.renderCommandPalette();
            view.renderCompletion();

            // Diagnostics: hook cost + inter-run gap histogram at 120Hz
            // granularity. Gaps 9-17ms = 1 dropped 120Hz vsync; 17-25 = 2;
            // 25-34 = 3; >34 = catastrophic. Old >33ms-only counter was
            // blind to all of these on a ProMotion display.
            if (self.perf_last_run_ms != 0) {
                const gap = t0 - self.perf_last_run_ms;
                if (gap > 34) {
                    self.perf_gaps_34 += 1;
                } else if (gap > 25) {
                    self.perf_gaps_25 += 1;
                } else if (gap > 17) {
                    self.perf_gaps_17 += 1;
                } else if (gap > 9) {
                    self.perf_gaps_9 += 1;
                }
                if (gap > self.perf_max_gap) self.perf_max_gap = gap;
            }
            self.perf_last_run_ms = t0;
            if (consumed) self.perf_consumes += 1;
            self.perf_hook_ns +%= @as(u64, @intCast(wallClockMs() - t0)) * std.time.ns_per_ms;
            self.perf_frames += 1;
            if (t0 - self.perf_last_log_ms >= 2000) {
                if (self.perf_last_log_ms != 0) {
                    std.log.debug("[ui-perf] frames={d} consumes={d} hook_us={d} gaps[9/17/25/34+]={d}/{d}/{d}/{d} max={d}ms", .{
                        self.perf_frames,
                        self.perf_consumes,
                        self.perf_hook_ns / @as(u64, self.perf_frames) / 1000,
                        self.perf_gaps_9,
                        self.perf_gaps_17,
                        self.perf_gaps_25,
                        self.perf_gaps_34,
                        self.perf_max_gap,
                    });
                }
                self.perf_frames = 0;
                self.perf_consumes = 0;
                self.perf_hook_ns = 0;
                self.perf_gaps_9 = 0;
                self.perf_gaps_17 = 0;
                self.perf_gaps_25 = 0;
                self.perf_gaps_34 = 0;
                self.perf_max_gap = 0;
                self.perf_last_log_ms = t0;
            }

            // Output publications wake the main loop. This is only a lifecycle,
            // reconnect and cursor fallback, not the terminal frame clock.
            self.cx.scheduleRedrawAfterNs(250 * std.time.ns_per_ms);
            return .done;
        }
    };

    fn onWorkerKeyDown(key: ui.events.KeyCode, modifiers: ui.events.Modifiers, context: ?*anyopaque) ui.events.EventResult {
        const raw = context orelse return .ignored;
        const view: *TerminalViewNode = @ptrCast(@alignCast(raw));
        if (view.cx.focus_manager.getFocused() != view.root) return .ignored;
        if (view.history.selected != null and key == .escape) {
            view.closeHistory();
            return .handled;
        }
        // History replay is intentionally read-only, but selection and Cmd+C
        // remain available. Handle copy before the no-worker early return.
        if (view.history.selected != null and key == .c and ui.events.primaryModifier(modifiers)) {
            if (view.selection.normalized()) |selection| {
                if (view.copyHistorySelection(selection, view.cx.allocator)) |text| {
                    defer view.cx.allocator.free(text);
                    _ = view.copySelectionToClipboard(view.cx, text);
                } else |err| {
                    applog.warn(.ui, "history copySelection failed: {s}", .{@errorName(err)});
                }
            }
            return .handled;
        }
        if (view.worker == null) {
            if (key == .f and ui.events.primaryModifier(modifiers)) view.openSearch();
            return .handled;
        }
        const worker = view.worker.?;
        view.text_input_modified = modifiers.ctrl or modifiers.alt or modifiers.super or modifiers.shift;
        view.suppress_broadcast = modifiers.ctrl or modifiers.alt or modifiers.super or modifiers.shift;
        defer view.suppress_broadcast = false;

        // IME composition owns the keyboard: Return commits a candidate and
        // Escape cancels — forwarding those bytes to the remote here would
        // interleave stray \r/\x1b with the committed Chinese text.
        if (view.history.selected != null and key == .escape) {
            view.closeHistory();
            return .handled;
        }
        if (view.history.selected != null) return .handled;
        if (view.preedit != null) return .handled;
        if (view.local_editor.active) {
            if (key == .@"return") {
                view.executeLocalCommand();
            } else {
                const editor_key: ?command_palette.Editor.Key = switch (key) {
                    .left => .left,
                    .right => .right,
                    .home => .home,
                    .end => .end,
                    .delete => .backspace,
                    .forward_delete => .delete,
                    .escape => .escape,
                    else => null,
                };
                if (editor_key) |input| _ = view.local_editor.key(input);
                view.renderLocalInput();
            }
            return .handled;
        }

        // Pending multiline paste is modal: Enter confirms, Escape cancels.
        if (view.paste_confirmation_pending) {
            switch (key) {
                .@"return" => view.paste_confirmation_pending = false, // pump starts next frame
                .escape => {
                    view.paste_confirmation_pending = false;
                    view.clearPendingPaste();
                },
                else => {},
            }
            return .handled;
        }

        if (view.handleCompletionKey(key, modifiers)) return .handled;

        // @ 命令面板优先接管导航键（↑↓/→/↵/Esc/Backspace，裸键）；
        // .forward（Tab/←/翻页/修饰组合…）继续走下面的终端正常路径。
        if (view.palette.isOpen()) {
            const palette_key = paletteKeyFrom(key, modifiers);
            const result = view.palette.handleKey(view.cx.allocator, palette_key);
            if (result != .forward) {
                switch (result) {
                    // 键盘路径不产生 escape_at（@@ 转义来自 text_input）；防御
                    // 性按字面 '@' 发送，与 handleChar 的语义一致。
                    .escape_at => view.pushBytesToWorker("@"),
                    .adopt => view.commitPaletteCommand(false),
                    .execute => view.commitPaletteCommand(true),
                    .close => view.closeCommandPalette(),
                    .none => view.refreshCommandPaletteSelection(),
                    .forward => unreachable,
                }
                return .handled;
            }
        }

        if (key == .c and ui.events.primaryModifier(modifiers)) {
            if (view.selection.normalized()) |selection| {
                if (worker.copySelection(selection, view.cx.allocator)) |text| {
                    defer view.cx.allocator.free(text);
                    _ = view.copySelectionToClipboard(view.cx, text);
                } else |err| {
                    applog.warn(.ui, "copySelection failed: {s}", .{@errorName(err)});
                }
            }
            return .handled;
        }

        if (modifiers.ctrl and !modifiers.super) {
            if (controlByteForKey(key)) |byte| {
                view.pushBytesToWorkerFrom(&.{byte}, .ordinary);
                return .handled;
            }
        }

        if (!view.tombstone.allowsRemoteInput() and !worker.allowsBufferedOrdinaryInput()) return .handled;
        // No .space case: space is delivered as text_input, and handling it
        // here too would send it twice.
        const bytes: []const u8 = switch (key) {
            .escape => "\x1b",
            .tab => "\t",
            .@"return" => "\r",
            .delete => "\x7f",
            .forward_delete => "\x1b[3~",
            .home => "\x1b[H",
            .end => "\x1b[F",
            .page_up => "\x1b[5~",
            .page_down => "\x1b[6~",
            .left => "\x1b[D",
            .right => "\x1b[C",
            .up => "\x1b[A",
            .down => "\x1b[B",
            else => return .ignored,
        };
        view.pushBytesToWorkerFrom(bytes, .ordinary);
        return .handled;
    }

    /// Copy already-extracted VT selection text through Zenit native clipboard service.
    /// ZeroWork does not own or bridge AppKit clipboard APIs.
    pub fn copySelectionToClipboard(_: *TerminalViewNode, cx: *ui.Cx, text: []const u8) bool {
        return ui.platform_services.clipboardSetText(cx.system_sdk, text);
    }

    pub const ExportKind = enum { selection, retained_session };

    /// true means saved; false means the native dialog was cancelled. Missing
    /// selection/SDK and write failures remain errors, never false success.
    pub fn exportText(self: *TerminalViewNode, cx: *ui.Cx, io: std.Io, kind: ExportKind) !bool {
        const sdk = cx.system_sdk orelse return error.NotSupported;
        const worker = self.worker orelse return error.NoTerminal;
        const text = switch (kind) {
            .selection => try worker.copySelection(self.selection.normalized() orelse return error.NoSelection, cx.allocator),
            .retained_session => try worker.searchText(cx.allocator),
        };
        defer cx.allocator.free(text);
        var path_buffer: [4096]u8 = undefined;
        const path = (try sdk.runDialog(.{
            .kind = .save_file,
            .title = if (kind == .selection) "terminal-selection.txt" else "terminal-session.txt",
        }, &path_buffer)) orelse return false;
        try @import("terminal_export.zig").writeSnapshot(io, .cwd(), path, text);
        return true;
    }

    /// Plain text without frame metadata: connection banner, tombstone notes.
    /// Lands on row 0 of the row pool (frames will overwrite it once data
    /// arrives).
    pub fn setOutput(self: *TerminalViewNode, cx: *ui.Cx, content: []const u8) !void {
        const node = self.ensureRowNode(cx, 0) catch return;
        try node.setTextContent(cx.allocator, content);
        node.markRenderDirty();
        // Sync the dirty-check cache: without this, consumeText's first
        // frame with an empty line 0 matches the stale cache ("") and skips
        // the update — the banner stays on screen after clear.
        if (self.row_texts[0].len > 0) cx.allocator.free(self.row_texts[0]);
        self.row_texts[0] = cx.allocator.dupe(u8, content) catch &[_]u8{};
    }

    /// Recomputes the cell grid origin from the output node's world rect.
    /// Cell size is the MEASURED monospace advance / row pitch — not a
    /// rect-division approximation — so overlay geometry matches glyph
    /// positions exactly.
    fn updateMetrics(self: *TerminalViewNode) void {
        // Native mouse coordinates are window-global. World layout stores a
        // parent-local rect, so accumulate the pane/sidebar/tab offsets once.
        const rect = self.rows_box.globalRect();
        if (rect.w <= 0 or rect.h <= 0) return;
        self.metrics = .{
            .origin_x = rect.x,
            .origin_y = rect.y,
            .cell_width = self.cell_width,
            .cell_height = self.cell_height,
            .cols = if (self.frame_cols > 0) self.frame_cols else 80,
        };
        if (@import("../platform/runtime_mode.zig").automation and (self.pointer_trace_metrics == null or !std.meta.eql(self.pointer_trace_metrics.?, self.metrics))) {
            self.pointer_trace_metrics = self.metrics;
            std.debug.print("TERMINAL_POINTER_METRICS {{\"node_id\":{d},\"origin_x\":{d},\"origin_y\":{d},\"cell_width\":{d},\"cell_height\":{d},\"cols\":{d}}}\n", .{ self.root.id, self.metrics.origin_x, self.metrics.origin_y, self.metrics.cell_width, self.metrics.cell_height, self.metrics.cols });
        }
    }

    /// Keeps the remote PTY and local VT grid in sync with the on-screen
    /// content area. Called every frame; only acts when the cell-fit dims
    /// actually changed. The first frame immediately grows the 80×24 default.
    fn syncGridSize(self: *TerminalViewNode) void {
        const worker = self.worker orelse return;
        if (!self.has_frame) return;
        const rect = self.rows_box.rectFromWorldOrFallback();
        if (rect.w <= 0 or rect.h <= 0) return;
        const target_cols: u16 = @intFromFloat(std.math.clamp(@floor(rect.w / self.cell_width), 2, 500));
        const target_rows: u16 = @intFromFloat(std.math.clamp(@floor(rect.h / self.cell_height), 2, 300));
        if (target_cols == self.frame_cols and target_rows == self.frame_rows) return;
        if (worker.reconnectState() != .connected) return;
        worker.requestResize(target_cols, target_rows);
    }

    /// Borderless terminal: no focus-border updates (user rejected the
    /// frame; tab highlighting carries the focus signal).
    fn updateFocusBorder(self: *TerminalViewNode) void {
        _ = self;
    }

    fn renderOverlays(self: *TerminalViewNode) void {
        self.renderInputLineHighlight();
        self.renderSelectionOverlays();
        self.renderCursorOverlay();
    }

    fn renderCursorOverlay(self: *TerminalViewNode) void {
        if (self.terminal_surface != null) {
            self.cursor_overlay.setDisplay(.none);
            return;
        }
        const rows: u32 = if (self.frame_rows > 0) self.frame_rows else 24;
        const cols: u32 = if (self.frame_cols > 0) self.frame_cols else 80;
        const cursor = self.frame_cursor;
        if (!self.has_frame or !cursor.visible or cursor.row >= rows or cursor.col > cols) {
            hideOverlay(self.cursor_overlay, &self.cursor_cache);
            return;
        }
        const focused = self.cx.focus_manager.getFocused();
        const has_focus = focused != null and focused.? == self.root;
        // Blink only while focused; a dim static block marks the typing
        // position when focus is elsewhere.
        if (has_focus and !self.cursor_visible) {
            hideOverlay(self.cursor_overlay, &self.cursor_cache);
            return;
        }
        const root_rect = self.root.globalRect();
        var x = self.metrics.origin_x - root_rect.x + @as(f32, @floatFromInt(cursor.col)) * self.metrics.cell_width;
        var y = self.metrics.origin_y - root_rect.y + @as(f32, @floatFromInt(cursor.row)) * self.metrics.cell_height;
        // During IME composition the block cursor sits after the preedit run.
        if (self.preedit) |composition| {
            x += @as(f32, @floatFromInt(displayCellWidth(composition))) * self.metrics.cell_width;
        }
        var width = self.metrics.cell_width;
        var height = self.metrics.cell_height;
        switch (self.cursor_style) {
            .block => {},
            .bar => width = @min(width, 2),
            .underline => {
                height = @min(height, 2);
                y += self.metrics.cell_height - height;
            },
        }
        placeOverlay(self.cursor_overlay, &self.cursor_cache, x, y, width, height);
    }

    fn renderSelectionOverlays(self: *TerminalViewNode) void {
        const selection = self.selection.normalized() orelse {
            for (self.selection_overlays, 0..) |node, index| hideOverlay(node, &self.selection_caches[index]);
            return;
        };
        const rows: u32 = if (self.frame_rows > 0) self.frame_rows else 24;
        const cols: u32 = if (self.frame_cols > 0) self.frame_cols else 80;
        const last_row: u32 = @min(@as(u32, @intCast(@min(selection.end_row, @as(u64, rows - 1)))), rows - 1);
        const start_row: u32 = @intCast(@min(selection.start_row, @as(u64, rows - 1)));
        const root_rect = self.root.globalRect();

        var used: usize = 0;
        var row = start_row;
        while (row <= last_row) : (row += 1) {
            const col_start: u32 = if (row == start_row) @min(@as(u32, selection.start_col), cols) else 0;
            const col_end: u32 = if (row == last_row) @min(@as(u32, selection.end_col), cols) else cols;
            if (col_end <= col_start) continue;
            if (used == self.selection_overlays.len) break; // long selections clip visually
            const x = self.metrics.origin_x - root_rect.x + @as(f32, @floatFromInt(col_start)) * self.metrics.cell_width;
            const y = self.metrics.origin_y - root_rect.y + @as(f32, @floatFromInt(row)) * self.metrics.cell_height;
            const w = @as(f32, @floatFromInt(col_end - col_start)) * self.metrics.cell_width;
            placeOverlay(self.selection_overlays[used], &self.selection_caches[used], x, y, w, self.metrics.cell_height);
            used += 1;
        }
        for (self.selection_overlays[used..], used..) |node, index| hideOverlay(node, &self.selection_caches[index]);
    }

    /// Renders the current terminal view: frame baseline (text + spans) with
    /// any active IME preedit appended at the caret, underlined. Always
    /// rebuilt from the baselines — never from the output node — so repeated
    /// composition edits cannot double-append.
    fn setPreedit(self: *TerminalViewNode, text: []const u8) void {
        self.freePreedit(self.cx);
        if (text.len > 0) {
            self.preedit = self.cx.allocator.dupe(u8, text) catch null;
        }
        self.refreshCursorRow();
    }
    fn clearPreedit(self: *TerminalViewNode) void {
        if (self.preedit == null) return;
        self.freePreedit(self.cx);
        self.refreshCursorRow();
    }
    fn freePreedit(self: *TerminalViewNode, cx: *ui.Cx) void {
        if (self.preedit) |owned| cx.allocator.free(owned);
        self.preedit = null;
    }

    /// Rewrites the cursor row node with cached base + preedit. Called when
    /// preedit starts/changes/ends and the row pool already has content.
    fn refreshCursorRow(self: *TerminalViewNode) void {
        const cx = self.cx;
        const cursor_row: usize = @intCast(@min(self.frame_cursor.row, max_grid_rows - 1));
        const node = self.row_nodes[cursor_row] orelse return;
        var props = node.getText() orelse return;
        const base = self.row_texts[cursor_row];
        const preedit = self.preedit orelse "";
        if (preedit.len > 0) {
            const combined = cx.allocator.alloc(u8, base.len + preedit.len) catch return;
            defer cx.allocator.free(combined);
            @memcpy(combined[0..base.len], base);
            @memcpy(combined[base.len..], preedit);
            props.setContent(cx.allocator, combined) catch return;
            if (props.spans_owned) cx.allocator.free(props.spans);
            var spans: std.ArrayList(ui.types.TextSpan) = .empty;
            defer spans.deinit(cx.allocator);
            spans.append(cx.allocator, .{
                .start = @intCast(base.len),
                .end = @intCast(base.len + preedit.len),
                .underline = true,
            }) catch return;
            props.spans = spans.toOwnedSlice(cx.allocator) catch return;
            props.spans_owned = true;
        } else {
            props.setContent(cx.allocator, base) catch return;
            if (props.spans_owned) cx.allocator.free(props.spans);
            props.spans = &.{};
            props.spans_owned = false;
        }
        node.setText(props);
        node.markRenderDirty();
        cx.requestRedraw();
    }
    /// Releases view-owned frame buffers (tab teardown).
    pub fn releaseBuffers(self: *TerminalViewNode, cx: *ui.Cx) void {
        if (self.error_hint) |hint| hint.destroy();
        self.error_hint = null;
        if (self.terminal_surface) |surface| self.unbindTerminalService(surface.owner);
        self.clearPreedit();
        if (self.terminal_font_family) |family| cx.allocator.free(family);
        self.terminal_font_family = null;
        for (&self.row_texts, &self.row_span_sets) |*text, *spans| {
            if (text.len > 0) cx.allocator.free(text.*);
            text.* = &[_]u8{};
            if (spans.len > 0) cx.allocator.free(spans.*);
            spans.* = &.{};
        }
        // @ 命令面板：状态机缓冲 + 动态行节点（卡片本体随 tab 节点树销毁）。
        self.palette.close();
        self.palette.deinit(cx.allocator);
        self.trusted_draft.deinit(cx.allocator);
        self.clearTrustedSnapshot();
        self.completion.deinit();
        for (self.completion_rows.items) |node| {
            self.completion_scroll.content.removeChild(node);
            cx.destroyDetached(node);
        }
        self.completion_rows.deinit(cx.allocator);
        self.completion_scope.dispose();
        self.local_editor.deinit(cx.allocator);
        self.line.deinit(cx.allocator);
        // Detach while the Input's event contexts are still alive: clearing
        // focused search must finish blur before its scope releases them.
        if (self.search_view) |view| {
            if (view.root.parent) |parent| cx.detachChild(parent, view.root);
        }
        if (self.search_scope) |scope| {
            if (!scope.disposed) scope.dispose();
            self.search_scope = null;
        }
        if (self.search_view) |view| {
            cx.destroyDetached(view.root);
            self.search_view = null;
        }
        self.search.deinit();
        self.history.deinit();
        self.history_search_wire.deinit(cx.allocator);
        self.search_marks.deinit(cx.allocator);
        for (self.palette_rows.items) |row| {
            self.palette_rows_box.removeChild(row);
            cx.freeNode(row);
        }
        self.palette_rows.deinit(cx.allocator);
        self.palette_scope.dispose();
    }
    /// Consume an owned UTF-8 frame published by the worker. The frame header
    /// carries the real VT cursor and grid; ANSI styles decode into text
    /// spans so colors/bold render through the theme base style.
    /// Consume an owned UTF-8 frame published by the worker. Ghostty-style
    /// damage tracking: the frame text is split into grid lines and each row
    /// is compared against its cached content — identical rows are skipped
    /// entirely (no setText, no shape, no layout), so the per-update cost is
    /// proportional to actual changes instead of the full viewport.
    pub fn consumeText(
        self: *TerminalViewNode,
        cx: *ui.Cx,
        text_slot: *TextSlot,
        seen_generation: *u64,
        scratch: []u8,
    ) !bool {
        const payload = try text_slot.take(seen_generation.*, scratch) orelse return false;
        seen_generation.* = payload.generation;
        const frame = text_frame.decode(payload.text) orelse {
            applog.warn(.ui, "terminal frame decode failed: {d} bytes", .{payload.text.len});
            return false;
        };
        try self.history.append(wallClockMs(), payload.text);
        if (self.history.selected != null) return false;
        return self.renderFrame(cx, frame);
    }

    fn renderFrame(self: *TerminalViewNode, cx: *ui.Cx, frame: text_frame.Frame) !bool {
        self.frame_cursor = frame.cursor;
        if (self.history.selected != null) self.frame_cursor.visible = false;
        self.frame_cols = frame.cols;
        self.frame_rows = frame.rows;
        self.has_frame = true;
        if (self.search_open and self.history.selected == null) {
            if (self.worker) |w| {
                if (w.searchText(cx.allocator)) |all| {
                    defer cx.allocator.free(all);
                    self.search.setSource(all) catch {};
                    if (self.search_view) |*view| view.refresh();
                    self.refreshSearchMarks() catch {};
                } else |_| {}
            }
        }

        const preedit_text = self.preedit orelse "";
        const cursor_row: usize = @intCast(@min(frame.cursor.row, max_grid_rows - 1));

        var line_iter = std.mem.splitScalar(u8, frame.text, '\n');
        var row: usize = 0;
        var line_start: u32 = 0;
        while (line_iter.next()) |line| : (row += 1) {
            if (row >= max_grid_rows) break;
            const line_len: u32 = @intCast(line.len);
            const line_end = line_start + line_len;
            const has_preedit = preedit_text.len > 0 and row == cursor_row;

            // Damage check: identical content + no preedit change = skip
            // the WRITE — but the placeholder node must still exist. A null
            // node here (first consume of an EMPTY grid line: cache "" ==
            // line "") previously skipped creation entirely, so the column
            // layout compacted subsequent rows upward and desynced visual
            // positions from VT row numbers (cursor drawn a row below the
            // prompt). The empty node costs one fixed-height box.
            if (!has_preedit and std.mem.eql(u8, self.row_texts[row], line)) {
                _ = try self.ensureRowNode(cx, row);
                if (self.row_nodes[row]) |node| {
                    if (node.style.display == .none) node.setDisplay(.flex);
                }
                line_start = line_end + 1;
                continue;
            }

            const node = try self.ensureRowNode(cx, row);
            var props = node.getText() orelse return false;

            if (has_preedit) {
                // Cursor row: base line + underlined preedit.
                const combined = try cx.allocator.alloc(u8, line.len + preedit_text.len);
                defer cx.allocator.free(combined);
                @memcpy(combined[0..line.len], line);
                @memcpy(combined[line.len..], preedit_text);
                try props.setContent(cx.allocator, combined);
            } else {
                try props.setContent(cx.allocator, line);
            }

            // Per-row spans: filter frame spans to this line's byte range and
            // rebase offsets, then add CJK padding via buildUiSpans.
            if (props.spans_owned) cx.allocator.free(props.spans);
            props.spans = self.buildRowSpans(cx, frame.spans, line_start, line_end, line, has_preedit, line_len) catch &.{};
            props.spans_owned = true;

            node.setText(props);
            node.markRenderDirty();
            if (node.style.display == .none) node.setDisplay(.flex);

            // Cache the BASE content (preedit excluded) for the next diff.
            if (self.row_texts[row].len > 0) cx.allocator.free(self.row_texts[row]);
            self.row_texts[row] = cx.allocator.dupe(u8, line) catch &[_]u8{};

            line_start = line_end + 1; // skip '\n'
        }

        // Hide rows beyond the grid height (PTY resize shrunk it).
        for (row..max_grid_rows) |i| {
            if (self.row_nodes[i]) |node| {
                if (node.style.display != .none) node.setDisplay(.none);
            }
        }
        cx.requestRedraw();
        return true;
    }

    /// Builds the span array for one grid row: frame spans intersecting the
    /// row's byte range are rebased to row-local offsets, wide chars get
    /// padding segments, and an active preedit adds an underline run.
    fn buildRowSpans(
        self: *TerminalViewNode,
        cx: *ui.Cx,
        wire: []const text_frame.WireSpan,
        line_start: u32,
        line_end: u32,
        line: []const u8,
        has_preedit: bool,
        base_len: u32,
    ) ![]ui.types.TextSpan {
        // 1. Collect wire spans clipped to this line, rebased to row-local.
        var local: std.ArrayList(text_frame.WireSpan) = .empty;
        defer local.deinit(cx.allocator);
        for (wire) |span| {
            const s = @max(span.start, line_start);
            const e = @min(span.end, line_end);
            if (e > s) {
                try local.append(cx.allocator, .{
                    .start = s - line_start,
                    .end = e - line_start,
                    .color = span.color,
                    .bg = span.bg,
                    .flags = span.flags,
                });
            }
        }
        // 2. Convert to UI spans with CJK padding on the row-local text.
        const spans = try buildUiSpans(cx.allocator, local.items, line, self.cell_width, self.terminal_font_size);
        for (spans) |*span| if (span.font_weight != null) {
            span.font_weight = boldWeight(self.terminal_font_weight);
        };
        if (!has_preedit) return spans;
        // 3. Append the preedit underline run.
        var with_preedit: std.ArrayList(ui.types.TextSpan) = .empty;
        errdefer with_preedit.deinit(cx.allocator);
        try with_preedit.appendSlice(cx.allocator, spans);
        cx.allocator.free(spans);
        try with_preedit.append(cx.allocator, .{
            .start = base_len,
            .end = @intCast(line.len),
            .underline = true,
        });
        return with_preedit.toOwnedSlice(cx.allocator);
    }
};

test {
    _ = @import("terminal_surface_tests.zig");
}

fn packedToColor(packed_rgba: u32) ui.Color {
    return .{
        .r = @truncate(packed_rgba >> 24),
        .g = @truncate(packed_rgba >> 16),
        .b = @truncate(packed_rgba >> 8),
        .a = @truncate(packed_rgba),
    };
}

/// Wire spans → Zenit TextSpans. Packed 0xRRGGBBAA; "default" sentinels map
/// to null (inherit the theme base style). Offsets clamp to the text length.
///
/// CJK width alignment: the VT grid stores a wide char as 2 cells, but the
/// CJK glyph renders through the fallback font at ~font_size advance — short
/// of the 2-cell width. Without correction everything after a CJK char shifts
/// left while the cursor (positioned in VT columns) stays put: the pre-fix
/// "cursor misplaced after Chinese input". Each wide codepoint becomes its
/// own segment carrying inline_box_padding_right = 2×cell − font_size,
/// restoring per-cell advance semantics. Segments split at wire-span edges
/// and wide-char edges so spans never overlap.
fn buildUiSpans(allocator: std.mem.Allocator, wire: []const text_frame.WireSpan, text: []const u8, cell_width: f32, font_size: f32) ![]ui.types.TextSpan {
    const styled_projection = @import("../vt/text_projection_styled.zig");
    const pad = @max(0, cell_width * 2 - font_size);
    var spans: std.ArrayList(ui.types.TextSpan) = .empty;
    errdefer spans.deinit(allocator);
    const limit: u32 = @intCast(text.len);

    var wire_index: usize = 0;
    var pos: u32 = 0;
    while (pos < limit) {
        // Segment end candidates: current wire-span boundary, then the next
        // codepoint boundary (a wide char gets its own segment).
        var seg_end: u32 = limit;
        if (wire_index < wire.len) {
            const w_start = @min(wire[wire_index].start, limit);
            if (pos < w_start) {
                seg_end = w_start;
            } else {
                seg_end = @min(wire[wire_index].end, limit);
            }
        }
        const cp_len: u32 = @intCast(std.unicode.utf8ByteSequenceLength(text[pos]) catch 1);
        const next_cp: u32 = @min(limit, pos + cp_len);
        if (next_cp < seg_end) seg_end = next_cp;

        const is_wide = blk: {
            if (pos + cp_len > text.len) break :blk false;
            const cp = std.unicode.utf8Decode(text[pos .. pos + cp_len]) catch break :blk false;
            break :blk isWideCodepoint(cp);
        };

        var span = ui.types.TextSpan{ .start = pos, .end = seg_end };
        var styled = false;
        if (wire_index < wire.len and wire[wire_index].start <= pos and pos < wire[wire_index].end) {
            const w = wire[wire_index];
            if (!styled_projection.isDefaultColor(w.color)) {
                span.color = packedToColor(w.color);
                styled = true;
            }
            if (!styled_projection.isDefaultColor(w.bg)) {
                span.bg_color = packedToColor(w.bg);
                styled = true;
            }
            if (w.bold()) {
                span.font_weight = 700;
                styled = true;
            }
            if (w.italic()) {
                span.use_italic_font = true;
                styled = true;
            }
            if (w.underline()) {
                span.underline = true;
                styled = true;
            }
        }
        if (is_wide and pad > 0) {
            span.inline_box_padding_right = pad;
            styled = true;
        }
        if (styled and spans.items.len < 512) {
            try spans.append(allocator, span);
        }
        pos = seg_end;
        while (wire_index < wire.len and wire[wire_index].end <= pos) wire_index += 1;
    }
    return spans.toOwnedSlice(allocator);
}

fn placeOverlay(node: *ui.Node, cache: *OverlayCache, x: f32, y: f32, w: f32, h: f32) void {
    // Dirty check: idle frames hit this with identical geometry 60×/s; the
    // writes below invalidate render caches, so skip when unchanged.
    if (cache.placed and
        @abs(cache.x - x) < 0.01 and @abs(cache.y - y) < 0.01 and
        @abs(cache.w - w) < 0.01 and @abs(cache.h - h) < 0.01) return;
    cache.* = .{ .placed = true, .x = x, .y = y, .w = w, .h = h };
    // Absolute-positioned with inset 0: translate is the cheapest way to move
    // it and needs no layout pass (same pattern as the devtools overlay).
    node.setDisplay(.flex);
    node.setTranslateX(x);
    node.style.translate_y = y;
    node.style.width = .{ .px = @max(w, 1) };
    node.style.height = .{ .px = @max(h, 1) };
    node.markCompositePropDirty();
    node.markRenderDirty();
}

fn hideOverlay(node: *ui.Node, cache: *OverlayCache) void {
    if (!cache.placed) return; // already hidden
    cache.placed = false;
    node.setDisplay(.none);
}

/// Ctrl+letter → C0 control byte (letter & 0x1F). macOS never routes these
/// through text_input, so key_down is their only delivery path.
fn controlByteForKey(key: ui.events.KeyCode) ?u8 {
    return switch (key) {
        .a => 0x01,
        .b => 0x02,
        .c => 0x03,
        .d => 0x04,
        .e => 0x05,
        .f => 0x06,
        .g => 0x07,
        .h => 0x08,
        .i => 0x09,
        .j => 0x0a,
        .k => 0x0b,
        .l => 0x0c,
        .m => 0x0d,
        .n => 0x0e,
        .o => 0x0f,
        .p => 0x10,
        .q => 0x11,
        .r => 0x12,
        .s => 0x13,
        .t => 0x14,
        .u => 0x15,
        .v => 0x16,
        .w => 0x17,
        .x => 0x18,
        .y => 0x19,
        .z => 0x1a,
        else => null,
    };
}

/// text_input 里是否夹带控制字节（回车/Esc/ctrl）：夹带 → 面板模式终止，
/// 输入走正常终端路径（多行粘贴、带控制符的剪贴板内容等）。
fn containsControlByte(bytes: []const u8) bool {
    for (bytes) |byte| {
        if (byte < 0x20 or byte == 0x7f) return true;
    }
    return false;
}

/// ui.events.KeyCode → 面板键（裸方向/回车/Esc/退格）。带修饰键的组合
/// （⌘/⌃/⌥/⇧）一律 .other → .forward，保持终端语义（复制、跳词等）。
fn paletteKeyFrom(key: ui.events.KeyCode, modifiers: ui.events.Modifiers) command_palette.Key {
    if (modifiers.shift or modifiers.ctrl or modifiers.alt or modifiers.super) return .other;
    return switch (key) {
        .up => .up,
        .down => .down,
        .right => .adopt,
        .@"return" => .execute,
        .escape => .escape,
        .delete => .backspace,
        else => .other,
    };
}

/// Terminal display width of a UTF-8 string in cells: CJK/fullwidth
/// codepoints occupy 2 columns, everything else 1. Used for preedit caret
/// positioning (pinyin candidates are often already Chinese).
fn displayCellWidth(text: []const u8) usize {
    var width: usize = 0;
    var index: usize = 0;
    while (index < text.len) {
        const len = std.unicode.utf8ByteSequenceLength(text[index]) catch {
            index += 1;
            width += 1;
            continue;
        };
        if (index + len > text.len) break;
        const cp = std.unicode.utf8Decode(text[index .. index + len]) catch {
            index += len;
            width += 1;
            continue;
        };
        width += if (isWideCodepoint(cp)) 2 else 1;
        index += len;
    }
    return width;
}

fn isWideCodepoint(cp: u21) bool {
    return (cp >= 0x1100 and cp <= 0x115F) or // Hangul Jamo
        (cp >= 0x2E80 and cp <= 0x9FFF) or // CJK radicals .. CJK
        (cp >= 0xAC00 and cp <= 0xD7AF) or // Hangul syllables
        (cp >= 0xF900 and cp <= 0xFAFF) or // CJK compat ideographs
        (cp >= 0xFE30 and cp <= 0xFE4F) or // CJK compat forms
        (cp >= 0xFF00 and cp <= 0xFF60) or // fullwidth forms
        (cp >= 0xFFE0 and cp <= 0xFFE6) or
        (cp >= 0x20000 and cp <= 0x2FFFD) or // CJK ext
        (cp >= 0x30000 and cp <= 0x3FFFD);
}

/// Formats a selection from a retained text frame using terminal cell
/// coordinates. Frame text is row-delimited UTF-8; this keeps copy semantics
/// consistent for archived/read-only tabs without requiring a worker engine.
fn extractFrameSelection(frame: text_frame.Frame, selection: @import("../vt/engine.zig").Selection, allocator: std.mem.Allocator) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    const start_row = @min(selection.start_row, @as(u64, frame.rows) -| 1);
    const end_row = @min(selection.end_row, @as(u64, frame.rows) -| 1);
    var it = std.mem.splitScalar(u8, frame.text, '\n');
    var row: u64 = 0;
    while (it.next()) |line| : (row += 1) {
        if (row < start_row) continue;
        if (row > end_row) break;
        const first: u16 = if (row == start_row) @min(selection.start_col, frame.cols) else 0;
        const last: u16 = if (row == end_row) @min(selection.end_col, frame.cols) else frame.cols;
        var col: u16 = 0;
        var index: usize = 0;
        var line_out_start = out.items.len;
        while (index < line.len and col < last) {
            const byte_len = std.unicode.utf8ByteSequenceLength(line[index]) catch 1;
            const end = @min(index + byte_len, line.len);
            const cp = std.unicode.utf8Decode(line[index..end]) catch @as(u21, line[index]);
            const width: u16 = if (isWideCodepoint(cp)) @as(u16, 2) else @as(u16, 1);
            if (col + width > first and col < last) try out.appendSlice(allocator, line[index..end]);
            col +|= width;
            index = end;
        }
        // Match terminal copy behavior: trim padding spaces at each row.
        while (out.items.len > line_out_start and out.items[out.items.len - 1] == ' ') out.items.len -= 1;
        if (row != end_row) try out.append(allocator, '\n');
        _ = &line_out_start;
    }
    return out.toOwnedSlice(allocator);
}

test "terminal tombstone reconnect transition hides reconnect action" {
    // Keep this contract test independent of Zenit allocation: the state owner is
    // the tombstone, while the node simply mirrors its visibility decision.
    var tombstone: @import("session_tombstone.zig").Tombstone = .{};
    tombstone.end("worker failed");
    try std.testing.expect(tombstone.canReconnect());
    try std.testing.expect(tombstone.beginReconnect());
    try std.testing.expect(!tombstone.canReconnect());
    try std.testing.expectEqualStrings("Reconnecting…", tombstone.reconnectLabel());
}

test "control byte mapping covers Ctrl+C as SIGINT and Ctrl+U as line kill" {
    try std.testing.expectEqual(@as(?u8, 0x03), controlByteForKey(.c));
    try std.testing.expectEqual(@as(?u8, 0x15), controlByteForKey(.u));
    try std.testing.expectEqual(@as(?u8, 0x1a), controlByteForKey(.z));
    try std.testing.expectEqual(@as(?u8, null), controlByteForKey(.up));
    try std.testing.expectEqual(@as(?u8, null), controlByteForKey(.@"return"));
}

test "archived frame selection extracts UTF-8 rows by terminal cells" {
    const frame: text_frame.Frame = .{ .cursor = .{}, .cols = 12, .rows = 2, .text = "ab你\nsecond   ", .spans = &.{} };
    const copied = try extractFrameSelection(frame, .{ .start_row = 0, .start_col = 1, .end_row = 1, .end_col = 5 }, std.testing.allocator);
    defer std.testing.allocator.free(copied);
    try std.testing.expectEqualStrings("b你\nsecon", copied);
}

const terminal_text =
    "ZeroWork terminal\n\n" ++
    "  Connected  ⬡  Direct\n" ++
    "  r97n0  ·  root  ·  xterm-256color\n\n" ++
    "  $ printf zerowork-session-ready\n" ++
    "  zerowork-session-ready\n\n" ++
    "  Session is ready. Type a command to begin.";

test "Figma command catalogue mounts exact card rows and viewport" {
    const cx = try ui.Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(1000, 700);
    const scope = try ui.Scope.init(cx.allocator, null, cx.owner);
    defer scope.dispose();
    var view = try TerminalViewNode.mount(cx);
    cx.root = view.root;
    defer view.releaseBuffers(cx);
    try view.attachSearch(scope);
    _ = cx.render();
    view.updateMetrics();
    view.openCommandPalette();
    for (0..4) |_| {
        cx.frame_count += 1;
        cx.frame_time_ms += 16;
        _ = cx.render();
    }
    const card = view.palette_panel.globalRect();
    try std.testing.expectApproxEqAbs(@as(f32, 430), card.w, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 276), card.h, 0.01);
    try std.testing.expectEqual(@as(f32, 14), view.palette_panel.style.border.radius);
    const header = view.palette_panel.children.items[0].globalRect();
    const header_icon = view.palette_panel.children.items[0].children.items[0];
    try std.testing.expectEqual(app_theme.current().accent, if (header_icon.getIcon()) |value| value.tint else header_icon.getImage().?.tint);
    try std.testing.expectApproxEqAbs(card.x + 12, header.x, 0.01);
    try std.testing.expectApproxEqAbs(card.y + 12, header.y, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 24), header.h, 0.01);
    const viewport = view.palette_scroll.container.globalRect();
    try std.testing.expectApproxEqAbs(card.x + 12, viewport.x, 0.01);
    try std.testing.expectApproxEqAbs(card.y + 42, viewport.y, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 406), viewport.w, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 200), viewport.h, 0.01);
    try std.testing.expectEqual(@as(usize, 14), view.palette_rows.items.len);
    const first = view.palette_rows.items[0].globalRect();
    const second = view.palette_rows.items[1].globalRect();
    try std.testing.expectApproxEqAbs(@as(f32, 400), first.w, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 30), first.h, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 34), second.y - first.y, 0.01);
    const footer = view.palette_panel.children.items[2].globalRect();
    try std.testing.expectApproxEqAbs(card.y + 248, footer.y, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 16), footer.h, 0.01);
    const count = view.palette_count_text;
    const count_props = count.getText().?;
    try std.testing.expectEqualStrings("共14项", count_props.content);
    try std.testing.expectEqual(@as(f32, 0), count.style.flex_shrink);
    const count_width = cx.text.measureTextWidth(count_props.content, count_props.font_size, count_props.font_weight, false);
    try std.testing.expect(count.globalRect().w + 0.01 >= count_width);
    try std.testing.expect(count.globalRect().x + count.globalRect().w <= footer.x + footer.w);
    // A tiny fit/paint rounding difference must not replace this short count
    // with ellipsis. Inspect the emitted rendering content, not just props.
    count.setStyleInline(cx.allocator, .{ .width = .{ .px = @max(1, count_width - 1) } });
    cx.advanceFrameClock();
    _ = cx.render();
    var rendered_full_count = false;
    for (cx.display_list.items.items) |item| switch (item) {
        .text_run => |run| if (std.mem.eql(u8, run.content, "共14项")) {
            rendered_full_count = true;
        },
        else => {},
    };
    try std.testing.expect(rendered_full_count);
    try std.testing.expectEqual(ui.types.TextOverflow.clip, count.getText().?.text_overflow);
    try std.testing.expectEqual(ui.types.Overflow.visible, count.style.overflow);
    count.setStyleInline(cx.allocator, .{ .width = .{ .fit = .{} } });
    cx.advanceFrameClock();
    _ = cx.render();
    const row = view.palette_rows.items[0];
    const icon = row.children.items[0].globalRect();
    const name = row.children.items[1].globalRect();
    const description = row.children.items[2].globalRect();
    try std.testing.expectApproxEqAbs(first.x, icon.x, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 14), icon.w, 0.01);
    try std.testing.expectApproxEqAbs(first.x + 20, name.x, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 58), name.w, 0.01);
    try std.testing.expectApproxEqAbs(first.x + 84, description.x, 0.01);
    try std.testing.expectEqual(@as(f32, 10.5), row.children.items[1].getText().?.font_size);
    try std.testing.expectEqual(@as(f32, 10.5), row.children.items[2].getText().?.font_size);
    // Four-pixel row gaps do not select a neighboring command. A real click
    // on the following row still adopts its captured catalog entry locally.
    cx.handleMouseDown(first.x + 10, first.y + 31, .{});
    cx.handleMouseUp(first.x + 10, first.y + 31);
    try std.testing.expect(view.palette.isOpen());
    cx.handleMouseDown(second.x + 10, second.y + 15, .{});
    cx.handleMouseUp(second.x + 10, second.y + 15);
    try std.testing.expect(!view.palette.isOpen());
    try std.testing.expect(view.local_editor.active);
    try std.testing.expectEqualStrings("@dl", view.local_editor.text.items);
}

test "command card keeps all matches scrollable and fits short pane" {
    const cx = try ui.Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(320, 220);
    var view = try TerminalViewNode.mount(cx);
    cx.root = view.root;
    defer view.releaseBuffers(cx);
    _ = cx.render();
    view.updateMetrics();
    view.palette.open();
    view.refreshCommandPaletteRows();
    view.renderCommandPalette();
    _ = cx.render();
    try std.testing.expectEqual(view.palette.matchCount(), view.palette_rows.items.len);
    try std.testing.expect(view.palette_scroll.state.maxScrollY() > 0);
    const card = view.palette_panel.globalRect();
    // Narrow panes clamp the design card to the available content width;
    // normal panes retain the 430px reference width.
    try std.testing.expect(card.w > 0 and card.w <= palette_width);
    const content = view.rows_box.globalRect();
    try std.testing.expect(card.x >= content.x - 0.5);
    try std.testing.expect(card.y >= content.y - 0.5);
    try std.testing.expect(card.x + card.w <= content.x + content.w + 0.5);
    try std.testing.expect(card.y + card.h <= content.y + content.h + 0.5);
    view.palette.selected = view.palette.matchCount() - 1;
    view.refreshCommandPaletteSelection();
    try std.testing.expect(view.palette_scroll.state.scroll_y > 0);
    _ = view.palette.handleKey(cx.allocator, .escape);
    view.renderCommandPalette();
    try std.testing.expect(!view.palette_cache.placed);
}

test "terminal overlay global command paint follows hidden and visible publication without replacing rows" {
    const theme = @import("app_theme.zig");
    const old_name = theme.currentName();
    const old_material = theme.materialVisible();
    defer {
        theme.select(old_name);
        _ = theme.setMaterialVisible(old_material);
    }
    theme.select(.dark);
    _ = theme.setMaterialVisible(false);
    const cx = try ui.Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(800, 450);
    var view = try TerminalViewNode.mount(cx);
    defer view.releaseBuffers(cx);
    cx.root = view.root;
    _ = cx.render();
    view.updateMetrics();
    view.openCommandPalette();
    view.palette.selected = view.palette.matchCount() - 1;
    view.refreshCommandPaletteSelection();
    const selected = view.palette.selected;
    const row = view.palette_rows.items[selected];
    const first = view.palette_rows.items[0];
    const row_id = row.id;
    const scroll_y = view.palette_scroll.state.scroll_y;
    cx.setFocus(view.root);
    const focus = cx.focus_manager.getFocused();
    // These are retained nodes, including the closed palette's current rows.
    view.palette_panel.setDisplay(.none);
    theme.select(.light);
    view.setThemeColors(theme.current().fg_1, theme.current().border, theme.current().accent);
    const header_icon = view.palette_panel.children.items[0].children.items[0];
    try std.testing.expectEqual(theme.current().accent, if (header_icon.getIcon()) |value| value.tint else header_icon.getImage().?.tint);
    try std.testing.expectEqual(theme.current().fg_1, row.children.items[2].getText().?.color);
    try std.testing.expectEqual(theme.current().accent_ink, row.children.items[1].getText().?.color);
    try std.testing.expectEqual(theme.current().fg_2, view.palette_count_text.getText().?.color);
    try std.testing.expectEqual(theme.current().overlay, view.palette_panel.getBackground());
    try std.testing.expectEqual(ui.Color.TRANSPARENT, first.getBackground());
    try std.testing.expectEqual(theme.current().selection, row.getBackground());
    try std.testing.expect(view.palette_panel.style.display == .none);
    view.renderCommandPalette();
    const geometry = view.palette_cache;
    theme.select(.sauber);
    _ = theme.setMaterialVisible(true);
    view.setThemeColors(theme.current().fg_1, theme.current().border, theme.current().accent);
    try std.testing.expectEqual(theme.current().accent, if (header_icon.getIcon()) |value| value.tint else header_icon.getImage().?.tint);
    try std.testing.expectEqual(theme.current().overlay, view.palette_panel.getBackground());
    try std.testing.expectEqual(theme.current().accent_ink, row.children.items[1].getText().?.color);
    try std.testing.expectEqual(theme.current().selection, row.getBackground());
    try std.testing.expectEqual(row_id, view.palette_rows.items[selected].id);
    try std.testing.expectEqual(selected, view.palette.selected);
    try std.testing.expectEqual(scroll_y, view.palette_scroll.state.scroll_y);
    try std.testing.expectEqual(focus, cx.focus_manager.getFocused());
    try std.testing.expectEqualDeep(geometry, view.palette_cache);
    // The lightweight keyboard selection path must not reintroduce white.
    view.palette.selected = 0;
    view.refreshCommandPaletteSelection();
    try std.testing.expectEqual(ui.Color.TRANSPARENT, row.getBackground());
    try std.testing.expectEqual(theme.current().selection, first.getBackground());
}

/// Shared headless VT fixture extended only with a trusted-editor provider.
const TrustedCompletionFixture = struct {
    base: @import("terminal_surface_tests.zig").FakeTransport = undefined,
    vtable: terminal_service.Service.VTable = undefined,
    buffer: []const u8 = "git st",
    revision: u64 = 1,
    requests: usize = 0,
    request_kind: terminal_service.trusted_edit.Kind = .replace,
    replacement: [256]u8 = undefined,
    replacement_len: usize = 0,
    lease: u64 = 0,
    fn init(self: *@This(), view: *TerminalViewNode) !void {
        try self.base.init(12, 50);
        const service = self.base.service();
        self.vtable = service.vtable.*;
        self.vtable.trusted_snapshot = snapshot;
        self.vtable.trusted_request = request;
        try view.bindTerminalService(.{ .binding = service.binding, .context = &self.base, .vtable = &self.vtable });
        view.cx.setFocus(view.root);
        _ = try view.refreshTerminalService(@import("terminal_surface_tests.zig").owner, true);
    }
    fn get(raw: *anyopaque) *@This() {
        const base: *@import("terminal_surface_tests.zig").FakeTransport = @ptrCast(@alignCast(raw));
        return @fieldParentPtr("base", base);
    }
    fn snapshot(raw: *anyopaque, _: @import("../host/session_host.zig").ServiceHandle, allocator: std.mem.Allocator) !?terminal_service.trusted_edit.Snapshot {
        const self = get(raw);
        return try (terminal_service.trusted_edit.Snapshot{ .owner = @import("terminal_surface_tests.zig").owner, .token = 1, .revision = self.revision, .buffer = @constCast(self.buffer), .cursor = try std.unicode.utf8CountCodepoints(self.buffer), .mark = 0, .region = 0, .keymap = @constCast("emacs"), .context = @constCast("start"), .prebuffer = @constCast(""), .lease = self.lease }).clone(allocator);
    }
    fn acknowledge(self: *@This(), view: *TerminalViewNode) !void {
        self.revision += 1;
        switch (self.request_kind) {
            .begin => self.lease = view.trusted_operation,
            .end => self.lease = 0,
            .replace => {
                self.buffer = self.replacement[0..self.replacement_len];
                self.lease = 0;
            },
        }
        const surface = view.terminal_surface.?;
        surface.trusted_pending = null;
        surface.trusted_outcome = .{ .operation = view.trusted_operation, .applied = true, .revision = self.revision, .lease = self.lease };
        _ = try view.refreshTerminalService(@import("terminal_surface_tests.zig").owner, true);
    }
    fn request(raw: *anyopaque, _: @import("../host/session_host.zig").ServiceHandle, value: terminal_service.trusted_edit.Request) !void {
        const self = get(raw);
        if (value.token != 1 or value.revision != self.revision) return error.StaleEdit;
        self.requests += 1;
        self.request_kind = value.kind;
        self.replacement_len = value.replacement.len;
        @memcpy(self.replacement[0..value.replacement.len], value.replacement);
    }
};

test "terminal overlay global completion and replay repaint preserve retained input and geometry" {
    const theme = @import("app_theme.zig");
    const old_name = theme.currentName();
    const old_material = theme.materialVisible();
    defer {
        theme.select(old_name);
        _ = theme.setMaterialVisible(old_material);
    }
    theme.select(.dark);
    _ = theme.setMaterialVisible(false);
    const cx = try ui.Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(800, 450);
    var view = try TerminalViewNode.mount(cx);
    defer view.releaseBuffers(cx);
    cx.root = view.root;
    try view.mountHistoryBar();
    _ = cx.render();
    view.updateMetrics();
    var provider: TrustedCompletionFixture = .{};
    try provider.init(&view);
    defer provider.base.deinit();
    defer view.unbindTerminalService(provider.base.service().binding.origin_session.?);
    view.recordCompletionHistory("git status");
    view.recordCompletionHistory("git stash");
    try view.addCompletionPath("git stash /srv/observed");
    view.line.record(cx.allocator, "git st");
    try std.testing.expect(view.handleCompletionKey(.semicolon, .{ .super = true }));
    try std.testing.expectEqual(@as(usize, 2), view.completion_count);
    const row = view.completion_rows.items[0];
    const row_id = row.id;
    const label = row.children.items[0];
    const span_start = label.getText().?.spans[0].start;
    const span_end = label.getText().?.spans[0].end;
    const menu_geometry = view.completion_cache;
    const history_id = view.history_bar.?.id;
    view.history_bar.?.setDisplay(.flex);
    view.history_fill.?.style.width = .{ .percent = 37 };
    view.history_dragging = true;
    view.completion_scroll.state.scroll_y = 11;
    cx.setFocus(view.root);
    const focus = cx.focus_manager.getFocused();
    // Local terminal publication uses setTerminalTheme, even when its VT
    // revision is unchanged for a background/material-only publication.
    const terminal_theme: terminal_service.Theme = .{ .revision = 1, .foreground = 0xffffffff, .background = 0x000000ff, .cursor = 0xffffffff, .selection = 0x6366f124, .ansi = @splat(0x000000ff) };
    for ([_]theme.Name{ .light, .sauber, .dark }) |name| {
        theme.select(name);
        _ = theme.setMaterialVisible(name == .sauber);
        try view.setTerminalTheme(terminal_theme);
        try std.testing.expectEqual(theme.current().overlay, view.completion_panel.getBackground());
        try std.testing.expectEqual(theme.current().fg_1, label.getText().?.color);
        try std.testing.expectEqual(theme.current().accent_ink, label.getText().?.spans[0].color.?);
        try std.testing.expectEqual(theme.current().selection, row.getBackground());
        try std.testing.expectEqual(theme.current().overlay, view.history_bar.?.getBackground());
        try std.testing.expectEqual(theme.current().well, view.history_track.?.getBackground());
        try std.testing.expectEqual(theme.current().accent, view.history_fill.?.getBackground());
        try std.testing.expectEqual(theme.current().warn_ink, view.history_bar.?.children.items[0].getText().?.color);
        try std.testing.expectEqual(theme.current().fg_2, view.history_bar.?.children.items[2].getText().?.color);
        for (view.completion_rows.items, 0..) |candidate_row, i| {
            const badge = candidate_row.children.items[1];
            const expected = switch (view.completion_matches[i].candidate.source) {
                .history => theme.current().ok_ink,
                .path => theme.current().accent_ink,
                .builtin => theme.current().fg_2,
            };
            try std.testing.expectEqual(expected, badge.children.items[0].getText().?.color);
        }
        try std.testing.expectEqual(row_id, view.completion_rows.items[0].id);
        try std.testing.expectEqual(span_start, label.getText().?.spans[0].start);
        try std.testing.expectEqual(span_end, label.getText().?.spans[0].end);
        try std.testing.expectEqual(history_id, view.history_bar.?.id);
        try std.testing.expectEqual(@as(f32, 37), view.history_fill.?.style.width.percent);
        try std.testing.expect(view.history_dragging);
        try std.testing.expectEqual(@as(f32, 11), view.completion_scroll.state.scroll_y);
        try std.testing.expectEqual(focus, cx.focus_manager.getFocused());
        try std.testing.expectEqualDeep(menu_geometry, view.completion_cache);
        try std.testing.expectEqualStrings("git st", view.line.content.items);
        try std.testing.expect(view.completion.state.menu_open);
    }
}

test "trusted completion routes Enter unchanged, replaces only on Right, and suppresses same revision" {
    const cx = try ui.Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(800, 450);
    var view = try TerminalViewNode.mount(cx);
    cx.root = view.root;
    defer view.releaseBuffers(cx);
    var provider: TrustedCompletionFixture = .{};
    try provider.init(&view);
    defer provider.base.deinit();
    defer view.unbindTerminalService(provider.base.service().binding.origin_session.?);
    view.recordCompletionHistory("git status");
    view.recordCompletionHistory("git stash");
    view.refreshCompletion();
    try std.testing.expect(view.completion.state.menu_open);
    try std.testing.expect(!view.handleCompletionKey(.@"return", .{}));
    try std.testing.expectEqual(@as(usize, 0), provider.requests);
    try std.testing.expect(view.handleCompletionKey(.escape, .{}));
    view.refreshCompletion();
    try std.testing.expect(!view.completion.state.menu_open);
    try std.testing.expect(view.handleCompletionKey(.semicolon, .{ .super = true }));
    try std.testing.expect(view.completion.state.menu_open);
    try std.testing.expect(!view.handleCompletionKey(.tab, .{ .shift = true }));
    try std.testing.expect(!view.completion.state.menu_open);
    try std.testing.expect(view.handleCompletionKey(.semicolon, .{ .super = true }));
    try std.testing.expect(view.handleCompletionKey(.down, .{}));
    try std.testing.expect(view.handleCompletionKey(.right, .{}));
    try std.testing.expectEqual(@as(usize, 1), provider.requests);
    try std.testing.expectEqual(terminal_service.trusted_edit.Kind.replace, provider.request_kind);
    try std.testing.expect(std.mem.indexOfScalar(u8, provider.replacement[0..provider.replacement_len], '\r') == null);
    try std.testing.expect(std.mem.indexOfScalar(u8, provider.replacement[0..provider.replacement_len], 0x7f) == null);
    try std.testing.expectEqualStrings("", provider.base.written.items);
}

test "trusted completion Begin ack owns app draft and double at replaces without Enter" {
    const cx = try ui.Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(800, 450);
    var view = try TerminalViewNode.mount(cx);
    cx.root = view.root;
    defer view.releaseBuffers(cx);
    var provider: TrustedCompletionFixture = .{ .buffer = "" };
    try provider.init(&view);
    defer provider.base.deinit();
    defer view.unbindTerminalService(provider.base.service().binding.origin_session.?);
    try std.testing.expect(TerminalViewNode.serviceEditText(&view, "@"));
    try std.testing.expectEqual(terminal_service.trusted_edit.Kind.begin, provider.request_kind);
    try std.testing.expect(!view.palette.isOpen());
    try std.testing.expect(TerminalViewNode.serviceEditKey(&view, .@"return", .{}));
    try std.testing.expect(TerminalViewNode.serviceEditText(&view, "@"));
    try provider.acknowledge(&view);
    try std.testing.expect(view.trusted_lease != 0);
    try std.testing.expectEqual(terminal_service.trusted_edit.Kind.replace, provider.request_kind);
    try std.testing.expectEqualStrings("@", provider.replacement[0..provider.replacement_len]);
    try provider.acknowledge(&view);
    try std.testing.expect(!view.palette.isOpen());
    try std.testing.expectEqual(@as(u64, 0), view.trusted_lease);
    try std.testing.expectEqualStrings("", provider.base.written.items);
    // The literal branch remains a shell draft for the rest of this prompt.
    try std.testing.expect(!TerminalViewNode.serviceEditText(&view, "@"));
}

test "trusted completion app action waits for End ack and stale lease cannot execute" {
    const cx = try ui.Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(800, 450);
    var view = try TerminalViewNode.mount(cx);
    cx.root = view.root;
    defer view.releaseBuffers(cx);
    var provider: TrustedCompletionFixture = .{ .buffer = "" };
    try provider.init(&view);
    defer provider.base.deinit();
    defer view.unbindTerminalService(provider.base.service().binding.origin_session.?);
    try std.testing.expect(TerminalViewNode.serviceEditText(&view, "@"));
    try provider.acknowledge(&view);
    view.closeCommandPalette();
    try view.local_editor.adopt(cx.allocator, "@ts on");
    const old = view.local_state.timestamp_gutter;
    view.executeLocalCommand();
    try std.testing.expectEqual(terminal_service.trusted_edit.Kind.end, provider.request_kind);
    try std.testing.expectEqual(old, view.local_state.timestamp_gutter);
    try provider.acknowledge(&view);
    try std.testing.expectEqual(!old, view.local_state.timestamp_gutter);
    try std.testing.expectEqualStrings("", provider.base.written.items);
    try view.local_editor.adopt(cx.allocator, "@ts on");
    view.executeLocalCommand();
    try std.testing.expectEqual(!old, view.local_state.timestamp_gutter);
}

test "trusted completion local draft renderer sleeps until text or visibility changes" {
    const cx = try ui.Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(800, 450);
    var view = try TerminalViewNode.mount(cx);
    cx.root = view.root;
    defer view.releaseBuffers(cx);
    try view.local_editor.adopt(cx.allocator, "@ts on");
    view.renderLocalInput();
    for (0..4) |_| {
        if (!cx.wantsFrame()) break;
        cx.advanceFrameClock();
        _ = cx.render();
    }
    try std.testing.expect(!cx.wantsFrame());
    view.renderLocalInput();
    try std.testing.expect(!cx.wantsFrame());
    _ = try view.local_editor.insert(cx.allocator, " ");
    view.renderLocalInput();
    try std.testing.expect(cx.wantsFrame());
    cx.advanceFrameClock();
    _ = cx.render();
    view.local_editor.cancel();
    view.renderLocalInput();
    for (0..4) |_| {
        if (!cx.wantsFrame()) break;
        cx.advanceFrameClock();
        _ = cx.render();
    }
    try std.testing.expect(!cx.wantsFrame());
    view.renderLocalInput();
    try std.testing.expect(!cx.wantsFrame());
    try std.testing.expect(!view.local_input_cache.placed);
}

test "untrusted terminal completion never consumes or replaces native input" {
    const cx = try ui.Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    var view = try TerminalViewNode.mount(cx);
    defer view.releaseBuffers(cx);
    cx.root = view.root;
    view.line.record(cx.allocator, "git st");
    view.recordCompletionHistory("git status");
    view.refreshCompletion();
    try std.testing.expect(!view.completion.state.menu_open);
    try std.testing.expect(!view.handleCompletionKey(.right, .{}));
    try std.testing.expect(!view.handleCompletionKey(.semicolon, .{ .super = true }));
    try std.testing.expectEqualStrings("git st", view.line.content.items);
}

fn boldWeight(base: u16) u16 {
    return if (base < 400) 400 else if (base < 500) 500 else if (base < 700) 700 else 900;
}

test "terminal SGR bold advances the configured base weight" {
    try std.testing.expectEqual(@as(u16, 400), boldWeight(300));
    try std.testing.expectEqual(@as(u16, 500), boldWeight(400));
    try std.testing.expectEqual(@as(u16, 700), boldWeight(500));
    try std.testing.expectEqual(@as(u16, 900), boldWeight(700));
}

test "terminal typography owns family and keeps new rows and SGR spans in sync" {
    const cx = try ui.Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    var view = try TerminalViewNode.mount(cx);
    cx.root = view.root;
    defer view.releaseBuffers(cx);
    _ = try view.ensureRowNode(cx, 0);
    var family = [_]u8{ 'M', 'e', 'n', 'l', 'o' };
    try view.setTypographyFamily(18, 1.5, 300, &family, 7);
    @memset(&family, 'x');
    try std.testing.expectEqualStrings("Menlo", view.terminal_font_family.?);
    const created = try view.ensureRowNode(cx, 1);
    try std.testing.expectEqual(@as(u16, 7), created.getText().?.font_family);
    try std.testing.expectEqual(@as(u16, 300), created.getText().?.font_weight);
    try std.testing.expectEqual(@as(u16, 300), view.row_nodes[0].?.getText().?.font_weight);
    const wire = [_]text_frame.WireSpan{.{ .start = 0, .end = 1, .color = 0, .bg = 0, .flags = 1 }};
    const spans = try view.buildRowSpans(cx, &wire, 0, 1, "a", false, 1);
    defer cx.allocator.free(spans);
    try std.testing.expectEqual(@as(?u16, 400), spans[0].font_weight);
}

test "terminal cursor settings change overlay geometry and highlight is conditional" {
    const cx = try ui.Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(500, 300);
    var view = try TerminalViewNode.mount(cx);
    cx.root = view.root;
    defer view.releaseBuffers(cx);
    _ = cx.render();
    view.updateMetrics();
    view.has_frame = true;
    view.frame_rows = 10;
    view.frame_cols = 40;
    view.frame_cursor = .{ .row = 1, .col = 2, .visible = true };
    view.setCursorStyle(.bar);
    try std.testing.expectEqual(@as(f32, 2), view.cursor_overlay.style.width.px);
    view.setCursorStyle(.underline);
    try std.testing.expectEqual(@as(f32, 2), view.cursor_overlay.style.height.px);
    try view.setInputLineHighlight(true);
    try std.testing.expect(view.input_highlight_node.?.style.display != .none);
    try std.testing.expect(view.input_highlight_bar.?.style.display == .none);
    view.remote_input_context.alternate_screen = true;
    view.renderInputLineHighlight();
    try std.testing.expect(view.input_highlight_node.?.style.display == .none);
}

test "SSH middle click uses the installed owner and never writes terminal input" {
    const allocator = std.testing.allocator;
    const cx = try ui.Cx.init(allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(800, 600);
    var view = try TerminalViewNode.mount(cx);
    defer view.releaseBuffers(cx);
    cx.root = view.root;
    // Only bindWorker's UI handler installation and the input queue are used.
    // No socket, VT or IO worker is started or read by this test.
    var worker: @import("../vt/ssh_worker.zig").SshWorker = undefined;
    worker.input = try @import("../vt/input_queue.zig").InputQueue.init(allocator, 128);
    defer worker.input.deinit(allocator);
    var native_runtime: @import("session_runtime.zig").SessionRuntime = undefined;
    native_runtime.torn_down = false;
    native_runtime.worker = &worker;
    var presentation = @import("../plugins/ssh/runtime_binding.zig").borrow(&native_runtime);
    view.bindWorker(&presentation);
    const Sink = struct {
        calls: usize = 0,
        owner: ?SessionHandle = null,
        x: f32 = 0,
        y: f32 = 0,
        fn request(raw: ?*anyopaque, owner: SessionHandle, x: f32, y: f32) void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.calls += 1;
            self.owner = owner;
            self.x = x;
            self.y = y;
        }
    };
    var sink: Sink = .{};
    const owner: SessionHandle = .{ .session_id = @fromBackingInt(901), .generation = 7 };
    view.setWorkerMenuHandler(owner, .{ .context = &sink, .request = Sink.request });
    _ = cx.render();
    const rect = view.root.globalRect();
    const x = rect.x + 120;
    const y = rect.y + 80;
    cx.handleMouseDownEx(x, y, .middle, .{});
    cx.handleMouseUpEx(x, y, .middle, .{});
    try std.testing.expectEqual(@as(usize, 1), sink.calls);
    try std.testing.expectEqual(owner, sink.owner.?);
    try std.testing.expectEqual(x, sink.x);
    try std.testing.expectEqual(y, sink.y);
    try std.testing.expectEqual(@as(usize, 0), worker.input.pending());
    try std.testing.expect(!view.selection.dragging);
    view.setWorkerMenuHandler(owner, null);
    cx.handleMouseDownEx(x, y, .middle, .{});
    cx.handleMouseUpEx(x, y, .middle, .{});
    try std.testing.expectEqual(@as(usize, 1), sink.calls);
}

// Exercise the actual SSH VT and UI input queue without starting a socket or
// worker thread. Only the resources touched by these handlers are initialized.
const ClipboardTestWorker = struct {
    worker: @import("../vt/ssh_worker.zig").SshWorker = undefined,
    native_runtime: @import("session_runtime.zig").SessionRuntime = undefined,
    presentation_storage: Presentation = undefined,
    fn presentation(self: *@This()) *Presentation {
        self.native_runtime.torn_down = false;
        self.native_runtime.worker = &self.worker;
        self.presentation_storage = @import("../plugins/ssh/runtime_binding.zig").borrow(&self.native_runtime);
        return &self.presentation_storage;
    }
    fn init(self: *@This()) !void {
        self.worker.input = try @import("../vt/input_queue.zig").InputQueue.init(std.testing.allocator, 16);
        errdefer self.worker.input.deinit(std.testing.allocator);
        self.worker.replay = try @import("../vt/reconnect_replay.zig").Replay.init(std.testing.allocator, 8192);
        errdefer self.worker.replay.deinit();
        self.worker.replay.configure(null, true, true);
        self.worker.reconnect = try @import("../vt/reconnect.zig").Machine.init(1, &.{1});
        self.worker.vt = try @import("../vt/ghostty_adapter.zig").Adapter.init(std.testing.allocator, 3, 32);
    }
    fn deinit(self: *@This()) void {
        self.worker.vt.destroy();
        self.worker.replay.deinit();
        self.worker.input.deinit(std.testing.allocator);
    }
};
const ClipboardTestSdk = @typeInfo(@typeInfo(@FieldType(ui.Cx, "system_sdk")).optional.child).pointer.child;
const ClipboardTestVTable = @typeInfo(@FieldType(ClipboardTestSdk, "vtable")).pointer.child;
const ClipboardTestPump = @typeInfo(@FieldType(ClipboardTestVTable, "pump_events")).pointer.child;
const ClipboardTestBackend = struct {
    text: []const u8 = "PASTE",
    copied: [128]u8 = undefined,
    copied_len: usize = 0,
    reads: usize = 0,
    writes: usize = 0,
    fail_set: bool = false,
    fn deinit(_: *anyopaque, _: std.mem.Allocator) void {}
    fn pump(_: *anyopaque, _: @typeInfo(ClipboardTestPump).@"fn".param_types[1].?, _: u32) @typeInfo(ClipboardTestPump).@"fn".return_type.? {
        return .{ .should_continue = true };
    }
    fn set(raw: *anyopaque, value: []const u8) error{BufferTooSmall}!void {
        const self: *@This() = @ptrCast(@alignCast(raw));
        if (self.fail_set or value.len > self.copied.len) return error.BufferTooSmall;
        @memcpy(self.copied[0..value.len], value);
        self.copied_len = value.len;
        self.text = self.copied[0..value.len];
        self.writes += 1;
    }
    fn get(raw: *anyopaque, out: []u8) error{BufferTooSmall}![]const u8 {
        const self: *@This() = @ptrCast(@alignCast(raw));
        if (out.len < self.text.len) return error.BufferTooSmall;
        @memcpy(out[0..self.text.len], self.text);
        self.reads += 1;
        return out[0..self.text.len];
    }
    fn len(raw: *anyopaque) error{}!usize {
        return @as(*@This(), @ptrCast(@alignCast(raw))).text.len;
    }
    const vtable: ClipboardTestVTable = .{ .name = "ssh-clipboard-test", .deinit = deinit, .pump_events = pump, .clipboard = .{ .set_text = set, .get_text = get, .get_text_len = len } };
};

test "SSH clipboard public drag release copies once and right click pastes despite selection" {
    const a = std.testing.allocator;
    var fixture: ClipboardTestWorker = .{};
    try fixture.init();
    defer fixture.deinit();
    _ = try fixture.worker.vt.feed("abcdef");
    var clipboard: ClipboardTestBackend = .{};
    var sdk = ClipboardTestSdk.init(a, &clipboard, &ClipboardTestBackend.vtable, .{ .clipboard = true });
    defer sdk.deinit();
    const cx = try ui.Cx.init(a, std.testing.io);
    defer cx.deinit();
    cx.setSystemSdk(&sdk);
    cx.setViewport(600, 180);
    var view = try TerminalViewNode.mount(cx);
    defer view.releaseBuffers(cx);
    cx.root = view.root;
    view.bindWorker(fixture.presentation());
    try view.setOutput(cx, "abcdef");
    _ = cx.render();
    view.updateMetrics();
    const x = view.metrics.origin_x + view.metrics.cell_width * 0.1;
    const y = view.metrics.origin_y + view.metrics.cell_height * 0.5;
    // Ghostty selection endpoints include the final cell.
    const end_x = x + 2 * view.metrics.cell_width;
    cx.handleMouseDownEx(x, y, .left, .{});
    cx.handleMouseMoveEx(end_x, y, .{});
    cx.handleMouseUpEx(end_x, y, .left, .{});
    try std.testing.expectEqualStrings("abc", clipboard.text);
    try std.testing.expectEqual(@as(usize, 1), clipboard.writes);
    try std.testing.expect(view.hasSelection() and !view.selection.dragging);
    cx.handleMouseUpEx(end_x, y, .left, .{});
    cx.handleMouseMoveEx(end_x + view.metrics.cell_width, y, .{});
    try std.testing.expectEqual(@as(usize, 1), clipboard.writes);
    clipboard.text = "EXACT_PASTE";
    cx.handleMouseDownEx(x, y, .right, .{});
    cx.handleMouseUpEx(x, y, .right, .{});
    var queued: [32]u8 = undefined;
    try std.testing.expectEqualStrings("EXACT_PASTE", fixture.worker.input.drain(&queued));
    try std.testing.expectEqual(@as(usize, 1), clipboard.reads);
    try std.testing.expectEqual(@as(usize, 1), clipboard.writes);
    try std.testing.expectEqualStrings("EXACT_PASTE", clipboard.text);
    cx.handleMouseDownEx(x, y, .left, .{});
    cx.handleMouseUpEx(x, y, .left, .{});
    try std.testing.expect(!view.hasSelection());
    try std.testing.expectEqual(@as(usize, 1), clipboard.writes);
    try std.testing.expectEqualStrings("EXACT_PASTE", clipboard.text);
    try std.testing.expectEqual(@as(usize, 0), fixture.worker.input.pending());
}

test "SSH clipboard nested pane maps native window coordinates to its actual VT cells" {
    const a = std.testing.allocator;
    var fixture: ClipboardTestWorker = .{};
    try fixture.init();
    defer fixture.deinit();
    _ = try fixture.worker.vt.feed("abcdef");
    var clipboard: ClipboardTestBackend = .{};
    var sdk = ClipboardTestSdk.init(a, &clipboard, &ClipboardTestBackend.vtable, .{ .clipboard = true });
    defer sdk.deinit();
    const cx = try ui.Cx.init(a, std.testing.io);
    defer cx.deinit();
    cx.setSystemSdk(&sdk);
    cx.setViewport(1440, 900);
    const root = try ui.box(cx, .{ .width = .fill(), .height = .fill(), .padding = .{ .left = 238, .top = 66 } }, .{});
    cx.root = root;
    var view = try TerminalViewNode.mount(cx);
    defer view.releaseBuffers(cx);
    try root.appendChild(a, view.root);
    view.bindWorker(fixture.presentation());
    try view.setOutput(cx, "abcdef");
    _ = cx.render();
    view.updateMetrics();
    const content = view.rows_box.globalRect();
    try std.testing.expectApproxEqAbs(@as(f32, 250), content.x, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 74), content.y, 0.01);
    try std.testing.expectApproxEqAbs(content.x, view.metrics.origin_x, 0.01);
    try std.testing.expectApproxEqAbs(content.y, view.metrics.origin_y, 0.01);
    const x = content.x + view.cell_width * 0.25;
    const y = content.y + view.cell_height * 0.5;
    const end = x + view.cell_width * 2;
    cx.handleMouseDownEx(x, y, .left, .{});
    cx.handleMouseMoveEx(end, y, .{});
    cx.handleMouseUpEx(end, y, .left, .{});
    try std.testing.expectEqualStrings("abc", clipboard.text);
    try std.testing.expectEqual(@as(usize, 1), clipboard.writes);
    const selected = view.selection.normalized().?;
    try std.testing.expectEqual(@as(u64, 0), selected.start_row);
    try std.testing.expectEqual(@as(u16, 0), selected.start_col);
    try std.testing.expectEqual(@as(u16, 2), selected.end_col);
    view.has_frame = true;
    view.frame_cols = 32;
    view.frame_rows = 3;
    view.frame_cursor = .{ .row = 0, .col = 2, .visible = true };
    view.renderSelectionOverlays();
    view.renderCursorOverlay();
    _ = cx.render();
    const highlight = view.selection_overlays[0].globalRect();
    const cursor = view.cursor_overlay.globalRect();
    try std.testing.expectApproxEqAbs(content.x, highlight.x, 0.01);
    try std.testing.expectApproxEqAbs(content.y, highlight.y, 0.01);
    try std.testing.expectApproxEqAbs(content.x + 2 * view.cell_width, cursor.x, 0.01);
    try std.testing.expectApproxEqAbs(content.y, cursor.y, 0.01);
}

test "SSH clipboard multiline uses existing Enter Esc gate and bounded queue" {
    const a = std.testing.allocator;
    var fixture: ClipboardTestWorker = .{};
    try fixture.init();
    defer fixture.deinit();
    var clipboard: ClipboardTestBackend = .{ .text = "first\nsecond\nthird" };
    var sdk = ClipboardTestSdk.init(a, &clipboard, &ClipboardTestBackend.vtable, .{ .clipboard = true });
    defer sdk.deinit();
    const cx = try ui.Cx.init(a, std.testing.io);
    defer cx.deinit();
    cx.setSystemSdk(&sdk);
    cx.setViewport(600, 180);
    var view = try TerminalViewNode.mount(cx);
    defer view.releaseBuffers(cx);
    defer view.clearPendingPaste();
    cx.root = view.root;
    view.bindWorker(fixture.presentation());
    _ = cx.render();
    cx.handleMouseDownEx(40, 40, .right, .{});
    cx.handleMouseUpEx(40, 40, .right, .{});
    try std.testing.expect(view.paste_confirmation_pending);
    try std.testing.expectEqualStrings(clipboard.text, view.pending_paste.?);
    view.pumpPendingPaste();
    try std.testing.expectEqual(@as(usize, 0), fixture.worker.input.pending());
    try std.testing.expectError(error.PendingPaste, view.requestPaste("other"));
    cx.handleKeyDown(.escape, .{});
    cx.handleKeyUp(.escape, .{});
    try std.testing.expect(!view.paste_confirmation_pending and view.pending_paste == null);
    try std.testing.expectEqual(@as(usize, 0), fixture.worker.input.pending());
    cx.handleMouseDownEx(40, 40, .right, .{});
    cx.handleMouseUpEx(40, 40, .right, .{});
    cx.handleKeyDown(.@"return", .{});
    cx.handleKeyUp(.@"return", .{});
    try std.testing.expect(!view.paste_confirmation_pending);
    try std.testing.expectEqual(@as(usize, 0), fixture.worker.input.pending());
    view.pumpPendingPaste();
    var queued: [32]u8 = undefined;
    try std.testing.expect(cx.nextWakeDelayNs().? <= 8 * std.time.ns_per_ms);
    // A full queue and silent remote still owe an autonomous retry.
    cx.next_redraw_scheduled_at = null;
    cx.next_redraw_delay_ns = null;
    view.pumpPendingPaste();
    try std.testing.expect(cx.nextWakeDelayNs().? <= 8 * std.time.ns_per_ms);
    const first = fixture.worker.input.drain(&queued);
    try std.testing.expectEqualStrings(clipboard.text[0..16], first);
    view.pumpPendingPaste();
    try std.testing.expectEqualStrings(clipboard.text[16..], fixture.worker.input.drain(&queued));
    try std.testing.expect(view.pending_paste == null);
    try std.testing.expectEqual(@as(usize, 0), fixture.worker.input.pending());
}

test "SSH clipboard rejects invalid oversized full queue and read only without false success" {
    const a = std.testing.allocator;
    var fixture: ClipboardTestWorker = .{};
    try fixture.init();
    defer fixture.deinit();
    var clipboard: ClipboardTestBackend = .{};
    var sdk = ClipboardTestSdk.init(a, &clipboard, &ClipboardTestBackend.vtable, .{ .clipboard = true });
    defer sdk.deinit();
    const cx = try ui.Cx.init(a, std.testing.io);
    defer cx.deinit();
    cx.setSystemSdk(&sdk);
    var view = try TerminalViewNode.mount(cx);
    defer view.releaseBuffers(cx);
    cx.root = view.root;
    view.bindWorker(fixture.presentation());
    try std.testing.expectError(error.InvalidPaste, view.requestPaste("bad\xff"));
    try std.testing.expectError(error.InvalidPaste, view.requestPaste("line\n\x1b[200~bad"));
    const oversized = try a.alloc(u8, 1024 * 1024 + 1);
    defer a.free(oversized);
    @memset(oversized, 'a');
    try std.testing.expectError(error.PasteTooLarge, view.requestPaste(oversized));
    try std.testing.expectEqual(@as(usize, 0), fixture.worker.input.pending());
    try fixture.worker.input.push("0123456789abcdef");
    try std.testing.expectError(error.Full, view.requestPaste("PASTE"));
    var queued: [32]u8 = undefined;
    try std.testing.expectEqualStrings("0123456789abcdef", fixture.worker.input.drain(&queued));
    view.history.selected = 0;
    try std.testing.expectError(error.ReadOnlyTerminal, view.pasteClipboard());
    view.history.selected = null;
    view.tombstone.end("closed");
    try std.testing.expectError(error.ReadOnlyTerminal, view.pasteClipboard());
    try std.testing.expectEqual(@as(usize, 0), clipboard.reads);
    try std.testing.expectEqual(@as(usize, 0), fixture.worker.input.pending());
}

test "SSH clipboard drag copies real unicode and archived frame while paste stays read only" {
    const a = std.testing.allocator;
    var fixture: ClipboardTestWorker = .{};
    try fixture.init();
    defer fixture.deinit();
    const unicode = "A界e\u{301}Z";
    _ = try fixture.worker.vt.feed(unicode);
    var clipboard: ClipboardTestBackend = .{};
    var sdk = ClipboardTestSdk.init(a, &clipboard, &ClipboardTestBackend.vtable, .{ .clipboard = true });
    defer sdk.deinit();
    const cx = try ui.Cx.init(a, std.testing.io);
    defer cx.deinit();
    cx.setSystemSdk(&sdk);
    cx.setViewport(600, 180);
    var view = try TerminalViewNode.mount(cx);
    defer view.releaseBuffers(cx);
    cx.root = view.root;
    view.bindWorker(fixture.presentation());
    try view.setOutput(cx, unicode);
    _ = cx.render();
    view.updateMetrics();
    const x = view.metrics.origin_x + view.metrics.cell_width * 0.1;
    const y = view.metrics.origin_y + view.metrics.cell_height * 0.5;
    cx.handleMouseDownEx(x, y, .left, .{});
    cx.handleMouseMoveEx(x + 3 * view.metrics.cell_width, y, .{});
    cx.handleMouseUpEx(x + 3 * view.metrics.cell_width, y, .left, .{});
    try std.testing.expectEqualStrings("A界e\u{301}", clipboard.text);
    clipboard.fail_set = true;
    try std.testing.expectError(error.ClipboardUnavailable, view.copyWorkerSelection());
    try std.testing.expectEqual(@as(usize, 1), clipboard.writes);
    clipboard.fail_set = false;
    const archived = "ARCHIVED";
    var wire: [text_frame.header_bytes + archived.len]u8 = undefined;
    text_frame.encodeHeader(wire[0..text_frame.header_bytes], .{}, 32, 1, 0, archived.len);
    @memcpy(wire[text_frame.header_bytes..], archived);
    try view.history.append(1, &wire);
    try std.testing.expect(view.history.open());
    view.bindArchived();
    cx.handleMouseDownEx(x, y, .left, .{});
    cx.handleMouseMoveEx(x + 4 * view.metrics.cell_width, y, .{});
    cx.handleMouseUpEx(x + 4 * view.metrics.cell_width, y, .left, .{});
    try std.testing.expectEqualStrings("ARCH", clipboard.text);
    try std.testing.expectEqual(@as(usize, 2), clipboard.writes);
    try std.testing.expectError(error.ReadOnlyTerminal, view.pasteClipboard());
    try std.testing.expectEqual(@as(usize, 0), clipboard.reads);
    try std.testing.expectEqual(@as(usize, 0), fixture.worker.input.pending());
}

test "sync commands reach workspace approval after trusted End and never toggle local broadcast" {
    const cx = try ui.Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(800, 450);
    var view = try TerminalViewNode.mount(cx);
    cx.root = view.root;
    defer view.releaseBuffers(cx);
    var provider: TrustedCompletionFixture = .{ .buffer = "" };
    try provider.init(&view);
    defer provider.base.deinit();
    defer view.unbindTerminalService(provider.base.service().binding.origin_session.?);
    const Observer = struct {
        calls: usize = 0,
        last_on: bool = false,
        fn command(raw: ?*anyopaque, text: []const u8, executed: bool) void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            if (!executed) return;
            switch (builtin_commands.parse(text)) {
                .sync => |enabled| {
                    self.calls += 1;
                    self.last_on = enabled;
                },
                else => {},
            }
        }
    };
    var observer: Observer = .{};
    view.palette_observer = .{ .context = &observer, .on_command = Observer.command };
    try std.testing.expect(TerminalViewNode.serviceEditText(&view, "@"));
    try provider.acknowledge(&view);
    view.closeCommandPalette();
    try view.local_editor.adopt(cx.allocator, "@sync on");
    view.executeLocalCommand();
    try std.testing.expectEqual(terminal_service.trusted_edit.Kind.end, provider.request_kind);
    try std.testing.expectEqual(@as(usize, 0), observer.calls);
    try provider.acknowledge(&view);
    try std.testing.expectEqual(@as(usize, 1), observer.calls);
    try std.testing.expect(observer.last_on);
    try std.testing.expect(!view.local_state.broadcast);
    try view.local_editor.adopt(cx.allocator, "@sync off");
    view.executeLocalCommandChecked();
    try std.testing.expectEqual(@as(usize, 2), observer.calls);
    try std.testing.expect(!observer.last_on);
    try std.testing.expect(!view.local_state.broadcast);
    try std.testing.expectEqualStrings("", provider.base.written.items);
}

test "terminal prepared font preserves fixed columns across colored SGR runs" {
    const cx = try ui.Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(800, 300);
    var view = try TerminalViewNode.mount(cx);
    cx.root = view.root;
    defer view.releaseBuffers(cx);
    try view.setTypographyFamily(14, 1.5, 400, "Menlo", 7);
    view.cell_width = 9;
    const row = try view.ensureRowNode(cx, 0);
    try row.setTextContent(cx.allocator, "first-directory    second-directory    tail");
    var props = row.getText().?;
    props.spans = &.{
        .{ .start = 0, .end = 15, .color = ui.Color.hex(0x76a5cc), .font_weight = 700 },
        .{ .start = 19, .end = 35, .color = ui.Color.hex(0x76a5cc), .font_weight = 700 },
        .{ .start = 39, .end = 43, .color = ui.Color.WHITE },
    };
    row.setText(props);
    cx.layout();
    _ = cx.render();
    var found: usize = 0;
    var origin_x: ?f32 = null;
    for (cx.display_list.items.items) |item| switch (item) {
        .text_run => |run| if (run.header.node_id == row.id) {
            try std.testing.expectEqual(@as(f32, 9), run.monospace_char_width);
            if (origin_x == null) origin_x = run.x;
            try std.testing.expectApproxEqAbs(origin_x.? + @as(f32, @floatFromInt(run.blob_byte_start)) * 9, run.x, 0.01);
            found += 1;
        },
        else => {},
    };
    try std.testing.expect(found >= 3);
}
