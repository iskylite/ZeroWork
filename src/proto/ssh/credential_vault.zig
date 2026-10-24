const std = @import("std");

pub const Kind = enum { password, private_key, passphrase, otp };
pub const Credential = struct { id: u32, kind: Kind, value: []u8, refs: u32 = 1 };
pub const Vault = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayList(Credential) = .empty,
    next_id: u32 = 1,

    pub fn init(allocator: std.mem.Allocator) Vault {
        return .{ .allocator = allocator };
    }
    pub fn deinit(self: *Vault) void {
        for (self.entries.items) |credential| {
            @memset(credential.value, 0);
            self.allocator.free(credential.value);
        }
        self.entries.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn add(self: *Vault, kind: Kind, value: []const u8) !u32 {
        const owned = try self.allocator.dupe(u8, value);
        errdefer self.allocator.free(owned);
        const id = self.next_id;
        self.next_id += 1;
        try self.entries.append(self.allocator, .{ .id = id, .kind = kind, .value = owned });
        return id;
    }

    pub fn retain(self: *Vault, id: u32) !void {
        const credential = self.find(id) orelse return error.UnknownCredential;
        credential.refs += 1;
    }

    pub fn release(self: *Vault, id: u32) !void {
        const index = self.indexOf(id) orelse return error.UnknownCredential;
        if (self.entries.items[index].refs > 1) {
            self.entries.items[index].refs -= 1;
            return;
        }
        @memset(self.entries.items[index].value, 0);
        self.allocator.free(self.entries.items[index].value);
        _ = self.entries.orderedRemove(index);
    }

    pub fn get(self: *Vault, id: u32) ![]const u8 {
        return (self.find(id) orelse return error.UnknownCredential).value;
    }

    pub fn entry(self: *Vault, id: u32) ?*Credential {
        return self.find(id);
    }

    pub fn refs(self: *Vault, id: u32) !u32 {
        return (self.find(id) orelse return error.UnknownCredential).refs;
    }

    fn find(self: *Vault, id: u32) ?*Credential {
        for (self.entries.items) |*credential| if (credential.id == id) return credential;
        return null;
    }
    fn indexOf(self: *Vault, id: u32) ?usize {
        for (self.entries.items, 0..) |credential, index| if (credential.id == id) return index;
        return null;
    }
};

test "credential vault retains for duplicate and releases securely" {
    var vault = Vault.init(std.testing.allocator);
    defer vault.deinit();
    const id = try vault.add(.password, "secret");
    try vault.retain(id);
    try std.testing.expectEqual(@as(u32, 2), try vault.refs(id));
    try std.testing.expectEqualStrings("secret", try vault.get(id));
    try vault.release(id);
    try vault.release(id);
    try std.testing.expectError(error.UnknownCredential, vault.get(id));
}
