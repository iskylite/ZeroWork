const std = @import("std");
pub const Mode = enum { confirm, auto };
pub const Verdict = enum { allow_auto, need_confirm, deny_exec_copy_only };
pub const Engine = struct { mode: Mode = .confirm, whitelist: []const []const u8 = &.{ "ps", "df", "free", "ls", "cat", "grep", "kubectl get", "systemctl status" } };
/// Only the mode changes while a worker runs; command templates stay owned by
/// the request. The UI and worker never mutate/read the same plain enum.
pub const LiveMode = struct {
    const Value = enum(u8) { inherit, confirm, auto };
    value: std.atomic.Value(Value) = .init(.inherit),
    pub fn set(self: *LiveMode, mode: Mode) void {
        self.value.store(if (mode == .auto) .auto else .confirm, .release);
    }
    pub fn reset(self: *LiveMode) void {
        self.value.store(.inherit, .release);
    }
    pub fn apply(self: *const LiveMode, engine: Engine) Engine {
        var result = engine;
        result.mode = switch (self.value.load(.acquire)) {
            .inherit => engine.mode,
            .confirm => .confirm,
            .auto => .auto,
        };
        return result;
    }
};
const readonly = [_][]const u8{ "ps", "df", "free", "ls", "cat", "grep", "kubectl get", "kubectl describe", "kubectl logs", "systemctl status" };
pub fn classify(engine: Engine, command: []const u8, _: bool) Verdict {
    switch (@import("shell_policy.zig").inspect(command)) {
        .blocked => return .deny_exec_copy_only,
        .uncertain => return .need_confirm,
        .ordinary => {},
    }
    // Automatic execution covers every validated command in the captured
    // scope, independently of shell syntax, templates or group membership.
    if (engine.mode == .auto) return .allow_auto;
    if (std.mem.indexOfAny(u8, command, ";|&$`\n\r><(){}") != null) return .need_confirm;
    if (isWhitelisted(&readonly, command)) return .allow_auto;
    return .need_confirm;
}
fn isWhitelisted(list: []const []const u8, command: []const u8) bool {
    for (list) |prefix| if (std.mem.startsWith(u8, command, prefix) and (command.len == prefix.len or (command.len > prefix.len and command[prefix.len] == ' '))) return true;
    return false;
}
/// An attached PTY uses the existing shell's variable attributes.
pub fn classifyTerminal(engine: Engine, command: []const u8, _: bool) Verdict {
    return switch (@import("shell_policy.zig").inspectTerminal(command)) {
        .blocked => .deny_exec_copy_only,
        .uncertain => .need_confirm,
        .ordinary => if (engine.mode == .auto) .allow_auto else .need_confirm,
    };
}

test {
    _ = @import("shell_policy_tests.zig");
}

test "permission engine blocks dangerous and auto allows readonly" {
    const e: Engine = .{ .mode = .auto };
    try std.testing.expectEqual(Verdict.deny_exec_copy_only, classify(e, "rm -rf /", false));
    try std.testing.expectEqual(Verdict.allow_auto, classify(e, "ps aux", false));
    try std.testing.expectEqual(Verdict.allow_auto, classify(e, "echo hi > x", true));
}

test "auto covers single compound and grouped commands without template restrictions" {
    const e: Engine = .{ .mode = .auto, .whitelist = &.{"kubectl rollout restart"} };
    try std.testing.expectEqual(Verdict.allow_auto, classify(e, "touch /tmp/file", false));
    try std.testing.expectEqual(Verdict.allow_auto, classify(e, "kubectl rollout restart deploy/api", false));
    try std.testing.expectEqual(Verdict.allow_auto, classify(e, "kubectl rollout restart deploy/api", true));
    try std.testing.expectEqual(Verdict.allow_auto, classify(e, "cat /var/log/app.log; touch /tmp/file", false));
    try std.testing.expectEqual(Verdict.allow_auto, classify(e, "catastrophe", false));
}

