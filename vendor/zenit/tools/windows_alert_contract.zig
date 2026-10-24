//! Exercise public alerts on an inactive desktop, preserving the input desktop.
const std = @import("std");
const App = @import("zenit_app").App;
const Window = @FieldType(App, "win");
extern fn zenit_win_alert_contract_desktop() ?*anyopaque;
extern fn zenit_win_alert_contract_leave_desktop() c_int;
extern fn zenit_win_alert_contract_close_desktop(*anyopaque) c_int;
extern fn zenit_win_alert_contract_begin(?*anyopaque, [*:0]const u8, [*:0]const u8) c_int;
extern fn zenit_win_alert_contract_end() c_int;
extern fn zenit_win_blocking_alert(?*anyopaque, [*:0]const u8, [*:0]const u8) c_int;
extern "user32" fn GetDesktopWindow() callconv(.winapi) ?*anyopaque;
extern "user32" fn GetForegroundWindow() callconv(.winapi) ?*anyopaque;

const title: [:0]const u8 = "Zenit 提示 🧪";
const message: [:0]const u8 = "第一行\r\nSecond line 🧪 & literal";

fn dialog(owner: ?*Window, expected_owner: ?*anyopaque, checked: bool) !void {
    const count = Window.liveWindowCount();
    if (zenit_win_alert_contract_begin(expected_owner, title, message) != 1) return error.AlertHookFailed;
    var ended = false;
    defer if (!ended) {
        _ = zenit_win_alert_contract_end();
    };
    if (owner) |win| {
        try win.showBlockingAlertOwned(title, message);
    } else if (checked) {
        try Window.showBlockingAlertChecked(title, message);
    } else {
        Window.showBlockingAlert(title, message);
    }
    const ok = zenit_win_alert_contract_end();
    ended = true;
    if (ok != 1 or Window.liveWindowCount() != count) return error.AlertContractFailed;
}

fn ownerless() !void {
    if (Window.liveWindowCount() != 0) return error.AlertFixtureNotIsolated;
    try dialog(null, null, false);
}

fn owned(win: *Window) !void {
    try dialog(win, win.getNativeSurfaceHandle(), true);
    // Static API must find this thread's Zenit window as owner, and survive reuse.
    try dialog(null, win.getNativeSurfaceHandle(), false);
    try dialog(null, win.getNativeSurfaceHandle(), true);
    const invalid: [:0]const u8 = &[_:0]u8{0xff};
    const foreground = GetForegroundWindow();
    const count = Window.liveWindowCount();
    if (Window.showBlockingAlertChecked(invalid, message)) |_| return error.InvalidAlertAccepted else |err| {
        if (err != error.NativeAlertFailed) return err;
    }
    if (Window.showBlockingAlertChecked(title, invalid)) |_| return error.InvalidAlertAccepted else |err| {
        if (err != error.NativeAlertFailed) return err;
    }
    // Reject foreign HWNDs before calling MessageBox; never manipulate them.
    if (zenit_win_blocking_alert(GetDesktopWindow(), title, message) != 0) return error.ForeignAlertOwnerAccepted;
    if (GetForegroundWindow() != foreground or Window.liveWindowCount() != count) return error.AlertContractFailed;
    std.log.info("Windows alerts: Unicode body capture, ownerless/owned/automatic owner, repeat, invalid UTF-8 and foreign owner PASS", .{});
}

const ThreadResult = struct {
    desktop: ?*anyopaque = null,
    failure: ?anyerror = null,
};
fn threadMain(result: *ThreadResult) void {
    result.desktop = zenit_win_alert_contract_desktop() orelse {
        result.failure = error.AlertDesktopFailed;
        return;
    };
    runIsolated() catch |err| {
        result.failure = err;
    };
    if (zenit_win_alert_contract_leave_desktop() != 1) result.failure = error.AlertDesktopRestoreFailed;
}
fn runIsolated() !void {
    try ownerless();
    var win = try Window.init(320, 240, "Zenit alert contract owner");
    defer win.deinit();
    try owned(&win);
}
pub fn run() !void {
    const count = Window.liveWindowCount();
    const foreground = GetForegroundWindow();
    var result: ThreadResult = .{};
    const thread = try std.Thread.spawn(.{}, threadMain, .{&result});
    thread.join();
    const closed = if (result.desktop) |desktop| zenit_win_alert_contract_close_desktop(desktop) == 1 else false;
    std.log.info("Windows alert desktop cleanup: closed={} windows={d}/{d} foreground={any}/{any}", .{ closed, Window.liveWindowCount(), count, GetForegroundWindow(), foreground });
    if (result.failure) |err| return err;
    if (!closed or Window.liveWindowCount() != count or GetForegroundWindow() != foreground) return error.AlertDesktopCleanupFailed;
    std.log.info("Windows alerts: inactive desktop closed, input desktop foreground and owned window count preserved PASS", .{});
}
