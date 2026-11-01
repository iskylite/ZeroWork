const std = @import("std");
const rfb = @import("plugins/bmc_ikvm/protocol/rfb_parser.zig");

test {
    std.testing.refAllDecls(rfb);
    std.testing.refAllDecls(rfb.raw);
    std.testing.refAllDecls(rfb.tight);
}

test "BMC decoder ownership starts empty" {
    var decoder = try rfb.Decoder.init(std.testing.allocator, .{});
    defer decoder.deinit();
    try std.testing.expectEqual(rfb.Phase.websocket, decoder.phase);
}

test "BMC RFB nonzero pixel flags accept observed ServerInit and keep negotiated format" {
    var format: [16]u8 = undefined;
    _ = try std.fmt.hexToBytes(&format, "202000ff00ff00ff00ff000810000000");
    const observed = try rfb.raw.PixelFormat.parse(&format);
    try T.expectEqual(@as(u8, 32), observed.depth);
    try T.expectEqualSlices(u8, &.{ 1, 2, 3, 255 }, &observed.rgba(&.{ 1, 2, 3, 0 }, false));
    format[2] = 255;
    const big = try rfb.raw.PixelFormat.parse(&format);
    try T.expect(big.big_endian);
    try T.expectEqualSlices(u8, &.{ 1, 2, 3, 255 }, &big.rgba(&.{ 0, 3, 2, 1 }, false));
    format[3] = 0;
    try T.expectError(error.UnsupportedPixelFormat, rfb.raw.PixelFormat.parse(&format));
    format[3] = 255;
    format[2] = 0;
    var harness = try Harness.init(.{});
    defer harness.deinit();
    try harness.decoder.websocketReady(.{ .tls_trusted = true, .web_authenticated = true, .oem_authenticated = true });
    var bytes = try handshake(2, 1);
    defer bytes.deinit(allocator);
    const format_offset = "RFB 003.008\n".len + 15 + 4;
    @memcpy(bytes.items[format_offset..][0..16], &format);
    try updateHeader(&bytes, 1);
    try rect(&bytes, 0, 0, 2, 1, 0);
    // The client requests its validated RGB format before the first update.
    try bytes.appendSlice(allocator, &.{ 3, 2, 1, 0, 6, 5, 4, 0 });
    try harness.pump(bytes.items, 1);
    try T.expectEqual(@as(usize, 1), harness.frames.items.len);
    try T.expectEqualSlices(u8, &.{ 1, 2, 3, 255, 4, 5, 6, 255 }, harness.frames.items[0].pixels);
}

const fixture_path = "plugins/bmc_ikvm/protocol/rfb_fixtures/";
const first_streams = [_][]const u8{
    @embedFile(fixture_path ++ "stream0_first.z"), @embedFile(fixture_path ++ "stream1_first.z"),
    @embedFile(fixture_path ++ "stream2_first.z"), @embedFile(fixture_path ++ "stream3_first.z"),
};
const second_streams = [_][]const u8{
    @embedFile(fixture_path ++ "stream0_second.z"), @embedFile(fixture_path ++ "stream1_second.z"),
    @embedFile(fixture_path ++ "stream2_second.z"), @embedFile(fixture_path ++ "stream3_second.z"),
};
const T = std.testing;
const allocator = T.allocator;
const OwnedFrame = struct { width: u16, height: u16, sequence: u64, generation: u64, pixels: []u8 };
const Harness = struct {
    decoder: rfb.Decoder,
    outbound: std.ArrayList(u8) = .empty,
    frames: std.ArrayList(OwnedFrame) = .empty,
    controls: std.ArrayList(rfb.Control) = .empty,
    notices: std.ArrayList(u8) = .empty,
    cursors: usize = 0,
    resize_count: usize = 0,
    request_count: usize = 0,
    frame_count: usize = 0,
    capture_frames: bool = true,
    fn init(limits: rfb.Limits) !Harness {
        return .{ .decoder = try rfb.Decoder.init(allocator, limits) };
    }
    fn deinit(self: *Harness) void {
        self.decoder.deinit();
        self.outbound.deinit(allocator);
        for (self.frames.items) |frame| allocator.free(frame.pixels);
        self.frames.deinit(allocator);
        self.controls.deinit(allocator);
        self.notices.deinit(allocator);
    }
    fn drain(self: *Harness) !usize {
        var count: usize = 0;
        while (self.decoder.nextEvent()) |value| {
            var event = value;
            defer event.deinit(allocator);
            count += 1;
            switch (event) {
                .outbound => |bytes| try self.outbound.appendSlice(allocator, bytes),
                .frame_complete => |frame| {
                    self.frame_count += 1;
                    if (self.capture_frames) try self.frames.append(allocator, .{
                        .width = frame.width,
                        .height = frame.height,
                        .sequence = frame.sequence,
                        .generation = frame.generation,
                        .pixels = try allocator.dupe(u8, frame.pixels),
                    });
                },
                .control => |control| try self.controls.append(allocator, control),
                .notice => |bytes| try self.notices.appendSlice(allocator, bytes),
                .resize => self.resize_count += 1,
                .control_request => self.request_count += 1,
                .cursor => self.cursors += 1,
                else => {},
            }
        }
        return count;
    }
    fn pump(self: *Harness, data: []const u8, chunk_size: usize) !void {
        var offset: usize = 0;
        while (offset < data.len) {
            const accepted = try self.decoder.feed(data[offset..][0..@min(chunk_size, data.len - offset)]);
            const events = try self.drain();
            if (accepted == 0 and events == 0) return error.TestParserStalled;
            offset += accepted;
        }
        for (0..4096) |_| {
            const before = self.decoder.bufferedBytes();
            _ = try self.decoder.feed(&.{});
            const events = try self.drain();
            if (self.decoder.bufferedBytes() == before and events == 0) break;
        } else return error.TestParserStalled;
    }
    fn ready(self: *Harness, width: u16, height: u16, chunk: usize) !void {
        try self.decoder.websocketReady(.{ .tls_trusted = true, .web_authenticated = true, .oem_authenticated = true });
        var bytes = try handshake(width, height);
        defer bytes.deinit(allocator);
        try self.pump(bytes.items, chunk);
        try T.expectEqual(rfb.Phase.normal, self.decoder.phase);
    }
};

