const std = @import("std");
const config = @import("config.zig");
const pages = @import("settings_pages.zig");

pub const Value = union(enum) { text: []const u8, boolean: bool, unsigned: u32, decimal: f32 };

pub fn writeValue(writer: *std.Io.Writer, value: Value) !void {
    switch (value) {
        .text => |text| {
            try writer.writeByte('"');
            for (text) |byte| switch (byte) {
                '"' => try writer.writeAll("\\\""),
                '\\' => try writer.writeAll("\\\\"),
                '\n' => try writer.writeAll("\\n"),
                '\r' => try writer.writeAll("\\r"),
                '\t' => try writer.writeAll("\\t"),
                else => try writer.writeByte(byte),
            };
            try writer.writeByte('"');
        },
        .boolean => |boolean| try writer.writeAll(if (boolean) "true" else "false"),
        .unsigned => |number| try writer.print("{d}", .{number}),
        .decimal => |number| try writer.print("{d}", .{number}),
    }
}

pub const WriteError = error{ UnknownKey, InvalidType, InvalidValue, OutOfRange, SettingsBusy };

/// Applies one settings-page value to the in-memory config. The UI layer must
/// validate through this boundary before asking the config store to persist it.
pub fn writeConfig(value: *config.Config, section: []const u8, key: []const u8, next: Value) WriteError!void {
    if (next == .text) {
        if (std.mem.eql(u8, section, "ui") and std.mem.eql(u8, key, "font_weight") and !config.validFontWeight(next.text)) return error.InvalidValue;
        if (std.mem.eql(u8, section, "ui") and std.mem.eql(u8, key, "cursor_style") and !config.validCursorStyle(next.text)) return error.InvalidValue;
        if (std.mem.eql(u8, section, "ui") and std.mem.eql(u8, key, "font_family") and std.mem.trim(u8, next.text, " \t\r\n").len == 0) return error.InvalidValue;
        if (std.mem.eql(u8, section, "ssh") and std.mem.eql(u8, key, "term") and next.text.len == 0) return error.InvalidValue;
        if (std.mem.eql(u8, section, "ssh") and std.mem.eql(u8, key, "socks_bind") and !config.validBind(next.text)) return error.InvalidValue;
        if (std.mem.eql(u8, section, "transfer") and std.mem.eql(u8, key, "conflict_policy") and !std.mem.eql(u8, next.text, "ask")) return error.InvalidValue;
        if (std.mem.eql(u8, section, "notify") and std.mem.eql(u8, key, "quiet_hours") and !config.validQuietHours(next.text)) return error.InvalidValue;
        if (std.mem.eql(u8, section, "log") and std.mem.eql(u8, key, "export_format") and !std.mem.eql(u8, next.text, "txt") and !std.mem.eql(u8, next.text, "cast") and !std.mem.eql(u8, next.text, "txt_cast")) return error.InvalidValue;
    }
    if (std.mem.eql(u8, section, "completion") and std.mem.eql(u8, key, "enabled")) return setBool(&value.completion.enabled, next);
    if (std.mem.eql(u8, section, "ui.materials") and std.mem.eql(u8, key, "blur_px")) return setUnsigned(&value.ui.materials.blur_px, next, 0, 96);
    if (std.mem.eql(u8, section, "ui.materials.background")) {
        const background = &value.ui.materials.background;
        if (std.mem.eql(u8, key, "enabled")) return setBool(&background.enabled, next);
        if (std.mem.eql(u8, key, "path")) return setText(&background.path, next);
        if (std.mem.eql(u8, key, "fit")) return setEnum(config.material.Fit, &background.fit, next);
        if (std.mem.eql(u8, key, "alignment_x")) return setEnum(config.material.Horizontal, &background.alignment_x, next);
        if (std.mem.eql(u8, key, "alignment_y")) return setEnum(config.material.Vertical, &background.alignment_y, next);
        if (std.mem.eql(u8, key, "transparency")) return setDecimal(&background.transparency, next, 0, 100);
    }
    if (std.mem.eql(u8, section, "ui")) {
        if (std.mem.eql(u8, key, "theme")) return setText(&value.ui.theme, next);
        if (std.mem.eql(u8, key, "font_weight")) return setText(&value.ui.font_weight, next);
        if (std.mem.eql(u8, key, "cursor_style")) return setText(&value.ui.cursor_style, next);
        if (std.mem.eql(u8, key, "input_line_highlight")) return setBool(&value.ui.input_line_highlight, next);
        if (std.mem.eql(u8, key, "timestamp_gutter")) return setBool(&value.ui.timestamp_gutter, next);
        if (std.mem.eql(u8, key, "sidebar_collapsed")) return setBool(&value.ui.sidebar_collapsed, next);
        if (std.mem.eql(u8, key, "font_size")) return setUnsigned(&value.ui.font_size, next, 8, 48);
        if (std.mem.eql(u8, key, "font_family")) return setText(&value.ui.font_family, next);
        if (std.mem.eql(u8, key, "line_height")) return setDecimal(&value.ui.line_height, next, 1.0, 3.0);
    } else if (std.mem.eql(u8, section, "ssh")) {
        if (std.mem.eql(u8, key, "connect_timeout_sec")) return setUnsigned(&value.ssh.connect_timeout_sec, next, 1, 65535);
        if (std.mem.eql(u8, key, "term")) return setText(&value.ssh.term, next);
        if (std.mem.eql(u8, key, "compression")) return setBool(&value.ssh.compression, next);
        if (std.mem.eql(u8, key, "auto_reconnect")) return setBool(&value.ssh.auto_reconnect, next);
        if (std.mem.eql(u8, key, "buffer_input")) return setBool(&value.ssh.buffer_input, next);
        if (std.mem.eql(u8, key, "socks_port")) return setUnsigned(&value.ssh.socks_port, next, 1, 65535);
        if (std.mem.eql(u8, key, "socks_bind")) return setText(&value.ssh.socks_bind, next);
        if (std.mem.eql(u8, key, "otp_modal")) return setBool(&value.ssh.otp_modal, next);
        if (std.mem.eql(u8, key, "totp_autofill")) return setBool(&value.ssh.totp_autofill, next);

        if (std.mem.eql(u8, key, "reconnect_max")) return setUnsigned(&value.ssh.reconnect_max, next, 0, value.ssh.reconnect_backoff.len);
        if (std.mem.eql(u8, key, "keepalive_sec")) return setUnsigned(&value.ssh.keepalive_sec, next, 1, std.math.maxInt(u16));
        if (std.mem.eql(u8, key, "reconnect_backoff")) return setBackoff(&value.ssh.reconnect_backoff, next);
    } else if (std.mem.eql(u8, section, "transfer")) {
        if (std.mem.eql(u8, key, "resume")) return setBool(&value.transfer.@"resume", next);
        if (std.mem.eql(u8, key, "max_tasks")) return setUnsigned(&value.transfer.max_tasks, next, 1, 255);
        if (std.mem.eql(u8, key, "conflict_policy")) return setText(&value.transfer.conflict_policy, next);

        if (std.mem.eql(u8, key, "shared_pacing_kbps")) return setUnsigned(&value.transfer.shared_pacing_kbps, next, 0, std.math.maxInt(u32));
        if (std.mem.eql(u8, key, "window_chunks")) return setUnsigned(&value.transfer.window_chunks, next, 1, std.math.maxInt(u8));
        if (std.mem.eql(u8, key, "chunk_kb")) return setUnsigned(&value.transfer.chunk_kb, next, 1, std.math.maxInt(u16));
        if (std.mem.eql(u8, key, "download_dir")) return setText(&value.transfer.download_dir, next);
        if (std.mem.eql(u8, key, "verify_md5")) return setBool(&value.transfer.verify_md5, next);
        if (std.mem.eql(u8, key, "dedicated_connection")) return setBool(&value.transfer.dedicated_connection, next);
    } else if (std.mem.eql(u8, section, "ai")) {
        if (std.mem.eql(u8, key, "default_provider")) return setText(&value.ai.default_provider, next);
        if (std.mem.eql(u8, key, "permission_mode")) {
            const text = switch (next) {
                .text => |v| v,
                else => return error.InvalidType,
            };
            value.ai.permission_mode = std.meta.stringToEnum(config.PermissionMode, text) orelse return error.InvalidValue;
            return;
        }
        if (std.mem.eql(u8, key, "error_hint")) return setBool(&value.ai.error_hint, next);
        if (std.mem.eql(u8, key, "redact_ip")) return setBool(&value.ai.redact_ip, next);
    } else if (std.mem.eql(u8, section, "log")) {
        if (std.mem.eql(u8, key, "retention_days")) return setUnsigned(&value.log.retention_days, next, 1, 65535);
        if (std.mem.eql(u8, key, "export_format")) return setText(&value.log.export_format, next);

        if (std.mem.eql(u8, key, "checkpoint_sec")) return setUnsigned(&value.log.checkpoint_sec, next, 1, std.math.maxInt(u16));
        if (std.mem.eql(u8, key, "ring_mb")) return setUnsigned(&value.log.ring_mb, next, 1, std.math.maxInt(u16));
    }
    if (std.mem.eql(u8, section, "notify")) {
        if (std.mem.eql(u8, key, "transfer_done")) return setBool(&value.notify.transfer_done, next);
        if (std.mem.eql(u8, key, "reconnect")) return setBool(&value.notify.reconnect, next);
        if (std.mem.eql(u8, key, "ai_ready")) return setBool(&value.notify.ai_ready, next);
        if (std.mem.eql(u8, key, "bell")) return setBool(&value.notify.bell, next);
        if (std.mem.eql(u8, key, "tab_dot")) return setBool(&value.notify.tab_dot, next);
        if (std.mem.eql(u8, key, "quiet_hours")) return setText(&value.notify.quiet_hours, next);
    }
    return error.UnknownKey;
}

