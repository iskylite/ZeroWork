const std = @import("std");

pub const max_hops: usize = 8;

pub const Hop = struct {
    host: []const u8,
    port: u16 = 22,
    user: []const u8,
    credential_id: ?u32 = null,
};

/// Immutable connection route consumed by the tunnel supervisor. The final
/// element is the destination; every preceding element is reached through a
/// direct-tcpip channel opened on the prior authenticated session.
pub const Plan = struct {
    hops: []const Hop,

    pub fn validate(self: Plan) !void {
        if (self.hops.len == 0) return error.EmptyRoute;
        if (self.hops.len > max_hops + 1) return error.TooManyHops;
        for (self.hops, 0..) |hop, index| {
            if (std.mem.trim(u8, hop.host, " \t\r\n").len == 0) return error.MissingHost;
            if (std.mem.trim(u8, hop.user, " \t\r\n").len == 0) return error.MissingUser;
            if (hop.port == 0) return error.InvalidPort;
            for (self.hops[0..index]) |previous| {
                if (previous.port == hop.port and std.mem.eql(u8, previous.host, hop.host)) return error.RouteCycle;
            }
        }
    }

    pub fn destination(self: Plan) Hop {
        return self.hops[self.hops.len - 1];
    }

    pub fn jumpCount(self: Plan) usize {
        return self.hops.len - 1;
    }
};

test "direct route has no jump and a destination" {
    const route = [_]Hop{.{ .host = "db.internal", .user = "ops" }};
    const plan: Plan = .{ .hops = &route };
    try plan.validate();
    try std.testing.expectEqual(@as(usize, 0), plan.jumpCount());
    try std.testing.expectEqualStrings("db.internal", plan.destination().host);
}

test "three hop route preserves terminal destination" {
    const route = [_]Hop{
        .{ .host = "edge", .user = "ops" },
        .{ .host = "bastion", .user = "ops" },
        .{ .host = "database", .port = 2222, .user = "dba" },
    };
    const plan: Plan = .{ .hops = &route };
    try plan.validate();
    try std.testing.expectEqual(@as(usize, 2), plan.jumpCount());
    try std.testing.expectEqual(@as(u16, 2222), plan.destination().port);
    try std.testing.expect(plan.destination().credential_id == null);
}

test "route validation rejects cycles and invalid endpoints" {
    const cycle = [_]Hop{
        .{ .host = "edge", .user = "ops" },
        .{ .host = "edge", .user = "root" },
    };
    try std.testing.expectError(error.RouteCycle, (Plan{ .hops = &cycle }).validate());
    const invalid = [_]Hop{.{ .host = "", .port = 0, .user = "" }};
    try std.testing.expectError(error.MissingHost, (Plan{ .hops = &invalid }).validate());
}
