//! Presentation contract tests using the real Ghostty engine and public zenit
//! tree, without a window or process. Real PTY integration is test-local.
const std = @import("std");
const ui = @import("ui");
const View = @import("terminal_view.zig").TerminalViewNode;
const Surface = @import("terminal_surface.zig").Surface;
const terminal = @import("../host/terminal_service.zig");
const host = @import("../host/session_host.zig");
const identity = @import("../host/identity.zig");
const Adapter = @import("../vt/ghostty_adapter.zig").Adapter;
const Controller = @import("../vt/terminal_controller.zig").Controller;
const Engine = @import("../vt/engine.zig").VtEngine;
const TextSlot = @import("../vt/text_slot.zig").TextSlot;
const a = std.testing.allocator;
pub const owner: identity.SessionHandle = .{ .session_id = @fromBackingInt(701), .generation = 3 };
pub const binding: host.ServiceHandle = .{ .resource_owner = .{ .session = owner }, .origin_session = owner, .kind = .terminal, .binding_id = 1, .binding_generation = 1 };

test "idle terminal surface settles interaction dirtiness after a filled viewport is cleared" {
    var transport: FakeTransport = undefined;
    try transport.init(4, 16);
    defer transport.deinit();
    const cx = try ui.Cx.init(a, std.testing.io);
    defer cx.deinit();
    cx.setViewport(800, 400);
    var view = try View.mount(cx);
    cx.root = view.root;
    defer view.releaseBuffers(cx);
    try view.bindTerminalService(transport.service());
    for ([_][]const u8{ "abcdefghijklmnop\r\n0123456789\r\nfilled", "\x1b[2J\x1b[Hshort" }, 1..) |bytes, sequence| {
        try transport.controller.feedOutput(owner, sequence, bytes, @as(i64, @intCast(sequence)) * 100);
        for (0..4) |_| {
            cx.requestRedraw();
            cx.advanceFrameClock();
            cx.layout();
            _ = try view.refreshTerminalService(owner, false);
            _ = cx.render();
        }
        try std.testing.expect(!cx.hasPendingSceneWork());
    }
}

test "idle terminal surface retries a consumed publication after a busy snapshot" {
    var transport: FakeTransport = undefined;
    try transport.init(4, 16);
    defer transport.deinit();
    const cx = try ui.Cx.init(a, std.testing.io);
    defer cx.deinit();
    cx.setViewport(800, 400);
    var view = try View.mount(cx);
    cx.root = view.root;
    defer view.releaseBuffers(cx);
    try view.bindTerminalService(transport.service());
    _ = cx.render();
    _ = try view.refreshTerminalService(owner, false);
    const surface = view.terminal_surface.?;
    for ([_]anyerror{ error.WorkerBusy, error.SnapshotUnavailable }, 1..) |failure, sequence| {
        try transport.controller.feedOutput(owner, sequence, "LATEST", @as(i64, @intCast(sequence)) * 100);
        transport.snapshot_error = failure;
        cx.next_redraw_scheduled_at = null;
        cx.next_redraw_delay_ns = null;
        _ = try view.refreshTerminalService(owner, false);
        try std.testing.expectEqual(transport.slot.generation.load(.acquire), surface.slot_generation);
        try std.testing.expect(surface.force_snapshot);
        try std.testing.expect(cx.nextWakeDelayNs().? <= 8 * std.time.ns_per_ms);
        transport.snapshot_error = null;
        _ = try view.refreshTerminalService(owner, false);
        try std.testing.expect(!surface.force_snapshot);
        try std.testing.expect(std.mem.indexOf(u8, surface.document.items, "LATEST") != null);
    }
}

pub const FakeTransport = struct {
    vt: Adapter,
    slot: TextSlot,
    controller: Controller,
    written: std.ArrayList(u8) = .empty,
    sequence: u64 = 0,
    resize_calls: usize = 0,
    scroll_calls: usize = 0,
    read_only: bool = false,
    busy: bool = false,
    receipt_busy: bool = false,
    snapshot_error: ?anyerror = null,
    defer_theme: bool = false,
    queued_theme: ?terminal.Theme = null,
    pub fn init(self: *FakeTransport, rows: u16, cols: u16) !void {
        self.* = .{ .vt = try Adapter.init(a, rows, cols), .slot = try TextSlot.init(a, TextSlot.default_capacity), .controller = undefined };
        self.controller = try Controller.init(.{ .owner = owner, .engine = Engine.from(Adapter, &self.vt), .text_slot = &self.slot });
    }
    pub fn deinit(self: *FakeTransport) void {
        self.written.deinit(a);
        self.slot.deinit(a);
        self.vt.destroy();
    }
    pub fn service(self: *FakeTransport) terminal.Service {
        return .{ .binding = binding, .context = self, .vtable = &vtable };
    }
    fn get(raw: *anyopaque) *FakeTransport {
        return @ptrCast(@alignCast(raw));
    }
    fn write(raw: *anyopaque, _: host.ServiceHandle, request: terminal.WriteRequest) !terminal.Submission {
        const self = get(raw);
        if (self.busy) return error.WorkerBusy;
        if (self.read_only) return error.ReadOnlyTerminal;
        if (request.input_sequence <= self.sequence) return error.StaleInput;
        if (request.mode_revision != self.vt.snapshot().mode_revision) return error.StaleMode;
        try self.written.appendSlice(a, request.bytes);
        self.sequence = request.input_sequence;
        return .{ .input_sequence = request.input_sequence, .queued_bytes = request.bytes.len };
    }
    fn resize(raw: *anyopaque, _: host.ServiceHandle, geometry: terminal.Geometry) !void {
        const self = get(raw);
        try self.controller.resizeApplied(owner, geometry, 1);
        self.resize_calls += 1;
    }
    fn read(_: *anyopaque, _: host.ServiceHandle, _: []u8) !terminal.Read {
        return error.ViewMustNotReadRawOutput;
    }
    fn receipt(raw: *anyopaque, _: host.ServiceHandle) !?terminal.WriteReceipt {
        if (get(raw).receipt_busy) return error.WorkerBusy;
        return null;
    }
    fn status(raw: *anyopaque, _: host.ServiceHandle) !terminal.Status {
        const self = get(raw);
        if (self.busy) return error.WorkerBusy;
        const state = self.controller.status();
        const scalar = self.vt.snapshot();
        return .{ .owner = owner, .writable = !self.read_only, .eof_seen = self.read_only, .geometry = state.geometry, .output_sequence = state.output_sequence, .pending_input_bytes = 0, .mode_revision = scalar.mode_revision, .modes = scalar.modes, .applied_theme_revision = if (self.controller.theme) |theme| theme.revision else 0 };
    }
    fn text(raw: *anyopaque, _: host.ServiceHandle) !*TextSlot {
        return &get(raw).slot;
    }
    fn snapshot(raw: *anyopaque, _: host.ServiceHandle, allocator: std.mem.Allocator) !terminal.TerminalSnapshot {
        const self = get(raw);
        if (self.snapshot_error) |err| return err;
        return .{ .owner = owner, .geometry_revision = self.controller.geometry.revision, .input_revision = self.sequence, .read_only = self.read_only, .eof_seen = self.read_only, .projection = try self.controller.copyProjection(owner, allocator), .applied_theme_revision = if (self.controller.theme) |theme| theme.revision else 0 };
    }
    fn searchSnapshot(raw: *anyopaque, _: host.ServiceHandle, allocator: std.mem.Allocator) !terminal.SearchSnapshot {
        const self = get(raw);
        if (self.busy) return error.WorkerBusy;
        return .{ .owner = owner, .document = try self.controller.searchSnapshot(owner, allocator) };
    }
    fn prepare(raw: *anyopaque, _: host.ServiceHandle, allocator: std.mem.Allocator, bytes: []const u8) !terminal.Paste {
        const self = get(raw);
        if (self.busy) return error.WorkerBusy;
        const decision = (terminal.PastePolicy{}).inspect(bytes);
        if (decision == .reject) return error.InvalidPaste;
        return .{ .binding = binding, .input_revision = self.sequence, .mode_revision = self.vt.snapshot().mode_revision, .text = try allocator.dupe(u8, bytes), .requires_confirmation = decision == .confirm };
    }
    fn commit(raw: *anyopaque, _: host.ServiceHandle, paste: terminal.Paste, seq: u64, confirmed: bool) !terminal.Submission {
        const self = get(raw);
        if (paste.input_revision != self.sequence) return error.StaleInput;
        if (paste.requires_confirmation and !confirmed) return error.ConfirmationRequired;
        return write(raw, binding, .{ .input_sequence = seq, .mode_revision = paste.mode_revision, .bytes = paste.text });
    }
    fn key(raw: *anyopaque, _: host.ServiceHandle, request: terminal.KeyRequest) !terminal.Submission {
        const self = get(raw);
        const bytes = try self.controller.encodeKey(owner, request.mode_revision, request.event, a);
        defer a.free(bytes);
        if (bytes.len == 0) {
            self.sequence = request.input_sequence;
            return .{ .input_sequence = request.input_sequence, .queued_bytes = 0 };
        }
        return write(raw, binding, .{ .input_sequence = request.input_sequence, .mode_revision = request.mode_revision, .bytes = bytes });
    }
    fn mouse(raw: *anyopaque, _: host.ServiceHandle, request: terminal.MouseRequest) !terminal.Submission {
        const self = get(raw);
        const bytes = try self.controller.encodeMouse(owner, request.mode_revision, request.geometry_revision, request.event, a);
        defer a.free(bytes);
        return write(raw, binding, .{ .input_sequence = request.input_sequence, .mode_revision = request.mode_revision, .bytes = bytes });
    }
    fn createAnchor(raw: *anyopaque, _: host.ServiceHandle, point: terminal.Point) !terminal.Anchor {
        const self = get(raw);
        if (self.busy) return error.WorkerBusy;
        return self.controller.createAnchor(owner, point);
    }
    fn resolveAnchor(raw: *anyopaque, _: host.ServiceHandle, anchor: terminal.Anchor) !?terminal.AnchorPosition {
        const self = get(raw);
        if (self.busy) return error.WorkerBusy;
        return self.controller.resolveAnchor(anchor);
    }
    fn releaseAnchor(raw: *anyopaque, _: host.ServiceHandle, anchor: terminal.Anchor) !void {
        try get(raw).controller.releaseAnchor(anchor);
    }
    fn selectionText(raw: *anyopaque, _: host.ServiceHandle, selection: terminal.Selection, allocator: std.mem.Allocator, limit: usize) ![]u8 {
        return get(raw).controller.selectionText(selection, allocator, limit);
    }
    fn scroll(raw: *anyopaque, _: host.ServiceHandle, request: terminal.Scroll) !void {
        const self = get(raw);
        try self.controller.scroll(owner, request, 1);
        self.scroll_calls += 1;
    }
    fn lines(raw: *anyopaque, _: host.ServiceHandle, limits: terminal.LineLimits, allocator: std.mem.Allocator) !terminal.Lines {
        return get(raw).controller.readLines(owner, limits, allocator);
    }
    fn applyTheme(raw: *anyopaque, _: host.ServiceHandle, value: terminal.Theme) !void {
        const self = get(raw);
        if (self.busy) return error.WorkerBusy;
        if (self.defer_theme) {
            self.queued_theme = value;
            return;
        }
        try self.controller.setTheme(owner, value, 1);
    }
    const vtable: terminal.Service.VTable = .{ .write = write, .resize = resize, .read = read, .receipt = receipt, .status = status, .text_slot = text, .snapshot = snapshot, .prepare_paste = prepare, .commit_paste = commit, .key = key, .mouse = mouse, .create_anchor = createAnchor, .resolve_anchor = resolveAnchor, .release_anchor = releaseAnchor, .selection_text = selectionText, .scroll = scroll, .read_lines = lines, .theme = applyTheme, .search_snapshot = searchSnapshot };
};

