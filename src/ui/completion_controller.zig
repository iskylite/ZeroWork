const std = @import("std");
const completion = @import("completion.zig");
const state_mod = @import("completion_state.zig");

pub const Controller = struct {
    allocator: std.mem.Allocator,
    candidates: std.ArrayList(completion.Candidate) = .empty,
    owned_text: std.ArrayList([]u8) = .empty,
    state: state_mod.State = .{},
    enabled: bool,

    pub fn init(allocator: std.mem.Allocator, enabled: bool) Controller {
        return .{ .allocator = allocator, .enabled = enabled };
    }

    pub fn deinit(self: *Controller) void {
        for (self.owned_text.items) |text| self.allocator.free(text);
        self.owned_text.deinit(self.allocator);
        self.candidates.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn add(self: *Controller, text: []const u8, source: completion.Source, frequency: u32, last_used_ms: i64) !void {
        const owned = try self.allocator.dupe(u8, text);
        errdefer self.allocator.free(owned);
        try self.owned_text.append(self.allocator, owned);
        errdefer _ = self.owned_text.pop();
        try self.candidates.append(self.allocator, .{ .text = owned, .source = source, .frequency = frequency, .last_used_ms = last_used_ms });
    }

    pub fn suggest(self: *Controller, query: []const u8, now_ms: i64, scratch: []completion.Match) ?[]const u8 {
        if (!self.enabled) return null;
        self.state.suggestion = (completion.Engine{ .candidates = self.candidates.items }).ghostText(query, now_ms, scratch);
        return self.state.suggestion;
    }

    pub fn menu(self: *Controller, query: []const u8, now_ms: i64, output: []completion.Match) []completion.Match {
        if (!self.enabled) return output[0..0];
        self.state.menu_open = true;
        return (completion.Engine{ .candidates = self.candidates.items }).top(query, now_ms, output);
    }

    /// Ordinary shell suggestions use only this owner's observed submissions.
    /// A contiguous match may replace the full buffer through TrustedEdit.
    pub fn historyMenu(self: *Controller, query: []const u8, now_ms: i64, output: []completion.Match) []completion.Match {
        return self.historyMatches(query, now_ms, output, false);
    }

    /// Without a shell editing provider, acceptance can only append a suffix.
    pub fn historyPrefixMenu(self: *Controller, query: []const u8, now_ms: i64, output: []completion.Match) []completion.Match {
        return self.historyMatches(query, now_ms, output, true);
    }

    fn historyMatches(self: *Controller, query: []const u8, now_ms: i64, output: []completion.Match, prefix_only: bool) []completion.Match {
        if (!self.enabled or query.len == 0) return output[0..0];
        var count: usize = 0;
        for (self.candidates.items) |candidate| {
            if (candidate.source != .history or std.mem.indexOf(u8, candidate.text, query) == null or std.mem.eql(u8, candidate.text, query)) continue;
            if (prefix_only and !std.mem.startsWith(u8, candidate.text, query)) continue;
            const score = @as(f64, @floatFromInt(candidate.frequency)) + 1.0 / (1.0 + @as(f64, @floatFromInt(@max(0, now_ms - candidate.last_used_ms))));
            if (output.len == 0) break;
            var index = @min(count, output.len - 1);
            if (count < output.len) count += 1 else if (score <= output[index].score) continue;
            while (index > 0 and output[index - 1].score < score) : (index -= 1) output[index] = output[index - 1];
            output[index] = .{ .candidate = candidate, .score = score };
        }
        return output[0..count];
    }

    pub fn dismiss(self: *Controller) void {
        self.state.suggestion = null;
        self.state.menu_open = false;
    }

    pub fn accept(self: *Controller, query: []const u8, allocator: std.mem.Allocator) !?[]u8 {
        const suffix = self.state.suggestion orelse return null;
        const result = try std.mem.concat(allocator, u8, &.{ query, suffix });
        self.state.suggestion = null;
        return result;
    }
};

test "completion controller fuses sources and accepts ghost text" {
    var controller = Controller.init(std.testing.allocator, true);
    defer controller.deinit();
    try controller.add("git status", .builtin, 1, 0);
    try controller.add("git stash", .history, 5, 100);
    try controller.add("/srv/git", .path, 2, 100);
    var scratch: [8]completion.Match = undefined;
    try std.testing.expectEqualStrings("ash", controller.suggest("git st", 100, &scratch).?);
    const accepted = (try controller.accept("git st", std.testing.allocator)).?;
    defer std.testing.allocator.free(accepted);
    try std.testing.expectEqualStrings("git stash", accepted);
}

test "completion menu exposes ranked candidates" {
    var controller = Controller.init(std.testing.allocator, true);
    defer controller.deinit();
    try controller.add("git status", .builtin, 1, 0);
    try controller.add("git stash", .history, 2, 0);
    var menu: [2]completion.Match = undefined;
    try std.testing.expectEqual(@as(usize, 2), controller.menu("git", 0, &menu).len);
}

test "disabled completion produces no suggestions" {
    var controller = Controller.init(std.testing.allocator, false);
    defer controller.deinit();
    try controller.add("ls -la", .builtin, 1, 0);
    var scratch: [2]completion.Match = undefined;
    try std.testing.expect(controller.suggest("ls", 0, &scratch) == null);
}

test "ordinary history menu uses contiguous owner history and caps supplied slots" {
    var controller = Controller.init(std.testing.allocator, true);
    defer controller.deinit();
    try controller.add("systemctl restart worker", .history, 5, 100);
    try controller.add("journalctl -u worker", .history, 2, 100);
    try controller.add("worker", .history, 10, 100);
    try controller.add("word breaker", .history, 8, 100);
    try controller.add("worker builtin", .builtin, 100, 100);
    try controller.add("/srv/worker", .path, 100, 100);
    var output: [1]completion.Match = undefined;
    const matches = controller.historyMenu("worker", 100, &output);
    try std.testing.expectEqual(@as(usize, 1), matches.len);
    try std.testing.expectEqualStrings("systemctl restart worker", matches[0].candidate.text);
    try std.testing.expectEqual(@as(usize, 0), controller.historyMenu("", 100, &output).len);
    controller.enabled = false;
    try std.testing.expectEqual(@as(usize, 0), controller.historyMenu("worker", 100, &output).len);
}

test "observed completion history only offers appendable prefixes" {
    var controller = Controller.init(std.testing.allocator, true);
    defer controller.deinit();
    try controller.add("find . -name __pycache__", .history, 1, 100);
    try controller.add("sudo find /tmp", .history, 10, 100);
    try controller.add("find", .history, 10, 100);
    try controller.add("find builtin", .builtin, 10, 100);
    var output: [6]completion.Match = undefined;
    const matches = controller.historyPrefixMenu("find", 100, &output);
    try std.testing.expectEqual(@as(usize, 1), matches.len);
    try std.testing.expectEqualStrings("find . -name __pycache__", matches[0].candidate.text);
}
