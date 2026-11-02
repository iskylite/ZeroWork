//! Boot patches contain only explicitly changed supported override fields.
//! Disabled closes an override without modifying the hidden target/mode draft.
const std = @import("std");
const svc = @import("../services.zig");
pub const Prepared = struct { body: []const u8, expected: svc.BootState, parameters: svc.BootState };
pub fn normalized(patch: svc.BootExecutionPatch) svc.BootState {
    return normalizedFields(patch.baseline, .{ .enabled = patch.enabled, .target = patch.target, .mode = patch.mode });
}
fn normalizedFields(baseline: svc.BootState, changed: svc.BootState) svc.BootState {
    var parameters = changed;
    if (parameters.enabled) |enabled| if (std.mem.eql(u8, enabled, "Disabled")) {
        parameters = .{ .enabled = "Disabled" };
    };
    if (svc.optionalEqual(parameters.enabled, baseline.enabled)) parameters.enabled = null;
    if (svc.optionalEqual(parameters.target, baseline.target)) parameters.target = null;
    if (svc.optionalEqual(parameters.mode, baseline.mode)) parameters.mode = null;
    return parameters;
}
/// Validate only the fields this request changes and the values needed to
/// establish their combination. A Disabled patch never consumes target/mode.
pub fn validate(snapshot: svc.BootSnapshot, patch: svc.BootExecutionPatch) !void {
    try validateFields(snapshot, patch.baseline, normalized(patch), patch.etag);
}
pub fn validateFields(snapshot: svc.BootSnapshot, baseline: svc.BootState, changed: svc.BootState, etag: ?[]const u8) !void {
    const parameters = normalizedFields(baseline, changed);
    if (!svc.optionalEqual(snapshot.etag, etag)) return error.StaleBaseline;
    if (parameters.enabled == null and parameters.target == null and parameters.mode == null) return error.UnchangedBoot;
    if (!baselineMatches(snapshot, baseline, parameters)) return error.StaleBaseline;
    if (parameters.enabled) |enabled| {
        if (!svc.contains(&.{ "Disabled", "Once", "Continuous" }, enabled) or !allowed(snapshot.allowed_enabled, enabled) or !snapshot.enabled_evidence.permitsWrite()) return error.UnsupportedBootValue;
    }
    const disabled = parameters.enabled != null and std.mem.eql(u8, parameters.enabled.?, "Disabled");
    if (!disabled) {
        if (parameters.target) |target| {
            if (!svc.contains(&.{ "Pxe", "Hdd", "Cd", "Diags", "BiosSetup", "Usb", "None" }, target) or !allowed(snapshot.allowed_targets, target) or !snapshot.target_evidence.permitsWrite()) return error.UnsupportedBootValue;
        }
        if (parameters.mode) |mode| if (!svc.contains(&.{ "Legacy", "UEFI" }, mode) or !allowed(snapshot.allowed_modes, mode) or !snapshot.mode_evidence.permitsWrite()) return error.UnsupportedBootValue;
        const enabled = parameters.enabled orelse snapshot.state.enabled orelse return error.MissingBootBaseline;
        if (parameters.enabled == null and (!snapshot.enabled_evidence.permitsWrite() or !svc.contains(&.{ "Disabled", "Once", "Continuous" }, enabled))) return error.UnsupportedBootValue;
        if (!std.mem.eql(u8, enabled, "Disabled")) {
            const target = parameters.target orelse snapshot.state.target orelse return error.MissingBootBaseline;
            if (parameters.target == null and !snapshot.target_evidence.permitsWrite()) return error.UnsupportedBootValue;
            if (std.mem.eql(u8, target, "None")) return error.InvalidBootCombination;
            if (std.mem.eql(u8, target, "UefiBootNext")) return error.UnsupportedBootValue;
        }
    }
}
pub fn baselineMatches(snapshot: svc.BootSnapshot, baseline: svc.BootState, changed: svc.BootState) bool {
    if (!matches(baseline, snapshot.state, changed)) return false;
    if (changed.enabled) |enabled| if (std.mem.eql(u8, enabled, "Disabled")) return true;
    if (changed.enabled == null and !svc.optionalEqual(snapshot.state.enabled, baseline.enabled)) return false;
    const enabled = changed.enabled orelse snapshot.state.enabled orelse return false;
    return std.mem.eql(u8, enabled, "Disabled") or changed.target != null or svc.optionalEqual(snapshot.state.target, baseline.target);
}
pub fn observationValid(snapshot: svc.BootSnapshot, changed: svc.BootState) bool {
    return (changed.enabled == null or snapshot.enabled_evidence.permitsWrite()) and
        (changed.target == null or snapshot.target_evidence.permitsWrite()) and
        (changed.mode == null or snapshot.mode_evidence.permitsWrite());
}
pub fn collectedMs(snapshot: svc.BootSnapshot, changed: svc.BootState) u64 {
    var collected: u64 = std.math.maxInt(u64);
    if (changed.enabled != null) collected = @min(collected, @min(snapshot.enabled_evidence.collected_ms, snapshot.allowed_enabled.evidence.collected_ms));
    if (changed.target != null) collected = @min(collected, @min(snapshot.target_evidence.collected_ms, snapshot.allowed_targets.evidence.collected_ms));
    if (changed.mode != null) collected = @min(collected, @min(snapshot.mode_evidence.collected_ms, snapshot.allowed_modes.evidence.collected_ms));
    if (changed.enabled) |enabled| if (std.mem.eql(u8, enabled, "Disabled")) return collected;
    if (changed.enabled == null) collected = @min(collected, snapshot.enabled_evidence.collected_ms);
    const enabled = changed.enabled orelse snapshot.state.enabled orelse return 0;
    if (!std.mem.eql(u8, enabled, "Disabled") and changed.target == null) collected = @min(collected, snapshot.target_evidence.collected_ms);
    return collected;
}
pub fn prepare(a: std.mem.Allocator, snapshot: svc.BootSnapshot, patch: svc.BootExecutionPatch) !Prepared {
    try validate(snapshot, patch);
    const parameters = normalized(patch);
    var expected = snapshot.state;
    if (parameters.enabled) |value| expected.enabled = value;
    if (parameters.target) |value| expected.target = value;
    if (parameters.mode) |value| expected.mode = value;
    var map: std.json.ObjectMap = .{};
    if (parameters.enabled) |value| try map.put(a, "BootSourceOverrideEnabled", .{ .string = value });
    if (parameters.target) |value| try map.put(a, "BootSourceOverrideTarget", .{ .string = value });
    if (parameters.mode) |value| try map.put(a, "BootSourceOverrideMode", .{ .string = value });
    var outer: std.json.ObjectMap = .{};
    try outer.put(a, "Boot", .{ .object = map });
    return .{ .body = try std.json.Stringify.valueAlloc(a, std.json.Value{ .object = outer }, .{}), .expected = expected, .parameters = parameters };
}
fn allowed(field: svc.Field([]const []const u8), value: []const u8) bool {
    return field.evidence.permitsWrite() and svc.contains(field.value orelse return false, value);
}
pub fn matches(expected: svc.BootState, observed: svc.BootState, changed: svc.BootState) bool {
    return (changed.enabled == null or svc.optionalEqual(expected.enabled, observed.enabled)) and
        (changed.target == null or svc.optionalEqual(expected.target, observed.target)) and
        (changed.mode == null or svc.optionalEqual(expected.mode, observed.mode));
}
