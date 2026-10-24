const std = @import("std");
const command_catalog = @import("command_catalog.zig");

pub const Entry = command_catalog.Entry;
pub const catalog = command_catalog.entries;
pub const find = command_catalog.find;

pub const Download = struct {
    remote_path: []const u8,
    local_directory: ?[]const u8 = null,
};

pub const Socks = struct {
    enabled: bool,
    port: ?u16 = null,
};

pub const Invalid = struct {
    name: []const u8,
    reason: Reason,
    pub const Reason = enum { missing_parameter, unexpected_parameter, invalid_switch, invalid_port, invalid_path };
};

pub const Command = union(enum) {
    help: void,
    upload: ?[]const u8,
    download: Download,
    ai: []const u8,
    group: []const u8,
    /// @new uses the active host; no host argument is accepted.
    new_session: []const u8,
    duplicate: void,
    pin: void,
    sync: bool,
    timestamp: bool,
    /// @log always enters read-only replay; no export path is accepted.
    log: ?[]const u8,
    socks: Socks,
    theme: ?[]const u8,
    literal: []const u8,
    invalid: Invalid,
    not_command: []const u8,
};

/// Parsing is client-local. Argument slices borrow the input for the callback.
pub fn parse(line: []const u8) Command {
    if (line.len == 0 or line[0] != '@') return .{ .not_command = line };
    if (std.mem.startsWith(u8, line, "@@")) return .{ .literal = line[1..] };
    const end = std.mem.indexOfAny(u8, line, " \t\r\n") orelse line.len;
    const name = line[0..end];
    const entry = find(name) orelse return .{ .not_command = line };
    const args = std.mem.trim(u8, line[end..], " \t\r\n");
    if (std.mem.indexOfAny(u8, args, "\r\n") != null) return invalid(name, .invalid_path);
    if (entry.requires_arguments and args.len == 0) return invalid(name, .missing_parameter);
    if (eq(name, "@up")) return .{ .upload = if (args.len == 0) null else unquote(args) orelse return invalid(name, .invalid_path) };
    if (eq(name, "@dl")) {
        const remote = takePath(args) orelse return invalid(name, .invalid_path);
        const rest = std.mem.trim(u8, args[remote.consumed..], " \t");
        if (rest.len != 0) return invalid(name, .unexpected_parameter);
        return .{ .download = .{ .remote_path = remote.value } };
    }
    if (eq(name, "@ai")) return .{ .ai = args };
    if (eq(name, "@grp")) return .{ .group = args };
    if (eq(name, "@theme")) return .{ .theme = if (args.len == 0) null else unquote(args) orelse return invalid(name, .invalid_path) };
    if (eq(name, "@sync") or eq(name, "@ts")) {
        const enabled = parseSwitch(args) orelse return invalid(name, .invalid_switch);
        return if (eq(name, "@sync")) .{ .sync = enabled } else .{ .timestamp = enabled };
    }
    if (eq(name, "@socks")) {
        const split = std.mem.indexOfAny(u8, args, " \t") orelse args.len;
        const enabled = parseSwitch(args[0..split]) orelse return invalid(name, .invalid_switch);
        const port_text = std.mem.trim(u8, args[split..], " \t");
        const port: ?u16 = if (port_text.len == 0) null else std.fmt.parseInt(u16, port_text, 10) catch return invalid(name, .invalid_port);
        if (port != null and (port.? == 0 or !enabled)) return invalid(name, .invalid_port);
        return .{ .socks = .{ .enabled = enabled, .port = port } };
    }
    if (args.len != 0) return invalid(name, .unexpected_parameter);
    if (eq(name, "@help")) return .help;
    if (eq(name, "@new")) return .{ .new_session = "" };
    if (eq(name, "@dup")) return .duplicate;
    if (eq(name, "@pin")) return .pin;
    if (eq(name, "@log")) return .{ .log = null };
    return .{ .not_command = line };
}

