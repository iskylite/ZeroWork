//! Production three-step connection wizard. Draft slices are borrowed only for
//! the duration of on_result/on_test; asynchronous consumers must use Draft.dupe
//! and release the result with Draft.deinit. Assets supplied via setAssets remain
//! borrowed until replaced or the wizard is disposed. No simulated probe success.

const std = @import("std");
const ui = @import("ui");
const S = @import("../../ui/wizard_styles.zig");
const hosts_mod = @import("../../config/hosts.zig");
const identity = @import("../../host/identity.zig");
pub const TestProgress = @import("../../ui/wizard_test_progress.zig");
var next_draft_id: std.atomic.Value(u64) = .init(1);

fn allocateDraftId() !u64 {
    var current = next_draft_id.load(.monotonic);
    while (true) {
        if (current == 0) return error.IdentityExhausted;
        const next = if (current == std.math.maxInt(u64)) 0 else current + 1;
        if (next_draft_id.cmpxchgWeak(current, next, .monotonic, .monotonic)) |actual| current = actual else return current;
    }
}

fn parseAssetValue(value: []const u8) !identity.ConnectionId {
    if (!std.mem.startsWith(u8, value, "conn:") or value.len <= 5) return error.InvalidIdentity;
    for (value[5..]) |byte| if (byte < '0' or byte > '9') return error.InvalidIdentity;
    const id = std.fmt.parseInt(u64, value[5..], 10) catch return error.InvalidIdentity;
    if (id == 0) return error.InvalidIdentity;
    return @fromBackingInt(id);
}

// ── 公共类型 ─────────────────────────────────────────────────────────

/// 向导三步。
pub const Step = enum { protocol, form, confirm };

/// Persisted protocol compatibility; the production picker exposes SSH and SFTP only.
pub const Protocol = enum { ssh, sftp, scp, mosh, telnet, serial, ftps, vnc, rdp, kvm };

/// 认证方式（表单 radio）。Agent 使用本机 SSH agent；keyboard-interactive
/// 不是凭据类型，而是服务器在认证协商中提出挑战时进入独立挑战模态。
pub const Auth = enum { password, key, agent };

/// 测试结果状态；ok/fail 携带的 detail 为调用方传入的描述
/// （如「连接成功 · 46ms」/「目标端口不可达」），向导负责加 ✓/✕ 与着色。
pub const TestState = union(enum) { none, pending, ok: []const u8, fail: []const u8 };

/// Draft 校验错误（对齐 HostConfig.validate 的前三条规则）。
pub const ValidationError = error{ MissingName, MissingHost, InvalidPort, MissingUser, TooManyJumps, InvalidIdentity, UnmigratedRoute, UnsupportedEncoding };

/// 测试 detail 拷贝上限（UTF-8 字节）。
pub const test_detail_max = 160;

/// 向导产出的连接草稿：与 HostConfig 字段对齐（见文件头对齐表）。
/// 字符串切片默认借用向导内部输入信号缓冲，跨事件保存用 `dupe`。
pub const Draft = struct {
    draft_id: u64 = 0,
    revision: u64 = 1,
    source_owner: ?identity.AssetOwner = null,
    copy_source_owner: ?identity.AssetOwner = null,
    name: []const u8 = "",
    protocol: Protocol = .ssh,
    host: []const u8 = "",
    port: u16 = 22,
    user: []const u8 = "",
    group: ?[]const u8 = null,
    auth: Auth = .password,
    password: ?[]const u8 = null,
    /// Explicit consent to persist the login password through the credential store.
    save_password: bool = false,
    key_path: ?[]const u8 = null,
    key_passphrase: ?[]const u8 = null,
    keepalive: bool = true,
    compression: bool = false,
    compression_explicit: bool = true,
    strict_host_key_checking: bool = true,
    encoding: []const u8 = "UTF-8",
    socks_enabled: bool = false,
    socks_port: u16 = 1080,
    socks_bind: []const u8 = "127.0.0.1",
    socks_exit: ?usize = null,
    socks_auto_start: bool = false,
    socks_max_connections: u16 = 64,
    terminal_type: []const u8 = "xterm-256color",
    terminal_type_explicit: bool = true,
    scrollback: u32 = 50000,
    jump_chain: []const []const u8 = &.{},
    route: []const identity.ConnectionId = &.{},
    startup_commands: []const []const u8 = &.{},

    /// 主机名/连接名非空、用户名非空、端口 1-65535（u16 上限即端口上界，
    /// 解析溢出回退 0 在此拒绝）。
    pub fn validate(self: Draft) ValidationError!void {
        if (!std.mem.eql(u8, self.encoding, "UTF-8")) return error.UnsupportedEncoding;
        if (trim(self.name).len == 0) return error.MissingName;
        if (trim(self.host).len == 0) return error.MissingHost;
        if (trim(self.user).len == 0) return error.MissingUser;
        if (self.port == 0 or (self.socks_enabled and self.socks_port == 0)) return error.InvalidPort;
        if (self.jump_chain.len > 8 or self.route.len > 8) return error.TooManyJumps;
        if (self.revision == 0) return error.InvalidIdentity;
        if (self.source_owner) |owner| if (@backingInt(owner.id) == 0 or owner.revision == 0) return error.InvalidIdentity;
        if (self.route.len == 0 and self.jump_chain.len != 0) return error.UnmigratedRoute;
        for (self.route) |id| if (@backingInt(id) == 0) return error.InvalidIdentity;
    }

    /// Borrowed projection. Clone with dupe() before retaining across events.
    pub fn fromHost(host: hosts_mod.HostConfig) Draft {
        return .{
            .source_owner = if (@backingInt(host.connection_id) != 0) host.owner() else null,
            .name = host.name,
            .protocol = if (host.protocol == .ssh) .ssh else .sftp,
            .host = host.host,
            .port = host.port,
            .user = host.user,
            .group = host.group,
            .auth = switch (host.auth_mode) {
                .agent => .agent,
                .password => .password,
                .private_key => .key,
            },
            .password = host.password,
            .save_password = host.password_ref != null or host.password != null,
            .key_path = host.identity_file,
            .key_passphrase = host.key_passphrase,
            .keepalive = host.keepalive,
            .compression = host.compression,
            .compression_explicit = host.compression_explicit,
            .strict_host_key_checking = host.strict_host_key_checking,
            .terminal_type = host.terminal_type,
            .terminal_type_explicit = host.terminal_type_explicit,
            .scrollback = host.scrollback,
            .route = host.route,
            .jump_chain = host.jump_chain,
            .startup_commands = host.startup_commands,
            .socks_enabled = host.socks_enabled,
            .socks_port = host.socks_port,
            .socks_bind = host.socks_bind,
            .socks_exit = host.socks_exit,
            .socks_auto_start = host.socks_auto_start,
            .socks_max_connections = host.socks_max_connections,
        };
    }

    /// Saved identity is present only for editing; copies retain their explicit
    /// source separately and request a new persistent identity on save.
    pub fn toHostConfig(self: Draft) !hosts_mod.HostConfig {
        try self.validate();
        const host: hosts_mod.HostConfig = .{
            .connection_id = if (self.source_owner) |owner| owner.id else @fromBackingInt(0),
            .revision = if (self.source_owner) |owner| owner.revision else 1,
            .protocol = switch (self.protocol) {
                .ssh => .ssh,
                .sftp => .sftp,
                else => return error.UnsupportedProtocol,
            },
            .auth_mode = switch (self.auth) {
                .agent => .agent,
                .password => .password,
                .key => .private_key,
            },
            .name = self.name,
            .host = self.host,
            .port = self.port,
            .user = self.user,
            .group = self.group,
            .password = if (self.auth == .password) self.password else null,
            .identity_file = if (self.auth == .key) self.key_path else null,
            .key_passphrase = if (self.auth == .key) self.key_passphrase else null,
            .keepalive = self.keepalive,
            .compression = self.compression,
            .compression_explicit = self.compression_explicit,
            .strict_host_key_checking = self.strict_host_key_checking,
            .terminal_type = self.terminal_type,
            .terminal_type_explicit = self.terminal_type_explicit,
            .scrollback = self.scrollback,
            .route = self.route,
            .jump_chain = self.jump_chain,
            .startup_commands = self.startup_commands,
            .socks_enabled = self.socks_enabled,
            .socks_port = self.socks_port,
            .socks_bind = self.socks_bind,
            .socks_exit = self.socks_exit,
            .socks_auto_start = self.socks_auto_start,
            .socks_max_connections = self.socks_max_connections,
        };
        try host.validate();
        return host;
    }

    /// Persistence projection keeps transient login credentials out of the host
    /// transaction unless explicitly selected. store.zig stages the selected
    /// password into Keychain and serializes only its opaque reference.
    pub fn toPersistentHostConfig(self: Draft) !hosts_mod.HostConfig {
        var host = try self.toHostConfig();
        if (!self.save_password) host.password = null;
        host.key_passphrase = null;
        host.totp_secret = null;
        return host;
    }

    /// 深拷贝全部字符串字段（调用方获得自有存储；失败时已拷贝部分由
    /// errdefer 释放，不泄漏不悬垂）。
    pub fn dupe(self: Draft, allocator: std.mem.Allocator) std.mem.Allocator.Error!Draft {
        var out = self;
        out.name = try allocator.dupe(u8, self.name);
        errdefer allocator.free(out.name);
        out.host = try allocator.dupe(u8, self.host);
        errdefer allocator.free(out.host);
        out.user = try allocator.dupe(u8, self.user);
        errdefer allocator.free(out.user);
        out.encoding = try allocator.dupe(u8, self.encoding);
        errdefer allocator.free(out.encoding);
        out.group = if (self.group) |v| try allocator.dupe(u8, v) else null;
        errdefer if (out.group) |v| allocator.free(v);
        out.password = if (self.password) |v| try allocator.dupe(u8, v) else null;
        errdefer if (out.password) |v| allocator.free(v);
        out.key_path = if (self.key_path) |v| try allocator.dupe(u8, v) else null;
        errdefer if (out.key_path) |v| allocator.free(v);
        out.key_passphrase = if (self.key_passphrase) |v| try allocator.dupe(u8, v) else null;
        errdefer if (out.key_passphrase) |v| allocator.free(v);
        out.socks_bind = try allocator.dupe(u8, self.socks_bind);
        errdefer allocator.free(out.socks_bind);
        out.terminal_type = try allocator.dupe(u8, self.terminal_type);
        errdefer allocator.free(out.terminal_type);
        out.jump_chain = try dupeStrings(allocator, self.jump_chain);
        errdefer freeStrings(allocator, out.jump_chain);
        out.route = try allocator.dupe(identity.ConnectionId, self.route);
        errdefer allocator.free(out.route);
        out.startup_commands = try dupeStrings(allocator, self.startup_commands);
        return out;
    }

    /// Only call on a value returned by dupe.
    pub fn deinit(self: *Draft, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.host);
        allocator.free(self.user);
        allocator.free(self.encoding);
        allocator.free(self.socks_bind);
        allocator.free(self.terminal_type);
        inline for (.{ "group", "password", "key_path", "key_passphrase" }) |field_name| {
            if (@field(self, field_name)) |v| allocator.free(v);
        }
        freeStrings(allocator, self.jump_chain);
        allocator.free(self.route);
        freeStrings(allocator, self.startup_commands);
        self.* = undefined;
    }

    /// 端口摘要文本（"22"/"2222"）。
    pub fn formatPort(self: Draft, buf: []u8) []const u8 {
        return std.fmt.bufPrint(buf, "{d}", .{self.port}) catch "—";
    }

    /// 认证摘要文本（"密码登录" / "密钥登录 · {路径}"）。
    pub fn formatAuth(self: Draft, buf: []u8) []const u8 {
        return switch (self.auth) {
            .password => "密码登录",
            .key => std.fmt.bufPrint(buf, "密钥登录 · {s}", .{self.key_path orelse "未指定路径"}) catch "密钥登录",
            .agent => "SSH Agent",
        };
    }
};

fn dupeStrings(allocator: std.mem.Allocator, values: []const []const u8) ![]const []const u8 {
    const result = try allocator.alloc([]const u8, values.len);
    var count: usize = 0;
    errdefer {
        for (result[0..count]) |value| allocator.free(value);
        allocator.free(result);
    }
    for (values, 0..) |value, i| {
        result[i] = try allocator.dupe(u8, value);
        count += 1;
    }
    return result;
}
fn freeStrings(allocator: std.mem.Allocator, values: []const []const u8) void {
    for (values) |value| allocator.free(value);
    allocator.free(values);
}

/// 保存/取消结果；saved 携带的 Draft 切片仅回调当次有效（见 `Draft.dupe`）。
pub const Result = union(enum) { save_only: Draft, saved: Draft, cancelled };
/// Disk commit succeeded for this exact asset revision. An opening failure
/// retains this receipt, so retrying never creates a duplicate saved asset.
pub const SaveReceipt = struct { owner: identity.AssetOwner, open_failure: ?anyerror = null };
pub const SaveFailure = struct { stage: enum { save, open }, cause: anyerror };

/// 端口文本 → u16：非数字/越界一律 0（由 Draft.validate 拒绝）。
pub fn parsePort(text: []const u8) u16 {
    const value = trim(text);
    if (value.len == 0) return 0;
    for (value) |byte| if (byte < '0' or byte > '9') return 0;
    return std.fmt.parseInt(u16, value, 10) catch 0;
}

fn trim(value: []const u8) []const u8 {
    return std.mem.trim(u8, value, " \t\r\n");
}

/// 状态机：下一步（confirm 为终点）。
fn stepAfter(step: Step) ?Step {
    return switch (step) {
        .protocol => .form,
        .form => .confirm,
        .confirm => null,
    };
}

/// 状态机：上一步（protocol 为起点）。
fn stepBefore(step: Step) ?Step {
    return switch (step) {
        .confirm => .form,
        .form => .protocol,
        .protocol => null,
    };
}

/// 三步共用字段校验，confirm 为终点。
pub fn advanceAllowed(step: Step, draft: Draft) bool {
    if (step == .confirm) return false;
    draft.validate() catch return false;
    return true;
}

/// 测试结果行文本：ok「✓ …」/ fail「✕ …」/ pending「… …」/ none 固定文案。
pub fn formatTestLine(state: TestState, buf: []u8) []const u8 {
    return switch (state) {
        .none => "尚未测试",
        .pending => "… 正在测试连接…",
        .ok => |detail| std.fmt.bufPrint(buf, "✓ {s}", .{detail}) catch "✓",
        .fail => |detail| std.fmt.bufPrint(buf, "✕ {s}", .{detail}) catch "✕",
    };
}

const TestKind = enum { none, pending, ok, fail };

// ── RemoteEditor ───────────────────────────────────────────────────────────

