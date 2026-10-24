const std = @import("std");
const Command = @import("builtin_commands.zig").Command;
const Timeline = @import("../vt/timeline.zig").Timeline;
const catalog = @import("command_catalog.zig");

pub const default_log_path = "logs/session.log";
pub const help_text = "@up @dl @ai @new @dup @grp @pin @sync @ts @log @socks @theme @help @@";
pub const HelpEntry = catalog.Entry;

pub const Context = struct {
    io: std.Io,
    dir: std.Io.Dir,
    timeline: *Timeline,
};

pub fn helpEntries() []const HelpEntry {
    return &catalog.entries;
}

pub fn formatHelp(_: std.mem.Allocator, buffer: []u8) ![]const u8 {
    var writer = std.Io.Writer.fixed(buffer);
    for (catalog.entries, 0..) |entry, index| {
        if (index != 0) try writer.writeByte('\n');
        try writer.print("{s}  {s} — {s}", .{ entry.name, entry.usage, entry.description });
    }
    return writer.buffered();
}

pub const Result = union(enum) {
    replay,
    saved_log: []const u8,
    passthrough: []const u8,
    unsupported,
};

/// Executes local commands that have a complete worker-independent boundary.
/// Other builtins remain available to their pane/group dispatchers.
pub fn execute(command: Command, context: Context) !Result {
    _ = context;
    return switch (command) {
        .help => .{ .passthrough = help_text },
        .log => .replay,
        .not_command => |line| .{ .passthrough = line },
        else => .unsupported,
    };
}

pub fn exportLog(context: Context, path: []const u8) !Result {
    try validateRelativePath(path);
    try context.timeline.save(context.io, context.dir, path);
    return .{ .saved_log = path };
}

fn validateRelativePath(path: []const u8) !void {
    if (path.len == 0 or path[0] == '/') return error.InvalidLogPath;
    var components = std.mem.splitScalar(u8, path, '/');
    while (components.next()) |component| {
        if (component.len == 0 or std.mem.eql(u8, component, ".") or std.mem.eql(u8, component, "..")) return error.InvalidLogPath;
    }
}

test "formatted help renders every local command" {
    var buffer: [1024]u8 = undefined;
    const text = try formatHelp(std.testing.allocator, &buffer);
    try std.testing.expect(std.mem.indexOf(u8, text, "@help  @help") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "@sync  @sync") != null);
}

test "help entries mirror local command catalog" {
    const entries = helpEntries();
    try std.testing.expectEqual(@as(usize, 14), entries.len);
    try std.testing.expect(catalog.find("@help") != null);
    try std.testing.expect(catalog.find("@sync") != null);
    try std.testing.expect(catalog.find("@@") != null);
}

test "log command saves timeline to requested path" {
    var timeline = try Timeline.init(std.testing.allocator, 4, 64);
    defer timeline.deinit();
    try timeline.append(42, 0, "ready\n");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const result = try exportLog(.{ .io = std.testing.io, .dir = tmp.dir, .timeline = &timeline }, "exports/session.log");
    try std.testing.expectEqualStrings("exports/session.log", result.saved_log);
    const content = try tmp.dir.readFileAlloc(std.testing.io, "exports/session.log", std.testing.allocator, .limited(256));
    defer std.testing.allocator.free(content);
    try std.testing.expectEqualStrings("[42] offset=0 ready\\n\n", content);
}

test "log command uses private default path and rejects traversal" {
    var timeline = try Timeline.init(std.testing.allocator, 1, 8);
    defer timeline.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const context: Context = .{ .io = std.testing.io, .dir = tmp.dir, .timeline = &timeline };
    try std.testing.expectEqual(Result.replay, try execute(.{ .log = null }, context));
    const result = try exportLog(context, default_log_path);
    try std.testing.expectEqualStrings(default_log_path, result.saved_log);
    try std.testing.expectError(error.InvalidLogPath, exportLog(context, "../secret"));
}
