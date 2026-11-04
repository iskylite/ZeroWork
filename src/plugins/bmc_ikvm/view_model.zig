//! Renderer projection and persistent Boot draft. Pure protocol field checks
//! share the executor's rules; no network or runtime access occurs here.
const std = @import("std");
const services = @import("services.zig");
const console = @import("console_service.zig");
const boot_fields = @import("protocol/boot.zig");
const power_fields = @import("protocol/power.zig");

pub const Menu = enum { control, keys, display, power, boot };
pub const Text = struct {
    bytes: [256]u8 = @splat(0),
    len: ?u16 = null,
    pub fn set(self: *Text, value: ?[]const u8) !void {
        if (value) |v| {
            if (v.len > self.bytes.len) return error.FieldTooLong;
            @memcpy(self.bytes[0..v.len], v);
            self.len = @intCast(v.len);
        } else self.len = null;
    }
    pub fn get(self: *const Text) ?[]const u8 {
        return if (self.len) |len| self.bytes[0..len] else null;
    }
    pub fn equal(self: *const Text, value: ?[]const u8) bool {
        return services.optionalEqual(self.get(), value);
    }
};
pub const BootValues = struct {
    enabled: Text = .{},
    target: Text = .{},
    mode: Text = .{},
    pub fn set(self: *BootValues, value: services.BootState) !void {
        try self.enabled.set(value.enabled);
        try self.target.set(value.target);
        try self.mode.set(value.mode);
    }
    pub fn state(self: *const BootValues) services.BootState {
        return .{ .enabled = self.enabled.get(), .target = self.target.get(), .mode = self.mode.get() };
    }
};
pub const BootDraft = struct {
    initialized: bool = false,
    baseline: BootValues = .{},
    value: BootValues = .{},
    remembered_enabled: Text = .{},
    capability_revision: u64 = 0,
    grant_revision: u64 = 0,
    binding_generation: u64 = 0,
    conflict: bool = false,

    pub fn refresh(self: *BootDraft, snapshot: services.BootSnapshot) !void {
        if (!self.initialized or snapshot.capability.binding_generation != self.binding_generation) {
            const had_draft = self.initialized and self.dirty();
            try self.baseline.set(snapshot.state);
            try self.value.set(snapshot.state);
            try self.remembered_enabled.set(if (services.optionalEqual(snapshot.state.enabled, "Continuous")) "Continuous" else "Once");
            self.initialized = true;
            self.binding_generation = snapshot.capability.binding_generation;
            self.capability_revision = snapshot.capability.revision;
            self.grant_revision = snapshot.capability.grant_revision;
            self.conflict = had_draft;
            return;
        }
        const old = self.baseline.state();
        const current = self.value.state();
        inline for (.{ "enabled", "target", "mode" }) |field| {
            const modified = !services.optionalEqual(@field(current, field), @field(old, field));
            if (modified) {
                if (!services.optionalEqual(@field(old, field), @field(snapshot.state, field))) self.conflict = true;
            } else try @field(self.value, field).set(@field(snapshot.state, field));
            try @field(self.baseline, field).set(@field(snapshot.state, field));
        }
        if (self.dirty() and (snapshot.capability.revision != self.capability_revision or snapshot.capability.grant_revision != self.grant_revision)) self.conflict = true;
        self.capability_revision = snapshot.capability.revision;
        self.grant_revision = snapshot.capability.grant_revision;
    }
    pub fn dirty(self: *const BootDraft) bool {
        if (!self.initialized) return false;
        if (self.disabled()) return !self.baseline.enabled.equal("Disabled");
        return !services.sameBoot(self.baseline.state(), self.value.state());
    }
    pub fn disabled(self: *const BootDraft) bool {
        return self.value.enabled.equal("Disabled");
    }
    pub fn continuous(self: *const BootDraft) bool {
        return self.value.enabled.equal("Continuous");
    }
    pub fn selectTarget(self: *BootDraft, value: []const u8) !void {
        if (std.mem.eql(u8, value, "Disabled")) {
            if (!self.disabled()) try self.remembered_enabled.set(self.value.enabled.get());
            try self.value.enabled.set("Disabled");
        } else {
            try self.value.target.set(value);
            if (self.disabled()) try self.value.enabled.set(self.remembered_enabled.get() orelse "Once");
        }
    }
    pub fn setContinuous(self: *BootDraft, on: bool) !void {
        if (self.disabled()) return;
        try self.value.enabled.set(if (on) "Continuous" else "Once");
        try self.remembered_enabled.set(self.value.enabled.get());
    }
    pub fn selectMode(self: *BootDraft, mode: []const u8) !void {
        try self.value.mode.set(mode);
    }
    pub fn canApply(self: *const BootDraft, snapshot: services.BootSnapshot) bool {
        if (!self.dirty() or self.conflict or !writeAllowed(snapshot.capability)) return false;
        if (snapshot.write_uri == null) return false;
        boot_fields.validateFields(snapshot, self.baseline.state(), self.changed(), snapshot.etag) catch return false;
        return true;
    }
    pub fn changed(self: *const BootDraft) services.BootState {
        const value = self.value.state();
        if (self.disabled()) return .{ .enabled = if (self.baseline.enabled.equal("Disabled")) null else "Disabled" };
        return .{
            .enabled = if (self.baseline.enabled.equal(value.enabled)) null else value.enabled,
            .target = if (self.baseline.target.equal(value.target)) null else value.target,
            .mode = if (self.baseline.mode.equal(value.mode)) null else value.mode,
        };
    }
    pub fn unavailableReason(self: *const BootDraft, snapshot: services.BootSnapshot) ?[]const u8 {
        if (!writeAllowed(snapshot.capability)) return "当前仅查看管理状态；执行需要本次操作的授权。";
        if (self.conflict) return "设备或能力已变化，请重新审查草稿。";
        if (!self.dirty()) return null;
        if (snapshot.write_uri == null) return "启动设置的写入目标尚未确认。";
        boot_fields.validateFields(snapshot, self.baseline.state(), self.changed(), snapshot.etag) catch |err| return switch (err) {
            error.StaleBaseline => "本次更改涉及的启动状态已变化，请重新审查草稿。",
            error.InvalidBootCombination => "当前启动覆盖与启动设备组合无效。",
            error.MissingBootBaseline => "本次更改缺少所需的当前启动字段。",
            error.UnchangedBoot => null,
            else => "本次更改涉及的启动字段或允许值不可用。",
        };
        return null;
    }
};

