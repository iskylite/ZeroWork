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
pub const Capability = struct {
    revision: u64 = 1,
    grant_revision: u64 = 1,
    binding_generation: u64 = 1,
    system_mapping_verified: bool = false,
    write_granted: bool = false,
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
    capability: Capability = .{},
    state: Field(PowerState) = .{},
    reset_types: Field([]const []const u8) = .{},
    reset_target: ?[]const u8 = null,
    etag: ?[]const u8 = null,
};
pub const BootState = struct { enabled: ?[]const u8 = null, target: ?[]const u8 = null, mode: ?[]const u8 = null };
pub const BootOption = struct { reference: []const u8, id: []const u8, name: ?[]const u8 = null, enabled: ?bool = null, evidence: Evidence = .{} };
pub const BootSnapshot = struct {
    system_uri: []const u8 = "",
    system_identity: []const u8 = "",
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
pub const Phase = enum { queued, awaiting_auth, refreshing, sending, accepted_remote, tracking_task, verifying, succeeded, failed, outcome_unknown, cancelled_unsent };
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
};
pub const BootService = struct {
    snapshot: *const fn (*anyopaque, Call, std.mem.Allocator) anyerror!OwnedBootSnapshot,
    apply: *const fn (*anyopaque, BootExecutionPatch) RequestResult,
    cancel: *const fn (*anyopaque, Call, OperationKey) CancelResult,
    result: *const fn (*anyopaque, Call, OperationKey, std.mem.Allocator) anyerror!Owned(Result),
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
