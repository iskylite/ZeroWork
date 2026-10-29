const std = @import("std");
const cleanup = @import("host/record_cleanup.zig");
const archive_mod = @import("vt/session_archive.zig");
const a = std.testing.allocator;
const io = std.testing.io;

fn archiveFor(dir: std.Io.Dir) archive_mod.Archive {
    return .{ .allocator = a, .io = io, .dir = dir };
}
fn addCast(dir: std.Io.Dir, id: u64, path: []const u8) !void {
    try dir.createDirPath(io, "logs/history");
    try dir.writeFile(io, .{ .sub_path = path, .data = "{\"version\":2}\n[0,\"o\",\"hello\"]\n" });
    var archive = archiveFor(dir);
    try archive.append(.{ .id = id, .started_ms = @intCast(id * 10), .ended_ms = @intCast(id * 10 + 1), .duration_ms = 1, .host = "saved", .user = "root", .cast_path = path });
}
fn rawFile(dir: std.Io.Dir, name: []const u8) !void {
    try dir.createDirPath(io, "logs");
    var bytes: [37]u8 = undefined;
    @memcpy(bytes[0..8], "ZWRAW001");
    std.mem.writeInt(u64, bytes[8..16], 1024, .little);
    std.mem.writeInt(u64, bytes[16..24], 5, .little);
    std.mem.writeInt(u64, bytes[24..32], 5, .little);
    @memcpy(bytes[32..], "hello");
    try dir.writeFile(io, .{ .sub_path = name, .data = &bytes });
}
fn exists(dir: std.Io.Dir, path: []const u8) bool {
    _ = dir.statFile(io, path, .{ .follow_symlinks = false }) catch return false;
    return true;
}
fn complete(controller: *cleanup.Controller) !cleanup.Progress {
    var receipt = controller.progress();
    while (controller.running) receipt = try controller.step(false);
    return receipt;
}
fn indexCount(dir: std.Io.Dir) !usize {
    var archive = archiveFor(dir);
    var entries = try archive.load(a);
    defer archive.freeEntries(&entries);
    return entries.items.len;
}

test "record cleanup active gate and cancelled frozen plan never mutate files" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try addCast(tmp.dir, 1, "logs/history/a.cast");
    try std.testing.expectError(error.LiveSessionActive, cleanup.Controller.freeze(a, io, tmp.dir, true));
    var plan = try cleanup.Controller.freeze(a, io, tmp.dir, false);
    defer plan.deinit();
    try std.testing.expectError(error.LiveSessionActive, plan.begin(true));
    try std.testing.expect(exists(tmp.dir, "logs/history/a.cast"));
    try std.testing.expectEqual(@as(usize, 1), try indexCount(tmp.dir));
    try std.testing.expect(!plan.running);
}

test "record cleanup deletes only recognized output and checkpoint preserves diagnostics and user files" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try addCast(tmp.dir, 1, "logs/history/a.cast");
    try rawFile(tmp.dir, "logs/session-12-34-56.raw");
    try tmp.dir.writeFile(io, .{ .sub_path = "logs/session-12-34-56.checkpoint", .data = &(@as([24]u8, @splat(0))) });
    for ([_][]const u8{ "hosts.toml", "settings.toml", "logs/app-current.log", "logs/history/user-original.txt", "logs/session-12-34-57.raw", "logs/session-12-34-56.snapshot", "logs/not-a-record.raw" }) |path|
        try tmp.dir.writeFile(io, .{ .sub_path = path, .data = "must stay" });
    var plan = try cleanup.Controller.freeze(a, io, tmp.dir, false);
    defer plan.deinit();
    try plan.begin(false);
    const receipt = try complete(&plan);
    try std.testing.expectEqual(@as(usize, 2), receipt.deleted);
    try std.testing.expectEqual(@as(usize, 0), receipt.failed);
    try std.testing.expect(!exists(tmp.dir, "logs/history/a.cast"));
    try std.testing.expect(!exists(tmp.dir, "logs/session-12-34-56.raw"));
    try std.testing.expect(!exists(tmp.dir, "logs/session-12-34-56.checkpoint"));
    for ([_][]const u8{ "hosts.toml", "settings.toml", "logs/app-current.log", "logs/history/user-original.txt", "logs/session-12-34-57.raw", "logs/session-12-34-56.snapshot", "logs/not-a-record.raw" }) |path|
        try std.testing.expect(exists(tmp.dir, path));
    try std.testing.expectEqual(@as(usize, 0), try indexCount(tmp.dir));
}

