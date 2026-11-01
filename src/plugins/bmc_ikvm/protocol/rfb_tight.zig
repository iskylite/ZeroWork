//! Complete Tight basic/fill/JPEG decoder with four persistent zlib streams.
//! Wire behaviour follows rfbproto (Tight Encoding); implementation is original.
const std = @import("std");
const raw = @import("rfb_raw.zig");
extern fn zw_rfb_inflate_create() ?*anyopaque;
extern fn zw_rfb_inflate_destroy(?*anyopaque) void;
extern fn zw_rfb_inflate_reset(?*anyopaque) c_int;
extern fn zw_rfb_inflate_exact(?*anyopaque, [*]const u8, usize, [*]u8, usize) c_int;
extern fn zw_rfb_decode_jpeg([*]const u8, usize, u32, u32, [*]u8, usize) c_int;

pub const CompactLength = struct { value: usize, bytes: usize };
pub fn compactLength(data: []const u8) ?CompactLength {
    if (data.len == 0) return null;
    var value: usize = data[0] & 0x7f;
    if (data[0] & 0x80 == 0) return .{ .value = value, .bytes = 1 };
    if (data.len < 2) return null;
    value |= @as(usize, data[1] & 0x7f) << 7;
    if (data[1] & 0x80 == 0) return .{ .value = value, .bytes = 2 };
    if (data.len < 3) return null;
    return .{ .value = value | (@as(usize, data[2]) << 14), .bytes = 3 };
}

pub const Packet = struct {
    consumed: usize,
    control: u8,
    filter: u8 = 0,
    palette: []const u8 = &.{},
    colours: usize = 0,
    data: []const u8,
    decoded_length: usize = 0,
    compressed: bool = false,
};

/// No stream state changes occur during inspection. Repeated calls on partial
/// transport input are safe, including reset bits split across WebSocket frames.
pub fn inspect(format: raw.PixelFormat, width: u16, height: u16, bytes: []const u8, decode_limit: usize) !?Packet {
    if (width == 0 or height == 0 or width > 2048) return error.InvalidTightRectangle;
    if (bytes.len == 0) return null;
    const control = bytes[0];
    const mode = control >> 4;
    const pixel_bytes = format.tightBytesPerPixel();
    var offset: usize = 1;
    if (mode == 8) {
        if (bytes.len < offset + pixel_bytes) return null;
        return .{ .consumed = offset + pixel_bytes, .control = control, .data = bytes[offset..][0..pixel_bytes] };
    }
    if (mode == 9) {
        if (format.bits_per_pixel != 16 and format.bits_per_pixel != 32) return error.UnsupportedTightMode;
        const length = compactLength(bytes[offset..]) orelse return null;
        offset += length.bytes;
        if (length.value == 0) return error.InvalidJpeg;
        if (length.value > decode_limit) return error.DecodeLimitExceeded;
        if (bytes.len - offset < length.value) return null;
        return .{ .consumed = offset + length.value, .control = control, .data = bytes[offset..][0..length.value] };
    }
    if (mode > 7) return error.UnsupportedTightMode; // no unadvertised no-zlib/PNG modes
    var filter: u8 = 0;
    if (mode & 4 != 0) {
        if (bytes.len <= offset) return null;
        filter = bytes[offset];
        offset += 1;
    }
    if (filter > 2 or (filter == 2 and format.bits_per_pixel == 8)) return error.UnsupportedTightFilter;
    var palette: []const u8 = &.{};
    var colours: usize = 0;
    var decoded_length = try raw.byteLength(width, height, pixel_bytes);
    if (filter == 1) {
        if (bytes.len <= offset) return null;
        colours = @as(usize, bytes[offset]) + 1;
        offset += 1;
        if (colours < 2) return error.InvalidTightPalette;
        const palette_length = colours * pixel_bytes;
        if (bytes.len - offset < palette_length) return null;
        palette = bytes[offset..][0..palette_length];
        offset += palette_length;
        decoded_length = if (colours == 2) try raw.byteLength((@as(u32, width) + 7) / 8, height, 1) else try raw.byteLength(width, height, 1);
    }
    if (decoded_length > decode_limit) return error.DecodeLimitExceeded;
    var data_length = decoded_length;
    const compressed = decoded_length >= 12;
    if (compressed) {
        const length = compactLength(bytes[offset..]) orelse return null;
        if (length.value == 0) return error.InvalidCompressedData;
        offset += length.bytes;
        data_length = length.value;
    }
    if (data_length > decode_limit) return error.DecodeLimitExceeded;
    if (bytes.len - offset < data_length) return null;
    return .{ .consumed = offset + data_length, .control = control, .filter = filter, .palette = palette, .colours = colours, .data = bytes[offset..][0..data_length], .decoded_length = decoded_length, .compressed = compressed };
}

