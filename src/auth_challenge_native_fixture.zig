//! Isolated acceptance window for the retained legacy view, not a production route.
//! Uses its actual InteractiveBridge; no SSH, trust-store or credential writes.
const std = @import("std");
const ui = @import("ui");
const App = @import("zenit_app").App;
const module = @import("ui/auth_challenge_view.zig");
const auth = module.auth;
const theme = @import("ui/app_theme.zig");
var selected_theme: theme.Name = .dark;
const Fixture = struct {
    cx: *ui.Cx,
    view: *module.View = undefined,
    bridge: auth.InteractiveBridge = .{},
    pending: ?auth.Kind = null,
    outcome: *ui.Node = undefined,
    close_pending: bool = false,
    fn submit(raw: *anyopaque, id: auth.RequestIdentity, reply: auth.Reply) !void {
        const self: *Fixture = @ptrCast(@alignCast(raw));
        try self.bridge.submit(id, reply);
        var result = try self.bridge.waitResponse(id, 50);
        defer result.deinit();
        // Record the decision only; fixture inputs never enter screenshot logs.
        try self.outcome.setTextContent(self.cx.allocator, switch (reply) {
            .answers => "submitted",
            .trust_once => "trust_once",
            .trust_save => "trust_save",
            .replace_host_key => "replace_host_key",
        });
        self.close_pending = true;
        self.cx.requestRedraw();
    }
    fn cancel(raw: *anyopaque, id: auth.RequestIdentity) void {
        const self: *Fixture = @ptrCast(@alignCast(raw));
        if (!self.bridge.cancelRequest(id)) return;
        self.outcome.setTextContent(self.cx.allocator, "cancelled") catch {};
        self.close_pending = true;
        self.cx.requestRedraw();
    }
    fn tick(raw: *anyopaque, _: u8, _: bool) ui.AfterLayoutResult {
        const self: *Fixture = @ptrCast(@alignCast(raw));
        if (self.close_pending) {
            self.close_pending = false;
            self.view.hide();
            return .needs_layout;
        }
        const kind = self.pending orelse return .done;
        self.pending = null;
        self.open(kind) catch |err| {
            std.log.err("legacy authentication fixture: {s}", .{@errorName(err)});
        };
        return .needs_layout;
    }
    fn open(self: *Fixture, kind: auth.Kind) !void {
        self.bridge.resetForAttempt();
        const prompts: []const auth.Prompt = switch (kind) {
            .host_key_unknown, .host_key_changed => &.{},
            .keyboard_interactive => &.{.{ .text = "Verification code:", .kind = .one_time_code }},
            .password => &.{.{ .text = "Password:" }},
            .private_key_passphrase => &.{.{ .text = "Private key passphrase:" }},
        };
        const id = try self.bridge.offerChallenge(.{
            .key = .{ .owner = .{ .session = .{ .session_id = @fromBackingInt(9), .generation = 3 } }, .operation_id = 7, .attempt_id = 2 },
            .hop_index = 0,
            .kind = kind,
            .endpoint_identity = .{ .host = "127.0.0.1", .user = "fixture", .port = 2222 },
            .prompts = prompts,
            .presentation = .otp_modal,
            .presentation_config_revision = 1,
        });
        try self.view.show(self.bridge.snapshot().?);
        try self.view.setDetails(id, .{
            .display_name = "旧认证组件验收 · 隔离数据",
            .private_key_path = "/fixtures/id_ed25519",
            .algorithm = "ssh-ed25519",
            .fingerprint = "SHA256:fixture-new-key-0123456789012345678901234567",
            .previous_algorithm = "ssh-ed25519",
            .previous_fingerprint = "SHA256:fixture-old-key-0123456789012345678901234567",
            .store_path = "/fixtures/known_hosts",
        });
        try self.view.retheme();
        try self.outcome.setTextContent(self.cx.allocator, "pending");
    }
};
const Choice = struct {
    fixture: *Fixture,
    kind: auth.Kind,
    fn click(self: *Choice) void {
        self.fixture.pending = self.kind;
        self.fixture.cx.requestRedraw();
    }
};
fn mount(cx: *ui.Cx, scope: *ui.Scope) !*ui.Node {
    theme.select(selected_theme);
    cx.setTheme(theme.widgetTheme(selected_theme));
    const root = try ui.box(cx, .{ .width = .fill(), .height = .fill(), .direction = .column, .padding = ui.Padding.all(24), .gap = 12, .background = theme.current().app }, .{});
    const state = try scope.createState(Fixture, .{ .cx = cx });
    try root.appendChild(cx.allocator, try ui.text(cx, "旧认证视图 · 真实组件隔离验收", .{ .font_size = 16, .font_weight = 700, .color = theme.current().fg_1 }));
    const row = try ui.box(cx, .{ .width = .fill(), .direction = .row, .gap = 8 }, .{});
    try root.appendChild(cx.allocator, row);
    inline for (std.enums.values(auth.Kind)) |kind| {
        const choice = try scope.createState(Choice, .{ .fixture = state, .kind = kind });
        const button = try ui.widgets.Button(.{ .label = @tagName(kind), .variant = .secondary, .on_click = cx.on(Choice, choice, Choice.click) }).mount(scope, cx);
        button.meta.ownership.meta.test_id = "legacy.auth." ++ @tagName(kind);
        try row.appendChild(cx.allocator, button);
    }
    state.outcome = try ui.text(cx, "idle", .{ .font_size = 13, .color = theme.current().fg_1 });
    state.outcome.meta.ownership.meta.test_id = "legacy.auth.outcome";
    try root.appendChild(cx.allocator, state.outcome);
    state.view = try module.View.mount(cx, scope, .{ .context = state, .submit = Fixture.submit, .cancel = Fixture.cancel });
    try root.appendChild(cx.allocator, state.view.root);
    try cx.addAfterLayoutHook(state, Fixture.tick);
    return root;
}
pub fn main(init: std.process.Init) !void {
    var args = init.minimal.args.iterate();
    _ = args.next();
    if (args.next()) |arg| selected_theme = std.meta.stringToEnum(theme.Name, arg) orelse return error.InvalidTheme;
    const app = try App.init(std.heap.c_allocator, .{ .io = init.io, .window = .{ .width = 1440, .height = 900, .min_width = 860, .min_height = 480, .title = "ZeroWork · Legacy Authentication Acceptance", .titlebar = .custom_inset, .titlebar_height = 40 } });
    defer app.deinit();
    try app.runWith(mount);
}
