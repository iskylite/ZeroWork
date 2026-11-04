//! Read-only OS identification. Output is captured by a separate SSH exec
//! channel, never written into the interactive PTY or inferred from a hostname.
const std = @import("std");
pub const Kind = enum(u8) {
    unknown,
    macos,
    linux,
    ubuntu,
    debian,
    fedora,
    arch,
    alpine,
    windows,
    freebsd,
    rocky,
    kylin,
    neokylin,
    openkylin,
    ubuntukylin,
    uos,
    deepin,
    openeuler,
    euleros,
    anolis,
    opencloudos,
    tencentos,
    alinux,
    loongnix,
    aosc,
    bclinux,
    kylinsec,
    nfs,
    linx,
    isoft,
    redflag,
    rhel,
    centos,
    almalinux,
    oraclelinux,
    sles,
    opensuse,
    amazonlinux,
    nixos,
    gentoo,
    kali,
    linuxmint,
    manjaro,
    openbsd,
    netbsd,
};
pub const command = "sh -c \"uname -s || exit; if test -r /etc/os-release; then cat /etc/os-release; elif test -r /usr/lib/os-release; then cat /usr/lib/os-release; fi\" || cmd /c ver";
pub fn parse(bytes: []const u8) Kind {
    var lines = std.mem.tokenizeAny(u8, bytes, "\r\n");
    var kernel: Kind = .unknown;
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t");
        if (std.mem.eql(u8, line, "Darwin")) kernel = .macos;
        if (std.mem.eql(u8, line, "Linux")) kernel = .linux;
        if (std.mem.eql(u8, line, "FreeBSD")) kernel = .freebsd;
        if (std.mem.eql(u8, line, "OpenBSD")) kernel = .openbsd;
        if (std.mem.eql(u8, line, "NetBSD")) kernel = .netbsd;
        if (std.mem.indexOf(u8, line, "Microsoft Windows") != null or std.mem.startsWith(u8, line, "MINGW") or std.mem.startsWith(u8, line, "MSYS") or std.mem.startsWith(u8, line, "CYGWIN")) return .windows;
        if (std.mem.startsWith(u8, line, "ID=")) {
            const id = std.mem.trim(u8, line[3..], " \t\"'");
            inline for (.{ "ubuntu", "debian", "fedora", "arch", "alpine", "rocky", "kylin", "neokylin", "openkylin", "ubuntukylin", "uos", "deepin", "openeuler", "euleros", "anolis", "opencloudos", "tencentos", "alinux", "loongnix", "aosc", "bclinux", "kylinsec", "nfs", "linx", "isoft", "redflag", "rhel", "centos", "almalinux", "sles", "nixos", "gentoo", "kali", "linuxmint", "manjaro" }) |name| if (std.ascii.eqlIgnoreCase(id, name)) return @field(Kind, name);
            if (std.ascii.eqlIgnoreCase(id, "kylinos")) return .kylin;
            if (std.ascii.eqlIgnoreCase(id, "uniontech") or std.ascii.eqlIgnoreCase(id, "uniontechos")) return .uos;
            if (std.ascii.eqlIgnoreCase(id, "tencent")) return .tencentos;
            if (std.ascii.eqlIgnoreCase(id, "alibaba") or std.ascii.eqlIgnoreCase(id, "aliyun")) return .alinux;
            if (std.ascii.eqlIgnoreCase(id, "aosc-os")) return .aosc;
            if (std.ascii.eqlIgnoreCase(id, "nfsserver") or std.ascii.eqlIgnoreCase(id, "nfsdesktop")) return .nfs;
            if (std.ascii.eqlIgnoreCase(id, "redflag-linux")) return .redflag;
            if (std.ascii.eqlIgnoreCase(id, "ol")) return .oraclelinux;
            if (std.ascii.eqlIgnoreCase(id, "sled")) return .sles;
            inline for (.{ "opensuse", "opensuse-leap", "opensuse-tumbleweed", "opensuse-microos", "opensuse-slowroll" }) |name| if (std.ascii.eqlIgnoreCase(id, name)) return .opensuse;
            if (std.ascii.eqlIgnoreCase(id, "amzn")) return .amazonlinux;
            if (std.ascii.eqlIgnoreCase(id, "openbsd")) return .openbsd;
            if (std.ascii.eqlIgnoreCase(id, "netbsd")) return .netbsd;
            if (id.len > 0 and kernel == .unknown) kernel = .linux;
        }
    }
    return kernel;
}

test "OS identification recognizes the reported Kylin V11 server release" {
    try std.testing.expectEqual(Kind.kylin, parse(
        "Linux\n" ++
            "NAME=\"Kylin Linux Advanced Server\"\n" ++
            "VERSION=\"V11 (Swan25)\"\n" ++
            "ID=\"kylin\"\n" ++
            "VERSION_ID=\"V11\"\n" ++
            "PRETTY_NAME=\"Kylin Linux Advanced Server V11 (Swan25)\"\n",
    ));
}

