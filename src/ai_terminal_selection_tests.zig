//! Actual Ghostty anchors and parsed text through the production service seam.
const std = @import("std");
const capture_mod = @import("host/ai_terminal_selection.zig");
const terminal = @import("host/terminal_service.zig");
const identity = @import("host/identity.zig");
const host = @import("host/session_host.zig");
const Adapter = @import("vt/ghostty_adapter.zig").Adapter;
const Controller = @import("vt/terminal_controller.zig").Controller;
const Engine = @import("vt/engine.zig").VtEngine;
const TextSlot = @import("vt/text_slot.zig").TextSlot;
const a = std.testing.allocator;
const owner: identity.SessionHandle = .{ .session_id = @fromBackingInt(81), .generation = 4 };
const binding: host.ServiceHandle = .{ .resource_owner = .{ .session = owner }, .origin_session = owner, .kind = .terminal, .binding_id = 7, .binding_generation = 2 };

const Fixture = struct {
    vt: Adapter,
    slot: TextSlot,
    controller: Controller,
    reads: usize = 0,
    status_calls: usize = 0,
    busy: bool = false,
    change_during_read: bool = false,
    change_owner_after_read: bool = false,
    selected: terminal.Selection = undefined,
    fn init(self: *Fixture) !void {
        self.* = .{ .vt = try Adapter.init(a, 4, 80), .slot = try TextSlot.init(a, TextSlot.default_capacity), .controller = undefined };
        self.controller = try Controller.init(.{ .owner = owner, .engine = Engine.from(Adapter, &self.vt), .text_slot = &self.slot });
        try self.controller.feedOutput(owner, 1, "14:20:05 \x1b[31m原始日志\x1b[0m\r\n14:20:06 second line", 1000);
        self.selected = .{ .start = try self.controller.createAnchor(owner, .{ .row = 0, .col = 0 }), .end = try self.controller.createAnchor(owner, .{ .row = 1, .col = 20 }) };
    }
    fn deinit(self: *Fixture) void {
        self.controller.releaseAnchor(self.selected.start) catch {};
        self.controller.releaseAnchor(self.selected.end) catch {};
        self.slot.deinit(a);
        self.vt.destroy();
    }
    fn service(self: *Fixture) terminal.Service {
        return .{ .binding = binding, .context = self, .vtable = &vtable };
    }
    fn get(raw: *anyopaque) *Fixture {
        return @ptrCast(@alignCast(raw));
    }
    fn status(raw: *anyopaque, _: host.ServiceHandle) !terminal.Status {
        const self = get(raw);
        self.status_calls += 1;
        if (self.busy) return error.WorkerBusy;
        const state = self.controller.status();
        const scalar = self.vt.snapshot();
        return .{ .owner = if (self.change_owner_after_read and self.reads != 0) try owner.nextGeneration() else owner, .writable = true, .eof_seen = false, .geometry = state.geometry, .output_sequence = state.output_sequence, .pending_input_bytes = 0, .mode_revision = scalar.mode_revision, .modes = scalar.modes };
    }
    fn resolve(raw: *anyopaque, _: host.ServiceHandle, anchor: terminal.Anchor) !?terminal.AnchorPosition {
        return get(raw).controller.resolveAnchor(anchor);
    }
    fn selection(raw: *anyopaque, _: host.ServiceHandle, selected: terminal.Selection, allocator: std.mem.Allocator, limit: usize) ![]u8 {
        const self = get(raw);
        self.reads += 1;
        const bytes = try self.controller.selectionText(selected, allocator, limit);
        errdefer allocator.free(bytes);
        if (self.change_during_read) try self.controller.feedOutput(owner, 2, "changed after capture", 1010);
        return bytes;
    }
    fn unexpectedWrite(_: *anyopaque, _: host.ServiceHandle, _: terminal.WriteRequest) !terminal.Submission {
        return error.UnexpectedTerminalMutation;
    }
    fn unexpectedResize(_: *anyopaque, _: host.ServiceHandle, _: terminal.Geometry) !void {
        return error.UnexpectedTerminalMutation;
    }
    fn unexpectedRead(_: *anyopaque, _: host.ServiceHandle, _: []u8) !terminal.Read {
        return error.RawPtyReadForbidden;
    }
    fn unexpectedReceipt(_: *anyopaque, _: host.ServiceHandle) !?terminal.WriteReceipt {
        return error.UnexpectedTerminalMutation;
    }
    fn unexpectedSlot(_: *anyopaque, _: host.ServiceHandle) !*TextSlot {
        return error.RawPtyReadForbidden;
    }
    fn unexpectedSnapshot(_: *anyopaque, _: host.ServiceHandle, _: std.mem.Allocator) !terminal.TerminalSnapshot {
        return error.UnexpectedTerminalRead;
    }
    fn unexpectedPrepare(_: *anyopaque, _: host.ServiceHandle, _: std.mem.Allocator, _: []const u8) !terminal.Paste {
        return error.UnexpectedTerminalMutation;
    }
    fn unexpectedCommit(_: *anyopaque, _: host.ServiceHandle, _: terminal.Paste, _: u64, _: bool) !terminal.Submission {
        return error.UnexpectedTerminalMutation;
    }
    fn unexpectedKey(_: *anyopaque, _: host.ServiceHandle, _: terminal.KeyRequest) !terminal.Submission {
        return error.UnexpectedTerminalMutation;
    }
    fn unexpectedMouse(_: *anyopaque, _: host.ServiceHandle, _: terminal.MouseRequest) !terminal.Submission {
        return error.UnexpectedTerminalMutation;
    }
    fn unexpectedAnchor(_: *anyopaque, _: host.ServiceHandle, _: terminal.Point) !terminal.Anchor {
        return error.UnexpectedTerminalMutation;
    }
    fn unexpectedRelease(_: *anyopaque, _: host.ServiceHandle, _: terminal.Anchor) !void {
        return error.SelectionMutationForbidden;
    }
    fn unexpectedScroll(_: *anyopaque, _: host.ServiceHandle, _: terminal.Scroll) !void {
        return error.UnexpectedTerminalMutation;
    }
    fn unexpectedLines(_: *anyopaque, _: host.ServiceHandle, _: terminal.LineLimits, _: std.mem.Allocator) !terminal.Lines {
        return error.UnexpectedTerminalRead;
    }
    fn unexpectedTheme(_: *anyopaque, _: host.ServiceHandle, _: terminal.Theme) !void {
        return error.UnexpectedTerminalMutation;
    }
    const vtable: terminal.Service.VTable = .{ .write = unexpectedWrite, .resize = unexpectedResize, .read = unexpectedRead, .receipt = unexpectedReceipt, .status = status, .text_slot = unexpectedSlot, .snapshot = unexpectedSnapshot, .prepare_paste = unexpectedPrepare, .commit_paste = unexpectedCommit, .key = unexpectedKey, .mouse = unexpectedMouse, .create_anchor = unexpectedAnchor, .resolve_anchor = resolve, .release_anchor = unexpectedRelease, .selection_text = selection, .scroll = unexpectedScroll, .read_lines = unexpectedLines, .theme = unexpectedTheme };
};

