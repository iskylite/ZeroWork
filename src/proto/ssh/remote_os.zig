//! Read-only OS identification. Output is captured by a separate SSH exec
//! channel, never written into the interactive PTY or inferred from a hostname.
const std = @import("std");
pub const Kind = enum(u8) { unknown, macos, linux, ubuntu, debian, fedora, arch, alpine, windows, freebsd };
pub const command = "sh -c \"uname -s; cat /etc/os-release\" || cmd /c ver";
pub fn parse(bytes: []const u8) Kind {
    var lines = std.mem.tokenizeAny(u8, bytes, "\r\n");
    var kernel: Kind = .unknown;
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t");
        if (std.mem.eql(u8, line, "Darwin")) kernel = .macos;
        if (std.mem.eql(u8, line, "Linux")) kernel = .linux;
        if (std.mem.eql(u8, line, "FreeBSD")) kernel = .freebsd;
        if (std.mem.indexOf(u8, line, "Microsoft Windows") != null or std.mem.startsWith(u8, line, "MINGW") or std.mem.startsWith(u8, line, "MSYS") or std.mem.startsWith(u8, line, "CYGWIN")) return .windows;
        if (std.mem.startsWith(u8, line, "ID=")) {
            const id = std.mem.trim(u8, line[3..], "\"'");
            inline for (.{ "ubuntu", "debian", "fedora", "arch", "alpine" }) |name| if (std.mem.eql(u8, id, name)) return @field(Kind, name);
            if (id.len > 0) kernel = .linux;
        }
    }
    return kernel;
}
pub fn local() Kind {
    return switch (@import("builtin").os.tag) {
        .macos => .macos,
        .linux => .linux,
        .windows => .windows,
        .freebsd => .freebsd,
        else => .unknown,
    };
}
test "OS identification uses kernel and exact distribution ID" {
    try std.testing.expectEqual(Kind.macos, parse("Darwin\n"));
    try std.testing.expectEqual(Kind.ubuntu, parse("Linux\nNAME=\"Ubuntu\"\nID=ubuntu\n"));
    try std.testing.expectEqual(Kind.debian, parse("Linux\nID=\"debian\"\n"));
    try std.testing.expectEqual(Kind.linux, parse("Linux\nID=rocky\n"));
    try std.testing.expectEqual(Kind.windows, parse("Microsoft Windows [Version 10.0]\r\n"));
    try std.testing.expectEqual(Kind.unknown, parse("Ubuntu server banner\n"));
}
