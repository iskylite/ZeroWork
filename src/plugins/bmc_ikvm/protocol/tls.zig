//! Nonblocking mbedTLS 3.6.7 client over an OwnedStream fd.
//! Invoke from a session worker; no method waits or touches UI. fd remains
//! owned by transport. Only cancel() is safe concurrently with worker IO.
const std = @import("std");
const http = @import("http.zig");
const Native = opaque {};
extern fn zw_bmc_tls_create(fd: c_int, host: [*:0]const u8, error_code: *c_int) ?*Native;
extern fn zw_bmc_tls_destroy(ctx: *Native) void;
extern fn zw_bmc_tls_handshake_step(ctx: *Native) c_int;
extern fn zw_bmc_tls_authorize_trust(ctx: *Native, authorized: c_int) c_int;
extern fn zw_bmc_tls_read(ctx: *Native, out: [*]u8, cap: usize, count: *usize) c_int;
extern fn zw_bmc_tls_write(ctx: *Native, data: [*]const u8, len: usize, count: *usize) c_int;
extern fn zw_bmc_tls_close_notify_step(ctx: *Native) c_int;
extern fn zw_bmc_tls_cancel(ctx: *Native) void;
extern fn zw_bmc_tls_last_error(ctx: *const Native) c_int;
extern fn zw_bmc_tls_original_host(ctx: *const Native) [*:0]const u8;
extern fn zw_bmc_tls_cert_count(ctx: *const Native) usize;
extern fn zw_bmc_tls_cert_der(ctx: *const Native, index: usize, len: *usize) ?[*]const u8;
extern fn zw_bmc_tls_verify_flags(ctx: *const Native) u32;
extern fn zw_bmc_rsa2048_encrypt(key: [*]const u8, key_len: usize, plaintext: [*]const u8, plaintext_len: usize, output: [*]u8, output_cap: usize, output_len: *usize) c_int;
extern fn zw_bmc_rsa2048_base64(key: [*]const u8, key_len: usize, plaintext: [*]const u8, plaintext_len: usize, output: [*]u8, output_cap: usize, output_len: *usize) c_int;

pub const Step = enum { ready, want_read, want_write, needs_trust, closed };
pub const IoResult = union(enum) { bytes: usize, progress: Step };
fn step(code: c_int) !Step {
    return switch (code) {
        0 => .ready,
        1 => .want_read,
        2 => .want_write,
        3 => .needs_trust,
        4 => .closed,
        -2 => error.Cancelled,
        -3 => error.TrustRejected,
        -4 => error.InvalidTlsState,
        else => error.TlsFailed,
    };
}

pub const Client = struct {
    native: *Native,
    pub fn init(fd: c_int, original_host: []const u8) !Client {
        try (http.Origin{ .host = original_host }).validate();
        const host = try std.heap.c_allocator.dupeSentinel(u8, original_host, 0);
        defer std.heap.c_allocator.free(host);
        var code: c_int = 0;
        const native = zw_bmc_tls_create(fd, host, &code) orelse return error.TlsInitFailed;
        return .{ .native = native };
    }
    pub fn deinit(self: *Client) void {
        zw_bmc_tls_destroy(self.native);
        self.* = undefined;
    }
    pub fn cancel(self: *Client) void {
        zw_bmc_tls_cancel(self.native);
    }
    pub fn handshakeStep(self: *Client) !Step {
        return step(zw_bmc_tls_handshake_step(self.native));
    }
    /// Call only after the host trust facade authorizes this exact operation,
    /// original authority and complete chain. A denial is terminal.
    pub fn authorizeTrust(self: *Client, authorized: bool) !void {
        _ = try step(zw_bmc_tls_authorize_trust(self.native, @intFromBool(authorized)));
    }
    pub fn read(self: *Client, out: []u8) !IoResult {
        var count: usize = 0;
        const progress = try step(zw_bmc_tls_read(self.native, out.ptr, out.len, &count));
        return if (progress == .ready) .{ .bytes = count } else .{ .progress = progress };
    }
    /// Retry an unchanged buffer after want_read/want_write. Advance a write
    /// cursor only on .bytes; positive short writes are valid.
    pub fn write(self: *Client, bytes: []const u8) !IoResult {
        var count: usize = 0;
        const progress = try step(zw_bmc_tls_write(self.native, bytes.ptr, bytes.len, &count));
        return if (progress == .ready) .{ .bytes = count } else .{ .progress = progress };
    }
    pub fn closeNotifyStep(self: *Client) !Step {
        return step(zw_bmc_tls_close_notify_step(self.native));
    }
    pub fn lastNativeError(self: *const Client) c_int {
        return zw_bmc_tls_last_error(self.native);
    }
    pub fn originalHost(self: *const Client) []const u8 {
        return std.mem.span(zw_bmc_tls_original_host(self.native));
    }
    pub fn verificationFlags(self: *const Client) u32 {
        return zw_bmc_tls_verify_flags(self.native);
    }
    /// Only the outer array is allocated. DER slices borrow Client and must not
    /// outlive it. Leaf-first, exactly the presented chain, without network IO.
    pub fn peerChain(self: *const Client, allocator: std.mem.Allocator) ![]const []const u8 {
        const count = zw_bmc_tls_cert_count(self.native);
        if (count == 0 or count > 16) return error.PeerChainUnavailable;
        const chain = try allocator.alloc([]const u8, count);
        errdefer allocator.free(chain);
        for (chain, 0..) |*der, index| {
            var len: usize = 0;
            const bytes = zw_bmc_tls_cert_der(self.native, index, &len) orelse return error.PeerChainUnavailable;
            der.* = bytes[0..len];
        }
        return chain;
    }
};

/// The caller supplies a public key fixed by evidence (or a synthetic test key).
/// This primitive never invents vendor material or retries a different format.
pub fn encryptPassword(allocator: std.mem.Allocator, public_key: []const u8, plaintext: []const u8) ![]u8 {
    if (plaintext.len > 245) return error.PasswordTooLong;
    if (public_key.len == 0) return error.ProfileEvidenceMissing;
    const output = try allocator.alloc(u8, 344);
    errdefer {
        std.crypto.secureZero(u8, output);
        allocator.free(output);
    }
    var len: usize = 0;
    if (zw_bmc_rsa2048_base64(public_key.ptr, public_key.len, plaintext.ptr, plaintext.len, output.ptr, output.len, &len) != 0 or len != 344) return error.InvalidPublicKey;
    return output;
}

/// Raw ciphertext provider for an auth layer which performs its own base64.
pub fn encryptRsa2048(allocator: std.mem.Allocator, public_key: []const u8, plaintext: []const u8) ![]u8 {
    if (plaintext.len > 245) return error.PasswordTooLong;
    if (public_key.len == 0) return error.ProfileEvidenceMissing;
    const output = try allocator.alloc(u8, 256);
    errdefer {
        std.crypto.secureZero(u8, output);
        allocator.free(output);
    }
    var len: usize = 0;
    if (zw_bmc_rsa2048_encrypt(public_key.ptr, public_key.len, plaintext.ptr, plaintext.len, output.ptr, output.len, &len) != 0 or len != 256) return error.InvalidPublicKey;
    return output;
}
