const std = @import("std");
const c = @import("generated_ghostty_vt");

fn localMonotonicNs() i128 {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(.MONOTONIC, &ts) != 0) return 0;
    return @as(i128, ts.sec) * std.time.ns_per_s + @as(i128, ts.nsec);
}
const engine = @import("engine.zig");
const Cell = @import("cell.zig").Cell;
const projection = @import("ghostty_projection.zig");
const snapshot_model = @import("snapshot.zig");
const view_types = @import("viewport.zig");
const ViewStore = @import("ghostty_view.zig").Store;
const RowMetadata = @import("row_metadata.zig");
fn wallClockMs() i64 {
    return @import("../platform/realtime.zig").milliseconds(undefined);
}

/// The sole VT engine adapter. Wraps the Ghostty render-state C ABI so
/// ZeroWork keeps its stable VtEngine contract for the worker/UI boundary.
pub const Adapter = struct {
    allocator: std.mem.Allocator,
    terminal_type: @import("terminal_type.zig").Type = .xterm_256color,
    search_scratch: @import("../platform/snapshot_scratch.zig").Scratch = .{},
    terminal: c.GhosttyTerminal,
    render_state: c.GhosttyRenderState,
    rows: u16,
    cols: u16,
    cells: []Cell,
    view_store: ViewStore,
    row_metadata: RowMetadata.Store,
    wall_clock_ms: *const fn () i64 = wallClockMs,
    /// Last shell-reported working directory. Owned by the adapter and only
    /// replaced while `mutex` is held (the Ghostty callback runs inline from
    /// `ghostty_terminal_vt_write`).
    cwd_owned: ?[]u8 = null,
    version: u64 = 1,
    theme_revision: u64 = 0,
    cells_dirty: bool = true,
    style_version: u64 = 1,
    output_sequence: u64 = 0,
    bell_count: u64 = 0,
    bell_seen: bool = false,
    page_versions: [1]u64 = .{1},
    mode_revision: u64 = 1,
    modes: engine.Modes = .{},
    osc_callback: ?engine.OscCallback = null,
    events: std.ArrayList(snapshot_model.Event) = .empty,
    event_sequence: u64 = 0,
    events_truncated: bool = false,
    replies: std.ArrayList(u8) = .empty,
    reply_offset: usize = 0,
    reply_failed: bool = false,
    /// Guards the whole Ghostty terminal/render-state/cells surface: the
    /// worker thread feeds output while the UI thread queries selections and
    /// snapshots through VtEngine. Ghostty's own contract requires the
    /// terminal to stay unmutated during a selection-format call, so the
    /// granularity is one adapter-wide lock.
    mutex: std.atomic.Mutex = .unlocked,

    pub fn init(allocator: std.mem.Allocator, rows: u16, cols: u16) !Adapter {
        var terminal: c.GhosttyTerminal = null;
        if (c.ghostty_terminal_new(null, &terminal, cols, rows) != c.GHOSTTY_SUCCESS) return error.GhosttyInitFailed;
        errdefer c.ghostty_terminal_free(terminal);
        // The application consumes full Unicode graphemes. Keep Ghostty's
        // native width/cluster mode as the reset default; programs may still
        // explicitly negotiate a different mode.
        const grapheme_mode: c.GhosttyTerminalModeConfig = .{ .mode = c.ghostty_mode_new(2027, false), .value = true };
        if (c.ghostty_terminal_set(terminal, c.GHOSTTY_TERMINAL_OPT_MODE_DEFAULT, @ptrCast(&grapheme_mode)) != c.GHOSTTY_SUCCESS or c.ghostty_terminal_set(terminal, c.GHOSTTY_TERMINAL_OPT_MODE, @ptrCast(&grapheme_mode)) != c.GHOSTTY_SUCCESS) return error.GhosttyModeInitFailed;
        var state: c.GhosttyRenderState = null;
        if (c.ghostty_render_state_new(null, &state) != c.GHOSTTY_SUCCESS) return error.GhosttyRenderStateInitFailed;
        errdefer c.ghostty_render_state_free(state);
        const cells = try allocator.alloc(Cell, @as(usize, rows) * cols);
        @memset(cells, Cell.blank());
        return .{ .allocator = allocator, .terminal = terminal, .render_state = state, .rows = rows, .cols = cols, .cells = cells, .modes = projection.modes(terminal), .view_store = .{ .allocator = allocator }, .row_metadata = .{ .allocator = allocator } };
    }

    /// Zero means unlimited. Ghostty uses a null pointer for unlimited;
    /// a numeric zero would disable scrollback instead.
    pub fn setScrollbackLimit(self: *Adapter, limit: u32) !void {
        while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
        defer self.mutex.unlock();
        var lines: usize = limit;
        if (c.ghostty_terminal_set(self.terminal, c.GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_BYTES, null) != c.GHOSTTY_SUCCESS or
            c.ghostty_terminal_set(self.terminal, c.GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_LINES, if (limit == 0) null else &lines) != c.GHOSTTY_SUCCESS) return error.ScrollbackConfigurationFailed;
        try self.refreshLocked();
        self.refreshVersions();
    }

    pub fn destroy(self: *Adapter) void {
        if (self.cwd_owned) |cwd| self.allocator.free(cwd);
        for (self.events.items) |event| self.allocator.free(event.text);
        self.events.deinit(self.allocator);
        self.replies.deinit(self.allocator);
        self.view_store.deinit();
        self.row_metadata.deinit();
        self.allocator.free(self.cells);
        c.ghostty_render_state_free(self.render_state);
        c.ghostty_terminal_free(self.terminal);
        self.search_scratch.deinit();
        self.* = undefined;
    }

    /// Install Ghostty's native OSC 7/9/1337 PWD notification.  Ghostty
    /// already handles sequence framing across writes; this deliberately does
    /// not implement a second byte-wise OSC parser.
    pub fn configureCwdTracking(self: *Adapter) void {
        const userdata: ?*const anyopaque = @ptrCast(self);
        _ = c.ghostty_terminal_set(self.terminal, c.GHOSTTY_TERMINAL_OPT_USERDATA, userdata);
        const callback: c.GhosttyTerminalPwdChangedFn = onPwdChanged;
        // Callback options consume the function pointer value itself (the
        // optional wrapper is only a Zig representation), not its address.
        _ = c.ghostty_terminal_set(self.terminal, c.GHOSTTY_TERMINAL_OPT_PWD_CHANGED, @ptrCast(callback));
    }

    fn configureCallbacks(self: *Adapter) void {
        self.configureCwdTracking();
        const semantic: c.GhosttyTerminalSemanticPromptFn = onSemanticPrompt;
        const reply: c.GhosttyTerminalWritePtyFn = onWritePty;
        const bell: c.GhosttyTerminalBellFn = onBell;
        _ = c.ghostty_terminal_set(self.terminal, c.GHOSTTY_TERMINAL_OPT_SEMANTIC_PROMPT, @ptrCast(semantic));
        _ = c.ghostty_terminal_set(self.terminal, c.GHOSTTY_TERMINAL_OPT_WRITE_PTY, @ptrCast(reply));
        _ = c.ghostty_terminal_set(self.terminal, c.GHOSTTY_TERMINAL_OPT_BELL, @ptrCast(bell));
    }
    fn onBell(_: c.GhosttyTerminal, userdata: ?*anyopaque) callconv(.c) void {
        const self: *Adapter = @ptrCast(@alignCast(userdata orelse return));
        self.bell_count +|= 1;
        self.bell_seen = true;
    }
    fn recordEvent(self: *Adapter, kind: @FieldType(snapshot_model.Event, "kind"), text: []const u8, exit_code: ?i32) void {
        if (self.event_sequence == std.math.maxInt(u64)) {
            self.events_truncated = true;
            return;
        }
        self.event_sequence += 1;
        const owned = self.allocator.dupe(u8, text[0..@min(text.len, 4096)]) catch {
            self.events_truncated = true;
            return;
        };
        if (text.len > 4096) self.events_truncated = true;
        if (self.events.items.len == 64) {
            self.allocator.free(self.events.orderedRemove(0).text);
            self.events_truncated = true;
        }
        self.events.append(self.allocator, .{ .sequence = self.event_sequence, .kind = kind, .text = owned, .exit_code = exit_code }) catch {
            self.allocator.free(owned);
            self.events_truncated = true;
        };
    }
    fn onSemanticPrompt(_: c.GhosttyTerminal, userdata: ?*anyopaque, event_ptr: [*c]const c.GhosttyTerminalSemanticPrompt) callconv(.c) void {
        const self: *Adapter = @ptrCast(@alignCast(userdata orelse return));
        if (event_ptr == null) return;
        const event = event_ptr.*;
        const kind: @FieldType(snapshot_model.Event, "kind") = switch (event.kind) {
            c.GHOSTTY_SEMANTIC_PROMPT_PROMPT_START => .prompt_start,
            c.GHOSTTY_SEMANTIC_PROMPT_INPUT_START => .input_start,
            c.GHOSTTY_SEMANTIC_PROMPT_OUTPUT_START => .output_start,
            c.GHOSTTY_SEMANTIC_PROMPT_COMMAND_END => .command_end,
            else => return,
        };
        const text = if (event.command.ptr != null) event.command.ptr[0..event.command.len] else "";
        self.recordEvent(kind, text, if (event.has_exit_code) event.exit_code else null);
        if (self.osc_callback) |callback| {
            callback(.{ .semantic = .{ .sequence = self.event_sequence, .kind = kind, .text = text, .exit_code = if (event.has_exit_code) event.exit_code else null } });
            callback(.command_boundary);
        }
    }
    fn onWritePty(_: c.GhosttyTerminal, userdata: ?*anyopaque, data: [*c]const u8, len: usize) callconv(.c) void {
        const self: *Adapter = @ptrCast(@alignCast(userdata orelse return));
        if (len == 0) return;
        if (data == null or len > 64 * 1024 - (self.replies.items.len - self.reply_offset)) {
            self.reply_failed = true;
            return;
        }
        if (self.reply_offset > 0) {
            std.mem.copyForwards(u8, self.replies.items, self.replies.items[self.reply_offset..]);
            self.replies.items.len -= self.reply_offset;
            self.reply_offset = 0;
        }
        self.replies.appendSlice(self.allocator, data[0..len]) catch {
            self.reply_failed = true;
        };
    }

    /// Return an owned snapshot of the shell cwd. The caller owns the result.
    pub fn copyCwd(self: *Adapter, allocator: std.mem.Allocator) !?[]u8 {
        while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
        defer self.mutex.unlock();
        return if (self.cwd_owned) |cwd| try allocator.dupe(u8, cwd) else null;
    }

    /// Discard the previous prompt's path before an explicit shell report.
    pub fn clearCwd(self: *Adapter) void {
        while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
        defer self.mutex.unlock();
        if (self.cwd_owned) |value| self.allocator.free(value);
        self.cwd_owned = null;
    }

    fn onPwdChanged(_: c.GhosttyTerminal, userdata: ?*anyopaque) callconv(.c) void {
        const ptr = userdata orelse return;
        const self: *Adapter = @ptrCast(@alignCast(ptr));
        var value: c.GhosttyString = .{};
        if (c.ghostty_terminal_get(self.terminal, c.GHOSTTY_TERMINAL_DATA_PWD, @ptrCast(&value)) != c.GHOSTTY_SUCCESS) return;
        if (self.cwd_owned) |old| {
            self.allocator.free(old);
            self.cwd_owned = null;
        }
        if (value.len == 0 or value.ptr == null) {
            self.recordEvent(.cwd, "", null);
            if (self.osc_callback) |callback| callback(.{ .cwd = "" });
            return;
        }
        const raw = value.ptr[0..value.len];
        const decoded = parseCwd(self.allocator, raw) catch return;
        if (decoded.len == 0) {
            self.allocator.free(decoded);
            return;
        }
        self.cwd_owned = decoded;
        self.recordEvent(.cwd, decoded, null);
        if (self.osc_callback) |callback| callback(.{ .cwd = decoded });
    }

    fn parseCwd(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
        var path = raw;
        if (std.mem.startsWith(u8, raw, "file://")) {
            const rest = raw[7..];
            const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return allocator.alloc(u8, 0);
            path = rest[slash..]; // discard URI host (including localhost)
        }
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        var i: usize = 0;
        while (i < path.len) : (i += 1) {
            if (path[i] == '%') {
                if (i + 2 >= path.len) return error.InvalidCwdUri;
                const hi = std.fmt.charToDigit(path[i + 1], 16) catch return error.InvalidCwdUri;
                const lo = std.fmt.charToDigit(path[i + 2], 16) catch return error.InvalidCwdUri;
                try out.append(allocator, @as(u8, @intCast(hi * 16 + lo)));
                i += 2;
            } else try out.append(allocator, path[i]);
        }
        if (out.items.len == 0 or out.items[0] != '/' or std.mem.indexOfScalar(u8, out.items, 0) != null or !std.unicode.utf8ValidateSlice(out.items)) return error.InvalidCwdUri;
        return out.toOwnedSlice(allocator);
    }

    pub fn feed(self: *Adapter, bytes: []const u8) !engine.FeedResult {
        while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
        defer self.mutex.unlock();
        self.configureCallbacks();
        const before = self.snapshotLocked().cursor;
        const metadata_before = if (bytes.len > 0) RowMetadata.begin(self.terminal) else RowMetadata.Before{};
        var observed = false;
        defer if (!observed) c.ghostty_tracked_grid_ref_free(metadata_before.native);
        self.bell_seen = false;
        c.ghostty_terminal_vt_write(self.terminal, bytes.ptr, bytes.len);
        if (bytes.len > 0) self.output_sequence +|= 1;
        self.cells_dirty = true;
        if (bytes.len > 0) {
            self.row_metadata.observe(self.terminal, self.rows, metadata_before, self.wall_clock_ms());
            observed = true;
        }
        self.refreshVersions();
        if (self.reply_failed) return error.TerminalReplyOverflow;
        const after = self.snapshotLocked().cursor;
        return .{
            // The current engine contract exposes page numbers, while Ghostty
            // reports row-level dirty state. Page zero is the conservative
            // contract-compatible invalidation until pagelist wiring lands.
            .dirty_pages = if (bytes.len == 0) &[_]u32{} else &[_]u32{0},
            .cursor_moved = before.row != after.row or before.col != after.col or before.visible != after.visible,
            .bell = self.bell_seen,
        };
    }

    pub fn resize(self: *Adapter, cols: u16, rows: u16) !void {
        if (cols == 0 or rows == 0) return error.InvalidDimensions;
        while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
        defer self.mutex.unlock();
        const next = try self.allocator.alloc(Cell, @as(usize, rows) * cols);
        var installed = false;
        errdefer if (!installed) self.allocator.free(next);
        @memset(next, Cell.blank());
        self.configureCallbacks();
        const result = c.ghostty_terminal_resize(self.terminal, cols, rows, 0, 0);
        if (result != c.GHOSTTY_SUCCESS) return error.InvalidDimensions;
        self.allocator.free(self.cells);
        self.cells = next;
        installed = true;
        self.rows = rows;
        self.cols = cols;
        self.refreshLocked() catch |err| {
            self.refreshVersions();
            return err;
        };
        self.refreshVersions();
    }

    pub fn trySnapshot(self: *Adapter) !engine.Snapshot {
        if (!self.mutex.tryLock()) return error.WorkerBusy;
        defer self.mutex.unlock();
        return self.snapshotLocked();
    }

    pub fn snapshot(self: *Adapter) engine.Snapshot {
        while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
        defer self.mutex.unlock();
        return self.snapshotLocked();
    }
    /// UI consumers can avoid copying an unchanged semantic event history.
    /// This has the same serialized ownership as a VT projection snapshot.
    pub fn semanticSequence(self: *Adapter) u64 {
        while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
        defer self.mutex.unlock();
        return self.event_sequence;
    }

    pub fn snapshotLocked(self: *Adapter) engine.Snapshot {
        var cursor_x: u16 = 0;
        var cursor_y: u16 = 0;
        var cursor_visible: bool = true;
        _ = c.ghostty_terminal_get(self.terminal, c.GHOSTTY_TERMINAL_DATA_CURSOR_X, @ptrCast(&cursor_x));
        _ = c.ghostty_terminal_get(self.terminal, c.GHOSTTY_TERMINAL_DATA_CURSOR_Y, @ptrCast(&cursor_y));
        _ = c.ghostty_terminal_get(self.terminal, c.GHOSTTY_TERMINAL_DATA_CURSOR_VISIBLE, @ptrCast(&cursor_visible));
        return .{
            .version = self.version,
            .style_version = self.style_version,
            .output_sequence = self.output_sequence,
            .bell_count = self.bell_count,
            .mode_revision = self.mode_revision,
            .modes = self.modes,
            .cols = self.cols,
            .rows = self.rows,
            .cursor = .{ .row = cursor_y, .col = cursor_x, .visible = cursor_visible },
            .page_versions = &self.page_versions,
            // Ghostty render-state cells currently cover the viewport only.
            // Do not expose terminal scrollback depth as an absolute row offset
            // until history grid refs are projected into PageList.
            .scroll_offset = 0,
        };
    }

    fn refreshVersions(self: *Adapter) void {
        // Conservative damage revisions include pure color/style mutations.
        self.version +|= 1;
        self.style_version +|= 1;
        self.page_versions[0] = self.version;
        const modes = projection.modes(self.terminal);
        if (!std.meta.eql(self.modes, modes)) {
            self.modes = modes;
            self.mode_revision +|= 1;
        }
    }
    pub fn copyProjection(self: *Adapter, allocator: std.mem.Allocator) !engine.Projection {
        while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
        defer self.mutex.unlock();
        if (c.ghostty_render_state_update(self.render_state, self.terminal) != c.GHOSTTY_SUCCESS) return error.GhosttyRenderStateFailed;
        var result = try projection.capture(self, allocator);
        result.output_sequence = self.output_sequence;
        result.bell_count = self.bell_count;
        result.theme_revision = self.theme_revision;
        return result;
    }
    /// Configure defaults through Ghostty's public ABI. Existing OSC 4/10/11/12
    /// overrides remain owned by Ghostty and take precedence until reset.
    pub fn setTheme(self: *Adapter, theme: engine.Theme) !void {
        if (theme.revision == 0) return error.InvalidTheme;
        while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
        defer self.mutex.unlock();
        return self.setThemeLocked(theme);
    }
    pub fn setThemeLocked(self: *Adapter, theme: engine.Theme) !void {
        if (theme.revision == 0) return error.InvalidTheme;
        var palette: [256]c.GhosttyColorRgb = undefined;
        if (c.ghostty_terminal_get(self.terminal, c.GHOSTTY_TERMINAL_DATA_COLOR_PALETTE_DEFAULT, @ptrCast(&palette)) != c.GHOSTTY_SUCCESS) return error.ThemeUnavailable;
        for (theme.ansi, 0..) |value, index| palette[index] = themeRgb(value);
        // Palette change is the sole allocating operation. Apply it first;
        // valid scalar default-color setters below cannot allocate.
        const changed = c.ghostty_terminal_set(self.terminal, c.GHOSTTY_TERMINAL_OPT_COLOR_PALETTE, @ptrCast(&palette));
        if (changed == c.GHOSTTY_OUT_OF_MEMORY) return error.OutOfMemory;
        if (changed != c.GHOSTTY_SUCCESS) return error.ThemeUnavailable;
        const foreground = themeRgb(theme.foreground);
        const background = themeRgb(theme.background);
        const cursor = themeRgb(theme.cursor);
        if (c.ghostty_terminal_set(self.terminal, c.GHOSTTY_TERMINAL_OPT_COLOR_FOREGROUND, @ptrCast(&foreground)) != c.GHOSTTY_SUCCESS or c.ghostty_terminal_set(self.terminal, c.GHOSTTY_TERMINAL_OPT_COLOR_BACKGROUND, @ptrCast(&background)) != c.GHOSTTY_SUCCESS or c.ghostty_terminal_set(self.terminal, c.GHOSTTY_TERMINAL_OPT_COLOR_CURSOR, @ptrCast(&cursor)) != c.GHOSTTY_SUCCESS) return error.ThemeUnavailable;
        var cursor_style: c.GhosttyTerminalCursorStyle = switch (theme.cursor_shape) {
            .block => c.GHOSTTY_TERMINAL_CURSOR_STYLE_BLOCK,
            .bar => c.GHOSTTY_TERMINAL_CURSOR_STYLE_BAR,
            .underline => c.GHOSTTY_TERMINAL_CURSOR_STYLE_UNDERLINE,
        };
        var cursor_blink = theme.cursor_blinking;
        if (c.ghostty_terminal_set(self.terminal, c.GHOSTTY_TERMINAL_OPT_DEFAULT_CURSOR_STYLE, @ptrCast(&cursor_style)) != c.GHOSTTY_SUCCESS or c.ghostty_terminal_set(self.terminal, c.GHOSTTY_TERMINAL_OPT_DEFAULT_CURSOR_BLINK, @ptrCast(&cursor_blink)) != c.GHOSTTY_SUCCESS) return error.ThemeUnavailable;
        self.theme_revision = theme.revision;
        defer self.refreshVersions();
        try self.refreshLocked();
    }
    fn themeRgb(value: u32) c.GhosttyColorRgb {
        return .{ .r = @truncate(value >> 24), .g = @truncate(value >> 16), .b = @truncate(value >> 8) };
    }
    /// Only the transport executor drains replies; this never writes a PTY.
    pub fn readReply(self: *Adapter, buffer: []u8) !usize {
        while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
        defer self.mutex.unlock();
        if (buffer.len == 0) return error.InvalidBuffer;
        const count = @min(buffer.len, self.replies.items.len - self.reply_offset);
        @memcpy(buffer[0..count], self.replies.items[self.reply_offset..][0..count]);
        self.reply_offset += count;
        if (self.reply_offset == self.replies.items.len) {
            self.replies.clearRetainingCapacity();
            self.reply_offset = 0;
        }
        return count;
    }
    pub fn encodeKey(self: *Adapter, event: @import("input_event.zig").KeyEvent, allocator: std.mem.Allocator) ![]u8 {
        while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
        defer self.mutex.unlock();
        return self.encodeKeyLocked(event, allocator);
    }
    /// Configure before handing this adapter to its worker/UI owners.
    pub fn configureTerminalType(self: *Adapter, name: []const u8) void {
        self.terminal_type = @import("terminal_type.zig").classify(name);
    }
    /// Caller holds mutex across mode validation and queue admission.
    pub fn encodeKeyLocked(self: *Adapter, event: @import("input_event.zig").KeyEvent, allocator: std.mem.Allocator) ![]u8 {
        return @import("ghostty_input.zig").keyForType(self.terminal, event, allocator, self.terminal_type);
    }
    pub fn encodeMouse(self: *Adapter, event: @import("input_event.zig").MouseEvent, allocator: std.mem.Allocator) ![]u8 {
        while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
        defer self.mutex.unlock();
        return @import("ghostty_input.zig").mouse(self.terminal, event, allocator);
    }
    pub fn createAnchor(self: *Adapter, point: view_types.Point) !view_types.AnchorId {
        while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
        defer self.mutex.unlock();
        return self.view_store.create(self.terminal, self.cols, point);
    }
    pub fn resolveAnchor(self: *Adapter, id: view_types.AnchorId) !?view_types.AnchorPosition {
        while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
        defer self.mutex.unlock();
        return self.view_store.resolve(id);
    }
    pub fn releaseAnchor(self: *Adapter, id: view_types.AnchorId) !void {
        while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
        defer self.mutex.unlock();
        return self.view_store.release(id);
    }
    pub fn selectionFromAnchors(self: *Adapter, selected: view_types.Selection, allocator: std.mem.Allocator, max_bytes: usize) ![]u8 {
        while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
        defer self.mutex.unlock();
        return self.view_store.selectionText(self.terminal, self.cols, selected, allocator, max_bytes);
    }
    pub fn scroll(self: *Adapter, request: view_types.Scroll) !void {
        while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
        defer self.mutex.unlock();
        try self.view_store.scroll(self.terminal, request);
        try self.refreshLocked();
        self.refreshVersions();
    }
    pub fn readLines(self: *Adapter, limits: view_types.LineLimits, allocator: std.mem.Allocator) !view_types.Lines {
        while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
        defer self.mutex.unlock();
        return @import("ghostty_view.zig").readLines(self.terminal, self.cols, limits, allocator);
    }
    pub fn searchSnapshot(self: *Adapter, allocator: std.mem.Allocator) !@import("search_snapshot.zig").Document {
        while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
        defer self.mutex.unlock();
        const document = try @import("ghostty_search.zig").capture(self, allocator);
        self.row_metadata.annotateSearch(self.terminal, document.rows);
        return document;
    }
    pub fn searchTail(self: *Adapter, allocator: std.mem.Allocator, start: u32, max_rows: u16, version: u64) !@import("search_snapshot.zig").Document {
        while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
        defer self.mutex.unlock();
        if (self.version != version) return error.StaleProjection;
        const document = try @import("ghostty_search.zig").captureRange(self, allocator, start, max_rows);
        self.row_metadata.annotateSearch(self.terminal, document.rows);
        return document;
    }
    pub fn recordSubmission(self: *Adapter) void {
        while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
        defer self.mutex.unlock();
        self.row_metadata.submitted(self.terminal, self.rows, self.wall_clock_ms());
        self.refreshVersions();
    }

    pub fn lineAt(self: *Adapter, row: u64) ?engine.LineView {
        while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
        defer self.mutex.unlock();
        if (row >= self.rows) return null;
        if (self.cells_dirty) self.refreshLocked() catch return null;
        const start = @as(usize, @intCast(row)) * self.cols;
        return .{ .abs_row = row, .cells = self.cells[start .. start + self.cols], .received_at_ms = 0 };
    }

    /// Search uses the complete active screen, including retained scrollback.
    /// Selection copying below continues to use viewport coordinates.
    pub fn searchText(self: *Adapter, allocator: std.mem.Allocator) ![]u8 {
        while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
        defer self.mutex.unlock();
        var formatter: c.GhosttyFormatter = null;
        const options: c.GhosttyFormatterTerminalOptions = .{
            .size = @sizeOf(c.GhosttyFormatterTerminalOptions),
            .emit = c.GHOSTTY_FORMATTER_FORMAT_PLAIN,
            .unwrap = false,
            .trim = true,
            .selection = null,
        };
        if (c.ghostty_formatter_terminal_new(null, &formatter, self.terminal, options) != c.GHOSTTY_SUCCESS) return error.GhosttyFormatFailed;
        defer c.ghostty_formatter_free(formatter);
        var needed: usize = 0;
        const query = c.ghostty_formatter_format_buf(formatter, null, 0, &needed);
        if (query != c.GHOSTTY_OUT_OF_SPACE and query != c.GHOSTTY_SUCCESS) return error.GhosttyFormatFailed;
        var out = try allocator.alloc(u8, needed);
        errdefer allocator.free(out);
        var written: usize = 0;
        if (c.ghostty_formatter_format_buf(formatter, out.ptr, out.len, &written) != c.GHOSTTY_SUCCESS) return error.GhosttyFormatFailed;
        if (written != out.len) out = try allocator.realloc(out, written);
        return out;
    }

    pub fn viewportOffset(self: *Adapter) u64 {
        while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
        defer self.mutex.unlock();
        var bar: c.GhosttyTerminalScrollbar = .{};
        if (c.ghostty_terminal_get(self.terminal, c.GHOSTTY_TERMINAL_DATA_SCROLLBAR, @ptrCast(&bar)) != c.GHOSTTY_SUCCESS) return 0;
        return bar.offset;
    }

    /// A missing native scrollbar report is unknown, never an assumed tail.
    pub fn viewportAtTail(self: *Adapter) ?bool {
        while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
        defer self.mutex.unlock();
        var bar: c.GhosttyTerminalScrollbar = .{};
        if (c.ghostty_terminal_get(self.terminal, c.GHOSTTY_TERMINAL_DATA_SCROLLBAR, @ptrCast(&bar)) != c.GHOSTTY_SUCCESS) return null;
        return bar.offset +| bar.len >= bar.total;
    }

    pub fn scrollToRow(self: *Adapter, row: usize) !void {
        while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
        defer self.mutex.unlock();
        c.ghostty_terminal_scroll_viewport(self.terminal, .{ .tag = c.GHOSTTY_SCROLL_VIEWPORT_ROW, .value = .{ .row = row } });
        try self.refreshLocked();
        self.refreshVersions();
    }

    pub fn selectionText(self: *Adapter, selection: engine.Selection, _: engine.CopyMode, allocator: std.mem.Allocator) ![]u8 {
        while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
        defer self.mutex.unlock();
        if (self.rows == 0 or self.cols == 0) return allocator.alloc(u8, 0);

        // Keep copy semantics in Ghostty's formatter: this preserves soft-wrap
        // unwrapping, trailing-space trimming, and grapheme clusters instead of
        // reconstructing text from the render cache. Selection endpoints are
        // viewport coordinates while the terminal is not mutated during this call.
        const start_row = @min(selection.start_row, @as(u64, self.rows - 1));
        const end_row = @min(selection.end_row, @as(u64, self.rows - 1));
        const start_col = @min(selection.start_col, self.cols - 1);
        const end_col = @min(selection.end_col, self.cols - 1);
        const start_point: c.GhosttyPoint = .{
            .tag = c.GHOSTTY_POINT_TAG_VIEWPORT,
            .value = .{ .coordinate = .{ .x = start_col, .y = @intCast(start_row) } },
        };
        const end_point: c.GhosttyPoint = .{
            .tag = c.GHOSTTY_POINT_TAG_VIEWPORT,
            .value = .{ .coordinate = .{ .x = end_col, .y = @intCast(end_row) } },
        };
        var start_ref: c.GhosttyGridRef = .{ .size = @sizeOf(c.GhosttyGridRef) };
        var end_ref: c.GhosttyGridRef = .{ .size = @sizeOf(c.GhosttyGridRef) };
        if (c.ghostty_terminal_grid_ref(self.terminal, start_point, &start_ref) != c.GHOSTTY_SUCCESS or
            c.ghostty_terminal_grid_ref(self.terminal, end_point, &end_ref) != c.GHOSTTY_SUCCESS)
        {
            return self.selectionTextFromCells(selection, allocator);
        }
        var selected: c.GhosttySelection = .{
            .size = @sizeOf(c.GhosttySelection),
            .start = start_ref,
            .end = end_ref,
            .rectangle = false,
        };
        const options: c.GhosttyTerminalSelectionFormatOptions = .{
            .size = @sizeOf(c.GhosttyTerminalSelectionFormatOptions),
            .emit = c.GHOSTTY_FORMATTER_FORMAT_PLAIN,
            .unwrap = true,
            .trim = true,
            .selection = &selected,
        };
        var needed: usize = 0;
        const query = c.ghostty_terminal_selection_format_buf(self.terminal, options, null, 0, &needed);
        if (query != c.GHOSTTY_OUT_OF_SPACE and query != c.GHOSTTY_SUCCESS) return self.selectionTextFromCells(selection, allocator);
        var out = try allocator.alloc(u8, needed);
        errdefer allocator.free(out);
        var written: usize = 0;
        if (c.ghostty_terminal_selection_format_buf(self.terminal, options, out.ptr, out.len, &written) != c.GHOSTTY_SUCCESS) {
            return self.selectionTextFromCells(selection, allocator);
        }
        if (written != out.len) out = try allocator.realloc(out, written);
        return out;
    }

    fn selectionTextFromCells(self: *Adapter, selection: engine.Selection, allocator: std.mem.Allocator) ![]u8 {
        if (self.cells_dirty) try self.refreshLocked();
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(allocator);
        const start_row = @min(selection.start_row, @as(u64, self.rows - 1));
        const end_row = @min(selection.end_row, @as(u64, self.rows - 1));
        for (start_row..end_row + 1) |row| {
            const first_col: u16 = if (row == start_row) @min(selection.start_col, self.cols) else 0;
            const last_col: u16 = if (row == end_row) @min(selection.end_col, self.cols) else self.cols;
            const row_start = @as(usize, @intCast(row)) * self.cols;
            for (first_col..last_col) |col| {
                const cell = self.cells[row_start + col];
                if (cell.width == .wide_tail) continue;
                var bytes: [4]u8 = undefined;
                const cp: u21 = if (cell.codepoint == 0) ' ' else cell.codepoint;
                const count = std.unicode.utf8Encode(cp, &bytes) catch continue;
                try out.appendSlice(allocator, bytes[0..count]);
            }
            if (row != end_row) try out.append(allocator, '\n');
        }
        return out.toOwnedSlice(allocator);
    }

    pub fn setOscCallback(self: *Adapter, callback: ?engine.OscCallback) void {
        while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
        defer self.mutex.unlock();
        self.osc_callback = callback;
        self.configureCallbacks();
    }

    fn packRgb(rgb: c.GhosttyColorRgb) u32 {
        return (@as(u32, rgb.r) << 24) | (@as(u32, rgb.g) << 16) | (@as(u32, rgb.b) << 8) | 0xff;
    }

    fn refreshLocked(self: *Adapter) !void {
        self.cells_dirty = false;
        errdefer self.cells_dirty = true;
        if (c.ghostty_render_state_update(self.render_state, self.terminal) != c.GHOSTTY_SUCCESS) return error.GhosttyRenderStateFailed;
        var iterator: c.GhosttyRenderStateRowIterator = null;
        if (c.ghostty_render_state_row_iterator_new(null, &iterator) != c.GHOSTTY_SUCCESS) return error.GhosttyRenderStateFailed;
        defer c.ghostty_render_state_row_iterator_free(iterator);
        if (c.ghostty_render_state_get(self.render_state, c.GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR, @ptrCast(&iterator)) != c.GHOSTTY_SUCCESS) return error.GhosttyRenderStateFailed;

        // The row API expects a caller-owned cells container. Passing null here
        // silently leaves the iterator unpopulated, which makes every parsed
        // character look like a blank cell. Reuse one container for all rows.
        var row_cells: c.GhosttyRenderStateRowCells = null;
        if (c.ghostty_render_state_row_cells_new(null, &row_cells) != c.GHOSTTY_SUCCESS) return error.GhosttyRenderStateFailed;
        defer c.ghostty_render_state_row_cells_free(row_cells);

        var row_y: i32 = 0;
        while (c.ghostty_render_state_row_iterator_next(iterator)) {
            if (c.ghostty_render_state_row_get(iterator, c.GHOSTTY_RENDER_STATE_ROW_DATA_VIEWPORT_Y, @ptrCast(&row_y)) != c.GHOSTTY_SUCCESS) continue;
            if (row_y < 0 or row_y >= self.rows) continue;
            const row: u16 = @intCast(row_y);
            var cells = row_cells;
            if (c.ghostty_render_state_row_get(iterator, c.GHOSTTY_RENDER_STATE_ROW_DATA_CELLS, @ptrCast(&cells)) != c.GHOSTTY_SUCCESS) continue;
            var col: u16 = 0;
            while (c.ghostty_render_state_row_cells_next(cells) and col < self.cols) : (col += 1) {
                var raw: c.GhosttyCell = 0;
                _ = c.ghostty_render_state_row_cells_get(cells, c.GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_RAW, @ptrCast(&raw));
                var codepoint: u32 = 0;
                _ = c.ghostty_cell_get(raw, c.GHOSTTY_CELL_DATA_CODEPOINT, @ptrCast(&codepoint));
                var wide: c.GhosttyCellWide = c.GHOSTTY_CELL_WIDE_NARROW;
                _ = c.ghostty_cell_get(raw, c.GHOSTTY_CELL_DATA_WIDE, @ptrCast(&wide));
                const width: @import("cell.zig").Width = switch (wide) {
                    c.GHOSTTY_CELL_WIDE_WIDE => .wide_lead,
                    c.GHOSTTY_CELL_WIDE_SPACER_TAIL => .wide_tail,
                    else => .single,
                };
                var mapped = Cell{ .codepoint = @intCast(codepoint), .width = width };
                var style: c.GhosttyStyle = .{};
                style.size = @sizeOf(c.GhosttyStyle);
                if (c.ghostty_render_state_row_cells_get(cells, c.GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_STYLE, @ptrCast(&style)) == c.GHOSTTY_SUCCESS) {
                    mapped.attrs = (@as(u16, @intFromBool(style.bold)) << 0) |
                        (@as(u16, @intFromBool(style.italic)) << 1) |
                        (@as(u16, @intFromBool(style.underline != 0)) << 2) |
                        (@as(u16, @intFromBool(style.blink)) << 3) |
                        (@as(u16, @intFromBool(style.inverse)) << 4) |
                        (@as(u16, @intFromBool(style.strikethrough)) << 5) |
                        (@as(u16, @intFromBool(style.faint)) << 6) |
                        (@as(u16, @intFromBool(style.invisible)) << 7);
                    // Resolve explicit ANSI/256-color references through the VT's
                    // palette; the wire format remains packed RGBA for consumers.
                    // Unset colors retain the existing inheritance sentinels.
                    var resolved: c.GhosttyColorRgb = .{};
                    if (c.ghostty_render_state_row_cells_get(cells, c.GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_FG_COLOR, @ptrCast(&resolved)) == c.GHOSTTY_SUCCESS)
                        mapped.fg = packRgb(resolved);
                    if (c.ghostty_render_state_row_cells_get(cells, c.GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_BG_COLOR, @ptrCast(&resolved)) == c.GHOSTTY_SUCCESS)
                        mapped.bg = packRgb(resolved);
                }
                // A Ghostty style id is not a grapheme handle. Keep the
                // grapheme slot neutral until ZeroWork has owned grapheme
                // storage; never expose style ids as text metadata.
                mapped.grapheme_link = 0;
                self.cells[@as(usize, row) * self.cols + col] = mapped;
            }
        }
    }
};

