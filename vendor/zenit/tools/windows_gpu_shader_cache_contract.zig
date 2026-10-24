//! DXBC disk cache of the D3D12 runtime HLSL compiler (native/windows/d3d12_shader.cpp).
//!
//! The first glass story paid ~2 s of D3DCompile on a GTX 1650 box; the cache
//! turns every later compile of the same source into a file read. This locks
//! the contract: a hit returns the bytes the compiler produced, a corrupt or
//! truncated entry is ignored and rewritten, and ZENIT_SHADER_CACHE=0 keeps
//! the directory untouched.
const std = @import("std");
const gpu = @import("gpu");
const d12 = @import("gpu").Backend.native;

extern "kernel32" fn SetEnvironmentVariableW(name: [*:0]const u16, value: ?[*:0]const u16) callconv(.winapi) c_int;
extern fn zenit_d12_shader_data(*anyopaque) [*]const u8;
extern fn zenit_d12_shader_size(*anyopaque) usize;

const source = "RWStructuredBuffer<float> result:register(u0); [numthreads(4,1,1)] void main(uint3 id:SV_DispatchThreadID){result[id.x]=id.x*0.5;}";

fn setEnv(allocator: std.mem.Allocator, name: []const u8, value: ?[]const u8) !void {
    const wname = try std.unicode.utf8ToUtf16LeAllocZ(allocator, name);
    defer allocator.free(wname);
    const wvalue = if (value) |v| try std.unicode.utf8ToUtf16LeAllocZ(allocator, v) else null;
    defer if (wvalue) |w| allocator.free(w);
    if (SetEnvironmentVariableW(wname.ptr, if (wvalue) |w| w.ptr else null) == 0) return error.SetEnvironmentFailed;
}

fn compileBytes(allocator: std.mem.Allocator, device: *d12.Device) ![]u8 {
    var module = try device.createShaderModule(allocator, .{ .source = .{ .hlsl = .{ .code = source, .entry_points = &.{.{ .name = "main", .stage = .compute }} } } });
    defer module.deinit();
    const raw: *anyopaque = @ptrCast(module.entries[0].raw);
    return allocator.dupe(u8, zenit_d12_shader_data(raw)[0..zenit_d12_shader_size(raw)]);
}

fn cacheFiles(io: std.Io, dir: std.Io.Dir) !usize {
    var count: usize = 0;
    var it = dir.iterate();
    while (try it.next(io)) |entry| if (std.mem.endsWith(u8, entry.name, ".dxbc")) {
        count += 1;
    };
    return count;
}

pub fn run(io: std.Io) !void {
    const allocator = std.heap.page_allocator;
    const temp = try @import("zenit_environment").getOwned(allocator, "TEMP");
    defer allocator.free(temp);
    const path = try std.fmt.allocPrint(allocator, "{s}\\zenit-shader-cache-contract-{d}", .{ temp, std.os.windows.GetCurrentProcessId() });
    defer allocator.free(path);
    std.Io.Dir.cwd().deleteTree(io, path) catch {};
    try std.Io.Dir.cwd().createDirPath(io, path);
    defer std.Io.Dir.cwd().deleteTree(io, path) catch {};
    try setEnv(allocator, "ZENIT_SHADER_CACHE_DIR", path);
    defer setEnv(allocator, "ZENIT_SHADER_CACHE_DIR", null) catch {};
    try setEnv(allocator, "ZENIT_SHADER_CACHE", null);
    var dir = try std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
    defer dir.close(io);

    var device = try d12.Device.init(true);
    defer device.destroy();

    const compiled = try compileBytes(allocator, &device);
    defer allocator.free(compiled);
    if (compiled.len < 4 or !std.mem.eql(u8, compiled[0..4], "DXBC")) return error.NotDxbc;
    if (try cacheFiles(io, dir) != 1) return error.CacheEntryNotWritten;

    const hit = try compileBytes(allocator, &device);
    defer allocator.free(hit);
    if (!std.mem.eql(u8, compiled, hit)) return error.CacheHitDiffers;
    if (try cacheFiles(io, dir) != 1) return error.CacheEntryDuplicated;

    // A truncated/corrupt entry is ignored and replaced by a fresh compile.
    var it = dir.iterate();
    const name = while (try it.next(io)) |entry| {
        if (std.mem.endsWith(u8, entry.name, ".dxbc")) break try allocator.dupe(u8, entry.name);
    } else return error.CacheEntryMissing;
    defer allocator.free(name);
    try dir.writeFile(io, .{ .sub_path = name, .data = "junk-not-dxbc-bytes" });
    const repaired = try compileBytes(allocator, &device);
    defer allocator.free(repaired);
    if (!std.mem.eql(u8, compiled, repaired)) return error.CorruptEntryServed;
    // Entry = 16-byte header (magic, payload size, checksum) + the DXBC.
    const stat = try dir.statFile(io, name, .{});
    if (stat.size != compiled.len + 16) return error.CorruptEntryNotRewritten;

    // Disabled: nothing is read or written.
    try setEnv(allocator, "ZENIT_SHADER_CACHE", "0");
    defer setEnv(allocator, "ZENIT_SHADER_CACHE", null) catch {};
    try dir.deleteFile(io, name);
    const uncached = try compileBytes(allocator, &device);
    defer allocator.free(uncached);
    if (!std.mem.eql(u8, compiled, uncached)) return error.UncachedCompileDiffers;
    if (try cacheFiles(io, dir) != 0) return error.CacheWrittenWhileDisabled;
    std.debug.print("PASS: DXBC disk cache: hit returns compiler bytes, corrupt entry recompiled and rewritten, ZENIT_SHADER_CACHE=0 leaves the directory untouched\n", .{});
}
