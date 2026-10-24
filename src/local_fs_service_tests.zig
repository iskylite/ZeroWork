const std = @import("std");
const fs = @import("local/fs_service.zig");
const operations = @import("host/operation.zig");
const identity = @import("host/identity.zig");
const clock = @import("platform/realtime.zig");

const endpoint: fs.EndpointRef = .{ .binding_id = 901, .binding_generation = 4 };
fn pause() void {
    var unused: [1]std.c.pollfd = undefined;
    _ = std.c.poll(&unused, 0, 2);
}
fn stop(service: *fs.Service) void {
    service.requestClose();
    const deadline = clock.monotonicNs() + 5 * std.time.ns_per_s;
    while (service.closeReceipt() != .released) {
        if (clock.monotonicNs() >= deadline) @panic("local fs worker did not close");
        pause();
    }
    service.deinit() catch unreachable;
}
fn next(service: *fs.Service) !fs.OwnedResult {
    const deadline = clock.monotonicNs() + 5 * std.time.ns_per_s;
    while (true) {
        if (service.poll()) |result| return result;
        if (clock.monotonicNs() >= deadline) return error.TestTimeout;
        pause();
    }
}
fn request(service: *fs.Service, journal: *operations.Journal, path: []const u8, action: fs.Action) !fs.OwnedResult {
    const key = try journal.begin(.app, null);
    try service.submit(key, .{ .endpoint = endpoint, .request_id = key.operation_id, .directory_revision = 17, .path = path, .action = action });
    const result = try next(service);
    errdefer {
        var owned = result;
        owned.deinit();
    }
    try std.testing.expect(result.value.key.eql(key));
    try std.testing.expect(result.value.endpoint.eql(endpoint));
    try std.testing.expectEqual(@as(u64, 17), result.value.directory_revision);
    try std.testing.expectEqual(fs.ReleaseReceipt.released, result.value.cleanup);
    try std.testing.expect(result.value.final);
    return result;
}
fn expectFailure(service: *fs.Service, journal: *operations.Journal, path: []const u8, action: fs.Action, failure: fs.Failure) !void {
    var result = try request(service, journal, path, action);
    defer result.deinit();
    try std.testing.expectEqual(fs.Body{ .failure = failure }, result.value.body);
}