test "Ghostty adapter initializes and resizes" {
    var adapter = try Adapter.init(std.testing.allocator, 4, 12);
    defer adapter.destroy();
    try adapter.resize(16, 6);
    try std.testing.expectEqual(@as(u16, 16), adapter.cols);
    try std.testing.expectEqual(@as(u16, 6), adapter.rows);
}

test "Ghostty adapter reports cursor position" {
    var adapter = try Adapter.init(std.testing.allocator, 3, 12);
    defer adapter.destroy();
    _ = try adapter.feed("abc");
    const snap = adapter.snapshot();
    try std.testing.expectEqual(@as(u32, 0), snap.cursor.row);
    try std.testing.expectEqual(@as(u16, 3), snap.cursor.col);
    try std.testing.expect(snap.cursor.visible);
}

test "Ghostty empty feed reports no cursor movement or dirty pages" {
    var adapter = try Adapter.init(std.testing.allocator, 3, 12);
    defer adapter.destroy();
    const result = try adapter.feed("");
    try std.testing.expectEqual(@as(usize, 0), result.dirty_pages.len);
    try std.testing.expect(!result.cursor_moved);
}

test "Ghostty control sequences move cursor without writing text" {
    var adapter = try Adapter.init(std.testing.allocator, 3, 12);
    defer adapter.destroy();
    const result = try adapter.feed("\x1b[2C");
    try std.testing.expect(result.cursor_moved);
    try std.testing.expectEqual(@as(u16, 2), adapter.snapshot().cursor.col);
}

