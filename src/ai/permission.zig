const std = @import("std");
pub const Mode = enum { confirm, auto };
pub const Verdict = enum { allow_auto, need_confirm, deny_exec_copy_only };
pub const Engine = struct { mode: Mode = .confirm, whitelist: []const []const u8 = &.{ "ps", "df", "free", "ls", "cat", "grep", "kubectl get", "systemctl status" } };
const readonly = [_][]const u8{ "ps", "df", "free", "ls", "cat", "grep", "kubectl get", "kubectl describe", "kubectl logs", "systemctl status" };
pub fn classify(engine: Engine, command: []const u8, grouped: bool) Verdict {
    if (isBlocked(command)) return .deny_exec_copy_only;
    // A prefix is never a proof about a compound shell command. Keep these
    // plans confirm-only instead of accidentally authorizing trailing writes.
    if (std.mem.indexOfAny(u8, command, ";|&$`\n\r><") != null) return .need_confirm;
    if (isWhitelisted(&readonly, command)) return .allow_auto;
    if (engine.mode == .auto and !grouped and isWhitelisted(engine.whitelist, command)) return .allow_auto;
    return .need_confirm;
}
fn isWhitelisted(list: []const []const u8, command: []const u8) bool {
    for (list) |prefix| if (std.mem.startsWith(u8, command, prefix) and (command.len == prefix.len or (command.len > prefix.len and command[prefix.len] == ' '))) return true;
    return false;
}
fn isBlocked(command: []const u8) bool {
    return std.mem.startsWith(u8, command, "rm -rf /") or std.mem.startsWith(u8, command, "mkfs") or std.mem.startsWith(u8, command, "shutdown");
}
test "permission engine blocks dangerous and auto allows readonly" {
    const e: Engine = .{ .mode = .auto };
    try std.testing.expectEqual(Verdict.deny_exec_copy_only, classify(e, "rm -rf /", false));
    try std.testing.expectEqual(Verdict.allow_auto, classify(e, "ps aux", false));
    try std.testing.expectEqual(Verdict.need_confirm, classify(e, "echo hi > x", true));
}

test "auto requires a matching template and does not authorize compound commands" {
    const e: Engine = .{ .mode = .auto, .whitelist = &.{"kubectl rollout restart"} };
    try std.testing.expectEqual(Verdict.need_confirm, classify(e, "touch /tmp/file", false));
    try std.testing.expectEqual(Verdict.allow_auto, classify(e, "kubectl rollout restart deploy/api", false));
    try std.testing.expectEqual(Verdict.need_confirm, classify(e, "kubectl rollout restart deploy/api", true));
    try std.testing.expectEqual(Verdict.need_confirm, classify(e, "cat /var/log/app.log; touch /tmp/file", false));
    try std.testing.expectEqual(Verdict.need_confirm, classify(e, "catastrophe", false));
}