fn append16(bytes: *std.ArrayList(u8), value: u16) !void {
    var encoded: [2]u8 = undefined;
    std.mem.writeInt(u16, &encoded, value, .big);
    try bytes.appendSlice(allocator, &encoded);
}
fn append32(bytes: *std.ArrayList(u8), value: u32) !void {
    var encoded: [4]u8 = undefined;
    std.mem.writeInt(u32, &encoded, value, .big);
    try bytes.appendSlice(allocator, &encoded);
}
fn appendLength(bytes: *std.ArrayList(u8), value: usize) !void {
    var remainder = value;
    try bytes.append(allocator, @as(u8, @intCast(remainder & 127)) | if (remainder > 127) @as(u8, 128) else 0);
    remainder >>= 7;
    if (remainder != 0) {
        try bytes.append(allocator, @as(u8, @intCast(remainder & 127)) | if (remainder > 127) @as(u8, 128) else 0);
        remainder >>= 7;
        if (remainder != 0) try bytes.append(allocator, @intCast(remainder));
    }
}
fn handshake(width: u16, height: u16) !std.ArrayList(u8) {
    var bytes: std.ArrayList(u8) = .empty;
    errdefer bytes.deinit(allocator);
    try bytes.appendSlice(allocator, "RFB 003.008\n");
    try bytes.appendSlice(allocator, &.{ 105, 0, 1, 99, 104, 0, 0, 0, 2, 2, 1, 0, 0, 0, 0 });
    try append16(&bytes, width);
    try append16(&bytes, height);
    var format: [16]u8 = undefined;
    (rfb.raw.PixelFormat{}).write(&format);
    try bytes.appendSlice(allocator, &format);
    try append32(&bytes, 9);
    try bytes.appendSlice(allocator, "synthetic");
    return bytes;
}
fn updateHeader(bytes: *std.ArrayList(u8), rectangles: u16) !void {
    try bytes.appendSlice(allocator, &.{ 0, 0 });
    try append16(bytes, rectangles);
}
fn rect(bytes: *std.ArrayList(u8), x: u16, y: u16, width: u16, height: u16, encoding: i32) !void {
    try append16(bytes, x);
    try append16(bytes, y);
    try append16(bytes, width);
    try append16(bytes, height);
    try append32(bytes, @bitCast(encoding));
}
fn tightCompressed(control: u8, filter: ?u8, data: []const u8) !std.ArrayList(u8) {
    var bytes: std.ArrayList(u8) = .empty;
    errdefer bytes.deinit(allocator);
    try bytes.append(allocator, control);
    if (filter) |value| try bytes.append(allocator, value);
    try appendLength(&bytes, data.len);
    try bytes.appendSlice(allocator, data);
    return bytes;
}

test "BMC OEM authenticated handshake, one-byte transport splits, exact replies and negotiated encodings" {
    var h = try Harness.init(.{});
    defer h.deinit();
    try h.ready(2, 1, 1);
    try T.expectEqualSlices(u8, "KVM RFB 003.008\n", h.outbound.items[0..16]);
    try T.expectEqualSlices(u8, &.{ 106, 0, 1, 99, 1, 1 }, h.outbound.items[16..22]);
    try T.expectEqual(rfb.ControlState.awaiting_authorization, h.controls.items[0].state);
    try T.expectEqual(@as(usize, 1), h.resize_count);
    const pf = try rfb.raw.PixelFormat.parse(h.outbound.items[26..42]);
    try T.expectEqual(@as(u8, 16), pf.red_shift);
    try T.expectEqual(@as(u8, 2), h.outbound.items[42]);
    try T.expectEqual(@as(u16, 6), std.mem.readInt(u16, h.outbound.items[44..46], .big));
    const request = h.outbound.items[h.outbound.items.len - 10 ..];
    try T.expectEqualSlices(u8, &.{ 3, 0, 0, 0, 0, 0, 0, 2, 0, 1 }, request);
    try h.decoder.finish();
}

