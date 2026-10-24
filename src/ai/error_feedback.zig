const std = @import("std");
const error_model = @import("error.zig");

pub const Feedback = struct {
    info: ?error_model.Info = null,
    retry_available: bool = false,
    pub fn show(self: *Feedback, info: error_model.Info) void {
        self.info = info;
        self.retry_available = info.retryable or error_model.retryable(info.kind);
    }
    pub fn dismiss(self: *Feedback) void {
        self.info = null;
        self.retry_available = false;
    }
};
test "error feedback exposes retry only for retryable errors" {
    var f: Feedback = .{};
    f.show(.{ .kind = .network, .message = "offline" });
    try std.testing.expect(f.retry_available);
    f.show(.{ .kind = .provider_missing, .message = "configure provider" });
    try std.testing.expect(!f.retry_available);
}
