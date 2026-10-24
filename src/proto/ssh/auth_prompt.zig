//! SSH keyboard-interactive has no native OTP type. Only closed, explicit
//! one-time-code labels become a typed OTP prompt; arbitrary server forms stay
//! generic, including passwords, recovery questions and mixed instructions.
const std = @import("std");
pub const Kind = enum { generic, one_time_code };

pub fn classify(text: []const u8, echo: bool) Kind {
    if (echo) return .generic;
    const label = std.mem.trim(u8, text, " \t\r\n:");
    for ([_][]const u8{ "OTP", "TOTP", "Verification code", "Authentication code", "Authenticator code", "One-time code", "One time code", "One-time password", "One time password", "Google Authenticator code", "一次性验证码", "动态验证码" }) |known| {
        if (std.ascii.eqlIgnoreCase(label, known)) return .one_time_code;
    }
    return .generic;
}