fn setText(target: *[]const u8, next: Value) WriteError!void {
    target.* = switch (next) {
        .text => |v| v,
        else => return error.InvalidType,
    };
}
fn setBool(target: *bool, next: Value) WriteError!void {
    target.* = switch (next) {
        .boolean => |v| v,
        else => return error.InvalidType,
    };
}
fn setUnsigned(target: anytype, next: Value, min: u64, max: u64) WriteError!void {
    const number = switch (next) {
        .unsigned => |v| v,
        else => return error.InvalidType,
    };
    if (number < min or number > max) return error.OutOfRange;
    target.* = @intCast(number);
}
fn setDecimal(target: *f32, next: Value, min: f32, max: f32) WriteError!void {
    const number = switch (next) {
        .decimal => |v| v,
        else => return error.InvalidType,
    };
    if (!std.math.isFinite(number) or number < min or number > max) return error.OutOfRange;
    target.* = number;
}
fn setBackoff(target: *[5]u8, next: Value) WriteError!void {
    const text = switch (next) {
        .text => |v| v,
        else => return error.InvalidType,
    };
    const trimmed = std.mem.trim(u8, text, " \t");
    const body = if (trimmed.len >= 2 and trimmed[0] == '[' and trimmed[trimmed.len - 1] == ']') trimmed[1 .. trimmed.len - 1] else trimmed;
    var parsed: [5]u8 = undefined;
    var index: usize = 0;
    var parts = std.mem.splitScalar(u8, body, ',');
    while (parts.next()) |part| {
        if (index == parsed.len) return error.InvalidValue;
        parsed[index] = std.fmt.parseInt(u8, std.mem.trim(u8, part, " \t"), 10) catch return error.InvalidValue;
        index += 1;
    }
    if (index != parsed.len) return error.InvalidValue;
    target.* = parsed;
}