test "live permission terminal follows auto and dangerous command gates across all scopes" {
    const engine: Engine = .{ .mode = .auto, .whitelist = &.{"kubectl rollout restart"} };
    try std.testing.expectEqual(Verdict.allow_auto, classifyTerminal(engine, "df -h", false));
    try std.testing.expectEqual(Verdict.allow_auto, classifyTerminal(engine, "kubectl rollout restart deploy/api", false));
    try std.testing.expectEqual(Verdict.allow_auto, classifyTerminal(engine, "kubectl rollout restart deploy/api", true));
    try std.testing.expectEqual(Verdict.allow_auto, classifyTerminal(engine, "df -h; echo x", false));
    try std.testing.expectEqual(Verdict.need_confirm, classifyTerminal(.{}, "df -h", false));
    for ([_][]const u8{ "rm -rf /", "mkfs.ext4 /dev/fixture", "shutdown now", "echo x; shutdown now", "df -h\nrm -rf /" }) |command| {
        try std.testing.expectEqual(Verdict.deny_exec_copy_only, classifyTerminal(engine, command, false));
    }
}

test "auto terminal allows job status query with stderr redirected to stdout" {
    try std.testing.expectEqual(Verdict.allow_auto, classifyTerminal(.{ .mode = .auto }, "/opt/cluskit/bin/clusconf show jobs -b 2>&1 | tail -30", false));
}

test "auto terminal blocks forbidden commands with stderr redirected to stdout" {
    try std.testing.expectEqual(Verdict.deny_exec_copy_only, classifyTerminal(.{ .mode = .auto }, "shutdown now 2>&1 | tail -30", false));
}

test "auto handles single-word redirections and still inspects commands and substitutions" {
    const engine: Engine = .{ .mode = .auto };
    for ([_][]const u8{
        "cat 0<&3 | tail -30",
        "printf done 2>&-",
        "cat 0<>/tmp/redirection-fixture",
        "printf done >| /tmp/redirection-fixture",
        "printf done &>/tmp/redirection-fixture",
        "printf done &>>/tmp/redirection-fixture",
        "cat <<< 'shutdown now'",
    }) |command| {
        try std.testing.expectEqual(Verdict.allow_auto, classifyTerminal(engine, command, false));
    }
    for ([_][]const u8{
        "rm -r 0<&3 -f /tmp/redirection-fixture",
        "rm -r 0<>/tmp/input -f /tmp/redirection-fixture",
        "rm -r >| /tmp/output -f /tmp/redirection-fixture",
        "rm -r &>/tmp/output -f /tmp/redirection-fixture",
        "rm -r &>>/tmp/output -f /tmp/redirection-fixture",
        "cat 0<&3 | shutdown now",
        "cat <<< \"$(shutdown now)\"",
    }) |command| {
        try std.testing.expectEqual(Verdict.deny_exec_copy_only, classifyTerminal(engine, command, false));
    }
    for ([_][]const u8{
        "cat 0<&",
        "printf done >|",
        "cat <<<",
        "cat <<< < /tmp/input",
    }) |command| {
        try std.testing.expectEqual(Verdict.need_confirm, classifyTerminal(engine, command, false));
    }
}

test "auto inspects here-document expansions and commands outside the body" {
    const engine: Engine = .{ .mode = .auto };
    for ([_][]const u8{
        "cat <<EOF\ntext $(printf done)\nEOF",
        "cat <<-EOF\n\ttext\n\tEOF",
        "cat <<'EOF'\n$(shutdown now)\nEOF\nprintf done",
        "cat <<-\"EOF\"\n\tshutdown now\n\tEOF",
        "cat <<EOF\n\\$(shutdown now)\nEOF",
        "cat <<EOF <<OTHER\ntext\nEOF\nOTHER",
        "sh <<'EOF'\nprintf done\nEOF",
        "cat <<'EOF' | sh\nprintf done\nEOF",
    }) |command| {
        try std.testing.expectEqual(Verdict.allow_auto, classifyTerminal(engine, command, false));
    }
    for ([_][]const u8{
        "cat <<EOF\n'$(shutdown now)'\nEOF",
        "cat <<-EOF\n\t`shutdown now`\n\tEOF",
        "cat <<'EOF'\ntext\nEOF\nshutdown now",
        "shutdown now <<EOF\ntext\nEOF",
    }) |command| {
        try std.testing.expectEqual(Verdict.deny_exec_copy_only, classifyTerminal(engine, command, false));
    }
    for ([_][]const u8{
        "cat <<EOF\ntext",
        "cat <<EOF",
        "cat <<EOF\ntext\\\nEOF",
    }) |command| {
        try std.testing.expectEqual(Verdict.need_confirm, classifyTerminal(engine, command, false));
    }
}