/// 新建连接向导：absolute 全屏压暗层 + 居中模态，三步状态机驱动。
/// 调用方注入 on_result / on_test（见文件头集成步骤），show()/hide() 控制显隐。
pub const RemoteEditor = struct {
    embedded: bool = false,
    protocol_picker: ?@import("../../host/plugin_ui_contract.zig").EditorProtocolPicker = null,
    nodes_alive: bool = true,
    connection_configs: ?@import("../../host/connection_config_resolver.zig").Resolver = null,
    protocol_id: []const u8 = "ssh",
    stepper: ?*ui.Node = null,

    /// Save errors are pre-commit; return a receipt after disk commit, even
    /// when opening subsequently fails. Cancellation returns null.
    /// Draft slices are borrowed only during this synchronous callback.
    on_result: ?*const fn (ctx: *anyopaque, result: Result) anyerror!?SaveReceipt = null,
    result_ctx: *anyopaque = undefined,
    saving: bool = false,
    cancel_requested: bool = false,
    locked: ?*ui.Signal(bool) = null,
    next1_disabled: ?*ui.Signal(bool) = null,
    next2_disabled: ?*ui.Signal(bool) = null,
    save_disabled: ?*ui.Signal(bool) = null,
    open_disabled: ?*ui.Signal(bool) = null,
    copy_disabled: ?*ui.Signal(bool) = null,
    copy_open_disabled: ?*ui.Signal(bool) = null,
    open: ?*ui.Signal(bool) = null,
    sig_protocol: ?*ui.Signal(?[]const u8) = null,
    sig_auth: ?*ui.Signal(?[]const u8) = null,
    sig_copy_source: ?*ui.Signal(?[]const u8) = null,
    copy_source_text: ?*ui.Signal([]const u8) = null,
    sig_strict: ?*ui.Signal(bool) = null,
    sig_strict_policy: ?*ui.Signal(?[]const u8) = null,
    sig_startup: ?*ui.Signal([]const u8) = null,
    startup_error: ?*ui.Signal([]const u8) = null,
    startup_textarea: ?ui.widgets.input.TextareaResult = null,
    startup_overflow: bool = false,
    sig_compression: ?*ui.Signal(bool) = null,
    logs_open: ?*ui.Signal(bool) = null,
    header: ?*ui.Node = null,
    title: ?*ui.Node = null,
    discard_open: bool = false,
    discard_expanded: bool = true,
    discard_heading: ?*ui.Node = null,
    discard_chevron: ?*ui.Node = null,
    discard_card: ?*ui.Node = null,
    discard_scroll: ?ui.widgets.ScrollAreaResult = null,
    discard_name: ?*ui.Node = null,
    discard_status: ?*ui.Node = null,
    discard_continue: ?*ui.Node = null,
    discard_confirm: ?*ui.Node = null,
    discard_footer: ?*ui.Node = null,
    body: ?*ui.Node = null,
    footer: ?*ui.Node = null,
    back_btn: ?*ui.Node = null,
    cancel_btn: ?*ui.Node = null,
    save_only_btn: ?*ui.Node = null,
    test_btn: ?*ui.Node = null,
    strict_checkbox: ?*ui.Node = null,
    compression_checkbox: ?*ui.Node = null,
    remember_checkbox: ?*ui.Node = null,
    identity_body: ?*ui.Node = null,
    auth_body: ?*ui.Node = null,
    identity_card: ?*ui.Node = null,
    auth_card: ?*ui.Node = null,
    identity_expanded: bool = true,
    auth_expanded: bool = true,
    furthest_step: Step = .protocol,
    step_buttons: [3]?*ui.Node = @splat(null),
    step_numbers: [3]?*ui.Node = @splat(null),
    step_digits: [3]?*ui.Node = @splat(null),
    step_checks: [3]?*ui.Node = @splat(null),
    step_titles: [3]?*ui.Node = @splat(null),
    step_details: [3]?*ui.Node = @splat(null),
    step_disabled: [3]?*ui.Signal(bool) = @splat(null),
    step_styles: [3]?*ui.Signal(ui.BoxStyle) = @splat(null),
    scrolls: [3]?ui.widgets.ScrollAreaResult = @splat(null),
    route_editor: ?*ui.Node = null,
    route_hint: ?*ui.Node = null,
    summary_identity: ?*ui.Node = null,
    summary_card: ?*ui.Node = null,
    summary_options: ?*ui.Node = null,
    summary_name: ?*ui.Node = null,
    summary_endpoint: ?*ui.Node = null,
    summary_values: [5]?*ui.Node = @splat(null),
    summary_route_card: ?*ui.Node = null,
    summary_route_nodes: [10]?*ui.Node = @splat(null),
    summary_route_names: [10]?*ui.Node = @splat(null),
    summary_route_captions: [10]?*ui.Node = @splat(null),
    summary_route_arrows: [9]?*ui.Node = @splat(null),
    protocol_icon: ?*ui.Node = null,
    protocol_select_icon: ?*ui.Node = null,
    summary_icon: ?*ui.Node = null,
    review_disclosure: ?*ui.Node = null,
    strict_focus_pending: bool = false,
    inputs: std.ArrayList(ui.widgets.input.InputResult) = .empty,
    field_feedback: std.ArrayList(*FieldFeedback) = .empty,
    validation_focus_group: ?*ui.Node = null,
    selects: std.ArrayList(ui.widgets.SelectResult) = .empty,
    buttons: std.ArrayList(ButtonPaint) = .empty,
    editor_actions: std.ArrayList(*EditorAction) = .empty,
    jump_add_disabled: ?*ui.Signal(bool) = null,
    owned_ids: std.ArrayList([]u8) = .empty,
    agent_notice: ?*ui.Node = null,
    route_choices: [2]?RouteChoice = @splat(null),
    route_empty_hint: ?*ui.Node = null,
    route_card: ?*ui.Node = null,
    route_body: ?*ui.Node = null,
    route_expanded: bool = true,
    copy_expanded: bool = false,
    copy_open: ?*ui.Signal(bool) = null,
    copy_dialog: ?*ui.Node = null,
    copy_body: ?*ui.Node = null,
    copy_trigger: ?*ui.Node = null,
    review_test_card: ?*ui.Node = null,
    logs_scroll: ?*ui.Node = null,
    test_source: ?TestProgress.Owned = null,
    test_history: TestProgress.History = .{},
    test_filter: ?usize = null,
    test_following: bool = true,
    test_new_logs: usize = 0,
    test_last_scroll: f32 = 0,
    test_cancel_sent: bool = false,
    test_reveal_pending: bool = false,
    test_copy_result: ?bool = null,
    test_action_disabled: ?*ui.Signal(bool) = null,
    test_rows: [128]TestLogRow = undefined,
    test_scroll: ?ui.widgets.ScrollAreaResult = null,
    test_follow_row: ?*ui.Node = null,
    test_follow_label: ?*ui.Node = null,
    test_follow_hint: ?*ui.Node = null,
    test_filter_label: ?*ui.Node = null,
    test_copy_icon: ?*ui.Node = null,
    test_disclosure_icon: ?*ui.Node = null,
    test_actions: [10]?*TestHopAction = @splat(null),
    review_body: ?*ui.Node = null,
    review_path: ?*ui.Node = null,
    review_expanded: bool = false,
    test_stages: [9]TestStageRow = undefined,
    summary_details: ?*ui.Node = null,
    on_cancel_test: ?*const fn (*anyopaque, TestProgress.operations.OperationKey) void = null,
    cancel_test_ctx: ?*anyopaque = null,
    painted_colors: ?S.theme.Colors = null,
    route_previews: [2]RoutePreview = @splat(.{}),

    save_failure: ?SaveFailure = null,
    save_error_node: ?*ui.Node = null,
    /// Stable slots inside the review step's scrolling content. The host owns
    /// authentication and supplies a frozen original-key probe projection.
    authentication_area: *ui.Node = undefined,
    test_logs_area: *ui.Node = undefined,
    test_log_text: *ui.Node = undefined,
    /// 连通性探测回调。向导在点击「测试全链路连通性」/「重新测试」时以
    /// Draft 快照调用（切片仅本回调内有效）；探测完成后由调用方回填
    /// `setTestResult`。未注入探测时必须失败；检测不是保存前提。
    on_test: ?*const fn (ctx: *anyopaque, draft: *const Draft) void = null,
    test_ctx: *anyopaque = undefined,

    assets: []const Draft = &.{},
    asset_strings: std.ArrayList([]u8) = .empty,
    draft_id: u64 = 0,
    draft_revision: u64 = 1,
    source_owner: ?identity.AssetOwner = null,
    copy_source_owner: ?identity.AssetOwner = null,
    strict_host_key_checking: bool = true,
    asset_options: ?*ui.Signal([]const ui.widgets.SelectOption) = null,
    jump_list: ?*ui.Signal([]const []const u8) = null,
    cx: *ui.Cx = undefined,
    scope: *ui.Scope = undefined,
    jump_values: [8]?*ui.Signal(?[]const u8) = @splat(null),
    jump_text: [8]?*ui.Signal([]const u8) = @splat(null),
    socks_exit_text: ?*ui.Signal([]const u8) = null,
    jump_rows: [8]?*ui.Node = @splat(null),
    jump_arrows: [8]?*ui.Node = @splat(null),
    jump_arrow_labels: [8]?*ui.Node = @splat(null),
    jump_addresses: [8]?*ui.Node = @splat(null),
    jump_actions: [8]?*ui.Node = @splat(null),
    editing_order: bool = false,
    jump_users: [8]?*ui.Node = @splat(null),
    exit_options: ?*ui.Signal([]const ui.widgets.SelectOption) = null,
    exit_labels: [8][128]u8 = undefined,
    topology_chain: ?*ui.Node = null,
    jump_count: usize = 0,
    jumps: [8][]const u8 = undefined,
    route_ids: [8]identity.ConnectionId = undefined,
    command_values: [32]?*ui.Signal([]const u8) = @splat(null),
    command_rows: [32]?*ui.Node = @splat(null),
    command_count: usize = 0,
    commands: [32][]const u8 = undefined,
    startup_enabled: bool = false,
    socks_enabled: bool = false,
    socks_auto_start: bool = false,
    socks_max_connections: u16 = 64,
    sig_socks_port: ?*ui.Signal([]const u8) = null,
    sig_socks_bind: ?*ui.Signal([]const u8) = null,
    sig_socks_exit: ?*ui.Signal(?[]const u8) = null,
    sig_terminal: ?*ui.Signal([]const u8) = null,
    terminal_type_explicit: bool = true,
    sig_scrollback: ?*ui.Signal([]const u8) = null,
    startup_track: ?*ui.Node = null,
    socks_track: ?*ui.Node = null,
    socks_auto_track: ?*ui.Node = null,
    next1_btn: ?*ui.Node = null,
    step2_grid: ?*ui.Node = null,
    step2_topology: ?*ui.Node = null,
    step2_topology_title: ?*ui.Node = null,
    step2_advanced: ?*ui.Node = null,
    step2_advanced_title: ?*ui.Node = null,
    /// Optional sections on the protocol page keep their header visible while
    /// the detailed controls remain collapsed until the user enables them.
    socks_card: ?*ui.Node = null,
    commands_card: ?*ui.Node = null,
    socks_details: ?*ui.Node = null,
    commands_details: ?*ui.Node = null,
    advanced_expanded: bool = false,
    advanced_body: ?*ui.Node = null,
    advanced_toggle: ?*ui.Node = null,
    advanced_chevron: ?*ui.Node = null,
    parent_presentation_visible: bool = true,
    parent_barrier_color: ui.Color = ui.Color.TRANSPARENT,
    direct_label: ?*ui.Node = null,
    ssh_card: ?*ui.Node = null,
    sftp_card: ?*ui.Node = null,
    // 运行时（mount 填充；均为内部实现细节）
    alloc: std.mem.Allocator = undefined,
    root: ?*ui.Node = null,
    modal: ?*ui.Node = null,
    confirm_card: ?*ui.Node = null,
    step1_view: ?*ui.Node = null,
    copy_bar: ?*ui.Node = null,
    step2_view: ?*ui.Node = null,
    step1_scroll: ?*ui.Node = null,
    step2_scroll: ?*ui.Node = null,
    step1_scroll_state: ?*ui.widgets.scroll_area.ScrollState = null,
    step2_scroll_state: ?*ui.widgets.scroll_area.ScrollState = null,
    step1_scroll_content: ?*ui.Node = null,
    step2_scroll_content: ?*ui.Node = null,
    viewport_width: f32 = -1,
    viewport_height: f32 = -1,
    viewport_step: ?Step = null,
    step: Step = .protocol,
    protocol: Protocol = .ssh,
    auth: Auth = .password,
    /// True when the current draft was populated through the top "从已有主机复制"
    /// picker.  The host editor uses this to distinguish "save edits" from
    /// "create a new cloned host" while both paths share the same wizard.
    copied_from_existing: bool = false,
    keepalive: bool = true,
    compression: bool = false,
    compression_explicit: bool = true,
    test_kind: TestKind = .none,
    /// Capture on_test entry and use setTestResultFor for asynchronous probes.
    test_generation: u64 = 0,
    identity_exhausted: bool = false,
    test_detail_buf: [test_detail_max]u8 = undefined,
    test_detail_len: usize = 0,
    /// 结果行/摘要行的格式化暂存（避免栈上多份大缓冲）。
    line_buf: [192]u8 = undefined,
    summary_auth_buf: [test_detail_max]u8 = undefined,

    // 输入信号（scope.createText，绑定 Draft 字段）
    sig_name: ?*ui.Signal([]const u8) = null,
    sig_group: ?*ui.Signal([]const u8) = null,
    sig_group_selection: ?*ui.Signal(?[]const u8) = null,
    group_options: ?*ui.Signal([]const ui.widgets.SelectOption) = null,
    group_name_pending: bool = false,
    sig_host: ?*ui.Signal([]const u8) = null,
    sig_port: ?*ui.Signal([]const u8) = null,
    sig_user: ?*ui.Signal([]const u8) = null,
    sig_password: ?*ui.Signal([]const u8) = null,
    sig_save_password: ?*ui.Signal(bool) = null,
    sig_key_path: ?*ui.Signal([]const u8) = null,
    sig_key_passphrase: ?*ui.Signal([]const u8) = null,
    sig_encoding: ?*ui.Signal([]const u8) = null,
    ssh_defaults: ?struct { connect_timeout_sec: u16, keepalive_sec: u16 } = null,
    connect_timeout_fact: ?*ui.Node = null,
    keepalive_fact: ?*ui.Node = null,

    // 动态节点（imperative 刷新目标）
    sum_nodes: [6]?*ui.Node = .{ null, null, null, null, null, null }, // 名称/主机/端口/用户/认证/测试
    res_dot: ?*ui.Node = null,
    test_status_icon: ?*ui.Node = null,
    res_text: ?*ui.Node = null,
    next2_btn: ?*ui.Node = null,
    save_btn: ?*ui.Node = null,
    pw_ring: ?*ui.Node = null,
    pw_dot: ?*ui.Node = null,
    key_ring: ?*ui.Node = null,
    key_dot: ?*ui.Node = null,
    agent_ring: ?*ui.Node = null,
    agent_dot: ?*ui.Node = null,
    cred_pw_row: ?*ui.Node = null,
    cred_key_row: ?*ui.Node = null,
    topo_name: ?*ui.Node = null,
    topo_addr: ?*ui.Node = null,
    topo_user: ?*ui.Node = null,
    keepalive_text: ?*ui.Node = null,
    keepalive_track: ?*ui.Node = null,
    compression_text: ?*ui.Node = null,
    compression_track: ?*ui.Node = null,

    /// 挂载：创建信号、三个步骤视图与确认卡，根节点初始 display .none。
    /// 信号与节点树绑定到传入 scope 的生命周期。
    pub fn mount(self: *RemoteEditor, cx: *ui.Cx, scope: *ui.Scope) anyerror!*ui.Node {
        self.alloc = cx.allocator;
        self.cx = cx;
        self.scope = scope;
        const feedback_guard = try scope.childScope();
        try feedback_guard.onCleanup(RemoteEditor, self, releaseFieldFeedback);
        if (self.draft_id == 0) self.draft_id = try allocateDraftId();
        errdefer self.releaseAssetValues();
        self.asset_options = try scope.createList(ui.widgets.SelectOption, &.{});
        self.jump_list = try scope.createList([]const u8, &.{});
        self.exit_options = try scope.createList(ui.widgets.SelectOption, &.{});
        self.sig_socks_port = try scope.createText("1080", .{});
        self.sig_socks_bind = try scope.createText("127.0.0.1", .{});
        self.sig_socks_exit = try scope.createSignal(?[]const u8, null);
        self.socks_exit_text = try scope.createText("", .{});
        self.sig_terminal = try scope.createText("xterm-256color", .{});
        self.sig_scrollback = try scope.createText("50000", .{});
        for (&self.jump_values) |*v| v.* = try scope.createSignal(?[]const u8, null);
        for (&self.jump_text) |*v| v.* = try scope.createText("", .{});
        for (&self.command_values) |*v| v.* = try scope.createText("", .{});
        self.sig_name = try scope.createText("", .{});
        self.sig_group = try scope.createText("", .{});
        self.sig_group_selection = try scope.createSignal(?[]const u8, "");
        self.group_options = try scope.createList(ui.widgets.SelectOption, &.{.{ .value = "", .label = "未分组" }});
        self.sig_host = try scope.createText("", .{});
        self.sig_port = try scope.createText("22", .{});
        self.sig_user = try scope.createText("", .{});
        self.sig_password = try scope.createText("", .{});
        self.sig_save_password = try scope.createSignal(bool, false);
        self.sig_key_path = try scope.createText("", .{});
        self.sig_key_passphrase = try scope.createText("", .{});
        self.sig_encoding = try scope.createText("UTF-8", .{});
        self.sig_startup = try scope.createText("", .{});
        self.startup_error = try scope.createText("", .{});
        self.sig_strict_policy = try scope.createSignal(?[]const u8, "true");

        self.locked = try scope.createSignal(bool, false);
        self.next1_disabled = try scope.createSignal(bool, true);
        self.next2_disabled = try scope.createSignal(bool, true);
        self.save_disabled = try scope.createSignal(bool, true);
        self.open_disabled = try scope.createSignal(bool, true);
        self.copy_disabled = try scope.createSignal(bool, true);
        self.copy_open_disabled = try scope.createSignal(bool, true);
        self.jump_add_disabled = try scope.createSignal(bool, false);
        self.open = try scope.createSignal(bool, false);
        self.sig_protocol = try scope.createSignal(?[]const u8, "ssh");
        self.sig_auth = try scope.createSignal(?[]const u8, "password");
        self.sig_copy_source = try scope.createSignal(?[]const u8, null);
        self.copy_source_text = try scope.createText("", .{});
        self.copy_open = try scope.createSignal(bool, false);
        self.sig_strict = try scope.createSignal(bool, self.strict_host_key_checking);
        self.sig_compression = try scope.createSignal(bool, self.compression);
        self.logs_open = try scope.createSignal(bool, false);
        self.test_action_disabled = try scope.createSignal(bool, false);
        const ModalParts = struct { overlay: *ui.Node, dialog: *ui.Node, body: *ui.Node, portaled: bool };
        const modal: ModalParts = if (self.embedded) blk: {
            const panel = try ui.box(cx, .{ .width = .fill(), .height = .fill(), .flex = 1, .direction = .column, .min_height = 0 }, .{});
            const content = try ui.box(cx, .{ .width = .fill(), .height = .fill(), .flex = 1, .direction = .column, .min_height = 0 }, .{});
            try panel.appendChild(self.alloc, content);
            break :blk .{ .overlay = panel, .dialog = panel, .body = content, .portaled = false };
        } else blk: {
            const value = try ui.widgets.Modal(.{ .open = ui.split(self.open.?, cx.on(RemoteEditor, self, openChanged)), .width = S.width, .max_height = S.max_height, .background = S.theme.current().overlay, .close_on_overlay = false }).mount(scope, cx);
            break :blk .{ .overlay = value.overlay, .dialog = value.dialog, .body = value.body, .portaled = value.portaled };
        };
        self.root = modal.overlay;
        self.modal = modal.dialog;
        if (!self.embedded) {
            modal.overlay.meta.ownership.meta.test_id = "wizard.overlay";
            modal.dialog.meta.ownership.meta.test_id = "wizard.dialog";
            modal.dialog.setStyleInline(self.alloc, S.panel(cx.tokens));
            modal.body.setStyleInline(self.alloc, S.modalBody());
        }
        const header = try ui.box(cx, S.header(), .{});
        self.header = header;
        if (self.embedded) header.setDisplay(.none);
        self.protocol_icon = try ui.iconTint(cx, ui.icons.terminal, S.theme.current().accent, S.icon(18));
        self.protocol_icon.?.meta.ownership.meta.test_id = "wizard.protocol.icon";
        self.protocol_icon.?.setDisplay(.none);
        try header.appendChild(self.alloc, self.protocol_icon.?);
        self.title = try ui.text(cx, "新建连接", S.text(13, 700, false));
        try header.appendChild(self.alloc, self.title.?);
        try header.appendChild(self.alloc, try ui.spacer(cx));
        const protocol_options = [_]ui.widgets.SelectOption{
            .{ .value = "ssh", .label = "SSH", .icon = ui.icons.terminal, .test_id = "wizard.protocol.ssh" },
            .{ .value = "sftp", .label = "SFTP", .icon = ui.icons.folder_open, .test_id = "wizard.protocol.sftp" },
        };
        const protocol = try ui.widgets.Select(.{ .options = &protocol_options, .value = self.sig_protocol.?, .leading_icon = ui.icons.terminal, .width = 104, .disabled = self.locked.?, .on_change = cx.on(RemoteEditor, self, onProtocolChanged) }).mount(scope, cx);
        skinSelect(self, protocol, 30, 12);
        self.protocol_select_icon = protocol.leading_icon;
        protocol.trigger.meta.ownership.meta.test_id = "wizard.protocol";
        try header.appendChild(self.alloc, protocol.wrapper);
        _ = try action(self, header, "关闭向导", "wizard.close", 22, 22, false, null, onCancelClick, ui.icons.x);
        try modal.body.appendChild(self.alloc, header);
        const body = try ui.box(cx, S.body(), .{});
        self.body = body;
        var stepper_style = S.row(46);
        stepper_style.padding = ui.Padding.all(5);
        stepper_style.background = S.theme.current().well;
        stepper_style.border = .{ .radius = 9 };
        const stepper = try ui.box(cx, stepper_style, .{});
        stepper.meta.ownership.meta.test_id = "wizard.steps";
        self.stepper = stepper;
        const labels = [_][]const u8{ "连接与认证", "连接路径", "核对与测试" };
        for (0..3) |i| {
            const ctx = try self.alloc.create(StepAction);
            ctx.* = .{ .wizard = self, .step = @fromBackingInt(@intCast(i)) };
            try scope.onCleanup(StepAction, ctx, StepAction.cleanup);
            self.step_disabled[i] = try scope.createSignal(bool, i != 0);
            self.step_styles[i] = try scope.createSignal(ui.BoxStyle, S.step(i == 0));
            const button = try ui.widgets.Button(.{ .variant = .ghost, .a11y_label = labels[i], .base_style = self.step_styles[i].?, .disabled = self.step_disabled[i].?, .on_click = cx.on(StepAction, ctx, StepAction.click) }).mount(scope, cx);
            for (button.children.items) |child| child.setDisplay(.none);
            button.meta.ownership.meta.test_id = ([_][]const u8{ "wizard.step.identity", "wizard.step.route", "wizard.step.review" })[i];
            self.step_buttons[i] = button;
            const number = try ui.box(cx, S.number(i == 0), .{});
            self.step_numbers[i] = number;
            const digit = try ui.text(cx, ([_][]const u8{ "1", "2", "3" })[i], S.stepNumber());
            digit.setStyleInline(self.alloc, .{ .width = .{ .px = 8 }, .height = .{ .px = 18 }, .flex_shrink = 0 });
            self.step_digits[i] = digit;
            try number.appendChild(self.alloc, digit);
            const check = try ui.iconTint(cx, ui.icons.check, S.theme.current().ok, S.icon(13));
            check.meta.ownership.meta.test_id = ([_][]const u8{ "wizard.step.identity.check", "wizard.step.route.check", "wizard.step.review.check" })[i];
            self.step_checks[i] = check;
            try number.appendChild(self.alloc, check);
            check.setDisplay(.none);
            try button.appendChild(self.alloc, number);
            const copy = try ui.box(cx, S.stepCopy(), .{});
            self.step_titles[i] = try ui.text(cx, labels[i], S.stepTitle(i == 0));
            try copy.appendChild(self.alloc, self.step_titles[i].?);
            self.step_details[i] = try ui.text(cx, if (i == 0) "当前步骤" else "待完成", S.text(9.5, 400, false));
            self.step_details[i].?.setDisplay(.none);
            try copy.appendChild(self.alloc, self.step_details[i].?);
            try button.appendChild(self.alloc, copy);
            try stepper.appendChild(self.alloc, button);
        }
        try body.appendChild(self.alloc, stepper);
        self.step1_view = try mountIdentity(self);
        self.refreshSshDefaults();
        self.step2_view = try mountRoute(self);
        self.confirm_card = try mountReview(self);
        const contents = [_]*ui.Node{ self.step1_view.?, self.step2_view.?, self.confirm_card.? };
        for (contents, 0..) |content, i| {
            const scroll = try ui.widgets.ScrollArea(.{ .direction = .vertical }).mount(scope, cx);
            scroll.container.setStyleInline(self.alloc, S.scroll());
            scroll.container.meta.ownership.meta.test_id = ([_][]const u8{ "wizard.scroll.identity", "wizard.scroll.route", "wizard.scroll.review" })[i];
            scroll.content.setStyleInline(self.alloc, .{ .width = .fill(), .height = .{ .fit = .{} }, .direction = .column, .gap = 6, .flex_shrink = 0 });
            if (i <= 1) scroll.content.setStyleInline(self.alloc, .{ .padding = .{ .left = 4, .right = 4, .bottom = 20 } });
            try scroll.content.appendChild(self.alloc, content);
            try body.appendChild(self.alloc, scroll.container);
            self.scrolls[i] = scroll;
        }
        self.step1_scroll = self.scrolls[0].?.container;
        self.step2_scroll = self.scrolls[1].?.container;
        self.step1_scroll_state = self.scrolls[0].?.state;
        self.step2_scroll_state = self.scrolls[1].?.state;
        self.step1_scroll_content = self.scrolls[0].?.content;
        self.step2_scroll_content = self.scrolls[1].?.content;
        self.discard_scroll = try ui.widgets.ScrollArea(.{ .direction = .vertical }).mount(scope, cx);
        self.discard_scroll.?.container.setStyleInline(self.alloc, S.scroll());
        self.discard_scroll.?.container.meta.ownership.meta.test_id = "wizard.discard";
        self.discard_card = try mountDiscard(self);
        try self.discard_scroll.?.content.appendChild(self.alloc, self.discard_card.?);
        self.discard_scroll.?.content.setStyleInline(self.alloc, S.stack(cx.tokens));
        try body.appendChild(self.alloc, self.discard_scroll.?.container);
        try modal.body.appendChild(self.alloc, body);
        const footer = try ui.box(cx, S.footer(), .{});
        self.footer = footer;
        footer.meta.ownership.meta.test_id = "wizard.footer";
        self.back_btn = try action(self, footer, "上一步", "wizard.back", 64, 34, false, self.locked, onBackClick, null);
        self.cancel_btn = try action(self, footer, "取消", "wizard.cancel", 52, 34, false, null, onCancelClick, null);
        try footer.appendChild(self.alloc, try ui.spacer(cx));
        self.test_btn = try action(self, footer, "测试连接", "wizard.test", 76, 34, false, self.test_action_disabled, onTestClick, null);
        self.save_only_btn = try action(self, footer, "仅保存", "wizard.save_only", 64, 34, false, self.save_disabled, onSaveOnlyClick, null);
        self.next1_btn = try action(self, footer, "下一步", "wizard.next.identity", 64, 34, true, self.next1_disabled, onNext1Click, null);
        self.next2_btn = try action(self, footer, "下一步", "wizard.next.route", 64, 34, true, self.next2_disabled, onNext2Click, null);
        self.save_btn = try action(self, footer, "保存并连接", "wizard.save", 88, 34, true, self.open_disabled, onSaveClick, null);
        try modal.body.appendChild(self.alloc, footer);
        const discard_footer = try ui.box(cx, S.footer(), .{});
        self.discard_footer = discard_footer;
        self.discard_continue = try action(self, discard_footer, "继续编辑", "wizard.discard.continue", 112, 34, false, null, onContinueEditing, null);
        try discard_footer.appendChild(self.alloc, try ui.spacer(cx));
        self.discard_confirm = try action(self, discard_footer, "放弃草稿", "wizard.discard.confirm", 112, 34, true, null, onDiscardConfirmed, null);
        try modal.body.appendChild(self.alloc, discard_footer);
        self.step = .protocol;
        try self.setAssets(self.assets);
        self.syncAll();
        self.applyStep();
        self.root.?.setHitTestVisible(false);
        self.root.?.setDisplay(.none);
        try cx.addAfterLayoutHook(self, viewportHook);
        try scope.onCleanup(RemoteEditor, self, removeViewportHook);
        _ = self.updateViewport();
        return if (modal.portaled) try ui.box(cx, .{ .width = .{ .px = 0 }, .height = .{ .px = 0 }, .display = .none }, .{}) else self.root.?;
    }

    fn releaseFieldFeedback(self: *RemoteEditor) void {
        if (!self.nodes_alive) return;
        // This guard scope is created before Input child scopes. Restore SDK
        // handlers while their nodes and edit states still exist.
        for (self.field_feedback.items) |feedback| feedback.releaseBlur();
    }

    fn removeViewportHook(self: *RemoteEditor) void {
        self.cx.removeAfterLayoutHook(self);
        if (self.test_source) |*source| source.deinit();
        self.releaseAssetValues();
        self.inputs.deinit(self.alloc);
        self.field_feedback.deinit(self.alloc);
        self.selects.deinit(self.alloc);
        self.buttons.deinit(self.alloc);
        self.editor_actions.deinit(self.alloc);
        for (self.owned_ids.items) |value| self.alloc.free(value);
        self.owned_ids.deinit(self.alloc);
    }

    fn releaseAssetValues(self: *RemoteEditor) void {
        for (self.asset_strings.items) |value| self.alloc.free(value);
        self.asset_strings.deinit(self.alloc);
        self.asset_strings = .empty;
    }
    fn ownAssetString(self: *RemoteEditor, text: []const u8) ![]const u8 {
        const value = try self.alloc.dupe(u8, text);
        errdefer self.alloc.free(value);
        try self.asset_strings.append(self.alloc, value);
        return value;
    }
    fn viewportHook(raw: *anyopaque, _: u8, _: bool) ui.AfterLayoutResult {
        const self: *RemoteEditor = @ptrCast(@alignCast(raw));
        // The retained logs ScrollArea must not publish interaction updates
        // after the whole wizard has closed underneath another modal.
        if (!self.isVisible()) return .done;
        for (self.selects.items) |select| {
            paintSelectTypography(select.trigger);
            paintSelectTypography(select.panel);
        }
        if (self.startup_textarea) |area| paintSelectTypography(area.input);
        for (self.inputs.items) |input| if (input.state.text_display_node) |text| paintSelectTypography(text);
        for ([_]?*ui.Node{ self.remember_checkbox, self.compression_checkbox }) |entry| if (entry) |checkbox| paintCheckboxLabels(checkbox);
        if (!self.embedded) {
            const parent_visible = !self.copy_open.?.peek();
            if (self.parent_presentation_visible != parent_visible) {
                if (!parent_visible) self.parent_barrier_color = self.root.?.getBackground();
                self.root.?.setBackground(if (parent_visible) self.parent_barrier_color else ui.Color.TRANSPARENT);
                self.modal.?.setDisplay(if (parent_visible) .flex else .none);
                self.parent_presentation_visible = parent_visible;
                return .needs_layout;
            }
        }
        if (self.copy_open.?.peek()) {
            var corrected = false;
            for ([_]?*ui.Node{ self.copy_dialog, self.copy_body }) |entry| if (entry) |node| {
                if (!std.meta.eql(node.style.padding, ui.Padding.all(0)) or node.style.gap != 0) {
                    node.setStyleInline(self.alloc, .{ .padding = .{}, .gap = 0 });
                    corrected = true;
                }
            };
            if (corrected) return .needs_layout;
        }
        if (self.validation_focus_group) |group| {
            self.validation_focus_group = null;
            const area = self.scrolls[0].?;
            area.state.content_height = area.content.globalRect().h;
            area.state.viewport_height = area.container.globalRect().h;
            ui.widgets.scrollIntoView(area.state, area.content, group, .nearest);
        }
        if (self.test_reveal_pending and self.step == .confirm and !self.discard_open) {
            self.test_reveal_pending = false;
            const area = self.scrolls[2].?;
            area.state.content_height = area.content.globalRect().h;
            area.state.viewport_height = area.container.globalRect().h;
            ui.widgets.scrollIntoView(area.state, area.content, self.review_test_card.?, .start);
        }
        self.updateTestScroll();
        if (self.updateViewport()) return .needs_layout;
        var route_changed = false;
        for (&self.route_previews) |*preview| route_changed = self.resizeRoutePreview(preview) or route_changed;
        if (route_changed) return .needs_layout;
        if (self.strict_focus_pending and self.step == .protocol and self.advanced_expanded) {
            self.strict_focus_pending = false;
            self.cx.setFocus(self.strict_checkbox.?);
            const scroll = self.scrolls[0].?;
            // This hook precedes the SDK's scrollbar before-render metric
            // update. Use the completed layout so the first focus request can
            // reach a just-expanded advanced card in this same frame.
            scroll.state.content_height = scroll.content.globalRect().h;
            scroll.state.viewport_height = scroll.container.globalRect().h;
            ui.widgets.scrollIntoView(scroll.state, scroll.content, self.strict_checkbox.?, .nearest);
        }
        return .done;
    }
    pub fn updateViewport(self: *RemoteEditor) bool {
        const compact = self.cx.viewport.width <= 860 or self.cx.viewport.height <= 480;
        const inset: f32 = if (compact) 18 else 20;
        const body_padding = ui.Padding{ .left = inset, .right = inset };
        var geometry_changed = false;
        if (self.body) |body| if (!std.meta.eql(body.style.padding, body_padding)) {
            body.setStyleInline(self.alloc, .{ .padding = body_padding, .gap = if (compact) 12 else 14 });
            for (self.scrolls, 0..) |slot, i| if (slot) |scroll| {
                const edge: f32 = if (compact) 0 else if (i <= 1) 4 else 0;
                scroll.content.setStyleInline(self.alloc, .{ .padding = .{ .left = edge, .right = edge, .bottom = if (compact) 12 else 20 } });
            };
            if (self.confirm_card) |review| review.setStyleInline(self.alloc, .{ .padding = .{ .left = if (compact) 0 else 4, .right = if (compact) 0 else 4 } });
            if (self.footer) |footer| footer.setStyleInline(self.alloc, .{ .height = .{ .px = if (compact) 54 else 62 }, .padding = .{ .left = if (compact) 18 else 24, .right = if (compact) 18 else 24, .top = if (compact) 10 else 14, .bottom = if (compact) 10 else 14 } });
            geometry_changed = true;
        };
        if (self.embedded) {
            const colors = S.theme.current();
            if (self.painted_colors == null or !std.meta.eql(self.painted_colors.?, colors)) self.retheme();
            return geometry_changed;
        }
        if (self.modal == null) return false;
        // Modal's deferred style host can initialise after the outer app mount.
        // Persist the caller's body override once that host is actually ready.
        if (self.header.?.parent) |modal_body| if (!std.meta.eql(modal_body.style.padding, ui.Padding.ZERO)) {
            modal_body.setStyleInline(self.alloc, S.modalBody());
            modal_body.markLayoutDirty();
            return true;
        };
        const available_w = @max(1, self.cx.viewport.width - 32);
        const available_h = @max(1, self.cx.viewport.height - @as(f32, if (compact) 48 else 32));
        const width = @min(S.width, available_w);
        const desired_h = self.preferredModalHeight();
        const height = @min(@min(desired_h, S.max_height), available_h);
        const changed = self.viewport_width != width or self.viewport_height != height or self.viewport_step != self.step;
        if (changed) {
            self.viewport_width = width;
            self.viewport_height = height;
            self.viewport_step = self.step;
            self.modal.?.setStyleInline(self.alloc, .{ .width = .{ .px = width }, .height = .{ .px = height } });
            for (&self.scrolls) |*slot| if (slot.*) |scroll| scroll.container.setStyleInline(self.alloc, S.scroll());
            self.modal.?.markLayoutDirty();
        }
        const colors = S.theme.current();
        if (self.painted_colors == null or !std.meta.eql(self.painted_colors.?, colors)) self.retheme();
        return changed or geometry_changed;
    }

    pub fn preferredModalHeight(self: *const RemoteEditor) f32 {
        return if (self.discard_open) (if (self.discard_expanded) S.discard_height else S.discard_height - 66) else S.max_height;
    }

    /// Presents the host's current global defaults. These are read-only facts,
    /// separate from the connection draft and any already-frozen probe source.
    /// May be called before mount; no placeholder measurements are inferred.
    pub fn setSshDefaults(self: *RemoteEditor, connect_timeout_sec: u16, keepalive_sec: u16) void {
        self.ssh_defaults = .{ .connect_timeout_sec = connect_timeout_sec, .keepalive_sec = keepalive_sec };
        self.refreshSshDefaults();
    }

    fn refreshSshDefaults(self: *RemoteEditor) void {
        const timeout_node = self.connect_timeout_fact orelse return;
        const keepalive_node = self.keepalive_fact orelse return;
        const defaults = self.ssh_defaults orelse return;
        var buffer: [32]u8 = undefined;
        timeout_node.setTextContent(self.alloc, std.fmt.bufPrint(&buffer, "{d} 秒", .{defaults.connect_timeout_sec}) catch return) catch return;
        keepalive_node.setTextContent(self.alloc, std.fmt.bufPrint(&buffer, "{d} 秒", .{defaults.keepalive_sec}) catch return) catch return;
        self.cx.requestRedraw();
    }

    /// Asset names must be unique. Pass the current registry as Draft views.
    pub fn setAssets(self: *RemoteEditor, assets: []const Draft) !void {
        for (assets, 0..) |asset, index| {
            const owner = asset.source_owner orelse return error.InvalidIdentity;
            if (@backingInt(owner.id) == 0 or owner.revision == 0) return error.InvalidIdentity;
            for (assets[0..index]) |previous| if (previous.source_owner.?.id == owner.id) return error.DuplicateConnectionId;
        }
        if (self.sig_copy_source) |selection| if (selection.get()) |value| {
            self.copy_source_text.?.set(value);
            selection.set(self.copy_source_text.?.get());
        };
        if (self.asset_options) |options| {
            const entries = try self.alloc.alloc(ui.widgets.SelectOption, assets.len);
            defer self.alloc.free(entries);
            // Equal list updates may retain the previous option records.
            // Their value and label strings therefore live with this editor,
            // including after the caller replaces its registry snapshot.
            for (assets, entries) |asset, *entry| {
                var buffer: [32]u8 = undefined;
                entry.* = .{
                    .value = try self.ownAssetString(try std.fmt.bufPrint(&buffer, "conn:{d}", .{@backingInt(asset.source_owner.?.id)})),
                    .label = try self.ownAssetString(asset.name),
                };
            }
            options.set(entries);
        }
        // Preserve selected names before caller releases the previous registry.
        if (self.root != null) for (0..8) |i| self.setJump(i, self.jump_values[i].?.get());
        self.assets = assets;
        self.resolveLoadedGroup();
        // The copy action is meaningful only when a real source host exists.
        if (assets.len == 0) self.closeCopy();
        if (self.root != null and self.topo_addr != null) {
            self.refreshEditorRows();
            self.refreshValidity();
            self.refreshSaveState();
        }
    }

    /// Registry group names are copied; include empty groups as well as hosts' groups.
    pub fn setGroups(self: *RemoteEditor, names: []const []const u8) !void {
        var options: std.ArrayList(ui.widgets.SelectOption) = .empty;
        defer options.deinit(self.alloc);
        try options.append(self.alloc, .{ .value = "", .label = "未分组" });
        for (names) |name| {
            if (name.len == 0) continue;
            var duplicate = false;
            for (options.items) |option| if (std.mem.eql(u8, option.value, name)) {
                duplicate = true;
                break;
            };
            if (duplicate) continue;
            const owned = try self.ownAssetString(name);
            try options.append(self.alloc, .{ .value = owned, .label = owned });
        }
        const current = self.sig_group.?.get();
        var found = current.len == 0;
        for (options.items) |option| if (std.mem.eql(u8, option.value, current)) {
            found = true;
            break;
        };
        if (!found) {
            const owned = try self.ownAssetString(current);
            try options.append(self.alloc, .{ .value = owned, .label = owned });
        }
        self.group_options.?.set(options.items);
    }
    fn resolveLoadedGroup(self: *RemoteEditor) void {
        if (!self.group_name_pending) return;
        const owner = self.source_owner orelse return;
        for (self.assets) |asset| if (std.meta.eql(asset.source_owner.?, owner)) {
            self.sig_group.?.set(asset.group orelse "");
            self.sig_group_selection.?.set(self.sig_group.?.get());
            self.group_name_pending = false;
            return;
        };
    }
    fn onGroupChanged(self: *RemoteEditor, value: ?[]const u8) void {
        if (self.isLocked()) return;
        self.group_name_pending = false;
        self.sig_group.?.set(value orelse "");
        self.onFieldChange("");
    }
    pub fn loadDraft(self: *RemoteEditor, draft: Draft) void {
        // Loading an existing host is the edit path.  A later save should
        // update that host unless the user explicitly picks another source
        // from the copy row after this load.
        self.copied_from_existing = false;
        self.validation_focus_group = null;
        for (self.field_feedback.items) |feedback| {
            feedback.touched = false;
            feedback.message.set("");
            feedback.resize(false);
        }
        self.strict_focus_pending = false;
        self.identity_expanded = true;
        self.auth_expanded = true;
        self.advanced_expanded = false;
        inline for (.{ Step.protocol, Step.form, Step.confirm }) |step_| self.scrollToTop(step_);
        self.save_failure = null;
        self.source_owner = draft.source_owner;
        self.furthest_step = .protocol;
        self.copy_source_owner = draft.copy_source_owner;
        self.strict_host_key_checking = draft.strict_host_key_checking;
        self.sig_strict.?.set(draft.strict_host_key_checking);
        self.sig_strict_policy.?.set(if (draft.strict_host_key_checking) "true" else "false");
        self.sig_compression.?.set(draft.compression);
        self.sig_protocol.?.set(if (draft.protocol == .sftp) "sftp" else "ssh");
        self.sig_name.?.set(draft.name);
        self.sig_host.?.set(draft.host);
        self.sig_user.?.set(draft.user);
        self.sig_group.?.set(draft.group orelse "");
        self.sig_group_selection.?.set(self.sig_group.?.get());
        // Envelope payloads deliberately omit shared registry group names.
        // Resolve that display value from the host projection once installed.
        self.group_name_pending = draft.source_owner != null and draft.group == null;
        self.resolveLoadedGroup();
        var group_names: std.ArrayList([]const u8) = .empty;
        defer group_names.deinit(self.alloc);
        for (self.group_options.?.get()) |option| group_names.append(self.alloc, option.value) catch {};
        self.setGroups(group_names.items) catch {};
        var buf: [32]u8 = undefined;
        self.sig_port.?.set(draft.formatPort(&buf));
        self.sig_password.?.set(draft.password orelse "");
        self.sig_save_password.?.set(draft.save_password);
        self.sig_key_path.?.set(draft.key_path orelse "");
        self.sig_key_passphrase.?.set(draft.key_passphrase orelse "");
        self.sig_encoding.?.set(draft.encoding);
        self.sig_terminal.?.set(draft.terminal_type);
        self.terminal_type_explicit = draft.terminal_type_explicit;
        self.sig_scrollback.?.set(std.fmt.bufPrint(&buf, "{d}", .{draft.scrollback}) catch "50000");
        self.sig_socks_port.?.set(std.fmt.bufPrint(&buf, "{d}", .{draft.socks_port}) catch "1080");
        self.sig_socks_bind.?.set(draft.socks_bind);
        self.socks_exit_text.?.set(if (draft.socks_exit) |index| std.fmt.bufPrint(&buf, "{d}", .{index}) catch "" else "");
        self.sig_socks_exit.?.set(if (draft.socks_exit != null) self.socks_exit_text.?.get() else null);
        self.protocol = draft.protocol;
        self.protocol_id = @tagName(draft.protocol);
        self.auth = draft.auth;
        self.keepalive = draft.keepalive;
        self.compression = draft.compression;
        self.compression_explicit = draft.compression_explicit;
        self.socks_enabled = draft.socks_enabled;
        self.socks_auto_start = draft.socks_auto_start;
        self.socks_max_connections = draft.socks_max_connections;
        self.jump_count = @min(8, @max(draft.route.len, draft.jump_chain.len));
        for (0..8) |i| {
            var id_buffer: [32]u8 = undefined;
            const value = if (i < draft.route.len)
                std.fmt.bufPrint(&id_buffer, "conn:{d}", .{@backingInt(draft.route[i])}) catch ""
            else if (i < draft.jump_chain.len)
                draft.jump_chain[i]
            else
                null;
            self.setJump(i, value);
        }
        self.command_count = @min(32, draft.startup_commands.len);
        self.startup_enabled = self.command_count > 0;
        for (self.command_values, 0..) |v, i| v.?.set(if (i < self.command_count) draft.startup_commands[i] else "");
        const startup = std.mem.join(self.alloc, "\n", draft.startup_commands) catch null;
        if (startup) |text| {
            defer self.alloc.free(text);
            self.sig_startup.?.set(text);
            self.syncStartup(text);
        }
        _ = self.advanceTestGeneration();
        if (self.draft_revision != 0) self.draft_revision = std.math.add(u64, self.draft_revision, 1) catch 0;
        self.clearTestProjection();
        self.test_logs_area.setDisplay(.none);
        self.test_log_text.setTextContent(self.alloc, "") catch {};
        self.setTestResult(.none);
        self.refreshEditorRows();
        self.syncAll();
        self.applyStep();
    }

    fn onCopy(self: *RemoteEditor, selected: ?[]const u8) void {
        const id = parseAssetValue(selected orelse return) catch return;
        for (self.assets) |asset| {
            if (asset.source_owner.?.id != id) continue;
            self.loadDraft(asset);
            self.copy_source_owner = asset.source_owner;
            self.source_owner = null;
            self.copied_from_existing = true;
            self.draft_id = allocateDraftId() catch {
                self.identity_exhausted = true;
                return;
            };
            self.sig_password.?.set("");
            self.sig_save_password.?.set(false);
            self.sig_key_passphrase.?.set("");
            const copy_name = std.fmt.allocPrint(self.alloc, "{s}-副本", .{asset.name}) catch return;
            defer self.alloc.free(copy_name);
            self.sig_name.?.set(copy_name);
            self.onFieldChange("");
            return;
        }
    }

    fn refreshEditorRows(self: *RemoteEditor) void {
        const has_jumps = self.jump_count > 0;
        self.refreshAccessChoices();
        self.refreshEditorActions();
        const route_error = self.routeError();
        if (self.route_empty_hint) |node| {
            node.setTextContent(self.alloc, route_error) catch {};
            node.setDisplay(if (route_error.len != 0) .flex else .none);
        }
        // The name/address/authentication form is always required.  Only the
        // optional topology is conditional on selecting at least one hop.
        inline for (.{ "step2_topology", "step2_topology_title" }) |field_name| if (@field(self, field_name)) |node| node.setDisplay(if (has_jumps) .flex else .none);
        if (self.direct_label) |node| node.setDisplay(if (has_jumps) .none else .flex);
        if (self.jump_list) |list| {
            var values: [8][]const u8 = undefined;
            var count: usize = 0;
            for (self.jump_values[0..self.jump_count]) |value| if (value.?.get()) |name| {
                values[count] = name;
                count += 1;
            };
            list.set(values[0..count]);
        }
        for (self.jump_rows, 0..) |row, i| if (row) |node| node.setDisplay(if (i < self.jump_count) .flex else .none);
        for (self.command_rows, 0..) |row, i| if (row) |node| node.setDisplay(if (i < self.command_count and self.startup_enabled) .flex else .none);
        var choices: [9]ui.widgets.SelectOption = undefined;
        choices[0] = .{ .value = "", .label = "链路末端" };
        var choice_count: usize = 1;
        const indices = [_][]const u8{ "0", "1", "2", "3", "4", "5", "6", "7" };
        for (0..8) |i| {
            if (self.jump_actions[i]) |actions| actions.setDisplay(if (self.editing_order) .flex else .none);
            if (self.jump_arrows[i]) |arrow| arrow.setDisplay(if (i < self.jump_count) .flex else .none);
            if (self.jump_arrow_labels[i]) |label| label.setTextContent(self.alloc, if (i + 1 == self.jump_count) "Direct-TCPIP" else "SSH Tunnel") catch {};
            const selected = self.jump_values[i].?.get();
            var asset: ?Draft = null;
            if (selected) |value| for (self.assets) |candidate| {
                const id = parseAssetValue(value) catch break;
                if (candidate.source_owner.?.id == id) {
                    asset = candidate;
                    break;
                }
            };
            if (self.jump_addresses[i]) |node| {
                var buffer: [160]u8 = undefined;
                node.setTextContent(self.alloc, if (asset) |a| std.fmt.bufPrint(&buffer, "{s}@{s}:{d}", .{ a.user, a.host, a.port }) catch a.host else "") catch {};
            }
            if (self.jump_users[i]) |node| node.setTextContent(self.alloc, if (asset != null) "待连接" else "") catch {};
            if (i < self.jump_count and asset != null) {
                const label = std.fmt.bufPrint(&self.exit_labels[i], "{d} · {s}", .{ i + 1, asset.?.name }) catch asset.?.name;
                choices[choice_count] = .{ .value = indices[i], .label = label };
                choice_count += 1;
            }
        }
        if (self.exit_options) |options| options.set(choices[0..choice_count]);
        if (self.sig_socks_exit.?.get()) |index| {
            const parsed = std.fmt.parseInt(usize, index, 10) catch self.jump_count;
            if (index.len > 0 and (parsed >= self.jump_count or self.jump_values[parsed].?.get() == null)) self.sig_socks_exit.?.set(null);
        }
        if (self.topology_chain) |chain| {
            chain.style.width = .{ .px = @max(674, 117 * @as(f32, @floatFromInt(self.jump_count + 2)) + 68 * @as(f32, @floatFromInt(self.jump_count + 1))) };
            chain.markLayoutDirty();
        }
        if (self.socks_details) |node| node.setDisplay(if (self.socks_enabled) .flex else .none);
        if (self.commands_details) |node| node.setDisplay(if (self.protocol == .ssh) .flex else .none);
        if (self.advanced_body) |node| node.setDisplay(if (self.advanced_expanded) .flex else .none);
        if (self.advanced_chevron) |node| paintIcon(node, if (self.advanced_expanded) ui.icons.chevron_down else ui.icons.chevron_right, 10, S.theme.current().fg_1);
        if (self.identity_body) |node| node.setDisplay(if (self.identity_expanded) .flex else .none);
        if (self.auth_body) |node| node.setDisplay(if (self.auth_expanded) .flex else .none);
        if (self.route_body) |node| node.setDisplay(if (self.route_expanded) .flex else .none);
        if (self.route_editor) |node| node.setDisplay(if (has_jumps) .flex else .none);
        for (&self.route_previews) |*preview| self.refreshRoutePreview(preview);
        self.refreshTestProjection() catch {};
    }
    fn refreshAccessChoices(self: *RemoteEditor) void {
        for (self.route_choices, 0..) |entry, index| if (entry) |choice| {
            const selected = (self.jump_count > 0) == (index == 1);
            choice.style.set(S.accessChoice(false));
            choice.highlight.setBackground(S.theme.current().selection);
            choice.highlight.setDisplay(if (selected) .flex else .none);
            choice.title.setTextColor(if (selected) S.theme.current().accent else S.theme.current().fg_1);
            choice.detail.setTextColor(S.theme.current().fg_2);
            if (choice.root.behavior.interaction.a11y) |*access| access.pressed = selected;
        };
    }
    fn refreshEditorActions(self: *RemoteEditor) void {
        const locked = self.isLocked();
        if (self.jump_add_disabled) |value| value.set(locked or self.jump_count >= 8);
        for (self.editor_actions.items) |action_| action_.disabled.set(locked or switch (action_.kind) {
            .jump_up => action_.index == 0 or action_.index >= self.jump_count,
            .jump_down => action_.index + 1 >= self.jump_count,
            .jump_remove => action_.index >= self.jump_count,
            .command_remove => action_.index >= self.command_count,
        });
    }
    fn onAccessDirect(self: *RemoteEditor) void {
        if (self.isLocked() or self.jump_count == 0) return;
        self.jump_count = 0;
        for (0..8) |i| self.setJump(i, null);
        self.refreshEditorRows();
        self.onFieldChange("");
    }
    fn onAccessJump(self: *RemoteEditor) void {
        if (self.isLocked() or self.jump_count != 0) return;
        self.onAddJump();
    }
    fn onOrder(self: *RemoteEditor) void {
        if (self.isLocked()) return;
        self.editing_order = !self.editing_order;
        self.refreshEditorRows();
    }
    fn onAddJump(self: *RemoteEditor) void {
        if (self.isLocked() or self.jump_count == 8) return;
        self.jump_count += 1;
        self.editing_order = true;
        self.refreshEditorRows();
        self.onFieldChange("");
    }
    fn onAddCommand(self: *RemoteEditor) void {
        if (self.isLocked() or self.command_count == 32) return;
        self.startup_enabled = true;
        self.command_count += 1;
        self.refreshEditorRows();
        self.onFieldChange("");
    }
    fn onStartup(self: *RemoteEditor) void {
        if (self.isLocked()) return;
        self.startup_enabled = !self.startup_enabled;
        self.refreshEditorRows();
        self.onFieldChange("");
    }
    fn onSocks(self: *RemoteEditor) void {
        self.socks_enabled = !self.socks_enabled;
        self.refreshEditorRows();
        self.onFieldChange("");
    }
    fn onSocksAuto(self: *RemoteEditor) void {
        self.socks_auto_start = !self.socks_auto_start;
        self.refreshEditorRows();
        self.onFieldChange("");
    }
    fn setJump(self: *RemoteEditor, index: usize, name: ?[]const u8) void {
        self.jump_text[index].?.set(name orelse "");
        self.jump_values[index].?.set(if (name != null) self.jump_text[index].?.get() else null);
    }

    fn onJumpList(self: *RemoteEditor, names: []const []const u8) void {
        if (self.isLocked()) return;
        const count = @min(names.len, 8);
        const owned = dupeStrings(self.alloc, names[0..count]) catch return;
        defer freeStrings(self.alloc, owned);
        self.jump_count = count;
        for (0..8) |i| self.setJump(i, if (i < count) owned[i] else null);
        self.refreshEditorRows();
        self.onFieldChange("");
    }
    fn onSelection(self: *RemoteEditor, _: ?[]const u8) void {
        self.refreshEditorRows();
        self.onFieldChange("");
    }

    /// 打开向导（回到第 1 步；已填字段保留便于修改）。
    pub fn show(self: *RemoteEditor) void {
        const r = self.root orelse return;
        self.discard_open = false;
        self.step = .protocol;
        self.syncAll();
        self.applyStep();
        r.setHitTestVisible(true);
        self.open.?.set(true);
        r.setDisplay(.flex);
    }

    /// 全量重刷动态部件：信号可能被调用方直接写入（外部写入不触发
    /// on_change），show/mount 时统一同步按钮可用态、radio、开关、
    /// 拓扑目标节点与测试结果行。
    fn syncAll(self: *RemoteEditor) void {
        self.refreshValidity();
        self.refreshAuth();
        self.refreshTopoTarget();
        self.refreshEditorRows();
        self.refreshProtocols();
        self.refreshTestRow();
    }

    /// 关闭向导（不触发回调；保存/取消路径已自带 hide + on_result）。
    pub fn hide(self: *RemoteEditor) void {
        self.closeCopy();
        _ = self.advanceTestGeneration();
        const r = self.root orelse return;
        r.setHitTestVisible(false);
        self.open.?.set(false);
        r.setDisplay(.none);
    }

    /// Escape and the close button share the same cancellation callback.
    pub fn cancel(self: *RemoteEditor) void {
        if (self.copy_open.?.peek()) {
            self.closeCopy();
            return;
        }
        self.onCancelClick();
    }

    pub fn isVisible(self: *const RemoteEditor) bool {
        return if (self.root) |node| node.style.display != .none else false;
    }

    pub fn setTestProgress(self: *RemoteEditor, generation: u64, draft_id: u64, revision: u64, text: []const u8) bool {
        if (generation == 0 or self.identity_exhausted or generation != self.test_generation or draft_id != self.draft_id or revision != self.draft_revision) return false;
        if (self.test_source != null) return false;
        for (self.test_rows) |row| row.node.setDisplay(.none);
        self.test_log_text.setDisplay(.flex);
        self.test_log_text.setTextContent(self.alloc, text) catch return false;
        self.test_logs_area.setDisplay(if (text.len != 0) .flex else .none);
        return true;
    }

    /// The host copies these original-job facts before the Job is retired.
    /// A different operation cannot replace the current generation's owner.
    pub fn setTestSnapshot(self: *RemoteEditor, snapshot: TestProgress.Snapshot) !bool {
        if (!snapshot.valid() or self.identity_exhausted or snapshot.generation != self.test_generation or snapshot.draft_id != self.draft_id or snapshot.draft_revision != self.draft_revision) return false;
        if (self.test_source) |*previous| {
            const old = &previous.value;
            if (!old.key.eql(snapshot.key)) return false;
            if (old.finished and !snapshot.finished) return false;
            if (old.cleanup == .released and snapshot.cleanup != .released) return false;
            if (old.resources.revision > snapshot.resources.revision) return false;
            if (old.journal.count != 0 and (snapshot.journal.count == 0 or old.journal.entries[old.journal.count - 1].sequence > snapshot.journal.entries[snapshot.journal.count - 1].sequence)) return false;
        }
        const first = self.test_source == null;
        if (self.test_source) |*current| {
            if (current.value.hops.len != snapshot.hops.len) return false;
            // Endpoints are immutable for this Job, even if a caller supplies
            // fresh registry strings while updating its journal/ledger.
            const frozen_hops = current.value.hops;
            current.value = snapshot;
            current.value.hops = frozen_hops;
        } else self.test_source = try TestProgress.Owned.init(self.alloc, snapshot);
        self.updateTestScroll();
        const appended = self.test_history.ingest(&self.test_source.?.value);
        if (!self.test_following) self.test_new_logs += appended;
        if (appended != 0) self.test_copy_result = null;
        if (first) {
            self.test_reveal_pending = true;
            self.logs_open.?.set(true);
            self.test_following = true;
            self.test_new_logs = 0;
        }
        if (snapshot.finished) {
            self.test_kind = if (snapshot.failure == null and !snapshot.cancelled) .ok else .fail;
            self.copyDetail(if (snapshot.cancelled) "测试已取消" else if (snapshot.failure != null) "验证失败" else "验证通过");
        }
        try self.refreshTestProjection();
        self.refreshTestRow();
        self.cx.requestRedraw();
        return true;
    }

    /// Scroll state is owned by the mount scope; callers may use it for a
    /// keyboard-accessible "focus next" action without moving the modal.
    pub fn scrollState(self: *RemoteEditor, step: Step) ?*ui.widgets.scroll_area.ScrollState {
        return switch (step) {
            .protocol => self.step1_scroll_state,
            .form => self.step2_scroll_state,
            .confirm => if (self.scrolls[2]) |scroll| scroll.state else null,
        };
    }

    pub fn scrollToBottom(self: *RemoteEditor, step: Step) void {
        const state = self.scrollState(step) orelse return;
        const content = switch (step) {
            .protocol => self.step1_scroll_content,
            .form => self.step2_scroll_content,
            .confirm => if (self.scrolls[2]) |scroll| scroll.content else null,
        } orelse return;
        ui.widgets.setScrollY(state, content, state.maxScrollY());
    }

    pub fn scrollToTop(self: *RemoteEditor, step: Step) void {
        const state = self.scrollState(step) orelse return;
        const content = switch (step) {
            .protocol => self.step1_scroll_content,
            .form => self.step2_scroll_content,
            .confirm => if (self.scrolls[2]) |scroll| scroll.content else null,
        } orelse return;
        ui.widgets.setScrollY(state, content, 0);
    }

    /// 回填测试结果（探测回调完成后由调用方调用；detail 会被拷贝）。
    pub fn setTestResultFor(self: *RemoteEditor, generation: u64, state: TestState) bool {
        if (generation == 0 or self.identity_exhausted or generation != self.test_generation) return false;
        self.setTestResult(state);
        return true;
    }

    pub fn setTestResultForDraft(self: *RemoteEditor, generation: u64, draft_id: u64, revision: u64, state: TestState) bool {
        if (draft_id == 0 or revision == 0 or draft_id != self.draft_id or revision != self.draft_revision) return false;
        return self.setTestResultFor(generation, state);
    }

    pub fn setStrictHostKeyChecking(self: *RemoteEditor, strict: bool) void {
        if (self.strict_host_key_checking == strict) return;
        self.strict_host_key_checking = strict;
        self.sig_strict.?.set(strict);
        self.sig_strict_policy.?.set(if (strict) "true" else "false");
        self.onFieldChange("");
    }

    pub fn setTestResult(self: *RemoteEditor, state: TestState) void {
        switch (state) {
            .none => {
                self.test_kind = .none;
                self.test_detail_len = 0;
            },
            .pending => {
                self.test_kind = .pending;
                self.test_detail_len = 0;
            },
            .ok => |detail| {
                self.test_kind = .ok;
                self.copyDetail(detail);
            },
            .fail => |detail| {
                self.test_kind = .fail;
                self.copyDetail(detail);
            },
        }
        self.refreshTestRow();
        if (self.cancel_requested and self.test_kind != .pending) {
            self.cancel_requested = false;
            self.finishDiscard();
        }
    }

    fn testDetail(self: *const RemoteEditor) []const u8 {
        return self.test_detail_buf[0..self.test_detail_len];
    }

    fn copyDetail(self: *RemoteEditor, detail: []const u8) void {
        const n = @min(detail.len, self.test_detail_buf.len);
        @memcpy(self.test_detail_buf[0..n], detail[0..n]);
        self.test_detail_len = n;
    }

    /// 从输入信号组装 Draft 快照（切片借用信号缓冲）。
    pub fn currentDraft(self: *RemoteEditor) Draft {
        const group = self.sig_group.?.get();
        const password = self.sig_password.?.get();
        const key_path = self.sig_key_path.?.get();
        const key_passphrase = self.sig_key_passphrase.?.get();
        var jump_len: usize = 0;
        for (self.jump_values[0..self.jump_count]) |value| if (value.?.get()) |selected| {
            const id = parseAssetValue(selected) catch @as(identity.ConnectionId, @fromBackingInt(0));
            self.route_ids[jump_len] = id;
            self.jumps[jump_len] = selected;
            for (self.assets) |asset| if (asset.source_owner.?.id == id) {
                self.jumps[jump_len] = asset.name;
                break;
            };
            jump_len += 1;
        };
        var command_len: usize = 0;
        if (self.startup_enabled) for (self.command_values[0..self.command_count]) |value| {
            const text = trim(value.?.get());
            if (text.len == 0) continue;
            self.commands[command_len] = text;
            command_len += 1;
        };
        return .{
            .draft_id = self.draft_id,
            .revision = self.draft_revision,
            .source_owner = self.source_owner,
            .copy_source_owner = self.copy_source_owner,
            .strict_host_key_checking = self.strict_host_key_checking,
            .route = self.route_ids[0..jump_len],
            .jump_chain = self.jumps[0..jump_len],
            .startup_commands = self.commands[0..command_len],
            .socks_enabled = self.socks_enabled,
            .socks_auto_start = self.socks_auto_start,
            .socks_max_connections = self.socks_max_connections,
            .socks_port = parsePort(self.sig_socks_port.?.get()),
            .socks_bind = self.sig_socks_bind.?.get(),
            .socks_exit = if (self.sig_socks_exit.?.get()) |value| std.fmt.parseInt(usize, value, 10) catch null else null,
            .terminal_type = self.sig_terminal.?.get(),
            .terminal_type_explicit = self.terminal_type_explicit,
            .scrollback = std.fmt.parseInt(u32, self.sig_scrollback.?.get(), 10) catch 50000,
            .name = self.sig_name.?.get(),
            .protocol = self.protocol,
            .host = self.sig_host.?.get(),
            .port = parsePort(self.sig_port.?.get()),
            .user = self.sig_user.?.get(),
            .group = if (group.len > 0) group else null,
            .auth = self.auth,
            .password = if (password.len > 0) password else null,
            .save_password = self.sig_save_password.?.get(),
            .key_path = if (key_path.len > 0) key_path else null,
            .key_passphrase = if (key_passphrase.len > 0) key_passphrase else null,
            .keepalive = self.keepalive,
            .compression = self.compression,
            .compression_explicit = self.compression_explicit,
            .encoding = self.sig_encoding.?.get(),
        };
    }

    fn routeError(self: *RemoteEditor) []const u8 {
        for (self.jump_values[0..self.jump_count], 0..) |value, i| {
            const id = parseAssetValue(value.?.get() orelse return "请选择 SSH 跳板主机，或切换为从本机直接连接。") catch return "跳板主机已失效，请重新选择。";
            if (self.source_owner) |owner| if (owner.id == id) return "目标主机不能同时作为自身的跳板。";
            for (self.jump_values[0..i]) |previous| if (previous.?.get()) |v| if ((parseAssetValue(v) catch continue) == id) return "同一主机不能重复出现在跳板路径中，请选择其他主机。";
            var found = false;
            for (self.assets) |asset| if (asset.source_owner.?.id == id and asset.protocol == .ssh) {
                found = true;
                break;
            };
            if (!found) return "跳板主机不可用，请重新选择已保存的 SSH 主机。";
        }
        return "";
    }
    fn validBasicDraft(self: *RemoteEditor) bool {
        for (self.field_feedback.items) |feedback| if (feedback.kind != .key_path and feedback.errorMessage().len != 0) return false;
        if (self.identity_exhausted) return false;
        for (self.jump_values[0..self.jump_count], 0..) |value, i| {
            const id = parseAssetValue(value.?.get() orelse return false) catch return false;
            var found = false;
            for (self.assets) |asset| if (asset.source_owner.?.id == id and asset.protocol == .ssh) {
                found = true;
                break;
            };
            if (!found) return false;
            if (self.source_owner) |owner| if (owner.id == id) return false;
            for (self.jump_values[0..i]) |previous| if (previous.?.get()) |v| if ((parseAssetValue(v) catch return false) == id) return false;
        }
        const draft = self.currentDraft();
        draft.validate() catch return false;
        return true;
    }

    fn validIdentityDraft(self: *RemoteEditor) bool {
        if (self.startup_overflow and self.protocol == .ssh) return false;
        var draft = self.currentDraft();
        // Identity editing remains reachable while an incomplete route is
        // being corrected in step two.
        draft.route = &.{};
        draft.jump_chain = &.{};
        draft.validate() catch return false;
        if (draft.auth == .key and (draft.key_path == null or trim(draft.key_path.?).len == 0)) return false;
        return true;
    }
    fn validDraft(self: *RemoteEditor) bool {
        if (!self.validIdentityDraft() or !self.validBasicDraft()) return false;
        for (self.jump_values[0..self.jump_count]) |value| if (value.?.get() == null) return false;
        return true;
    }

    // ── 步进与刷新 ───────────────────────────────────────────────────

    fn applyStep(self: *RemoteEditor) void {
        if (self.stepper) |stepper| stepper.setDisplay(if (self.discard_open) .none else .flex);
        self.discard_scroll.?.container.setDisplay(if (self.discard_open) .flex else .none);
        self.discard_footer.?.setDisplay(if (self.discard_open) .flex else .none);
        self.footer.?.setDisplay(if (self.discard_open) .none else .flex);
        for (self.scrolls, 0..) |slot, i| if (slot) |scroll| scroll.container.setDisplay(if (!self.discard_open and i == @backingInt(self.step)) .flex else .none);
        const review = self.step == .confirm;
        self.back_btn.?.setDisplay(if (self.step != .protocol) .flex else .none);
        self.next1_btn.?.setDisplay(if (self.step == .protocol) .flex else .none);
        self.next2_btn.?.setDisplay(if (self.step == .form) .flex else .none);
        self.save_only_btn.?.setDisplay(if (review) .flex else .none);
        self.save_btn.?.setDisplay(if (review) .flex else .none);
        self.test_btn.?.setDisplay(if (review) .flex else .none);
        self.paintSteps();
        self.refreshValidity();
        if (review) self.refreshSummary();
        _ = self.updateViewport();
        self.cx.requestRedraw();
    }

    fn paintSteps(self: *RemoteEditor) void {
        for (self.step_buttons, 0..) |slot, i| if (slot) |node| {
            const current = i == @backingInt(self.step);

            var invalid = false;
            if (i == 0) for (self.field_feedback.items) |feedback| {
                if (feedback.touched and feedback.errorMessage().len != 0) {
                    invalid = true;
                    break;
                }
            };
            const style = S.step(current);
            self.step_styles[i].?.set(style);
            // Keep the public inline layer in sync with the state; an initial
            // current-step override must not pin step one after navigation.
            node.setStyleInline(self.alloc, style);
            node.setOpacity(1);
            self.step_numbers[i].?.setStyleInline(self.alloc, S.number(current));
            self.step_digits[i].?.setDisplay(if (invalid) .none else .flex);
            self.step_digits[i].?.setTextColor(if (current) S.theme.current().accent_ink else S.theme.current().fg_2);
            self.step_checks[i].?.setDisplay(if (invalid) .flex else .none);
            paintIcon(self.step_checks[i].?, if (invalid) ui.icons.circle_alert else ui.icons.check, 13, if (invalid) S.theme.current().danger_ink else S.theme.current().ok);
            if (invalid) self.step_numbers[i].?.setBackground(S.theme.current().well);
            self.step_titles[i].?.setTextColor(S.stepTitle(current).color);
            self.step_details[i].?.setTextColor(S.theme.current().fg_2);
        };
    }

    fn goNext(self: *RemoteEditor) void {
        if (self.isLocked()) return;
        if (stepAfter(self.step)) |next| {
            self.step = next;
            if (@backingInt(next) > @backingInt(self.furthest_step)) self.furthest_step = next;
            self.applyStep();
        }
    }

    fn goBack(self: *RemoteEditor) void {
        if (self.isLocked()) return;
        if (stepBefore(self.step)) |previous| {
            self.step = previous;
            self.applyStep();
        }
    }

    fn refreshValidity(self: *RemoteEditor) void {
        for (self.step_disabled, 0..) |slot, i| if (slot) |signal| {
            const allowed = i == 0 or (i <= @backingInt(self.furthest_step) and (if (i == 1) self.validIdentityDraft() else self.validDraft()));
            signal.set(self.isLocked() or !allowed);
            self.step_details[i].?.setTextContent(self.alloc, if (i == @backingInt(self.step)) "当前步骤" else if (allowed) "可返回修改" else "待完成") catch {};
        };
        if (self.next1_disabled) |v| v.set(self.isLocked() or !self.validIdentityDraft());
        if (self.next2_disabled) |v| v.set(self.isLocked() or !self.validDraft());
        self.refreshSaveState();
        for (self.field_feedback.items) |feedback| feedback.refresh();
        self.paintSteps();
    }

    fn refreshAuth(self: *RemoteEditor) void {
        self.cred_pw_row.?.setDisplay(if (self.auth == .password) .flex else .none);
        self.cred_key_row.?.setDisplay(if (self.auth == .key) .flex else .none);
        self.agent_notice.?.setDisplay(if (self.auth == .agent) .flex else .none);
        self.sig_auth.?.set(@tagName(self.auth));
    }

    fn refreshTopoTarget(self: *RemoteEditor) void {
        var buf: [96]u8 = undefined;
        const host = self.sig_host.?.get();
        const user = self.sig_user.?.get();
        const name = self.sig_name.?.get();
        const port = parsePort(self.sig_port.?.get());
        const addr = if (host.len > 0)
            (std.fmt.bufPrint(&buf, "{s}@{s}:{d}", .{ user, host, port }) catch host)
        else
            "host:port";
        self.topo_addr.?.setTextContent(self.alloc, addr) catch {};
        self.topo_name.?.setTextContent(self.alloc, if (name.len > 0) name else "目标主机") catch {};
        self.topo_user.?.setTextContent(self.alloc, "待连接") catch {};
    }

    /// 测试结果行（第 2 步 footer）+ 确认卡测试行 + 保存按钮可用态。
    fn refreshTestRow(self: *RemoteEditor) void {
        const line = formatTestLine(switch (self.test_kind) {
            .none => .none,
            .pending => .pending,
            .ok => .{ .ok = self.testDetail() },
            .fail => .{ .fail = self.testDetail() },
        }, &self.line_buf);
        const colors = S.theme.current();
        const color = switch (self.test_kind) {
            .ok => colors.ok,
            .fail => colors.danger,
            .pending => colors.warn,
            .none => colors.fg_3,
        };
        if (self.test_status_icon) |icon| {
            const asset = switch (self.test_kind) {
                .ok => ui.icons.circle_check,
                .fail => ui.icons.circle_alert,
                .pending => ui.icons.loader,
                .none => ui.icons.circle,
            };
            if (asset.icon_id) |id| if (asset.pickRep(16)) |rep| icon.setIcon(.{ .icon_id = id, .rep = rep, .tint = color });
        } else self.res_dot.?.setBackground(color);
        self.res_text.?.setTextColor(color);
        self.res_text.?.setTextContent(self.alloc, line) catch {};
        self.refreshTestProjection() catch {};
        self.refreshDiscard();
        self.refreshValidity();
    }

    pub fn canSave(self: *RemoteEditor) bool {
        if (self.saving or self.discard_open or self.test_kind == .pending or self.on_result == null or !self.validDraft()) return false;
        _ = self.currentDraft().toHostConfig() catch return false;
        return true;
    }

    pub fn canOpen(self: *RemoteEditor) bool {
        return self.canSave() and !self.sftpRouteUnavailable();
    }

    fn sftpRouteUnavailable(self: *const RemoteEditor) bool {
        return self.protocol == .sftp and self.jump_count != 0;
    }

    fn refreshSaveState(self: *RemoteEditor) void {
        const busy = self.isLocked();
        if (self.locked) |v| v.set(busy);
        if (self.save_disabled) |v| v.set(!self.canSave());
        if (self.open_disabled) |v| v.set(!self.canOpen());
        if (self.test_kind != .pending) if (self.test_action_disabled) |v| v.set(self.saving or !self.validDraft() or self.sftpRouteUnavailable());
        if (self.route_hint) |hint| {
            hint.setDisplay(if (self.sftpRouteUnavailable()) .flex else .none);
        }
        if (self.copy_open_disabled) |v| v.set(busy or self.assets.len == 0);
        if (self.copy_disabled) |v| {
            const selected = self.sig_copy_source.?.get();
            var matches = false;
            if (selected) |value| {
                const id = parseAssetValue(value) catch @as(identity.ConnectionId, @fromBackingInt(0));
                for (self.assets) |asset| if (asset.source_owner.?.id == id) {
                    matches = true;
                    break;
                };
            }
            v.set(busy or !matches);
        }
        if (self.next1_disabled) |v| v.set(busy or !self.validIdentityDraft());
        if (self.next2_disabled) |v| v.set(busy or !self.validDraft());
        self.paintButtons();
        const editing = self.source_owner != null;
        if (self.title) |title| title.setTextContent(self.alloc, if (editing) "编辑连接" else "新建连接") catch {};
        self.refreshProtocolAppearance();
        for (self.buttons.items) |button| {
            if (button.node == self.save_only_btn) {
                if (button.label) |label| label.setTextContent(self.alloc, if (editing) "保存更改" else "仅保存") catch {};
                if (button.node.behavior.interaction.a11y) |*a11y| a11y.label = if (editing) "保存更改" else "仅保存";
            } else if (button.node == self.save_btn) {
                if (button.label) |label| label.setTextContent(self.alloc, "保存并连接") catch {};
                if (button.node.behavior.interaction.a11y) |*a11y| a11y.label = "保存并连接";
            }
        }
        if (self.save_error_node) |node| {
            node.setDisplay(if (self.save_failure != null) .flex else .none);
            if (self.save_failure) |failure| {
                const message = if (failure.stage == .open) "配置已保存，但无法打开会话。草稿已保留，可重试。" else switch (failure.cause) {
                    error.FileConflict, error.RevisionConflict => "主机配置已被修改。当前草稿已保留，请重新载入后再保存。",
                    error.AccessDenied, error.PermissionDenied => "无法写入主机配置。请检查文件权限后重试。",
                    error.CredentialDenied, error.CredentialLocked, error.CredentialUnavailable, error.CredentialStorageFailure => "无法保存密码到系统钥匙串。草稿已保留，请解锁或授权钥匙串后重试，也可取消保存密码。",
                    error.OutOfMemory => "内存不足。连接草稿已保留，请重试。",
                    else => "保存连接配置失败。草稿已保留，请重试。",
                };
                node.setTextContent(self.alloc, message) catch {};
            }
        }
        self.cx.requestRedraw();
    }

    /// 确认卡摘要行（进入第 3 步时改写）。
    fn refreshSummary(self: *RemoteEditor) void {
        if (self.test_source == null) self.refreshRoutePreview(&self.route_previews[1]);
        const draft = self.currentDraft();
        var path = std.Io.Writer.Allocating.init(self.alloc);
        defer path.deinit();
        for (draft.jump_chain, 0..) |name, i| {
            if (i != 0) path.writer.writeAll(" → ") catch {};
            path.writer.writeAll(name) catch {};
        }
        const route = if (path.writer.buffered().len != 0) path.writer.buffered() else "直连";
        if (self.review_path) |label| label.setTextContent(self.alloc, route) catch {};
        const subtitle = std.fmt.allocPrint(self.alloc, "独立连接会话 · {s}", .{draft.group orelse "未分组"}) catch return;
        defer self.alloc.free(subtitle);
        self.summary_identity.?.setTextContent(self.alloc, subtitle) catch {};
        self.summary_name.?.setTextContent(self.alloc, draft.name) catch {};
        var endpoint_buffer: [512]u8 = undefined;
        const endpoint = std.fmt.bufPrint(&endpoint_buffer, "{s}:{d}", .{ draft.host, draft.port }) catch "";
        const values = [_][]const u8{
            if (draft.protocol == .sftp) "SFTP" else "SSH",
            endpoint,
            draft.user,
            switch (draft.auth) {
                .key => "私钥文件",
                .agent => "SSH Agent",
                .password => if (draft.save_password) "密码 · 保存后自动使用" else "密码 · 仅本次使用",
            },
            if (draft.strict_host_key_checking) "严格验证主机密钥" else "严格验证已关闭",
        };
        for (values, self.summary_values) |value, node| node.?.setTextContent(self.alloc, value) catch {};
        var options_buffer: [128]u8 = undefined;
        const options = if (draft.protocol == .ssh and draft.startup_commands.len != 0) std.fmt.bufPrint(&options_buffer, "启动命令 {d} 条", .{draft.startup_commands.len}) catch "" else "";
        self.summary_options.?.setTextContent(self.alloc, options) catch {};
        self.summary_options.?.setDisplay(if (options.len != 0) .flex else .none);
        const count = draft.jump_chain.len + 2;
        for (self.summary_route_nodes, 0..) |node, i| {
            node.?.setDisplay(if (i < count) .flex else .none);
            if (i >= count) continue;
            const name = if (i == 0) "本机" else if (i == count - 1) draft.host else draft.jump_chain[i - 1];
            const caption = if (i == 0) "客户端" else if (i == count - 1) (if (draft.protocol == .sftp) "SFTP · 目标" else "SSH · 目标") else std.fmt.bufPrint(&options_buffer, "SSH · 第 {d} 跳", .{i}) catch "SSH 跳板";
            self.summary_route_names[i].?.setTextContent(self.alloc, name) catch {};
            self.summary_route_captions[i].?.setTextContent(self.alloc, caption) catch {};
        }
        for (self.summary_route_arrows, 0..) |arrow, i| arrow.?.setDisplay(if (i < count - 1) .flex else .none);
        self.refreshTestRow();
    }

    // ── 事件处理 ─────────────────────────────────────────────────────

    fn validateFields(self: *RemoteEditor) bool {
        var first: ?*FieldFeedback = null;
        for (self.field_feedback.items) |feedback| {
            feedback.touched = true;
            feedback.refresh();
            if (first == null and feedback.message.get().len != 0) first = feedback;
        }
        self.paintSteps();
        if (first) |feedback| {
            self.cx.setFocus(feedback.input.input_container);
            self.validation_focus_group = feedback.group;
            if (feedback.kind == .key_path) self.auth_expanded = true else self.identity_expanded = true;
            self.refreshEditorRows();
            return false;
        }
        return true;
    }

    fn onFieldSubmit(self: *RemoteEditor, _: []const u8) void {
        if (self.isLocked() or self.step != .protocol) return;
        self.onNext1Click();
    }

    fn onNext1Click(self: *RemoteEditor) void {
        if (self.isLocked()) return;
        if (!self.validateFields() or !self.validIdentityDraft()) return;
        self.goNext();
    }

    fn onNext2Click(self: *RemoteEditor) void {
        if (self.isLocked() or !self.validDraft()) return;
        self.goNext();
    }

    fn onBackClick(self: *RemoteEditor) void {
        self.goBack();
    }

    fn onCancelClick(self: *RemoteEditor) void {
        if (self.saving or self.cancel_requested) return;
        if (self.discard_open) {
            self.onContinueEditing();
            return;
        }
        if (!self.hasDraftInput()) {
            self.onDiscardConfirmed();
            return;
        }
        self.discard_open = true;
        self.discard_expanded = true;
        self.updateDiscardExpansion();
        self.refreshDiscard();
        self.applyStep();
        self.cx.setFocus(self.discard_continue.?);
    }

    fn hasDraftInput(self: *RemoteEditor) bool {
        const d = self.currentDraft();
        if (d.name.len != 0 or d.host.len != 0 or d.user.len != 0 or d.password != null or d.key_path != null or d.key_passphrase != null or d.group != null) return true;
        return d.protocol != .ssh or d.auth != .password or d.port != 22 or !d.keepalive or d.compression or !d.strict_host_key_checking or d.socks_enabled or d.route.len != 0 or d.startup_commands.len != 0 or !std.mem.eql(u8, d.encoding, "UTF-8") or !std.mem.eql(u8, d.terminal_type, "xterm-256color") or d.scrollback != 50000;
    }

    fn onContinueEditing(self: *RemoteEditor) void {
        if (self.cancel_requested) return;
        self.discard_open = false;
        self.applyStep();
        self.cx.setFocus(self.cancel_btn.?);
    }

    fn onDiscardToggle(self: *RemoteEditor) void {
        if (!self.discard_open or self.cancel_requested) return;
        self.discard_expanded = !self.discard_expanded;
        self.updateDiscardExpansion();
        _ = self.updateViewport();
        self.cx.requestRedraw();
    }

    fn updateDiscardExpansion(self: *RemoteEditor) void {
        const card = self.discard_card orelse return;
        for (card.children.items) |child| if (child != self.discard_heading) child.setDisplay(if (self.discard_expanded) .flex else .none);
        card.setStyleInline(self.alloc, .{ .height = .{ .px = if (self.discard_expanded) 118 else 52 } });
        if (self.discard_chevron) |node| paintIcon(node, if (self.discard_expanded) ui.icons.chevron_down else ui.icons.chevron_right, 16, S.theme.current().fg_2);
    }

    fn refreshDiscard(self: *RemoteEditor) void {
        if (self.discard_name == null) return;
        var buffer: [512]u8 = undefined;
        const name = self.sig_name.?.get();
        self.discard_name.?.setTextContent(self.alloc, std.fmt.bufPrint(&buffer, "{s} · 当前草稿尚未保存", .{if (name.len == 0) @as([]const u8, "未命名连接") else name}) catch "当前草稿尚未保存") catch {};
        const status: []const u8 = if (self.test_source) |source| switch (source.value.cleanup) {
            .released => "本次测试已结束。",
            .unknown => "测试清理结果尚未确认。",
            else => if (self.test_kind == .pending) "放弃后将取消正在进行的测试。" else "测试清理尚未结束。",
        } else if (self.test_kind == .pending) "放弃后将取消正在进行的测试。" else "尚未保存或打开此连接。";
        self.discard_status.?.setTextContent(self.alloc, status) catch {};
    }

    fn finishDiscard(self: *RemoteEditor) void {
        self.discard_open = false;
        self.hide();
        self.loadDraft(.{});
    }

    fn onDiscardConfirmed(self: *RemoteEditor) void {
        if (self.saving or self.cancel_requested) return;
        const wait_for_release = self.test_kind == .pending;
        if (self.on_result) |cb| _ = cb(self.result_ctx, .cancelled) catch |err| {
            self.save_failure = .{ .stage = .save, .cause = err };
            self.refreshSaveState();
            return;
        };
        if (wait_for_release and self.test_kind == .pending and self.on_result != null) {
            // Retain the exact probe stamp until the host publishes its final
            // released result. Advancing it now would strand the pending lock.
            self.discard_open = false;
            self.applyStep();
            self.cancel_requested = true;
            self.res_text.?.setTextContent(self.alloc, "正在取消测试 · 等待资源释放") catch {};
            self.refreshSaveState();
        } else self.finishDiscard();
    }

    fn onTestClick(self: *RemoteEditor) void {
        if (self.test_kind == .pending) {
            const source = if (self.test_source) |*owned| &owned.value else return;
            if (self.test_cancel_sent or source.cancelled or source.cleanup != .not_started) return;
            const callback = self.on_cancel_test orelse return;
            self.test_cancel_sent = true;
            callback(self.cancel_test_ctx orelse return, source.key);
            self.refreshTestRow();
            return;
        }
        if (self.isLocked()) return;
        if (!self.validDraft() or self.sftpRouteUnavailable()) return;
        if (!self.advanceTestGeneration()) {
            self.refreshValidity();
            return;
        }
        if (self.test_source) |*source| source.deinit();
        self.test_source = null;
        self.test_cancel_sent = false;
        self.test_filter = null;
        self.test_copy_result = null;
        self.test_following = true;
        self.review_expanded = false;
        self.test_kind = .pending;
        self.test_reveal_pending = true;
        self.test_detail_len = 0;
        self.refreshTestRow();
        if (self.on_test) |cb| {
            var draft = self.currentDraft();
            cb(self.test_ctx, &draft);
        } else {
            // A missing production probe cannot claim a successful test.
            self.setTestResult(.{ .fail = "连接探测未配置" });
        }
    }

    fn onSaveClick(self: *RemoteEditor) void {
        self.save(false);
    }
    fn onSaveOnlyClick(self: *RemoteEditor) void {
        self.save(true);
    }
    fn save(self: *RemoteEditor, only: bool) void {
        if (!self.canSave() or (!only and !self.canOpen())) return;
        const callback = self.on_result orelse return;
        const draft = self.currentDraft();
        self.saving = true;
        self.save_failure = null;
        self.refreshSaveState();
        defer {
            self.saving = false;
            self.refreshSaveState();
        }
        const receipt = (callback(self.result_ctx, if (only) .{ .save_only = draft } else .{ .saved = draft }) catch |err| {
            self.save_failure = .{ .stage = .save, .cause = err };
            return;
        }) orelse {
            self.save_failure = .{ .stage = .save, .cause = error.MissingSaveReceipt };
            return;
        };
        self.source_owner = receipt.owner;
        self.copied_from_existing = false;
        if (receipt.open_failure) |err| {
            self.save_failure = .{ .stage = .open, .cause = err };
            return;
        }
        self.hide();
    }

    fn onAuthChanged(self: *RemoteEditor, value: ?[]const u8) void {
        if (self.isLocked()) {
            self.sig_auth.?.set(@tagName(self.auth));
            return;
        }
        self.auth = std.meta.stringToEnum(Auth, value orelse "") orelse return;
        self.onFieldChange("");
        self.refreshAuth();
    }

    fn onAuthPasswordClick(self: *RemoteEditor) void {
        if (self.isLocked()) return;
        self.auth = .password;
        self.onFieldChange("");
        self.refreshAuth();
    }

    fn onAuthKeyClick(self: *RemoteEditor) void {
        if (self.isLocked()) return;
        self.auth = .key;
        self.onFieldChange("");
        self.refreshAuth();
    }

    fn onAuthAgentClick(self: *RemoteEditor) void {
        if (self.isLocked()) return;
        self.auth = .agent;
        self.onFieldChange("");
        self.refreshAuth();
    }

    fn refreshProtocols(self: *RemoteEditor) void {
        self.sig_protocol.?.set(self.protocol_id);
    }

    fn refreshProtocolAppearance(self: *RemoteEditor) void {
        const asset = if (self.protocol == .sftp) ui.icons.folder_open else ui.icons.terminal;
        if (self.protocol_icon) |icon| paintIcon(icon, asset, 18, S.theme.current().accent);
        if (self.protocol_select_icon) |icon| paintIcon(icon, asset, 16, S.theme.current().fg_2);
        if (self.summary_icon) |icon| paintIcon(icon, asset, 20, S.theme.current().accent);
    }
    fn onProtocolChanged(self: *RemoteEditor, selected: ?[]const u8) void {
        if (self.isLocked()) return;
        const value = selected orelse return;
        const protocol = std.meta.stringToEnum(Protocol, value) orelse return;
        if (protocol != .ssh and protocol != .sftp) return;
        self.sig_password.?.set("");
        self.sig_save_password.?.set(false);
        self.sig_key_passphrase.?.set("");
        self.protocol_id = value;
        self.protocol = protocol;
        self.onFieldChange("");
        self.applyStep();
    }

    fn onAdvancedToggle(self: *RemoteEditor) void {
        if (self.isLocked()) return;
        self.advanced_expanded = !self.advanced_expanded;
        self.refreshEditorRows();
    }

    fn isLocked(self: *const RemoteEditor) bool {
        return self.saving or self.test_kind == .pending or self.discard_open;
    }

    fn openChanged(self: *RemoteEditor, value: bool) void {
        if (value) return;
        for (self.inputs.items) |input| if (input.state.focused and input.state.imeIsComposing()) {
            input.state.cancelImeComposition();
            self.cx.requestRedraw();
            return;
        };
        self.onCancelClick();
    }

    fn onIdentityToggle(self: *RemoteEditor) void {
        if (self.isLocked()) return;
        self.identity_expanded = !self.identity_expanded;
        self.refreshEditorRows();
    }
    fn onAuthToggle(self: *RemoteEditor) void {
        if (self.isLocked()) return;
        self.auth_expanded = !self.auth_expanded;
        self.refreshEditorRows();
    }
    fn onRouteToggle(self: *RemoteEditor) void {
        if (self.isLocked()) return;
        self.route_expanded = !self.route_expanded;
        self.refreshEditorRows();
    }
    fn onCopyToggle(self: *RemoteEditor) void {
        if (self.isLocked()) return;
        if (self.assets.len == 0) return;
        self.copy_expanded = true;
        self.copy_open.?.set(true);
    }
    fn closeCopy(self: *RemoteEditor) void {
        self.copy_expanded = false;
        if (self.copy_open) |open| open.set(false);
    }
    fn onCopyCancel(self: *RemoteEditor) void {
        self.closeCopy();
    }
    fn onCopyOpenChanged(self: *RemoteEditor, opened: bool) void {
        if (!opened) self.closeCopy();
    }
    fn onCopySourceChanged(self: *RemoteEditor, _: ?[]const u8) void {
        self.refreshSaveState();
    }
    fn onCopyApply(self: *RemoteEditor) void {
        if (self.isLocked()) return;
        self.closeCopy();
        self.onCopy(self.sig_copy_source.?.get());
    }
    fn onPickKey(self: *RemoteEditor) void {
        if (self.isLocked()) return;
        var buffer: [4096]u8 = undefined;
        const path = ui.platform_services.openFilePanel(self.cx.system_sdk, &buffer) orelse return;
        self.sig_key_path.?.set(path);
        self.onFieldChange("");
    }
    fn onSavePasswordChanged(self: *RemoteEditor, checked: bool) void {
        if (self.isLocked()) return;
        self.sig_save_password.?.set(checked);
        self.onFieldChange("");
    }
    fn onStrictPolicyChanged(self: *RemoteEditor, value: ?[]const u8) void {
        if (self.isLocked()) return;
        self.setStrictHostKeyChecking(value == null or !std.mem.eql(u8, value.?, "false"));
    }
    fn syncStartup(self: *RemoteEditor, text: []const u8) void {
        var lines = std.mem.splitScalar(u8, text, '\n');
        var count: usize = 0;
        self.startup_overflow = false;
        while (lines.next()) |line| {
            const command = trim(line);
            if (command.len == 0) continue;
            if (count == self.command_values.len) {
                self.startup_overflow = true;
                break;
            }
            self.command_values[count].?.set(command);
            count += 1;
        }
        self.command_count = count;
        self.startup_enabled = count != 0;
        self.startup_error.?.set(if (self.startup_overflow) "最多支持 32 条启动命令，请减少后继续。" else "");
    }
    fn onStartupTextChanged(self: *RemoteEditor, text: []const u8) void {
        if (self.isLocked()) return;
        self.syncStartup(text);
        self.onFieldChange("");
    }
    fn onStrictChanged(self: *RemoteEditor, checked: bool) void {
        if (self.isLocked()) return;
        self.setStrictHostKeyChecking(checked);
    }
    fn onCompressionChanged(self: *RemoteEditor, checked: bool) void {
        if (self.isLocked()) return;
        self.compression = checked;
        self.compression_explicit = true;
        self.onFieldChange("");
    }
    fn onSummaryModify(self: *RemoteEditor) void {
        if (self.isLocked()) return;
        self.step = .protocol;
        self.strict_focus_pending = false;
        self.refreshEditorRows();
        self.applyStep();
        const area = self.scrolls[0].?;
        ui.widgets.setScrollY(area.state, area.content, 0);
        for (self.field_feedback.items) |feedback| if (feedback.kind == .name) {
            self.cx.setFocus(feedback.input.input_container);
            break;
        };
    }
    fn onSummaryRouteModify(self: *RemoteEditor) void {
        if (self.isLocked()) return;
        self.step = .form;
        self.applyStep();
    }
    fn onReviewToggle(self: *RemoteEditor) void {
        self.review_expanded = !self.review_expanded;
        self.refreshTestProjection() catch {};
        self.cx.requestRedraw();
    }
    fn onLogsToggle(self: *RemoteEditor) void {
        self.logs_open.?.set(!self.logs_open.?.get());
        self.logs_scroll.?.setDisplay(if (self.logs_open.?.get()) .flex else .none);
        self.test_follow_row.?.setDisplay(if (self.logs_open.?.get()) .flex else .none);
        if (self.test_disclosure_icon) |icon| {
            const asset = if (self.logs_open.?.get()) ui.icons.chevron_up else ui.icons.chevron_down;
            if (asset.icon_id) |id| if (asset.pickRep(16)) |rep| icon.setIcon(.{ .icon_id = id, .rep = rep, .tint = S.theme.current().fg_2 });
        }
    }
    fn onLogsCopy(self: *RemoteEditor) void {
        const text = self.test_log_text.getText() orelse return;
        self.test_copy_result = ui.platform_services.clipboardSetText(self.cx.system_sdk, text.content);
        self.refreshTestProjection() catch {};
    }
    fn onTestFilterAll(self: *RemoteEditor) void {
        self.test_filter = null;
        self.test_copy_result = null;
        self.test_following = true;
        self.test_new_logs = 0;
        self.refreshTestProjection() catch {};
    }
    fn onTestFollow(self: *RemoteEditor) void {
        if (self.test_source != null and self.test_source.?.value.finished) {
            self.test_following = false;
            if (self.test_scroll) |scroll| {
                ui.widgets.setScrollY(scroll.state, scroll.content, 0);
                self.cx.setFocus(scroll.container);
            }
            return;
        }
        if (self.test_following) self.test_following = false else {
            self.test_following = true;
            self.test_new_logs = 0;
        }
        self.refreshTestProjection() catch {};
        self.updateTestScroll();
    }
    fn updateTestScroll(self: *RemoteEditor) void {
        const scroll = self.test_scroll orelse return;
        const y = scroll.state.scroll_y;
        const max = scroll.state.maxScrollY();
        if (y < self.test_last_scroll - 0.5 and y < max - 1) self.test_following = false;
        if (self.test_source != null and self.logs_open.?.get() and self.test_following) {
            // This hook runs before SDK metrics; use the actual finished layout.
            scroll.state.content_height = scroll.content.globalRect().h;
            scroll.state.viewport_height = scroll.container.globalRect().h;
            ui.widgets.setScrollY(scroll.state, scroll.content, scroll.state.maxScrollY());
        }
        self.test_last_scroll = scroll.state.scroll_y;
        if (self.test_follow_label) |label| {
            var buffer: [64]u8 = undefined;
            label.setTextContent(self.alloc, if (self.test_source != null and self.test_source.?.value.finished) "查看记录" else if (self.test_following) "跟随中" else if (self.test_new_logs != 0) std.fmt.bufPrint(&buffer, "{d} 条新日志 ↓", .{self.test_new_logs}) catch "跳到底部" else "跳到底部") catch {};
        }
    }
    fn clearTestProjection(self: *RemoteEditor) void {
        if (self.test_source) |*source| source.deinit();
        self.test_source = null;
        self.test_history = .{};
        self.test_filter = null;
        self.test_cancel_sent = false;
        self.test_copy_result = null;
        self.test_following = true;
        self.test_new_logs = 0;
        for (self.test_actions) |ctx| if (ctx) |action_ctx| {
            action_ctx.key = null;
        };
        for (self.test_rows) |row| row.node.setDisplay(.none);
    }
    fn refreshTestProjection(self: *RemoteEditor) !void {
        const pending = self.test_kind == .pending;
        const source = if (self.test_source) |*owned| &owned.value else null;
        if (self.summary_details) |node| node.setDisplay(.flex);
        if (self.review_test_card) |node| node.setDisplay(if (self.test_kind != .none) .flex else .none);
        if (self.review_body) |node| node.setDisplay(if (self.review_expanded) .flex else .none);
        if (self.review_disclosure) |node| paintIcon(node, if (self.review_expanded) ui.icons.chevron_down else ui.icons.chevron_right, 16, S.theme.current().fg_3);
        self.test_action_disabled.?.set(if (pending) self.test_cancel_sent or self.on_cancel_test == null or source == null or source.?.cancelled or source.?.cleanup != .not_started else self.saving or !self.validDraft() or self.sftpRouteUnavailable());
        for (self.buttons.items) |*button| if (button.node == self.test_btn) {
            const unavailable = self.sftpRouteUnavailable() and !pending;
            const label: []const u8 = if (pending) (if (self.test_cancel_sent or (source != null and source.?.cancelled)) "正在取消" else "取消测试") else if (unavailable) "检测 SFTP · 不可用" else if (self.test_kind != .none) "重新测试" else if (self.protocol == .sftp) "检测 SFTP" else "测试连接";
            button.width = if (unavailable) S.unavailable_test_width else S.test_action_width;
            button.height = 34;
            const style = S.button(button.width, button.height, false);
            button.style.set(style);
            button.node.setStyleInline(self.alloc, style);
            if (button.label) |node| try node.setTextContent(self.alloc, label);
            if (button.node.behavior.interaction.a11y) |*a11y| a11y.label = label;
        };
        for (self.test_stages) |row| row.node.setDisplay(.none);
        if (source == null) return;
        var buffer: [1024]u8 = undefined;
        try self.res_text.?.setTextContent(self.alloc, source.?.summary(&buffer));
        const color = if (source.?.cleanup == .unknown) S.theme.current().warn else if (source.?.failure != null and !source.?.cancelled) S.theme.current().danger else if (source.?.finished and !source.?.cancelled) S.theme.current().ok else if (source.?.cancelled) S.theme.current().fg_2 else S.theme.current().accent;
        self.res_text.?.setTextColor(color);
        if (self.test_status_icon) |icon| _ = icon.setTint(color);
        for (source.?.hops, 0..) |hop, i| {
            const row = self.test_stages[i];
            row.node.setDisplay(.flex);
            try row.title.setTextContent(self.alloc, try std.fmt.bufPrint(&buffer, "第 {d} 跳 · {s}", .{ i + 1, hop.name }));
            var state_buffer: [256]u8 = undefined;
            const state_text = source.?.node(i, &state_buffer);
            try row.detail.setTextContent(self.alloc, try std.fmt.bufPrint(&buffer, "{s}@{s}:{d} · {s}", .{ hop.user, hop.host, hop.port, state_text }));
            const last = source.?.latest(i);
            const failed = last != null and last.?.status == .failed;
            const done = source.?.finished and source.?.failure == null and !source.?.cancelled;
            const checking = !source.?.finished and !source.?.cancelled and last != null and last.?.status == .started;
            try row.mark.setTextContent(self.alloc, if (failed) "×" else if (done) "✓" else if (checking) "◌" else "○");
            row.mark.setTextColor(if (failed) S.theme.current().danger_ink else if (done) S.theme.current().ok else if (checking) S.theme.current().accent_ink else S.theme.current().fg_2);
        }
        try self.review_path.?.setTextContent(self.alloc, if (pending) "检测中 · 详情" else "检测结果 · 详情");
        var preview = &self.route_previews[1];
        _ = self.resizeRoutePreview(preview);
        for (preview.nodes, 0..) |optional, index| {
            const node = optional orelse continue;
            const hop: ?usize = if (index == 0) null else if (index == 9) source.?.hops.len - 1 else if (index < source.?.hops.len) index - 1 else null;
            const visible = index == 0 or index == 9 or (index < source.?.hops.len);
            node.setDisplay(if (visible) .flex else .none);
            if (self.test_actions[index]) |ctx| ctx.key = source.?.key;
            if (hop) |i| {
                const value = source.?.hops[i];
                try preview.names[index].?.setTextContent(self.alloc, value.name);
                try preview.addresses[index].?.setTextContent(self.alloc, try std.fmt.bufPrint(&buffer, "{s}@{s}:{d}", .{ value.user, value.host, value.port }));
                try preview.users[index].?.setTextContent(self.alloc, source.?.node(i, &buffer));
                const last = source.?.latest(i);
                preview.users[index].?.setTextColor(if (last != null and last.?.status == .failed) S.theme.current().danger else if (source.?.finished and source.?.failure == null and !source.?.cancelled) S.theme.current().ok else if (last != null and last.?.status == .started and source.?.cleanup == .not_started) S.theme.current().accent else S.theme.current().fg_2);
                node.setBackground(if (self.test_filter == i) S.theme.current().selection else S.theme.current().well);
            }
        }
        for (preview.arrows, 0..) |node, index| node.?.setDisplay(if (index < source.?.hops.len) .flex else .none);
        self.test_logs_area.setDisplay(.flex);
        self.logs_scroll.?.setDisplay(if (self.logs_open.?.get()) .flex else .none);
        self.test_follow_row.?.setDisplay(if (self.logs_open.?.get()) .flex else .none);
        try self.test_filter_label.?.setTextContent(self.alloc, if (self.test_filter) |hop| std.fmt.bufPrint(&buffer, "第{d}跳", .{hop + 1}) catch "节点" else "全部节点");
        try self.refreshTestLogs();
        self.updateTestScroll();
    }
    fn refreshTestLogs(self: *RemoteEditor) !void {
        const source = if (self.test_source) |*owned| &owned.value else return;
        var plain = std.Io.Writer.Allocating.init(self.alloc);
        defer plain.deinit();
        var index: usize = 0;
        for (self.test_history.records[0..self.test_history.count]) |record| {
            if (self.test_filter) |hop| if (hop != record.entry.hop) continue;
            const entry = record.entry;
            const row = self.test_rows[index];
            var buffer: [256]u8 = undefined;
            const elapsed = @divTrunc(@max(0, entry.timestamp_ns - record.origin_ns), std.time.ns_per_ms);
            try row.text[0].setTextContent(self.alloc, try std.fmt.bufPrint(&buffer, "+{d}ms", .{elapsed}));
            try row.text[1].setTextContent(self.alloc, try std.fmt.bufPrint(&buffer, "第{d}跳", .{entry.hop + 1}));
            try row.text[2].setTextContent(self.alloc, TestProgress.shortPhase(entry.phase));
            try row.text[3].setTextContent(self.alloc, TestProgress.eventResult(entry));
            const color = switch (entry.status) {
                .failed => S.theme.current().danger,
                .started => S.theme.current().accent,
                .succeeded => S.theme.current().ok,
                .cancelled => S.theme.current().fg_2,
            };
            row.text[0].setTextColor(S.theme.current().fg_2);
            row.text[1].setTextColor(S.theme.current().fg_2);
            row.text[2].setTextColor(color);
            row.text[3].setTextColor(color);
            row.node.setDisplay(.flex);
            try plain.writer.print("尝试 {d} / +{d}ms / 第{d}跳 / {s} / {s}\n", .{ record.key.attempt_id.?, elapsed, entry.hop + 1, TestProgress.shortPhase(entry.phase), TestProgress.eventResult(entry) });
            index += 1;
        }
        for (self.test_rows[index..]) |row| row.node.setDisplay(.none);
        if (self.test_history.dropped != 0) try plain.writer.print("更早的 {d} 条日志已省略。\n", .{self.test_history.dropped});
        if (source.cleanup == .unknown or source.cleanup == .releasing) for (source.resources.resources[0..source.resources.hop_count], 0..) |resources, hop| for (resources) |resource| {
            if (resource.state != .absent and resource.state != .released) try plain.writer.print("第{d}跳资源：{s}\n", .{ hop + 1, switch (resource.state) {
                .owned => @as([]const u8, "仍由本次测试持有"),
                .releasing => "正在释放",
                .unknown => "待核实",
                else => unreachable,
            } });
        };
        try self.test_log_text.setTextContent(self.alloc, plain.writer.buffered());
        self.test_log_text.setDisplay(.none);
        var buffer: [192]u8 = undefined;
        const hint = if (self.test_copy_result) |ok| (if (ok) @as([]const u8, "已复制") else "复制失败，请重试") else if (source.finished) "本次已结束 · 日志保留" else try std.fmt.bufPrint(&buffer, "{s} · 本次尝试 #{d}{s}", .{ if (self.test_following) @as([]const u8, "实时跟随") else "已暂停跟随", source.key.attempt_id.?, if (self.test_history.dropped != 0) @as([]const u8, " · 更早日志已省略") else "" });
        try self.test_follow_hint.?.setTextContent(self.alloc, hint);
    }

    fn resizeRoutePreview(self: *RemoteEditor, preview: *RoutePreview) bool {
        const row = preview.row orelse return false;
        const count = if (preview == &self.route_previews[1] and self.test_source != null) self.test_source.?.value.hops.len + 1 else self.jump_count + 2;
        const available = @max(@as(f32, 0), row.parent.?.globalRect().w);
        const natural: f32 = 146 * @as(f32, @floatFromInt(count)) + 24 * @as(f32, @floatFromInt(count - 1));
        const width = @max(available, natural);
        if (row.style.width == .px and row.style.width.px == width) return false;
        row.setStyleInline(self.alloc, .{ .width = .{ .px = width }, .gap = 6 });
        return true;
    }

    fn refreshRoutePreview(self: *RemoteEditor, preview: *RoutePreview) void {
        if (preview.row == null) return;
        _ = self.resizeRoutePreview(preview);
        for (preview.nodes, 0..) |node, i| {
            const visible = i == 0 or i == 9 or (i >= 1 and i <= self.jump_count);
            node.?.setDisplay(if (visible) .flex else .none);
            if (i >= 1 and i <= self.jump_count) {
                const id = parseAssetValue(self.jump_values[i - 1].?.get() orelse "") catch @as(identity.ConnectionId, @fromBackingInt(0));
                var selected: ?Draft = null;
                for (self.assets) |asset| if (asset.source_owner.?.id == id) {
                    selected = asset;
                    break;
                };
                var buffer: [256]u8 = undefined;
                preview.names[i].?.setTextContent(self.alloc, if (selected) |a| a.name else "选择跳板") catch {};
                preview.addresses[i].?.setTextContent(self.alloc, if (selected) |a| std.fmt.bufPrint(&buffer, "{s}@{s}:{d}", .{ a.user, a.host, a.port }) catch a.host else "") catch {};
                preview.users[i].?.setTextContent(self.alloc, if (selected != null) "待连接" else "") catch {};
            }
        }
        for (preview.arrows, 0..) |node, i| node.?.setDisplay(if (i <= self.jump_count) .flex else .none);
        var buffer: [256]u8 = undefined;
        preview.names[9].?.setTextContent(self.alloc, if (self.sig_name.?.get().len != 0) self.sig_name.?.get() else "目标主机") catch {};
        preview.addresses[9].?.setTextContent(self.alloc, std.fmt.bufPrint(&buffer, "{s}@{s}:{s}", .{ self.sig_user.?.get(), self.sig_host.?.get(), self.sig_port.?.get() }) catch self.sig_host.?.get()) catch {};
        preview.users[9].?.setTextContent(self.alloc, "待连接") catch {};
    }

    fn paintButtons(self: *RemoteEditor) void {
        for (self.buttons.items) |button| {
            var style = if (button.width == 0) S.disclosure() else S.button(button.width, button.height, button.primary);
            if (button.node == self.discard_confirm) {
                style.background = S.theme.current().danger;
                button.node.setStyleInline(self.alloc, .{ .background = S.theme.current().danger });
            }
            const review_link = if (button.node.meta.ownership.meta.test_id) |id| std.mem.eql(u8, id, "wizard.review.modify") or std.mem.eql(u8, id, "wizard.review.route.modify") else false;
            if (button.quiet or review_link) style.background = ui.Color.TRANSPARENT;
            button.style.set(style);
            if (button.label) |label| label.setTextColor(if (review_link) S.theme.current().accent else if (button.width == 0) S.theme.current().fg_1 else S.action(button.primary).color);
            if (button.icon) |icon| _ = icon.setTint(S.theme.current().fg_2);
        }
        self.refreshAuth();
        self.refreshAccessChoices();
        self.refreshEditorActions();
        for (self.field_feedback.items) |feedback| feedback.repaint();
    }

    fn retheme(self: *RemoteEditor) void {
        self.painted_colors = S.theme.current();
        if (self.footer) |footer| footer.setBackground(S.theme.current().surface_2);
        if (self.discard_footer) |footer| footer.setBackground(S.theme.current().surface_2);
        self.modal.?.setBackground(S.theme.current().overlay);
        if (self.route_empty_hint) |node| node.setTextColor(S.theme.current().danger_ink);
        for (self.jump_rows) |node| if (node) |row| row.setBackground(S.theme.current().well);
        for (self.editor_actions.items) |action_| if (action_.icon) |icon| {
            _ = icon.setTint(S.theme.current().fg_3);
        };
        if (self.review_test_card) |card| card.setBackground(S.theme.current().well);
        for ([_]?*ui.Node{self.discard_card}) |node| if (node) |card| card.setBackground(S.theme.current().surface_2);
        for (self.inputs.items) |input| {
            input.input_container.setStyleInline(self.alloc, S.input());
            input.state.tokens = self.cx.tokens;
            input.state.dirty = true;
        }
        for (self.selects.items) |select| select.trigger.setBackground(S.theme.current().well);
        for ([_]?*ui.Node{ self.remember_checkbox, self.compression_checkbox }) |entry| if (entry) |checkbox| paintCheckboxLabels(checkbox);
        if (self.startup_textarea) |area| {
            area.state.tokens = self.cx.tokens;
            area.state.dirty = true;
            area.input.markLayoutDirty();
            area.input.setBackground(S.theme.current().well);
        }
        if (self.copy_dialog) |dialog| dialog.setBackground(S.theme.current().overlay);
        if (self.title) |title| title.setTextColor(S.theme.current().fg_1);
        if (self.discard_card) |card| for (card.children.items) |child| {
            if (child.getText() != null) child.setTextColor(if (child == self.discard_name) S.theme.current().fg_1 else S.theme.current().fg_2);
        };
        if (self.summary_card) |card| card.setBackground(S.theme.current().well);
        if (self.summary_route_card) |card| card.setBackground(S.theme.current().well);
        self.paintSteps();
        self.test_logs_area.setBackground(S.theme.current().well);
        for (&self.route_previews) |*preview| for (preview.addresses) |node| if (node) |address| address.setTextColor(S.theme.current().fg_2);
        self.paintButtons();
        for (&self.route_previews) |*preview| for (preview.nodes) |node| if (node) |n| n.setBackground(S.theme.current().well);
        self.refreshTestRow();
        self.cx.requestRedraw();
    }

    fn advanceTestGeneration(self: *RemoteEditor) bool {
        if (self.identity_exhausted) return false;
        self.test_generation = std.math.add(u64, self.test_generation, 1) catch {
            self.identity_exhausted = true;
            return false;
        };
        return true;
    }

    /// 任一输入变化：刷新下一步可用态与拓扑目标节点；旧测试结果作废。
    fn onFieldChange(self: *RemoteEditor, _: []const u8) void {
        if (self.isLocked()) return;
        self.save_failure = null;
        self.clearTestProjection();
        self.test_log_text.setTextContent(self.alloc, "") catch {};
        self.test_logs_area.setDisplay(.none);
        _ = self.advanceTestGeneration();
        if (self.draft_revision != 0) self.draft_revision = std.math.add(u64, self.draft_revision, 1) catch 0;
        self.refreshValidity();
        self.refreshTopoTarget();
        if (self.test_kind != .none) {
            self.test_kind = .none;
            self.test_detail_len = 0;
            self.refreshTestRow();
        }
        self.refreshSaveState();
    }
};

