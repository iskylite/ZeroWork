//! Presentation/controller facade for an already-created TerminalService.
//! This module never owns a VT engine, process, file descriptor, or raw-output
//! reader. All mutable UI state is confined to the UI thread.
const std = @import("std");
const ui = @import("ui");
const terminal = @import("../host/terminal_service.zig");
const identity = @import("../host/identity.zig");
const vt = @import("../vt/snapshot.zig");
const TextSlot = @import("../vt/text_slot.zig").TextSlot;
const S = @import("terminal_styles.zig");
const records_style = @import("builtin_records_styles.zig");
const input = @import("terminal_surface_input.zig");
const blink_half_period_ms = 550;
// Viewport cell arrays are large and short-lived. Keep them out of malloc's
// small-region high-water caches so retiring a pane actually releases pages.
const snapshot_allocator = std.heap.page_allocator;

pub const Options = struct {
    grouped: bool = false,
    font_size: f32 = S.body_size,
    row_height: f32 = S.body_height,
    cell_width: f32,
    family_id: u16,
    family_name: []const u8,
    weight: u16 = 400,
    foreground: ui.Color,
    background: ui.Color,
    cursor: ui.Color,
    timestamps: bool,
    highlight: bool,
    cursor_style: enum { block, bar, underline },
};
const Glyph = struct { node: *ui.Node, background: ?*ui.Node = null, overline: ?*ui.Node = null, double_underline: ?*ui.Node = null };
const Row = struct {
    root: *ui.Node,
    test_id: []u8,
    time: ?*ui.Node = null,
    record_time: ?*ui.Node = null,
    selected: *ui.Node,
    marker: ?*ui.Node = null,
    status_icon: ?*ui.Node = null,
    article: ?*ui.Node = null,
    layout: @import("terminal_record_geometry.zig").Layout = .{},
    glyphs: std.ArrayList(Glyph) = .empty,
    hash: u64 = 0,
    pending_hash: ?u64 = null,
    pending_col: usize = 0,
    pending_glyphs: usize = 0,
    content_id: ?vt.RowId = null,
};
const Pending = union(enum) { bytes: []u8, protocol: []u8, key: terminal.KeyEvent, mouse: terminal.MouseRequest };