test "OS identification distinguishes domestic distributions from their upstream families" {
    const cases = .{
        .{ Kind.kylin, "ID=Kylin\nID_LIKE=debian\n" },
        .{ Kind.neokylin, "ID=\"neokylin\"\nID_LIKE=\"rhel fedora\"\n" },
        .{ Kind.openkylin, "ID=openkylin\nID_LIKE=debian\n" },
        .{ Kind.ubuntukylin, "ID=ubuntukylin\nID_LIKE=ubuntu\n" },
        .{ Kind.uos, "ID=Uos\nID_LIKE=debian\n" },
        .{ Kind.uos, "ID=UnionTechOS\nID_LIKE=\"rhel centos fedora\"\n" },
        .{ Kind.deepin, "ID=deepin\nID_LIKE=debian\n" },
        .{ Kind.openeuler, "ID=\"openEuler\"\nID_LIKE=\"rhel centos fedora\"\n" },
        .{ Kind.euleros, "ID=euleros\n" },
        .{ Kind.anolis, "ID=\"anolis\"\nID_LIKE=\"rhel fedora centos\"\n" },
        .{ Kind.opencloudos, "ID=\"opencloudos\"\n" },
        .{ Kind.tencentos, "ID=\"tencentos\"\n" },
        .{ Kind.tencentos, "ID=tencent\n" },
        .{ Kind.alinux, "ID=alinux\nID_LIKE=\"rhel fedora centos\"\n" },
        .{ Kind.alinux, "ID=alibaba\n" },
        .{ Kind.loongnix, "ID=Loongnix\nID_LIKE=debian\n" },
        .{ Kind.aosc, "ID=aosc\n" },
        .{ Kind.bclinux, "ID=bclinux\n" },
        .{ Kind.kylinsec, "ID=kylinsec\n" },
        .{ Kind.nfs, "ID=nfsserver\n" },
        .{ Kind.linx, "ID=linx\n" },
        .{ Kind.isoft, "ID=isoft\n" },
        .{ Kind.redflag, "ID=redflag\n" },
    };
    inline for (cases) |case| try std.testing.expectEqual(case[0], parse("Linux\n" ++ case[1]));
    try std.testing.expectEqual(Kind.linux, parse("Linux\nID=custom\nID_LIKE=\"openEuler kylin uos\"\n"));
    try std.testing.expectEqual(Kind.linux, parse("Linux\nID=kylin-custom\n"));
    try std.testing.expectEqual(Kind.unknown, parse("Welcome to Kylin Linux Advanced Server\n"));
}
pub fn local() Kind {
    return switch (@import("builtin").os.tag) {
        .macos => .macos,
        .linux => .linux,
        .windows => .windows,
        .freebsd => .freebsd,
        .openbsd => .openbsd,
        .netbsd => .netbsd,
        else => .unknown,
    };
}
test "OS identification uses kernel and exact distribution ID" {
    try std.testing.expectEqual(Kind.macos, parse("Darwin\n"));
    try std.testing.expectEqual(Kind.ubuntu, parse("Linux\nNAME=\"Ubuntu\"\nID=ubuntu\n"));
    try std.testing.expectEqual(Kind.debian, parse("Linux\nID=\"debian\"\n"));
    try std.testing.expectEqual(Kind.rocky, parse("Linux\nID=rocky\n"));
    try std.testing.expectEqual(Kind.rocky, parse("Linux\nID=\"rocky\"\nID_LIKE=\"rhel centos fedora\"\n"));
    try std.testing.expectEqual(Kind.linux, parse("Linux\nID=unlisted\nID_LIKE=rocky\n"));
    try std.testing.expectEqual(Kind.windows, parse("Microsoft Windows [Version 10.0]\r\n"));
    try std.testing.expectEqual(Kind.unknown, parse("Ubuntu server banner\n"));
}

test "OS identification distinguishes international distributions and BSD kernels" {
    const cases = .{
        .{ Kind.rhel, "Linux\nID=rhel\nID_LIKE=fedora\n" },
        .{ Kind.centos, "Linux\nNAME=CentOS Stream\nID=centos\nID_LIKE=rhel fedora\n" },
        .{ Kind.almalinux, "Linux\nID=almalinux\nID_LIKE=rhel centos fedora\n" },
        .{ Kind.oraclelinux, "Linux\nID=ol\nID_LIKE=fedora\n" },
        .{ Kind.sles, "Linux\nID=sles\nID_LIKE=suse\n" },
        .{ Kind.sles, "Linux\nID=sled\nID_LIKE=suse\n" },
        .{ Kind.opensuse, "Linux\nID=opensuse-leap\nID_LIKE=suse opensuse\n" },
        .{ Kind.opensuse, "Linux\nID=opensuse-tumbleweed\n" },
        .{ Kind.opensuse, "Linux\nID=opensuse-microos\n" },
        .{ Kind.opensuse, "Linux\nID=opensuse-slowroll\n" },
        .{ Kind.amazonlinux, "Linux\nID=amzn\nVERSION_ID=2023\nID_LIKE=fedora\n" },
        .{ Kind.nixos, "Linux\nID=nixos\n" },
        .{ Kind.gentoo, "Linux\nID=gentoo\n" },
        .{ Kind.kali, "Linux\nID=kali\nID_LIKE=debian\n" },
        .{ Kind.linuxmint, "Linux\nID=linuxmint\nID_LIKE=ubuntu debian\n" },
        .{ Kind.manjaro, "Linux\nID=Manjaro\nID_LIKE=arch\n" },
        .{ Kind.openbsd, "OpenBSD\n" },
        .{ Kind.netbsd, "NetBSD\n" },
    };
    inline for (cases) |case| try std.testing.expectEqual(case[0], parse(case[1]));
    try std.testing.expectEqual(Kind.linux, parse("Linux\nID=custom\nID_LIKE=rhel centos opensuse\n"));
    try std.testing.expectEqual(Kind.linux, parse("Linux\nID=almalinux-custom\n"));
    try std.testing.expectEqual(Kind.unknown, parse("Welcome to Amazon Linux and OpenBSD\n"));
    // A release file must not turn a known non-Linux kernel into Linux.
    try std.testing.expectEqual(Kind.freebsd, parse("FreeBSD\nID=freebsd\n"));
}