pub fn writeAllowed(capability: services.Capability) bool {
    return (capability.write_granted or capability.write_requestable) and capability.system_mapping_verified and capability.secondary_auth != .unknown and capability.secondary_auth_evidence.permitsWrite();
}
pub fn resultLabel(result: services.Result) []const u8 {
    return switch (result.phase) {
        .awaiting_approval => "等待批准本次操作；尚未发送。",
        .awaiting_auth => "等待二次认证；尚未发送。",
        .queued => "本次操作已批准，正在排队。",
        .refreshing => "正在重新读取设备状态与写入条件。",
        .sending => "正在发送本次操作，请等待结果。",
        .accepted_remote, .tracking_task => "设备已接受，正在跟踪远端任务。",
        .verifying => "正在回读设备状态。",
        .succeeded => "回读已确认本次更改。",
        .cancelled_unsent => "已取消，本次请求未发送。",
        .outcome_unknown => if (result.reason == .pending) "更改已进入待生效设置，当前值尚未生效；可查询结果。" else if (result.reason == .accepted_unverified) "设备当前开机；此状态不能确认重启完成，仅可查询。" else "操作结果未知，仅可查询；不会自动重发。",
        .failed => reasonLabel(result.reason orelse .remote_error),
    };
}
pub fn reasonLabel(reason: services.Reason) []const u8 {
    return switch (reason) {
        .permission_denied => "当前会话或设备权限不允许此操作。",
        .stale_binding => "会话已变化，请重新打开管理工具。",
        .stale_capability, .stale_baseline, .conflict => "设备状态或能力已变化，请重新审查草稿。",
        .mapping_unverified => "尚未确认管理目标或系统信息的来源，仅供查看。",
        .secondary_auth_unknown => "二次认证要求尚未核实，暂不能执行。",
        .secondary_auth_required => "设备要求二次认证，当前未取得本次操作的验证材料。",
        .unsupported, .invalid_request => "设备不支持当前操作或设置。",
        .busy => "已有管理操作正在处理或结果未知。",
        .authentication_failed => "管理认证已失效，请重新连接。",
        .unavailable => "管理通道当前不可用。",
        .journal_failed => "操作记录无法保存，本次操作已停止。",
        .cancelled => "本次操作已取消。",
        .timeout => "等待设备结果超时。",
        .transport_lost => "管理连接已中断。",
        .verification_mismatch => "回读值与本次更改不一致。",
        .pending => "更改处于待生效状态。",
        .accepted_unverified => "设备已接受，执行结果尚未确认。",
        .remote_error => "设备拒绝了请求或返回了无法确认的结果。",
    };
}
pub fn powerAllowed(snapshot: services.PowerSnapshot, action: services.PowerAction) bool {
    if (!writeAllowed(snapshot.capability)) return false;
    power_fields.validatePowerFields(snapshot, action) catch return false;
    return true;
}
pub fn powerUnavailableReason(snapshot: services.PowerSnapshot, action: services.PowerAction) ?[]const u8 {
    if (!writeAllowed(snapshot.capability)) return "当前仅查看管理状态；执行需要本次操作的授权。";
    if (!snapshot.state.evidence.permitsWrite() or snapshot.state.value == null or snapshot.state.value == .unknown) return "本次电源操作所需的电源状态不可用。";
    if (snapshot.reset_target == null) return "电源动作的目标尚未确认。";
    if (!snapshot.reset_types.evidence.permitsWrite()) return "电源动作的允许值读取异常，暂不能执行此操作。";
    power_fields.validatePowerFields(snapshot, action) catch |err| return if (err == error.ActionNotApplicable) "当前电源状态不适用此操作。" else "设备未声明支持此电源操作。";
    return null;
}
pub fn powerLabel(action: services.PowerAction) []const u8 {
    return switch (action) {
        .on => "开机",
        .graceful_shutdown => "正常关机",
        .graceful_restart => "正常重启",
        .force_off => "强制断电",
        .force_restart => "强制重启",
        .power_cycle => "断电后开机",
    };
}
pub fn powerStateLabel(state: ?services.PowerState) []const u8 {
    return switch (state orelse .unknown) {
        .on => "开机",
        .off => "关机",
        .powering_on => "正在开机",
        .powering_off => "正在关机",
        .unknown => "未知",
    };
}
pub fn statusTitle(snapshot: console.Snapshot, has_texture: bool) []const u8 {
    if (snapshot.cleanup == .unknown) return "连接清理结果待确认";
    if (snapshot.cleanup == .awaiting) return "正在释放连接";
    if (snapshot.progress.failure_code != null) return if (has_texture) "视频已中断 · 画面已停止更新" else "连接失败";
    if (snapshot.progress.stage == .cancelled) return "连接已取消";
    if (snapshot.route == .closed) return "连接已结束";
    if (snapshot.route == .failed or snapshot.video == .failed) return if (has_texture) "视频已中断 · 画面已停止更新" else "连接失败";
    if (snapshot.cleanup == .released) return "连接已结束";
    if (snapshot.progress.revision != 0 and snapshot.video != .streaming) return console.progress.stageLabel(snapshot.progress.stage);
    return switch (snapshot.video) {
        .streaming => if (has_texture) "" else "正在准备画面",
        .authenticating => "正在验证视频会话",
        .negotiating => "正在协商视频通道",
        .awaiting_frame => "正在等待视频帧",
        else => if (snapshot.route == .connecting) "正在建立独立连接" else "正在准备连接",
    };
}

