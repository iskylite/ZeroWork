const std = @import("std");
extern fn zw_credentials_cached() c_int;
extern fn zw_credentials_authorize(service: [*:0]const u8) c_int;
extern fn zw_credentials_get(service: [*:0]const u8, account: [*:0]const u8, out: *?[*]u8, length: *usize) c_int;
extern fn zw_credentials_add(service: [*:0]const u8, account: [*:0]const u8, value: [*]const u8, length: usize) c_int;
extern fn zw_credentials_delete(service: [*:0]const u8, account: [*:0]const u8) c_int;
extern fn zw_credentials_collect(service: [*:0]const u8, keep: [*]const [*:0]const u8, count: usize) c_int;
extern fn zw_credentials_erase(service: [*:0]const u8) c_int;
extern fn zw_credentials_free(value: ?[*]u8, length: usize) void;
extern fn zw_credentials_export(service: [*:0]const u8, context: *anyopaque, callback: *const fn (*anyopaque, *const [68]u8, [*]const u8, usize) callconv(.c) c_int) c_int;

pub const Error = error{ CredentialMissing, CredentialDenied, CredentialLocked, CredentialUnavailable, CredentialAlreadyExists, CredentialStorageFailure, CredentialAuthenticationCanceled, CredentialAuthenticationFailed, CredentialBusy, OutOfMemory };
fn check(status: c_int) Error!void {
    switch (status) {
        0 => {},
        -25300 => return error.CredentialMissing,
        -25299 => return error.CredentialAlreadyExists,
        -25293 => return error.CredentialDenied,
        -25308 => return error.CredentialLocked,
        -25291 => return error.CredentialUnavailable,
        -43001, -128 => return error.CredentialAuthenticationCanceled,
        -43002 => return error.CredentialAuthenticationFailed,
        -43003 => return error.CredentialBusy,
        else => return error.CredentialStorageFailure,
    }
}
pub fn get(allocator: std.mem.Allocator, service: [:0]const u8, reference: []const u8) ![]u8 {
    const account = try allocator.dupeSentinel(u8, reference, 0);
    defer allocator.free(account);
    var data: ?[*]u8 = null;
    var length: usize = 0;
    try check(zw_credentials_get(service, account, &data, &length));
    defer zw_credentials_free(data, length);
    return allocator.dupe(u8, data.?[0..length]);
}
pub fn add(allocator: std.mem.Allocator, service: [:0]const u8, reference: []const u8, secret: []const u8) !void {
    const account = try allocator.dupeSentinel(u8, reference, 0);
    defer allocator.free(account);
    try check(zw_credentials_add(service, account, secret.ptr, secret.len));
}
pub fn remove(allocator: std.mem.Allocator, service: [:0]const u8, reference: []const u8) !void {
    const account = try allocator.dupeSentinel(u8, reference, 0);
    defer allocator.free(account);
    try check(zw_credentials_delete(service, account));
}
pub fn collect(allocator: std.mem.Allocator, service: [:0]const u8, keep: []const []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const refs = try a.alloc([*:0]const u8, keep.len);
    for (keep, refs) |value, *target| target.* = try a.dupeSentinel(u8, value, 0);
    try check(zw_credentials_collect(service, refs.ptr, refs.len));
}

pub fn erase(service: [:0]const u8) !void {
    try check(zw_credentials_erase(service));
}

pub fn cached() bool {
    return zw_credentials_cached() != 0;
}

/// Explicit access recovery for a locked legacy keychain.
pub fn authorize(service: [:0]const u8) !void {
    try check(zw_credentials_authorize(service));
}

pub fn copyToLocal(service: [:0]const u8, store: @import("../config/local_credentials.zig")) !void {
    const Copy = struct {
        target: @import("../config/local_credentials.zig"),
        failure: ?anyerror = null,
        fn write(raw: *anyopaque, reference: *const [68]u8, value: [*]const u8, length: usize) callconv(.c) c_int {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.target.importValue(reference, value[0..length]) catch |err| {
                self.failure = err;
                return 1;
            };
            return 0;
        }
    };
    var copy: Copy = .{ .target = store };
    const status = zw_credentials_export(service, &copy, Copy.write);
    if (copy.failure) |err| return err;
    try check(status);
}
