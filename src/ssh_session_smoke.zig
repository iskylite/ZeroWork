const std = @import("std");
const ssh = @import("proto/ssh/session.zig");

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    const host: [:0]const u8 = if (args.len > 1) args[1] else "127.0.0.1";
    const user: [:0]const u8 = if (args.len > 2) args[2] else "root";
    const password_raw = std.process.getEnvVarOwned(allocator, "ZEROWORK_SSH_PASSWORD") catch null;
    defer if (password_raw) |value| allocator.free(value);
    const password = if (password_raw) |value| try allocator.dupeZ(u8, value) else null;
    defer if (password) |value| allocator.free(value);
    const use_agent = std.process.hasEnvVarConstant("ZEROWORK_SSH_AGENT");
    if (!use_agent and password == null) return error.MissingCredential;

    var library = try ssh.Library.init();
    defer library.deinit();
    var session = try ssh.Session.connect(&library, .{
        .host = host,
        .user = user,
        .auth = if (use_agent) .agent else .{ .password = password.? },
        .cols = 100,
        .rows = 30,
    });
    defer session.close();
    try session.resize(110, 35);

    var writer = try session.writer();
    const command = "printf zerowork-zig-session-ok; exit\n";
    var sent: usize = 0;
    while (sent < command.len) {
        const count = try writer.write(command[sent..]);
        if (count == 0) {
            std.Thread.sleep(10 * std.time.ns_per_ms);
            continue;
        }
        sent += count;
    }

    var reader = try session.reader();
    var output: [8192]u8 = undefined;
    var used: usize = 0;
    var idle: usize = 0;
    while (used < output.len and idle < 500) {
        const count = switch (try reader.read(output[used..])) {
            .eof => break,
            .would_block => {
                idle += 1;
                std.Thread.sleep(10 * std.time.ns_per_ms);
                continue;
            },
            .bytes => |count| count,
        };
        used += count;
        idle = 0;
        if (std.mem.indexOf(u8, output[0..used], "zerowork-zig-session-ok") != null) break;
    }
    if (std.mem.indexOf(u8, output[0..used], "zerowork-zig-session-ok") == null) return error.MarkerMissing;
    std.debug.print("{s}\n", .{output[0..used]});
}