/// A compact, evidence-based projection. A stage event proves only that work
/// began: optional branches remain waiting unless the session actually visits
/// them. Retain observed groups while the bounded event ring rotates.
pub const ProgressGroup = enum { route, tls, identity, authentication, management, video };
pub const progress_group_count = @typeInfo(ProgressGroup).@"enum".field_names.len;
pub const StepState = enum { waiting, current, waiting_for_user, done, warning, failed, stopped };
/// A failure opens its own step once. Later timer snapshots must respect a
/// user's choice to collapse it, including after cleanup and ring rollover.
pub const ProgressDisclosure = struct {
    open: u8 = 0,
    auto_opened: u8 = 0,

    pub fn observe(self: *ProgressDisclosure, snapshot: console.progress.Snapshot) void {
        var failures: u8 = 0;
        if (snapshot.failure_stage) |stage| if (progressGroup(stage)) |group| {
            failures |= groupBit(group);
        };
        for (snapshot.events[0..@min(snapshot.event_count, snapshot.events.len)]) |event| {
            if (event.kind != .failure and event.error_code == null) continue;
            if (progressGroup(event.stage)) |group| failures |= groupBit(group);
        }
        self.open |= failures & ~self.auto_opened;
        self.auto_opened |= failures;
    }
    pub fn isOpen(self: *const ProgressDisclosure, group: ProgressGroup) bool {
        return self.open & groupBit(group) != 0;
    }
    pub fn toggle(self: *ProgressDisclosure, group: ProgressGroup) void {
        self.open ^= groupBit(group);
    }
};
pub const ProgressProjection = struct {
    seen: u8 = 0,
    warnings: u8 = 0,
    last_group: ?ProgressGroup = null,
    cancelled: bool = false,

    pub fn observe(self: *ProgressProjection, snapshot: console.progress.Snapshot) void {
        if (snapshot.discovery_issue != null) self.warnings |= groupBit(.management);
        inline for (@typeInfo(console.progress.Stage).@"enum".field_names) |field| {
            const stage = @field(console.progress.Stage, field);
            if (snapshot.completed_stage_ms[@intCast(@backingInt(stage))] != null) {
                if (progressGroup(stage)) |group| self.seen |= groupBit(group);
            }
        }
        for (snapshot.events[0..@min(snapshot.event_count, snapshot.events.len)]) |event| {
            if (event.stage == .cancelled) self.cancelled = true;
            const code_name = @tagName(event.code);
            if ((std.mem.startsWith(u8, code_name, "mapping_") and event.code != .mapping_verified) or
                (std.mem.startsWith(u8, code_name, "readonly_") and event.code != .readonly_projection_available)) self.warnings |= groupBit(.management);
            const group = progressGroup(event.stage) orelse continue;
            if (event.kind == .stage) {
                self.seen |= groupBit(group);
                self.last_group = group;
            }
            if (event.error_code != null or (if (event.validity) |validity| validity != .valid else false)) self.warnings |= groupBit(group);
        }
        if (progressGroup(snapshot.stage)) |group| {
            self.seen |= groupBit(group);
            self.last_group = group;
        }
        if (snapshot.stage == .cancelled) self.cancelled = true;
    }

    pub fn state(self: *const ProgressProjection, snapshot: console.progress.Snapshot, group: ProgressGroup) StepState {
        if (snapshot.failure_stage) |stage| if (progressGroup(stage) == group) return .failed;
        if (self.cancelled and self.last_group == group) return .stopped;
        if (progressGroup(snapshot.stage) == group and snapshot.stage != .streaming) return if (snapshot.waiting_for_user) .waiting_for_user else .current;
        if (self.warnings & groupBit(group) != 0) return .warning;
        return if (self.seen & groupBit(group) != 0) .done else .waiting;
    }
};