test "auto checks commands inside process substitutions and the surrounding command" {
    const engine: Engine = .{ .mode = .auto };
    for ([_][]const u8{
        "cat <(printf done)",
        "cat < <(printf done)",
        "printf done > >(cat)",
        "cat <(cat <(printf done))",
    }) |command| {
        try std.testing.expectEqual(Verdict.allow_auto, classifyTerminal(engine, command, false));
    }
    for ([_][]const u8{
        "cat <(shutdown now)",
        "cat <(cat <(shutdown now))",
        "printf done > >(shutdown now)",
        "rm -r <(printf done) -f /tmp/redirection-fixture",
    }) |command| {
        try std.testing.expectEqual(Verdict.deny_exec_copy_only, classifyTerminal(engine, command, false));
    }
    try std.testing.expectEqual(Verdict.need_confirm, classifyTerminal(engine, "cat <(printf done", false));
}

test "redirections preserve shell and wrapper option operands" {
    const engine: Engine = .{ .mode = .auto };
    for ([_][]const u8{
        "bash -o 2>&1 errexit -c 'shutdown now'",
        "sudo -u >/tmp/redirection-fixture root shutdown now",
        "bash -o &>/tmp/redirection-fixture errexit -c 'shutdown now'",
    }) |command| {
        try std.testing.expectEqual(Verdict.deny_exec_copy_only, classifyTerminal(engine, command, false));
    }
    try std.testing.expectEqual(Verdict.allow_auto, classifyTerminal(engine, "bash -o 2>&1 errexit -c 'printf done'", false));
}

test "auto requires confirmation for uninspectable scripts at redirection boundaries" {
    const engine: Engine = .{ .mode = .auto };
    for ([_][]const u8{
        "sh < <(printf done)",
        "sh <(printf done)",
        "sh -- <(printf done)",
        "cat <<EOF<(printf done)\ntext\nEOF",
        "cat <<EOF\n`printf %s \\\\$VALUE`\nEOF",
    }) |command| {
        try std.testing.expectEqual(Verdict.need_confirm, classifyTerminal(engine, command, false));
    }
}

test "auto compound commands allow shell syntax and deny dangerous command segments" {
    const engine: Engine = .{ .mode = .auto };
    for ([_][]const u8{
        "printf a; printf b",
        "(printf a)",
        "{ printf a; }",
        "printf a | cat",
        "printf a > /tmp/compound-test",
        "cat < /tmp/compound-test",
        "printf a >> /tmp/compound-test 2>/dev/null",
        "true && printf a || printf b",
        "printf a\nprintf b",
        "if [ -d /opt/example ]; then ls /opt/example; else printf missing; fi",
        "printf '%s' $(printf a)",
        "printf '%s' `printf a`",
    }) |command| {
        try std.testing.expectEqual(Verdict.allow_auto, classify(engine, command, false));
        try std.testing.expectEqual(Verdict.allow_auto, classifyTerminal(engine, command, false));
        try std.testing.expectEqual(Verdict.need_confirm, classify(.{}, command, false));
        try std.testing.expectEqual(Verdict.allow_auto, classify(engine, command, true));
    }
    for ([_][]const u8{
        "printf safe; rm -rf /tmp/compound-test",
        "printf safe | mkfs.ext4 /dev/fixture",
        "true && shutdown now",
        "false || shutdown now",
        "printf safe\nrm -rf /tmp/compound-test",
        "if true; then rm -rf /tmp/compound-test; fi",
        "if shutdown now; then printf done; fi",
        "while true; do mkfs.ext4 /dev/fixture; done",
        "printf '%s' $(shutdown now)",
        "printf '%s' `shutdown now`",
        "( shutdown now )",
        "{ rm -rf /tmp/compound-test; }",
        "shutdown now > /tmp/compound-test",
    }) |command| {
        try std.testing.expectEqual(Verdict.deny_exec_copy_only, classify(engine, command, false));
        try std.testing.expectEqual(Verdict.deny_exec_copy_only, classifyTerminal(engine, command, false));
        try std.testing.expectEqual(Verdict.deny_exec_copy_only, classify(.{}, command, false));
    }
}