test "Ghostty adapter maps Ghostty SGR attributes" {
    var adapter = try Adapter.init(std.testing.allocator, 2, 12);
    defer adapter.destroy();
    _ = try adapter.feed("\x1b[1;3;4;9mX");
    const attrs = adapter.lineAt(0).?.cells[0].attrs;
    try std.testing.expect((attrs & @import("cell.zig").attrMask(.bold)) != 0);
    try std.testing.expect((attrs & @import("cell.zig").attrMask(.italic)) != 0);
    try std.testing.expect((attrs & @import("cell.zig").attrMask(.underline)) != 0);
    try std.testing.expect((attrs & @import("cell.zig").attrMask(.strike)) != 0);
}

test "Ghostty adapter maps parsed text and wide cells" {
    var adapter = try Adapter.init(std.testing.allocator, 3, 12);
    defer adapter.destroy();
    _ = try adapter.feed("A界B");
    try std.testing.expectEqual(@as(u21, 'A'), adapter.lineAt(0).?.cells[0].codepoint);
    try std.testing.expectEqual(@as(u21, '界'), adapter.lineAt(0).?.cells[1].codepoint);
    try std.testing.expectEqual(@import("cell.zig").Width.wide_lead, adapter.lineAt(0).?.cells[1].width);
    try std.testing.expectEqual(@import("cell.zig").Width.wide_tail, adapter.lineAt(0).?.cells[2].width);
    try std.testing.expectEqual(@as(u21, 'B'), adapter.lineAt(0).?.cells[3].codepoint);
}