// Derive the public backend types from Cx's injected SDK; the application test
// module intentionally has no additional direct SDK dependency.
const TestSdk = @typeInfo(@typeInfo(@FieldType(ui.Cx, "system_sdk")).optional.child).pointer.child;
const TestBackendVTable = @typeInfo(@FieldType(TestSdk, "vtable")).pointer.child;
const TestPump = @typeInfo(@FieldType(TestBackendVTable, "pump_events")).pointer.child;
const TestClipboard = struct {
    text: []const u8 = "PASTE",
    copied: [128]u8 = undefined,
    copied_len: usize = 0,
    reads: usize = 0,
    writes: usize = 0,
    fail_set: bool = false,
    fn deinit(_: *anyopaque, _: std.mem.Allocator) void {}
    fn pump(_: *anyopaque, _: @typeInfo(TestPump).@"fn".param_types[1].?, _: u32) @typeInfo(TestPump).@"fn".return_type.? {
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
        const self: *@This() = @ptrCast(@alignCast(raw));
        return self.text.len;
    }
    const vtable: TestBackendVTable = .{ .name = "terminal-selection-test", .deinit = deinit, .pump_events = pump, .clipboard = .{ .set_text = set, .get_text = get, .get_text_len = len } };
};

test "terminal surface binds real owned VT projection and preserves over sixty rows with exact gutter" {
    var transport: FakeTransport = undefined;
    try transport.init(70, 16);
    defer transport.deinit();
    try transport.controller.feedOutput(owner, 1, "\x1b[38;2;0;0;0mA界e\u{301}👩‍💻\x1b[48;2;255;255;255m   ", 1);
    const cx = try ui.Cx.init(a, std.testing.io);
    defer cx.deinit();
    cx.setViewport(800, 1700);
    var view = try View.mount(cx);
    cx.root = view.root;
    defer view.releaseBuffers(cx);
    view.setTypography(14, 22.0 / 14.0, 400);
    view.setTimestampGutter(true);
    try view.bindTerminalService(transport.service());
    _ = cx.render();
    _ = try view.refreshTerminalService(owner, false);
    _ = cx.render();
    const surface = view.terminal_surface.?;
    try std.testing.expectEqual(@as(usize, 70), surface.rows.items.len);
    const glyph = surface.rows.items[0].glyphs.items[0].node;
    try std.testing.expectEqual(@as(f32, 76), glyph.globalRect().x);
    try std.testing.expectEqual(@as(f32, 8), glyph.globalRect().y);
    try std.testing.expectEqual(@as(u8, 0), glyph.getText().?.color.r);
    try std.testing.expectEqualStrings("界", surface.rows.items[0].glyphs.items[1].node.getText().?.content);
    try std.testing.expectEqualStrings("e\u{301}", surface.rows.items[0].glyphs.items[2].node.getText().?.content);
    try std.testing.expectEqualStrings("👩‍💻", surface.rows.items[0].glyphs.items[3].node.getText().?.content);
    view.unbindTerminalService(try owner.nextGeneration());
    try std.testing.expect(view.terminal_surface != null);
    view.unbindTerminalService(owner);
    try std.testing.expect(view.terminal_surface == null);
}

test "terminal surface waits for actual theme receipt before adopting effective VT colors" {
    var transport: FakeTransport = undefined;
    try transport.init(3, 16);
    defer transport.deinit();
    try transport.controller.feedOutput(owner, 1, "plain \x1b[31mred", 1);
    const cx = try ui.Cx.init(a, std.testing.io);
    defer cx.deinit();
    cx.setViewport(600, 160);
    var view = try View.mount(cx);
    cx.root = view.root;
    defer view.releaseBuffers(cx);
    const first: terminal.Theme = .{ .revision = 1, .foreground = 0x123456ff, .background = 0x060608ff, .cursor = 0x777777ff, .selection = 0x22222240, .ansi = @splat(0x990000ff) };
    var next = first;
    next.revision = 2;
    next.foreground = 0xabcdefFF;
    next.ansi[1] = 0x12ab34ff;
    try view.setTerminalTheme(first);
    cx.needs_redraw = false;
    try view.setTerminalTheme(first);
    try std.testing.expect(!cx.needs_redraw);
    var conflicting = first;
    conflicting.foreground = 0xffffffff;
    try std.testing.expectError(error.ConflictingTheme, view.setTerminalTheme(conflicting));
    try std.testing.expect(!cx.needs_redraw);
    try view.bindTerminalService(transport.service());
    _ = cx.render();
    _ = try view.refreshTerminalService(owner, false);
    const surface = view.terminal_surface.?;
    try std.testing.expectEqual(@as(u64, 1), view.terminalSnapshot(owner).?.applied_theme_revision);
    try std.testing.expectEqual(ui.Color.hex(0x123456), surface.rows.items[0].glyphs.items[0].node.getText().?.color);
    transport.defer_theme = true;
    cx.needs_redraw = false;
    try view.setTerminalTheme(next);
    try std.testing.expect(cx.needs_redraw);
    _ = try view.refreshTerminalService(owner, false);
    try std.testing.expectEqual(@as(u64, 1), view.terminalSnapshot(owner).?.applied_theme_revision);
    try std.testing.expectEqual(ui.Color.hex(0x123456), surface.rows.items[0].glyphs.items[0].node.getText().?.color);
    try std.testing.expectEqual(@as(usize, 0), transport.written.items.len);
    try transport.controller.setTheme(owner, transport.queued_theme.?, 2);
    _ = try view.refreshTerminalService(owner, false);
    try std.testing.expectEqual(@as(u64, 2), view.terminalSnapshot(owner).?.applied_theme_revision);
    try std.testing.expectEqual(ui.Color.hex(0xabcdef), surface.rows.items[0].glyphs.items[0].node.getText().?.color);
    try std.testing.expectEqual(ui.Color.hex(0x12ab34), surface.rows.items[0].glyphs.items[6].node.getText().?.color);
    try std.testing.expectError(error.StaleTheme, view.setTerminalTheme(first));
}

test "terminal surface row query ids stay owned across pool growth shrink and teardown" {
    var transport: FakeTransport = undefined;
    try transport.init(70, 16);
    defer transport.deinit();
    try transport.controller.feedOutput(owner, 1, "row identity", 1);
    const cx = try ui.Cx.init(a, std.testing.io);
    defer cx.deinit();
    cx.setViewport(800, 1700);
    var view = try View.mount(cx);
    cx.root = view.root;
    defer view.releaseBuffers(cx);
    try view.bindTerminalService(transport.service());
    _ = cx.render();
    _ = try view.refreshTerminalService(owner, false);
    const surface = view.terminal_surface.?;
    const first_id = surface.rows.items[0].root.meta.ownership.meta.test_id.?.ptr;
    for ([_]u16{ 70, 2, 80 }) |count| {
        if (count != 70) {
            try transport.controller.resizeApplied(owner, .{ .revision = transport.controller.geometry.revision + 1, .cols = 16, .rows = count }, 2);
            _ = try view.refreshTerminalService(owner, false);
        }
        try std.testing.expectEqual(@as(usize, count), surface.rows.items.len);
        try std.testing.expectEqual(first_id, surface.rows.items[0].root.meta.ownership.meta.test_id.?.ptr);
        for (surface.rows.items, 0..) |row, index| {
            var buffer: [64]u8 = undefined;
            const expected = try std.fmt.bufPrint(&buffer, "terminal.surface.row.{d}", .{index});
            try std.testing.expectEqualStrings(expected, row.root.meta.ownership.meta.test_id.?);
        }
    }
    view.unbindTerminalService(owner);
    try std.testing.expect(view.terminal_surface == null);
}

