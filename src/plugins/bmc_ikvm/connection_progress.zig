//! Bounded, memory-only connection telemetry. Writers accept only enums,
//! numeric metadata and Zig error values: never device text, URLs or secrets.
//! Each attempt owns one heap-stable Tracker; snapshots are copied under its
//! lock and contain no pointers into network/parser/worker-owned buffers.
const std = @import("std");

pub const capacity = 32;
pub const Stage = enum {
    idle,
    route,
    tls_handshake,
    waiting_certificate,
    public_identity,
    public_script,
    waiting_credentials,
    web_login,
    firmware_confirmation,
    redfish_discovery,
    oem_session,
    video_tls_handshake,
    waiting_video_certificate,
    websocket_upgrade,
    rfb_negotiation,
    awaiting_first_frame,
    streaming,
    cleanup,
    released,
    cancelled,
    failed,
};
pub const Kind = enum { stage, diagnostic, http_response, failure };
pub const Validity = enum { valid, partial_with_error, unavailable };
pub const Resource = enum { none, management_route, video_route, service_root, public_script, session_service, web_session, managers_collection, manager, systems_collection, system, other_redfish, kvm_session, websocket };
pub const Code = enum {
    none,
    route_connected,
    tls_trusted,
    public_material_verified,
    firmware_verified,
    web_authenticated,
    kvm_authenticated,
    websocket_ready,
    mapping_verified,
    mapping_manager_document_rejected,
    mapping_manager_servers_not_single,
    mapping_system_missing,
    mapping_system_document_rejected,
    mapping_system_reverse_link_missing,
    mapping_system_identity_missing,
    mapping_invalid_relationship,
    mapping_profile_evidence_unverified,
    mapping_ambiguous,
    readonly_projection_available,
    readonly_discovery_incomplete,
    readonly_collection_missing,
    readonly_collection_rejected,
    readonly_collection_invalid,
    readonly_members_not_single,
    readonly_member_missing,
    readonly_member_rejected,
    readonly_system_invalid,
    readonly_identity_missing,
    management_fields_unavailable,
    websocket_close_sent,
    websocket_close_unconfirmed,
    remote_logout_confirmed,
    remote_logout_unconfirmed,
    local_cleanup_unknown,
};
pub const Event = struct {
    sequence: u64 = 0,
    /// Milliseconds since this attempt began, measured by MONOTONIC.
    at_ms: u64 = 0,
    stage: Stage = .idle,
    kind: Kind = .stage,
    code: Code = .none,
    resource: Resource = .none,
    http_status: ?u16 = null,
    /// Only @errorName(error), never an externally supplied string.
    error_code: ?[]const u8 = null,
    count: ?u16 = null,
    validity: ?Validity = null,
};
pub const Snapshot = struct {
    revision: u64 = 0,
    stage: Stage = .idle,
    elapsed_ms: u64 = 0,
    stage_elapsed_ms: u64 = 0,
    waiting_for_user: bool = false,
    route_hops: u8 = 0,
    failure_stage: ?Stage = null,
    failure_code: ?[]const u8 = null,
    /// Oldest first; only events[0..event_count] contain published events.
    events: [capacity]Event = @splat(.{}),
    event_count: u8 = 0,
};
pub const Detail = struct {
    code: Code = .none,
    resource: Resource = .none,
    http_status: ?u16 = null,
    count: ?u16 = null,
    validity: ?Validity = null,
};

