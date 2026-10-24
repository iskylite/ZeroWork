const std = @import("std");
const PageList = @import("../vt/pagelist.zig").PageList;
const Cell = @import("../vt/cell.zig").Cell;

pub const SessionIdentity = struct {
    host: []const u8 = "",
    user: []const u8 = "",
    hops: u8 = 0,
};

pub const ContextBlock = struct {
    lines: [][]u8,
    cwd: ?[]const u8,
    shell: ?[]const u8,
    truncated: bool,

    pub fn deinit(self: *ContextBlock, allocator: std.mem.Allocator) void {
        for (self.lines) |line| allocator.free(line);
        allocator.free(self.lines);
        self.* = undefined;
    }
};

pub const SessionContextProvider = struct {
    ctx: *anyopaque,
    read_lines: *const fn (ctx: *anyopaque, max_lines: u32, allocator: std.mem.Allocator) anyerror!ContextBlock,
    cwd: *const fn (ctx: *anyopaque) ?[]const u8,
    identity: *const fn (ctx: *anyopaque) SessionIdentity,
};

pub const TerminalContext = struct {
    page_list: *const PageList,
    cwd_value: ?[]const u8 = null,
    shell_value: ?[]const u8 = null,
    identity_value: SessionIdentity = .{},

    pub fn provider(self: *TerminalContext) SessionContextProvider {
        return .{ .ctx = self, .read_lines = readLines, .cwd = cwd, .identity = identity };
    }

    fn readLines(ctx: *anyopaque, max_lines: u32, allocator: std.mem.Allocator) !ContextBlock {
        const self: *TerminalContext = @ptrCast(@alignCast(ctx));
        const available = self.page_list.snapshot().next_row - self.page_list.snapshot().first_row;
        const count: usize = @intCast(@min(@as(u64, max_lines), available));
        const lines = try allocator.alloc([]u8, count);
        errdefer allocator.free(lines);
        var written: usize = 0;
        const start = self.page_list.snapshot().next_row - count;
        errdefer for (lines[0..written]) |line| allocator.free(line);
        for (lines) |*slot| {
            slot.* = try lineToText(self.page_list.lineAt(start + written).?, allocator);
            written += 1;
        }
        return .{ .lines = lines, .cwd = self.cwd_value, .shell = self.shell_value, .truncated = count < available };
    }

    fn cwd(ctx: *anyopaque) ?[]const u8 {
        return @as(*TerminalContext, @ptrCast(@alignCast(ctx))).cwd_value;
    }
    fn identity(ctx: *anyopaque) SessionIdentity {
        return @as(*TerminalContext, @ptrCast(@alignCast(ctx))).identity_value;
    }
};

fn lineToText(line: anytype, allocator: std.mem.Allocator) ![]u8 {
    const capacity = try std.math.mul(usize, line.cells.len, 4);
    var out = try allocator.alloc(u8, capacity);
    errdefer allocator.free(out);
    var end: usize = 0;
    for (line.cells) |cell| {
        if (cell.width == .wide_tail or cell.codepoint == 0) continue;
        end += try std.unicode.utf8Encode(cell.codepoint, out[end..][0..4]);
    }
    return allocator.realloc(out, end);
}

test "terminal context returns recent plain lines and truncation" {
    var pages = try PageList.init(std.testing.allocator, 4, 8);
    defer pages.deinit();
    const a = [_]Cell{ Cell.fromCodepoint('o'), Cell.fromCodepoint('k') };
    _ = try pages.appendLine(&a, 1);
    var terminal: TerminalContext = .{ .page_list = &pages, .cwd_value = "/tmp" };
    var block = try terminal.provider().read_lines(terminal.provider().ctx, 1, std.testing.allocator);
    defer block.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), block.lines.len);
    try std.testing.expectEqualStrings("ok  ", block.lines[0]);
    try std.testing.expect(!block.truncated);
}

test "terminal context returns newest lines and marks truncation" {
    var pages = try PageList.init(std.testing.allocator, 2, 8);
    defer pages.deinit();
    const a = [_]Cell{Cell.fromCodepoint('a')};
    const b = [_]Cell{Cell.fromCodepoint('b')};
    _ = try pages.appendLine(&a, 1);
    _ = try pages.appendLine(&b, 2);
    var terminal: TerminalContext = .{ .page_list = &pages, .identity_value = .{ .host = "node", .user = "ops", .hops = 2 } };
    const provider = terminal.provider();
    var block = try provider.read_lines(provider.ctx, 1, std.testing.allocator);
    defer block.deinit(std.testing.allocator);
    try std.testing.expect(block.truncated);
    try std.testing.expectEqualStrings("b ", block.lines[0]);
    try std.testing.expectEqual(@as(u8, 2), provider.identity(provider.ctx).hops);
}

test "terminal context emits utf8 and omits wide tail placeholders" {
    var pages = try PageList.init(std.testing.allocator, 3, 8);
    defer pages.deinit();
    var lead = Cell.fromCodepoint(0x754c);
    lead.width = .wide_lead;
    var tail = Cell.blank();
    tail.width = .wide_tail;
    const cells = [_]Cell{ Cell.fromCodepoint(0x4f60), lead, tail };
    _ = try pages.appendLine(&cells, 1);
    var terminal: TerminalContext = .{ .page_list = &pages };
    const provider = terminal.provider();
    var block = try provider.read_lines(provider.ctx, 1, std.testing.allocator);
    defer block.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("你界", block.lines[0]);
}
