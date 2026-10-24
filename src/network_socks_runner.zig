//! Controlled loopback-only runner for the real SOCKS listener + libssh2.
const std = @import("std");
const ssh = @import("proto/ssh/session.zig");
const socks = @import("proto/ssh/socks5_listener.zig");
const clock = @import("platform/realtime.zig");
const Trust = struct {
    fingerprint: []const u8,
    fn observe(raw: *anyopaque, host: []const u8, _: u16, value: ssh.HostKeyInfo) ssh.HostKeyDecision {
        const self: *Trust = @ptrCast(@alignCast(raw));
        return if (std.mem.eql(u8, host, "127.0.0.1") and std.mem.eql(u8, value.fingerprint, self.fingerprint)) .trust_once else .reject_unknown;
    }
};
fn pause() void {
    var empty: [1]std.c.pollfd = undefined;
    _ = std.c.poll(&empty, 0, 2);
}
pub fn main(init: std.process.Init) !void {
    var args = init.minimal.args.iterate();
    _ = args.next();
    const port = try std.fmt.parseInt(u16, args.next() orelse return error.MissingPort, 10);
    const fingerprint = args.next() orelse return error.MissingFingerprint;
    const controls = args.next() orelse return error.MissingControls;
    if (!std.mem.startsWith(u8, controls, "/")) return error.OwnedControlsRequired;
    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const known = try std.fs.path.join(a, &.{ controls, "known_hosts" });
    var store = try @import("proto/ssh/host_key_store.zig").HostKeyStore.load(init.io, std.Io.Dir.cwd(), init.gpa, known);
    defer store.deinit();
    var trust: Trust = .{ .fingerprint = fingerprint };
    var library = try ssh.Library.init();
    defer library.deinit();
    var session = try ssh.Session.connect(&library, .{ .host = "127.0.0.1", .port = port, .user = "socks-fixture", .auth = .{ .password = "local-controlled-only" }, .open_shell = false, .connect_timeout_ms = 2000, .host_key_store = &store, .host_key_observer = .{ .ctx = &trust, .callback = Trust.observe } });
    defer session.close();
    if (session.channel != null) return error.UnexpectedShell;
    // Match the actual application's existing dedicated SOCKS connect path.
    session.setBlocking();
    const listener = try socks.Socks5Listener.init(init.gpa, &session);
    defer listener.deinit();
    try listener.start(0);
    const ready = try std.fmt.allocPrint(a, "{{\"local_port\":{d}}}\n", .{listener.port()});
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = try std.fs.path.join(a, &.{ controls, "ready.json" }), .data = ready });
    const stop = try std.fs.path.join(a, &.{ controls, "stop" });
    const deadline = clock.monotonicNs() + 10 * std.time.ns_per_s;
    while (true) {
        std.Io.Dir.cwd().access(init.io, stop, .{}) catch |err| {
            if (err != error.FileNotFound) return err;
            if (clock.monotonicNs() >= deadline) return error.StopSignalTimeout;
            pause();
            continue;
        };
        break;
    }
    const started = clock.monotonicNs();
    listener.stop();
    const stopped_ms = @divTrunc(clock.monotonicNs() - started, std.time.ns_per_ms);
    const release_deadline = clock.monotonicNs() + 3 * std.time.ns_per_s;
    while (session.closeReceipt() != .released) {
        if (clock.monotonicNs() >= release_deadline) return error.TransportNotReleased;
        pause();
    }
    const stats = listener.stats();
    const report = try std.fmt.allocPrint(a, "{{\"stop_ms\":{d},\"bytes_up\":{d},\"bytes_down\":{d},\"active\":{d},\"transport_released\":true,\"shell_absent\":true}}\n", .{ stopped_ms, stats.bytes_up, stats.bytes_down, stats.connections_active });
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = try std.fs.path.join(a, &.{ controls, "runner-report.json" }), .data = report });
}
