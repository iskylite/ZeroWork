const std = @import("std");
const Vault = @import("credential_vault.zig").Vault;
const Auth = @import("session.zig").Auth;
const authFor = @import("auth_from_vault.zig").authFor;

pub const OwnedAuth = struct {
    auth: Auth,
    allocator: std.mem.Allocator,

    pub fn init(vault: *Vault, id: u32, allocator: std.mem.Allocator) !OwnedAuth {
        return .{ .auth = try authFor(vault, id, allocator), .allocator = allocator };
    }

    pub fn deinit(self: *OwnedAuth) void {
        switch (self.auth) {
            .password => |value| self.allocator.free(value),
            .private_key => |key| {
                self.allocator.free(key.path);
                if (key.passphrase) |passphrase| self.allocator.free(passphrase);
            },
            .agent, .password_prompt => {},
            .keyboard_interactive => {},
        }
        self.* = undefined;
    }
};

test "owned auth releases duplicated password" {
    var vault = Vault.init(std.testing.allocator);
    defer vault.deinit();
    const id = try vault.add(.password, "secret");
    var owned = try OwnedAuth.init(&vault, id, std.testing.allocator);
    defer owned.deinit();
    try std.testing.expectEqualStrings("secret", owned.auth.password);
}
