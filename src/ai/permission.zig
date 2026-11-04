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
    if (isBlocked(command)) return .deny_exec_copy_only;
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
fn isBlocked(command: []const u8) bool {
    return blockedScript(command, 0);
}
fn blockedScript(command: []const u8, depth: u8) bool {
    if (depth >= 8) return true;
    var segments = std.mem.tokenizeAny(u8, command, ";|&\n\r()`");
    while (segments.next()) |segment| {
        var words = std.mem.tokenizeAny(u8, std.mem.trim(u8, segment, " \t{}"), " \t");
        while (words.next()) |raw_word| {
            const word = std.mem.trim(u8, raw_word, "\"'");
            const name = std.fs.path.basename(word);
            // Control words, environment assignments and common executable
            // wrappers do not conceal the command from the deny rules.
            var prefix = std.mem.indexOfScalar(u8, word, '=') != null;
            for ([_][]const u8{ "if", "then", "elif", "else", "while", "until", "do", "!", "sudo", "doas", "command", "exec", "env", "nohup" }) |keyword| {
                if (std.mem.eql(u8, name, keyword)) prefix = true;
            }
            if (prefix) continue;
            if (word.len > 0 and word[0] == '-') {
                for ([_][]const u8{ "-u", "-g", "--user", "--group" }) |option| {
                    if (std.mem.eql(u8, word, option)) _ = words.next();
                }
                continue;
            }
            if (std.mem.startsWith(u8, name, "mkfs") or std.mem.startsWith(u8, name, "shutdown")) return true;
            if (std.mem.eql(u8, name, "rm")) {
                var recursive = false;
                var force = false;
                var absolute = false;
                while (words.next()) |raw_argument| {
                    const argument = std.mem.trim(u8, raw_argument, "\"'");
                    if (std.mem.eql(u8, argument, "--recursive")) recursive = true else if (std.mem.eql(u8, argument, "--force")) force = true else if (argument.len > 1 and argument[0] == '-' and argument[1] != '-') {
                        recursive = recursive or std.mem.indexOfAny(u8, argument[1..], "rR") != null;
                        force = force or std.mem.indexOfScalar(u8, argument[1..], 'f') != null;
                    } else if (std.fs.path.isAbsolute(argument)) absolute = true;
                }
                if (recursive and force and absolute) return true;
            } else if (std.mem.eql(u8, name, "eval")) {
                if (blockedScript(std.mem.trim(u8, words.rest(), " \t\"'"), depth + 1)) return true;
            } else {
                for ([_][]const u8{ "sh", "bash", "zsh", "dash", "ksh" }) |shell| {
                    if (!std.mem.eql(u8, name, shell)) continue;
                    while (words.next()) |option| {
                        if (option.len < 2 or option[0] != '-') break;
                        if (std.mem.indexOfScalar(u8, option[1..], 'c') != null) {
                            if (blockedScript(std.mem.trim(u8, words.rest(), " \t\"'"), depth + 1)) return true;
                            break;
                        }
                    }
                }
            }
            break;
        }
    }
    return false;
}
/// PTY and batch execution share automatic permission and dangerous-command
/// checks. Confirm mode retains the PTY's exact-command approval.
pub fn classifyTerminal(engine: Engine, command: []const u8, grouped: bool) Verdict {
    const verdict = classify(engine, command, grouped);
    return if (verdict == .deny_exec_copy_only or engine.mode == .auto) verdict else .need_confirm;
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