test "BMC security None requires trusted TLS and both prior authentications" {
    for (0..3) |missing| {
        var d = try rfb.Decoder.init(allocator, .{});
        defer d.deinit();
        try T.expectError(error.AuthenticationRequired, d.websocketReady(.{ .tls_trusted = missing != 0, .web_authenticated = missing != 1, .oem_authenticated = missing != 2 }));
        try T.expectEqual(rfb.Phase.websocket, d.failure.?.phase);
        try T.expect(d.nextEvent() == null);
    }
}

test "BMC Raw full update and consecutive incremental rectangles retain prior pixels" {
    var h = try Harness.init(.{});
    defer h.deinit();
    try h.ready(2, 1, 65536);
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(allocator);
    try updateHeader(&bytes, 2);
    try rect(&bytes, 0, 0, 1, 1, 0);
    try bytes.appendSlice(allocator, &.{ 3, 2, 1, 0 });
    try rect(&bytes, 1, 0, 1, 1, 0);
    try bytes.appendSlice(allocator, &.{ 6, 5, 4, 0 });
    try updateHeader(&bytes, 1);
    try rect(&bytes, 1, 0, 1, 1, 0);
    try bytes.appendSlice(allocator, &.{ 9, 8, 7, 0 });
    try h.pump(bytes.items, 1);
    try T.expectEqual(@as(usize, 2), h.frames.items.len);
    try T.expectEqualSlices(u8, &.{ 1, 2, 3, 255, 4, 5, 6, 255 }, h.frames.items[0].pixels);
    try T.expectEqualSlices(u8, &.{ 1, 2, 3, 255, 7, 8, 9, 255 }, h.frames.items[1].pixels);
    try T.expectEqual(@as(u64, 2), h.frames.items[1].sequence);
    try T.expectEqual(@as(u8, 1), h.outbound.items[h.outbound.items.len - 9]);
}

test "BMC explicit full refresh waits for the outstanding update and then resumes incremental frames" {
    var h = try Harness.init(.{});
    defer h.deinit();
    try h.ready(1, 1, 65536);
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(allocator);
    try updateHeader(&bytes, 1);
    try rect(&bytes, 0, 0, 1, 1, 0);
    try bytes.appendSlice(allocator, &.{ 3, 2, 1, 0 });
    try h.pump(bytes.items, 1);
    try T.expectEqual(@as(u8, 1), h.outbound.items[h.outbound.items.len - 9]);
    h.outbound.clearRetainingCapacity();
    try h.decoder.requestFullRefresh();
    try h.decoder.requestFullRefresh();
    _ = try h.drain();
    try T.expectEqual(@as(usize, 0), h.outbound.items.len);
    try T.expect(h.decoder.request_outstanding);

    // A static server may answer with no changed rectangles. That completes
    // its outstanding incremental response and permits exactly one full one.
    try h.pump(&.{ 0, 0, 0, 0 }, 1);
    try T.expectEqualSlices(u8, &.{ 3, 0, 0, 0, 0, 0, 0, 1, 0, 1 }, h.outbound.items);
    h.outbound.clearRetainingCapacity();
    bytes.clearRetainingCapacity();
    try updateHeader(&bytes, 1);
    try rect(&bytes, 0, 0, 1, 1, 0);
    try bytes.appendSlice(allocator, &.{ 6, 5, 4, 0 });
    try h.pump(bytes.items, 1);
    try T.expectEqualSlices(u8, &.{ 3, 1, 0, 0, 0, 0, 0, 1, 0, 1 }, h.outbound.items);
    try T.expectEqual(@as(usize, 3), h.frames.items.len);
    try T.expectEqualSlices(u8, &.{ 4, 5, 6, 255 }, h.frames.items[2].pixels);
    try T.expect(h.decoder.request_outstanding and !h.decoder.force_full_next);
}

