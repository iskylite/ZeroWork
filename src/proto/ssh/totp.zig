const std = @import("std");

/// ZeroWork's fixed TOTP profile: RFC 6238, T0 = 0, HMAC-SHA1, 30 seconds,
/// six decimal digits. Time and request ownership are supplied by the caller.
pub const period_seconds: u64 = 30;
pub const digits: usize = 6;

pub const SeedError = error{
    EmptySeed,
    InvalidBase32Length,
    InvalidBase32Padding,
    InvalidBase32Character,
    NonCanonicalBase32,
};

pub const Code = struct {
    bytes: [digits]u8,

    pub fn slice(self: *const Code) []const u8 {
        return &self.bytes;
    }

    pub fn deinit(self: *Code) void {
        std.crypto.secureZero(u8, &self.bytes);
    }
};

/// Accepts case-insensitive RFC 4648 Base32 with omitted or exact padding.
/// Empty input, whitespace, aliases such as 0/1, and nonzero pad bits fail.
/// This checks encoding only; the caller retains ownership of the seed.
pub fn validate(seed: []const u8) SeedError!void {
    try decode(seed, null);
}

/// Returns six ASCII digits, including leading zeroes. The caller must erase
/// its seed and the returned Code when no longer needed. Module-owned decoded
/// key material, HMAC state, and digest buffers are erased before returning.
pub fn generate(seed: []const u8, unix_seconds: u64) SeedError!Code {
    var material: KeyMaterial = .{};
    defer std.crypto.secureZero(u8, std.mem.asBytes(&material));
    try decode(seed, &material);

    var counter: [8]u8 = undefined;
    defer std.crypto.secureZero(u8, &counter);
    std.mem.writeInt(u64, &counter, unix_seconds / period_seconds, .big);

    const Hmac = std.crypto.auth.hmac.HmacSha1;
    var hmac = Hmac.init(material.key());
    defer std.crypto.secureZero(u8, std.mem.asBytes(&hmac));
    hmac.update(&counter);
    var digest: [Hmac.mac_length]u8 = undefined;
    defer std.crypto.secureZero(u8, &digest);
    hmac.final(&digest);

    const offset: usize = digest[digest.len - 1] & 0x0f;
    var value = (std.mem.readInt(u32, digest[offset..][0..4], .big) & 0x7fffffff) % 1_000_000;
    defer std.crypto.secureZero(u8, std.mem.asBytes(&value));
    var code: Code = undefined;
    var index = code.bytes.len;
    while (index > 0) {
        index -= 1;
        code.bytes[index] = '0' + @as(u8, @intCast(value % 10));
        value /= 10;
    }
    return code;
}

const Sha1 = std.crypto.hash.Sha1;

/// Streaming HMAC key normalization avoids heap allocation or a seed size cap.
const KeyMaterial = struct {
    first_block: [Sha1.block_length]u8 = @splat(0),
    decoded_len: usize = 0,
    hash: Sha1 = Sha1.init(.{}),
    normalized: [Sha1.digest_length]u8 = @splat(0),

    fn append(self: *KeyMaterial, octet: *const [1]u8) void {
        if (self.decoded_len < self.first_block.len) self.first_block[self.decoded_len] = octet[0];
        self.decoded_len += 1;
        self.hash.update(octet);
    }

    fn key(self: *KeyMaterial) []const u8 {
        if (self.decoded_len <= self.first_block.len) return self.first_block[0..self.decoded_len];
        self.hash.final(&self.normalized);
        return &self.normalized;
    }
};

fn decode(seed: []const u8, material: ?*KeyMaterial) SeedError!void {
    const data_len = std.mem.indexOfScalar(u8, seed, '=') orelse seed.len;
    if (data_len == 0) return error.EmptySeed;
    const expected_padding: usize = switch (data_len % 8) {
        0 => 0,
        2 => 6,
        4 => 4,
        5 => 3,
        7 => 1,
        else => return error.InvalidBase32Length,
    };
    if (data_len != seed.len) {
        if (seed.len - data_len != expected_padding) return error.InvalidBase32Padding;
        for (seed[data_len..]) |char| if (char != '=') return error.InvalidBase32Padding;
    }

    var state: struct {
        accumulator: u16 = 0,
        bits: u4 = 0,
        octet: [1]u8 = @splat(0),
    } = .{};
    defer std.crypto.secureZero(u8, std.mem.asBytes(&state));
    for (seed[0..data_len]) |char| {
        const word: u5 = switch (char) {
            'A'...'Z' => @intCast(char - 'A'),
            'a'...'z' => @intCast(char - 'a'),
            '2'...'7' => @intCast(char - '2' + 26),
            else => return error.InvalidBase32Character,
        };
        state.accumulator = (state.accumulator << 5) | @as(u16, word);
        state.bits += 5;
        if (state.bits >= 8) {
            state.bits -= 8;
            state.octet[0] = @intCast(state.accumulator >> state.bits);
            if (material) |key_material| key_material.append(&state.octet);
            state.accumulator &= (@as(u16, 1) << state.bits) - 1;
        }
    }
    if (state.accumulator != 0) return error.NonCanonicalBase32;
}