test "record cleanup frozen scope preserves later records and corrupt index bytes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try addCast(tmp.dir, 1, "logs/history/a.cast");
    var plan = try cleanup.Controller.freeze(a, io, tmp.dir, false);
    defer plan.deinit();
    try addCast(tmp.dir, 2, "logs/history/new.cast");
    try rawFile(tmp.dir, "logs/session-20-30-40.raw");
    const index = try tmp.dir.readFileAlloc(io, "logs/history/index.tsv", a, .limited(4096));
    defer a.free(index);
    const with_tail = try std.mem.concat(a, u8, &.{ index, "partial\tnew-tail" });
    defer a.free(with_tail);
    try tmp.dir.writeFile(io, .{ .sub_path = "logs/history/index.tsv", .data = with_tail });
    try plan.begin(false);
    _ = try complete(&plan);
    try std.testing.expect(exists(tmp.dir, "logs/history/new.cast"));
    try std.testing.expect(exists(tmp.dir, "logs/session-20-30-40.raw"));
    try std.testing.expectEqual(@as(usize, 1), try indexCount(tmp.dir));
    const after = try tmp.dir.readFileAlloc(io, "logs/history/index.tsv", a, .limited(4096));
    defer a.free(after);
    try std.testing.expect(std.mem.endsWith(u8, after, "partial\tnew-tail"));
}

test "record cleanup reference failure retains index and retry targets only original failed IDs" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try addCast(tmp.dir, 1, "logs/history/busy.cast");
    try addCast(tmp.dir, 2, "logs/history/ok.cast");
    var lease = try archive_mod.acquireLease(a, io, tmp.dir, "logs/history/busy.cast");
    defer lease.deinit();
    var plan = try cleanup.Controller.freeze(a, io, tmp.dir, false);
    defer plan.deinit();
    try plan.begin(false);
    try std.testing.expectError(error.CleanupAlreadyRunning, plan.retryFailed(false));
    const first = try complete(&plan);
    try std.testing.expectEqual(@as(usize, 1), first.deleted);
    try std.testing.expectEqual(@as(usize, 1), first.failed);
    try std.testing.expectEqual(error.RecordBusy, plan.firstFailure().?);
    try std.testing.expect(exists(tmp.dir, "logs/history/busy.cast"));
    try std.testing.expectEqual(@as(usize, 1), try indexCount(tmp.dir));
    try addCast(tmp.dir, 3, "logs/history/new.cast");
    lease.deinit();
    try plan.retryFailed(false);
    const second = try complete(&plan);
    try std.testing.expectEqual(@as(usize, 2), second.deleted);
    try std.testing.expectEqual(@as(usize, 0), second.failed);
    try std.testing.expect(exists(tmp.dir, "logs/history/new.cast"));
    try std.testing.expectEqual(@as(usize, 1), try indexCount(tmp.dir));
}

test "record cleanup missing file after index failure remains retryable without scope expansion" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try addCast(tmp.dir, 1, "logs/history/a.cast");
    var plan = try cleanup.Controller.freeze(a, io, tmp.dir, false);
    defer plan.deinit();
    try tmp.dir.rename("logs/history/index.tsv", tmp.dir, "logs/history/index.backup", io);
    try tmp.dir.createDir(io, "logs/history/index.tsv", .default_dir);
    try plan.begin(false);
    const first = try complete(&plan);
    try std.testing.expectEqual(@as(usize, 1), first.failed);
    try std.testing.expect(!exists(tmp.dir, "logs/history/a.cast"));
    try std.testing.expect(plan.records.items[0].files.items[0].removed);
    try tmp.dir.deleteDir(io, "logs/history/index.tsv");
    try tmp.dir.rename("logs/history/index.backup", tmp.dir, "logs/history/index.tsv", io);
    try std.testing.expectEqual(@as(usize, 1), try indexCount(tmp.dir));
    try addCast(tmp.dir, 2, "logs/history/new.cast");
    try plan.retryFailed(false);
    const second = try complete(&plan);
    try std.testing.expectEqual(@as(usize, 1), second.deleted);
    try std.testing.expectEqual(@as(usize, 0), second.failed);
    try std.testing.expect(exists(tmp.dir, "logs/history/new.cast"));
    try std.testing.expectEqual(@as(usize, 1), try indexCount(tmp.dir));
}