test "terminal surface public Cx wheel hit converts native positive up to Ghostty rows once" {
    var transport: FakeTransport = undefined;
    try transport.init(3, 16);
    defer transport.deinit();
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(a);
    for (0..40) |index| {
        var line: [32]u8 = undefined;
        try output.appendSlice(a, try std.fmt.bufPrint(&line, "ROW_{d:0>3}\r\n", .{index}));
    }
    try transport.controller.feedOutput(owner, 1, output.items, 1);
    const cx = try ui.Cx.init(a, std.testing.io);
    defer cx.deinit();
    cx.setViewport(400, 100);
    var view = try View.mount(cx);
    cx.root = view.root;
    defer view.releaseBuffers(cx);
    try view.bindTerminalService(transport.service());
    _ = cx.render();
    _ = try view.refreshTerminalService(owner, false);
    _ = cx.render();
    const surface = view.terminal_surface.?;
    const bottom = view.terminalSnapshot(owner).?.projection.scrollback.viewport_offset;
    try std.testing.expect(bottom > 2);
    const bounds = surface.root.globalRect();
    // Use the same Cx API as native wheel delivery and the public Harness.
    // Directly invoking an event callback would miss the scroll-owner bug.
    cx.handleScroll(.{ .x = bounds.x + bounds.w * 0.6, .y = bounds.y + bounds.h * 0.5, .dx = 0, .dy = 2 * surface.options.row_height });
    _ = try view.refreshTerminalService(owner, false);
    try std.testing.expectEqual(bottom - 2, view.terminalSnapshot(owner).?.projection.scrollback.viewport_offset);
    try std.testing.expectEqual(@as(usize, 1), transport.scroll_calls);
    cx.handleScroll(.{ .x = bounds.x + bounds.w * 0.6, .y = bounds.y + bounds.h * 0.5, .dx = 0, .dy = -2 * surface.options.row_height });
    _ = try view.refreshTerminalService(owner, false);
    try std.testing.expectEqual(bottom, view.terminalSnapshot(owner).?.projection.scrollback.viewport_offset);
    try std.testing.expectEqual(@as(usize, 2), transport.scroll_calls);
    view.unbindTerminalService(owner);
    try std.testing.expect(view.root.behavior.events.on_scroll == null);
}

test "terminal surface prepared registry face keeps glyph IME metrics and grid stable across theme application" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    const NativeSystem = @typeInfo(@typeInfo(@TypeOf(@as(ui.Cx, undefined).text.font_system)).optional.child).pointer.child;
    const FontPointer = @typeInfo(@typeInfo(@TypeOf(NativeSystem.findFont)).@"fn".return_type.?).error_union.payload;
    var system = try NativeSystem.init(a, std.testing.io);
    defer system.deinit();
    const face = try system.findFont(.{ .family = "Menlo", .size = 14, .weight = .regular });
    defer face.deinit();
    const FaceProvider = struct {
        face: FontPointer,
        calls: usize = 0,
        family_id: u16 = 0,
        semantic_mono: bool = true,
        fn resolve(raw: *anyopaque, options: ui.Cx.ShapeTextOpts) ?FontPointer {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.calls += 1;
            self.family_id = options.font_family_id;
            self.semantic_mono = options.use_monospace;
            return self.face;
        }
    };
    var provider: FaceProvider = .{ .face = face };
    var transport: FakeTransport = undefined;
    try transport.init(3, 16);
    defer transport.deinit();
    try transport.controller.feedOutput(owner, 1, "MMMM", 1);
    const cx = try ui.Cx.init(a, std.testing.io);
    defer cx.deinit();
    cx.text.setFontSystem(&system);
    cx.text.font_resolve_fn = FaceProvider.resolve;
    cx.text.font_resolve_ctx = &provider;
    cx.setViewport(600, 160);
    var view = try View.mount(cx);
    cx.root = view.root;
    defer view.releaseBuffers(cx);
    const previous_calls = provider.calls;
    try view.setTypographyFamily(14, 22.0 / 14.0, 400, "Menlo", 42);
    try std.testing.expect(provider.calls > previous_calls);
    try std.testing.expectEqual(@as(u16, 42), provider.family_id);
    try std.testing.expect(!provider.semantic_mono);
    const cell_width = face.measureWidth("M");
    try std.testing.expectApproxEqAbs(cell_width, view.cell_width, 0.001);
    view.setTimestampGutter(true);
    try view.bindTerminalService(transport.service());
    _ = cx.render();
    cx.setFocus(view.root);
    _ = try view.refreshTerminalService(owner, true);
    _ = try view.refreshTerminalService(owner, true);
    const surface = view.terminal_surface.?;
    const old_cols = surface.snapshot.?.projection.cols;
    const old_geometry = surface.snapshot.?.geometry_revision;
    const old_resize_calls = transport.resize_calls;
    surface.setPreedit("MM");
    try std.testing.expectApproxEqAbs(2 * cell_width, surface.measured("MM"), 0.001);
    try std.testing.expect(!surface.preedit_node.getText().?.use_monospace_font);
    try std.testing.expectEqual(@as(u16, 42), surface.preedit_node.getText().?.font_family);
    const glyph = surface.rows.items[0].glyphs.items[0].node;
    try std.testing.expect(!glyph.getText().?.use_monospace_font);
    try std.testing.expectEqual(@as(u16, 42), glyph.getText().?.font_family);
    try std.testing.expect(!surface.rows.items[0].time.getText().?.use_monospace_font);

    // This is the same typography tuple main re-publishes on a theme change.
    try view.setTypographyFamily(14, 22.0 / 14.0, 400, "Menlo", 42);
    view.setThemeColors(ui.Color.hex(0xd8dee9), ui.Color.hex(0x4c566a), ui.Color.hex(0x88c0d0));
    try view.setTerminalTheme(.{ .revision = 1, .foreground = 0xd8dee9ff, .background = 0x2e3440ff, .cursor = 0x88c0d0ff, .selection = 0x4c566a80, .ansi = @splat(0x88c0d0ff) });
    _ = try view.refreshTerminalService(owner, true);
    _ = try view.refreshTerminalService(owner, true);
    try std.testing.expectApproxEqAbs(cell_width, view.cell_width, 0.001);
    try std.testing.expectEqual(old_cols, surface.snapshot.?.projection.cols);
    try std.testing.expectEqual(old_geometry, surface.snapshot.?.geometry_revision);
    try std.testing.expectEqual(old_resize_calls, transport.resize_calls);
    try std.testing.expectEqualStrings("MM", surface.preedit);
    try std.testing.expect(!glyph.getText().?.use_monospace_font);
}

test "terminal surface native input queues once across busy service and exposes actual caret IME range" {
    var transport: FakeTransport = undefined;
    try transport.init(3, 16);
    defer transport.deinit();
    try transport.controller.feedOutput(owner, 1, "a界\x1b[1;2H", 1);
    const cx = try ui.Cx.init(a, std.testing.io);
    defer cx.deinit();
    cx.setViewport(600, 160);
    var view = try View.mount(cx);
    cx.root = view.root;
    defer view.releaseBuffers(cx);
    try view.bindTerminalService(transport.service());
    _ = cx.render();
    _ = try view.refreshTerminalService(owner, false);
    cx.setFocus(view.root);
    const surface = view.terminal_surface.?;
    transport.busy = true;
    try surface.queueText("中文");
    try std.testing.expectEqual(@as(usize, 0), transport.written.items.len);
    transport.busy = false;
    try surface.pump();
    try std.testing.expectEqualStrings("中文", transport.written.items);
    _ = view.root.behavior.events.on_key_down.?(.tab, .{ .shift = true }, view.root.behavior.events.key_context);
    try std.testing.expectEqualStrings("中文\x1b[Z", transport.written.items);
    _ = view.root.behavior.events.on_key_down.?(.c, .{ .ctrl = true }, view.root.behavior.events.key_context);
    try std.testing.expectEqualStrings("中文\x1b[Z\x03", transport.written.items);
    _ = view.root.behavior.events.on_event.?(.{ .ime_preedit = .{ .text = "候选" } }, view.root.behavior.events.event_context);
    try std.testing.expectEqual(@as(usize, "中文\x1b[Z\x03".len), transport.written.items.len);
    const client = view.root.behavior.interaction.text_input_client.?;
    var frame: ui.types.A11yRect = undefined;
    try std.testing.expect(client.frame_for_range.?(client.context, surface.caret_byte, surface.caret_byte, &frame));
    try std.testing.expectEqual(surface.root.globalRect().x + 8 + view.cell_width, frame.x);
    _ = view.root.behavior.events.on_event.?(.{ .ime_commit = .{ .text = "候选" } }, view.root.behavior.events.event_context);
    try std.testing.expectEqualStrings("中文\x1b[Z\x03候选", transport.written.items);
    try view.pasteTerminalText(owner, "a\nb");
    try std.testing.expect(surface.pending_paste != null and surface.modal_open.?.get());
    const before = transport.written.items.len;
    transport.read_only = true;
    _ = try view.refreshTerminalService(owner, false);
    try std.testing.expectEqual(before, transport.written.items.len);
    try std.testing.expect(view.terminalSnapshot(owner).?.read_only);
    try std.testing.expectError(error.ReadOnlyTerminal, surface.queueText("no"));
}

test "terminal surface queued text owns its copy across pump receipt backpressure" {
    var transport: FakeTransport = undefined;
    try transport.init(3, 16);
    defer transport.deinit();
    const cx = try ui.Cx.init(a, std.testing.io);
    defer cx.deinit();
    cx.setViewport(600, 160);
    var view = try View.mount(cx);
    cx.root = view.root;
    defer view.releaseBuffers(cx);
    try view.bindTerminalService(transport.service());
    _ = try view.refreshTerminalService(owner, true);
    const surface = view.terminal_surface.?;
    transport.receipt_busy = true;
    var first = "echo original".*;
    try surface.queueText(&first);
    @memset(&first, 'x');
    try surface.queueText(" next");
    try std.testing.expectEqual(@as(usize, 2), surface.pending.items.len);
    try std.testing.expectEqualStrings("echo original", surface.pending.items[0].bytes);
    try std.testing.expectEqualStrings(" next", surface.pending.items[1].bytes);
    try std.testing.expectEqualStrings("", transport.written.items);
    transport.receipt_busy = false;
    try surface.pump();
    try std.testing.expectEqualStrings("echo original next", transport.written.items);
    try std.testing.expectEqual(@as(u64, 2), transport.sequence);
    try std.testing.expectEqual(@as(usize, 0), surface.pending.items.len);
    try std.testing.expectEqual(@as(usize, 0), surface.pending_bytes);
    try surface.pump();
    try std.testing.expectEqualStrings("echo original next", transport.written.items);
}