test "BMC Tight four persistent zlib streams, successive fragments, and reset bits" {
    var decoder = rfb.tight.Decoder.init(allocator);
    defer decoder.deinit();
    var frame: [16]u8 = undefined;
    for (0..2) |pass| {
        for (0..4) |stream| {
            const control: u8 = @as(u8, @intCast(stream)) << 4;
            var bytes = try tightCompressed(control, null, (if (pass == 0) first_streams else second_streams)[stream]);
            defer bytes.deinit(allocator);
            const packet = (try rfb.tight.inspect(.{}, 2, 2, bytes.items, 65536)).?;
            try decoder.apply(packet, .{}, .{ .x = 0, .y = 0, .width = 2, .height = 2 }, 2, &frame, 65536);
            for (0..4) |index| {
                const base: u8 = @intCast((if (pass == 0) @as(usize, 10) + index * 30 else 1 + index * 3) + stream * 20);
                const step: u8 = if (pass == 0) 10 else 1;
                try T.expectEqualSlices(u8, &.{ base, base + step, base + 2 * step, 255 }, frame[index * 4 ..][0..4]);
            }
        }
    }
    // Reset all four, including streams not selected by this rectangle.
    var reset_bytes = try tightCompressed(0x0f, null, first_streams[0]);
    defer reset_bytes.deinit(allocator);
    const reset_packet = (try rfb.tight.inspect(.{}, 2, 2, reset_bytes.items, 65536)).?;
    try decoder.apply(reset_packet, .{}, .{ .x = 0, .y = 0, .width = 2, .height = 2 }, 2, &frame, 65536);
    for (1..4) |stream| {
        var bytes = try tightCompressed(@as(u8, @intCast(stream)) << 4, null, first_streams[stream]);
        defer bytes.deinit(allocator);
        const packet = (try rfb.tight.inspect(.{}, 2, 2, bytes.items, 65536)).?;
        try decoder.apply(packet, .{}, .{ .x = 0, .y = 0, .width = 2, .height = 2 }, 2, &frame, 65536);
    }
}

test "BMC Tight copy, fill, two-colour row padding, indexed palette and gradient RGB" {
    var decoder = rfb.tight.Decoder.init(allocator);
    defer decoder.deinit();
    var frame: [18 * 4]u8 = @splat(0);
    const small_copy = [_]u8{ 0, 1, 2, 3, 4, 5, 6 };
    var packet = (try rfb.tight.inspect(.{}, 2, 1, &small_copy, 65536)).?;
    try decoder.apply(packet, .{}, .{ .x = 0, .y = 0, .width = 2, .height = 1 }, 2, &frame, 65536);
    try T.expectEqualSlices(u8, &.{ 1, 2, 3, 255, 4, 5, 6, 255 }, frame[0..8]);
    const fill = [_]u8{ 0x80, 30, 40, 50 };
    packet = (try rfb.tight.inspect(.{}, 2, 1, &fill, 65536)).?;
    try decoder.apply(packet, .{}, .{ .x = 0, .y = 0, .width = 2, .height = 1 }, 2, &frame, 65536);
    try T.expectEqualSlices(u8, &.{ 30, 40, 50, 255, 30, 40, 50, 255 }, frame[0..8]);
    const palette = [_]u8{ 0x40, 1, 1, 255, 0, 0, 0, 0, 255, 0xaa, 0x80, 0x55, 0x00 };
    packet = (try rfb.tight.inspect(.{}, 9, 2, &palette, 65536)).?;
    try decoder.apply(packet, .{}, .{ .x = 0, .y = 0, .width = 9, .height = 2 }, 9, &frame, 65536);
    for (0..18) |index| try T.expectEqualSlices(u8, if (index % 2 == 0) &.{ 0, 0, 255, 255 } else &.{ 255, 0, 0, 255 }, frame[index * 4 ..][0..4]);
    const indexed = [_]u8{ 0x40, 1, 2, 255, 0, 0, 0, 255, 0, 0, 0, 255, 0, 1, 2 };
    packet = (try rfb.tight.inspect(.{}, 3, 1, &indexed, 65536)).?;
    try decoder.apply(packet, .{}, .{ .x = 0, .y = 0, .width = 3, .height = 1 }, 3, &frame, 65536);
    try T.expectEqualSlices(u8, &.{ 255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255 }, frame[0..12]);
    var gradient = try tightCompressed(0x41, 2, @embedFile(fixture_path ++ "gradient_rgb.z"));
    defer gradient.deinit(allocator);
    packet = (try rfb.tight.inspect(.{}, 2, 2, gradient.items, 65536)).?;
    try decoder.apply(packet, .{}, .{ .x = 0, .y = 0, .width = 2, .height = 2 }, 2, &frame, 65536);
    try T.expectEqualSlices(u8, &.{ 10, 20, 30, 255, 15, 25, 35, 255, 20, 40, 60, 255, 30, 55, 80, 255 }, frame[0..16]);
}

test "BMC Tight gradient 16-bit reconstructs component arithmetic before RGBA scaling" {
    const format: rfb.raw.PixelFormat = .{ .bits_per_pixel = 16, .depth = 16, .red_max = 31, .green_max = 63, .blue_max = 31, .red_shift = 11, .green_shift = 5, .blue_shift = 0 };
    var decoder = rfb.tight.Decoder.init(allocator);
    defer decoder.deinit();
    // Actual components (r,g,b): (31,63,31), (0,0,0). Second pixel's
    // residual wraps modulo each component maximum+1, not modulo RGBA8.
    const bytes = [_]u8{ 0x40, 2, 0xff, 0xff, 0x21, 0x08 };
    const packet = (try rfb.tight.inspect(format, 2, 1, &bytes, 65536)).?;
    var frame: [8]u8 = undefined;
    try decoder.apply(packet, format, .{ .x = 0, .y = 0, .width = 2, .height = 1 }, 2, &frame, 65536);
    try T.expectEqualSlices(u8, &.{ 255, 255, 255, 255, 0, 0, 0, 255 }, &frame);
}