pub fn read(value: config.Config, section: []const u8, key: []const u8) ?Value {
    if (std.mem.eql(u8, section, "ui.materials") and std.mem.eql(u8, key, "blur_px")) return .{ .unsigned = value.ui.materials.blur_px };
    if (std.mem.eql(u8, section, "ui.materials.background")) {
        const background = value.ui.materials.background;
        if (std.mem.eql(u8, key, "enabled")) return .{ .boolean = background.enabled };
        if (std.mem.eql(u8, key, "path")) return .{ .text = background.path };
        if (std.mem.eql(u8, key, "fit")) return .{ .text = @tagName(background.fit) };
        if (std.mem.eql(u8, key, "alignment_x")) return .{ .text = @tagName(background.alignment_x) };
        if (std.mem.eql(u8, key, "alignment_y")) return .{ .text = @tagName(background.alignment_y) };
        if (std.mem.eql(u8, key, "transparency")) return .{ .decimal = background.transparency };
    }
    if (std.mem.eql(u8, section, "completion") and std.mem.eql(u8, key, "enabled")) return .{ .boolean = value.completion.enabled };
    if (std.mem.eql(u8, section, "ui")) {
        if (std.mem.eql(u8, key, "theme")) return .{ .text = value.ui.theme };
        if (std.mem.eql(u8, key, "font_weight")) return .{ .text = value.ui.font_weight };
        if (std.mem.eql(u8, key, "cursor_style")) return .{ .text = value.ui.cursor_style };
        if (std.mem.eql(u8, key, "input_line_highlight")) return .{ .boolean = value.ui.input_line_highlight };
        if (std.mem.eql(u8, key, "timestamp_gutter")) return .{ .boolean = value.ui.timestamp_gutter };
        if (std.mem.eql(u8, key, "sidebar_collapsed")) return .{ .boolean = value.ui.sidebar_collapsed };
        if (std.mem.eql(u8, key, "font_size")) return .{ .unsigned = value.ui.font_size };
        if (std.mem.eql(u8, key, "font_family")) return .{ .text = value.ui.font_family };
        if (std.mem.eql(u8, key, "line_height")) return .{ .decimal = value.ui.line_height };
    } else if (std.mem.eql(u8, section, "ssh")) {
        if (std.mem.eql(u8, key, "connect_timeout_sec")) return .{ .unsigned = value.ssh.connect_timeout_sec };
        if (std.mem.eql(u8, key, "term")) return .{ .text = value.ssh.term };
        if (std.mem.eql(u8, key, "compression")) return .{ .boolean = value.ssh.compression };
        if (std.mem.eql(u8, key, "auto_reconnect")) return .{ .boolean = value.ssh.auto_reconnect };
        if (std.mem.eql(u8, key, "buffer_input")) return .{ .boolean = value.ssh.buffer_input };
        if (std.mem.eql(u8, key, "socks_port")) return .{ .unsigned = value.ssh.socks_port };
        if (std.mem.eql(u8, key, "socks_bind")) return .{ .text = value.ssh.socks_bind };
        if (std.mem.eql(u8, key, "otp_modal")) return .{ .boolean = value.ssh.otp_modal };
        if (std.mem.eql(u8, key, "totp_autofill")) return .{ .boolean = value.ssh.totp_autofill };

        if (std.mem.eql(u8, key, "reconnect_max")) return .{ .unsigned = value.ssh.reconnect_max };
        if (std.mem.eql(u8, key, "keepalive_sec")) return .{ .unsigned = value.ssh.keepalive_sec };
        if (std.mem.eql(u8, key, "reconnect_backoff")) return .{ .text = "[1,2,4,8,16]" };
    } else if (std.mem.eql(u8, section, "transfer")) {
        if (std.mem.eql(u8, key, "resume")) return .{ .boolean = value.transfer.@"resume" };
        if (std.mem.eql(u8, key, "max_tasks")) return .{ .unsigned = value.transfer.max_tasks };
        if (std.mem.eql(u8, key, "conflict_policy")) return .{ .text = value.transfer.conflict_policy };

        if (std.mem.eql(u8, key, "shared_pacing_kbps")) return .{ .unsigned = value.transfer.shared_pacing_kbps };
        if (std.mem.eql(u8, key, "window_chunks")) return .{ .unsigned = value.transfer.window_chunks };
        if (std.mem.eql(u8, key, "chunk_kb")) return .{ .unsigned = value.transfer.chunk_kb };
        if (std.mem.eql(u8, key, "download_dir")) return .{ .text = value.transfer.download_dir };
        if (std.mem.eql(u8, key, "verify_md5")) return .{ .boolean = value.transfer.verify_md5 };
        if (std.mem.eql(u8, key, "dedicated_connection")) return .{ .boolean = value.transfer.dedicated_connection };
    } else if (std.mem.eql(u8, section, "ai")) {
        if (std.mem.eql(u8, key, "default_provider")) return .{ .text = value.ai.default_provider };
        if (std.mem.eql(u8, key, "permission_mode")) return .{ .text = @tagName(value.ai.permission_mode) };
        if (std.mem.eql(u8, key, "error_hint")) return .{ .boolean = value.ai.error_hint };
        if (std.mem.eql(u8, key, "redact_ip")) return .{ .boolean = value.ai.redact_ip };
    } else if (std.mem.eql(u8, section, "log")) {
        if (std.mem.eql(u8, key, "retention_days")) return .{ .unsigned = value.log.retention_days };
        if (std.mem.eql(u8, key, "export_format")) return .{ .text = value.log.export_format };

        if (std.mem.eql(u8, key, "checkpoint_sec")) return .{ .unsigned = value.log.checkpoint_sec };
        if (std.mem.eql(u8, key, "ring_mb")) return .{ .unsigned = value.log.ring_mb };
    }
    if (std.mem.eql(u8, section, "notify")) {
        if (std.mem.eql(u8, key, "transfer_done")) return .{ .boolean = value.notify.transfer_done };
        if (std.mem.eql(u8, key, "reconnect")) return .{ .boolean = value.notify.reconnect };
        if (std.mem.eql(u8, key, "ai_ready")) return .{ .boolean = value.notify.ai_ready };
        if (std.mem.eql(u8, key, "bell")) return .{ .boolean = value.notify.bell };
        if (std.mem.eql(u8, key, "tab_dot")) return .{ .boolean = value.notify.tab_dot };
        if (std.mem.eql(u8, key, "quiet_hours")) return .{ .text = value.notify.quiet_hours };
    }
    return null;
}

