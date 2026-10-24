const std = @import("std");
const Interest = @import("../vt/worker_interest.zig").Interest;

pub const Filter = enum { read, write };
pub const Action = enum { enable, disable };
pub const Change = struct { filter: Filter, action: Action };

/// Produces the minimal EV_ENABLE/EV_DISABLE changes for one socket.
pub fn plan(previous: Interest, next: Interest, output: *[2]Change) []const Change {
    var count: usize = 0;
    if (previous.read != next.read) {
        output[count] = .{ .filter = .read, .action = if (next.read) .enable else .disable };
        count += 1;
    }
    if (previous.write != next.write) {
        output[count] = .{ .filter = .write, .action = if (next.write) .enable else .disable };
        count += 1;
    }
    return output[0..count];
}

pub fn encodeDarwin(fd: i32, changes: []const Change, output: *[2]std.posix.Kevent) []const std.posix.Kevent {
    for (changes, 0..) |change, index| output[index] = .{
        .ident = @intCast(fd),
        .filter = switch (change.filter) {
            .read => std.c.EVFILT.READ,
            .write => std.c.EVFILT.WRITE,
        },
        .flags = switch (change.action) {
            .enable => std.c.EV.ADD | std.c.EV.ENABLE,
            .disable => std.c.EV.DISABLE,
        },
        .fflags = 0,
        .data = 0,
        .udata = 0,
    };
    return output[0..changes.len];
}

test "kqueue plan emits only changed filters" {
    var changes: [2]Change = undefined;
    try std.testing.expectEqual(@as(usize, 0), plan(.{}, .{}, &changes).len);
    const enable_write = plan(.{}, .{ .write = true }, &changes);
    try std.testing.expectEqual(@as(usize, 1), enable_write.len);
    try std.testing.expectEqual(Filter.write, enable_write[0].filter);
    try std.testing.expectEqual(Action.enable, enable_write[0].action);
}

test "Darwin kevent encoder maps filters and actions" {
    var planned: [2]Change = undefined;
    const changes = plan(.{ .read = false, .write = false }, .{ .read = true, .write = true }, &planned);
    var events: [2]std.posix.Kevent = undefined;
    const encoded = encodeDarwin(42, changes, &events);
    try std.testing.expectEqual(@as(usize, 42), encoded[0].ident);
    try std.testing.expectEqual(@as(i16, std.c.EVFILT.READ), encoded[0].filter);
    try std.testing.expect(encoded[0].flags & std.c.EV.ADD != 0);
    try std.testing.expectEqual(@as(i16, std.c.EVFILT.WRITE), encoded[1].filter);
}

test "kqueue plan pauses and resumes socket reads" {
    var changes: [2]Change = undefined;
    const paused = plan(.{ .read = true, .write = true }, .{ .read = false, .write = true, .paused_for_ui = true }, &changes);
    try std.testing.expectEqual(@as(usize, 1), paused.len);
    try std.testing.expectEqual(Action.disable, paused[0].action);
    const resumed = plan(.{ .read = false, .write = true, .paused_for_ui = true }, .{ .read = true, .write = false }, &changes);
    try std.testing.expectEqual(@as(usize, 2), resumed.len);
}