test "BMC Tight JPEG bounded source dimensions, RGBA channels and top-to-bottom orientation" {
    var bytes = try tightCompressed(0x90, null, @embedFile(fixture_path ++ "quadrants_32.jpg"));
    defer bytes.deinit(allocator);
    var decoder = rfb.tight.Decoder.init(allocator);
    defer decoder.deinit();
    var frame: [32 * 32 * 4]u8 = undefined;
    const packet = (try rfb.tight.inspect(.{}, 32, 32, bytes.items, 65536)).?;
    try decoder.apply(packet, .{}, .{ .x = 0, .y = 0, .width = 32, .height = 32 }, 32, &frame, 65536);
    const locations = [_]usize{ 0, 31, 31 * 32, 32 * 32 - 1 };
    const expected = [_][3]u8{ .{ 255, 0, 0 }, .{ 0, 255, 0 }, .{ 0, 0, 255 }, .{ 255, 255, 255 } };
    for (locations, expected) |index, rgb| {
        for (0..3) |channel| try T.expect(@abs(@as(i16, frame[index * 4 + channel]) - rgb[channel]) <= 5);
        try T.expectEqual(@as(u8, 255), frame[index * 4 + 3]);
    }
    try T.expectError(error.InvalidJpeg, decoder.apply(packet, .{}, .{ .x = 0, .y = 0, .width = 31, .height = 32 }, 32, &frame, 65536));
}

test "BMC known runtime OEM lengths, live context echoes and explicit control answers" {
    var h = try Harness.init(.{});
    defer h.deinit();
    try h.ready(1, 1, 65536);
    h.outbound.clearRetainingCapacity();
    h.controls.clearRetainingCapacity();
    const messages = [_]u8{
        102,
        105,
        1,
        17,
        18,
        105,
        0,
        0,
        77,
        105,
        127,
        3,
        4,
        106,
        0,
        1,
        22,
        107,
        42,
        43,
        44,
        125,
        2,
        122,
        7,
        123,
        2,
        0,
        0,
        0x10,
        0,
        8,
        0x70,
        121,
        4,
        0,
        3,
        'o',
        'k',
        '!',
        121,
        4,
        0,
        127,
        113,
        0,
        1,
        2,
        3,
        4,
        5,
        6,
        102,
    };
    try h.pump(&messages, 1);
    try T.expectEqualSlices(u8, &.{ 102, 106, 1, 17, 18, 106, 0, 0, 77, 106, 127, 3, 4, 102 }, h.outbound.items);
    try T.expectEqual(@as(usize, 4), h.controls.items.len);
    try T.expectEqual(rfb.ControlState.major, h.controls.items[0].state);
    try T.expectEqual(rfb.ControlState.read_only, h.controls.items[1].state);
    try T.expectEqual(rfb.ControlState.rejected, h.controls.items[2].state);
    try T.expectEqual(rfb.ControlState.awaiting_authorization, h.controls.items[3].state);
    try T.expectEqual(@as(usize, 1), h.request_count);
    try T.expectEqual(@as(usize, 31), h.notices.items.len);
    try h.decoder.replyControl(.{ 107, 42, 43, 44 }, .video_only);
    _ = try h.drain();
    try T.expectEqualSlices(u8, &.{ 108, 0, 43, 44 }, h.outbound.items[h.outbound.items.len - 4 ..]);
    try T.expectError(error.NoControlRequest, h.decoder.replyControl(.{ 107, 42, 43, 44 }, .full_control));
    try h.decoder.requestControl();
    _ = try h.drain();
    try T.expectEqual(@as(u8, 109), h.outbound.items[h.outbound.items.len - 1]);
    try h.pump(&.{ 107, 1, 9, 10 }, 4);
    h.decoder.expireControlRequest();
    try T.expectError(error.NoControlRequest, h.decoder.replyControl(.{ 107, 1, 9, 10 }, .reject));
    try h.decoder.finish();
}

test "BMC OEM macro length requires an explicit evidence-gated profile selection" {
    var unsupported = try Harness.init(.{});
    defer unsupported.deinit();
    try unsupported.ready(1, 1, 65536);
    try T.expectError(error.UnverifiedOemMacroLength, unsupported.decoder.feed(&.{126}));
    for ([_]u16{ 1443, 1444 }) |length| {
        var h = try Harness.init(.{ .oem_macro_message_bytes = length });
        defer h.deinit();
        try h.ready(1, 1, 65536);
        h.outbound.clearRetainingCapacity();
        var message: [1445]u8 = @splat(0);
        message[0] = 126;
        message[length] = 102;
        try h.pump(message[0 .. length + 1], 11);
        try T.expectEqualSlices(u8, &.{102}, h.outbound.items);
        try h.decoder.finish();
    }
}