fn setEnum(comptime T: type, target: *T, value: Value) WriteError!void {
    if (value != .text) return error.InvalidType;
    target.* = std.meta.stringToEnum(T, value.text) orelse return error.InvalidValue;
}

test "settings writer validates type and range before mutation" {
    var value: config.Config = .{};
    try writeConfig(&value, "ui", "font_size", .{ .unsigned = 18 });
    try std.testing.expectEqual(@as(u8, 18), value.ui.font_size);
    try std.testing.expectError(error.OutOfRange, writeConfig(&value, "ui", "font_size", .{ .unsigned = 2 }));
    try std.testing.expectEqual(@as(u8, 18), value.ui.font_size);
    try std.testing.expectError(error.InvalidType, writeConfig(&value, "ui", "font_size", .{ .boolean = true }));
    try std.testing.expectError(error.InvalidValue, writeConfig(&value, "ai", "permission_mode", .{ .text = "unsafe" }));
    try std.testing.expectError(error.UnknownKey, writeConfig(&value, "ui", "not_a_setting", .{ .boolean = true }));
    try writeConfig(&value, "ai", "permission_mode", .{ .text = "auto" });
    try std.testing.expectEqual(config.PermissionMode.auto, value.ai.permission_mode);
    try writeConfig(&value, "ssh", "reconnect_backoff", .{ .text = "[2,3,5,8,13]" });
    try std.testing.expectEqual(@as(u8, 13), value.ssh.reconnect_backoff[4]);
    try std.testing.expectError(error.InvalidValue, writeConfig(&value, "ssh", "reconnect_backoff", .{ .text = "[1,2]" }));
}