test "record cleanup rejects same-path replacement and preserves the original index entry" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try addCast(tmp.dir, 1, "logs/history/a.cast");
    var plan = try cleanup.Controller.freeze(a, io, tmp.dir, false);
    defer plan.deinit();
    try tmp.dir.rename("logs/history/a.cast", tmp.dir, "logs/history/original.cast", io);
    try tmp.dir.writeFile(io, .{ .sub_path = "logs/history/a.cast", .data = "unrelated replacement" });
    try plan.begin(false);
    const receipt = try complete(&plan);
    try std.testing.expectEqual(@as(usize, 1), receipt.failed);
    try std.testing.expectEqual(error.RecordingChanged, plan.firstFailure().?);
    try std.testing.expect(exists(tmp.dir, "logs/history/a.cast"));
    try std.testing.expectEqual(@as(usize, 1), try indexCount(tmp.dir));
}

test "record cleanup checkpoint reference blocks its raw pair before either is removed" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try rawFile(tmp.dir, "logs/session-1-2-3.raw");
    try tmp.dir.writeFile(io, .{ .sub_path = "logs/session-1-2-3.checkpoint", .data = &(@as([24]u8, @splat(0))) });
    var lease = try archive_mod.acquireLease(a, io, tmp.dir, "logs/session-1-2-3.checkpoint");
    defer lease.deinit();
    var plan = try cleanup.Controller.freeze(a, io, tmp.dir, false);
    defer plan.deinit();
    try plan.begin(false);
    _ = try complete(&plan);
    try std.testing.expectEqual(error.RecordBusy, plan.firstFailure().?);
    try std.testing.expect(exists(tmp.dir, "logs/session-1-2-3.raw"));
    try std.testing.expect(exists(tmp.dir, "logs/session-1-2-3.checkpoint"));
}

test "record cleanup local cast and raw keep one frozen recording and all-path lease" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try addCast(tmp.dir, 1, "logs/history/session-local-1-2-3-4.cast");
    try rawFile(tmp.dir, "logs/session-local-1-2-3-4.raw");
    var plan = try cleanup.Controller.freeze(a, io, tmp.dir, false);
    defer plan.deinit();
    try std.testing.expectEqual(@as(usize, 1), plan.records.items.len);
    try std.testing.expectEqual(@as(usize, 2), plan.records.items[0].files.items.len);
    try plan.begin(false);
    _ = try complete(&plan);
    try std.testing.expect(!exists(tmp.dir, "logs/history/session-local-1-2-3-4.cast"));
    try std.testing.expect(!exists(tmp.dir, "logs/session-local-1-2-3-4.raw"));
}

test "record cleanup a new active session stops pending work and retries the frozen set" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try addCast(tmp.dir, 1, "logs/history/a.cast");
    var plan = try cleanup.Controller.freeze(a, io, tmp.dir, false);
    defer plan.deinit();
    try plan.begin(false);
    const receipt = try plan.step(true);
    try std.testing.expectEqual(@as(usize, 1), receipt.failed);
    try std.testing.expectEqual(error.LiveSessionActive, plan.firstFailure().?);
    try std.testing.expect(exists(tmp.dir, "logs/history/a.cast"));
    try std.testing.expectError(error.LiveSessionActive, plan.retryFailed(true));
    try addCast(tmp.dir, 2, "logs/history/new.cast");
    try plan.retryFailed(false);
    _ = try complete(&plan);
    try std.testing.expect(exists(tmp.dir, "logs/history/new.cast"));
}

test "record cleanup missing source is diagnostic failure rather than false successful index removal" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try addCast(tmp.dir, 1, "logs/history/a.cast");
    var plan = try cleanup.Controller.freeze(a, io, tmp.dir, false);
    defer plan.deinit();
    try tmp.dir.deleteFile(io, "logs/history/a.cast");
    try plan.begin(false);
    const receipt = try complete(&plan);
    try std.testing.expectEqual(@as(usize, 0), receipt.deleted);
    try std.testing.expectEqual(@as(usize, 1), receipt.failed);
    try std.testing.expectEqual(error.RecordingMissing, plan.firstFailure().?);
    try std.testing.expectEqual(@as(usize, 1), try indexCount(tmp.dir));
}