pub const Surface = struct {
    pub const MenuHandler = struct {
        context: ?*anyopaque = null,
        request: *const fn (?*anyopaque, identity.SessionHandle, f32, f32) void,
    };

    pub const TakeoverHandler = struct {
        context: *anyopaque,
        request: *const fn (*anyopaque, identity.TaskId, identity.SessionHandle, identity.ExecutionId) anyerror!void,
    };
    pub const Feedback = struct {
        context: ?*anyopaque = null,
        publish: *const fn (?*anyopaque, *ui.Cx, identity.SessionHandle, []const u8) anyerror!void = publishFeedback,
    };
    feedback: Feedback = .{},
    timing: ?*@import("../vt/input_timing.zig").Trace = null,
    cx: *ui.Cx,
    host: *ui.Node,
    root: *ui.Node,
    viewport: *ui.Node,
    service: terminal.Service,
    composite: @import("terminal_document.zig").Document,
    owner: identity.SessionHandle,
    menu_handler: ?MenuHandler = null,
    takeover_handler: ?TakeoverHandler = null,
    control_scope: ?*ui.Scope = null,
    control_tag: ?*ui.Node = null,
    control_button: ?*ui.Node = null,
    control_grant: ?terminal.execution.Grant = null,
    control_style: ?*ui.Signal(@FieldType(ui.widgets.ControlShellConfig, "style")) = null,
    control_icon: ?*ui.Node = null,
    shell_observer: ?struct {
        context: *anyopaque,
        accepted: *const fn (*anyopaque, identity.SessionHandle, u64, @import("broadcast_event.zig").Payload) void,
        paste_stamp: *const fn (*anyopaque, identity.SessionHandle) u64,
    } = null,
    broadcast_paste_stamp: u64 = 0,
    enhancement: ?struct {
        context: *anyopaque,
        key: *const fn (*anyopaque, ui.events.KeyCode, ui.events.Modifiers) bool,
        text: *const fn (*anyopaque, []const u8) bool,
        event: ?*const fn (*anyopaque, ui.events.Event) ?ui.events.EventResult = null,
    } = null,
    trusted_outcome: ?terminal.trusted_edit.Outcome = null,
    trusted_pending: ?u64 = null,
    recovered_input: std.ArrayList(u8) = .empty,

    options: Options,
    requested_theme: ?terminal.Theme = null,
    displayed_theme: ?terminal.Theme = null,
    sent_theme_revision: u64 = 0,
    theme_error_seen: ?[]const u8 = null,
    snapshot: ?terminal.TerminalSnapshot = null,
    rows: std.ArrayList(Row) = .empty,
    document_version: ?u64 = null,
    slot_generation: u64 = 0,
    next_input: u64 = 1,
    /// Ordinary UI admission only. VT replies and private execution input
    /// bypass Surface and never advance this ownership signal.
    user_input_revision: u64 = 0,
    next_geometry: u64 = 1,
    requested_cols: u16 = 0,
    requested_rows: u16 = 0,
    pending: std.ArrayList(Pending) = .empty,
    pending_bytes: usize = 0,
    force_snapshot: bool = true,
    active: bool = false,
    focused: bool = false,
    blink: bool = true,
    blink_running: bool = false,
    glyphs_pending: bool = false,
    input_during_hydration: u64 = 0,
    glyph_budget_frame: u64 = std.math.maxInt(u64),
    glyph_budget_remaining: usize = 24,
    reduced_motion: bool = false,
    last_blink: f64 = 0,
    error_message: ?[]const u8 = null,
    error_until_ms: f64 = 0,
    message: *ui.Node,
    message_root: *ui.Node,
    caret: *ui.Node,
    preedit_node: *ui.Node,
    preedit: []u8 = &.{},
    preedit_cursor: u32 = 0,
    command_caret_advance: f32 = 0,
    document: std.ArrayList(u8) = .empty,
    caret_byte: u32 = 0,
    selection: ?terminal.Selection = null,
    released_anchors: std.ArrayList(terminal.Anchor) = .empty,
    dragging: bool = false,
    drag_origin: ui.Point = .{ .x = 0, .y = 0 },
    rectangle: bool = false,
    mouse_reporting: bool = false,
    reported_button: @FieldType(terminal.MouseEvent, "button") = .none,
    wheel_remainder: f32 = 0,
    pending_scroll: f32 = 0,
    scrollbar: ?*ui.Node = null,
    scrollbar_until: f64 = 0,
    pending_paste: ?terminal.Paste = null,
    paste_requested: ?[]u8 = null,
    paste_confirmed: bool = false,
    modal_scope: ?*ui.Scope = null,
    modal_open: ?*ui.Signal(bool) = null,
    modal: ?ui.widgets.ModalResult = null,
    modal_text: ?*ui.Node = null,

    pub fn create(cx: *ui.Cx, host: *ui.Node, service: terminal.Service, options: Options) !*Surface {
        if (service.binding.kind != .terminal) return error.InvalidTerminalBinding;
        const owner = switch (service.binding.resource_owner) {
            .session => |value| value,
            else => return error.InvalidTerminalBinding,
        };
        if (service.binding.origin_session) |origin| if (!origin.eql(owner)) return error.InvalidTerminalBinding;
        const self = try cx.allocator.create(Surface);
        errdefer cx.allocator.destroy(self);
        var owned_options = options;
        owned_options.family_name = try cx.allocator.dupe(u8, options.family_name);
        errdefer cx.allocator.free(owned_options.family_name);
        const root = try ui.boxStyled(cx, S.surface, .{});
        errdefer cx.destroyDetached(root);
        root.meta.ownership.meta.test_id = "terminal.surface";
        const viewport = try ui.box(cx, .{ .position = .absolute, .overflow = .hidden, .hit_behavior = .pass_through }, .{});
        viewport.meta.ownership.meta.test_id = "terminal.surface.viewport";
        try root.appendChild(cx.allocator, viewport);
        const caret = try leaf(cx, options.cursor);
        caret.meta.ownership.meta.test_id = "terminal.surface.caret";
        (try caret.style.ensureExtFallible(cx.allocator)).z_index = 5;
        try viewport.appendChild(cx.allocator, caret);
        const preedit = try ui.text(cx, "", .{ .font_size = options.font_size, .font_family = options.family_id, .use_monospace_font = options.family_id == 0, .selectable = false });
        try absolute(cx, preedit, 0, 0, 0, options.row_height);
        (try preedit.style.ensureExtFallible(cx.allocator)).z_index = 6;
        preedit.setDisplay(.none);
        try viewport.appendChild(cx.allocator, preedit);
        const message_root = try ui.box(cx, S.errorMessage(0, 0, 0, options.row_height, options.background), .{});
        message_root.meta.ownership.meta.test_id = "terminal.message";
        message_root.behavior.interaction.a11y = .{ .role = .status, .live = "polite" };
        try root.appendChild(cx.allocator, message_root);
        const message = try ui.textStyled(cx, S.copiedText, "");
        message.meta.ownership.meta.test_id = "terminal.message.text";
        message.setStyleInline(cx.allocator, S.messageTextBox(cx.tokens));
        try message_root.appendChild(cx.allocator, message);
        message_root.setDisplay(.none);
        message.setDisplay(.none);
        self.* = .{ .cx = cx, .host = host, .root = root, .viewport = viewport, .service = service, .owner = owner, .options = owned_options, .composite = @import("terminal_document.zig").Document.init(cx.allocator, service, owner), .caret = caret, .preedit_node = preedit, .message = message, .message_root = message_root };
        self.service = self.composite.service();
        if (service.textSlot()) |slot| slot.enableStructured() else |_| {}
        self.scrollbar = try @import("terminal_scrollbar.zig").mount(cx, root);
        try host.appendChild(cx.allocator, root);
        if (@import("../vt/input_timing.zig").enabled) {
            if (service.textSlot()) |slot| {
                self.timing = &slot.timing;
                @import("../vt/input_timing.zig").attach(&slot.timing, @backingInt(owner.session_id), owner.generation);
            } else |_| {}
        }
        return self;
    }
    pub fn install(self: *Surface) void {
        self.host.behavior.events.event_context = self;
        self.host.behavior.events.key_context = self;
        self.host.behavior.events.on_event = onEvent;
        self.host.behavior.events.on_key_down = onKey;
        // The host also contains search and other editable overlays. Pointer
        // events belong to the canvas; a child's handled event still bubbles.
        self.root.behavior.events.event_context = self;
        self.root.behavior.events.on_event = onCanvasEvent;
        self.root.behavior.events.on_scroll = onScroll;
        self.host.behavior.interaction.focusable = true;
        self.host.behavior.interaction.a11y = .{ .role = .textarea, .label = "终端", .multiline = true };
        self.host.on_capture_lost = captureLost;
        self.host.behavior.interaction.text_input_client = .{ .context = self, .text_len = textLen, .copy_text = copyText, .selection = imeSelection, .frame_for_range = frameForRange, .range_at_point = rangeAtPoint };
    }
    pub fn destroy(self: *Surface) void {
        if (self.timing) |trace| @import("../vt/input_timing.zig").detach(trace);
        self.host.behavior.interaction.text_input_client = null;
        self.host.behavior.events.on_event = null;
        self.host.behavior.events.on_key_down = null;
        self.host.behavior.events.on_scroll = null;
        self.host.on_capture_lost = null;
        self.clearSelection();
        self.composite.deinit();
        if (self.dragging) self.cx.releasePointerCapture();
        self.cancelPaste();
        if (self.paste_requested) |bytes| self.cx.allocator.free(bytes);
        if (self.modal_scope) |scope| scope.dispose();
        if (self.control_scope) |scope| scope.dispose();
        for (self.pending.items) |item| if (bytePayload(item)) |bytes| self.cx.allocator.free(bytes);
        self.pending.deinit(self.cx.allocator);
        self.released_anchors.deinit(self.cx.allocator);
        self.cx.allocator.free(self.preedit);
        self.recovered_input.deinit(self.cx.allocator);
        self.document.deinit(self.cx.allocator);
        for (self.rows.items) |*row| row.glyphs.deinit(self.cx.allocator);
        if (self.snapshot) |*value| value.deinit(snapshot_allocator);
        self.cx.allocator.free(self.options.family_name);
        if (self.root.parent) |parent| self.cx.detachChild(parent, self.root);
        self.cx.destroyDetached(self.root);
        for (self.rows.items) |row| self.cx.allocator.free(row.test_id);
        self.rows.deinit(self.cx.allocator);
        self.cx.allocator.destroy(self);
    }
    fn liveControlGrant(self: *Surface) ?terminal.execution.Grant {
        if (self.takeover_handler == null) return null;
        const status = self.service.status() catch return null;
        if (!status.owner.eql(self.owner) or status.eof_seen or !status.writable) return null;
        const snapshot = self.service.executionSnapshot() catch return null;
        if (!snapshot.owner.eql(self.owner) or snapshot.input_handed_off) return null;
        const execution_id = snapshot.execution_id orelse return null;
        const grant = snapshot.grant orelse return null;
        if (!grant.execution_id.eql(execution_id)) return null;
        return grant;
    }
    fn cancelControlPress(self: *Surface) void {
        var pressed = self.cx.dispatcher.mouseDownNode();
        while (pressed) |node| : (pressed = node.parent) {
            if (node == self.control_tag) {
                self.cx.cancelPointerInteractions(.explicit);
                return;
            }
        }
    }
    fn refreshControl(self: *Surface) !void {
        const grant = self.liveControlGrant();
        if (!std.meta.eql(grant, self.control_grant)) self.cancelControlPress();
        self.control_grant = grant;
        if (grant != null and self.control_tag == null) {
            const scope = try ui.Scope.init(self.cx.allocator, null, self.cx.owner);
            errdefer scope.dispose();
            const tag = try ui.boxStyled(self.cx, S.aiControlTag, .{});
            errdefer self.cx.destroyDetached(tag);
            tag.meta.ownership.meta.test_id = "terminal.ai_control";
            const badge = try ui.boxStyled(self.cx, S.aiControlBadge, .{});
            try tag.appendChild(self.cx.allocator, badge);
            const icon = try ui.iconTint(self.cx, ui.icons.sparkles, @import("app_theme.zig").current().accent, .{ .width = .{ .px = 13 }, .height = .{ .px = 13 }, .flex_shrink = 0 });
            try badge.appendChild(self.cx.allocator, icon);
            const title = try ui.textStyled(self.cx, S.aiControlText, "AI 控制 • 只读");
            title.meta.ownership.meta.test_id = "terminal.ai_control.title";
            try badge.appendChild(self.cx.allocator, title);
            const style = try scope.createSignal(@FieldType(ui.widgets.ControlShellConfig, "style"), S.aiControlButton());
            const button = try ui.widgets.Button(.{ .label = "接管", .variant = .secondary, .base_style = style, .on_click = self.cx.on(Surface, self, requestTakeover) }).mount(scope, self.cx);
            controlLabelLineHeight(button);
            button.meta.ownership.meta.test_id = "terminal.ai_control.takeover";
            try tag.appendChild(self.cx.allocator, button);
            try self.root.appendChild(self.cx.allocator, tag);
            self.control_scope = scope;
            self.control_tag = tag;
            self.control_button = button;
            self.control_style = style;
            self.control_icon = icon;
        }
        if (self.control_style) |style| style.set(S.aiControlButton());
        if (self.control_icon) |icon| if (ui.icons.sparkles.icon_id) |id| if (ui.icons.sparkles.pickRep(13)) |rep| icon.setIcon(.{ .icon_id = id, .rep = rep, .tint = @import("app_theme.zig").current().accent });
        if (self.control_tag) |tag| tag.setDisplay(if (grant != null) .flex else .none);
    }
    fn controlLabelLineHeight(node: *ui.Node) void {
        if (node.getText()) |text| {
            var next = text;
            next.line_height = 20.0 / 11.0;
            node.setText(next);
        }
        for (node.children.items) |child| controlLabelLineHeight(child);
    }
    fn requestTakeover(self: *Surface) void {
        const expected = self.control_grant orelse return;
        const live = self.liveControlGrant() orelse return;
        if (!std.meta.eql(expected, live)) return;
        const handler = self.takeover_handler orelse return;
        handler.request(handler.context, live.task_id, self.owner, live.execution_id) catch |err| self.showError(err);
    }
    pub fn configure(self: *Surface, options: Options) void {
        if (self.composite.setColors(records_style.colors())) self.force_snapshot = true;
        if (self.composite.setCellWidth(options.cell_width)) self.force_snapshot = true;
        if (self.composite.setRowHeight(options.row_height)) self.force_snapshot = true;
        var next = options;
        next.family_name = self.options.family_name;
        if (std.meta.eql(self.options, next) and std.mem.eql(u8, options.family_name, next.family_name)) return;
        const family = self.cx.allocator.dupe(u8, options.family_name) catch return;
        self.cx.allocator.free(self.options.family_name);
        next.family_name = family;
        self.options = next;
        for (self.rows.items) |*row| row.hash = 0;
        self.force_snapshot = true;
    }
    pub fn setTheme(self: *Surface, theme: terminal.Theme) !void {
        if (theme.revision == 0) return error.InvalidTheme;
        if (self.requested_theme) |previous| {
            if (theme.revision < previous.revision) return error.StaleTheme;
            if (theme.revision == previous.revision) {
                if (!std.meta.eql(theme, previous)) return error.ConflictingTheme;
                return;
            }
        }
        self.requested_theme = theme;
        self.theme_error_seen = null;
        self.force_snapshot = true;
        self.cx.scheduleRedrawAfterNs(16 * std.time.ns_per_ms);
    }
    pub fn refresh(self: *Surface, expected: identity.SessionHandle, active: bool) !bool {
        if (!self.composite.flushRecording()) self.cx.scheduleRedrawAfterNs(8 * std.time.ns_per_ms);
        if (!self.owner.eql(expected)) return error.StaleOwner;
        try self.refreshControl();
        // A retained, exited pane has no worker/clock tick to wake it. Keep
        // polling only until this request appears in an actual owned frame.
        defer if (self.requested_theme) |theme| {
            if (self.snapshot == null or self.snapshot.?.applied_theme_revision != theme.revision)
                self.cx.scheduleRedrawAfterNs(16 * std.time.ns_per_ms);
        };
        if (self.pending_scroll != 0) {
            var accepted = true;
            self.composite.scrollPixels(self.pending_scroll) catch |err| {
                accepted = false;
                if (err != error.WorkerBusy and err != error.SnapshotUnavailable and err != error.StaleProjection) {
                    self.pending_scroll = 0;
                    self.showError(err);
                }
                self.cx.scheduleRedrawAfterNs(8 * std.time.ns_per_ms);
            };
            if (accepted) {
                self.pending_scroll = 0;
                self.force_snapshot = true;
            }
        }
        const activated = active and !self.active;
        self.active = active;
        if (activated) self.force_snapshot = true;
        // The public preferences reader is fed by the native NSWorkspace
        // accessibility notification. Host/renderer overrides also apply.
        const reduced = ui.a11y.preferences.reduceMotion() or self.cx.reduced_motion or self.cx.renderer_reduced_motion;
        const reduced_changed = self.reduced_motion != reduced;
        self.reduced_motion = reduced;
        const focused = self.cx.focus_manager.getFocused();
        const was_focused = self.focused;
        self.focused = active and self.cx.window_active and focused != null and focused.? == self.host;
        if (was_focused and !self.focused) {
            self.setPreedit("");
            if (self.dragging) self.cx.releasePointerCapture();
            self.dragging = false;
            if (self.modal_open == null or !self.modal_open.?.get()) self.cancelPaste();
        }
        if (!active) {
            self.cancelPaste();
            if (self.preedit.len != 0) self.setPreedit("");
        }
        if (self.requested_theme) |theme| if (theme.revision != self.sent_theme_revision) {
            var sent = true;
            self.service.setTheme(theme) catch |err| {
                if (err != error.WorkerBusy) self.showError(err);
                sent = false;
            };
            if (sent) self.sent_theme_revision = theme.revision;
        };
        const slot = self.service.textSlot() catch |err| {
            if (err == error.WorkerBusy) {
                self.cx.scheduleRedrawAfterNs(8 * std.time.ns_per_ms);
                return false;
            }
            return err;
        };
        defer if (self.composite.search_task != null) self.cx.scheduleRedrawAfterNs(16 * std.time.ns_per_ms);
        var changed = self.force_snapshot or self.snapshot == null or self.composite.searchReady();
        if (slot.acknowledge(self.slot_generation)) |generation| {
            self.slot_generation = generation;
            changed = true;
        }
        const status = self.service.status() catch |err| {
            if (err == error.WorkerBusy) {
                self.cx.scheduleRedrawAfterNs(8 * std.time.ns_per_ms);
                self.force_snapshot = changed;
                return false;
            }
            return err;
        };
        if (status.theme_error != null and self.theme_error_seen == null) {
            self.theme_error_seen = status.theme_error;
            self.showError(error.ThemeApplyFailed);
        }
        var gate_changed = false;
        if (self.snapshot) |*current| {
            gate_changed = current.read_only == status.writable or current.eof_seen != status.eof_seen;
            changed = changed or current.read_only == status.writable or current.eof_seen != status.eof_seen or current.geometry_revision != status.geometry.revision or current.projection.mode_revision != status.mode_revision or current.applied_theme_revision != status.applied_theme_revision;
            // End-of-life input gates cannot wait behind an appearance update.
            current.read_only = !status.writable;
            current.eof_seen = status.eof_seen;
        }
        if (changed) update: {
            const next = self.service.snapshot(snapshot_allocator) catch |err| {
                self.force_snapshot = true;
                if (err == error.WorkerBusy or err == error.SnapshotUnavailable or err == error.StaleProjection) {
                    self.cx.scheduleRedrawAfterNs(8 * std.time.ns_per_ms);
                    return false;
                }
                return err;
            };
            if (!next.owner.eql(self.owner)) {
                var stale = next;
                stale.deinit(snapshot_allocator);
                return error.StaleOwner;
            }
            if (self.requested_theme) |theme| if (next.applied_theme_revision != theme.revision) {
                var deferred = next;
                deferred.deinit(snapshot_allocator);
                self.force_snapshot = true;
                changed = false;
                break :update;
            };
            if (self.snapshot) |*old| old.deinit(snapshot_allocator);
            self.snapshot = next;
            self.displayed_theme = self.requested_theme;
            self.next_input = @max(self.next_input, next.input_revision +| 1);
            self.next_geometry = @max(self.next_geometry, next.geometry_revision +| 1);
            self.force_snapshot = false;
            self.blink = true;
            self.last_blink = self.cx.frame_time_ms;
            if (next.read_only) {
                self.cancelPaste();
                self.setPreedit("");
                for (self.pending.items) |item| if (bytePayload(item)) |bytes| self.cx.allocator.free(bytes);
                self.pending.clearRetainingCapacity();
                self.pending_bytes = 0;
            }
        }
        changed = changed or gate_changed or reduced_changed;
        if (!status.writable) {
            self.cancelPaste();
            if (self.preedit.len != 0) self.setPreedit("");
            for (self.pending.items) |item| if (bytePayload(item)) |bytes| self.cx.allocator.free(bytes);
            self.pending.clearRetainingCapacity();
            self.pending_bytes = 0;
        }
        if (self.snapshot == null) return changed;
        if (was_focused != self.focused and self.snapshot.?.projection.modes.focus_events and !self.snapshot.?.read_only) {
            self.queueProtocolText(if (self.focused) "\x1b[I" else "\x1b[O") catch |err| self.showError(err);
        }
        try self.pump();
        // Retain fresh input/mode/notification facts for hidden group members,
        // but do not generate glyph/layout work until the pane is visible.
        if (!self.host.isDisplayedInTree()) {
            self.force_snapshot = true;
            return changed;
        }
        try self.resize();
        const now = @import("../platform/realtime.zig").milliseconds(undefined);
        if (self.error_message != null and self.cx.frame_time_ms >= self.error_until_ms) {
            self.error_message = null;
            self.message_root.setDisplay(.none);
            self.message.setDisplay(.none);
            changed = true;
        }
        const value = &self.snapshot.?;
        if (self.scrollbar) |bar| {
            const range = value.projection.scrollback;
            @import("terminal_scrollbar.zig").update(self.cx, bar, range.total_rows, range.viewport_offset, range.viewport_rows, !value.projection.modes.alternate_screen and (self.cx.frame_time_ms < self.scrollbar_until or range.viewport_offset + range.viewport_rows < range.total_rows));
            if (self.cx.frame_time_ms < self.scrollbar_until) self.cx.scheduleRedrawAfterNs(900 * std.time.ns_per_ms);
        }
        const current_input = self.focused and !value.read_only and value.projection.cursor.visible and value.projection.cursor.row < value.projection.visible_rows.len;
        const text_blinking = for (value.projection.cells) |cell| {
            if (cell.attributes & (1 << 3) != 0) break true;
        } else false;
        const blink_running = self.focused and !value.read_only and !reduced and ((current_input and value.projection.modes.cursor_blinking) or text_blinking);
        if (blink_running != self.blink_running) {
            self.blink_running = blink_running;
            self.last_blink = self.cx.frame_time_ms;
            self.blink = true;
            changed = true;
        }
        if (blink_running and self.cx.frame_time_ms - self.last_blink >= blink_half_period_ms) {
            self.last_blink = self.cx.frame_time_ms;
            self.blink = !self.blink;
            changed = true;
        }
        if (changed or was_focused != self.focused or self.glyphs_pending) try self.render(now);
        if (blink_running) {
            const remaining = @max(1, blink_half_period_ms - (self.cx.frame_time_ms - self.last_blink));
            self.cx.scheduleRedrawAfterNs(@intFromFloat(remaining * std.time.ns_per_ms));
        }
        return changed;
    }
    fn resize(self: *Surface) !void {
        if (self.snapshot.?.read_only or (!self.active and !self.visibleGrouped())) return;
        const rect = self.root.rectFromWorldOrFallback();
        if (rect.w <= self.contentPadding().left + self.contentPadding().right or rect.h <= self.contentPadding().top + self.contentPadding().bottom or self.options.cell_width <= 0 or self.options.row_height <= 0) return;
        const cols: u16 = @intFromFloat(std.math.clamp(@floor((rect.w - self.contentPadding().left - self.contentPadding().right - self.bodyX()) / self.options.cell_width), 1, 65535));
        const rows: u16 = @intFromFloat(std.math.clamp(@floor((rect.h - self.contentPadding().top - self.contentPadding().bottom) / self.options.row_height), 1, 65535));
        if (cols == self.requested_cols and rows == self.requested_rows) return;
        self.service.resize(.{ .revision = self.next_geometry, .cols = cols, .rows = rows }) catch |err| {
            if (err == error.WorkerBusy) return;
            return err;
        };
        self.next_geometry = try std.math.add(u64, self.next_geometry, 1);
        self.requested_cols = cols;
        self.requested_rows = rows;
    }
    fn visibleGrouped(self: *const Surface) bool {
        if (!self.options.grouped) return false;
        var current: ?*ui.Node = self.root;
        while (current) |node| : (current = node.parent) {
            if (node.style.display == .none) return false;
            if (node == self.cx.root) return true;
        }
        return false;
    }
    pub fn contentPadding(self: *const Surface) ui.Padding {
        return S.contentPadding(self.options.grouped);
    }
    pub fn bodyX(self: *const Surface) f32 {
        return if (self.options.timestamps) S.gutter else 0;
    }
    fn render(self: *Surface, _: i64) !void {
        if (self.glyph_budget_frame != self.cx.frame_count) {
            self.glyph_budget_frame = self.cx.frame_count;
            // The first frame also pays for cold fonts and row layout. Later
            // frames can fill larger batches without repeating that work.
            self.glyph_budget_remaining = if (self.glyphs_pending) 96 else 24;
        }
        self.glyphs_pending = false;
        defer if (self.glyphs_pending) self.cx.scheduleRedrawAfterNs(8 * std.time.ns_per_ms);
        const projection = &self.snapshot.?.projection;
        // OSC default-background changes affect cell color resolution, while the
        // terminal canvas always exposes the shared application background.
        self.root.setBackground(ui.Color.TRANSPARENT);
        const bounds = self.root.rectFromWorldOrFallback();
        try absolute(self.cx, self.viewport, 0, self.contentPadding().top, bounds.w, @min(@max(0, bounds.h - self.contentPadding().top - self.contentPadding().bottom), @as(f32, @floatFromInt(projection.rows)) * self.options.row_height));
        const row_width = @max(0, bounds.w - self.contentPadding().left - self.contentPadding().right);
        while (self.rows.items.len < projection.visible_rows.len) {
            try self.rows.ensureUnusedCapacity(self.cx.allocator, 1);
            const test_id = try std.fmt.allocPrint(self.cx.allocator, "terminal.surface.row.{d}", .{self.rows.items.len});
            errdefer self.cx.allocator.free(test_id);
            const root = try ui.boxStyled(self.cx, S.row, .{});
            errdefer self.cx.destroyDetached(root);
            root.meta.ownership.meta.test_id = test_id;
            const selected = try leaf(self.cx, S.selection(self.cx.tokens));
            // Paint the selection before glyphs: opaque terminal theme colors
            // must remain a background rather than covering the selected ink.
            try root.appendChild(self.cx.allocator, selected);
            try self.viewport.appendChild(self.cx.allocator, root);
            self.rows.appendAssumeCapacity(.{ .root = root, .test_id = test_id, .selected = selected });
        }
        while (self.rows.items.len > projection.visible_rows.len) {
            var row = self.rows.pop().?;
            row.glyphs.deinit(self.cx.allocator);
            self.cx.detachChild(self.viewport, row.root);
            self.cx.destroyDetached(row.root);
            self.cx.allocator.free(row.test_id);
        }
        // Keep shaped glyphs with their document row as the viewport moves.
        // Match every retained row before painting, so newly exposed rows only
        // reuse nodes belonging to content that has left the viewport.
        for (projection.visible_rows) |value| {
            const target = value.viewport_y;
            for (self.rows.items, 0..) |cached, index| {
                if (cached.content_id) |id| if (std.meta.eql(id, value.id)) {
                    std.mem.swap(Row, &self.rows.items[target], &self.rows.items[index]);
                    // Query ids belong to viewport slots, not recycled content.
                    std.mem.swap([]u8, &self.rows.items[target].test_id, &self.rows.items[index].test_id);
                    break;
                };
            }
        }
        for (projection.visible_rows) |value| {
            const row = &self.rows.items[value.viewport_y];
            row.content_id = value.id;
            row.root.meta.ownership.meta.test_id = switch (value.application_kind) {
                1 => "terminal.command.record",
                2, 3, 4 => "terminal.command.output",
                else => row.test_id,
            };
            if (self.displayed_theme) |theme| row.selected.setBackground(rgba(theme.selection));
            row.layout = value.presentation;
            const row_y = self.presentationY(value.viewport_y);
            try absolute(self.cx, row.root, self.contentPadding().left, row_y, row_width, self.options.row_height);
            const first_article = value.application_record_id != 0 and (value.viewport_y == 0 or projection.visible_rows[value.viewport_y - 1].application_record_id != value.application_record_id);
            if (first_article) {
                if (row.article == null) {
                    const article = try ui.box(self.cx, .{ .position = .absolute, .border = .{ .radius = 8 }, .hit_behavior = .pass_through }, .{});
                    errdefer self.cx.destroyDetached(article);
                    article.meta.ownership.meta.test_id = "terminal.command.article";
                    try row.root.insertChildBefore(self.cx.allocator, article, row.root.children.items[0]);
                    row.article = article;
                }
                row.article.?.setDisplay(.flex);
                row.article.?.setBackground(records_style.tint(if (value.application_state == 2) 3 else value.application_kind));
                try absolute(self.cx, row.article.?, -@import("terminal_record_geometry.zig").padding_inline, value.presentation.article_y - row_y, row_width + 2 * @import("terminal_record_geometry.zig").padding_inline, value.presentation.article_height);
            } else if (row.article) |article| article.setDisplay(.none);
            const current = !self.snapshot.?.read_only and projection.cursor.visible and value.viewport_y == projection.cursor.row;
            row.root.setBackground(if (value.application_record_id == 0 and current and self.options.highlight) S.inputHighlight(self.cx.tokens) else ui.Color.TRANSPARENT);
            const cells = projection.cells[value.cell_start .. value.cell_start + value.cell_count];
            const has_text = for (cells) |cell| {
                if (std.mem.trim(u8, projection.grapheme(cell), " \t\r\n").len > 0) break true;
            } else false;
            const stamp = value.submitted_wallclock_ms orelse value.received_wallclock_ms;
            const header = value.application_kind == 1 and value.id[1] == 0;
            try self.renderTime(row, if (has_text and (value.application_record_id == 0 or header)) stamp else null);
            if (header and stamp != null) {
                const time = try self.rowText(row, "record_time", records_style.recordTime, "", "terminal.command.time");
                time.setDisplay(.flex);
                var clock: [19]u8 = undefined;
                const text = try input.localDateTimestamp(&clock, stamp.?);
                try time.setTextContent(self.cx.allocator, text);
                time.setTextColor(@import("app_theme.zig").current().fg_3);
                var time_props = time.getText().?;
                time_props.line_height = self.options.row_height / time_props.font_size;
                time.setText(time_props);
                try absolute(self.cx, time, @max(self.bodyX(), row_width - 160), 0, 160, self.options.row_height);
            } else if (row.record_time) |time| time.setDisplay(.none);
            if (header and projection.cols > self.composite.command_inset_cells + 5) {
                const marker = try self.rowText(row, "marker", records_style.markerText, "ZeroWork", "terminal.command.source");
                marker.setStyleInline(self.cx.allocator, records_style.markerBox(self.cx.tokens));
                marker.setDisplay(.flex);
                marker.setBackground(@import("app_theme.zig").current().accent.withAlpha(31));
                var marker_props = marker.getText().?;
                marker_props.color = @import("app_theme.zig").current().accent_ink;
                marker.setText(marker_props);
                records_style.place(self.cx, marker, self.bodyX(), 2, records_style.marker_width, records_style.marker_height);
            } else if (row.marker) |marker| marker.setDisplay(.none);
            if (value.application_kind >= 2 and value.id[1] == (1 << 32)) {
                const icon = try self.rowText(row, "status_icon", records_style.resultText, "", "terminal.command.state");
                icon.setDisplay(.flex);
                try icon.setTextContent(self.cx.allocator, switch (value.application_kind) {
                    2 => "✓",
                    3 => "!",
                    else => "…",
                });
                var props = icon.getText().?;
                props.color = records_style.resultColor(value.application_kind);
                icon.setText(props);
                records_style.place(self.cx, icon, self.bodyX(), 0, records_style.result_icon_width, self.options.row_height);
            } else if (row.status_icon) |icon| icon.setDisplay(.none);
            var hash = std.hash.Wyhash.init(0);
            hash.update(std.mem.asBytes(&value.id));
            for (cells) |cell| {
                var style_cell = cell;
                // Grapheme arena offsets change when a row moves in a snapshot;
                // only its text and style determine whether glyphs need work.
                style_cell.grapheme_start = 0;
                std.hash.autoHash(&hash, style_cell);
                hash.update(projection.grapheme(cell));
                if (cell.attributes & (1 << 3) != 0) {
                    hash.update(std.mem.asBytes(&self.blink));
                    hash.update(std.mem.asBytes(&self.focused));
                }
            }
            std.hash.autoHash(&hash, .{ @as(u32, @bitCast(row_width)), row.record_time != null and row.record_time.?.style.display != .none });
            std.hash.autoHash(&hash, @as(u32, @bitCast(value.presentation.shift_x)));
            std.hash.autoHash(&hash, projection.colors);
            std.hash.autoHash(&hash, projection.modes.reverse_colors);
            std.hash.autoHash(&hash, .{ @as(u32, @bitCast(self.options.font_size)), @as(u32, @bitCast(self.options.row_height)), @as(u32, @bitCast(self.options.cell_width)), self.options.family_id, self.options.weight, self.options.foreground, self.options.background, self.options.timestamps });
            if (row.hash != hash.final() or row.pending_hash != null) {
                if (row.pending_hash != hash.final()) {
                    row.pending_hash = hash.final();
                    row.pending_col = 0;
                    row.pending_glyphs = 0;
                }
                if (try self.renderGlyphs(row, cells, projection)) {
                    row.hash = hash.final();
                    row.pending_hash = null;
                }
            }
        }
        try self.renderSelection();
        try self.renderCaret();
        try self.buildDocument();
        if (self.timing) |trace| trace.applied(self.snapshot.?.output_sequence);
        self.cx.requestRedraw();
    }
    fn renderTime(self: *Surface, row: *Row, timestamp: ?i64) !void {
        if (!self.options.timestamps or timestamp == null) {
            if (row.time) |time| time.setDisplay(.none);
            return;
        }
        const time = try self.rowText(row, "time", S.timestamp, "", "terminal.timestamp");
        time.setDisplay(.flex);
        var bytes: [8]u8 = undefined;
        const stamp = try input.localTimestamp(&bytes, timestamp.?);
        if (time.getText()) |props| if (!std.mem.eql(u8, props.content, stamp)) try time.setTextContent(self.cx.allocator, stamp);
        var props = time.getText().?;
        if (props.font_family != self.options.family_id or props.use_monospace_font != (self.options.family_id == 0)) {
            props.font_family = self.options.family_id;
            props.use_monospace_font = self.options.family_id == 0;
            time.setText(props);
        }
        var aligned = time.getText().?;
        aligned.line_height = self.options.row_height / aligned.font_size;
        time.setText(aligned);
        try absolute(self.cx, time, S.timestamp_x, S.timestamp_y, S.timestamp_width, self.options.row_height);
    }
    fn rowText(self: *Surface, row: *Row, comptime field: []const u8, comptime style: anytype, content: []const u8, test_id: []const u8) !*ui.Node {
        if (@field(row, field)) |node| return node;
        const node = try ui.textStyled(self.cx, style, content);
        errdefer self.cx.destroyDetached(node);
        node.meta.ownership.meta.test_id = test_id;
        try row.root.appendChild(self.cx.allocator, node);
        @field(row, field) = node;
        return node;
    }
    pub fn presentationY(self: *const Surface, index: usize) f32 {
        if (self.snapshot) |snap| if (index < snap.projection.visible_rows.len) return @import("terminal_record_geometry.zig").rowY(snap.projection.visible_rows[index].presentation, index, self.options.row_height);
        return @as(f32, @floatFromInt(index)) * self.options.row_height;
    }
    fn renderGlyphs(self: *Surface, row: *Row, cells: []const vt.Cell, projection: *const vt.Projection) !bool {
        var used = row.pending_glyphs;
        var col = row.pending_col;
        var complete = true;
        while (col < cells.len) {
            const cell = cells[col];
            const start = col;
            col += 1;
            if (row.record_time != null and row.record_time.?.style.display != .none and self.bodyX() + row.layout.shift_x + @as(f32, @floatFromInt(start + 1)) * self.options.cell_width > row.root.style.width.px - 164) continue;
            if (cell.width == .wide_tail) continue;
            var text = projection.grapheme(cell);
            if (text.len == 0 and cell.background == .default and cell.attributes == 0 and !projection.modes.reverse_colors) continue;
            // Keep complex graphemes at their exact VT columns. Adjacent ASCII
            // cells share one native text run instead of two nodes per cell.
            // fixed advance preserves the terminal grid even for ligatures.
            var ascii: [500]u8 = undefined;
            if (asciiCell(cell, projection)) {
                ascii[0] = text[0];
                while (col < cells.len and col - start < ascii.len) : (col += 1) {
                    const next = cells[col];
                    if (!asciiCell(next, projection) or !sameCellStyle(cell, next)) break;
                    if (row.record_time != null and row.record_time.?.style.display != .none and self.bodyX() + row.layout.shift_x + @as(f32, @floatFromInt(col + 1)) * self.options.cell_width > row.root.style.width.px - 164) break;
                    ascii[col - start] = projection.grapheme(next)[0];
                }
                text = ascii[0 .. col - start];
            }
            if (used == row.glyphs.items.len) {
                if (self.glyph_budget_remaining == 0 and row.layout.article_height > 0) {
                    self.glyphs_pending = true;
                    col = start;
                    complete = false;
                    break;
                }
                if (row.layout.article_height > 0) self.glyph_budget_remaining -|= 1;
                try row.glyphs.ensureUnusedCapacity(self.cx.allocator, 1);
                const node = try ui.text(self.cx, "", .{ .selectable = false });
                errdefer {
                    if (node.parent) |parent| self.cx.detachChild(parent, node);
                    self.cx.destroyDetached(node);
                }
                try row.root.appendChild(self.cx.allocator, node);
                row.glyphs.appendAssumeCapacity(.{ .node = node });
            }
            const glyph = &row.glyphs.items[used];
            var fg = resolveColor(cell.foreground, ui.Color.hex(if (projection.modes.reverse_colors) projection.colors.background else projection.colors.foreground), projection.colors);
            var bg = resolveColor(cell.background, ui.Color.hex(if (projection.modes.reverse_colors) projection.colors.foreground else projection.colors.background), projection.colors);
            if (cell.attributes & (1 << 4) != 0) std.mem.swap(ui.Color, &fg, &bg);
            if (cell.attributes & (1 << 6) != 0) fg.a = @intCast(@as(u16, fg.a) / 2);
            const hide_ink = cell.attributes & (1 << 7) != 0 or
                (cell.attributes & (1 << 3) != 0 and self.focused and !self.reduced_motion and !self.blink);
            if (hide_ink) fg.a = 0;
            var props = glyph.node.getText().?;
            const decorated = cell.attributes & (1 << 5) != 0 or (cell.underline != 0 and cell.underline != 2);
            const spans: []ui.types.TextSpan = if (decorated) try self.cx.allocator.alloc(ui.types.TextSpan, 1) else &.{};
            var published = false;
            errdefer if (!published and spans.len > 0) self.cx.allocator.free(spans);
            try props.setContent(self.cx.allocator, if (text.len == 0) " " else text);
            props.font_size = self.options.font_size;
            props.line_height = self.options.row_height / self.options.font_size;
            props.font_weight = if (cell.attributes & 1 != 0) @min(@as(u16, 900), self.options.weight +| 300) else self.options.weight;
            props.font_family = self.options.family_id;
            props.use_monospace_font = self.options.family_id == 0;
            props.use_italic_font = cell.attributes & 2 != 0;
            props.monospace_char_width = self.options.cell_width;
            props.strikethrough = cell.attributes & (1 << 5) != 0;
            props.color = fg;
            if (spans.len > 0) spans[0] = .{ .start = 0, .end = @intCast(props.content.len), .strikethrough = props.strikethrough, .underline = cell.underline != 0 and cell.underline != 2, .underline_color = if (hide_ink) ui.Color.TRANSPARENT else resolveColor(cell.underline_color, fg, projection.colors), .underline_style = switch (cell.underline) {
                3 => .wavy,
                4 => .dotted,
                5 => .dashed,
                else => .solid,
            }, .underline_thickness = 1 };
            props.spans = spans;
            props.spans_owned = spans.len > 0;
            glyph.node.setText(props);
            published = true;
            const has_background = cell.background != .default or cell.attributes & (1 << 4) != 0 or projection.modes.reverse_colors;
            // Cell backgrounds belong below the selection; text stays above it.
            if (has_background and glyph.background == null) {
                const background = try leaf(self.cx, bg);
                errdefer self.cx.destroyDetached(background);
                try row.root.insertChildBefore(self.cx.allocator, background, row.selected);
                glyph.background = background;
            }
            glyph.node.setBackground(ui.Color.TRANSPARENT);
            glyph.node.setDisplay(.flex);
            const x = self.bodyX() + row.layout.shift_x + @as(f32, @floatFromInt(start)) * self.options.cell_width;
            const width = self.options.cell_width * @as(f32, @floatFromInt(if (cell.width == .wide_lead) @as(usize, 2) else col - start));
            try absolute(self.cx, glyph.node, x, 0, width, self.options.row_height);
            if (glyph.background) |background| {
                background.setDisplay(if (has_background) .flex else .none);
                background.setBackground(bg);
                try absolute(self.cx, background, x, 0, width, self.options.row_height);
            }
            if (cell.attributes & (1 << 8) != 0 and glyph.overline == null) {
                const line = try leaf(self.cx, fg);
                errdefer self.cx.destroyDetached(line);
                try row.root.appendChild(self.cx.allocator, line);
                glyph.overline = line;
            }
            if (glyph.overline) |line| {
                line.setDisplay(if (cell.attributes & (1 << 8) != 0) .flex else .none);
                line.setBackground(fg);
                try absolute(self.cx, line, x, 1, width, 1);
            }
            if (cell.underline == 2 and glyph.double_underline == null) {
                const line = try leaf(self.cx, ui.Color.TRANSPARENT);
                errdefer self.cx.destroyDetached(line);
                try row.root.appendChild(self.cx.allocator, line);
                glyph.double_underline = line;
            }
            if (glyph.double_underline) |line| {
                line.setDisplay(if (cell.underline == 2) .flex else .none);
                const color = if (hide_ink) ui.Color.TRANSPARENT else resolveColor(cell.underline_color, fg, projection.colors);
                line.setStyleInline(self.cx.allocator, .{ .border_top_width = 1, .border_bottom_width = 1, .border_top_color = color, .border_bottom_color = color });
                try absolute(self.cx, line, x, self.options.row_height - 5, width, 4);
            }
            used += 1;
        }
        for (row.glyphs.items[used..]) |glyph| {
            glyph.node.setDisplay(.none);
            if (glyph.background) |background| background.setDisplay(.none);
            if (glyph.overline) |line| line.setDisplay(.none);
            if (glyph.double_underline) |line| line.setDisplay(.none);
        }
        row.pending_col = col;
        row.pending_glyphs = used;
        return complete;
    }
    pub fn setCommandCaret(self: *Surface, advance: f32) void {
        if (self.command_caret_advance == advance) return;
        self.command_caret_advance = advance;
        if (self.snapshot != null) self.renderCaret() catch {};
        self.renderPreedit() catch {};
        self.cx.requestRedraw();
    }
    fn renderCaret(self: *Surface) !void {
        const value = &self.snapshot.?;
        const cursor = value.projection.cursor;
        const show = !value.read_only and self.active and cursor.visible and cursor.row < value.projection.visible_rows.len and (self.reduced_motion or !self.focused or self.blink or !value.projection.modes.cursor_blinking);
        self.caret.setDisplay(if (show) .flex else .none);
        if (!show) return;
        var x = self.contentPadding().left + self.bodyX() + @as(f32, @floatFromInt(cursor.col)) * self.options.cell_width + self.command_caret_advance;
        var y = self.presentationY(cursor.row);
        var width = self.options.cell_width;
        var height = self.options.row_height;
        if (self.preedit.len != 0) x += self.measured(self.preedit[0..self.preedit_cursor]);
        switch (if (self.displayed_theme != null) cursor.shape else switch (self.options.cursor_style) {
            .block => @as(@FieldType(@import("../vt/engine.zig").Cursor, "shape"), .block),
            .bar => .bar,
            .underline => .underline,
        }) {
            .block, .hollow => {},
            .bar => width = 2,
            .underline => {
                height = 2;
                y += self.options.row_height - height;
            },
        }
        const cursor_color = if (value.projection.colors.cursor) |color| ui.Color.hex(color) else self.options.cursor;
        self.caret.setBackground(cursor_color.withAlpha(if (self.focused) 160 else 65));
        try absolute(self.cx, self.caret, x, y, width, height);
        try self.renderPreedit();
    }
    pub fn measured(self: *Surface, bytes: []const u8) f32 {
        // Use the painter's own font/segment loop, including explicit grid
        // advances and fallback fonts in mixed CJK/emoji preedit text.
        if (self.cx.text.font_props_measure_fn) |measure| if (self.cx.text.font_resolve_ctx) |context| {
            if (measure(context, bytes, self.options.font_size, self.options.weight, false, self.options.family_id == 0, self.options.family_id, false, self.options.cell_width)) |width| return width;
        };
        const ascii = for (bytes) |byte| {
            if (byte >= 0x80) break false;
        } else true;
        if (ascii) return @as(f32, @floatFromInt(bytes.len)) * self.options.cell_width;
        if (self.cx.text.shapeText(.{ .text = bytes, .font_family = self.options.family_name, .font_family_id = self.options.family_id, .font_size = self.options.font_size, .font_weight = self.options.weight, .use_monospace = self.options.family_id == 0 })) |run| return run.total_advance else |_| return 0;
    }
    pub fn setPreedit(self: *Surface, bytes: []const u8) void {
        const next = self.cx.allocator.dupe(u8, bytes) catch return;
        self.cx.allocator.free(self.preedit);
        self.preedit = next;
        self.document_version = null;
        self.preedit_cursor = @intCast(bytes.len);
        self.renderPreedit() catch {};
        self.buildDocument() catch {};
        self.cx.requestRedraw();
    }
    fn renderPreedit(self: *Surface) !void {
        self.preedit_node.setDisplay(if (self.preedit.len != 0 and self.snapshot != null and !self.snapshot.?.read_only) .flex else .none);
        if (self.preedit.len == 0 or self.snapshot == null) return;
        const cursor = self.snapshot.?.projection.cursor;
        var props = self.preedit_node.getText().?;
        const spans = try self.cx.allocator.alloc(ui.types.TextSpan, 1);
        var published = false;
        errdefer if (!published) self.cx.allocator.free(spans);
        try props.setContent(self.cx.allocator, self.preedit);
        props.font_size = self.options.font_size;
        props.monospace_char_width = self.options.cell_width;
        props.font_family = self.options.family_id;
        props.use_monospace_font = self.options.family_id == 0;
        props.font_weight = self.options.weight;
        props.line_height = self.options.row_height / self.options.font_size;
        props.color = self.options.foreground;
        spans[0] = .{ .start = 0, .end = @intCast(self.preedit.len), .underline = true };
        props.spans = spans;
        props.spans_owned = true;
        self.preedit_node.setText(props);
        published = true;
        self.preedit_node.setBackground(self.options.background.withAlpha(@min(self.options.background.a, 64)));
        try absolute(self.cx, self.preedit_node, self.contentPadding().left + self.bodyX() + @as(f32, @floatFromInt(cursor.col)) * self.options.cell_width + self.command_caret_advance, self.presentationY(cursor.row), @max(self.options.cell_width, self.measured(self.preedit)), self.options.row_height);
    }
    fn bytePayload(item: Pending) ?[]u8 {
        return switch (item) { .bytes, .protocol => |bytes| bytes, else => null };
    }
    fn queueProtocolText(self: *Surface, bytes: []const u8) !void {
        return self.queueTextFrom(bytes, false);
    }
    pub fn queueText(self: *Surface, bytes: []const u8) !void {
        return self.queueTextFrom(bytes, true);
    }
    fn queueTextFrom(self: *Surface, bytes: []const u8, human: bool) !void {
        if (bytes.len == 0) return;
        if (self.snapshot == null or self.snapshot.?.read_only) return error.ReadOnlyTerminal;
        if (self.snapshot.?.projection.modes.keyboard_disabled) return error.KeyboardDisabled;
        const limit: usize = if (self.trusted_pending != null) terminal.trusted_edit.max_buffer else 1024 * 1024;
        if (self.pending.items.len >= 256 or self.pending_bytes > limit or bytes.len > limit - self.pending_bytes) return error.InputQueueFull;
        // Reserve before allocating bytes. After append, pending owns the
        // copy even if the first pump cannot acquire the worker guard.
        try self.pending.ensureUnusedCapacity(self.cx.allocator, 1);
        const owned = try self.cx.allocator.dupe(u8, bytes);
        if (self.timing) |trace| trace.begin(self.next_input + self.pending.items.len);
        self.pending.appendAssumeCapacity(if (human) .{ .bytes = owned } else .{ .protocol = owned });
        self.pending_bytes += bytes.len;
        self.pump() catch |err| {
            if (err != error.WorkerBusy) return err;
        };
    }
    pub fn requestTrustedEdit(self: *Surface, request: terminal.trusted_edit.Request) !void {
        if (self.pending.items.len != 0 or self.pending_paste != null or self.paste_requested != null or self.preedit.len != 0) return error.WorkerBusy;
        try self.service.trustedRequest(request);
        self.trusted_pending = request.operation;
    }
    pub fn cancelTrustedEdit(self: *Surface) !void {
        try self.service.cancelTrustedEdit();
        try self.recoverQueuedInput();
        self.trusted_pending = null;
    }
    fn recoverQueuedInput(self: *Surface) !void {
        for (self.pending.items) |item| if (item == .bytes) try self.recovered_input.appendSlice(self.cx.allocator, item.bytes);
        for (self.pending.items) |item| if (bytePayload(item)) |bytes| self.cx.allocator.free(bytes);
        self.pending.clearRetainingCapacity();
        self.pending_bytes = 0;
        self.cancelPaste();
    }
    pub fn noteUserInputAccepted(self: *Surface) void {
        self.user_input_revision +|= 1;
    }
    pub fn pump(self: *Surface) !void {
        defer if (self.pending.items.len > 0 or self.trusted_pending != null) self.cx.scheduleRedrawAfterNs(8 * std.time.ns_per_ms);
        const trusted_outcome = self.service.trustedOutcome() catch |err| {
            if (err == error.WorkerBusy) return;
            return err;
        };
        if (trusted_outcome) |outcome| {
            self.trusted_outcome = outcome;
            if (self.trusted_pending == outcome.operation) {
                self.trusted_pending = null;
                if (outcome.applied) self.noteUserInputAccepted();
                if (!outcome.applied) {
                    try self.recoverQueuedInput();
                    self.showError(error.TrustedEditRejected);
                }
            }
        }

        while (self.released_anchors.items.len > 0) {
            self.service.releaseAnchor(self.released_anchors.items[0]) catch |err| {
                if (err == error.WorkerBusy) break;
            };
            _ = self.released_anchors.orderedRemove(0);
        }
        while (self.service.takeWriteReceipt() catch |err| {
            if (err == error.WorkerBusy) return;
            return err;
        }) |receipt| {
            // Successful delivery updates input bookkeeping; a new viewport
            // arrives through publication. Do not clone/recompose the whole
            // screen once for a receipt and again for the shell's echo.
            if (receipt.state == .completed) {
                if (self.snapshot) |*snapshot| snapshot.input_revision = @max(snapshot.input_revision, receipt.input_sequence);
            } else self.force_snapshot = true;
            if (receipt.state == .failed) self.showError(if (receipt.failure == .stale_mode) error.StaleMode else error.TransportFailed);
        }
        while (self.pending.items.len > 0 and self.snapshot != null and !self.snapshot.?.read_only) {
            const item = self.pending.items[0];
            const mode = self.snapshot.?.projection.mode_revision;
            const admitted = switch (item) {
                .bytes, .protocol => |bytes| self.service.write(.{ .input_sequence = self.next_input, .mode_revision = mode, .bytes = bytes }),
                .key => |key| self.service.writeKey(.{ .input_sequence = self.next_input, .mode_revision = mode, .event = key }),
                .mouse => |request| value: {
                    var current = request;
                    current.input_sequence = self.next_input;
                    break :value self.service.writeMouse(current);
                },
            } catch |err| {
                if (err == error.WorkerBusy or err == error.InputFull or err == error.InputQueueFull or err == error.ReceiptQueueFull or err == error.TrustedEditPending) return;
                // These failures precede admission. Keep ordinary input in
                // order until refresh adopts the worker's modes/input epoch;
                // retrying an unaccepted item cannot duplicate a PTY write.
                if (item != .mouse and (err == error.StaleMode or err == error.StaleInput)) {
                    self.force_snapshot = true;
                    return;
                }
                if (bytePayload(item)) |bytes| {
                    self.pending_bytes -= bytes.len;
                    self.cx.allocator.free(bytes);
                }
                _ = self.pending.orderedRemove(0);
                self.showError(err);
                self.force_snapshot = true;
                continue;
            };
            if (item != .protocol and admitted.queued_bytes > 0) self.noteUserInputAccepted();
            if (self.shell_observer) |observer| switch (item) {
                .bytes => |bytes| observer.accepted(observer.context, self.owner, self.next_input, .{ .bytes = bytes }),
                .key => |key| observer.accepted(observer.context, self.owner, self.next_input, .{ .key = key }),
                .mouse, .protocol => {},
            };
            self.next_input = try std.math.add(u64, self.next_input, 1);
            if (bytePayload(item)) |bytes| {
                self.pending_bytes -= bytes.len;
                self.cx.allocator.free(bytes);
            }
            _ = self.pending.orderedRemove(0);
        }
        try input.pumpPaste(self);
    }
    pub fn showError(self: *Surface, err: anyerror) void {
        self.error_message = switch (err) {
            error.TrustedEditRejected => "Shell 编辑状态已变化；后续文字保留为本地草稿，提交键已取消。",
            error.TrustedEditUnavailable => "当前 Shell 尚未提供可信编辑能力。",
            error.StaleEdit => "Shell 输入已变化，请重新选择候选。",
            error.ClipboardUnavailable => "复制失败：剪贴板不可用。",
            error.InvalidPaste, error.PasteTooLarge => "粘贴未插入：请检查 UTF-8、1 MiB 上限及终端控制边界。",
            error.ReadOnlyTerminal => "当前会话只读，仍可选择和复制输出。",
            error.StaleOwner, error.StaleSession, error.StaleBinding => "原会话已失效，本次操作未转交其它终端。",
            error.StaleMode, error.StaleInput => "终端输入或模式已变化，请重新发起操作。",
            error.StaleProjection => "终端输出已更新，请在新画面上继续选择。",
            error.WorkerBusy, error.InputQueueFull, error.ReceiptQueueFull => "终端繁忙，请稍后重试。",
            error.KeyboardDisabled => "终端程序暂时停用了键盘输入。",
            error.ThemeApplyFailed => "主题尚未应用，终端保留上一次已生效的配色。",
            else => "终端操作未完成，请重试。",
        };
        self.error_until_ms = self.cx.frame_time_ms + 3000;
        self.message_root.setDisplay(.none);
        self.message.setDisplay(.none);
        self.feedback.publish(self.feedback.context, self.cx, self.owner, self.error_message.?) catch |publish_err| {
            std.log.debug("terminal error feedback unavailable: {s}", .{@errorName(publish_err)});
        };
    }

    /// Shared by drag-release, Cmd-C and the host's captured menu-copy path.
    /// The acknowledgement is published only after a real clipboard write.
    pub fn copySelectionToClipboard(self: *Surface, text: []const u8) !void {
        if (text.len == 0) return;
        const status = try self.service.status();
        if (!status.owner.eql(self.owner)) return error.StaleOwner;
        if (!ui.platform_services.clipboardSetText(self.cx.system_sdk, text)) return error.ClipboardUnavailable;
    }
    fn publishFeedback(_: ?*anyopaque, cx: *ui.Cx, owner: identity.SessionHandle, summary: []const u8) !void {
        try @import("plugin_window_host.zig").Host.publishFailure(cx, owner, summary);
    }
    // Input, selection and IME callbacks are below; they use only this binding.
    fn onKey(key: ui.events.KeyCode, modifiers: ui.events.Modifiers, raw: ?*anyopaque) ui.events.EventResult {
        const self: *Surface = @ptrCast(@alignCast(raw orelse return .ignored));
        if (self.cx.focus_manager.getFocused() != self.host) return .ignored;
        if (key == .c and modifiers.ctrl and !modifiers.alt and !modifiers.super) {
            self.cancelTrustedEdit() catch |err| {
                self.showError(err);
                return .stop;
            };
        }
        if (self.preedit.len == 0 and self.pending_paste == null and self.paste_requested == null) if (self.enhancement) |handler| {
            if (handler.key(handler.context, key, modifiers)) return .stop;
        };
        return input.onKey(self, key, modifiers);
    }
    fn captureLost(node: *ui.Node) void {
        const self: *Surface = @ptrCast(@alignCast(node.behavior.events.event_context orelse return));
        self.dragging = false;
        self.mouse_reporting = false;
        self.reported_button = .none;
    }
    pub fn releaseAnchorLater(self: *Surface, anchor: terminal.Anchor) void {
        self.service.releaseAnchor(anchor) catch |err| {
            if (err == error.WorkerBusy) self.released_anchors.append(self.cx.allocator, anchor) catch {};
        };
    }
    fn onEvent(event: ui.events.Event, raw: ?*anyopaque) ui.events.EventResult {
        const self: *Surface = @ptrCast(@alignCast(raw orelse return .ignored));
        if (self.enhancement) |handler| if (handler.event) |callback| if (callback(handler.context, event)) |result| return result;
        switch (event) {
            .key_down, .key_up, .text_input, .ime_preedit, .ime_commit => {
                if (self.cx.focus_manager.getFocused() != self.host) return .ignored;
            },
            // Pointer capture is deliberately held by the original host, so
            // an active canvas drag still receives release outside its rect.
            .mouse_move, .mouse_up => if (!self.dragging and !self.mouse_reporting) return .ignored,
            .mouse_down, .click, .scroll => return .ignored,
            else => {},
        }
        switch (event) {
            .text_input => |value| if (self.preedit.len == 0 and self.pending_paste == null and self.paste_requested == null) {
                if (self.glyphs_pending and value.text.len > 0) self.input_during_hydration +|= 1;
                if (self.enhancement) |handler| if (handler.text(handler.context, value.text)) return .stop;
            },
            .ime_commit => |value| if (self.pending_paste == null and self.paste_requested == null) {
                if (self.glyphs_pending and value.text.len > 0) self.input_during_hydration +|= 1;
                self.setPreedit("");
                if (self.enhancement) |handler| if (handler.text(handler.context, value.text)) return .stop;
            },
            else => {},
        }
        return input.onEvent(self, event);
    }
    fn onCanvasEvent(event: ui.events.Event, raw: ?*anyopaque) ui.events.EventResult {
        const self: *Surface = @ptrCast(@alignCast(raw orelse return .ignored));
        if (self.control_grant != null) if (self.control_tag) |tag| {
            const point: ?ui.Point = switch (event) {
                .mouse_down, .mouse_up => |mouse| .{ .x = mouse.x, .y = mouse.y },
                .mouse_move => |mouse| .{ .x = mouse.x, .y = mouse.y },
                .double_click => |mouse| .{ .x = mouse.x, .y = mouse.y },
                else => null,
            };
            if (point) |p| if (tag.globalRect().contains(p.x, p.y)) return .stop;
        };
        return switch (event) {
            .mouse_down, .mouse_move, .mouse_up, .double_click => input.onEvent(self, event),
            // The specialized callback declares the canvas as a scroll owner.
            // Deliver a wheel event exactly once after generic dispatch.
            else => .ignored,
        };
    }
    fn onScroll(event: ui.events.ScrollEvent, raw: ?*anyopaque) ui.events.EventResult {
        return input.onEvent(@ptrCast(@alignCast(raw orelse return .ignored)), .{ .scroll = event });
    }
    fn textLen(raw: *anyopaque) usize {
        const self: *Surface = @ptrCast(@alignCast(raw));
        return self.document.items.len;
    }
    fn copyText(raw: *anyopaque, offset: usize, out: []u8) usize {
        const self: *Surface = @ptrCast(@alignCast(raw));
        if (offset >= self.document.items.len) return 0;
        const count = @min(out.len, self.document.items.len - offset);
        @memcpy(out[0..count], self.document.items[offset..][0..count]);
        return count;
    }
    fn imeSelection(raw: *anyopaque) ui.TextInputSelection {
        const self: *Surface = @ptrCast(@alignCast(raw));
        const caret = self.caret_byte + self.preedit_cursor;
        return .{ .start = caret, .end = caret, .caret = caret };
    }
    fn frameForRange(raw: *anyopaque, start: u32, end: u32, out: *ui.types.A11yRect) bool {
        return input.frameForRange(@ptrCast(@alignCast(raw)), start, end, out);
    }
    fn rangeAtPoint(raw: *anyopaque, x: f32, y: f32, start: *u32, end: *u32) bool {
        return input.rangeAtPoint(@ptrCast(@alignCast(raw)), x, y, start, end);
    }
    pub fn clearSelection(self: *Surface) void {
        input.clearSelection(self);
    }
    fn cancelPaste(self: *Surface) void {
        input.cancelPaste(self);
    }
    fn renderSelection(self: *Surface) !void {
        try input.renderSelection(self);
    }
    fn buildDocument(self: *Surface) !void {
        const version = if (self.snapshot) |value| value.projection.version else return;
        if (self.document_version == version) return;
        try input.buildDocument(self);
        self.document_version = version;
    }
    pub fn requestPaste(self: *Surface, bytes: []const u8) !void {
        try input.requestPaste(self, bytes);
    }
    pub fn hasSelection(self: *Surface) !bool {
        return input.hasSelection(self);
    }
    pub fn copySelectionText(self: *Surface, allocator: std.mem.Allocator) !?[]u8 {
        return input.copySelectionText(self, allocator);
    }
};