// View nodes are retained for all three steps. Changing a step never replaces
// an editor or a draft signal; SDK slots/results are the only widget access.
const ButtonPaint = struct { node: *ui.Node, label: ?*ui.Node, icon: ?*ui.Node, style: *ui.Signal(ui.BoxStyle), width: f32, height: f32, primary: bool, quiet: bool = false };
const RoutePreview = struct {
    row: ?*ui.Node = null,
    nodes: [10]?*ui.Node = @splat(null),
    names: [10]?*ui.Node = @splat(null),
    addresses: [10]?*ui.Node = @splat(null),
    users: [10]?*ui.Node = @splat(null),
    arrows: [9]?*ui.Node = @splat(null),
};
const TestLogRow = struct { node: *ui.Node, text: [4]*ui.Node };
const TestStageRow = struct { node: *ui.Node, mark: *ui.Node, title: *ui.Node, detail: *ui.Node };
const TestHopAction = struct {
    wizard: *RemoteEditor,
    index: usize,
    key: ?TestProgress.operations.OperationKey = null,
    fn cleanup(self: *TestHopAction) void {
        self.wizard.alloc.destroy(self);
    }
    fn click(self: *TestHopAction) void {
        const source = if (self.wizard.test_source) |*owned| &owned.value else return;
        if (self.key == null or !self.key.?.eql(source.key)) return;
        const hop: ?usize = if (self.index == 0) null else if (self.index == 9) source.hops.len - 1 else if (self.index < source.hops.len) self.index - 1 else return;
        self.wizard.test_filter = hop;
        self.wizard.test_following = true;
        self.wizard.test_new_logs = 0;
        self.wizard.test_copy_result = null;
        self.wizard.refreshTestProjection() catch {};
    }
};
const StepAction = struct {
    wizard: *RemoteEditor,
    step: Step,
    fn cleanup(self: *StepAction) void {
        self.wizard.alloc.destroy(self);
    }
    fn click(self: *StepAction) void {
        const w = self.wizard;
        if (w.isLocked() or @backingInt(self.step) > @backingInt(w.furthest_step)) return;
        if (self.step == .form and !w.validIdentityDraft()) return;
        if (self.step == .confirm and !w.validDraft()) return;
        w.step = self.step;
        w.applyStep();
    }
};

