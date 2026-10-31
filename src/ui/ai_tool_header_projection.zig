//! Display-only tool parameters. Raw arguments remain the source for copying,
//! approval and dispatch; a header never falls back to call/request identities.
const std = @import("std");

pub fn projectWithStatus(a: std.mem.Allocator, name: []const u8, raw: []const u8, status: ?[]const u8) ![]u8 {
    const value = try project(a, name, raw);
    const label = status orelse return value;
    defer a.free(value);
    return if (value.len == 0) a.dupe(u8, label) else std.fmt.allocPrint(a, "{s} · {s}", .{ label, value });
}

/// Approval snapshots retain their exact subject. Only the visible target is
/// projected: lifecycle subjects use the tool ID plus JSON detail, terminal
/// subjects use a target reference, and trusted human labels stay readable.
pub fn approvalTarget(a: std.mem.Allocator, tool: []const u8, target: []const u8, detail: []const u8) ![]u8 {
    if (try targetReference(a, target)) |value| return value;
    if (std.mem.eql(u8, target, tool) or std.mem.startsWith(u8, target, "host.") or std.mem.startsWith(u8, target, "host__")) return project(a, tool, detail);
    for ([_][]const u8{ "s1:", "g1:", "c1:", "o1:", "x1:", "r1:" }) |prefix| {
        if (std.mem.startsWith(u8, target, prefix)) return a.dupe(u8, "");
    }
    return singleLine(a, target);
}

/// Returns owned text. Legacy tools already carry an extracted command/path;
/// host tools carry an argument object, including during streamed assembly.
pub fn project(a: std.mem.Allocator, name: []const u8, raw: []const u8) ![]u8 {
    for ([_][]const u8{ "run_command", "read_remote_file", "list_remote_files" }) |legacy| {
        if (std.mem.eql(u8, name, legacy)) return a.dupe(u8, raw);
    }
    const input = std.mem.trim(u8, raw, " \t\r\n");
    const parsed = std.json.parseFromSlice(std.json.Value, a, input, .{}) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        // Plugin steps may already contain an extracted command or path.
        // Host events always contain JSON, so incomplete input stays blank.
        if (!std.mem.startsWith(u8, name, "host.") and !std.mem.startsWith(u8, name, "host__") and
            input.len > 0 and input[0] != '{' and input[0] != '[' and input[0] != '"') return singleLine(a, raw);
        return a.dupe(u8, "");
    };
    defer parsed.deinit();
    if (parsed.value != .object) {
        if (!std.mem.startsWith(u8, name, "host.") and !std.mem.startsWith(u8, name, "host__") and
            input.len > 0 and input[0] != '[' and input[0] != '"') return singleLine(a, raw);
        return a.dupe(u8, "");
    }
    // These are actual human-readable fields in the tool schemas, ordered by
    // their usefulness as a compact target. Never enumerate arbitrary JSON.
    for ([_][]const u8{ "command", "path", "url", "name", "host", "query" }) |key| {
        if (parsed.value.object.get(key)) |value| {
            if (value == .string and value.string.len > 0) return singleLine(a, value.string);
        }
    }
    for ([_][]const u8{ "session_ref", "source_ref", "initial_session_ref", "group_ref" }) |key| {
        if (parsed.value.object.get(key)) |value| {
            if (value == .string) if (try targetReference(a, value.string)) |target| return target;
        }
    }
    if (parsed.value.object.get("session_ids")) |ids| {
        if (ids == .array and ids.array.items.len > 0 and ids.array.items.len <= 16) {
            for (ids.array.items) |id| if (id != .integer or id.integer <= 0) return a.dupe(u8, "");
            var targets: std.Io.Writer.Allocating = .init(a);
            defer targets.deinit();
            try targets.writer.writeAll("会话 ");
            for (ids.array.items, 0..) |id, index| try targets.writer.print("{s}#{d}", .{ if (index == 0) "" else "、", id.integer });
            return targets.toOwnedSlice();
        }
    }
    return a.dupe(u8, "");
}

fn singleLine(a: std.mem.Allocator, value: []const u8) ![]u8 {
    if (!std.unicode.utf8ValidateSlice(value) or std.mem.indexOfScalar(u8, value, 0) != null) return a.dupe(u8, "");
    const text = try a.dupe(u8, value);
    for (text) |*byte| if (byte.* == '\n' or byte.* == '\r' or byte.* == '\t') {
        byte.* = ' ';
    };
    return text;
}