test "terminal surface busy Enter retries before the slower host lifecycle deadline" {
    var transport: FakeTransport = undefined;
    try transport.init(3, 16);
    defer transport.deinit();
    try transport.controller.feedOutput(owner, 1, "\x1b[?12l", 1);
    const cx = try ui.Cx.init(a, std.testing.io);
    defer cx.deinit();
    cx.setViewport(600, 160);
    var view = try View.mount(cx);
    cx.root = view.root;
    defer view.releaseBuffers(cx);
    view.setTimestampGutter(false);
    try view.bindTerminalService(transport.service());
    _ = cx.render();
    cx.setFocus(view.root);
    _ = try view.refreshTerminalService(owner, true);
    _ = cx.render();

    const Clock = struct {
        value: i96,
        fn now(raw: ?*anyopaque, clock: std.Io.Clock) std.Io.Timestamp {
            if (clock != .awake) return std.testing.io.vtable.now(std.testing.io.userdata, clock);
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            return .{ .nanoseconds = self.value };
        }
        fn resolution(_: ?*anyopaque, _: std.Io.Clock) std.Io.Clock.ResolutionError!std.Io.Duration {
            return .{ .nanoseconds = 1 };
        }
    };
    var clock: Clock = .{ .value = std.Io.Clock.awake.now(std.testing.io).nanoseconds };
    var io_vtable = std.testing.io.vtable.*;
    io_vtable.now = Clock.now;
    io_vtable.clockResolution = Clock.resolution;
    cx.io = .{ .userdata = &clock, .vtable = &io_vtable };
    defer cx.io = std.testing.io;

    const HostPoll = struct {
        view: *View,
        problem: ?anyerror = null,
        calls: usize = 0,
        fn run(raw: *anyopaque, _: u8, _: bool) ui.AfterLayoutResult {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.calls += 1;
            _ = self.view.refreshTerminalService(owner, true) catch |err| failed: {
                self.problem = err;
                break :failed false;
            };
            // A host may have a slower lifecycle deadline; pending input must
            // schedule its own earlier retry and never depend on another key.
            self.view.cx.scheduleRedrawAfterNs(33 * std.time.ns_per_ms);
            return .done;
        }
    };
    var poll: HostPoll = .{ .view = &view };
    try cx.addAfterLayoutHook(&poll, HostPoll.run);
    defer cx.removeAfterLayoutHook(&poll);
    cx.advanceFrameClock();
    clock.value += 33 * std.time.ns_per_ms;
    cx.requestRedraw();
    cx.advanceFrameClock();
    _ = cx.render();
    for (0..4) |_| {
        if (!cx.wantsFrame()) break;
        cx.advanceFrameClock();
        _ = cx.render();
    }
    try std.testing.expect(poll.calls > 0 and poll.problem == null);
    const surface = view.terminal_surface.?;
    try std.testing.expect(!surface.blink_running);
    try std.testing.expectEqual(@as(?u64, 33 * std.time.ns_per_ms), cx.nextWakeDelayNs());
    try std.testing.expectEqual(false, cx.wantsFrame());

    transport.busy = true;
    cx.handleKeyDown(.@"return", .{});
    try std.testing.expectEqual(@as(usize, 1), surface.pending.items.len);
    try std.testing.expectEqual(@as(usize, 0), transport.written.items.len);
    // Exhaust the immediate input frame, then rely solely on idle deadlines.
    cx.advanceFrameClock();
    _ = cx.render();
    for (0..2) |_| {
        const before = poll.calls;
        const delay = cx.nextWakeDelayNs().?;
        try std.testing.expect(delay > 0 and delay <= 8 * std.time.ns_per_ms);
        try std.testing.expectEqual(false, cx.wantsFrame());
        clock.value += delay;
        try std.testing.expectEqual(true, cx.wantsFrame());
        cx.advanceFrameClock();
        _ = cx.render();
        try std.testing.expect(poll.calls > before and poll.problem == null);
        try std.testing.expectEqual(@as(usize, 1), surface.pending.items.len);
        try std.testing.expectEqual(@as(usize, 0), transport.written.items.len);
    }
    transport.busy = false;
    clock.value += cx.nextWakeDelayNs().?;
    try std.testing.expectEqual(true, cx.wantsFrame());
    cx.advanceFrameClock();
    _ = cx.render();
    try std.testing.expectEqualStrings("\r", transport.written.items);
    try std.testing.expectEqual(@as(u64, 1), transport.sequence);
    try std.testing.expectEqual(@as(usize, 0), surface.pending.items.len);

    // The earlier takeWriteReceipt Busy exit also retains the input. Its
    // 3-second error hint must not displace the host's earlier retry deadline.
    transport.receipt_busy = true;
    cx.handleKeyDown(.@"return", .{});
    try std.testing.expectEqual(@as(usize, 1), surface.pending.items.len);
    try std.testing.expectEqualStrings("\r", transport.written.items);
    clock.value += cx.nextWakeDelayNs().?;
    try std.testing.expectEqual(true, cx.wantsFrame());
    cx.advanceFrameClock();
    _ = cx.render();
    try std.testing.expectEqual(error.WorkerBusy, poll.problem.?);
    try std.testing.expectEqual(@as(usize, 1), surface.pending.items.len);
    try std.testing.expectEqual(@as(?u64, 8 * std.time.ns_per_ms), cx.nextWakeDelayNs());
    poll.problem = null;
    transport.receipt_busy = false;
    clock.value += cx.nextWakeDelayNs().?;
    try std.testing.expectEqual(true, cx.wantsFrame());
    cx.advanceFrameClock();
    _ = cx.render();
    try std.testing.expect(poll.problem == null);
    try std.testing.expectEqualStrings("\r\r", transport.written.items);
    try std.testing.expectEqual(@as(u64, 2), transport.sequence);
    try std.testing.expectEqual(@as(usize, 0), surface.pending.items.len);
    clock.value += cx.nextWakeDelayNs().?;
    try std.testing.expectEqual(true, cx.wantsFrame());
    cx.advanceFrameClock();
    _ = cx.render();
    try std.testing.expectEqualStrings("\r\r", transport.written.items);
    try std.testing.expectEqual(@as(u64, 2), transport.sequence);
}

test "terminal surface menu paste rejection is visible and writes zero bytes before one valid submission" {
    var transport: FakeTransport = undefined;
    try transport.init(3, 16);
    defer transport.deinit();
    const cx = try ui.Cx.init(a, std.testing.io);
    defer cx.deinit();
    cx.setViewport(600, 160);
    var view = try View.mount(cx);
    cx.root = view.root;
    defer view.releaseBuffers(cx);
    try view.bindTerminalService(transport.service());
    _ = cx.render();
    _ = try view.refreshTerminalService(owner, false);
    const surface = view.terminal_surface.?;
    const oversized = try a.alloc(u8, 1024 * 1024 + 1);
    defer a.free(oversized);
    @memset(oversized, 'X');
    for ([_][]const u8{ oversized, "SAFE_A\x1b[201~SAFE_B" }) |rejected| {
        // This is the exact public entry called by MenuHost/native Cmd-V,
        // rather than Surface's already-covered keyboard/clipboard catch.
        try std.testing.expectError(error.InvalidPaste, view.requestPaste(rejected));
        try std.testing.expectEqual(@as(usize, 0), transport.written.items.len);
        try std.testing.expectEqual(@as(u64, 0), transport.sequence);
        try std.testing.expect(surface.pending_paste == null and surface.paste_requested == null);
        try std.testing.expect(surface.message.style.display == .flex);
        try std.testing.expectEqualStrings("粘贴未插入：请检查 UTF-8、1 MiB 上限及终端控制边界。", surface.message.getText().?.content);
        _ = cx.render();
        const message = surface.message.globalRect();
        const pane = surface.root.globalRect();
        try std.testing.expect(message.w > 0 and message.h > 0);
        try std.testing.expect(message.x >= pane.x and message.x + message.w <= pane.x + pane.w);
        try std.testing.expect(message.y >= pane.y and message.y + message.h <= pane.y + pane.h);
    }
    try view.requestPaste("ONE_SAFE_INPUT");
    _ = try view.refreshTerminalService(owner, false);
    try std.testing.expectEqualStrings("ONE_SAFE_INPUT", transport.written.items);
    try std.testing.expectEqual(@as(u64, 1), transport.sequence);
    try std.testing.expect(surface.pending_paste == null and surface.paste_requested == null);
}

