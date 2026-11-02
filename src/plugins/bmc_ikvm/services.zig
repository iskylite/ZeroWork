//! Single definitions for the management service type tokens. Snapshots own all
//! strings and can be retained independently of the worker/controller arena.
const std = @import("std");
pub const identity = @import("../../host/identity.zig");
pub const OperationKey = @import("../../host/operation.zig").OperationKey;
const typed = @import("../../host/plugin_services.zig");
pub const power_key: typed.ServiceKey = .{ .name = "bmc_ikvm.power", .major = 1 };
pub const boot_key: typed.ServiceKey = .{ .name = "bmc_ikvm.boot", .major = 1 };
pub const Validity = enum { valid, partial_with_error, unavailable };
pub const Evidence = struct {
    source_uri: []const u8 = "",
    collected_ms: u64 = 0,
    validity: Validity = .unavailable,
    corroborated: bool = false,
    pub fn permitsWrite(self: Evidence) bool {
        return self.validity == .valid or (self.validity == .partial_with_error and self.corroborated);
    }
};
pub fn Field(comptime T: type) type {
    return struct { value: ?T = null, evidence: Evidence = .{} };
}
pub const SecondaryAuth = enum { unknown, disabled, required };
/// Frozen by the session factory. Read-only owners cannot acquire a write
/// approval, even if a backend or caller supplies permissive snapshot flags.
pub const ManagementPolicy = enum { user_approved, read_only };
pub const Capability = struct {
    revision: u64 = 1,
    grant_revision: u64 = 1,
    binding_generation: u64 = 1,
    /// The selected standard management System and service Manager are
    /// verified. This does not assert an OEM KVM channel displays that System.
    system_mapping_verified: bool = false,
    write_granted: bool = false,
    /// The UI may request a one-operation approval. This flag is never proof
    /// that a mutation was approved and is not accepted at dispatch.
    write_requestable: bool = false,
    secondary_auth: SecondaryAuth = .unknown,
    secondary_auth_evidence: Evidence = .{},
};
pub const PowerState = enum { on, off, powering_on, powering_off, unknown };
pub const PowerAction = enum {
    on,
    graceful_shutdown,
    graceful_restart,
    force_off,
    force_restart,
    power_cycle,
    pub fn redfish(self: PowerAction) []const u8 {
        return switch (self) {
            .on => "On",
            .graceful_shutdown => "GracefulShutdown",
            .graceful_restart => "GracefulRestart",
            .force_off => "ForceOff",
            .force_restart => "ForceRestart",
            .power_cycle => "PowerCycle",
        };
    }
    pub fn isRestart(self: PowerAction) bool {
        return self == .graceful_restart or self == .force_restart or self == .power_cycle;
    }
};
pub const PowerSnapshot = struct {
    system_uri: []const u8 = "",
    system_identity: []const u8 = "",
    /// Response-level diagnostics are retained separately from the evidence
    /// of each field. They do not by themselves disable every operation.
    resource_evidence: Evidence = .{},
    capability: Capability = .{},
    state: Field(PowerState) = .{},
    reset_types: Field([]const []const u8) = .{},
    reset_target: ?[]const u8 = null,
    etag: ?[]const u8 = null,
    last_reset_time: Field([]const u8) = .{},
};
const ResetTime = struct { seconds: i64, nanoseconds: u32 };
/// Bounded RFC3339 parser for a device's standard LastResetTime. Unknown
/// offsets, impossible dates and leap-second ambiguity cannot prove progress.
fn parseResetTime(value: ?[]const u8) ?ResetTime {
    const text = value orelse return null;
    if (text.len < 20 or text.len > 35 or text[4] != '-' or text[7] != '-' or text[10] != 'T' or text[13] != ':' or text[16] != ':') return null;
    const year: i64 = resetNumber(text[0..4]) orelse return null;
    const month: i64 = resetNumber(text[5..7]) orelse return null;
    const day: i64 = resetNumber(text[8..10]) orelse return null;
    const hour: i64 = resetNumber(text[11..13]) orelse return null;
    const minute: i64 = resetNumber(text[14..16]) orelse return null;
    const second: i64 = resetNumber(text[17..19]) orelse return null;
    if (year < 1 or month < 1 or month > 12 or hour > 23 or minute > 59 or second > 59) return null;
    const leap = @mod(year, 4) == 0 and (@mod(year, 100) != 0 or @mod(year, 400) == 0);
    const lengths = [_]i64{ 31, if (leap) 29 else 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    if (day < 1 or day > lengths[@intCast(month - 1)]) return null;
    var index: usize = 19;
    var nanos: u32 = 0;
    if (text[index] == '.') {
        index += 1;
        const start = index;
        while (index < text.len and std.ascii.isDigit(text[index])) : (index += 1) {
            if (index - start >= 9) return null;
            nanos = nanos * 10 + (text[index] - '0');
        }
        if (index == start) return null;
        var digits = index - start;
        while (digits < 9) : (digits += 1) nanos *= 10;
    }
    if (index >= text.len) return null;
    var offset: i64 = 0;
    if (text[index] == 'Z') {
        if (index + 1 != text.len) return null;
    } else {
        if (index + 6 != text.len or (text[index] != '+' and text[index] != '-') or text[index + 3] != ':') return null;
        const hours = resetNumber(text[index + 1 .. index + 3]) orelse return null;
        const minutes = resetNumber(text[index + 4 .. index + 6]) orelse return null;
        if (hours > 14 or minutes > 59 or (hours == 14 and minutes != 0) or (text[index] == '-' and hours == 0 and minutes == 0)) return null;
        offset = (@as(i64, hours) * 60 + minutes) * 60;
        if (text[index] == '-') offset = -offset;
    }
    const y = year - @as(i64, if (month <= 2) 1 else 0);
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const adjusted_month = month + @as(i64, if (month > 2) -3 else 9);
    const doy = @divTrunc(153 * adjusted_month + 2, 5) + day - 1;
    const doe = yoe * 365 + @divTrunc(yoe, 4) - @divTrunc(yoe, 100) + doy;
    const days = era * 146097 + doe - 719468;
    return .{ .seconds = days * 86400 + hour * 3600 + minute * 60 + second - offset, .nanoseconds = nanos };
}
fn resetNumber(text: []const u8) ?u32 {
    var value: u32 = 0;
    for (text) |char| {
        if (!std.ascii.isDigit(char)) return null;
        value = value * 10 + (char - '0');
    }
    return value;
}
pub fn lastResetTimeMillis(value: ?[]const u8) ?i64 {
    const parsed = parseResetTime(value) orelse return null;
    return parsed.seconds * 1000 + @divTrunc(parsed.nanoseconds, 1_000_000);
}
pub fn lastResetTimeAdvanced(before: ?[]const u8, after: ?[]const u8) bool {
    const baseline = parseResetTime(before) orelse return false;
    const observed = parseResetTime(after) orelse return false;
    return observed.seconds > baseline.seconds or (observed.seconds == baseline.seconds and observed.nanoseconds > baseline.nanoseconds);
}
pub const BootState = struct { enabled: ?[]const u8 = null, target: ?[]const u8 = null, mode: ?[]const u8 = null };
pub const BootOption = struct { reference: []const u8, id: []const u8, name: ?[]const u8 = null, enabled: ?bool = null, evidence: Evidence = .{} };
pub const BootSnapshot = struct {
    system_uri: []const u8 = "",
    system_identity: []const u8 = "",
    resource_evidence: Evidence = .{},
    write_uri: ?[]const u8 = null,
    settings_uri: ?[]const u8 = null,
    pending: ?BootState = null,
    capability: Capability = .{},
    state: BootState = .{},
    enabled_evidence: Evidence = .{},
    target_evidence: Evidence = .{},
    mode_evidence: Evidence = .{},
    allowed_enabled: Field([]const []const u8) = .{},
    allowed_targets: Field([]const []const u8) = .{},
    allowed_modes: Field([]const []const u8) = .{},
    boot_order: Field([]const []const u8) = .{},
    alias_boot_order: Field([]const []const u8) = .{},
    options: []const BootOption = &.{},
    etag: ?[]const u8 = null,
};
pub fn Owned(comptime T: type) type {
    return struct {
        arena: std.heap.ArenaAllocator,
        value: T,
        pub fn init(a: std.mem.Allocator, value: T) !@This() {
            var arena: std.heap.ArenaAllocator = .init(a);
            errdefer arena.deinit();
            // Schema-only JSON round trip gives a recursive owned copy without
            // retaining pointers to a runtime's temporary response buffer.
            const bytes = try std.json.Stringify.valueAlloc(arena.allocator(), value, .{});
            const parsed = try std.json.parseFromSlice(T, arena.allocator(), bytes, .{ .allocate = .alloc_always });
            return .{ .arena = arena, .value = parsed.value };
        }
        pub fn deinit(self: *@This()) void {
            self.arena.deinit();
            self.* = undefined;
        }
    };
}
pub const OwnedPowerSnapshot = Owned(PowerSnapshot);
pub const OwnedBootSnapshot = Owned(BootSnapshot);
pub const Call = struct { owner: identity.SessionHandle, binding_generation: u64 };
pub const Execution = struct {
    call: Call,
    operation: OperationKey,
    nonce: [16]u8,
    system_uri: []const u8,
    capability_revision: u64,
    grant_revision: u64,
};
pub const PowerExecutionRequest = struct { execution: Execution, action: PowerAction };
/// Null means unchanged; Disabled is the sole field emitted when closing an
/// override. BootOrder, BootNext and arbitrary UEFI paths have no write API.
pub const BootExecutionPatch = struct { execution: Execution, baseline: BootState, enabled: ?[]const u8 = null, target: ?[]const u8 = null, mode: ?[]const u8 = null, etag: ?[]const u8 = null };
pub const ManagementRequest = union(enum) {
    power: PowerExecutionRequest,
    boot: BootExecutionPatch,
    pub fn execution(self: ManagementRequest) Execution {
        return switch (self) {
            .power => |value| value.execution,
            .boot => |value| value.execution,
        };
    }
};
/// Covers the complete owner/op/nonce, target, action/patch, baseline and both
/// revisions. Authority and discovered identity prevent cross-resource reuse.
pub fn requestFingerprint(a: std.mem.Allocator, request: ManagementRequest, authority: []const u8, system_identity: []const u8) ![32]u8 {
    const encoded = try std.json.Stringify.valueAlloc(a, request, .{});
    defer a.free(encoded);
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(authority);
    hash.update("\x00");
    hash.update(system_identity);
    hash.update("\x00");
    hash.update(encoded);
    return hash.finalResult();
}
pub const Phase = enum { queued, awaiting_approval, awaiting_auth, refreshing, sending, accepted_remote, tracking_task, verifying, succeeded, failed, outcome_unknown, cancelled_unsent };
pub const Reason = enum { unsupported, stale_binding, stale_capability, permission_denied, mapping_unverified, secondary_auth_unknown, secondary_auth_required, stale_baseline, conflict, busy, invalid_request, unavailable, journal_failed, remote_error, authentication_failed, timeout, transport_lost, verification_mismatch, pending, accepted_unverified, cancelled };
pub const Result = struct {
    operation: OperationKey,
    phase: Phase,
    reason: ?Reason = null,
    http_status: ?u16 = null,
    dispatched: bool = false,
    current_power: ?PowerState = null,
    current_boot: ?BootState = null,
    pending_boot: ?BootState = null,
    task_uri: ?[]const u8 = null,
    retry_after_ms: u64 = 0,
    pub fn terminal(self: Result) bool {
        return self.phase == .succeeded or self.phase == .failed or self.phase == .outcome_unknown or self.phase == .cancelled_unsent;
    }
};
pub const RequestResult = union(enum) { accepted: OperationKey, rejected: Reason };
pub const CancelResult = enum { cancelled_unsent, observation_stopped_remote_may_continue, already_terminal, stale_operation };
pub const PowerService = struct {
    snapshot: *const fn (*anyopaque, Call, std.mem.Allocator) anyerror!OwnedPowerSnapshot,
    request: *const fn (*anyopaque, PowerExecutionRequest) RequestResult,
    cancel: *const fn (*anyopaque, Call, OperationKey) CancelResult,
    result: *const fn (*anyopaque, Call, OperationKey, std.mem.Allocator) anyerror!Owned(Result),
    /// Explicit GET-only observation of a previously unknown operation.
    query: ?*const fn (*anyopaque, Call, OperationKey) anyerror!void = null,
};
pub const BootService = struct {
    snapshot: *const fn (*anyopaque, Call, std.mem.Allocator) anyerror!OwnedBootSnapshot,
    apply: *const fn (*anyopaque, BootExecutionPatch) RequestResult,
    cancel: *const fn (*anyopaque, Call, OperationKey) CancelResult,
    result: *const fn (*anyopaque, Call, OperationKey, std.mem.Allocator) anyerror!Owned(Result),
    query: ?*const fn (*anyopaque, Call, OperationKey) anyerror!void = null,
};
pub const power_definition = typed.Definition.of(PowerService, power_key);
pub const boot_definition = typed.Definition.of(BootService, boot_key);
pub fn contains(values: []const []const u8, candidate: []const u8) bool {
    for (values) |value| if (std.mem.eql(u8, value, candidate)) return true;
    return false;
}
pub fn sameBoot(a: BootState, b: BootState) bool {
    return optionalEqual(a.enabled, b.enabled) and optionalEqual(a.target, b.target) and optionalEqual(a.mode, b.mode);
}
pub fn optionalEqual(a: ?[]const u8, b: ?[]const u8) bool {
    if ((a == null) != (b == null)) return false;
    return a == null or std.mem.eql(u8, a.?, b.?);
}
