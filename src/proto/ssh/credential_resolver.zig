const std = @import("std");
const Vault = @import("credential_vault.zig").Vault;
const CredentialResolver = @import("hop_supervisor.zig").Supervisor.CredentialResolver;

pub fn resolver(_: *Vault) CredentialResolver {
    return resolve;
}

fn resolve(ctx: *anyopaque, id: u32) ![]const u8 {
    const vault: *Vault = @ptrCast(@alignCast(ctx));
    return vault.get(id);
}

test "vault adapter resolves hop credential ids" {
    var vault = Vault.init(@import("std").testing.allocator);
    defer vault.deinit();
    const id = try vault.add(.password, "secret");
    const value = try resolver(&vault)(&vault, id);
    try @import("std").testing.expectEqualStrings("secret", value);
}