test "terminal surface caret uses 550ms and actual accessibility preferences without idle blink wakeups" {
    const saved = ui.a11y.preferences.current();
    defer ui.a11y.preferences.set(saved);
    ui.a11y.preferences.set(.{});
    var transport: FakeTransport = undefined;
    try transport.init(3, 16);
    defer transport.deinit();
    try transport.controller.feedOutput(owner, 1, "x\x1b[?12h", 1);
    const cx = try ui.Cx.init(a, std.testing.io);
    defer cx.deinit();
    cx.setViewport(600, 160);
    var view = try View.mount(cx);
    cx.root = view.root;
    defer view.releaseBuffers(cx);
    view.setTimestampGutter(false);
    try view.bindTerminalService(transport.service());
    _ = cx.render();
    cx.setFocus(view.root);
    _ = try view.refreshTerminalService(owner, true);
    _ = try view.refreshTerminalService(owner, true);
    const surface = view.terminal_surface.?;
    try std.testing.expect(surface.snapshot.?.projection.modes.cursor_blinking);
    cx.frame_time_ms = 100;
    surface.last_blink = 100;
    surface.blink = true;
    cx.next_redraw_scheduled_at = null;
    cx.next_redraw_delay_ns = null;
    _ = try view.refreshTerminalService(owner, true);
    try std.testing.expectEqual(@as(?u64, 550 * std.time.ns_per_ms), cx.next_redraw_delay_ns);
    cx.frame_time_ms = 649;
    _ = try view.refreshTerminalService(owner, true);
    try std.testing.expect(surface.blink);
    cx.frame_time_ms = 650;
    _ = try view.refreshTerminalService(owner, true);
    try std.testing.expect(!surface.blink);
    try std.testing.expectEqual(.none, surface.caret.style.display);

    // Set the framework's real native-preference store, not a View-only flag.
    ui.a11y.preferences.set(.{ .reduce_motion = true });
    cx.next_redraw_scheduled_at = null;
    cx.next_redraw_delay_ns = null;
    _ = try view.refreshTerminalService(owner, true);
    try std.testing.expect(surface.blink and surface.reduced_motion);
    try std.testing.expect(surface.caret.style.display != .none);
    try std.testing.expectEqual(@as(?u64, null), cx.next_redraw_delay_ns);

    ui.a11y.preferences.set(.{});
    cx.renderer_reduced_motion = true;
    _ = try view.refreshTerminalService(owner, true);
    try std.testing.expect(surface.reduced_motion);
    try std.testing.expectEqual(@as(?u64, null), cx.next_redraw_delay_ns);
    cx.renderer_reduced_motion = false;
    try transport.controller.feedOutput(owner, 2, "\x1b[?12l", 2);
    _ = try view.refreshTerminalService(owner, true);
    try std.testing.expect(!surface.blink_running);
    try std.testing.expectEqual(@as(?u64, null), cx.next_redraw_delay_ns);

    view.setTimestampGutter(true);
    _ = try view.refreshTerminalService(owner, true);
    try std.testing.expect(cx.next_redraw_delay_ns.? > 0 and cx.next_redraw_delay_ns.? <= std.time.ns_per_s);
    cx.next_redraw_scheduled_at = null;
    cx.next_redraw_delay_ns = null;
    _ = try view.refreshTerminalService(owner, false);
    try std.testing.expectEqual(@as(?u64, null), cx.next_redraw_delay_ns);
}

test "terminal surface middle click captures service owner and point without terminal input" {
    var transport: FakeTransport = undefined;
    try transport.init(3, 16);
    defer transport.deinit();
    try transport.controller.feedOutput(owner, 1, "\x1b[?1000h", 1);
    const cx = try ui.Cx.init(a, std.testing.io);
    defer cx.deinit();
    cx.setViewport(600, 160);
    var view = try View.mount(cx);
    cx.root = view.root;
    defer view.releaseBuffers(cx);
    const Sink = struct {
        calls: usize = 0,
        captured: ?identity.SessionHandle = null,
        x: f32 = 0,
        y: f32 = 0,
        fn request(raw: ?*anyopaque, captured: identity.SessionHandle, x: f32, y: f32) void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.calls += 1;
            self.captured = captured;
            self.x = x;
            self.y = y;
        }
    };
    var sink: Sink = .{};
    view.setTerminalMenuHandler(.{ .context = &sink, .request = Sink.request });
    try view.bindTerminalService(transport.service());
    _ = cx.render();
    _ = try view.refreshTerminalService(owner, false);
    _ = cx.render();
    const surface = view.terminal_surface.?;
    const event = surface.root.behavior.events.on_event.?;
    const context = surface.root.behavior.events.event_context;
    // Canvas owns pointer events; the host also contains editable overlays.
    try std.testing.expectEqual(.stop, event(.{ .mouse_down = .{ .button = .middle, .x = 213, .y = 47 } }, context));
    try std.testing.expectEqual(@as(usize, 1), sink.calls);
    try std.testing.expect(sink.captured.?.eql(owner));
    try std.testing.expectEqual(@as(f32, 213), sink.x);
    try std.testing.expectEqual(@as(f32, 47), sink.y);
    try std.testing.expectEqual(@as(usize, 0), transport.written.items.len);
    try std.testing.expect(!cx.dispatcher.hasPointerCapture());
}

test "terminal surface selection remains original VT text and waits for applied resize geometry" {
    var transport: FakeTransport = undefined;
    try transport.init(3, 16);
    defer transport.deinit();
    try transport.controller.feedOutput(owner, 1, "ab界e\u{301}tail\r\nnext", 1);
    const cx = try ui.Cx.init(a, std.testing.io);
    defer cx.deinit();
    cx.setViewport(600, 160);
    var view = try View.mount(cx);
    cx.root = view.root;
    defer view.releaseBuffers(cx);
    view.setTypography(14, 22.0 / 14.0, 400);
    view.setTimestampGutter(true);
    try view.bindTerminalService(transport.service());
    _ = cx.render();
    _ = try view.refreshTerminalService(owner, false);
    _ = cx.render();
    try std.testing.expect(!view.hasSelection());
    const surface = view.terminal_surface.?;
    const x = surface.root.globalRect().x + 76;
    const y = surface.root.globalRect().y + 12;
    cx.handleMouseDownEx(x, y, .left, .{});
    cx.handleMouseMoveEx(x + 5 * view.cell_width, y, .{});
    cx.handleMouseUpEx(x + 5 * view.cell_width, y, .left, .{});
    try std.testing.expect(view.hasSelection());
    const copied = (try view.copySelectionText(a)).?;
    defer a.free(copied);
    try std.testing.expectEqualStrings("ab界e\u{301}", copied);
    try std.testing.expect(!surface.dragging and !cx.dispatcher.hasPointerCapture());
    const previous_version = view.terminalSnapshot(owner).?.projection.version;
    try transport.controller.feedOutput(owner, 2, "\r\nnew output", 2);
    try @import("terminal_surface_input.zig").renderSelection(surface);
    try std.testing.expect(surface.force_snapshot);
    for (surface.rows.items) |row| try std.testing.expectEqual(.none, row.selected.style.display);
    _ = try view.refreshTerminalService(owner, false);
    try std.testing.expect(view.terminalSnapshot(owner).?.projection.version > previous_version);
    _ = try view.refreshTerminalService(owner, true);
    try std.testing.expectEqual(@as(u64, 1), view.terminalSnapshot(owner).?.geometry_revision);
    _ = try view.refreshTerminalService(owner, true);
    const resized = view.terminalSnapshot(owner).?;
    try std.testing.expectEqual(transport.controller.geometry.revision, resized.geometry_revision);
    try std.testing.expectEqual(transport.controller.geometry.cols, resized.projection.cols);
    try std.testing.expectEqual(transport.controller.geometry.rows, resized.projection.rows);
}

test "terminal surface public Cx drag release copies and right click always pastes" {
    var transport: FakeTransport = undefined;
    try transport.init(3, 16);
    defer transport.deinit();
    try transport.controller.feedOutput(owner, 1, "abcdef\r\nsecond", 1);
    var clipboard: TestClipboard = .{};
    var sdk = TestSdk.init(a, &clipboard, &TestClipboard.vtable, .{ .clipboard = true });
    defer sdk.deinit();
    const cx = try ui.Cx.init(a, std.testing.io);
    defer cx.deinit();
    cx.setSystemSdk(&sdk);
    cx.setViewport(600, 160);
    var view = try View.mount(cx);
    cx.root = view.root;
    defer view.releaseBuffers(cx);
    view.setTimestampGutter(false);
    try view.bindTerminalService(transport.service());
    _ = cx.render();
    _ = try view.refreshTerminalService(owner, false);
    _ = cx.render();
    const surface = view.terminal_surface.?;
    surface.feedback.publish = struct {
        fn publish(_: ?*anyopaque, _: *ui.Cx, _: identity.SessionHandle, _: []const u8) !void {}
    }.publish;
    const x = surface.root.globalRect().x + 8 + surface.bodyX();
    const y = surface.root.globalRect().y + 8 + surface.options.row_height * 0.5;
    cx.handleMouseDownEx(x, y, .left, .{});
    try std.testing.expect(!view.hasSelection());
    cx.handleMouseUpEx(x, y, .left, .{});
    try std.testing.expect(surface.selection == null);
    try std.testing.expect(!view.hasSelection() and !cx.dispatcher.hasPointerCapture());
    try std.testing.expect((try view.copySelectionText(a)) == null);
    cx.handleMouseDownEx(x, y, .right, .{});
    cx.handleMouseUpEx(x, y, .right, .{});
    try std.testing.expectEqualStrings("PASTE", transport.written.items);
    try std.testing.expectEqual(@as(usize, 1), clipboard.reads);
    try std.testing.expectEqual(@as(usize, 0), clipboard.writes);

    cx.handleMouseDownEx(x, y, .left, .{});
    cx.handleMouseMoveEx(x + 3 * surface.options.cell_width, y, .{});
    cx.handleMouseUpEx(x + 3 * surface.options.cell_width, y, .left, .{});
    try std.testing.expect(view.hasSelection());
    try std.testing.expectEqual(@as(usize, 1), clipboard.writes);
    try std.testing.expectEqualStrings("abc", clipboard.copied[0..clipboard.copied_len]);
    try std.testing.expectEqual(.none, surface.message_root.style.display);
    const text = (try view.copySelectionText(a)).?;
    defer a.free(text);
    try std.testing.expectEqualStrings("abc", text);
    cx.handleMouseDownEx(x, y, .right, .{});
    cx.handleMouseUpEx(x, y, .right, .{});
    try std.testing.expectEqualStrings("abc", clipboard.copied[0..clipboard.copied_len]);
    try std.testing.expectEqual(@as(usize, 1), clipboard.writes);
    try std.testing.expectEqual(@as(usize, 2), clipboard.reads);
    try std.testing.expectEqualStrings("PASTEabc", transport.written.items);
    cx.handleKeyDown(.c, .{ .super = true });
    cx.handleKeyUp(.c, .{ .super = true });
    try std.testing.expectEqual(@as(usize, 2), clipboard.writes);
    try std.testing.expectEqualStrings("PASTEabc", transport.written.items);
    cx.handleMouseDownEx(x, y, .left, .{});
    cx.handleMouseUpEx(x, y, .left, .{});
    try std.testing.expectEqual(@as(usize, 2), clipboard.writes);
    try std.testing.expectEqualStrings("abc", clipboard.text);
    cx.handleKeyDown(.c, .{ .super = true });
    cx.handleKeyUp(.c, .{ .super = true });
    try std.testing.expectEqualStrings("PASTEabc\x03", transport.written.items);

    clipboard.fail_set = true;
    cx.handleMouseDownEx(x, y, .left, .{});
    cx.handleMouseMoveEx(x + 3 * surface.options.cell_width, y, .{});
    cx.handleMouseUpEx(x + 3 * surface.options.cell_width, y, .left, .{});
    try std.testing.expect(view.hasSelection());
    try std.testing.expectEqual(@as(usize, 2), clipboard.writes);
    try std.testing.expectEqualStrings("abc", clipboard.text);
    try std.testing.expectEqualStrings("复制失败：剪贴板不可用。", surface.message.getText().?.content);
}

