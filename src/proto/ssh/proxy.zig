const std = @import("std");
const socks = @import("socks5.zig");
const Plan = @import("hop_plan.zig").Plan;

pub const State = enum { idle, handshaking, opening_target, replying, relaying, closed, failed };

pub const Proxy = struct {
    plan: Plan,
    state: State = .idle,
    request: ?socks.ConnectRequest = null,
    response: ?socks.ConnectResponse = null,

    pub fn init(plan: Plan) !Proxy {
        try plan.validate();
        return .{ .plan = plan };
    }

    pub fn beginHandshake(self: *Proxy) !void {
        if (self.state != .idle) return error.InvalidTransition;
        self.state = .handshaking;
    }

    pub fn targetRequested(self: *Proxy, request: socks.ConnectRequest) !void {
        if (self.state != .handshaking) return error.InvalidTransition;
        if (request.command != .connect) return error.UnsupportedCommand;
        self.request = request;
        self.state = .opening_target;
    }

    pub fn target(self: Proxy) ?socks.ConnectRequest {
        return self.request;
    }

    pub fn bindResponse(self: Proxy) ?socks.ConnectResponse {
        return self.response;
    }

    pub const TargetOpener = *const fn (*anyopaque, socks.ConnectRequest) anyerror!socks.ConnectResponse;

    /// Invoke the transport-specific target opener and record its bind response.
    /// The callback is where Session.openDirectTcpip or a future SOCKS egress
    /// implementation is injected; this layer owns only lifecycle transitions.
    pub fn openTarget(self: *Proxy, opener: TargetOpener, ctx: *anyopaque) !socks.ConnectResponse {
        if (self.state != .opening_target) return error.InvalidTransition;
        const request = self.request orelse return error.MissingTarget;
        const response = opener(ctx, request) catch |err| {
            self.state = .failed;
            return err;
        };
        try self.targetOpened(response);
        return response;
    }

    pub fn targetOpened(self: *Proxy, response: socks.ConnectResponse) !void {
        if (self.state != .opening_target) return error.InvalidTransition;
        self.response = response;
        self.state = .replying;
    }

    pub fn replySent(self: *Proxy) !void {
        if (self.state != .replying) return error.InvalidTransition;
        if (self.response.?.reply != .succeeded) {
            self.state = .failed;
            return;
        }
        self.state = .relaying;
    }

    pub fn close(self: *Proxy) void {
        self.state = .closed;
    }
    pub fn fail(self: *Proxy) void {
        self.state = .failed;
    }
};

const OpenContext = struct {
    calls: usize = 0,
    fn open(ctx: *anyopaque, request: @import("socks5.zig").ConnectRequest) !@import("socks5.zig").ConnectResponse {
        const self: *OpenContext = @ptrCast(@alignCast(ctx));
        self.calls += 1;
        return .{ .reply = .succeeded, .port = request.port };
    }
};

test "proxy opener callback records target response" {
    const hops = [_]@import("hop_plan.zig").Hop{.{ .host = "edge", .user = "ops" }};
    var proxy = try Proxy.init(.{ .hops = &hops });
    try proxy.beginHandshake();
    try proxy.targetRequested(.{ .command = .connect, .address = .{ .domain = "db" }, .port = 5432 });
    var context: OpenContext = .{};
    const response = try proxy.openTarget(OpenContext.open, &context);
    try std.testing.expectEqual(@as(usize, 1), context.calls);
    try std.testing.expectEqual(@as(u16, 5432), response.port);
    try std.testing.expectEqual(State.replying, proxy.state);
}

test "proxy orchestration marks target failure before relay" {
    const hops = [_]@import("hop_plan.zig").Hop{.{ .host = "edge", .user = "ops" }};
    var proxy = try Proxy.init(.{ .hops = &hops });
    try proxy.beginHandshake();
    try proxy.targetRequested(.{ .command = .connect, .address = .{ .domain = "db" }, .port = 5432 });
    try proxy.targetOpened(.{ .reply = .connection_refused });
    try proxy.replySent();
    try std.testing.expectEqual(State.failed, proxy.state);
}

test "proxy orchestration reaches relay after successful target" {
    const hops = [_]@import("hop_plan.zig").Hop{.{ .host = "edge", .user = "ops" }};
    var proxy = try Proxy.init(.{ .hops = &hops });
    try proxy.beginHandshake();
    try proxy.targetRequested(.{ .command = .connect, .address = .{ .domain = "db" }, .port = 5432 });
    try proxy.targetOpened(.{ .reply = .succeeded, .port = 5432 });
    try proxy.replySent();
    try std.testing.expectEqual(State.relaying, proxy.state);
}
