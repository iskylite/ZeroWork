//! Read-only adapter facade for archived/legacy document composition. It has
//! no transport capability: every input operation explicitly rejects writes.
const std = @import("std");
const terminal = @import("../host/terminal_service.zig");
const Binding = @import("../host/session_host.zig").ServiceHandle;
const Adapter = @import("../vt/ghostty_adapter.zig").Adapter;
const Owner = @import("../host/identity.zig").SessionHandle;
pub const Source = struct {
    adapter: *Adapter,
    owner: Owner,
    timeline: ?*@import("../vt/timeline.zig").Timeline = null,
    validator: ?struct { context: *anyopaque, check: *const fn (*anyopaque, Owner) anyerror!void } = null,
    pub fn service(self: *Source) terminal.Service {
        return .{ .binding = .{ .resource_owner = .{ .session = self.owner }, .origin_session = self.owner, .kind = .terminal, .binding_id = 1, .binding_generation = self.owner.generation }, .context = self, .vtable = &vtable };
    }
    fn get(raw: *anyopaque, binding: Binding) !*Source {
        const self: *Source = @ptrCast(@alignCast(raw));
        if (!self.service().binding.eql(binding)) return error.StaleOwner;
        if (self.validator) |v| try v.check(v.context, self.owner);
        return self;
    }
    fn snapshot(raw: *anyopaque, binding: Binding, allocator: std.mem.Allocator) !terminal.TerminalSnapshot {
        const self = try get(raw, binding);
        return .{ .owner = self.owner, .geometry_revision = 1, .input_revision = 1, .read_only = true, .eof_seen = false, .projection = try self.adapter.copyProjection(allocator) };
    }
    fn searchSnapshot(raw: *anyopaque, binding: Binding, allocator: std.mem.Allocator) !terminal.SearchSnapshot {
        const self = try get(raw, binding);
        return .{ .owner = self.owner, .document = try self.adapter.searchSnapshot(allocator) };
    }
    fn createAnchor(raw: *anyopaque, binding: Binding, point: terminal.Point) !terminal.Anchor {
        const self = try get(raw, binding);
        if (point.source_version) |v| if (v != self.adapter.snapshot().version) return error.StaleProjection;
        return .{ .owner = self.owner, .id = try self.adapter.createAnchor(point) };
    }
    fn resolveAnchor(raw: *anyopaque, binding: Binding, anchor: terminal.Anchor) !?terminal.AnchorPosition {
        const self = try get(raw, binding);
        if (!self.owner.eql(anchor.owner)) return error.StaleOwner;
        var result = (try self.adapter.resolveAnchor(anchor.id)) orelse return null;
        result.source_version = self.adapter.snapshot().version;
        return result;
    }
    fn releaseAnchor(raw: *anyopaque, binding: Binding, anchor: terminal.Anchor) !void {
        const self = try get(raw, binding);
        if (!self.owner.eql(anchor.owner)) return error.StaleOwner;
        return self.adapter.releaseAnchor(anchor.id);
    }
    fn selectionText(raw: *anyopaque, binding: Binding, selected: terminal.Selection, allocator: std.mem.Allocator, limit: usize) ![]u8 {
        const self = try get(raw, binding);
        if (!self.owner.eql(selected.start.owner) or !self.owner.eql(selected.end.owner)) return error.StaleOwner;
        return self.adapter.selectionFromAnchors(.{ .start = selected.start.id, .end = selected.end.id, .rectangle = selected.rectangle }, allocator, limit);
    }
    fn scroll(raw: *anyopaque, binding: Binding, value: terminal.Scroll) !void {
        const self = try get(raw, binding);
        return self.adapter.scroll(switch (value) {
            .top => .top,
            .bottom => .bottom,
            .delta => |d| .{ .delta = d },
            .anchor => |a| .{ .anchor = a.id },
        });
    }
    fn lines(raw: *anyopaque, binding: Binding, limits: terminal.LineLimits, allocator: std.mem.Allocator) !terminal.Lines {
        const self = try get(raw, binding);
        return self.adapter.readLines(limits, allocator);
    }
    fn write(_: *anyopaque, _: Binding, _: terminal.WriteRequest) !terminal.Submission {
        return error.ReadOnlyDocument;
    }
    fn resize(_: *anyopaque, _: Binding, _: terminal.Geometry) !void {
        return error.ReadOnlyDocument;
    }
    fn read(_: *anyopaque, _: Binding, _: []u8) !terminal.Read {
        return error.ReadOnlyDocument;
    }
    fn receipt(_: *anyopaque, _: Binding) !?terminal.WriteReceipt {
        return error.ReadOnlyDocument;
    }
    fn status(raw: *anyopaque, binding: Binding) !terminal.Status {
        const self = try get(raw, binding);
        const state = self.adapter.snapshot();
        return .{ .owner = self.owner, .writable = false, .eof_seen = false, .geometry = .{ .revision = 1, .cols = state.cols, .rows = state.rows }, .output_sequence = state.output_sequence, .bell_count = state.bell_count, .pending_input_bytes = 0, .mode_revision = state.mode_revision, .modes = state.modes };
    }
    fn textSlot(_: *anyopaque, _: Binding) !*@import("../vt/text_slot.zig").TextSlot {
        return error.ReadOnlyDocument;
    }
    fn preparePaste(_: *anyopaque, _: Binding, _: std.mem.Allocator, _: []const u8) !terminal.Paste {
        return error.ReadOnlyDocument;
    }
    fn commitPaste(_: *anyopaque, _: Binding, _: terminal.Paste, _: u64, _: bool) !terminal.Submission {
        return error.ReadOnlyDocument;
    }
    fn key(_: *anyopaque, _: Binding, _: terminal.KeyRequest) !terminal.Submission {
        return error.ReadOnlyDocument;
    }
    fn mouse(_: *anyopaque, _: Binding, _: terminal.MouseRequest) !terminal.Submission {
        return error.ReadOnlyDocument;
    }
    fn theme(_: *anyopaque, _: Binding, _: terminal.Theme) !void {
        return error.ReadOnlyDocument;
    }
    fn applicationRecord(raw: *anyopaque, binding: Binding, record: terminal.ApplicationRecord) !void {
        const self = try get(raw, binding);
        if (!record.owner.eql(self.owner)) return error.StaleOwner;
        if (self.timeline) |timeline| try timeline.appendApplication(record, 0);
    }
    const vtable: terminal.Service.VTable = .{ .write = write, .resize = resize, .read = read, .receipt = receipt, .status = status, .text_slot = textSlot, .snapshot = snapshot, .prepare_paste = preparePaste, .commit_paste = commitPaste, .key = key, .mouse = mouse, .create_anchor = createAnchor, .resolve_anchor = resolveAnchor, .release_anchor = releaseAnchor, .selection_text = selectionText, .scroll = scroll, .read_lines = lines, .theme = theme, .search_snapshot = searchSnapshot, .application_record = applicationRecord };
};