pub const Decoder = struct {
    allocator: std.mem.Allocator,
    streams: [4]?*anyopaque = @splat(null),
    pub fn init(allocator: std.mem.Allocator) Decoder {
        return .{ .allocator = allocator };
    }
    pub fn deinit(self: *Decoder) void {
        for (self.streams) |stream| zw_rfb_inflate_destroy(stream);
        self.* = undefined;
    }
    pub fn reset(self: *Decoder, bits: u8) !void {
        for (&self.streams, 0..) |*stream, i| {
            if (bits & (@as(u8, 1) << @intCast(i)) != 0) {
                if (stream.*) |context| {
                    if (zw_rfb_inflate_reset(context) != 0) return error.InvalidCompressedData;
                }
            }
        }
    }

    /// Applies the complete packet directly into the unique protocol work frame.
    /// Temporary allocations are <= raw rectangle bytes + two gradient rows;
    /// JPEG has one bounded rectangle-sized RGBA temporary instead.
    pub fn apply(self: *Decoder, packet: Packet, format: raw.PixelFormat, rect: raw.Rect, frame_width: u16, frame: []u8, decode_limit: usize) !void {
        try self.reset(packet.control & 15);
        const mode = packet.control >> 4;
        const pixels = try raw.byteLength(rect.width, rect.height, 1);
        if (mode == 8) {
            const colour = format.rgba(packet.data, true);
            for (0..pixels) |index| raw.put(frame, frame_width, rect, index, colour);
            return;
        }
        if (mode == 9) {
            const length = try raw.byteLength(rect.width, rect.height, 4);
            if (length > decode_limit) return error.DecodeLimitExceeded;
            const decoded = try self.allocator.alloc(u8, length);
            defer self.allocator.free(decoded);
            if (zw_rfb_decode_jpeg(packet.data.ptr, packet.data.len, rect.width, rect.height, decoded.ptr, decoded.len) != 0) return error.InvalidJpeg;
            for (0..rect.height) |row| {
                const target = ((@as(usize, rect.y) + row) * frame_width + rect.x) * 4;
                const source = row * @as(usize, rect.width) * 4;
                @memcpy(frame[target..][0 .. @as(usize, rect.width) * 4], decoded[source..][0 .. @as(usize, rect.width) * 4]);
            }
            return;
        }
        var allocated: ?[]u8 = null;
        defer if (allocated) |bytes| self.allocator.free(bytes);
        const decoded = if (packet.compressed) block: {
            const bytes = try self.allocator.alloc(u8, packet.decoded_length);
            allocated = bytes;
            const stream_index = mode & 3;
            if (self.streams[stream_index] == null) self.streams[stream_index] = zw_rfb_inflate_create() orelse return error.OutOfMemory;
            if (zw_rfb_inflate_exact(self.streams[stream_index], packet.data.ptr, packet.data.len, bytes.ptr, bytes.len) != 0) return error.InvalidCompressedData;
            break :block bytes;
        } else packet.data;
        const pixel_bytes = format.tightBytesPerPixel();
        if (packet.filter == 1) {
            const row_bytes = (@as(usize, rect.width) + 7) / 8;
            for (0..pixels) |index| {
                const palette_index: usize = if (packet.colours == 2)
                    (decoded[(index / rect.width) * row_bytes + (index % rect.width) / 8] >> @as(u3, @intCast(7 - index % rect.width % 8))) & 1
                else
                    decoded[index];
                if (palette_index >= packet.colours) return error.InvalidTightPaletteIndex;
                raw.put(frame, frame_width, rect, index, format.rgba(packet.palette[palette_index * pixel_bytes ..][0..pixel_bytes], true));
            }
        } else if (packet.filter == 2) {
            const row_components = @as(usize, rect.width) * 3;
            const scratch_bytes = try std.math.mul(usize, row_components, 2 * @sizeOf(u16));
            if (scratch_bytes > decode_limit - packet.decoded_length) return error.DecodeLimitExceeded;
            const rows = try self.allocator.alloc(u16, row_components * 2);
            defer self.allocator.free(rows);
            @memset(rows, 0);
            var previous = rows[0..row_components];
            var current = rows[row_components..];
            const maxima = [_]u16{ format.red_max, format.green_max, format.blue_max };
            for (0..rect.height) |y| {
                for (0..rect.width) |x| {
                    const index = y * @as(usize, rect.width) + x;
                    const differences = format.components(decoded[index * pixel_bytes ..][0..pixel_bytes], true);
                    var components: [3]u16 = undefined;
                    for (0..3) |component| {
                        const left: i32 = if (x == 0) 0 else current[(x - 1) * 3 + component];
                        const upper: i32 = previous[x * 3 + component];
                        const upper_left: i32 = if (x == 0) 0 else previous[(x - 1) * 3 + component];
                        const predicted: u16 = @intCast(std.math.clamp(left + upper - upper_left, 0, maxima[component]));
                        components[component] = @intCast((@as(u32, predicted) + differences[component]) & maxima[component]);
                        current[x * 3 + component] = components[component];
                    }
                    raw.put(frame, frame_width, rect, index, format.componentsRgba(components));
                }
                std.mem.swap([]u16, &previous, &current);
            }
        } else {
            for (0..pixels) |index| raw.put(frame, frame_width, rect, index, format.rgba(decoded[index * pixel_bytes ..][0..pixel_bytes], true));
        }
    }
};

test "compact length supports split third byte and all 22 bits" {
    const t = std.testing;
    try t.expect(compactLength(&.{}) == null);
    try t.expect(compactLength(&.{0x80}) == null);
    try t.expect(compactLength(&.{ 0x80, 0x80 }) == null);
    try t.expectEqual(@as(usize, 10000), compactLength(&.{ 0x90, 0x4e }).?.value);
    try t.expectEqual(@as(usize, 4194303), compactLength(&.{ 0xff, 0xff, 0xff }).?.value);
}