/// Only the concrete target number is shown. CID, generation, request keys,
/// execution UUIDs and other opaque protocol identities are never displayed.
fn targetReference(a: std.mem.Allocator, reference: []const u8) !?[]u8 {
    var parts = std.mem.splitScalar(u8, reference, ':');
    const kind = parts.next() orelse return null;
    const label = if (std.mem.eql(u8, kind, "s1")) "会话" else if (std.mem.eql(u8, kind, "g1")) "会话组" else if (std.mem.eql(u8, kind, "c1")) "连接" else return null;
    const cid = parts.next() orelse return null;
    if (cid.len != 32) return null;
    for (cid) |byte| if (!std.ascii.isHex(byte)) return null;
    const target = parts.next() orelse return null;
    if (!positiveDecimal(target)) return null;
    if (!std.mem.eql(u8, kind, "g1")) {
        if (!positiveDecimal(parts.next() orelse return null)) return null;
    }
    if (parts.next() != null) return null;
    return try std.fmt.allocPrint(a, "{s} #{s}", .{ label, target });
}

fn positiveDecimal(value: []const u8) bool {
    if (value.len == 0 or value[0] == '0') return false;
    for (value) |byte| if (!std.ascii.isDigit(byte)) return false;
    _ = std.fmt.parseInt(u64, value, 10) catch return false;
    return true;
}

test "tool header projection selects concrete schema parameters and hides call identity" {
    const a = std.testing.allocator;
    const cases = [_]struct { name: []const u8, raw: []const u8, expected: []const u8 }{
        .{ .name = "host.run_in_terminal", .raw = "{\"command\":\"printf '你好'\\npwd\",\"session_ref\":\"opaque\",\"request_key\":\"call-123\"}", .expected = "printf '你好' pwd" },
        .{ .name = "host.create_group", .raw = "{\"name\":\"部署检查\",\"request_key\":\"create_group\"}", .expected = "部署检查" },
        .{ .name = "host.fetch_url", .raw = "{\"url\":\"https://example.com/文档\"}", .expected = "https://example.com/文档" },
        .{ .name = "fixture__read", .raw = "{\"path\":\"/srv/项目/配置.json\"}", .expected = "/srv/项目/配置.json" },
        .{ .name = "host.open_session", .raw = "{\"source_ref\":\"s1:0123456789abcdef0123456789abcdef:101:3\",\"request_key\":\"open-call\"}", .expected = "会话 #101" },
        .{ .name = "host.open_session", .raw = "{\"source_ref\":\"c1:0123456789abcdef0123456789abcdef:99:2\"}", .expected = "连接 #99" },
        .{ .name = "host.get_group", .raw = "{\"group_ref\":\"g1:0123456789abcdef0123456789abcdef:7\"}", .expected = "会话组 #7" },
        .{ .name = "host.get_execution", .raw = "{\"execution_ref\":\"internal-execution\",\"request_key\":\"call-123\"}", .expected = "" },
        .{ .name = "host.open_session", .raw = "{\"source_ref\":\"s1:invalid:101:3\"}", .expected = "" },
        .{ .name = "host.run_in_terminal", .raw = "{\"command\":\"assembling", .expected = "" },
        .{ .name = "host.run_in_terminal", .raw = "not JSON", .expected = "" },
        .{ .name = "host.create_group", .raw = "[]", .expected = "" },
        .{ .name = "host.create_group", .raw = "{\"name\":42}", .expected = "" },
        .{ .name = "host.create_group", .raw = "{\"name\":\"bad\\u0000name\"}", .expected = "" },
        .{ .name = "run_command", .raw = "{ printf 'literal shell block'; }", .expected = "{ printf 'literal shell block'; }" },
        .{ .name = "read_terminal", .raw = "{\"session_ids\":[101,102]}", .expected = "会话 #101、#102" },
        .{ .name = "fixture__read", .raw = "/srv/already-extracted", .expected = "/srv/already-extracted" },
        .{ .name = "fixture__run", .raw = "true", .expected = "true" },
    };
    for (cases) |case| {
        const actual = try project(a, case.name, case.raw);
        defer a.free(actual);
        try std.testing.expectEqualStrings(case.expected, actual);
    }
}