test "BMC all byte split positions preserve one Tight FBU with LastRect and OEM keepalive" {
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(allocator);
    try updateHeader(&bytes, 65535);
    try rect(&bytes, 0, 0, 2, 2, 7);
    var payload = try tightCompressed(1, null, first_streams[0]);
    defer payload.deinit(allocator);
    try bytes.appendSlice(allocator, payload.items);
    try rect(&bytes, 0, 0, 0, 0, -224);
    try bytes.append(allocator, 102);
    for (0..bytes.items.len + 1) |split| {
        var h = try Harness.init(.{});
        defer h.deinit();
        try h.ready(2, 2, 65536);
        try h.pump(bytes.items[0..split], 65536);
        try h.pump(bytes.items[split..], 65536);
        try T.expectEqual(@as(usize, 1), h.frames.items.len);
        try T.expectEqualSlices(u8, &.{ 10, 20, 30, 255, 40, 50, 60, 255, 70, 80, 90, 255, 100, 110, 120, 255 }, h.frames.items[0].pixels);
        try T.expectEqual(@as(u8, 102), h.outbound.items[h.outbound.items.len - 1]);
        try h.decoder.finish();
    }
}

test "BMC DesktopSize invalidates the base and publishes only a newly complete frame" {
    var h = try Harness.init(.{});
    defer h.deinit();
    try h.ready(1, 1, 65536);
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(allocator);
    try updateHeader(&bytes, 1);
    try rect(&bytes, 0, 0, 1, 1, 7);
    try bytes.appendSlice(allocator, &.{ 0x80, 1, 2, 3 });
    try updateHeader(&bytes, 2);
    try rect(&bytes, 0, 0, 2, 1, -223);
    try rect(&bytes, 0, 0, 1, 1, 7);
    try bytes.appendSlice(allocator, &.{ 0x80, 4, 5, 6 });
    try h.pump(bytes.items, 65536);
    try T.expectEqual(@as(usize, 1), h.frames.items.len);
    try T.expectEqual(@as(u8, 0), h.outbound.items[h.outbound.items.len - 9]);
    bytes.clearRetainingCapacity();
    try updateHeader(&bytes, 1);
    try rect(&bytes, 1, 0, 1, 1, 7);
    try bytes.appendSlice(allocator, &.{ 0x80, 7, 8, 9 });
    try h.pump(bytes.items, 2);
    try T.expectEqual(@as(usize, 2), h.frames.items.len);
    try T.expectEqual(@as(u64, 2), h.frames.items[1].generation);
    try T.expectEqual(@as(u64, 2), h.frames.items[1].sequence);
    try T.expectEqualSlices(u8, &.{ 4, 5, 6, 255, 7, 8, 9, 255 }, h.frames.items[1].pixels);
}

test "BMC CopyRect preserves overlapping horizontal and vertical source pixels" {
    var h = try Harness.init(.{});
    defer h.deinit();
    try h.ready(3, 2, 65536);
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(allocator);
    try updateHeader(&bytes, 1);
    try rect(&bytes, 0, 0, 3, 2, 0);
    for (0..6) |i| try bytes.appendSlice(allocator, &.{ @intCast(i), 0, 0, 0 });
    try updateHeader(&bytes, 1);
    try rect(&bytes, 1, 0, 2, 1, 1);
    try append16(&bytes, 0);
    try append16(&bytes, 0);
    try updateHeader(&bytes, 1);
    try rect(&bytes, 0, 1, 3, 1, 1);
    try append16(&bytes, 0);
    try append16(&bytes, 0);
    try h.pump(bytes.items, 7);
    const frame = h.frames.items[2].pixels;
    try T.expectEqualSlices(u8, frame[0..12], frame[12..24]);
    try T.expectEqual(@as(u8, 0), frame[2]);
    try T.expectEqual(@as(u8, 0), frame[6]);
    try T.expectEqual(@as(u8, 1), frame[10]);
}

test "BMC RichCursor mask, hide and position remain correctly framed" {
    var h = try Harness.init(.{ .advertise_cursor = true });
    defer h.deinit();
    try h.ready(2, 1, 65536);
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(allocator);
    try updateHeader(&bytes, 4);
    try rect(&bytes, 0, 0, 2, 1, -239);
    try bytes.appendSlice(allocator, &.{ 0, 0, 255, 0, 255, 0, 0, 0, 0x80 });
    try rect(&bytes, 0, 0, 0, 0, -239);
    try rect(&bytes, 1, 0, 0, 0, -232);
    try rect(&bytes, 0, 0, 2, 1, 7);
    try bytes.appendSlice(allocator, &.{ 0x80, 1, 2, 3 });
    try h.pump(bytes.items, 1);
    try T.expectEqual(@as(usize, 2), h.cursors);
    try T.expectEqual(@as(usize, 1), h.frames.items.len);
    try h.decoder.finish();
}