fn groupBit(group: ProgressGroup) u8 {
    return @as(u8, 1) << @intCast(@backingInt(group));
}

pub fn progressGroup(stage: console.progress.Stage) ?ProgressGroup {
    return switch (stage) {
        .route => .route,
        .tls_handshake, .waiting_certificate => .tls,
        .public_identity, .public_script => .identity,
        .waiting_credentials, .web_login, .firmware_confirmation => .authentication,
        .redfish_discovery => .management,
        .oem_session, .video_tls_handshake, .waiting_video_certificate, .websocket_upgrade, .rfb_negotiation, .awaiting_first_frame, .streaming => .video,
        .idle, .cleanup, .released, .cancelled, .failed => null,
    };
}

/// Sum protocol-stage visits for a displayed step, including human waits.
/// Completed timings survive event-ring eviction; cleanup and streaming do not
/// increase a finished connection step.
pub fn progressGroupDuration(snapshot: console.progress.Snapshot, group: ProgressGroup) ?u64 {
    if (snapshot.revision == 0) return null;
    var duration: ?u64 = null;
    inline for (@typeInfo(console.progress.Stage).@"enum".field_names) |field| {
        const stage = @field(console.progress.Stage, field);
        if (stage != .streaming and progressGroup(stage) == group) {
            const completed = snapshot.completed_stage_ms[@intCast(@backingInt(stage))];
            if (completed) |ms| duration = (duration orelse 0) +| ms;
            if (snapshot.stage == stage) duration = (duration orelse 0) +| snapshot.stage_elapsed_ms;
        }
    }
    return duration;
}