test "AI terminal selection captures actual parsed VT bytes with source identity row count and no UI timestamps" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    var captured = try capture_mod.capture(a, f.service(), owner, f.selected, 1024);
    defer captured.deinit();
    try std.testing.expect(captured.owner.eql(owner));
    try std.testing.expectEqual(@as(u32, 2), captured.selected_rows);
    try std.testing.expectEqualStrings("14:20:05 原始日志\n14:20:06 second line", captured.bytes);
    try std.testing.expect(std.mem.indexOfScalar(u8, captured.bytes, 0x1b) == null);
    try std.testing.expectEqual(@as(usize, 1), f.reads);
    // Reading did not release/change the anchors or the terminal selection.
    var again = try capture_mod.capture(a, f.service(), owner, f.selected, 1024);
    defer again.deinit();
    try std.testing.expectEqualStrings(captured.bytes, again.bytes);
    try std.testing.expect(try f.controller.resolveAnchor(f.selected.start) != null);
    try f.controller.feedOutput(owner, 2, "\x1b[2J\x1b[Hlater terminal content", 1100);
    try std.testing.expectEqualStrings("14:20:05 原始日志\n14:20:06 second line", captured.bytes);
}

test "AI terminal selection stale owner busy invalid and oversized reads never switch targets or clear original anchors" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try std.testing.expectError(error.StaleOwner, capture_mod.capture(a, f.service(), try owner.nextGeneration(), f.selected, 1024));
    var foreign = f.selected;
    foreign.end.owner = try owner.nextGeneration();
    try std.testing.expectError(error.StaleOwner, capture_mod.capture(a, f.service(), owner, foreign, 1024));
    try std.testing.expectEqual(@as(usize, 0), f.reads);
    f.busy = true;
    try std.testing.expectError(error.WorkerBusy, capture_mod.capture(a, f.service(), owner, f.selected, 1024));
    f.busy = false;
    try std.testing.expectError(error.InvalidSelectionLimit, capture_mod.capture(a, f.service(), owner, f.selected, 0));
    try std.testing.expectError(error.InvalidSelectionLimit, capture_mod.capture(a, f.service(), owner, f.selected, capture_mod.max_service_bytes + 1));
    try std.testing.expectError(error.NoSelection, capture_mod.capture(a, f.service(), owner, .{ .start = f.selected.start, .end = f.selected.start }, 1024));
    try std.testing.expectError(error.CopyTooLarge, capture_mod.capture(a, f.service(), owner, f.selected, 4));
    try std.testing.expect(try f.controller.resolveAnchor(f.selected.start) != null);
    try std.testing.expect(try f.controller.resolveAnchor(f.selected.end) != null);
}