test "BMC Raw streaming accepts an update larger than the transport memory limit" {
    var h = try Harness.init(.{ .max_buffered_bytes = 65536 });
    defer h.deinit();
    h.capture_frames = false;
    try h.ready(2048, 1080, 65536);
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(allocator);
    try updateHeader(&bytes, 1);
    try rect(&bytes, 0, 0, 2048, 1080, 0);
    try h.pump(bytes.items, 65536);
    const chunk: [65536]u8 = @splat(17);
    var remaining: usize = 2048 * 1080 * 4;
    while (remaining != 0) {
        const amount = @min(remaining, chunk.len);
        try h.pump(chunk[0..amount], 65536);
        try T.expect(h.decoder.buffer.capacity <= 65536);
        remaining -= amount;
    }
    try T.expectEqual(@as(usize, 1), h.frame_count);
    try T.expectEqualSlices(u8, &.{ 17, 17, 17, 255 }, h.decoder.frame[0..4]);
    try h.decoder.finish();
}

test "BMC unknown messages and H264 fail without trying to skip to a later frame" {
    var h = try Harness.init(.{});
    defer h.deinit();
    try h.ready(1, 1, 65536);
    try T.expectError(error.UnsupportedServerMessage, h.decoder.feed(&.{ 199, 102 }));
    try T.expectEqual(@as(?u8, 199), h.decoder.failure.?.message_type);
    try T.expectError(error.RfbFailed, h.decoder.feed(&.{102}));
    var encoded = try Harness.init(.{});
    defer encoded.deinit();
    try encoded.ready(1, 1, 65536);
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(allocator);
    try updateHeader(&bytes, 1);
    try rect(&bytes, 0, 0, 1, 1, 50);
    try T.expectError(error.UnsupportedEncoding, encoded.decoder.feed(bytes.items));
    try T.expectEqual(@as(usize, 0), encoded.frame_count);
}

test "BMC size, rectangle, compressed output and truncated-stream bounds" {
    try T.expectEqual(@as(usize, 35389440), try rfb.frameBytesForSize(.{}, 4096, 2160));
    try T.expectError(error.FrameLimitExceeded, rfb.frameBytesForSize(.{ .max_frame_bytes = 32 * 1024 * 1024 }, 4096, 2160));
    try T.expectError(error.FrameLimitExceeded, rfb.frameBytesForSize(.{}, 4097, 2160));
    try T.expectError(error.FrameLimitExceeded, rfb.raw.byteLength(std.math.maxInt(u32), std.math.maxInt(u32), 4));
    var h = try Harness.init(.{});
    defer h.deinit();
    try h.ready(1, 1, 65536);
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(allocator);
    try updateHeader(&bytes, 1);
    try rect(&bytes, 1, 0, 1, 1, 0);
    try T.expectError(error.RectangleOutOfBounds, h.decoder.feed(bytes.items));
    var d = try rfb.Decoder.init(allocator, .{});
    defer d.deinit();
    try d.websocketReady(.{ .tls_trusted = true, .web_authenticated = true, .oem_authenticated = true });
    _ = try d.feed("RFB 003");
    try T.expectError(error.TruncatedRfbStream, d.finish());
    var decoder = rfb.tight.Decoder.init(allocator);
    defer decoder.deinit();
    var compressed = try tightCompressed(1, null, first_streams[0]);
    defer compressed.deinit(allocator);
    var packet = (try rfb.tight.inspect(.{}, 2, 2, compressed.items, 65536)).?;
    packet.decoded_length = 11;
    var frame: [16]u8 = undefined;
    try T.expectError(error.InvalidCompressedData, decoder.apply(packet, .{}, .{ .x = 0, .y = 0, .width = 2, .height = 2 }, 2, &frame, 65536));
    try T.expectError(error.DecodeLimitExceeded, rfb.tight.inspect(.{}, 2, 2, compressed.items, 11));
    try T.expectError(error.UnsupportedTightMode, rfb.tight.inspect(.{}, 1, 1, &.{0xa0}, 65536));
    try T.expectError(error.InvalidTightRectangle, rfb.tight.inspect(.{}, 2049, 1, &.{0x80}, 65536));
    try T.expectError(error.InvalidTightPalette, rfb.tight.inspect(.{}, 1, 1, &.{ 0x40, 1, 0 }, 65536));
}

test "BMC OEM handshake occupied, session-limit and unsupported states fail closed" {
    const cases = [_]struct { bytes: [4]u8, expected: anyerror }{
        .{ .bytes = .{ 104, 1, 0, 0 }, .expected = error.OemExclusiveSession },
        .{ .bytes = .{ 104, 2, 0, 0 }, .expected = error.OemSessionLimit },
        .{ .bytes = .{ 104, 3, 0, 0 }, .expected = error.UnsupportedOemHandshake },
        .{ .bytes = .{ 199, 0, 0, 0 }, .expected = error.UnsupportedOemHandshake },
    };
    for (cases) |case| {
        var h = try Harness.init(.{});
        defer h.deinit();
        try h.decoder.websocketReady(.{ .tls_trusted = true, .web_authenticated = true, .oem_authenticated = true });
        try h.pump("RFB 003.008\n", 1);
        try T.expectError(case.expected, h.decoder.feed(&case.bytes));
        try T.expectEqual(rfb.Phase.oem_magic, h.decoder.failure.?.phase);
        try T.expectEqual(@as(usize, 16), h.outbound.items.len);
    }
    var security = try Harness.init(.{});
    defer security.deinit();
    try security.decoder.websocketReady(.{ .tls_trusted = true, .web_authenticated = true, .oem_authenticated = true });
    try security.pump("RFB 003.008\n", 12);
    try T.expectError(error.UnsupportedSecurityType, security.decoder.feed(&.{ 104, 0, 0, 0, 1, 2 }));
}

