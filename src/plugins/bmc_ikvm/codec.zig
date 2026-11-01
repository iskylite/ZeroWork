const std = @import("std");
const model = @import("model.zig");
const envelope = @import("../../config/connection_envelope.zig");
pub const validatePayload = model.validatePayload;

pub fn encode(a: std.mem.Allocator, original: envelope.Envelope) !envelope.Envelope {
    try original.validate();
    if (!std.mem.eql(u8, original.protocol_id, model.protocol_id)) return error.ProtocolMismatch;
    if (original.payload_version != model.payload_version) return error.UnsupportedPayloadVersion;
    var parsed = try model.parse(a, original.payload);
    defer parsed.deinit();
    const payload = try std.json.Stringify.valueAlloc(a, parsed.value(), .{});
    errdefer a.free(payload);
    const name = try a.dupe(u8, original.name);
    errdefer a.free(name);
    const protocol = try a.dupe(u8, model.protocol_id);
    var result = original;
    result.payload = payload;
    result.name = name;
    result.protocol_id = protocol;
    return result;
}
pub fn decode(a: std.mem.Allocator, original: envelope.Envelope) !envelope.Envelope {
    return encode(a, original);
}
pub fn migrate(a: std.mem.Allocator, original: envelope.Envelope, target_version: u32) !envelope.Envelope {
    if (target_version != model.payload_version or original.payload_version != model.payload_version) return error.UnsupportedPayloadVersion;
    return encode(a, original);
}
/// Plugin GC hook. Returned references are owned by the supplied transaction
/// allocator. No Keychain reads or writes, DNS or connection attempts occur.
pub fn credentialReferences(a: std.mem.Allocator, payload: []const u8) ![]const []const u8 {
    var parsed = try model.parse(a, payload);
    defer parsed.deinit();
    const reference = parsed.value().credential_ref orelse return &.{};
    const result = try a.alloc([]const u8, 1);
    errdefer a.free(result);
    result[0] = try a.dupe(u8, reference);
    return result;
}