pub const Tracker = struct {
    mutex: std.atomic.Value(bool) = .init(false),
    value: Snapshot = .{},
    started_ms: u64 = 0,
    stage_started_ms: u64 = 0,
    last_ms: u64 = 0,
    ended_ms: ?u64 = null,
    was_cancelled: bool = false,

    pub fn init(route_hops: u8) Tracker {
        return initAt(route_hops, nowMs());
    }
    pub fn initAt(route_hops: u8, now_ms: u64) Tracker {
        return .{ .value = .{ .route_hops = route_hops }, .started_ms = now_ms, .stage_started_ms = now_ms, .last_ms = now_ms };
    }
    pub fn setStage(self: *Tracker, stage: Stage) void {
        self.setStageAt(stage, nowMs());
    }
    pub fn setStageAt(self: *Tracker, stage: Stage, now_ms: u64) void {
        self.lock();
        defer self.unlock();
        if (self.ended_ms != null or self.value.stage == stage) return;
        self.transition(stage, self.clampTime(now_ms));
    }
    pub fn note(self: *Tracker, detail: Detail) void {
        self.noteAt(detail, nowMs());
    }
    pub fn noteAt(self: *Tracker, detail: Detail, now_ms: u64) void {
        self.lock();
        defer self.unlock();
        if (self.ended_ms != null) return;
        self.append(.{ .at_ms = self.clampTime(now_ms) -| self.started_ms, .stage = self.value.stage, .kind = if (detail.http_status != null and detail.code == .none) .http_response else .diagnostic, .code = detail.code, .resource = detail.resource, .http_status = detail.http_status, .count = detail.count, .validity = detail.validity });
    }
    pub fn fail(self: *Tracker, err: anyerror) void {
        self.failAt(err, nowMs());
    }
    pub fn failAt(self: *Tracker, err: anyerror, now_ms: u64) void {
        self.lock();
        defer self.unlock();
        if (self.ended_ms != null) return;
        const current = self.clampTime(now_ms);
        if (err == error.Cancelled) {
            self.was_cancelled = true;
            self.transition(.cancelled, current);
            return;
        }
        if (self.value.failure_code == null) {
            self.value.failure_stage = self.value.stage;
            self.value.failure_code = @errorName(err);
        }
        self.append(.{ .at_ms = current -| self.started_ms, .stage = self.value.stage, .kind = .failure, .error_code = @errorName(err) });
        self.transition(.failed, current);
    }
    /// Called only after the complete local cleanup/FrameLease barrier.
    /// Cleanup progress never discards the original connection failure.
    pub fn finish(self: *Tracker, cancelled: bool) void {
        self.finishAt(cancelled, nowMs());
    }
    pub fn finishAt(self: *Tracker, cancelled: bool, now_ms: u64) void {
        self.lock();
        defer self.unlock();
        if (self.ended_ms != null) return;
        const current = self.clampTime(now_ms);
        self.transition(if (self.value.failure_code != null) .failed else if (cancelled or self.was_cancelled) .cancelled else .released, current);
        self.ended_ms = current;
    }
    pub fn snapshot(self: *Tracker) Snapshot {
        return self.snapshotAt(nowMs());
    }
    pub fn snapshotAt(self: *Tracker, now_ms: u64) Snapshot {
        self.lock();
        defer self.unlock();
        var result = self.value;
        const current = self.ended_ms orelse self.clampTime(now_ms);
        result.elapsed_ms = current -| self.started_ms;
        result.stage_elapsed_ms = current -| self.stage_started_ms;
        result.waiting_for_user = result.stage == .waiting_certificate or result.stage == .waiting_video_certificate or result.stage == .waiting_credentials;
        return result;
    }
    fn transition(self: *Tracker, stage: Stage, current: u64) void {
        if (self.value.stage == stage) return;
        self.value.stage = stage;
        self.stage_started_ms = current;
        self.append(.{ .at_ms = current -| self.started_ms, .stage = stage });
    }
    fn append(self: *Tracker, event: Event) void {
        self.value.revision +|= 1;
        var published = event;
        published.sequence = self.value.revision;
        const count: usize = self.value.event_count;
        if (count == capacity) {
            std.mem.copyForwards(Event, self.value.events[0 .. capacity - 1], self.value.events[1..]);
            self.value.events[capacity - 1] = published;
        } else {
            self.value.events[count] = published;
            self.value.event_count += 1;
        }
    }
    fn clampTime(self: *Tracker, now_ms: u64) u64 {
        self.last_ms = @max(self.last_ms, now_ms);
        return self.last_ms;
    }
    fn lock(self: *Tracker) void {
        while (self.mutex.cmpxchgWeak(false, true, .acquire, .monotonic) != null) std.atomic.spinLoopHint();
    }
    fn unlock(self: *Tracker) void {
        self.mutex.store(false, .release);
    }
};

