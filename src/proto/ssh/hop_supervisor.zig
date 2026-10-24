const std = @import("std");
const Plan = @import("hop_plan.zig").Plan;

/// UI-independent lifecycle contract for a multi-hop tunnel supervisor.
/// Transport construction remains in the SSH worker; this state machine keeps
/// hop progress observable without pretending a channel is a TCP file descriptor.
pub const State = enum { idle, connecting, authenticated, tunneling, active, failed, closed };

pub const Supervisor = struct {
    plan: Plan,
    state: State = .idle,
    current_hop: usize = 0,
    failure: ?Failure = null,

    pub const Failure = struct { hop: usize, code: Code };
    pub const CredentialResolver = *const fn (*anyopaque, u32) anyerror![]const u8;

    pub fn credentialForCurrentHop(self: Supervisor, resolver: CredentialResolver, ctx: *anyopaque) !?[]const u8 {
        const credential_id = self.plan.hops[self.current_hop].credential_id orelse return null;
        return try resolver(ctx, credential_id);
    }

    pub const Code = enum { invalid_route, connect_failed, authentication_failed, tunnel_failed };

    pub fn init(plan: Plan) !Supervisor {
        try plan.validate();
        return .{ .plan = plan };
    }

    pub fn begin(self: *Supervisor) !void {
        if (self.state != .idle) return error.InvalidTransition;
        self.state = .connecting;
        self.current_hop = 0;
    }

    pub fn markAuthenticated(self: *Supervisor) !void {
        if (self.state != .connecting) return error.InvalidTransition;
        self.state = .authenticated;
    }

    pub fn markTunnelOpened(self: *Supervisor) !void {
        if (self.state != .authenticated) return error.InvalidTransition;
        self.state = .tunneling;
    }

    pub fn advanceHop(self: *Supervisor) !void {
        if (self.state != .tunneling) return error.InvalidTransition;
        if (self.current_hop + 1 >= self.plan.hops.len) {
            self.state = .active;
            return;
        }
        self.current_hop += 1;
        self.state = .connecting;
    }

    pub fn fail(self: *Supervisor, code: Code) void {
        self.failure = .{ .hop = self.current_hop, .code = code };
        self.state = .failed;
    }

    pub fn close(self: *Supervisor) void {
        self.state = .closed;
    }

    pub fn jumpCount(self: Supervisor) usize {
        return self.plan.jumpCount();
    }
};

const Resolver = struct {
    fn get(_: *anyopaque, id: u32) ![]const u8 {
        return if (id == 7) "secret" else error.UnknownCredential;
    }
};

test "supervisor resolves current hop credential id" {
    const hops = [_]@import("hop_plan.zig").Hop{.{ .host = "edge", .user = "ops", .credential_id = 7 }};
    const supervisor = try Supervisor.init(.{ .hops = &hops });
    const value = (try supervisor.credentialForCurrentHop(Resolver.get, undefined)).?;
    try std.testing.expectEqualStrings("secret", value);
}

test "supervisor walks a two-hop route" {
    const hops = [_]@import("hop_plan.zig").Hop{
        .{ .host = "bastion", .user = "ops" },
        .{ .host = "database", .port = 5432, .user = "dba" },
    };
    var supervisor = try Supervisor.init(.{ .hops = &hops });
    try supervisor.begin();
    try supervisor.markAuthenticated();
    try supervisor.markTunnelOpened();
    try supervisor.advanceHop();
    try std.testing.expectEqual(State.connecting, supervisor.state);
    try supervisor.markAuthenticated();
    try supervisor.markTunnelOpened();
    try supervisor.advanceHop();
    try std.testing.expectEqual(State.active, supervisor.state);
    try std.testing.expectEqual(@as(usize, 1), supervisor.jumpCount());
}

test "supervisor records the failing hop" {
    const hops = [_]@import("hop_plan.zig").Hop{.{ .host = "edge", .user = "ops" }};
    var supervisor = try Supervisor.init(.{ .hops = &hops });
    try supervisor.begin();
    supervisor.fail(.authentication_failed);
    try std.testing.expectEqual(State.failed, supervisor.state);
    try std.testing.expectEqual(@as(usize, 0), supervisor.failure.?.hop);
}
