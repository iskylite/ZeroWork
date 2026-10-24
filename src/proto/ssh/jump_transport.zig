//! Real channel-backed multi-hop transport. Options are borrowed during init;
//! sessions and relay owners remain alive until reverse-order teardown.
const std = @import("std");
const ssh = @import("session.zig");
const sockets = @import("socket_relay.zig");
const c = @import("generated_ssh_session");
const Channel = @import("channel.zig").Channel;
const Forward = @import("forward_service.zig").Service;

pub const Route = struct {
    allocator: std.mem.Allocator,
    hops: []Hop,
    initialized: usize = 0,
    resource_ledger: ?*ssh.ResourceLedger = null,
    pub const Hop = struct {
        session: ssh.Session,
        channel: ?Channel = null,
        relay: ?*sockets.Relay = null,
        forward: ?*Forward = null,
    };

    /// Includes final target. All earlier entries authenticate without shell.
    /// Each options entry must carry its own host-key policy/observer.
    pub fn connect(allocator: std.mem.Allocator, library: *const ssh.Library, options: []const ssh.Options) !*Route {
        return connectWithForwards(allocator, library, options, &.{});
    }
    /// Borrow stable controller facades; every upstream Relay remains its
    /// Session's sole native owner. The caller owns facades through teardown.
    pub fn connectWithForwards(allocator: std.mem.Allocator, library: *const ssh.Library, options: []const ssh.Options, forwards: []const ?*Forward) !*Route {
        if (options.len < 2 or options.len > 9) return error.InvalidJumpRoute;
        if (forwards.len != 0 and forwards.len != options.len) return error.InvalidForwardRoute;
        // Use the same route contract as configuration validation before any IO.
        const plan_mod = @import("hop_plan.zig");
        var hops: [9]plan_mod.Hop = undefined;
        for (options, 0..) |option, i| hops[i] = .{ .host = option.host, .port = option.port, .user = option.user };
        try (plan_mod.Plan{ .hops = hops[0..options.len] }).validate();
        for (options, 0..) |option, index| {
            if (option.resource_ledger != options[0].resource_ledger) return error.InvalidResourceOwner;
            if (option.resource_ledger) |ledger| {
                if (!ledger.accepts(option.operation_key, index, options.len)) return error.InvalidResourceOwner;
            }
            try option.prepareDetails();
        }
        const self = try allocator.create(Route);
        var retained = false;
        errdefer if (!retained) allocator.destroy(self);
        self.* = .{ .allocator = allocator, .hops = try allocator.alloc(Hop, options.len), .resource_ledger = options[0].resource_ledger };
        errdefer {
            if (self.closeReceipt() != .released) {
                if (self.resource_ledger) |ledger| {
                    retained = ledger.retainRoute(self);
                }
                if (!retained) {
                    // Legacy callers without an attempt ledger still cannot
                    // claim a native graph was freed when it was not.
                    retained = true;
                    std.log.err("SSH route rollback retains incomplete cleanup", .{});
                }
            }
            if (!retained) allocator.free(self.hops);
        }
        for (options, 0..) |original, i| {
            var current = original;
            current.hop_index = i;
            current.hop_count = options.len;
            current.open_shell = i + 1 == options.len and original.open_shell;
            const session = if (i == 0)
                try ssh.Session.connect(library, current)
            else blk: {
                const parent = &self.hops[i - 1];
                // No concurrent calls on parent Session until the channel is
                // opened; afterwards its relay is the sole libssh2 owner.
                if (current.cancel_token) |token| if (token.load(.acquire)) {
                    current.report(.tunnel, .cancelled, error.Cancelled);
                    return error.Cancelled;
                };
                current.report(.tunnel, .started, null);
                // This phase targets the next hop. Attribute forwarding failures
                // to that edge, rather than reporting a generic target failure.
                parent.session.setBlocking();
                parent.channel = parent.session.openDirectTcpip(current.host, current.port) catch |err| {
                    current.report(.tunnel, .failed, err);
                    return err;
                };
                c.zw_libssh2_session_nonblocking(parent.session.handle.?);
                const pair = sockets.Pair.create() catch |err| {
                    current.report(.tunnel, .failed, err);
                    return err;
                };
                current.recordResource(.transport, .owned);
                parent.session.recordResource(.relay_socket, .owned);
                parent.relay = sockets.Relay.startSessionWithForward(allocator, pair.relay_fd, &parent.channel.?, &parent.session, parent.forward) catch |err| {
                    parent.session.recordResource(.relay_socket, .released);
                    current.recordResource(.transport, .releasing);
                    c.zw_ssh_socket_close(pair.target_fd);
                    current.recordResource(.transport, .released);
                    current.report(.tunnel, .failed, err);
                    return err;
                };
                parent.session.recordResource(.relay_worker, .owned);
                current.report(.tunnel, .succeeded, null);
                break :blk try ssh.Session.connectOverFd(library, current, pair.target_fd);
            };
            self.hops[i] = .{ .session = session, .forward = if (forwards.len == 0) null else forwards[i] };
            self.initialized += 1;
        }
        return self;
    }

    pub fn target(self: *Route) *ssh.Session {
        return &self.hops[self.initialized - 1].session;
    }
    pub fn bindForwards(self: *Route, forwards: []const ?*Forward) void {
        std.debug.assert(forwards.len == self.hops.len);
        for (self.hops, forwards) |*hop, forward| {
            hop.forward = forward;
            if (hop.relay) |relay| if (forward) |value| relay.bindForward(value);
        }
    }
    /// Used only by an explicit detailed test. Parent transports keep their
    /// relay IO owners; this thread drives the final target and observes copies.
    pub fn measureRtt(self: *Route, timeout_ms: u32, cancelled: ?*const std.atomic.Value(bool)) !void {
        const session = self.target();
        const store = session.connection_details orelse return error.DetailsUnavailable;
        const key = session.resource_key orelse return error.MissingOperation;
        const request = try store.request(key, null, timeout_ms);
        try session.driveRtt(request, true, cancelled);
    }
    /// Transfer final Session to the worker, retain all parent hops/relays.
    pub fn takeTarget(self: *Route) ssh.Session {
        self.initialized -= 1;
        return self.hops[self.initialized].session;
    }
    pub fn close(self: *Route) void {
        _ = self.closeReceipt();
    }
    pub fn closeReceipt(self: *Route) ssh.ReleaseReceipt {
        while (self.initialized > 0) {
            const index = self.initialized - 1;
            // A taken target or a failed downstream Session may still be held
            // by its original owner. Never release its parent out of order.
            if (self.resource_ledger) |ledger| {
                const resources = ledger.snapshot();
                for (index + 1..resources.hop_count) |downstream| {
                    for (resources.resources[downstream]) |resource| {
                        if (resource.state == .unknown) return .unknown;
                        if (resource.state != .absent and resource.state != .released) return .awaiting;
                    }
                }
            }
            const hop = &self.hops[index];
            if (hop.relay) |relay| {
                hop.session.recordResource(.relay_worker, .releasing);
                hop.session.recordResource(.relay_socket, .releasing);
                relay.deinit();
                hop.session.recordResource(.relay_worker, .released);
                hop.session.recordResource(.relay_socket, .released);
            }
            hop.relay = null;
            if (hop.forward) |forward| {
                // The relay has joined. Its native retries/buffers move as one
                // owner graph; no UI/controller thread touches the Session.
                forward.adoptIoAfterOwnerStopped();
                forward.transportLost() catch return .unknown;
            }
            if (hop.channel) |*channel| {
                const receipt = hop.session.closeChannelReceipt(channel);
                if (receipt == .released) hop.channel = null;
            }
            // This is whole-hop teardown. If an individual channel is still
            // awaiting its peer, the parent can abort its own transport and
            // actually free all children without disturbing another session.
            const receipt = hop.session.closeReceipt();
            if (receipt != .released) return receipt;
            if (hop.forward) |forward| forward.sessionReleased() catch return .unknown;
            hop.channel = null;
            self.initialized -= 1;
        }
        return .released;
    }
    pub fn deinit(self: *Route) void {
        if (self.closeReceipt() != .released) {
            if (self.resource_ledger) |ledger| if (ledger.retainRoute(self)) return;
            // An incomplete graph is still owned. Do not turn an uncertain
            // native free into a deallocation/release receipt.
            std.log.err("SSH route cleanup did not release its resources", .{});
            return;
        }
        self.allocator.free(self.hops);
        self.allocator.destroy(self);
    }
};

test "jump transport rejects empty and single-entry routes before network" {
    var library: ssh.Library = .{ .active = false };
    try std.testing.expectError(error.InvalidJumpRoute, Route.connect(std.testing.allocator, &library, &.{}));
    try std.testing.expectError(error.InvalidJumpRoute, Route.connect(std.testing.allocator, &library, &.{.{ .host = "target", .user = "u", .auth = .agent }}));
}

test "jump transport shares route validation before attempting a network connection" {
    const library: ssh.Library = .{ .active = false };
    const options = [_]ssh.Options{
        .{ .host = "edge", .user = "ops", .auth = .agent },
        .{ .host = "edge", .user = "other", .auth = .agent },
    };
    try std.testing.expectError(error.RouteCycle, Route.connect(std.testing.allocator, &library, &options));
}