pub fn nowMs() u64 {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(.MONOTONIC, &ts) != 0 or ts.sec < 0 or ts.nsec < 0) return 0;
    return @as(u64, @intCast(ts.sec)) * 1000 + @as(u64, @intCast(ts.nsec)) / 1_000_000;
}
pub fn stageLabel(stage: Stage) []const u8 {
    return switch (stage) {
        .idle => "准备连接",
        .route => "建立连接路由",
        .tls_handshake => "TLS 握手",
        .waiting_certificate => "等待用户确认证书",
        .public_identity => "读取公开设备身份",
        .public_script => "验证公开脚本摘要",
        .waiting_credentials => "等待用户输入凭据",
        .web_login => "WEB 登录",
        .firmware_confirmation => "确认固件版本",
        .redfish_discovery => "Redfish 只读发现",
        .oem_session => "创建 OEM KVM 会话",
        .video_tls_handshake => "视频 TLS 握手",
        .waiting_video_certificate => "等待用户确认视频通道证书",
        .websocket_upgrade => "建立 WSS 视频通道",
        .rfb_negotiation => "RFB 协商",
        .awaiting_first_frame => "等待首帧",
        .streaming => "画面已连接",
        .cleanup => "释放连接资源",
        .released => "连接资源已释放",
        .cancelled => "连接已取消",
        .failed => "连接失败",
    };
}
pub fn resourceLabel(resource: Resource) []const u8 {
    return switch (resource) {
        .none => "",
        .management_route => "管理通道",
        .video_route => "视频通道",
        .service_root => "服务根",
        .public_script => "公开脚本",
        .session_service => "WEB 会话服务",
        .web_session => "本次 WEB 会话",
        .managers_collection => "管理器集合",
        .manager => "管理器资源",
        .systems_collection => "系统集合",
        .system => "系统资源",
        .other_redfish => "只读 Redfish 资源",
        .kvm_session => "本次 KVM 会话",
        .websocket => "WebSocket",
    };
}
pub fn codeLabel(code: Code) []const u8 {
    return switch (code) {
        .none => "",
        .route_connected => "路由已建立",
        .tls_trusted => "TLS 证书信任已确认",
        .public_material_verified => "公开脚本摘要已匹配",
        .firmware_verified => "固件版本已确认",
        .web_authenticated => "WEB 登录成功",
        .kvm_authenticated => "OEM KVM 认证成功",
        .websocket_ready => "WSS 升级成功",
        .mapping_verified => "管理器与系统映射已验证",
        .mapping_manager_document_rejected => "系统映射未验证：管理器文档不可用",
        .mapping_manager_servers_not_single => "系统映射未验证：管理器系统关系不唯一",
        .mapping_system_missing => "系统映射未验证：关联的系统资源缺失",
        .mapping_system_document_rejected => "系统映射未验证：关联的系统文档被拒绝",
        .mapping_system_reverse_link_missing => "系统映射未验证：缺少反向管理器关系",
        .mapping_system_identity_missing => "系统映射未验证：缺少系统身份",
        .mapping_invalid_relationship => "系统映射未验证：关系无效",
        .mapping_profile_evidence_unverified => "系统映射未验证：协议证据不足",
        .mapping_ambiguous => "系统映射未验证：存在多个匹配",
        .readonly_projection_available => "独立只读系统投影可用（未授予写权限）",
        .readonly_discovery_incomplete => "只读系统投影不可用：发现尚未完成",
        .readonly_collection_missing => "只读系统投影不可用：系统集合缺失",
        .readonly_collection_rejected => "只读系统投影不可用：系统集合文档被拒绝",
        .readonly_collection_invalid => "只读系统投影不可用：系统集合结构无效",
        .readonly_members_not_single => "只读系统投影不可用：集合成员不唯一或为空",
        .readonly_member_missing => "只读系统投影不可用：集合成员文档缺失",
        .readonly_member_rejected => "只读系统投影不可用：成员文档被拒绝",
        .readonly_system_invalid => "只读系统投影不可用：系统文档结构无效",
        .readonly_identity_missing => "只读系统投影不可用：系统身份缺失",
        .management_fields_unavailable => "只读管理字段不可用：未观察到有效值",
        .websocket_close_sent => "WebSocket 关闭帧已发送",
        .websocket_close_unconfirmed => "WebSocket 关闭未确认",
        .remote_logout_confirmed => "本次远程会话注销已确认",
        .remote_logout_unconfirmed => "本次远程会话注销未确认",
        .local_cleanup_unknown => "本地资源释放尚未确认",
    };
}