fn eq(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

fn invalid(name: []const u8, reason: Invalid.Reason) Command {
    return .{ .invalid = .{ .name = name, .reason = reason } };
}

fn parseSwitch(text: []const u8) ?bool {
    if (eq(text, "on")) return true;
    if (eq(text, "off")) return false;
    return null;
}

fn unquote(text: []const u8) ?[]const u8 {
    if (text.len == 0) return null;
    if (text[0] != '"' and text[0] != '\'') return text;
    if (text.len < 2 or text[text.len - 1] != text[0]) return null;
    const result = text[1 .. text.len - 1];
    return if (result.len == 0) null else result;
}

fn takePath(text: []const u8) ?struct { value: []const u8, consumed: usize } {
    if (text.len == 0) return null;
    if (text[0] == '"' or text[0] == '\'') {
        const end = std.mem.indexOfScalarPos(u8, text, 1, text[0]) orelse return null;
        if (end == 1 or (end + 1 < text.len and text[end + 1] != ' ' and text[end + 1] != '\t')) return null;
        return .{ .value = text[1..end], .consumed = end + 1 };
    }
    const end = std.mem.indexOfAny(u8, text, " \t") orelse text.len;
    return .{ .value = text[0..end], .consumed = end };
}

test "parser exposes all local operations and literal escape" {
    try std.testing.expectEqual(Command.help, parse("@help"));
    try std.testing.expectEqualStrings("prod", parse("@grp prod").group);
    try std.testing.expectEqualStrings("", parse("@new").new_session);
    try std.testing.expectEqual(Command.duplicate, parse("@dup"));
    try std.testing.expectEqual(Command.pin, parse("@pin"));
    try std.testing.expect(parse("@sync on").sync);
    try std.testing.expect(!parse("@ts off").timestamp);
    try std.testing.expectEqualStrings("why did this fail", parse("@ai why did this fail").ai);
    try std.testing.expect(parse("@up").upload == null);
    try std.testing.expectEqualStrings("/tmp/My File.txt", parse("@up \"/tmp/My File.txt\"").upload.?);
    try std.testing.expectEqualStrings("dark-pro", parse("@theme dark-pro").theme.?);
    try std.testing.expect(parse("@theme").theme == null);
    try std.testing.expect(parse("@log").log == null);
    try std.testing.expectEqualStrings("@up", parse("@@up").literal);
}

test "download paths and socks port preserve the intended target" {
    const download = parse("@dl \"/var/log/my app.log\"").download;
    try std.testing.expectEqualStrings("/var/log/my app.log", download.remote_path);
    try std.testing.expect(download.local_directory == null);
    try std.testing.expectEqual(Invalid.Reason.unexpected_parameter, parse("@dl /var/log/app.log /tmp").invalid.reason);
    try std.testing.expectEqual(Invalid.Reason.unexpected_parameter, parse("@dl \"/var/log/my app.log\" \"/tmp/Saved Files\"").invalid.reason);
    try std.testing.expectEqualStrings("/var/log/app.log", parse("@dl /var/log/app.log").download.remote_path);
    try std.testing.expectEqual(Socks{ .enabled = true, .port = 1080 }, parse("@socks on 1080").socks);
    try std.testing.expectEqual(Socks{ .enabled = false }, parse("@socks off").socks);
}

test "old invented aliases and invalid parameters do not become actions" {
    try std.testing.expectEqualStrings("@history", parse("@history").not_command);
    try std.testing.expectEqualStrings(" @up", parse(" @up").not_command);
    try std.testing.expectEqualStrings("echo @up", parse("echo @up").not_command);
    try std.testing.expectEqual(Invalid.Reason.unexpected_parameter, parse("@log export.cast").invalid.reason);
    try std.testing.expectEqual(Invalid.Reason.unexpected_parameter, parse("@new db").invalid.reason);
    try std.testing.expectEqual(Invalid.Reason.missing_parameter, parse("@grp").invalid.reason);
    try std.testing.expectEqual(Invalid.Reason.missing_parameter, parse("@dl").invalid.reason);
    try std.testing.expectEqual(Invalid.Reason.invalid_switch, parse("@sync yes").invalid.reason);
    try std.testing.expectEqual(Invalid.Reason.invalid_port, parse("@socks on 0").invalid.reason);
    try std.testing.expectEqual(Invalid.Reason.invalid_port, parse("@socks off 1080").invalid.reason);
}

test {
    _ = @import("command_palette.zig");
}