test "Ghostty formatter copies a viewport selection" {
    var adapter = try Adapter.init(std.testing.allocator, 3, 12);
    defer adapter.destroy();
    _ = try adapter.feed("A界B");
    const copied = try adapter.selectionText(.{ .start_row = 0, .start_col = 0, .end_row = 0, .end_col = 3 }, .plain, std.testing.allocator);
    defer std.testing.allocator.free(copied);
    try std.testing.expectEqualStrings("A界B", copied);
}

test "native OSC 7 cwd bridge decodes URI and clears on empty" {
    var adapter = try Adapter.init(std.testing.allocator, 3, 12);
    defer adapter.destroy();
    adapter.configureCwdTracking();
    _ = try adapter.feed("\x1b]7;file://host/srv/a%20b\x07");
    const cwd = (try adapter.copyCwd(std.testing.allocator)).?;
    defer std.testing.allocator.free(cwd);
    try std.testing.expectEqualStrings("/srv/a b", cwd);
    _ = try adapter.feed("\x1b]7;\x07");
    const cleared = try adapter.copyCwd(std.testing.allocator);
    try std.testing.expect(cleared == null);
}

test "native OSC 7 bridge handles sequence split across feeds and ignores absent cwd" {
    var adapter = try Adapter.init(std.testing.allocator, 3, 12);
    defer adapter.destroy();
    adapter.configureCwdTracking();
    try std.testing.expect((try adapter.copyCwd(std.testing.allocator)) == null);
    _ = try adapter.feed("\x1b]7;file://host/srv/");
    _ = try adapter.feed("a%2Fb\x07");
    const cwd = (try adapter.copyCwd(std.testing.allocator)).?;
    defer std.testing.allocator.free(cwd);
    try std.testing.expectEqualStrings("/srv/a/b", cwd);
}

