//! Only an OS tag is persisted. The key includes stable connection identity
//! and endpoint, so editing/reusing a connection cannot inherit another OS.
const std = @import("std");
const Host = @import("../config/hosts.zig").HostConfig;
pub const Kind = @import("../proto/ssh/remote_os.zig").Kind;
fn path(allocator: std.mem.Allocator, hosts_path: []const u8, host: Host) ![]u8 {
    var hash = std.hash.Wyhash.init(0);
    const id: u64 = @backingInt(host.connection_id);
    hash.update(std.mem.asBytes(&id));
    inline for (.{ "host", "user" }) |field| {
        hash.update(@field(host, field));
        hash.update(&.{0});
    }
    hash.update(std.mem.asBytes(&host.port));
    hash.update(host.protocolId());
    return std.fmt.allocPrint(allocator, "{s}/cache/os-{x}.txt", .{ std.fs.path.dirname(hosts_path) orelse ".", hash.final() });
}
pub fn load(allocator: std.mem.Allocator, io: std.Io, hosts_path: []const u8, host: Host) Kind {
    if (hosts_path.len == 0 or @backingInt(host.connection_id) == 0) return .unknown;
    const file = path(allocator, hosts_path, host) catch return .unknown;
    defer allocator.free(file);
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, file, allocator, .limited(32)) catch return .unknown;
    defer allocator.free(bytes);
    return std.meta.stringToEnum(Kind, std.mem.trim(u8, bytes, " \r\n")) orelse .unknown;
}
pub fn save(allocator: std.mem.Allocator, io: std.Io, hosts_path: []const u8, host: Host, kind: Kind) void {
    if (hosts_path.len == 0 or @backingInt(host.connection_id) == 0 or kind == .unknown) return;
    const file = path(allocator, hosts_path, host) catch return;
    defer allocator.free(file);
    std.Io.Dir.cwd().createDirPath(io, std.fs.path.dirname(file).?) catch return;
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = file, .data = @tagName(kind) }) catch {};
}

test "OS cache persists only the tag and isolates endpoint changes" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "hosts.toml", .data = "" });
    const hosts_path = try tmp.dir.realPathFileAlloc(io, "hosts.toml", a);
    defer a.free(hosts_path);
    var host: Host = .{ .connection_id = @fromBackingInt(7), .name = "test", .host = "example.test", .user = "tester", .password = "never-persist-this" };
    save(a, io, hosts_path, host, .ubuntu);
    try std.testing.expectEqual(Kind.ubuntu, load(a, io, hosts_path, host));
    const file = try path(a, hosts_path, host);
    defer a.free(file);
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, file, a, .limited(32));
    defer a.free(bytes);
    try std.testing.expectEqualStrings("ubuntu", bytes);
    save(a, io, hosts_path, host, .unknown);
    try std.testing.expectEqual(Kind.ubuntu, load(a, io, hosts_path, host));
    host.host = "other.test";
    try std.testing.expectEqual(Kind.unknown, load(a, io, hosts_path, host));
}
