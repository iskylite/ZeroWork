const std = @import("std");

pub const Source = enum { history, path, builtin };
pub const Candidate = struct {
    text: []const u8,
    source: Source,
    frequency: u32 = 1,
    last_used_ms: i64 = 0,
};
pub const Match = struct { candidate: Candidate, score: f64 };

pub const Engine = struct {
    candidates: []const Candidate,
    half_life_ms: f64 = 7.0 * 24.0 * 60.0 * 60.0 * 1000.0,

    pub fn top(self: Engine, query: []const u8, now_ms: i64, output: []Match) []Match {
        var len: usize = 0;
        for (self.candidates) |candidate| {
            const match_score = matchScore(query, candidate.text) orelse continue;
            const age: f64 = @floatFromInt(@max(now_ms - candidate.last_used_ms, 0));
            const recency = @exp(-age / self.half_life_ms);
            const source_weight: f64 = switch (candidate.source) {
                .history => 1.0,
                .path => 0.9,
                .builtin => 0.75,
            };
            const score = match_score * source_weight * (@as(f64, @floatFromInt(candidate.frequency)) * recency + 1.0);
            insertSorted(output, &len, .{ .candidate = candidate, .score = score });
        }
        return output[0..len];
    }

    pub fn ghostText(self: Engine, query: []const u8, now_ms: i64, scratch: []Match) ?[]const u8 {
        if (query.len == 0) return null;
        const matches = self.top(query, now_ms, scratch);
        // Fuzzy matches may rank higher in the menu, but cannot be appended
        // to the remote line. Pick the best actual prefix among predictions.
        for (matches) |match| {
            const text = match.candidate.text;
            if (std.mem.startsWith(u8, text, query) and text.len > query.len) return text[query.len..];
        }
        return null;
    }
};

fn matchScore(query: []const u8, candidate: []const u8) ?f64 {
    if (query.len == 0) return 1.0;
    if (std.mem.startsWith(u8, candidate, query)) return 1.0 + @as(f64, @floatFromInt(query.len)) / @as(f64, @floatFromInt(candidate.len));
    var qi: usize = 0;
    for (candidate) |byte| if (qi < query.len and std.ascii.toLower(byte) == std.ascii.toLower(query[qi])) {
        qi += 1;
    };
    if (qi != query.len) return null;
    return 0.6 * @as(f64, @floatFromInt(query.len)) / @as(f64, @floatFromInt(candidate.len));
}

fn insertSorted(output: []Match, len: *usize, value: Match) void {
    if (output.len == 0) return;
    var index = @min(len.*, output.len - 1);
    if (len.* < output.len) len.* += 1 else if (value.score <= output[output.len - 1].score) return;
    while (index > 0 and output[index - 1].score < value.score) : (index -= 1) output[index] = output[index - 1];
    output[index] = value;
}

test "completion ranks prefix and recent history above static entries" {
    const candidates = [_]Candidate{
        .{ .text = "git status", .source = .builtin },
        .{ .text = "git stash", .source = .history, .frequency = 4, .last_used_ms = 1_000 },
        .{ .text = "/srv/git", .source = .path },
    };
    var output: [3]Match = undefined;
    const matches = (Engine{ .candidates = &candidates }).top("git st", 1_000, &output);
    try std.testing.expectEqualStrings("git stash", matches[0].candidate.text);
}

test "completion provides prefix suffix and keeps tab out of policy" {
    const candidates = [_]Candidate{.{ .text = "kubectl get pods", .source = .builtin }};
    var scratch: [1]Match = undefined;
    try std.testing.expectEqualStrings("ctl get pods", (Engine{ .candidates = &candidates }).ghostText("kube", 0, &scratch).?);
}

test "ghost never appends a fuzzy replacement or empty suffix" {
    const candidates = [_]Candidate{.{ .text = "git status", .source = .history, .frequency = 200 }};
    var scratch: [1]Match = undefined;
    const engine = Engine{ .candidates = &candidates };
    try std.testing.expect(engine.ghostText("gs", 0, &scratch) == null);
    try std.testing.expect(engine.ghostText("git status", 0, &scratch) == null);
    try std.testing.expectEqual(@as(usize, 1), engine.top("", 0, &scratch).len);
}