test "search includes retained rows without changing viewport copy" {
    var adapter = try Adapter.init(std.testing.allocator, 2, 32);
    defer adapter.destroy();
    _ = try adapter.feed("old-search-hit\r\nsecond\r\nthird\r\nviewport-last");
    const all = try adapter.searchText(std.testing.allocator);
    defer std.testing.allocator.free(all);
    try std.testing.expect(std.mem.indexOf(u8, all, "old-search-hit") != null);
    try std.testing.expect(std.mem.indexOf(u8, all, "viewport-last") != null);
    const viewport = try adapter.selectionText(.{ .start_row = 0, .start_col = 0, .end_row = 1, .end_col = 31 }, .plain, std.testing.allocator);
    defer std.testing.allocator.free(viewport);
    try std.testing.expect(std.mem.indexOf(u8, viewport, "old-search-hit") == null);
    try std.testing.expect(std.mem.indexOf(u8, viewport, "viewport-last") != null);
    try std.testing.expect(adapter.viewportOffset() > 0);
    try adapter.scrollToRow(0);
    try std.testing.expectEqual(@as(u64, 0), adapter.viewportOffset());
    const located = try adapter.selectionText(.{ .start_row = 0, .start_col = 0, .end_row = 0, .end_col = 31 }, .plain, std.testing.allocator);
    defer std.testing.allocator.free(located);
    try std.testing.expect(std.mem.indexOf(u8, located, "old-search-hit") != null);
}

