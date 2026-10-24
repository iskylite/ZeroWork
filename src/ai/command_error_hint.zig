//! A failed command is a shell semantic fact, never a match on output words.
const std = @import("std");
const identity = @import("../host/identity.zig");
const vt = @import("../vt/snapshot.zig");

pub const Hint = struct {
    owner: identity.SessionHandle,
    /// The original owner's OSC output_start sequence identifies this command.
    command_id: u64,
    end_sequence: u64,
    command: []const u8,
    output: []const u8,
    exit_code: i32,
};
pub const Handler = struct {
    context: ?*anyopaque = null,
    /// Borrowed immutable strings are valid for this synchronous call only.
    on_open: *const fn (?*anyopaque, Hint) anyerror!void,
};

pub const Model = struct {
    allocator: std.mem.Allocator,
    owner: ?identity.SessionHandle = null,
    enabled: bool = false,
    baseline_pending: bool = true,
    seen_sequence: u64 = 0,
    running_id: ?u64 = null,
    command: []u8 = &.{},
    pending: ?Hint = null,

    pub fn init(allocator: std.mem.Allocator) Model {
        return .{ .allocator = allocator };
    }
    pub fn deinit(self: *Model) void {
        self.dismiss();
        self.clearRunning();
    }
    pub fn configure(self: *Model, owner: identity.SessionHandle, enabled: bool) void {
        if (self.owner != null and self.owner.?.eql(owner) and self.enabled == enabled) return;
        self.dismiss();
        self.clearRunning();
        self.owner = owner;
        self.enabled = enabled;
        self.baseline_pending = true;
        self.seen_sequence = 0;
    }
    pub fn resetFacts(self: *Model) void {
        self.dismiss();
        self.clearRunning();
        self.baseline_pending = true;
        self.seen_sequence = 0;
    }
    pub fn primeSequence(self: *Model, owner: identity.SessionHandle, sequence: u64) !void {
        if (self.owner == null or !self.owner.?.eql(owner)) return error.StaleOwner;
        if (!self.baseline_pending) return;
        self.seen_sequence = sequence;
        self.baseline_pending = false;
    }
    /// The first snapshot after binding/enabling establishes a cutoff. Old
    /// failures never become new merely because settings or paint changed.
    pub fn observe(self: *Model, owner: identity.SessionHandle, projection: *const vt.Projection) !bool {
        if (self.owner == null or !self.owner.?.eql(owner)) return error.StaleOwner;
        if (self.baseline_pending) {
            for (projection.events) |event| self.seen_sequence = @max(self.seen_sequence, event.sequence);
            self.baseline_pending = false;
            return false;
        }
        var changed = false;
        for (projection.events) |event| {
            if (event.sequence <= self.seen_sequence) continue;
            if (self.seen_sequence != 0 and event.sequence > self.seen_sequence +| 1) self.clearRunning();
            self.seen_sequence = event.sequence;
            switch (event.kind) {
                .output_start => {
                    self.clearRunning();
                    self.command = try copyBounded(self.allocator, event.text, 4096);
                    self.running_id = event.sequence;
                },
                .command_end => {
                    defer self.clearRunning();
                    const command_id = self.running_id orelse continue;
                    const code = event.exit_code orelse continue;
                    if (!self.enabled or code == 0) continue;
                    const command = try self.allocator.dupe(u8, self.command);
                    errdefer self.allocator.free(command);
                    const output = try projectionText(self.allocator, projection, 16 * 1024);
                    self.dismiss();
                    self.pending = .{ .owner = owner, .command_id = command_id, .end_sequence = event.sequence, .command = command, .output = output, .exit_code = code };
                    changed = true;
                },
                else => {},
            }
        }
        return changed;
    }
    pub fn current(self: *const Model, owner: identity.SessionHandle, command_id: u64) ?Hint {
        if (!self.enabled or self.owner == null or !self.owner.?.eql(owner)) return null;
        const hint = self.pending orelse return null;
        return if (hint.owner.eql(owner) and hint.command_id == command_id) hint else null;
    }
    pub fn dismiss(self: *Model) void {
        if (self.pending) |hint| {
            self.allocator.free(hint.command);
            self.allocator.free(hint.output);
        }
        self.pending = null;
    }
    fn clearRunning(self: *Model) void {
        self.allocator.free(self.command);
        self.command = &.{};
        self.running_id = null;
    }
};

/// Draft only. The caller opens this original owner's composer and never
/// dispatches the question or executes the captured command automatically.
pub fn question(allocator: std.mem.Allocator, existing: []const u8, hint: Hint) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}{s}请分析这条命令失败的原因，并给出修复建议。\n命令：{s}\n退出码：{d}\n终端输出上下文：\n{s}", .{ existing, if (existing.len == 0) "" else "\n\n", if (hint.command.len == 0) "（未提供）" else hint.command, hint.exit_code, hint.output });
}

fn copyBounded(allocator: std.mem.Allocator, text: []const u8, limit: usize) ![]u8 {
    var length = @min(text.len, limit);
    while (length > 0 and !std.unicode.utf8ValidateSlice(text[0..length])) length -= 1;
    return allocator.dupe(u8, text[0..length]);
}

/// Preserve the original parsed VT context. Escape/control bytes never enter
/// this text: these are projected graphemes, not raw PTY chunks.
pub fn projectionText(allocator: std.mem.Allocator, projection: *const vt.Projection, limit: usize) ![]u8 {
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);
    for (projection.visible_rows) |row| {
        const start = result.items.len;
        const cells = projection.cells[row.cell_start..][0..row.cell_count];
        for (cells) |cell| {
            if (cell.width == .wide_tail) continue;
            const grapheme = projection.grapheme(cell);
            const bytes = if (grapheme.len == 0) " " else grapheme;
            if (result.items.len + bytes.len > limit) return result.toOwnedSlice(allocator);
            try result.appendSlice(allocator, bytes);
        }
        while (result.items.len > start and result.items[result.items.len - 1] == ' ') result.items.len -= 1;
        if (result.items.len == limit) break;
        try result.append(allocator, '\n');
    }
    return result.toOwnedSlice(allocator);
}