fn asciiCell(cell: vt.Cell, projection: *const vt.Projection) bool {
    const text = projection.grapheme(cell);
    return cell.width == .single and text.len == 1 and text[0] >= ' ' and text[0] <= '~';
}
fn sameCellStyle(a: vt.Cell, b: vt.Cell) bool {
    return a.attributes == b.attributes and a.underline == b.underline and
        std.meta.eql(a.foreground, b.foreground) and std.meta.eql(a.background, b.background) and
        std.meta.eql(a.underline_color, b.underline_color);
}

pub fn resolveColor(value: vt.Color, fallback: ui.Color, colors: vt.Colors) ui.Color {
    return switch (value) {
        .default => fallback,
        .rgb => |rgb| ui.Color.hex(rgb),
        .ansi => |index| ui.Color.hex(colors.palette[index]),
        .indexed => |index| ui.Color.hex(colors.palette[index]),
    };
}
fn rgba(value: u32) ui.Color {
    return .{ .r = @truncate(value >> 24), .g = @truncate(value >> 16), .b = @truncate(value >> 8), .a = @truncate(value) };
}
pub fn absolute(cx: *ui.Cx, node: *ui.Node, x: f32, y: f32, w: f32, h: f32) !void {
    const ext = try node.style.ensureExtFallible(cx.allocator);
    const inset: ui.Inset = .{ .left = .{ .px = x }, .top = .{ .px = y } };
    if (node.style.position == .absolute and std.meta.eql(ext.inset, inset) and std.meta.eql(node.style.width, ui.Sizing{ .px = w }) and std.meta.eql(node.style.height, ui.Sizing{ .px = h })) return;
    node.style.position = .absolute;
    ext.inset = inset;
    node.style.width = .{ .px = w };
    node.style.height = .{ .px = h };
    node.markLayoutDirty();
}
fn leaf(cx: *ui.Cx, color: ui.Color) !*ui.Node {
    const node = try ui.box(cx, .{ .position = .absolute, .background = color }, .{});
    node.setDisplay(.none);
    return node;
}