fn paintIcon(node: *ui.Node, asset: ui.SvgAsset, size: f32, tint: ui.Color) void {
    if (asset.icon_id) |id| if (asset.pickRep(size)) |rep| node.setIcon(.{ .icon_id = id, .rep = rep, .tint = tint });
}

fn action(w: *RemoteEditor, parent: *ui.Node, label: []const u8, id: []const u8, width: f32, height: f32, primary: bool, disabled: ?*ui.Signal(bool), comptime callback: *const fn (*RemoteEditor) void, icon: ?ui.SvgAsset) !*ui.Node {
    const source: ui.Source(bool) = if (disabled) |signal| .{ .signal = signal } else .{ .value = false };
    const base = try w.scope.createSignal(ui.BoxStyle, S.button(width, height, primary));
    const node = try ui.widgets.Button(.{ .variant = @as(ui.widgets.ButtonVariant, if (primary) .primary else .ghost), .a11y_label = label, .disabled = source, .base_style = base, .on_click = w.cx.on(RemoteEditor, w, callback) }).mount(w.scope, w.cx);
    for (node.children.items) |child| child.setDisplay(.none);
    node.setStyleInline(w.alloc, S.button(width, height, primary));
    node.meta.ownership.meta.test_id = id;
    var label_node: ?*ui.Node = null;
    var icon_node: ?*ui.Node = null;
    if (icon) |asset| {
        icon_node = try ui.iconTint(w.cx, asset, if (primary) S.action(true).color else S.theme.current().fg_2, .{ .width = .{ .px = 16 }, .height = .{ .px = 16 }, .flex_shrink = 0 });
        try node.appendChild(w.alloc, icon_node.?);
    } else {
        const test_action = std.mem.eql(u8, id, "wizard.test");
        label_node = try ui.text(w.cx, label, if (test_action) S.testActionText() else S.action(primary));
        if (test_action) label_node.?.setStyleInline(w.alloc, S.testActionLabel());
        try node.appendChild(w.alloc, label_node.?);
    }
    try w.buttons.append(w.alloc, .{ .node = node, .label = label_node, .icon = icon_node, .style = base, .width = width, .height = height, .primary = primary, .quiet = std.mem.eql(u8, id, "wizard.close") });
    try parent.appendChild(w.alloc, node);
    return node;
}