test "terminal surface copy publishes the original owner once through shared feedback and keeps inline validation" {
    const Feedback = struct {
        count: usize = 0,
        received_owner: ?identity.SessionHandle = null,
        summary: []const u8 = "",
        fn publish(raw: ?*anyopaque, _: *ui.Cx, value: identity.SessionHandle, summary: []const u8) !void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.count += 1;
            self.received_owner = value;
            self.summary = summary;
        }
    };
    var transport: FakeTransport = undefined;
    try transport.init(3, 16);
    defer transport.deinit();
    var clipboard: TestClipboard = .{};
    var sdk = TestSdk.init(a, &clipboard, &TestClipboard.vtable, .{ .clipboard = true });
    defer sdk.deinit();
    const cx = try ui.Cx.init(a, std.testing.io);
    defer cx.deinit();
    cx.setSystemSdk(&sdk);
    cx.setViewport(600, 160);
    var view = try View.mount(cx);
    cx.root = view.root;
    defer view.releaseBuffers(cx);
    try view.bindTerminalService(transport.service());
    _ = cx.render();
    cx.setFocus(view.root);
    const surface = view.terminal_surface.?;
    var feedback: Feedback = .{};
    surface.feedback = .{ .context = &feedback, .publish = Feedback.publish };
    const baseline_timers = cx.timers.items.len;
    try surface.copySelectionToClipboard("owned selection");
    try std.testing.expectEqual(@as(usize, 1), feedback.count);
    try std.testing.expect(feedback.received_owner.?.eql(owner));
    try std.testing.expectEqualStrings("选区已复制", feedback.summary);
    try std.testing.expectEqual(.none, surface.message_root.style.display);
    try std.testing.expectEqual(baseline_timers, cx.timers.items.len);
    try std.testing.expect(cx.focus_manager.getFocused() == view.root);
    surface.showError(error.WorkerBusy);
    try surface.copySelectionToClipboard("copied while validation is visible");
    try std.testing.expectEqual(@as(usize, 2), feedback.count);
    try std.testing.expectEqualStrings("终端繁忙，请稍后重试。", surface.message.getText().?.content);
    clipboard.fail_set = true;
    try std.testing.expectError(error.ClipboardUnavailable, surface.copySelectionToClipboard("not copied"));
    try std.testing.expectEqual(@as(usize, 2), feedback.count);
    try std.testing.expectEqualStrings("copied while validation is visible", clipboard.text);
}

test "terminal surface selection clears invalid anchors and zero width rectangles without treating busy as paste" {
    var transport: FakeTransport = undefined;
    try transport.init(3, 16);
    defer transport.deinit();
    try transport.controller.feedOutput(owner, 1, "abcdef\r\nsecond", 1);
    var clipboard: TestClipboard = .{};
    var sdk = TestSdk.init(a, &clipboard, &TestClipboard.vtable, .{ .clipboard = true });
    defer sdk.deinit();
    const cx = try ui.Cx.init(a, std.testing.io);
    defer cx.deinit();
    cx.setSystemSdk(&sdk);
    cx.setViewport(600, 160);
    var view = try View.mount(cx);
    cx.root = view.root;
    defer view.releaseBuffers(cx);
    view.setTimestampGutter(false);
    try view.bindTerminalService(transport.service());
    _ = cx.render();
    _ = try view.refreshTerminalService(owner, false);
    _ = cx.render();
    const surface = view.terminal_surface.?;
    const x = surface.root.globalRect().x + 8 + surface.bodyX();
    const y = surface.root.globalRect().y + 8 + surface.options.row_height * 0.5;
    cx.handleMouseDownEx(x, y, .left, .{ .alt = true });
    cx.handleMouseMoveEx(x, y + surface.options.row_height, .{ .alt = true });
    cx.handleMouseUpEx(x, y + surface.options.row_height, .left, .{ .alt = true });
    try std.testing.expect(surface.selection == null and !view.hasSelection());
    try std.testing.expectEqual(@as(usize, 0), clipboard.writes);

    cx.handleMouseDownEx(x, y, .left, .{ .alt = true });
    cx.handleMouseMoveEx(x + 2 * surface.options.cell_width, y + surface.options.row_height, .{ .alt = true });
    cx.handleMouseUpEx(x + 2 * surface.options.cell_width, y + surface.options.row_height, .left, .{ .alt = true });
    try std.testing.expectEqual(@as(usize, 1), clipboard.writes);
    try std.testing.expectEqualStrings("ab\nse", clipboard.text);
    clipboard.text = "PASTE";
    clipboard.reads = 0;
    clipboard.writes = 0;

    cx.handleMouseDownEx(x, y, .left, .{});
    cx.handleMouseMoveEx(x + 3 * surface.options.cell_width, y, .{});
    transport.busy = true;
    cx.handleMouseUpEx(x + 3 * surface.options.cell_width, y, .left, .{});
    try std.testing.expect(view.hasSelection());
    try std.testing.expect(!surface.dragging and !cx.dispatcher.hasPointerCapture());
    try std.testing.expectError(error.WorkerBusy, surface.hasSelection());
    try std.testing.expect(view.hasSelection());
    cx.handleMouseDownEx(x, y, .right, .{});
    cx.handleMouseUpEx(x, y, .right, .{});
    cx.handleKeyDown(.c, .{ .super = true });
    cx.handleKeyUp(.c, .{ .super = true });
    try std.testing.expect(surface.selection != null);
    try std.testing.expectEqual(@as(usize, 0), clipboard.reads);
    try std.testing.expectEqual(@as(usize, 0), clipboard.writes);
    try std.testing.expectEqual(@as(usize, 0), transport.written.items.len);
    transport.busy = false;
    const start = surface.selection.?.start;
    try surface.service.releaseAnchor(start);
    try std.testing.expect(!view.hasSelection());
    try std.testing.expect(surface.selection == null);
    for (surface.rows.items) |row| try std.testing.expectEqual(.none, row.selected.style.display);
    try std.testing.expect((try view.copySelectionText(a)) == null);
    cx.handleMouseDownEx(x, y, .right, .{});
    cx.handleMouseUpEx(x, y, .right, .{});
    try std.testing.expectEqualStrings("PASTE", transport.written.items);
}

test "terminal surface offset pane uses window logical points for selection mouse and IME" {
    var transport: FakeTransport = undefined;
    try transport.init(6, 64);
    defer transport.deinit();
    try transport.controller.feedOutput(owner, 1, "ROW_A_123456789\r\nROW_B_abcdefghij", 1);
    const cx = try ui.Cx.init(a, std.testing.io);
    defer cx.deinit();
    cx.setViewport(1440, 889);
    cx.root = try ui.box(cx, .{ .width = .fill(), .height = .fill() }, .{});
    const pane = try ui.box(cx, .{ .position = .absolute, .inset = .{ .left = .{ .px = 238 }, .top = .{ .px = 60 } }, .width = .{ .px = 1194 }, .height = .{ .px = 794 } }, .{});
    try cx.root.?.appendChild(a, pane);
    var view = try View.mount(cx);
    try pane.appendChild(a, view.root);
    defer view.releaseBuffers(cx);
    view.setTypography(14, 22.0 / 14.0, 400);
    try view.bindTerminalService(transport.service());
    _ = cx.render();
    _ = try view.refreshTerminalService(owner, false);
    _ = cx.render();
    const surface = view.terminal_surface.?;
    const bounds = surface.root.globalRect();
    try std.testing.expectEqual(@as(f32, 238), bounds.x);
    try std.testing.expectEqual(@as(f32, 60), bounds.y);
    const body_x = bounds.x + 8 + surface.bodyX();
    const body_y = bounds.y + 8;
    const cell = surface.options.cell_width;
    const row_height = surface.options.row_height;
    const start_x = body_x + 6 * cell;
    const y = body_y + row_height * 0.5;
    // These are the same window-logical Cx entry points used by the native
    // bridge. A root at (0, 0) would hide the parent-local/world mismatch.
    cx.handleMouseDownEx(start_x, y, .left, .{});
    cx.handleMouseMoveEx(body_x + 10 * cell, y, .{});
    cx.handleMouseUpEx(body_x + 10 * cell, y, .left, .{});
    const selection = surface.selection.?;
    const start = (try surface.service.resolveAnchor(selection.start)).?;
    const end = (try surface.service.resolveAnchor(selection.end)).?;
    try std.testing.expectEqual(@as(u32, 0), start.row);
    try std.testing.expectEqual(@as(u16, 6), start.col);
    try std.testing.expectEqual(@as(u32, 0), end.row);
    try std.testing.expectEqual(@as(u16, 10), end.col);
    const copied = (try view.copySelectionText(a)).?;
    defer a.free(copied);
    try std.testing.expectEqualStrings("1234", copied);
    _ = cx.render();
    const selected = surface.rows.items[0].selected.globalRect();
    try std.testing.expectApproxEqAbs(start_x, selected.x, 0.01);
    try std.testing.expectApproxEqAbs(body_y, selected.y, 0.01);
    for (surface.rows.items[1..]) |row| try std.testing.expectEqual(.none, row.selected.style.display);

    const client = view.root.behavior.interaction.text_input_client.?;
    var first: u32 = 0;
    var last: u32 = 0;
    try std.testing.expect(client.range_at_point.?(client.context, body_x + 7 * cell, y, &first, &last));
    try std.testing.expectEqual(@as(u32, 7), first);
    try std.testing.expectEqual(@as(u32, 8), last);
    var frame: ui.types.A11yRect = undefined;
    try std.testing.expect(client.frame_for_range.?(client.context, 6, 6, &frame));
    try std.testing.expectApproxEqAbs(start_x, frame.x, 0.01);
    try std.testing.expectApproxEqAbs(body_y, frame.y, 0.01);
    cx.handleImePreedit("候选", 0);
    try std.testing.expect(client.frame_for_range.?(client.context, surface.caret_byte, surface.caret_byte, &frame));
    const cursor = surface.snapshot.?.projection.cursor;
    try std.testing.expectApproxEqAbs(body_x + @as(f32, @floatFromInt(cursor.col)) * cell, frame.x, 0.01);
    try std.testing.expectApproxEqAbs(body_y + @as(f32, @floatFromInt(cursor.row)) * row_height, frame.y, 0.01);
    cx.handleImePreedit("", 0);

    try transport.controller.feedOutput(owner, 2, "\x1b[?1000h\x1b[?1006h", 2);
    _ = try view.refreshTerminalService(owner, false);
    transport.written.clearRetainingCapacity();
    cx.handleMouseDownEx(start_x, y, .left, .{});
    try std.testing.expectEqualStrings("\x1b[<0;7;1M", transport.written.items);
    cx.handleMouseUpEx(start_x, y, .left, .{});
}

