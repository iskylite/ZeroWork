const std = @import("std");
const context = @import("context.zig");
const card = @import("card.zig");

pub const Assembled = struct {
    text: []u8,
    tokens: usize,
    truncated: bool,
    pub fn deinit(self: *Assembled, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
        self.* = undefined;
    }
};

pub const Options = struct {
    selection: ?[]const u8 = null,
    redact_identity: bool = false,
};

pub const Assembler = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) Assembler {
        return .{ .allocator = allocator };
    }

    /// Combines recent session lines and identity metadata without accessing local files.
    pub fn assemble(self: Assembler, provider: context.SessionContextProvider, context_window: u32) !Assembled {
        return self.assembleWithOptions(provider, context_window, .{});
    }

    pub fn assembleWithOptions(self: Assembler, provider: context.SessionContextProvider, context_window: u32, options: Options) !Assembled {
        const budget = card.contextBudget(context_window) * 4;
        var block = try provider.read_lines(provider.ctx, 1024, self.allocator);
        defer block.deinit(self.allocator);
        var output = std.ArrayList(u8).empty;
        defer output.deinit(self.allocator);
        var truncated = block.truncated;
        const identity = provider.identity(provider.ctx);
        const host = if (options.redact_identity and identity.host.len != 0) "<redacted>" else identity.host;
        const user = if (options.redact_identity and identity.user.len != 0) "<redacted>" else identity.user;
        const cwd = provider.cwd(provider.ctx);
        var metadata: [2048]u8 = undefined;
        const metadata_text = if (cwd) |path|
            try std.fmt.bufPrint(&metadata, "host={s} user={s} hops={d} cwd={s}\n", .{ host, user, identity.hops, path })
        else
            try std.fmt.bufPrint(&metadata, "host={s} user={s} hops={d}\n", .{ host, user, identity.hops });
        const selected = options.selection orelse "";
        const selection_extra = if (selected.len == 0) @as(usize, 0) else selected.len + 12;
        const reserved = @min(budget, metadata_text.len + selection_extra);
        const line_budget = budget - reserved;
        var used: usize = 0;
        var first: usize = block.lines.len;
        var i = block.lines.len;
        while (i > 0) {
            i -= 1;
            const extra = block.lines[i].len + 1;
            if (used + extra > line_budget) {
                truncated = true;
                break;
            }
            used += extra;
            first = i;
        }
        if (first < block.lines.len) for (block.lines[first..]) |line| {
            try output.appendSlice(self.allocator, line);
            try output.append(self.allocator, '\n');
        };
        if (metadata_text.len <= budget - output.items.len) try output.appendSlice(self.allocator, metadata_text) else truncated = true;
        if (selected.len != 0) {
            if (output.items.len + selection_extra <= budget) {
                try output.appendSlice(self.allocator, "selection:\n");
                try output.appendSlice(self.allocator, selected);
                try output.append(self.allocator, '\n');
            } else truncated = true;
        }
        const token_estimate = card.estimateTokens(output.items.len);
        return .{ .text = try output.toOwnedSlice(self.allocator), .tokens = token_estimate, .truncated = truncated };
    }
};

test "context assembler truncates to model budget and includes identity" {
    var pages = try @import("../vt/pagelist.zig").PageList.init(std.testing.allocator, 4, 8);
    defer pages.deinit();
    const line = [_]@import("../vt/cell.zig").Cell{@import("../vt/cell.zig").Cell.fromCodepoint('x')};
    _ = try pages.appendLine(&line, 1);
    var terminal: context.TerminalContext = .{ .page_list = &pages, .identity_value = .{ .host = "node", .user = "ops" } };
    var assembled = try Assembler.init(std.testing.allocator).assemble(terminal.provider(), 1024);
    defer assembled.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, assembled.text, "host=node") != null);
}
