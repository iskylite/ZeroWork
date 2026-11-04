//! A submitted command is only a switch candidate. Never inject initialization
//! until the assistant has read the live terminal and confirmed a Shell prompt.
const std = @import("std");
pub const Kind = enum { none, ssh, su, bash, zsh, container };
pub const Notice = struct {
    sequence: u64 = 0,
    pending: bool = false,
    kind: Kind = .none,
    command: [256]u8 = @splat(0),
    command_len: u16 = 0,
    pub fn text(self: *const Notice) []const u8 {
        return self.command[0..self.command_len];
    }
    pub fn jsonStringify(self: Notice, writer: anytype) !void {
        try writer.write(.{ .sequence = self.sequence, .pending = self.pending, .kind = self.kind, .command = self.text() });
    }
    const Wire = struct { sequence: u64 = 0, pending: bool = false, kind: Kind = .none, command: []const u8 = "" };
    fn fromWire(wire: Wire) !Notice {
        var result: Notice = .{ .sequence = wire.sequence, .pending = wire.pending, .kind = wire.kind };
        if (wire.command.len > result.command.len) return error.Overflow;
        if (!std.unicode.utf8ValidateSlice(wire.command)) return error.InvalidCharacter;
        @memcpy(result.command[0..wire.command.len], wire.command);
        result.command_len = @intCast(wire.command.len);
        return result;
    }
    pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !Notice {
        return fromWire(try std.json.innerParse(Wire, allocator, source, options));
    }
    pub fn jsonParseFromValue(allocator: std.mem.Allocator, value: std.json.Value, options: std.json.ParseOptions) !Notice {
        return fromWire(try std.json.innerParseFromValue(Wire, allocator, value, options));
    }
    pub fn submitted(self: *Notice, command: []const u8) void {
        const kind = classify(command);
        if (kind == .none) return;
        self.sequence +|= 1;
        self.pending = true;
        self.kind = kind;
        var len = @min(command.len, self.command.len);
        while (len > 0 and !std.unicode.utf8ValidateSlice(command[0..len])) len -= 1;
        @memcpy(self.command[0..len], command[0..len]);
        self.command_len = @intCast(len);
    }
};
pub fn classify(command: []const u8) Kind {
    var words = std.mem.tokenizeAny(u8, command, " \t\r\n");
    var first = words.next() orelse return .none;
    // These common prefixes preserve the command; aliases/complex syntax fall
    // back to the same assistant attachment tool after execution preflight.
    while (std.mem.eql(u8, first, "command") or std.mem.eql(u8, first, "exec")) first = words.next() orelse return .none;
    first = std.fs.path.basename(first);
    if (std.mem.eql(u8, first, "ssh")) return .ssh;
    if (std.mem.eql(u8, first, "su")) return .su;
    if (std.mem.eql(u8, first, "bash")) return .bash;
    if (std.mem.eql(u8, first, "zsh")) return .zsh;
    if (std.mem.eql(u8, first, "docker") or std.mem.eql(u8, first, "podman")) {
        if (std.mem.eql(u8, words.next() orelse return .none, "exec")) return .container;
    }
    return .none;
}
test "shell switch detection is a candidate and does not interpret arbitrary text" {
    var notice: Notice = .{};
    for ([_][]const u8{ "ssh host", "su - root", "bash", "command /bin/zsh -f", "docker exec -it c bash", "podman exec -it c zsh" }) |command| {
        notice.submitted(command);
        try std.testing.expect(notice.pending and notice.kind != .none);
    }
    try std.testing.expectEqual(@as(u64, 6), notice.sequence);
    for ([_][]const u8{ "echo ssh host", "cat file", "docker ps", "tmux", "screen", "my-login" }) |command| try std.testing.expectEqual(Kind.none, classify(command));
    // ssh remote commands/failed connections still only create a candidate.
    try std.testing.expectEqual(Kind.ssh, classify("ssh host uname"));
}

test "shell switch compact wire roundtrips empty short and bounded commands" {
    const a = std.testing.allocator;
    var long: [256]u8 = @splat('x');
    @memcpy(long[0..4], "ssh ");
    for ([_][]const u8{ "", "ssh 主机", &long }) |command| {
        var original: Notice = .{};
        original.submitted(command);
        const json = try std.json.Stringify.valueAlloc(a, original, .{});
        defer a.free(json);
        const parsed = try std.json.parseFromSlice(Notice, a, json, .{});
        defer parsed.deinit();
        try std.testing.expectEqualDeep(original, parsed.value);
        const value = try std.json.parseFromSlice(std.json.Value, a, json, .{});
        defer value.deinit();
        const from_value = try std.json.parseFromValue(Notice, a, value.value, .{});
        defer from_value.deinit();
        try std.testing.expectEqualDeep(original, from_value.value);
    }
    const oversized = try std.fmt.allocPrint(a, "{{\"command\":\"{s}x\"}}", .{long});
    defer a.free(oversized);
    try std.testing.expectError(error.Overflow, std.json.parseFromSlice(Notice, a, oversized, .{}));
}