pub fn progressGroupLabel(group: ProgressGroup) []const u8 {
    return switch (group) {
        .route => "独立连接路由",
        .tls => "目标 TLS 与证书",
        .identity => "公开设备信息",
        .authentication => "管理认证与固件确认",
        .management => "管理资源发现",
        .video => "视频会话与首帧",
    };
}

pub fn stepPrefix(state: StepState) []const u8 {
    return switch (state) {
        .waiting => "○",
        .current => "◌",
        .waiting_for_user => "◷",
        .done => "✓",
        .warning => "!",
        .failed => "×",
        .stopped => "–",
    };
}

pub fn stepLabel(state: StepState) []const u8 {
    return switch (state) {
        .waiting => "等待",
        .current => "进行中",
        .waiting_for_user => "等待用户",
        .done => "已完成",
        .warning => "部分结果",
        .failed => "失败",
        .stopped => "已停止",
    };
}

pub fn failureReason(code: ?[]const u8, stage: ?console.progress.Stage) []const u8 {
    const value = code orelse return "该阶段未完成，连接已停止。";
    if (std.mem.eql(u8, value, "Cancelled")) return "本次连接已取消，目标与路由配置已保留。";
    if (std.mem.indexOf(u8, value, "Timeout") != null) return "当前阶段等待超时，未能继续连接。";
    if (std.mem.eql(u8, value, "SshHandshakeReceiveFailed")) return "SSH 握手失败，未能完成当前连接链路。";
    if (std.mem.eql(u8, value, "TrustRejected")) return "目标证书未获信任，连接已停止。";
    if (std.mem.indexOf(u8, value, "AuthenticationEvidence") != null) return "当前设备缺少已验证的认证协议信息，无法继续认证。";
    if (std.mem.indexOf(u8, value, "Authentication") != null or std.mem.eql(u8, value, "PermissionDenied")) return "目标认证未成功，请检查当前凭据与访问权限。";
    if (std.mem.eql(u8, value, "SecretDenied") or std.mem.eql(u8, value, "SecretUngranted")) return "未获准读取本次连接所需的凭据。";
    if (std.mem.eql(u8, value, "SecretUnavailable") or std.mem.eql(u8, value, "InvalidCredentialReference")) return "当前连接的凭据不可用。";
    if (std.mem.indexOf(u8, value, "PublicEvidence") != null) return "无法取得可验证的公开设备信息，设备兼容性尚未确认。";
    if (std.mem.indexOf(u8, value, "FirmwareMismatch") != null) return "目标固件与当前支持的设备配置不一致。";
    if (std.mem.indexOf(u8, value, "FirmwareUnavailable") != null) return "目标未返回可验证的固件信息。";
    if (std.mem.indexOf(u8, value, "IdentityAmbiguous") != null) return "设备返回了多个身份，无法确认当前目标。";
    if (std.mem.indexOf(u8, value, "SessionHeaders") != null or std.mem.indexOf(u8, value, "Token") != null) return "目标未返回可验证的会话认证信息。";
    if (std.mem.eql(u8, value, "TlsClosed") or std.mem.eql(u8, value, "VideoClosed")) return "目标关闭了连接，当前阶段未完成。";
    if (stage) |failed| return switch (failed) {
        .route => "独立连接路由未能建立，请查看连接日志中的错误码。",
        .tls_handshake, .waiting_certificate => "目标 TLS 或证书验证未完成。",
        .video_tls_handshake, .waiting_video_certificate => "视频通道 TLS 或证书验证未完成。",
        .web_login, .waiting_credentials => "管理认证未完成，请查看连接日志中的错误码。",
        .oem_session, .websocket_upgrade, .rfb_negotiation, .awaiting_first_frame => "视频会话未能就绪，请查看连接日志中的错误码。",
        else => "该阶段未完成，请查看连接日志中的错误码。",
    };
    return "连接未能继续，请查看连接日志中的错误码。";
}