test "local fs native pages preserve raw names, symlinks, endpoint and frozen HOME/path" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "alpha.txt", .data = "abc" });
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "空格 文.txt", .data = "你好" });
    // APFS rejects invalid UTF-8 filenames; other local filesystems may expose
    // them. Keep the real filesystem's outcome and test byte display separately.
    const invalid_supported = if (temporary.dir.writeFile(std.testing.io, .{ .sub_path = "raw-\xff", .data = "z" })) true else |err| switch (err) {
        error.BadPathName => false,
        else => return err,
    };
    try temporary.dir.createDir(std.testing.io, "sub", .default_dir);
    try temporary.dir.symLink(std.testing.io, "alpha.txt", "alpha-link", .{});
    try temporary.dir.symLink(std.testing.io, "missing", "dangling", .{});
    const path = try temporary.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(path);
    const home = try std.testing.allocator.dupe(u8, path);
    const service = try fs.Service.start(std.testing.allocator, endpoint, .{ .home = home });
    @memset(home, 'x');
    std.testing.allocator.free(home);
    defer stop(service);
    var journal = operations.Journal.init(std.testing.allocator);
    defer journal.deinit();
    const key = try journal.begin(.app, null);
    const input = try std.testing.allocator.dupe(u8, "~/");
    const accepted = service.submit(key, .{ .endpoint = endpoint, .request_id = 71, .directory_revision = 23, .path = input, .action = .{ .list = .{ .page_entries = 2, .max_entries = 16 } } });
    @memset(input, 'x');
    std.testing.allocator.free(input);
    try accepted;
    var count: usize = 0;
    var page_index: u32 = 0;
    var invalid_name = false;
    var regular = false;
    var directory = false;
    var symlinks: usize = 0;
    while (true) {
        var result = try next(service);
        defer result.deinit();
        try std.testing.expect(result.value.key.eql(key));
        try std.testing.expect(result.value.endpoint.eql(endpoint));
        try std.testing.expectEqual(@as(u64, 71), result.value.request_id);
        try std.testing.expectEqual(@as(u64, 23), result.value.directory_revision);
        try std.testing.expectEqualStrings("~/", result.value.requested_path);
        try std.testing.expectEqualStrings(path, result.value.resolved_path.?);
        try std.testing.expect(result.value.body == .page);
        const page = result.value.body.page;
        try std.testing.expectEqual(page_index, page.index);
        try std.testing.expect(page.entries.len <= 2);
        for (page.entries) |entry| {
            count += 1;
            try std.testing.expect(std.unicode.utf8ValidateSlice(entry.display_name));
            try std.testing.expect(std.mem.startsWith(u8, entry.absolute_path, path));
            try std.testing.expect(std.mem.endsWith(u8, entry.absolute_path, entry.raw_name));
            if (std.mem.eql(u8, entry.raw_name, "alpha.txt")) {
                regular = true;
                try std.testing.expectEqual(.file, entry.attributes.kind);
                try std.testing.expectEqual(@as(?u64, 3), entry.attributes.size);
            } else if (std.mem.eql(u8, entry.raw_name, "sub")) {
                directory = true;
                try std.testing.expectEqual(.directory, entry.attributes.kind);
            } else if (std.mem.eql(u8, entry.raw_name, "alpha-link") or std.mem.eql(u8, entry.raw_name, "dangling")) {
                symlinks += 1;
                try std.testing.expectEqual(.symlink, entry.attributes.kind);
            } else if (std.mem.eql(u8, entry.raw_name, "raw-\xff")) {
                invalid_name = true;
                try std.testing.expectEqualStrings("raw-�", entry.display_name);
                try std.testing.expect(!std.mem.eql(u8, entry.raw_name, entry.display_name));
            }
        }
        try std.testing.expectEqual(if (result.value.final) fs.ReleaseReceipt.released else .awaiting, result.value.cleanup);
        if (result.value.final) break;
        page_index += 1;
    }
    try std.testing.expectEqual(@as(usize, 5) + @intFromBool(invalid_supported), count);
    try std.testing.expect(regular and directory);
    try std.testing.expectEqual(invalid_supported, invalid_name);
    try std.testing.expectEqual(@as(usize, 2), symlinks);
    var stat = try request(service, &journal, "~/alpha-link", .stat);
    defer stat.deinit();
    try std.testing.expectEqual(.symlink, stat.value.body.stat.kind);
    var realpath = try request(service, &journal, "~/sub/..", .realpath);
    defer realpath.deinit();
    try std.testing.expectEqualStrings(path, realpath.value.body.realpath);
    var empty = try request(service, &journal, "~/sub", .{ .list = .{} });
    defer empty.deinit();
    try std.testing.expectEqual(@as(usize, 0), empty.value.body.page.entries.len);
    try expectFailure(service, &journal, "~", .{ .list = .{ .max_entries = 1 } }, .entry_limit);
}