test "automatic permission denies dangerous commands behind wrappers and shell control" {
    for ([_][]const u8{
        "sudo rm -rf /tmp/auto-fixture",
        "sudo -u root /bin/rm -fr /tmp/auto-fixture",
        "env PATH=/usr/bin /sbin/shutdown now",
        "command /sbin/mkfs.ext4 /dev/fixture",
        "sh -c 'shutdown now'",
        "bash -lc 'rm --recursive --force /tmp/auto-fixture'",
        "eval 'shutdown now'",
        "true; then /bin/rm -r -f /tmp/auto-fixture",
    }) |command| {
        for ([_]bool{ false, true }) |grouped| {
            try std.testing.expectEqual(Verdict.deny_exec_copy_only, classify(.{ .mode = .auto }, command, grouped));
            try std.testing.expectEqual(Verdict.deny_exec_copy_only, classifyTerminal(.{ .mode = .auto }, command, grouped));
        }
    }
}

test "review repair shell quote and escape equivalents cannot bypass dangerous command denial" {
    for ([_][]const u8{
        "r\"\"m -rf /tmp/policy-fixture",
        "r\\m -rf /tmp/policy-fixture",
        "r\\\nm -rf /tmp/policy-fixture",
        "rm -'r'f /tmp/policy-fixture",
        "rm -rf ~/policy-fixture",
        "shut\"\"down now",
        "sudo -u root r\\m -rf /tmp/policy-fixture",
        "sh -c 'r\"\"m -rf /tmp/policy-fixture'",
        "sh -c \"shut\\\"\\\"down now\"",
        "bash --rcfile /tmp/policy-rc -o errexit -c 'r\"\"m -rf /tmp/policy-fixture'",
        "2>/dev/null r\"\"m -rf /tmp/policy-fixture",
        "eval 'r'\"m -rf /tmp/policy-fixture\"",
        "printf '%s' \"$(r\\m -rf /tmp/policy-fixture)\"",
    }) |command| {
        try std.testing.expectEqual(Verdict.deny_exec_copy_only, classify(.{ .mode = .auto }, command, false));
        try std.testing.expectEqual(Verdict.deny_exec_copy_only, classifyTerminal(.{}, command, true));
    }
}

test "review repair uncertain executable expansions require exact approval without blocking literal data" {
    for ([_][]const u8{ "$COMMAND /tmp/policy-fixture", "r${EMPTY}m -rf /tmp/policy-fixture", "sh -c \"$SCRIPT\"", "rm -rf \"$HOME/policy-fixture\"", "sudo --host remote rm -rf /tmp/policy-fixture", "sudo -p prompt rm -rf /tmp/policy-fixture", "printf 'unterminated" }) |command| {
        try std.testing.expectEqual(Verdict.need_confirm, classify(.{ .mode = .auto }, command, false));
        try std.testing.expectEqual(Verdict.need_confirm, classifyTerminal(.{ .mode = .auto }, command, false));
    }
    for ([_][]const u8{ "printf '%s' 'rm -rf /tmp/policy-fixture'", "printf '%s' 'shutdown now; mkfs.ext4 /dev/test'", "echo \"$HOME\"", "printf '%s' $(printf a)", "printf safe # shutdown now", "rm -- -rf /tmp/policy-fixture" }) |command| {
        try std.testing.expectEqual(Verdict.allow_auto, classify(.{ .mode = .auto }, command, false));
    }
}
