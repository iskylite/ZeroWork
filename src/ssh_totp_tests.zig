const std = @import("std");
const totp = @import("proto/ssh/totp.zig");

// Public RFC test secret: ASCII "12345678901234567890".
const rfc_seed = "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ";

fn expectCode(seed: []const u8, seconds: u64, expected: []const u8) !void {
    var code = try totp.generate(seed, seconds);
    defer code.deinit();
    try std.testing.expectEqual(@as(usize, 6), code.slice().len);
    try std.testing.expectEqualStrings(expected, code.slice());
}

test "TOTP RFC 6238 SHA1 timestamps preserve six digit leading zeroes" {
    // RFC 6238 Appendix B specifies eight digits. Applying RFC 4226's
    // modulo 10^6 to the same truncated value gives their final six digits.
    const vectors = [_]struct { seconds: u64, code: []const u8 }{
        .{ .seconds = 59, .code = "287082" },
        .{ .seconds = 1111111109, .code = "081804" },
        .{ .seconds = 1111111111, .code = "050471" },
        .{ .seconds = 1234567890, .code = "005924" },
        .{ .seconds = 2000000000, .code = "279037" },
        .{ .seconds = 20000000000, .code = "353130" },
    };
    for (vectors) |vector| try expectCode(rfc_seed, vector.seconds, vector.code);
}

test "TOTP RFC 4226 counters map to complete thirty second windows" {
    const expected = [_][]const u8{
        "755224", "287082", "359152", "969429", "338314",
        "254676", "287922", "162583", "399871", "520489",
    };
    for (expected, 0..) |code, counter| {
        const seconds: u64 = @as(u64, @intCast(counter)) * totp.period_seconds;
        try expectCode(rfc_seed, seconds, code);
        try expectCode(rfc_seed, seconds + totp.period_seconds - 1, code);
    }
}

test "TOTP Base32 RFC 4648 encodings accept exact or omitted padding and case" {
    // Codes for the RFC's decoded f/fo/foo/foob/fooba/foobar fixtures were
    // independently calculated with Python hmac/hashlib at counter one.
    const encodings = [_]struct { padded: []const u8, plain: []const u8, mixed: []const u8, code: []const u8 }{
        .{ .padded = "MY======", .plain = "MY", .mixed = "mY======", .code = "300412" },
        .{ .padded = "MZXQ====", .plain = "MZXQ", .mixed = "MzxQ====", .code = "412468" },
        .{ .padded = "MZXW6===", .plain = "MZXW6", .mixed = "mZxW6===", .code = "398408" },
        .{ .padded = "MZXW6YQ=", .plain = "MZXW6YQ", .mixed = "mZxW6yQ=", .code = "087780" },
        .{ .padded = "MZXW6YTB", .plain = "MZXW6YTB", .mixed = "mZxW6yTb", .code = "707689" },
        .{ .padded = "MZXW6YTBOI======", .plain = "MZXW6YTBOI", .mixed = "mZxW6yTbOi======", .code = "449542" },
    };
    for (encodings) |encoding| {
        try totp.validate(encoding.padded);
        try totp.validate(encoding.plain);
        try totp.validate(encoding.mixed);
        try expectCode(encoding.padded, 59, encoding.code);
        try expectCode(encoding.plain, 59, encoding.code);
        try expectCode(encoding.mixed, 59, encoding.code);
    }
}

test "TOTP Base32 rejects empty seeds and impossible terminal lengths" {
    for ([_][]const u8{ "", "=", "========" }) |seed| {
        try std.testing.expectError(error.EmptySeed, totp.validate(seed));
        try std.testing.expectError(error.EmptySeed, totp.generate(seed, 0));
    }
    for ([_][]const u8{ "A", "AAA", "AAAAAA", "AAAAAAAAA", "A=======", "AAA=====", "AAAAAA==" }) |seed| {
        try std.testing.expectError(error.InvalidBase32Length, totp.validate(seed));
        try std.testing.expectError(error.InvalidBase32Length, totp.generate(seed, 0));
    }
}

test "TOTP Base32 rejects whitespace aliases separators and non ASCII" {
    for ([_][]const u8{
        "M0", "M1", "M8", "M9",    "M ",    " M",       "M\t", "M\r", "M\n",
        "M-", "M_", "M!", "M\x00", "M\xff", "\xc3\xa9",
    }) |seed| {
        try std.testing.expectError(error.InvalidBase32Character, totp.validate(seed));
        try std.testing.expectError(error.InvalidBase32Character, totp.generate(seed, 0));
    }
}

test "TOTP Base32 rejects incorrect or interior padding" {
    for ([_][]const u8{
        "MY=",       "MY=====",          "MY=======",        "MY==============", "MY====A=",
        "MZXQ===",   "MZXQ=====",        "MZXW6==",          "MZXW6====",        "MZXW6YQ==",
        "MZXW6YTB=", "MZXW6YTB========", "MZXW6YQ=MY======",
    }) |seed| {
        try std.testing.expectError(error.InvalidBase32Padding, totp.validate(seed));
        try std.testing.expectError(error.InvalidBase32Padding, totp.generate(seed, 0));
    }
}

test "TOTP Base32 rejects nonzero trailing bits for every partial octet tail" {
    for ([_][]const u8{
        "MZ",    "MZ======", "MZXR",    "MZXR====",
        "MZXW7", "MZXW7===", "MZXW6YR", "MZXW6YR=",
    }) |seed| {
        try std.testing.expectError(error.NonCanonicalBase32, totp.validate(seed));
        try std.testing.expectError(error.NonCanonicalBase32, totp.generate(seed, 0));
    }
}

test "TOTP supports full unsigned Unix time without window arithmetic overflow" {
    // Independently checked with Python's hmac/hashlib and an eight-byte
    // big-endian counter; unlike RFC 6238 Appendix B this tests u64.max.
    try expectCode(rfc_seed, std.math.maxInt(u64), "277486");
}

test "TOTP streaming key normalization covers SHA1 block boundaries and long keys" {
    // Public all-zero fixtures independently calculated with Python hmac.
    const key64: [103]u8 = @splat('A');
    const key65: [104]u8 = @splat('A');
    const key640: [1024]u8 = @splat('A');
    try expectCode(&key64, 59, "812658");
    try expectCode(&key65, 59, "523350");
    try expectCode(&key640, 59, "459856");
}

test "TOTP returned code can be explicitly erased" {
    var code = try totp.generate(rfc_seed, 59);
    code.deinit();
    const erased: [totp.digits]u8 = @splat(0);
    try std.testing.expectEqualSlices(u8, &erased, code.slice());
}
