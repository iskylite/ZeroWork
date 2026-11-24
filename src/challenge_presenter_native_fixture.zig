//! Isolated native window for the shared host-challenge presenter.
//! Synthetic payload only; no SSH, trust store or credential writes.
const std = @import("std");
const ui = @import("ui");
const App = @import("zenit_app").App;
const Shared = @import("ui/challenge_window_host.zig").Services;
const identity = @import("host/identity.zig");
const theme = @import("ui/app_theme.zig");
var selected_theme: theme.Name = .dark;

const owner: identity.SessionHandle = .{ .session_id = @fromBackingInt(97), .generation = 1 };

const Fixture = struct {
    shared: *Shared = undefined,
    frame: u32 = 0,
    fn step(raw: *anyopaque, _: u8, _: bool) ui.AfterLayoutResult {
        const self: *Fixture = @ptrCast(@alignCast(raw));
        self.frame += 1;
        switch (self.frame) {
            1 => {
                self.shared.active_owner = owner;
                self.shared.host.offer(owner, 1, 1, .secret_input, .{ .title = "SSH 密码认证", .fields = &.{.{ .label = "Password:" }} }, std.math.maxInt(u64)) catch return .done;
                return .needs_layout;
            },
            5 => {
                self.shared.host.retire(owner, 1, 1);
                return .needs_layout;
            },
            8 => {
                self.shared.host.offer(owner, 2, 1, .trust_material, .{
                    .title = "核对主机密钥",
                    .source_name = "临时-BW1101-RAM96GB · root@10.17.53.66:22 · 第 1 跳",
                    .detail = "请通过可信渠道核对指纹。仅本次信任不写记录；保存并继续会记录本次核对的密钥。",
                    .material = "ecdsa-sha2-nistp256\nSHA256:naWLpS2Mg4PErI2xEpfkIjMrwAXnF7n5go",
                    .choices = &.{ .{ .value = "trust_once", .label = "仅本次信任" }, .{ .value = "trust_save", .label = "保存并继续" } },
                }, std.math.maxInt(u64)) catch return .done;
                return .needs_layout;
            },
            else => return .done,
        }
    }
};

fn mount(cx: *ui.Cx, scope: *ui.Scope) !*ui.Node {
    theme.select(selected_theme);
    cx.setTheme(theme.widgetTheme(selected_theme));
    const root = try ui.box(cx, .{ .width = .fill(), .height = .fill(), .direction = .column }, .{});
    const state = try scope.createState(Fixture, .{});
    state.shared = try Shared.mount(cx, scope);
    try cx.addAfterLayoutHook(state, Fixture.step);
    return root;
}

pub fn main(init: std.process.Init) !void {
    var args = init.minimal.args.iterate();
    _ = args.next();
    if (args.next()) |arg| selected_theme = std.meta.stringToEnum(theme.Name, arg) orelse return error.InvalidTheme;
    const app = try App.init(std.heap.c_allocator, .{ .io = init.io, .window = .{ .width = 1440, .height = 900, .min_width = 860, .min_height = 480, .title = "ZeroWork · Challenge Presenter", .titlebar = .custom_inset, .titlebar_height = 40 } });
    defer app.deinit();
    try app.runWith(mount);
}
