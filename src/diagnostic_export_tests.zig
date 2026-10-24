const std = @import("std");
const Export = @import("host/diagnostic_export.zig");
const a = std.testing.allocator;
const io = std.testing.io;
const first = "app-20261021-090000.log";
const second = "app-20261021-090000.log.1";
const raw = "09:00:00.123 +0000001ms ERROR ssh] AuthenticationFailed host=private.example password=VERY_SECRET_API_KEY\n" ++
    "AI_QUESTION_AND_TERMINAL_BODY_SHOULD_NEVER_LEAVE\n" ++
    "09:00:00.124 +0000002ms INFO  ai] prompt=TOP_SECRET_COMMAND\n";

fn fixture(dir: std.Io.Dir) !void {
    try dir.createDirPath(io, "logs");
    try dir.writeFile(io, .{ .sub_path = "logs/" ++ first, .data = raw });
    try dir.writeFile(io, .{ .sub_path = "logs/" ++ second, .data = "08:00:00.000 +0000000ms INFO  app] old process started\n" });
    for ([_][]const u8{ "session.raw", "session.cast", "session.checkpoint", "hosts.toml", "config.toml", "history.json", "app-not-a-producer.log" }) |name| {
        const file_path = try std.fs.path.join(a, &.{ "logs", name });
        defer a.free(file_path);
        try dir.writeFile(io, .{ .sub_path = file_path, .data = "FORBIDDEN_SESSION_OR_CONFIGURATION_CONTENT" });
    }
}
fn path(dir: std.Io.Dir, name: []const u8) ![]u8 {
    const parent = try dir.realPathFileAlloc(io, ".", a);
    defer a.free(parent);
    return std.fs.path.join(a, &.{ parent, name });
}
fn tar(args: []const []const u8) ![]u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(a);
    try argv.append(a, "/usr/bin/tar");
    try argv.appendSlice(a, args);
    const result = try std.process.run(a, io, .{ .argv = argv.items, .stdout_limit = .limited(1024 * 1024), .stderr_limit = .limited(16 * 1024) });
    a.free(result.stderr);
    if (!result.term.success()) {
        a.free(result.stdout);
        return error.TestArchiveInspectionFailed;
    }
    return result.stdout;
}
fn cancelled(raw_context: ?*anyopaque) bool {
    const count: *CancelAt = @ptrCast(@alignCast(raw_context.?));
    count.calls += 1;
    return count.calls >= count.at;
}
const CancelAt = struct { calls: usize = 0, at: usize };

test "diagnostic export actual gzip tar contains only redacted application files and safe manifest" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try fixture(tmp.dir);
    try tmp.dir.writeFile(io, .{ .sub_path = "outside-secret", .data = "OUTSIDE_SYMLINK_SECRET" });
    try tmp.dir.symLink(io, "../outside-secret", "logs/app-20261021-100000.log", .{});
    const data = try path(tmp.dir, ".");
    defer a.free(data);
    var plan = try Export.Plan.capture(a, io, data, .{ .operation_id = 71 });
    defer plan.deinit();
    try std.testing.expectEqual(@as(usize, 2), plan.files.items.len);
    const destination = try path(tmp.dir, "diagnostics.tar.gz");
    defer a.free(destination);
    try plan.write(destination, .{});
    const names = try tar(&.{ "-tzf", destination });
    defer a.free(names);
    try std.testing.expectEqualStrings("manifest.json\ndiagnostics/" ++ first ++ "\ndiagnostics/" ++ second ++ "\n", names);
    const bytes = try tar(&.{ "-xOzf", destination });
    defer a.free(bytes);
    for ([_][]const u8{ "VERY_SECRET_API_KEY", "private.example", "TOP_SECRET_COMMAND", "AI_QUESTION", "FORBIDDEN_SESSION", "OUTSIDE_SYMLINK_SECRET", data }) |secret| try std.testing.expect(std.mem.indexOf(u8, bytes, secret) == null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "AuthenticationFailed") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "09:00:00.123") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "redaction_policy_revision") != null);
    const original = try tmp.dir.readFileAlloc(io, "logs/" ++ first, a, .unlimited);
    defer a.free(original);
    try std.testing.expectEqualStrings(raw, original);
    const published = try std.Io.Dir.cwd().statFile(io, destination, .{});
    try std.testing.expectEqual(@as(u32, 0o600), @as(u32, @intCast(@backingInt(published.permissions))) & 0o777);
}