test "record cleanup Local snapshot is grouped and a cast read lease blocks every sidecar" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cast = "logs/history/session-local-11-22-33-44.cast";
    const raw = "logs/session-local-11-22-33-44.raw";
    const snapshot = "logs/session-local-11-22-33-44.checkpoint";
    try addCast(tmp.dir, 1, cast);
    try rawFile(tmp.dir, raw);
    try tmp.dir.writeFile(io, .{ .sub_path = snapshot, .data = "GHOSTSNP-application-snapshot-fixture" });
    var lease = try archive_mod.acquireLease(a, io, tmp.dir, cast);
    defer lease.deinit();
    var plan = try cleanup.Controller.freeze(a, io, tmp.dir, false);
    defer plan.deinit();
    try std.testing.expectEqual(@as(usize, 1), plan.records.items.len);
    try std.testing.expectEqual(@as(usize, 3), plan.records.items[0].files.items.len);
    try plan.begin(false);
    const first = try complete(&plan);
    try std.testing.expectEqual(@as(usize, 1), first.failed);
    for ([_][]const u8{ cast, raw, snapshot }) |path| try std.testing.expect(exists(tmp.dir, path));
    lease.deinit();
    try plan.retryFailed(false);
    const second = try complete(&plan);
    try std.testing.expectEqual(@as(usize, 1), second.deleted);
    for ([_][]const u8{ cast, raw, snapshot }) |path| try std.testing.expect(!exists(tmp.dir, path));
}

test "record cleanup frozen enumeration releases all resources on allocation failure" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try addCast(tmp.dir, 1, "logs/history/session-local-11-22-33-44.cast");
    try rawFile(tmp.dir, "logs/session-local-11-22-33-44.raw");
    try tmp.dir.writeFile(io, .{ .sub_path = "logs/session-local-11-22-33-44.checkpoint", .data = "GHOSTSNP-application-snapshot-fixture" });
    const Check = struct {
        fn run(allocator: std.mem.Allocator, dir: std.Io.Dir) !void {
            var plan = try cleanup.Controller.freeze(allocator, io, dir, false);
            defer plan.deinit();
            try std.testing.expectEqual(@as(usize, 1), plan.records.items.len);
        }
    };
    try std.testing.checkAllAllocationFailures(a, Check.run, .{tmp.dir});
    try std.testing.expect(exists(tmp.dir, "logs/history/session-local-11-22-33-44.cast"));
}

test "record cleanup never follows a recording symlink or a replaced history directory" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try addCast(tmp.dir, 1, "logs/history/a.cast");
    try tmp.dir.writeFile(io, .{ .sub_path = "user-original.txt", .data = "user bytes stay" });
    try tmp.dir.deleteFile(io, "logs/history/a.cast");
    try tmp.dir.symLink(io, "../../user-original.txt", "logs/history/a.cast", .{});
    var linked_plan = try cleanup.Controller.freeze(a, io, tmp.dir, false);
    defer linked_plan.deinit();
    try linked_plan.begin(false);
    const linked = try complete(&linked_plan);
    try std.testing.expectEqual(@as(usize, 1), linked.failed);
    try std.testing.expect(exists(tmp.dir, "user-original.txt"));
    try std.testing.expectEqual(@as(usize, 1), try indexCount(tmp.dir));
    try tmp.dir.deleteFile(io, "logs/history/a.cast");
    try tmp.dir.writeFile(io, .{ .sub_path = "logs/history/a.cast", .data = "real recording" });
    var replaced_plan = try cleanup.Controller.freeze(a, io, tmp.dir, false);
    defer replaced_plan.deinit();
    try tmp.dir.rename("logs/history", tmp.dir, "history-original", io);
    try tmp.dir.symLink(io, "../history-original", "logs/history", .{ .is_directory = true });
    try replaced_plan.begin(false);
    const replaced = try complete(&replaced_plan);
    try std.testing.expectEqual(@as(usize, 1), replaced.failed);
    try std.testing.expect(exists(tmp.dir, "history-original/a.cast"));
    const bytes = try tmp.dir.readFileAlloc(io, "user-original.txt", a, .limited(64));
    defer a.free(bytes);
    try std.testing.expectEqualStrings("user bytes stay", bytes);
}