test "AI terminal selection concurrent source version or generation change rejects and frees a captured result" {
    for ([_]bool{ false, true }) |generation_change| {
        var f: Fixture = undefined;
        try f.init();
        defer f.deinit();
        f.change_owner_after_read = generation_change;
        f.change_during_read = !generation_change;
        try std.testing.expectError(if (generation_change) error.StaleOwner else error.StaleSelection, capture_mod.capture(a, f.service(), owner, f.selected, 1024));
        try std.testing.expectEqual(@as(usize, 1), f.reads);
        try std.testing.expect(try f.controller.resolveAnchor(f.selected.start) != null);
    }
}

test "AI terminal selection row metadata respects reversed and half-open linear endpoints and inclusive rectangular rows" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    var reversed = try capture_mod.capture(a, f.service(), owner, .{ .start = f.selected.end, .end = f.selected.start }, 1024);
    defer reversed.deinit();
    try std.testing.expectEqual(@as(u32, 2), reversed.selected_rows);
    try std.testing.expectEqualStrings("14:20:05 原始日志\n14:20:06 second line", reversed.bytes);
    const end = try f.controller.createAnchor(owner, .{ .row = 1, .col = 0 });
    defer f.controller.releaseAnchor(end) catch {};
    var one_row = try capture_mod.capture(a, f.service(), owner, .{ .start = f.selected.start, .end = end }, 1024);
    defer one_row.deinit();
    try std.testing.expectEqual(@as(u32, 1), one_row.selected_rows);
    try std.testing.expect(std.mem.startsWith(u8, one_row.bytes, "14:20:05 原始日志"));
    const left = try f.controller.createAnchor(owner, .{ .row = 1, .col = 2 });
    defer f.controller.releaseAnchor(left) catch {};
    const right = try f.controller.createAnchor(owner, .{ .row = 0, .col = 8 });
    defer f.controller.releaseAnchor(right) catch {};
    var rectangle = try capture_mod.capture(a, f.service(), owner, .{ .start = right, .end = left, .rectangle = true }, 1024);
    defer rectangle.deinit();
    try std.testing.expectEqual(@as(u32, 2), rectangle.selected_rows);
    try std.testing.expectEqualStrings(":20:05\n:20:06", rectangle.bytes);
}

test "AI terminal selection bounded immutable result releases all allocation failures and preserves live anchors" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const Scenario = struct {
        fn run(allocator: std.mem.Allocator, source: terminal.Service, selected: terminal.Selection) !void {
            var captured = try capture_mod.capture(allocator, source, owner, selected, 1024);
            defer captured.deinit();
            try std.testing.expectEqualStrings("14:20:05 原始日志\n14:20:06 second line", captured.bytes);
        }
    };
    try std.testing.checkAllAllocationFailures(a, Scenario.run, .{ f.service(), f.selected });
    try std.testing.expect(try f.controller.resolveAnchor(f.selected.start) != null);
}