test "Ghostty resolves indexed colors without changing the RGBA wire format" {
    var adapter = try Adapter.init(std.testing.allocator, 2, 12);
    defer adapter.destroy();
    _ = try adapter.feed("\x1b[31mR\x1b[48;5;196mB\x1b[0mD");
    try std.testing.expect(adapter.lineAt(0).?.cells[0].fg != Cell.blank().fg);
    try std.testing.expectEqual(@as(u32, 0xff0000ff), adapter.lineAt(0).?.cells[1].bg);
    try std.testing.expectEqual(Cell.blank().fg, adapter.lineAt(0).?.cells[2].fg);
    try std.testing.expectEqual(Cell.blank().bg, adapter.lineAt(0).?.cells[2].bg);
}
test "notification parser distinguishes actual BEL from OSC terminators across feeds" {
    var adapter = try Adapter.init(std.testing.allocator, 3, 24);
    defer adapter.destroy();
    try std.testing.expect(!(try adapter.feed("\x1b]0;title\x07")).bell);
    try std.testing.expect(!(try adapter.feed("\x1b]7;file://host/srv/")).bell);
    try std.testing.expect(!(try adapter.feed("directory\x07")).bell);
    try std.testing.expect(!(try adapter.feed("\x1b]133;A\x07")).bell);
    try std.testing.expect((try adapter.feed("\x07")).bell);
    try std.testing.expect(!(try adapter.feed("\x1b")).bell);
    try std.testing.expect(!(try adapter.feed("]0;split")).bell);
    try std.testing.expect(!(try adapter.feed("\x07")).bell);
    try std.testing.expect((try adapter.feed("text\x07\x07")).bell);
    try std.testing.expect(!(try adapter.feed("")).bell);
    try std.testing.expectEqual(@as(u64, 9), adapter.snapshot().output_sequence);
    try std.testing.expectEqual(@as(u64, 3), adapter.snapshot().bell_count);
    try std.testing.expect(!(try adapter.feed("\x1b]0;st terminator\x1b\\")).bell);
    try std.testing.expectEqual(@as(u64, 3), adapter.snapshot().bell_count);
}

