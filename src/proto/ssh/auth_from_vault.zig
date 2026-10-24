const std = @import("std");
const Vault = @import("credential_vault.zig").Vault;
const Kind = @import("credential_vault.zig").Kind;
const Auth = @import("session.zig").Auth;
const PrivateKeyAuth = @import("session.zig").PrivateKeyAuth;

/// Builds a borrowed Session.Auth from a vault entry. The returned auth only
/// borrows vault memory and is valid until the credential is released.
pub fn authFor(vault: *Vault, id: u32, allocator: std.mem.Allocator) !Auth {
    const entry = vault.entry(id) orelse return error.UnknownCredential;
    return switch (entry.kind) {
        .password => .{ .password = try allocator.dupeSentinel(u8, entry.value, 0) },
        .private_key => .{ .private_key = .{ .path = try allocator.dupeSentinel(u8, entry.value, 0) } },
        // A passphrase is only meaningful together with an identity-file
        // credential; this API receives one vault entry and must not mistake
        // the secret text for a filesystem path.
        .passphrase => error.UnsupportedCredentialKind,
        .otp => error.UnsupportedCredentialKind,
    };
}

test "vault auth maps password credential" {
    var vault = Vault.init(std.testing.allocator);
    defer vault.deinit();
    const id = try vault.add(.password, "secret");
    const auth = try authFor(&vault, id, std.testing.allocator);
    defer switch (auth) {
        .password => |value| std.testing.allocator.free(value),
        else => {},
    };
    try std.testing.expectEqualStrings("secret", auth.password);
}