fn disclosure(w: *RemoteEditor, parent: *ui.Node, label: []const u8, id: []const u8, comptime callback: *const fn (*RemoteEditor) void) !*ui.Node {
    const row = try ui.box(w.cx, S.row(18), .{});
    const base = try w.scope.createSignal(ui.BoxStyle, S.disclosure());
    const node = try ui.widgets.Button(.{ .variant = .ghost, .a11y_label = label, .disabled = w.locked.?, .base_style = base, .hover_style = S.disclosureHover(), .pressed_style = S.disclosureHover(), .on_click = w.cx.on(RemoteEditor, w, callback) }).mount(w.scope, w.cx);
    node.meta.ownership.meta.test_id = id;
    const title = try ui.text(w.cx, label, .{ .font_size = 12, .line_height = 1.5, .color = S.theme.current().fg_1 });
    const chevron = try ui.iconTint(w.cx, ui.icons.chevron_right, S.theme.current().fg_1, .{ .width = .{ .px = 10 }, .height = .{ .px = 10 }, .flex_shrink = 0 });
    w.advanced_chevron = chevron;
    const content = try ui.box(w.cx, .{ .width = .fill(), .height = .{ .px = 18 }, .min_width = 0, .flex = 1, .direction = .row, .align_items = .center, .justify = .start, .gap = 4, .hit_behavior = .pass_through }, .{});
    try content.appendChild(w.alloc, chevron);
    try content.appendChild(w.alloc, title);
    try node.appendChild(w.alloc, content);
    try w.buttons.append(w.alloc, .{ .node = node, .label = title, .icon = null, .style = base, .width = 0, .height = 18, .primary = false, .quiet = true });
    try row.appendChild(w.alloc, node);
    try parent.appendChild(w.alloc, row);
    return row;
}

