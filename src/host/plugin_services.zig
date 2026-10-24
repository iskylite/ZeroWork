//! Open, versioned service identities. Legacy ServiceKind is only an engine bridge.
const std = @import("std");
const identity = @import("identity.zig");

pub const ServiceKey = struct {
    name: []const u8,
    major: u32 = 1,
    pub fn eql(a: ServiceKey, b: ServiceKey) bool {
        return a.major == b.major and std.mem.eql(u8, a.name, b.name);
    }
};
pub const TypeToken = *const anyopaque;
pub fn typeToken(comptime Interface: type) TypeToken {
    return &struct {
        var marker: u8 = 0;
        const Keep = Interface;
    }.marker;
}
pub const Definition = struct {
    key: ServiceKey,
    type_token: TypeToken,
    pub fn of(comptime Interface: type, key: ServiceKey) Definition {
        return .{ .key = key, .type_token = typeToken(Interface) };
    }
    pub fn matches(a: Definition, b: Definition) bool {
        return a.key.eql(b.key) and a.type_token == b.type_token;
    }
};
pub const Requirement = Definition;
pub const Unavailable = struct { reason: []const u8, revision: u64 };
pub const Binding = struct {
    definition: Definition,
    context: *anyopaque,
    vtable: *const anyopaque,
    owner: identity.SessionHandle,
    generation: u64,
    revision: u64 = 1,
    authorized: bool = true,

    pub fn init(comptime Interface: type, key: ServiceKey, context: *anyopaque, vtable: *const Interface, owner: identity.SessionHandle, revision: u64) Binding {
        return .{ .definition = Definition.of(Interface, key), .context = context, .vtable = vtable, .owner = owner, .generation = owner.generation, .revision = revision };
    }
    pub fn borrow(self: Binding, comptime Interface: type, key: ServiceKey, owner: identity.SessionHandle) !*const Interface {
        if (!self.owner.eql(owner) or self.generation != owner.generation) return error.StaleBinding;
        if (!self.definition.key.eql(key)) return error.ServiceVersionMismatch;
        if (self.definition.type_token != typeToken(Interface)) return error.ServiceTypeMismatch;
        if (!self.authorized) return error.ServiceDenied;
        return @ptrCast(@alignCast(self.vtable));
    }
};
pub fn Query(comptime Interface: type) type {
    return union(enum) {
        available: struct { context: *anyopaque, vtable: *const Interface, binding: Binding },
        unsupported,
        temporarily_unavailable: Unavailable,
        denied: Unavailable,
    };
}

test "typed service token version and owner cannot be substituted" {
    const Read = struct { read: *const fn (*anyopaque) void };
    const Write = struct { write: *const fn (*anyopaque) void };
    const Noop = struct {
        fn run(_: *anyopaque) void {}
    };
    var context: u8 = 0;
    const owner: identity.SessionHandle = .{ .session_id = @fromBackingInt(1) };
    const binding = Binding.init(Read, .{ .name = "fixture.read" }, &context, &.{ .read = Noop.run }, owner, 1);
    _ = try binding.borrow(Read, .{ .name = "fixture.read" }, owner);
    try std.testing.expectError(error.ServiceTypeMismatch, binding.borrow(Write, .{ .name = "fixture.read" }, owner));
    try std.testing.expectError(error.ServiceVersionMismatch, binding.borrow(Read, .{ .name = "fixture.read", .major = 2 }, owner));
    try std.testing.expectError(error.StaleBinding, binding.borrow(Read, .{ .name = "fixture.read" }, try owner.nextGeneration()));
}