test "settings value reader exposes mapped config values" {
    const value = config.Config{};
    try std.testing.expectEqualStrings("dark", read(value, "ui", "theme").?.text);
    try std.testing.expect(read(value, "ai", "error_hint").?.boolean);
    try std.testing.expectEqual(@as(u32, 30), read(value, "log", "checkpoint_sec").?.unsigned);
    try std.testing.expect(read(value, "ai", "missing") == null);
    _ = pages.pages;
    var buffer: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try writeValue(&writer, read(value, "ui", "font_size").?);
    try std.testing.expectEqualStrings("14", writer.buffered());
    var escaped: [64]u8 = undefined;
    var escaped_writer = std.Io.Writer.fixed(&escaped);
    try writeValue(&escaped_writer, .{ .text = "a\"b" });
    try std.testing.expectEqualStrings("\"a\\\"b\"", escaped_writer.buffered());
}

test "new settings validate before mutation and completion writes" {
    var value: config.Config = .{};
    try writeConfig(&value, "completion", "enabled", .{ .boolean = false });
    try writeConfig(&value, "ssh", "term", .{ .text = "vt100" });
    try writeConfig(&value, "notify", "quiet_hours", .{ .text = "21:30-06:15" });
    try writeConfig(&value, "transfer", "max_tasks", .{ .unsigned = 8 });
    try std.testing.expect(!read(value, "completion", "enabled").?.boolean);
    try std.testing.expectEqualStrings("vt100", read(value, "ssh", "term").?.text);
    try std.testing.expectEqual(@as(u32, 8), read(value, "transfer", "max_tasks").?.unsigned);
    try std.testing.expectError(error.InvalidValue, writeConfig(&value, "notify", "quiet_hours", .{ .text = "26:00-07:00" }));
    try std.testing.expectEqualStrings("21:30-06:15", value.notify.quiet_hours);
    try std.testing.expectError(error.InvalidValue, writeConfig(&value, "ssh", "socks_bind", .{ .text = "remote" }));
    try std.testing.expectEqualStrings("127.0.0.1", value.ssh.socks_bind);
    try std.testing.expectError(error.OutOfRange, writeConfig(&value, "transfer", "max_tasks", .{ .unsigned = 0 }));
    try std.testing.expectEqual(@as(u8, 8), value.transfer.max_tasks);
}

test "settings reconnect backoff accepts prototype comma list and legacy brackets" {
    var value = config.Config{};
    try writeConfig(&value, "ssh", "reconnect_backoff", .{ .text = "1, 2, 4, 8, 16" });
    try std.testing.expectEqual([5]u8{ 1, 2, 4, 8, 16 }, value.ssh.reconnect_backoff);
    try writeConfig(&value, "ssh", "reconnect_backoff", .{ .text = "[2,3,5,8,13]" });
    try std.testing.expectEqual([5]u8{ 2, 3, 5, 8, 13 }, value.ssh.reconnect_backoff);
    try std.testing.expectError(error.InvalidValue, writeConfig(&value, "ssh", "reconnect_backoff", .{ .text = "1,2,3,4,256" }));
    try std.testing.expectError(error.InvalidValue, writeConfig(&value, "ssh", "reconnect_backoff", .{ .text = "1,2" }));
}