const FieldKind = enum { name, host, user, port, key_path };
const FieldFeedback = struct {
    wizard: *RemoteEditor,
    kind: FieldKind,
    message: *ui.Signal([]const u8),
    touched: bool = false,
    attached: bool = false,
    input: ui.widgets.input.InputResult = undefined,
    group: *ui.Node = undefined,
    error_node: ?*ui.Node = null,
    previous_blur: ?ui.HandlerRef = null,

    fn prepare(w: *RemoteEditor, id: []const u8) !?*FieldFeedback {
        const kind: FieldKind = if (std.mem.eql(u8, id, "wizard.name")) .name else if (std.mem.eql(u8, id, "wizard.host")) .host else if (std.mem.eql(u8, id, "wizard.user")) .user else if (std.mem.eql(u8, id, "wizard.port")) .port else if (std.mem.eql(u8, id, "wizard.key_path")) .key_path else return null;
        const self = try w.scope.createState(FieldFeedback, .{ .wizard = w, .kind = kind, .message = try w.scope.createText("", .{}) });
        try w.field_feedback.append(w.alloc, self);
        return self;
    }
    fn attach(self: *FieldFeedback, input: ui.widgets.input.InputResult, group: *ui.Node, label: []const u8) !void {
        self.input = input;
        self.group = group;
        self.previous_blur = input.input_container.behavior.events.on_blur;
        self.attached = true;
        input.input_container.behavior.events.on_blur = ui.Cx.simpleHandler(blurred, self);
        if (input.input_container.behavior.interaction.a11y) |*attrs| {
            attrs.label = label;
            attrs.required = true;
        }
        // Input's public wrapper includes its own helper Text after the field shell.
        // Use that native error presentation and preserve SDK focus/IME cleanup.
        for (input.node.children.items) |child| if (child.getText() != null) {
            self.error_node = child;
            const id = try std.fmt.allocPrint(self.wizard.alloc, "wizard.{s}.error", .{@tagName(self.kind)});
            try self.wizard.owned_ids.append(self.wizard.alloc, id);
            child.meta.ownership.meta.test_id = id;
            if (child.getText()) |old| {
                var props = old;
                props.font_size = 10.5;
                props.line_height = 16.0 / 10.5;
                child.setText(props);
            }
            child.setStyleInline(self.wizard.alloc, S.errorLabel());
        };
        input.node.setStyleInline(self.wizard.alloc, .{ .gap = 4 });
    }
    fn releaseBlur(self: *FieldFeedback) void {
        if (!self.attached) return;
        self.input.input_container.behavior.events.on_blur = self.previous_blur;
        self.attached = false;
    }
    fn blurred(raw: *anyopaque) void {
        const self: *FieldFeedback = @ptrCast(@alignCast(raw));
        if (self.previous_blur) |callback| callback.invoke();
        if (!self.wizard.isVisible() or self.wizard.isLocked()) return;
        self.touched = true;
        self.refresh();
        self.wizard.paintSteps();
        self.wizard.cx.requestRedraw();
    }
    fn errorMessage(self: *FieldFeedback) []const u8 {
        const w = self.wizard;
        const raw = switch (self.kind) {
            .name => w.sig_name.?.get(),
            .host => w.sig_host.?.get(),
            .user => w.sig_user.?.get(),
            .port => w.sig_port.?.get(),
            .key_path => w.sig_key_path.?.get(),
        };
        if (self.kind == .key_path and w.auth != .key) return "";
        if (self.kind == .port) return if (parsePort(raw) == 0) "请输入 1–65535 的整数。" else "";
        if (trim(raw).len == 0) return switch (self.kind) {
            .name => "请输入主机名称。",
            .host => "请输入主机地址。",
            .user => "请输入登录用户。",
            .key_path => "请选择或输入私钥文件。",
            .port => unreachable,
        };
        if (self.kind != .key_path and (!std.unicode.utf8ValidateSlice(raw) or std.mem.indexOfAny(u8, raw, "\x00\r\n\t") != null)) return "请移除换行或控制字符。";
        return "";
    }
    fn refresh(self: *FieldFeedback) void {
        const message = if (self.touched) self.errorMessage() else "";
        self.message.set(message);
        self.resize(message.len != 0);
        self.repaint();
    }
    fn resize(self: *FieldFeedback, invalid: bool) void {
        self.group.setStyleInline(self.wizard.alloc, .{ .height = .{ .px = if (invalid) 73.5 else 53.5 } });
        self.input.node.setStyleInline(self.wizard.alloc, .{ .height = .{ .px = if (invalid) 52 else 32 }, .flex_shrink = 0 });
    }
    fn repaint(self: *FieldFeedback) void {
        if (self.error_node) |node| node.setTextColor(S.theme.current().danger_ink);
    }
};

fn field(w: *RemoteEditor, parent: *ui.Node, label: []const u8, value: *ui.Signal([]const u8), placeholder: []const u8, id: []const u8, width: ?f32, secret: bool) !ui.widgets.input.InputResult {
    const group = try ui.box(w.cx, S.field(width), .{});
    const title = try fieldLabel(w.cx, label);
    title.style.height = .{ .px = 16.5 };
    try group.appendChild(w.alloc, title);
    const feedback = try FieldFeedback.prepare(w, id);
    const input = try ui.widgets.Input(.{ .error_msg = if (feedback) |f| ui.Source([]const u8){ .signal = f.message } else ui.Source([]const u8){ .value = "" }, .value = value, .readonly = std.mem.eql(u8, id, "wizard.encoding"), .placeholder = placeholder, .input_type = @as(ui.widgets.input.InputType, if (secret) .password else .text), .disabled = w.locked.?, .on_change = w.cx.on(RemoteEditor, w, RemoteEditor.onFieldChange), .on_submit = w.cx.on(RemoteEditor, w, RemoteEditor.onFieldSubmit) }).mountResult(w.scope, w.cx);
    input.node.setStyleInline(w.alloc, .{ .width = .fill(), .height = .{ .px = 32 }, .min_width = 0, .flex_shrink = 1 });
    input.input_container.setStyleInline(w.alloc, S.input());
    input.input_container.meta.ownership.meta.test_id = id;
    input.state.font_size = 12;
    input.state.line_height = 18;
    input.state.padding_h = 0;
    input.state.char_width = 6.9;
    input.state.tokens = w.cx.tokens;
    input.state.dirty = true;
    if (feedback) |f| try f.attach(input, group, label);
    try w.inputs.append(w.alloc, input);
    try group.appendChild(w.alloc, input.node);
    try parent.appendChild(w.alloc, group);
    return input;
}
fn twoFields(w: *RemoteEditor, parent: *ui.Node, label_a: []const u8, a: *ui.Signal([]const u8), id_a: []const u8, label_b: []const u8, b: *ui.Signal([]const u8), id_b: []const u8) !void {
    const row = try ui.box(w.cx, S.fieldRow(), .{});
    _ = try field(w, row, label_a, a, "", id_a, null, false);
    _ = try field(w, row, label_b, b, "", id_b, null, false);
    try parent.appendChild(w.alloc, row);
}
fn fieldLabel(cx: *ui.Cx, value: []const u8) !*ui.Node {
    const label = try ui.textStyled(cx, S.label, value);
    label.setStyleInline(cx.allocator, .{ .height = .{ .px = 16.5 }, .flex_shrink = 0 });
    return label;
}
fn readonlyField(w: *RemoteEditor, parent: *ui.Node, label: []const u8, text: []const u8) !*ui.Node {
    const group = try ui.box(w.cx, S.field(null), .{});
    try group.appendChild(w.alloc, try fieldLabel(w.cx, label));
    const well = try ui.box(w.cx, S.input(), .{});
    well.style.direction = .row;
    well.style.align_items = .center;
    const value = try ui.textStyled(w.cx, S.readonlyValue, text);
    value.setStyleInline(w.alloc, .{ .width = .fill(), .min_width = 0, .flex = 1 });
    try well.appendChild(w.alloc, value);
    try group.appendChild(w.alloc, well);
    try parent.appendChild(w.alloc, group);
    return value;
}

fn mountIdentity(w: *RemoteEditor) !*ui.Node {
    const cx = w.cx;
    const root = try ui.boxStyled(cx, S.formSection, .{});
    if (w.protocol_picker) |picker| try root.appendChild(w.alloc, try picker.mount(picker.context, cx, w.scope));
    const card = try ui.boxStyled(cx, S.formSection, .{});
    w.identity_card = card;
    card.meta.ownership.meta.test_id = "wizard.identity.card";
    const head = try ui.box(cx, S.row(30), .{});
    try head.appendChild(w.alloc, try ui.text(cx, "连接信息", S.text(12, 700, false)));
    w.copy_trigger = try action(w, head, "从已有主机复制", "wizard.copy.open", 116, 28, false, w.copy_open_disabled, RemoteEditor.onCopyToggle, null);
    try card.appendChild(w.alloc, head);
    const details = try ui.boxStyled(cx, S.formSection, .{});
    w.identity_body = details;
    const copy_modal = try ui.widgets.Modal(.{ .open = ui.split(w.copy_open.?, cx.on(RemoteEditor, w, RemoteEditor.onCopyOpenChanged)), .width = 440, .max_height = 320, .background = S.theme.current().overlay }).mount(w.scope, cx);
    w.copy_dialog = copy_modal.dialog;
    w.copy_body = copy_modal.body;
    copy_modal.dialog.meta.ownership.meta.test_id = "wizard.copy.dialog";
    copy_modal.dialog.setStyleInline(w.alloc, .{ .width = .{ .px = 440 }, .height = .{ .fit = .{} }, .max_height = 320, .padding = .{}, .gap = 0, .direction = .column, .overflow_hidden = true, .border = .{ .radius = 14 } });
    copy_modal.body.setStyleInline(w.alloc, .{ .width = .fill(), .height = .{ .fit = .{} }, .padding = .{}, .gap = 0, .direction = .column });
    const copy_head = try ui.box(cx, S.copyHeader(), .{});
    try copy_head.appendChild(w.alloc, try ui.text(cx, "从已有主机复制", S.text(13, 700, false)));
    try copy_head.appendChild(w.alloc, try ui.spacer(cx));
    _ = try action(w, copy_head, "关闭", "wizard.copy.close", 24, 24, false, null, RemoteEditor.onCopyCancel, ui.icons.x);
    try copy_modal.body.appendChild(w.alloc, copy_head);
    const copy_bar = try ui.box(cx, .{ .width = .fill(), .height = .{ .px = 73.5 }, .padding = .{ .left = 24, .right = 24, .bottom = 20 }, .direction = .column, .gap = 5, .flex_shrink = 0 }, .{});
    w.copy_bar = copy_bar;
    copy_bar.meta.ownership.meta.test_id = "wizard.copy.row";
    try copy_bar.appendChild(w.alloc, try fieldLabel(cx, "选择复制来源"));
    const source = try ui.widgets.Select(.{ .options = w.asset_options.?, .placeholder = "选择复制来源", .value = w.sig_copy_source.?, .width = 392, .searchable = true, .disabled = w.locked.?, .on_change = cx.on(RemoteEditor, w, RemoteEditor.onCopySourceChanged) }).mount(w.scope, cx);
    skinSelect(w, source, 32, 12);
    source.trigger.meta.ownership.meta.test_id = "wizard.copy.source";
    try copy_bar.appendChild(w.alloc, source.wrapper);
    try copy_modal.body.appendChild(w.alloc, copy_bar);
    const copy_foot = try ui.box(cx, S.copyFooter(), .{});
    copy_foot.setBackground(S.theme.current().surface_2);
    _ = try action(w, copy_foot, "取消", "wizard.copy.cancel", 76, 34, false, null, RemoteEditor.onCopyCancel, null);
    try copy_foot.appendChild(w.alloc, try ui.spacer(cx));
    _ = try action(w, copy_foot, "复制到当前草稿", "wizard.copy.apply", 128, 34, true, w.copy_disabled, RemoteEditor.onCopyApply, null);
    try copy_modal.body.appendChild(w.alloc, copy_foot);
    if (!copy_modal.portaled) try root.appendChild(w.alloc, copy_modal.overlay);
    const name_row = try ui.box(cx, S.fieldRow(), .{});
    _ = try field(w, name_row, "连接名称", w.sig_name.?, "", "wizard.name", null, false);
    const group_field = try ui.box(cx, S.field(null), .{});
    try group_field.appendChild(w.alloc, try fieldLabel(cx, "资产分组"));
    const group_select = try ui.widgets.Select(.{ .options = w.group_options.?, .value = w.sig_group_selection.?, .width = (S.width - 48 - 16) / 2, .disabled = w.locked.?, .on_change = cx.on(RemoteEditor, w, RemoteEditor.onGroupChanged) }).mount(w.scope, cx);
    skinSelect(w, group_select, 32, 12);
    group_select.wrapper.setStyleInline(w.alloc, .{ .width = .fill(), .min_width = 0 });
    group_select.trigger.meta.ownership.meta.test_id = "wizard.group";
    group_select.chrome.meta.ownership.meta.test_id = "wizard.group.menu";
    try group_field.appendChild(w.alloc, group_select.wrapper);
    try name_row.appendChild(w.alloc, group_field);
    try details.appendChild(w.alloc, name_row);
    try twoFields(w, details, "主机地址", w.sig_host.?, "wizard.host", "端口", w.sig_port.?, "wizard.port");
    const identity_row = try ui.box(cx, S.fieldRow(), .{});
    _ = try field(w, identity_row, "用户名", w.sig_user.?, "", "wizard.user", null, false);
    const auth_field = try ui.box(cx, S.field(null), .{});
    try auth_field.appendChild(w.alloc, try fieldLabel(cx, "认证方式"));
    const auth_options = [_]ui.widgets.SelectOption{
        .{ .value = "password", .label = "密码", .test_id = "wizard.auth.password" },
        .{ .value = "key", .label = "私钥文件", .test_id = "wizard.auth.key" },
        .{ .value = "agent", .label = "SSH Agent", .test_id = "wizard.auth.agent" },
    };
    const auth_select = try ui.widgets.Select(.{ .options = &auth_options, .value = w.sig_auth.?, .width = (S.width - 48 - 16) / 2, .disabled = w.locked.?, .on_change = cx.on(RemoteEditor, w, RemoteEditor.onAuthChanged) }).mount(w.scope, cx);
    skinSelect(w, auth_select, 32, 12);
    auth_select.wrapper.setStyleInline(w.alloc, .{ .width = .fill(), .min_width = 0 });
    auth_select.trigger.meta.ownership.meta.test_id = "wizard.auth";
    auth_select.chrome.meta.ownership.meta.test_id = "wizard.auth.menu";
    try auth_field.appendChild(w.alloc, auth_select.wrapper);
    try identity_row.appendChild(w.alloc, auth_field);
    try details.appendChild(w.alloc, identity_row);
    try card.appendChild(w.alloc, details);
    try root.appendChild(w.alloc, card);

    const auth_card = try ui.boxStyled(cx, S.formSection, .{});
    w.auth_card = auth_card;
    auth_card.meta.ownership.meta.test_id = "wizard.auth.card";
    const auth_body = try ui.boxStyled(cx, S.formSection, .{});
    w.auth_body = auth_body;
    const key = try ui.boxStyled(cx, S.stack, .{});
    w.cred_key_row = key;
    const key_group = try ui.box(cx, S.field(null), .{});
    try key_group.appendChild(w.alloc, try fieldLabel(cx, "私钥文件路径"));
    const key_row = try ui.box(cx, S.fieldRow(), .{});
    const key_feedback = (try FieldFeedback.prepare(w, "wizard.key_path")).?;
    const key_input = try ui.widgets.Input(.{ .error_msg = key_feedback.message, .value = w.sig_key_path.?, .placeholder = "~/.ssh/id_ed25519", .disabled = w.locked.?, .on_change = cx.on(RemoteEditor, w, RemoteEditor.onFieldChange), .on_submit = cx.on(RemoteEditor, w, RemoteEditor.onFieldSubmit) }).mountResult(w.scope, cx);
    key_input.node.setStyleInline(w.alloc, .{ .width = .fill(), .min_width = 0, .height = .{ .px = 32 } });
    key_input.input_container.setStyleInline(w.alloc, S.input());
    key_input.input_container.meta.ownership.meta.test_id = "wizard.key_path";
    key_input.state.font_size = 12;
    key_input.state.line_height = 18;
    key_input.state.padding_h = 0;
    key_input.state.dirty = true;
    try key_feedback.attach(key_input, key_group, "私钥文件");
    try w.inputs.append(w.alloc, key_input);
    try key_row.appendChild(w.alloc, key_input.node);
    _ = try action(w, key_row, "选择私钥文件", "wizard.key_path.pick", 28, 28, false, w.locked, RemoteEditor.onPickKey, ui.icons.folder_open);
    try key_group.appendChild(w.alloc, key_row);
    try key.appendChild(w.alloc, key_group);
    _ = try field(w, key, "私钥口令 · 仅本次使用", w.sig_key_passphrase.?, "可留空，连接时再输入", "wizard.key_passphrase", null, true);
    try auth_body.appendChild(w.alloc, key);
    const pw = try ui.boxStyled(cx, S.stack, .{});
    w.cred_pw_row = pw;
    _ = try field(w, pw, "密码", w.sig_password.?, "可留空，连接时再输入", "wizard.password", null, true);
    const remember = try ui.widgets.Checkbox(.{ .checked = w.sig_save_password.?, .label = "保存密码，下次连接自动使用", .box_size = @as(f32, 16), .label_font_size = @as(f32, 11), .disabled = w.locked.?, .on_change = cx.on(RemoteEditor, w, RemoteEditor.onSavePasswordChanged) }).mount(w.scope, cx);
    remember.setStyleInline(w.alloc, .{ .width = .fill(), .height = .{ .px = 24 }, .gap = 6, .flex_shrink = 0 });
    remember.meta.ownership.meta.test_id = "wizard.password.remember";
    w.remember_checkbox = remember;
    paintCheckboxLabels(remember);
    try pw.appendChild(w.alloc, remember);
    try pw.appendChild(w.alloc, try ui.textStyled(cx, S.hint, "凭据保存到系统钥匙串，仅在此设备使用；导出连接不包含密码。"));
    try auth_body.appendChild(w.alloc, pw);
    const agent = try ui.textStyled(cx, S.paragraph, "建立连接时从本机 SSH Agent 获取可用身份，不读取或保存私钥。");
    agent.meta.ownership.meta.test_id = "wizard.auth.agent_notice";
    w.agent_notice = agent;
    try auth_body.appendChild(w.alloc, agent);
    try auth_card.appendChild(w.alloc, auth_body);
    try root.appendChild(w.alloc, auth_card);

    const policy_field = try ui.box(cx, S.field(null), .{});
    try policy_field.appendChild(w.alloc, try fieldLabel(cx, "主机密钥策略"));
    const policy_options = [_]ui.widgets.SelectOption{
        .{ .value = "true", .label = "严格验证主机密钥（推荐）", .test_id = "wizard.strict.enabled" },
        .{ .value = "false", .label = "关闭严格验证（测试环境）", .test_id = "wizard.strict.disabled" },
    };
    const policy = try ui.widgets.Select(.{ .options = &policy_options, .value = w.sig_strict_policy.?, .width = S.width - 48, .disabled = w.locked.?, .on_change = cx.on(RemoteEditor, w, RemoteEditor.onStrictPolicyChanged) }).mount(w.scope, cx);
    skinSelect(w, policy, 32, 12);
    policy.wrapper.setStyleInline(w.alloc, .{ .width = .fill(), .min_width = 0 });
    policy.trigger.meta.ownership.meta.test_id = "wizard.strict_host_key";
    w.strict_checkbox = policy.trigger;
    try policy_field.appendChild(w.alloc, policy.wrapper);
    try root.appendChild(w.alloc, policy_field);

    const advanced = try ui.boxStyled(cx, S.advancedSection, .{});
    w.step2_advanced = advanced;
    advanced.meta.ownership.meta.test_id = "wizard.advanced.card";
    _ = try disclosure(w, advanced, "高级选项", "wizard.advanced.toggle", RemoteEditor.onAdvancedToggle);
    const advanced_body = try ui.boxStyled(cx, S.formSection, .{});
    w.advanced_body = advanced_body;
    advanced_body.meta.ownership.meta.test_id = "wizard.advanced.body";
    const defaults = try ui.box(cx, S.fieldRow(), .{});
    w.connect_timeout_fact = try readonlyField(w, defaults, "连接超时（全局默认）", "—");
    w.connect_timeout_fact.?.meta.ownership.meta.test_id = "wizard.ssh.connect_timeout";
    w.keepalive_fact = try readonlyField(w, defaults, "KeepAlive（全局默认）", "—");
    w.keepalive_fact.?.meta.ownership.meta.test_id = "wizard.ssh.keepalive";
    try advanced_body.appendChild(w.alloc, defaults);
    const encoding = try ui.box(cx, S.fieldRow(), .{});
    _ = try field(w, encoding, "字符编码", w.sig_encoding.?, "UTF-8", "wizard.encoding", null, false);
    const compression = try ui.widgets.Checkbox(.{ .checked = w.sig_compression.?, .label = "SSH 传输压缩", .box_size = @as(f32, 16), .label_font_size = @as(f32, 11), .disabled = w.locked.?, .on_change = cx.on(RemoteEditor, w, RemoteEditor.onCompressionChanged) }).mount(w.scope, cx);
    compression.setStyleInline(w.alloc, .{ .width = .fill(), .min_width = 0, .height = .{ .px = 53.5 }, .gap = 8, .flex = 1, .flex_shrink = 0 });
    compression.meta.ownership.meta.test_id = "wizard.compression";
    w.compression_checkbox = compression;
    paintCheckboxLabels(compression);
    try encoding.appendChild(w.alloc, compression);
    try advanced_body.appendChild(w.alloc, encoding);
    const commands = try ui.boxStyled(cx, S.commandField, .{});
    w.commands_card = commands;
    w.commands_details = commands;
    try commands.appendChild(w.alloc, try fieldLabel(cx, "启动命令（每行一条，连接成功后按序执行）"));
    const textarea = try ui.widgets.Textarea(.{ .value = w.sig_startup.?, .rows = 6, .placeholder = "cd /var/www/app", .error_msg = w.startup_error.?, .disabled = w.locked.?, .on_change = cx.on(RemoteEditor, w, RemoteEditor.onStartupTextChanged) }).mountResult(w.scope, cx);
    textarea.input.meta.ownership.meta.test_id = "wizard.startup";
    textarea.wrapper.meta.ownership.meta.test_id = "wizard.startup.field";
    textarea.state.font_size = 12;
    textarea.state.line_height = 18;
    textarea.state.padding_h = 11;
    textarea.state.padding_v = 9;
    textarea.state.wrap_map.font_size = 12;
    textarea.state.wrap_map.rebuildAll(textarea.state.doc);
    if (textarea.state.vl_state) |list| {
        list.props.item_height = 18;
        ui.widgets.virtual_list.updateItemCount(list, list.item_count);
        list.container_node.setStyleInline(w.alloc, .{ .padding = .{ .left = 11, .right = 11, .top = 9, .bottom = 9 } });
    }
    textarea.state.dirty = true;
    textarea.input.setStyleInline(w.alloc, .{ .border = .{ .radius = 8, .width = 1, .color = ui.Color.TRANSPARENT } });
    textarea.wrapper.setStyleInline(w.alloc, .{ .width = .fill(), .min_width = 0, .flex_shrink = 0 });
    w.startup_textarea = textarea;
    try commands.appendChild(w.alloc, textarea.wrapper);
    try advanced_body.appendChild(w.alloc, commands);
    try advanced.appendChild(w.alloc, advanced_body);
    try root.appendChild(w.alloc, advanced);
    return root;
}