pub fn writeDuration(writer: *std.Io.Writer, ms: u64) !void {
    try writer.print("{d}.{d} 秒", .{ ms / 1000, (ms % 1000) / 100 });
}

/// Owned resource paths and registry IDs supplement static labels. Response
/// bodies, headers, queries and credentials never reach this formatter.
pub fn writeConnectionLog(writer: *std.Io.Writer, snapshot: console.progress.Snapshot) !void {
    return writeConnectionLogForTarget(writer, snapshot, null);
}
pub fn writeConnectionLogForTarget(writer: *std.Io.Writer, snapshot: console.progress.Snapshot, target: ?[]const u8) !void {
    if (snapshot.event_count == 0) {
        try writer.writeAll("本会话尚未产生连接事件。");
        return;
    }
    for (snapshot.events[0..@min(snapshot.event_count, snapshot.events.len)], 0..) |event, index| {
        if (index != 0) try writer.writeByte('\n');
        try writeProgressEvent(writer, event, target);
    }
    if (retainedFailure(snapshot)) |event| {
        try writer.writeAll("\n保留的原始失败 · ");
        try writeProgressEvent(writer, event, target);
    }
    if (retainedDiscoveryIssue(snapshot)) |event| {
        try writer.writeAll("\n保留的管理资源异常 · ");
        try writeProgressEvent(writer, event, target);
    }
}
fn retainedDiscoveryIssue(snapshot: console.progress.Snapshot) ?console.progress.Event {
    const issue = snapshot.discovery_issue orelse return null;
    for (snapshot.events[0..@min(snapshot.event_count, snapshot.events.len)]) |event| if (event.sequence == issue.sequence) return null;
    return issue;
}

pub fn writeStepDiagnostics(writer: *std.Io.Writer, snapshot: console.progress.Snapshot, group: ProgressGroup) !void {
    return writeStepDiagnosticsForTarget(writer, snapshot, group, null);
}
pub fn writeStepDiagnosticsForTarget(writer: *std.Io.Writer, snapshot: console.progress.Snapshot, group: ProgressGroup, target: ?[]const u8) !void {
    var count: usize = 0;
    if (retainedDiscoveryIssue(snapshot)) |event| if (progressGroup(event.stage) == group) {
        try writer.writeAll("保留的管理资源异常 · ");
        try writeProgressEvent(writer, event, target);
        count += 1;
    };
    var original_failure: ?console.progress.Event = null;
    if (snapshot.failure_stage) |stage| if (progressGroup(stage) == group) {
        if (count != 0) try writer.writeByte('\n');
        try writer.print("{s}\n失败阶段：{s} · {s}", .{ failureReason(snapshot.failure_code, stage), console.progress.stageLabel(stage), snapshot.failure_code orelse "UnknownFailure" });
        original_failure = snapshot.failure_event;
        if (original_failure == null) for (snapshot.events[0..@min(snapshot.event_count, snapshot.events.len)]) |event| {
            if (event.kind == .failure and event.stage == stage) {
                original_failure = event;
                break;
            }
        };
        if (original_failure) |event| {
            try writer.writeByte('\n');
            if (retainedFailure(snapshot) != null) try writer.writeAll("保留的原始失败 · ");
            try writeProgressEvent(writer, event, target);
        }
        count += 1;
    };
    for (snapshot.events[0..@min(snapshot.event_count, snapshot.events.len)]) |event| {
        if (progressGroup(event.stage) != group) continue;
        if (original_failure) |failure| if (event.kind == .failure and event.stage == failure.stage and event.at_ms == failure.at_ms and services.optionalEqual(event.error_code, failure.error_code)) continue;
        if (count != 0) try writer.writeByte('\n');
        try writeProgressEvent(writer, event, target);
        count += 1;
    }
    if (count == 0) try writer.writeAll("该步骤尚无连接事件。");
}

