//! Boot patches contain only explicitly changed supported override fields.
//! Disabled closes an override without modifying the hidden target/mode draft.
const std = @import("std");
const svc = @import("../services.zig");
pub const Prepared = struct { body: []const u8, expected: svc.BootState, parameters: svc.BootState };
pub fn normalized(patch: svc.BootExecutionPatch) svc.BootState {
    var parameters: svc.BootState = .{ .enabled = patch.enabled, .target = patch.target, .mode = patch.mode };
    if (parameters.enabled) |enabled| if (std.mem.eql(u8, enabled, "Disabled")) {
        parameters = .{ .enabled = "Disabled" };
    };
    if (svc.optionalEqual(parameters.enabled, patch.baseline.enabled)) parameters.enabled = null;
    if (svc.optionalEqual(parameters.target, patch.baseline.target)) parameters.target = null;
    if (svc.optionalEqual(parameters.mode, patch.baseline.mode)) parameters.mode = null;
    return parameters;
}
pub fn prepare(a: std.mem.Allocator, snapshot: svc.BootSnapshot, patch: svc.BootExecutionPatch) !Prepared {
    if (!svc.sameBoot(snapshot.state, patch.baseline)) return error.StaleBaseline;
    if (!svc.optionalEqual(snapshot.etag, patch.etag)) return error.StaleBaseline;
    var parameters: svc.BootState = .{ .enabled = patch.enabled, .target = patch.target, .mode = patch.mode };
    if (patch.enabled) |enabled| {
        if (!svc.contains(&.{ "Disabled", "Once", "Continuous" }, enabled) or !allowed(snapshot.allowed_enabled, enabled) or !snapshot.enabled_evidence.permitsWrite()) return error.UnsupportedBootValue;
        if (std.mem.eql(u8, enabled, "Disabled")) parameters = .{ .enabled = "Disabled" };
    }
    const disabled = parameters.enabled != null and std.mem.eql(u8, parameters.enabled.?, "Disabled");
    if (!disabled) {
        if (parameters.target) |target| {
            if (!svc.contains(&.{ "Pxe", "Hdd", "Cd", "Diags", "BiosSetup", "Usb", "None" }, target) or !allowed(snapshot.allowed_targets, target) or !snapshot.target_evidence.permitsWrite()) return error.UnsupportedBootValue;
        }
        if (parameters.mode) |mode| if (!svc.contains(&.{ "Legacy", "UEFI" }, mode) or !allowed(snapshot.allowed_modes, mode) or !snapshot.mode_evidence.permitsWrite()) return error.UnsupportedBootValue;
        const enabled = parameters.enabled orelse snapshot.state.enabled orelse return error.MissingBootBaseline;
        const target = parameters.target orelse snapshot.state.target orelse return error.MissingBootBaseline;
        if (!std.mem.eql(u8, enabled, "Disabled") and std.mem.eql(u8, target, "None")) return error.InvalidBootCombination;
        if (std.mem.eql(u8, target, "UefiBootNext")) return error.UnsupportedBootValue;
    }
    if (svc.optionalEqual(parameters.enabled, snapshot.state.enabled)) parameters.enabled = null;
    if (svc.optionalEqual(parameters.target, snapshot.state.target)) parameters.target = null;
    if (svc.optionalEqual(parameters.mode, snapshot.state.mode)) parameters.mode = null;
    if (parameters.enabled == null and parameters.target == null and parameters.mode == null) return error.UnchangedBoot;
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