const RouteChoice = struct { root: *ui.Node, highlight: *ui.Node, style: *ui.Signal(S.ButtonStyle), title: *ui.Node, detail: *ui.Node };
fn mountAccessChoice(w: *RemoteEditor, parent: *ui.Node, index: usize, title: []const u8, detail: []const u8, id: []const u8, comptime callback: *const fn (*RemoteEditor) void) !void {
    const style = try w.scope.createSignal(S.ButtonStyle, S.accessChoice(false));
    const root = try ui.widgets.Button(.{ .a11y_label = title, .disabled = w.locked.?, .base_style = style, .on_click = w.cx.on(RemoteEditor, w, callback) }).mount(w.scope, w.cx);
    root.meta.ownership.meta.test_id = id;
    const highlight = try ui.box(w.cx, .{ .position = .absolute, .inset = .{ .left = .{ .px = 0 }, .right = .{ .px = 0 }, .top = .{ .px = 0 }, .bottom = .{ .px = 0 } }, .width = .fill(), .height = .fill(), .background = S.theme.current().selection, .border = .{ .radius = 8 }, .hit_behavior = .pass_through }, .{});
    try root.appendChild(w.alloc, highlight);
    const heading = try ui.text(w.cx, title, S.text(12, 600, false));
    heading.setStyleInline(w.alloc, .{ .position = .absolute, .inset = .{ .left = .{ .px = 14 }, .top = .{ .px = 12 }, .right = .{ .px = 14 } }, .height = .{ .px = 18 } });
    const subtitle = try ui.text(w.cx, detail, S.text(10, 400, false));
    subtitle.setStyleInline(w.alloc, .{ .position = .absolute, .inset = .{ .left = .{ .px = 14 }, .top = .{ .px = 34 }, .right = .{ .px = 14 } }, .height = .{ .px = 15 } });
    try root.appendChild(w.alloc, heading);
    try root.appendChild(w.alloc, subtitle);
    try parent.appendChild(w.alloc, root);
    w.route_choices[index] = .{ .root = root, .highlight = highlight, .style = style, .title = heading, .detail = subtitle };
}
fn mountRoute(w: *RemoteEditor) !*ui.Node {
    const root = try ui.boxStyled(w.cx, S.formSection, .{});
    const card = try ui.boxStyled(w.cx, S.formSection, .{});
    w.route_card = card;
    card.meta.ownership.meta.test_id = "wizard.route.card";
    try card.appendChild(w.alloc, try ui.text(w.cx, "连接路径", S.text(12, 700, false)));
    const detail = try ui.boxStyled(w.cx, S.formSection, .{});
    w.route_body = detail;
    var access_style = S.row(61);
    access_style.gap = 10;
    const access = try ui.box(w.cx, access_style, .{});
    try mountAccessChoice(w, access, 0, "从本机直接连接", "本机 → 目标主机", "wizard.access.direct", RemoteEditor.onAccessDirect);
    try mountAccessChoice(w, access, 1, "经 SSH 跳板连接", "通过有序跳板访问目标", "wizard.access.jump", RemoteEditor.onAccessJump);
    try detail.appendChild(w.alloc, access);
    const editor = try ui.boxStyled(w.cx, S.stack, .{});
    w.route_editor = editor;
    for (0..8) |i| {
        const jump_row = try ui.box(w.cx, S.routeHop(), .{});
        var label: [40]u8 = undefined;
        const number = try ui.text(w.cx, try std.fmt.bufPrint(&label, "{d}", .{i + 1}), S.text(11, 500, false));
        number.setStyleInline(w.alloc, .{ .width = .{ .px = 16 }, .height = .{ .px = 16 }, .flex_shrink = 0 });
        try jump_row.appendChild(w.alloc, number);
        const picker = try ui.widgets.Select(.{ .options = w.asset_options.?, .placeholder = "选择 SSH 主机", .value = w.jump_values[i].?, .width = 566, .disabled = w.locked.?, .on_change = w.cx.on(RemoteEditor, w, RemoteEditor.onSelection) }).mount(w.scope, w.cx);
        skinSelect(w, picker, 32, 12);
        var id: [48]u8 = undefined;
        picker.trigger.meta.ownership.meta.test_id = try ownedId(w, &id, "wizard.route.hop.{d}", i);
        try jump_row.appendChild(w.alloc, picker.wrapper);
        const actions = try ui.box(w.cx, .{ .width = .{ .px = 96 }, .height = .{ .px = 32 }, .direction = .row, .align_items = .center, .gap = 6, .flex_shrink = 0 }, .{});
        try actions.appendChild(w.alloc, try editorAction(w, w.cx, "上移", i, .jump_up));
        try actions.appendChild(w.alloc, try editorAction(w, w.cx, "下移", i, .jump_down));
        try actions.appendChild(w.alloc, try editorAction(w, w.cx, "删除", i, .jump_remove));
        try jump_row.appendChild(w.alloc, actions);
        w.jump_rows[i] = jump_row;
        try editor.appendChild(w.alloc, jump_row);
    }
    _ = try action(w, editor, "添加跳板", "wizard.route.add", 712, 30, false, w.jump_add_disabled, RemoteEditor.onAddJump, null);
    try detail.appendChild(w.alloc, editor);
    w.route_empty_hint = try ui.textStyled(w.cx, S.paragraph, "请选择 SSH 跳板主机，或切换为从本机直接连接。");
    w.route_empty_hint.?.meta.ownership.meta.test_id = "wizard.route.error";
    w.route_empty_hint.?.setTextColor(S.theme.current().danger_ink);
    try detail.appendChild(w.alloc, w.route_empty_hint.?);
    try detail.appendChild(w.alloc, try mountRoutePreview(w, 0));
    w.route_hint = try ui.textStyled(w.cx, S.paragraph, "SFTP 暂不支持跳板。可仅保存配置，或改为直连后浏览。");
    w.route_hint.?.setDisplay(if (w.sftpRouteUnavailable()) .flex else .none);
    try detail.appendChild(w.alloc, w.route_hint.?);
    try card.appendChild(w.alloc, detail);
    try root.appendChild(w.alloc, card);
    return root;
}

fn mountRoutePreview(w: *RemoteEditor, index: usize) !*ui.Node {
    const scroll = try ui.widgets.ScrollArea(.{ .height = 76, .direction = .horizontal }).mount(w.scope, w.cx);
    scroll.container.setStyleInline(w.alloc, .{ .width = .fill(), .height = .{ .px = 76 }, .flex_shrink = 0 });
    const row = scroll.content;
    row.setStyleInline(w.alloc, .{ .width = .{ .px = 668 }, .height = .{ .px = 76 }, .direction = .row, .align_items = .center, .justify = .center, .gap = 6, .flex_shrink = 0 });
    var preview = &w.route_previews[index];
    preview.row = row;
    for (0..10) |i| {
        if (i != 0) {
            const arrow = try ui.box(w.cx, .{ .width = .{ .px = 12 }, .height = .{ .px = 76 }, .align_items = .center, .justify = .center, .flex_shrink = 0 }, .{});
            try arrow.appendChild(w.alloc, try ui.iconTint(w.cx, ui.icons.chevron_right, S.theme.current().fg_3, .{ .width = .{ .px = 10 }, .height = .{ .px = 16 } }));
            preview.arrows[i - 1] = arrow;
            try row.appendChild(w.alloc, arrow);
        }
        const node = if (index == 1) blk: {
            const ctx = try w.alloc.create(TestHopAction);
            ctx.* = .{ .wizard = w, .index = i };
            try w.scope.onCleanup(TestHopAction, ctx, TestHopAction.cleanup);
            w.test_actions[i] = ctx;
            const button = try ui.widgets.Button(.{ .variant = .ghost, .a11y_label = if (i == 0) @as([]const u8, "全部节点日志") else "筛选节点日志", .on_click = w.cx.on(TestHopAction, ctx, TestHopAction.click) }).mount(w.scope, w.cx);
            for (button.children.items) |child| child.setDisplay(.none);
            button.setStyleInline(w.alloc, S.testNode());
            var id: [48]u8 = undefined;
            button.meta.ownership.meta.test_id = try ownedId(w, &id, "wizard.test.hop.{d}", i);
            break :blk button;
        } else try ui.box(w.cx, S.routeNode(i == 9), .{});
        preview.nodes[i] = node;
        preview.names[i] = try ui.text(w.cx, if (i == 0) "Local" else "", if (index == 1) S.testNodeText(.name) else S.title(w.cx.tokens));
        preview.addresses[i] = try ui.text(w.cx, if (i == 0) "127.0.0.1" else "", if (index == 1) S.testNodeText(.address) else S.text(10.5, 400, true));
        preview.users[i] = try ui.text(w.cx, if (i == 0) "本机" else "待连接", if (index == 1) S.testNodeText(.status) else S.hint(w.cx.tokens));
        if (index == 1) {
            const name_row = try ui.box(w.cx, S.row(20), .{});
            try name_row.appendChild(w.alloc, try ui.iconTint(w.cx, if (i == 0) ui.icons.laptop else ui.icons.server, S.theme.current().fg_2, .{ .width = .{ .px = 14 }, .height = .{ .px = 14 }, .flex_shrink = 0 }));
            preview.names[i].?.setStyleInline(w.alloc, .{ .width = .fill(), .height = .{ .px = 16 }, .min_width = 0 });
            try name_row.appendChild(w.alloc, preview.names[i].?);
            try node.appendChild(w.alloc, name_row);
            preview.addresses[i].?.setStyleInline(w.alloc, .{ .width = .fill(), .height = .{ .px = 14 } });
            preview.users[i].?.setStyleInline(w.alloc, .{ .width = .fill(), .height = .{ .px = 16 } });
        } else try node.appendChild(w.alloc, preview.names[i].?);
        try node.appendChild(w.alloc, preview.addresses[i].?);
        try node.appendChild(w.alloc, preview.users[i].?);
        try row.appendChild(w.alloc, node);
        if (index == 0 and i > 0 and i < 9) {
            w.jump_addresses[i - 1] = preview.addresses[i];
            w.jump_users[i - 1] = preview.users[i];
        }
    }
    if (index == 0) {
        w.topo_name = preview.names[9];
        w.topo_addr = preview.addresses[9];
        w.topo_user = preview.users[9];
    }
    return scroll.container;
}

fn mountDiscard(w: *RemoteEditor) !*ui.Node {
    const card = try ui.box(w.cx, S.discardCard(), .{});
    const heading = try action(w, card, "放弃尚未保存的连接？", "wizard.discard.toggle", 668, 28, false, null, RemoteEditor.onDiscardToggle, null);
    w.discard_heading = heading;
    for (heading.children.items) |child| child.setDisplay(.none);
    heading.setStyleInline(w.alloc, .{ .width = .fill(), .justify = .start, .background = ui.Color.TRANSPARENT });
    try heading.appendChild(w.alloc, try ui.iconTint(w.cx, ui.icons.circle_alert, S.theme.current().fg_2, S.icon(16)));
    try heading.appendChild(w.alloc, try ui.textStyled(w.cx, S.title, "放弃尚未保存的连接？"));
    try heading.appendChild(w.alloc, try ui.spacer(w.cx));
    w.discard_chevron = try ui.iconTint(w.cx, ui.icons.chevron_down, S.theme.current().fg_2, S.icon(16));
    try heading.appendChild(w.alloc, w.discard_chevron.?);
    w.discard_name = try ui.text(w.cx, "", S.discardText(false));
    w.discard_name.?.setStyleInline(w.alloc, S.discardLine());
    try card.appendChild(w.alloc, w.discard_name.?);
    const note = try ui.text(w.cx, "继续编辑可保留所有输入；放弃只丢弃本份草稿。", S.discardText(true));
    note.setStyleInline(w.alloc, S.discardLine());
    try card.appendChild(w.alloc, note);
    w.discard_status = try ui.text(w.cx, "", S.discardText(true));
    w.discard_status.?.meta.ownership.meta.test_id = "wizard.discard.status";
    w.discard_status.?.setStyleInline(w.alloc, S.discardLine());
    try card.appendChild(w.alloc, w.discard_status.?);
    return card;
}

fn mountReview(w: *RemoteEditor) !*ui.Node {
    var id_buffer: [80]u8 = undefined;
    const root = try ui.boxStyled(w.cx, S.reviewStack, .{});
    const summary = try ui.box(w.cx, S.reviewIdentity(), .{});
    w.summary_card = summary;
    summary.meta.ownership.meta.test_id = "wizard.review.summary";
    w.summary_icon = try ui.iconTint(w.cx, ui.icons.terminal, S.theme.current().accent, S.icon(20));
    w.summary_icon.?.meta.ownership.meta.test_id = "wizard.review.summary.icon";
    try summary.appendChild(w.alloc, w.summary_icon.?);
    const identity_copy = try ui.box(w.cx, .{ .width = .fill(), .min_width = 0, .flex = 1, .direction = .column, .gap = 4 }, .{});
    w.summary_name = try ui.text(w.cx, "", S.summaryName());
    w.summary_name.?.meta.ownership.meta.test_id = "wizard.review.name";
    w.summary_name.?.setStyleInline(w.alloc, .{ .width = .fill(), .height = .{ .px = 18 } });
    try identity_copy.appendChild(w.alloc, w.summary_name.?);
    w.summary_identity = try ui.textStyled(w.cx, S.hint, "");
    w.summary_identity.?.setStyleInline(w.alloc, .{ .width = .fill(), .height = .{ .px = 16 } });
    try identity_copy.appendChild(w.alloc, w.summary_identity.?);
    try summary.appendChild(w.alloc, identity_copy);
    _ = try action(w, summary, "编辑连接信息", "wizard.review.modify", 96, 28, false, w.locked, RemoteEditor.onSummaryModify, null);
    try root.appendChild(w.alloc, summary);
    const details = try ui.boxStyled(w.cx, S.reviewFields, .{});
    w.summary_details = details;
    const labels = [_][]const u8{ "协议", "目标地址", "认证账户", "认证方式", "目标验证" };
    const ids = [_][]const u8{ "wizard.review.protocol", "wizard.review.endpoint", "wizard.review.user", "wizard.review.auth", "wizard.review.verification" };
    for (0..3) |row_index| {
        const row = try ui.box(w.cx, S.reviewFieldRow(), .{});
        for (0..2) |column| {
            const index = row_index * 2 + column;
            const cell = try ui.box(w.cx, S.reviewField(), .{});
            if (index < labels.len) {
                try cell.appendChild(w.alloc, try ui.text(w.cx, labels[index], S.text(11, 400, false)));
                const value = try ui.text(w.cx, "", S.readonlyValue(undefined));
                value.meta.ownership.meta.test_id = ids[index];
                value.setStyleInline(w.alloc, .{ .width = .fill(), .height = .{ .px = 18 }, .min_width = 0 });
                w.summary_values[index] = value;
                try cell.appendChild(w.alloc, value);
            }
            try row.appendChild(w.alloc, cell);
        }
        try details.appendChild(w.alloc, row);
    }
    w.summary_endpoint = w.summary_values[1];
    // Existing advanced settings stay visible in the review, without exposing credentials.
    w.summary_options = try ui.textStyled(w.cx, S.summaryOptions, "");
    w.summary_options.?.meta.ownership.meta.test_id = "wizard.review.options";
    try details.appendChild(w.alloc, w.summary_options.?);
    try root.appendChild(w.alloc, details);
    const route_card = try ui.box(w.cx, S.reviewRoute(), .{});
    w.summary_route_card = route_card;
    const route_header = try ui.box(w.cx, S.row(28), .{});
    try route_header.appendChild(w.alloc, try ui.textStyled(w.cx, S.title, "连接路径"));
    try route_header.appendChild(w.alloc, try ui.spacer(w.cx));
    _ = try action(w, route_header, "编辑路径", "wizard.review.route.modify", 76, 28, false, w.locked, RemoteEditor.onSummaryRouteModify, null);
    try route_card.appendChild(w.alloc, route_header);
    const route_list = try ui.box(w.cx, .{ .width = .fill(), .height = .{ .fit = .{} }, .direction = .row, .flex_wrap = .wrap, .align_items = .center, .gap = 10, .flex_shrink = 0 }, .{});
    route_list.meta.ownership.meta.test_id = "wizard.review.route";
    for (0..10) |i| {
        // Keep the centered arrow with its destination when the route wraps.
        const item = try ui.box(w.cx, .{ .width = .{ .fit = .{} }, .height = .{ .px = 36 }, .direction = .row, .align_items = .center, .gap = 10, .flex_shrink = 0 }, .{});
        w.summary_route_nodes[i] = item;
        if (i != 0) {
            const arrow = try ui.iconTint(w.cx, ui.icons.arrow_right, S.theme.current().fg_2, S.icon(14));
            w.summary_route_arrows[i - 1] = arrow;
            try item.appendChild(w.alloc, arrow);
        }
        const node = try ui.box(w.cx, .{ .width = .{ .fit = .{} }, .min_width = 80, .max_width = 180, .height = .{ .px = 36 }, .direction = .column, .gap = 3, .flex_shrink = 0 }, .{});
        const name = try ui.text(w.cx, "", S.readonlyValue(undefined));
        name.setStyleInline(w.alloc, .{ .height = .{ .px = 18 }, .max_width = 180 });
        w.summary_route_names[i] = name;
        const caption = try ui.textStyled(w.cx, S.hint, "");
        caption.setStyleInline(w.alloc, .{ .height = .{ .px = 15 } });
        w.summary_route_captions[i] = caption;
        try node.appendChild(w.alloc, name);
        try node.appendChild(w.alloc, caption);
        try item.appendChild(w.alloc, node);
        try route_list.appendChild(w.alloc, item);
    }
    try route_card.appendChild(w.alloc, route_list);
    try root.appendChild(w.alloc, route_card);
    const note = try ui.textStyled(w.cx, S.paragraph, "仅保存配置不会建立会话。连接时逐跳核对身份并完成认证，不跳过失败阶段。");
    try root.appendChild(w.alloc, note);
    const card = try ui.boxStyled(w.cx, S.testResult, .{});
    w.review_test_card = card;
    card.meta.ownership.meta.test_id = "wizard.test.card";
    const header = try action(w, card, "展开检测详情", "wizard.test.toggle", 668, 18, false, null, RemoteEditor.onReviewToggle, null);
    for (header.children.items) |child| child.setDisplay(.none);
    header.setStyleInline(w.alloc, .{ .width = .fill(), .justify = .start, .background = ui.Color.TRANSPARENT, .margin = .{ .bottom = 8 } });
    const title = try ui.text(w.cx, "连接预检", S.text(12, 500, false));
    title.setStyleInline(w.alloc, .{ .width = .{ .px = 150 }, .height = .{ .px = 18 }, .flex_shrink = 0 });
    try header.appendChild(w.alloc, title);
    try header.appendChild(w.alloc, try ui.spacer(w.cx));
    w.review_path = try ui.textStyled(w.cx, S.hint, "检测中 · 详情");
    w.review_path.?.setStyleInline(w.alloc, .{ .width = .{ .px = 330 }, .min_width = 0, .height = .{ .px = 16 }, .flex_shrink = 1 });
    try header.appendChild(w.alloc, w.review_path.?);
    w.review_disclosure = try ui.iconTint(w.cx, ui.icons.chevron_down, S.theme.current().fg_3, .{ .width = .{ .px = 16 }, .height = .{ .px = 16 }, .margin = .{ .left = 3, .right = 3 }, .flex_shrink = 0 });
    try header.appendChild(w.alloc, w.review_disclosure.?);
    for (&w.test_stages, 0..) |*row, i| {
        row.node = try ui.box(w.cx, S.testStage(), .{});
        row.node.meta.ownership.meta.test_id = try ownedId(w, &id_buffer, "wizard.test.stage.{d}", i);
        row.mark = try ui.text(w.cx, "○", S.text(12, 400, false));
        row.mark.setStyleInline(w.alloc, .{ .width = .{ .px = 16 }, .height = .{ .px = 18 }, .flex_shrink = 0 });
        try row.node.appendChild(w.alloc, row.mark);
        const copy = try ui.box(w.cx, .{ .width = .fill(), .min_width = 0, .direction = .column, .gap = 3, .flex_shrink = 0 }, .{});
        row.title = try ui.text(w.cx, "", S.testStageTitle());
        row.title.setStyleInline(w.alloc, .{ .width = .fill(), .height = .{ .px = 18 } });
        row.detail = try ui.text(w.cx, "", S.testStageDetail());
        row.detail.setStyleInline(w.alloc, .{ .width = .fill(), .height = .{ .px = 17.6 } });
        try copy.appendChild(w.alloc, row.title);
        try copy.appendChild(w.alloc, row.detail);
        try row.node.appendChild(w.alloc, copy);
        try card.appendChild(w.alloc, row.node);
        row.node.setDisplay(.none);
    }
    const content = try ui.boxStyled(w.cx, S.stack, .{});
    w.review_body = content;
    try content.appendChild(w.alloc, try mountRoutePreview(w, 1));
    const test_row = try ui.box(w.cx, S.row(24), .{});
    w.res_dot = try ui.box(w.cx, .{ .width = .{ .px = 16 }, .height = .{ .px = 16 }, .border = .{ .radius = 8 }, .flex_shrink = 0 }, .{});
    w.test_status_icon = try ui.iconTint(w.cx, ui.icons.circle, S.theme.current().fg_3, .{ .width = .{ .px = 16 }, .height = .{ .px = 16 } });
    try w.res_dot.?.appendChild(w.alloc, w.test_status_icon.?);
    try test_row.appendChild(w.alloc, w.res_dot.?);
    w.res_text = try ui.textStyled(w.cx, S.paragraph, "尚未测试");
    w.res_text.?.setStyleInline(w.alloc, .{ .width = .fill(), .min_width = 0, .height = .{ .px = 16 }, .flex = 1 });
    w.res_text.?.meta.ownership.meta.test_id = "wizard.test.status";
    try test_row.appendChild(w.alloc, w.res_text.?);
    try card.appendChild(w.alloc, test_row);
    w.authentication_area = try ui.boxStyled(w.cx, S.stack, .{});
    w.authentication_area.meta.ownership.meta.test_id = "wizard.test.authentication";
    // The slot remains mounted through authentication; empty slots take no gap.
    try card.appendChild(w.alloc, w.authentication_area);
    w.authentication_area.setDisplay(.none);
    w.test_logs_area = try ui.box(w.cx, S.testLogs(), .{});
    w.test_logs_area.meta.ownership.meta.test_id = "wizard.test.logs";
    const log_header = try ui.box(w.cx, S.row(28), .{});
    const log_title = try ui.text(w.cx, "阶段日志", S.text(11, 500, false));
    log_title.setStyleInline(w.alloc, .{ .width = .{ .px = 100 }, .height = .{ .px = 16 }, .flex_shrink = 0 });
    try log_header.appendChild(w.alloc, log_title);
    try log_header.appendChild(w.alloc, try ui.spacer(w.cx));
    const filter = try action(w, log_header, "全部节点", "wizard.test.logs.filter", 112, 26, false, null, RemoteEditor.onTestFilterAll, null);
    w.test_filter_label = filter.children.items[filter.children.items.len - 1];
    const copy = try action(w, log_header, "复制日志", "wizard.test.logs.copy", 24, 24, false, null, RemoteEditor.onLogsCopy, ui.icons.copy);
    copy.setBackground(ui.Color.TRANSPARENT);
    w.test_copy_icon = copy.children.items[copy.children.items.len - 1];
    const toggle = try action(w, log_header, "展开或收起阶段日志", "wizard.test.logs.toggle", 24, 24, false, null, RemoteEditor.onLogsToggle, ui.icons.chevron_up);
    toggle.setBackground(ui.Color.TRANSPARENT);
    w.test_disclosure_icon = toggle.children.items[toggle.children.items.len - 1];
    try w.test_logs_area.appendChild(w.alloc, log_header);
    const logs = try ui.widgets.ScrollArea(.{ .height = 80, .direction = .vertical, .rubber_band_y = false }).mount(w.scope, w.cx);
    w.test_scroll = logs;
    w.logs_scroll = logs.container;
    logs.container.setStyleInline(w.alloc, .{ .width = .fill(), .height = .{ .px = 80 }, .flex_shrink = 0 });
    logs.container.meta.ownership.meta.test_id = "wizard.test.logs.viewport";
    logs.content.setStyleInline(w.alloc, .{ .width = .fill(), .height = .{ .fit = .{} }, .direction = .column, .gap = 0 });
    w.test_log_text = try ui.textStyled(w.cx, S.logs, "");
    w.test_log_text.style.width = .fill();
    try logs.content.appendChild(w.alloc, w.test_log_text);
    for (&w.test_rows) |*row| {
        row.node = try ui.box(w.cx, S.row(20), .{});
        for (&row.text, 0..) |*text, column| {
            text.* = try ui.text(w.cx, "", S.testLogText(column));
            text.*.setStyleInline(w.alloc, .{ .width = if (column == 3) .fill() else .{ .px = ([_]f32{ 56, 46, 58 })[column] }, .height = .{ .px = 16 }, .min_width = 0, .flex_shrink = 0 });
            try row.node.appendChild(w.alloc, text.*);
        }
        try logs.content.appendChild(w.alloc, row.node);
        row.node.setDisplay(.none);
    }
    try w.test_logs_area.appendChild(w.alloc, logs.container);
    const follow = try ui.box(w.cx, S.row(26), .{});
    w.test_follow_row = follow;
    w.test_follow_hint = try ui.text(w.cx, "", S.text(9.5, 400, false));
    w.test_follow_hint.?.setStyleInline(w.alloc, .{ .width = .fill(), .height = .{ .px = 16 }, .min_width = 0, .flex = 1 });
    try follow.appendChild(w.alloc, w.test_follow_hint.?);
    const follow_button = try action(w, follow, "跟随中", "wizard.test.logs.follow", 112, 26, false, null, RemoteEditor.onTestFollow, null);
    w.test_follow_label = follow_button.children.items[follow_button.children.items.len - 1];
    try w.test_logs_area.appendChild(w.alloc, follow);
    w.test_logs_area.setDisplay(.none);
    logs.container.setDisplay(.none);
    follow.setDisplay(.none);
    try content.appendChild(w.alloc, w.test_logs_area);
    try card.appendChild(w.alloc, content);
    try root.appendChild(w.alloc, card);
    w.save_error_node = try ui.textStyled(w.cx, S.paragraph, "");
    w.save_error_node.?.meta.ownership.meta.test_id = "wizard.save.error";
    w.save_error_node.?.setDisplay(.none);
    try root.appendChild(w.alloc, w.save_error_node.?);
    return root;
}

