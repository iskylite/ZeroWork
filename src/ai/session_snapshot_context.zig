const std = @import("std");
const context = @import("context.zig");
const assembler = @import("assembler.zig");
const card = @import("card.zig");

/// The immutable inputs captured by the UI before a request is submitted.
/// `provider` must point at the owning session snapshot; this module never
/// opens files or reaches back into the local machine.
/// Adapter for the retained terminal text returned by `SshWorker.searchText`.
/// The text is copied into an owned snapshot before the worker is released.
pub const RetainedTextContext = struct {
    allocator: std.mem.Allocator,
    text: []u8,
    identity_value: context.SessionIdentity = .{},
    cwd_owned: ?[]u8 = null,

    pub fn init(allocator: std.mem.Allocator, text: []const u8, identity: context.SessionIdentity, cwd: ?[]const u8) !RetainedTextContext {
        const host = try allocator.dupe(u8, identity.host);
        errdefer allocator.free(host);
        const user = try allocator.dupe(u8, identity.user);
        errdefer allocator.free(user);
        const cwd_copy = if (cwd) |value| try allocator.dupe(u8, value) else null;
        errdefer if (cwd_copy) |value| allocator.free(value);
        const text_copy = try allocator.dupe(u8, text);
        errdefer allocator.free(text_copy);
        return .{ .allocator = allocator, .text = text_copy, .identity_value = .{ .host = host, .user = user, .hops = identity.hops }, .cwd_owned = cwd_copy };
    }
    pub fn deinit(self: *RetainedTextContext) void {
        self.allocator.free(self.text);
        self.allocator.free(self.identity_value.host);
        self.allocator.free(self.identity_value.user);
        if (self.cwd_owned) |value| self.allocator.free(value);
        self.* = undefined;
    }
    pub fn provider(self: *RetainedTextContext) context.SessionContextProvider {
        return .{ .ctx = self, .read_lines = readLines, .cwd = getCwd, .identity = getIdentity };
    }
    fn readLines(ctx: *anyopaque, max_lines: u32, allocator: std.mem.Allocator) !context.ContextBlock {
        const self: *RetainedTextContext = @ptrCast(@alignCast(ctx));
        var count: usize = 0;
        var i: usize = self.text.len;
        while (i > 0) : (i -= 1) {
            if (self.text[i - 1] == '\n') count += 1;
        }
        if (self.text.len != 0 and self.text[self.text.len - 1] != '\n') count += 1;
        const wanted = @min(count, @as(usize, max_lines));
        const lines = try allocator.alloc([]u8, wanted);
        errdefer allocator.free(lines);
        var end = self.text.len;
        var n: usize = wanted;
        while (n > 0) {
            const line_end = end;
            var begin = end;
            while (begin > 0 and self.text[begin - 1] != '\n') begin -= 1;
            const slice_end = if (line_end > begin and self.text[line_end - 1] == '\n') line_end - 1 else line_end;
            n -= 1;
            lines[n] = try allocator.dupe(u8, self.text[begin..slice_end]);
            end = if (begin > 0) begin - 1 else 0;
        }
        return .{ .lines = lines, .cwd = self.cwd_owned, .shell = null, .truncated = wanted < count };
    }
    fn getCwd(ctx: *anyopaque) ?[]const u8 {
        return @as(*RetainedTextContext, @ptrCast(@alignCast(ctx))).cwd_owned;
    }
    fn getIdentity(ctx: *anyopaque) context.SessionIdentity {
        return @as(*RetainedTextContext, @ptrCast(@alignCast(ctx))).identity_value;
    }
};

pub fn assembleText(allocator: std.mem.Allocator, text: []const u8, identity: context.SessionIdentity, cwd: ?[]const u8, selection: ?[]const u8, redact_ip: bool, context_window: u32) !assembler.Assembled {
    var retained = try RetainedTextContext.init(allocator, text, identity, cwd);
    defer retained.deinit();
    return assemble(allocator, .{ .terminal = retained.provider(), .selection = selection, .redact_ip = redact_ip, .context_window = context_window });
}

pub const Inputs = struct {
    terminal: context.SessionContextProvider,
    selection: ?[]const u8 = null,
    redact_ip: bool = false,
    context_window: u32 = 8192,
};

/// Build the request context from a live, owned session snapshot. Terminal
/// output is retained text from the remote PTY; selection is treated as user
/// supplied command/output text and is never rewritten by redaction.
pub fn assemble(allocator: std.mem.Allocator, inputs: Inputs) !assembler.Assembled {
    return assembler.Assembler.init(allocator).assembleWithOptions(inputs.terminal, inputs.context_window, .{
        .selection = inputs.selection,
        .redact_identity = inputs.redact_ip,
    });
}

fn testProvider(_: *anyopaque, _: u32, allocator: std.mem.Allocator) !context.ContextBlock {
    const lines = try allocator.alloc([]u8, 4);
    errdefer allocator.free(lines);
    for (lines, 0..) |*line, i| line.* = try allocator.dupe(u8, switch (i) {
        0 => "old",
        1 => "run 10.20.1.18",
        2 => "new",
        else => "utf8 你好",
    });
    return .{ .lines = lines, .cwd = "/srv/app", .shell = null, .truncated = false };
}
fn testCwd(_: *anyopaque) ?[]const u8 {
    return "/srv/app";
}
fn testIdentity(_: *anyopaque) context.SessionIdentity {
    return .{ .host = "10.20.1.18", .user = "deploy", .hops = 1 };
}

fn provider() context.SessionContextProvider {
    return .{ .ctx = undefined, .read_lines = testProvider, .cwd = testCwd, .identity = testIdentity };
}

test "snapshot keeps newest lines, metadata and selection" {
    var result = try assemble(std.testing.allocator, .{ .terminal = provider(), .selection = "echo 10.20.1.18", .context_window = 2000 });
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "old") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "selection:\necho 10.20.1.18") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "cwd=/srv/app") != null);
}

test "redaction masks identity metadata but does not rewrite command text" {
    var result = try assemble(std.testing.allocator, .{ .terminal = provider(), .selection = "connect 10.20.1.18", .redact_ip = true, .context_window = 2000 });
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "host=<redacted> user=<redacted>") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "run 10.20.1.18") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "connect 10.20.1.18") != null);
}

test "empty source and utf8 are safe" {
    const empty = struct {
        fn read(_: *anyopaque, _: u32, a: std.mem.Allocator) !context.ContextBlock {
            return .{ .lines = try a.alloc([]u8, 0), .cwd = null, .shell = null, .truncated = false };
        }
        fn cwd(_: *anyopaque) ?[]const u8 {
            return null;
        }
        fn id(_: *anyopaque) context.SessionIdentity {
            return .{};
        }
    };
    var result = try assemble(std.testing.allocator, .{ .terminal = .{ .ctx = undefined, .read_lines = empty.read, .cwd = empty.cwd, .identity = empty.id }, .context_window = 8192 });
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("host= user= hops=0\n", result.text);
}
