//! Production three-step connection wizard. Draft slices are borrowed only for
//! the duration of on_result/on_test; asynchronous consumers must use Draft.dupe
//! and release the result with Draft.deinit. Assets supplied via setAssets remain
//! borrowed until replaced or the wizard is disposed. No simulated probe success.

const std = @import("std");
const ui = @import("ui");
const S = @import("../../ui/wizard_styles.zig");
const Stepper = @import("../../ui/connection_stepper.zig");
const hosts_mod = @import("../../config/hosts.zig");
const identity = @import("../../host/identity.zig");
pub const TestProgress = @import("../../ui/wizard_test_progress.zig");
const auth_options = [_]ui.widgets.checkbox.RadioOption{
    .{ .value = "password", .label = "密码", .test_id = "wizard.auth.password" },
    .{ .value = "key", .label = "私钥文件", .test_id = "wizard.auth.key" },
    .{ .value = "agent", .label = "SSH Agent", .test_id = "wizard.auth.agent" },
};

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
    save_password: bool = @import("../../host/plugin_ui_contract.zig").default_save_password,
    key_path: ?[]const u8 = null,
    key_passphrase: ?[]const u8 = null,
    save_key_passphrase: bool = false,
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
    scrollback: u32 = 25000,
    scrollback_explicit: bool = false,
    jump_chain: []const []const u8 = &.{},
    route: []const identity.ConnectionId = &.{},
    startup_commands: []const []const u8 = &.{},
    auto_shell_integration: ?bool = null,
    command_info: ?bool = null,

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
            .save_password = true,
            .key_path = host.identity_file,
            .key_passphrase = host.key_passphrase,
            .save_key_passphrase = host.key_passphrase != null,
            .keepalive = host.keepalive,
            .compression = host.compression,
            .compression_explicit = host.compression_explicit,
            .strict_host_key_checking = host.strict_host_key_checking,
            .terminal_type = host.terminal_type,
            .terminal_type_explicit = host.terminal_type_explicit,
            .scrollback = host.scrollback,
            .scrollback_explicit = host.scrollback_explicit or host.scrollback != 25000,
            .route = host.route,
            .jump_chain = host.jump_chain,
            .startup_commands = host.startup_commands,
            .auto_shell_integration = host.auto_shell_integration,
            .command_info = host.command_info,
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
            .scrollback_explicit = self.scrollback_explicit,
            .route = self.route,
            .jump_chain = self.jump_chain,
            .startup_commands = self.startup_commands,
            .auto_shell_integration = self.auto_shell_integration,
            .command_info = self.command_info,
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
    /// credentials into Keychain and serializes only their opaque references.
    pub fn toPersistentHostConfig(self: Draft) !hosts_mod.HostConfig {
        var host = try self.toHostConfig();
        if (!self.save_password) host.password = null;
        if (!self.save_key_passphrase) host.key_passphrase = null;
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
pub const SaveFailure = struct {
    stage: enum { save, open, stash },
    cause: anyerror,

    fn message(self: SaveFailure) []const u8 {
        return switch (self.stage) {
            .open => "配置已保存，但未能打开会话。可以重新连接。",
            .stash => "无法暂存连接。请在当前窗口继续填写或保存。",
            .save => switch (self.cause) {
                error.DuplicateConnectionName => "已有同名连接，请修改连接名称。",
                error.FileConflict => "连接配置文件已被修改。请记下连接信息，重新打开 ZeroWork 后再保存。",
                error.RevisionConflict => "原连接已被修改，请重新打开该连接的编辑页。",
                error.ConnectionNotFound => "原连接已被删除，请重新新建连接。",
                error.StaleGroup, error.GroupNotFound, error.InvalidGroup => "无法保存到当前分组，请重新选择分组。",
                error.MissingRouteReference, error.InvalidRouteProtocol, error.RouteCycle, error.DuplicateRoute => "连接路径已失效，请检查跳板配置。",
                error.WouldBlock, error.FileBusy => "连接配置正在被使用，请稍后重试。",
                error.AccessDenied, error.PermissionDenied, error.ReadOnlyFileSystem, error.NotDir, error.IsDir => "无法写入连接配置文件，请检查应用数据目录。",
                error.NoSpaceLeft, error.DiskQuota => "磁盘空间不足，无法保存连接。",
                error.WriteFailed, error.InputOutput => "写入连接配置文件失败。请复制错误详情以便排查。",
                error.HostRegistryTooLarge => "连接配置文件已达到大小上限。",
                error.CredentialMissing => "钥匙串中找不到已有的凭据，请检查钥匙串。",
                error.CredentialAuthenticationCanceled => "已取消系统认证。请重试并完成认证。",
                error.CredentialAuthenticationFailed => "系统认证未通过。请重试并完成认证。",
                error.CredentialDenied, error.CredentialLocked, error.CredentialUnavailable, error.CredentialStorageFailure => "无法访问系统钥匙串，请解锁或授权后重试。",
                error.OutOfMemory => "内存不足，无法保存连接。",
                else => "连接未保存。请复制错误详情以便排查。",
            },
        };
    }
};

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
    sig_shell_integration: ?*ui.Signal(?[]const u8) = null,
    sig_command_info: ?*ui.Signal(?[]const u8) = null,
    logs_open: ?*ui.Signal(bool) = null,
    header: ?*ui.Node = null,
    title: ?*ui.Node = null,
    body: ?*ui.Node = null,
    footer: ?*ui.Node = null,
    back_btn: ?*ui.Node = null,
    cancel_btn: ?*ui.Node = null,
    save_only_btn: ?*ui.Node = null,
    test_btn: ?*ui.Node = null,
    strict_checkbox: ?*ui.Node = null,
    compression_checkbox: ?*ui.Node = null,
    remember_checkbox: ?*ui.Node = null,
    remember_passphrase_checkbox: ?*ui.Node = null,
    auth_group: ?*ui.Node = null,
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
    step_connectors: [3]?*ui.Node = @splat(null),
    step_details: [3]?*ui.Node = @splat(null),
    step_disabled: [3]?*ui.Signal(bool) = @splat(null),
    step_styles: [3]?*ui.Signal(ui.BoxStyle) = @splat(null),
    scrolls: [3]?ui.widgets.ScrollAreaResult = @splat(null),
    route_chain_scroll: ?ui.widgets.ScrollAreaResult = null,
    route_vertical: ?bool = null,
    route_edges: [9]?RouteEdge = @splat(null),
    route_hop_controls: [8]?*RouteHopControl = @splat(null),
    route_picker: ?*RoutePicker = null,
    route_reveal: ?usize = null,
    route_hint: ?*ui.Node = null,
    summary_identity: ?*ui.Node = null,
    summary_card: ?*ui.Node = null,
    summary_options: ?*ui.Node = null,
    summary_name: ?*ui.Node = null,
    summary_endpoint: ?*ui.Node = null,
    summary_edit: ?*ui.Node = null,
    summary_route_edit: ?*ui.Node = null,
    summary_values: [5]?*ui.Node = @splat(null),
    summary_route_card: ?*ui.Node = null,
    summary_route_nodes: [10]?*ui.Node = @splat(null),
    summary_route_names: [10]?*ui.Node = @splat(null),
    summary_route_captions: [10]?*ui.Node = @splat(null),
    summary_route_icons: [10]?*ui.Node = @splat(null),
    summary_route_scroll: ?ui.widgets.ScrollAreaResult = null,
    summary_note: ?*ui.Node = null,
    review_layout_compact: ?bool = null,
    route_chrome: bool = false,
    protocol_icon: ?*ui.Node = null,
    protocol_select_icon: ?*ui.Node = null,
    protocol_header: ?*ui.Node = null,
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
    copy_footer: ?*ui.Node = null,
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
    test_copy_feedback: ?*@import("../../ui/copy_button.zig").Button = null,
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
    suspend_draft: ?struct {
        context: *anyopaque,
        save: *const fn (*anyopaque, Draft, bool) anyerror!void,
    } = null,
    resume_on_close: bool = false,
    save_error_banner: ?*ui.Node = null,
    save_error_icon: ?*ui.Node = null,
    save_error_node: ?*ui.Node = null,
    save_error_hint: ?*ui.Node = null,
    save_error_rename: ?*ui.Node = null,
    save_error_copy: ?*@import("../../ui/copy_button.zig").Button = null,
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
    jump_options: [8]?*ui.Signal([]const ui.widgets.SelectOption) = @splat(null),
    jump_text: [8]?*ui.Signal([]const u8) = @splat(null),
    socks_exit_text: ?*ui.Signal([]const u8) = null,
    jump_arrows: [8]?*ui.Node = @splat(null),
    jump_arrow_labels: [8]?*ui.Node = @splat(null),
    jump_actions: [8]?*ui.Node = @splat(null),
    exit_options: ?*ui.Signal([]const ui.widgets.SelectOption) = null,
    exit_labels: [8][128]u8 = undefined,
    topology_chain: ?*ui.Node = null,
    jump_count: usize = 0,
    // Direct access hides the route without discarding its in-progress draft.
    dormant_jump_count: usize = 0,
    dormant_socks_exit: ?usize = null,
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
    sig_scrollback_hint: ?*ui.Signal([]const u8) = null,
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
    shell_integration_field: ?*ui.Node = null,
    command_info_row: ?*ui.Node = null,
    socks_details: ?*ui.Node = null,
    commands_details: ?*ui.Node = null,
    advanced_expanded: bool = false,
    height_motion: @import("../../ui/layout_motion.zig").Height = .{},
    advanced_disclosure: ?*@import("../../ui/layout_motion.zig").Disclosure = null,
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
    group_edited: bool = false,
    sig_host: ?*ui.Signal([]const u8) = null,
    sig_port: ?*ui.Signal([]const u8) = null,
    sig_user: ?*ui.Signal([]const u8) = null,
    sig_password: ?*ui.Signal([]const u8) = null,
    sig_save_password: ?*ui.Signal(bool) = null,
    sig_key_path: ?*ui.Signal([]const u8) = null,
    sig_key_passphrase: ?*ui.Signal([]const u8) = null,
    sig_save_key_passphrase: ?*ui.Signal(bool) = null,
    sig_encoding: ?*ui.Signal([]const u8) = null,
    loaded_scrollback_explicit: bool = false,
    scrollback_default: u32 = 25000,
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
    password_input: ?ui.widgets.input.InputResult = null,
    password_control: ?*ui.Node = null,
    password_reveal_button: ?*ui.Node = null,
    password_reveal_error: ?*ui.Node = null,
    password_reveal_disabled: ?*ui.Signal(bool) = null,
    password_authorization: @import("../../platform/password_reveal.zig").Request = .{},
    password_visible: bool = false,
    password_visible_until: i128 = 0,
    password_approval_deadline: i128 = 0,
    cred_key_row: ?*ui.Node = null,
    topo_name: ?*ui.Node = null,
    topo_addr: ?*ui.Node = null,
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
        self.painted_colors = S.theme.current();
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
        self.sig_scrollback = try scope.createText("", .{});
        self.sig_scrollback_hint = try scope.createText("", .{});
        self.refreshScrollbackHint();
        for (&self.jump_values) |*v| v.* = try scope.createSignal(?[]const u8, null);
        for (&self.jump_options) |*v| v.* = try scope.createList(ui.widgets.SelectOption, &.{});
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
        self.password_reveal_disabled = try scope.createSignal(bool, true);
        self.sig_save_password = try scope.createSignal(bool, true);
        self.sig_key_path = try scope.createText("", .{});
        self.sig_key_passphrase = try scope.createText("", .{});
        self.sig_save_key_passphrase = try scope.createSignal(bool, false);
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
        self.sig_shell_integration = try scope.createSignal(?[]const u8, "inherit");
        self.sig_command_info = try scope.createSignal(?[]const u8, "inherit");
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
        self.protocol_icon = try ui.iconTint(cx, ui.icons.plug, S.theme.current().accent, S.icon(18));
        self.protocol_icon.?.meta.ownership.meta.test_id = "wizard.protocol.icon";
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
        self.protocol_header = protocol.wrapper;
        try header.appendChild(self.alloc, protocol.wrapper);
        _ = try action(self, header, "关闭向导", "wizard.close", 22, 22, false, null, cancel, ui.icons.x);
        try modal.body.appendChild(self.alloc, header);
        const body = try ui.box(cx, S.body(), .{});
        self.body = body;
        const stepper = try Stepper.row(cx);
        self.stepper = stepper;
        for (0..3) |i| {
            const ctx = try self.alloc.create(StepAction);
            ctx.* = .{ .wizard = self, .step = @fromBackingInt(@intCast(i)) };
            try scope.onCleanup(StepAction, ctx, StepAction.cleanup);
            self.step_disabled[i] = try scope.createSignal(bool, i != 0);
            self.step_styles[i] = try scope.createSignal(ui.BoxStyle, S.step(i == 0));
            const entry = try Stepper.append(cx, scope, stepper, i, ([_][]const u8{ "wizard.step.identity", "wizard.step.route", "wizard.step.review" })[i], self.step_disabled[i].?, self.step_styles[i].?, cx.on(StepAction, ctx, StepAction.click));
            self.step_buttons[i] = entry.button;
            self.step_numbers[i] = entry.badge;
            self.step_digits[i] = entry.digit;
            self.step_checks[i] = entry.check;
            self.step_titles[i] = entry.title;
            self.step_connectors[i] = entry.connector_before;
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
            if (i <= 1) scroll.content.setStyleInline(self.alloc, .{ .padding = .{ .left = 4, .right = 20, .bottom = 20 } });
            try scroll.content.appendChild(self.alloc, content);
            try body.appendChild(self.alloc, scroll.container);
            self.scrolls[i] = scroll;
        }
        self.step1_scroll = self.scrolls[0].?.container;
        self.step2_scroll = self.scrolls[1].?.container;
        self.step1_scroll_state = self.scrolls[0].?.state;
        self.step2_scroll_state = self.route_chain_scroll.?.state;
        self.step1_scroll_content = self.scrolls[0].?.content;
        self.step2_scroll_content = self.route_chain_scroll.?.content;
        try modal.body.appendChild(self.alloc, body);
        try modal.body.appendChild(self.alloc, try mountSaveError(self));
        const footer = try ui.box(cx, S.footer(), .{});
        self.footer = footer;
        footer.meta.ownership.meta.test_id = "wizard.footer";
        self.back_btn = try action(self, footer, "上一步", "wizard.back", 64, 34, false, self.locked, onBackClick, null);
        self.cancel_btn = try action(self, footer, "取消", "wizard.cancel", 52, 34, false, null, onCancelClick, null);
        try footer.appendChild(self.alloc, try ui.spacer(cx));
        self.test_btn = try action(self, footer, "测试连接", "wizard.test", 76, 34, false, self.test_action_disabled, onTestClick, null);
        self.save_only_btn = try action(self, footer, "仅保存", "wizard.save_only", 64, 34, false, self.save_disabled, onSaveOnlyClick, null);
        self.next1_btn = try action(self, footer, "下一步", "wizard.next.identity", 94, 34, true, self.next1_disabled, onNext1Click, null);
        self.next2_btn = try action(self, footer, "下一步", "wizard.next.route", 64, 34, true, self.next2_disabled, onNext2Click, null);
        self.save_btn = try action(self, footer, "保存并连接", "wizard.save", 88, 34, true, self.open_disabled, onSaveClick, null);
        try modal.body.appendChild(self.alloc, footer);
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
        self.resetPasswordVisibility();
        // This guard scope is created before Input child scopes. Restore SDK
        // handlers while their nodes and edit states still exist.
        for (self.field_feedback.items) |feedback| feedback.releaseBlur();
    }

    fn removeViewportHook(self: *RemoteEditor) void {
        self.password_authorization.cancel();
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
        self.pollPasswordVisibility();
        for (self.selects.items) |select| {
            paintSelectTypography(select.trigger);
            paintSelectTypography(select.panel);
            paintSelectMenu(select);
            // Select's reactive label restores its mount-time palette after
            // loadDraft/value updates. Reapply the live role to that owned
            // content only, preserving placeholder and option semantics.
            const selected = if (select.value) |value| value.peek() != null else false;
            paintSelectContent(select.content_slot, if (selected) S.theme.current().fg_2 else S.theme.current().fg_3);
        }
        if (self.startup_textarea) |area| paintSelectTypography(area.input);
        for (self.inputs.items) |input| if (input.state.text_display_node) |text| paintInputTypography(text);
        if (self.remember_checkbox) |checkbox| paintCheckboxLabels(checkbox);
        if (self.remember_passphrase_checkbox) |checkbox| paintCheckboxLabels(checkbox);
        if (self.compression_checkbox) |group| paintAuthLabels(group);
        if (self.auth_group) |group| paintAuthLabels(group);
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
        if (self.test_reveal_pending and self.step == .confirm) {
            self.test_reveal_pending = false;
            const area = self.scrolls[2].?;
            area.state.content_height = area.content.globalRect().h;
            area.state.viewport_height = area.container.globalRect().h;
            if (self.save_failure != null) {
                ui.widgets.scrollIntoView(area.state, area.content, self.res_text.?, .nearest);
            } else {
                ui.widgets.scrollIntoView(area.state, area.content, self.review_test_card.?, .start);
            }
        }
        self.updateTestScroll();
        if (self.updateViewport()) return .needs_layout;
        if (self.resizeRoutePreview(&self.route_previews[1])) return .needs_layout;
        if (self.route_picker) |picker| if (picker.update()) return .needs_layout;
        if (self.route_reveal) |index| {
            self.route_reveal = null;
            const area = self.route_chain_scroll.?;
            area.state.content_height = area.content.globalRect().h;
            area.state.viewport_height = area.container.globalRect().h;
            ui.widgets.scrollIntoView(area.state, area.content, self.route_previews[0].nodes[index + 1].?, .nearest);
        }
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
        const compact = S.compactWindow(self.cx.viewport.width, self.cx.viewport.height);
        const review = self.step == .confirm;
        const route = self.step == .form;
        const body_padding = ui.Padding{ .left = 24, .right = 24 };
        const footer_padding: f32 = if (route) 11 else if (compact and !review) 10 else 13;
        const footer_height = 34 + 2 * footer_padding;
        const footer_needs_layout = if (self.footer) |footer|
            footer.style.height != .px or footer.style.height.px != footer_height
        else
            false;
        var geometry_changed = false;
        if (self.body) |body| if (!std.meta.eql(body.style.padding, body_padding) or self.review_layout_compact != compact or self.route_chrome != route or footer_needs_layout) {
            self.review_layout_compact = compact;
            self.route_chrome = route;
            body.setStyleInline(self.alloc, .{ .padding = body_padding, .gap = if (route) 16 else 12 });
            for (self.scrolls, 0..) |slot, i| if (slot) |scroll| {
                scroll.content.setStyleInline(self.alloc, .{ .padding = if (i == 2) .{ .bottom = 8 } else if (i == 1) .{} else .{ .bottom = 12 } });
            };
            if (self.stepper) |stepper| stepper.setStyleInline(self.alloc, S.reviewStepTrack(compact));
            if (self.confirm_card) |card| card.setStyleInline(self.alloc, .{ .gap = if (compact) 12 else 16 });
            if (self.summary_card) |card| card.setStyleInline(self.alloc, .{ .height = .{ .px = if (compact) 58 else 78 } });
            for ([_]?*ui.Node{ self.summary_details, self.summary_route_card }) |slot| if (slot) |card| {
                card.setStyleInline(self.alloc, .{ .height = .{ .px = if (compact) 134 else 178 }, .padding = .{ .left = 16, .right = 16, .top = if (compact) 4 else 12 } });
            };
            const row_height = S.reviewRouteRowHeight(compact);
            if (self.summary_route_scroll) |scroll| scroll.container.setStyleInline(self.alloc, .{ .height = .{ .px = 3 * row_height } });
            for (self.summary_route_nodes) |slot| if (slot) |node| node.setStyleInline(self.alloc, .{ .height = .{ .px = row_height } });
            if (self.footer) |footer| {
                footer.setStyleInline(self.alloc, .{ .height = .{ .px = footer_height }, .padding = .{ .left = 24, .right = 24, .top = footer_padding, .bottom = footer_padding } });
                footer.setBackground(if (route) ui.Color.TRANSPARENT else S.footer().background.?);
            }
            geometry_changed = true;
        };
        if (route) geometry_changed = self.layoutRoute() or geometry_changed;
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
        const width = @min(S.width, S.availableModalWidth(self.cx.viewport.width));
        const desired_h = self.preferredModalHeight();
        const height = @min(desired_h, S.availableModalHeight(self.cx.viewport.height, compact));
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

    pub fn preferredModalHeight(self: *RemoteEditor) f32 {
        const compact = S.compactWindow(self.cx.viewport.width, self.cx.viewport.height);
        const limit = @min(S.remote_max_height, S.availableModalHeight(self.cx.viewport.height, compact));
        const target = @min(self.contentModalHeight(compact), limit);
        return @min(limit, self.height_motion.sample(self.cx, target, true));
    }

    fn routeIsVertical(self: *const RemoteEditor) bool {
        return self.jump_count > 1 or @min(S.width, S.availableModalWidth(self.cx.viewport.width)) < 728;
    }

    fn routeChromeHeight(self: *const RemoteEditor, compact: bool) f32 {
        var height: f32 = if (compact) 276 else 284;
        if (self.route_empty_hint) |hint| {
            if (hint.style.display != .none) height += 24;
        }
        if (self.sftpRouteUnavailable()) height += 24;
        return height;
    }

    const route_endpoint_height: f32 = 46;

    fn routeNaturalHeight(self: *const RemoteEditor) f32 {
        if (self.jump_count == 0) return 0;
        if (!self.routeIsVertical()) return 68;
        const jumps: f32 = @floatFromInt(self.jump_count);
        return 12 + 2 * route_endpoint_height + jumps * 52 + (jumps + 1) * 38;
    }

    fn layoutRoute(self: *RemoteEditor) bool {
        const area = self.route_chain_scroll orelse return false;
        const compact = S.compactWindow(self.cx.viewport.width, self.cx.viewport.height);
        const limit = @min(S.remote_max_height, S.availableModalHeight(self.cx.viewport.height, compact));
        const height = @min(self.routeNaturalHeight(), @max(52, limit - self.routeChromeHeight(compact)));
        var changed = false;
        if (area.container.style.height != .px or area.container.style.height.px != height) {
            area.container.setStyleInline(self.alloc, .{ .height = .{ .px = height } });
            if (self.routeNaturalHeight() > height) area.state.onScrollActivity();
            changed = true;
        }
        const vertical = self.routeIsVertical();
        if (self.route_vertical != vertical) {
            self.route_vertical = vertical;
            area.content.setStyleInline(self.alloc, .{ .width = .fill(), .height = .{ .fit = .{} }, .direction = if (vertical) .column else .row, .align_items = .center, .gap = 0, .padding = .{ .left = 12, .right = if (vertical) 16 else 12, .top = 6, .bottom = 6 } });
            for (self.route_previews[0].nodes, 0..) |entry, index| if (entry) |node| {
                const hop = index != 0 and index != 9;
                var style = S.row(if (!vertical) 56 else if (hop) 52 else route_endpoint_height);
                style.padding = .{ .left = 10, .right = 8 };
                style.gap = 9;
                if (!vertical and index == 0) style.width = .{ .px = 110 };
                if (!vertical and hop) style.width = .{ .px = 216 };
                if (!vertical and index == 9) style.flex = 1;
                style.min_width = 0;
                style.border = .{ .radius = 7 };
                node.setStyleInline(self.alloc, style);
            };
            for (self.route_edges) |entry| if (entry) |edge| edge.layout(self, vertical);
            ui.widgets.setScrollY(area.state, area.content, 0);
            changed = true;
        }
        return changed;
    }

    fn contentModalHeight(self: *const RemoteEditor, compact: bool) f32 {
        if (self.step == .form) return self.routeChromeHeight(compact) + self.routeNaturalHeight();
        if (self.step == .confirm) {
            if (self.review_expanded or (self.test_kind != .none and self.save_failure == null)) return S.remote_max_height;
            if (compact) return S.review_compact_height;
            if (self.save_failure != null) return if (self.test_kind != .none) 564 else 524;
            return S.review_height;
        }
        if (self.step == .protocol) {
            if (self.scrolls[0]) |scroll| {
                const disclosure_motion = self.advanced_disclosure.?;
                const expanded_height = if (self.advanced_expanded) disclosure_motion.content.globalRect().h else 0;
                const content_height = scroll.content.globalRect().h - disclosure_motion.root.globalRect().h + expanded_height;
                if (content_height > 0) {
                    const header_height: f32 = if (compact and self.embedded) 48 else 52;
                    const footer_height: f32 = if (compact) 54 else 60;
                    const track_margin: f32 = if (compact) 4 else 8;
                    return header_height + track_margin + 36 + 12 + content_height + footer_height;
                }
            }
        }
        return S.remote_max_height;
    }

    /// Presents the host's current global defaults. These are read-only facts,
    /// separate from the connection draft and any already-frozen probe source.
    /// May be called before mount; no placeholder measurements are inferred.
    pub fn setScrollbackDefault(self: *RemoteEditor, limit: u32) void {
        if (self.scrollback_default == limit and self.sig_scrollback_hint != null) return;
        self.scrollback_default = limit;
        self.refreshScrollbackHint();
    }
    fn refreshScrollbackHint(self: *RemoteEditor) void {
        const hint = self.sig_scrollback_hint orelse return;
        var buffer: [96]u8 = undefined;
        hint.set(if (self.scrollback_default == 0) "继承全局：0（不限制）" else std.fmt.bufPrint(&buffer, "继承全局：{d} 行", .{self.scrollback_default}) catch unreachable);
    }

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
        self.group_edited = true;
        self.sig_group.?.set(value orelse "");
        self.onFieldChange("");
    }
    fn onGroupInput(self: *RemoteEditor, _: []const u8) void {
        if (self.isLocked()) return;
        self.group_name_pending = false;
        self.group_edited = true;
        self.sig_group_selection.?.set(null);
        self.onFieldChange("");
    }
    pub fn loadDraft(self: *RemoteEditor, draft: Draft) void {
        self.resetPasswordVisibility();
        // Loading an existing host is the edit path.  A later save should
        // update that host unless the user explicitly picks another source
        // from the copy row after this load.
        self.copied_from_existing = false;
        self.group_edited = false;
        self.loaded_scrollback_explicit = draft.scrollback_explicit or draft.scrollback != 25000;
        self.dormant_jump_count = 0;
        self.dormant_socks_exit = null;
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
        self.resume_on_close = false;
        self.source_owner = draft.source_owner;
        self.furthest_step = .protocol;
        self.copy_source_owner = draft.copy_source_owner;
        self.strict_host_key_checking = draft.strict_host_key_checking;
        self.sig_strict.?.set(draft.strict_host_key_checking);
        self.sig_strict_policy.?.set(if (draft.strict_host_key_checking) "true" else "false");
        self.sig_compression.?.set(draft.compression);
        self.sig_shell_integration.?.set(if (draft.auto_shell_integration) |enabled| if (enabled) "on" else "off" else "inherit");
        self.sig_command_info.?.set(if (draft.command_info) |enabled| if (enabled) "on" else "off" else "inherit");
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
        self.sig_save_key_passphrase.?.set(draft.save_key_passphrase);
        self.sig_encoding.?.set(draft.encoding);
        self.sig_terminal.?.set(draft.terminal_type);
        self.terminal_type_explicit = draft.terminal_type_explicit;
        self.sig_scrollback.?.set(if (self.loaded_scrollback_explicit) (std.fmt.bufPrint(&buf, "{d}", .{draft.scrollback}) catch "25000") else "");
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
            self.group_edited = true;
            self.copy_source_owner = asset.source_owner;
            self.source_owner = null;
            self.copied_from_existing = true;
            self.draft_id = allocateDraftId() catch {
                self.identity_exhausted = true;
                return;
            };
            self.sig_save_password.?.set(asset.save_password);
            self.sig_save_key_passphrase.?.set(false);
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
        if (self.asset_options) |all_options| {
            const entries = self.alloc.dupe(ui.widgets.SelectOption, all_options.get()) catch return;
            defer self.alloc.free(entries);
            for (self.jump_options, 0..) |options, row_index| {
                for (entries) |*entry| {
                    entry.disabled = false;
                    for (self.jump_values[0..self.jump_count], 0..) |selected, selected_index| {
                        if (selected_index == row_index) continue;
                        if (selected.?.get()) |value| if (std.mem.eql(u8, value, entry.value)) {
                            entry.disabled = true;
                        };
                    }
                }
                if (options) |value| value.set(entries);
            }
        }
        for (self.command_rows, 0..) |row, i| if (row) |node| node.setDisplay(if (i < self.command_count and self.startup_enabled) .flex else .none);
        var choices: [9]ui.widgets.SelectOption = undefined;
        choices[0] = .{ .value = "", .label = "链路末端" };
        var choice_count: usize = 1;
        const indices = [_][]const u8{ "0", "1", "2", "3", "4", "5", "6", "7" };
        for (0..8) |i| {
            if (self.jump_actions[i]) |actions| actions.setDisplay(if (i < self.jump_count) .flex else .none);
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
        if (self.command_info_row) |node| node.setDisplay(if (self.protocol == .ssh) .flex else .none);
        if (self.step2_advanced) |node| {
            const gap: f32 = if (self.advanced_expanded) 4 else 0;
            if (node.style.gap != gap) node.setStyleInline(self.alloc, .{ .gap = gap });
        }
        if (self.advanced_disclosure) |section_motion| section_motion.setExpanded(self.advanced_expanded);
        self.paintAdvancedToggle();
        if (self.identity_body) |node| node.setDisplay(if (self.identity_expanded) .flex else .none);
        if (self.auth_body) |node| node.setDisplay(if (self.auth_expanded) .flex else .none);
        if (self.route_body) |node| node.setDisplay(if (self.route_expanded) .flex else .none);
        if (self.route_chain_scroll) |area| area.container.setDisplay(if (has_jumps) .flex else .none);
        if (self.route_hint) |node| node.setDisplay(if (self.sftpRouteUnavailable()) .flex else .none);
        self.refreshRoutePreview(&self.route_previews[0]);
        self.refreshRoutePreview(&self.route_previews[1]);
        for (self.route_hop_controls) |slot| if (slot) |control| control.refresh();
        if (self.route_picker) |picker| picker.dirty = true;
        self.refreshTestProjection() catch {};
    }
    fn advancedInk(self: *const RemoteEditor) ui.Color {
        const colors = S.theme.current();
        return if (self.advanced_expanded) colors.accent_ink else colors.fg_2;
    }

    fn paintAdvancedToggle(self: *RemoteEditor) void {
        if (self.advanced_chevron) |node| {
            paintIcon(node, if (self.advanced_expanded) ui.icons.chevron_down else ui.icons.chevron_right, 14, self.advancedInk());
        }
    }

    fn refreshAccessChoices(self: *RemoteEditor) void {
        if (self.route_card) |card| card.setBackground(if (self.jump_count > 0) S.theme.popupSelection() else ui.Color.TRANSPARENT);
        for (self.route_choices, 0..) |entry, index| if (entry) |choice| {
            const selected = (self.jump_count > 0) == (index == 1);
            paintIcon(choice.mark, if (selected) ui.icons.circle_dot else ui.icons.circle, 14, if (selected) S.theme.current().accent else S.theme.current().fg_2);
            choice.title.setTextColor(if (selected) S.theme.current().accent_ink else S.theme.current().fg_1);
            if (choice.root.behavior.interaction.a11y) |*access| access.pressed = selected;
        };
    }
    fn routeAssetAllowed(self: *const RemoteEditor, value: []const u8) bool {
        const id = parseAssetValue(value) catch return false;
        if (self.source_owner) |owner| if (owner.id == id) return false;
        for (self.assets) |asset| if (asset.source_owner.?.id == id) return asset.protocol == .ssh;
        return false;
    }

    fn routeAssetUnused(self: *const RemoteEditor, value: []const u8) bool {
        for (self.jump_values[0..self.jump_count]) |selection| {
            if (selection.?.peek()) |selected| if (std.mem.eql(u8, selected, value)) return false;
        }
        return true;
    }

    fn canInsertJump(self: *const RemoteEditor) bool {
        if (self.isLocked() or self.jump_count >= self.jump_values.len) return false;
        for (self.asset_options.?.peek()) |option| {
            if (self.routeAssetAllowed(option.value) and self.routeAssetUnused(option.value)) return true;
        }
        return false;
    }

    fn refreshEditorActions(self: *RemoteEditor) void {
        const locked = self.isLocked();
        if (self.jump_add_disabled) |value| value.set(!self.canInsertJump());
        for (self.editor_actions.items) |action_| action_.disabled.set(locked or switch (action_.kind) {
            .jump_up => action_.index == 0 or action_.index >= self.jump_count,
            .jump_down => action_.index + 1 >= self.jump_count,
            .jump_remove => action_.index >= self.jump_count,
            .command_remove => action_.index >= self.command_count,
        });
    }
    fn onAccessDirect(self: *RemoteEditor) void {
        if (self.isLocked() or self.jump_count == 0) return;
        if (self.route_picker) |picker| picker.close();
        self.dormant_jump_count = self.jump_count;
        self.dormant_socks_exit = if (self.sig_socks_exit.?.get()) |value| std.fmt.parseInt(usize, value, 10) catch null else null;
        self.jump_count = 0;
        self.refreshEditorRows();
        self.onFieldChange("");
    }
    fn onAccessJump(self: *RemoteEditor) void {
        if (self.isLocked() or self.jump_count != 0) return;
        if (self.dormant_jump_count > 0) {
            self.jump_count = self.dormant_jump_count;
            self.dormant_jump_count = 0;
            self.refreshEditorRows();
            if (self.dormant_socks_exit) |index| {
                var buffer: [20]u8 = undefined;
                self.socks_exit_text.?.set(std.fmt.bufPrint(&buffer, "{d}", .{index}) catch "");
                self.sig_socks_exit.?.set(self.socks_exit_text.?.get());
            }
            self.dormant_socks_exit = null;
            self.onFieldChange("");
            return;
        }
        self.jump_count = 1;
        self.setJump(0, null);
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
        if (self.route_picker) |picker| picker.close();
        for (self.route_hop_controls) |entry| if (entry) |control| control.menu_open.?.set(false);
        self.resetPasswordVisibility();
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
        if (self.saving or self.cancel_requested) return;
        if (self.resume_on_close) if (self.suspend_draft) |suspend_draft| {
            var draft = self.currentDraft();
            draft.password = null;
            draft.key_passphrase = null;
            suspend_draft.save(suspend_draft.context, draft, self.group_edited) catch |err| {
                self.save_failure = .{ .stage = .stash, .cause = err };
                self.step = .confirm;
                self.applyStep();
                return;
            };
        };
        self.onCancelClick();
    }

    pub fn isVisible(self: *const RemoteEditor) bool {
        var current: ?*ui.Node = self.root orelse return false;
        while (current) |node| : (current = node.parent) {
            if (node.style.display == .none) return false;
        }
        return true;
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
        const group = std.mem.trim(u8, self.sig_group.?.get(), " \t\r\n");
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
            .auto_shell_integration = if (self.sig_shell_integration.?.get()) |choice| if (std.mem.eql(u8, choice, "on")) true else if (std.mem.eql(u8, choice, "off")) false else null else null,
            .command_info = if (self.sig_command_info.?.get()) |choice| if (std.mem.eql(u8, choice, "on")) true else if (std.mem.eql(u8, choice, "off")) false else null else null,
            .socks_enabled = self.socks_enabled,
            .socks_auto_start = self.socks_auto_start,
            .socks_max_connections = self.socks_max_connections,
            .socks_port = parsePort(self.sig_socks_port.?.get()),
            .socks_bind = self.sig_socks_bind.?.get(),
            .socks_exit = if (self.sig_socks_exit.?.get()) |value| std.fmt.parseInt(usize, value, 10) catch null else null,
            .terminal_type = self.sig_terminal.?.get(),
            .terminal_type_explicit = self.terminal_type_explicit,
            .scrollback = std.fmt.parseInt(u32, trim(self.sig_scrollback.?.get()), 10) catch 25000,
            .scrollback_explicit = trim(self.sig_scrollback.?.get()).len != 0,
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
            .save_key_passphrase = self.sig_save_key_passphrase.?.get(),
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
        if (self.step != .form) {
            self.route_reveal = null;
            if (self.route_picker) |picker| picker.close();
            for (self.route_hop_controls) |entry| if (entry) |control| control.menu_open.?.set(false);
        }
        if (self.step != .protocol) self.resetPasswordVisibility();
        const review = self.step == .confirm;
        if (review and self.scrolls[2].?.container.style.display == .none) {
            const area = self.scrolls[2].?;
            ui.widgets.setScrollY(area.state, area.content, 0);
            const route = self.summary_route_scroll.?;
            ui.widgets.setScrollY(route.state, route.content, 0);
        }
        for (self.scrolls, 0..) |slot, i| if (slot) |scroll| scroll.container.setDisplay(if (i == @backingInt(self.step)) .flex else .none);
        self.back_btn.?.setDisplay(if (self.step != .protocol) .flex else .none);
        self.next1_btn.?.setDisplay(if (self.step == .protocol) .flex else .none);
        self.next2_btn.?.setDisplay(if (self.step == .form) .flex else .none);
        self.save_only_btn.?.setDisplay(if (review) .flex else .none);
        self.save_btn.?.setDisplay(if (review) .flex else .none);
        self.paintSteps();
        self.refreshValidity();
        if (review) self.refreshSummary();
        _ = self.updateViewport();
        self.cx.requestRedraw();
    }

    fn paintSteps(self: *RemoteEditor) void {
        if (self.stepper) |stepper| stepper.setBackground(S.theme.popupInset());
        for (self.step_buttons, 0..) |slot, i| if (slot) |node| {
            const current = i == @backingInt(self.step);
            if (self.step_connectors[i]) |connector| connector.setDisplay(.none);

            var invalid = false;
            if (i == 0) for (self.field_feedback.items) |feedback| {
                if (feedback.touched and feedback.errorMessage().len != 0) {
                    invalid = true;
                    break;
                }
            };
            self.step_styles[i].?.set(S.reviewStep(current));
            self.step_titles[i].?.setStyleInline(self.alloc, .{ .width = .{ .px = if (i == 1) 52 else 66 }, .flex_shrink = 0 });
            Stepper.paint(self.cx, .{ .button = node, .badge = self.step_numbers[i].?, .digit = self.step_digits[i].?, .check = self.step_checks[i].?, .title = self.step_titles[i].?, .segmented = true }, current, i < @backingInt(self.step), invalid);
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
        };
        if (self.next1_disabled) |v| v.set(self.isLocked() or !self.validIdentityDraft());
        if (self.next2_disabled) |v| v.set(self.isLocked() or !self.validDraft());
        self.refreshSaveState();
        for (self.field_feedback.items) |feedback| feedback.refresh();
        self.paintSteps();
    }

    fn refreshPasswordRevealControl(self: *RemoteEditor) void {
        if (self.password_reveal_disabled) |disabled| disabled.set(self.isLocked() or self.password_authorization.active or self.sig_password.?.peek().len == 0);
        if (self.password_reveal_button) |button| {
            if (button.behavior.interaction.a11y) |*a11y| a11y.label = if (self.password_visible) "隐藏密码" else "查看密码";
            const asset = if (self.password_visible) ui.icons.eye_off else ui.icons.eye;
            for (self.buttons.items) |entry| if (entry.node == button) {
                if (entry.icon) |icon| if (asset.icon_id) |id| if (asset.pickRep(16)) |rep| icon.setIcon(.{ .icon_id = id, .rep = rep, .tint = S.theme.current().fg_2 });
            };
        }
    }

    fn resetPasswordVisibility(self: *RemoteEditor) void {
        self.password_authorization.cancel();
        self.password_visible = false;
        self.password_visible_until = 0;
        self.password_approval_deadline = 0;
        if (!self.nodes_alive) return;
        if (self.password_input) |input| {
            input.state.input_type = .password;
            if (input.input_container.behavior.interaction.a11y) |*a11y| {
                a11y.secure = true;
                a11y.value_text = null;
                a11y.editable_text = null;
            }
            input.state.markVisualDirty();
        }
        if (self.password_reveal_error) |node| node.setDisplay(.none);
        self.refreshPasswordRevealControl();
    }

    fn passwordRevealFailed(self: *RemoteEditor) void {
        self.resetPasswordVisibility();
        if (self.password_reveal_error) |node| node.setDisplay(.flex);
        self.cx.requestRedraw();
    }

    fn onPasswordReveal(self: *RemoteEditor) void {
        if (self.isLocked() or self.auth != .password or self.sig_password.?.peek().len == 0) return;
        if (self.password_visible) {
            self.resetPasswordVisibility();
        } else if (!self.password_authorization.active) {
            self.password_authorization.begin() catch {
                self.passwordRevealFailed();
                return;
            };
            if (self.password_reveal_error) |node| node.setDisplay(.none);
            self.cx.scheduleRedrawAfterNs(50 * std.time.ns_per_ms);
        }
        self.refreshPasswordRevealControl();
        self.cx.requestRedraw();
    }

    fn pollPasswordVisibility(self: *RemoteEditor) void {
        if (self.password_authorization.active) switch (self.password_authorization.result()) {
            .pending => {},
            .approved => {
                if (!self.cx.window_active) {
                    // The system sheet may finish before AppKit restores focus.
                    // Allow that transition, but never retain a grant indefinitely.
                    const now = @import("../../platform/realtime.zig").monotonicNs();
                    if (self.password_approval_deadline == 0) self.password_approval_deadline = now + 3 * std.time.ns_per_s;
                    if (now >= self.password_approval_deadline) self.resetPasswordVisibility();
                } else {
                    self.password_authorization.cancel();
                    self.password_visible = true;
                    self.password_visible_until = @import("../../platform/realtime.zig").monotonicNs() + 30 * std.time.ns_per_s;
                    if (self.password_input) |input| {
                        input.state.input_type = .text;
                        if (input.input_container.behavior.interaction.a11y) |*a11y| a11y.secure = false;
                        input.state.markVisualDirty();
                    }
                    self.refreshPasswordRevealControl();
                }
            },
            .cancelled => self.resetPasswordVisibility(),
            .failed => self.passwordRevealFailed(),
        };
        if (self.password_visible and (!self.cx.window_active or @import("../../platform/realtime.zig").monotonicNs() >= self.password_visible_until)) self.resetPasswordVisibility();
        if (self.password_authorization.active or self.password_visible) self.cx.scheduleRedrawAfterNs((if (self.password_authorization.active) @as(u64, 50) else 250) * std.time.ns_per_ms);
    }

    fn refreshAuth(self: *RemoteEditor) void {
        if (self.auth != .password) self.resetPasswordVisibility();
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
        self.refreshValidity();
    }

    pub fn canSave(self: *RemoteEditor) bool {
        if (self.saving or self.test_kind == .pending or self.on_result == null or !self.validDraft()) return false;
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
        self.refreshPasswordRevealControl();
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
        const show_error = self.step == .confirm and self.save_failure != null;
        self.refreshTestStageVisibility();
        if (self.test_btn) |node| node.setDisplay(if (self.step == .confirm and !show_error) .flex else .none);
        if (self.summary_note) |node| node.setDisplay(if (!show_error and self.test_kind == .none) .flex else .none);
        for (self.buttons.items) |*button| if (button.node == self.cancel_btn) {
            button.width = if (self.resume_on_close) 82 else 52;
            break;
        };
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
            } else if (button.node == self.cancel_btn) {
                const label_text = if (self.resume_on_close) "放弃草稿" else "取消";
                if (button.label) |label| label.setTextContent(self.alloc, label_text) catch {};
                if (button.node.behavior.interaction.a11y) |*a11y| a11y.label = label_text;
            }
        }
        if (self.save_error_banner) |banner| {
            const colors = S.theme.current();
            const background = S.saveErrorBackground();
            const error_ink = S.theme.patchInk(colors.danger_ink, &.{background});
            banner.setDisplay(if (show_error) .flex else .none);
            banner.setBackground(background);
            self.save_error_node.?.setDisplay(if (show_error) .flex else .none);
            self.save_error_node.?.setTextColor(error_ink);
            self.save_error_hint.?.setTextColor(S.theme.patchInk(colors.fg_2, &.{background}));
            _ = self.save_error_icon.?.setTint(error_ink);
            if (show_error) {
                const failure = self.save_failure.?;
                const rename = failure.stage == .save and failure.cause == error.DuplicateConnectionName;
                self.save_error_node.?.setTextContent(self.alloc, failure.message()) catch {};
                self.save_error_rename.?.setDisplay(if (rename) .flex else .none);
                self.save_error_copy.?.node.setDisplay(if (rename) .none else .flex);
                const hint = self.resume_on_close and failure.stage != .stash;
                self.save_error_hint.?.setDisplay(if (hint) .flex else .none);
                if (hint) {
                    const draft = self.currentDraft();
                    self.save_error_hint.?.setTextContent(self.alloc, if (draft.password != null or draft.key_passphrase != null)
                        "关闭向导后可从「新建连接」继续，密码或私钥口令需重新输入。"
                    else
                        "关闭向导后可从「新建连接」继续。") catch {};
                }
            }
        }
        self.cx.requestRedraw();
    }

    /// 确认卡摘要行（进入第 3 步时改写）。
    fn refreshSummary(self: *RemoteEditor) void {
        if (self.test_source == null) self.refreshRoutePreview(&self.route_previews[1]);
        const draft = self.currentDraft();
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
                .key => if (draft.key_passphrase == null) "私钥文件" else if (draft.save_key_passphrase) "私钥文件 · 保存口令" else "私钥文件 · 口令仅本次使用",
                .agent => "SSH Agent",
                .password => if (draft.password == null) "密码 · 连接时输入" else if (draft.save_password) "密码 · 保存后自动使用" else "密码 · 仅本次使用",
            },
            if (draft.strict_host_key_checking) "严格验证主机密钥" else "严格验证已关闭",
        };
        for (values, self.summary_values) |value, node| node.?.setTextContent(self.alloc, value) catch {};
        self.summary_values[0].?.setDisplay(if (draft.protocol == .sftp) .flex else .none);
        var options_buffer: [128]u8 = undefined;
        const options = if (draft.protocol == .ssh and draft.startup_commands.len != 0) std.fmt.bufPrint(&options_buffer, "启动命令 {d} 条", .{draft.startup_commands.len}) catch "" else "";
        self.summary_options.?.setTextContent(self.alloc, options) catch {};
        self.summary_options.?.setDisplay(if (options.len != 0) .flex else .none);
        const count = draft.jump_chain.len + 2;
        for (self.summary_route_nodes, 0..) |node, i| {
            node.?.setDisplay(if (i < count) .flex else .none);
            if (i >= count) continue;
            const target = i == count - 1;
            const name = if (i == 0) "本机" else if (target) draft.host else draft.jump_chain[i - 1];
            const caption = if (i == 0) "客户端" else if (target) (if (draft.protocol == .sftp) "SFTP · 目标" else "SSH · 目标") else std.fmt.bufPrint(&options_buffer, "SSH · 第 {d} 跳", .{i}) catch "SSH 跳板";
            self.summary_route_names[i].?.setTextContent(self.alloc, name) catch {};
            self.summary_route_names[i].?.setTextColor(if (target) S.theme.current().accent_ink else S.theme.current().fg_1);
            self.summary_route_captions[i].?.setTextContent(self.alloc, caption) catch {};
            const icon = self.summary_route_icons[i].?;
            const asset = if (i == 0) ui.icons.monitor else if (target) ui.icons.server else ui.icons.route;
            paintIcon(icon, asset, 16, if (target) S.theme.current().accent_ink else S.theme.current().fg_2);
            icon.parent.?.setBackground(S.reviewIconTile(26, target).background.?);
        }
        if (count > 3) self.summary_route_scroll.?.state.scrollbar_fade.onActivity();
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

    fn finishDiscard(self: *RemoteEditor) void {
        self.hide();
        self.loadDraft(.{});
    }

    fn onCancelClick(self: *RemoteEditor) void {
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
            if (self.save_failure != null and self.test_kind == .ok) self.test_reveal_pending = true;
            self.refreshSaveState();
        }
        const receipt = (callback(self.result_ctx, if (only) .{ .save_only = draft } else .{ .saved = draft }) catch |err| {
            @import("../../platform/applog.zig").warn(.ui, "connection configuration save failed: {s}", .{@errorName(err)});
            self.save_failure = .{ .stage = .save, .cause = err };
            self.resume_on_close = draft.source_owner == null and self.suspend_draft != null;
            return;
        }) orelse {
            self.save_failure = .{ .stage = .save, .cause = error.MissingSaveReceipt };
            self.resume_on_close = draft.source_owner == null and self.suspend_draft != null;
            return;
        };
        self.resume_on_close = false;
        self.source_owner = receipt.owner;
        self.copied_from_existing = false;
        if (receipt.open_failure) |err| {
            self.save_failure = .{ .stage = .open, .cause = err };
            return;
        }
        self.hide();
    }

    fn onAuthPicked(self: *RemoteEditor, value: []const u8) void {
        self.onAuthChanged(value);
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
        if (self.protocol_icon) |icon| paintIcon(icon, ui.icons.plug, 18, S.theme.current().accent);
        if (self.protocol_select_icon) |icon| paintIcon(icon, asset, 16, S.theme.current().fg_2);
        if (self.summary_icon) |icon| {
            paintIcon(icon, asset, 24, S.theme.current().accent_ink);
            icon.parent.?.setBackground(S.reviewIconTile(44, true).background.?);
        }
    }
    fn onProtocolChanged(self: *RemoteEditor, selected: ?[]const u8) void {
        if (self.isLocked()) return;
        const value = selected orelse return;
        const protocol = std.meta.stringToEnum(Protocol, value) orelse return;
        if (protocol != .ssh and protocol != .sftp) return;
        self.sig_password.?.set("");
        self.sig_save_password.?.set(true);
        self.sig_key_passphrase.?.set("");
        self.sig_save_key_passphrase.?.set(false);
        self.protocol_id = value;
        self.protocol = protocol;
        self.onFieldChange("");
        self.applyStep();
    }

    fn onAdvancedToggle(self: *RemoteEditor) void {
        if (self.isLocked()) return;
        self.advanced_expanded = !self.advanced_expanded;
        self.refreshEditorRows();
        self.paintButtons();
    }

    fn isLocked(self: *const RemoteEditor) bool {
        return self.saving or self.test_kind == .pending;
    }

    fn openChanged(self: *RemoteEditor, value: bool) void {
        if (value) return;
        for (self.inputs.items) |input| if (input.state.focused and input.state.imeIsComposing()) {
            input.state.cancelImeComposition();
            self.cx.requestRedraw();
            return;
        };
        self.cancel();
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
    fn onSaveKeyPassphraseChanged(self: *RemoteEditor, checked: bool) void {
        if (self.isLocked()) return;
        self.sig_save_key_passphrase.?.set(checked);
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
    fn onShellIntegrationPicked(self: *RemoteEditor, value: ?[]const u8) void {
        if (self.isLocked()) return;
        self.sig_shell_integration.?.set(value);
        self.onFieldChange("");
    }
    fn onCommandInfoPicked(self: *RemoteEditor, value: ?[]const u8) void {
        if (self.isLocked()) return;
        self.sig_command_info.?.set(value);
        self.onFieldChange("");
    }
    fn onCompressionPicked(self: *RemoteEditor, value: []const u8) void {
        self.onCompressionChanged(std.mem.eql(u8, value, "on"));
    }
    fn onCompressionChanged(self: *RemoteEditor, checked: bool) void {
        if (self.isLocked()) return;
        self.compression = checked;
        self.sig_compression.?.set(checked);
        self.compression_explicit = true;
        self.onFieldChange("");
    }
    fn onSummaryModify(self: *RemoteEditor) void {
        if (self.isLocked()) return;
        self.identity_expanded = true;
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
    fn onSaveErrorCopy(self: *RemoteEditor) void {
        const failure = self.save_failure orelse return;
        const stage = switch (failure.stage) {
            .save => "保存连接",
            .open => "打开会话",
            .stash => "暂存连接",
        };
        var buffer: [256]u8 = undefined;
        const details = std.fmt.bufPrint(&buffer, "{s}失败\n错误代码：{s}", .{ stage, @errorName(failure.cause) }) catch return;
        self.save_error_copy.?.copy(details);
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
        if (self.test_copy_feedback) |feedback| feedback.report(self.test_copy_result.?);
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
        if (self.summary_note) |node| node.setDisplay(if (self.save_failure == null and self.test_kind == .none) .flex else .none);
        if (self.review_path) |label| try label.setTextContent(self.alloc, if (self.review_expanded) "收起预检详情" else "查看预检详情");
        if (self.review_disclosure) |node| paintIcon(node, if (self.review_expanded) ui.icons.chevron_down else ui.icons.chevron_right, 16, S.theme.current().fg_3);
        self.test_action_disabled.?.set(if (pending) self.test_cancel_sent or self.on_cancel_test == null or source == null or source.?.cancelled or source.?.cleanup != .not_started else self.saving or !self.validDraft() or self.sftpRouteUnavailable());
        for (self.buttons.items) |*button| if (button.node == self.test_btn) {
            const unavailable = self.sftpRouteUnavailable() and !pending;
            const label: []const u8 = if (pending) (if (self.test_cancel_sent or (source != null and source.?.cancelled)) "正在取消" else "取消测试") else if (unavailable) "检测 SFTP · 不可用" else if (self.test_kind != .none) "重新测试" else if (self.protocol == .sftp) "检测 SFTP" else "测试连接";
            button.width = if (unavailable) S.unavailable_test_width else if (self.protocol == .ssh) 96 else S.test_action_width;
            button.height = 34;
            var style = S.button(button.width, button.height, false);
            const is_disabled = if (button.disabled) |disabled| disabled.peek() else false;
            style.opacity = if (is_disabled) 0.4 else 1;
            if (is_disabled and button.primary) style.gradient = .{ .from = style.background.?, .to = style.background.?, .direction = .diagonal };
            button.style.set(style);
            button.node.setStyleInline(self.alloc, style);
            if (button.icon) |icon| icon.setDisplay(if (self.protocol == .ssh) .flex else .none);
            if (button.label) |node| try node.setTextContent(self.alloc, label);
            if (button.node.behavior.interaction.a11y) |*a11y| a11y.label = label;
        };
        self.refreshTestStageVisibility();
        if (source == null) return;
        var buffer: [1024]u8 = undefined;
        try self.res_text.?.setTextContent(self.alloc, source.?.summary(&buffer));
        const color = if (source.?.cleanup == .unknown) S.theme.current().warn else if (source.?.failure != null and !source.?.cancelled) S.theme.current().danger else if (source.?.finished and !source.?.cancelled) S.theme.current().ok else if (source.?.cancelled) S.theme.current().fg_2 else S.theme.current().accent;
        self.res_text.?.setTextColor(color);
        if (self.test_status_icon) |icon| _ = icon.setTint(color);
        for (source.?.hops, 0..) |hop, i| {
            const row = self.test_stages[i];
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
        var preview = &self.route_previews[1];
        if (preview != &self.route_previews[0]) _ = self.resizeRoutePreview(preview);
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
                node.setBackground(if (self.test_filter == i) S.theme.popupSelection() else S.testNode().background.?);
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

    fn refreshTestStageVisibility(self: *RemoteEditor) void {
        if (self.review_test_card == null) return;
        const count = if (self.test_source) |source| source.value.hops.len else 0;
        const show_stages = self.save_failure == null or self.review_expanded;
        for (self.test_stages, 0..) |row, i| row.node.setDisplay(if (show_stages and i < count) .flex else .none);
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
                const address = if (selected) |a|
                    if (preview == &self.route_previews[0] and a.port == 22)
                        std.fmt.bufPrint(&buffer, "{s}@{s}", .{ a.user, a.host }) catch a.host
                    else
                        std.fmt.bufPrint(&buffer, "{s}@{s}:{d}", .{ a.user, a.host, a.port }) catch a.host
                else
                    "";
                preview.addresses[i].?.setTextContent(self.alloc, address) catch {};
                if (preview != &self.route_previews[0]) preview.users[i].?.setTextContent(self.alloc, if (selected != null) "待连接" else "") catch {};
            }
        }
        for (preview.arrows, 0..) |node, i| node.?.setDisplay(if (i <= self.jump_count) .flex else .none);
        var buffer: [256]u8 = undefined;
        preview.names[9].?.setTextContent(self.alloc, if (self.sig_name.?.get().len != 0) self.sig_name.?.get() else "目标主机") catch {};
        preview.addresses[9].?.setTextContent(self.alloc, std.fmt.bufPrint(&buffer, "{s}@{s}:{s}", .{ self.sig_user.?.get(), self.sig_host.?.get(), self.sig_port.?.get() }) catch self.sig_host.?.get()) catch {};
        if (preview != &self.route_previews[0]) preview.users[9].?.setTextContent(self.alloc, "待连接") catch {};
    }

    fn paintButtons(self: *RemoteEditor) void {
        for (self.buttons.items) |button| {
            const review = self.step == .confirm;
            const review_link = button.node == self.summary_edit or button.node == self.summary_route_edit;
            const width: f32 = if (review and button.node == self.back_btn)
                84
            else if (review and button.node == self.save_btn)
                115
            else if (review and button.node == self.save_only_btn)
                if (self.source_owner != null) 88 else 80
            else
                button.width;
            var style = if (width == 0) S.advancedToggle() else S.button(width, button.height, button.primary);
            if (button.quiet or review_link or (self.step != .form and button.node == self.cancel_btn)) style.background = ui.Color.TRANSPARENT;
            const is_disabled = if (button.disabled) |disabled| disabled.peek() else false;
            style.opacity = if (is_disabled) 0.4 else 1;
            if (button.node == self.next1_btn or (is_disabled and button.primary)) style.gradient = .{ .from = style.background.?, .to = style.background.?, .direction = .diagonal };
            button.style.set(style);
            button.node.setStyleInline(self.alloc, style);
            if (button.label) |label| label.setTextColor(if (review_link) S.theme.current().accent else if (button.width == 0) self.advancedInk() else S.action(button.primary).color);
            if (button.icon) |icon| {
                _ = icon.setTint(if (button.primary) S.action(true).color else if (review_link) S.theme.current().accent else S.theme.current().fg_2);
                if (button.node == self.back_btn) icon.setDisplay(if (review) .flex else .none);
            }
        }
        self.refreshAuth();
        self.refreshAccessChoices();
        self.refreshEditorActions();
        for (self.field_feedback.items) |feedback| feedback.repaint();
    }

    fn retintText(node: *ui.Node, before: S.theme.Colors, after: S.theme.Colors) void {
        if (node.getText()) |text| {
            inline for (.{ "fg_1", "fg_2", "fg_3", "accent_ink", "accent", "danger_ink", "danger", "warn_ink", "warn", "ok_ink", "ok" }) |role| {
                if (std.meta.eql(text.color, @field(before, role))) {
                    node.setTextColor(@field(after, role));
                    break;
                }
            }
        }
        for (node.children.items) |child| retintText(child, before, after);
    }
    fn retheme(self: *RemoteEditor) void {
        const colors = S.theme.current();
        if (self.painted_colors) |before| {
            if (self.modal) |node| retintText(node, before, colors);
            if (self.copy_dialog) |node| retintText(node, before, colors);
        }
        self.painted_colors = colors;
        // Embedded editors share the shell's material; layout chrome must not
        // introduce another fill when a retained editor changes theme.
        if (self.footer) |footer| footer.setBackground(if (self.step == .form) ui.Color.TRANSPARENT else S.footer().background.?);
        self.modal.?.setBackground(if (self.embedded) ui.Color.TRANSPARENT else colors.overlay);
        if (self.route_empty_hint) |node| node.setTextColor(S.theme.current().danger_ink);
        self.refreshAccessChoices();
        if (self.route_chain_scroll) |area| area.container.setBackground(S.theme.popupInset());
        const endpoint_fill = S.routeEndpointFill();
        if (self.route_previews[0].nodes[0]) |local| local.setBackground(endpoint_fill);
        if (self.route_previews[0].nodes[9]) |target| target.setBackground(endpoint_fill);
        for (self.route_edges) |slot| if (slot) |edge| edge.paint();
        if (self.route_picker) |picker| picker.paint();
        for (self.editor_actions.items) |action_| if (action_.icon) |icon| {
            _ = icon.setTint(S.theme.current().fg_3);
        };
        if (self.review_test_card) |card| card.setBackground(S.testResult(undefined).background.?);
        for ([_]?*ui.Node{ self.identity_card, self.auth_card, self.advanced_body }) |slot| if (slot) |card| card.setBackground(S.identityPanelColor());
        for (self.inputs.items) |input| {
            const id = input.input_container.meta.ownership.meta.test_id orelse "";
            const compound = std.mem.eql(u8, id, "wizard.group") or std.mem.eql(u8, id, "wizard.password");
            input.input_container.setStyleInline(self.alloc, if (compound or std.mem.eql(u8, id, "wizard.encoding")) S.groupInput() else S.input());
            input.state.tokens = self.cx.tokens;
            input.state.dirty = true;
        }
        if (self.password_control) |control| control.setBackground(S.groupControl().background.?);
        for (self.selects.items) |select| {
            const group_picker = std.mem.eql(u8, select.trigger.meta.ownership.meta.test_id orelse "", "wizard.group.pick");
            if (group_picker) {
                select.trigger.setStyleInline(self.alloc, S.groupPicker());
            } else {
                select.trigger.setBackground(S.input().background.?);
            }
        }
        if (self.remember_checkbox) |checkbox| paintCheckboxLabels(checkbox);
        if (self.remember_passphrase_checkbox) |checkbox| paintCheckboxLabels(checkbox);
        if (self.compression_checkbox) |group| paintAuthLabels(group);
        if (self.startup_textarea) |area| {
            area.state.tokens = self.cx.tokens;
            area.state.dirty = true;
            area.input.markLayoutDirty();
        }
        if (self.copy_dialog) |dialog| dialog.setBackground(colors.overlay);
        if (self.copy_footer) |footer| footer.setBackground(S.copyFooter().background.?);
        if (self.title) |title| title.setTextColor(S.theme.current().fg_1);
        if (self.summary_card) |card| card.setBackground(S.reviewIdentity().background.?);
        if (self.summary_details) |card| card.setBackground(S.reviewRoute().background.?);
        if (self.summary_route_card) |card| card.setBackground(S.reviewRoute().background.?);
        self.paintSteps();
        self.paintAdvancedToggle();
        self.test_logs_area.setBackground(S.testLogs().background.?);
        for (&self.route_previews) |*preview| for (preview.addresses) |node| if (node) |address| address.setTextColor(S.theme.current().fg_2);
        self.paintButtons();
        for (self.route_previews[1].nodes) |node| if (node) |n| n.setBackground(S.routeNode(false).background.?);
        if (self.step == .confirm) self.refreshSummary() else self.refreshTestRow();
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
    fn onScrollbackChanged(self: *RemoteEditor, text: []const u8) void {
        self.loaded_scrollback_explicit = trim(text).len != 0;
        self.onFieldChange(text);
    }

    fn onFieldChange(self: *RemoteEditor, _: []const u8) void {
        if (self.password_authorization.active) self.resetPasswordVisibility();
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
const ButtonPaint = struct { node: *ui.Node, label: ?*ui.Node, icon: ?*ui.Node, style: *ui.Signal(ui.BoxStyle), width: f32, height: f32, primary: bool, disabled: ?*ui.Signal(bool) = null, quiet: bool = false };
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
    const test_action = std.mem.eql(u8, id, "wizard.test");
    const trailing_arrow = std.mem.eql(u8, id, "wizard.next.identity");
    const glyph: ?ui.SvgAsset = icon orelse (if (test_action) ui.icons.activity else if (trailing_arrow) ui.icons.arrow_right else if (std.mem.eql(u8, id, "wizard.back")) ui.icons.arrow_left else if (std.mem.startsWith(u8, id, "wizard.review.")) ui.icons.pencil else null);
    if (glyph) |asset| {
        icon_node = try ui.iconTint(w.cx, asset, if (primary) S.action(true).color else S.theme.current().fg_2, .{ .width = .{ .px = 16 }, .height = .{ .px = 16 }, .flex_shrink = 0 });
        if (!trailing_arrow) try node.appendChild(w.alloc, icon_node.?);
    }
    if (icon == null) {
        label_node = try ui.text(w.cx, label, if (test_action) S.testActionText() else S.action(primary));
        if (test_action) label_node.?.setStyleInline(w.alloc, S.testActionLabel());
        try node.appendChild(w.alloc, label_node.?);
    }
    if (trailing_arrow) try node.appendChild(w.alloc, icon_node.?);
    try w.buttons.append(w.alloc, .{ .node = node, .label = label_node, .icon = icon_node, .style = base, .width = width, .height = height, .primary = primary, .disabled = disabled, .quiet = std.mem.eql(u8, id, "wizard.close") });
    try parent.appendChild(w.alloc, node);
    return node;
}

fn disclosure(w: *RemoteEditor, parent: *ui.Node, label: []const u8, id: []const u8, comptime callback: *const fn (*RemoteEditor) void) !*ui.Node {
    const row = try ui.box(w.cx, S.row(30), .{});
    const base = try w.scope.createSignal(ui.BoxStyle, S.advancedToggle());
    const node = try ui.widgets.Button(.{ .variant = .ghost, .a11y_label = label, .disabled = w.locked.?, .base_style = base, .hover_style = S.disclosureHover(), .pressed_style = S.disclosureHover(), .on_click = w.cx.on(RemoteEditor, w, callback) }).mount(w.scope, w.cx);
    node.meta.ownership.meta.test_id = id;
    const title = try ui.text(w.cx, label, S.text(13, 500, false));
    const chevron = try ui.iconTint(w.cx, ui.icons.chevron_right, w.advancedInk(), S.icon(14));
    w.advanced_chevron = chevron;
    const content = try ui.box(w.cx, .{ .width = .fill(), .height = .{ .px = 30 }, .min_width = 0, .flex = 1, .direction = .row, .align_items = .center, .justify = .start, .gap = 8, .hit_behavior = .pass_through }, .{});
    try content.appendChild(w.alloc, chevron);
    try content.appendChild(w.alloc, title);
    try node.appendChild(w.alloc, content);
    try w.buttons.append(w.alloc, .{ .node = node, .label = title, .icon = null, .style = base, .width = 0, .height = 30, .primary = false, .disabled = w.locked, .quiet = true });
    try row.appendChild(w.alloc, node);
    try parent.appendChild(w.alloc, row);
    return row;
}

const FieldKind = enum { name, host, user, port, key_path, scrollback };
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
        const kind: FieldKind = if (std.mem.eql(u8, id, "wizard.name")) .name else if (std.mem.eql(u8, id, "wizard.host")) .host else if (std.mem.eql(u8, id, "wizard.user")) .user else if (std.mem.eql(u8, id, "wizard.port")) .port else if (std.mem.eql(u8, id, "wizard.key_path")) .key_path else if (std.mem.eql(u8, id, "wizard.scrollback")) .scrollback else return null;
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
            .scrollback => w.sig_scrollback.?.get(),
            .key_path => w.sig_key_path.?.get(),
        };
        if (self.kind == .scrollback) {
            if (trim(raw).len == 0) return "";
            _ = std.fmt.parseInt(u32, trim(raw), 10) catch return "请输入非负整数；0 表示不限制。";
            return "";
        }
        if (self.kind == .key_path and w.auth != .key) return "";
        if (self.kind == .port) return if (parsePort(raw) == 0) "请输入 1–65535 的整数。" else "";
        if (trim(raw).len == 0) return switch (self.kind) {
            .name => "请输入主机名称。",
            .host => "请输入主机地址。",
            .user => "请输入登录用户。",
            .key_path => "请选择或输入私钥文件。",
            .port, .scrollback => unreachable,
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
        self.group.setStyleInline(self.wizard.alloc, .{ .height = .{ .px = if (invalid) 75.5 else 55.5 } });
        self.input.node.setStyleInline(self.wizard.alloc, .{ .height = .{ .px = if (invalid) 54 else 34 }, .flex_shrink = 0 });
    }
    fn repaint(self: *FieldFeedback) void {
        if (self.error_node) |node| node.setTextColor(S.theme.current().danger_ink);
    }
};

fn field(w: *RemoteEditor, parent: *ui.Node, label: []const u8, value: *ui.Signal([]const u8), placeholder: []const u8, id: []const u8, width: ?f32, secret: bool) !ui.widgets.input.InputResult {
    const group = try ui.box(w.cx, S.field(width), .{});
    const title = try fieldLabel(w.cx, label);
    title.style.height = .{ .px = 16.5 };
    if (std.mem.eql(u8, id, "wizard.scrollback")) {
        const label_row = try ui.hstack(w.cx, .{ .width = .fill(), .height = .{ .px = 16.5 }, .gap = 8, .align_items = .center, .flex_shrink = 0 }, .{});
        try label_row.appendChild(w.alloc, title);
        try label_row.appendChild(w.alloc, try ui.text(w.cx, "0 不限制", S.text(10, 400, true)));
        try group.appendChild(w.alloc, label_row);
    } else try group.appendChild(w.alloc, title);
    const feedback = try FieldFeedback.prepare(w, id);
    const input = try ui.widgets.Input(.{ .error_msg = if (feedback) |f| ui.Source([]const u8){ .signal = f.message } else ui.Source([]const u8){ .value = "" }, .value = value, .embedded = std.mem.eql(u8, id, "wizard.password") or std.mem.eql(u8, id, "wizard.encoding"), .readonly = std.mem.eql(u8, id, "wizard.encoding"), .placeholder = if (std.mem.eql(u8, id, "wizard.scrollback")) ui.Source([]const u8){ .signal = w.sig_scrollback_hint.? } else ui.Source([]const u8){ .value = placeholder }, .input_type = @as(ui.widgets.input.InputType, if (secret) .password else .text), .disabled = w.locked.?, .on_change = if (std.mem.eql(u8, id, "wizard.scrollback")) w.cx.on(RemoteEditor, w, RemoteEditor.onScrollbackChanged) else w.cx.on(RemoteEditor, w, RemoteEditor.onFieldChange), .on_submit = w.cx.on(RemoteEditor, w, RemoteEditor.onFieldSubmit) }).mountResult(w.scope, w.cx);
    S.theme.stylePanelInput(input);
    input.node.setStyleInline(w.alloc, .{ .width = .fill(), .height = .{ .px = 34 }, .min_width = 0, .flex_shrink = 1 });
    input.input_container.setStyleInline(w.alloc, S.input());
    input.input_container.meta.ownership.meta.test_id = id;
    input.state.font_size = 11;
    input.state.line_height = 16;
    input.state.padding_h = 0;
    input.state.char_width = 6.3;
    input.state.tokens = w.cx.tokens;
    input.state.dirty = true;
    if (feedback) |f| try f.attach(input, group, label);
    try w.inputs.append(w.alloc, input);
    if (std.mem.eql(u8, id, "wizard.password")) {
        w.password_input = input;
        const control = try ui.box(w.cx, S.groupControl(), .{});
        w.password_control = control;
        input.input_container.setStyleInline(w.alloc, S.groupInput());
        try control.appendChild(w.alloc, input.node);
        w.password_reveal_button = try action(w, control, "查看密码", "wizard.password.reveal", 32, 32, false, w.password_reveal_disabled, RemoteEditor.onPasswordReveal, ui.icons.eye);
        try group.appendChild(w.alloc, control);
    } else try group.appendChild(w.alloc, input.node);
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
fn helpLabel(w: *RemoteEditor, label: []const u8, explanation: []const u8, test_id: []const u8) !*ui.Node {
    const row = try ui.box(w.cx, .{ .width = .fill(), .height = .{ .px = 16.5 }, .direction = .row, .align_items = .center, .gap = 5, .flex_shrink = 0 }, .{});
    try row.appendChild(w.alloc, try fieldLabel(w.cx, label));
    const tip = try ui.widgets.Tooltip(.{ .text = explanation, .open_delay_ms = 450 }).mount(w.scope, w.cx);
    const help = try ui.widgets.Button(.{ .variant = .ghost, .icon_only = true, .icon_asset = ui.icons.info, .icon_size = 12, .icon_tint = S.theme.current().fg_2, .a11y_label = explanation, .base_style = .{ .width = .{ .px = 16 }, .height = .{ .px = 16 }, .padding = .{}, .border = .{ .radius = 4 }, .flex_shrink = 0 } }).mount(w.scope, w.cx);
    help.meta.ownership.meta.test_id = test_id;
    try tip.trigger.appendChild(w.alloc, help);
    try row.appendChild(w.alloc, tip.wrapper);
    return row;
}
fn readonlyField(w: *RemoteEditor, parent: *ui.Node, label: []const u8, text: []const u8) !*ui.Node {
    const group = try ui.box(w.cx, S.field(null), .{});
    try group.appendChild(w.alloc, try fieldLabel(w.cx, label));
    const well = try ui.box(w.cx, S.row(34), .{});
    const value = try ui.textStyled(w.cx, S.readonlyValue, text);
    value.setStyleInline(w.alloc, .{ .width = .fill(), .min_width = 0, .flex = 1 });
    try well.appendChild(w.alloc, value);
    try group.appendChild(w.alloc, well);
    try parent.appendChild(w.alloc, group);
    return value;
}

fn mountIdentity(w: *RemoteEditor) !*ui.Node {
    const cx = w.cx;
    var form_style = S.formSection(cx.tokens);
    form_style.gap = 12;
    const root = try ui.box(cx, form_style, .{});
    if (w.protocol_picker) |picker| try root.appendChild(w.alloc, try picker.mount(picker.context, cx, w.scope));
    const columns = try ui.box(cx, S.reviewColumns(), .{});
    const card = try ui.boxStyled(cx, S.identitySection, .{});
    w.identity_card = card;
    card.meta.ownership.meta.test_id = "wizard.identity.card";
    const head = try ui.box(cx, S.row(26), .{});
    try head.appendChild(w.alloc, try ui.text(cx, "连接信息", S.text(14, 600, false)));
    try head.appendChild(w.alloc, try ui.spacer(cx));
    w.copy_trigger = try action(w, head, "从已有主机复制", "wizard.copy.open", 116, 26, false, w.copy_open_disabled, RemoteEditor.onCopyToggle, null);
    try card.appendChild(w.alloc, head);
    const details = try ui.boxStyled(cx, S.identityFields, .{});
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
    w.copy_footer = copy_foot;
    _ = try action(w, copy_foot, "取消", "wizard.copy.cancel", 76, 34, false, null, RemoteEditor.onCopyCancel, null);
    try copy_foot.appendChild(w.alloc, try ui.spacer(cx));
    _ = try action(w, copy_foot, "复制到当前草稿", "wizard.copy.apply", 128, 34, true, w.copy_disabled, RemoteEditor.onCopyApply, null);
    try copy_modal.body.appendChild(w.alloc, copy_foot);
    if (!copy_modal.portaled) try root.appendChild(w.alloc, copy_modal.overlay);
    _ = try field(w, details, "连接名称", w.sig_name.?, "", "wizard.name", null, false);
    const target_row = try ui.box(cx, S.fieldRow(), .{});
    target_row.style.gap = 12;
    _ = try field(w, target_row, "主机地址", w.sig_host.?, "", "wizard.host", null, false);
    _ = try field(w, target_row, "端口", w.sig_port.?, "", "wizard.port", 76, false);
    try details.appendChild(w.alloc, target_row);
    const group_field = try ui.box(cx, S.field(null), .{});
    try group_field.appendChild(w.alloc, try fieldLabel(cx, "资产分组"));
    const group_control = try ui.box(cx, S.groupControl(), .{});
    group_control.meta.ownership.meta.test_id = "wizard.group.control";
    const group_input = try ui.widgets.Input(.{ .value = w.sig_group.?, .placeholder = "未分组，可输入新分组", .embedded = true, .disabled = w.locked.?, .on_change = cx.on(RemoteEditor, w, RemoteEditor.onGroupInput) }).mountResult(w.scope, cx);
    @import("../../ui/app_theme.zig").styleInput(group_input);
    group_input.node.setStyleInline(w.alloc, .{ .width = .fill(), .min_width = 0, .height = .{ .px = 34 } });
    group_input.input_container.setStyleInline(w.alloc, S.groupInput());
    group_input.input_container.meta.ownership.meta.test_id = "wizard.group";
    group_input.state.font_size = 11;
    group_input.state.line_height = 16;
    group_input.state.padding_h = 0;
    group_input.state.char_width = 6.3;
    group_input.state.tokens = cx.tokens;
    group_input.state.dirty = true;
    try w.inputs.append(w.alloc, group_input);
    try group_control.appendChild(w.alloc, group_input.node);
    const group_select = try ui.widgets.Select(.{ .options = w.group_options.?, .value = w.sig_group_selection.?, .width = 32, .disabled = w.locked.?, .on_change = cx.on(RemoteEditor, w, RemoteEditor.onGroupChanged) }).mount(w.scope, cx);
    skinSelect(w, group_select, 34, 12);
    group_select.trigger.setStyleInline(w.alloc, S.groupPicker());
    group_select.trigger.addBeforeRender(clearGroupInnerChrome);
    group_select.content_slot.setStyleInline(w.alloc, .{ .display = .none });
    group_select.trigger.meta.ownership.meta.test_id = "wizard.group.pick";
    group_select.chrome.meta.ownership.meta.test_id = "wizard.group.menu";
    group_select.chrome.setStyleInline(w.alloc, .{ .min_width = (S.width - 48 - 16) / 2 - 32 });
    try group_control.appendChild(w.alloc, group_select.wrapper);
    group_control.behavior.events.event_context = try w.scope.createState(GroupControlChrome, .{ .input = group_input, .select = group_select });
    group_control.addBeforeRender(GroupControlChrome.paint);
    try group_field.appendChild(w.alloc, group_control);
    try details.appendChild(w.alloc, group_field);
    try card.appendChild(w.alloc, details);
    try columns.appendChild(w.alloc, card);

    const auth_card = try ui.boxStyled(cx, S.identitySection, .{});
    w.auth_card = auth_card;
    auth_card.meta.ownership.meta.test_id = "wizard.auth.card";
    const auth_head = try ui.box(cx, S.row(26), .{});
    try auth_head.appendChild(w.alloc, try ui.text(cx, "认证", S.text(14, 600, false)));
    try auth_card.appendChild(w.alloc, auth_head);
    const auth_body = try ui.boxStyled(cx, S.identityFields, .{});
    w.auth_body = auth_body;
    _ = try field(w, auth_body, "用户名", w.sig_user.?, "", "wizard.user", null, false);
    const auth_field = try ui.box(cx, S.field(null), .{});
    try auth_field.appendChild(w.alloc, try fieldLabel(cx, "认证方式"));
    const auth_group = try ui.widgets.RadioGroup(.{ .options = &auth_options, .value = w.sig_auth.?, .focus_ring = S.radioFocus(), .horizontal = true, .disabled = w.locked.?, .on_change = cx.on(RemoteEditor, w, RemoteEditor.onAuthPicked) }).mount(w.scope, cx);
    w.auth_group = auth_group;
    skinIdentityRadios(w, auth_group);
    auth_group.meta.ownership.meta.test_id = "wizard.auth";
    try auth_field.appendChild(w.alloc, auth_group);
    try auth_body.appendChild(w.alloc, auth_field);
    const key = try ui.boxStyled(cx, S.stack, .{});
    w.cred_key_row = key;
    const key_group = try ui.box(cx, S.field(null), .{});
    try key_group.appendChild(w.alloc, try fieldLabel(cx, "私钥文件路径"));
    const key_row = try ui.box(cx, S.fieldRow(), .{});
    const key_feedback = (try FieldFeedback.prepare(w, "wizard.key_path")).?;
    const key_input = try ui.widgets.Input(.{ .error_msg = key_feedback.message, .value = w.sig_key_path.?, .placeholder = "~/.ssh/id_ed25519", .disabled = w.locked.?, .on_change = cx.on(RemoteEditor, w, RemoteEditor.onFieldChange), .on_submit = cx.on(RemoteEditor, w, RemoteEditor.onFieldSubmit) }).mountResult(w.scope, cx);
    S.theme.stylePanelInput(key_input);
    key_input.node.setStyleInline(w.alloc, .{ .width = .fill(), .min_width = 0, .height = .{ .px = 34 } });
    key_input.input_container.setStyleInline(w.alloc, S.input());
    key_input.input_container.meta.ownership.meta.test_id = "wizard.key_path";
    key_input.state.font_size = 11;
    key_input.state.line_height = 16;
    key_input.state.padding_h = 0;
    key_input.state.dirty = true;
    try key_feedback.attach(key_input, key_group, "私钥文件");
    try w.inputs.append(w.alloc, key_input);
    try key_row.appendChild(w.alloc, key_input.node);
    _ = try action(w, key_row, "选择私钥文件", "wizard.key_path.pick", 28, 28, false, w.locked, RemoteEditor.onPickKey, ui.icons.folder_open);
    try key_group.appendChild(w.alloc, key_row);
    try key.appendChild(w.alloc, key_group);
    const passphrase_row = try ui.box(cx, .{ .width = .fill(), .height = .{ .fit = .{} }, .direction = .row, .align_items = .end, .gap = 16 }, .{});
    _ = try field(w, passphrase_row, "私钥口令", w.sig_key_passphrase.?, "可留空，连接时再输入", "wizard.key_passphrase", null, true);
    const remember_passphrase = try ui.widgets.Checkbox(.{ .checked = w.sig_save_key_passphrase.?, .label = "保存口令", .box_size = @as(f32, 14), .label_font_size = @as(f32, 11), .disabled = w.locked.?, .on_change = cx.on(RemoteEditor, w, RemoteEditor.onSaveKeyPassphraseChanged) }).mount(w.scope, cx);
    remember_passphrase.setStyleInline(w.alloc, .{ .width = .{ .fit = .{} }, .height = .{ .px = 34 }, .gap = 8, .flex_shrink = 0 });
    remember_passphrase.meta.ownership.meta.test_id = "wizard.key_passphrase.remember";
    w.remember_passphrase_checkbox = remember_passphrase;
    paintCheckboxLabels(remember_passphrase);
    try passphrase_row.appendChild(w.alloc, remember_passphrase);
    try key.appendChild(w.alloc, passphrase_row);
    try auth_body.appendChild(w.alloc, key);
    const pw = try ui.boxStyled(cx, S.stack, .{});
    w.cred_pw_row = pw;
    const password_row = try ui.box(cx, .{ .width = .fill(), .height = .{ .fit = .{} }, .direction = .row, .align_items = .end, .gap = 16 }, .{});
    try pw.appendChild(w.alloc, password_row);
    _ = try field(w, password_row, "密码", w.sig_password.?, "可留空，连接时再输入", "wizard.password", null, true);
    const remember = try ui.widgets.Checkbox(.{ .checked = w.sig_save_password.?, .label = "保存密码", .box_size = @as(f32, 14), .label_font_size = @as(f32, 11), .disabled = w.locked.?, .on_change = cx.on(RemoteEditor, w, RemoteEditor.onSavePasswordChanged) }).mount(w.scope, cx);
    remember.setStyleInline(w.alloc, .{ .width = .{ .fit = .{} }, .height = .{ .px = 34 }, .gap = 8, .flex_shrink = 0 });
    remember.meta.ownership.meta.test_id = "wizard.password.remember";
    w.remember_checkbox = remember;
    paintCheckboxLabels(remember);
    try password_row.appendChild(w.alloc, remember);
    const reveal_error = try ui.textStyled(cx, S.hint, "无法完成系统身份验证，密码保持隐藏，请重试。");
    reveal_error.setTextColor(S.theme.current().danger);
    reveal_error.setDisplay(.none);
    reveal_error.meta.ownership.meta.test_id = "wizard.password.reveal.error";
    w.password_reveal_error = reveal_error;
    try pw.appendChild(w.alloc, reveal_error);
    try auth_body.appendChild(w.alloc, pw);
    const agent = try ui.textStyled(cx, S.paragraph, "建立连接时从本机 SSH Agent 获取可用身份，不读取或保存私钥。");
    agent.meta.ownership.meta.test_id = "wizard.auth.agent_notice";
    w.agent_notice = agent;
    try auth_body.appendChild(w.alloc, agent);
    try auth_card.appendChild(w.alloc, auth_body);
    try columns.appendChild(w.alloc, auth_card);
    try root.appendChild(w.alloc, columns);

    const advanced = try ui.boxStyled(cx, S.advancedSection, .{});
    w.step2_advanced = advanced;
    advanced.meta.ownership.meta.test_id = "wizard.advanced.card";
    _ = try disclosure(w, advanced, "高级选项", "wizard.advanced.toggle", RemoteEditor.onAdvancedToggle);
    const advanced_body = try ui.boxStyled(cx, S.identityPanel, .{});
    advanced_body.setStyleInline(w.alloc, .{ .gap = 20, .padding = ui.Padding.all(16) });
    w.advanced_body = advanced_body;
    advanced_body.meta.ownership.meta.test_id = "wizard.advanced.body";
    const settings = try ui.box(cx, S.reviewColumns(), .{});
    settings.style.gap = 32;
    settings.style.align_items = .start;
    const ssh_fields = try ui.boxStyled(cx, S.identityFields, .{});
    const terminal_fields = try ui.boxStyled(cx, S.identityFields, .{});
    for ([_]*ui.Node{ ssh_fields, terminal_fields }) |column| {
        column.setStyleInline(w.alloc, .{ .flex = 1, .min_width = 0, .gap = 7.5 });
        try settings.appendChild(w.alloc, column);
    }
    try advanced_body.appendChild(w.alloc, settings);
    const policy_field = try ui.box(cx, S.field(null), .{});
    try policy_field.appendChild(w.alloc, try fieldLabel(cx, "主机密钥策略"));
    const policy_options = [_]ui.widgets.SelectOption{
        .{ .value = "true", .label = "严格验证主机密钥（推荐）", .test_id = "wizard.strict.enabled" },
        .{ .value = "false", .label = "关闭严格验证（测试环境）", .test_id = "wizard.strict.disabled" },
    };
    const policy = try ui.widgets.Select(.{ .options = &policy_options, .value = w.sig_strict_policy.?, .width = S.width - 48, .disabled = w.locked.?, .on_change = cx.on(RemoteEditor, w, RemoteEditor.onStrictPolicyChanged) }).mount(w.scope, cx);
    skinSelect(w, policy, 34, 12);
    policy.trigger.addBeforeRender(paintPanelControl);
    policy.wrapper.setStyleInline(w.alloc, .{ .width = .fill(), .min_width = 0 });
    policy.trigger.meta.ownership.meta.test_id = "wizard.strict_host_key";
    w.strict_checkbox = policy.trigger;
    try policy_field.appendChild(w.alloc, policy.wrapper);
    try ssh_fields.appendChild(w.alloc, policy_field);

    const compression_field = try ui.box(cx, S.field(null), .{});
    try compression_field.appendChild(w.alloc, try fieldLabel(cx, "SSH 传输压缩"));
    const compression_choice = try w.scope.createSignal(?[]const u8, if (w.compression) "on" else "off");
    const compression_options = [_]ui.widgets.checkbox.RadioOption{
        .{ .value = "off", .label = "关闭", .test_id = "wizard.compression.disabled" },
        .{ .value = "on", .label = "开启", .test_id = "wizard.compression.enabled" },
    };
    const compression = try ui.widgets.RadioGroup(.{ .options = &compression_options, .value = compression_choice, .focus_ring = S.radioFocus(), .horizontal = true, .disabled = w.locked.?, .on_change = cx.on(RemoteEditor, w, RemoteEditor.onCompressionPicked) }).mount(w.scope, cx);
    skinIdentityRadios(w, compression);
    compression.meta.ownership.meta.test_id = "wizard.compression";
    if (compression.behavior.interaction.a11y) |*a11y| a11y.label = "SSH 传输压缩";
    w.compression_checkbox = compression;
    try w.scope.createEffect(.{ .checked = w.sig_compression.?, .choice = compression_choice }, struct {
        fn run(ctx: anytype) void {
            ctx.choice.set(if (ctx.checked.get()) "on" else "off");
        }
    }.run);
    try compression_field.appendChild(w.alloc, compression);
    try ssh_fields.appendChild(w.alloc, compression_field);

    const defaults = try ui.box(cx, S.fieldRow(), .{});
    w.connect_timeout_fact = try readonlyField(w, defaults, "连接超时（全局默认）", "—");
    w.connect_timeout_fact.?.meta.ownership.meta.test_id = "wizard.ssh.connect_timeout";
    w.keepalive_fact = try readonlyField(w, defaults, "保活间隔（全局默认）", "—");
    w.keepalive_fact.?.meta.ownership.meta.test_id = "wizard.ssh.keepalive";
    try ssh_fields.appendChild(w.alloc, defaults);
    const info_row = try ui.boxStyled(cx, S.identityFields, .{});
    info_row.setStyleInline(w.alloc, .{ .gap = 7.5 });
    info_row.meta.ownership.meta.test_id = "wizard.command_info.row";
    w.command_info_row = info_row;
    const info_field = try ui.box(cx, S.field(null), .{});
    info_field.meta.ownership.meta.test_id = "wizard.command_info.field";
    try info_field.appendChild(w.alloc, try helpLabel(w, "命令信息", "在命令首行右缘显示 AI、返回码与运行时间；鼠标悬停在命令上时隐藏，不影响复制。保存后立即更新已打开的此主机终端。", "wizard.command_info.help"));
    const info_options = [_]ui.widgets.SelectOption{
        .{ .value = "inherit", .label = "继承全局设置", .test_id = "wizard.command_info.inherit" },
        .{ .value = "on", .label = "显示", .test_id = "wizard.command_info.on" },
        .{ .value = "off", .label = "隐藏", .test_id = "wizard.command_info.off" },
    };
    const info_choice = try ui.widgets.Select(.{ .options = &info_options, .value = w.sig_command_info.?, .width = (S.width - 64) / 2, .disabled = w.locked.?, .on_change = cx.on(RemoteEditor, w, RemoteEditor.onCommandInfoPicked) }).mount(w.scope, cx);
    skinSelect(w, info_choice, 34, 12);
    info_choice.trigger.addBeforeRender(paintPanelControl);
    info_choice.wrapper.setStyleInline(w.alloc, .{ .width = .fill(), .min_width = 0 });
    info_choice.trigger.meta.ownership.meta.test_id = "wizard.command_info";
    try info_field.appendChild(w.alloc, info_choice.wrapper);
    try info_row.appendChild(w.alloc, info_field);

    const shell_field = try ui.box(cx, S.field(null), .{});
    w.shell_integration_field = shell_field;
    try shell_field.appendChild(w.alloc, try helpLabel(w, "自动会话初始化", "每次连接 SSH 时发送文本钩子以获取命令状态，不上传文件。登录后会自动运行其他程序的主机可关闭；下次新建会话或重连生效。", "wizard.shell_integration.help"));
    const shell_options = [_]ui.widgets.SelectOption{
        .{ .value = "inherit", .label = "继承全局设置", .test_id = "wizard.shell_integration.inherit" },
        .{ .value = "on", .label = "开启", .test_id = "wizard.shell_integration.on" },
        .{ .value = "off", .label = "关闭", .test_id = "wizard.shell_integration.off" },
    };
    const shell_choice = try ui.widgets.Select(.{ .options = &shell_options, .value = w.sig_shell_integration.?, .width = (S.width - 64) / 2, .disabled = w.locked.?, .on_change = cx.on(RemoteEditor, w, RemoteEditor.onShellIntegrationPicked) }).mount(w.scope, cx);
    skinSelect(w, shell_choice, 34, 12);
    shell_choice.trigger.addBeforeRender(paintPanelControl);
    shell_choice.wrapper.setStyleInline(w.alloc, .{ .width = .fill(), .min_width = 0 });
    shell_choice.trigger.meta.ownership.meta.test_id = "wizard.shell_integration";
    try shell_field.appendChild(w.alloc, shell_choice.wrapper);
    try info_row.appendChild(w.alloc, shell_field);
    try terminal_fields.appendChild(w.alloc, info_row);
    const terminal_row = try ui.box(cx, S.fieldRow(), .{});
    terminal_row.style.gap = 12;
    const encoding = try field(w, terminal_row, "字符编码", w.sig_encoding.?, "UTF-8", "wizard.encoding", 118, false);
    encoding.input_container.setStyleInline(w.alloc, S.groupInput());
    _ = try field(w, terminal_row, "终端最大显示行数", w.sig_scrollback.?, "继承全局；0 不限制", "wizard.scrollback", null, false);
    try terminal_fields.appendChild(w.alloc, terminal_row);

    const commands = try ui.boxStyled(cx, S.commandField, .{});
    w.commands_card = commands;
    w.commands_details = commands;
    try commands.appendChild(w.alloc, try fieldLabel(cx, "启动命令 · 每行一条，连接后依次执行"));
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
    textarea.input.setStyleInline(w.alloc, .{ .border = .{ .radius = 8, .width = 0, .color = ui.Color.TRANSPARENT } });
    textarea.input.addBeforeRender(paintPanelControl);
    textarea.wrapper.setStyleInline(w.alloc, .{ .width = .fill(), .min_width = 0, .flex_shrink = 0 });
    w.startup_textarea = textarea;
    try commands.appendChild(w.alloc, textarea.wrapper);
    try advanced_body.appendChild(w.alloc, commands);
    w.advanced_disclosure = try @import("../../ui/layout_motion.zig").Disclosure.mount(cx, w.scope, advanced_body, w.advanced_expanded);
    try advanced.appendChild(w.alloc, w.advanced_disclosure.?.root);
    try root.appendChild(w.alloc, advanced);
    return root;
}

const RouteChoice = struct { root: *ui.Node, title: *ui.Node, mark: *ui.Node };

fn mountAccessChoice(w: *RemoteEditor, parent: *ui.Node, index: usize, title: []const u8, id: []const u8, comptime callback: *const fn (*RemoteEditor) void) !void {
    const height: f32 = if (index == 0) 40 else 43;
    var style = S.row(height);
    style.padding = .{ .left = 16 };
    style.gap = 10;
    style.justify = .start;
    style.background = ui.Color.TRANSPARENT;
    const root = try ui.widgets.Button(.{ .variant = .ghost, .a11y_label = title, .disabled = w.locked.?, .base_style = style, .on_click = w.cx.on(RemoteEditor, w, callback) }).mount(w.scope, w.cx);
    root.meta.ownership.meta.test_id = id;
    for (root.children.items) |child| child.setDisplay(.none);
    root.setStyleInline(w.alloc, style);
    const mark = try ui.iconTint(w.cx, ui.icons.circle, S.theme.current().fg_2, S.icon(14));
    try root.appendChild(w.alloc, mark);
    const heading = try ui.text(w.cx, title, S.text(13, 600, false));
    heading.setStyleInline(w.alloc, .{ .width = .fill(), .min_width = 0, .flex = 1 });
    try root.appendChild(w.alloc, heading);
    try parent.appendChild(w.alloc, root);
    w.route_choices[index] = .{ .root = root, .title = heading, .mark = mark };
}

fn mountRoute(w: *RemoteEditor) !*ui.Node {
    const root = try ui.box(w.cx, .{ .width = .fill(), .height = .{ .fit = .{} }, .direction = .column, .gap = 8, .flex_shrink = 0 }, .{});
    w.route_body = root;
    try mountAccessChoice(w, root, 0, "从本机直接连接", "wizard.access.direct", RemoteEditor.onAccessDirect);
    const card = try ui.box(w.cx, .{ .width = .fill(), .height = .{ .fit = .{} }, .direction = .column, .border = .{ .radius = 12 }, .flex_shrink = 0 }, .{});
    w.route_card = card;
    card.meta.ownership.meta.test_id = "wizard.route.card";
    try root.appendChild(w.alloc, card);
    try mountAccessChoice(w, card, 1, "经 SSH 跳板连接", "wizard.access.jump", RemoteEditor.onAccessJump);

    const area = try ui.widgets.ScrollArea(.{ .direction = .vertical, .rubber_band_y = false }).mount(w.scope, w.cx);
    area.container.meta.ownership.meta.test_id = "wizard.route.chain";
    area.container.setStyleInline(w.alloc, .{ .width = .{ .grow = .{} }, .height = .{ .px = 68 }, .margin = .{ .left = 16, .right = 16, .bottom = 16 }, .background = S.theme.popupInset(), .border = .{ .radius = 8 }, .flex_shrink = 0 });
    try card.appendChild(w.alloc, area.container);
    w.route_chain_scroll = area;
    const preview = &w.route_previews[0];
    preview.row = area.content;

    const endpoint_fill = S.routeEndpointFill();
    for (0..10) |i| {
        if (i > 0) {
            const edge = try RouteEdge.mount(w, i - 1);
            w.route_edges[i - 1] = edge;
            preview.arrows[i - 1] = edge.root;
            try area.content.appendChild(w.alloc, edge.root);
        }
        const hop = i > 0 and i < 9;
        var style = S.row(52);
        if (!hop) style.background = endpoint_fill;
        const node = try ui.box(w.cx, style, .{});
        preview.nodes[i] = node;
        if (i == 9) node.meta.ownership.meta.test_id = "wizard.route.target";
        try area.content.appendChild(w.alloc, node);
        const main = if (hop) try RouteHopControl.mount(w, node, i - 1) else node;
        const asset = if (i == 0) ui.icons.laptop else ui.icons.server;
        const icon = if (hop) try S.theme.icon(w.cx, asset, "accent", S.icon(24)) else try S.theme.icon(w.cx, asset, "fg_2", S.icon(24));
        try main.appendChild(w.alloc, icon);
        const labels = try ui.box(w.cx, .{ .width = .fill(), .height = .{ .fit = .{} }, .direction = .column, .flex = 1, .min_width = 0, .gap = 1 }, .{});
        try main.appendChild(w.alloc, labels);
        if (i != 0) {
            var buffer: [24]u8 = undefined;
            const role = if (hop) try std.fmt.bufPrint(&buffer, "跳板 {d}", .{i}) else "目标主机";
            var role_style = S.text(10, 500, false);
            role_style.line_height = 12.0 / 10.0;
            role_style.color = S.theme.current().fg_3;
            const label = try ui.text(w.cx, role, role_style);
            try labels.appendChild(w.alloc, label);
        }
        var name_style = S.text(13, 600, false);
        name_style.line_height = 17.0 / 13.0;
        var address_style = S.text(10.5, 400, true);
        address_style.line_height = 13.0 / 10.5;
        preview.names[i] = try ui.text(w.cx, if (i == 0) "本机" else "", name_style);
        preview.addresses[i] = try ui.text(w.cx, if (i == 0) "127.0.0.1" else "", address_style);
        for ([_]*ui.Node{ preview.names[i].?, preview.addresses[i].? }) |label| {
            label.setStyleInline(w.alloc, .{ .width = .fill(), .min_width = 0 });
            try labels.appendChild(w.alloc, label);
        }
    }
    w.topo_name = preview.names[9];
    w.topo_addr = preview.addresses[9];
    w.route_empty_hint = try ui.textStyled(w.cx, S.paragraph, "");
    w.route_empty_hint.?.meta.ownership.meta.test_id = "wizard.route.error";
    w.route_empty_hint.?.setTextColor(S.theme.current().danger_ink);
    try root.appendChild(w.alloc, w.route_empty_hint.?);
    w.route_hint = try ui.textStyled(w.cx, S.paragraph, "SFTP 暂不支持跳板。可仅保存配置，或改为直连后浏览。");
    try root.appendChild(w.alloc, w.route_hint.?);
    w.route_picker = try RoutePicker.mount(w, root);
    return root;
}

const RouteEdge = struct {
    root: *ui.Node,
    width: f32,
    line: *ui.Node,
    arrow: *ui.Node,
    button: *ui.Node,
    badge: *ui.Node,
    icon: *ui.Node,

    fn mount(w: *RemoteEditor, index: usize) !RouteEdge {
        const context = try w.alloc.create(RouteInsert);
        context.* = .{ .wizard = w, .index = index };
        try w.scope.onCleanup(RouteInsert, context, RouteInsert.cleanup);
        const root = try ui.box(w.cx, .{}, .{});
        const line = try ui.box(w.cx, .{ .hit_behavior = .pass_through }, .{});
        const arrow = try ui.iconTint(w.cx, ui.icons.chevron_right, S.theme.current().fg_2, S.icon(14));
        try root.appendChild(w.alloc, line);
        try root.appendChild(w.alloc, arrow);
        var style = S.button(24, 24, false);
        style.background = ui.Color.TRANSPARENT;
        const button = try ui.widgets.Button(.{ .variant = .ghost, .a11y_label = "在此处添加跳板", .disabled = w.jump_add_disabled.?, .base_style = style, .on_click = w.cx.on(RouteInsert, context, RouteInsert.click) }).mount(w.scope, w.cx);
        for (button.children.items) |child| child.setDisplay(.none);
        button.setStyleInline(w.alloc, style);
        context.anchor = button;
        var id: [40]u8 = undefined;
        button.meta.ownership.meta.test_id = try ownedId(w, &id, "wizard.route.insert.{d}", index);
        const badge = try ui.box(w.cx, .{ .width = .{ .px = 16 }, .height = .{ .px = 16 }, .border = .{ .radius = 8 }, .align_items = .center, .justify = .center, .background = S.theme.popupSelection(), .hit_behavior = .pass_through }, .{});
        const icon = try ui.iconTint(w.cx, ui.icons.plus, S.theme.current().accent, S.icon(12));
        try badge.appendChild(w.alloc, icon);
        try button.appendChild(w.alloc, badge);
        try root.appendChild(w.alloc, button);
        return .{ .root = root, .width = if (index == 0) 74 else 54, .line = line, .arrow = arrow, .button = button, .badge = badge, .icon = icon };
    }

    fn layout(self: RouteEdge, w: *RemoteEditor, vertical: bool) void {
        self.root.setStyleInline(w.alloc, .{ .width = if (vertical) .fill() else .{ .px = self.width }, .height = .{ .px = if (vertical) 38 else 56 }, .flex_shrink = 0 });
        self.line.setStyleInline(w.alloc, .{
            .position = .absolute,
            .inset = if (vertical) .{ .left = .{ .px = 21 }, .top = .{ .px = 3 } } else .{ .left = .{ .px = 3 }, .top = .{ .px = 28 } },
            .width = .{ .px = if (vertical) 1.35 else self.width - 10 },
            .height = .{ .px = if (vertical) 29 else 1.35 },
        });
        self.arrow.setStyleInline(w.alloc, .{
            .position = .absolute,
            .inset = if (vertical) .{ .left = .{ .px = 15 }, .top = .{ .px = 24 } } else .{ .left = .{ .px = self.width - 15 }, .top = .{ .px = 22 } },
            .width = .{ .px = 14 },
            .height = .{ .px = 14 },
        });
        paintIcon(self.arrow, if (vertical) ui.icons.chevron_down else ui.icons.chevron_right, 14, S.theme.current().fg_2);
        self.button.setStyleInline(w.alloc, .{ .position = .absolute, .inset = .{ .left = .{ .px = if (vertical) 23 else self.width / 2 - 12 }, .top = .{ .px = if (vertical) 7 else 2 } } });
        self.paint();
    }

    fn paint(self: RouteEdge) void {
        const colors = S.theme.current();
        const surface = S.theme.popupInset();
        const line = ui.Color.lerp(colors.fg_2, surface, 0.22);
        self.line.setBackground(line);
        _ = self.arrow.setTint(line);
        self.badge.setBackground(ui.Color.lerp(surface, colors.accent, 0.24));
        _ = self.icon.setTint(colors.fg_1);
    }
};

const RouteInsert = struct {
    wizard: *RemoteEditor,
    index: usize,
    anchor: *ui.Node = undefined,

    fn cleanup(self: *RouteInsert) void {
        self.wizard.alloc.destroy(self);
    }

    fn click(self: *RouteInsert) void {
        const w = self.wizard;
        if (w.isLocked() or w.jump_add_disabled.?.peek() or self.index > w.jump_count) return;
        w.route_picker.?.show(self.anchor, .{ .insert = self.index });
    }
};

const RouteHopControl = struct {
    wizard: *RemoteEditor,
    index: usize,
    trigger: *ui.Node = undefined,
    items: *ui.Signal([]const ui.widgets.MenuItem),
    menu_open: ?*ui.Signal(bool) = null,

    fn cleanup(self: *RouteHopControl) void {
        self.wizard.alloc.destroy(self);
    }

    fn mount(w: *RemoteEditor, row: *ui.Node, index: usize) !*ui.Node {
        const self = try w.alloc.create(RouteHopControl);
        self.* = .{ .wizard = w, .index = index, .items = undefined };
        w.scope.onCleanup(RouteHopControl, self, cleanup) catch |err| {
            w.alloc.destroy(self);
            return err;
        };
        self.items = try w.scope.createList(ui.widgets.MenuItem, &.{});
        w.route_hop_controls[index] = self;

        var content_style = S.row(52);
        content_style.flex = 1;
        content_style.min_width = 0;
        content_style.justify = .start;
        content_style.gap = 9;
        content_style.padding = .{};
        content_style.background = ui.Color.TRANSPARENT;
        content_style.cursor = .pointer;
        const shell = try ui.widgets.control_shell.ControlShell(.{
            .tag = .button,
            .style = content_style,
            .interactive = false,
            .focus_ring = false,
        }, .{}).mount(w.scope, w.cx);
        self.trigger = shell.node;
        self.trigger.setStyleInline(w.alloc, content_style);
        self.trigger.behavior.interaction.a11y = .{ .role = .button, .label = "选择 SSH 跳板主机" };
        self.trigger.behavior.events.on_click = ui.Cx.handlerFrom(RouteHopControl, self, replace);
        var id: [48]u8 = undefined;
        self.trigger.meta.ownership.meta.test_id = try ownedId(w, &id, "wizard.route.hop.{d}", index);
        try row.appendChild(w.alloc, self.trigger);

        const focus = try ui.hooks.useFocusState(w.scope, w.cx, self.trigger);
        try w.scope.createEffect(.{ .visible = focus.visible, .locked = w.locked.?, .trigger = self.trigger, .row = row, .theme = try w.cx.themeSignal(w.scope) }, struct {
            fn paint(ctx: anytype) void {
                _ = ctx.theme.get();
                const locked = ctx.locked.get();
                ctx.trigger.setFocusable(!locked);
                ctx.trigger.behavior.interaction.a11y.?.disabled = locked;
                const keyboard_focus = ctx.visible.get() and !locked;
                const colors = S.theme.states();
                ctx.row.setBackground(if (keyboard_focus) colors.selected_hover else colors.selected);
            }
        }.paint);

        const menu = try ui.widgets.Menu(.{ .items = self.items, .width = 154, .position = .bottom_end, .on_select = w.cx.on(RouteHopControl, self, select) }).mount(w.scope, w.cx);
        self.menu_open = menu.open;
        var style = S.button(26, 26, false);
        style.background = ui.Color.TRANSPARENT;
        const button = try ui.widgets.Button(.{ .variant = .ghost, .icon_only = true, .icon_asset = ui.icons.ellipsis, .icon_size = @as(f32, 15), .a11y_label = "跳板操作", .disabled = w.locked.?, .base_style = style }).mount(w.scope, w.cx);
        button.meta.ownership.meta.test_id = try ownedId(w, &id, "wizard.route.menu.{d}", index);
        menu.wrapper.setStyleInline(w.alloc, .{ .width = .{ .px = 26 }, .height = .{ .px = 26 }, .flex_shrink = 0 });
        try menu.trigger.appendChild(w.alloc, button);
        try row.appendChild(w.alloc, menu.wrapper);
        return self.trigger;
    }

    fn refresh(self: *RouteHopControl) void {
        self.items.set(&.{
            .{ .id = "replace", .label = "更换主机" },
            .{ .id = "previous", .label = "前移", .disabled = self.index == 0 },
            .{ .id = "next", .label = "后移", .disabled = self.index + 1 >= self.wizard.jump_count },
            .{ .id = "remove", .label = "移除跳板", .danger = true },
        });
    }

    fn replace(self: *RouteHopControl) void {
        if (self.wizard.isLocked() or self.index >= self.wizard.jump_count) return;
        self.wizard.route_picker.?.show(self.trigger, .{ .replace = self.index });
    }

    fn select(self: *RouteHopControl, command: []const u8) void {
        if (std.mem.eql(u8, command, "replace")) return self.replace();
        const kind: EditorKind = if (std.mem.eql(u8, command, "previous")) .jump_up else if (std.mem.eql(u8, command, "next")) .jump_down else if (std.mem.eql(u8, command, "remove")) .jump_remove else return;
        EditorAction.apply(self.wizard, self.index, kind);
    }
};

const RoutePicker = struct {
    const Target = union(enum) { insert: usize, replace: usize };
    const Option = struct {
        picker: *RoutePicker,
        value: []const u8,

        fn cleanup(self: *Option) void {
            self.picker.wizard.alloc.destroy(self);
        }

        fn choose(self: *Option) void {
            self.picker.choose(self.value);
        }
    };

    wizard: *RemoteEditor,
    popup: ui.widgets.popover.PopoverResult = undefined,
    input: ui.widgets.input.InputResult = undefined,
    query: *ui.Signal([]const u8) = undefined,
    list: ui.widgets.ScrollAreaResult = undefined,
    row_scope: ?*ui.Scope = null,
    source: ?*ui.Node = null,
    target: Target = .{ .insert = 0 },
    dirty: bool = false,
    focus_pending: bool = false,

    fn cleanup(self: *RoutePicker) void {
        self.wizard.alloc.destroy(self);
    }

    fn mount(w: *RemoteEditor, parent: *ui.Node) !*RoutePicker {
        const self = try w.alloc.create(RoutePicker);
        self.* = .{ .wizard = w };
        w.scope.onCleanup(RoutePicker, self, cleanup) catch |err| {
            w.alloc.destroy(self);
            return err;
        };
        self.popup = try ui.widgets.Popover(.{
            .trigger = .manual,
            .position = .bottom,
            .width = 216,
            .max_height = 202,
            .offset = .{ .static = 10 },
            .anchor = .{ .virtual = .{ .ctx = self, .getRect = anchor } },
            .on_open_change = w.cx.on(RoutePicker, self, openChanged),
            .constrain_width_to_viewport = true,
            .shift_main_axis = true,
            .close_on_escape = true,
            .size_policy = .fit_content,
            .a11y_role = .dialog,
        }).mount(w.scope, w.cx);
        const popup = self.popup;
        popup.wrapper.setStyleInline(w.alloc, .{ .position = .absolute, .width = .{ .px = 0 }, .height = .{ .px = 0 } });
        try parent.appendChild(w.alloc, popup.wrapper);
        popup.content.meta.ownership.meta.test_id = "wizard.route.picker";
        popup.content.setStyleInline(w.alloc, .{ .padding = ui.Padding.all(8), .direction = .column, .gap = 6 });
        self.query = try popup.scope.createText("", .{});
        self.input = try ui.widgets.Input(.{
            .value = self.query,
            .placeholder = "搜索 SSH 主机",
            .size = .sm,
            .leading_icon_asset = ui.icons.search,
            .on_change = w.cx.on(RoutePicker, self, queryChanged),
            .on_submit = w.cx.on(RoutePicker, self, submit),
        }).mountResult(popup.scope, w.cx);
        self.input.input_container.meta.ownership.meta.test_id = "wizard.route.search";
        try popup.content.appendChild(w.alloc, self.input.node);
        self.list = try ui.widgets.ScrollArea(.{ .direction = .vertical, .rubber_band_y = false }).mount(popup.scope, w.cx);
        self.list.content.setStyleInline(w.alloc, .{ .width = .fill(), .height = .{ .fit = .{} }, .direction = .column, .gap = 2 });
        try popup.content.appendChild(w.alloc, self.list.container);
        self.paint();
        return self;
    }

    fn anchor(raw: *anyopaque) ui.widgets.popover.AnchorRect {
        const self: *RoutePicker = @ptrCast(@alignCast(raw));
        const rect = (self.source orelse return .{ .x = 0, .y = 0, .w = 0, .h = 0 }).globalRect();
        const gap: f32 = if (self.target == .insert and !self.wizard.routeIsVertical()) 12 else 0;
        return .{ .x = rect.x, .y = rect.y, .w = rect.w, .h = rect.h + gap };
    }

    fn show(self: *RoutePicker, source: *ui.Node, target: Target) void {
        self.source = source;
        self.target = target;
        self.query.set("");
        self.dirty = true;
        self.focus_pending = true;
        self.popup.show.invoke();
        self.paintAnchor(true);
        self.wizard.cx.requestRedraw();
    }

    fn paintAnchor(self: *RoutePicker, active: bool) void {
        const index = switch (self.target) {
            .insert => |index| index,
            .replace => return,
        };
        const edge = self.wizard.route_edges[index].?;
        if (active) {
            const colors = S.theme.current();
            edge.badge.setBackground(colors.accent);
            _ = edge.icon.setTint(S.theme.patchInk(colors.overlay, &.{colors.accent}));
        } else edge.paint();
    }

    fn close(self: *RoutePicker) void {
        if (self.popup.open.?.peek()) self.popup.close.invoke();
    }

    fn openChanged(self: *RoutePicker, open: bool) void {
        if (open) return;
        self.paintAnchor(false);
        self.focus_pending = false;
        if (self.source) |source| self.wizard.cx.setFocus(source);
    }

    fn paint(self: *RoutePicker) void {
        self.popup.chrome.setBackground(S.theme.popupAction());
        self.input.input_container.setBackground(S.theme.popupInset());
        self.input.state.tokens = self.wizard.cx.tokens;
        self.input.state.dirty = true;
        if (self.popup.open.?.peek()) self.paintAnchor(true);
        self.dirty = true;
    }

    fn queryChanged(self: *RoutePicker, _: []const u8) void {
        self.dirty = true;
        self.wizard.cx.requestRedraw();
    }

    fn options(self: *RoutePicker) []const ui.widgets.SelectOption {
        const w = self.wizard;
        return switch (self.target) {
            .insert => w.asset_options.?.peek(),
            .replace => |index| w.jump_options[index].?.peek(),
        };
    }

    fn available(self: *RoutePicker, option: ui.widgets.SelectOption) bool {
        const w = self.wizard;
        return !option.disabled and w.routeAssetAllowed(option.value) and (self.target == .replace or w.routeAssetUnused(option.value));
    }

    fn matches(self: *RoutePicker, option: ui.widgets.SelectOption) bool {
        return self.available(option) and std.ascii.findIgnoreCase(option.label, trim(self.query.peek())) != null;
    }

    fn submit(self: *RoutePicker, _: []const u8) void {
        for (self.options()) |option| if (self.matches(option)) {
            self.choose(option.value);
            return;
        };
    }

    fn choose(self: *RoutePicker, value: []const u8) void {
        const w = self.wizard;
        if (w.isLocked() or w.step != .form or !self.popup.open.?.peek()) return;
        for (self.options()) |option| {
            if (std.mem.eql(u8, option.value, value) and self.available(option)) break;
        } else return;
        const index = switch (self.target) {
            .replace => |index| blk: {
                if (index >= w.jump_count) return;
                break :blk index;
            },
            .insert => |index| blk: {
                if (w.jump_add_disabled.?.peek() or index > w.jump_count) return;
                var end = w.jump_count;
                while (end > index) : (end -= 1) w.setJump(end, w.jump_values[end - 1].?.peek());
                w.jump_count += 1;
                if (w.sig_socks_exit.?.peek()) |text| {
                    const exit_index = std.fmt.parseInt(usize, text, 10) catch w.jump_count;
                    if (exit_index >= index and exit_index < w.jump_count - 1) {
                        var buffer: [4]u8 = undefined;
                        w.socks_exit_text.?.set(std.fmt.bufPrint(&buffer, "{d}", .{exit_index + 1}) catch "");
                        w.sig_socks_exit.?.set(w.socks_exit_text.?.peek());
                    }
                }
                break :blk index;
            },
        };
        self.close();
        w.setJump(index, value);
        w.route_reveal = index;
        w.onSelection(null);
    }

    fn update(self: *RoutePicker) bool {
        if (!self.popup.open.?.peek()) return false;
        if (self.dirty) {
            self.dirty = false;
            self.rebuild() catch return false;
            return true;
        }
        if (self.focus_pending) {
            self.focus_pending = false;
            self.wizard.cx.setFocus(self.input.input_container);
        }
        return false;
    }

    fn rebuild(self: *RoutePicker) !void {
        const w = self.wizard;
        const list = self.list.content;
        for (list.children.items) |node| w.cx.invalidateReferencesTo(node);
        if (self.row_scope) |scope| scope.dispose();
        self.row_scope = null;
        while (list.children.items.len != 0) {
            const node = list.children.items[list.children.items.len - 1];
            w.cx.detachChild(list, node);
            w.cx.destroyDetached(node);
        }
        const scope = try self.popup.scope.childScope();
        self.row_scope = scope;
        var count: usize = 0;
        for (self.options()) |option| {
            if (!self.matches(option)) continue;
            const ctx = try w.alloc.create(Option);
            ctx.* = .{ .picker = self, .value = option.value };
            scope.onCleanup(Option, ctx, Option.cleanup) catch |err| {
                w.alloc.destroy(ctx);
                return err;
            };
            var style = S.row(30);
            style.padding = .{ .left = 8 };
            style.background = if (count == 0) S.theme.popupSelection() else ui.Color.TRANSPARENT;
            style.border = .{ .radius = 6 };
            style.justify = .start;
            const row = try ui.widgets.Button(.{ .variant = .ghost, .a11y_label = option.label, .base_style = style, .on_click = w.cx.on(Option, ctx, Option.choose) }).mount(scope, w.cx);
            for (row.children.items) |child| child.setDisplay(.none);
            row.setStyleInline(w.alloc, style);
            row.meta.ownership.meta.test_id = "wizard.route.option";
            try row.appendChild(w.alloc, try ui.iconTint(w.cx, ui.icons.server, S.theme.current().fg_2, S.icon(14)));
            const name = try ui.text(w.cx, option.label, S.text(12, 600, false));
            name.setStyleInline(w.alloc, .{ .width = .fill(), .min_width = 0, .flex = 1 });
            try row.appendChild(w.alloc, name);
            try list.appendChild(w.alloc, row);
            count += 1;
        }
        if (count == 0) {
            const empty = try ui.text(w.cx, "没有可选的 SSH 主机", S.text(12, 400, false));
            empty.setStyleInline(w.alloc, S.row(30));
            try list.appendChild(w.alloc, empty);
        }
        const visible: usize = @min(@max(count, 1), 4);
        self.list.container.setStyleInline(w.alloc, .{ .width = .fill(), .height = .{ .px = @floatFromInt(visible * 32 - 2) }, .flex_shrink = 0 });
        ui.widgets.setScrollY(self.list.state, list, 0);
    }
};

fn mountTestRoutePreview(w: *RemoteEditor) !*ui.Node {
    const scroll = try ui.widgets.ScrollArea(.{ .height = 76, .direction = .horizontal }).mount(w.scope, w.cx);
    scroll.container.setStyleInline(w.alloc, .{ .width = .fill(), .height = .{ .px = 76 }, .flex_shrink = 0 });
    const row = scroll.content;
    row.setStyleInline(w.alloc, .{ .width = .{ .px = 668 }, .height = .{ .px = 76 }, .direction = .row, .align_items = .center, .justify = .center, .gap = 6, .flex_shrink = 0 });
    var preview = &w.route_previews[1];
    preview.row = row;
    for (0..10) |i| {
        if (i != 0) {
            const arrow = try ui.box(w.cx, .{ .width = .{ .px = 12 }, .height = .{ .px = 76 }, .align_items = .center, .justify = .center, .flex_shrink = 0 }, .{});
            try arrow.appendChild(w.alloc, try ui.iconTint(w.cx, ui.icons.chevron_right, S.theme.current().fg_3, .{ .width = .{ .px = 10 }, .height = .{ .px = 16 } }));
            preview.arrows[i - 1] = arrow;
            try row.appendChild(w.alloc, arrow);
        }
        const node = blk: {
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
        };
        preview.nodes[i] = node;
        preview.names[i] = try ui.text(w.cx, if (i == 0) "Local" else "", S.testNodeText(.name));
        preview.addresses[i] = try ui.text(w.cx, if (i == 0) "127.0.0.1" else "", S.testNodeText(.address));
        preview.users[i] = try ui.text(w.cx, if (i == 0) "本机" else "待连接", S.testNodeText(.status));
        {
            const name_row = try ui.box(w.cx, S.row(20), .{});
            try name_row.appendChild(w.alloc, try ui.iconTint(w.cx, if (i == 0) ui.icons.laptop else ui.icons.server, S.theme.current().fg_2, .{ .width = .{ .px = 14 }, .height = .{ .px = 14 }, .flex_shrink = 0 }));
            preview.names[i].?.setStyleInline(w.alloc, .{ .width = .fill(), .height = .{ .px = 16 }, .min_width = 0 });
            try name_row.appendChild(w.alloc, preview.names[i].?);
            try node.appendChild(w.alloc, name_row);
            preview.addresses[i].?.setStyleInline(w.alloc, .{ .width = .fill(), .height = .{ .px = 14 } });
            preview.users[i].?.setStyleInline(w.alloc, .{ .width = .fill(), .height = .{ .px = 16 } });
        }
        try node.appendChild(w.alloc, preview.addresses[i].?);
        try node.appendChild(w.alloc, preview.users[i].?);
        try row.appendChild(w.alloc, node);
    }
    return scroll.container;
}

fn mountReviewSummary(w: *RemoteEditor, root: *ui.Node) !void {
    const summary = try ui.box(w.cx, S.reviewIdentity(), .{});
    w.summary_card = summary;
    summary.meta.ownership.meta.test_id = "wizard.review.summary";
    const icon_tile = try ui.box(w.cx, S.reviewIconTile(44, true), .{});
    w.summary_icon = try ui.iconTint(w.cx, ui.icons.terminal, S.theme.current().accent_ink, S.icon(24));
    w.summary_icon.?.meta.ownership.meta.test_id = "wizard.review.summary.icon";
    try icon_tile.appendChild(w.alloc, w.summary_icon.?);
    try summary.appendChild(w.alloc, icon_tile);
    const identity_copy = try ui.box(w.cx, .{ .width = .fill(), .min_width = 0, .flex = 1, .direction = .column, .gap = 2 }, .{});
    w.summary_name = try ui.text(w.cx, "", S.summaryName());
    w.summary_name.?.meta.ownership.meta.test_id = "wizard.review.name";
    w.summary_name.?.setStyleInline(w.alloc, .{ .width = .fill() });
    try identity_copy.appendChild(w.alloc, w.summary_name.?);
    w.summary_identity = try ui.text(w.cx, "", S.text(12, 400, false));
    w.summary_identity.?.setStyleInline(w.alloc, .{ .width = .fill() });
    try identity_copy.appendChild(w.alloc, w.summary_identity.?);
    try summary.appendChild(w.alloc, identity_copy);

    const endpoint = try ui.box(w.cx, .{ .width = .fill(), .min_width = 0, .flex = 0.7, .direction = .column, .align_items = .end, .gap = 2 }, .{});
    var caption_style = S.row(18);
    caption_style.justify = .end;
    const endpoint_caption = try ui.box(w.cx, caption_style, .{});
    w.summary_values[0] = try ui.text(w.cx, "", S.text(12, 400, false));
    w.summary_values[0].?.meta.ownership.meta.test_id = "wizard.review.protocol";
    try endpoint_caption.appendChild(w.alloc, w.summary_values[0].?);
    try endpoint_caption.appendChild(w.alloc, try ui.text(w.cx, "目标地址", S.text(12, 400, false)));
    try endpoint.appendChild(w.alloc, endpoint_caption);
    var endpoint_text = S.text(18, 600, true);
    endpoint_text.text_align = .end;
    w.summary_endpoint = try ui.text(w.cx, "", endpoint_text);
    w.summary_endpoint.?.meta.ownership.meta.test_id = "wizard.review.endpoint";
    w.summary_endpoint.?.setStyleInline(w.alloc, .{ .width = .fill() });
    w.summary_values[1] = w.summary_endpoint;
    try endpoint.appendChild(w.alloc, w.summary_endpoint.?);
    try summary.appendChild(w.alloc, endpoint);
    try root.appendChild(w.alloc, summary);

    const columns = try ui.box(w.cx, S.reviewColumns(), .{});
    const details = try ui.box(w.cx, S.reviewRoute(), .{});
    details.meta.ownership.meta.test_id = "wizard.review.authentication";
    w.summary_details = details;
    const auth_header = try ui.box(w.cx, S.row(26), .{});
    try auth_header.appendChild(w.alloc, try ui.text(w.cx, "认证与验证", S.text(14, 600, false)));
    try auth_header.appendChild(w.alloc, try ui.spacer(w.cx));
    w.summary_edit = try action(w, auth_header, "编辑连接信息", "wizard.review.modify", 98, 26, false, w.locked, RemoteEditor.onSummaryModify, null);
    try details.appendChild(w.alloc, auth_header);
    const fields = try ui.box(w.cx, .{ .width = .fill(), .height = .fill(), .flex = 1, .min_height = 0, .direction = .column, .padding = .{ .bottom = 16 } }, .{});
    const labels = [_][]const u8{ "认证账户", "认证方式", "目标验证" };
    const ids = [_][]const u8{ "wizard.review.user", "wizard.review.auth", "wizard.review.verification" };
    for (labels, ids, 2..) |label, id, i| {
        var row_style = S.row(32);
        row_style.height = .fill();
        row_style.min_height = 18;
        row_style.flex = 1;
        const row = try ui.box(w.cx, row_style, .{});
        const key = try ui.text(w.cx, label, S.text(12, 400, false));
        key.setStyleInline(w.alloc, .{ .width = .{ .px = 82 }, .flex_shrink = 0 });
        try row.appendChild(w.alloc, key);
        const value = try ui.text(w.cx, "", S.text(13, 550, i == 2));
        value.meta.ownership.meta.test_id = id;
        value.setStyleInline(w.alloc, .{ .width = .fill(), .min_width = 0, .flex = 1 });
        w.summary_values[i] = value;
        try row.appendChild(w.alloc, value);
        try fields.appendChild(w.alloc, row);
    }
    w.summary_options = try ui.textStyled(w.cx, S.summaryOptions, "");
    w.summary_options.?.meta.ownership.meta.test_id = "wizard.review.options";
    try fields.appendChild(w.alloc, w.summary_options.?);
    try details.appendChild(w.alloc, fields);
    try columns.appendChild(w.alloc, details);

    const route_card = try ui.box(w.cx, S.reviewRoute(), .{});
    w.summary_route_card = route_card;
    const route_header = try ui.box(w.cx, S.row(26), .{});
    try route_header.appendChild(w.alloc, try ui.text(w.cx, "连接路径", S.text(14, 600, false)));
    try route_header.appendChild(w.alloc, try ui.spacer(w.cx));
    w.summary_route_edit = try action(w, route_header, "编辑路径", "wizard.review.route.modify", 70, 26, false, w.locked, RemoteEditor.onSummaryRouteModify, null);
    try route_card.appendChild(w.alloc, route_header);
    const row_height = S.reviewRouteRowHeight(false);
    const route = try ui.widgets.ScrollArea(.{ .height = 3 * row_height, .direction = .vertical, .rubber_band_y = false }).mount(w.scope, w.cx);
    w.summary_route_scroll = route;
    route.state.scrollbar_fade.fade_delay = std.math.maxInt(u32);
    route.container.meta.ownership.meta.test_id = "wizard.review.route.viewport";
    route.container.setStyleInline(w.alloc, .{ .width = .fill(), .flex_shrink = 0 });
    route.content.meta.ownership.meta.test_id = "wizard.review.route";
    route.content.setStyleInline(w.alloc, .{ .width = .fill(), .height = .{ .fit = .{} }, .direction = .column, .gap = 0, .padding = .{ .right = 12 } });
    var id_buffer: [48]u8 = undefined;
    for (&w.summary_route_nodes, 0..) |*slot, i| {
        var style = S.row(row_height);
        style.gap = 11;
        const item = try ui.box(w.cx, style, .{});
        item.meta.ownership.meta.test_id = try ownedId(w, &id_buffer, "wizard.review.route.node.{d}", i);
        slot.* = item;
        const tile = try ui.box(w.cx, S.reviewIconTile(26, false), .{});
        const icon = try ui.iconTint(w.cx, ui.icons.route, S.theme.current().fg_2, S.icon(16));
        w.summary_route_icons[i] = icon;
        try tile.appendChild(w.alloc, icon);
        try item.appendChild(w.alloc, tile);
        const name = try ui.text(w.cx, "", S.text(13, 550, false));
        name.setStyleInline(w.alloc, .{ .width = .fill(), .min_width = 0, .flex = 1 });
        w.summary_route_names[i] = name;
        try item.appendChild(w.alloc, name);
        const caption = try ui.text(w.cx, "", S.text(12, 400, false));
        caption.setStyleInline(w.alloc, .{ .flex_shrink = 0 });
        w.summary_route_captions[i] = caption;
        try item.appendChild(w.alloc, caption);
        try route.content.appendChild(w.alloc, item);
        item.setDisplay(.none);
    }
    try route_card.appendChild(w.alloc, route.container);
    try columns.appendChild(w.alloc, route_card);
    try root.appendChild(w.alloc, columns);

    var note_style = S.row(18);
    note_style.height = .{ .fit = .{} };
    note_style.align_items = .start;
    const note = try ui.box(w.cx, note_style, .{});
    w.summary_note = note;
    try note.appendChild(w.alloc, try ui.iconTint(w.cx, ui.icons.info, S.theme.current().fg_2, S.icon(14)));
    var note_text = S.text(12, 400, false);
    note_text.wrap = .word;
    note_text.text_overflow = .clip;
    const note_copy = try ui.text(w.cx, "仅保存配置不会建立会话。连接时逐跳验证主机身份并完成认证，失败即停止。", note_text);
    note_copy.setStyleInline(w.alloc, .{ .width = .fill(), .min_width = 0, .flex = 1 });
    try note.appendChild(w.alloc, note_copy);
    try root.appendChild(w.alloc, note);
}

fn mountReview(w: *RemoteEditor) !*ui.Node {
    var id_buffer: [80]u8 = undefined;
    const root = try ui.boxStyled(w.cx, S.reviewStack, .{});
    try mountReviewSummary(w, root);
    const card = try ui.boxStyled(w.cx, S.testResult, .{});
    w.review_test_card = card;
    card.meta.ownership.meta.test_id = "wizard.test.card";
    var header_style = S.row(36);
    header_style.background = ui.Color.TRANSPARENT;
    header_style.gap = 8;
    const header = try ui.widgets.Button(.{
        .variant = .ghost,
        .base_style = header_style,
        .a11y_label = "预检详情",
        .on_click = w.cx.on(RemoteEditor, w, RemoteEditor.onReviewToggle),
    }).mount(w.scope, w.cx);
    header.meta.ownership.meta.test_id = "wizard.test.toggle";
    for (header.children.items) |child| child.setDisplay(.none);
    header.setStyleInline(w.alloc, header_style);
    w.res_dot = try ui.box(w.cx, S.iconBox(16), .{});
    w.test_status_icon = try ui.iconTint(w.cx, ui.icons.circle, S.theme.current().fg_3, S.icon(16));
    try w.res_dot.?.appendChild(w.alloc, w.test_status_icon.?);
    try header.appendChild(w.alloc, w.res_dot.?);
    w.res_text = try ui.text(w.cx, "尚未测试", S.text(13, 550, false));
    w.res_text.?.setStyleInline(w.alloc, .{ .width = .fill(), .min_width = 0, .flex = 1 });
    w.res_text.?.meta.ownership.meta.test_id = "wizard.test.status";
    try header.appendChild(w.alloc, w.res_text.?);
    w.review_path = try ui.text(w.cx, "查看预检详情", S.text(12, 400, false));
    w.review_path.?.setStyleInline(w.alloc, .{ .flex_shrink = 0 });
    try header.appendChild(w.alloc, w.review_path.?);
    w.review_disclosure = try ui.iconTint(w.cx, ui.icons.chevron_right, S.theme.current().fg_3, S.icon(16));
    try header.appendChild(w.alloc, w.review_disclosure.?);
    try card.appendChild(w.alloc, header);
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
    try content.appendChild(w.alloc, try mountTestRoutePreview(w));
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
    w.test_copy_feedback = try @import("../../ui/copy_button.zig").Button.attach(w.cx, w.scope, copy);
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
    return root;
}

fn mountSaveError(w: *RemoteEditor) !*ui.Node {
    const banner = try ui.box(w.cx, S.saveError(), .{});
    w.save_error_banner = banner;
    banner.meta.ownership.meta.test_id = "wizard.save.error.banner";
    w.save_error_icon = try ui.iconTint(w.cx, ui.icons.circle_alert, S.theme.current().danger_ink, S.icon(16));
    try banner.appendChild(w.alloc, w.save_error_icon.?);
    const copy = try ui.box(w.cx, .{ .width = .fill(), .min_width = 0, .flex = 1, .direction = .column, .gap = 3 }, .{});
    var message_style = S.paragraph(undefined);
    message_style.font_weight = 500;
    message_style.font_size = 12;
    w.save_error_node = try ui.text(w.cx, "", message_style);
    w.save_error_node.?.meta.ownership.meta.test_id = "wizard.save.error";
    try copy.appendChild(w.alloc, w.save_error_node.?);
    w.save_error_hint = try ui.textStyled(w.cx, S.paragraph, "");
    try copy.appendChild(w.alloc, w.save_error_hint.?);
    try banner.appendChild(w.alloc, copy);
    w.save_error_rename = try action(w, banner, "修改名称", "wizard.save.error.rename", 82, 28, false, w.locked, RemoteEditor.onSummaryModify, null);
    w.save_error_copy = try @import("../../ui/copy_button.zig").Button.mount(w.cx, w.scope, .{
        .label = "复制错误详情",
        .variant = .ghost,
        .size = .sm,
        .base_style = S.button(108, 28, false),
        .on_click = w.cx.on(RemoteEditor, w, RemoteEditor.onSaveErrorCopy),
    });
    w.save_error_copy.?.node.meta.ownership.meta.test_id = "wizard.save.error.copy";
    try banner.appendChild(w.alloc, w.save_error_copy.?.node);
    banner.setDisplay(.none);
    return banner;
}

fn paintInputTypography(node: *ui.Node) void {
    if (node.getText()) |old| {
        if (old.font_size != 11 or old.line_height != 16.0 / 11.0) {
            var props = old;
            props.font_size = 11;
            props.line_height = 16.0 / 11.0;
            node.setText(props);
        }
    }
}

fn paintPanelControl(node: *ui.Node) void {
    // Select publishes its disabled state on the trigger's wrapper. Textarea
    // publishes it on the field itself.
    const parent = node.parent orelse node;
    const attrs = node.behavior.interaction.a11y orelse parent.behavior.interaction.a11y;
    const disabled = if (attrs) |value| value.disabled else false;
    const fill = if (disabled) S.theme.states().disabled else S.theme.current().overlay;
    if (ui.Color.eql(node.getBackground(), fill)) return;
    node.setBackgroundRaw(fill);
    node.markRenderDirty();
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

fn paintSelectContent(node: *ui.Node, color: ui.Color) void {
    if (node.getText()) |text| {
        if (!std.meta.eql(text.color, color)) node.setTextColor(color);
    }
    for (node.children.items) |child| paintSelectContent(child, color);
}

// Read the Select's public derived state; keep its controlled event/selection
// pipeline intact while the host supplies the live V3 surface roles.
fn paintSelectMenu(select: ui.widgets.SelectResult) void {
    const colors = S.theme.current();
    const state = ui.widgets.select.stateOf(select);
    select.trigger.setBorderColor(ui.Color.TRANSPARENT);
    _ = select.chevron_down.setTint(colors.fg_2);
    _ = select.chevron_up.setTint(colors.fg_2);
    for (state.option_nodes, 0..) |row, i| {
        const sized = switch (row.style.height) {
            .px => |height| height == 32,
            else => false,
        };
        if (!sized) row.setStyleInline(state.allocator, .{ .height = .{ .px = 32 }, .padding = .{ .top = 7, .bottom = 7, .left = 9, .right = 9 }, .border = .{ .radius = 7 }, .flex_shrink = 0 });
        const selected = state.isSelected(i);
        const highlighted = if (state.highlighted_index) |index| index == i else state.shown_open and selected;
        row.setBackground(if (highlighted) colors.hover else if (selected) colors.selection else ui.Color.TRANSPARENT);
        paintSelectContent(row, if (state.options[i].disabled) colors.fg_3 else if (selected) colors.accent_ink else colors.fg_1);
        _ = state.check_nodes[i].setTint(colors.accent_ink);
    }
}

fn skinIdentityRadios(w: *RemoteEditor, group: *ui.Node) void {
    group.setStyleInline(w.alloc, .{ .width = .fill(), .min_width = 0, .height = .{ .px = 34 }, .align_items = .center, .gap = 8 });
    for (group.children.items) |choice| {
        if (choice.children.items.len < 2) continue;
        choice.setStyleInline(w.alloc, .{ .height = .{ .px = 34 }, .gap = 7, .padding = .{ .left = 10, .right = 10 }, .border = .{ .radius = 8 } });
        const circle = choice.children.items[0];
        circle.setStyleInline(w.alloc, .{ .width = .{ .px = 12 }, .height = .{ .px = 12 }, .corner_radii = .{ .all = 6 } });
        if (circle.children.items.len != 0) circle.children.items[0].setStyleInline(w.alloc, .{ .width = .{ .px = 5 }, .height = .{ .px = 5 }, .corner_radii = .{ .all = 2.5 } });
    }
    paintAuthLabels(group);
}

fn paintAuthLabels(group: *ui.Node) void {
    for (group.children.items) |choice| {
        if (choice.children.items.len < 2) continue;
        const attrs = choice.behavior.interaction.a11y;
        const selected = if (attrs) |access| access.checked orelse false else false;
        const disabled = if (attrs) |access| access.disabled else false;
        const colors = S.theme.current();
        choice.setBackground(if (selected) S.theme.popupSelection() else ui.Color.TRANSPARENT);
        const node = choice.children.items[1];
        if (node.getText()) |old| {
            const ink = if (disabled) colors.fg_3 else if (selected) colors.accent_ink else colors.fg_2;
            if (old.font_size == 12 and old.line_height == 1.5 and !old.selectable and ui.Color.eql(old.color, ink)) continue;
            var props = old;
            props.font_size = 12;
            props.line_height = 1.5;
            props.selectable = false;
            props.color = ink;
            node.setText(props);
        }
    }
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

// Input and Select retain their native event handlers; only the outer field
// paints the compound control, including focus on the arrow or its open menu.
const GroupControlChrome = struct {
    input: ui.widgets.input.InputResult,
    select: ui.widgets.SelectResult,

    fn paint(node: *ui.Node) void {
        const self: *GroupControlChrome = @ptrCast(@alignCast(node.behavior.events.event_context.?));
        var focused = self.input.state.focused or self.select.open.?.peek();
        if (self.input.state.cx_ref) |cx| {
            var ancestor = cx.focused_node;
            while (ancestor) |current| : (ancestor = current.parent) {
                if (current == node) {
                    focused = true;
                    break;
                }
            }
        }
        node.setBackground(if (self.input.state.disabled) S.theme.states().disabled else if (focused) S.theme.states().focus else S.groupControl().background.?);
    }
};

fn clearGroupInnerChrome(node: *ui.Node) void {
    node.setBackground(ui.Color.TRANSPARENT);
    node.setBorderWidth(0);
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
    // HTML preview: 5px panel inset, contiguous 32px rows, radius10/7.
    result.chrome.setStyleInline(w.alloc, .{ .padding = ui.Padding.all(5), .gap = 0, .background = S.theme.current().overlay, .border = .{ .radius = 10, .width = 0 } });
    result.panel.setStyleInline(w.alloc, .{ .gap = 0 });
    const state = ui.widgets.select.stateOf(result);
    for (state.option_nodes) |row| row.setStyleInline(w.alloc, .{ .height = .{ .px = 32 }, .padding = .{ .top = 7, .bottom = 7, .left = 9, .right = 9 }, .border = .{ .radius = 7 }, .flex_shrink = 0 });
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

test "password reveal stays masked until fresh authorization and hides on lifecycle changes" {
    const a = std.testing.allocator;
    const cx = try ui.Cx.init(a, std.testing.io);
    defer cx.deinit();
    const scope = try ui.Scope.init(a, null, cx.owner);
    defer scope.dispose();
    const root = try ui.box(cx, .{}, .{});
    cx.root = root;
    cx.window_active = true;
    var editor: RemoteEditor = .{};
    try root.appendChild(a, try editor.mount(cx, scope));
    editor.loadDraft(.{ .name = "fixture", .host = "fixture.invalid", .user = "fixture", .password = "owned-fixture-password" });
    editor.show();
    editor.onPasswordReveal();
    try std.testing.expect(editor.password_authorization.active);
    try std.testing.expectEqual(ui.widgets.input.InputType.password, editor.password_input.?.state.input_type);
    editor.password_authorization.test_result = .cancelled;
    editor.pollPasswordVisibility();
    try std.testing.expect(!editor.password_visible);
    editor.onPasswordReveal();
    editor.password_authorization.test_result = .failed;
    editor.pollPasswordVisibility();
    try std.testing.expect(!editor.password_visible);
    try std.testing.expect(editor.password_reveal_error.?.style.display != .none);
    editor.onPasswordReveal();
    editor.password_authorization.test_result = .approved;
    editor.pollPasswordVisibility();
    try std.testing.expect(editor.password_visible);
    try std.testing.expectEqual(ui.widgets.input.InputType.text, editor.password_input.?.state.input_type);
    editor.onPasswordReveal();
    try std.testing.expectEqual(ui.widgets.input.InputType.password, editor.password_input.?.state.input_type);
    try std.testing.expect(editor.password_input.?.input_container.behavior.interaction.a11y.?.value_text == null);
    editor.onPasswordReveal();
    editor.password_authorization.test_result = .approved;
    editor.hide();
    try std.testing.expect(!editor.password_visible and !editor.password_authorization.active);
    editor.show();
    editor.onPasswordReveal();
    try std.testing.expectEqual(@import("../../platform/password_reveal.zig").Result.pending, editor.password_authorization.result());
    editor.password_authorization.test_result = .approved;
    editor.pollPasswordVisibility();
    cx.window_active = false;
    editor.pollPasswordVisibility();
    try std.testing.expect(!editor.password_visible);
    cx.window_active = true;
    editor.onPasswordReveal();
    editor.password_authorization.test_result = .approved;
    editor.pollPasswordVisibility();
    editor.password_visible_until = 0;
    editor.pollPasswordVisibility();
    try std.testing.expect(!editor.password_visible);
    editor.onPasswordReveal();
    cx.window_active = false;
    editor.password_authorization.test_result = .approved;
    editor.pollPasswordVisibility();
    try std.testing.expect(!editor.password_visible and editor.password_authorization.active);
    editor.password_approval_deadline = -1;
    editor.pollPasswordVisibility();
    try std.testing.expect(!editor.password_visible and !editor.password_authorization.active);
    cx.window_active = true;
    editor.onPasswordReveal();
    editor.loadDraft(.{ .name = "next", .host = "next.invalid", .user = "fixture" });
    try std.testing.expect(!editor.password_authorization.active and !editor.password_visible);
}

test "authentication radio labels cannot create a text selection highlight" {
    const cx = try ui.Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    const scope = try ui.Scope.init(std.testing.allocator, null, cx.owner);
    defer scope.dispose();
    const selected = try scope.createSignal(?[]const u8, "password");
    const group = try ui.widgets.RadioGroup(.{ .options = &auth_options, .value = selected, .horizontal = true }).mount(scope, cx);
    cx.root = group;
    paintAuthLabels(group);
    for (group.children.items) |choice| {
        const label = choice.children.items[1];
        try std.testing.expect(!label.getText().?.selectable);
    }
    selected.set("private_key");
    paintAuthLabels(group);
    for (group.children.items) |choice| try std.testing.expect(!choice.children.items[1].getText().?.selectable);
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
        apply(self.wizard, self.index, self.kind);
    }
    fn apply(w: *RemoteEditor, i: usize, kind: EditorKind) void {
        if (w.isLocked()) return;
        var exit_name: ?[]const u8 = null;
        if (w.sig_socks_exit.?.get()) |text| {
            const exit_index = std.fmt.parseInt(usize, text, 10) catch w.jump_count;
            if (exit_index < w.jump_count) if (w.jump_values[exit_index].?.get()) |name| {
                exit_name = w.alloc.dupe(u8, name) catch return;
            };
        }
        defer if (exit_name) |name| w.alloc.free(name);
        switch (kind) {
            .jump_up, .jump_down => {
                if (i >= w.jump_count) return;
                const other = if (kind == .jump_up) (if (i == 0) return else i - 1) else (if (i + 1 >= w.jump_count) return else i + 1);
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
    var action_style = S.button(28, 28, false);
    action_style.background = ui.Color.TRANSPARENT;
    const node = try ui.widgets.Button(.{ .variant = .ghost, .a11y_label = label, .disabled = state.disabled, .base_style = action_style, .on_click = cx.on(EditorAction, state, EditorAction.click) }).mount(self.scope, cx);
    node.setStyleInline(self.alloc, action_style);
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
    try std.testing.expectEqualStrings(source[0].key_passphrase.?, copy.key_passphrase.?);
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
    var edit_action: EditorAction = .{ .wizard = &wizard, .index = 0, .kind = .jump_down, .disabled = try scope.createSignal(bool, false) };
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

test "host scrollback inherits global until explicitly edited and clearing restores inheritance" {
    const a = std.testing.allocator;
    const cx = try ui.Cx.init(a, std.testing.io);
    defer cx.deinit();
    const scope = try ui.Scope.init(a, null, cx.owner);
    defer scope.dispose();
    cx.root = try ui.box(cx, .{}, .{});
    var editor: RemoteEditor = .{};
    try cx.root.?.appendChild(a, try editor.mount(cx, scope));
    editor.setScrollbackDefault(70000);
    editor.loadDraft(.{ .name = "n", .host = "h", .user = "u" });
    try std.testing.expectEqualStrings("", editor.sig_scrollback.?.get());
    try std.testing.expectEqualStrings("继承全局：70000 行", editor.sig_scrollback_hint.?.get());
    editor.setScrollbackDefault(12000);
    try std.testing.expectEqualStrings("继承全局：12000 行", editor.sig_scrollback_hint.?.get());
    try std.testing.expectEqualStrings("", editor.sig_scrollback.?.get());
    var host = try editor.currentDraft().toHostConfig();
    try std.testing.expect(!host.scrollback_explicit);
    try std.testing.expect(@import("../../ui/session_runtime.zig").targetFromHost(host, &.{}).scrollback == null);
    editor.sig_scrollback.?.set("0");
    editor.onScrollbackChanged("0");
    editor.setScrollbackDefault(0);
    try std.testing.expectEqualStrings("继承全局：0（不限制）", editor.sig_scrollback_hint.?.get());
    try std.testing.expectEqualStrings("0", editor.sig_scrollback.?.get());
    host = try editor.currentDraft().toHostConfig();
    try std.testing.expect(host.scrollback_explicit);
    try std.testing.expectEqual(@as(?u32, 0), @import("../../ui/session_runtime.zig").targetFromHost(host, &.{}).scrollback);
    editor.sig_scrollback.?.set("");
    editor.onScrollbackChanged("");
    host = try editor.currentDraft().toHostConfig();
    try std.testing.expect(!host.scrollback_explicit);
    var writer: std.Io.Writer.Allocating = .init(a);
    defer writer.deinit();
    try @import("../../config/hosts.zig").Registry.formatOne(host, &writer.writer);
    try std.testing.expect(std.mem.indexOf(u8, writer.written(), "scrollback =") == null);
}

test "hidden maintenance RemoteEditor respects hidden ancestors and resumes on reopen" {
    const cx = try ui.Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    const parent = try ui.box(cx, .{}, .{});
    cx.root = parent;
    const child = try ui.box(cx, .{}, .{});
    try parent.appendChild(cx.allocator, child);
    var editor: RemoteEditor = undefined;
    editor.root = child;
    try std.testing.expect(editor.isVisible());
    parent.setDisplay(.none);
    try std.testing.expect(!editor.isVisible());
    parent.setDisplay(.flex);
    try std.testing.expect(editor.isVisible());
    child.setDisplay(.none);
    try std.testing.expect(!editor.isVisible());
}