fn paintSelectTypography(node: *ui.Node) void {
    if (node.getText()) |old| {
        if (old.font_size != 12 or old.line_height != 1.5) {
            var props = old;
            props.font_size = 12;
            props.line_height = 1.5;
            node.setText(props);
        }
    }
    for (node.children.items) |child| paintSelectTypography(child);
}

fn paintCheckboxLabels(node: *ui.Node) void {
    if (node.getText()) |old| {
        var props = old;
        props.font_size = 11;
        props.line_height = 1.5;
        props.color = S.theme.current().fg_1;
        node.setText(props);
    }
    for (node.children.items) |child| paintCheckboxLabels(child);
}

fn skinSelect(w: *RemoteEditor, result: ui.widgets.SelectResult, height: f32, size: f32) void {
    result.wrapper.setStyleInline(w.alloc, .{ .height = .{ .px = height }, .flex_shrink = 0 });
    var style = S.input();
    style.height = .{ .px = height };
    style.font_size = size;
    result.trigger.setStyleInline(w.alloc, style);
    // Select owns a separate Popover trigger wrapper with the initial pixel
    // width. Let that wrapper follow its responsive field as well.
    if (result.trigger.parent) |trigger_wrapper| trigger_wrapper.setStyleInline(w.alloc, .{ .width = .fill(), .min_width = 0 });
    w.selects.append(w.alloc, result) catch {};
}
fn ownedId(w: *RemoteEditor, buf: []u8, comptime format: []const u8, value: usize) ![]const u8 {
    const value_text = try std.fmt.bufPrint(buf, format, .{value});
    const owned = try w.alloc.dupe(u8, value_text);
    errdefer w.alloc.free(owned);
    try w.owned_ids.append(w.alloc, owned);
    return owned;
}

// ── 单测：Draft 校验 / 状态机 / 摘要渲染（纯逻辑，无 UI 依赖） ────────

// 强制 UI 装配路径（mount 及其传递引用的全部私有装配函数）参与语义分析，
// 避免 Zig 惰性分析漏掉未被执行的视图构建代码。
test "refAllDecls forces analysis of the full mounting path" {
    std.testing.refAllDecls(RemoteEditor);
    std.testing.refAllDecls(@This());
}

test "Draft.validate rejects empty name host user and zero port" {
    const ok: Draft = .{ .name = "prod-db", .host = "10.200.4.18", .user = "dbadmin" };
    try ok.validate();
    try std.testing.expectError(error.MissingHost, (Draft{ .name = "n", .host = "", .user = "u" }).validate());
    try std.testing.expectError(error.MissingName, (Draft{ .name = "   ", .host = "h", .user = "u" }).validate());
    try std.testing.expectError(error.MissingUser, (Draft{ .name = "n", .host = "h", .user = "" }).validate());
    try std.testing.expectError(error.InvalidPort, (Draft{ .name = "n", .host = "h", .user = "u", .port = 0 }).validate());
    // 端口上界：u16 满量程合法；输入侧溢出在 parsePort 回退 0 再被拒绝。
    try (Draft{ .name = "n", .host = "h", .user = "u", .port = 65535 }).validate();
}

test "parsePort accepts digits only and clamps overflow to zero" {
    try std.testing.expectEqual(@as(u16, 22), parsePort("22"));
    try std.testing.expectEqual(@as(u16, 65535), parsePort("65535"));
    try std.testing.expectEqual(@as(u16, 0), parsePort("99999"));
    try std.testing.expectEqual(@as(u16, 0), parsePort("abc"));
    try std.testing.expectEqual(@as(u16, 0), parsePort("+22"));
    try std.testing.expectEqual(@as(u16, 0), parsePort("2_2"));
    try std.testing.expectEqual(@as(u16, 0), parsePort(""));
    // 首尾空白宽容（与名称/主机/用户名的 trim 语义一致）。
    try std.testing.expectEqual(@as(u16, 80), parsePort(" 80 "));
}

test "three step state machine advances retreats and gates on draft validity" {
    try std.testing.expectEqual(Step.form, stepAfter(.protocol).?);
    try std.testing.expectEqual(Step.confirm, stepAfter(.form).?);
    try std.testing.expect(stepAfter(.confirm) == null);
    try std.testing.expectEqual(Step.form, stepBefore(.confirm).?);
    try std.testing.expectEqual(Step.protocol, stepBefore(.form).?);
    try std.testing.expect(stepBefore(.protocol) == null);

    const bad: Draft = .{ .name = "", .host = "h", .user = "u" };
    const good: Draft = .{ .name = "n", .host = "h", .user = "u", .port = 22 };
    try std.testing.expect(!advanceAllowed(.protocol, bad));
    try std.testing.expect(!advanceAllowed(.form, bad));
    try std.testing.expect(advanceAllowed(.form, good));
    try std.testing.expect(!advanceAllowed(.confirm, good));

    // 默认值与 HostConfig 默认端口对齐（22），协议默认 SSH。
    var d: Draft = .{};
    try std.testing.expectEqual(@as(u16, 22), d.port);
    try std.testing.expectEqual(Protocol.ssh, d.protocol);
    _ = &d;
}

test "draft formats summary values and test line" {
    var buf: [128]u8 = undefined;
    const d: Draft = .{ .name = "prod-db", .host = "10.200.4.18", .port = 2222, .user = "dbadmin", .auth = .key, .key_path = "~/.ssh/id_ed25519" };
    try std.testing.expectEqualStrings("2222", d.formatPort(&buf));
    try std.testing.expectEqualStrings("密钥登录 · ~/.ssh/id_ed25519", d.formatAuth(&buf));

    const pw: Draft = .{ .name = "n", .host = "h", .user = "u" };
    try std.testing.expectEqualStrings("密码登录", pw.formatAuth(&buf));

    try std.testing.expectEqualStrings("✓ 连接成功 · 46ms", formatTestLine(.{ .ok = "连接成功 · 46ms" }, &buf));
    try std.testing.expectEqualStrings("✕ 目标端口不可达", formatTestLine(.{ .fail = "目标端口不可达" }, &buf));
    try std.testing.expectEqualStrings("… 正在测试连接…", formatTestLine(.pending, &buf));
    try std.testing.expectEqualStrings("尚未测试", formatTestLine(.none, &buf));
}

test "dupe deep copies every string field without aliasing" {
    const allocator = std.testing.allocator;
    const src: Draft = .{
        .name = "n",
        .host = "h",
        .user = "u",
        .group = "g",
        .password = "p",
        .key_path = "k",
        .key_passphrase = "kp",
        .encoding = "UTF-8",
        .port = 2200,
        .keepalive = false,
        .compression = true,
    };
    const copy = try src.dupe(allocator);
    defer {
        var owned = copy;
        owned.deinit(allocator);
    }
    try std.testing.expectEqualStrings("n", copy.name);
    try std.testing.expectEqualStrings("h", copy.host);
    try std.testing.expectEqualStrings("u", copy.user);
    try std.testing.expectEqualStrings("g", copy.group.?);
    try std.testing.expectEqualStrings("p", copy.password.?);
    try std.testing.expectEqualStrings("k", copy.key_path.?);
    try std.testing.expectEqualStrings("kp", copy.key_passphrase.?);
    try std.testing.expectEqualStrings("UTF-8", copy.encoding);
    try std.testing.expectEqual(@as(u16, 2200), copy.port);
    try std.testing.expect(!copy.keepalive);
    try std.testing.expect(copy.compression);
    try std.testing.expect(copy.name.ptr != src.name.ptr);
    try copy.validate();
}

const EditorKind = enum { jump_up, jump_down, jump_remove, command_remove };
const EditorAction = struct {
    wizard: *RemoteEditor,
    index: usize,
    kind: EditorKind,
    disabled: *ui.Signal(bool),
    icon: ?*ui.Node = null,
    fn cleanup(self: *EditorAction) void {
        self.wizard.alloc.destroy(self);
    }
    fn click(self: *EditorAction) void {
        const w = self.wizard;
        if (w.isLocked()) return;
        const i = self.index;
        var exit_name: ?[]const u8 = null;
        if (w.sig_socks_exit.?.get()) |text| {
            const exit_index = std.fmt.parseInt(usize, text, 10) catch w.jump_count;
            if (exit_index < w.jump_count) if (w.jump_values[exit_index].?.get()) |name| {
                exit_name = w.alloc.dupe(u8, name) catch return;
            };
        }
        defer if (exit_name) |name| w.alloc.free(name);
        switch (self.kind) {
            .jump_up, .jump_down => {
                if (i >= w.jump_count) return;
                const other = if (self.kind == .jump_up) (if (i == 0) return else i - 1) else (if (i + 1 >= w.jump_count) return else i + 1);
                const old = w.jump_values[i].?.get();
                // Values belong to different signals; preserve text before mutation.
                const saved = if (old) |v| w.alloc.dupe(u8, v) catch return else null;
                defer if (saved) |v| w.alloc.free(v);
                w.setJump(i, w.jump_values[other].?.get());
                w.setJump(other, saved);
            },
            .jump_remove => {
                if (i >= w.jump_count) return;
                for (i..w.jump_count - 1) |j| w.setJump(j, w.jump_values[j + 1].?.get());
                w.jump_count -= 1;
                w.setJump(w.jump_count, null);
            },
            .command_remove => {
                if (i >= w.command_count) return;
                for (i..w.command_count - 1) |j| w.command_values[j].?.set(w.command_values[j + 1].?.get());
                w.command_count -= 1;
                w.command_values[w.command_count].?.set("");
            },
        }
        if (exit_name) |name| {
            w.sig_socks_exit.?.set(null);
            for (w.jump_values[0..w.jump_count], 0..) |value, index| if (value.?.get()) |candidate| {
                if (!std.mem.eql(u8, name, candidate)) continue;
                var buf: [4]u8 = undefined;
                w.socks_exit_text.?.set(std.fmt.bufPrint(&buf, "{d}", .{index}) catch "");
                w.sig_socks_exit.?.set(w.socks_exit_text.?.get());
                break;
            };
        }
        w.refreshEditorRows();
        w.onFieldChange("");
    }
};
fn editorAction(self: *RemoteEditor, cx: *ui.Cx, label: []const u8, index: usize, kind: EditorKind) !*ui.Node {
    const state = try self.alloc.create(EditorAction);
    state.* = .{ .wizard = self, .index = index, .kind = kind, .disabled = try self.scope.createSignal(bool, false) };
    try self.scope.onCleanup(EditorAction, state, EditorAction.cleanup);
    try self.editor_actions.append(self.alloc, state);
    const node = try ui.widgets.Button(.{ .variant = .ghost, .a11y_label = label, .disabled = state.disabled, .base_style = S.button(28, 28, false), .on_click = cx.on(EditorAction, state, EditorAction.click) }).mount(self.scope, cx);
    node.setStyleInline(self.alloc, S.button(28, 28, false));
    const icon = switch (kind) {
        .jump_up => ui.icons.chevron_up,
        .jump_down => ui.icons.chevron_down,
        .jump_remove, .command_remove => ui.icons.x,
    };
    state.icon = try ui.iconTint(cx, icon, S.theme.current().fg_3, .{ .width = .{ .px = 14 }, .height = .{ .px = 14 } });
    try node.appendChild(self.alloc, state.icon.?);
    var id: [64]u8 = undefined;
    const prefix = switch (kind) {
        .jump_up => "wizard.route.up.",
        .jump_down => "wizard.route.down.",
        .jump_remove => "wizard.route.remove.",
        .command_remove => "wizard.command.remove.",
    };
    const value = try std.fmt.bufPrint(&id, "{s}{d}", .{ prefix, index });
    const owned = try self.alloc.dupe(u8, value);
    errdefer self.alloc.free(owned);
    try self.owned_ids.append(self.alloc, owned);
    node.meta.ownership.meta.test_id = owned;
    return node;
}

test "owned draft owns nested jump and command slices" {
    var draft = try (Draft{ .name = "n", .host = "h", .user = "u", .jump_chain = &.{ "jump1", "jump2" }, .startup_commands = &.{ "cd /tmp", "echo ready" } }).dupe(std.testing.allocator);
    defer draft.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("jump2", draft.jump_chain[1]);
    try std.testing.expectEqualStrings("echo ready", draft.startup_commands[1]);
    try std.testing.expect(draft.jump_chain[0].ptr != "jump1".ptr);
}

test "unconfigured probe fails and changes invalidate success" {
    const cx = try ui.Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    const scope = try ui.Scope.init(std.testing.allocator, null, cx.owner);
    defer scope.dispose();
    const root = try ui.box(cx, .{}, .{});
    cx.root = root;
    var wizard: RemoteEditor = .{};
    try root.appendChild(cx.allocator, try wizard.mount(cx, scope));
    wizard.loadDraft(.{ .name = "target", .host = "127.0.0.1", .user = "user", .password = "test-password" });
    wizard.onTestClick();
    try std.testing.expectEqual(TestKind.fail, wizard.test_kind);
    try std.testing.expectEqualStrings("连接探测未配置", wizard.testDetail());
    wizard.setTestResult(.{ .ok = "verified" });
    const generation = wizard.test_generation;
    wizard.onAuthKeyClick();
    try std.testing.expectEqual(TestKind.none, wizard.test_kind);
    try std.testing.expect(!wizard.setTestResultFor(generation, .{ .ok = "stale" }));
    try std.testing.expectEqual(TestKind.none, wizard.test_kind);
}
fn duplicateDraftWithFailures(allocator: std.mem.Allocator) !void {
    var draft = try (Draft{ .name = "name", .host = "host", .user = "user", .group = "group", .password = "password", .key_path = "key", .key_passphrase = "passphrase", .jump_chain = &.{ "one", "two" }, .startup_commands = &.{"command"} }).dupe(allocator);
    defer draft.deinit(allocator);
}

test "copy picker clones every draft field and leaves cancellation unchanged" {
    const cx = try ui.Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    const scope = try ui.Scope.init(std.testing.allocator, null, cx.owner);
    defer scope.dispose();
    const root = try ui.box(cx, .{}, .{});
    cx.root = root;
    var wizard: RemoteEditor = .{};
    try root.appendChild(cx.allocator, try wizard.mount(cx, scope));

    const source = [_]Draft{ .{
        .source_owner = .{ .id = @fromBackingInt(71), .revision = 5 },
        .name = "prod",
        .protocol = .sftp,
        .host = "192.0.2.10",
        .port = 2222,
        .user = "deploy",
        .group = "ops",
        .auth = .key,
        .key_path = "~/.ssh/id_ed25519",
        .key_passphrase = "secret",
        .keepalive = false,
        .compression = true,
        .strict_host_key_checking = false,
        .encoding = "GB18030",
        .socks_enabled = true,
        .socks_port = 1090,
        .socks_bind = "127.0.0.2",
        .socks_exit = 0,
        .socks_auto_start = true,
        .socks_max_connections = 17,
        .terminal_type = "screen-256color",
        .scrollback = 1234,
        .jump_chain = &.{"bastion"},
        .route = &.{@fromBackingInt(42)},
        .startup_commands = &.{ "cd /srv", "echo ready" },
    }, .{ .source_owner = .{ .id = @fromBackingInt(42), .revision = 3 }, .name = "bastion", .host = "192.0.2.11", .user = "jump", .password = "test-password" } };
    try wizard.setAssets(&source);
    wizard.loadDraft(.{ .name = "editing", .host = "old", .user = "old-user" });
    try std.testing.expect(!wizard.copied_from_existing);
    const before = wizard.currentDraft();
    wizard.onCopy(null);
    try std.testing.expectEqualStrings("editing", wizard.currentDraft().name);
    try std.testing.expectEqualStrings(before.host, wizard.currentDraft().host);
    try std.testing.expect(!wizard.copied_from_existing);

    wizard.onCopy("conn:71");
    const copy = wizard.currentDraft();
    try std.testing.expect(wizard.copied_from_existing);
    try std.testing.expect(copy.source_owner == null);
    try std.testing.expectEqual(source[0].source_owner.?, copy.copy_source_owner.?);
    try std.testing.expect(!copy.strict_host_key_checking);
    try std.testing.expectEqualStrings("prod-副本", copy.name);
    try std.testing.expectEqual(Protocol.sftp, copy.protocol);
    try std.testing.expectEqualStrings("192.0.2.10", copy.host);
    try std.testing.expectEqual(@as(u16, 2222), copy.port);
    try std.testing.expectEqualStrings("deploy", copy.user);
    try std.testing.expectEqualStrings("ops", copy.group.?);
    try std.testing.expectEqual(Auth.key, copy.auth);
    try std.testing.expectEqualStrings("~/.ssh/id_ed25519", copy.key_path.?);
    try std.testing.expect(copy.password == null);
    try std.testing.expect(copy.key_passphrase == null);
    try std.testing.expect(copy.draft_id != before.draft_id);
    try std.testing.expect(!copy.keepalive);
    try std.testing.expect(copy.compression);
    try std.testing.expectEqualStrings("GB18030", copy.encoding);
    try std.testing.expect(copy.socks_enabled and copy.socks_auto_start);
    try std.testing.expectEqual(@as(u16, 1090), copy.socks_port);
    try std.testing.expectEqual(@as(u16, 17), copy.socks_max_connections);
    try std.testing.expectEqualStrings("127.0.0.2", copy.socks_bind);
    try std.testing.expectEqual(@as(?usize, 0), copy.socks_exit);
    try std.testing.expectEqualStrings("screen-256color", copy.terminal_type);
    try std.testing.expectEqual(@as(u32, 1234), copy.scrollback);
    try std.testing.expectEqualStrings("bastion", copy.jump_chain[0]);
    try std.testing.expectEqualStrings("echo ready", copy.startup_commands[1]);
}

test "draft deep copy releases partial allocations on every failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, duplicateDraftWithFailures, .{});
}

test "reordering jumps preserves SOCKS exit identity" {
    const cx = try ui.Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    const scope = try ui.Scope.init(std.testing.allocator, null, cx.owner);
    defer scope.dispose();
    const root = try ui.box(cx, .{}, .{});
    cx.root = root;
    var wizard: RemoteEditor = .{};
    try root.appendChild(cx.allocator, try wizard.mount(cx, scope));
    const assets = [_]Draft{ .{ .source_owner = .{ .id = @fromBackingInt(1) }, .name = "a", .host = "a", .user = "u" }, .{ .source_owner = .{ .id = @fromBackingInt(2) }, .name = "b", .host = "b", .user = "u" } };
    try wizard.setAssets(&assets);
    wizard.loadDraft(.{ .name = "target", .host = "host", .user = "u", .route = &.{ @fromBackingInt(1), @fromBackingInt(2) }, .socks_exit = 0 });
    var edit_action: EditorAction = .{ .wizard = &wizard, .index = 0, .kind = .jump_down };
    edit_action.click();
    try std.testing.expectEqualStrings("b", wizard.currentDraft().jump_chain[0]);
    try std.testing.expectEqual(@as(?usize, 1), wizard.currentDraft().socks_exit);
    edit_action.index = 1;
    edit_action.kind = .jump_remove;
    edit_action.click();
    try std.testing.expect(wizard.currentDraft().socks_exit == null);
}

test "basic step can reach authentication before credentials are entered" {
    const cx = try ui.Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    const scope = try ui.Scope.init(std.testing.allocator, null, cx.owner);
    defer scope.dispose();
    const root = try ui.box(cx, .{}, .{});
    cx.root = root;
    var wizard: RemoteEditor = .{};
    try root.appendChild(cx.allocator, try wizard.mount(cx, scope));
    wizard.loadDraft(.{ .name = "VM", .host = "192.0.2.10", .user = "root" });
    try std.testing.expect(wizard.validBasicDraft());
    try std.testing.expect(wizard.validDraft());
    wizard.onNext1Click();
    try std.testing.expectEqual(Step.form, wizard.step);
    wizard.onNext2Click();
    try std.testing.expectEqual(Step.confirm, wizard.step);
    wizard.sig_password.?.set("test-only-password");
    wizard.onNext2Click();
    try std.testing.expectEqual(Step.confirm, wizard.step);
}

test "SSH host inheritance survives wizard draft copy and unrelated edit" {
    var registry = try hosts_mod.Registry.parse(std.testing.allocator, "[[hosts]] name=\"inherited\";host=\"h\";user=\"u\"\n" ++
        "[[hosts]] name=\"explicit\";host=\"h\";user=\"u\";terminal_type=\"xterm-256color\";compression=false\n");
    defer registry.deinit();
    const cx = try ui.Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    const scope = try ui.Scope.init(std.testing.allocator, null, cx.owner);
    defer scope.dispose();
    cx.root = try ui.box(cx, .{}, .{});
    var wizard: RemoteEditor = .{};
    try cx.root.?.appendChild(cx.allocator, try wizard.mount(cx, scope));
    for (registry.hosts) |host| {
        var draft = try Draft.fromHost(host).dupe(std.testing.allocator);
        defer draft.deinit(std.testing.allocator);
        draft.port = 2222;
        const edited = try draft.toHostConfig();
        try std.testing.expectEqual(host.terminal_type_explicit, edited.terminal_type_explicit);
        try std.testing.expectEqual(host.compression_explicit, edited.compression_explicit);
        wizard.loadDraft(draft);
        wizard.sig_name.?.set("renamed");
        const saved = try wizard.currentDraft().toHostConfig();
        try std.testing.expectEqual(host.terminal_type_explicit, saved.terminal_type_explicit);
        try std.testing.expectEqual(host.compression_explicit, saved.compression_explicit);
    }
    wizard.loadDraft(Draft.fromHost(registry.hosts[0]));
    wizard.onCompressionChanged(true);
    wizard.onCompressionChanged(false);
    const explicit_false = try wizard.currentDraft().toHostConfig();
    try std.testing.expect(explicit_false.compression_explicit);
    try std.testing.expect(!explicit_false.compression);
}
