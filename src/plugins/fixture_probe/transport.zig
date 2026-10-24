//! Fixture extension: two streams on one independently owned transport facade.
//! This file never imports a native SSH/session/forward implementation.
const std = @import("std");
const identity = @import("../../host/identity.zig");
const config = @import("../../host/connection_config_resolver.zig");
const transport = @import("../../host/transport_factory.zig");
pub const Pair = struct {
    owned: *transport.OwnedTransport,
    observation: transport.OwnedStream,
    management: transport.OwnedStream,
    closed: bool = false,
    /// Resolve/freeze is done before calling this and is retained by the
    /// transport. Every call obtains a fresh IO owner and two stream queues.
    pub fn open(factory: transport.Factory, owner: identity.SessionHandle, route: *const config.FrozenRoute, destination: transport.Destination, cancel: ?*const std.atomic.Value(bool)) !Pair {
        const owned = try factory.openOwned(.{ .session = owner }, route, .connection, cancel);
        errdefer {
            _ = owned.adoptFailedOpen() catch {};
        }
        var observation = try owned.openTcpStream(destination);
        errdefer observation.close();
        const management = try owned.openTcpStream(destination);
        return .{ .owned = owned, .observation = observation, .management = management };
    }
    /// The main-thread host already froze credential references; this consumes
    /// the prepared owner and performs network work on the fixture worker.
    pub fn openPrepared(owned: *transport.OwnedTransport, destination: transport.Destination) !Pair {
        var cleanup: transport.ReleaseReceipt = .released;
        return openPreparedWithReceipt(owned, destination, &cleanup);
    }
    pub fn openPreparedWithReceipt(owned: *transport.OwnedTransport, destination: transport.Destination, cleanup: *transport.ReleaseReceipt) !Pair {
        errdefer {
            cleanup.* = owned.adoptFailedOpen() catch .unknown;
        }
        try owned.start();
        var observation = try owned.openTcpStream(destination);
        errdefer observation.close();
        const management = try owned.openTcpStream(destination);
        return .{ .owned = owned, .observation = observation, .management = management };
    }
    pub fn close(self: *Pair) transport.ReleaseReceipt {
        if (!self.closed) {
            self.observation.close();
            self.management.close();
            self.closed = true;
        }
        return self.owned.close();
    }
    pub fn deinit(self: *Pair) !void {
        _ = self.close();
        try self.owned.deinit();
        self.* = undefined;
    }
};
