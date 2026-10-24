//! Copy an unsigned x86 PE executable with the large-address-aware flag set.
//! The linked input (including Zig's compilation cache) is never modified.
const std = @import("std");

fn range(data: []const u8, offset: usize, len: usize) ![]const u8 {
    if (offset > data.len or len > data.len - offset) return error.TruncatedExecutable;
    return data[offset..][0..len];
}

fn read16(data: []const u8, offset: usize) !u16 {
    return std.mem.readInt(u16, (try range(data, offset, 2))[0..2], .little);
}

fn read32(data: []const u8, offset: usize) !u32 {
    return std.mem.readInt(u32, (try range(data, offset, 4))[0..4], .little);
}

/// Validate before mutation. Only COFF Characteristics can change; failures
/// leave the caller's bytes untouched. Signed images and nonzero checksums
/// require a different signing/checksum workflow and are deliberately refused.
pub fn enableLargeAddressAware(data: []u8) !void {
    _ = try range(data, 0, 64);
    if (!std.mem.eql(u8, data[0..2], "MZ")) return error.InvalidDosSignature;
    const pe: usize = try read32(data, 0x3c);
    if (pe < 64) return error.InvalidPeOffset;
    _ = try range(data, pe, 24);
    if (!std.mem.eql(u8, data[pe..][0..4], "PE\x00\x00")) return error.InvalidPeSignature;
    if (try read16(data, pe + 4) != 0x14c) return error.NotX86Executable;
    const characteristics = try read16(data, pe + 22);
    if (characteristics & 0x2000 != 0) return error.DllNotSupported;
    if (characteristics & 0x0002 == 0) return error.NotExecutableImage;
    const optional_size: usize = try read16(data, pe + 20);
    const optional = pe + 24;
    _ = try range(data, optional, optional_size);
    if (optional_size < 96) return error.TruncatedOptionalHeader;
    if (try read16(data, optional) != 0x10b) return error.NotPe32Executable;
    if (try read32(data, optional + 64) != 0) return error.NonzeroChecksum;
    const directories: usize = try read32(data, optional + 92);
    if (directories > (optional_size - 96) / 8) return error.TruncatedDataDirectories;
    // IMAGE_DIRECTORY_ENTRY_SECURITY is a file offset rather than an RVA.
    // Any nonempty declaration is refused, even if the certificate is malformed.
    if (directories > 4 and
        (try read32(data, optional + 128) != 0 or try read32(data, optional + 132) != 0))
        return error.SignedExecutable;
    const section_count: usize = try read16(data, pe + 6);
    _ = try range(data, optional + optional_size, section_count * 40);
    for (0..section_count) |index| {
        const section = optional + optional_size + index * 40;
        const raw_size: usize = try read32(data, section + 16);
        const raw_offset: usize = try read32(data, section + 20);
        if (raw_size != 0) _ = try range(data, raw_offset, raw_size);
    }
    std.mem.writeInt(u16, data[pe + 22 ..][0..2], characteristics | 0x20, .little);
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    if (args.len != 3) {
        std.debug.print("usage: windows-large-address INPUT.exe OUTPUT.exe\n", .{});
        std.process.exit(64);
    }
    const bytes = try std.Io.Dir.cwd().readFileAlloc(init.io, args[1], allocator, .limited(1024 * 1024 * 1024));
    try enableLargeAddressAware(bytes);
    // Exclusive creation also refuses an output alias/symlink/hardlink to the
    // original, rather than trusting path-string equality to protect it.
    const output = try std.Io.Dir.cwd().createFile(init.io, args[2], .{ .exclusive = true });
    // A failed write must not leave a partial cache output that prevents the
    // same build step from retrying. Remove only the file we just created.
    errdefer std.Io.Dir.cwd().deleteFile(init.io, args[2]) catch {};
    defer output.close(init.io);
    try output.writeStreamingAll(init.io, bytes);
}
