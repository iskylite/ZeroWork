const std = @import("std");
const ui = @import("ui");
const binding = @import("../settings_content_view.zig");
const config = @import("../config.zig");
const controls = @import("settings_controls.zig");

const terms = [_]ui.widgets.SelectOption{
    .{ .value = "xterm-256color", .label = "xterm-256color" },
    .{ .value = "xterm", .label = "xterm" },
    .{ .value = "vt100", .label = "vt100" },
    .{ .value = "__custom", .label = "自定义…" },
};
const binds = [_]ui.widgets.SelectOption{
    .{ .value = "127.0.0.1", .label = "127.0.0.1" },
    .{ .value = "0.0.0.0", .label = "0.0.0.0" },
};

pub fn mountContent(cx: *ui.Cx, bound: *binding.Binding) !*ui.Node {
    const page = try controls.Page.create(cx, bound, "settings.ssh");
    const query = bound.controller.search_query;
    if (binding.matches(query, "连接 保活 KeepAlive 超时 终端 TERM 压缩 keepalive_sec connect_timeout_sec term compression")) {
        const section = try page.section("连接", "连接保活、超时与终端类型", ui.icons.network, 8, "settings.ssh.connection", null);
        try section.input(.{ .section = "ssh", .key = "keepalive_sec" }, "KeepAlive 间隔（秒）", "用于新连接和重连。", null);
        try section.input(.{ .section = "ssh", .key = "connect_timeout_sec" }, "连接超时（秒）", "", null);
        var term_options: [terms.len + 1]ui.widgets.SelectOption = undefined;
        @memcpy(term_options[0..terms.len], &terms);
        const current_term = bound.controller.model.value.ssh.term;
        var known_term = false;
        for (terms[0..3]) |option| if (std.mem.eql(u8, current_term, option.value)) {
            known_term = true;
            break;
        };
        if (!known_term) {
            const text = try controls.owned(bound.scope, current_term);
            term_options[terms.len] = .{ .value = text, .label = text };
        }
        try section.select(.{ .section = "ssh", .key = "term" }, "默认终端类型", "", term_options[0 .. terms.len + @intFromBool(!known_term)], null);
        try section.toggle(.{ .section = "ssh", .key = "compression" }, "SSH 压缩", "", null);
    }
    if (binding.matches(query, "断线 自动重连 最大次数 退避 输入缓存 auto_reconnect reconnect_max reconnect_backoff buffer_input")) {
        const section = try page.section("断线重连", "自动重连与输入缓存", ui.icons.rotate_ccw, 9, "settings.ssh.reconnect", null);
        try section.toggle(.{ .section = "ssh", .key = "auto_reconnect" }, "自动重连", "", null);
        try section.input(.{ .section = "ssh", .key = "reconnect_max" }, "最大重连次数（次）", "0 表示不重试。", reconnectEnabled);
        try section.input(.{ .section = "ssh", .key = "reconnect_backoff" }, "重连间隔（秒）", "5 个间隔，以逗号分隔；每项 0–255 秒。", retriesEnabled);
        try section.toggle(.{ .section = "ssh", .key = "buffer_input" }, "重连期间缓存输入", "恢复后回放缓存输入，关闭可避免意外执行。", retriesEnabled);
    }
    if (binding.matches(query, "SOCKS5 默认值 本地端口 绑定地址 socks_port socks_bind")) {
        const section = try page.section("SOCKS5 默认值", "用于下次开启的转发", ui.icons.network, 10, "settings.ssh.socks", null);
        try section.input(.{ .section = "ssh", .key = "socks_port" }, "默认本地端口", "", null);
        try section.select(.{ .section = "ssh", .key = "socks_bind" }, "默认绑定地址", "0.0.0.0 允许局域网内其他设备访问。", &binds, null);
    }
    if (binding.matches(query, "双因素 认证 验证码 OTP TOTP 自动填充 otp_modal totp_autofill")) {
        const section = try page.section("双因素认证", "验证码输入与自动填充", ui.icons.shield, 11, "settings.ssh.authentication", null);
        try section.toggle(.{ .section = "ssh", .key = "otp_modal" }, "专用验证码表单", "为六位验证码显示专用输入框。", null);
        try section.toggle(.{ .section = "ssh", .key = "totp_autofill" }, "TOTP 自动填充", "填入已配置主机的验证码，提交前仍需确认。", null);
    }
    return page.finish();
}

fn reconnectEnabled(value: config.Config) bool {
    return value.ssh.auto_reconnect;
}
fn retriesEnabled(value: config.Config) bool {
    return value.ssh.auto_reconnect and value.ssh.reconnect_max > 0;
}
fn connectionSummary(value: config.Config, buffer: []u8) ![]const u8 {
    return std.fmt.bufPrint(buffer, "保活 {d} 秒 · 超时 {d} 秒", .{ value.ssh.keepalive_sec, value.ssh.connect_timeout_sec });
}
fn reconnectSummary(value: config.Config, buffer: []u8) ![]const u8 {
    if (!value.ssh.auto_reconnect) return "已关闭";
    return std.fmt.bufPrint(buffer, "最多 {d} 次", .{value.ssh.reconnect_max});
}
fn socksSummary(value: config.Config, buffer: []u8) ![]const u8 {
    return std.fmt.bufPrint(buffer, "{s}:{d}", .{ value.ssh.socks_bind, value.ssh.socks_port });
}
fn authenticationSummary(value: config.Config, buffer: []u8) ![]const u8 {
    _ = value;
    _ = buffer;
    return "OTP / TOTP";
}