fn retainedFailure(snapshot: console.progress.Snapshot) ?console.progress.Event {
    const failure = snapshot.failure_event orelse return null;
    for (snapshot.events[0..@min(snapshot.event_count, snapshot.events.len)]) |event| {
        if (event.kind == .failure and event.stage == failure.stage and event.at_ms == failure.at_ms and services.optionalEqual(event.error_code, failure.error_code)) return null;
    }
    return failure;
}

pub const log_capacity = console.progress.capacity + 2;
pub const LogEvents = struct {
    events: [log_capacity]console.progress.Event = @splat(.{}),
    count: usize = 0,
};
pub fn connectionLogEvents(snapshot: console.progress.Snapshot) LogEvents {
    var result: LogEvents = .{};
    result.count = @min(snapshot.event_count, snapshot.events.len);
    @memcpy(result.events[0..result.count], snapshot.events[0..result.count]);
    if (retainedFailure(snapshot)) |event| {
        result.events[result.count] = event;
        result.count += 1;
    }
    if (retainedDiscoveryIssue(snapshot)) |event| {
        result.events[result.count] = event;
        result.count += 1;
    }
    return result;
}

pub fn writeLogTimestamp(writer: *std.Io.Writer, event: console.progress.Event) !void {
    const wall_ms = event.at_unix_ms orelse return writer.writeAll("时间未知");
    var buffer: [32]u8 = undefined;
    const formatted = @import("../../proto/ssh/forward_diagnostics.zig").formatTimestamp(&buffer, wall_ms);
    // Zig 0.17 prints an explicit sign for the shared formatter's signed
    // local-time fields. Normalize those numeric fields for clock notation.
    var parts = std.mem.splitAny(u8, formatted, ":.");
    var values: [4]u16 = undefined;
    for (&values) |*value| {
        const part = parts.next() orelse return writer.writeAll("时间未知");
        value.* = std.fmt.parseInt(u16, part, 10) catch return writer.writeAll("时间未知");
    }
    try writer.print("{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}", .{ values[0], values[1], values[2], values[3] });
}
pub fn writeLogDuration(writer: *std.Io.Writer, event: console.progress.Event) !void {
    const duration = event.duration_ms orelse (if (event.context) |context| context.duration_ms else null) orelse return writer.writeAll("—");
    if (duration < 1000) try writer.print("{d} ms", .{duration}) else try writer.print("{d}.{d:0>3} s", .{ duration / 1000, duration % 1000 });
}
pub fn writeLogMessage(writer: *std.Io.Writer, event: console.progress.Event, target: ?[]const u8) !void {
    try writeProgressMessage(writer, event, target, false);
}

