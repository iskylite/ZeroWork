//! Native wording for the structured local webpage reader result, including
//! older receipts that classified capability failures as rejected.
const std = @import("std");
pub const Feedback = struct { label: []const u8, detail: []const u8 };
pub fn label(code: []const u8) []const u8 {
    const mappings = .{
        .{ "CapabilityUnavailable", "能力不可用" },
        .{ "ProxyConfigurationUnavailable", "代理配置不可用" },
        .{ "ProxyUnsupported", "能力不可用 · 不支持当前代理协议" },
        .{ "ProxyConnectFailed", "代理连接或隧道建立失败" },
        .{ "ProxyAuthenticationFailed", "代理认证失败" },
        .{ "PermissionDenied", "权限不足" },
        .{ "ApprovalRequired", "待授权" },
        .{ "ScopeChanged", "会话授权已变化" },
        .{ "UrlNotAllowed", "目标地址不允许" },
        .{ "InvalidUrl", "网页地址无效" },
        .{ "DnsFailed", "域名解析失败" },
        .{ "ConnectFailed", "目标连接失败" },
        .{ "TlsFailed", "HTTPS 证书或握手失败" },
        .{ "FetchTimeout", "网页读取超时" },
        .{ "RedirectLimit", "网页重定向次数超限" },
        .{ "ResponseTooLarge", "网页内容超过大小限制" },
        .{ "UnsupportedContentType", "不支持该网页内容格式" },
        .{ "HttpError", "网站返回 HTTP 错误" },
        .{ "CancelledBeforeDispatch", "已取消 · 请求未发送" },
        .{ "Cancelled", "已取消" },
        .{ "NetworkUnavailable", "网络请求失败" },
    };
    inline for (mappings) |entry| if (std.mem.eql(u8, code, entry[0])) return entry[1];
    return "网页读取失败";
}
pub fn project(a: std.mem.Allocator, name: []const u8, body: []const u8) !?Feedback {
    var decoded: [128]u8 = undefined;
    const logical = @import("plugin_tools.zig").decodeName(&decoded, name) catch name;
    if (!std.mem.eql(u8, logical, "host.fetch_url")) return null;
    const parsed = std.json.parseFromSlice(std.json.Value, a, body, .{}) catch |err| {
        if (err == error.OutOfMemory) return err;
        return null;
    };
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const object = parsed.value.object;
    const code = object.get("code") orelse return null;
    if (code != .string) return null;
    const title = label(code.string);
    const stage = object.get("stage");
    const hint = object.get("recovery_hint");
    const detail = try std.fmt.allocPrint(a, "{s}\n错误码：{s}\n阶段：{s}{s}{s}", .{ title, code.string, if (stage != null and stage.? == .string) stage.?.string else "unknown", if (hint != null and hint.? == .string) "\n原因与建议：" else "", if (hint != null and hint.? == .string) hint.?.string else "" });
    return .{ .label = title, .detail = detail };
}
test "fetch_url feedback distinguishes old capability rejection from permission and proxy failures" {
    const a = std.testing.allocator;
    for ([_][]const u8{ "CapabilityUnavailable", "ProxyUnsupported", "ProxyConnectFailed", "ProxyAuthenticationFailed", "PermissionDenied" }) |code| {
        const body = try std.fmt.allocPrint(a, "{{\"code\":\"{s}\",\"stage\":\"connect_tls\",\"recovery_hint\":\"specific reason\"}}", .{code});
        defer a.free(body);
        const feedback = (try project(a, "host.fetch_url", body)).?;
        defer a.free(feedback.detail);
        try std.testing.expect(std.mem.indexOf(u8, feedback.label, "已拒绝") == null);
        try std.testing.expect(std.mem.indexOf(u8, feedback.detail, code) != null);
        try std.testing.expect(std.mem.indexOf(u8, feedback.detail, "specific reason") != null);
    }
}