const Budget = struct {
    used: usize = 0,
    maximum: usize,
    fn reserve(context: *anyopaque, length: usize) !void {
        const self: *Budget = @ptrCast(@alignCast(context));
        if (length > self.maximum - self.used) return error.ResourceBudgetExceeded;
        self.used += length;
    }
    fn release(context: *anyopaque, length: usize) void {
        const self: *Budget = @ptrCast(@alignCast(context));
        self.used -= length;
    }
    fn facade(self: *Budget) rfb.MemoryBudget {
        return .{ .context = self, .reserve = reserve, .release = release };
    }
};

test "BMC frame memory reservation releases coverage and failed resize retains the old work frame" {
    var budget: Budget = .{ .maximum = 16 };
    {
        var h = try Harness.init(.{ .memory_budget = budget.facade() });
        defer h.deinit();
        try h.ready(2, 1, 65536);
        try T.expectEqual(@as(usize, 9), budget.used);
        var bytes: std.ArrayList(u8) = .empty;
        defer bytes.deinit(allocator);
        try updateHeader(&bytes, 1);
        try rect(&bytes, 0, 0, 2, 1, 7);
        try bytes.appendSlice(allocator, &.{ 0x80, 1, 2, 3 });
        try h.pump(bytes.items, 65536);
        try T.expectEqual(@as(usize, 8), budget.used);
        bytes.clearRetainingCapacity();
        try updateHeader(&bytes, 1);
        try rect(&bytes, 0, 0, 3, 1, -223);
        try T.expectError(error.ResourceBudgetExceeded, h.decoder.feed(bytes.items));
        try T.expectEqual(@as(usize, 8), budget.used);
        try T.expectEqual(@as(u16, 2), h.decoder.width);
        try T.expectEqualSlices(u8, &.{ 1, 2, 3, 255, 1, 2, 3, 255 }, h.decoder.frame);
    }
    try T.expectEqual(@as(usize, 0), budget.used);
}

test "BMC stale control popup context cannot answer a newer request" {
    var h = try Harness.init(.{});
    defer h.deinit();
    try h.ready(1, 1, 65536);
    try h.pump(&.{ 107, 1, 2, 3, 107, 1, 2, 4 }, 65536);
    const previous_output = h.outbound.items.len;
    try T.expectError(error.StaleControlRequest, h.decoder.replyControl(.{ 107, 1, 2, 3 }, .full_control));
    _ = try h.drain();
    try T.expectEqual(previous_output, h.outbound.items.len);
    try h.decoder.replyControl(.{ 107, 1, 2, 4 }, .reject);
    _ = try h.drain();
    try T.expectEqualSlices(u8, &.{ 108, 127, 2, 4 }, h.outbound.items[h.outbound.items.len - 4 ..]);
}

test "BMC malformed palettes, UTF8, JPEG and compressed data fail rather than desynchronize" {
    var decoder = rfb.tight.Decoder.init(allocator);
    defer decoder.deinit();
    const bad_index = [_]u8{ 0x40, 1, 2, 255, 0, 0, 0, 255, 0, 0, 0, 255, 3 };
    var packet = (try rfb.tight.inspect(.{}, 1, 1, &bad_index, 65536)).?;
    var frame: [16]u8 = undefined;
    try T.expectError(error.InvalidTightPaletteIndex, decoder.apply(packet, .{}, .{ .x = 0, .y = 0, .width = 1, .height = 1 }, 1, &frame, 65536));
    packet = (try rfb.tight.inspect(.{}, 1, 1, &.{ 0x90, 3, 1, 2, 3 }, 65536)).?;
    try T.expectError(error.InvalidJpeg, decoder.apply(packet, .{}, .{ .x = 0, .y = 0, .width = 1, .height = 1 }, 1, &frame, 65536));
    packet = (try rfb.tight.inspect(.{}, 2, 2, &.{ 1, 4, 1, 2, 3, 4 }, 65536)).?;
    try T.expectError(error.InvalidCompressedData, decoder.apply(packet, .{}, .{ .x = 0, .y = 0, .width = 2, .height = 2 }, 2, &frame, 65536));
    var h = try Harness.init(.{});
    defer h.deinit();
    try h.ready(1, 1, 65536);
    try T.expectError(error.InvalidOemText, h.decoder.feed(&.{ 121, 4, 0, 2, 0xff, 0xff }));
}