test "notification parser counters saturate while feed results retain actual Bell" {
    var adapter = try Adapter.init(std.testing.allocator, 2, 20);
    defer adapter.destroy();
    adapter.output_sequence = std.math.maxInt(u64) - 1;
    adapter.bell_count = std.math.maxInt(u64) - 1;
    try std.testing.expect((try adapter.feed("\x07\x07")).bell);
    try std.testing.expectEqual(std.math.maxInt(u64), adapter.snapshot().output_sequence);
    try std.testing.expectEqual(std.math.maxInt(u64), adapter.snapshot().bell_count);
    try std.testing.expect((try adapter.feed("\x07")).bell);
    try std.testing.expect(!(try adapter.feed("\x1b]0;title\x07")).bell);
    try std.testing.expectEqual(std.math.maxInt(u64), adapter.snapshot().output_sequence);
    try std.testing.expectEqual(std.math.maxInt(u64), adapter.snapshot().bell_count);
}

test "terminal scrollback limits preserve unlimited zero and finite line configuration" {
    var adapter = try Adapter.init(std.testing.allocator, 3, 40);
    defer adapter.destroy();
    try adapter.setScrollbackLimit(25000);
    var lines: usize = 0;
    if (c.ghostty_terminal_get(adapter.terminal, c.GHOSTTY_TERMINAL_DATA_SCROLLBACK_MAX_LINES, &lines) != c.GHOSTTY_SUCCESS) return error.GhosttyGetFailed;
    try std.testing.expectEqual(@as(usize, 25000), lines);
    try adapter.setScrollbackLimit(0);
    for (0..1000) |i| {
        var buffer: [32]u8 = undefined;
        _ = try adapter.feed(try std.fmt.bufPrint(&buffer, "retained-row-{d}\r\n", .{i}));
    }
    var projection_value = try adapter.copyProjection(std.testing.allocator);
    defer projection_value.deinit(std.testing.allocator);
    try std.testing.expect(projection_value.scrollback.total_rows >= 1000);
    try adapter.setScrollbackLimit(100);
    if (c.ghostty_terminal_get(adapter.terminal, c.GHOSTTY_TERMINAL_DATA_SCROLLBACK_MAX_LINES, &lines) != c.GHOSTTY_SUCCESS) return error.GhosttyGetFailed;
    try std.testing.expectEqual(@as(usize, 100), lines);
}