test "local fs bounded actual file reads reject binary, encoding, directory and device" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "empty", .data = "" });
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "text", .data = "hello" });
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "utf8", .data = "a你好" });
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "binary", .data = "a\x00b" });
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "bad", .data = "\xff" });
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "incomplete", .data = "a\xe4\xbd" });
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "bad-prefix", .data = "a\xe4x" });
    var large: [65538]u8 = @splat('a');
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "large", .data = &large });
    try temporary.dir.symLink(std.testing.io, "text", "link", .{});
    try temporary.dir.symLink(std.testing.io, "loop-b", "loop-a", .{});
    try temporary.dir.symLink(std.testing.io, "loop-a", "loop-b", .{});
    const home = try temporary.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(home);
    const service = try fs.Service.start(std.testing.allocator, endpoint, .{ .home = home });
    defer stop(service);
    var journal = operations.Journal.init(std.testing.allocator);
    defer journal.deinit();
    var empty = try request(service, &journal, "~/empty", .{ .read_text = .{} });
    defer empty.deinit();
    try std.testing.expectEqualStrings("", empty.value.body.text.text);
    try std.testing.expectEqual(@as(?u64, 0), empty.value.body.text.original_size);
    try std.testing.expectEqual(@as(usize, 0), empty.value.body.text.read_bytes);
    try std.testing.expect(!empty.value.body.text.truncated);
    var text = try request(service, &journal, "~/link", .{ .read_text = .{} });
    defer text.deinit();
    try std.testing.expectEqualStrings("hello", text.value.body.text.text);
    try std.testing.expect(std.mem.endsWith(u8, text.value.resolved_path.?, "/text"));
    try std.testing.expectEqualStrings("~/link", text.value.requested_path);
    try std.testing.expect(text.value.body.text.captured_at_ms > 1_500_000_000_000);
    var utf8 = try request(service, &journal, "~/utf8", .{ .read_text = .{ .max_bytes = 2 } });
    defer utf8.deinit();
    try std.testing.expectEqualStrings("a", utf8.value.body.text.text);
    try std.testing.expectEqual(@as(usize, 3), utf8.value.body.text.read_bytes);
    try std.testing.expect(utf8.value.body.text.truncated);
    var bounded = try request(service, &journal, "~/large", .{ .read_text = .{} });
    defer bounded.deinit();
    try std.testing.expectEqual(@as(usize, 4096), bounded.value.body.text.text.len);
    try std.testing.expectEqual(@as(usize, 4097), bounded.value.body.text.read_bytes);
    try std.testing.expect(bounded.value.body.text.truncated);
    var maximum = try request(service, &journal, "~/large", .{ .read_text = .{ .max_bytes = 65536 } });
    defer maximum.deinit();
    try std.testing.expectEqual(@as(usize, 65536), maximum.value.body.text.text.len);
    try std.testing.expectEqual(@as(usize, 65537), maximum.value.body.text.read_bytes);
    try std.testing.expect(maximum.value.body.text.truncated);
    try expectFailure(service, &journal, "~/binary", .{ .read_text = .{} }, .unsupported_binary);
    try expectFailure(service, &journal, "~/bad", .{ .read_text = .{} }, .unsupported_encoding);
    try expectFailure(service, &journal, "~/incomplete", .{ .read_text = .{} }, .unsupported_encoding);
    try expectFailure(service, &journal, "~/bad-prefix", .{ .read_text = .{ .max_bytes = 2 } }, .unsupported_encoding);
    try expectFailure(service, &journal, "~", .{ .read_text = .{} }, .not_regular_file);
    try expectFailure(service, &journal, "/dev/null", .{ .read_text = .{} }, .not_regular_file);
    try expectFailure(service, &journal, "~/loop-a", .{ .read_text = .{} }, .symlink_loop);
    try expectFailure(service, &journal, "~/missing", .stat, .not_found);
    try expectFailure(service, &journal, "~/text", .{ .list = .{} }, .not_directory);
}

test "local fs mkdir uses original explicit child, reports collision and permission without refresh" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDir(std.testing.io, "denied", .default_dir);
    var denied = try temporary.dir.openDir(std.testing.io, "denied", .{});
    defer denied.close(std.testing.io);
    try denied.writeFile(std.testing.io, .{ .sub_path = "unreadable", .data = "private" });
    var unreadable = try denied.openFile(std.testing.io, "unreadable", .{});
    defer unreadable.close(std.testing.io);
    try unreadable.setPermissions(std.testing.io, .fromMode(0));
    defer unreadable.setPermissions(std.testing.io, .fromMode(0o600)) catch unreachable;
    const home = try temporary.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(home);
    const service = try fs.Service.start(std.testing.allocator, endpoint, .{ .home = home });
    defer stop(service);
    var journal = operations.Journal.init(std.testing.allocator);
    defer journal.deinit();
    const key = try journal.begin(.app, null);
    const name = try std.testing.allocator.dupe(u8, "new 目录");
    const accepted = service.submit(key, .{ .endpoint = endpoint, .request_id = 11, .directory_revision = 3, .path = "~", .action = .{ .mkdir = .{ .name = name } } });
    @memset(name, 'x');
    std.testing.allocator.free(name);
    try accepted;
    var created = try next(service);
    defer created.deinit();
    try std.testing.expect(created.value.key.eql(key));
    try std.testing.expectEqual(@as(u64, 3), created.value.directory_revision);
    try std.testing.expect(created.value.final and created.value.cleanup == .released);
    try std.testing.expect(std.mem.endsWith(u8, created.value.body.created, "/new 目录"));
    const actual = try temporary.dir.statFile(std.testing.io, "new 目录", .{});
    try std.testing.expectEqual(.directory, actual.kind);
    try std.testing.expect(service.poll() == null); // No invented refresh success.
    try expectFailure(service, &journal, "~", .{ .mkdir = .{ .name = "new 目录" } }, .already_exists);
    try expectFailure(service, &journal, "~/denied/unreadable", .{ .read_text = .{} }, .permission_denied);
    for ([_][]const u8{ ".", "..", "nested/child" }) |invalid| {
        const rejected = try journal.begin(.app, null);
        try std.testing.expectError(error.InvalidName, service.submit(rejected, .{ .endpoint = endpoint, .request_id = rejected.operation_id, .path = "~", .action = .{ .mkdir = .{ .name = invalid } } }));
    }
    for ([_][]const u8{ "", "bad\x00name" }) |invalid| {
        const rejected = try journal.begin(.app, null);
        try std.testing.expectError(error.InvalidPath, service.submit(rejected, .{ .endpoint = endpoint, .request_id = rejected.operation_id, .path = "~", .action = .{ .mkdir = .{ .name = invalid } } }));
    }
    try denied.setPermissions(std.testing.io, .fromMode(0));
    defer denied.setPermissions(std.testing.io, .fromMode(0o700)) catch unreachable;
    try expectFailure(service, &journal, "~/denied", .{ .list = .{} }, .permission_denied);
    try expectFailure(service, &journal, "~/denied", .{ .mkdir = .{ .name = "not-created" } }, .permission_denied);
    try denied.setPermissions(std.testing.io, .fromMode(0o700));
    try std.testing.expectError(error.FileNotFound, denied.statFile(std.testing.io, "not-created", .{}));
}