test "terminal surface canvas click after hidden textarea restores the host and routes Enter and IME once" {
    var transport: FakeTransport = undefined;
    try transport.init(3, 60);
    defer transport.deinit();
    try transport.controller.feedOutput(owner, 1, "click target\r\nprompt$ ", 1);
    const cx = try ui.Cx.init(a, std.testing.io);
    defer cx.deinit();
    cx.setViewport(600, 180);
    cx.root = try ui.box(cx, .{ .width = .fill(), .height = .fill() }, .{});
    const scope = try ui.Scope.init(a, null, cx.owner);
    defer scope.dispose();
    var view = try View.mount(cx);
    defer view.releaseBuffers(cx);
    try cx.root.?.appendChild(a, view.root);
    try view.bindTerminalService(transport.service());
    _ = cx.render();
    _ = try view.refreshTerminalService(owner, true);
    const panel = try ui.box(cx, .{ .position = .absolute, .inset = .{ .left = .{ .px = 180 }, .top = .{ .px = 20 } }, .width = .{ .px = 240 }, .height = .{ .px = 100 }, .z_index = 50 }, .{});
    const prompt = try scope.createText("assistant draft", .{});
    const input_widget = try ui.widgets.Textarea(.{ .value = prompt }).mountResult(scope, cx);
    try panel.appendChild(a, input_widget.wrapper);
    try cx.root.?.appendChild(a, panel);
    _ = cx.render();
    cx.setFocus(input_widget.input);
    try std.testing.expect(cx.focus_manager.getFocused() == input_widget.input);
    panel.setDisplay(.none);
    _ = cx.render();
    // Reproduce the native report's cleared authority. Hiding alone does not
    // specify a terminal return target; this test never calls setFocus(view).
    cx.clearFocus();
    const surface = view.terminal_surface.?;
    try std.testing.expectEqualStrings("terminal.input", view.root.meta.ownership.meta.test_id.?);
    try std.testing.expectEqualStrings("terminal.surface", surface.root.meta.ownership.meta.test_id.?);
    try std.testing.expect(view.root.behavior.interaction.text_input_client != null);
    try std.testing.expect(surface.root.behavior.interaction.text_input_client == null);
    const canvas = surface.root.globalRect();
    const glyph = surface.rows.items[0].glyphs.items[0].node.globalRect();
    const targets = [_]struct { x: f32, y: f32, text: []const u8 }{
        .{ .x = canvas.x + canvas.w / 2, .y = canvas.y + canvas.h / 2, .text = "CANVAS" },
        .{ .x = glyph.x + glyph.w / 2, .y = glyph.y + glyph.h / 2, .text = "GLYPH" },
        .{ .x = canvas.x + 6, .y = canvas.y + 6, .text = "INSET" },
    };
    for (targets) |target| {
        cx.clearFocus();
        cx.handleMouseDown(target.x, target.y, .{});
        cx.handleMouseUp(target.x, target.y);
        if (cx.focus_manager.getFocused() != view.root) std.debug.print("focus target={s} point=({d},{d}) canvas={any} glyph={any} focused={?d} expected={d}\n", .{ target.text, target.x, target.y, canvas, glyph, if (cx.focus_manager.getFocused()) |node| node.id else null, view.root.id });
        try std.testing.expect(cx.focus_manager.getFocused() == view.root);
        transport.written.clearRetainingCapacity();
        cx.handleTextInput(target.text);
        cx.handleKeyDown(.@"return", .{});
        try std.testing.expectEqualSlices(u8, target.text, transport.written.items[0..target.text.len]);
        try std.testing.expectEqual(@as(usize, target.text.len + 1), transport.written.items.len);
        try std.testing.expectEqual(@as(u8, '\r'), transport.written.items[target.text.len]);
    }
    transport.written.clearRetainingCapacity();
    cx.handleImePreedit("候选", "候选".len);
    cx.handleKeyDown(.@"return", .{});
    try std.testing.expectEqualStrings("候选", surface.preedit);
    try std.testing.expectEqual(@as(usize, 0), transport.written.items.len);
    cx.handleImeCommit("中文");
    cx.handleKeyDown(.@"return", .{});
    try std.testing.expectEqualStrings("中文\r", transport.written.items);
}

test "assistant focus return validates the original full owner and preserves foreign IME composition" {
    const focus_return = @import("ai_return_focus.zig");
    var transport: FakeTransport = undefined;
    try transport.init(3, 60);
    defer transport.deinit();
    const cx = try ui.Cx.init(a, std.testing.io);
    defer cx.deinit();
    cx.setViewport(600, 180);
    cx.root = try ui.box(cx, .{ .width = .fill(), .height = .fill() }, .{});
    const scope = try ui.Scope.init(a, null, cx.owner);
    defer scope.dispose();
    var view = try View.mount(cx);
    defer view.releaseBuffers(cx);
    try cx.root.?.appendChild(a, view.root);
    try view.bindTerminalService(transport.service());
    _ = cx.render();
    _ = try view.refreshTerminalService(owner, true);
    const panel = try ui.box(cx, .{ .position = .absolute, .width = .{ .px = 180 }, .height = .{ .px = 80 } }, .{});
    const ai_text = try scope.createText("assistant draft", .{});
    const ai_input = try ui.widgets.Textarea(.{ .value = ai_text }).mountResult(scope, cx);
    try panel.appendChild(a, ai_input.wrapper);
    try cx.root.?.appendChild(a, panel);
    const foreign_text = try scope.createText("other editor", .{});
    const foreign = try ui.widgets.Textarea(.{ .value = foreign_text }).mountResult(scope, cx);
    foreign.wrapper.setStyleInline(a, .{ .position = .absolute, .inset = .{ .left = .{ .px = 350 }, .top = .{ .px = 20 } }, .width = .{ .px = 200 }, .height = .{ .px = 100 } });
    try cx.root.?.appendChild(a, foreign.wrapper);
    const toolbar = try ui.widgets.Button(.{ .label = "AI" }).mount(scope, cx);
    toolbar.setStyleInline(a, .{ .position = .absolute, .inset = .{ .left = .{ .px = 550 }, .top = .{ .px = 0 } }, .width = .{ .px = 40 }, .height = .{ .px = 30 } });
    try cx.root.?.appendChild(a, toolbar);
    for (0..4) |_| _ = cx.render();
    cx.layout();
    const ticket: focus_return.Ticket = .{ .tab = @fromBackingInt(17), .owner = .{ .session = owner }, .group = 9 };

    cx.setFocus(ai_input.input);
    try std.testing.expect(focus_return.restore(cx, ticket, ticket, view.root, panel, toolbar, false));
    try std.testing.expect(cx.focus_manager.getFocused() == view.root);
    cx.handleTextInput("AFTER_AI");
    cx.handleKeyDown(.@"return", .{});
    try std.testing.expectEqualStrings("AFTER_AI\r", transport.written.items);

    cx.setFocus(toolbar);
    var stale = ticket;
    stale.owner.session.generation += 1;
    try std.testing.expect(!focus_return.restore(cx, ticket, stale, view.root, panel, toolbar, false));
    try std.testing.expect(cx.focus_manager.getFocused() == toolbar);
    stale = ticket;
    stale.tab = @fromBackingInt(18);
    try std.testing.expect(!focus_return.restore(cx, ticket, stale, view.root, panel, toolbar, false));
    stale = ticket;
    stale.group = 10;
    try std.testing.expect(!focus_return.restore(cx, ticket, stale, view.root, panel, toolbar, false));
    try std.testing.expect(focus_return.restore(cx, ticket, ticket, view.root, panel, toolbar, false));

    const foreign_rect = foreign.input.globalRect();
    cx.handleMouseDown(foreign_rect.x + foreign_rect.w - 10, foreign_rect.y + 15, .{});
    cx.handleMouseUp(foreign_rect.x + foreign_rect.w - 10, foreign_rect.y + 15);
    try std.testing.expect(cx.focus_manager.getFocused() == foreign.input);
    cx.handleImePreedit("候选", "候选".len);
    try std.testing.expect(foreign.state.imeIsComposing());
    try std.testing.expect(!focus_return.restore(cx, ticket, ticket, view.root, panel, toolbar, false));
    try std.testing.expect(cx.focus_manager.getFocused() == foreign.input);
    try std.testing.expect(foreign.state.imeIsComposing());
    cx.handleImeCommit("中文");
    try std.testing.expectEqualStrings("other editor中文", foreign_text.peek());

    cx.setFocus(ai_input.input);
    cx.handleImePreedit("保留", "保留".len);
    try std.testing.expect(!focus_return.restore(cx, ticket, ticket, view.root, panel, toolbar, true));
    try std.testing.expect(cx.focus_manager.getFocused() == ai_input.input);
    try std.testing.expect(ai_input.state.imeIsComposing());
    cx.handleImeCommit("中文");
    try std.testing.expectEqualStrings("assistant draft中文", ai_text.peek());

    cx.clearFocus();
    view.root.setDisplay(.none);
    try std.testing.expect(!focus_return.restore(cx, ticket, ticket, view.root, panel, toolbar, false));
    view.root.setDisplay(.flex);
    try std.testing.expect(focus_return.restore(cx, ticket, ticket, view.root, panel, toolbar, false));
}