fn writeProgressEvent(writer: *std.Io.Writer, event: console.progress.Event, target: ?[]const u8) !void {
    try writer.print("+{d}.{d}s  ", .{ event.at_ms / 1000, (event.at_ms % 1000) / 100 });
    try writeProgressMessage(writer, event, target, true);
}
fn writeProgressMessage(writer: *std.Io.Writer, event: console.progress.Event, target: ?[]const u8, include_duration: bool) !void {
    try writer.writeAll(console.progress.stageLabel(event.stage));
    if (event.kind == .failure) try writer.writeAll(" · 失败");
    if (event.context) |context| {
        try writer.print(" · {s}", .{console.progress.channelLabel(context.channel)});
        if (context.channel == .ssh) {
            if (context.ssh_hop) |hop| if (context.ssh_hops) |hops| try writer.print(" · 跳板 {d}/{d}", .{ hop, hops });
        } else if (target) |endpoint| try writer.print(" → {s}", .{endpoint});
        if (context.method != .none) try writer.print(" · {s} {s}", .{ console.progress.methodLabel(context.method), if (context.resource_path) |*path| path.text() else console.progress.pathLabel(context.path) });
        if (context.source_path) |*source| {
            try writer.print(" · 链接来源：{s}", .{source.text()});
            if (context.source_property) |*property| try writer.print(" 的 {s}", .{property.text()});
        }
        if (context.phase != .none) try writer.print(" · {s}", .{console.progress.phaseLabel(context.phase)});
        if (context.received_bytes) |bytes| try writer.print(" · 已收 {d} B", .{bytes});
        if (include_duration) if (context.duration_ms) |ms| try writer.print(" · 请求 {d}.{d}s", .{ ms / 1000, (ms % 1000) / 100 });
    }
    if (event.code != .none) try writer.print(" · {s}", .{console.progress.codeLabel(event.code)});
    if (event.resource != .none) try writer.print(" · {s}", .{console.progress.resourceLabel(event.resource)});
    if (event.http_status orelse (if (event.context) |context| context.http_status else null)) |status| {
        try writer.print(" · HTTP {d}{s}", .{ status, switch (status) {
            400 => "（请求无效）",
            401 => "（认证失败）",
            403 => "（权限不足）",
            404 => "（资源不存在）",
            405 => "（不支持该请求方法）",
            409 => "（资源冲突）",
            412 => "（前置条件不满足）",
            429 => "（请求过于频繁）",
            500 => "（设备内部错误）",
            502, 503, 504 => "（设备服务暂不可用）",
            else => "",
        } });
    } else if (event.error_code != null) {
        if (event.context) |context| if (context.method != .none) try writer.writeAll(" · HTTP 状态不可用");
    }
    if (event.context) |context| if (context.response_errors) |*errors| {
        try writer.writeAll(if (event.code == .resource_fields_available or event.code == .readonly_projection_available) " · 设备附带诊断/MessageId：" else " · Redfish 错误码/MessageId：");
        var ids = std.mem.splitSequence(u8, errors.text(), ", ");
        var first = true;
        while (ids.next()) |id| {
            if (!first) try writer.writeAll(", ");
            first = false;
            try writer.writeAll(id);
            const key = id[(std.mem.lastIndexOfScalar(u8, id, '.') orelse continue) + 1 ..];
            const reasons = .{
                .{ "InternalError", "设备报告内部错误" },
                .{ "GeneralError", "设备报告一般错误" },
                .{ "ResourceNotFound", "资源不存在" },
                .{ "InsufficientPrivilege", "当前账号权限不足" },
                .{ "NoValidSession", "认证会话无效" },
                .{ "ResourceInUse", "资源正被占用" },
                .{ "PropertyValueError", "属性值错误" },
                .{ "PropertyValueTypeError", "属性值类型错误" },
                .{ "PropertyValueNotInList", "属性值不在设备允许范围内" },
                .{ "ActionNotSupported", "设备不支持该动作" },
                .{ "PreconditionFailed", "前置条件不满足" },
            };
            inline for (reasons) |reason| {
                if (std.mem.eql(u8, key, reason[0])) try writer.print("（{s}）", .{reason[1]});
            }
        }
    };
    if (event.count) |count| try writer.print(" · {d} 项", .{count});
    if (event.validity) |validity| try writer.print(" · {s}", .{switch (validity) {
        .valid => "有效",
        .partial_with_error => "部分结果",
        .unavailable => "不可用",
    }});
    if (event.error_code) |error_code| try writer.print(" · {s}", .{error_code});
}
