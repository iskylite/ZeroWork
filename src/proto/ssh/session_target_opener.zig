const std = @import("std");
const Session = @import("session.zig").Session;
const socks = @import("socks5.zig");

pub const Opener = struct {
    session: *Session,
    allocator: std.mem.Allocator,
    close_channel: ?@import("channel.zig").Channel = null,

    pub fn callback(ctx: *anyopaque, request: socks.ConnectRequest) !socks.ConnectResponse {
        const self: *Opener = @ptrCast(@alignCast(ctx));
        const opened_channel = try self.openChannel(request);
        // The direct channel is retained by the orchestration owner. This
        // callback only reports a successful target; it must not close it.
        self.close_channel = opened_channel;
        return .{ .reply = .succeeded, .address = .{ .ipv4 = .{ 0, 0, 0, 0 } }, .port = 0 };
    }

    fn openChannel(self: *Opener, request: socks.ConnectRequest) !@import("channel.zig").Channel {
        const host = try socks.addressHost(self.allocator, request.address);
        defer self.allocator.free(host);
        return self.session.openDirectTcpip(host, request.port);
    }

    pub fn retainedChannel(self: *Opener) ?*@import("channel.zig").Channel {
        if (self.close_channel) |*retained| return retained;
        return null;
    }

    pub fn release(self: *Opener) void {
        if (self.close_channel) |*retained| self.session.closeChannel(retained);
        self.close_channel = null;
    }

    /// Construct the target-side reader/writer pair for RelayPump. The returned
    /// adapters borrow the retained channel; the opener must outlive the pump.
    pub fn relayAdapters(self: *Opener) !struct { reader: @import("../../vt/worker_io.zig").ChannelReader, writer: @import("../../vt/channel_pump.zig").ChannelWriter } {
        const channel = self.retainedChannel() orelse return error.TargetChannelUnavailable;
        return .{ .reader = channel.reader(), .writer = channel.writer() };
    }
};

test "opener rejects inactive session before allocating a tunnel" {
    var session: Session = .{};
    var opener: Opener = .{ .session = &session, .allocator = std.testing.allocator };
    try std.testing.expectError(error.SessionNotActive, Opener.callback(&opener, .{ .command = .connect, .address = .{ .domain = "db" }, .port = 5432 }));
}