test "terminal surface focused search blurs before its event resources are released" {
    const cx = try ui.Cx.init(a, std.testing.io);
    defer cx.deinit();
    cx.setViewport(600, 160);
    var view = try View.mount(cx);
    cx.root = view.root;
    const scope = try ui.Scope.init(a, null, cx.owner);
    defer scope.dispose();
    var released = false;
    defer if (!released) view.releaseBuffers(cx);
    try view.attachSearch(scope);
    view.openSearch();
    _ = cx.render();
    const Probe = struct {
        released: bool = false,
        blur_after_release: bool = false,
        blurred: bool = false,
        fn cleanup(self: *@This()) void {
            self.released = true;
        }
        fn blur(raw: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.blurred = true;
            self.blur_after_release = self.released;
        }
    };
    var probe: Probe = .{};
    try view.search_scope.?.onCleanup(Probe, &probe, Probe.cleanup);
    view.search_view.?.input_result.input_container.behavior.events.on_blur = .{ .callback = Probe.blur, .context = &probe };
    try std.testing.expect(cx.focus_manager.getFocused() == view.search_view.?.input_result.input_container);
    view.releaseBuffers(cx);
    released = true;
    try std.testing.expect(probe.released and probe.blurred);
    try std.testing.expect(!probe.blur_after_release);
    try std.testing.expect(cx.focus_manager.getFocused() == null);
}

test "terminal surface search drops overwritten hits instead of locating a replacement row" {
    var transport: FakeTransport = undefined;
    try transport.init(3, 32);
    defer transport.deinit();
    try transport.controller.feedOutput(owner, 1, "original needle\r\nsecond", 1);
    const cx = try ui.Cx.init(a, std.testing.io);
    defer cx.deinit();
    cx.setViewport(600, 160);
    var view = try View.mount(cx);
    cx.root = view.root;
    const scope = try ui.Scope.init(a, null, cx.owner);
    defer scope.dispose();
    defer view.releaseBuffers(cx);
    try view.attachSearch(scope);
    try view.bindTerminalService(transport.service());
    _ = cx.render();
    _ = try view.refreshTerminalService(owner, false);
    view.openSearch();
    _ = cx.render();
    cx.handleTextInput("needle");
    _ = try view.refreshTerminalService(owner, false);
    try std.testing.expectEqual(@as(usize, 1), view.search.count());
    try std.testing.expect(view.search_anchor != null);
    const previous = view.service_search.?.document.source_version;
    const scrolls = transport.scroll_calls;
    try transport.controller.feedOutput(owner, 2, "\x1b[2J\x1b[Hreplacement\r\nsecond", 2);
    view.terminal_surface.?.force_snapshot = true;
    _ = try view.refreshTerminalService(owner, false);
    try std.testing.expect(view.service_search.?.document.source_version > previous);
    try std.testing.expectEqual(@as(usize, 0), view.search.count());
    try std.testing.expect(view.search_anchor == null);
    try std.testing.expectEqualStrings("无匹配", view.search_view.?.count.getText().?.content);
    for (view.search_marks.items) |mark| try std.testing.expectEqual(.none, mark.style.display);
    cx.handleKeyDown(.@"return", .{});
    try std.testing.expectEqual(scrolls, transport.scroll_calls);
    try std.testing.expectEqual(@as(usize, 0), transport.written.items.len);
}

test "history search uses complete retained VT source and locates offscreen softwrapped graphemes" {
    const cast = "{\"version\":2,\"width\":8,\"height\":2}\n" ++
        "[0,\"o\",\"\\u001b[1;31mabcdef界é👩‍💻XYZ\\u001b[0m\\r\\n\"]\n" ++
        "[1,\"o\",\"second\\r\\nthird\\r\\nlast\"]\n";
    var timeline = try @import("history_cast.zig").load(a, cast);
    defer timeline.deinit();
    timeline.history_id = @fromBackingInt(@intCast(91));
    const cx = try ui.Cx.init(a, std.testing.io);
    defer cx.deinit();
    cx.setViewport(600, 160);
    var view = try View.mount(cx);
    cx.root = view.root;
    const scope = try ui.Scope.init(a, null, cx.owner);
    defer scope.dispose();
    defer view.releaseBuffers(cx);
    try view.attachSearch(scope);
    view.history.deinit();
    view.history = timeline;
    timeline = @import("history_replay.zig").Timeline.init(a, timeline.limit);
    view.bindArchived();
    try std.testing.expect(view.openHistory());
    _ = cx.render();
    try std.testing.expect(std.mem.indexOf(u8, text_frameForTest(view.history.current().?.wire), "abcdef") == null);
    view.openSearch();
    _ = cx.render();
    cx.handleTextInput("界é👩‍💻");
    _ = cx.render();
    try std.testing.expectEqual(@as(usize, 1), view.search.count());
    try std.testing.expectEqual(@as(?@import("../host/identity.zig").HistoryId, @fromBackingInt(@intCast(91))), view.history.history_id);
    try std.testing.expect(view.history_search_top != null);
    try std.testing.expect(std.mem.indexOf(u8, text_frameForTest(view.history_search_wire.items), "界") != null);
    const painted_frame = @import("../vt/text_frame.zig").decode(view.history_search_wire.items).?;
    try std.testing.expect(painted_frame.spans.len > 0);
    try std.testing.expect(painted_frame.spans[0].color != 0);
    try std.testing.expect(painted_frame.spans[0].bold());
    try std.testing.expect(view.worker == null and view.terminal_surface == null);
    cx.handleKeyDown(.escape, .{});
    try std.testing.expect(!view.search_open and cx.focus_manager.getFocused() == view.root);
}

fn text_frameForTest(wire: []const u8) []const u8 {
    return @import("../vt/text_frame.zig").decode(wire).?.text;
}

test "legacy history search locates an original earlier frame from the final frame" {
    const cx = try ui.Cx.init(a, std.testing.io);
    defer cx.deinit();
    cx.setViewport(600, 160);
    var view = try View.mount(cx);
    cx.root = view.root;
    const scope = try ui.Scope.init(a, null, cx.owner);
    defer scope.dispose();
    defer view.releaseBuffers(cx);
    try view.attachSearch(scope);
    const frame = @import("../vt/text_frame.zig");
    var wire: [frame.header_bytes + 6]u8 = undefined;
    frame.encodeHeader(wire[0..frame.header_bytes], .{}, 6, 1, 0, 6);
    @memcpy(wire[frame.header_bytes..], "needle");
    try view.history.append(1, &wire);
    @memcpy(wire[frame.header_bytes..], "latest");
    try view.history.append(2, &wire);
    view.bindArchived();
    try std.testing.expect(view.openHistory());
    _ = cx.render();
    try std.testing.expectEqual(@as(usize, 1), view.history.selected.?);
    view.openSearch();
    _ = cx.render();
    cx.handleTextInput("needle");
    _ = cx.render();
    try std.testing.expectEqual(@as(usize, 1), view.search.count());
    try std.testing.expectEqual(@as(usize, 0), view.history.selected.?);
    try std.testing.expectEqualStrings("needle", text_frameForTest(view.history.current().?.wire));
    try std.testing.expect(view.worker == null and view.terminal_surface == null);
}

test "terminal surface defers hidden painting but preserves latest output when revealed" {
    var transport: FakeTransport = undefined;
    try transport.init(4, 16);
    defer transport.deinit();
    const cx = try ui.Cx.init(a, std.testing.io);
    defer cx.deinit();
    cx.setViewport(800, 400);
    var view = try View.mount(cx);
    cx.root = view.root;
    defer view.releaseBuffers(cx);
    try view.bindTerminalService(transport.service());
    _ = cx.render();
    view.root.setDisplay(.none);
    try transport.controller.feedOutput(owner, 1, "LATEST", 100);
    _ = try view.refreshTerminalService(owner, false);
    try std.testing.expectEqual(@as(usize, 0), view.terminal_surface.?.rows.items.len);
    try std.testing.expect(transport.slot.canPublish());
    view.root.setDisplay(.flex);
    _ = cx.render();
    _ = try view.refreshTerminalService(owner, false);
    const surface = view.terminal_surface.?;
    try std.testing.expect(surface.rows.items.len > 0);
    try std.testing.expectEqualStrings("L", surface.rows.items[0].glyphs.items[0].node.getText().?.content);
    try std.testing.expect(std.mem.indexOf(u8, surface.document.items, "LATEST") != null);
}