test "local fs rejects stale binding, wrong original owner, invalid path and limits before IO" {
    var journal = operations.Journal.init(std.testing.allocator);
    defer journal.deinit();
    const service = try fs.Service.start(std.testing.allocator, endpoint, .{});
    defer stop(service);
    const key = try journal.begin(.app, null);
    const base: fs.Request = .{ .endpoint = endpoint, .request_id = 1, .path = "/", .action = .stat };
    var stale = base;
    stale.endpoint.binding_generation += 1;
    try std.testing.expectError(error.StaleBinding, service.submit(key, stale));
    const owner: identity.SessionHandle = .{ .session_id = @fromBackingInt(27), .generation = 3 };
    const other_key = try journal.begin(.{ .session = owner }, null);
    try std.testing.expectError(error.OwnerMismatch, service.submit(other_key, base));
    var invalid = base;
    invalid.path = "/a\x00b";
    try std.testing.expectError(error.InvalidPath, service.submit(key, invalid));
    var oversized: [fs.path_limit + 1]u8 = @splat('x');
    oversized[0] = '/';
    invalid.path = &oversized;
    try std.testing.expectError(error.InvalidPath, service.submit(key, invalid));
    invalid.path = "relative";
    try std.testing.expectError(error.AbsolutePathRequired, service.submit(key, invalid));
    invalid.path = "~other";
    try std.testing.expectError(error.AbsolutePathRequired, service.submit(key, invalid));
    invalid.path = "~";
    try std.testing.expectError(error.HomeUnavailable, service.submit(key, invalid));
    invalid = base;
    invalid.action = .{ .read_text = .{ .max_bytes = 0 } };
    try std.testing.expectError(error.InvalidReadLimit, service.submit(key, invalid));
    invalid.action = .{ .read_text = .{ .max_bytes = 65537 } };
    try std.testing.expectError(error.InvalidReadLimit, service.submit(key, invalid));
    invalid.action = .{ .list = .{ .page_entries = 129 } };
    try std.testing.expectError(error.InvalidEntryLimit, service.submit(key, invalid));
    invalid.action = .{ .list = .{ .max_entries = 4097 } };
    try std.testing.expectError(error.InvalidEntryLimit, service.submit(key, invalid));
    try std.testing.expect(!service.cancel(key));
    try std.testing.expectError(error.Busy, service.deinit());
    var session_endpoint = endpoint;
    session_endpoint.resource_owner = .{ .session = owner };
    const owned = try fs.Service.start(std.testing.allocator, session_endpoint, .{});
    defer stop(owned);
    var original = base;
    original.endpoint = session_endpoint;
    try std.testing.expectError(error.OwnerMismatch, owned.submit(key, original));
    var replaced = other_key;
    replaced.owner.session.generation += 1;
    try std.testing.expectError(error.OwnerMismatch, owned.submit(replaced, original));
    try owned.submit(other_key, original);
    var result = try next(owned);
    defer result.deinit();
    try std.testing.expect(result.value.key.eql(other_key));
    try std.testing.expect(result.value.endpoint.resource_owner.?.session.eql(owner));
    try std.testing.expectEqual(.directory, result.value.body.stat.kind);
}
