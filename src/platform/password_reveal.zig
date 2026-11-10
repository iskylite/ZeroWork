//! Fresh macOS device-owner authorization for one password reveal action.
const builtin = @import("builtin");
extern fn zw_password_reveal_begin() ?*anyopaque;
extern fn zw_password_reveal_status(*anyopaque) c_int;
extern fn zw_password_reveal_cancel(*anyopaque) void;

pub const Result = enum(c_int) { pending, approved, cancelled, failed };
pub const Request = struct {
    handle: ?*anyopaque = null,
    active: bool = false,
    test_result: if (builtin.is_test) Result else void = if (builtin.is_test) .pending else {},

    pub fn begin(self: *Request) !void {
        self.cancel();
        if (!builtin.is_test) self.handle = zw_password_reveal_begin() orelse return error.AuthorizationUnavailable;
        self.active = true;
    }
    pub fn result(self: *const Request) Result {
        if (!self.active) return .cancelled;
        if (builtin.is_test) return self.test_result;
        return switch (zw_password_reveal_status(self.handle.?)) {
            0 => .pending,
            1 => .approved,
            2 => .cancelled,
            else => .failed,
        };
    }
    pub fn cancel(self: *Request) void {
        if (!builtin.is_test) if (self.handle) |handle| zw_password_reveal_cancel(handle);
        self.* = .{};
    }
};
