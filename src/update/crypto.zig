const std = @import("std");
const Ed = std.crypto.sign.Ed25519;
export fn zw_update_trust_json() [*:0]const u8 {
    return @embedFile("trust.json");
}
export fn zw_update_verify_signature(key: [*]const u8, signature: [*]const u8, payload: [*]const u8, len: usize) c_int {
    const public = Ed.PublicKey.fromBytes(key[0..32].*) catch return 0;
    Ed.Signature.fromBytes(signature[0..64].*).verify(payload[0..len], public) catch return 0;
    return 1;
}
export fn zw_update_newer(candidate: [*:0]const u8, current: [*:0]const u8) c_int {
    const next = std.SemanticVersion.parse(std.mem.span(candidate)) catch return 0;
    const old = std.SemanticVersion.parse(std.mem.span(current)) catch return 0;
    // Feed is stable-only, even when the installed app is a release candidate.
    if (next.pre != null or next.build != null) return 0;
    return @intFromBool(next.order(old) == .gt);
}
test "update stable feed semver and signature tampering" {
    try std.testing.expectEqual(@as(c_int, 1), zw_update_newer("0.3.0", "0.3.0-rc1"));
    try std.testing.expectEqual(@as(c_int, 0), zw_update_newer("0.3.0-rc2", "0.3.0-rc1"));
    try std.testing.expectEqual(@as(c_int, 0), zw_update_newer("0.3.0", "0.4.0"));
    try std.testing.expectEqual(@as(c_int, 0), zw_update_newer("garbage", "0.3.0"));
    const pair = try Ed.KeyPair.generateDeterministic(@splat(7));
    const sig = (try pair.sign("payload", null)).toBytes();
    const key = pair.public_key.toBytes();
    try std.testing.expectEqual(@as(c_int, 1), zw_update_verify_signature(&key, &sig, "payload", 7));
    try std.testing.expectEqual(@as(c_int, 0), zw_update_verify_signature(&key, &sig, "Payload", 7));
}
