//! Automation-only process inputs. Formal App builds use framework defaults.
//! Values returned by getOwned are copied; Windows uses the Unicode Win32 API.
const std = @import("std");
const builtin = @import("builtin");
const enabled = @import("automation_options").test_mode or builtin.is_test;

/// Raw compatibility accessor for diagnostics migrated from direct libc calls.
pub fn getRaw(name: [:0]const u8) ?[*:0]const u8 {
    if (!enabled) return null;
    const value = std.c.getenv(name.ptr) orelse return null;
    return value;
}

pub fn has(comptime name: [:0]const u8) bool {
    if (!enabled) return false;
    if (builtin.target.os.tag == .windows) {
        const environ: std.process.Environ = .{ .block = .global };
        return environ.getWindows(std.unicode.utf8ToUtf16LeStringLiteral(name)) != null;
    }
    return std.c.getenv(name) != null;
}

/// Borrowing matches the native POSIX getenv lifetime: environment mutation
/// may invalidate the result. Call getOwned when the value must be retained.
pub fn getBorrowed(comptime name: [:0]const u8) ?[:0]const u8 {
    if (!enabled) return null;
    if (builtin.target.os.tag == .windows) @compileError("use getOwned on Windows");
    const value = std.c.getenv(name) orelse return null;
    return std.mem.span(value);
}

pub const GetError = error{ OutOfMemory, EnvironmentVariableNotFound, InvalidWtf8, Unexpected };
pub fn getOwned(allocator: std.mem.Allocator, name: []const u8) GetError![]u8 {
    if (!enabled) return error.EnvironmentVariableNotFound;
    if (builtin.target.os.tag == .windows) {
        const windows = std.os.windows;
        const name_w = try std.unicode.wtf8ToWtf16LeAllocZ(allocator, name);
        defer allocator.free(name_w);
        windows.teb().LastErrorValue = .SUCCESS;
        var needed = GetEnvironmentVariableW(name_w.ptr, null, 0);
        if (needed == 0) {
            if (windows.GetLastError() == .ENVVAR_NOT_FOUND) return error.EnvironmentVariableNotFound;
            if (windows.GetLastError() != .SUCCESS) return error.Unexpected;
            return allocator.dupe(u8, "");
        }
        while (true) {
            const value = try allocator.alloc(u16, needed);
            defer allocator.free(value);
            windows.teb().LastErrorValue = .SUCCESS;
            const len = GetEnvironmentVariableW(name_w.ptr, value.ptr, @intCast(value.len));
            if (len >= value.len) {
                needed = len;
                continue;
            }
            if (len == 0 and windows.GetLastError() == .ENVVAR_NOT_FOUND) return error.EnvironmentVariableNotFound;
            if (len == 0 and windows.GetLastError() != .SUCCESS) return error.Unexpected;
            return std.unicode.wtf16LeToWtf8Alloc(allocator, value[0..len]);
        }
    }
    const name_z = try allocator.dupeSentinel(u8, name, 0);
    defer allocator.free(name_z);
    const value = std.c.getenv(name_z.ptr) orelse return error.EnvironmentVariableNotFound;
    return allocator.dupe(u8, std.mem.span(value));
}

extern "kernel32" fn GetEnvironmentVariableW(name: [*:0]const u16, buffer: ?[*]u16, size: u32) callconv(.winapi) u32;

test "missing process environment values stay missing" {
    const name = "ZENIT_MISSING_ENVIRONMENT_TEST_0D391170";
    try std.testing.expect(!has(name));
    try std.testing.expectError(error.EnvironmentVariableNotFound, getOwned(std.testing.allocator, name));
}

test "process environment preserves empty and Unicode values and owns copies" {
    const name = "ZENIT_ENVIRONMENT_COPY_TEST_F493EC17";
    if (has(name)) return error.TestEnvironmentAlreadySet;
    defer setTestValue(name, null) catch unreachable;
    try setTestValue(name, "");
    try std.testing.expect(has(name));
    const empty = try getOwned(std.testing.allocator, name);
    defer std.testing.allocator.free(empty);
    try std.testing.expectEqualStrings("", empty);

    const original = "日本語/é/🦊";
    try setTestValue(name, original);
    const copy = try getOwned(std.testing.allocator, name);
    defer std.testing.allocator.free(copy);
    try setTestValue(name, "changed");
    try std.testing.expectEqualStrings(original, copy);
    if (builtin.os.tag != .windows) try std.testing.expectEqualStrings("changed", getBorrowed(name).?);
    try setTestValue(name, null);
    try std.testing.expect(!has(name));
    try std.testing.expectError(error.EnvironmentVariableNotFound, getOwned(std.testing.allocator, name));
}

fn setTestValue(comptime name: [:0]const u8, value: ?[:0]const u8) !void {
    if (builtin.os.tag == .windows) {
        const wide = if (value) |v| try std.unicode.wtf8ToWtf16LeAllocZ(std.testing.allocator, v) else null;
        defer if (wide) |w| std.testing.allocator.free(w);
        if (SetEnvironmentVariableW(std.unicode.utf8ToUtf16LeStringLiteral(name), if (wide) |w| w.ptr else null) == 0)
            return error.TestEnvironmentMutationFailed;
    } else {
        const result = if (value) |v| setenv(name.ptr, v.ptr, 1) else unsetenv(name.ptr);
        if (result != 0) return error.TestEnvironmentMutationFailed;
    }
}

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;
extern "kernel32" fn SetEnvironmentVariableW(name: [*:0]const u16, value: ?[*:0]const u16) callconv(.winapi) i32;