test "diagnostic export picker delay cannot expand frozen content or follow rotated same name" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try fixture(tmp.dir);
    const data = try path(tmp.dir, ".");
    defer a.free(data);
    var plan = try Export.Plan.capture(a, io, data, .{ .operation_id = 72 });
    defer plan.deinit();
    // Real subsequent append and rotation. No new pathname may substitute for
    // the held descriptors or immutable redacted bytes captured before picker.
    const opened = try tmp.dir.openFile(io, "logs/" ++ first, .{ .mode = .write_only });
    defer opened.close(io);
    try opened.writePositionalAll(io, "23:59:59.999 +0000999ms ERROR app] LATE_APPEND\n", raw.len);
    try tmp.dir.rename("logs/" ++ first, tmp.dir, "logs/rotated-captured.log", io);
    try tmp.dir.writeFile(io, .{ .sub_path = "logs/" ++ first, .data = "22:22:22.222 +0000222ms ERROR app] SAME_NAME_REPLACEMENT\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "logs/app-20261021-110000.log", .data = "21:21:21.111 +0000111ms INFO app] NEW_FILE\n" });
    const destination = try path(tmp.dir, "frozen.tar.gz");
    defer a.free(destination);
    try plan.write(destination, .{});
    const bytes = try tar(&.{ "-xOzf", destination });
    defer a.free(bytes);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "09:00:00.123") != null);
    for ([_][]const u8{ "23:59:59.999", "22:22:22.222", "21:21:21.111", "app-20261021-110000.log" }) |late| try std.testing.expect(std.mem.indexOf(u8, bytes, late) == null);
    try std.testing.expectEqual(@as(u64, raw.len), plan.files.items[0].frozen_bytes);
    const source = try plan.files.items[0].handle.stat(io);
    try std.testing.expectEqual(plan.files.items[0].identity.inode, source.inode);
}

test "diagnostic export cancellation during write or immediately before publish preserves old target and removes temp" {
    for ([_]usize{ 3, 4 }) |cancel_at| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try fixture(tmp.dir);
        try tmp.dir.writeFile(io, .{ .sub_path = "existing.tar.gz", .data = "OLD_USER_ARTIFACT" });
        const data = try path(tmp.dir, ".");
        defer a.free(data);
        var plan = try Export.Plan.capture(a, io, data, .{ .operation_id = 73 });
        defer plan.deinit();
        const destination = try path(tmp.dir, "existing.tar.gz");
        defer a.free(destination);
        var cancel: CancelAt = .{ .at = cancel_at };
        try std.testing.expectError(error.Cancelled, plan.write(destination, .{ .context = &cancel, .is_cancelled = cancelled }));
        try std.testing.expectEqual(if (cancel_at == 4) Export.Stage.publish else Export.Stage.write, plan.failure.stage);
        const kept = try tmp.dir.readFileAlloc(io, "existing.tar.gz", a, .unlimited);
        defer a.free(kept);
        try std.testing.expectEqualStrings("OLD_USER_ARTIFACT", kept);
        var listing = try tmp.dir.openDir(io, ".", .{ .iterate = true });
        defer listing.close(io);
        var entries = listing.iterate();
        while (try entries.next(io)) |entry| try std.testing.expect(std.mem.eql(u8, entry.name, "logs") or std.mem.eql(u8, entry.name, "existing.tar.gz"));
    }
}

