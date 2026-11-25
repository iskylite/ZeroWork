const std = @import("std");
const feedback = @import("../ui/feedback_message.zig");

extern fn zw_data_startup_alert([*:0]const u8, [*]const u8, usize, c_int, [*]const u8, usize) c_int;
extern fn zw_data_notify_startup_failure([*]const u8, usize) void;

pub const StartupAlert = struct {
    complete: bool = false,
    reported: bool = false,

    pub fn dataFailure(self: *StartupAlert, err: anyerror, reset_pending: bool) bool {
        self.reported = true;
        std.log.err("opening application data: {s}", .{@errorName(err)});
        var buffer: [512]u8 = undefined;
        const message = feedback.knownMessage(@errorName(err)) orelse
            std.fmt.bufPrint(&buffer, "启动时发生错误（{s}）。请检查应用数据目录的权限，再重新打开 ZeroWork。原有数据会保留。", .{@errorName(err)}) catch
            "无法打开应用数据。原有数据会保留。";
        return show(@errorName(err), message, reset_pending);
    }

    pub fn configFailure(self: *StartupAlert, io: std.Io, err: anyerror, line: ?usize) void {
        self.reported = true;
        std.log.err("reading config.toml (line {?d}): {s}", .{ line, @errorName(err) });
        var location: [64]u8 = undefined;
        var buffer: [512]u8 = undefined;
        const source = if (line) |number|
            std.fmt.bufPrint(&location, "config.toml 第 {d} 行", .{number}) catch "config.toml"
        else
            "config.toml";
        const reason = switch (err) {
            error.UnknownKey => "包含不认识的配置项",
            error.InvalidSection => "包含无效的配置分区",
            error.InvalidAssignment, error.MissingSection => "配置格式有误",
            error.InvalidValue, error.OutOfRange, error.Overflow, error.InvalidExecutionMode, error.InvalidSessionRetention => "包含无效或超出范围的值",
            error.InvalidCredentialReference, error.AmbiguousCredential => "凭据配置有误",
            error.AccessDenied, error.PermissionDenied => "无法读取，应用没有访问权限",
            else => "读取或校验失败",
        };
        var reason_buffer: [256]u8 = undefined;
        const summary = std.fmt.bufPrint(&reason_buffer, "{s}\n{s}（{s}）", .{ source, reason, @errorName(err) }) catch "无法读取 config.toml。";
        const guidance = "修正配置后，请重新打开 ZeroWork。";
        @import("../ui/startup_failure_view.zig").show(io, summary, guidance, notifySystem) catch |view_err| {
            std.log.warn("showing configuration startup failure: {s}", .{@errorName(view_err)});
            const message = std.fmt.bufPrint(&buffer, "{s}\n\n{s}", .{ summary, guidance }) catch summary;
            _ = show("StartupConfigFailure", message, false);
        };
    }

    pub fn reportUnhandled(self: *StartupAlert, err: anyerror) void {
        if (self.complete or self.reported) return;
        self.reported = true;
        std.log.err("starting ZeroWork: {s}", .{@errorName(err)});
        var buffer: [512]u8 = undefined;
        const message = feedback.knownMessage(@errorName(err)) orelse
            std.fmt.bufPrint(&buffer, "ZeroWork 初始化时发生错误（{s}）。", .{@errorName(err)}) catch "ZeroWork 初始化失败。";
        _ = show("StartupFailure", message, false);
    }
};

fn notifySystem(summary: []const u8) void {
    zw_data_notify_startup_failure(summary.ptr, summary.len);
}

fn show(code: [:0]const u8, message: []const u8, reset_pending: bool) bool {
    const icon = @import("app_icon_assets").transparent;
    return zw_data_startup_alert(code, message.ptr, message.len, @intFromBool(reset_pending), icon.ptr, icon.len) != 0;
}