test "record cleanup manifest group waits for reader then commits a shared tombstone" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cast_path = "logs/history/session-local-11-22-33-44.cast";
    const raw_path = "logs/session-local-11-22-33-44.raw";
    const sidecar = "logs/history/session-local-11-22-33-44.session.json";
    try addCast(tmp.dir, 1, cast_path);
    try rawFile(tmp.dir, raw_path);
    const manifest = archive_mod.manifest;
    const cast = try manifest.openManaged(io, tmp.dir, cast_path);
    defer cast.close(io);
    const raw = try manifest.openManaged(io, tmp.dir, raw_path);
    defer raw.close(io);
    const cast_stat = try cast.stat(io);
    const raw_stat = try raw.stat(io);
    const cast_checksum = try manifest.fingerprint(io, cast, cast_stat.size);
    const raw_checksum = try manifest.fingerprint(io, raw, raw_stat.size);
    const generation: manifest.Generation = .{ .session_id = 1, .session_generation = 1, .initial_cols = 80, .initial_rows = 24, .receive_time_origin = 0 };
    try manifest.save(a, io, tmp.dir, sidecar, .{
        .archive_key = "11111111111111111111111111111111",
        .recording_id = "22222222222222222222222222222222",
        .source_kind = .local,
        .started_ms = 10,
        .ended_ms = 11,
        .state = .closed,
        .recording = .{ .generations = &.{generation} },
        .coverage = .complete,
        .files = &.{ .{ .path = cast_path, .kind = .cast, .committed_length = cast_stat.size, .checksum = &cast_checksum }, .{ .path = raw_path, .kind = .raw, .committed_length = raw_stat.size, .checksum = &raw_checksum } },
    });
    var archive = archiveFor(tmp.dir);
    var resolved = try archive.resolveRecord(a, .{ .recording_id = "22222222222222222222222222222222" });
    defer resolved.deinit();
    var group = try archive.acquireRecord(a, resolved.descriptor);
    defer group.deinit();
    var plan = try cleanup.Controller.freeze(a, io, tmp.dir, false);
    defer plan.deinit();
    try std.testing.expectEqual(@as(usize, 1), plan.records.items.len);
    try plan.begin(false);
    try std.testing.expectEqual(@as(usize, 1), (try complete(&plan)).failed);
    try std.testing.expect(exists(tmp.dir, cast_path) and exists(tmp.dir, raw_path));
    group.deinit();
    try plan.retryFailed(false);
    try std.testing.expectEqual(@as(usize, 1), (try complete(&plan)).deleted);
    try std.testing.expect(!exists(tmp.dir, cast_path) and !exists(tmp.dir, raw_path));
    try std.testing.expect(exists(tmp.dir, sidecar));
    try std.testing.expectError(error.RecordRemoved, archive.resolveRecord(a, .{ .archive_key = "11111111111111111111111111111111" }));
    const tombstone = try manifest.load(a, io, tmp.dir, sidecar);
    defer tombstone.deinit();
    try std.testing.expectEqualStrings("UserRemoved", tombstone.value.failure.?);
    try std.testing.expectEqual(@as(usize, 0), try indexCount(tmp.dir));
}

test "record cleanup metadata-only unrecorded entry commits removal without inventing a cast" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var archive = archiveFor(tmp.dir);
    const ids = archive_mod.MetadataIdentity.generate();
    const id = std.fmt.bytesToHex(ids.recording_id.bytes, .lower);
    const publication: archive_mod.MetadataPublication = .{ .identity = ids, .owner = .{ .session_id = @fromBackingInt(7) }, .source_kind = .local, .started_ms = 1, .ended_ms = 2, .initial_cols = 80, .initial_rows = 24, .display = .{ .title = "not recorded" }, .reason = .RecordingDisabled };
    _ = try archive.publishMetadata(publication);
    var plan = try cleanup.Controller.freeze(a, io, tmp.dir, false);
    defer plan.deinit();
    try std.testing.expectEqual(@as(usize, 1), plan.records.items.len);
    try std.testing.expectEqual(@as(usize, 0), plan.records.items[0].files.items.len);
    try plan.begin(false);
    const receipt = try complete(&plan);
    try std.testing.expectEqual(@as(usize, 1), receipt.deleted);
    try std.testing.expectEqual(@as(usize, 0), receipt.failed);
    try std.testing.expectError(error.RecordRemoved, archive.resolveRecord(a, .{ .recording_id = &id }));
    try std.testing.expect((try archive.publishMetadata(publication)).removed);
    try std.testing.expectEqual(@as(usize, 0), try indexCount(tmp.dir));
}
