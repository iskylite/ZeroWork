//! Credential references are declared by a connection contribution, never found
//! by searching arbitrary payload bytes. A provider is borrowed for one call.
const std = @import("std");
const hosts = @import("hosts.zig");
const credentials = @import("credential_store.zig");

/// The caller owns the returned slice and each reference string.
pub const Enumerator = *const fn (std.mem.Allocator, []const u8) anyerror![]const []const u8;

/// Resolve only a contribution which understands this exact payload version.
/// No process-global registry is retained; an unloaded domain cannot affect a
/// later domain's cleanup decisions.
pub const Provider = struct {
    context: *const anyopaque,
    resolve: *const fn (*const anyopaque, []const u8, u32) ?Enumerator,
};

pub const CleanupStatus = enum { complete, deferred };

/// An owned, deduplicated union. Incomplete enumeration makes all deletion
/// unsafe, even when some of the references could be read successfully.
pub const References = struct {
    allocator: std.mem.Allocator,
    items: std.ArrayList([]const u8) = .empty,
    status: CleanupStatus = .complete,

    pub fn init(allocator: std.mem.Allocator) References {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *References) void {
        for (self.items.items) |reference| self.allocator.free(reference);
        self.items.deinit(self.allocator);
    }

    pub fn deferCleanup(self: *References) void {
        self.status = .deferred;
    }

    pub fn contains(self: *const References, reference: []const u8) bool {
        for (self.items.items) |item| if (std.mem.eql(u8, item, reference)) return true;
        return false;
    }

    pub fn add(self: *References, reference: []const u8) !void {
        if (!credentials.validReference(reference)) {
            self.deferCleanup();
            return;
        }
        if (self.contains(reference)) return;
        const copy = try self.allocator.dupe(u8, reference);
        errdefer self.allocator.free(copy);
        try self.items.append(self.allocator, copy);
    }

    pub fn addRegistry(self: *References, registry: *const hosts.Registry, provider: ?Provider) !void {
        for (registry.hosts) |host| try self.addHost(host, provider);
    }

    pub fn addHost(self: *References, host: hosts.HostConfig, provider: ?Provider) !void {
        inline for (.{ "password_ref", "key_passphrase_ref", "totp_secret_ref" }) |field| {
            if (@field(host, field)) |reference| try self.add(reference);
        }
        // The old, structured SSH/SFTP format needs no plugin contribution.
        if (host.isLegacy() and host.payload_version == 1 and host.plugin_payload == null) return;
        const payload = host.plugin_payload orelse {
            self.deferCleanup();
            return;
        };
        const selected = provider orelse {
            self.deferCleanup();
            return;
        };
        const enumerate = selected.resolve(selected.context, host.protocolId(), host.payload_version) orelse {
            self.deferCleanup();
            return;
        };
        const references = enumerate(self.allocator, payload) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                self.deferCleanup();
                return;
            },
        };
        defer self.allocator.free(references);
        defer for (references) |reference| self.allocator.free(reference);
        for (references) |reference| try self.add(reference);
    }
};
