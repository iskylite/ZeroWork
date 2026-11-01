//! Renderer-only projection and persistent Boot draft. No protocol or runtime
//! access: capabilities and evidence come solely from owned service snapshots.
const std = @import("std");
const services = @import("services.zig");
const console = @import("console_service.zig");

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
        if (self.dirty() and snapshot.capability.revision != self.capability_revision) self.conflict = true;
        self.capability_revision = snapshot.capability.revision;
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
        if (snapshot.write_uri == null or !snapshot.allowed_enabled.evidence.permitsWrite()) return false;
        const value = self.value.state();
        const enabled = value.enabled orelse return false;
        if (!services.contains(snapshot.allowed_enabled.value orelse &.{}, enabled)) return false;
        if (self.disabled()) return snapshot.enabled_evidence.permitsWrite();
        return snapshot.target_evidence.permitsWrite() and snapshot.allowed_targets.evidence.permitsWrite() and services.contains(snapshot.allowed_targets.value orelse &.{}, value.target orelse return false);
    }
};

pub fn writeAllowed(capability: services.Capability) bool {
    return capability.write_granted and capability.system_mapping_verified and capability.secondary_auth != .unknown and capability.secondary_auth_evidence.permitsWrite();
}
pub fn powerAllowed(snapshot: services.PowerSnapshot, action: services.PowerAction) bool {
    if (!writeAllowed(snapshot.capability) or snapshot.reset_target == null or !snapshot.reset_types.evidence.permitsWrite() or !snapshot.state.evidence.permitsWrite()) return false;
    if (!services.contains(snapshot.reset_types.value orelse &.{}, action.redfish())) return false;
    const state = snapshot.state.value orelse return false;
    return switch (action) {
        .on => state == .off,
        else => state == .on,
    };
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
pub const ProgressProjection = struct {
    seen: u8 = 0,
    warnings: u8 = 0,
    last_group: ?ProgressGroup = null,
    cancelled: bool = false,

    pub fn observe(self: *ProgressProjection, snapshot: console.progress.Snapshot) void {
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

/// Only schema-owned labels, numeric diagnostics and static error names cross
/// this formatter. It never receives response bodies, headers or credentials.
pub fn writeConnectionLog(writer: *std.Io.Writer, snapshot: console.progress.Snapshot) !void {
    if (snapshot.event_count == 0) {
        try writer.writeAll("本会话尚未产生连接事件。");
        return;
    }
    for (snapshot.events[0..@min(snapshot.event_count, snapshot.events.len)], 0..) |event, index| {
        if (index != 0) try writer.writeByte('\n');
        try writer.print("+{d}.{d}s  {s}", .{ event.at_ms / 1000, (event.at_ms % 1000) / 100, console.progress.stageLabel(event.stage) });
        if (event.kind == .failure) try writer.writeAll(" · 失败");
        if (event.code != .none) try writer.print(" · {s}", .{console.progress.codeLabel(event.code)});
        if (event.resource != .none) try writer.print(" · {s}", .{console.progress.resourceLabel(event.resource)});
        if (event.http_status) |status| try writer.print(" · HTTP {d}", .{status});
        if (event.count) |count| try writer.print(" · {d} 项", .{count});
        if (event.validity) |validity| try writer.print(" · {s}", .{switch (validity) {
            .valid => "有效",
            .partial_with_error => "部分结果",
            .unavailable => "不可用",
        }});
        if (event.error_code) |error_code| try writer.print(" · {s}", .{error_code});
    }
}
