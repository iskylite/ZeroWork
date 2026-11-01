//! Process/domain-owned public capabilities; windows borrow owner-scoped facades.
const std = @import("std");
const identity = @import("identity.zig");
const operations = @import("operation.zig");
const tls = @import("tls_trust.zig");
const secrets = @import("secret_lease.zig");
const actions = @import("resource_actions.zig");

pub const Services = struct {
    allocator: std.mem.Allocator,
    tls_store: tls.Store,
    pin_store: ?tls.FilePinStore = null,
    secret_store: secrets.Store,
    action_store: actions.Arbiter,

    pub fn init(allocator: std.mem.Allocator) Services {
        return .{ .allocator = allocator, .tls_store = tls.Store.init(allocator, tls.Verifier.native(), null), .secret_store = secrets.Store.init(allocator), .action_store = actions.Arbiter.init(allocator) };
    }

    /// Configure once, at a stable address before exposing the first facade.
    /// FilePinStore owns its path; the platform backend performs safe atomic IO.
    pub fn configurePins(self: *Services, absolute_directory: []const u8) !void {
        if (self.pin_store) |*store| {
            if (!std.mem.eql(u8, store.directory, absolute_directory)) return error.TrustDataDomainChanged;
            return;
        }
        self.pin_store = try tls.FilePinStore.init(self.allocator, absolute_directory);
        self.tls_store.pins = self.pin_store.?.backend();
    }

    pub fn deinit(self: *Services) void {
        self.tls_store.deinit();
        self.secret_store.deinit();
        self.action_store.deinit();
        if (self.pin_store) |*store| store.deinit();
    }

    pub fn revokeOwner(self: *Services, owner: identity.SessionHandle) void {
        self.tls_store.cancelOwner(owner);
        self.secret_store.revokeOwner(owner);
        self.action_store.releaseOwner(owner);
    }

    /// Called with validated, frozen contribution references by the host only.
    pub fn authorizeReferences(self: *Services, owner: identity.SessionHandle, operation: operations.OperationKey, references: []const []const u8) !void {
        if (references.len > 16) return error.CredentialReferenceLimit;
        for (references) |reference| try self.secret_store.authorize(owner, operation, reference);
    }
};