test "diagnostic export empty and cancelled capture never create a fallback session package" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "logs");
    try tmp.dir.writeFile(io, .{ .sub_path = "logs/session.cast", .data = "SESSION_ONLY" });
    const data = try path(tmp.dir, ".");
    defer a.free(data);
    try std.testing.expectError(error.NoDiagnosticLogs, Export.Plan.capture(a, io, data, .{ .operation_id = 74 }));
    var cancel: CancelAt = .{ .at = 1 };
    try std.testing.expectError(error.Cancelled, Export.Plan.capture(a, io, data, .{ .operation_id = 75, .cancel = .{ .context = &cancel, .is_cancelled = cancelled } }));
    try std.testing.expectError(error.InvalidDiagnosticOperation, Export.Plan.capture(a, io, data, .{ .operation_id = 0 }));
    try std.testing.expectError(error.InvalidDiagnosticDirectory, Export.Plan.capture(a, io, "relative", .{ .operation_id = 1 }));
}

test "diagnostic export rejects source destinations and missing parents without changing any records" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try fixture(tmp.dir);
    const data = try path(tmp.dir, ".");
    defer a.free(data);
    var plan = try Export.Plan.capture(a, io, data, .{ .operation_id = 76 });
    defer plan.deinit();
    const original = try path(tmp.dir, "logs/" ++ first);
    defer a.free(original);
    try std.testing.expectError(error.DiagnosticTargetInsideSource, plan.write(original, .{}));
    const missing = try path(tmp.dir, "missing/export.tar.gz");
    defer a.free(missing);
    try std.testing.expectError(error.FileNotFound, plan.write(missing, .{}));
    const bytes = try tmp.dir.readFileAlloc(io, "logs/" ++ first, a, .unlimited);
    defer a.free(bytes);
    try std.testing.expectEqualStrings(raw, bytes);
}

test "diagnostic export allocation failures release captured names content and file descriptors" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try fixture(tmp.dir);
    const data = try path(tmp.dir, ".");
    defer a.free(data);
    const Scenario = struct {
        fn run(allocator: std.mem.Allocator, directory: []const u8) !void {
            var plan = try Export.Plan.capture(allocator, io, directory, .{ .operation_id = 77 });
            defer plan.deinit();
        }
    };
    try std.testing.checkAllAllocationFailures(a, Scenario.run, .{data});
}

test "diagnostic export producer filename filter rejects secrets paths and session recordings" {
    for ([_][]const u8{ first, second, "app-unknown.log", "app-unknown.log.1" }) |name| try std.testing.expect(Export.isDiagnosticName(name));
    for ([_][]const u8{ "session.raw", "session.cast", "app-secret.log", "../app-20261021-090000.log", "app-20261021-090000.log.1.1", "app-20261021-090000.log/secret", "app-abcdefgh-090000.log", "app-20261021-abcdef.log", "app-20261021-090000.log.2" }) |name| try std.testing.expect(!Export.isDiagnosticName(name));
}

test "diagnostic export resolves separate macOS log directory without session records" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "support/logs");
    try tmp.dir.createDirPath(io, "diagnostics");
    try tmp.dir.writeFile(io, .{ .sub_path = "support/logs/" ++ first, .data = "SESSION_MUST_NOT_EXPORT" });
    try tmp.dir.writeFile(io, .{ .sub_path = "diagnostics/" ++ first, .data = raw });
    const support = try path(tmp.dir, "support");
    defer a.free(support);
    const diagnostics = try path(tmp.dir, "diagnostics");
    defer a.free(diagnostics);
    var plan = try Export.Plan.capture(a, io, support, .{ .operation_id = 81, .diagnostic_directory = diagnostics });
    defer plan.deinit();
    try std.testing.expectEqual(@as(usize, 1), plan.files.items.len);
    try std.testing.expect(std.mem.indexOf(u8, plan.files.items[0].content, "AuthenticationFailed") != null);
    try std.testing.expect(std.mem.indexOf(u8, plan.files.items[0].content, "SESSION_MUST_NOT_EXPORT") == null);
}
