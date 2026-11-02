//! Isolated acceptance window for the retained legacy view, not a production route.
//! Uses its actual InteractiveBridge; no SSH, trust-store or credential writes.
const std = @import("std");
const ui = @import("ui");
const App = @import("zenit_app").App;
const module = @import("ui/auth_challenge_view.zig");
const auth = module.auth;
const theme = @import("ui/app_theme.zig");
const Shared = @import("ui/challenge_window_host.zig").Services;
const identity = @import("host/identity.zig");
var selected_theme: theme.Name = .dark;
var launch_certificate: bool = false;
const Fixture = struct {
    cx: *ui.Cx,
    view: *module.View = undefined,
    bridge: auth.InteractiveBridge = .{},
    pending: ?auth.Kind = null,
    shared: *Shared = undefined,
    pending_certificate: bool = false,
    certificate_request_id: u64 = 0,
    outcome: *ui.Node = undefined,
    close_pending: bool = false,
    const certificate_owner: identity.SessionHandle = .{ .session_id = @fromBackingInt(93), .generation = 1 };
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
        if (self.shared.host.takeAnswer(certificate_owner, self.certificate_request_id, 1)) |incoming| {
            var answer = incoming;
            defer answer.deinit();
            self.outcome.setTextContent(self.cx.allocator, answer.value.choice) catch {};
        }
        if (self.shared.host.stateFor(certificate_owner, self.certificate_request_id, 1) == .withdrawn) {
            self.shared.host.retire(certificate_owner, self.certificate_request_id, 1);
            self.outcome.setTextContent(self.cx.allocator, "cancelled") catch {};
        }
        if (self.pending_certificate) {
            self.pending_certificate = false;
            self.openCertificate() catch |err| std.log.err("certificate trust fixture: {s}", .{@errorName(err)});
            return .needs_layout;
        }
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
    fn requestCertificate(self: *Fixture) void {
        self.pending_certificate = true;
        self.cx.requestRedraw();
    }
    fn openCertificate(self: *Fixture) !void {
        self.shared.host.retireOwner(certificate_owner);
        self.certificate_request_id += 1;
        var leaf: [32]u8 = undefined;
        var chain: [32]u8 = undefined;
        _ = try std.fmt.hexToBytes(&leaf, "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef");
        _ = try std.fmt.hexToBytes(&chain, "fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210");
        try self.shared.host.offer(certificate_owner, self.certificate_request_id, 1, .choice, .{
            .title = "信任 BMC 证书",
            .source_name = "BMC · iKVM",
            .detail = "通过可信渠道核对原始 BMC 目标和指纹后，再选择信任范围。\n拒绝会停止连接，且不会发送 BMC 凭据。",
            .certificate_trust = .{
                .authority = "bmc.example.test:443",
                .leaf_fingerprint = leaf,
                .chain_fingerprint = chain,
                .subject = "CN=bmc.example.test, OU=Management, O=Example Hardware, L=Shanghai, ST=Shanghai, C=CN",
                .issuer = "CN=bmc.example.test, OU=Management, O=Example Hardware, L=Shanghai, ST=Shanghai, C=CN",
                .valid_from = "2025-01-01 00:00:00 UTC",
                .valid_until = "2035-01-01 00:00:00 UTC",
                .failures = "- 证书颁发者不受信任（可能为自签名证书或未知 CA）\n- 证书主机名与目标不匹配\n- 证书总有效期超过系统允许上限",
            },
            .choices = &.{ .{ .value = "reject", .label = "拒绝连接" }, .{ .value = "once", .label = "仅本次信任" }, .{ .value = "persistent", .label = "保存并继续" } },
        }, std.math.maxInt(u64));
        self.shared.active_owner = certificate_owner;
        try self.shared.view.update(certificate_owner);
        try self.outcome.setTextContent(self.cx.allocator, "pending");
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
    state.shared = try Shared.mount(cx, scope);
    state.pending_certificate = launch_certificate;
    try root.appendChild(cx.allocator, try ui.text(cx, "旧认证视图 · 真实组件隔离验收", .{ .font_size = 16, .font_weight = 700, .color = theme.current().fg_1 }));
    const row = try ui.box(cx, .{ .width = .fill(), .direction = .row, .gap = 8 }, .{});
    try root.appendChild(cx.allocator, row);
    inline for (std.enums.values(auth.Kind)) |kind| {
        const choice = try scope.createState(Choice, .{ .fixture = state, .kind = kind });
        const button = try ui.widgets.Button(.{ .label = @tagName(kind), .variant = .secondary, .on_click = cx.on(Choice, choice, Choice.click) }).mount(scope, cx);
        button.meta.ownership.meta.test_id = "legacy.auth." ++ @tagName(kind);
        try row.appendChild(cx.allocator, button);
    }
    const certificate_button = try ui.widgets.Button(.{ .label = "certificate_tls", .variant = .secondary, .on_click = cx.on(Fixture, state, Fixture.requestCertificate) }).mount(scope, cx);
    certificate_button.meta.ownership.meta.test_id = "legacy.auth.certificate_tls";
    try row.appendChild(cx.allocator, certificate_button);
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
    if (args.next()) |arg| launch_certificate = std.mem.eql(u8, arg, "certificate_tls");
    const app = try App.init(std.heap.c_allocator, .{ .io = init.io, .window = .{ .width = 1440, .height = 900, .min_width = 860, .min_height = 480, .title = if (launch_certificate) "ZeroWork · Certificate Trust Acceptance" else "ZeroWork · Legacy Authentication Acceptance", .titlebar = .custom_inset, .titlebar_height = 40 } });
    defer app.deinit();
    if (launch_certificate) {
        // Match the production monospace role; App's stock selector otherwise
        // falls back to its proportional UI font in this isolated fixture.
        const mono = try app.font_manager.findFont(.{ .family = "Menlo", .size = 13 });
        mono.setScaleFactor(app.scale);
        app.font_selector.mono_fonts[0] = mono;
        app.font_selector.mono_count = 1;
    }
    try app.runWith(mount);
}
